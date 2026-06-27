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

short_path() {
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
  local now s state at path cmd tool name rank label desc ago
  now=$(date +%s)
  tmux list-sessions -F '#{session_name}	#{@agent_state}	#{@agent_state_at}	#{pane_current_path}	#{@agent_tool}	#{pane_current_command}' 2>/dev/null |
    while IFS=$'\t' read -r s state at path tool cmd; do
      is_managed_session "$s" || continue
      name=${path##*/}
      # The agent recorded at launch, falling back to whatever runs in the pane.
      [ -n "$tool" ] || tool=${cmd##*/}
      split_classify "$state"
      if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
      # rank \t kind \t target \t label \t name \t age \t path \t desc \t tool
      printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$s" "$label" "$name" "$ago" "$(short_path "$path")" "$desc" "$tool"
    done
}

emit_manual_rows() {
  local now s pane cmd ppid path state at opts base name rank label desc ago
  now=$(date +%s)
  tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_current_command}	#{pane_pid}	#{pane_current_path}' 2>/dev/null |
    while IFS=$'\t' read -r s pane cmd ppid path; do
      # Managed sessions are already listed as managed agent sessions.
      is_managed_session "$s" && continue
      # Resolve the agent name, including wrappers (codex runs under node) by
      # walking the pane's process subtree only for known wrapper commands.
      # Empty -> not an agent pane.
      base="$(resolve_pane_agent "${cmd##*/}" "$ppid")" || continue
      [ -n "$base" ] || continue
      name=${path##*/}
      # Per-pane state, written by the extension/state.sh when loaded. Falls back
      # to a plain "manual" marker when no status extension is attached.
      opts="$(tmux show-options -pqv -t "$pane" @agent_state \
        \; show-options -pqv -t "$pane" @agent_state_at)" || exit $?
      state=${opts%%$'\n'*}
      at=${opts#*$'\n'}
      [ "$at" = "$opts" ] && at=''
      if [ -n "$state" ]; then
        split_classify "$state"
      else
        rank=2; label='🟣 manual '; desc="pane running $base"
      fi
      if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
      printf '%s\tpane\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$pane" "$label" "$name" "$ago" "$(short_path "$path")" "$desc" "$base"
    done
}

emit_rows() {
  {
    emit_managed_rows
    emit_manual_rows
    # rank asc (attention-needed floats up), then age asc so the session that
    # finished just now sits at the top of its group. -k6,6n reads the leading
    # number of the age field ("5m" -> 5; "-" -> 0).
  } | sort -t$'\t' -k1,1n -k6,6n |
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
  local kind="$1" target="$2"
  case "$kind" in
  session) tmux kill-session -t "$target" 2>/dev/null ;;
  pane)    tmux send-keys -t "$target" C-c 2>/dev/null ;;
  esac
}

open_session_target() {
  local target="$1" origin parent
  # Move the underlying parent client to the session's origin window (best-effort),
  # then resume the session in THIS popup over it. Falls back to resuming over the
  # current window when origin/parent are unknown.
  origin=$(tmux show-options -qv -t "$target" @agent_origin 2>/dev/null)
  parent=$(tmux show-options -gqv @agent_parent 2>/dev/null)
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

  parent=$(tmux show-options -gqv @agent_parent 2>/dev/null)
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
  exit 0
}

[ "${1:-}" = '--kill' ] && {
  kill_target "${2:-}" "${3:-}"
  exit 0
}

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
