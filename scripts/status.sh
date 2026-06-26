#!/usr/bin/env bash
# Compact Pi status summary for the tmux status line.
#
#   status.sh           Print a one-line summary like "π 2▶ 1✓ 1●", suitable for
#                       embedding in status-right via #(.../status.sh).
#
# Counts both managed `pi-<hash>` sessions and manually-started `pi` panes,
# reading the same @pi_state options the picker uses. Only non-zero groups are
# shown; prints nothing when there are no Pi sessions at all.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @pi_session_prefix 'pi-')"

# Icons/labels per state. Override via tmux options if desired.
icon_working="$(get_tmux_option @pi_status_icon_working '▶')"
icon_done="$(get_tmux_option @pi_status_icon_done '✓')"
icon_blocked="$(get_tmux_option @pi_status_icon_blocked '●')"
icon_idle="$(get_tmux_option @pi_status_icon_idle '·')"
sigil="$(get_tmux_option @pi_status_sigil 'π')"

# tmux colour names for #[fg=...]; empty disables colouring.
col_working="$(get_tmux_option @pi_status_color_working 'yellow')"
col_done="$(get_tmux_option @pi_status_color_done 'cyan')"
col_blocked="$(get_tmux_option @pi_status_color_blocked 'red')"
col_idle="$(get_tmux_option @pi_status_color_idle 'green')"
# Whether to emit #[fg=...] colour escapes (only meaningful inside status line).
use_color="$(get_tmux_option @pi_status_color 'on')"
# Show idle count too? Off by default to keep the line quiet.
show_idle="$(get_tmux_option @pi_status_show_idle 'off')"

working=0 done_=0 blocked=0 idle=0 total=0

count_state() {
  case "$1" in
  working) working=$((working + 1)) ;;
  done)    done_=$((done_ + 1)) ;;
  blocked) blocked=$((blocked + 1)) ;;
  *)       idle=$((idle + 1)) ;; # idle / unknown / empty
  esac
  total=$((total + 1))
}

# Managed sessions (session-scoped @pi_state).
while IFS= read -r s; do
  [ -z "$s" ] && continue
  [[ "$s" == "$prefix"* ]] || continue
  count_state "$(tmux show-options -qv -t "$s" @pi_state 2>/dev/null)"
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

# Manual `pi` panes (pane-scoped @pi_state).
while IFS=$'\t' read -r s pane cmd; do
  [[ "$s" == "$prefix"* ]] && continue
  [ "${cmd##*/}" = pi ] || continue
  count_state "$(tmux show-options -pqv -t "$pane" @pi_state 2>/dev/null)"
done < <(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_current_command}' 2>/dev/null)

# Nothing to show.
[ "$total" -eq 0 ] && exit 0

# Build segments. With colour: "#[fg=COL]N ICON#[default]".
seg() {
  local n="$1" icon="$2" col="$3"
  [ "$n" -le 0 ] && return
  if [ "$use_color" = on ] && [ -n "$col" ]; then
    printf '#[fg=%s]%s%s#[default] ' "$col" "$n" "$icon"
  else
    printf '%s%s ' "$n" "$icon"
  fi
}

out="$sigil "
out+="$(seg "$blocked" "$icon_blocked" "$col_blocked")"
out+="$(seg "$working" "$icon_working" "$col_working")"
out+="$(seg "$done_"   "$icon_done"    "$col_done")"
[ "$show_idle" = on ] && out+="$(seg "$idle" "$icon_idle" "$col_idle")"

# Trim a single trailing space.
printf '%s' "${out% }"
