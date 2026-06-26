#!/usr/bin/env bash
# Launch (or re-attach to) a Pi session for a directory, shown in a popup.
# Args: <dir> [origin-window-id]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"

prefix="$(get_tmux_option @pi_session_prefix 'pi-')"
default_cmd="pi -e '$ROOT/extensions/tmux-state.ts'"
cmd="$(get_tmux_option @pi_command "$default_cmd")"
w="$(get_tmux_option @pi_popup_width '90%')"
h="$(get_tmux_option @pi_popup_height '90%')"

session="${prefix}$(session_hash "$path")"

if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message 'π Popup window already open'
  exit 0
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -c "$path" "$cmd"
  tmux set-option -t "$session" @pi_state idle
  tmux set-option -t "$session" @pi_state_at "$(date +%s)"
fi

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @pi_origin "$window"

# Opening a completed session marks it as seen.
if [ "$(tmux show-options -qv -t "$session" @pi_state 2>/dev/null)" = done ]; then
  tmux set-option -t "$session" @pi_state idle
  tmux set-option -t "$session" @pi_state_at "$(date +%s)"
fi

tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session"
