#!/usr/bin/env bash
# Shared helpers for tmux-agents-session-manager.

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

# detect_commands
# Space-separated list of agent commands the picker/status line auto-detect when
# they are running directly in a tmux pane (manual, non-managed sessions).
# Override with: set -g @pi_detect_commands 'pi codex claude aider'
detect_commands() {
  get_tmux_option @pi_detect_commands 'pi codex claude'
}

# is_detected_command <command-basename>
# Succeeds when <command-basename> is in the detect_commands list.
is_detected_command() {
  case " $(detect_commands) " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# resolve_pane_agent <pane-current-command> <pane-pid>
# Prints the detected agent name for a pane, or nothing if none matches.
#
# Some agents (e.g. codex) ship as a Node wrapper that spawns a native binary,
# so tmux's pane_current_command reports the wrapper ("node") rather than the
# agent. When the foreground command itself is not a known agent, walk the
# descendants of <pane-pid> and return the first child whose comm matches the
# detect list. This makes codex discoverable while keeping bare commands fast.
resolve_pane_agent() {
  local cmd="$1" pid="$2"
  if is_detected_command "$cmd"; then
    printf '%s' "$cmd"
    return 0
  fi
  [ -n "$pid" ] || return 1
  # ps may be unavailable in minimal environments; fail quietly if so.
  command -v ps >/dev/null 2>&1 || return 1
  # Breadth-first walk of the process subtree rooted at $pid.
  local queue="$pid" current children child comm
  while [ -n "$queue" ]; do
    current="${queue%% *}"
    case "$queue" in
    *" "*) queue="${queue#* }" ;;
    *) queue="" ;;
    esac
    children=$(ps -o pid= --ppid "$current" 2>/dev/null | tr '\n' ' ')
    for child in $children; do
      comm=$(ps -o comm= -p "$child" 2>/dev/null)
      comm="${comm##*/}"
      if is_detected_command "$comm"; then
        printf '%s' "$comm"
        return 0
      fi
      queue="$queue $child"
    done
  done
  return 1
}

# agents_config
# Newline-separated "name=command" registry of launchable agents. The default
# wires pi to the bundled status extension; codex and claude run bare. Override
# the whole list with @pi_agents, or just pi's command with @pi_command.
#   set -g @pi_agents 'pi=pi -e /path/ext.ts\ncodex=codex\nclaude=claude --foo'
# <pi-default-command> is substituted for the pi entry's command when @pi_agents
# is unset, so callers pass the extension-aware default in.
agents_config() {
  local pi_default="$1"
  local configured
  configured="$(get_tmux_option @pi_agents '')"
  if [ -n "$configured" ]; then
    printf '%b' "$configured"
    return
  fi
  printf '%s\n' "pi=$pi_default" "codex=codex" "claude=claude"
}

# agent_command <name> <pi-default-command>
# Prints the command line registered for <name>, or nothing if unknown.
agent_command() {
  local name="$1" pi_default="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
    "$name="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <<EOF
$(agents_config "$pi_default")
EOF
  return 1
}

# agent_names <pi-default-command>
# Prints the registered agent names, one per line.
agent_names() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "${line%%=*}"
  done <<EOF
$(agents_config "$1")
EOF
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  printf '%s' "${out%% *}" | cut -c1-8
}
