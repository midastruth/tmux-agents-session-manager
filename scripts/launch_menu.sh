#!/usr/bin/env bash
# Choose which agent to launch for the current directory, then hand off to
# launch.sh. With a single configured agent (or @agent_launch_menu off)
# it skips the menu and launches directly, preserving the original prefix+y behaviour.
# Args: [--select <output-file>] <dir> [origin-window-id]
#   <dir> / [origin-window-id] are expanded by run-shell in the binding.

# macOS still ships bash 3.2 as /bin/bash, which lacks features this menu relies
# on (notably `read -t` with fractional seconds for arrow keys). If we're running
# under an old bash, re-exec with a newer one from PATH (e.g. Homebrew bash).
if [ -z "${AGENT_MENU_REEXEC:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  for _bash in /opt/homebrew/bin/bash /usr/local/bin/bash bash; do
    _bin="$(command -v "$_bash" 2>/dev/null)" || continue
    # shellcheck disable=SC2016 # expansion must happen in the re-exec'd bash
    _ver="$("$_bin" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
    if [ "${_ver:-0}" -ge 4 ] 2>/dev/null; then
      export AGENT_MENU_REEXEC=1
      exec "$_bin" "${BASH_SOURCE[0]}" "$@"
    fi
  done
fi

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

select_out=''
if [ "${1:-}" = '--select' ]; then
  select_out="${2:-}"
  shift 2
fi

path="${1:-$PWD}"
window="${2:-}"
default_cmd="pi -e '$ROOT/extensions/tmux-state.ts'"

# Collect configured agent names. Avoid bash 4's `mapfile` so this keeps working
# on macOS's default /bin/bash 3.2.
names=()
while IFS= read -r _name; do
  [ -n "$_name" ] && names+=("$_name")
done < <(agent_names "$default_cmd")

show_menu="$(get_tmux_option @agent_launch_menu 'on')"

# A single configured agent: launch it directly because there is nothing to
# choose. Menu disabled with multiple agents: keep the default launch path.
if [ -z "$select_out" ]; then
  if [ "${#names[@]}" -le 1 ]; then
    if [ "${#names[@]}" -eq 1 ]; then
      exec "$DIR/launch.sh" "$path" "$window" "${names[0]}"
    fi
    exec "$DIR/launch.sh" "$path" "$window"
  fi
  if [ "$show_menu" != on ]; then
    exec "$DIR/launch.sh" "$path" "$window"
  fi
fi

repeat_char() {
  local char="$1" count="$2" out=''
  while [ "$count" -gt 0 ]; do
    out="$out$char"
    count=$((count - 1))
  done
  printf '%s' "$out"
}

render_menu() {
  local selected="$1" i label title label_width inner_width title_width pad_right
  local top bottom line
  title=' Launch agent '
  label_width=0
  for i in "${!names[@]}"; do
    label=$(printf '%-8s (%d)' "${names[$i]}" "$((i + 1))")
    [ "${#label}" -gt "$label_width" ] && label_width=${#label}
  done
  title_width=${#title}
  inner_width=$((label_width + 2))
  [ "$inner_width" -lt "$title_width" ] && inner_width=$title_width

  pad_right=$((inner_width - title_width))
  top="┌${title}$(repeat_char '─' "$pad_right")┐"
  bottom="└$(repeat_char '─' "$inner_width")┘"

  printf '\033[2J\033[H\033[?25l'
  printf '%s\n' "$top"
  for i in "${!names[@]}"; do
    label=$(printf '%-8s (%d)' "${names[$i]}" "$((i + 1))")
    line=$(printf ' %-*s ' "$label_width" "$label")
    # If the title forced the menu wider than the labels, pad the entry too.
    line=$(printf '%-*s' "$inner_width" "$line")
    if [ "$i" -eq "$selected" ]; then
      printf '│\033[7m%s\033[0m│\n' "$line"
    else
      printf '│%s│\n' "$line"
    fi
  done
  printf '%s' "$bottom"
}

select_agent() {
  local selected=0 count key rest idx
  count=${#names[@]}
  [ "$count" -gt 0 ] || exit 0
  [ -n "$select_out" ] || exit 0

  while :; do
    render_menu "$selected"
    IFS= read -rsn1 key || exit 0
    case "$key" in
    $'\x0e') selected=$(((selected + 1) % count)) ;;         # Ctrl+n
    $'\x10') selected=$(((selected + count - 1) % count)) ;; # Ctrl+p
    ''|$'\r'|$'\n') # Empty: terminal ICRNL turned Enter's \r into \n, read's
                    # delimiter, so read returns success with an empty key.
      printf '%s' "${names[$selected]}" >"$select_out"; exit 0 ;;
    q|Q) exit 0 ;;
    $'\x1b')
      # Support arrows as the native tmux menu does; a bare Esc cancels.
      rest=''
      IFS= read -rsn2 -t 0.03 rest || true
      case "$rest" in
      '[B') selected=$(((selected + 1) % count)) ;;         # Down
      '[A') selected=$(((selected + count - 1) % count)) ;; # Up
      *) exit 0 ;;
      esac
      ;;
    [1-9])
      idx=$((key - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "$count" ]; then
        printf '%s' "${names[$idx]}" >"$select_out"
        exit 0
      fi
      ;;
    esac
  done
}

if [ -n "$select_out" ]; then
  trap 'printf "\033[?25h"' EXIT
  select_agent
fi

# Native tmux display-menu only supports Enter/Up/Down/q plus item shortcut
# keys; it cannot bind Ctrl+n/Ctrl+p for movement. Use a borderless popup that
# draws the same compact menu shape, then launch the selected agent after the
# selector exits so the agent still opens in the normal full-size popup.
tmp="$(mktemp "${TMPDIR:-/tmp}/agent-launch.XXXXXX")" || exit 0
trap 'rm -f "$tmp"' EXIT

label_width=0
for i in "${!names[@]}"; do
  label=$(printf '%-8s (%d)' "${names[$i]}" "$((i + 1))")
  [ "${#label}" -gt "$label_width" ] && label_width=${#label}
done
inner_width=$((label_width + 2))
[ "$inner_width" -lt 14 ] && inner_width=14
w=$((inner_width + 2))
h=$((${#names[@]} + 2))

self_q=$(printf '%q' "$DIR/launch_menu.sh")
tmp_q=$(printf '%q' "$tmp")
path_q=$(printf '%q' "$path")
window_q=$(printf '%q' "$window")

tmux display-popup -B -w "$w" -h "$h" -E "$self_q --select $tmp_q $path_q $window_q"

agent=''
[ -s "$tmp" ] && agent="$(<"$tmp")"
[ -n "$agent" ] || exit 0
exec "$DIR/launch.sh" "$path" "$window" "$agent"
