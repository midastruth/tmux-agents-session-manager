#!/usr/bin/env bash
# Shared tmux/ps mocks for the test suite. Source this file, then call
# install_tmux_mock <bindir> to write executable `tmux` and `ps` mocks there.
#
# The tmux mock is driven entirely by environment variables:
#   TMUX_MOCK_LOG              append every invocation (tab-separated) to file
#   TMUX_MOCK_OPTIONS          "key=value" lines for global show-option
#   TMUX_MOCK_TARGET_OPTIONS   "target|key=value" lines for -t show-option(s)
#   TMUX_MOCK_STATUS_OPTIONS   output for display-message with -F
#   TMUX_MOCK_LIST_SESSIONS    output for list-sessions
#   TMUX_MOCK_LIST_PANES       output for list-panes (single fixture)
#   TMUX_MOCK_LIST_PANES_PICKER / TMUX_MOCK_LIST_PANES_STATUS
#                              alternative per-caller fixtures: when either is
#                              set, list-panes returns the PICKER fixture for
#                              formats containing pane_current_command and the
#                              STATUS fixture otherwise
#   TMUX_MOCK_LIST_CLIENTS     output for list-clients
#   TMUX_MOCK_HAS_SESSION      "yes" to make has-session succeed
#   TMUX_MOCK_CURRENT_SESSION  session name for '#S' display-message formats
#   TMUX_MOCK_PANE_SESSION     session name for '#{session_name}' formats
#   TMUX_MOCK_PANE_VISIBLE     output for '#{session_attached}' formats
#   TMUX_MOCK_FAIL_TARGETS     space-separated targets whose -t queries fail
#   TMUX_MOCK_FAIL_REFRESH_CLIENT
#                              non-empty makes refresh-client fail
#
# The ps mock is driven by:
#   TMUX_MOCK_PS_CHILDREN      "ppid=pid pid..." lines
#   TMUX_MOCK_PS_COMM          "pid=comm" lines

install_tmux_mock() {
  local bin="$1"
  mkdir -p "$bin"

  cat >"$bin/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -u

log() {
  [ -n "${TMUX_MOCK_LOG:-}" ] || return 0
  {
    printf '%s' "${1:-}"
    shift || true
    for arg in "$@"; do
      printf '\t%s' "$arg"
    done
    printf '\n'
  } >>"$TMUX_MOCK_LOG"
}

kv_get() {
  local key="$1" line k v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [ "$k" = "$key" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "${TMUX_MOCK_OPTIONS:-}"
  return 1
}

target_kv_get() {
  local target="$1" opt="$2" line k v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [ "$k" = "$target|$opt" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "${TMUX_MOCK_TARGET_OPTIONS:-}"
  return 1
}

last_arg() {
  local x last=''
  for x in "$@"; do last="$x"; done
  printf '%s' "$last"
}

target_arg() {
  local prev='' x
  for x in "$@"; do
    if [ "$prev" = '-t' ]; then
      printf '%s' "$x"
      return 0
    fi
    prev="$x"
  done
  return 1
}

target_should_fail() {
  local target="$1"
  [ -n "$target" ] || return 1
  case " ${TMUX_MOCK_FAIL_TARGETS:-} " in
  *" $target "*) return 0 ;;
  *) return 1 ;;
  esac
}

show_option() {
  local opt target value x value_only=no quiet=no
  opt="$(last_arg "$@")"
  target="$(target_arg "$@" || true)"
  for x in "$@"; do
    case "$x" in
    -*v*) value_only=yes ;;
    -*q*) quiet=yes ;;
    esac
  done
  if target_should_fail "$target"; then
    [ "$quiet" = yes ] && return 0
    return 1
  fi
  if [ -n "$target" ] && [[ "$opt" != @* ]]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      k="${line%%=*}"
      value="${line#*=}"
      case "$k" in
      "$target|"@*) printf '%s %s\n' "${k#"$target|"}" "$value" ;;
      esac
    done <<< "${TMUX_MOCK_TARGET_OPTIONS:-}"
    return 0
  fi
  if [ -n "$target" ]; then
    value="$(target_kv_get "$target" "$opt" || true)"
  else
    value="$(kv_get "$opt" || true)"
  fi
  [ -n "$value" ] || return 0
  if [ "$value_only" = yes ]; then
    printf '%s' "$value"
  else
    printf '%s %s' "$opt" "$value"
  fi
}

run_group() {
  local group_cmd="$1" joined target
  shift || true
  case "$group_cmd" in
    show-option|show-options)
      show_option "$@"
      ;;
    display-message)
      joined=" $* "
      target="$(target_arg "$@" || true)"
      if target_should_fail "$target"; then
        return 1
      fi
      if [[ "$joined" == *' -F '* ]]; then
        printf '%s' "${TMUX_MOCK_STATUS_OPTIONS:-}"
      elif [[ "$joined" == *'#{session_attached}'* ]]; then
        printf '%s' "${TMUX_MOCK_PANE_VISIBLE:-0 0 0}"
      elif [[ "$joined" == *'#{session_name}'* ]]; then
        printf '%s' "${TMUX_MOCK_PANE_SESSION:-${TMUX_MOCK_CURRENT_SESSION:-}}"
      elif [[ "$joined" == *'#S'* ]]; then
        printf '%s' "${TMUX_MOCK_CURRENT_SESSION:-}"
      else
        last_arg "$@"
      fi
      ;;
  esac
}

run_chain() {
  local -a group=()
  local arg first=yes status=0
  for arg in "$@"; do
    if [ "$arg" = ';' ]; then
      if [ "${#group[@]}" -gt 0 ]; then
        [ "$first" = no ] && printf '\n'
        run_group "${group[@]}" || status=$?
        first=no
      fi
      group=()
    else
      group+=("$arg")
    fi
  done
  if [ "${#group[@]}" -gt 0 ]; then
    [ "$first" = no ] && printf '\n'
    run_group "${group[@]}" || status=$?
  fi
  return "$status"
}

emit_list_panes() {
  local data="$1" joined="$2" line f1 f2 rest
  [ -n "$data" ] || return 0
  if [[ "$joined" == *'#{pane_id}'* ]] &&
    [[ "$joined" != *'#{session_name}'* ]] &&
    [[ "$joined" != *pane_current_command* ]]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=$'\t' read -r f1 f2 rest <<< "$line"
      printf '%s\n' "${f2:-$f1}"
    done <<< "$data"
  else
    printf '%s\n' "$data"
  fi
}

cmd="${1:-}"
shift || true
log "$cmd" "$@"

case "$cmd" in
  show-option|show-options|display-message)
    run_chain "$cmd" "$@"
    ;;
  list-sessions)
    [ -n "${TMUX_MOCK_LIST_SESSIONS:-}" ] && printf '%s\n' "$TMUX_MOCK_LIST_SESSIONS"
    exit 0
    ;;
  list-panes)
    joined=" $* "
    if [ -n "${TMUX_MOCK_LIST_PANES_PICKER:-}" ] || [ -n "${TMUX_MOCK_LIST_PANES_STATUS:-}" ]; then
      if [[ "$joined" == *pane_current_command* ]]; then
        emit_list_panes "${TMUX_MOCK_LIST_PANES_PICKER:-}" "$joined"
      else
        emit_list_panes "${TMUX_MOCK_LIST_PANES_STATUS:-}" "$joined"
      fi
    else
      emit_list_panes "${TMUX_MOCK_LIST_PANES:-}" "$joined"
    fi
    ;;
  list-clients)
    printf '%s' "${TMUX_MOCK_LIST_CLIENTS:-}"
    ;;
  has-session)
    [ "${TMUX_MOCK_HAS_SESSION:-no}" = yes ]
    ;;
  refresh-client)
    [ -z "${TMUX_MOCK_FAIL_REFRESH_CLIENT:-}" ]
    ;;
  new-session|set-option|display-popup|kill-session|send-keys|attach-session|switch-client|detach-client)
    exit 0
    ;;
  run-shell)
    # Ignore backgrounded refreshes (`run-shell -b .../status.sh --refresh`).
    # Running them would recurse into status.sh during unrelated tests; the log
    # entry above is enough to assert the trigger fired.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
TMUX_MOCK
  chmod +x "$bin/tmux"

  cat >"$bin/ps" <<'PS_MOCK'
#!/usr/bin/env bash
set -u

kv_get() {
  local data="$1" key="$2" line k v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [ "$k" = "$key" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "$data"
  return 1
}

# Portable full-table form used by resolve_pane_agent:
#   ps -axo pid=,ppid=,comm=   (BSD/macOS)
#   ps -eo  pid=,ppid=,comm=   (GNU/Linux fallback)
# Reconstruct the table from the parent/child and comm fixtures so the same
# mock data drives both the old per-parent form and this snapshot form.
if { [ "${1:-}" = '-axo' ] || [ "${1:-}" = '-eo' ]; } &&
  [ "${2:-}" = 'pid=,ppid=,comm=' ]; then
  line=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    parent="${line%%=*}"
    kids="${line#*=}"
    for child in $kids; do
      comm="$(kv_get "${TMUX_MOCK_PS_COMM:-}" "$child" || true)"
      printf '%s %s %s\n' "$child" "$parent" "$comm"
    done
  done <<< "${TMUX_MOCK_PS_CHILDREN:-}"
  exit 0
fi

if [ "${1:-}" = '-o' ] && [ "${2:-}" = 'pid=' ] && [ "${3:-}" = '--ppid' ]; then
  children="$(kv_get "${TMUX_MOCK_PS_CHILDREN:-}" "${4:-}" || true)"
  for child in $children; do
    printf '%s\n' "$child"
  done
  exit 0
fi

if [ "${1:-}" = '-o' ] && [ "${2:-}" = 'comm=' ] && [ "${3:-}" = '-p' ]; then
  kv_get "${TMUX_MOCK_PS_COMM:-}" "${4:-}" || true
  exit 0
fi

exit 0
PS_MOCK
  chmod +x "$bin/ps"
}
