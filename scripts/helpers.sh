#!/usr/bin/env bash
# Shared helpers for tmux-agents-session-manager.

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

agent_session_prefix() {
  if [ -n "${AGENT_SESSION_PREFIX:-}" ]; then
    printf '%s' "$AGENT_SESSION_PREFIX"
  else
    get_tmux_option @agent_session_prefix 'agent-'
  fi
}

is_managed_session() {
  local session="$1" prefix
  prefix="$(agent_session_prefix)"
  [[ "$session" == "$prefix"* ]]
}

# mark_managed_session_seen_if_done <session>
# Opening a managed session that has reported session-scoped "done" marks that
# finished turn as seen. Pi/state.sh write both session-scoped and pane-scoped
# @agent_state; tmux formats such as #{@agent_state} may prefer a pane option, so
# also clear pane-scoped "done" values. A pane-scoped stale "done" must not reset
# an authoritative session-level "working"/"blocked" state.
mark_managed_session_seen_if_done() {
  local session="$1" session_state pane pane_state now
  local -a args

  session_state="$(tmux show-options -qv -t "$session" @agent_state 2>/dev/null || true)"
  now="$(date +%s)"
  args=()

  if [ "$session_state" = done ]; then
    args+=(
      set-option -t "$session" @agent_state idle
      \; set-option -t "$session" @agent_state_at "$now"
    )
  fi

  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    pane_state="$(tmux show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
    [ "$pane_state" = done ] || continue
    if [ "${#args[@]}" -gt 0 ]; then
      args+=(\;)
    fi
    args+=(
      set-option -pu -t "$pane" @agent_state
      \; set-option -pu -t "$pane" @agent_state_at
    )
  done < <(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)

  [ "${#args[@]}" -gt 0 ] || return 0
  tmux "${args[@]}" 2>/dev/null || true
}

# mark_pane_seen_if_done <pane>
mark_pane_seen_if_done() {
  local pane="$1" state now
  state="$(tmux show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
  [ "$state" = done ] || return 0
  now="$(date +%s)"
  tmux set-option -p -t "$pane" @agent_state idle \
    \; set-option -p -t "$pane" @agent_state_at "$now" 2>/dev/null || true
}

# detect_commands
# Space-separated list of agent commands the picker/status line auto-detect when
# they are running directly in a tmux pane (manual, non-managed sessions).
# Override with: set -g @agent_detect_commands 'pi codex claude aider'
detect_commands() {
  if [ -n "${AGENT_DETECT_COMMANDS:-}" ]; then
    printf '%s' "$AGENT_DETECT_COMMANDS"
  else
    get_tmux_option @agent_detect_commands 'pi codex claude'
  fi
}

# wrapper_commands
# Space-separated list of command basenames whose descendants may contain a
# real agent process. Keeping this narrow avoids scanning every ordinary shell,
# editor, or build pane on each picker/status refresh. Override with:
#   set -g @agent_detect_wrappers 'node bun npx npm pnpm yarn my-wrapper'
wrapper_commands() {
  if [ -n "${AGENT_DETECT_WRAPPERS:-}" ]; then
    printf '%s' "$AGENT_DETECT_WRAPPERS"
  else
    get_tmux_option @agent_detect_wrappers 'node bun npx npm pnpm yarn'
  fi
}

# contains_word <word> <space-separated-list>
contains_word() {
  case " $2 " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# is_detected_command <command-basename>
# Succeeds when <command-basename> is in the detect_commands list.
is_detected_command() {
  contains_word "$1" "$(detect_commands)"
}

# is_wrapper_command <command-basename>
# Succeeds when <command-basename> is allowed to trigger process-subtree scans.
is_wrapper_command() {
  contains_word "$1" "$(wrapper_commands)"
}

# process_table_snapshot
# Portable full process table snapshot: "pid ppid comm". Picker callers can set
# AGENT_PS_TABLE once per invocation so wrapper detection does not spawn and
# rescan ps once per pane.
process_table_snapshot() {
  command -v ps >/dev/null 2>&1 || return 1
  ps -axo pid=,ppid=,comm= 2>/dev/null ||
    ps -eo pid=,ppid=,comm= 2>/dev/null
}

# resolve_pane_agent <pane-current-command> <pane-pid>
# Prints the detected agent name for a pane, or nothing if none matches.
#
# Some agents (e.g. codex) ship as a Node wrapper that spawns a native binary,
# so tmux's pane_current_command reports the wrapper ("node") rather than the
# agent. When the foreground command itself is not a known agent, walk the
# descendants of <pane-pid> and return the first child whose comm matches the
# detect list. This makes codex discoverable while keeping bare commands fast.
resolve_pane_agent() {
  local cmd="$1" pid="$2" table out
  if is_detected_command "$cmd"; then
    printf '%s' "$cmd"
    return 0
  fi
  [ -n "$pid" ] || return 1
  # Only known wrappers get a process-subtree scan. Walking every non-agent pane
  # is expensive in large tmux workspaces and status.sh runs repeatedly.
  is_wrapper_command "$cmd" || return 1

  table="${AGENT_PS_TABLE:-}"
  if [ -z "$table" ] && [ "${AGENT_PS_TABLE_READY:-}" != 1 ]; then
    table="$(process_table_snapshot 2>/dev/null)" || return 1
  fi
  [ -n "$table" ] || return 1

  # Build parent->children and pid->comm indexes in awk, then do one BFS. This
  # avoids the old O(subtree * process-table) bash loop and lets picker.sh reuse
  # one ps snapshot for every wrapper pane.
  out="$({
    printf '%s\n' "$table"
  } | awk -v root="$pid" -v detects="$(detect_commands)" '
    BEGIN {
      n = split(detects, d, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (d[i] != "") wanted[d[i]] = 1
    }
    NF >= 3 {
      pid = $1; ppid = $2; comm = $3
      sub(/^.*\//, "", comm)
      cmd[pid] = comm
      children[ppid] = children[ppid] " " pid
    }
    END {
      if (cmd[root] in wanted) { print cmd[root]; exit 0 }
      head = tail = 1; q[1] = root; seen[root] = 1
      while (head <= tail) {
        cur = q[head++]
        k = split(children[cur], kids, " ")
        for (i = 1; i <= k; i++) {
          child = kids[i]
          if (child == "" || seen[child] || child == cur) continue
          seen[child] = 1
          if (cmd[child] in wanted) { print cmd[child]; exit 0 }
          q[++tail] = child
        }
      }
      exit 1
    }
  ')" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# agents_config
# Newline-separated "name=command" registry of launchable agents. The default
# wires pi to the bundled status extension; codex and claude run bare. Override
# the whole list with @agent_agents, or just pi's command with
# @agent_default_command.
#   set -g @agent_agents 'pi=pi -e /path/ext.ts\ncodex=codex\nclaude=claude --foo'
# <pi-default-command> is used for the pi entry's command when neither the
# registry nor @agent_default_command is set, so callers pass the
# extension-aware default in.
agents_config() {
  local pi_default="$1"
  local configured default_command
  configured="$(get_tmux_option @agent_agents '')"
  if [ -n "$configured" ]; then
    printf '%b' "$configured"
    return
  fi
  default_command="$(get_tmux_option @agent_default_command "$pi_default")"
  printf '%s\n' "pi=$default_command" "codex=codex" "claude=claude"
}

# agent_command <name> <pi-default-command>
# Prints the command line registered for <name>, or nothing if unknown.
agent_command() {
  local name="$1" pi_default="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
    "$name="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <<EOF
$(agents_config "$pi_default")
EOF
  return 1
}

# agent_names <pi-default-command>
# Prints the registered agent names, one per line.
agent_names() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "${line%%=*}"
  done <<EOF
$(agents_config "$1")
EOF
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  printf '%s' "${out%% *}" | cut -c1-8
}
