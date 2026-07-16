#!/usr/bin/env bash
# Route a status-line mouse click to the picker or the launcher, based on which
# user-defined status range was clicked. Bound to MouseDown1Status by the plugin
# entrypoint; unrelated status clicks (window names, etc.) never reach this
# script because the binding only dispatches for our own ranges.
# Args: <range> <client-name> <pane-current-path> <window-id>
#   All four are expanded by tmux from the mouse event in the binding.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

range="${1:-}"
client="${2:-}"
path="${3:-}"
window="${4:-}"

case "$range" in
agent_list)
  # Same entry point as the prefix+u binding: open the picker on the clicking
  # client so it appears on the terminal the user clicked in.
  exec "$DIR/list.sh" "$client"
  ;;
agent_launch)
  # Same entry point as the prefix+y binding: launch/attach an agent for the
  # active pane's directory, remembering the window that started it.
  exec "$DIR/launch_menu.sh" "$path" "$window"
  ;;
agent_detach)
  # Click-to-close the agent popup: detach only the client that was clicked, so
  # other terminals attached to the same managed session keep running. The
  # detach badge is only drawn inside managed sessions, so this always targets a
  # popup-hosted client; the agent session itself stays alive in the background.
  [ -n "$client" ] || exit 0
  exec tmux detach-client -t "$client"
  ;;
*)
  exit 0
  ;;
esac
