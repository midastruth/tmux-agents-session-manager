#!/usr/bin/env bash
# Interactive picker for running agent sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       chosen session's origin window and resumes it in the popup.
#                       Manually-started agent panes are also listed and jumped to.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Cache hot global options for this invocation. The picker enumerates every
# session/pane and should not shell out to tmux for static config per row.
AGENT_SESSION_PREFIX="$(agent_session_prefix)"
AGENT_DETECT_COMMANDS="$(detect_commands)"
AGENT_DETECT_WRAPPERS="$(wrapper_commands)"
export AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS

# One daemon snapshot supplies every row; the picker never reads legacy tmux
# state options. If the daemon is unavailable, rows remain discoverable with an
# unknown/manual state.
daemon_records="$("$DIR/daemon.sh" snapshot-picker 2>/dev/null || true)"

lookup_daemon_state() {
  local kind="$1" target="$2" session pane state changed
  while IFS=$'\037' read -r session pane state changed; do
    [ -n "$state" ] || continue
    if { [ "$kind" = session ] && [ "$session" = "$target" ]; } || { [ "$kind" = pane ] && [ "$pane" = "$target" ]; }; then
      printf '%s\t%s' "$state" "$changed"
      return 0
    fi
  done <<< "$daemon_records"
  return 1
}

short_path() {
  # shellcheck disable=SC2088 # literal ~ is intentional for display
  case "$1" in
  "$HOME")   printf '~' ;;
  "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
  *)          printf '%s' "$1" ;;
  esac
}

# classify <state>  ->  prints "<rank>\t<label>\t<desc>"
# label is the padded status badge; desc is the trailing note shown after the
# path. Shared so managed sessions and manual panes render identically.
classify() {
  case "$1" in
  blocked) printf '0\t🔴 blocked\tneeds input' ;;
  done)    printf '1\t🔵 done   \tfinished, unseen' ;;
  idle)    printf '2\t🟢 idle   \twaiting for prompt' ;;
  working) printf '3\t🟡 working\tactively running' ;;
  *)       printf '2\t⚪ unknown\tno status extension' ;;
  esac
}

# picker_now -> current epoch seconds. Honors PICKER_NOW when set to a numeric
# value so tests can pin "now" and avoid a race: picker.sh would otherwise read
# the clock again after the test captured its own timestamp, drifting the
# rendered age across a one-second boundary. Not for production use.
picker_now() {
  if [[ "${PICKER_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$PICKER_NOW"
  else
    date +%s
  fi
}

# humanize_ago <epoch-seconds> <now> -> compact age like 45s / 12m / 3h / 2d.
# Falls back to '-' when the timestamp is missing or non-numeric.
humanize_ago() {
  local at="$1" now="$2" delta
  [[ "$at" =~ ^[0-9]+$ ]] || { printf '%s' '-'; return; }
  delta=$((now - at))
  [ "$delta" -lt 0 ] && delta=0
  if [ "$delta" -lt 60 ]; then
    printf '%ds' "$delta"
  elif [ "$delta" -lt 3600 ]; then
    printf '%dm' "$((delta / 60))"
  elif [ "$delta" -lt 86400 ]; then
    printf '%dh' "$((delta / 3600))"
  else
    printf '%dd' "$((delta / 86400))"
  fi
}

pane_still_exists() {
  local target="$1" panes pane
  panes="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)" || return 2
  while IFS= read -r pane; do
    [ "$pane" = "$target" ] && return 0
  done <<< "$panes"
  return 1
}

# split_classify <state> -> sets $rank $label $desc from classify output.
split_classify() {
  local info rest
  info=$(classify "$1")
  rank=${info%%$'\t'*}
  rest=${info#*$'\t'}
  label=${rest%%$'\t'*}
  desc=${rest#*$'\t'}
}

emit_managed_rows() {
  local now s state at path cmd tool instance name rank label desc ago daemon_state
  now=$(picker_now)
  tmux list-sessions -F '#{session_name}	#{@agent_state}	#{@agent_state_at}	#{pane_current_path}	#{@agent_tool}	#{pane_current_command}	#{@agent_instance}' 2>/dev/null |
    while IFS=$'\t' read -r s state at path tool cmd instance; do
      is_managed_session "$s" || continue
      name=${path##*/}
      daemon_state="$(lookup_daemon_state session "$s" || true)"
      if [ -n "$daemon_state" ]; then
        state="${daemon_state%%$'\t'*}"
        at="${daemon_state#*$'\t'}"
      fi
      # The agent recorded at launch, falling back to whatever runs in the pane.
      [ -n "$tool" ] || tool=${cmd##*/}
      [ -n "$instance" ] && tool="${tool}-${instance}"
      split_classify "$state"
      ago="$(humanize_ago "$at" "$now")"
      # rank \t kind \t target \t label \t name \t age \t path \t desc \t tool
      printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$s" "$label" "$name" "$ago" "$(short_path "$path")" "$desc" "$tool"
    done
}

emit_manual_rows() {
  local now panes s pane cmd ppid path state at opts line base name rank label desc ago daemon_state
  now=$(picker_now)
  panes="$(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_current_command}	#{pane_pid}	#{pane_current_path}' 2>/dev/null)" || return 1

  # Snapshot ps at most once, and only when at least one non-managed pane is
  # running a configured wrapper command. This preserves the cheap direct-command
  # path while avoiding one full process-table scan per node/npm/bun pane.
  AGENT_PS_TABLE=''
  AGENT_PS_TABLE_READY=0
  while IFS=$'\t' read -r s pane cmd ppid path; do
    [ -z "$pane" ] && continue
    is_managed_session "$s" && continue
    if is_wrapper_command "${cmd##*/}"; then
      AGENT_PS_TABLE="$(process_table_snapshot 2>/dev/null || true)"
      AGENT_PS_TABLE_READY=1
      break
    fi
  done <<< "$panes"

  while IFS=$'\t' read -r s pane cmd ppid path; do
    # Managed sessions are already listed as managed agent sessions.
    is_managed_session "$s" && continue
    # Resolve the agent name, including wrappers (codex runs under node) by
    # walking the pane's process subtree only for known wrapper commands.
    # Empty -> not an agent pane.
    base="$(resolve_pane_agent "${cmd##*/}" "$ppid")" || continue
    [ -n "$base" ] || continue
    name=${path##*/}
    daemon_state="$(lookup_daemon_state pane "$pane" || true)"
    if [ -n "$daemon_state" ]; then
      state="${daemon_state%%$'\t'*}"
      at="${daemon_state#*$'\t'}"
    else
      # The tmux mirror is the daemon's restart/recovery snapshot and remains a
      # reliable picker fallback while the daemon client is unavailable.
      if ! opts="$(tmux show-options -p -t "$pane" 2>/dev/null)"; then
        pane_still_exists "$pane"
        case "$?" in
        1) continue ;;
        *) return 1 ;;
        esac
      fi
      state=''
      at=''
      while IFS= read -r line; do
        case "$line" in
        "@agent_state "*) state="${line#@agent_state }" ;;
        "@agent_state_at "*) at="${line#@agent_state_at }" ;;
        esac
      done <<< "$opts"
    fi
    if [ -n "$state" ]; then
      split_classify "$state"
    else
      rank=2; label='🟣 manual '; desc="pane running $base"
    fi
    ago="$(humanize_ago "$at" "$now")"
    printf '%s\tpane\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rank" "$pane" "$label" "$name" "$ago" "$(short_path "$path")" "$desc" "$base"
  done <<< "$panes"
}

emit_rows() {
  {
    emit_managed_rows
    emit_manual_rows
  } | awk 'BEGIN { FS = OFS = "\t" }
      {
        # Decorate: convert the humanized age (45s/12m/3h/2d/-) back into
        # seconds so the numeric sort compares real ages. Sorting the display
        # string numerically would rank "3h" (3) before "45s" (45). An unknown
        # age ("-") must sort last within its rank, not first: "-" + 0 is 0,
        # which would outrank every real timestamp as the youngest row.
        if ($6 == "-") {
          secs = 2147483647
        } else {
          n = $6 + 0
          u = substr($6, length($6))
          secs = (u == "m") ? n * 60 : (u == "h") ? n * 3600 : \
                 (u == "d") ? n * 86400 : n
        }
        print secs, $0
      }' |
    # rank asc (attention-needed floats up), then age asc so the session that
    # finished just now sits at the top of its group. Field 1 is the sort
    # decoration (age in seconds), field 2 the rank; strip it after sorting.
    sort -t$'\t' -k2,2n -k1,1n | cut -f2- |
    # Append a pre-aligned display column (field 10). Two passes: first find the
    # widest project name and tool name, then pad every row to those widths so
    # the tool, age and path columns line up. Logic fields 1-9 stay untouched
    # for enter/ctrl-x. Field order: 1 rank, 2 kind, 3 target, 4 label,
    # 5 name, 6 age, 7 path, 8 desc, 9 tool.
    awk 'BEGIN { FS = OFS = "\t" }
      {
        rows[NR] = $0
        if (length($5) > w) w = length($5)
        if (length($9) > tw) tw = length($9)
      }
      END {
        for (i = 1; i <= NR; i++) {
          split(rows[i], f, "\t")
          disp = sprintf("%s  %-*s  %-*s  %4s  %s — %s", \
            f[4], tw, f[9], w, f[5], f[6], f[7], f[8])
          print rows[i], disp
        }
      }'
}

kill_target() {
  local kind="$1" target="$2" event_q
  event_q="$(printf '%q' "$DIR/event.sh")"
  case "$kind" in
  session)
    if tmux kill-session -t "$target" 2>/dev/null; then
      tmux run-shell -b "$event_q exited-session $(printf '%q' "$target")" 2>/dev/null || true
    fi
    ;;
  pane)
    # Ctrl-C interrupts the current turn; it does not prove the long-lived CLI
    # exited, so keep daemon state and Claude polling active.
    tmux send-keys -t "$target" C-c 2>/dev/null
    ;;
  esac
}

open_session_target() {
  local target="$1" origin parent
  # Move the underlying parent client to the session's origin window (best-effort),
  # then resume the session in THIS popup over it. Falls back to resuming over the
  # current window when origin/parent are unknown.
  origin=$(tmux show-options -qv -t "$target" @agent_origin 2>/dev/null)
  parent="${parent_client:-}"
  [ -n "$parent" ] || parent=$(tmux show-options -gqv @agent_parent 2>/dev/null)
  [ -n "$origin" ] && [ -n "$parent" ] &&
    tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

  # Opening a completed session marks it as seen.
  mark_managed_session_seen_if_done "$target"

  tmux attach-session -t "$target"
}

open_pane_target() {
  local target="$1" parent
  # Opening a completed manual pane marks it as seen.
  mark_pane_seen_if_done "$target"

  parent="${parent_client:-}"
  [ -n "$parent" ] || parent=$(tmux show-options -gqv @agent_parent 2>/dev/null)
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$target" 2>/dev/null || tmux switch-client -t "$target"
  else
    tmux switch-client -t "$target"
  fi
}

open_target() {
  local kind="$1" target="$2"
  case "$kind" in
  session) open_session_target "$target" ;;
  pane)    open_pane_target "$target" ;;
  esac
}

[ "${1:-}" = '--list' ] && {
  emit_rows
  exit $?
}

[ "${1:-}" = '--kill' ] && {
  kill_target "${2:-}" "${3:-}"
  exit 0
}

parent_client="${1:-}"

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-agents-session-manager: fzf is required for the picker"
  exit 0
fi

self="${BASH_SOURCE[0]}"
self_cmd=$(printf '%q' "$self")
export FZF_DEFAULT_OPTS=''
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=10 \
  --reverse --cycle --header='Agent sessions/panes · enter: jump · ctrl-x: kill/interrupt' \
  --preview="tmux capture-pane -ept {3}" --preview-window='right,62%,wrap' \
  --bind="ctrl-x:execute-silent($self_cmd --kill {2} {3})+reload($self_cmd --list)")

[ -z "$sel" ] && exit 0
kind=$(printf '%s' "$sel" | cut -f2)
target=$(printf '%s' "$sel" | cut -f3)

open_target "$kind" "$target"
