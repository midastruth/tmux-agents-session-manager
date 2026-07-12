#!/usr/bin/env bash
# tmux-agents-session-manager plugin entrypoint.
set -uo pipefail
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @agent_launch_key 'y')"
list_key="$(get_tmux_option @agent_list_key 'u')"
daemon_binary="$(get_tmux_option @agent_daemon_binary "$CURRENT_DIR/daemon/target/release/tmux-agents-state-daemon")"
tmux set-option -gq @agent_daemon_binary "$daemon_binary"

launch_menu_q=$(printf '%q' "$CURRENT_DIR/scripts/launch_menu.sh")
tmux bind-key "$launch_key" run-shell "$launch_menu_q '#{pane_current_path}' '#{window_id}'"
list_q=$(printf '%q' "$CURRENT_DIR/scripts/list.sh")
tmux bind-key "$list_key" run-shell "$list_q '#{client_name}'"

status_enabled="$(get_tmux_option @agent_status 'on')"
if [ "$status_enabled" = on ]; then
  current_right="$(tmux show-option -gqv status-right)"
  case "$current_right" in
  *"@agent_status_cache"*) ;;
  *) tmux set-option -g status-right '#{@agent_status_cache} '"$current_right" ;;
  esac
fi

# Hook support differs by tmux release. Append only hooks advertised by this
# server; never replace user hooks. tmux 3.6 exposes no killed-pane identity to
# after-kill-pane, so only session-closed can provide a reliable exit target.
event_q=$(printf '%q' "$CURRENT_DIR/scripts/event.sh")
available_hooks="$(tmux show-hooks -g 2>/dev/null || true)"
if printf '%s\n' "$available_hooks" | grep -Eq '^session-closed($|\[|[[:space:]])'; then
  existing_hook="$(tmux show-hooks -g session-closed 2>/dev/null || true)"
  if [[ "$existing_hook" != *"$CURRENT_DIR/scripts/event.sh"* ]]; then
    tmux set-hook -ag session-closed "run-shell \"$event_q exited-session '#{hook_session_name}'\""
  fi
fi

# ensure is idempotent and starts one daemon per tmux server. ReloadConfig keeps
# a running daemon while atomically retaining its old config on validation error.
daemon_q=$(printf '%q' "$CURRENT_DIR/scripts/daemon.sh")
tmux run-shell -b "$daemon_q ensure >/dev/null 2>&1 && $daemon_q reload >/dev/null 2>&1"
