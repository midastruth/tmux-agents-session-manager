#!/usr/bin/env bash
# Codex `notify` hook: map Codex events to the picker's @agent_state.
#
# Wire it up in ~/.codex/config.toml:
#   notify = ["/path/to/tmux-agents-session-manager/scripts/codex_notify.sh"]
#
# Codex passes a single JSON argument describing the event. We only act on
# `agent-turn-complete` (the turn finished) and mark the session `done`.
# Codex has no "turn started" event, so `working` is not reported here.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${CODEX_NOTIFY_DEBUG:-}" ] || [ -f /tmp/codex_notify.debug ]; then
  {
    echo "--- $(date '+%F %T') ---"
    echo "TMUX_PANE=${TMUX_PANE:-<unset>} argc=$#"
    i=0; for a in "$@"; do echo "arg$i=$a"; i=$((i+1)); done
  } >>/tmp/codex_notify.log 2>&1
fi

payload="${1:-}"
type=""
if [ -n "$payload" ]; then
  type="$(printf '%s' "$payload" | jq -r '.type // empty' 2>/dev/null)"
fi

case "$type" in
  agent-turn-complete) "$DIR/state.sh" done ;;
  *) : ;;
esac
exit 0
