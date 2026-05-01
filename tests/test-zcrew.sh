#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZCREW_BIN="$REPO_ROOT/bin/zcrew"
TMP_BASE="${TMPDIR:-/tmp}"
TEST_ROOT="$TMP_BASE/zcrew-tests-$$"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  local pid_file pid
  shopt -s nullglob
  for pid_file in "$TEST_ROOT"/**/*.pid "$TEST_ROOT"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    pid="$(tr -dc '0-9' < "$pid_file")"
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  shopt -u nullglob
  jobs -pr | xargs -r kill 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

new_test_dir() {
  local n="$1"
  local d="$TEST_ROOT/zcrew-test-$n"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

zcrew_cmd() {
  local d="$1"
  shift
  (
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" "$@"
  )
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1"
}

run_test() {
  local name="$1"
  local fn="$2"
  if "$fn"; then
    pass "$name"
  else
    fail "$name"
  fi
}

test_0_no_hardcoded_home_paths_in_source_files() {
  local needle='/home'"'/dl"
  ! rg -n "$needle" "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/tests" >/dev/null
}

make_mock_zellij() {
  local bindir="$1"
  local list_output="${2:-}"
  local child_pane_id="${3:-777}"
  mkdir -p "$bindir"
  cat > "$bindir/zellij" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

# inputs passed via env from test harness
LIST_OUTPUT="${MOCK_ZELLIJ_LIST_OUTPUT:-}"
CHILD_PANE_ID="${MOCK_ZELLIJ_CHILD_PANE_ID:-777}"
LIST_SESSIONS_OUTPUT="${MOCK_ZELLIJ_SESSIONS_OUTPUT:-test-session}"

case "${1:-}" in
  list-sessions)
    printf '%s\n' "$LIST_SESSIONS_OUTPUT"
    ;;
  action)
    shift
    case "${1:-}" in
      list-panes)
        printf '%s\n' "$LIST_OUTPUT"
        ;;
      new-pane)
        # find "--" and execute the command after it as the spawned pane.
        shift
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "--" ]]; then
            shift
            break
          fi
          shift
        done
        ZELLIJ_PANE_ID="$CHILD_PANE_ID" "$@"
        ;;
      *)
        ;;
    esac
    ;;
  *)
    ;;
esac
MOCK
  chmod +x "$bindir/zellij"
}

make_mock_zellij_spawn() {
  local bindir="$1"
  local args_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/zellij" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

LIST_OUTPUT="${MOCK_ZELLIJ_LIST_OUTPUT:-}"
NEW_PANE_OUTPUT="${MOCK_ZELLIJ_NEW_PANE_OUTPUT:-terminal_777}"
LIST_SESSIONS_OUTPUT="${MOCK_ZELLIJ_SESSIONS_OUTPUT:-test-session}"
: "${MOCK_ZELLIJ_ARGS_FILE:?MOCK_ZELLIJ_ARGS_FILE is required}"

printf '%s\n' "$*" >> "$MOCK_ZELLIJ_ARGS_FILE"

case "${1:-}" in
  list-sessions)
    printf '%s\n' "$LIST_SESSIONS_OUTPUT"
    ;;
  action)
    shift
    case "${1:-}" in
      list-panes)
        printf '%s\n' "$LIST_OUTPUT"
        ;;
      new-pane)
        printf '%s\n' "$NEW_PANE_OUTPUT"
        ;;
      *)
        ;;
    esac
    ;;
  *)
    ;;
esac
MOCK
  chmod +x "$bindir/zellij"
}

make_mock_bx() {
  local bindir="$1"
  local args_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/bx" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_BX_ARGS_FILE:?MOCK_BX_ARGS_FILE is required}"
printf '%s\n' "$*" > "$MOCK_BX_ARGS_FILE"
exit 0
MOCK
  chmod +x "$bindir/bx"
}

make_mock_tell() {
  local tell_path="$1"
  local args_file="$2"
  mkdir -p "$(dirname "$tell_path")"
  cat > "$tell_path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_TELL_ARGS_FILE:?MOCK_TELL_ARGS_FILE is required}"
if [[ "${MOCK_TELL_INCLUDE_TS:-0}" == "1" ]]; then
  printf '%s\t%q\n' "$(date +%s)" "$*" >> "$MOCK_TELL_ARGS_FILE"
else
  printf '%s\n' "$*" >> "$MOCK_TELL_ARGS_FILE"
fi
exit 0
MOCK
  chmod +x "$tell_path"
}

make_mock_sleep() {
  local bindir="$1"
  local args_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_SLEEP_ARGS_FILE:?MOCK_SLEEP_ARGS_FILE is required}"
printf '%s\n' "$*" >> "$MOCK_SLEEP_ARGS_FILE"
exit 0
MOCK
  chmod +x "$bindir/sleep"
}

make_mock_mise() {
  local bindir="$1"
  local args_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/mise" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_MISE_ARGS_FILE:?MOCK_MISE_ARGS_FILE is required}"
printf '%s\n' "$PWD:$*" >> "$MOCK_MISE_ARGS_FILE"
case "${MOCK_MISE_EXIT_MODE:-success}" in
  success) exit 0 ;;
  fail) exit 1 ;;
  *)
    echo "unknown MOCK_MISE_EXIT_MODE=${MOCK_MISE_EXIT_MODE}" >&2
    exit 2
    ;;
esac
MOCK
  chmod +x "$bindir/mise"
}

prepare_send_test_tools() {
  local project_dir="$1"
  local bindir="$2"
  local args_file="$3"
  local live_pane_ids="${4:-123}"
  local session_name="${5:-test-session}"
  local list_output=""
  local pane_id

  make_mock_tell "$project_dir/lib/zcrew/tell" "$args_file"
  mkdir -p "$bindir"
  for pane_id in ${live_pane_ids//,/ }; do
    list_output+="terminal_${pane_id}"$'\n'
  done
  cat > "$bindir/zellij" <<MOCK_ZELLIJ
#!/bin/bash
case "\${1:-}" in
  list-sessions) echo "$session_name" ;;
  action)
    case "\${2:-}" in
      list-panes) printf '%s' '$list_output' ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK_ZELLIJ
  chmod +x "$bindir/zellij"
}

run_codex_launcher() {
  local project_dir="$1"
  local home_dir="$2"
  local mockbin="$3"
  local args_file="$4"

  (
    cd "$project_dir" || exit 1
    HOME="$home_dir" PATH="$mockbin:$PATH" MOCK_BX_ARGS_FILE="$args_file" \
      "$REPO_ROOT/lib/zcrew/launchers/codex.sh" >/dev/null 2>&1
  )
}

source_zcrew_lib() {
  local lib_copy="$1"
  sed '$d' "$ZCREW_BIN" > "$lib_copy"
}

plant_host_claude_auth() {
  local home_dir="$1"
  local json_content="${2:-{\"host\":\"json\"}}"
  local creds_content="${3:-{\"claudeAiOauth\":{\"accessToken\":\"a\",\"refreshToken\":\"r\"}}}"

  mkdir -p "$home_dir/.claude"
  printf '%s\n' "$json_content" > "$home_dir/.claude.json"
  printf '%s\n' "$creds_content" > "$home_dir/.claude/.credentials.json"
}

test_1_init_creates_registry() {
  local d
  d="$(new_test_dir 1)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  [[ -d "$d/.zcrew" ]] || return 1
  [[ -f "$d/.zcrew/registry.json" ]] || return 1
  jq -e '.version == 1 and .panes == {}' "$d/.zcrew/registry.json" >/dev/null
}

test_2_list_empty_plain_and_json() {
  local d out_plain out_json
  d="$(new_test_dir 2)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  out_plain="$(zcrew_cmd "$d" list 2>/dev/null)" || return 1
  out_json="$(zcrew_cmd "$d" list --json 2>/dev/null)" || return 1

  printf '%s\n' "$out_plain" | jq -e '.version == 1 and .panes == {}' >/dev/null || return 1
  printf '%s\n' "$out_json" | jq -e '.version == 1 and .panes == {}' >/dev/null
}

test_3_register_create_then_update() {
  local d
  d="$(new_test_dir 3)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register foo --paneId 11 --sessionId s1 --agent claude --cwd "$d" --pid 100 --status alive >/dev/null 2>&1 || return 1
  jq -e --arg d "$d" '.panes.foo.paneId=="11" and .panes.foo.sessionId=="s1" and .panes.foo.agent=="claude" and .panes.foo.cwd==$d and .panes.foo.pid==100 and .panes.foo.status=="alive"' "$d/.zcrew/registry.json" >/dev/null || return 1

  zcrew_cmd "$d" register foo --paneId 22 --sessionId s2 --agent codex --cwd "$d/sub" --pid 200 --status stale >/dev/null 2>&1 || return 1
  jq -e --arg d "$d/sub" '.panes.foo.paneId=="22" and .panes.foo.sessionId=="s2" and .panes.foo.agent=="codex" and .panes.foo.cwd==$d and .panes.foo.pid==200 and .panes.foo.status=="stale"' "$d/.zcrew/registry.json" >/dev/null
}

test_4_list_outside_project_fails_hard() {
  local d out
  d="$(new_test_dir 4)"

  if out="$(zcrew_cmd "$d" list 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -q 'zcrew: no \.zcrew/'
}

test_5_parallel_register_all_present() {
  local d i
  d="$(new_test_dir 5)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1

  for i in $(seq 1 10); do
    (
      zcrew_cmd "$d" register "n$i" --paneId "$i" --sessionId "s$i" --agent claude --cwd "$d" --pid "$((1000+i))" --status alive >/dev/null 2>&1
    ) &
  done
  wait

  for i in $(seq 1 10); do
    jq -e --arg k "n$i" '.panes | has($k)' "$d/.zcrew/registry.json" >/dev/null || return 1
  done

  [[ "$(jq '.panes | length' "$d/.zcrew/registry.json")" -eq 10 ]]
}

test_6_sync_prune_with_mocked_zellij() {
  local d mockbin
  d="$(new_test_dir 6)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  jq '.panes = {stale:{paneId:"999",sessionId:"s",agent:"claude",cwd:"x",pid:1,lastSeen:1,status:"alive"}, live:{paneId:"123",sessionId:"s",agent:"claude",cwd:"x",pid:2,lastSeen:1,status:"alive"}}' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"

  make_mock_zellij "$mockbin"

  (
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_123' "$ZCREW_BIN" sync >/dev/null 2>&1
  ) || return 1

  jq -e '.panes | has("live") and (has("stale")|not)' "$d/.zcrew/registry.json" >/dev/null
}

test_7_placeholder_promotion_no_duplicate() {
  local d mockbin
  d="$(new_test_dir 7)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/bin"
  ln -sf "$ZCREW_BIN" "$d/bin/zcrew"
  zcrew_cmd "$d" register pane-99 --paneId 99 --sessionId s99 --agent claude --cwd "$d" --pid 99 --status alive >/dev/null 2>&1 || return 1

  make_mock_zellij "$mockbin"
  make_mock_bx "$mockbin" "$d/bx-args.txt"

  (
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_CHILD_PANE_ID=555 MOCK_BX_ARGS_FILE="$d/bx-args.txt" ZELLIJ_PANE_ID=99 "$ZCREW_BIN" spawn claude child >/dev/null 2>&1
  ) || return 1

  jq -e '.panes | has("main") and (has("pane-99")|not)' "$d/.zcrew/registry.json" >/dev/null || return 1
  [[ "$(jq -r '.panes.main.paneId' "$d/.zcrew/registry.json")" == "99" ]]
}

test_9_send_calls_tell_with_expected_args() {
  local d mockbin args_file sent
  d="$(new_test_dir 9)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  make_mock_tell "$d/lib/zcrew/tell" "$args_file"
  mkdir -p "$mockbin"

  # Mock zellij so require_zellij_session and liveness check pass
  cat > "$mockbin/zellij" <<'MOCK_ZELLIJ'
#!/bin/bash
case "${1:-}" in
  list-sessions) echo "test-session" ;;
  action)
    case "${2:-}" in
      list-panes) echo "terminal_123" ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK_ZELLIJ
  chmod +x "$mockbin/zellij"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  [[ -f "$args_file" ]] || return 1
  sent="$(sed -n '1p' "$args_file")"
  [[ "$sent" == 123\ hello\ world* ]] || return 1
  grep -q 'To report a result, finding, blocker, or question' "$args_file"
}

test_9b_send_compact_calls_tell_twice_with_delay() {
  local d mockbin args_file sleep_file first second
  d="$(new_test_dir 9b)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  sleep_file="$d/sleep-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"
  make_mock_sleep "$mockbin" "$sleep_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" MOCK_SLEEP_ARGS_FILE="$sleep_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send --compact buddy "hello compact" >/dev/null 2>&1
  ) || return 1

  [[ -f "$sleep_file" ]] || return 1
  [[ "$(wc -l < "$sleep_file")" -eq 1 ]] || return 1
  [[ "$(cat "$sleep_file")" == "10" ]] || return 1
  first="$(sed -n '1p' "$args_file")"
  second="$(sed -n '2p' "$args_file")"
  [[ "$first" == "123 /compact" ]] || return 1
  printf '%s\n' "$second" | grep -q '123 hello compact' || return 1
  grep -q 'zcrew send main' "$args_file"
}

test_9c_send_without_compact_calls_tell_once() {
  local d mockbin args_file
  d="$(new_test_dir 9c)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello once" >/dev/null 2>&1
  ) || return 1

  [[ "$(grep -c '^123 hello once' "$args_file")" -eq 1 ]]
}

test_10_sync_no_prune_marks_stale_not_delete() {
  local d mockbin
  d="$(new_test_dir 10)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  jq '.panes = {stale:{paneId:"999",sessionId:"s",agent:"claude",cwd:"x",pid:1,lastSeen:1,status:"alive"}, live:{paneId:"123",sessionId:"s",agent:"claude",cwd:"x",pid:2,lastSeen:1,status:"alive"}}' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  make_mock_zellij "$mockbin"

  (
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_123' "$ZCREW_BIN" sync --keep-stale >/dev/null 2>&1
  ) || return 1

  jq -e '.panes | has("stale") and has("live")' "$d/.zcrew/registry.json" >/dev/null || return 1
  [[ "$(jq -r '.panes.stale.status' "$d/.zcrew/registry.json")" == "stale" ]] || return 1
  [[ "$(jq -r '.panes.live.status' "$d/.zcrew/registry.json")" == "alive" ]]
}

test_11_spawn_unknown_agent_uses_bx_fallback() {
  local d mockbin args_file out
  d="$(new_test_dir 11)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_444' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn aider foo 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: foo (aider) pane=444' || return 1
  grep -Fq 'action new-pane' "$args_file" || return 1
  grep -Fq 'bash -c' "$args_file" || return 1
  grep -Fq 'bx run aider' "$args_file" || return 1
  ! grep -Fq 'launchers/aider.sh' "$args_file" || return 1
  jq -e '.panes.foo.agent == "aider" and .panes.foo.paneId == "444"' "$d/.zcrew/registry.json" >/dev/null
}

test_11b_spawn_duplicate_name_fails_before_new_pane() {
  local d mockbin out args_file
  d="$(new_test_dir 11b)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s1 --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  mkdir -p "$d/lib/zcrew/launchers"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/lib/zcrew/launchers/claude.sh"
  chmod +x "$d/lib/zcrew/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  if out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='terminal_123' ZELLIJ_SESSION_NAME='test-session' \
      "$ZCREW_BIN" spawn claude buddy 2>&1
  )"; then
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq "pane 'buddy' already exists (pane=123)" || return 1
  ! grep -Fq 'action new-pane' "$args_file" || return 1
  jq -e '.panes.buddy.paneId == "123"' "$d/.zcrew/registry.json" >/dev/null
}

test_11c_spawn_allows_name_after_pruning_stale_entry() {
  local d mockbin args_file out
  d="$(new_test_dir 11c)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx"
  mkdir -p "$d/lib/zcrew/launchers"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/lib/zcrew/launchers/claude.sh"
  chmod +x "$d/lib/zcrew/launchers/claude.sh"
  zcrew_cmd "$d" register buddy --paneId 999 --sessionId s1 --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_777' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude buddy 2>&1
  )" || return 1

  grep -Fq 'action new-pane' "$args_file" || return 1
  printf '%s\n' "$out" | grep -Fq 'spawned: buddy (claude) pane=777' || return 1
  jq -e '.panes.buddy.paneId == "777"' "$d/.zcrew/registry.json" >/dev/null
}

test_11d_spawn_fresh_name_succeeds() {
  local d mockbin args_file
  d="$(new_test_dir 11d)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx"
  mkdir -p "$d/lib/zcrew/launchers"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/lib/zcrew/launchers/claude.sh"
  chmod +x "$d/lib/zcrew/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_555' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude fresh >/dev/null 2>&1
  ) || return 1

  grep -Fq 'action new-pane' "$args_file" || return 1
  jq -e '.panes.fresh.paneId == "555"' "$d/.zcrew/registry.json" >/dev/null
}

test_11e_spawn_builtin_agent_uses_launcher_script() {
  local d mockbin args_file out
  d="$(new_test_dir 11e)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/lib/zcrew/launchers"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/lib/zcrew/launchers/codex.sh"
  chmod +x "$d/lib/zcrew/launchers/codex.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_556' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn codex reviewer 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: reviewer (codex) pane=556' || return 1
  grep -Fq "$d/lib/zcrew/launchers/codex.sh" "$args_file" || return 1
  ! grep -Fq 'bx run codex' "$args_file" || return 1
  jq -e '.panes.reviewer.agent == "codex" and .panes.reviewer.paneId == "556"' "$d/.zcrew/registry.json" >/dev/null
}

test_11f_spawn_seeds_missing_managed_mounts() {
  local d mockbin args_file out zellij_sock
  d="$(new_test_dir 11f)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"
  zellij_sock="/run/user/$(id -u)/zellij"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  rm -f "$d/.bx/mounts"
  mkdir -p "$d/.bx" "$d/lib/zcrew/launchers"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/lib/zcrew/launchers/claude.sh"
  chmod +x "$d/lib/zcrew/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_557' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude healer 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: healer (claude) pane=557' || return 1
  [[ -f "$d/.bx/mounts" ]] || return 1
  grep -Fqx "$zellij_sock $zellij_sock rw" "$d/.bx/mounts"
}

test_11g_spawn_repairs_managed_mounts_preserving_custom_lines() {
  local d mockbin args_file out zellij_sock custom_src custom_dst
  d="$(new_test_dir 11g)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"
  zellij_sock="/run/user/$(id -u)/zellij"
  custom_src="$d/custom-src"
  custom_dst="/opt/custom"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/lib/zcrew/launchers" "$custom_src"
  cat > "$d/.bx/mounts" <<EOF
$custom_src $custom_dst ro
/old/zellij /run/user/$(id -u)/zellij rw
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/lib/zcrew/launchers/claude.sh"
  chmod +x "$d/lib/zcrew/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_558' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude healer2 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: healer2 (claude) pane=558' || return 1
  grep -Fqx "$custom_src $custom_dst ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$zellij_sock $zellij_sock rw" "$d/.bx/mounts" || return 1
  [[ "$(grep -Fxc "$zellij_sock $zellij_sock rw" "$d/.bx/mounts")" -eq 1 ]]
}

test_12_send_outside_project_fails_hard() {
  local d out
  d="$(new_test_dir 12)"

  if out="$(zcrew_cmd "$d" send any hello 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -q 'zcrew: no \.zcrew/'
}

test_12b_send_stale_unknown_agent_preserves_agent_name_in_suggestion() {
  local d mockbin out
  d="$(new_test_dir 12b)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register helper --paneId 999 --sessionId s --agent aider --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin" ""

  if out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME='test-session' \
      "$ZCREW_BIN" send helper "hello" 2>&1
  )"; then
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq "zcrew spawn aider helper" || return 1
  ! printf '%s\n' "$out" | grep -Fq "zcrew spawn claude helper"
}

test_13_rename_happy_path_preserves_fields() {
  local d
  d="$(new_test_dir 13)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register foo --paneId 77 --sessionId s77 --agent codex --cwd "$d/work" --pid 707 --status stale >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" rename foo bar >/dev/null 2>&1 || return 1

  jq -e --arg cwd "$d/work" '
    (.panes | has("foo") | not) and
    (.panes | has("bar")) and
    (.panes.bar.paneId == "77") and
    (.panes.bar.sessionId == "s77") and
    (.panes.bar.agent == "codex") and
    (.panes.bar.cwd == $cwd) and
    (.panes.bar.pid == 707) and
    (.panes.bar.status == "stale")
  ' "$d/.zcrew/registry.json" >/dev/null
}

test_14_rename_missing_old_fails() {
  local d out
  d="$(new_test_dir 14)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  if out="$(zcrew_cmd "$d" rename nope newname 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -q 'does not exist'
}

test_15_rename_duplicate_new_fails() {
  local d out
  d="$(new_test_dir 15)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register foo --paneId 1 --sessionId s1 --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register bar --paneId 2 --sessionId s2 --agent codex --cwd "$d" --pid 2 --status alive >/dev/null 2>&1 || return 1

  if out="$(zcrew_cmd "$d" rename foo bar 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -q 'already exists'
}

test_16_install_leaves_claude_settings_absent_when_missing() {
  local d
  d="$(new_test_dir 16)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ ! -f "$d/.claude/settings.json" ]]
}

test_17_install_deletes_settings_file_if_cleanup_leaves_empty_object() {
  local d
  d="$(new_test_dir 17)"
  mkdir -p "$d/.claude"
  cat > "$d/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/zcrew-register.sh"
          }
        ]
      }
    ]
  }
}
JSON

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ ! -f "$d/.claude/settings.json" ]]
}

test_17b_install_preserves_existing_claude_settings_and_removes_retired_hook() {
  local d
  d="$(new_test_dir 17b)"
  mkdir -p "$d/.claude"
  cat > "$d/.claude/settings.json" <<'JSON'
{"env":{"KEEP_ME":"yes","OTHER_KEY":"still-here"},"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.claude/hooks/zcrew-register.sh"},{"type":"command","command":"echo keep-session"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}
JSON

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  jq -e '
    .env.KEEP_ME == "yes"
    and .env.OTHER_KEY == "still-here"
    and ((.hooks.SessionStart[0].hooks | length) == 1)
    and .hooks.SessionStart[0].hooks[0].command == "echo keep-session"
    and .hooks.PreToolUse[0].matcher == "Bash"
  ' "$d/.claude/settings.json" >/dev/null
}

test_18_install_via_symlink_writes_managed_files_in_canonical_target() {
  local real_dir link_dir
  real_dir="$(new_test_dir 18-real)"
  link_dir="$TEST_ROOT/zcrew-test-18-link"
  rm -f "$link_dir"
  ln -s "$real_dir" "$link_dir"

  zcrew_cmd "$TEST_ROOT" install "$link_dir" >/dev/null 2>&1 || return 1

  [[ -f "$real_dir/.config/mise.toml" ]] || return 1
  [[ -d "$real_dir/.zcrew" ]] || return 1
  [[ -d "$real_dir/.bx" ]]
}

test_18b_install_writes_managed_mise_floor() {
  local d
  d="$(new_test_dir 18b)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$d/.config/mise.toml" ]] || return 1
  cat > "$d/expected-mise.toml" <<EOF
# Managed by zcrew install — do not edit manually.
# Project-specific overrides go in .mise.toml (higher precedence).
[env]
_.path = ["bin"]
EOF
  cmp -s "$d/expected-mise.toml" "$d/.config/mise.toml"
}

test_18c_reinstall_overwrites_managed_mise_floor_with_canonical_path() {
  local real_dir link_dir
  real_dir="$(new_test_dir 18c-real)"
  link_dir="$TEST_ROOT/zcrew-test-18c-link"
  rm -f "$link_dir"
  ln -s "$real_dir" "$link_dir"

  mkdir -p "$real_dir/.config"
  cat > "$real_dir/.config/mise.toml" <<'EOF'
# stale file
[tools]
node = "18"
EOF

  zcrew_cmd "$TEST_ROOT" install "$link_dir" >/dev/null 2>&1 || return 1

  grep -Fxq '# Managed by zcrew install — do not edit manually.' "$real_dir/.config/mise.toml" || return 1
  grep -Fxq '# Project-specific overrides go in .mise.toml (higher precedence).' "$real_dir/.config/mise.toml" || return 1
  ! grep -Fq '[tools]' "$real_dir/.config/mise.toml" || return 1
  grep -Fxq '[env]' "$real_dir/.config/mise.toml" || return 1
  ! grep -Fq 'ZCREW_PROJECT_DIR' "$real_dir/.config/mise.toml" || return 1
  grep -Fxq '_.path = ["bin"]' "$real_dir/.config/mise.toml"
}

test_18d_install_does_not_create_envrc() {
  local d
  d="$(new_test_dir 18d)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ ! -e "$d/.envrc" ]]
}

test_18e_install_preserves_existing_envrc_content() {
  local d before after
  d="$(new_test_dir 18e)"
  mkdir -p "$d"
  cat > "$d/.envrc" <<'EOF'
export FOO=bar
layout python
EOF
  before="$(cat "$d/.envrc")"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  after="$(cat "$d/.envrc")"

  [[ "$before" == "$after" ]]
}

test_18f_install_does_not_invoke_mise() {
  local d mockbin args_file
  d="$(new_test_dir 18f)"
  mockbin="$d/mock-bin"
  args_file="$d/mise-args.txt"
  mkdir -p "$d"
  make_mock_mise "$mockbin" "$args_file"

  (
    cd "$TEST_ROOT" || exit 1
    ZCREW_AUTO_SYNC=0 PATH="$mockbin:$PATH" MOCK_MISE_ARGS_FILE="$args_file" "$ZCREW_BIN" install "$d" >/dev/null 2>&1
  ) || return 1

  [[ ! -f "$args_file" ]]
}

test_19_find_project_root_from_root_uses_local_state() {
  local d out
  d="$(new_test_dir 19-project)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register rooted --paneId 19 --sessionId s19 --agent claude --cwd "$d" --pid 19 --status alive >/dev/null 2>&1 || return 1

  out="$(zcrew_cmd "$d" list --json 2>/dev/null)" || return 1
  printf '%s\n' "$out" | jq -e '.panes.rooted.paneId == "19"' >/dev/null || return 1
}

test_20_find_project_root_walks_up_from_subdir() {
  local d subdir
  d="$(new_test_dir 20)"
  subdir="$d/cmd/subdir"
  mkdir -p "$subdir"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 20 --sessionId s20 --agent codex --cwd "$d" --pid 20 --status alive >/dev/null 2>&1 || return 1

  (
    cd "$subdir" || exit 1
    ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list --json
  ) | jq -e '.panes.buddy.paneId == "20"' >/dev/null
}

test_20b_find_project_root_fails_outside_zcrew_tree() {
  local d other_dir out
  d="$(new_test_dir 20b-project)"
  other_dir="$(new_test_dir 20b-other)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1

  if out="$(zcrew_cmd "$other_dir" list 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq "no .zcrew/ found from $other_dir upward"
}

test_21_list_auto_sync_prunes_dead_entries() {
  local d mockbin out
  d="$(new_test_dir 21)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  jq '.panes = {dead:{paneId:"999",sessionId:"s",agent:"claude",cwd:"x",pid:1,lastSeen:1,status:"alive"}}' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  make_mock_zellij "$mockbin" ""

  out="$(
    cd "$d" || exit 1
    ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" "$ZCREW_BIN" list --json
  )" || return 1

  printf '%s\n' "$out" | jq -e '.panes.dead == null' >/dev/null || return 1
  jq -e '.panes.dead == null' "$d/.zcrew/registry.json" >/dev/null
}

test_22_list_env_opt_out_preserves_fixture() {
  local d mockbin out
  d="$(new_test_dir 22)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  jq '.panes = {dead:{paneId:"999",sessionId:"s",agent:"claude",cwd:"x",pid:1,lastSeen:1,status:"alive"}}' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  make_mock_zellij "$mockbin" ""

  out="$(
    cd "$d" || exit 1
    ZCREW_AUTO_SYNC=0 PATH="$mockbin:$PATH" "$ZCREW_BIN" list --json
  )" || return 1

  printf '%s\n' "$out" | jq -e '.panes.dead.paneId == "999"' >/dev/null || return 1
  jq -e '.panes.dead.paneId == "999"' "$d/.zcrew/registry.json" >/dev/null
}

test_23_spawn_implicit_sync_registers_existing_live_pane() {
  local d mockbin
  d="$(new_test_dir 23)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin" "terminal_123"

  if (
    cd "$d" || exit 1
    ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT="terminal_123" ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" "$ZCREW_BIN" spawn claude buddy >/dev/null 2>&1
  ); then
    return 1
  fi

  jq -e '.panes["pane-123"].paneId == "123"' "$d/.zcrew/registry.json" >/dev/null
}

test_24_sync_keep_stale_preserves_entries() {
  local d mockbin out
  d="$(new_test_dir 24)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  jq '.panes = {dead:{paneId:"999",sessionId:"s",agent:"claude",cwd:"x",pid:1,lastSeen:1,status:"alive"}}' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  make_mock_zellij "$mockbin" ""

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" "$ZCREW_BIN" sync --keep-stale
  )" || return 1

  [[ "$out" == "synced" ]] || return 1
  jq -e '.panes.dead.status == "stale"' "$d/.zcrew/registry.json" >/dev/null
}

test_25_skill_passthrough_forwards_arguments() {
  grep -Fqx '!`zcrew list $ARGUMENTS`' "$REPO_ROOT/.claude/skills/zpanes/SKILL.md" || return 1
  grep -Fqx '!`zcrew sync $ARGUMENTS`' "$REPO_ROOT/.claude/skills/zsync/SKILL.md"
}

test_26_auto_sync_timing_under_100ms() {
  local d mockbin start_ms end_ms elapsed_ms
  local samples=()
  d="$(new_test_dir 26)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin" ""

  (
    cd "$d" || exit 1
    ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" "$ZCREW_BIN" list --json >/dev/null
  ) || return 1

  for _ in 1 2 3; do
    start_ms="$(date +%s%3N)"
    (
      cd "$d" || exit 1
      ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" "$ZCREW_BIN" list --json >/dev/null
    ) || return 1
    end_ms="$(date +%s%3N)"
    samples+=("$((end_ms - start_ms))")
  done
  IFS=$'\n' read -r -d '' -a samples < <(printf '%s\n' "${samples[@]}" | sort -n && printf '\0')
  elapsed_ms="${samples[1]}"
  echo "TIMING: zcrew list auto-sync median ${elapsed_ms}ms"
  [[ "$elapsed_ms" -lt 100 ]]
}

test_27_install_writes_managed_gitignores() {
  local d
  d="$(new_test_dir 27)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$d/.bx/.gitignore" ]] || return 1
  [[ -f "$d/.zcrew/.gitignore" ]] || return 1
  grep -Fxq 'home/' "$d/.bx/.gitignore" || return 1
  grep -Fxq '.provisioned' "$d/.bx/.gitignore" || return 1
  grep -Fxq 'registry.json' "$d/.zcrew/.gitignore" || return 1
  grep -Fxq 'registry.lock' "$d/.zcrew/.gitignore" || return 1
  grep -Fxq 'audit.log' "$d/.zcrew/.gitignore" || return 1
  grep -Fxq 'spawn/' "$d/.zcrew/.gitignore" || return 1
  ! grep -Fxq 'team.conf' "$d/.zcrew/.gitignore"
}

test_28_second_install_keeps_gitignore_entries_unique() {
  local d
  d="$(new_test_dir 28)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ "$(grep -Fxc 'home/' "$d/.bx/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc '.provisioned' "$d/.bx/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'registry.json' "$d/.zcrew/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'registry.lock' "$d/.zcrew/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'audit.log' "$d/.zcrew/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'spawn/' "$d/.zcrew/.gitignore")" -eq 1 ]]
}

test_29_install_preserves_custom_gitignore_lines() {
  local d
  d="$(new_test_dir 29)"
  mkdir -p "$d/.bx" "$d/.zcrew"
  printf '%s\n' 'custom-bx-line' > "$d/.bx/.gitignore"
  printf '%s\n' 'custom-zcrew-line' > "$d/.zcrew/.gitignore"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  grep -Fxq 'custom-bx-line' "$d/.bx/.gitignore" || return 1
  grep -Fxq 'custom-zcrew-line' "$d/.zcrew/.gitignore"
}

test_30_install_preserves_managed_gitignore_lines_in_any_order() {
  local d
  d="$(new_test_dir 30)"
  mkdir -p "$d/.bx" "$d/.zcrew"
  cat > "$d/.bx/.gitignore" <<'EOF'
.provisioned
home/
EOF
  cat > "$d/.zcrew/.gitignore" <<'EOF'
spawn/
audit.log
registry.lock
registry.json
EOF

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ "$(grep -Fxc 'home/' "$d/.bx/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc '.provisioned' "$d/.bx/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'registry.json' "$d/.zcrew/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'registry.lock' "$d/.zcrew/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'audit.log' "$d/.zcrew/.gitignore")" -eq 1 ]] || return 1
  [[ "$(grep -Fxc 'spawn/' "$d/.zcrew/.gitignore")" -eq 1 ]]
}

test_31_install_writes_pi_skills() {
  local d skill
  d="$(new_test_dir 31)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  for skill in zcrew zspawn zsend zpanes zsync zname zclose; do
    [[ -f "$d/.pi/skills/$skill/SKILL.md" ]] || return 1
  done
  [[ -L "$d/.pi/skills/zcrew" ]] || return 1
  [[ "$(readlink "$d/.pi/skills/zcrew")" == "../../.agents/skills/zcrew" ]]
}

test_32_second_install_overwrites_pi_skills_with_latest_content() {
  local d marker
  d="$(new_test_dir 32)"
  marker='<!-- custom pi edit -->'
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  printf '\n%s\n' "$marker" >> "$d/.pi/skills/zspawn/SKILL.md"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  ! grep -Fxq "$marker" "$d/.pi/skills/zspawn/SKILL.md" || return 1
  cmp -s "$REPO_ROOT/.pi/skills/zspawn/SKILL.md" "$d/.pi/skills/zspawn/SKILL.md"
}

test_32b_install_writes_internal_tell_binary() {
  local d
  d="$(new_test_dir 32b)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$d/lib/zcrew/tell" ]] || return 1
  [[ -x "$d/lib/zcrew/tell" ]] || return 1
  cmp -s "$REPO_ROOT/lib/zcrew/tell" "$d/lib/zcrew/tell"
}

test_33_install_does_not_write_host_pi_dirs() {
  local d home_root
  d="$(new_test_dir 33)"
  home_root="$d/fake-home"
  mkdir -p "$d" "$home_root"

  (
    cd "$TEST_ROOT" || exit 1
    HOME="$home_root" ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" install "$d" >/dev/null 2>&1
  ) || return 1

  [[ ! -e "$home_root/.pi" ]] || return 1
  [[ ! -e "$home_root/.agents" ]]
}

test_34_pi_skill_frontmatter_sanity() {
  local d skill skill_file frontmatter
  d="$(new_test_dir 34)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  for skill in zcrew zspawn zsend zpanes zsync zname zclose; do
    skill_file="$d/.pi/skills/$skill/SKILL.md"
    [[ -f "$skill_file" ]] || return 1
    head -1 "$skill_file" | grep -Fxq -- '---' || return 1
    frontmatter="$(sed -n '/^---$/,/^---$/p' "$skill_file")"
    [[ -n "$frontmatter" ]] || return 1
    printf '%s\n' "$frontmatter" | grep -Eq "^name: $skill$" || return 1
    printf '%s\n' "$frontmatter" | grep -Eq '^description: .+' || return 1
  done
}

test_34b_install_writes_cross_tool_zcrew_skill_layout() {
  local d
  d="$(new_test_dir 34b)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$d/.agents/skills/zcrew/SKILL.md" ]] || return 1
  [[ -L "$d/.claude/skills/zcrew" ]] || return 1
  [[ "$(readlink "$d/.claude/skills/zcrew")" == "../../.agents/skills/zcrew" ]] || return 1
  [[ -L "$d/.codex/skills/zcrew" ]] || return 1
  [[ "$(readlink "$d/.codex/skills/zcrew")" == "../../.agents/skills/zcrew" ]] || return 1
  [[ -L "$d/.pi/skills/zcrew" ]] || return 1
  [[ "$(readlink "$d/.pi/skills/zcrew")" == "../../.agents/skills/zcrew" ]] || return 1
  cmp -s "$d/.agents/skills/zcrew/SKILL.md" "$d/.claude/skills/zcrew/SKILL.md" || return 1
  cmp -s "$d/.agents/skills/zcrew/SKILL.md" "$d/.codex/skills/zcrew/SKILL.md" || return 1
  cmp -s "$d/.agents/skills/zcrew/SKILL.md" "$d/.pi/skills/zcrew/SKILL.md"
}

test_34c_second_install_overwrites_codex_skill_with_latest_content() {
  local d marker
  d="$(new_test_dir 34c)"
  marker='<!-- custom codex edit -->'
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  printf '\n%s\n' "$marker" >> "$d/.codex/skills/zcrew/SKILL.md"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  ! grep -Fxq "$marker" "$d/.codex/skills/zcrew/SKILL.md" || return 1
  cmp -s "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" "$d/.codex/skills/zcrew/SKILL.md"
}

test_34d_codex_skill_frontmatter_sanity() {
  local d skill_file frontmatter
  d="$(new_test_dir 34d)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  skill_file="$d/.codex/skills/zcrew/SKILL.md"
  [[ -f "$skill_file" ]] || return 1
  head -1 "$skill_file" | grep -Fxq -- '---' || return 1
  frontmatter="$(sed -n '/^---$/,/^---$/p' "$skill_file")"
  [[ -n "$frontmatter" ]] || return 1
  printf '%s\n' "$frontmatter" | grep -Eq '^name: zcrew$' || return 1
  printf '%s\n' "$frontmatter" | grep -Eq '^description: .+' || return 1
  printf '%s\n' "$frontmatter" | grep -Eq '^type: skill$' || return 1
  ! printf '%s\n' "$frontmatter" | grep -Eq '^disable-model-invocation:' || return 1
  [[ "$(printf '%s\n' "$frontmatter" | grep -Ec '^[^#[:space:]][^:]*:')" -eq 3 ]]
}

test_34e_install_seeds_agents_and_claude_symlink_when_both_missing() {
  local d
  d="$(new_test_dir 34e)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  cmp -s "$REPO_ROOT/AGENTS.md" "$d/AGENTS.md" || return 1
  [[ -L "$d/CLAUDE.md" ]] || return 1
  [[ "$(readlink "$d/CLAUDE.md")" == "AGENTS.md" ]]
}

test_34f_install_skips_agents_and_claude_when_agents_exists() {
  local d before_agents before_claude
  d="$(new_test_dir 34f)"
  mkdir -p "$d"
  printf '%s\n' '# existing agents doc' > "$d/AGENTS.md"
  printf '%s\n' '# existing claude doc' > "$d/CLAUDE.md"
  before_agents="$(cat "$d/AGENTS.md")"
  before_claude="$(cat "$d/CLAUDE.md")"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ "$(cat "$d/AGENTS.md")" == "$before_agents" ]] || return 1
  [[ "$(cat "$d/CLAUDE.md")" == "$before_claude" ]]
}

test_34g_install_writes_agents_only_when_claude_exists() {
  local d before_claude
  d="$(new_test_dir 34g)"
  mkdir -p "$d"
  printf '%s\n' '# existing claude doc' > "$d/CLAUDE.md"
  before_claude="$(cat "$d/CLAUDE.md")"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  cmp -s "$REPO_ROOT/AGENTS.md" "$d/AGENTS.md" || return 1
  [[ ! -L "$d/CLAUDE.md" ]] || return 1
  [[ "$(cat "$d/CLAUDE.md")" == "$before_claude" ]]
}

test_34h_install_seeds_team_conf_template() {
  local d
  d="$(new_test_dir 34h)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$d/.zcrew/team.conf" ]] || return 1
  grep -Fxq '# Team composition — read by the orchestrator at session start.' "$d/.zcrew/team.conf" || return 1
  grep -Fxq '# name  agent  model  role' "$d/.zcrew/team.conf" || return 1
  grep -Fxq 'claudio  claude  sonnet  assistant / researcher' "$d/.zcrew/team.conf" || return 1
  grep -Fxq 'sam      codex   -       reviewer' "$d/.zcrew/team.conf" || return 1
  grep -Fxq 'piper    pi      -       implementer' "$d/.zcrew/team.conf"
}

test_34i_reinstall_preserves_existing_team_conf() {
  local d marker
  d="$(new_test_dir 34i)"
  marker='# custom team override'
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  printf '\n%s\n' "$marker" >> "$d/.zcrew/team.conf"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  grep -Fxq "$marker" "$d/.zcrew/team.conf"
}

test_35_send_claude_target_refreshes_auth_files() {
  local d target_cwd target_home mockbin args_file host_home before_json before_creds after_json after_creds
  d="$(new_test_dir 35)"
  target_cwd="$d/target-pane"
  target_home="$target_cwd/.bx/home"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_home/.claude"
  printf '%s\n' '{"stale":"json"}' > "$target_home/.claude.json"
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"old"}}' > "$target_home/.claude/.credentials.json"
  touch -d '2020-01-01 00:00:00' "$target_home/.claude.json" "$target_home/.claude/.credentials.json"
  plant_host_claude_auth "$host_home" '{"fresh":"json"}' '{"claudeAiOauth":{"accessToken":"fresh","refreshToken":"refresh"}}'
  before_json="$(stat -c %Y "$target_home/.claude.json")"
  before_creds="$(stat -c %Y "$target_home/.claude/.credentials.json")"

  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  after_json="$(stat -c %Y "$target_home/.claude.json")"
  after_creds="$(stat -c %Y "$target_home/.claude/.credentials.json")"
  [[ "$after_json" -gt "$before_json" ]] || return 1
  [[ "$after_creds" -gt "$before_creds" ]] || return 1
  jq -e --arg cwd "$target_cwd" '.hasCompletedOnboarding == true and .projects[$cwd].hasTrustDialogAccepted == true' "$target_home/.claude.json" >/dev/null || return 1
  ! grep -Fq '"fresh":"json"' "$target_home/.claude.json" || return 1
  grep -Fq '"accessToken":"fresh"' "$target_home/.claude/.credentials.json" || return 1
}

test_36_send_codex_target_skips_claude_auth_refresh() {
  local d target_cwd target_home mockbin args_file host_home before_json before_creds after_json after_creds
  d="$(new_test_dir 36)"
  target_cwd="$d/target-pane"
  target_home="$target_cwd/.bx/home"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_home/.claude"
  printf '%s\n' '{"keep":"json"}' > "$target_home/.claude.json"
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"keep"}}' > "$target_home/.claude/.credentials.json"
  plant_host_claude_auth "$host_home" '{"fresh":"json"}' '{"claudeAiOauth":{"accessToken":"fresh","refreshToken":"refresh"}}'
  before_json="$(stat -c %Y "$target_home/.claude.json")"
  before_creds="$(stat -c %Y "$target_home/.claude/.credentials.json")"

  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent codex --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  after_json="$(stat -c %Y "$target_home/.claude.json")"
  after_creds="$(stat -c %Y "$target_home/.claude/.credentials.json")"
  [[ "$after_json" -eq "$before_json" ]] || return 1
  [[ "$after_creds" -eq "$before_creds" ]] || return 1
  grep -Fq '"keep":"json"' "$target_home/.claude.json" || return 1
  grep -Fq '"accessToken":"keep"' "$target_home/.claude/.credentials.json" || return 1
}

test_37_send_unknown_target_skips_claude_auth_refresh() {
  local d target_cwd target_home mockbin args_file host_home before_json before_creds after_json after_creds
  d="$(new_test_dir 37)"
  target_cwd="$d/target-pane"
  target_home="$target_cwd/.bx/home"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_home/.claude"
  printf '%s\n' '{"keep":"json"}' > "$target_home/.claude.json"
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"keep"}}' > "$target_home/.claude/.credentials.json"
  plant_host_claude_auth "$host_home" '{"fresh":"json"}' '{"claudeAiOauth":{"accessToken":"fresh","refreshToken":"refresh"}}'
  before_json="$(stat -c %Y "$target_home/.claude.json")"
  before_creds="$(stat -c %Y "$target_home/.claude/.credentials.json")"

  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent unknown --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  after_json="$(stat -c %Y "$target_home/.claude.json")"
  after_creds="$(stat -c %Y "$target_home/.claude/.credentials.json")"
  [[ "$after_json" -eq "$before_json" ]] || return 1
  [[ "$after_creds" -eq "$before_creds" ]] || return 1
}

test_38_send_missing_host_claude_json_generates_minimal_target_state() {
  local d target_cwd target_home mockbin args_file host_home
  d="$(new_test_dir 38)"
  target_cwd="$d/target-pane"
  target_home="$target_cwd/.bx/home"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_home"
  mkdir -p "$host_home/.claude"
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"fresh","refreshToken":"refresh"}}' > "$host_home/.claude/.credentials.json"
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  [[ -f "$args_file" ]] || return 1
  jq -e --arg cwd "$target_cwd" '.hasCompletedOnboarding == true and .projects[$cwd].hasTrustDialogAccepted == true' "$target_home/.claude.json" >/dev/null || return 1
}

test_39_send_missing_host_credentials_soft_fails() {
  local d target_cwd target_home mockbin args_file host_home
  d="$(new_test_dir 39)"
  target_cwd="$d/target-pane"
  target_home="$target_cwd/.bx/home"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_home"
  mkdir -p "$host_home"
  printf '%s\n' '{"fresh":"json"}' > "$host_home/.claude.json"
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  [[ -f "$args_file" ]] || return 1
  [[ ! -e "$target_home/.claude/.credentials.json" ]]
}

test_40_send_without_target_bx_home_soft_fails() {
  local d target_cwd mockbin args_file host_home
  d="$(new_test_dir 40)"
  target_cwd="$d/target-pane"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_cwd"
  plant_host_claude_auth "$host_home" '{"fresh":"json"}' '{"claudeAiOauth":{"accessToken":"fresh","refreshToken":"refresh"}}'
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  [[ -f "$args_file" ]] || return 1
  [[ ! -e "$target_cwd/.bx/home/.claude.json" ]]
}

test_41_send_claude_refresh_leaves_no_tmp_files() {
  local d target_cwd target_home mockbin args_file host_home
  d="$(new_test_dir 41)"
  target_cwd="$d/target-pane"
  target_home="$target_cwd/.bx/home"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  host_home="$d/host-home"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$target_home/.claude"
  plant_host_claude_auth "$host_home" '{"fresh":"json"}' '{"claudeAiOauth":{"accessToken":"fresh","refreshToken":"refresh"}}'
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$target_cwd" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE HOME="$host_home" PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello world" >/dev/null 2>&1
  ) || return 1

  [[ -f "$args_file" ]] || return 1
  ! find "$target_home" -name '*.tmp.*' -print | grep -q .
}

test_42_codex_launcher_preseeds_trust_entry_in_sandbox_config() {
  local d home_dir mockbin args_file sandbox_config
  d="$(new_test_dir 42)"
  home_dir="$d/host-home"
  mockbin="$d/mock-bin"
  args_file="$d/bx-args.txt"
  sandbox_config="$d/.bx/home/.codex/config.toml"

  mkdir -p "$home_dir/.codex" "$d/.bx/home"
  printf '%s\n' 'model = "gpt-5"' > "$home_dir/.codex/config.toml"
  make_mock_bx "$mockbin" "$args_file"

  run_codex_launcher "$d" "$home_dir" "$mockbin" "$args_file" || return 1

  grep -Fxq 'run codex -a never -s danger-full-access' "$args_file" || return 1
  ! grep -Fq ' -c ' "$args_file"
  [[ ! -f "$sandbox_config" ]]
}

test_43_codex_launcher_forwards_model_to_bx_run() {
  local d home_dir mockbin args_file
  d="$(new_test_dir 43)"
  home_dir="$d/host-home"
  mockbin="$d/mock-bin"
  args_file="$d/bx-args.txt"

  make_mock_bx "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    HOME="$home_dir" PATH="$mockbin:$PATH" MOCK_BX_ARGS_FILE="$args_file" \
      ZCREW_MODEL="gpt-5.4" \
      "$REPO_ROOT/lib/zcrew/launchers/codex.sh" >/dev/null 2>&1
  ) || return 1

  grep -Fxq 'run codex -a never -s danger-full-access --model gpt-5.4' "$args_file"
}

test_44_codex_launcher_does_not_mutate_sandbox_config_before_bx_run() {
  local d home_dir mockbin args_file sandbox_config
  d="$(new_test_dir 44)"
  home_dir="$d/host-home"
  mockbin="$d/mock-bin"
  args_file="$d/bx-args.txt"
  sandbox_config="$d/.bx/home/.codex/config.toml"

  mkdir -p "$(dirname "$sandbox_config")"
  cat > "$sandbox_config" <<EOF
[projects."/tmp/other-project"]
trust_level = "trusted"
EOF
  make_mock_bx "$mockbin" "$args_file"

  run_codex_launcher "$d" "$home_dir" "$mockbin" "$args_file" || return 1

  grep -Fxq '[projects."/tmp/other-project"]' "$sandbox_config" || return 1
  [[ "$(grep -Fxc '[projects."/tmp/other-project"]' "$sandbox_config")" -eq 1 ]] || return 1
}

test_45_install_self_install_no_crash() {
  local d fixture out
  d="$(new_test_dir 45)"
  fixture="$d/zcrew-fixture"
  cp -r "$REPO_ROOT" "$fixture" || return 1
  rm -rf "$fixture/.bx" "$fixture/.zcrew"
  out=$(
    cd "$fixture" || exit 1
    ZCREW_AUTO_SYNC=0 "$fixture/bin/zcrew" install "$fixture" 2>&1
  ) || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "source == target" || return 1
  printf '%s\n' "$out" | grep -qi "cp: .*same file" && return 1
  [[ -d "$fixture/.bx" ]] || return 1
  [[ -d "$fixture/.zcrew" ]] || return 1
  return 0
}

test_46_resolve_sender_name_readonly_is_pure() {
  local d lib_copy before after mapped unmapped
  d="$(new_test_dir 46)"
  lib_copy="$d/zcrew-lib.sh"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register alpha --paneId 42 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  before="$(sha256sum "$d/.zcrew/registry.json")" || return 1
  source_zcrew_lib "$lib_copy"

  mapped=$(
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZELLIJ_PANE_ID=42 bash -c 'set -euo pipefail; source "$1"; resolve_sender_name_readonly' bash "$lib_copy"
  ) || return 1
  unmapped=$(
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZELLIJ_PANE_ID=99 bash -c 'set -euo pipefail; source "$1"; resolve_sender_name_readonly' bash "$lib_copy"
  ) || return 1
  after="$(sha256sum "$d/.zcrew/registry.json")" || return 1

  [[ "$mapped" == "alpha" ]] || return 1
  [[ -z "$unmapped" ]] || return 1
  [[ "$before" == "$after" ]]
}

test_47_claim_main_for_send_promotes_host_when_main_absent() {
  local d lib_copy
  d="$(new_test_dir 47)"
  lib_copy="$d/zcrew-lib.sh"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register helper --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-99 --paneId 99 --sessionId s99 --agent unknown --cwd "$d" --pid 99 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$d/mock-bin" "$d/tell-args.txt" "99,123"
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 PATH="$d/mock-bin:$PATH" ZELLIJ_PANE_ID=99 ZELLIJ_SESSION_NAME=test-session bash -c 'set -euo pipefail; source "$1"; claim_main_for_send' bash "$lib_copy"
  ) || return 1

  jq -e '.panes.main.paneId == "99" and (.panes | has("pane-99") | not)' "$d/.zcrew/registry.json" >/dev/null
}

test_48_claim_main_for_send_noops_when_live_main_exists() {
  local d lib_copy before after
  d="$(new_test_dir 48)"
  lib_copy="$d/zcrew-lib.sh"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 50 --sessionId s50 --agent unknown --cwd "$d" --pid 50 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-99 --paneId 99 --sessionId s99 --agent unknown --cwd "$d" --pid 99 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$d/mock-bin" "$d/tell-args.txt" "50,99"
  before="$(sha256sum "$d/.zcrew/registry.json")" || return 1
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 PATH="$d/mock-bin:$PATH" ZELLIJ_PANE_ID=99 ZELLIJ_SESSION_NAME=test-session bash -c 'set -euo pipefail; source "$1"; claim_main_for_send' bash "$lib_copy"
  ) || return 1
  after="$(sha256sum "$d/.zcrew/registry.json")" || return 1

  [[ "$before" == "$after" ]]
}

test_49_claim_main_for_send_worker_never_claims() {
  local d lib_copy before after
  d="$(new_test_dir 49)"
  lib_copy="$d/zcrew-lib.sh"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-99 --paneId 99 --sessionId s99 --agent unknown --cwd "$d" --pid 99 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$d/mock-bin" "$d/tell-args.txt" "99"
  before="$(sha256sum "$d/.zcrew/registry.json")" || return 1
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    BX_INSIDE=1 ZCREW_AUTO_SYNC=0 PATH="$d/mock-bin:$PATH" ZELLIJ_PANE_ID=99 ZELLIJ_SESSION_NAME=test-session bash -c 'set -euo pipefail; source "$1"; claim_main_for_send' bash "$lib_copy" >/dev/null
  ) || return 1
  after="$(sha256sum "$d/.zcrew/registry.json")" || return 1

  [[ "$before" == "$after" ]]
}

test_50_send_rejects_self_send() {
  local d mockbin args_file out
  d="$(new_test_dir 50)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0"

  if out=$(cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" send main "hello" 2>&1); then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: cannot send to self' || return 1
  [[ ! -e "$args_file" ]]
}

test_51_send_rejects_worker_to_worker() {
  local d mockbin args_file out
  d="$(new_test_dir 51)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register piper --paneId 123 --sessionId s1 --agent pi --cwd "$d" --pid 2 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77,123"

  if out=$(cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" send piper "hello" 2>&1); then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: worker panes cannot send directly to other workers; send results, questions, or blockers to main' || return 1
  [[ ! -e "$args_file" ]]
}

test_52_send_banner_host_only() {
  local d mockbin args_file sent banner expected
  d="$(new_test_dir 52)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  banner=$'hello host\n\nTo report a result, finding, blocker, or question, run this in your shell/bash tool. Do NOT write it as reply text:\n\n  zcrew send main "<your message>"\n\nCommunicate ONLY with main. Never send to other workers. Never send bare acknowledgments.'
  expected="123 $banner"$'\n''0 hello worker'

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s1 --agent claude --cwd "$d" --pid 2 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77,123"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" send buddy "hello host" >/dev/null 2>&1) || return 1
  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" send main "hello worker" >/dev/null 2>&1) || return 1

  sent="$(cat "$args_file")"
  [[ "$sent" == "$expected" ]]
}

test_53_rename_main_alias_guards() {
  local d out
  d="$(new_test_dir 53)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register foo --paneId 1 --sessionId s1 --agent unknown --cwd "$d" --pid 2 --status alive >/dev/null 2>&1 || return 1
  if out="$(zcrew_cmd "$d" rename main boss 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: cannot rename main alias' || return 1
  if out="$(zcrew_cmd "$d" rename foo main 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: main alias is taken' || return 1

  jq 'del(.panes.main)' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  zcrew_cmd "$d" rename foo main >/dev/null 2>&1 || return 1
  jq -e '.panes.main.paneId == "1" and (.panes | has("foo") | not)' "$d/.zcrew/registry.json" >/dev/null
}

test_54_send_claims_main_after_main_disappears() {
  local d mockbin args_file
  d="$(new_test_dir 54)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register helper --paneId 123 --sessionId s1 --agent claude --cwd "$d" --pid 2 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-88 --paneId 88 --sessionId s88 --agent unknown --cwd "$d" --pid 88 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "88,123"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=88 "$ZCREW_BIN" send helper "hello after restart" >/dev/null 2>&1) || return 1

  jq -e '.panes.main.paneId == "88" and (.panes | has("pane-88") | not)' "$d/.zcrew/registry.json" >/dev/null || return 1
  grep -Fq 'zcrew send main "<your message>"' "$args_file"
}

main() {
  mkdir -p "$TEST_ROOT"

  run_test "0) source files have no hardcoded home path literals" test_0_no_hardcoded_home_paths_in_source_files
  run_test "1) init creates .zcrew with empty registry" test_1_init_creates_registry
  run_test "2) list empty registry (plain + json)" test_2_list_empty_plain_and_json
  run_test "3) register creates then updates entry" test_3_register_create_then_update
  run_test "4) list outside zcrew project fails hard" test_4_list_outside_project_fails_hard
  run_test "5) parallel register keeps all entries" test_5_parallel_register_all_present
  run_test "6) sync --prune removes stale entries with mocked zellij" test_6_sync_prune_with_mocked_zellij
  # SKIP 7: placeholder promotion is for a later step (cmd_spawn currently minimal)
  # run_test "7) placeholder promotion leaves only main" test_7_placeholder_promotion_no_duplicate
  run_test "9) send calls tell with paneId and message" test_9_send_calls_tell_with_expected_args
  run_test "9b) send --compact calls tell twice with a compaction delay" test_9b_send_compact_calls_tell_twice_with_delay
  run_test "9c) send without --compact still calls tell once" test_9c_send_without_compact_calls_tell_once
  run_test "10) sync without prune marks stale but keeps entries" test_10_sync_no_prune_marks_stale_not_delete
  run_test "11) spawn unknown agent uses bx fallback" test_11_spawn_unknown_agent_uses_bx_fallback
  run_test "11b) spawn duplicate name fails before opening a pane" test_11b_spawn_duplicate_name_fails_before_new_pane
  run_test "11c) spawn reuses a name after auto-pruning a stale entry" test_11c_spawn_allows_name_after_pruning_stale_entry
  run_test "11d) spawn fresh name succeeds" test_11d_spawn_fresh_name_succeeds
  run_test "11e) spawn built-in agent uses launcher script" test_11e_spawn_builtin_agent_uses_launcher_script
  run_test "11f) spawn seeds missing managed bx mounts" test_11f_spawn_seeds_missing_managed_mounts
  run_test "11g) spawn repairs managed mounts preserving custom lines" test_11g_spawn_repairs_managed_mounts_preserving_custom_lines
  run_test "12) send outside project fails hard" test_12_send_outside_project_fails_hard
  run_test "12b) stale send suggestion preserves unknown agent name" test_12b_send_stale_unknown_agent_preserves_agent_name_in_suggestion
  run_test "13) rename foo->bar preserves fields and removes old key" test_13_rename_happy_path_preserves_fields
  run_test "14) rename missing old name fails with does not exist" test_14_rename_missing_old_fails
  run_test "15) rename duplicate new name fails with already exists" test_15_rename_duplicate_new_fails
  run_test "16) install leaves missing .claude/settings.json alone" test_16_install_leaves_claude_settings_absent_when_missing
  run_test "17) install deletes settings.json if cleanup leaves empty object" test_17_install_deletes_settings_file_if_cleanup_leaves_empty_object
  run_test "17b) install preserves settings and removes retired SessionStart hook" test_17b_install_preserves_existing_claude_settings_and_removes_retired_hook
  run_test "18) install via symlink writes managed files in canonical target" test_18_install_via_symlink_writes_managed_files_in_canonical_target
  run_test "18b) install writes managed .config/mise.toml floor" test_18b_install_writes_managed_mise_floor
  run_test "18c) reinstall overwrites managed mise floor with canonical root" test_18c_reinstall_overwrites_managed_mise_floor_with_canonical_path
  run_test "18d) install no longer creates .envrc" test_18d_install_does_not_create_envrc
  run_test "18e) install leaves existing .envrc untouched" test_18e_install_preserves_existing_envrc_content
  run_test "18f) install does not invoke mise" test_18f_install_does_not_invoke_mise
  run_test "19) find_project_root uses state from project root" test_19_find_project_root_from_root_uses_local_state
  run_test "20) find_project_root walks up from subdir" test_20_find_project_root_walks_up_from_subdir
  run_test "20b) find_project_root fails outside zcrew tree" test_20b_find_project_root_fails_outside_zcrew_tree
  run_test "21) list auto-sync prunes dead entries by default" test_21_list_auto_sync_prunes_dead_entries
  run_test "22) ZCREW_AUTO_SYNC=0 preserves raw registry state" test_22_list_env_opt_out_preserves_fixture
  run_test "23) spawn implicit sync registers existing live panes before later checks" test_23_spawn_implicit_sync_registers_existing_live_pane
  run_test "24) sync --keep-stale preserves stale entries" test_24_sync_keep_stale_preserves_entries
  run_test "25) zpanes and zsync skills forward \$ARGUMENTS" test_25_skill_passthrough_forwards_arguments
  run_test "26) auto-sync overhead stays under 100ms" test_26_auto_sync_timing_under_100ms
  run_test "27) install writes managed .bx and .zcrew gitignores" test_27_install_writes_managed_gitignores
  run_test "28) second install keeps managed gitignore entries unique" test_28_second_install_keeps_gitignore_entries_unique
  run_test "29) install preserves custom gitignore lines" test_29_install_preserves_custom_gitignore_lines
  run_test "30) install preserves managed gitignore lines in any order" test_30_install_preserves_managed_gitignore_lines_in_any_order
  run_test "31) install writes .pi zcrew and z* skills" test_31_install_writes_pi_skills
  run_test "32) second install overwrites .pi skills with latest content" test_32_second_install_overwrites_pi_skills_with_latest_content
  run_test "32b) install writes lib/zcrew/tell" test_32b_install_writes_internal_tell_binary
  run_test "33) install does not write host ~/.pi or ~/.agents" test_33_install_does_not_write_host_pi_dirs
  run_test "34) installed .pi skills have valid required frontmatter" test_34_pi_skill_frontmatter_sanity
  run_test "34b) install writes canonical .agents zcrew skill plus symlinked codex/pi views" test_34b_install_writes_cross_tool_zcrew_skill_layout
  run_test "34c) second install overwrites .codex zcrew skill" test_34c_second_install_overwrites_codex_skill_with_latest_content
  run_test "34d) installed .codex zcrew skill has simplified frontmatter" test_34d_codex_skill_frontmatter_sanity
  run_test "34e) install writes AGENTS.md and CLAUDE.md symlink when both are missing" test_34e_install_seeds_agents_and_claude_symlink_when_both_missing
  run_test "34f) install skips AGENTS.md and CLAUDE.md when AGENTS.md already exists" test_34f_install_skips_agents_and_claude_when_agents_exists
  run_test "34g) install writes AGENTS.md only when CLAUDE.md already exists" test_34g_install_writes_agents_only_when_claude_exists
  run_test "34h) install seeds .zcrew/team.conf template" test_34h_install_seeds_team_conf_template
  run_test "34i) reinstall preserves existing .zcrew/team.conf" test_34i_reinstall_preserves_existing_team_conf
  run_test "35) send to claude target refreshes auth in .bx/home" test_35_send_claude_target_refreshes_auth_files
  run_test "36) send to codex target skips claude auth refresh" test_36_send_codex_target_skips_claude_auth_refresh
  run_test "37) send to unknown target skips claude auth refresh" test_37_send_unknown_target_skips_claude_auth_refresh
  run_test "38) send with missing host .claude.json generates minimal target state" test_38_send_missing_host_claude_json_generates_minimal_target_state
  run_test "39) send with missing host credentials soft-fails" test_39_send_missing_host_credentials_soft_fails
  run_test "40) send without target .bx/home soft-fails" test_40_send_without_target_bx_home_soft_fails
  run_test "41) successful claude auth refresh leaves no tmp files" test_41_send_claude_refresh_leaves_no_tmp_files
  run_test "42) codex launcher runs bx codex without inline trust override" test_42_codex_launcher_preseeds_trust_entry_in_sandbox_config
  run_test "43) codex launcher forwards model to bx run" test_43_codex_launcher_forwards_model_to_bx_run
  run_test "44) codex launcher does not mutate sandbox config before bx run" test_44_codex_launcher_does_not_mutate_sandbox_config_before_bx_run
  run_test "45) install where src == target skips materialization without crashing" test_45_install_self_install_no_crash
  run_test "46) resolve_sender_name_readonly is pure and returns empty for unmapped panes" test_46_resolve_sender_name_readonly_is_pure
  run_test "47) claim_main_for_send promotes host pane to main when main is absent" test_47_claim_main_for_send_promotes_host_when_main_absent
  run_test "48) claim_main_for_send no-ops when a live main exists" test_48_claim_main_for_send_noops_when_live_main_exists
  run_test "49) claim_main_for_send no-ops inside workers" test_49_claim_main_for_send_worker_never_claims
  run_test "50) send rejects self-send" test_50_send_rejects_self_send
  run_test "51) send rejects worker-to-worker delivery" test_51_send_rejects_worker_to_worker
  run_test "52) send banner is host-only with exact literal" test_52_send_banner_host_only
  run_test "53) rename guards main alias" test_53_rename_main_alias_guards
  run_test "54) send reclaims main after host restart" test_54_send_claims_main_after_main_disappears

  echo ""
  echo "Total: $PASS_COUNT PASS, $FAIL_COUNT FAIL"

  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
