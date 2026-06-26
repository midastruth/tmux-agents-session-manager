#!/usr/bin/env bash
# Interactive picker for running Pi sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       chosen session's origin window and resumes it in the popup.
#                       Manually-started `pi` panes are also listed and jumped to.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @pi_session_prefix 'pi-')"

short_path() {
  printf '%s' "${1/#$HOME/~}"
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
  local now s state at path name rank label desc ago
  now=$(date +%s)
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r s; do
    [[ "$s" == "$prefix"* ]] || continue
    state=$(tmux show-options -qv -t "$s" @pi_state 2>/dev/null)
    at=$(tmux show-options -qv -t "$s" @pi_state_at 2>/dev/null)
    path=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)
    name=${path##*/}
    split_classify "$state"
    if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
    # rank \t kind \t target \t label \t name \t age \t path \t desc
    printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rank" "$s" "$label" "$name" "$ago" "$(short_path "$path")" "$desc"
  done
}

emit_manual_rows() {
  local now s pane cmd path base name state at rank label desc ago
  now=$(date +%s)
  tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_current_command}	#{pane_current_path}' 2>/dev/null |
    while IFS=$'\t' read -r s pane cmd path; do
      # Prefixed sessions are already listed as managed Pi sessions.
      [[ "$s" == "$prefix"* ]] && continue
      base="${cmd##*/}"
      [ "$base" = pi ] || continue
      name=${path##*/}
      # Per-pane state, written by the extension/state.sh when loaded. Falls back
      # to a plain "manual" marker when no status extension is attached.
      state=$(tmux show-options -pqv -t "$pane" @pi_state 2>/dev/null)
      at=$(tmux show-options -pqv -t "$pane" @pi_state_at 2>/dev/null)
      if [ -n "$state" ]; then
        split_classify "$state"
      else
        rank=2; label='🟣 manual '; desc='pane running pi'
      fi
      if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
      printf '%s\tpane\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$pane" "$label" "$name" "$ago" "$(short_path "$path")" "$desc"
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
    # Append a pre-aligned display column (field 9). Two passes: first find the
    # widest project name, then pad every name to that width so the age and path
    # columns line up. Logic fields 1-8 stay untouched for enter/ctrl-x.
    awk 'BEGIN { FS = OFS = "\t" }
      { rows[NR] = $0; if (length($5) > w) w = length($5) }
      END {
        for (i = 1; i <= NR; i++) {
          split(rows[i], f, "\t")
          disp = sprintf("%s  %-*s  %4s  %s — %s", f[4], w, f[5], f[6], f[7], f[8])
          print rows[i], disp
        }
      }'
}

[ "${1:-}" = '--list' ] && {
  emit_rows
  exit 0
}

[ "${1:-}" = '--kill' ] && {
  kind="${2:-}"
  target="${3:-}"
  case "$kind" in
  session) tmux kill-session -t "$target" 2>/dev/null ;;
  pane)    tmux send-keys -t "$target" C-c 2>/dev/null ;;
  esac
  exit 0
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-pi-session-manager: fzf is required for the picker"
  exit 0
fi

self="${BASH_SOURCE[0]}"
self_cmd=$(printf '%q' "$self")
export FZF_DEFAULT_OPTS=''
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=9 \
  --reverse --cycle --header='Pi sessions/panes · enter: jump · ctrl-x: kill/interrupt' \
  --preview="tmux capture-pane -ept {3}" --preview-window='right,62%,wrap' \
  --bind="ctrl-x:execute-silent($self_cmd --kill {2} {3})+reload($self_cmd --list)")

[ -z "$sel" ] && exit 0
kind=$(printf '%s' "$sel" | cut -f2)
target=$(printf '%s' "$sel" | cut -f3)

case "$kind" in
session)
  # Move the underlying parent client to the session's origin window (best-effort),
  # then resume the session in THIS popup over it. Falls back to resuming over the
  # current window when origin/parent are unknown.
  origin=$(tmux show-options -qv -t "$target" @pi_origin 2>/dev/null)
  parent=$(tmux show-options -gqv @pi_parent 2>/dev/null)
  [ -n "$origin" ] && [ -n "$parent" ] &&
    tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

  # Opening a completed session marks it as seen.
  if [ "$(tmux show-options -qv -t "$target" @pi_state 2>/dev/null)" = done ]; then
    tmux set-option -t "$target" @pi_state idle
    tmux set-option -t "$target" @pi_state_at "$(date +%s)"
  fi

  tmux attach-session -t "$target"
  ;;
pane)
  # Opening a completed manual pane marks it as seen.
  if [ "$(tmux show-options -pqv -t "$target" @pi_state 2>/dev/null)" = done ]; then
    tmux set-option -p -t "$target" @pi_state idle
    tmux set-option -p -t "$target" @pi_state_at "$(date +%s)"
  fi

  parent=$(tmux show-options -gqv @pi_parent 2>/dev/null)
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$target" 2>/dev/null || tmux switch-client -t "$target"
  else
    tmux switch-client -t "$target"
  fi
  ;;
esac
