#!/usr/bin/env bash
# Launch a numbered agent session for a directory, shown in a popup.
# Args: <dir> [origin-window-id] [agent-name]
#   <dir> / [origin-window-id] are expanded by run-shell in the binding.
#   [agent-name] selects an entry from @agent_agents (pi/codex/claude...).
#   When omitted, @agent_default_command is used.
# By default each launch creates a numbered instance. Set
# @agent_multiple_instances off to restore one session per directory/agent.
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
  session_base="${prefix}${agent}-$(session_hash "$path")"
else
  # Default command, unnamespaced session.
  cmd="$(get_tmux_option @agent_default_command "$default_cmd")"
  session_base="${prefix}$(session_hash "$path")"
fi

if is_managed_session "$(tmux display-message -p '#S')"; then
  tmux display-message 'Agent popup already open'
  exit 0
fi

multiple_instances="$(get_tmux_option @agent_multiple_instances 'on')"
created=0
instance=''
if [ "$multiple_instances" = on ]; then
  # Reserve the first free numbered name. new-session itself is the atomic
  # operation: if two launchers race for the same number, the loser retries.
  instance=1
  while :; do
    session="${session_base}-${instance}"
    if tmux has-session -t "=$session" 2>/dev/null; then
      instance=$((instance + 1))
      continue
    fi
    if tmux new-session -d -s "$session" -c "$path" "$cmd"; then
      created=1
      break
    fi
    if tmux has-session -t "=$session" 2>/dev/null; then
      instance=$((instance + 1))
      continue
    fi
    tmux display-message "Failed to create agent session: $session"
    exit 0
  done
else
  session="$session_base"
  if ! tmux has-session -t "=$session" 2>/dev/null; then
    if tmux new-session -d -s "$session" -c "$path" "$cmd"; then
      created=1
    elif ! tmux has-session -t "=$session" 2>/dev/null; then
      tmux display-message "Failed to create agent session: $session"
      exit 0
    fi
  fi
fi

if [ -n "$agent" ]; then
  tool="$agent"
else
  tool_first="${cmd%% *}"
  tool="${tool_first##*/}"
fi

if [ "$created" -eq 1 ]; then
  tmux set-option -t "$session" @agent_state idle
  tmux set-option -t "$session" @agent_state_at "$(date +%s)"
  # Record the selected agent and optional instance separately, so the picker
  # can display pi-1 / pi-2 without having to parse the internal session name.
  tmux set-option -t "$session" @agent_tool "$tool"
  [ -n "$instance" ] && tmux set-option -t "$session" @agent_instance "$instance"
fi

agent_pane="$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -n 1)"
if [ "$created" -eq 1 ] && [ -n "$agent_pane" ]; then
  tmux set-option -p -t "$agent_pane" @agent_tool "$tool"
fi
if [ "$tool" = claude ] && [ -n "$agent_pane" ]; then
  event_q="$(printf '%q' "$DIR/event.sh")"
  tmux run-shell -b "$event_q claude-started $(printf '%q' "$agent_pane") $(printf '%q' "$session")"
fi

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @agent_origin "$window"

# Opening a completed session marks it as seen.
mark_managed_session_seen_if_done "$session"

session_q=$(printf '%q' "$session")
tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session_q"
