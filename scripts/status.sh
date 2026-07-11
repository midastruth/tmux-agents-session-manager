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
# Event-driven modes (used by the auto-injected status line, see
# agents_session_manager.tmux). These avoid a fork on every status refresh:
#
#   status.sh --refresh   Recompute the summary and store it in the
#                         @agent_status_cache tmux option, set the
#                         @agent_status_working flag, then refresh-client -S.
#                         Call this whenever an agent reports a new state
#                         (scripts/state.sh, the bundled Pi extension) so the
#                         cached badge updates without polling. Prints nothing.
#   status.sh --animate   Same recompute + cache update, but also prints the
#                         summary to stdout. This is the branch tmux runs from
#                         status-right ONLY while agents are working, to advance
#                         the spinner. When work drops to zero it clears the
#                         working flag and forces a re-eval so tmux switches back
#                         to the zero-fork cached branch.
#   status.sh --expire N G  Refresh only if N/G are still the scheduled state
#                           expiry and generation. Used internally by a one-shot
#                           tmux run-shell timer so blocked states (and
#                           non-animated working states) honor @agent_state_ttl
#                           without idle polling.
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

# display-message needs a client/pane context that hooks and backgrounded
# run-shell calls may lack. If the batched read produced nothing, fall back to
# per-option show-option reads (slower, but this path is rare) instead of
# silently rendering with defaults — a custom @agent_session_prefix would
# otherwise miscount managed sessions.
if [ -z "$option_values" ]; then
  AGENT_SESSION_PREFIX="$(get_tmux_option @agent_session_prefix '')"
  icon_working="$(get_tmux_option @agent_status_icon_working '')"
  icon_done="$(get_tmux_option @agent_status_icon_done '')"
  icon_blocked="$(get_tmux_option @agent_status_icon_blocked '')"
  icon_idle="$(get_tmux_option @agent_status_icon_idle '')"
  sigil="$(get_tmux_option @agent_status_sigil '')"
  animate_working="$(get_tmux_option @agent_status_animate_working '')"
  anim_frames="$(get_tmux_option @agent_status_anim_frames '')"
  col_working="$(get_tmux_option @agent_status_color_working '')"
  col_done="$(get_tmux_option @agent_status_color_done '')"
  col_blocked="$(get_tmux_option @agent_status_color_blocked '')"
  col_idle="$(get_tmux_option @agent_status_color_idle '')"
  use_color="$(get_tmux_option @agent_status_color '')"
  show_idle="$(get_tmux_option @agent_status_show_idle '')"
  state_ttl="$(get_tmux_option @agent_state_ttl '')"
fi

# Apply defaults for unset/empty options, matching get_tmux_option semantics.
AGENT_SESSION_PREFIX="${AGENT_SESSION_PREFIX:-agent-}"
icon_working="${icon_working:-✦}"
icon_done="${icon_done:-✓}"
icon_blocked="${icon_blocked:-●}"
icon_idle="${icon_idle:-·}"
sigil="${sigil:-agents}"
animate_working="${animate_working:-on}"
anim_frames="${anim_frames:-✦ ✷  ✹  ✴}"
col_working="${col_working:-yellow}"
col_done="${col_done:-cyan}"
col_blocked="${col_blocked:-red}"
col_idle="${col_idle:-green}"
use_color="${use_color:-off}"
show_idle="${show_idle:-off}"
# Ignore states whose timestamp is older than this many seconds. This prevents
# manually-started panes (or crashed managed agents) from leaving a permanent
# "working" badge after an unclean exit. Set to 0 to disable expiry.
state_ttl="${state_ttl:-259200}"
export AGENT_SESSION_PREFIX

# Parse the mode. --or/--or-host only affect the classic print mode; --refresh
# and --animate drive the event-driven cache and never apply a text fallback
# (the status-right format handles the empty-cache fallback natively).
mode=print
fallback=""
fallback_host=off
expiry_token=''
expiry_generation=''
case "${1:-}" in
--or)      fallback="${2:-}" ;;
--or-host) fallback_host=on ;;
--refresh) mode=refresh ;;
--animate) mode=animate ;;
--expire)  mode=expire; expiry_token="${2:-}"; expiry_generation="${3:-}" ;;
esac

fallback_text() {
  if [ "$fallback_host" = on ]; then
    hostname -s 2>/dev/null || hostname 2>/dev/null
  else
    printf '%s' "$fallback"
  fi
}

is_numeric() {
  case "$1" in
  ''|*[!0-9]*) return 1 ;;
  *)           return 0 ;;
  esac
}

# Snapshot publication and timer identities before scanning. Animation and
# expiry publication use this revision for an optimistic server-side compare;
# a concurrent refresh must win rather than being overwritten by an older scan.
prev_cache=''
prev_expiry=''
prev_expiry_generation=''
prev_revision=''
case "$mode" in
refresh|animate|expire)
  prev_cache="$(tmux show-option -gqv @agent_status_cache 2>/dev/null)" || exit 1
  prev_expiry="$(tmux show-option -gqv @agent_status_expiry_at 2>/dev/null)" || exit 1
  prev_expiry_generation="$(tmux show-option -gqv @agent_status_expiry_generation 2>/dev/null)" || exit 1
  prev_revision="$(tmux show-option -gqv @agent_status_revision 2>/dev/null)" || exit 1
  ;;
esac

# Delayed timers cannot be cancelled by tmux. The expiry generation identifies
# the actual one-shot timer, independently of the publication revision.
if [ "$mode" = expire ]; then
  is_numeric "$expiry_token" || exit 0
  case "$expiry_generation" in
  ''|*[!0-9_]*) exit 0 ;;
  esac
  [ "$prev_expiry" = "$expiry_token" ] || exit 0
  [ "$prev_expiry_generation" = "$expiry_generation" ] || exit 0
fi

state_is_expired() {
  local at="$1"
  is_numeric "$state_ttl" || return 1
  [ "$state_ttl" -gt 0 ] || return 1
  is_numeric "$at" || return 1
  [ $((status_now - at)) -gt "$state_ttl" ]
}

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

# compute_summary scans managed sessions and manual panes, then sets two
# globals for the caller:
#   SUMMARY        the badge string (with sigil), or empty when nothing is shown
#   WORKING_COUNT  number of active "working" agents after TTL expiry
# It does not print anything and does not apply the text fallback, so every
# mode can share it.
SUMMARY=""
WORKING_COUNT=0
NEXT_EXPIRY_AT=""

compute_summary() {
  local working=0 done_=0 blocked=0 idle=0 total=0

  count_state() {
    local state="$1" at="${2:-}" expires
    # TTL is only for states that can become stale after an unclean crash/kill.
    # A completed-but-unseen turn must remain visible until the user opens it
    # and explicitly marks it seen.
    case "$state" in
    working|blocked)
      state_is_expired "$at" && return 0
      # Cache mode normally has no polling. Remember the earliest future expiry
      # so a one-shot tmux timer can remove this state at at+TTL+1 (expiry uses
      # a strict greater-than comparison) even for blocked/non-animated work.
      if is_numeric "$state_ttl" && [ "$state_ttl" -gt 0 ] && is_numeric "$at"; then
        expires=$((at + state_ttl + 1))
        if [ "$expires" -gt "$status_now" ] &&
          { [ -z "$NEXT_EXPIRY_AT" ] || [ "$expires" -lt "$NEXT_EXPIRY_AT" ]; }; then
          NEXT_EXPIRY_AT="$expires"
        fi
      fi
      ;;
    esac
    case "$state" in
    working) working=$((working + 1)) ;;
    done)    done_=$((done_ + 1)) ;;
    blocked) blocked=$((blocked + 1)) ;;
    *)       idle=$((idle + 1)) ;; # idle / unknown / empty
    esac
    total=$((total + 1))
  }

  pane_target_is_visible() {
    local target="$1" out attached window_active pane_active
    [ -n "$target" ] || return 1
    out="$(tmux display-message -p -t "$target" '#{session_attached} #{window_active} #{pane_active}' 2>/dev/null)" || return 1
    read -r attached window_active pane_active <<EOF
$out
EOF
    [ "${attached:-0}" != 0 ] && [ "${window_active:-0}" = 1 ] && [ "${pane_active:-0}" = 1 ]
  }

  managed_done_is_visible() {
    local session="$1" agent_pane="$2" panes pane pane_count=0 only_pane='' pane_state

    # Prefer the pane that last reported session state. This avoids the old
    # coarse session_attached check, which hid unseen completions when some
    # other window/pane in the same managed session was active.
    if [ -n "$agent_pane" ]; then
      pane_target_is_visible "$agent_pane"
      return $?
    fi

    # Older sessions may not have @agent_pane. If a pane-scoped "done" exists,
    # only hide it when that exact pane is visible. As a compatibility fallback,
    # a single-pane managed session can safely treat that sole pane as the agent
    # pane; multi-pane sessions without pane identity keep showing "done".
    panes="$(tmux list-panes -s -t "$session" -F '#{pane_id}' 2>/dev/null)" || return 1
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      pane_count=$((pane_count + 1))
      only_pane="$pane"
      if ! pane_state="$(tmux show-options -pqv -t "$pane" @agent_state 2>/dev/null)"; then
        continue
      fi
      if [ "$pane_state" = done ] && pane_target_is_visible "$pane"; then
        return 0
      fi
    done <<< "$panes"

    [ "$pane_count" -eq 1 ] && pane_target_is_visible "$only_pane"
  }

  # Managed sessions (session-scoped @agent_state). Read state in the list call
  # to avoid one extra tmux process per session on every status refresh. If a
  # stale "done" belongs to the visible agent pane, treat it as already seen so
  # the current popup/session does not keep showing a done badge.
  local s state at agent_pane session_rows row_sep
  row_sep=$'\037'
  session_rows="$(tmux list-sessions -F "#{session_name}${row_sep}#{@agent_state}${row_sep}#{@agent_state_at}${row_sep}#{@agent_pane}" 2>/dev/null)" || return 1
  while IFS="$row_sep" read -r s state at agent_pane; do
    [ -z "$s" ] && continue
    is_managed_session "$s" || continue
    [ -n "$state" ] || continue
    if [ "$state" = done ] && managed_done_is_visible "$s" "$agent_pane"; then
      state=idle
    fi
    count_state "$state" "$at"
  done <<< "$session_rows"

  # Manual agent panes. Do not discover agents from process names here:
  # status.sh runs from status-right and may execute every second. A manual pane
  # is counted only after pi/codex/claude/etc. self-reports by writing
  # pane-scoped @agent_state via scripts/state.sh or an equivalent integration.
  # Do not read #{@agent_state} from list-panes here: tmux formats fall back to
  # session-scoped options, which would count every pane in a manual session
  # with session state.
  local pane pane_rows
  local -a manual_panes=()
  pane_rows="$(tmux list-panes -a -F '#{session_name}	#{pane_id}' 2>/dev/null)" || return 1
  while IFS=$'\t' read -r s pane; do
    [ -z "$pane" ] && continue
    is_managed_session "$s" && continue
    manual_panes+=("$pane")
  done <<< "$pane_rows"

  pane_in_list() {
    local needle="$1" haystack="$2" line
    while IFS= read -r line; do
      [ "$line" = "$needle" ] && return 0
    done <<< "$haystack"
    return 1
  }

  filter_existing_manual_panes() {
    local existing="$1" pane
    filtered_panes=()
    for pane in "${manual_panes[@]}"; do
      pane_in_list "$pane" "$existing" && filtered_panes+=("$pane")
    done
  }

  query_manual_pane_states() {
    local pane pane_states existing before_count
    local -a pane_state_cmd filtered_panes
    while [ "${#manual_panes[@]}" -gt 0 ]; do
      pane_state_cmd=(tmux)
      for pane in "${manual_panes[@]}"; do
        if [ "${#pane_state_cmd[@]}" -gt 1 ]; then
          pane_state_cmd+=(\;)
        fi
        pane_state_cmd+=(display-message -p -t "$pane" "__agent_pane__ $pane #{session_attached} #{window_active} #{pane_active}")
        pane_state_cmd+=(\; show-options -pq -t "$pane")
      done
      if pane_states="$("${pane_state_cmd[@]}" 2>/dev/null)"; then
        printf '%s' "$pane_states"
        return 0
      fi

      # A pane may close between list-panes and this batched query. That race is
      # safe to recover from, but only after a fresh list-panes confirms at
      # least one queried pane is now gone. If every target still exists (or the
      # confirmation query fails), this is a real tmux failure and the caller
      # must not publish a partial/empty cache.
      existing="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)" || return 1
      before_count="${#manual_panes[@]}"
      filter_existing_manual_panes "$existing"
      # ${arr[@]+...} guards the empty-array case: bash < 4.4 (macOS /bin/bash
      # 3.2) treats "${arr[@]}" of an empty array as unbound under `set -u`.
      manual_panes=(${filtered_panes[@]+"${filtered_panes[@]}"})
      [ "${#manual_panes[@]}" -eq 0 ] && return 0
      [ "${#manual_panes[@]}" -lt "$before_count" ] || return 1
    done
    return 0
  }

  # Read pane-scoped state for all manual panes with one tmux client process.
  # Use named option output plus a marker line per pane, because show-options
  # -qv emits no placeholder for unset options; relying on line positions would
  # mis-associate @agent_state and @agent_state_at when one is missing.
  if [ "${#manual_panes[@]}" -gt 0 ]; then
    local pane_states
    pane_states="$(query_manual_pane_states)" || return 1

    local current_pane='' pane_state='' pane_at='' pane_visible=0 line
    flush_pane_state() {
      [ -n "$current_pane" ] || return 0
      [ -n "$pane_state" ] || return 0
      if [ "$pane_state" = done ] && [ "$pane_visible" = 1 ]; then
        pane_state=idle
      fi
      count_state "$pane_state" "$pane_at"
    }

    while IFS= read -r line; do
      case "$line" in
      "__agent_pane__ "*)
        flush_pane_state
        read -r _marker current_pane attached window_active pane_active <<< "$line"
        pane_visible=0
        if [ "${attached:-0}" != 0 ] && [ "${window_active:-0}" = 1 ] && [ "${pane_active:-0}" = 1 ]; then
          pane_visible=1
        fi
        pane_state=''
        pane_at=''
        ;;
      "@agent_state "*)
        pane_state="${line#@agent_state }"
        ;;
      "@agent_state_at "*)
        pane_at="${line#@agent_state_at }"
        ;;
      esac
    done <<< "$pane_states"
    flush_pane_state
  fi

  WORKING_COUNT="$working"

  # Nothing to show.
  if [ "$total" -eq 0 ]; then
    SUMMARY=""
    return 0
  fi

  # Animate the working icon by cycling through a space-separated list of
  # frames, advancing one frame per second (driven by the caller's
  # status-interval). Defer icon selection until we know a working segment will
  # be visible.
  # Enable with: set -g @agent_status_animate_working 'on'
  # Customise frames with: set -g @agent_status_anim_frames '✦ ✷  ✹  ✴'
  local icon_working_frame="$icon_working"
  if [ "$working" -gt 0 ] && [ "$animate_working" = on ]; then
    # shellcheck disable=SC2206
    local -a frames=($anim_frames)
    if [ "${#frames[@]}" -gt 0 ]; then
      icon_working_frame="${frames[$(( status_now % ${#frames[@]} ))]}"
    fi
  fi

  local segments=""
  segments+="$(seg "$blocked" "$icon_blocked" "$col_blocked")"
  segments+="$(seg "$working" "$icon_working_frame" "$col_working")"
  segments+="$(seg "$done_"   "$icon_done"    "$col_done")"
  [ "$show_idle" = on ] && segments+="$(seg "$idle" "$icon_idle" "$col_idle")"

  # No visible state segments -> empty summary so the whole badge (sigil
  # included) disappears instead of leaving a lone marker stuck.
  if [ -z "$segments" ]; then
    SUMMARY=""
    return 0
  fi

  # Trim a single trailing space.
  SUMMARY="$sigil ${segments% }"
}

status_now="$(date +%s)"
compute_summary || exit 1

case "$mode" in
print)
  if [ -n "$SUMMARY" ]; then
    printf '%s' "$SUMMARY"
  else
    fallback_text
  fi
  ;;
refresh|animate|expire)
  # Keep polling (and thus animating) only while there is at least one working
  # agent AND animation is enabled. Otherwise clear the flag so tmux evaluates
  # the status-right condition as false and stops forking this script entirely.
  working_flag=""
  if [ "$WORKING_COUNT" -gt 0 ] && [ "$animate_working" = on ]; then
    working_flag=1
  fi
  # Keep timer identity stable while the nearest expiry is unchanged. Since
  # tmux delayed jobs cannot be cancelled, replacing such a timer on every
  # report would accumulate sleeping jobs for the full TTL.
  next_expiry_generation="$prev_expiry_generation"
  schedule_expiry=off
  if [ -z "$NEXT_EXPIRY_AT" ]; then
    next_expiry_generation=''
  elif [ "$mode" = expire ] || [ "$NEXT_EXPIRY_AT" != "$prev_expiry" ]; then
    next_expiry_generation="${status_now}_$$"
    schedule_expiry=on
    delay=$((NEXT_EXPIRY_AT - status_now))
    [ "$delay" -gt 0 ] || delay=1
    status_q=$(printf '%q' "$DIR/status.sh")
    timer_command="$status_q --expire $NEXT_EXPIRY_AT $next_expiry_generation"
  fi
  next_revision="${status_now}_$$"

  if [ "$mode" = refresh ]; then
    publish_args=()
    if [ "$schedule_expiry" = on ]; then
      # Timer creation and identity publication are ordered in one tmux command
      # sequence, so even a one-second timer sees its published identity.
      publish_args+=(run-shell -b -d "$delay" "$timer_command" \;)
    fi
    publish_args+=(
      set-option -g @agent_status_cache "$SUMMARY"
      \; set-option -g @agent_status_working "$working_flag"
      \; set-option -g @agent_status_expiry_at "$NEXT_EXPIRY_AT"
      \; set-option -g @agent_status_expiry_generation "$next_expiry_generation"
      \; set-option -g @agent_status_revision "$next_revision"
    )
    tmux "${publish_args[@]}" 2>/dev/null || exit 1
  else
    # Stage values, then publish only if no refresh or other animation changed
    # the revision after this invocation took its pre-scan snapshot.
    retry_command=''
    retry_delay=''
    if [ "$mode" = expire ]; then
      # If this scan loses the publication race, re-arm the consumed timer with
      # its original identity. Store the shell-escaped command in a tmux option
      # rather than interpolating it inside another quoted tmux command; nested
      # single quotes would break paths whose printf %q form contains escapes.
      retry_delay=$((expiry_token - status_now))
      [ "$retry_delay" -gt 0 ] || retry_delay=1
      status_q=$(printf '%q' "$DIR/status.sh")
      retry_command="$status_q --expire $expiry_token $expiry_generation"
    fi

    candidate_base="@agent_status_candidate_$$"
    candidate_cache="${candidate_base}_cache"
    candidate_working="${candidate_base}_working"
    candidate_expiry="${candidate_base}_expiry"
    candidate_generation="${candidate_base}_generation"
    candidate_revision="${candidate_base}_revision"
    candidate_timer="${candidate_base}_timer"
    candidate_retry="${candidate_base}_retry"
    tmux set-option -g "$candidate_cache" "$SUMMARY" \
      \; set-option -g "$candidate_working" "$working_flag" \
      \; set-option -g "$candidate_expiry" "$NEXT_EXPIRY_AT" \
      \; set-option -g "$candidate_generation" "$next_expiry_generation" \
      \; set-option -g "$candidate_revision" "$next_revision" \
      \; set-option -g "$candidate_timer" "${timer_command:-}" \
      \; set-option -g "$candidate_retry" "$retry_command" 2>/dev/null || exit 1

    commit_command=''
    if [ "$schedule_expiry" = on ]; then
      commit_command="run-shell -b -d $delay \"#{${candidate_timer}}\" ; "
    fi
    commit_command+="set-option -gF @agent_status_cache \"#{${candidate_cache}}\" ; "
    commit_command+="set-option -gF @agent_status_working \"#{${candidate_working}}\" ; "
    commit_command+="set-option -gF @agent_status_expiry_at \"#{${candidate_expiry}}\" ; "
    commit_command+="set-option -gF @agent_status_expiry_generation \"#{${candidate_generation}}\" ; "
    commit_command+="set-option -gF @agent_status_revision \"#{${candidate_revision}}\" ; "
    commit_command+='display-message -p committed'

    if [ "$mode" = expire ]; then
      commit_condition="#{&&:#{==:#{@agent_status_expiry_generation},$expiry_generation},#{==:#{@agent_status_revision},$prev_revision}}"
      # If only the publication revision changed while this one-shot callback
      # was scanning, the timer was consumed but remains responsible for the
      # same epoch. Re-arm it instead of orphaning automatic expiry.
      stale_command="if-shell -F \"#{&&:#{==:#{@agent_status_expiry_at},$expiry_token},#{==:#{@agent_status_expiry_generation},$expiry_generation}}\" \"run-shell -b -d $retry_delay \\\"#{${candidate_retry}}\\\"\" '' ; display-message -p stale"
    else
      commit_condition="#{==:#{@agent_status_revision},$prev_revision}"
      stale_command='display-message -p stale'
    fi

    commit_result="$(tmux if-shell -F "$commit_condition" "$commit_command" "$stale_command" 2>/dev/null)"
    commit_rc=$?
    tmux set-option -gu "$candidate_cache" \
      \; set-option -gu "$candidate_working" \
      \; set-option -gu "$candidate_expiry" \
      \; set-option -gu "$candidate_generation" \
      \; set-option -gu "$candidate_revision" \
      \; set-option -gu "$candidate_timer" \
      \; set-option -gu "$candidate_retry" 2>/dev/null || exit 1
    [ "$commit_rc" -eq 0 ] || exit 1
    if [ "$commit_result" != committed ] && [ "$mode" = expire ]; then
      exit 0
    fi
  fi

  if [ "$mode" = animate ]; then
    printf '%s' "$SUMMARY"
    # When work just dropped to zero, force a re-eval so tmux switches to the
    # zero-fork cached branch immediately instead of after one more interval.
    if [ -z "$working_flag" ]; then
      # Redraw is best-effort: hooks/background run-shell calls can have no
      # current client. The cache update above is the authoritative state
      # change and must remain fail-fast; a redraw failure should not break the
      # agent hook that reported the state.
      tmux refresh-client -S 2>/dev/null || true
    fi
  elif [ "$SUMMARY" != "$prev_cache" ]; then
    # Only redraw the status line when the cached badge actually changed.
    # Best-effort for the same no-current-client cases described above.
    tmux refresh-client -S 2>/dev/null || true
  fi
  ;;
esac
