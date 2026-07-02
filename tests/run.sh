#!/usr/bin/env bash
# Lightweight unit tests for tmux-agents-session-manager.
# No external test framework is required; run with: bash tests/run.sh
set -u
# Most tests configure the tmux mock through environment variables. Export new
# assignments by default so subprocesses under run_bash see them.
set -a

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-agents-tests.$$"
MOCK_BIN="$TMP_ROOT/bin"
TMUX_LOG="$TMP_ROOT/tmux.log"
mkdir -p "$MOCK_BIN"
: >"$TMUX_LOG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat >"$MOCK_BIN/tmux" <<'TMUX_MOCK'
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

show_option() {
  local opt target value x value_only=no
  opt="$(last_arg "$@")"
  target="$(target_arg "$@" || true)"
  for x in "$@"; do
    case "$x" in
    -*v*) value_only=yes ;;
    esac
  done
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
  local group_cmd="$1" joined
  shift || true
  case "$group_cmd" in
    show-option|show-options)
      show_option "$@"
      ;;
    display-message)
      joined=" $* "
      if [[ "$joined" == *' -F '* ]]; then
        printf '%s' "${TMUX_MOCK_STATUS_OPTIONS:-}"
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
  local arg first=yes
  for arg in "$@"; do
    if [ "$arg" = ';' ]; then
      if [ "${#group[@]}" -gt 0 ]; then
        [ "$first" = no ] && printf '\n'
        run_group "${group[@]}"
        first=no
      fi
      group=()
    else
      group+=("$arg")
    fi
  done
  if [ "${#group[@]}" -gt 0 ]; then
    [ "$first" = no ] && printf '\n'
    run_group "${group[@]}"
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
    ;;
  list-panes)
    [ -n "${TMUX_MOCK_LIST_PANES:-}" ] && printf '%s\n' "$TMUX_MOCK_LIST_PANES"
    ;;
  list-clients)
    printf '%s' "${TMUX_MOCK_LIST_CLIENTS:-}"
    ;;
  has-session)
    [ "${TMUX_MOCK_HAS_SESSION:-no}" = yes ]
    ;;
  new-session|set-option|display-popup|kill-session|send-keys|attach-session|switch-client|detach-client)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
TMUX_MOCK
chmod +x "$MOCK_BIN/tmux"

cat >"$MOCK_BIN/ps" <<'PS_MOCK'
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
chmod +x "$MOCK_BIN/ps"

export PATH="$MOCK_BIN:$PATH"
export TMUX_MOCK_LOG="$TMUX_LOG"

PASS=0
FAIL=0

reset_mocks() {
  : >"$TMUX_LOG"
  unset TMUX_MOCK_OPTIONS TMUX_MOCK_TARGET_OPTIONS TMUX_MOCK_STATUS_OPTIONS \
    TMUX_MOCK_LIST_SESSIONS TMUX_MOCK_LIST_PANES TMUX_MOCK_LIST_CLIENTS \
    TMUX_MOCK_HAS_SESSION TMUX_MOCK_CURRENT_SESSION TMUX_MOCK_PANE_SESSION \
    TMUX_MOCK_PS_CHILDREN TMUX_MOCK_PS_COMM \
    AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS TMUX_PANE
}

pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
  [ "$#" -gt 1 ] && printf '  %s\n' "$2" >&2
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected: [$expected], actual: [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "missing: [$needle] in [$haystack]"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "unexpected: [$needle] in [$haystack]"
  fi
}

run_bash() {
  (cd "$ROOT" && bash -c "$1")
}

status_options() {
  local us=$'\037'
  local prefix="${1:-agent-}"
  local animate="${2:-off}"
  local color="${3:-off}"
  local show_idle="${4:-off}"
  local ttl="${5:-21600}"
  printf '%s' "${prefix}${us}✦${us}✓${us}●${us}·${us}agents${us}${animate}${us}✦ ✶ ✷ ✶${us}yellow${us}cyan${us}red${us}green${us}${color}${us}${show_idle}${us}${ttl}"
}

# helpers.sh
reset_mocks
TMUX_MOCK_OPTIONS=$'@foo=bar'
out="$(run_bash '. scripts/helpers.sh; get_tmux_option @foo default')"
assert_eq 'get_tmux_option reads tmux value' 'bar' "$out"

reset_mocks
out="$(run_bash '. scripts/helpers.sh; get_tmux_option @missing default')"
assert_eq 'get_tmux_option returns default when unset' 'default' "$out"

reset_mocks
out="$(run_bash 'AGENT_SESSION_PREFIX=bot-; . scripts/helpers.sh; agent_session_prefix')"
assert_eq 'agent_session_prefix prefers environment override' 'bot-' "$out"

reset_mocks
run_bash 'AGENT_SESSION_PREFIX=bot-; . scripts/helpers.sh; is_managed_session bot-123' >/dev/null
assert_eq 'is_managed_session accepts configured prefix' '0' "$?"
run_bash 'AGENT_SESSION_PREFIX=bot-; . scripts/helpers.sh; is_managed_session agent-123' >/dev/null
assert_eq 'is_managed_session rejects other prefix' '1' "$?"

reset_mocks
out="$(run_bash 'AGENT_DETECT_COMMANDS="pi aider"; . scripts/helpers.sh; is_detected_command aider && printf yes')"
assert_eq 'is_detected_command uses environment command list' 'yes' "$out"

reset_mocks
out="$(run_bash '. scripts/helpers.sh; agents_config "pi --ext"')"
assert_eq 'agents_config defaults include pi/codex/claude' $'pi=pi --ext\ncodex=codex\nclaude=claude' "$out"

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_agents=foo=foo --bar\\nbar=bar --baz'
out="$(run_bash '. scripts/helpers.sh; agent_command bar "pi"')"
assert_eq 'agent_command reads configured registry' 'bar --baz' "$out"
run_bash '. scripts/helpers.sh; agent_command nope "pi"' >/dev/null
assert_eq 'agent_command fails for unknown agent' '1' "$?"
out="$(run_bash '. scripts/helpers.sh; agent_names "pi"')"
assert_eq 'agent_names reads configured registry' $'foo\nbar' "$out"

reset_mocks
out="$(run_bash '. scripts/helpers.sh; session_hash /tmp/project')"
assert_eq 'session_hash is stable and 8 chars' '6533d8b9' "$out"

reset_mocks
out="$(run_bash 'AGENT_DETECT_COMMANDS="pi codex"; . scripts/helpers.sh; resolve_pane_agent codex 123')"
assert_eq 'resolve_pane_agent returns direct detected command' 'codex' "$out"

reset_mocks
AGENT_DETECT_COMMANDS='pi codex'
AGENT_DETECT_WRAPPERS='node'
TMUX_MOCK_PS_CHILDREN=$'123=456\n456=789'
TMUX_MOCK_PS_COMM=$'456=bash\n789=codex'
out="$(run_bash '. scripts/helpers.sh; resolve_pane_agent node 123')"
assert_eq 'resolve_pane_agent finds child agent for configured wrapper' 'codex' "$out"

# tmux may report the wrapper basename ("node") while the pane root process has
# renamed itself in place to the real agent ("pi"). The root pid's own comm must
# be detected even when it has no matching descendant.
reset_mocks
AGENT_DETECT_COMMANDS='pi codex'
AGENT_DETECT_WRAPPERS='node'
TMUX_MOCK_PS_CHILDREN=$'0=123'
TMUX_MOCK_PS_COMM=$'123=pi'
out="$(run_bash '. scripts/helpers.sh; resolve_pane_agent node 123')"
assert_eq 'resolve_pane_agent detects renamed-in-place root process' 'pi' "$out"

reset_mocks
TMUX_MOCK_TARGET_OPTIONS=$'%7|@agent_state=done'
run_bash '. scripts/helpers.sh; mark_pane_seen_if_done %7' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'mark_pane_seen_if_done sets pane state to idle' "$log_contents" $'set-option\t-p\t-t\t%7\t@agent_state\tidle'

reset_mocks
TMUX_MOCK_TARGET_OPTIONS=$'%7|@agent_state=working'
run_bash '. scripts/helpers.sh; mark_pane_seen_if_done %7' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'mark_pane_seen_if_done leaves non-done pane unchanged' "$log_contents" $'set-option\t-p\t-t\t%7\t@agent_state\tidle'

# status.sh
reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
out="$(run_bash 'scripts/status.sh --or fallback')"
assert_eq 'status.sh prints fallback with no states' 'fallback' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tworking\nagent-b\tdone\nwork\tblocked'
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh counts managed session states only' 'agents 1✦ 1✓' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_PANES=$'work\t%1\nwork\t%2\nagent-a\t%3'
TMUX_MOCK_TARGET_OPTIONS=$'%1|@agent_state=blocked\n%2|@agent_state=idle\n%3|@agent_state=done'
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh counts self-reported manual panes and ignores managed panes' 'agents 1●' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off on on)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tblocked\nagent-b\tidle'
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh can render color and idle segments' 'agents #[fg=red]1●#[default] #[fg=green]1·#[default]' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off)"
stale_at=$(( $(date +%s) - 30000 ))
TMUX_MOCK_LIST_PANES=$'work\t%1'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=working"$'\n'"%1|@agent_state_at=$stale_at"
out="$(run_bash 'scripts/status.sh --or fallback')"
assert_eq 'status.sh ignores stale pane state by default' 'fallback' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off)"
TMUX_MOCK_LIST_PANES=$'work\t%1'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=done"$'\n'"%1|@agent_state_at=$stale_at"
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh keeps stale done state visible' 'agents 1✓' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off 0)"
TMUX_MOCK_LIST_PANES=$'work\t%1'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=working"$'\n'"%1|@agent_state_at=$stale_at"
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh can disable state expiry' 'agents 1✦' "$out"

# picker.sh --list
reset_mocks
picker_home="$HOME"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
picker_now="$(date +%s)"
TMUX_MOCK_LIST_SESSIONS="agent-pi	blocked	${picker_now}	${picker_home}/proj	pi	pi
other	done	${picker_now}	/tmp/x		bash"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits managed session row identity' "$out" $'session\tagent-pi\t🔴 blocked\tproj\t0m'
assert_contains 'picker --list shortens home path and describes state' "$out" $'~/proj\tneeds input\tpi'
assert_not_contains 'picker --list ignores unmanaged sessions' "$out" $'session\tother'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits manual pane row' "$out" $'pane\t%1\t🟣 manual \tmanual-proj'
assert_contains 'picker --list describes manual pane agent' "$out" $'/tmp/manual-proj\tpane running pi\tpi'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=done"$'\n'"%1|@agent_state_at=$picker_now"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list reads manual pane state and timestamp' "$out" $'pane\t%1\t🔵 done   \tmanual-proj\t0m'

# state.sh
reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh writes pane scoped state' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_contains 'state.sh writes session scoped state for managed sessions' "$log_contents" $'set-option\t-t\tagent-a\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='work'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh still writes pane scoped state for manual panes' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_not_contains 'state.sh does not pollute manual sessions' "$log_contents" $'set-option\t-t\twork\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh nonsense' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'state.sh ignores invalid states' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tnonsense'

# launch.sh
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='no'
run_bash 'scripts/launch.sh /tmp/project @9' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh creates default session from path hash' "$log_contents" $'new-session\t-d\t-s\tagent-6533d8b9\t-c\t/tmp/project'
assert_contains 'launch.sh records origin window' "$log_contents" $'set-option\t-t\tagent-6533d8b9\t@agent_origin\t@9'
assert_contains 'launch.sh opens popup attached to session' "$log_contents" $'display-popup\t-w\t90%\t-h\t90%\t-E\ttmux attach-session -t agent-6533d8b9'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='yes'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex --fast\\npi=pi'
run_bash 'scripts/launch.sh /tmp/project @9 codex' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'launch.sh does not recreate existing named session' "$log_contents" $'new-session\t-d\t-s\tagent-codex-6533d8b9'
assert_contains 'launch.sh opens existing named agent session' "$log_contents" $'display-popup\t-w\t90%\t-h\t90%\t-E\ttmux attach-session -t agent-codex-6533d8b9'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex'
run_bash 'scripts/launch.sh /tmp/project @9 nope' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh reports unknown named agent' "$log_contents" $'display-message\tUnknown agent: nope'
assert_not_contains 'launch.sh does not open popup for unknown agent' "$log_contents" $'display-popup'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
