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

# Pane-scoped: works for manual agent panes that share a tmux session.
tmux set-option -p -t "$TMUX_PANE" @agent_state "$state" 2>/dev/null
tmux set-option -p -t "$TMUX_PANE" @agent_state_at "$now" 2>/dev/null

# Session-scoped: keeps managed sessions working as before.
session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
if [ -n "$session" ]; then
  tmux set-option -t "$session" @agent_state "$state"
  tmux set-option -t "$session" @agent_state_at "$now"
fi
exit 0
