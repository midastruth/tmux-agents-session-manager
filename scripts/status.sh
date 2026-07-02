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
option_values="$(tmux display-message -p -F "#{@agent_session_prefix}${option_sep}#{@agent_status_icon_working}${option_sep}#{@agent_status_icon_done}${option_sep}#{@agent_status_icon_blocked}${option_sep}#{@agent_status_icon_idle}${option_sep}#{@agent_status_sigil}${option_sep}#{@agent_status_animate_working}${option_sep}#{@agent_status_anim_frames}${option_sep}#{@agent_status_color_working}${option_sep}#{@agent_status_color_done}${option_sep}#{@agent_status_color_blocked}${option_sep}#{@agent_status_color_idle}${option_sep}#{@agent_status_color}${option_sep}#{@agent_status_show_idle}${option_sep}#{@agent_state_ttl}" 2>/dev/null || true)"
IFS="$option_sep" read -r \
  AGENT_SESSION_PREFIX \
  icon_working icon_done icon_blocked icon_idle sigil \
  animate_working anim_frames \
  col_working col_done col_blocked col_idle \
  use_color show_idle state_ttl <<< "$option_values"

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
# Ignore states whose timestamp is older than this many seconds. This prevents
# manually-started panes (or crashed managed agents) from leaving a permanent
# "working" badge after an unclean exit. Set to 0 to disable expiry.
state_ttl="${state_ttl:-21600}"
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

is_numeric() {
  case "$1" in
  ''|*[!0-9]*) return 1 ;;
  *)           return 0 ;;
  esac
}

state_is_expired() {
  local at="$1"
  is_numeric "$state_ttl" || return 1
  [ "$state_ttl" -gt 0 ] || return 1
  is_numeric "$at" || return 1
  [ $((status_now - at)) -gt "$state_ttl" ]
}

count_state() {
  local state="$1" at="${2:-}"
  # TTL is only for states that can become stale after an unclean crash/kill.
  # A completed-but-unseen turn must remain visible until the user opens it and
  # explicitly marks it seen.
  case "$state" in
  working|blocked) state_is_expired "$at" && return 0 ;;
  esac
  case "$state" in
  working) working=$((working + 1)) ;;
  done)    done_=$((done_ + 1)) ;;
  blocked) blocked=$((blocked + 1)) ;;
  *)       idle=$((idle + 1)) ;; # idle / unknown / empty
  esac
  total=$((total + 1))
}

status_now="$(date +%s)"

# Managed sessions (session-scoped @agent_state). Read state in the list call to
# avoid one extra tmux process per session on every status refresh.
while IFS=$'\t' read -r s state at; do
  [ -z "$s" ] && continue
  is_managed_session "$s" || continue
  [ -n "$state" ] || continue
  count_state "$state" "$at"
done < <(tmux list-sessions -F '#{session_name}	#{@agent_state}	#{@agent_state_at}' 2>/dev/null)

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

# Read pane-scoped state for all manual panes with one tmux client process. Use
# named option output plus a marker line per pane, because show-options -qv emits
# no placeholder for unset options; relying on line positions would mis-associate
# @agent_state and @agent_state_at when one is missing.
if [ "${#manual_panes[@]}" -gt 0 ]; then
  pane_state_cmd=(tmux)
  for pane in "${manual_panes[@]}"; do
    if [ "${#pane_state_cmd[@]}" -gt 1 ]; then
      pane_state_cmd+=(\;)
    fi
    pane_state_cmd+=(display-message -p -t "$pane" "__agent_pane__ $pane")
    pane_state_cmd+=(\; show-options -pq -t "$pane")
  done
  pane_states="$("${pane_state_cmd[@]}" 2>/dev/null)" || exit $?

  current_pane='' pane_state='' pane_at=''
  flush_pane_state() {
    [ -n "$current_pane" ] || return 0
    [ -n "$pane_state" ] || return 0
    count_state "$pane_state" "$pane_at"
  }

  while IFS= read -r line; do
    case "$line" in
    "__agent_pane__ "*)
      flush_pane_state
      current_pane="${line#__agent_pane__ }"
      pane_state=''
      pane_at=''
      ;;
    "@agent_state "*)
      pane_state="${line#@agent_state }"
      ;;
    "@agent_state_at "*)
      pane_at="${line#@agent_state_at }"
      ;;
    blocked|working|done|idle)
      [ -z "$pane_state" ] && pane_state="$line"
      ;;
    esac
  done <<< "$pane_states"
  flush_pane_state
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
    icon_working="${frames[$(( status_now % ${#frames[@]} ))]}"
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
