#!/usr/bin/env bash
# Record an agent session's state on its tmux session, for the picker.
# Usage: state.sh <blocked|working|done|idle>
#
# This is useful for custom integrations. The bundled Pi extension at
# extensions/tmux-state.ts updates the same @agent_state /
# @agent_state_at options.
[ -z "$TMUX_PANE" ] && exit 0

SOURCE_PATH="${BASH_SOURCE[0]}"
DIR="${SOURCE_PATH%/*}"
[ "$DIR" = "$SOURCE_PATH" ] && DIR=.
DIR="$(cd "$DIR" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

now="$(date +%s)"
state="${1:-idle}"
case "$state" in
blocked|working|done|idle) ;;
*) exit 0 ;;
esac

# If the user is actively watching this managed session's pane right now, there
# is nothing left to "discover" later, so downgrade "done" to "idle" instead of
# leaving a stale badge until the session is reopened. This mirrors the bundled
# Pi extension's agent_end shortcut, so agents wired through hooks (e.g. Codex's
# Stop hook running state.sh done) behave like pi. Manual panes never take this
# shortcut (see is_watched_managed_pane).
if [ "$state" = "done" ] && is_watched_managed_pane "$TMUX_PANE"; then
  state=idle
fi

# Build one tmux invocation instead of spawning a process for every option.
args=(
  set-option -p -t "$TMUX_PANE" @agent_state "$state"
  \; set-option -p -t "$TMUX_PANE" @agent_state_at "$now"
)

# Session-scoped state is authoritative only for managed sessions (one agent per
# tmux session). Manual panes can share a session, so session-level state there
# would be last-writer-wins pollution and may leak through tmux format fallback.
session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
if [ -n "$session" ] && is_managed_session "$session"; then
  args+=(
    \; set-option -t "$session" @agent_state "$state"
    \; set-option -t "$session" @agent_state_at "$now"
  )
fi

tmux "${args[@]}" 2>/dev/null

# Update the event-driven status badge now that state changed, so the cached
# summary (and the working spinner flag) reflect this report without polling.
trigger_status_refresh "$DIR"
exit 0
