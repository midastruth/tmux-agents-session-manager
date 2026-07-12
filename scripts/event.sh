#!/usr/bin/env bash
# Send lifecycle/discovery events to the state daemon.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

json_string() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '"%s"' "$value"
}

kind="${1:-}"
case "$kind" in
seen-pane)
  [ -n "${2:-}" ] || exit 1
  request="{\"type\":\"Seen\",\"pane_id\":$(json_string "$2"),\"session_id\":null}"
  ;;
exited-pane)
  [ -n "${2:-}" ] || exit 1
  request="{\"type\":\"Exited\",\"pane_id\":$(json_string "$2"),\"session_name\":null}"
  ;;
exited-session)
  [ -n "${2:-}" ] || exit 1
  request="{\"type\":\"Exited\",\"pane_id\":null,\"session_name\":$(json_string "$2")}"
  ;;
claude-started|claude-discovered)
  [ -n "${2:-}" ] || exit 1
  if [ "$kind" = claude-started ]; then event_type=ClaudeStarted; else event_type=ClaudeDiscovered; fi
  session_name="${3:-}"
  session_id="${4:-}"
  if [ -n "$session_name" ]; then session_json="$(json_string "$session_name")"; else session_json=null; fi
  if [ -n "$session_id" ]; then id_json="$(json_string "$session_id")"; else id_json=null; fi
  request="{\"type\":\"$event_type\",\"pane_id\":$(json_string "$2"),\"session_name\":$session_json,\"session_id\":$id_json}"
  ;;
*) exit 1 ;;
esac
"$DIR/daemon.sh" send "$request" >/dev/null
