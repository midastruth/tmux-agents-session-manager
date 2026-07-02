#!/usr/bin/env bash
# Launch (or re-attach to) an agent session for a directory, shown in a popup.
# Args: <dir> [origin-window-id] [agent-name]
#   <dir> / [origin-window-id] are expanded by run-shell in the binding.
#   [agent-name] selects an entry from @agent_agents (pi/codex/claude...).
#   When omitted, @agent_default_command is used.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"
agent="${3:-}"

prefix="$(agent_session_prefix)"
default_cmd="pi -e '$ROOT/extensions/tmux-state.ts'"
w="$(get_tmux_option @agent_popup_width '90%')"
h="$(get_tmux_option @agent_popup_height '90%')"

if [ -n "$agent" ]; then
  # Named agent from the @agent_agents registry.
  cmd="$(agent_command "$agent" "$default_cmd")" || {
    tmux display-message "Unknown agent: $agent"
    exit 0
  }
  # Namespace the session per agent so pi/codex/claude in the same directory
  # get distinct sessions instead of colliding on the same path hash.
  session="${prefix}${agent}-$(session_hash "$path")"
else
  # Default command, unnamespaced session.
  cmd="$(get_tmux_option @agent_default_command "$default_cmd")"
  session="${prefix}$(session_hash "$path")"
fi

if is_managed_session "$(tmux display-message -p '#S')"; then
  tmux display-message 'Agent popup already open'
  exit 0
fi

created=0
if ! tmux has-session -t "$session" 2>/dev/null; then
  if tmux new-session -d -s "$session" -c "$path" "$cmd"; then
    created=1
  elif ! tmux has-session -t "$session" 2>/dev/null; then
    tmux display-message "Failed to create agent session: $session"
    exit 0
  fi
fi

if [ "$created" -eq 1 ]; then
  tmux set-option -t "$session" @agent_state idle
  tmux set-option -t "$session" @agent_state_at "$(date +%s)"
  # Record which agent this session runs (first token's basename of $cmd), so
  # the picker can show pi / codex / claude side by side.
  tool_first="${cmd%% *}"
  tmux set-option -t "$session" @agent_tool "${tool_first##*/}"
fi

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @agent_origin "$window"

# Opening a completed session marks it as seen.
mark_managed_session_seen_if_done "$session"

session_q=$(printf '%q' "$session")
tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session_q"
