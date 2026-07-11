# tmux-agents-session-manager

Run many coding-agent sessions across your projects — [Pi](https://pi.dev),
[Codex](https://openai.com/codex/), [Claude Code](https://www.anthropic.com/claude-code),
or any CLI agent — each inside its own tmux session. Then list them, preview
them, see which ones are working vs. finished, and jump back to any session from
one popup.

This is a tmux plugin for people who launch coding agents per project directory.
It can keep multiple numbered nested sessions per directory/agent and gives you
a central picker for all of them. Out of the box it manages **pi, codex, and claude**; add
or swap agents via `@agent_agents`.

## Features

- 🔢 **Central picker** (`prefix` + `u`) listing every managed agent tmux session, plus panes where a known agent (pi/codex/claude) was started manually. A tool column shows which agent each row is.
- 🤖 **Multi-agent and multi-instance**: manage pi, codex, and claude side by side; each `prefix` + `y` launch creates a numbered instance such as `pi-1`, `pi-2`, and `pi-3` by default.
- 🟡 **Live status** per session: `working` / `done` / `idle` (via the bundled Pi
  extension, or any agent that calls `scripts/state.sh` from a hook).
- 👁️ **Live preview** of each session's screen in the picker.
- 🎯 **Smart jump** back to the window where the session was launched.
- 🚀 **Launcher** (`prefix` + `y`) to open or attach an agent session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) from the picker.
- 📊 **Status-line summary** (opt-in): a compact `agents 1● 2✦ 1✓` badge in
  `status-right` counting self-reported blocked / working / done states without
  scanning process trees on every refresh.

## Prerequisites

- **tmux ≥ 3.3** for borderless `display-popup` (`-B`)
- **fzf** for the picker UI
- **Pi** CLI (`pi` command) for the default Pi agent (other agents can be configured instead)
- bash; macOS or Linux

For best Pi keyboard behavior inside tmux, Pi recommends:

```tmux
set -g extended-keys on
set -g extended-keys-format csi-u
```

`extended-keys-format csi-u` requires tmux 3.5+. On tmux 3.3–3.4, use only
`set -g extended-keys on`.

## Install

### Manual install

```sh
git clone <this-repo-url> ~/clone/path/tmux-agents-session-manager
```

Add to `~/.tmux.conf`, then reload tmux:

```tmux
run-shell ~/clone/path/tmux-agents-session-manager/agents_session_manager.tmux
```

### tpm

After publishing/renaming the repo, use the normal tpm form:

```tmux
set -g @plugin 'yourname/tmux-agents-session-manager'
```

Then press `prefix` + <kbd>I</kbd>.

## Usage

| Key            | Action                                                                   |
| -------------- | ------------------------------------------------------------------------ |
| `prefix` + `y` | Launch a numbered agent instance for the current directory; shows an agent menu when more than one is configured |
| `prefix` + `u` | Open the agent session picker                                            |

Inside the picker:

| Key                       | Action                                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `enter`                   | Jump to the session/pane; managed sessions resume in the popup            |
| `ctrl-x`                  | Kill a managed session, or send `Ctrl-C` to a manual agent pane           |
| `↑` / `↓`, type to filter | fzf navigation                                                            |

Sessions marked `done` sort near the top so finished work is easy to find.
Manual panes are detected when their current tmux command is one of
`@agent_detect_commands` (default `pi codex claude`), so an agent started by typing
its command in a normal tmux pane is also found with `prefix` + `u`. For wrapped
CLIs such as Node-based launchers, only commands in `@agent_detect_wrappers` are
scanned for child agent processes to keep large tmux workspaces responsive.

## Managing pi, codex, and claude

The plugin manages multiple agents at once. The launchable agents are defined by
the `@agent_agents` registry (one `name=command` per line); the default is:

```tmux
set -g @agent_agents "pi=pi -e '/path/to/extensions/tmux-state.ts'
codex=codex
claude=claude"
```

- `prefix` + `y` shows a compact tmux menu for these agents (pi/codex/claude),
  with entries like `pi (1)`, `codex (2)`, `claude (3)`. Use `Ctrl+n` /
  `Ctrl+p` to move, or number keys to select. With a single agent configured,
  or `@agent_launch_menu off`, it launches directly with no menu.
- Sessions are **namespaced and numbered per agent**
  (`agent-<agent>-<hash>-<instance>`), so the same directory can run pi, codex,
  and claude—or multiple copies of any one of them—without colliding.
- The picker shows a **tool column** with instance labels such as `pi-1` and
  `pi-2`. Set `@agent_multiple_instances off` to restore the legacy behavior:
  one reusable session per directory/agent.
- `@agent_detect_commands` controls which manually-started panes are auto-listed.
- `@agent_detect_wrappers` controls which wrapper commands (default `node bun npx npm pnpm yarn`) are allowed to trigger a child-process scan.

Make sure each agent's command is on your `PATH` (`pi`, `codex`, `claude`).
Only **pi** reports live `working` / `done` status out of the box via its
bundled extension; see [Status for other agents](#status-for-other-agents).

## Status extension

By default, the launcher runs Pi with the bundled extension:

```sh
pi -e /path/to/tmux-agents-session-manager/extensions/tmux-state.ts
```

The extension writes these tmux options on the nested Pi session:

| Pi event           | tmux state | Meaning              |
| ------------------ | ---------- | -------------------- |
| `session_start`    | `idle`     | Pi is open           |
| `agent_start`      | `working`  | Pi is processing     |
| `agent_end`        | `done`\*   | The turn finished and has not been opened yet |
| `session_shutdown` | `idle`     | Pi is shutting down  |

\* If the pane is already visible when the turn ends (its session is attached,
its window is active, and it is the active pane), `agent_end` reports `idle`
directly instead of `done` — you were already watching it finish, so there is
nothing left to "discover" later and the right status bar does not get stuck
showing `done` for the current session/pane. tmux can only detect client
attachment, not terminal focus, so a pane in an attached-but-unfocused terminal
may also be treated as seen.

Opening a `done` session from the picker or launcher marks it `idle` again.

If you override `@agent_default_command` and do not load the extension, the picker still
lists, previews, jumps, and kills sessions; status may stay `idle` or show
`unknown`.

### Status for other agents

Codex, Claude Code, and any other agent are managed (listed, previewed, jumped,
killed) without any extra setup — but they show `unknown` status until they
report state. The state layer is agent-agnostic: anything that runs
`scripts/state.sh <state>` updates the same `@agent_state` the picker and status
line read.

```sh
# From inside the agent's tmux pane:
/path/to/tmux-agents-session-manager/scripts/state.sh working
/path/to/tmux-agents-session-manager/scripts/state.sh done
```

Wire these into whatever hooks your agent provides (e.g. a pre/post-prompt hook,
or a wrapper script) to get the same `working` / `done` badges that pi gets from
its bundled extension.

Codex reports full state through its `[hooks]` config. Add to `~/.codex/config.toml`:

```toml
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "/path/to/tmux-agents-session-manager/scripts/state.sh idle"
timeout = 1

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/path/to/tmux-agents-session-manager/scripts/state.sh working"
timeout = 1

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "/path/to/tmux-agents-session-manager/scripts/state.sh done"
timeout = 1
```

This gives Codex the animated `working` badge on turn start (the old `notify`
hook could only report `done`).

`state.sh` applies the same "skip `done` when the pane is being watched"
shortcut as the bundled Pi extension: when the `Stop` hook fires while the pane
is visible (its session is attached and this is the active pane in the active
window), the recorded state is downgraded from `done` to `idle` so the status
bar does not get stuck showing `done` for the current session/pane.

## Status line summary

Show a compact badge of self-reported agent states in your tmux status bar, so
you know when work finished or got blocked without opening the picker. The status
script does not discover agents by inspecting commands or walking process trees;
manual-pane discovery is reserved for the picker (`prefix` + `u`).

Enable auto-injection into `status-right`:

```tmux
set -g @agent_status on
```

Output looks like:

```
agents 1● 2✦ 1✓
```

**Event-driven, not polled.** The badge is served from a cached tmux option
(`@agent_status_cache`) that agents update only when their state changes, so an
idle or finished workspace costs **zero** background CPU — tmux just expands the
cached string. The one exception is the spinner: while any agent is `working`,
tmux runs the summary once per interval to advance the animation frame, then
stops forking entirely as soon as work drops to zero. (tmux lazily evaluates
only the selected branch of its `#{?...}` format, so the polling branch is never
run while idle.)

Agents refresh the cache by calling `scripts/status.sh --refresh` when they
report a state — the bundled Pi extension and `scripts/state.sh` both do this
automatically, so custom hook-based integrations get it for free.

| Segment | State     | Meaning                |
| ------- | --------- | ---------------------- |
| `●`     | `blocked` | needs input (shown first) |
| `✦`     | `working` | actively running       |
| `✓`     | `done`    | finished, unseen       |
| `·`     | `idle`    | hidden unless enabled  |

Only non-zero groups appear, and nothing is printed when there are no reported
agent states. Prefer to place it yourself? Skip `@agent_status` and embed the
script directly. Note that a raw embed polls once per `status-interval` (it does
not use the cached, event-driven path):

```tmux
set -g status-right '#(~/clone/path/tmux-agents-session-manager/scripts/status.sh) %H:%M'
```

### Fallback slot (`--or` / `--or-host`)

When there are no reported agent states the script prints nothing. To reuse the
same status-right slot for something else when idle, pass a fallback:

```tmux
# Show the agents badge while active, otherwise the short hostname.
set -g status-right '#(~/clone/path/tmux-agents-session-manager/scripts/status.sh --or-host)'

# Or any literal fallback text.
set -g status-right '#(~/clone/path/tmux-agents-session-manager/scripts/status.sh --or "no agents")'
```

Use `--or-host` rather than `#h`: inside `#(...)`, tmux does not expand `#h`, so
it would be passed through literally.

### Animated working icon

Give the `working` count a subtle spinner so active turns stand out:

```tmux
set -g @agent_status_animate_working 'on'
set -g @agent_status_anim_frames     '✦ ✷  ✹  ✴'   # space-separated frames
```

Frames advance roughly once per second (driven by `status-interval`), so keep
`@agent_status_interval` low for a smooth animation.

## Options

Set any of these before the plugin loads:

```tmux
set -g @agent_launch_key     'y'        # prefix key: launch/open for current dir
set -g @agent_list_key       'u'        # prefix key: open the picker
set -g @agent_default_command 'pi'       # pi's command; default loads bundled extension
set -g @agent_agents         '...'      # name=command registry of launchable agents (see below)
set -g @agent_launch_menu    'on'       # 'off' skips the agent menu on prefix+y
set -g @agent_multiple_instances 'on'   # 'off' reuses one session per directory/agent
set -g @agent_detect_commands 'pi codex claude'  # manual-pane commands to auto-list
set -g @agent_detect_wrappers 'node bun npx npm pnpm yarn' # wrappers to scan for child agents
set -g @agent_session_prefix 'agent-'   # tmux session name prefix
set -g @agent_popup_width    '90%'      # popup width
set -g @agent_popup_height   '90%'      # popup height
```

Status-line options (only relevant with `@agent_status on` or manual embedding):

```tmux
set -g @agent_status            'off'   # 'on' auto-appends the summary to status-right
set -g @agent_status_interval   '1'     # max seconds between refreshes
set -g @agent_status_show_idle  'off'   # also count idle sessions
set -g @agent_status_color      'off'   # emit #[fg=...] colours
set -g @agent_status_sigil      'agents'    # leading marker
set -g @agent_status_icon_blocked '●'   # per-state icons
set -g @agent_status_icon_working '✦'
set -g @agent_status_icon_done    '✓'
set -g @agent_status_icon_idle    '·'
set -g @agent_status_color_blocked 'red'    # per-state colours (tmux colour names)
set -g @agent_status_color_working 'yellow'
set -g @agent_status_color_done    'cyan'
set -g @agent_status_color_idle    'green'
set -g @agent_status_animate_working 'on'   # 'on' animates the working icon
set -g @agent_status_anim_frames     '✦ ✷  ✹  ✴'  # spinner frames (space-separated)
set -g @agent_state_ttl              '21600'      # seconds before stale states are ignored; 0 disables
```

The stale-state TTL prevents crashed/killed agents from leaving a permanent
`working`/`blocked` badge when they cannot report shutdown cleanly.

The status script also exposes a path-free reference via the
`@agent_status_script` tmux option (set by the plugin on load), so your config
never has to hardcode the install directory:

```tmux
set -g status-right '#(#{@agent_status_script} --or-host)'
```

For a styled Powerline-style right segment, keep your existing separators and
put the script in the slot that would otherwise show the host:

```tmux
set -g status-right "#[fg=#586e75,bg=#292a30,nobold,nounderscore,noitalics]#[fg=#93a1a1,bg=#586e75]#[fg=#657b83,bg=#586e75,nobold,nounderscore,noitalics]#[fg=#93a1a1,bg=#657b83]#[fg=#93a1a1,bg=#657b83,nobold,nounderscore,noitalics]#[fg=#15161E,bg=#93a1a1,bold] #{?@agent_status_script,#(#{@agent_status_script} --or-host),#h} "
```

That Powerline example uses `#(... --or-host)`, which **forks the script once
per `status-interval`** even when nothing is happening. For a zero-fork,
event-driven segment, replace the badge slot with the same cached/animated
expression the plugin injects by default:

```tmux
set -g status-right "#[fg=#586e75,bg=#292a30,nobold,nounderscore,noitalics]#[fg=#93a1a1,bg=#586e75]#[fg=#657b83,bg=#586e75,nobold,nounderscore,noitalics]#[fg=#93a1a1,bg=#657b83]#[fg=#93a1a1,bg=#657b83,nobold,nounderscore,noitalics]#[fg=#15161E,bg=#93a1a1,bold] #{?@agent_status_working,#(#{@agent_status_script} --animate),#{?@agent_status_cache,#{@agent_status_cache},#h}} "
```

How this segment behaves:

- **Working:** `@agent_status_working` is set, so tmux forks
  `status.sh --animate` once per `status-interval` to advance the spinner.
- **Idle / done:** tmux expands the cached `@agent_status_cache` string with
  **zero forks** (agents refresh it via `status.sh --refresh` only on state
  changes).
- **No agents:** the cache is empty, so the nested `#{?@agent_status_cache,...}`
  falls back to `#h` (the short hostname). Use `#h` here rather than
  `--or-host`, because tmux *does* expand `#h` in a plain format string (the
  `--or-host` flag only exists for the `#(...)` case, where `#h` is passed
  through literally).

> **Note the `@` prefixes.** The option names are `@agent_status_working`,
> `@agent_status_cache`, and `@agent_status_script`. Dropping the `@` silently
> breaks the condition (it can never be true) **and** defeats the auto-inject
> guard below, producing a duplicate badge.

### Manual placement auto-detects and skips auto-injection

You do **not** have to set `@agent_status off` when you place the badge
yourself. On load, the plugin only prepends its summary to `status-right` when
that string does **not** already reference the status feature. It checks for
either marker:

```sh
case "$current_right" in
*"@agent_status_working"*|*".../scripts/status.sh"*) : ;;   # already present → skip
*) tmux set-option -g status-right "$summary $current_right" ;;
esac
```

So as long as your manual `status-right` contains `@agent_status_working` (or a
literal path to `scripts/status.sh`), the plugin detects it and does **not**
append a second badge — even with `@agent_status on` (the default). It still
sets `@agent_status_script`, primes the cache once, and may tighten
`status-interval` down to `@agent_status_interval` so the spinner animates
smoothly. If you prefer the plugin to touch nothing but the script path and
cache, set `@agent_status off` explicitly before it loads.

The actual default for `@agent_default_command` is equivalent to:

```tmux
set -g @agent_default_command "pi -e '/path/to/tmux-agents-session-manager/extensions/tmux-state.ts'"
```

## How it works

- The **launcher** picks an agent from `@agent_agents` (or launches the default),
  creates a detached `agent-<agent>-<hash-of-dir>-<instance>` tmux session running
  that agent, records the origin window, agent, and instance, then attaches to it
  in a popup. With `@agent_multiple_instances off`, it instead opens or reuses the
  unnumbered session.
- The bundled **Pi extension** updates `@agent_state` / `@agent_state_at` as Pi starts
  and finishes turns; other agents can do the same via `scripts/state.sh`.
- The **picker** lists tmux sessions matching the prefix and non-prefixed panes
  whose current command is in `@agent_detect_commands` (or a configured wrapper
  whose child process matches), reads state for managed sessions, shows a live
  `capture-pane` preview and a per-row tool column, and jumps to the selected
  session or pane. This is where process discovery happens.
- The **status-line script** only reads self-reported `@agent_state` values from
  managed sessions and panes; it does not scan commands or process trees, so it
  is safe to run frequently from `status-right`.
- Pressing `prefix` + `u` from inside an agent popup first detaches that popup,
  then reopens the picker on the outer tmux client.

## Naming

Configuration uses the `@agent_*` option namespace (for example
`@agent_state`). Old Pi-prefixed option names are not read or written.

## Acknowledgements

This project was originally forked from
[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager.git).
Many thanks to [Takuya Matsuyama (craftzdog)](https://github.com/craftzdog) for creating and open-sourcing the original project.

## Development

Run the lightweight unit test suite with:

```sh
bash tests/run.sh
```

Run smoke performance checks for the hot paths (`status.sh` and
`picker.sh --list`) with:

```sh
bash tests/perf_smoke.sh
```

The performance smoke test simulates 10/50/100 managed sessions plus manual
agent panes using a local fake `tmux` binary. Tune or disable thresholds with:

```sh
PERF_ITERATIONS=10 PERF_MAX_STATUS_MS=2000 PERF_MAX_PICKER_MS=5000 bash tests/perf_smoke.sh
PERF_MAX_STATUS_MS=0 PERF_MAX_PICKER_MS=0 bash tests/perf_smoke.sh
```

The tests use a local fake `tmux` binary, so they do not require a running tmux
server or external test framework. CI also runs `shellcheck` over the plugin
scripts and entrypoints.


