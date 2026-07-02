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

# The client that invoked the binding (#{client_name}). Prefer hosting the
# popup here so it always opens on the terminal the user pressed the key in,
# even when several clients are attached to the same session.
invoking_client="${1:-}"

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
  # Wait briefly until the popup client detaches. Do not block the binding for
  # several seconds if tmux/client state is stale.
  for _ in $(seq 1 20); do
    [ -z "$(nested_session)" ] && break
    sleep 0.05
  done
fi

# Prefer the invoking client when it isn't itself a managed (popup) session.
# Resolve its session from list-clients output rather than display-message -c/-t:
# while a popup is open those targets resolve to the popup client, not the one
# that pressed the key.
host=''
if [ -n "$invoking_client" ]; then
  inv_session="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    while read -r client session; do
      [ "$client" = "$invoking_client" ] && { printf '%s\n' "$session"; break; }
    done)"
  if [ -n "$inv_session" ] && ! is_managed_session "$inv_session"; then
    host="$invoking_client"
  fi
fi
# Fall back to scanning for any non-managed client.
[ -n "$host" ] || host="$(host_client)"

# Host the picker on the outer client. -c is honored because that client has no
# popup open now; pass the parent client as an argument instead of storing it in
# a global tmux option, so concurrent tmux clients do not clobber one another.
picker_q=$(printf '%q' "$DIR/picker.sh")
host_q=$(printf '%q' "$host")
if [ -n "$host" ]; then
  tmux display-popup -c "$host" -w "$w" -h "$h" -E "$picker_q $host_q"
else
  tmux display-popup -w "$w" -h "$h" -E "$picker_q"
fi
