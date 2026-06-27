#!/usr/bin/env bash
# Open the agent session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Avoid reading the same tmux option once per client while locating host/nested
# sessions.
AGENT_SESSION_PREFIX="$(agent_session_prefix)"
export AGENT_SESSION_PREFIX

w="$(get_tmux_option @agent_popup_width '90%')"
h="$(get_tmux_option @agent_popup_height '90%')"

# The session of a client attached to a managed session — i.e. the popup we are
# inside, if any. Empty when invoked from a normal (non-popup) pane.
nested_session() {
  local client session
  tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    while read -r client session; do
      is_managed_session "$session" && { printf '%s\n' "$session"; return; }
    done
}

# A client NOT attached to a managed session — the outer client that should host
# the picker popup.
host_client() {
  local client session
  tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    while read -r client session; do
      is_managed_session "$session" || { printf '%s\n' "$client"; return; }
    done
}

# If we are inside a session popup, close it (detach its client)
sess="$(nested_session)"
if [ -n "$sess" ]; then
  tmux detach-client -s "$sess"
  # Wait until the session is gone
  for _ in $(seq 1 100); do
    [ -z "$(nested_session)" ] && break
    sleep 0.05
  done
fi

host="$(host_client)"
tmux set-option -gq @agent_parent "$host"

# Host the picker on the outer client. -c is honored because that client has no
# popup open now; fall back to the default client if none was found.
if [ -n "$host" ]; then
  tmux display-popup -c "$host" -w "$w" -h "$h" -E "$DIR/picker.sh"
else
  tmux display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
fi
