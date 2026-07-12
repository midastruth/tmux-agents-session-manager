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
- 📊 **Status-line summary**: a compact `agents 1● 2✦ 1✓` badge in
  `status-right` counting self-reported blocked / working / done states without
  scanning process trees on every refresh.

## Prerequisites

- **tmux ≥ 3.3** for borderless `display-popup` (`-B`)
- **fzf** for the picker UI
- **Pi** CLI (`pi` command) for the default Pi agent (other agents can be configured instead)
- bash and a Rust toolchain; macOS or Linux

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

Build the bundled daemon once:

```sh
cd ~/clone/path/tmux-agents-session-manager
cargo build --release --manifest-path daemon/Cargo.toml
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

Then press `prefix` + <kbd>I</kbd> and build the daemon from the installed
plugin directory:

```sh
cd ~/.tmux/plugins/tmux-agents-session-manager
cargo build --release --manifest-path daemon/Cargo.toml
```

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
Pi reports through the bundled extension, Codex reports when its hooks are
configured, and Claude uses daemon polling as described below.

## Unified status daemon

A single-thread-owned Rust daemon is the authoritative runtime state center for
each tmux server. It uses a private mode-0600 Unix socket, restores Pi/Codex
mirror options once at startup, and then updates state only from events. The
Pi extension and `scripts/state.sh` continue writing tmux mirror options so the
daemon can recover after restart and the picker can display reliable state if a
daemon snapshot is temporarily unavailable.

| Agent event | State |
| --- | --- |
| session start / shutdown | `idle` |
| turn start | `working` |
| turn end while not watched | `done` |
| turn end while watched | `idle` |

Opening a `done` pane sends `Seen`; `done` remains until then. `working` and
`blocked` expire after `@agent_state_ttl`. Managed-session exits are sent by
picker actions and an appended `session-closed` tmux hook when available.
`after-kill-pane` is intentionally not used because tmux does not expose the
removed pane identity there. Existing hooks are never overwritten.

### Pi and Codex reporting

The default Pi command loads `extensions/tmux-state.ts`. Each extension process
creates a fresh process generation and sends monotonic sequences, preventing an
old event or reused pane id from overwriting a newer process.

Codex can report through hooks:

```sh
/path/to/plugin/scripts/state.sh working
/path/to/plugin/scripts/state.sh done
```

For Codex, configure these command hooks (replace the plugin path):

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

`state.sh` keeps one generation for the long-lived hook parent and monotonic
pane sequence, while preserving the watched-pane `done` to `idle` behavior.

### Claude adaptive polling

A plugin-launched Claude sends `ClaudeStarted`; a manual Claude found by the
picker sends `ClaudeDiscovered`. Therefore a manually started Claude that has
never been shown in the picker is **not guaranteed to enter the status line**.
Claude uses stable `sessionId` identity, never PID identity.

Only one Claude query can be in flight. The default intervals are 3 seconds
while working and 10 seconds while idle/waiting. A newly launched target gets
three successful-query attempts to register; after it has been observed, a
successful query that no longer returns it removes the target and stops polling
when no Claude targets remain. Deadlines start at query completion. Timeout, non-zero exit, and JSON
errors preserve the last successful states and apply bounded backoff. Timeout
kills and reaps the child process group.

The collector runs the user-verified command `claude agents --json`. Its real
records contain `pid`, `cwd`, `kind`, `startedAt`, `sessionId`, `name`, and
`status`. Only `kind=interactive` is used. `busy` maps to `working`, `waiting`
maps to `blocked`, and `idle` maps to `idle`. The collector resolves
each PID to its TTY and then matches that TTY to a tmux pane/session. PID is
used only for this live association; `sessionId` remains the long-lived
identity. Each poll starts one `claude agents --json`, one full-table `ps`
snapshot, and one `tmux list-panes` query regardless of the number of returned
agents; it never starts one `ps` per agent.

### Zero-fork animated status line

The status line expands only `#{@agent_status_cache}` and forks no process.
While `working > 0`, the daemon advances and publishes animation frames (default
one second). At `working = 0` it stops animation and resets the frame index.
The daemon publishes only when the final rendered summary changes. A publish
uses one tmux option update plus explicit refreshes for cached client names; the
status format itself remains zero-fork. Cache publication and redraw are
separate: a successful option update remains valid if an explicit client
refresh fails.

Animation frames are whitespace-separated; a frame itself cannot contain a
space. The daemon validates non-empty bounded frames, a minimum 250ms animation
interval, positive Claude intervals/timeouts, and non-negative TTL. Invalid
reload retains the old config; successful reload immediately reconciles state.

## Options

Launcher and picker options:

```tmux
set -g @agent_launch_key     'y'
set -g @agent_list_key       'u'
set -g @agent_default_command 'pi'
set -g @agent_agents         '...'
set -g @agent_launch_menu    'on'
set -g @agent_multiple_instances 'on'
set -g @agent_detect_commands 'pi codex claude'
set -g @agent_detect_wrappers 'node bun npx npm pnpm yarn'
set -g @agent_session_prefix 'agent-'
set -g @agent_popup_width    '90%'
set -g @agent_popup_height   '90%'
```

Daemon/status options:

```tmux
set -g @agent_status                 'on'
set -g @agent_status_animate_working 'on'
set -g @agent_status_show_idle       'off'
set -g @agent_status_sigil           'agents'
set -g @agent_status_icon_blocked    '●'
set -g @agent_status_icon_working    '✦'
set -g @agent_status_icon_done       '✓'
set -g @agent_status_icon_idle       '·'
set -g @agent_status_anim_frames     '✦ ✷ ✹ ✴'
set -g @agent_animation_interval_ms  '1000'
set -g @agent_state_ttl              '259200'
set -g @agent_claude_working_interval '3'
set -g @agent_claude_idle_interval    '10'
set -g @agent_claude_timeout          '2'
set -g @agent_claude_failure_max_interval '30'
set -g @agent_daemon_binary '/path/to/daemon/target/release/tmux-agents-state-daemon'
```

The plugin sets `@agent_daemon_binary` to its release build by default. It does
not install a toolchain or build code during tmux startup. Plugin reload sends
`ReloadConfig`; explicit inspection/reload is also available:

```sh
scripts/daemon.sh snapshot
scripts/daemon.sh reload
```

## How it works

- The **launcher** picks an agent from `@agent_agents` (or launches the default),
  creates a detached `agent-<agent>-<hash-of-dir>-<instance>` tmux session running
  that agent, records the origin window, agent, and instance, then attaches to it
  in a popup. With `@agent_multiple_instances off`, it instead opens or reuses the
  unnumbered session.
- The bundled **Pi extension** and `scripts/state.sh` mirror recovery options and send sequenced events to the per-server daemon.
- The **picker** lists tmux sessions matching the prefix and non-prefixed panes
  whose current command is in `@agent_detect_commands` (or a configured wrapper
  whose child process matches), reads state for managed sessions, shows a live
  `capture-pane` preview and a per-row tool column, and jumps to the selected
  session or pane. This is where process discovery happens.
- The **daemon** owns live state, Claude polling, TTL and animation, and publishes a cache-only zero-fork status segment.
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

Build and test the Rust daemon, then run the Bash integration suite:

```sh
cargo test --manifest-path daemon/Cargo.toml
bash tests/run.sh
```

Run the picker discovery smoke performance check with:

```sh
bash tests/perf_smoke.sh
```

The performance smoke test simulates 10/50/100 managed sessions plus manual
agent panes using a local fake `tmux` binary. Daemon state-loop behavior is
covered by Rust tests and the status line itself forks zero processes. Tune or
disable thresholds with:

```sh
PERF_ITERATIONS=10 PERF_MAX_PICKER_MS=5000 bash tests/perf_smoke.sh
PERF_MAX_PICKER_MS=0 bash tests/perf_smoke.sh
```

The tests use a local fake `tmux` binary, so they do not require a running tmux
server or external test framework. CI also runs `shellcheck` over the plugin
scripts and entrypoints.


