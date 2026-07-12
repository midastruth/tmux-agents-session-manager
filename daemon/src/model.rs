use crate::protocol::{AgentState, Request};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_FRAMES: usize = 64;
const MAX_FRAME_BYTES: usize = 64;
const MAX_PENDING_CLAUDE_MISSES: u8 = 3;

#[derive(Clone, Debug)]
pub struct Config {
    pub prefix: String,
    pub status_enabled: bool,
    pub animate_working: bool,
    pub sigil: String,
    pub icon_blocked: String,
    pub icon_working: String,
    pub icon_done: String,
    pub icon_idle: String,
    pub show_idle: bool,
    pub frames: Vec<String>,
    pub animation_interval: Duration,
    pub claude_working_interval: Duration,
    pub claude_idle_interval: Duration,
    pub claude_timeout: Duration,
    pub claude_failure_max_interval: Duration,
    pub state_ttl: Duration,
}

impl Config {
    pub fn load(server_socket: &str) -> Result<Self, String> {
        let output = tmux_output(server_socket, ["show-options", "-g"])
            .ok_or("failed to read tmux global options")?;
        let mut values = HashMap::new();
        for line in output.lines() {
            if let Some((name, value)) = line.split_once(' ') {
                values.insert(name.to_string(), decode_tmux_value(value));
            }
        }
        Self::from_values(&values)
    }

    fn from_values(values: &HashMap<String, String>) -> Result<Self, String> {
        let get = |name: &str, default: &str| {
            values
                .get(name)
                .filter(|v| !v.is_empty())
                .map(String::as_str)
                .unwrap_or(default)
                .to_string()
        };
        let parse_u64 = |name: &str, default: u64, label: &str| -> Result<u64, String> {
            let raw = values.get(name).map(String::as_str).unwrap_or("");
            if raw.is_empty() {
                return Ok(default);
            }
            raw.parse::<u64>()
                .map_err(|_| format!("{label} must be an integer"))
        };
        let working_icon = get("@agent_status_icon_working", "✦");
        let default_frames = format!("{working_icon} ✷ ✹ ✴");
        let frame_text = get("@agent_status_anim_frames", &default_frames);
        let frames: Vec<String> = frame_text.split_whitespace().map(str::to_string).collect();
        if frames.is_empty()
            || frames.len() > MAX_FRAMES
            || frames.iter().any(|v| v.len() > MAX_FRAME_BYTES)
        {
            return Err("animation frames must contain 1..64 frames of at most 64 bytes".into());
        }
        let animation_ms = parse_u64("@agent_animation_interval_ms", 1000, "animation interval")?;
        if animation_ms < 250 {
            return Err("animation interval must be at least 250ms".into());
        }
        let working = parse_u64(
            "@agent_claude_working_interval",
            3,
            "Claude working interval",
        )?;
        let idle = parse_u64("@agent_claude_idle_interval", 10, "Claude idle interval")?;
        let timeout = parse_u64("@agent_claude_timeout", 2, "Claude timeout")?;
        let failure_max = parse_u64(
            "@agent_claude_failure_max_interval",
            30,
            "Claude failure maximum interval",
        )?;
        if working == 0 || idle == 0 || timeout == 0 {
            return Err("Claude intervals and timeout must be positive".into());
        }
        if failure_max < working || failure_max < idle {
            return Err(
                "Claude failure maximum interval must not be shorter than normal polling intervals"
                    .into(),
            );
        }
        let ttl = parse_u64("@agent_state_ttl", 259200, "state TTL")?;
        Ok(Self {
            prefix: get("@agent_session_prefix", "agent-"),
            status_enabled: get("@agent_status", "on") == "on",
            animate_working: get("@agent_status_animate_working", "on") == "on",
            sigil: get("@agent_status_sigil", "agents"),
            icon_blocked: get("@agent_status_icon_blocked", "●"),
            icon_working: working_icon,
            icon_done: get("@agent_status_icon_done", "✓"),
            icon_idle: get("@agent_status_icon_idle", "·"),
            show_idle: get("@agent_status_show_idle", "off") == "on",
            frames,
            animation_interval: Duration::from_millis(animation_ms),
            claude_working_interval: Duration::from_secs(working),
            claude_idle_interval: Duration::from_secs(idle),
            claude_timeout: Duration::from_secs(timeout),
            claude_failure_max_interval: Duration::from_secs(failure_max),
            state_ttl: Duration::from_secs(ttl),
        })
    }

    #[cfg(test)]
    fn test() -> Self {
        Self {
            prefix: "agent-".into(),
            status_enabled: true,
            animate_working: true,
            sigil: "agents".into(),
            icon_blocked: "●".into(),
            icon_working: "✦".into(),
            icon_done: "✓".into(),
            icon_idle: "·".into(),
            show_idle: false,
            frames: vec!["a".into(), "b".into()],
            animation_interval: Duration::from_secs(1),
            claude_working_interval: Duration::from_secs(3),
            claude_idle_interval: Duration::from_secs(10),
            claude_timeout: Duration::from_secs(1),
            claude_failure_max_interval: Duration::from_secs(30),
            state_ttl: Duration::from_secs(60),
        }
    }
}

#[derive(Clone, Debug)]
struct AgentRecord {
    source: Source,
    tool: String,
    pane_id: Option<String>,
    session_name: Option<String>,
    process_generation: Option<String>,
    sequence: u64,
    state: AgentState,
    changed_at: SystemTime,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Source {
    Event,
    Claude,
}

#[derive(Debug)]
struct ClaudeQueryFinished {
    generation: u64,
    completed: Instant,
    result: Result<Vec<ClaudeStatus>, String>,
}
#[derive(Debug)]
struct ClaudeStatus {
    session_id: String,
    state: AgentState,
    pane_id: Option<String>,
    session_name: Option<String>,
}

#[derive(Clone, Debug)]
struct ClaudeTarget {
    session_name: Option<String>,
    observed: bool,
    successful_misses: u8,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeAgent {
    pid: u32,
    #[allow(dead_code)]
    cwd: String,
    kind: String,
    #[allow(dead_code)]
    started_at: Value,
    session_id: String,
    #[allow(dead_code)]
    name: String,
    status: String,
}

pub struct StateCenter {
    pub server_socket: String,
    config: Config,
    agents: HashMap<String, AgentRecord>,
    retired_event_generations: HashSet<String>,
    frame_index: usize,
    animation_deadline: Option<Instant>,
    expiry_deadline: Option<Instant>,
    claude_deadline: Option<Instant>,
    claude_generation: u64,
    claude_in_flight: bool,
    claude_targets: HashMap<String, ClaudeTarget>,
    claude_failures: u32,
    claude_sender: Sender<ClaudeQueryFinished>,
    claude_receiver: Receiver<ClaudeQueryFinished>,
    published_summary: Option<String>,
}

impl StateCenter {
    pub fn new(server_socket: String, config: Config) -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            server_socket,
            config,
            agents: HashMap::new(),
            retired_event_generations: HashSet::new(),
            frame_index: 0,
            animation_deadline: None,
            expiry_deadline: None,
            claude_deadline: None,
            claude_generation: 0,
            claude_in_flight: false,
            claude_targets: HashMap::new(),
            claude_failures: 0,
            claude_sender: sender,
            claude_receiver: receiver,
            published_summary: None,
        }
    }

    pub fn restore_once(&mut self) {
        let format = "#{session_name}\t#{pane_id}\t#{@agent_tool}\t#{@agent_state}\t#{@agent_state_at}\t#{@agent_process_generation}\t#{@agent_sequence}";
        let Some(output) = tmux_output(&self.server_socket, ["list-sessions", "-F", format]) else {
            return;
        };
        for line in output.lines() {
            self.restore_mirror_row(line, true);
        }
        let pane_format = "#{session_name}\t#{pane_id}\t#{@agent_tool}\t#{@agent_state}\t#{@agent_state_at}\t#{@agent_process_generation}\t#{@agent_sequence}";
        if let Some(panes) =
            tmux_output(&self.server_socket, ["list-panes", "-a", "-F", pane_format])
        {
            for line in panes.lines() {
                self.restore_mirror_row(line, false);
            }
        }
    }

    fn restore_mirror_row(&mut self, line: &str, managed_only: bool) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 7 {
            return;
        }
        let managed = fields[0].starts_with(&self.config.prefix);
        if managed_only != managed {
            return;
        }
        if fields[2] == "claude" {
            self.claude_targets.insert(
                fields[1].to_string(),
                ClaudeTarget {
                    session_name: Some(fields[0].to_string()),
                    observed: false,
                    successful_misses: 0,
                },
            );
            self.claude_deadline = Some(Instant::now());
            return;
        }
        if fields[2].is_empty() {
            return;
        }
        let Some(state) = parse_state(fields[3]) else {
            return;
        };
        let changed_at = fields[4]
            .parse::<u64>()
            .ok()
            .map(|s| UNIX_EPOCH + Duration::from_secs(s))
            .unwrap_or_else(SystemTime::now);
        let generation = if fields[5].is_empty() {
            format!("restore:{}", fields[1])
        } else {
            fields[5].to_string()
        };
        let sequence = fields[6].parse().unwrap_or(0);
        let key = event_key(fields[2], fields[1], &generation);
        self.agents.insert(
            key,
            AgentRecord {
                source: Source::Event,
                tool: fields[2].into(),
                pane_id: Some(fields[1].into()),
                session_name: Some(fields[0].into()),
                process_generation: Some(generation),
                sequence,
                state,
                changed_at,
            },
        );
    }

    pub fn replace_config(&mut self, config: Config) {
        self.config = config;
        self.frame_index = 0;
        self.animation_deadline = None;
        self.claude_deadline = Some(Instant::now());
    }

    pub fn apply(&mut self, request: Request) -> Result<(), String> {
        match request {
            Request::Report {
                tool,
                pane_id,
                process_generation,
                sequence,
                state,
                session_name,
            } => {
                if tool == "claude" {
                    return Err("Claude state is owned by the native poller".into());
                }
                let key = event_key(&tool, &pane_id, &process_generation);
                if self.retired_event_generations.contains(&key) {
                    return Ok(());
                }
                self.remove_reused_pane(&tool, &pane_id, &process_generation);
                if self
                    .agents
                    .get(&key)
                    .is_some_and(|record| sequence <= record.sequence)
                {
                    return Ok(());
                }
                self.agents.insert(
                    key,
                    AgentRecord {
                        source: Source::Event,
                        tool,
                        pane_id: Some(pane_id),
                        session_name,
                        process_generation: Some(process_generation),
                        sequence,
                        state,
                        changed_at: SystemTime::now(),
                    },
                );
            }
            Request::Seen {
                pane_id,
                session_id,
            } => {
                for (key, record) in &mut self.agents {
                    if (pane_id
                        .as_ref()
                        .is_some_and(|p| record.pane_id.as_ref() == Some(p))
                        || session_id.as_ref().is_some_and(|s| key == &claude_key(s)))
                        && record.state == AgentState::Done
                    {
                        record.state = AgentState::Idle;
                        record.changed_at = SystemTime::now();
                    }
                }
            }
            Request::Exited {
                pane_id,
                session_name,
            } => {
                for (identity, record) in &self.agents {
                    let exits_record = pane_id
                        .as_ref()
                        .is_some_and(|p| record.pane_id.as_ref() == Some(p))
                        || session_name
                            .as_ref()
                            .is_some_and(|s| record.session_name.as_ref() == Some(s));
                    if exits_record && record.source == Source::Event {
                        self.retired_event_generations.insert(identity.clone());
                    }
                }
                self.agents.retain(|_, record| {
                    !(pane_id
                        .as_ref()
                        .is_some_and(|p| record.pane_id.as_ref() == Some(p))
                        || session_name
                            .as_ref()
                            .is_some_and(|s| record.session_name.as_ref() == Some(s)))
                });
                self.claude_targets.retain(|pane, target| {
                    !(pane_id.as_ref() == Some(pane)
                        || session_name
                            .as_ref()
                            .is_some_and(|value| target.session_name.as_ref() == Some(value)))
                });
            }
            Request::ClaudeStarted {
                pane_id,
                session_name,
                session_id: _,
            }
            | Request::ClaudeDiscovered {
                pane_id,
                session_name,
                session_id: _,
            } => {
                self.claude_targets.insert(
                    pane_id,
                    ClaudeTarget {
                        session_name,
                        observed: false,
                        successful_misses: 0,
                    },
                );
                self.claude_deadline = Some(Instant::now());
            }
            _ => return Err("command is not a state event".into()),
        }
        Ok(())
    }

    fn remove_reused_pane(&mut self, tool: &str, pane: &str, generation: &str) {
        let reused: Vec<String> = self
            .agents
            .iter()
            .filter(|(_, record)| {
                record.source == Source::Event
                    && record.tool == tool
                    && record.pane_id.as_deref() == Some(pane)
                    && record.process_generation.as_deref() != Some(generation)
            })
            .map(|(identity, _)| identity.clone())
            .collect();
        for identity in reused {
            self.agents.remove(&identity);
            self.retired_event_generations.insert(identity);
        }
    }

    pub fn process_deadlines(&mut self, now: Instant) {
        while let Ok(result) = self.claude_receiver.try_recv() {
            self.apply_claude_result(result);
        }
        if self
            .animation_deadline
            .is_some_and(|deadline| deadline <= now)
        {
            self.frame_index = (self.frame_index + 1) % self.config.frames.len();
            self.animation_deadline = Some(now + self.config.animation_interval);
        }
        self.expire_states();
        if self.claude_deadline.is_some_and(|deadline| deadline <= now) && !self.claude_in_flight {
            self.start_claude_query();
        }
    }

    fn expire_states(&mut self) {
        if self.config.state_ttl.is_zero() {
            return;
        }
        let ttl = self.config.state_ttl;
        self.agents.retain(|_, record| match record.state {
            AgentState::Working | AgentState::Blocked => record
                .changed_at
                .elapsed()
                .map(|age| age <= ttl)
                .unwrap_or(true),
            _ => true,
        });
    }

    fn start_claude_query(&mut self) {
        if self.claude_targets.is_empty() {
            self.claude_deadline = None;
            return;
        }
        self.claude_generation = self.claude_generation.wrapping_add(1);
        let generation = self.claude_generation;
        let timeout = self.config.claude_timeout;
        let server_socket = self.server_socket.clone();
        let sender = self.claude_sender.clone();
        self.claude_in_flight = true;
        self.claude_deadline = None;
        thread::spawn(move || {
            let result = run_claude_command(timeout)
                .and_then(|bytes| collect_claude_statuses(&server_socket, &bytes));
            let _ = sender.send(ClaudeQueryFinished {
                generation,
                completed: Instant::now(),
                result,
            });
        });
    }

    fn apply_claude_result(&mut self, result: ClaudeQueryFinished) {
        if result.generation != self.claude_generation {
            return;
        }
        self.claude_in_flight = false;
        match result.result {
            Ok(mut statuses) => {
                self.claude_failures = 0;
                statuses.retain(|status| {
                    status
                        .pane_id
                        .as_ref()
                        .is_some_and(|pane| self.claude_targets.contains_key(pane))
                });

                let matched_panes: HashSet<String> = statuses
                    .iter()
                    .filter_map(|status| status.pane_id.clone())
                    .collect();
                self.claude_targets.retain(|pane, target| {
                    if matched_panes.contains(pane) {
                        target.observed = true;
                        target.successful_misses = 0;
                        return true;
                    }
                    if target.observed {
                        return false;
                    }
                    target.successful_misses = target.successful_misses.saturating_add(1);
                    target.successful_misses < MAX_PENDING_CLAUDE_MISSES
                });

                let returned: HashSet<String> =
                    statuses.iter().map(|s| claude_key(&s.session_id)).collect();
                self.agents.retain(|key, record| {
                    record.source != Source::Claude || returned.contains(key)
                });
                for status in statuses {
                    let key = claude_key(&status.session_id);
                    let previous_record = self.agents.get(&key);
                    let state = self.claude_display_state(previous_record, &status);
                    let changed_at = previous_record
                        .filter(|record| {
                            record.state == state
                                && record.pane_id == status.pane_id
                                && record.session_name == status.session_name
                        })
                        .map(|record| record.changed_at)
                        .unwrap_or_else(SystemTime::now);
                    self.agents.insert(
                        key,
                        AgentRecord {
                            source: Source::Claude,
                            tool: "claude".into(),
                            pane_id: status.pane_id,
                            session_name: status.session_name,
                            process_generation: None,
                            sequence: 0,
                            state,
                            changed_at,
                        },
                    );
                }
            }
            Err(_) => self.claude_failures = self.claude_failures.saturating_add(1),
        }
        if self.claude_targets.is_empty() {
            self.claude_deadline = None;
            return;
        }

        let working = self
            .agents
            .values()
            .any(|r| r.source == Source::Claude && r.state == AgentState::Working);
        let pending = self.claude_targets.values().any(|target| !target.observed);
        let base = if working || pending {
            self.config.claude_working_interval
        } else {
            self.config.claude_idle_interval
        };
        let delay = if self.claude_failures == 0 {
            base
        } else {
            (base * (1u32 << self.claude_failures.min(5)))
                .min(self.config.claude_failure_max_interval)
        };
        self.claude_deadline = Some(result.completed + delay);
    }

    fn claude_display_state(
        &self,
        previous_record: Option<&AgentRecord>,
        status: &ClaudeStatus,
    ) -> AgentState {
        if status.state != AgentState::Idle {
            return status.state;
        }
        let Some(record) = previous_record else {
            return AgentState::Idle;
        };
        if record.state == AgentState::Done {
            return AgentState::Done;
        }
        if record.state != AgentState::Working {
            return AgentState::Idle;
        }
        let Some(pane_id) = status.pane_id.as_deref() else {
            return AgentState::Done;
        };
        if is_pane_visible(&self.server_socket, pane_id) {
            AgentState::Idle
        } else {
            AgentState::Done
        }
    }

    pub fn reconcile(&mut self, now: Instant) {
        let working = self
            .agents
            .values()
            .filter(|r| r.state == AgentState::Working)
            .count();
        if self.config.status_enabled && self.config.animate_working && working > 0 {
            if self.animation_deadline.is_none() {
                self.animation_deadline = Some(now + self.config.animation_interval);
            }
        } else {
            self.animation_deadline = None;
            self.frame_index = 0;
        }
        self.expiry_deadline = self.next_expiry();
        let summary = if self.config.status_enabled {
            self.render()
        } else {
            String::new()
        };
        if self.published_summary.as_ref() == Some(&summary) {
            return;
        }
        if self.publish(&summary) {
            self.published_summary = Some(summary);
        }
    }

    fn next_expiry(&self) -> Option<Instant> {
        if self.config.state_ttl.is_zero() {
            return None;
        }
        self.agents
            .values()
            .filter(|r| matches!(r.state, AgentState::Working | AgentState::Blocked))
            .filter_map(|r| {
                let age = r.changed_at.elapsed().ok()?;
                Some(Instant::now() + self.config.state_ttl.saturating_sub(age))
            })
            .min()
    }

    pub fn next_wait(&self, now: Instant) -> Duration {
        [
            self.animation_deadline,
            self.expiry_deadline,
            self.claude_deadline,
        ]
        .into_iter()
        .flatten()
        .map(|deadline| deadline.saturating_duration_since(now))
        .min()
        .unwrap_or(Duration::from_secs(60))
    }

    fn render(&self) -> String {
        let mut blocked = 0;
        let mut working = 0;
        let mut done = 0;
        let mut idle = 0;
        for record in self.agents.values() {
            match record.state {
                AgentState::Blocked => blocked += 1,
                AgentState::Working => working += 1,
                AgentState::Done => done += 1,
                _ => idle += 1,
            }
        }
        let mut segments = Vec::new();
        if blocked > 0 {
            segments.push(format!("{blocked}{}", self.config.icon_blocked));
        }
        if working > 0 {
            let icon = if self.config.animate_working {
                &self.config.frames[self.frame_index]
            } else {
                &self.config.icon_working
            };
            segments.push(format!("{working}{icon}"));
        }
        if done > 0 {
            segments.push(format!("{done}{}", self.config.icon_done));
        }
        if self.config.show_idle && idle > 0 {
            segments.push(format!("{idle}{}", self.config.icon_idle));
        }
        if segments.is_empty() {
            String::new()
        } else {
            format!("{} {}", self.config.sigil, segments.join(" "))
        }
    }

    fn publish(&mut self, summary: &str) -> bool {
        let status = Command::new("tmux")
            .args([
                "-S",
                &self.server_socket,
                "set-option",
                "-g",
                "@agent_status_cache",
                summary,
            ])
            .status();
        if !status.is_ok_and(|s| s.success()) {
            return false;
        }

        // Cache publication is authoritative. Redraw is best-effort and uses
        // explicit client targets because a daemon has no current tmux client.
        let clients = tmux_output(
            &self.server_socket,
            ["list-clients", "-F", "#{client_name}"],
        )
        .unwrap_or_default();
        let clients: Vec<&str> = clients
            .lines()
            .filter(|client| !client.is_empty())
            .collect();
        if !clients.is_empty() {
            let mut args: Vec<String> = vec!["-S".into(), self.server_socket.clone()];
            for (index, client) in clients.iter().enumerate() {
                if index > 0 {
                    args.push(";".into());
                }
                args.extend([
                    "refresh-client".into(),
                    "-S".into(),
                    "-t".into(),
                    (*client).into(),
                ]);
            }
            let _ = Command::new("tmux").args(args).status();
        }
        true
    }

    pub fn snapshot(&self) -> Value {
        let records: Vec<Value> = self.agents.iter().map(|(identity, record)| json!({
            "identity": identity,
            "tool": record.tool,
            "paneId": record.pane_id,
            "sessionName": record.session_name,
            "state": match record.state { AgentState::Blocked => "blocked", AgentState::Working => "working", AgentState::Done => "done", AgentState::Idle => "idle" },
            "changedAt": record.changed_at.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
        })).collect();
        let summary = if self.config.status_enabled {
            self.render()
        } else {
            String::new()
        };
        json!({ "summary": summary, "agents": self.agents.len(), "records": records, "working": self.agents.values().filter(|r| r.state == AgentState::Working).count(), "claudeInFlight": self.claude_in_flight, "claudeGeneration": self.claude_generation, "frameIndex": self.frame_index })
    }
}

fn decode_tmux_value(value: &str) -> String {
    if value == "''" {
        return String::new();
    }
    if value.starts_with('"') && value.ends_with('"') {
        if let Ok(decoded) = serde_json::from_str::<String>(value) {
            return decoded;
        }
        return value[1..value.len() - 1].to_string();
    }
    value.to_string()
}

fn event_key(tool: &str, pane: &str, generation: &str) -> String {
    format!("event:{tool}:{pane}:{generation}")
}
fn claude_key(session_id: &str) -> String {
    format!("claude:{session_id}")
}
fn parse_state(value: &str) -> Option<AgentState> {
    match value {
        "blocked" => Some(AgentState::Blocked),
        "working" => Some(AgentState::Working),
        "done" => Some(AgentState::Done),
        "idle" => Some(AgentState::Idle),
        _ => None,
    }
}
fn parse_claude_state(value: &str) -> Option<AgentState> {
    match value {
        "busy" => Some(AgentState::Working),
        "waiting" => Some(AgentState::Blocked),
        "idle" => Some(AgentState::Idle),
        _ => None,
    }
}
fn tmux_output<const N: usize>(server_socket: &str, args: [&str; N]) -> Option<String> {
    Command::new("tmux")
        .args(["-S", server_socket])
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

fn is_pane_visible(server_socket: &str, pane_id: &str) -> bool {
    let Some(output) = tmux_output(
        server_socket,
        [
            "display-message",
            "-p",
            "-t",
            pane_id,
            "#{session_attached} #{window_active} #{pane_active}",
        ],
    ) else {
        return false;
    };
    let mut fields = output.split_whitespace();
    let Some(session_attached) = fields.next() else {
        return false;
    };
    let Some(window_active) = fields.next() else {
        return false;
    };
    let Some(pane_active) = fields.next() else {
        return false;
    };
    session_attached != "0" && window_active == "1" && pane_active == "1"
}

fn collect_claude_statuses(server_socket: &str, bytes: &[u8]) -> Result<Vec<ClaudeStatus>, String> {
    let agents: Vec<ClaudeAgent> =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid Claude JSON: {e}"))?;
    let pane_rows = tmux_output(
        server_socket,
        [
            "list-panes",
            "-a",
            "-F",
            "#{pane_id}\t#{session_name}\t#{pane_tty}",
        ],
    )
    .ok_or("failed to list tmux panes for Claude PID association")?;
    let panes: Vec<(&str, &str, &str)> = pane_rows
        .lines()
        .filter_map(|line| {
            let mut fields = line.split('\t');
            Some((fields.next()?, fields.next()?, fields.next()?))
        })
        .collect();
    // One process-table snapshot gives fixed collector subprocess cost even
    // when Claude reports many agents.
    let ps_output = Command::new("ps")
        .args(["-axo", "pid=,tty="])
        .output()
        .map_err(|e| e.to_string())?;
    if !ps_output.status.success() {
        return Err("failed to snapshot PID/TTY table".into());
    }
    let pid_ttys: HashMap<u32, String> = String::from_utf8_lossy(&ps_output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse::<u32>().ok()?;
            let tty = fields.next()?.to_string();
            Some((pid, tty))
        })
        .collect();
    let mut statuses = Vec::new();
    for agent in agents {
        if agent.kind != "interactive"
            || agent.session_id.is_empty()
            || agent.session_id.len() > 1024
        {
            continue;
        }
        let Some(state) = parse_claude_state(&agent.status) else {
            continue;
        };
        let Some(raw_tty) = pid_ttys.get(&agent.pid).cloned() else {
            continue;
        };
        if raw_tty.is_empty() || raw_tty == "??" || raw_tty == "?" {
            continue;
        }
        let tty = if raw_tty.starts_with("/dev/") {
            raw_tty
        } else {
            format!("/dev/{raw_tty}")
        };
        let Some((pane_id, session_name, _)) =
            panes.iter().find(|(_, _, pane_tty)| *pane_tty == tty)
        else {
            continue;
        };
        statuses.push(ClaudeStatus {
            session_id: agent.session_id,
            state,
            pane_id: Some((*pane_id).to_string()),
            session_name: Some((*session_name).to_string()),
        });
    }
    Ok(statuses)
}

fn run_claude_command(timeout: Duration) -> Result<Vec<u8>, String> {
    let mut child = Command::new("claude");
    child
        .args(["agents", "--json"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    unsafe {
        child.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = child.spawn().map_err(|e| e.to_string())?;
    let pid = child.id() as i32;
    let mut stdout = child
        .stdout
        .take()
        .ok_or("Claude command stdout unavailable")?;
    let output_reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).map(|_| bytes)
    });
    let started = Instant::now();
    loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(status) => {
                let output = output_reader
                    .join()
                    .map_err(|_| "Claude output reader panicked")?
                    .map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err(format!("Claude command exited {status}"));
                }
                return Ok(output);
            }
            None if started.elapsed() >= timeout => {
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
                let _ = child.wait();
                let _ = output_reader.join();
                return Err("Claude command timed out".into());
            }
            None => thread::sleep(Duration::from_millis(20)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn center() -> StateCenter {
        StateCenter::new("/nonexistent".into(), Config::test())
    }
    #[test]
    fn startup_restore_accepts_manual_pi_codex_mirrors() {
        let mut c = center();
        c.restore_mirror_row("work\t%2\tpi\tdone\t123\tmanual-generation\t7", false);
        assert_eq!(c.agents.len(), 1);
        let restored = c.agents.values().next().unwrap();
        assert_eq!(restored.pane_id.as_deref(), Some("%2"));
        assert_eq!(restored.state, AgentState::Done);
        assert_eq!(restored.sequence, 7);
    }
    #[test]
    fn old_sequence_does_not_replace_new() {
        let mut c = center();
        c.apply(Request::Report {
            tool: "pi".into(),
            pane_id: "%1".into(),
            process_generation: "g".into(),
            sequence: 2,
            state: AgentState::Working,
            session_name: None,
        })
        .unwrap();
        c.apply(Request::Report {
            tool: "pi".into(),
            pane_id: "%1".into(),
            process_generation: "g".into(),
            sequence: 1,
            state: AgentState::Done,
            session_name: None,
        })
        .unwrap();
        assert_eq!(c.agents.values().next().unwrap().state, AgentState::Working);
    }
    #[test]
    fn pane_reuse_drops_old_generation() {
        let mut c = center();
        for g in ["a", "b"] {
            c.apply(Request::Report {
                tool: "codex".into(),
                pane_id: "%1".into(),
                process_generation: g.into(),
                sequence: 1,
                state: AgentState::Idle,
                session_name: None,
            })
            .unwrap();
        }
        c.apply(Request::Report {
            tool: "codex".into(),
            pane_id: "%1".into(),
            process_generation: "a".into(),
            sequence: 2,
            state: AgentState::Done,
            session_name: None,
        })
        .unwrap();
        assert_eq!(c.agents.len(), 1);
        assert_eq!(
            c.agents
                .values()
                .next()
                .unwrap()
                .process_generation
                .as_deref(),
            Some("b")
        );
    }
    #[test]
    fn seen_only_clears_done() {
        let mut c = center();
        c.apply(Request::Report {
            tool: "pi".into(),
            pane_id: "%1".into(),
            process_generation: "g".into(),
            sequence: 1,
            state: AgentState::Done,
            session_name: None,
        })
        .unwrap();
        c.apply(Request::Seen {
            pane_id: Some("%1".into()),
            session_id: None,
        })
        .unwrap();
        assert_eq!(c.agents.values().next().unwrap().state, AgentState::Idle);
    }
    #[test]
    fn animation_stops_and_resets() {
        let mut c = center();
        c.frame_index = 1;
        c.animation_deadline = Some(Instant::now());
        c.published_summary = Some(String::new());
        c.reconcile(Instant::now());
        assert_eq!(c.frame_index, 0);
        assert!(c.animation_deadline.is_none());
    }
    #[test]
    fn disabled_status_does_not_schedule_animation() {
        let mut c = center();
        c.config.status_enabled = false;
        c.agents.insert(
            "working".into(),
            AgentRecord {
                source: Source::Event,
                tool: "pi".into(),
                pane_id: None,
                session_name: None,
                process_generation: None,
                sequence: 1,
                state: AgentState::Working,
                changed_at: SystemTime::now(),
            },
        );
        c.published_summary = Some(String::new());
        c.reconcile(Instant::now());
        assert!(c.animation_deadline.is_none());
        assert_eq!(c.frame_index, 0);
    }
    #[test]
    fn failed_claude_result_preserves_state() {
        let mut c = center();
        c.agents.insert(
            claude_key("s"),
            AgentRecord {
                source: Source::Claude,
                tool: "claude".into(),
                pane_id: None,
                session_name: None,
                process_generation: None,
                sequence: 0,
                state: AgentState::Done,
                changed_at: SystemTime::now(),
            },
        );
        c.claude_targets.insert(
            "%1".into(),
            ClaudeTarget {
                session_name: None,
                observed: true,
                successful_misses: 0,
            },
        );
        c.claude_generation = 2;
        c.claude_in_flight = true;
        c.apply_claude_result(ClaudeQueryFinished {
            generation: 2,
            completed: Instant::now(),
            result: Err("bad".into()),
        });
        assert_eq!(c.agents.values().next().unwrap().state, AgentState::Done);
        assert!(c.claude_deadline.is_some());
    }
    #[test]
    fn successful_missing_result_removes_observed_claude_target() {
        let mut c = center();
        c.claude_targets.insert(
            "%1".into(),
            ClaudeTarget {
                session_name: None,
                observed: true,
                successful_misses: 0,
            },
        );
        c.claude_generation = 1;
        c.apply_claude_result(ClaudeQueryFinished {
            generation: 1,
            completed: Instant::now(),
            result: Ok(vec![]),
        });
        assert!(c.claude_targets.is_empty());
        assert!(c.claude_deadline.is_none());
    }
    #[test]
    fn pending_claude_target_has_bounded_registration_grace() {
        let mut c = center();
        c.claude_targets.insert(
            "%1".into(),
            ClaudeTarget {
                session_name: None,
                observed: false,
                successful_misses: 0,
            },
        );
        c.claude_generation = 1;
        for miss in 1..=MAX_PENDING_CLAUDE_MISSES {
            c.apply_claude_result(ClaudeQueryFinished {
                generation: 1,
                completed: Instant::now(),
                result: Ok(vec![]),
            });
            assert_eq!(
                c.claude_targets.is_empty(),
                miss == MAX_PENDING_CLAUDE_MISSES
            );
        }
        assert!(c.claude_deadline.is_none());
    }
    #[test]
    fn claude_unseen_working_to_idle_becomes_done_until_seen() {
        let mut c = center();
        c.claude_targets.insert(
            "%1".into(),
            ClaudeTarget {
                session_name: Some("work".into()),
                observed: true,
                successful_misses: 0,
            },
        );
        c.agents.insert(
            claude_key("session"),
            AgentRecord {
                source: Source::Claude,
                tool: "claude".into(),
                pane_id: Some("%1".into()),
                session_name: Some("work".into()),
                process_generation: None,
                sequence: 0,
                state: AgentState::Working,
                changed_at: SystemTime::now() - Duration::from_secs(30),
            },
        );
        c.claude_generation = 1;
        c.apply_claude_result(ClaudeQueryFinished {
            generation: 1,
            completed: Instant::now(),
            result: Ok(vec![ClaudeStatus {
                session_id: "session".into(),
                state: AgentState::Idle,
                pane_id: Some("%1".into()),
                session_name: Some("work".into()),
            }]),
        });
        assert_eq!(c.agents[&claude_key("session")].state, AgentState::Done);

        c.claude_generation = 2;
        c.apply_claude_result(ClaudeQueryFinished {
            generation: 2,
            completed: Instant::now(),
            result: Ok(vec![ClaudeStatus {
                session_id: "session".into(),
                state: AgentState::Idle,
                pane_id: Some("%1".into()),
                session_name: Some("work".into()),
            }]),
        });
        assert_eq!(c.agents[&claude_key("session")].state, AgentState::Done);

        c.apply(Request::Seen {
            pane_id: Some("%1".into()),
            session_id: None,
        })
        .unwrap();
        assert_eq!(c.agents[&claude_key("session")].state, AgentState::Idle);
    }

    #[test]
    fn unchanged_claude_state_preserves_transition_timestamp() {
        let mut c = center();
        let changed_at = SystemTime::now() - Duration::from_secs(30);
        c.claude_targets.insert(
            "%1".into(),
            ClaudeTarget {
                session_name: Some("work".into()),
                observed: true,
                successful_misses: 0,
            },
        );
        c.agents.insert(
            claude_key("session"),
            AgentRecord {
                source: Source::Claude,
                tool: "claude".into(),
                pane_id: Some("%1".into()),
                session_name: Some("work".into()),
                process_generation: None,
                sequence: 0,
                state: AgentState::Idle,
                changed_at,
            },
        );
        c.claude_generation = 1;
        c.apply_claude_result(ClaudeQueryFinished {
            generation: 1,
            completed: Instant::now(),
            result: Ok(vec![ClaudeStatus {
                session_id: "session".into(),
                state: AgentState::Idle,
                pane_id: Some("%1".into()),
                session_name: Some("work".into()),
            }]),
        });
        assert_eq!(c.agents[&claude_key("session")].changed_at, changed_at);
    }
    #[test]
    fn stale_claude_generation_is_ignored() {
        let mut c = center();
        c.claude_generation = 2;
        c.claude_in_flight = true;
        c.apply_claude_result(ClaudeQueryFinished {
            generation: 1,
            completed: Instant::now(),
            result: Ok(vec![]),
        });
        assert!(c.claude_in_flight);
    }
    #[test]
    fn working_and_blocked_expire_but_done_remains() {
        let mut c = center();
        let old = SystemTime::now() - Duration::from_secs(61);
        for (key, state) in [("w", AgentState::Working), ("d", AgentState::Done)] {
            c.agents.insert(
                key.into(),
                AgentRecord {
                    source: Source::Event,
                    tool: "pi".into(),
                    pane_id: None,
                    session_name: None,
                    process_generation: None,
                    sequence: 0,
                    state,
                    changed_at: old,
                },
            );
        }
        c.expire_states();
        assert!(!c.agents.contains_key("w"));
        assert!(c.agents.contains_key("d"));
    }
    #[test]
    fn tmux_quoted_config_values_are_decoded() {
        assert_eq!(decode_tmux_value("\"✦ ✷\""), "✦ ✷");
        assert_eq!(decode_tmux_value("on"), "on");
        assert_eq!(decode_tmux_value("''"), "");
    }
    #[test]
    fn config_rejects_empty_frames_and_short_animation_interval() {
        let mut values = HashMap::new();
        values.insert("@agent_status_anim_frames".into(), "   ".into());
        assert!(Config::from_values(&values).is_err());
        values.insert("@agent_status_anim_frames".into(), "a b".into());
        values.insert("@agent_animation_interval_ms".into(), "249".into());
        assert!(Config::from_values(&values).is_err());
        values.insert("@agent_animation_interval_ms".into(), "1000".into());
        values.insert("@agent_claude_failure_max_interval".into(), "2".into());
        assert!(Config::from_values(&values).is_err());
    }
    #[test]
    fn claude_real_status_values_map_correctly() {
        let agents: Vec<ClaudeAgent> = serde_json::from_str(
            r#"[{"pid":42,"cwd":"/tmp/work","kind":"interactive","startedAt":1234,"sessionId":"session-1","name":"work","status":"busy"}]"#,
        )
        .unwrap();
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].pid, 42);
        assert_eq!(agents[0].session_id, "session-1");
        assert_eq!(parse_claude_state("busy"), Some(AgentState::Working));
        assert_eq!(parse_claude_state("waiting"), Some(AgentState::Blocked));
        assert_eq!(parse_claude_state("idle"), Some(AgentState::Idle));
        assert_eq!(parse_claude_state("done"), None);
    }
}
