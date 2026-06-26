# tmux-pi-session-manager

Run many [Pi](https://pi.dev) coding-agent sessions across your projects, each
inside its own tmux session — then list them, preview them, see which ones are
working vs. finished, and jump back to any session from one popup.

This is a tmux plugin for people who launch `pi` per project directory. It keeps
one nested tmux session per directory and gives you a central picker for all of
them.

## Features

- 🔢 **Central picker** (`prefix` + `u`) listing every managed Pi tmux session, plus panes where `pi` was started manually.
- 🟡 **Live status** per session: `working` / `done` / `idle` via the bundled Pi
  extension.
- 👁️ **Live preview** of each session's screen in the picker.
- 🎯 **Smart jump** back to the window where the Pi session was launched.
- 🚀 **Launcher** (`prefix` + `y`) to open or attach the Pi session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) from the picker.
- 📊 **Status-line summary** (opt-in): a compact `π 1● 2▶ 1✓` badge in
  `status-right` counting blocked / working / done sessions at a glance.

## Prerequisites

- **tmux ≥ 3.2** for `display-popup`
- **fzf** for the picker UI
- **Pi** CLI (`pi` command)
- bash; macOS or Linux

For best Pi keyboard behavior inside tmux, Pi recommends:

```tmux
set -g extended-keys on
set -g extended-keys-format csi-u
```

`extended-keys-format csi-u` requires tmux 3.5+. On tmux 3.2–3.4, use only
`set -g extended-keys on`.

## Install

### Manual install

```sh
git clone <this-repo-url> ~/clone/path/tmux-pi-session-manager
```

Add to `~/.tmux.conf`, then reload tmux:

```tmux
run-shell ~/clone/path/tmux-pi-session-manager/pi_session_manager.tmux
```

### tpm

After publishing/renaming the repo, use the normal tpm form:

```tmux
set -g @plugin 'yourname/tmux-pi-session-manager'
```

Then press `prefix` + <kbd>I</kbd>.

## Usage

| Key            | Action                                                                   |
| -------------- | ------------------------------------------------------------------------ |
| `prefix` + `y` | Launch or re-attach to a Pi session for the current directory in a popup |
| `prefix` + `u` | Open the Pi session picker                                               |

Inside the picker:

| Key                       | Action                                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `enter`                   | Jump to the session/pane; managed sessions resume in the popup            |
| `ctrl-x`                  | Kill a managed session, or send `Ctrl-C` to a manual `pi` pane            |
| `↑` / `↓`, type to filter | fzf navigation                                                            |

Sessions marked `done` sort near the top so finished work is easy to find.
Manual panes are detected when their current tmux command is `pi`, so a `pi`
started by typing `pi` in a normal tmux pane can also be found with
`prefix` + `u`.

## Status extension

By default, the launcher runs Pi with the bundled extension:

```sh
pi -e /path/to/tmux-pi-session-manager/extensions/tmux-state.ts
```

The extension writes these tmux options on the nested Pi session:

| Pi event           | tmux state | Meaning              |
| ------------------ | ---------- | -------------------- |
| `session_start`    | `idle`     | Pi is open           |
| `agent_start`      | `working`  | Pi is processing     |
| `agent_end`        | `done`     | The turn finished and has not been opened yet |
| `session_shutdown` | `idle`     | Pi is shutting down  |

Opening a `done` session from the picker or launcher marks it `idle` again.

If you override `@pi_command` and do not load the extension, the picker still
lists, previews, jumps, and kills sessions; status may stay `idle` or show
`unknown`.

## Status line summary

Show a compact badge of Pi session states in your tmux status bar, so you know
when work finished or got blocked without opening the picker.

Enable auto-injection into `status-right`:

```tmux
set -g @pi_status on
```

This appends `#(.../scripts/status.sh)` to `status-right` and tightens
`status-interval` so it refreshes promptly. Output looks like:

```
π 1● 2▶ 1✓
```

| Segment | State     | Meaning                |
| ------- | --------- | ---------------------- |
| `●`     | `blocked` | needs input (shown first) |
| `▶`     | `working` | actively running       |
| `✓`     | `done`    | finished, unseen       |
| `·`     | `idle`    | hidden unless enabled  |

Only non-zero groups appear, and nothing is printed when there are no Pi
sessions. Prefer to place it yourself? Skip `@pi_status` and embed the script
directly:

```tmux
set -g status-right '#(~/clone/path/tmux-pi-session-manager/scripts/status.sh) %H:%M'
```

### Fallback slot (`--or` / `--or-host`)

When there are no Pi sessions the script prints nothing. To reuse the same
status-right slot for something else when idle, pass a fallback:

```tmux
# Show the Pi badge while active, otherwise the short hostname.
set -g status-right '#(~/clone/path/tmux-pi-session-manager/scripts/status.sh --or-host)'

# Or any literal fallback text.
set -g status-right '#(~/clone/path/tmux-pi-session-manager/scripts/status.sh --or "no agents")'
```

Use `--or-host` rather than `#h`: inside `#(...)`, tmux does not expand `#h`, so
it would be passed through literally.

### Animated working icon

Give the `working` count a subtle spinner so active turns stand out:

```tmux
set -g @pi_status_animate_working 'on'
set -g @pi_status_anim_frames     '✦ ✶ ✷ ✶'   # space-separated frames
```

Frames advance roughly once per second (driven by `status-interval`), so keep
`@pi_status_interval` low for a smooth animation.

## Options

Set any of these before the plugin loads:

```tmux
set -g @pi_launch_key     'y'        # prefix key: launch/open for current dir
set -g @pi_list_key       'u'        # prefix key: open the picker
set -g @pi_command        'pi'       # command run in new sessions; default loads bundled extension
set -g @pi_session_prefix 'pi-'      # tmux session name prefix
set -g @pi_popup_width    '90%'      # popup width
set -g @pi_popup_height   '90%'      # popup height
```

Status-line options (only relevant with `@pi_status on` or manual embedding):

```tmux
set -g @pi_status            'off'   # 'on' auto-appends the summary to status-right
set -g @pi_status_interval   '5'     # max seconds between refreshes
set -g @pi_status_show_idle  'off'   # also count idle sessions
set -g @pi_status_color      'on'    # emit #[fg=...] colours
set -g @pi_status_sigil      'π'     # leading marker
set -g @pi_status_icon_blocked '●'   # per-state icons
set -g @pi_status_icon_working '▶'
set -g @pi_status_icon_done    '✓'
set -g @pi_status_icon_idle    '·'
set -g @pi_status_color_blocked 'red'    # per-state colours (tmux colour names)
set -g @pi_status_color_working 'yellow'
set -g @pi_status_color_done    'cyan'
set -g @pi_status_color_idle    'green'
set -g @pi_status_animate_working 'off'  # 'on' animates the working icon
set -g @pi_status_anim_frames     '✦ ✶ ✷ ✶'  # spinner frames (space-separated)
```

The status script also exposes a path-free reference via the
`@pi_status_script` tmux option (set by the plugin on load), so your config
never has to hardcode the install directory:

```tmux
set -g status-right '#(#{@pi_status_script} --or-host)'
```

The actual default for `@pi_command` is equivalent to:

```tmux
set -g @pi_command "pi -e '/path/to/tmux-pi-session-manager/extensions/tmux-state.ts'"
```

## How it works

- The **launcher** creates a detached `pi-<hash-of-dir>` tmux session running
  `pi`, records the origin window in `@pi_origin`, and attaches to it in a popup.
- The bundled **Pi extension** updates `@pi_state` / `@pi_state_at` as Pi starts
  and finishes turns.
- The **picker** lists tmux sessions matching the prefix and non-prefixed panes
  whose current command is `pi`, reads state for managed sessions, shows a live
  `capture-pane` preview, and jumps to the selected session or pane.
- Pressing `prefix` + `u` from inside a Pi popup first detaches that popup, then
  reopens the picker on the outer tmux client.

## Compatibility

The old `claude_session_manager.tmux` file remains as a compatibility wrapper,
but new configs should use `pi_session_manager.tmux` and the `@pi_*` options.

## License

[MIT](LICENSE)
