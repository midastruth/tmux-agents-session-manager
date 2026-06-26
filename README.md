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
