#!/usr/bin/env bash
# Choose which agent to launch for the current directory, then hand off to
# launch.sh. With a single configured agent (or @pi_launch_menu off) it skips
# the menu and launches directly, preserving the original prefix+y behaviour.
# Args: <dir> [origin-window-id]   (expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"
default_cmd="pi -e '$ROOT/extensions/tmux-state.ts'"

# Collect configured agent names.
mapfile -t names < <(agent_names "$default_cmd")

show_menu="$(get_tmux_option @pi_launch_menu 'on')"

# Zero or one agent, or menu disabled: launch the default path directly.
if [ "$show_menu" != on ] || [ "${#names[@]}" -le 1 ]; then
  exec "$DIR/launch.sh" "$path" "$window"
fi

# Build a tmux display-menu: one numbered entry per agent that re-invokes
# launch.sh with the chosen agent name.
menu_args=()
i=1
for name in "${names[@]}"; do
  menu_args+=("$name" "$i" "run-shell \"$DIR/launch.sh '$path' '$window' '$name'\"")
  i=$((i + 1))
done

tmux display-menu -T ' Launch agent ' "${menu_args[@]}"
