#!/usr/bin/env bash
# Launch (or re-attach to) an agent session for a directory, shown in a popup.
# Args: <dir> [origin-window-id] [agent-name]
#   <dir> / [origin-window-id] are expanded by run-shell in the binding.
#   [agent-name] selects an entry from @pi_agents (pi/codex/claude...). When
#   omitted, the pi default command (@pi_command) is used.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"
agent="${3:-}"

prefix="$(get_tmux_option @pi_session_prefix 'pi-')"
default_cmd="pi -e '$ROOT/extensions/tmux-state.ts'"
w="$(get_tmux_option @pi_popup_width '90%')"
h="$(get_tmux_option @pi_popup_height '90%')"

if [ -n "$agent" ]; then
  # Named agent from the @pi_agents registry.
  cmd="$(agent_command "$agent" "$default_cmd")" || {
    tmux display-message "π Unknown agent: $agent"
    exit 0
  }
  # Namespace the session per agent so pi/codex/claude in the same directory
  # get distinct sessions instead of colliding on the same path hash.
  session="${prefix}${agent}-$(session_hash "$path")"
else
  # Backwards-compatible default: the pi command, unnamespaced session.
  cmd="$(get_tmux_option @pi_command "$default_cmd")"
  session="${prefix}$(session_hash "$path")"
fi

if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message 'π Popup window already open'
  exit 0
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -c "$path" "$cmd"
  tmux set-option -t "$session" @pi_state idle
  tmux set-option -t "$session" @pi_state_at "$(date +%s)"
  # Record which agent this session runs (first token's basename of $cmd), so
  # the picker can show pi / codex / claude side by side.
  tool_first="${cmd%% *}"
  tmux set-option -t "$session" @pi_tool "${tool_first##*/}"
fi

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @pi_origin "$window"

# Opening a completed session marks it as seen.
if [ "$(tmux show-options -qv -t "$session" @pi_state 2>/dev/null)" = done ]; then
  tmux set-option -t "$session" @pi_state idle
  tmux set-option -t "$session" @pi_state_at "$(date +%s)"
fi

tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session"
