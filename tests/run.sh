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

# shellcheck source=lib/tmux_mock.sh
. "$ROOT/tests/lib/tmux_mock.sh"
install_tmux_mock "$MOCK_BIN"

export PATH="$MOCK_BIN:$PATH"
export TMUX_MOCK_LOG="$TMUX_LOG"

PASS=0
FAIL=0

reset_mocks() {
  : >"$TMUX_LOG"
  unset TMUX_MOCK_OPTIONS TMUX_MOCK_TARGET_OPTIONS TMUX_MOCK_STATUS_OPTIONS \
    TMUX_MOCK_LIST_SESSIONS TMUX_MOCK_LIST_PANES TMUX_MOCK_LIST_CLIENTS \
    TMUX_MOCK_LIST_PANES_PICKER TMUX_MOCK_LIST_PANES_STATUS \
    TMUX_MOCK_HAS_SESSION TMUX_MOCK_CURRENT_SESSION TMUX_MOCK_PANE_SESSION \
    TMUX_MOCK_PANE_VISIBLE TMUX_MOCK_FAIL_TARGETS \
    TMUX_MOCK_FAIL_REFRESH_CLIENT \
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
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_PANES=$'work\t%1'
TMUX_MOCK_FAIL_TARGETS='%1'
out="$(run_bash 'scripts/status.sh --refresh' 2>/dev/null)"
rc="$?"
assert_eq 'status.sh --refresh fails on non-race manual pane query error' '1' "$rc"
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'status.sh --refresh does not publish cache on query error' "$log_contents" $'set-option\t-g\t@agent_status_cache'

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
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tdone\t123\t%1'
TMUX_MOCK_PANE_VISIBLE='1 0 1'
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh keeps done for attached but inactive managed pane' 'agents 1✓' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tdone\t123\t%1'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
out="$(run_bash 'scripts/status.sh --or fallback')"
assert_eq 'status.sh hides done for visible managed pane' 'fallback' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off)"
TMUX_MOCK_LIST_PANES=$'work\t%1'
TMUX_MOCK_TARGET_OPTIONS=$'%1|@agent_state=done'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
out="$(run_bash 'scripts/status.sh --or fallback')"
assert_eq 'status.sh hides done for visible manual pane' 'fallback' "$out"

reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off off off 0)"
TMUX_MOCK_LIST_PANES=$'work\t%1'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=working"$'\n'"%1|@agent_state_at=$stale_at"
out="$(run_bash 'scripts/status.sh')"
assert_eq 'status.sh can disable state expiry' 'agents 1✦' "$out"

# status.sh --refresh: caches the summary, sets the working flag, no stdout.
# Animation must be on for the working flag (the spinner poll trigger) to be set.
reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- on)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tworking\nagent-b\tdone'
out="$(run_bash 'scripts/status.sh --refresh')"
assert_eq 'status.sh --refresh prints nothing' '' "$out"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status.sh --refresh caches the summary' "$log_contents" $'set-option\t-g\t@agent_status_cache\tagents 1'
assert_contains 'status.sh --refresh sets working flag when working' "$log_contents" $'set-option\t-g\t@agent_status_working\t1'
assert_contains 'status.sh --refresh forces a client redraw' "$log_contents" $'refresh-client\t-S'

# status.sh --refresh: cache updates are authoritative, but the redraw can fail
# in background hook contexts with no current client. That failure must not make
# the hook fail after the cache was successfully published.
reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tdone'
TMUX_MOCK_FAIL_REFRESH_CLIENT=1
out="$(run_bash 'scripts/status.sh --refresh')"
rc="$?"
assert_eq 'status.sh --refresh ignores redraw-only failure' '0' "$rc"
assert_eq 'status.sh --refresh with redraw failure prints nothing' '' "$out"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status.sh --refresh still publishes cache before redraw failure' "$log_contents" $'set-option\t-g\t@agent_status_cache\tagents 1✓'
assert_contains 'status.sh --refresh attempts best-effort redraw' "$log_contents" $'refresh-client\t-S'

# status.sh --refresh: animation off -> no spinner needed, so the working flag
# stays cleared even while working (the cache alone drives the badge).
reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tworking'
run_bash 'scripts/status.sh --refresh' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status.sh --refresh leaves flag clear when animation off' "$log_contents" $'set-option\t-g\t@agent_status_working\t\n'

# status.sh --refresh: no working agents -> working flag cleared to empty, so
# tmux stops forking the animate branch entirely.
reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tdone\nagent-b\tidle'
run_bash 'scripts/status.sh --refresh' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status.sh --refresh clears working flag when idle' "$log_contents" $'set-option\t-g\t@agent_status_working\t\n'

# status.sh --animate: prints the summary AND caches it (drives the spinner).
reset_mocks
TMUX_MOCK_STATUS_OPTIONS="$(status_options agent- off)"
TMUX_MOCK_LIST_SESSIONS=$'agent-a\tworking'
out="$(run_bash 'scripts/status.sh --animate')"
assert_eq 'status.sh --animate prints the summary' 'agents 1✦' "$out"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status.sh --animate also caches the summary' "$log_contents" $'set-option\t-g\t@agent_status_cache\tagents 1✦'

# picker.sh --list
reset_mocks
picker_home="$HOME"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
# Pin now via PICKER_NOW so picker.sh uses the same instant we stamp into the
# mock rows; reading the clock twice would race a one-second boundary and make
# the rendered age (0s) flaky.
picker_now="$(date +%s)"
PICKER_NOW="$picker_now"
TMUX_MOCK_LIST_SESSIONS="agent-pi	blocked	${picker_now}	${picker_home}/proj	pi	pi
other	done	${picker_now}	/tmp/x		bash"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits managed session row identity' "$out" $'session\tagent-pi\t🔴 blocked\tproj\t0s'
assert_contains 'picker --list shortens home path and describes state' "$out" $'~/proj\tneeds input\tpi'
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
out="$(run_bash 'scripts/picker.sh --list' | cut -f3 | paste -sd,)"
assert_eq 'picker --list sorts same-rank rows by real age ascending' \
  'agent-new,agent-old' "$out"

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
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=on'
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_MOCK_OPTIONS TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh writes pane scoped state' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_contains 'state.sh writes session scoped state for managed sessions' "$log_contents" $'set-option\t-t\tagent-a\t@agent_state\tdone'
assert_contains 'state.sh triggers an event-driven status refresh' "$log_contents" $'run-shell\t-b'

# state.sh must fork a status refresh when @agent_status is unset/empty, because
# the badge is enabled by default (agents_session_manager.tmux reads it with a
# default of 'on'). A stale cache would otherwise freeze until the next event.
reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh refreshes status when badge defaults to on' "$log_contents" $'run-shell\t-b'

# state.sh must NOT fork a status refresh when the badge is explicitly disabled
# (@agent_status=off): users who turned the badge off pay nothing. Note an
# unset/empty @agent_status defaults to on (see agents_session_manager.tmux),
# so disabling requires the explicit 'off' value.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=off'
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_MOCK_OPTIONS TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh still writes state when badge disabled' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_not_contains 'state.sh skips status refresh when badge disabled' "$log_contents" $'run-shell\t-b'

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

# agents_session_manager.tmux status-right auto-injection guard
# The entrypoint is an executable bash script (tpm runs it directly), not a
# sourced library, so invoke it with `bash <file>` rather than run_bash's
# `. scripts/...` style. It reads the current status-right via `show-option
# -gqv status-right`; the mock serves that from TMUX_MOCK_OPTIONS.
run_entrypoint() {
  (cd "$ROOT" && bash agents_session_manager.tmux)
}

# When status-right already references @agent_status_working, the plugin must
# detect its own marker and NOT append a second badge (the exact duplicate-badge
# bug that a missing '@' on the option name would reintroduce).
reset_mocks
TMUX_MOCK_OPTIONS=$'status-right=pre #{?@agent_status_working,#(x --animate),#{@agent_status_cache}} post'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint skips injection when @agent_status_working marker present' \
  "$log_contents" $'set-option\t-g\tstatus-right'

# When status-right embeds a literal path to scripts/status.sh (a legacy raw
# embed from an older plugin version), the guard must also skip.
reset_mocks
TMUX_MOCK_OPTIONS="status-right=x #($ROOT/scripts/status.sh --or-host) y"
export TMUX_MOCK_OPTIONS
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint skips injection when literal status.sh path present' \
  "$log_contents" $'set-option\t-g\tstatus-right'

# A plain status-right with no marker must get the cached/animated summary
# prepended exactly once, preserving the user's existing content.
reset_mocks
TMUX_MOCK_OPTIONS=$'status-right=%H:%M'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
injected_count="$(grep -c $'set-option\t-g\tstatus-right' "$TMUX_LOG")"
assert_eq 'entrypoint injects status-right exactly once when no marker present' \
  '1' "$injected_count"
assert_contains 'entrypoint prepends the event-driven summary marker' \
  "$log_contents" $'set-option\t-g\tstatus-right\t#{?@agent_status_working,'
assert_contains 'entrypoint preserves existing status-right content' \
  "$log_contents" $'#{@agent_status_cache}} %H:%M'

# With @agent_status off, the plugin must not touch status-right at all, even
# when there is no marker present.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=off\nstatus-right=%H:%M'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint leaves status-right untouched when @agent_status off' \
  "$log_contents" $'set-option\t-g\tstatus-right'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
