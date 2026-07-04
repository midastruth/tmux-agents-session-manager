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
# Enable with `set -g @agent_status on`.
#
# Event-driven, not polled. The badge normally comes from the cached
# @agent_status_cache option, which tmux expands with zero forks. Agents refresh
# that cache only when their state changes (scripts/state.sh / the bundled Pi
# extension call `status.sh --refresh`). The one exception is the spinner: while
# any agent is working, @agent_status_working is set and tmux runs
# `status.sh --animate` from status-right to advance the animation frame. tmux
# lazily evaluates only the selected branch of #{?...}, so when nothing is
# working the animate branch is never forked and CPU use drops to zero.
#
# @agent_status_interval still bounds how often the spinner advances while
# working; it no longer sets a permanent polling cost for idle/done states.
status_enabled="$(get_tmux_option @agent_status 'off')"
if [ "$status_enabled" = on ]; then
  status_interval="$(get_tmux_option @agent_status_interval '1')"
  # While working: fork status.sh --animate to advance the spinner.
  # Otherwise:     expand the cached badge (or #h when it is empty). Zero forks.
  summary="#{?@agent_status_working,#($CURRENT_DIR/scripts/status.sh --animate),#{?@agent_status_cache,#{@agent_status_cache},#h}}"
  current_right="$(tmux show-option -gqv status-right)"
  # Avoid appending twice on plugin reload. Match either the new marker option
  # or a legacy raw #(status.sh) embed from an earlier version of this plugin.
  case "$current_right" in
  *"@agent_status_working"*|*"$CURRENT_DIR/scripts/status.sh"*) : ;;
  *) tmux set-option -g status-right "$summary $current_right" ;;
  esac
  # Ensure the line refreshes often enough to animate smoothly while working.
  if [ "$(tmux show-option -gqv status-interval)" -gt "$status_interval" ] 2>/dev/null; then
    tmux set-option -g status-interval "$status_interval"
  fi
  # Prime the cache once on load so the badge reflects current state before the
  # first agent event fires.
  tmux run-shell -b "$CURRENT_DIR/scripts/status.sh --refresh"
fi
