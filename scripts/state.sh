#!/usr/bin/env bash
# Record an agent session's state on its tmux session, for the picker.
# Usage: state.sh <blocked|working|done|idle>
#
# This is useful for custom integrations. The bundled Pi extension at
# extensions/tmux-state.ts updates the same @agent_state /
# @agent_state_at options.
[ -z "$TMUX_PANE" ] && exit 0

now="$(date +%s)"
state="${1:-idle}"

# Build one tmux invocation instead of spawning a process for every option.
args=(
  set-option -p -t "$TMUX_PANE" @agent_state "$state"
  \; set-option -p -t "$TMUX_PANE" @agent_state_at "$now"
)

# Session-scoped: keeps managed sessions working as before.
session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
if [ -n "$session" ]; then
  args+=(
    \; set-option -t "$session" @agent_state "$state"
    \; set-option -t "$session" @agent_state_at "$now"
  )
fi

tmux "${args[@]}" 2>/dev/null
exit 0
