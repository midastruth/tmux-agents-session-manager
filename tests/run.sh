#!/usr/bin/env bash
# shellcheck disable=SC2034 # mock configuration variables are consumed by subprocesses
# shellcheck source-path=SCRIPTDIR
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

# shellcheck source=lib/tmux_mock.sh
. "$ROOT/tests/lib/tmux_mock.sh"
install_tmux_mock "$MOCK_BIN"

DAEMON_LOG="$TMP_ROOT/daemon.log"
: >"$DAEMON_LOG"
cat >"$MOCK_BIN/state-daemon" <<'DAEMON_MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DAEMON_LOG"
if [ "${1:-}" = snapshot-picker ]; then
  printf '%s' "${DAEMON_SNAPSHOT_ROWS:-}"
elif [ "${1:-}" = snapshot ]; then
  printf '%s\n' "${DAEMON_SNAPSHOT:-{\"ok\":true,\"data\":{\"records\":[]}}}"
else
  printf '{"ok":true}\n'
fi
DAEMON_MOCK
chmod +x "$MOCK_BIN/state-daemon"
export DAEMON_LOG AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"

export PATH="$MOCK_BIN:$PATH"
export TMUX_MOCK_LOG="$TMUX_LOG"

PASS=0
FAIL=0

reset_mocks() {
  : >"$TMUX_LOG"
  : >"$DAEMON_LOG"
  unset DAEMON_SNAPSHOT DAEMON_SNAPSHOT_ROWS
  unset TMUX_MOCK_OPTIONS TMUX_MOCK_TARGET_OPTIONS TMUX_MOCK_STATUS_OPTIONS \
    TMUX_MOCK_LIST_SESSIONS TMUX_MOCK_LIST_PANES TMUX_MOCK_LIST_CLIENTS \
    TMUX_MOCK_LIST_PANES_PICKER TMUX_MOCK_LIST_PANES_STATUS \
    TMUX_MOCK_HAS_SESSION TMUX_MOCK_EXISTING_SESSIONS TMUX_MOCK_CURRENT_SESSION \
    TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE TMUX_MOCK_SERVER_PID \
    TMUX_MOCK_FAIL_TARGETS \
    TMUX_MOCK_FAIL_REFRESH_CLIENT TMUX_MOCK_IF_SHELL_RESULT TMUX_MOCK_SHOW_HOOKS \
    TMUX_MOCK_PS_CHILDREN TMUX_MOCK_PS_COMM \
    AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS TMUX_PANE \
    PICKER_NOW
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
out="$(run_bash 'AGENT_DETECT_COMMANDS="pi codex claude"; . scripts/helpers.sh; resolve_pane_agent claude.exe 123')"
assert_eq 'resolve_pane_agent normalizes Claude executable name' 'claude' "$out"

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

# list.sh: a regular terminal client switched directly into a managed session
# must not be mistaken for the nested client created by display-popup.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_SERVER_PID=100
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/1\tagent-a\t300'
TMUX_MOCK_PS_CHILDREN=$'10=300'
run_bash "scripts/list.sh /dev/pts/1" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'list.sh keeps a direct managed-session client attached' "$log_contents" $'detach-client\t'
assert_contains 'list.sh opens picker on the direct managed-session client' "$log_contents" $'display-popup\t-c\t/dev/pts/1'

# A client spawned inside an agent popup is safe to detach, but only that exact
# client should be detached; other clients on its managed session must survive.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_SERVER_PID=100
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/1\twork\t200\n/dev/pts/2\tagent-a\t300'
TMUX_MOCK_PS_CHILDREN=$'100=250\n250=300'
run_bash "scripts/list.sh /dev/pts/2" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'list.sh detaches only the nested popup client' "$log_contents" $'detach-client\t-t\t/dev/pts/2'
assert_not_contains 'list.sh never detaches a whole managed session' "$log_contents" $'detach-client\t-s\t'
assert_contains 'list.sh reopens picker on an outer client' "$log_contents" $'display-popup\t-c\t/dev/pts/1'

# If the invoking client disappears before list.sh resolves it, use another
# valid ordinary client rather than targeting the stale client name.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/1\twork\t200'
run_bash "scripts/list.sh /dev/pts/stale" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'list.sh falls back when invoking client is stale' "$log_contents" $'display-popup\t-c\t/dev/pts/1'
assert_not_contains 'list.sh does not target a stale invoking client' "$log_contents" $'display-popup\t-c\t/dev/pts/stale'

# picker.sh --list
reset_mocks
picker_home="$HOME"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
# Pin now via PICKER_NOW so picker.sh uses the same instant we stamp into the
# mock rows; reading the clock twice would race a one-second boundary and make
# the rendered age (0s) flaky.
picker_now="$(date +%s)"
PICKER_NOW="$picker_now"
TMUX_MOCK_LIST_SESSIONS="agent-pi	blocked	${picker_now}	${picker_home}/proj	pi	pi	1
other	done	${picker_now}	/tmp/x		bash	"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits managed session row identity' "$out" $'session\tagent-pi\t🔴 blocked\tproj\t0s'
assert_contains 'picker --list shortens home path and shows numbered tool' "$out" $'~/proj\tneeds input\tpi-1'
assert_not_contains 'picker --list ignores unmanaged sessions' "$out" $'session\tother'

# picker.sh age column scales seconds/minutes/hours/days.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-a	blocked	$((now_ts - 45))	/tmp/a	pi	pi
agent-b	blocked	$((now_ts - 720))	/tmp/b	pi	pi
agent-c	blocked	$((now_ts - 10800))	/tmp/c	pi	pi
agent-d	blocked	$((now_ts - 172800))	/tmp/d	pi	pi"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list age shows seconds' "$out" $'session\tagent-a\t🔴 blocked\ta\t45s'
assert_contains 'picker --list age shows minutes' "$out" $'session\tagent-b\t🔴 blocked\tb\t12m'
assert_contains 'picker --list age shows hours' "$out" $'session\tagent-c\t🔴 blocked\tc\t3h'
assert_contains 'picker --list age shows days' "$out" $'session\tagent-d\t🔴 blocked\td\t2d'

# Rows within the same rank must sort by real age (youngest first), not by the
# leading number of the humanized age string ("3h" is older than "45s").
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-old	blocked	$((now_ts - 10800))	/tmp/old	pi	pi
agent-new	blocked	$((now_ts - 45))	/tmp/new	pi	pi"
out="$(run_bash 'scripts/picker.sh --list' | cut -f3 | paste -sd, -)"
assert_eq 'picker --list sorts same-rank rows by real age ascending' \
  'agent-new,agent-old' "$out"

# A row with no timestamp renders '-' for its age. It must sort LAST within its
# rank, not first: awk's "-" + 0 is 0, which would otherwise make an unknown
# age look like the youngest row.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-old	blocked	$((now_ts - 10800))	/tmp/old	pi	pi
agent-noage	blocked		/tmp/noage	pi	pi
agent-new	blocked	$((now_ts - 45))	/tmp/new	pi	pi"
out="$(run_bash 'scripts/picker.sh --list' | cut -f3 | paste -sd, -)"
assert_eq 'picker --list sorts unknown age last within its rank' \
  'agent-new,agent-old,agent-noage' "$out"

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits manual pane row' "$out" $'pane\t%1\t🟣 manual \tmanual-proj'
assert_contains 'picker --list describes manual pane agent' "$out" $'/tmp/manual-proj\tpane running pi\tpi'

reset_mocks
# Pin now so picker.sh and the stamped @agent_state_at agree exactly, keeping
# the rendered age deterministic at 0s.
picker_now="$(date +%s)"
PICKER_NOW="$picker_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=done"$'\n'"%1|@agent_state_at=$picker_now"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list reads manual pane state and timestamp' "$out" $'pane\t%1\t🔵 done   \tmanual-proj\t0s'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_FAIL_TARGETS='%1'
out="$(run_bash 'scripts/picker.sh --list' 2>/dev/null)"
rc="$?"
assert_eq 'picker --list fails on non-race manual pane option error' '1' "$rc"

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES_PICKER=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_LIST_PANES_STATUS=''
TMUX_MOCK_FAIL_TARGETS='%1'
out="$(run_bash 'scripts/picker.sh --list')"
rc="$?"
assert_eq 'picker --list skips manual pane closed during option query' '0' "$rc"
assert_eq 'picker --list emits no stale row for closed manual pane' '' "$out"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker --list validates closed pane without quiet target suppression' "$log_contents" $'show-options\t-p\t-t\t%1'
assert_not_contains 'picker --list no longer uses quiet option query for race detection' "$log_contents" $'show-options\t-pq\t-t\t%1'

# state.sh
AGENT_TOOL=pi
export AGENT_TOOL
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=on'
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_MOCK_OPTIONS TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh writes pane scoped state' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_contains 'state.sh writes session scoped state for managed sessions' "$log_contents" $'set-option\t-t\tagent-a\t@agent_state\tdone'
daemon_log_contents="$(<"$DAEMON_LOG")"
assert_contains 'state.sh reports state to daemon' "$daemon_log_contents" '"type":"Report"'
assert_contains 'state.sh sends a process generation' "$daemon_log_contents" '"process_generation":'
assert_contains 'state.sh sends a monotonic sequence' "$daemon_log_contents" '"sequence":1'

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

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh downgrades done to idle on watched managed pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tidle'
assert_not_contains 'state.sh does not record done on watched managed pane' "$log_contents" $'@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='work'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh downgrades done to idle on watched manual pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tidle'
assert_not_contains 'state.sh does not record done on watched manual pane' "$log_contents" $'@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh keeps done on unwatched managed pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_contains 'state.sh writes session done on unwatched managed pane' "$log_contents" $'set-option\t-t\tagent-a\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 0 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh keeps done when managed window is inactive' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 1 0'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh keeps done when managed pane is inactive' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh working' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh does not downgrade working on watched managed pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tworking'
assert_not_contains 'state.sh does not turn working into idle when watched' "$log_contents" $'@agent_state\tidle'
unset AGENT_TOOL

# launch.sh
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='no'
run_bash 'scripts/launch.sh /tmp/project @9' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh creates numbered default session from path hash' "$log_contents" $'new-session\t-d\t-s\tagent-6533d8b9-1\t-c\t/tmp/project'
assert_contains 'launch.sh records instance number' "$log_contents" $'set-option\t-t\tagent-6533d8b9-1\t@agent_instance\t1'
assert_contains 'launch.sh records origin window' "$log_contents" $'set-option\t-t\tagent-6533d8b9-1\t@agent_origin\t@9'
assert_contains 'launch.sh opens popup attached to numbered session' "$log_contents" $'display-popup\t-w\t90%\t-h\t90%\t-E\ttmux attach-session -t agent-6533d8b9-1'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_EXISTING_SESSIONS='agent-pi-6533d8b9-1 agent-pi-6533d8b9-2'
TMUX_MOCK_OPTIONS=$'@agent_agents=pi=pi'
run_bash 'scripts/launch.sh /tmp/project @9 pi' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh chooses the next free instance number' "$log_contents" $'new-session\t-d\t-s\tagent-pi-6533d8b9-3\t-c\t/tmp/project'
assert_contains 'launch.sh labels the selected agent instance' "$log_contents" $'set-option\t-t\tagent-pi-6533d8b9-3\t@agent_instance\t3'
assert_contains 'launch.sh checks numbered sessions by exact name' "$log_contents" $'has-session\t-t\t=agent-pi-6533d8b9-1'

# tmux normally treats a target as a prefix. An existing -10 must not make the
# exact -1 name appear occupied.
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_EXISTING_SESSIONS='agent-pi-6533d8b9-10'
TMUX_MOCK_OPTIONS=$'@agent_agents=pi=pi'
run_bash 'scripts/launch.sh /tmp/project @9 pi' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh does not confuse instance 1 with instance 10' "$log_contents" $'new-session\t-d\t-s\tagent-pi-6533d8b9-1\t-c\t/tmp/project'
assert_not_contains 'launch.sh does not skip free instance 1 due to prefix matching' "$log_contents" $'new-session\t-d\t-s\tagent-pi-6533d8b9-2'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='yes'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex --fast\\npi=pi\n@agent_multiple_instances=off'
run_bash 'scripts/launch.sh /tmp/project @9 codex' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'launch.sh does not recreate existing named session when instances disabled' "$log_contents" $'new-session\t-d\t-s\tagent-codex-6533d8b9'
assert_contains 'launch.sh checks legacy session by exact name' "$log_contents" $'has-session\t-t\t=agent-codex-6533d8b9'
assert_contains 'launch.sh opens existing named session when instances disabled' "$log_contents" $'display-popup\t-w\t90%\t-h\t90%\t-E\ttmux attach-session -t agent-codex-6533d8b9'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex'
run_bash 'scripts/launch.sh /tmp/project @9 nope' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh reports unknown named agent' "$log_contents" $'display-message\tUnknown agent: nope'
assert_not_contains 'launch.sh does not open popup for unknown agent' "$log_contents" $'display-popup'

# daemon client / lifecycle integration
reset_mocks
run_bash 'scripts/event.sh seen-pane %7' >/dev/null
log_contents="$(<"$DAEMON_LOG")"
assert_contains 'event client sends Seen' "$log_contents" '"type":"Seen"'
assert_contains 'event client sends seen pane id' "$log_contents" '"pane_id":"%7"'

reset_mocks
run_bash 'scripts/event.sh exited-pane %8' >/dev/null
assert_contains 'event client sends pane Exited' "$(<"$DAEMON_LOG")" '"type":"Exited"'

reset_mocks
run_bash 'scripts/picker.sh --kill pane %8' >/dev/null
assert_contains 'picker interrupt sends Ctrl-C to manual pane' "$(<"$TMUX_LOG")" $'send-keys\t-t\t%8\tC-c'
assert_not_contains 'picker interrupt does not report a still-running pane as exited' "$(<"$DAEMON_LOG")" '"type":"Exited"'

reset_mocks
run_bash 'scripts/picker.sh --kill session agent-pi' >/dev/null
assert_contains 'picker managed-session kill schedules exit report' "$(<"$TMUX_LOG")" 'event.sh exited-session agent-pi'

# A missing daemon snapshot must retain the tmux recovery mirror in the picker.
reset_mocks
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
PICKER_NOW=100
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\tdone\t100\t/tmp/project\tpi\tpi\t1'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker falls back to managed tmux mirror when daemon is unavailable' "$out" $'session\tagent-pi\t🔵 done'
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"

reset_mocks
PICKER_NOW=100
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\tdone\t90\t/tmp/project\tpi\tpi\t1'
DAEMON_SNAPSHOT_ROWS=$'agent-pi\037%1\037working\037100\n'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker prefers authoritative daemon snapshot over recovery mirror' "$out" $'session\tagent-pi\t🟡 working'

# agents_session_manager.tmux status-right auto-injection guard
# The entrypoint is an executable bash script (tpm runs it directly), not a
# sourced library, so invoke it with `bash <file>` rather than run_bash's
# `. scripts/...` style. It reads the current status-right via `show-option
# -gqv status-right`; the mock serves that from TMUX_MOCK_OPTIONS.
run_entrypoint() {
  (cd "$ROOT" && bash agents_session_manager.tmux)
}

# A cache marker is never duplicated and the status line contains no #() fork.
reset_mocks
TMUX_MOCK_OPTIONS=$'status-right=pre #{@agent_status_cache} post'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint skips duplicate daemon cache marker' "$log_contents" $'set-option	-g	status-right'

reset_mocks
TMUX_MOCK_OPTIONS=$'status-right=%H:%M'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint injects cache-only status summary' "$log_contents" $'set-option	-g	status-right	#{@agent_status_cache} %H:%M'
assert_not_contains 'entrypoint status summary performs zero forks' "$log_contents" '#('
assert_contains 'entrypoint ensures and reloads daemon' "$log_contents" 'daemon.sh ensure'

reset_mocks
TMUX_MOCK_OPTIONS=$'status-right=%H:%M'
TMUX_MOCK_SHOW_HOOKS=$'after-kill-pane\nsession-closed'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint skips pane hook without reliable killed-pane identity' "$log_contents" $'set-hook\t-ag\tafter-kill-pane'
assert_contains 'entrypoint appends supported session lifecycle hook' "$log_contents" $'set-hook\t-ag\tsession-closed'

reset_mocks
TMUX_MOCK_OPTIONS=$'status-right=%H:%M'
TMUX_MOCK_SHOW_HOOKS=$'session-closed[0] run-shell "user hook"'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint appends session lifecycle hook when user hook already exists' "$log_contents" $'set-hook\t-ag\tsession-closed'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=off
status-right=%H:%M'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint leaves status-right untouched when disabled' "$log_contents" $'set-option	-g	status-right'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
