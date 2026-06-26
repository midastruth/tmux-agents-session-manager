#!/usr/bin/env bash
# Compatibility entry point for the old project/file name.
# Prefer: run-shell /path/to/tmux-pi-session-manager/pi_session_manager.tmux

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$CURRENT_DIR/pi_session_manager.tmux"
