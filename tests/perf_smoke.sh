#!/usr/bin/env bash
# Smoke performance checks for hot paths. Uses a tmux mock, so results are
# stable enough to catch large regressions without requiring a live tmux server.
# Run with: bash tests/perf_smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-agents-perf.$$"
MOCK_BIN="$TMP_ROOT/bin"
mkdir -p "$MOCK_BIN"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat >"$MOCK_BIN/tmux" <<'TMUX_MOCK'
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
  local opt target
  opt="$(last_arg "$@")"
  target="$(target_arg "$@" || true)"
  if [ -n "$target" ]; then
    kv_get "${TMUX_MOCK_TARGET_OPTIONS:-}" "$target|$opt" || true
    return 0
  fi
  kv_get "${TMUX_MOCK_OPTIONS:-}" "$opt" || true
}

show_option_chain() {
  local -a group=()
  local arg
  for arg in "$@"; do
    if [ "$arg" = ';' ]; then
      [ "${#group[@]}" -gt 0 ] && show_option "${group[@]}" && printf '\n'
      group=()
    else
      group+=("$arg")
    fi
  done
  [ "${#group[@]}" -gt 0 ] && show_option "${group[@]}"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  display-message)
    joined=" $* "
    if [[ "$joined" == *' -F '* ]]; then
      printf '%s' "${TMUX_MOCK_STATUS_OPTIONS:-}"
    fi
    ;;
  show-option|show-options)
    show_option_chain "$@"
    ;;
  list-sessions)
    [ -n "${TMUX_MOCK_LIST_SESSIONS:-}" ] && printf '%s\n' "$TMUX_MOCK_LIST_SESSIONS"
    ;;
  list-panes)
    joined=" $* "
    if [[ "$joined" == *pane_current_command* ]]; then
      [ -n "${TMUX_MOCK_LIST_PANES_PICKER:-}" ] && printf '%s\n' "$TMUX_MOCK_LIST_PANES_PICKER"
    else
      [ -n "${TMUX_MOCK_LIST_PANES_STATUS:-}" ] && printf '%s\n' "$TMUX_MOCK_LIST_PANES_STATUS"
    fi
    ;;
  *)
    ;;
esac
TMUX_MOCK
chmod +x "$MOCK_BIN/tmux"

export PATH="$MOCK_BIN:$PATH"
export AGENT_SESSION_PREFIX='agent-'
export AGENT_DETECT_COMMANDS='pi codex claude'
export AGENT_DETECT_WRAPPERS='node bun npx npm pnpm yarn'

status_options() {
  local us=$'\037'
  printf '%s' "agent-${us}✦${us}✓${us}●${us}·${us}agents${us}off${us}✦ ✶ ✷ ✶${us}yellow${us}cyan${us}red${us}green${us}off${us}off"
}

now_ns() {
  local ns
  ns="$(date +%s%N 2>/dev/null || true)"
  if [[ "$ns" =~ ^[0-9]+$ ]]; then
    printf '%s' "$ns"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(time.time_ns())
PY
  else
    printf '%s000000000' "$(date +%s)"
  fi
}

ms_from_ns() {
  awk -v ns="$1" 'BEGIN { printf "%.1f", ns / 1000000 }'
}

measure() {
  local label="$1" iterations="$2" cmd="$3" start end elapsed avg
  start="$(now_ns)"
  for _ in $(seq 1 "$iterations"); do
    (cd "$ROOT" && bash -c "$cmd") >/dev/null
  done
  end="$(now_ns)"
  elapsed=$((end - start))
  avg=$((elapsed / iterations))
  printf '%-24s %4s runs  total=%8sms  avg=%7sms\n' \
    "$label" "$iterations" "$(ms_from_ns "$elapsed")" "$(ms_from_ns "$avg")"
  PERF_LAST_AVG_MS="$(ms_from_ns "$avg")"
}

build_case() {
  local n="$1" now sessions='' panes_status='' panes_picker='' opts=''
  local i state tool cmd path pane manual_state
  now="$(date +%s)"
  for i in $(seq 1 "$n"); do
    case $((i % 4)) in
      0) state='blocked' ;;
      1) state='working' ;;
      2) state='done' ;;
      *) state='idle' ;;
    esac
    case $((i % 3)) in
      0) tool='claude'; cmd='claude' ;;
      1) tool='pi'; cmd='pi' ;;
      *) tool='codex'; cmd='codex' ;;
    esac
    path="/tmp/project-$i"
    sessions+="agent-$tool-$i	$state	$now	$path	$tool	$cmd"$'\n'

    pane="%$i"
    manual_state="$state"
    panes_status+="work-$i	$pane"$'\n'
    panes_picker+="work-$i	$pane	$cmd	$((1000 + i))	/tmp/manual-$i"$'\n'
    opts+="$pane|@agent_state=$manual_state"$'\n'
    opts+="$pane|@agent_state_at=$now"$'\n'
  done

  export TMUX_MOCK_STATUS_OPTIONS="$(status_options)"
  export TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_detect_commands=pi codex claude\n@agent_detect_wrappers=node bun npx npm pnpm yarn'
  export TMUX_MOCK_LIST_SESSIONS="${sessions%$'\n'}"
  export TMUX_MOCK_LIST_PANES_STATUS="${panes_status%$'\n'}"
  export TMUX_MOCK_LIST_PANES_PICKER="${panes_picker%$'\n'}"
  export TMUX_MOCK_TARGET_OPTIONS="${opts%$'\n'}"
}

check_threshold() {
  local label="$1" avg="$2" max="$3"
  [ "$max" = 0 ] && return 0
  awk -v avg="$avg" -v max="$max" 'BEGIN { exit !(avg <= max) }' || {
    printf 'not ok - %s average %sms exceeded threshold %sms\n' "$label" "$avg" "$max" >&2
    return 1
  }
}

iterations="${PERF_ITERATIONS:-5}"
max_status_ms="${PERF_MAX_STATUS_MS:-2000}"
max_picker_ms="${PERF_MAX_PICKER_MS:-5000}"

printf 'Smoke performance test (mock tmux, %s iterations/case)\n' "$iterations"
printf 'Thresholds: status<=%sms, picker<=%sms (set to 0 to disable)\n\n' "$max_status_ms" "$max_picker_ms"

for n in 10 50 100; do
  printf 'case: %s managed sessions + %s manual panes\n' "$n" "$n"
  build_case "$n"
  measure "status.sh n=$n" "$iterations" 'scripts/status.sh'
  check_threshold "status.sh n=$n" "$PERF_LAST_AVG_MS" "$max_status_ms"
  measure "picker.sh --list n=$n" "$iterations" 'scripts/picker.sh --list'
  check_threshold "picker.sh --list n=$n" "$PERF_LAST_AVG_MS" "$max_picker_ms"
  printf '\n'
done

printf 'ok - performance smoke test completed\n'
