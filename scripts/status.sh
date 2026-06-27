#!/usr/bin/env bash
# Compact agent status summary for the tmux status line.
#
#   status.sh             Print a summary like "agents 2✦ 1✓ 1●"; empty when no states.
#   status.sh --or <txt>  Same, but fall back to <txt> when there is no summary.
#   status.sh --or-host   Fall back to the short hostname. Use this in tmux
#                         status-right, where '#h' inside #(...) is NOT expanded
#                         and would be passed through literally.
#                         Lets one status-right slot show the agents badge while
#                         active and e.g. the hostname otherwise.
#
# Counts self-reported agent states only. Managed agent sessions are identified
# by the configured session prefix; manual panes are counted only when an agent
# integration has written pane-scoped @agent_state. This script intentionally
# does not inspect pane commands or walk process trees, so it is safe to run from
# status-right frequently. Discovery of manual panes happens in picker.sh when
# prefix+u is pressed.
set -uo pipefail
SOURCE_PATH="${BASH_SOURCE[0]}"
DIR="${SOURCE_PATH%/*}"
[ "$DIR" = "$SOURCE_PATH" ] && DIR=.
DIR="$(cd "$DIR" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Read all global options in one tmux call. status.sh can run every second, so
# avoid repeated show-option processes on every refresh.
option_sep=$'\037'
option_values="$(tmux display-message -p -F "#{@agent_session_prefix}${option_sep}#{@agent_status_icon_working}${option_sep}#{@agent_status_icon_done}${option_sep}#{@agent_status_icon_blocked}${option_sep}#{@agent_status_icon_idle}${option_sep}#{@agent_status_sigil}${option_sep}#{@agent_status_animate_working}${option_sep}#{@agent_status_anim_frames}${option_sep}#{@agent_status_color_working}${option_sep}#{@agent_status_color_done}${option_sep}#{@agent_status_color_blocked}${option_sep}#{@agent_status_color_idle}${option_sep}#{@agent_status_color}${option_sep}#{@agent_status_show_idle}" 2>/dev/null || true)"
IFS="$option_sep" read -r \
  AGENT_SESSION_PREFIX \
  icon_working icon_done icon_blocked icon_idle sigil \
  animate_working anim_frames \
  col_working col_done col_blocked col_idle \
  use_color show_idle <<< "$option_values"

# Apply defaults for unset/empty options, matching get_tmux_option semantics.
AGENT_SESSION_PREFIX="${AGENT_SESSION_PREFIX:-agent-}"
icon_working="${icon_working:-✦}"
icon_done="${icon_done:-✓}"
icon_blocked="${icon_blocked:-●}"
icon_idle="${icon_idle:-·}"
sigil="${sigil:-agents}"
animate_working="${animate_working:-on}"
anim_frames="${anim_frames:-✦ ✶ ✷ ✶}"
col_working="${col_working:-yellow}"
col_done="${col_done:-cyan}"
col_blocked="${col_blocked:-red}"
col_idle="${col_idle:-green}"
use_color="${use_color:-off}"
show_idle="${show_idle:-off}"
export AGENT_SESSION_PREFIX

# Fallback text shown when there is no active summary (e.g. a hostname). For
# --or-host, compute hostname lazily only if the fallback will actually print.
fallback=""
fallback_host=off
case "${1:-}" in
--or)      fallback="${2:-}" ;;
--or-host) fallback_host=on ;;
esac

fallback_text() {
  if [ "$fallback_host" = on ]; then
    hostname -s 2>/dev/null || hostname 2>/dev/null
  else
    printf '%s' "$fallback"
  fi
}

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

# Managed sessions (session-scoped @agent_state). Read state in the list call to
# avoid one extra tmux process per session on every status refresh.
while IFS=$'\t' read -r s state; do
  [ -z "$s" ] && continue
  is_managed_session "$s" || continue
  [ -n "$state" ] || continue
  count_state "$state"
done < <(tmux list-sessions -F '#{session_name}	#{@agent_state}' 2>/dev/null)

# Manual agent panes. Do not discover agents from process names here: status.sh
# runs from status-right and may execute every second. A manual pane is counted
# only after pi/codex/claude/etc. self-reports by writing pane-scoped
# @agent_state via scripts/state.sh or an equivalent integration. Do not read
# #{@agent_state} from list-panes here: tmux formats fall back to session-scoped
# options, which would count every pane in a manual session with session state.
manual_panes=()
while IFS=$'\t' read -r s pane; do
  [ -z "$pane" ] && continue
  is_managed_session "$s" && continue
  manual_panes+=("$pane")
done < <(tmux list-panes -a -F '#{session_name}	#{pane_id}' 2>/dev/null)

# Read pane-scoped state for all manual panes with one tmux client process. This
# preserves the old show-options -p behavior (pane options only, no inheritance)
# without spawning one tmux process per pane.
if [ "${#manual_panes[@]}" -gt 0 ]; then
  pane_state_cmd=(tmux)
  for pane in "${manual_panes[@]}"; do
    if [ "${#pane_state_cmd[@]}" -gt 1 ]; then
      pane_state_cmd+=(\;)
    fi
    pane_state_cmd+=(show-options -pqv -t "$pane" @agent_state)
  done
  pane_states="$("${pane_state_cmd[@]}" 2>/dev/null)" || exit $?
  while IFS= read -r state; do
    [ -n "$state" ] || continue
    count_state "$state"
  done <<< "$pane_states"
fi

# Nothing to show.
[ "$total" -eq 0 ] && { fallback_text; exit 0; }

# Animate the working icon by cycling through a space-separated list of frames,
# advancing one frame per second (driven by the caller's status-interval). Defer
# date(1) until we know a working segment will be visible.
# Enable with: set -g @agent_status_animate_working 'on'
# Customise frames with: set -g @agent_status_anim_frames '✦ ✶ ✷ ✶'
if [ "$working" -gt 0 ] && [ "$animate_working" = on ]; then
  # shellcheck disable=SC2206
  frames=($anim_frames)
  if [ "${#frames[@]}" -gt 0 ]; then
    icon_working="${frames[$(( $(date +%s) % ${#frames[@]} ))]}"
  fi
fi

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

segments=""
segments+="$(seg "$blocked" "$icon_blocked" "$col_blocked")"
segments+="$(seg "$working" "$icon_working" "$col_working")"
segments+="$(seg "$done_"   "$icon_done"    "$col_done")"
[ "$show_idle" = on ] && segments+="$(seg "$idle" "$icon_idle" "$col_idle")"

# No visible state segments -> show the fallback (empty by default) so the whole
# badge (sigil included) disappears instead of leaving a lone marker stuck.
[ -z "$segments" ] && { fallback_text; exit 0; }

# Trim a single trailing space.
printf '%s%s' "$sigil " "${segments% }"
