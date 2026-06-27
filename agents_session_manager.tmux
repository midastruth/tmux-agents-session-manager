#!/usr/bin/env bash
# tmux-agents-session-manager
#
# List, monitor status, and jump across nested Pi coding-agent sessions from a
# single popup. tpm runs this file as an executable on tmux startup; it reads
# user options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @agent_launch_key 'y')"
list_key="$(get_tmux_option @agent_list_key 'u')"

# Export the absolute path to status.sh as a tmux option so user config never
# has to hardcode this plugin's install directory. Reference it from
# status-right like:  #(#{@agent_status_script} --or-host)
# This decouples the user's status line from where the plugin lives on disk.
tmux set-option -gq @agent_status_script "$CURRENT_DIR/scripts/status.sh"

# Launch (or re-attach to) an agent session for the current pane's directory.
# launch_menu.sh offers a picker when multiple agents are configured via
# @agent_agents (pi/codex/claude...), otherwise it launches directly.
# #{pane_current_path} / #{window_id} are expanded by run-shell before the args
# reach the script.
tmux bind-key "$launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch_menu.sh '#{pane_current_path}' '#{window_id}'"

# Open the session picker. When pressed from inside a session popup, list.sh
# closes that popup first so the picker opens full-size on the outer client.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh '#{client_name}'"

# Optional: append a compact agent status summary to status-right.
# Enable with `set -g @agent_status on`. The interval (seconds)
# controls how often tmux re-runs the summary; status-interval also bounds it.
status_enabled="$(get_tmux_option @agent_status 'off')"
if [ "$status_enabled" = on ]; then
  status_interval="$(get_tmux_option @agent_status_interval '5')"
  summary="#($CURRENT_DIR/scripts/status.sh)"
  current_right="$(tmux show-option -gqv status-right)"
  # Avoid appending twice on plugin reload.
  case "$current_right" in
  *"$CURRENT_DIR/scripts/status.sh"*) : ;;
  *) tmux set-option -g status-right "$summary $current_right" ;;
  esac
  # Ensure the line refreshes often enough to feel live.
  if [ "$(tmux show-option -gqv status-interval)" -gt "$status_interval" ] 2>/dev/null; then
    tmux set-option -g status-interval "$status_interval"
  fi
fi
