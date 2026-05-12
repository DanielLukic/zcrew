#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZCREW_BIN="$REPO_ROOT/.zcrew/bin/zcrew"
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

dryrun_install_cmd() {
  local d="$1"
  shift
  (
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" install "$@"
  )
}

snapshot_tree_state() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -printf '%P\t%TY-%Tm-%TdT%TH:%TM:%TS\t%s\t%y\n' | LC_ALL=C sort
}

plan_section() {
  local title="$1"
  awk -v title="$title" '
    $0 == title { in_section = 1; next }
    in_section && $0 ~ /^(REPLACE|KEEP|SKIP)$/ { exit }
    in_section { print }
  '
}

make_mock_systemctl() {
  local bindir="$1"
  local args_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_SYSTEMCTL_ARGS_FILE:?MOCK_SYSTEMCTL_ARGS_FILE is required}"
printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_ARGS_FILE"
exit 0
MOCK
  chmod +x "$bindir/systemctl"
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
  ! rg -n "$needle" "$REPO_ROOT/.zcrew/bin" "$REPO_ROOT/.zcrew/lib" "$REPO_ROOT/tests" >/dev/null
}

clear_mx_backend_state() {
  unset _MX_BACKEND _MX_BACKEND_CHECKED
}

test_xmx_a_multiplexer_lazy_init_sets_backend_only_on_first_use() {
  local out
  clear_mx_backend_state
  out="$(
    env -u TMUX ZELLIJ_SESSION_NAME=test-session bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      [[ -z "${_MX_BACKEND:-}" ]]
      _mx_ensure_init
      [[ "${_MX_BACKEND:-}" == "zellij" ]]
      printf "ok\n"
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
  )" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
  [[ "$out" == "ok" ]]
}

test_xmx_b_sourcing_without_mux_does_not_error_and_register_still_succeeds() {
  local d out
  d="$(new_test_dir xmx-b)"
  clear_mx_backend_state
  out="$(
    env -u ZELLIJ_SESSION_NAME -u TMUX bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      [[ -z "${_MX_BACKEND:-}" ]]
      printf "ok\n"
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
  )" || { clear_mx_backend_state; return 1; }
  [[ "$out" == "ok" ]] || { clear_mx_backend_state; return 1; }

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  (
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_SESSION_NAME -u TMUX ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" register lazy --paneId 1 --sessionId s1 --agent claude --cwd "$d" --pid 1 --status alive
  ) >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_c_operational_call_errors_when_both_mux_envs_are_set() {
  local out
  clear_mx_backend_state
  if out="$(
    env TMUX=/tmp/tmux-1/default,123,0 ZELLIJ_SESSION_NAME=test-session bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_pane_id
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh" 2>&1
  )"; then
    clear_mx_backend_state
    return 1
  fi
  clear_mx_backend_state
  printf '%s\n' "$out" | grep -Fq 'ZELLIJ_SESSION_NAME and TMUX are both set; nested session unsupported'
}

test_xmx_d_require_session_errors_when_no_mux_env_is_set() {
  local out
  clear_mx_backend_state
  if out="$(
    env -u ZELLIJ_SESSION_NAME -u TMUX bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_require_session
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh" 2>&1
  )"; then
    clear_mx_backend_state
    return 1
  fi
  clear_mx_backend_state
  printf '%s\n' "$out" | grep -Fq 'this command requires a multiplexer session; ZELLIJ_SESSION_NAME and TMUX are both unset'
}

test_xmx_e_register_and_unregister_succeed_when_both_mux_envs_are_set() {
  local d
  d="$(new_test_dir xmx-e)"
  clear_mx_backend_state
  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }

  (
    cd "$d" || exit 1
    env -u BX_INSIDE TMUX=/tmp/tmux-1/default,123,0 ZELLIJ_SESSION_NAME=test-session ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" register dual --paneId 2 --sessionId s2 --agent claude --cwd "$d" --pid 2 --status alive
  ) >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  (
    cd "$d" || exit 1
    env -u BX_INSIDE TMUX=/tmp/tmux-1/default,123,0 ZELLIJ_SESSION_NAME=test-session ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" unregister dual
  ) >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_f_backend_written_on_first_mux_op() {
  local d lib_copy out
  d="$(new_test_dir xmx-f)"
  lib_copy="$d/zcrew-lib.sh"
  clear_mx_backend_state

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  source_zcrew_lib "$lib_copy"
  make_mock_zellij "$d/mock-bin"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE -u TMUX PATH="$d/mock-bin:$PATH" ZCREW_AUTO_SYNC=0 ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=11 bash -c '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      _resolve_and_set_project_dir stateful
      ensure_registry_files
      mx_pane_id
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$lib_copy"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "11" ]] || { clear_mx_backend_state; return 1; }
  jq -e '.backend == "zellij"' "$d/.zcrew/registry.json" >/dev/null || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_g_backend_not_written_on_register() {
  local d
  d="$(new_test_dir xmx-g)"
  clear_mx_backend_state

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  (
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_SESSION_NAME -u TMUX ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" register plain --paneId 12 --sessionId s12 --agent claude --cwd "$d" --pid 12 --status alive
  ) >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }

  jq -e 'has("backend") | not' "$d/.zcrew/registry.json" >/dev/null || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_h_backend_no_reset_same_mux() {
  local d lib_copy before out
  d="$(new_test_dir xmx-h)"
  lib_copy="$d/zcrew-lib.sh"
  clear_mx_backend_state

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  zcrew_cmd "$d" register helper --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  jq '.backend = "zellij"' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || { clear_mx_backend_state; return 1; }
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  before="$(sha256sum "$d/.zcrew/registry.json")" || { clear_mx_backend_state; return 1; }
  source_zcrew_lib "$lib_copy"
  make_mock_zellij "$d/mock-bin"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE -u TMUX PATH="$d/mock-bin:$PATH" ZCREW_AUTO_SYNC=0 ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=123 bash -c '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      _resolve_and_set_project_dir stateful
      ensure_registry_files
      mx_pane_id
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$lib_copy"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "123" ]] || { clear_mx_backend_state; return 1; }
  [[ "$before" == "$(sha256sum "$d/.zcrew/registry.json")" ]] || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_i_backend_reset_wipes_panes_and_audits() {
  local d lib_copy out
  d="$(new_test_dir xmx-i)"
  lib_copy="$d/zcrew-lib.sh"
  clear_mx_backend_state

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  zcrew_cmd "$d" register helper --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  jq '.backend = "zellij"' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || { clear_mx_backend_state; return 1; }
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  source_zcrew_lib "$lib_copy"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_SESSION_NAME TMUX=/tmp/tmux-1/default,123,0 TMUX_PANE=%456 ZCREW_AUTO_SYNC=0 bash -c '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      _resolve_and_set_project_dir stateful
      ensure_registry_files
      mx_pane_id
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$lib_copy" 2>&1
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == *$'456'* ]] || { clear_mx_backend_state; return 1; }
  jq -e '.backend == "tmux" and .panes == {}' "$d/.zcrew/registry.json" >/dev/null || { clear_mx_backend_state; return 1; }
  grep -Fq $'backend-reset\twarn\tfrom=zellij to=tmux reason=mux-switch' "$d/.zcrew/audit.log" || { clear_mx_backend_state; return 1; }
  printf '%s\n' "$out" | grep -Fq 'zcrew: multiplexer changed (zellij → tmux); registry reset. Old workers are orphaned.' || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_j_backend_legacy_adopts_on_first_mux_op() {
  local d lib_copy out
  d="$(new_test_dir xmx-j)"
  lib_copy="$d/zcrew-lib.sh"
  clear_mx_backend_state

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  zcrew_cmd "$d" register helper --paneId 123 --sessionId s --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  source_zcrew_lib "$lib_copy"
  make_mock_zellij "$d/mock-bin"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE -u TMUX PATH="$d/mock-bin:$PATH" ZCREW_AUTO_SYNC=0 ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=123 bash -c '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      _resolve_and_set_project_dir stateful
      ensure_registry_files
      mx_pane_id
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$lib_copy"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "123" ]] || { clear_mx_backend_state; return 1; }
  jq -e '.backend == "zellij" and .panes.helper.paneId == "123"' "$d/.zcrew/registry.json" >/dev/null || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_k_spawn_tmux_split_window_parses_pct_pane_id() {
  local d mockbin args_file out
  d="$(new_test_dir xmx-k)"
  mockbin="$d/mock-bin"
  args_file="$d/tmux-args.txt"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  out="$(
    env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 TMUX_PANE=%42 MOCK_TMUX_ARGS_FILE="$args_file" MOCK_TMUX_SESSION_NAME=sess bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_new_pane "/tmp/project" "worker" "echo hi"
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "5" ]] || { clear_mx_backend_state; return 1; }
  grep -Fqx "split-window -d -P -F #{pane_id} -c /tmp/project -t %42 -- bash -c echo hi" "$args_file" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_kb_spawn_tmux_sets_pane_title_after_spawn() {
  local d mockbin args_file out
  d="$(new_test_dir xmx-kb)"
  mockbin="$d/mock-bin"
  args_file="$d/tmux-args.txt"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  out="$(
    env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 TMUX_PANE=%42 MOCK_TMUX_ARGS_FILE="$args_file" MOCK_TMUX_SESSION_NAME=sess bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_new_pane "/tmp/project" "worker" "echo hi"
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "5" ]] || { clear_mx_backend_state; return 1; }
  grep -Fqx "select-pane -t %5 -T worker" "$args_file" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_kc_spawn_tmux_tiles_layout_after_spawn() {
  local d mockbin args_file out
  d="$(new_test_dir xmx-kc)"
  mockbin="$d/mock-bin"
  args_file="$d/tmux-args.txt"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  out="$(
    env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 TMUX_PANE=%42 MOCK_TMUX_ARGS_FILE="$args_file" MOCK_TMUX_SESSION_NAME=sess bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_new_pane "/tmp/project" "worker" "echo hi"
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "5" ]] || { clear_mx_backend_state; return 1; }
  grep -Fqx "select-layout tiled" "$args_file" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_l_close_tmux_kill_pane_with_pct_prefix() {
  local d mockbin args_file
  d="$(new_test_dir xmx-l)"
  mockbin="$d/mock-bin"
  args_file="$d/tmux-args.txt"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 MOCK_TMUX_ARGS_FILE="$args_file" MOCK_TMUX_SESSION_NAME=sess bash -lc '
    set -euo pipefail
    unset _MX_BACKEND _MX_BACKEND_CHECKED
    source "$1"
    mx_close_pane "5"
    unset _MX_BACKEND _MX_BACKEND_CHECKED
  ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh" >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }

  grep -Fqx "kill-pane -t %5" "$args_file" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_m_list_tmux_strips_percent_from_all_ids() {
  local d mockbin out
  d="$(new_test_dir xmx-m)"
  mockbin="$d/mock-bin"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  out="$(
    env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 MOCK_TMUX_SESSION_NAME=sess MOCK_TMUX_LIST_OUTPUT=$'%5 sess\n%7 sess\n%8 other' bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_list_pane_ids
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
  )" || { clear_mx_backend_state; return 1; }

  [[ "$out" == $'5\n7' ]] || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_n_rename_tmux_select_pane_T() {
  local d mockbin args_file
  d="$(new_test_dir xmx-n)"
  mockbin="$d/mock-bin"
  args_file="$d/tmux-args.txt"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 MOCK_TMUX_ARGS_FILE="$args_file" MOCK_TMUX_SESSION_NAME=sess bash -lc '
    set -euo pipefail
    unset _MX_BACKEND _MX_BACKEND_CHECKED
    source "$1"
    mx_rename_pane "5" "name"
    unset _MX_BACKEND _MX_BACKEND_CHECKED
  ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh" >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }

  grep -Fqx "select-pane -t %5 -T name" "$args_file" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_nb_send_tmux_uses_bracketed_paste_and_cr() {
  local d mockbin args_file out start_ns end_ns elapsed_ms
  local payload
  d="$(new_test_dir xmx-nb)"
  mockbin="$d/mock-bin"
  args_file="$d/tmux-args.txt"
  payload=$'\n\nReply from claudio:\nline one\nline two'
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  start_ns="$(date +%s%N)"
  out="$(
    (
      set -euo pipefail
      export PATH="$mockbin:$PATH"
      export TMUX=/tmp/tmux.sock,123,0
      export MOCK_TMUX_ARGS_FILE="$args_file"
      export MOCK_TMUX_SESSION_NAME=sess
      unset ZELLIJ_SESSION_NAME BASH_ENV ENV REGISTRY_FILE PROJECT_DIR _MX_BACKEND _MX_BACKEND_CHECKED
      source "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
      mx_send_text "5" "$payload"
      unset _MX_BACKEND _MX_BACKEND_CHECKED
    )
  )" || { clear_mx_backend_state; return 1; }
  end_ns="$(date +%s%N)"
  elapsed_ms="$(( (end_ns - start_ns) / 1000000 ))"

  [[ -z "$out" ]] || { clear_mx_backend_state; return 1; }
  python3 - "$args_file" <<'PY' || { clear_mx_backend_state; return 1; }
import pathlib
import sys

payload = b"\n\nReply from claudio:\nline one\nline two"
expected = b"send-keys -t %5 -l -- \x1b[200~" + payload + b"\x1b[201~\nsend-keys -t %5 C-m\n"
data = pathlib.Path(sys.argv[1]).read_bytes()
if data != expected:
    raise SystemExit(f"unexpected mock args bytes: {data!r}")
PY
  [[ "$elapsed_ms" -ge 100 ]] || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_o_claim_uses_tmux_pane_stripped() {
  local d mockbin out
  d="$(new_test_dir xmx-o)"
  mockbin="$d/mock-bin"
  clear_mx_backend_state
  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  make_mock_multiplexer tmux "$mockbin"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 TMUX_PANE=%42 MOCK_TMUX_SESSION_NAME=sess MOCK_TMUX_LIST_OUTPUT='%42 sess' "$ZCREW_BIN" claim 2>&1
  )" || { clear_mx_backend_state; return 1; }

  [[ -z "$out" ]] || { clear_mx_backend_state; return 1; }
  jq -e '.panes.main.paneId == "42"' "$d/.zcrew/registry.json" >/dev/null || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_p_session_check_tmux_stale_hard_errors() {
  local d mockbin out
  d="$(new_test_dir xmx-p)"
  mockbin="$d/mock-bin"
  clear_mx_backend_state
  make_mock_multiplexer tmux "$mockbin"

  if out="$(
    env -u ZELLIJ_SESSION_NAME PATH="$mockbin:$PATH" TMUX=/tmp/tmux.sock,123,0 MOCK_TMUX_SESSION_NAME=sess MOCK_TMUX_LIST_SESSIONS_OUTPUT=other bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      mx_require_session
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh" 2>&1
  )"; then
    clear_mx_backend_state
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq "TMUX session 'sess' is stale" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_xmx_q_tmux_transport_text_matrix() {
  clear_mx_backend_state
  (
    set -euo pipefail
    command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not available"; exit 0; }

    local tmpdir socket capture_file pane_id pane_ref captured payload
    tmpdir="$(mktemp -d)"
    socket="$tmpdir/tmux.sock"
    capture_file="$tmpdir/inbox.txt"
    payload=$'\n\nReply from claudio:\nline one\nline two'

    cleanup_tmux_matrix() {
      tmux -S "$socket" kill-session -t zcrew-test >/dev/null 2>&1 || true
      rm -rf "$tmpdir"
      clear_mx_backend_state
    }
    trap cleanup_tmux_matrix EXIT

    tmux -S "$socket" -f /dev/null new-session -d -s zcrew-test -x 220 -y 50 /bin/sh
    pane_id="$(tmux -S "$socket" list-panes -t zcrew-test -F '#{pane_id}' | sed 's/^%//')" || exit 1
    pane_ref="%$pane_id"
    tmux -S "$socket" send-keys -t zcrew-test "cat > '$capture_file'" C-m
    sleep 0.3

    send_tmux_matrix() {
      local payload="$1"
      (
        set -euo pipefail
        export TMUX="$socket,0,0"
        export TMUX_PANE="$pane_ref"
        unset ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID BASH_ENV ENV REGISTRY_FILE PROJECT_DIR _MX_BACKEND _MX_BACKEND_CHECKED
        source "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
        mx_send_text "$pane_id" "$payload"
      )
      sleep 0.3
    }

    capture_tmux_matrix() {
      tmux -S "$socket" capture-pane -p -t zcrew-test
    }

    send_tmux_matrix "$payload"

    captured="$(capture_tmux_matrix)"
    grep -Fq "Reply from claudio:" <<< "$captured" || exit 1
    grep -Fq "line one" <<< "$captured" || exit 1
    grep -Fq "line two" <<< "$captured" || exit 1
    [[ "$captured" == *$'\n\nReply from claudio:\nline one\nline two'* ]] || exit 1

    python3 - "$capture_file" <<'PY'
import sys
path = sys.argv[1]
payload = b"\n\nReply from claudio:\nline one\nline two"
# tmux delivers C-m to the pane, but the tty running `cat` canonicalizes it to a
# trailing newline in the captured file.
expected = b"\x1b[200~" + payload + b"\x1b[201~\n"
data = open(path, "rb").read()
if data != expected:
    raise SystemExit(f"unexpected bytes: {data!r}")
PY
  )
  local status=$?
  clear_mx_backend_state
  return "$status"
}

make_mock_multiplexer() {
  local backend="$1"
  local bindir="$2"
  local arg3="${3:-}"
  local arg4="${4:-}"
  local arg5="${5:-}"
  local arg6="${6:-}"
  mkdir -p "$bindir"
  case "$backend" in
    zellij)
      local list_output="$arg3"
      local child_pane_id="${arg4:-777}"
      local args_file="${arg5:-}"
      local new_pane_output="${arg6:-terminal_777}"
      cat > "$bindir/zellij" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

# inputs passed via env from test harness
LIST_OUTPUT="${MOCK_ZELLIJ_LIST_OUTPUT:-}"
CHILD_PANE_ID="${MOCK_ZELLIJ_CHILD_PANE_ID:-777}"
LIST_SESSIONS_OUTPUT="${MOCK_ZELLIJ_SESSIONS_OUTPUT:-test-session}"
CLOSE_LOG_FILE="${MOCK_ZELLIJ_CLOSE_LOG_FILE:-}"
: "${MOCK_ZELLIJ_ARGS_FILE:=}"
NEW_PANE_OUTPUT="${MOCK_ZELLIJ_NEW_PANE_OUTPUT:-terminal_777}"

case "${1:-}" in
  list-sessions)
    printf '%s\n' "$LIST_SESSIONS_OUTPUT"
    ;;
  action)
    if [[ -n "$MOCK_ZELLIJ_ARGS_FILE" ]]; then
      printf '%s\n' "$*" >> "$MOCK_ZELLIJ_ARGS_FILE"
    fi
    shift
    case "${1:-}" in
      list-panes)
        printf '%s\n' "$LIST_OUTPUT"
        ;;
      close-pane)
        if [[ -n "$CLOSE_LOG_FILE" ]]; then
          printf '%s\n' "$*" >> "$CLOSE_LOG_FILE"
        fi
        ;;
      new-pane)
        if [[ -n "$MOCK_ZELLIJ_ARGS_FILE" ]]; then
          printf '%s\n' "$NEW_PANE_OUTPUT"
        else
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
        fi
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
      if [[ -n "$list_output" ]]; then
        : "${MOCK_ZELLIJ_LIST_OUTPUT:=$list_output}"
      fi
      if [[ -n "$child_pane_id" ]]; then
        : "${MOCK_ZELLIJ_CHILD_PANE_ID:=$child_pane_id}"
      fi
      if [[ -n "$args_file" ]]; then
        : "${MOCK_ZELLIJ_ARGS_FILE:=$args_file}"
      fi
      if [[ -n "$new_pane_output" ]]; then
        : "${MOCK_ZELLIJ_NEW_PANE_OUTPUT:=$new_pane_output}"
      fi
      ;;
    tmux)
      cat > "$bindir/tmux" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

TMUX_ARGS_FILE="${MOCK_TMUX_ARGS_FILE:-}"
TMUX_LIST_OUTPUT="${MOCK_TMUX_LIST_OUTPUT:-}"
TMUX_SESSION_NAME="${MOCK_TMUX_SESSION_NAME:-sess}"
TMUX_LIST_SESSIONS_OUTPUT="${MOCK_TMUX_LIST_SESSIONS_OUTPUT:-$TMUX_SESSION_NAME}"

if [[ -n "$TMUX_ARGS_FILE" ]]; then
  printf '%s\n' "$*" >> "$TMUX_ARGS_FILE"
fi

case "${1:-}" in
  split-window)
    printf '%%5\n'
    ;;
  kill-pane)
    ;;
  select-pane)
    ;;
  select-layout)
    ;;
  list-panes)
    printf '%s\n' "$TMUX_LIST_OUTPUT"
    ;;
  send-keys)
    if [[ " $* " != *" C-m "* && " $* " != *" -l "* ]]; then
      echo "mock tmux: send-keys must be either literal paste or C-m submit" >&2
      exit 91
    fi
    ;;
  display-message)
    if [[ "${2:-}" == "-p" && "${3:-}" == "#S" ]]; then
      printf '%s\n' "$TMUX_SESSION_NAME"
      exit 0
    fi
    exit 1
    ;;
  show-options)
    if [[ "${2:-}" == "-gv" && "${3:-}" == "pane-border-status" ]]; then
      printf '%s\n' "${MOCK_TMUX_PANE_BORDER_STATUS:-top}"
      exit 0
    fi
    exit 1
    ;;
  list-sessions)
    if [[ "${2:-}" == "-F" && "${3:-}" == "#{session_name}" ]]; then
      printf '%s\n' "$TMUX_LIST_SESSIONS_OUTPUT"
      exit 0
    fi
    exit 1
    ;;
  *)
    ;;
esac
MOCK
      chmod +x "$bindir/tmux"
      ;;
    *)
      echo "unknown multiplexer backend: $backend" >&2
      return 1
      ;;
  esac
}

make_mock_zellij() {
  local bindir="$1"
  local list_output="${2:-}"
  local child_pane_id="${3:-777}"
  make_mock_multiplexer zellij "$bindir" "$list_output" "$child_pane_id"
}

make_mock_zellij_spawn() {
  local bindir="$1"
  local args_file="$2"
  make_mock_multiplexer zellij "$bindir" "" "777" "$args_file" "terminal_777"
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

  seed_local_lib_fixture "$project_dir"
  make_mock_tell "$project_dir/.zcrew/lib/tell" "$args_file"
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
      "$REPO_ROOT/.zcrew/lib/launchers/codex.sh" >/dev/null 2>&1
  )
}

read_proc_starttime() {
  local pid="$1"
  local raw tail
  raw="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  tail="${raw##*) }"
  awk -v t="$tail" 'BEGIN{n=split(t,a," "); if (n < 20) exit 1; print a[20]}'
}

source_zcrew_lib() {
  local lib_copy="$1"
  local test_lib_dir
  test_lib_dir="$(dirname "$lib_copy")/../lib"
  mkdir -p "$test_lib_dir"
  test_lib_dir="$(cd "$test_lib_dir" && pwd)"
  cp "$REPO_ROOT/.zcrew/lib/multiplexer.sh" "$test_lib_dir/multiplexer.sh"
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

seed_stale_zcrew_layout() {
  local target="$1"
  mkdir -p "$target/bin" "$target/lib/zcrew/launchers"
  cp "$REPO_ROOT/.zcrew/bin/zcrew" "$target/bin/zcrew"
  cp "$REPO_ROOT/.zcrew/bin/bx" "$target/bin/bx"
  cp "$REPO_ROOT/.zcrew/bin/ix" "$target/bin/ix"
  cp "$REPO_ROOT/.zcrew/lib/tell" "$target/lib/zcrew/tell"
  cp "$REPO_ROOT/.zcrew/lib/multiplexer.sh" "$target/lib/zcrew/multiplexer.sh"
  cp "$REPO_ROOT/.zcrew/lib/launchers/claude.sh" "$target/lib/zcrew/launchers/claude.sh"
  cp "$REPO_ROOT/.zcrew/lib/launchers/codex.sh" "$target/lib/zcrew/launchers/codex.sh"
  cp "$REPO_ROOT/.zcrew/lib/launchers/pi.sh" "$target/lib/zcrew/launchers/pi.sh"
  chmod +x "$target/bin/zcrew" "$target/bin/bx" "$target/bin/ix" \
    "$target/lib/zcrew/tell" "$target/lib/zcrew/launchers/claude.sh" \
    "$target/lib/zcrew/launchers/codex.sh" "$target/lib/zcrew/launchers/pi.sh"
}

assert_managed_zcrew_layout() {
  local target="$1"
  [[ -x "$target/.zcrew/bin/zcrew" ]] || return 1
  [[ -x "$target/.zcrew/bin/bx" ]] || return 1
  [[ -x "$target/.zcrew/bin/ix" ]] || return 1
  [[ -x "$target/.zcrew/lib/tell" ]] || return 1
  [[ -r "$target/.zcrew/lib/multiplexer.sh" ]] || return 1
  [[ -x "$target/.zcrew/lib/launchers/claude.sh" ]] || return 1
  [[ -x "$target/.zcrew/lib/launchers/codex.sh" ]] || return 1
  [[ -x "$target/.zcrew/lib/launchers/pi.sh" ]]
}

seed_local_lib_fixture() {
  local target="$1"
  mkdir -p "$target/.zcrew/lib/launchers"
  cp "$REPO_ROOT/.zcrew/lib/tell" "$target/.zcrew/lib/tell"
  cp "$REPO_ROOT/.zcrew/lib/mcp_server.py" "$target/.zcrew/lib/mcp_server.py"
  cp "$REPO_ROOT/.zcrew/lib/multiplexer.sh" "$target/.zcrew/lib/multiplexer.sh"
  cp "$REPO_ROOT/.zcrew/lib/stop-hook.sh" "$target/.zcrew/lib/stop-hook.sh"
  cp "$REPO_ROOT/.zcrew/lib/codex-auto-reply.mjs" "$target/.zcrew/lib/codex-auto-reply.mjs"
  cp "$REPO_ROOT/.zcrew/lib/pi-zcrew-ext.ts" "$target/.zcrew/lib/pi-zcrew-ext.ts"
  cp "$REPO_ROOT/.zcrew/lib/launchers/claude.sh" "$target/.zcrew/lib/launchers/claude.sh"
  cp "$REPO_ROOT/.zcrew/lib/launchers/codex.sh" "$target/.zcrew/lib/launchers/codex.sh"
  cp "$REPO_ROOT/.zcrew/lib/launchers/pi.sh" "$target/.zcrew/lib/launchers/pi.sh"
  chmod +x "$target/.zcrew/lib/tell" \
    "$target/.zcrew/lib/stop-hook.sh" \
    "$target/.zcrew/lib/codex-auto-reply.mjs" \
    "$target/.zcrew/lib/launchers/claude.sh" \
    "$target/.zcrew/lib/launchers/codex.sh" \
    "$target/.zcrew/lib/launchers/pi.sh"
}

seed_local_tell_sentinel() {
  local target="$1"
  seed_local_lib_fixture "$target"
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
  printf '%s\n' "$out" | grep -q 'zcrew: no zcrew project here'
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
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_123' "$ZCREW_BIN" sync >/dev/null 2>&1
  ) || return 1

  jq -e '.panes | has("live") and (has("stale")|not)' "$d/.zcrew/registry.json" >/dev/null
}

test_6b_reconcile_inside_bx_is_noop() {
  local d before after
  d="$(new_test_dir 6b)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register claudio --paneId 11 --sessionId s11 --agent claude --cwd "$d" --pid 11 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register sam --paneId 12 --sessionId s12 --agent codex --cwd "$d" --pid 12 --status alive >/dev/null 2>&1 || return 1
  before="$(sha256sum "$d/.zcrew/registry.json")" || return 1

  (
    cd "$d" || exit 1
    BX_INSIDE=1 "$ZCREW_BIN" sync >/dev/null 2>&1
  ) || return 1
  after="$(sha256sum "$d/.zcrew/registry.json")" || return 1

  [[ "$before" == "$after" ]]
}

test_6c_sync_prune_empty_live_set_warns_and_preserves_registry() {
  local d mockbin out
  d="$(new_test_dir 6c)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register claudio --paneId 11 --sessionId s11 --agent claude --cwd "$d" --pid 11 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin" ""

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" "$ZCREW_BIN" sync 2>&1
  )" || return 1

  jq -e '.panes.claudio.paneId == "11"' "$d/.zcrew/registry.json" >/dev/null || return 1
  printf '%s\n' "$out" | grep -Fxq 'warning: multiplexer returned no live panes; preserving non-empty registry'
}

test_6d_sync_prune_preserves_named_aliases_for_live_panes() {
  local d mockbin
  d="$(new_test_dir 6d)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register claudio --paneId 11 --sessionId s11 --agent claude --cwd "$d" --pid 11 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register sam --paneId 12 --sessionId s12 --agent codex --cwd "$d" --pid 12 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin" $'terminal_11\nterminal_12'

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT=$'terminal_11\nterminal_12' "$ZCREW_BIN" sync >/dev/null 2>&1
  ) || return 1

  jq -e '
    (.panes.claudio.paneId == "11") and
    (.panes.sam.paneId == "12") and
    (.panes | has("pane-11") | not) and
    (.panes | has("pane-12") | not)
  ' "$d/.zcrew/registry.json" >/dev/null
}

test_7_placeholder_promotion_no_duplicate() {
  local d mockbin
  d="$(new_test_dir 7)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/bin"
  mkdir -p "$d/.zcrew/bin"
  ln -sf "$ZCREW_BIN" "$d/.zcrew/bin/zcrew"
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
  seed_local_lib_fixture "$d"
  make_mock_tell "$d/.zcrew/lib/tell" "$args_file"
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
  # Claude target gets NO footer — message is verbatim.
  [[ "$sent" == "123 hello world" ]]
}


test_9h_send_refuses_target_registered_in_different_project() {
  local d other_project mockbin args_file out
  d="$(new_test_dir 9h)"
  other_project="$(new_test_dir 9h-other)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$other_project" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$other_project" --pid 1 --status alive >/dev/null 2>&1 || return 1
  jq --arg other "$(realpath "$other_project")" '.panes.buddy.projectDir = $other' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  if out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello wrong project" 2>&1
  )"; then
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq "zcrew: refusing to send to pane 'buddy' registered in a different project." || return 1
  printf '%s\n' "$out" | grep -Fq "$(realpath "$d")" || return 1
  printf '%s\n' "$out" | grep -Fq "$(realpath "$other_project")" || return 1
  [[ ! -f "$args_file" ]]
}

test_9i_send_backfills_legacy_entry_when_cwd_resolves_to_same_project() {
  local d subdir mockbin args_file sent
  d="$(new_test_dir 9i)"
  subdir="$d/work/subdir"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  mkdir -p "$subdir"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$subdir" --pid 1 --status alive >/dev/null 2>&1 || return 1
  jq 'del(.panes.buddy.projectDir)' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello legacy backfill" >/dev/null 2>&1
  ) || return 1

  sent="$(sed -n '1p' "$args_file")"
  [[ "$sent" == "123 hello legacy backfill" ]] || return 1
  jq -e --arg project "$(realpath "$d")" '.panes.buddy.projectDir == $project' "$d/.zcrew/registry.json" >/dev/null
}

test_9j_send_refuses_legacy_entry_when_cwd_resolves_to_different_project() {
  local d other_project mockbin args_file out
  d="$(new_test_dir 9j)"
  other_project="$(new_test_dir 9j-other)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$other_project" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$other_project" --pid 1 --status alive >/dev/null 2>&1 || return 1
  jq 'del(.panes.buddy.projectDir)' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  if out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello legacy mismatch" 2>&1
  )"; then
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq "zcrew: refusing to send to pane 'buddy' registered in a different project." || return 1
  printf '%s\n' "$out" | grep -Fq "$(realpath "$other_project")" || return 1
  [[ ! -f "$args_file" ]]
}

test_9k_send_refuses_legacy_entry_when_project_ownership_is_unknown() {
  local d foreign_dir mockbin args_file out
  d="$(new_test_dir 9k)"
  foreign_dir="$(new_test_dir 9k-foreign)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent claude --cwd "$foreign_dir" --pid 1 --status alive >/dev/null 2>&1 || return 1
  jq 'del(.panes.buddy.projectDir)' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  if out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "hello legacy unknown" 2>&1
  )"; then
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq "zcrew: project ownership for pane 'buddy' is unknown; respawn pane." || return 1
  [[ ! -f "$args_file" ]]
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
  printf '%s\n' "$second" | grep -q '123 hello compact'
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

test_9d_send_slash_command_skips_banner_from_host() {
  local d mockbin args_file sent
  d="$(new_test_dir 9d)"
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
      "$ZCREW_BIN" send buddy "/compact" >/dev/null 2>&1
  ) || return 1

  sent="$(cat "$args_file")"
  [[ "$sent" == '123 /compact' ]] || return 1
  ! grep -Fq 'To report a result, finding, blocker, or question' "$args_file"
}

test_9e_send_arbitrary_slash_command_skips_banner_from_host() {
  local d mockbin args_file sent
  d="$(new_test_dir 9e)"
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
      "$ZCREW_BIN" send buddy "/anything" >/dev/null 2>&1
  ) || return 1

  sent="$(cat "$args_file")"
  [[ "$sent" == '123 /anything' ]] || return 1
  ! grep -Fq 'To report a result, finding, blocker, or question' "$args_file"
}

test_9f_send_path_like_message_keeps_banner_from_host() {
  local d mockbin args_file sent
  d="$(new_test_dir 9f)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  # Use an unknown-agent worker because claude/codex no longer get a footer
  # (auto-reply mechanisms cover them) and pi has its own short footer.
  # Unknown agents fall through to the verbose fallback footer.
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" \
      ZELLIJ_SESSION_NAME="test-session" \
      ZELLIJ_PANE_ID="0" \
      "$ZCREW_BIN" send buddy "/path/to/file" >/dev/null 2>&1
  ) || return 1

  sent="$(cat "$args_file")"
  [[ "$sent" == 123\ /path/to/file* ]] || return 1
  # path-like slash message is treated as regular text, so fallback footer is appended.
  grep -Fq 'mcp__zcrew__zcrew_reply' "$args_file"
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
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_123' "$ZCREW_BIN" sync --keep-stale >/dev/null 2>&1
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
    PATH="$mockbin:$(dirname "$ZCREW_BIN"):$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
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
  mkdir -p "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
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
  [[ ! -f "$args_file" ]] || ! grep -Fq 'action new-pane' "$args_file" || return 1
  jq -e '.panes.buddy.paneId == "123"' "$d/.zcrew/registry.json" >/dev/null
}

test_11c_spawn_allows_name_after_pruning_stale_entry() {
  local d mockbin args_file out
  d="$(new_test_dir 11c)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx"
  mkdir -p "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  zcrew_cmd "$d" register buddy --paneId 999 --sessionId s1 --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='terminal_0' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_777' \
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
  mkdir -p "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
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
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/codex.sh"
  chmod +x "$d/.zcrew/lib/launchers/codex.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_556' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn codex reviewer 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: reviewer (codex) pane=556' || return 1
  grep -Fq "$d/.zcrew/lib/launchers/codex.sh" "$args_file" || return 1
  ! grep -Fq 'bx run codex' "$args_file" || return 1
  jq -e '.panes.reviewer.agent == "codex" and .panes.reviewer.paneId == "556"' "$d/.zcrew/registry.json" >/dev/null
}

test_11i_spawn_builtin_launcher_path_is_shell_quoted() {
  local d mockbin args_file out launcher_q
  d="$(new_test_dir '11i path with spaces')"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/codex.sh"
  chmod +x "$d/.zcrew/lib/launchers/codex.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_560' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn codex spaced 2>&1
  )" || return 1

  launcher_q=$(printf '%q' "$d/.zcrew/lib/launchers/codex.sh")
  printf '%s\n' "$out" | grep -Fq 'spawned: spaced (codex) pane=560' || return 1
  grep -Fq "$launcher_q" "$args_file" || return 1
  ! grep -Fq "$d/.zcrew/lib/launchers/codex.sh" "$args_file" || return 1
}

test_11f_spawn_seeds_missing_managed_mounts() {
  local d mockbin args_file out zellij_sock target_abs
  d="$(new_test_dir 11f)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"
  zellij_sock="/run/user/$(id -u)/zellij"
  target_abs="$(realpath "$d")"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  rm -f "$d/.bx/mounts"
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_557' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude healer 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: healer (claude) pane=557' || return 1
  [[ -f "$d/.bx/mounts" ]] || return 1
  grep -Fqx '# zcrew-managed begin' "$d/.bx/mounts" || return 1
  grep -Fqx "$zellij_sock $zellij_sock rw" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.zcrew/bin $target_abs/.zcrew/bin ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.zcrew/lib $target_abs/.zcrew/lib ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.config/mise.toml $target_abs/.config/mise.toml ro" "$d/.bx/mounts"
}

test_11g_spawn_repairs_managed_mounts_preserving_custom_lines() {
  local d mockbin args_file out zellij_sock custom_src custom_dst target_abs
  d="$(new_test_dir 11g)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"
  zellij_sock="/run/user/$(id -u)/zellij"
  custom_src="$d/custom-src"
  custom_dst="/opt/custom"
  target_abs="$(realpath "$d")"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers" "$custom_src"
  seed_local_tell_sentinel "$d"
  cat > "$d/.bx/mounts" <<EOF
$custom_src $custom_dst ro
# zcrew-managed begin
/old/zellij /run/user/$(id -u)/zellij rw
/old/project/.zcrew /old/workdir/.zcrew ro
# zcrew-managed end
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
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
  grep -Fqx "$target_abs/.zcrew/bin $target_abs/.zcrew/bin ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.zcrew/lib $target_abs/.zcrew/lib ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.config/mise.toml $target_abs/.config/mise.toml ro" "$d/.bx/mounts" || return 1
  [[ "$(grep -Fxc '# zcrew-managed begin' "$d/.bx/mounts")" -eq 1 ]]
}

test_11h_spawn_claims_host_as_main_when_absent() {
  local d mockbin args_file out
  d="$(new_test_dir 11h)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='terminal_42' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_559' \
      ZELLIJ_SESSION_NAME='test-session' ZELLIJ_PANE_ID=42 "$ZCREW_BIN" spawn claude claimer 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: claimer (claude) pane=559' || return 1
  jq -e '.panes.main.paneId == "42" and .panes.claimer.paneId == "559"' "$d/.zcrew/registry.json" >/dev/null
}

test_11i_spawn_does_not_churn_when_live_main_exists() {
  local d mockbin args_file before after
  d="$(new_test_dir 11i)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 50 --sessionId s50 --agent unknown --cwd "$d" --pid 50 --status alive >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"
  before="$(jq -c '.panes.main' "$d/.zcrew/registry.json")" || return 1

  (
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT=$'terminal_50\nterminal_42' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_560' \
      ZELLIJ_SESSION_NAME='test-session' ZELLIJ_PANE_ID=42 "$ZCREW_BIN" spawn claude extra >/dev/null 2>&1
  ) || return 1
  after="$(jq -c '.panes.main' "$d/.zcrew/registry.json")" || return 1

  [[ "$before" == "$after" ]]
}

test_11j_spawn_outside_zellij_skips_claim_without_error() {
  local d mockbin args_file
  d="$(new_test_dir 11j)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_PANE_ID \
      PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_561' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude plain >/dev/null 2>&1
  ) || return 1

  jq -e '(.panes | has("main") | not) and .panes.plain.paneId == "561"' "$d/.zcrew/registry.json" >/dev/null
}

# ── cmd_spawn model fallback from .zcrew/team.conf ──────────────────────

_run_spawn_with_team_conf() {
  # args: <test_dir> <team_conf_content> <name> [--model X]
  local d="$1" team_content="$2" worker_name="$3"
  shift 3
  local mockbin="$d/mock-bin" args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/codex.sh"
  chmod +x "$d/.zcrew/lib/launchers/codex.sh"
  printf '%s' "$team_content" > "$d/.zcrew/team.conf"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_PANE_ID \
      PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_561' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn "$@" codex "$worker_name" >/dev/null 2>&1
  )
}

test_11k_spawn_uses_team_conf_model_when_cli_omits() {
  local d
  d="$(new_test_dir 11k)"
  _run_spawn_with_team_conf "$d" "sparky codex gpt-5.3-codex implementer
" "sparky" || return 1
  grep -Fq 'ZCREW_MODEL=gpt-5.3-codex' "$d/zellij-args.txt"
}

test_11l_spawn_team_conf_dash_keeps_model_unset() {
  local d
  d="$(new_test_dir 11l)"
  _run_spawn_with_team_conf "$d" "sam codex - reviewer
" "sam" || return 1
  ! grep -Fq 'ZCREW_MODEL=' "$d/zellij-args.txt"
}

test_11m_spawn_cli_model_wins_over_team_conf() {
  local d
  d="$(new_test_dir 11m)"
  _run_spawn_with_team_conf "$d" "sparky codex gpt-5.3-codex implementer
" "sparky" --model gpt-5.5 || return 1
  grep -Fq 'ZCREW_MODEL=gpt-5.5' "$d/zellij-args.txt" || return 1
  ! grep -Fq 'ZCREW_MODEL=gpt-5.3-codex' "$d/zellij-args.txt"
}

test_11n_spawn_name_missing_from_team_conf_keeps_model_unset() {
  local d
  d="$(new_test_dir 11n)"
  _run_spawn_with_team_conf "$d" "sam codex - reviewer
" "stranger" || return 1
  ! grep -Fq 'ZCREW_MODEL=' "$d/zellij-args.txt"
}

test_11o_spawn_fails_when_zcrew_missing_on_path() {
  local d mockbin args_file out
  d="$(new_test_dir 11o)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"

  if out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:/usr/bin:/bin" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_560' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude missingzcrew 2>&1
  )"; then
    return 1
  fi

  printf '%s\n' "$out" | grep -Fq 'cannot find zcrew binary on PATH for worker EXIT trap; spawn aborted' || return 1
  ! grep -Fq 'action new-pane' "$args_file" || return 1
  ! jq -e '.panes | has("missingzcrew")' "$d/.zcrew/registry.json" >/dev/null
}

test_11p_spawn_trap_uses_resolved_binary_not_project_literal() {
  local d mockbin args_file out
  d="$(new_test_dir 11p)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"
  ln -sf "$ZCREW_BIN" "$mockbin/zcrew"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:/usr/bin:/bin" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_561' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude trapcheck 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: trapcheck (claude) pane=561' || return 1
  grep -Fq "trap '\"$ZCREW_BIN\" unregister \"trapcheck\"' EXIT" "$args_file" || return 1
  ! grep -Fq "$d/.zcrew/bin/zcrew" "$args_file" || return 1
}

test_11q_spawn_trap_canonicalizes_symlinked_zcrew_path() {
  local d mockbin args_file out real_dir real_zcrew link_zcrew
  d="$(new_test_dir 11q)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"
  real_dir="$d/tools/real"
  real_zcrew="$real_dir/zcrew"
  link_zcrew="$mockbin/zcrew"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  mkdir -p "$d/.bx" "$d/.zcrew/lib/launchers" "$real_dir"
  seed_local_tell_sentinel "$d"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.zcrew/lib/launchers/claude.sh"
  chmod +x "$d/.zcrew/lib/launchers/claude.sh"
  make_mock_zellij_spawn "$mockbin" "$args_file"
  cp "$ZCREW_BIN" "$real_zcrew"
  chmod +x "$real_zcrew"
  ln -s "$real_zcrew" "$link_zcrew"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE PATH="$mockbin:/usr/bin:/bin" MOCK_ZELLIJ_ARGS_FILE="$args_file" \
      MOCK_ZELLIJ_LIST_OUTPUT='' MOCK_ZELLIJ_NEW_PANE_OUTPUT='terminal_562' \
      ZELLIJ_SESSION_NAME='test-session' "$ZCREW_BIN" spawn claude symlinktrap 2>&1
  )" || return 1

  printf '%s\n' "$out" | grep -Fq 'spawned: symlinktrap (claude) pane=562' || return 1
  grep -Fq "trap '\"$real_zcrew\" unregister \"symlinktrap\"' EXIT" "$args_file" || return 1
  ! grep -Fq "trap '\"$link_zcrew\" unregister \"symlinktrap\"' EXIT" "$args_file" || return 1
}

test_12_send_outside_project_fails_hard() {
  local d out
  d="$(new_test_dir 12)"

  if out="$(zcrew_cmd "$d" send any hello 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -q 'zcrew: no zcrew project here'
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
[tools]
node = "lts"

[env]
_.path = [".zcrew/bin"]
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
  grep -Fxq '[tools]' "$real_dir/.config/mise.toml" || return 1
  grep -Fxq 'node = "lts"' "$real_dir/.config/mise.toml" || return 1
  grep -Fxq '[env]' "$real_dir/.config/mise.toml" || return 1
  ! grep -Fq 'ZCREW_PROJECT_DIR' "$real_dir/.config/mise.toml" || return 1
  grep -Fxq '_.path = [".zcrew/bin"]' "$real_dir/.config/mise.toml"
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

test_18f_install_trusts_managed_mise_floor_when_mise_exists() {
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

  [[ -f "$args_file" ]] || return 1
  grep -Fxq "$TEST_ROOT:trust $d/.config/mise.toml" "$args_file"
}

test_18g_install_writes_sandbox_git_ignore_and_managed_gitconfig() {
  local d ignore_file gitconfig_file
  d="$(new_test_dir 18g)"
  ignore_file="$d/.bx/home/.config/git/ignore"
  gitconfig_file="$d/.bx/home/.gitconfig"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$ignore_file" ]] || return 1
  grep -Fxq '# zcrew-managed' "$ignore_file" || return 1
  grep -Fxq '.bx/' "$ignore_file" || return 1
  grep -Fxq '.zcrew/' "$ignore_file" || return 1
  grep -Fxq '.config/mise.toml' "$ignore_file" || return 1
  grep -Fxq '.codex/skills/zcrew/' "$ignore_file" || return 1
  grep -Fxq 'bin/zcrew' "$ignore_file" || return 1
  [[ -f "$gitconfig_file" ]] || return 1
  grep -Fxq '# zcrew-managed' "$gitconfig_file" || return 1
  grep -Fq 'excludesfile = ~/.config/git/ignore' "$gitconfig_file"
}

test_18h_install_preserves_user_sandbox_gitconfig() {
  local d gitconfig_file before after
  d="$(new_test_dir 18h)"
  gitconfig_file="$d/.bx/home/.gitconfig"
  mkdir -p "$(dirname "$gitconfig_file")"
  cat > "$gitconfig_file" <<'EOF'
[user]
	name = custom
EOF
  before="$(cat "$gitconfig_file")"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  after="$(cat "$gitconfig_file")"

  [[ "$before" == "$after" ]]
}

test_18i_install_rewrites_managed_sandbox_gitconfig() {
  local d gitconfig_file
  d="$(new_test_dir 18i)"
  gitconfig_file="$d/.bx/home/.gitconfig"
  mkdir -p "$(dirname "$gitconfig_file")"
  cat > "$gitconfig_file" <<'EOF'
# zcrew-managed
[core]
	excludesfile = /tmp/wrong
EOF

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  grep -Fq 'excludesfile = ~/.config/git/ignore' "$gitconfig_file"
}

test_18j_install_preserves_gitconfig_with_nonleading_managed_marker() {
  local d gitconfig_file before after
  d="$(new_test_dir 18j)"
  gitconfig_file="$d/.bx/home/.gitconfig"
  mkdir -p "$(dirname "$gitconfig_file")"
  cat > "$gitconfig_file" <<'EOF'
[user]
	name = custom
# zcrew-managed
[core]
	excludesfile = /tmp/user-choice
EOF
  before="$(cat "$gitconfig_file")"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  after="$(cat "$gitconfig_file")"
  [[ "$before" == "$after" ]]
}

test_18k_dryrun_exits_zero_without_mutation() {
  local d before after out
  d="$(new_test_dir 18k)"
  mkdir -p "$d/custom-dir"
  printf 'keep\n' > "$d/custom-dir/user.txt"
  before="$(snapshot_tree_state "$d")" || return 1

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }

  after="$(snapshot_tree_state "$d")" || return 1
  [[ "$before" == "$after" ]]
}

test_18l_dryrun_plan_has_three_sections() {
  local d out
  d="$(new_test_dir 18l)"
  mkdir -p "$d"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  printf '%s\n' "$out" | awk '
    /^REPLACE$/ { r = NR }
    /^KEEP$/ { k = NR }
    /^SKIP$/ { s = NR }
    END { exit !(r && k && s && r < k && k < s) }
  '
}

test_18m_dryrun_plan_includes_core_files() {
  local d out
  d="$(new_test_dir 18m)"
  mkdir -p "$d"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  printf '%s\n' "$out" | grep -Fqx '  .zcrew/bin/zcrew (create)' || return 1
  printf '%s\n' "$out" | grep -Fqx '  .zcrew/lib/tell (create)' || return 1
  printf '%s\n' "$out" | grep -Fqx '  AGENTS.md (create)' || return 1
  printf '%s\n' "$out" | grep -Fqx '  CLAUDE.md (create symlink to AGENTS.md)'
}

test_18n_dryrun_plan_keeps_runtime_state() {
  local d out keep
  d="$(new_test_dir 18n)"
  mkdir -p "$d"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  keep="$(printf '%s\n' "$out" | plan_section KEEP)" || return 1
  printf '%s\n' "$keep" | grep -Fqx '  .zcrew/registry.json (preserve runtime state)' || return 1
  printf '%s\n' "$keep" | grep -Fqx '  .bx/home/ (preserve sandbox home and runtime state)'
}

test_18o_dryrun_plan_keeps_mixed_content() {
  local d out keep
  d="$(new_test_dir 18o)"
  mkdir -p "$d"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  keep="$(printf '%s\n' "$out" | plan_section KEEP)" || return 1
  printf '%s\n' "$keep" | grep -Fqx '  .mcp.json (will merge/rewrite zcrew MCP entry)' || return 1
  printf '%s\n' "$keep" | grep -Fqx '  .codex/config.toml (will merge/rewrite zcrew block)' || return 1
  printf '%s\n' "$keep" | grep -Fqx '  .bx/mounts (will merge/rewrite zcrew-managed block)'
}

test_18p_dryrun_skips_user_agents_md() {
  local d out replace keep skip
  d="$(new_test_dir 18p)"
  mkdir -p "$d"
  printf 'custom agents\n' > "$d/AGENTS.md"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  replace="$(printf '%s\n' "$out" | plan_section REPLACE)" || return 1
  keep="$(printf '%s\n' "$out" | plan_section KEEP)" || return 1
  skip="$(printf '%s\n' "$out" | plan_section SKIP)" || return 1
  ! printf '%s\n' "$replace" | grep -Fqx '  AGENTS.md (create)' || return 1
  ! printf '%s\n' "$replace" | grep -Fqx '  AGENTS.md (overwrite, managed-pristine)' || return 1
  ! printf '%s\n' "$replace" | grep -Fq '  AGENTS.md (overwrite, managed-modified' || return 1
  printf '%s\n' "$skip" | grep -Fqx '  AGENTS.md (user file; no zcrew ownership marker)'
  printf '%s\n' "$keep" | grep -Fqx '  CLAUDE.md (will skip; AGENTS.md already exists)'
}

test_18q_dryrun_replaces_user_skill_path_owned_by_zcrew() {
  local d out replace skip
  d="$(new_test_dir 18q)"
  mkdir -p "$d/.claude/skills/zcrew"
  printf 'custom skill\n' > "$d/.claude/skills/zcrew/SKILL.md"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  replace="$(printf '%s\n' "$out" | plan_section REPLACE)" || return 1
  skip="$(printf '%s\n' "$out" | plan_section SKIP)" || return 1
  # Skill directories are zcrew-owned by path and are overwritten by install.
  printf '%s\n' "$replace" | grep -Fq '  .claude/skills/zcrew/SKILL.md (overwrite, managed-modified' || return 1
  ! printf '%s\n' "$skip" | grep -Fq '.claude/skills/zcrew/SKILL.md'
}

test_18qa_dryrun_keeps_existing_managed_agents_md() {
  local d out replace keep
  d="$(new_test_dir 18qa)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  replace="$(printf '%s\n' "$out" | plan_section REPLACE)" || return 1
  keep="$(printf '%s\n' "$out" | plan_section KEEP)" || return 1

  ! printf '%s\n' "$replace" | grep -Fq '  AGENTS.md ' || return 1
  printf '%s\n' "$keep" | grep -Fqx '  AGENTS.md (will skip; install preserves existing file)' || return 1
  printf '%s\n' "$keep" | grep -Fqx '  CLAUDE.md (will skip; AGENTS.md already exists)'
}

test_18r_dryrun_classifies_pristine_vs_modified() {
  local d out
  d="$(new_test_dir 18r)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  printf '# test modification\n' >> "$d/.zcrew/bin/zcrew"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  printf '%s\n' "$out" | grep -Fqx '  .zcrew/bin/zcrew (overwrite, managed-modified, line-diff=1)' || return 1
  printf '%s\n' "$out" | grep -Fqx '  .zcrew/bin/bx (overwrite, managed-pristine)'
}

test_18s_dryrun_classifies_absent_as_create() {
  local d out
  d="$(new_test_dir 18s)"
  mkdir -p "$d"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  printf '%s\n' "$out" | grep -Fqx '  .zcrew/bin/zcrew (create)' || return 1
  ! printf '%s\n' "$out" | grep -Fq '.zcrew/bin/zcrew (overwrite)'
}

test_18t_dryrun_path_owned_premarker_lib_file_is_replace_not_skip() {
  local d out replace skip
  d="$(new_test_dir 18t)"
  mkdir -p "$d/.zcrew/lib"
  printf 'legacy content without marker\n' > "$d/.zcrew/lib/mcp_server.py"

  out="$(dryrun_install_cmd "$TEST_ROOT" "$d" --dry-run 2>&1)" || return 1
  replace="$(printf '%s\n' "$out" | plan_section REPLACE)" || return 1
  skip="$(printf '%s\n' "$out" | plan_section SKIP)" || return 1
  printf '%s\n' "$replace" | grep -Fq '  .zcrew/lib/mcp_server.py (overwrite, managed-modified' || return 1
  ! printf '%s\n' "$skip" | grep -Fq '.zcrew/lib/mcp_server.py'
}

test_19_resolve_project_dir_from_root_uses_local_state() {
  local d out
  d="$(new_test_dir 19-project)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register rooted --paneId 19 --sessionId s19 --agent claude --cwd "$d" --pid 19 --status alive >/dev/null 2>&1 || return 1

  out="$(zcrew_cmd "$d" list --json 2>/dev/null)" || return 1
  printf '%s\n' "$out" | jq -e '.panes.rooted.paneId == "19"' >/dev/null || return 1
}

test_20_resolve_project_dir_walks_up_from_subdir() {
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

test_20b_resolve_project_dir_fails_outside_zcrew_tree() {
  local d other_dir out
  d="$(new_test_dir 20b-project)"
  other_dir="$(new_test_dir 20b-other)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1

  if out="$(zcrew_cmd "$other_dir" list 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq "zcrew: no zcrew project here"
}

test_20c_resolve_project_dir_worktree_uses_main_registry() {
  local d main_repo worktree_dir out
  d="$(new_test_dir 20c)"
  main_repo="$d/main-repo"
  worktree_dir="$d/feature-worktree"
  mkdir -p "$main_repo"

  git -C "$main_repo" init >/dev/null 2>&1 || return 1
  git -C "$main_repo" config user.name "zcrew-tests" || return 1
  git -C "$main_repo" config user.email "zcrew-tests@example.com" || return 1
  mkdir -p "$main_repo/.zcrew"
  printf '{"panes":{"main":{"paneId":"42","sessionId":"s42","agent":"codex","cwd":"%s","pid":42,"lastSeen":1,"status":"alive"}}}\n' "$main_repo" > "$main_repo/.zcrew/registry.json" || return 1
  printf '' > "$main_repo/.zcrew/registry.lock" || return 1
  printf '' > "$main_repo/.zcrew/audit.log" || return 1
  mkdir -p "$main_repo/.zcrew/spawn"
  printf 'seed\n' > "$main_repo/seed.txt"
  git -C "$main_repo" add seed.txt || return 1
  git -C "$main_repo" add -f .zcrew || return 1
  git -C "$main_repo" commit -m "seed" >/dev/null 2>&1 || return 1

  git -C "$main_repo" worktree add "$worktree_dir" -b feature >/dev/null 2>&1 || return 1

  jq '.panes.main.paneId = "99"' "$main_repo/.zcrew/registry.json" > "$main_repo/.zcrew/registry.json.tmp" || return 1
  mv "$main_repo/.zcrew/registry.json.tmp" "$main_repo/.zcrew/registry.json"

  out="$(
    cd "$worktree_dir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list --json
  )" || return 1

  printf '%s\n' "$out" | jq -e '.panes.main.paneId == "99"' >/dev/null || return 1
  jq -e '.panes.main.paneId == "42"' "$worktree_dir/.zcrew/registry.json" >/dev/null
}

# ── Hardened resolver tests (4-rule with stateful guard) ────────────────

test_96_resolver_returns_env_var_when_set_and_valid() {
  local d subdir out
  d="$(new_test_dir 96)"
  subdir="$d/sub"
  mkdir -p "$subdir"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register envtest --paneId 96 --sessionId s96 --agent claude --cwd "$d" --pid 96 --status alive >/dev/null 2>&1 || return 1

  # ZCREW_PROJECT_DIR overrides PWD (we're in subdir, but env points to parent)
  out="$(
    cd "$subdir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZCREW_PROJECT_DIR="$d" "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.envtest.paneId == "96"' >/dev/null
}

test_96a_resolver_allows_env_when_cwd_resolves_to_same_project() {
  local d subdir out
  d="$(new_test_dir 96a)"
  subdir="$d/sub"
  mkdir -p "$subdir"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register sameproj --paneId 961 --sessionId s961 --agent claude --cwd "$d" --pid 961 --status alive >/dev/null 2>&1 || return 1

  out="$(
    cd "$subdir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZCREW_PROJECT_DIR="$d" "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.sameproj.paneId == "961"' >/dev/null
}

test_96b_resolver_allows_env_when_cwd_is_same_project_worktree() {
  local d main_repo worktree_dir out
  d="$(new_test_dir 96b)"
  main_repo="$d/main-repo"
  worktree_dir="$d/feature-worktree"
  mkdir -p "$main_repo"

  git -C "$main_repo" init >/dev/null 2>&1 || return 1
  git -C "$main_repo" config user.name "zcrew-tests" || return 1
  git -C "$main_repo" config user.email "zcrew-tests@example.com" || return 1
  mkdir -p "$main_repo/.zcrew"
  printf '{"version":1,"panes":{"envworktree":{"paneId":"962","sessionId":"s962","agent":"codex","cwd":"%s","pid":962,"lastSeen":1,"status":"alive"}}}\n' "$main_repo" > "$main_repo/.zcrew/registry.json" || return 1
  printf '' > "$main_repo/.zcrew/registry.lock" || return 1
  printf '' > "$main_repo/.zcrew/audit.log" || return 1
  mkdir -p "$main_repo/.zcrew/spawn"
  printf 'seed\n' > "$main_repo/seed.txt"
  git -C "$main_repo" add seed.txt || return 1
  git -C "$main_repo" add -f .zcrew || return 1
  git -C "$main_repo" commit -m "seed" >/dev/null 2>&1 || return 1
  git -C "$main_repo" worktree add "$worktree_dir" -b feature >/dev/null 2>&1 || return 1

  out="$(
    cd "$worktree_dir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZCREW_PROJECT_DIR="$main_repo" "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.envworktree.paneId == "962"' >/dev/null
}

test_96c_resolver_allows_env_when_cwd_has_no_resolvable_project() {
  local d other_dir out
  d="$(new_test_dir 96c-project)"
  other_dir="$(new_test_dir 96c-other)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register envonly --paneId 963 --sessionId s963 --agent claude --cwd "$d" --pid 963 --status alive >/dev/null 2>&1 || return 1

  out="$(
    cd "$other_dir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZCREW_PROJECT_DIR="$d" "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.envonly.paneId == "963"' >/dev/null
}

test_96e_resolver_allows_env_when_cwd_is_plain_git_repo_without_zcrew() {
  local d other_repo out
  d="$(new_test_dir 96e-project)"
  other_repo="$(new_test_dir 96e-other-git)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register envgit --paneId 965 --sessionId s965 --agent claude --cwd "$d" --pid 965 --status alive >/dev/null 2>&1 || return 1
  git -C "$other_repo" init >/dev/null 2>&1 || return 1

  out="$(
    cd "$other_repo" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZCREW_PROJECT_DIR="$d" "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.envgit.paneId == "965"' >/dev/null
}

test_96d_resolver_errors_when_env_and_cwd_projects_disagree() {
  local env_project cwd_project out
  env_project="$(new_test_dir 96d-env)"
  cwd_project="$(new_test_dir 96d-cwd)"

  zcrew_cmd "$env_project" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$cwd_project" init >/dev/null 2>&1 || return 1

  if out="$(
    cd "$cwd_project" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 ZCREW_PROJECT_DIR="$env_project" "$ZCREW_BIN" list 2>&1
  )"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq 'zcrew: ZCREW_PROJECT_DIR points at a different project than the current working directory' || return 1
  printf '%s\n' "$out" | grep -Fq "$(realpath "$env_project")" || return 1
  printf '%s\n' "$out" | grep -Fq "$(realpath "$cwd_project")" || return 1
  printf '%s\n' "$out" | grep -Fq 'shell profile or parent shell' || return 1
}

test_97_resolver_ignores_env_var_inside_sandbox() {
  local d out
  d="$(new_test_dir 97)"
  mkdir -p "$d"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register sbxtest --paneId 97 --sessionId s97 --agent claude --cwd "$d" --pid 97 --status alive >/dev/null 2>&1 || return 1

  # BX_INSIDE=1 means ZCREW_PROJECT_DIR should be ignored; resolver walks PWD instead
  out="$(
    cd "$d" || exit 1
    env -u ZCREW_AUTO_SYNC BX_INSIDE=1 ZCREW_PROJECT_DIR="/nonexistent/path" "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.sbxtest.paneId == "97"' >/dev/null
}

test_98_resolver_stateful_errors_in_git_repo_subdir_without_zcrew() {
  local d out
  d="$(new_test_dir 98)"
  mkdir -p "$d/sub"

  # Create a git repo without .zcrew/
  git -C "$d" init >/dev/null 2>&1 || return 1

  # Stateful op from subdir should error
  if out="$(
    cd "$d/sub" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list 2>&1
  )"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq 'zcrew: no zcrew project here'
}

test_99_resolver_stateful_errors_in_git_root_without_zcrew() {
  local d out
  d="$(new_test_dir 99)"
  mkdir -p "$d"

  # Git repo with no .zcrew/ at all
  git -C "$d" init >/dev/null 2>&1 || return 1

  # Stateful op from git root should also error
  if out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list 2>&1
  )"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq 'zcrew: no zcrew project here'
}

test_100_resolver_discovery_returns_git_root_for_init() {
  local d out
  d="$(new_test_dir 100)"
  mkdir -p "$d/sub"

  git -C "$d" init >/dev/null 2>&1 || return 1

  # Discovery op (init) should succeed and create .zcrew/ at git root
  out="$(
    cd "$d/sub" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" init 2>&1
  )" || return 1
  printf '%s\n' "$out" | grep -Fq "Initialized .zcrew/ at $d"
  [[ -d "$d/.zcrew" ]] || return 1
  [[ -f "$d/.zcrew/registry.json" ]]
}

test_101_resolver_worktree_redirects_to_main_repo() {
  local d main_repo worktree_dir out
  d="$(new_test_dir 101)"
  main_repo="$d/main-repo"
  worktree_dir="$d/feature-worktree"
  mkdir -p "$main_repo"

  git -C "$main_repo" init >/dev/null 2>&1 || return 1
  git -C "$main_repo" config user.name "zcrew-tests" || return 1
  git -C "$main_repo" config user.email "zcrew-tests@example.com" || return 1
  mkdir -p "$main_repo/.zcrew"
  printf '{"version":1,"panes":{"main":{"paneId":"101","sessionId":"s101","agent":"codex","cwd":"%s","pid":101,"lastSeen":1,"status":"alive"}}}\n' "$main_repo" > "$main_repo/.zcrew/registry.json" || return 1
  printf '' > "$main_repo/.zcrew/registry.lock" || return 1
  printf '' > "$main_repo/.zcrew/audit.log" || return 1
  mkdir -p "$main_repo/.zcrew/spawn"
  printf 'seed\n' > "$main_repo/seed.txt"
  git -C "$main_repo" add seed.txt || return 1
  git -C "$main_repo" add -f .zcrew || return 1
  git -C "$main_repo" commit -m "seed" >/dev/null 2>&1 || return 1

  git -C "$main_repo" worktree add "$worktree_dir" -b feature >/dev/null 2>&1 || return 1

  out="$(
    cd "$worktree_dir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list --json
  )" || return 1
  # Should read main repo's registry
  printf '%s\n' "$out" | jq -e '.panes.main.paneId == "101"' >/dev/null
}

test_102_resolver_canonicalizes_via_realpath() {
  local d symlink_dir out
  d="$(new_test_dir 102)"
  symlink_dir="$d/link"
  mkdir -p "$d/real"
  ln -s "$d/real" "$symlink_dir"

  zcrew_cmd "$d/real" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d/real" register symtest --paneId 102 --sessionId s102 --agent claude --cwd "$d/real" --pid 102 --status alive >/dev/null 2>&1 || return 1

  # Accessing via symlink should still resolve to real path
  out="$(
    cd "$symlink_dir" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list --json
  )" || return 1
  printf '%s\n' "$out" | jq -e '.panes.symtest.paneId == "102"' >/dev/null
}

test_103_resolve_lib_dir_prefers_project_local() {
  local d home_dir lib_copy out
  d="$(new_test_dir 103)"
  home_dir="$d/home"
  lib_copy="$d/zcrew-lib.sh"
  mkdir -p "$d/.zcrew/lib" "$home_dir"
  seed_local_tell_sentinel "$d"

  source_zcrew_lib "$lib_copy"
  # shellcheck disable=SC1090
  source "$lib_copy"
  PROJECT_DIR="$d"
  HOME="$home_dir"
  _RESOLVED_LIB_DIR=""
  out="$(resolve_lib_dir)" || return 1
  [[ "$out" == "$(realpath "$d/.zcrew/lib")" ]]
}


test_104b_resolve_lib_dir_cache_hits_same_project() {
  local d home_dir lib_copy first second
  d="$(new_test_dir 104b)"
  home_dir="$d/home"
  lib_copy="$d/zcrew-lib.sh"
  mkdir -p "$d/.zcrew/lib" "$home_dir"
  seed_local_tell_sentinel "$d"

  source_zcrew_lib "$lib_copy"
  # shellcheck disable=SC1090
  source "$lib_copy"
  PROJECT_DIR="$d"
  HOME="$home_dir"
  _RESOLVED_LIB_DIR=""
  first="$(resolve_lib_dir)" || return 1
  second="$(resolve_lib_dir)" || return 1

  [[ "$first" == "$(realpath "$d/.zcrew/lib")" ]] || return 1
  [[ "$second" == "$first" ]]
}


test_105_resolve_lib_dir_errors_when_missing() {
  local d home_dir lib_copy
  d="$(new_test_dir 105)"
  home_dir="$d/home"
  lib_copy="$d/zcrew-lib.sh"
  mkdir -p "$home_dir"

  source_zcrew_lib "$lib_copy"
  # shellcheck disable=SC1090
  source "$lib_copy"
  PROJECT_DIR="$d"
  HOME="$home_dir"
  _RESOLVED_LIB_DIR=""
  if ( resolve_lib_dir >/dev/null 2>&1 ); then
    return 1
  fi
}



test_21_list_auto_sync_prunes_dead_entries() {
  local d mockbin out
  d="$(new_test_dir 21)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  jq '.panes = {dead:{paneId:"999",sessionId:"s",agent:"claude",cwd:"x",pid:1,lastSeen:1,status:"alive"}}' "$d/.zcrew/registry.json" > "$d/.zcrew/registry.json.tmp" || return 1
  mv "$d/.zcrew/registry.json.tmp" "$d/.zcrew/registry.json"
  make_mock_zellij "$mockbin" "terminal_123"

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_123' "$ZCREW_BIN" list --json
  )" || return 1

  printf '%s\n' "$out" | jq -e '.panes.dead == null and .panes["pane-123"].paneId == "123"' >/dev/null || return 1
  jq -e '.panes.dead == null and .panes["pane-123"].paneId == "123"' "$d/.zcrew/registry.json" >/dev/null
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
    env -u BX_INSIDE ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT="terminal_123" ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="0" "$ZCREW_BIN" spawn claude buddy >/dev/null 2>&1
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
    env -u BX_INSIDE PATH="$mockbin:$PATH" "$ZCREW_BIN" sync --keep-stale
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
  [[ -d "$d/.pi/skills/zcrew" ]] || return 1
  [[ ! -L "$d/.pi/skills/zcrew" ]]
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

  [[ -f "$d/.zcrew/lib/tell" ]] || return 1
  [[ -x "$d/.zcrew/lib/tell" ]] || return 1
  cmp -s "$REPO_ROOT/.zcrew/lib/tell" "$d/.zcrew/lib/tell"
}

test_32bb_tell_shim_uses_mx_send_text_zellij_sequence() {
  local d mockbin args_file sleep_file
  d="$(new_test_dir 32bb)"
  mockbin="$d/mock-bin"
  args_file="$d/zellij-args.txt"
  sleep_file="$d/sleep-args.txt"
  clear_mx_backend_state
  mkdir -p "$d/lib" "$mockbin"
  cp "$REPO_ROOT/.zcrew/lib/tell" "$d/lib/tell" || { clear_mx_backend_state; return 1; }
  cp "$REPO_ROOT/.zcrew/lib/multiplexer.sh" "$d/lib/multiplexer.sh" || { clear_mx_backend_state; return 1; }
  chmod +x "$d/lib/tell"

  cat > "$mockbin/zellij" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_ZELLIJ_ARGS_FILE:?MOCK_ZELLIJ_ARGS_FILE is required}"
printf '%s\n' "$*" >> "$MOCK_ZELLIJ_ARGS_FILE"
EOF
  chmod +x "$mockbin/zellij"
  make_mock_sleep "$mockbin" "$sleep_file"

  (
    env -u TMUX PATH="$mockbin:$PATH" MOCK_ZELLIJ_ARGS_FILE="$args_file" MOCK_SLEEP_ARGS_FILE="$sleep_file" \
      ZELLIJ_SESSION_NAME=test-session \
      bash "$d/lib/tell" 123 "hello world"
  ) >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }

  [[ "$(sed -n '1p' "$args_file")" == "action write 27 91 50 48 48 126 --pane-id 123" ]] || { clear_mx_backend_state; return 1; }
  [[ "$(sed -n '2p' "$args_file")" == "action write-chars hello world --pane-id 123" ]] || { clear_mx_backend_state; return 1; }
  [[ "$(sed -n '3p' "$args_file")" == "action write 27 91 50 48 49 126 --pane-id 123" ]] || { clear_mx_backend_state; return 1; }
  [[ "$(sed -n '4p' "$args_file")" == "action write 13 --pane-id 123" ]] || { clear_mx_backend_state; return 1; }
  [[ "$(cat "$sleep_file")" == "0.15" ]] || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_32bc_install_replaces_old_tell_byte_sequence_with_managed_shim() {
  local d
  d="$(new_test_dir 32bc)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  cat > "$d/.zcrew/lib/tell" <<'EOF'
#!/usr/bin/env bash
zellij action write 27 91 50 48 48 126 --pane-id "$1"
EOF
  chmod +x "$d/.zcrew/lib/tell"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  grep -Fqx '# zcrew-managed' "$d/.zcrew/lib/tell" || return 1
  cmp -s "$REPO_ROOT/.zcrew/lib/tell" "$d/.zcrew/lib/tell"
}

test_32c_install_writes_nonexecutable_multiplexer_library() {
  local d
  d="$(new_test_dir 32c)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -f "$d/.zcrew/lib/multiplexer.sh" ]] || return 1
  [[ -r "$d/.zcrew/lib/multiplexer.sh" ]] || return 1
  [[ ! -x "$d/.zcrew/lib/multiplexer.sh" ]]
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
  [[ -d "$d/.claude/skills/zcrew" && ! -L "$d/.claude/skills/zcrew" ]] || return 1
  [[ -d "$d/.codex/skills/zcrew" && ! -L "$d/.codex/skills/zcrew" ]] || return 1
  [[ -d "$d/.pi/skills/zcrew" && ! -L "$d/.pi/skills/zcrew" ]] || return 1
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

test_34c_install_materializes_zcrew_skill_symlinks_as_real_dirs() {
  local d
  d="$(new_test_dir 34c-symlink)"
  mkdir -p "$d/.agents"
  ln -s ../docs/skills "$d/.agents/skills"
  mkdir -p "$d/docs/skills"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  [[ -d "$d/.codex/skills/zcrew" && ! -L "$d/.codex/skills/zcrew" ]] || return 1
  [[ -d "$d/.pi/skills/zcrew" && ! -L "$d/.pi/skills/zcrew" ]] || return 1
  [[ -d "$d/.claude/skills/zcrew" && ! -L "$d/.claude/skills/zcrew" ]] || return 1
  cmp -s "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" "$d/.codex/skills/zcrew/SKILL.md" || return 1
  cmp -s "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" "$d/.pi/skills/zcrew/SKILL.md" || return 1
  cmp -s "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" "$d/.claude/skills/zcrew/SKILL.md"
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
  grep -Fxq 'claudio  claude  sonnet         assistant / researcher' "$d/.zcrew/team.conf" || return 1
  grep -Fxq 'sam      codex   -              reviewer' "$d/.zcrew/team.conf" || return 1
  grep -Fxq 'sparky   codex   gpt-5.3-codex  implementer' "$d/.zcrew/team.conf" || return 1
  grep -Fxq 'piper    pi      glm-5.1        optional alternative model agent' "$d/.zcrew/team.conf"
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

test_34j_install_seeds_mcp_configs() {
  local d
  d="$(new_test_dir 34j)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  # Project-root .mcp.json: orchestrator (host main) needs zcrew_send /
  # zcrew_list MCP tools.
  jq -e '.mcpServers.zcrew.command == "python3"' "$d/.mcp.json" >/dev/null || return 1
  jq -e --arg path "$(realpath "$d/.zcrew/lib/mcp_server.py")" '.mcpServers.zcrew.args[0] == $path' "$d/.mcp.json" >/dev/null || return 1
  # Sandbox pi mcp.json: zcrew NOT seeded — pi worker uses native extension.
  if [[ -f "$d/.bx/home/.pi/agent/mcp.json" ]]; then
    jq -e '.mcpServers // {} | has("zcrew") | not' "$d/.bx/home/.pi/agent/mcp.json" >/dev/null || return 1
  fi
  # Sandbox codex config.toml: zcrew block NOT seeded — codex worker uses
  # the app-server adapter for auto-reply.
  if [[ -f "$d/.bx/home/.codex/config.toml" ]]; then
    ! grep -Fxq '[mcp_servers.zcrew]' "$d/.bx/home/.codex/config.toml"
  fi
}

test_34k_reinstall_preserves_other_mcp_servers() {
  local d
  d="$(new_test_dir 34k)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  # User adds a custom MCP server alongside zcrew.
  jq '.mcpServers.userserver = {command: "echo", args: ["hello"]}' "$d/.mcp.json" > "$d/.mcp.json.tmp" || return 1
  mv "$d/.mcp.json.tmp" "$d/.mcp.json"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  jq -e '.mcpServers.userserver.command == "echo"' "$d/.mcp.json" >/dev/null || return 1
  jq -e '.mcpServers.zcrew.command == "python3"' "$d/.mcp.json" >/dev/null
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

test_42_codex_launcher_runs_inside_bx() {
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

  # Outer launcher delegates to bx with re-entry sentinel; the inner-launcher
  # body runs inside the sandbox.
  grep -Fq 'run -- bash' "$args_file" || return 1
  grep -Fq -- '--zcrew-inner-codex-launcher' "$args_file" || return 1
  ! grep -Fq ' -c ' "$args_file"
  [[ ! -f "$sandbox_config" ]]
}


test_42c_stop_hook_uses_own_project_when_cwd_is_other_project() {
  local d project_a project_b mockbin args_a args_b hook_input
  d="$(new_test_dir 42c)"
  project_a="$d/proj-a"
  project_b="$d/proj-b"
  mockbin="$d/mock-bin"
  args_a="$d/tell-a.txt"
  args_b="$d/tell-b.txt"
  hook_input='{"last_assistant_message":"hook reply"}'
  mkdir -p "$project_a" "$project_b"

  zcrew_cmd "$project_a" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$project_b" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$project_a" register main --paneId 1 --sessionId s --agent claude --cwd "$project_a" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$project_a" register worker --paneId 77 --sessionId s --agent claude --cwd "$project_a" --pid 77 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$project_b" register main --paneId 2 --sessionId s --agent claude --cwd "$project_b" --pid 2 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$project_b" register worker --paneId 77 --sessionId s --agent claude --cwd "$project_b" --pid 77 --status alive >/dev/null 2>&1 || return 1
  seed_local_lib_fixture "$project_a"
  seed_local_lib_fixture "$project_b"
  cat > "$project_a/.zcrew/lib/tell" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$args_a"
EOF
  cat > "$project_b/.zcrew/lib/tell" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$args_b"
EOF
  chmod +x "$project_a/.zcrew/lib/tell" "$project_b/.zcrew/lib/tell"
  make_mock_zellij "$mockbin" $'terminal_1\nterminal_2\nterminal_77'

  (
    cd "$project_b" || exit 1
    printf '%s\n' "$hook_input" | env -u BX_INSIDE BX_INSIDE=1 ZCREW_BIN="$ZCREW_BIN" PATH="$mockbin:$PATH" \
      MOCK_ZELLIJ_LIST_OUTPUT=$'terminal_1\nterminal_2\nterminal_77' \
      ZELLIJ_SESSION_NAME="test-session" ZELLIJ_PANE_ID="77" \
      "$project_a/.zcrew/lib/stop-hook.sh" >/dev/null 2>&1
  ) || return 1

  grep -Fq '1' "$args_a" || return 1
  grep -Fq 'hook reply' "$args_a" || return 1
  [[ ! -s "$args_b" ]]
}

test_43_codex_launcher_forwards_model_through_bx() {
  # The launcher always passes --model: ZCREW_MODEL if set, else the
  # enforced default gpt-5.4. Source-level check (simpler than a runtime
  # mock). Use -- to keep grep from reading --model as a flag.
  local launcher="$REPO_ROOT/.zcrew/lib/launchers/codex.sh"
  grep -Fq -- '--model "${ZCREW_MODEL:-gpt-5.4}"' "$launcher"
}

test_43b_codex_launcher_uses_launcher_relative_adapter_path() {
  local launcher="$REPO_ROOT/.zcrew/lib/launchers/codex.sh"
  grep -Fq 'launcher_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' "$launcher" || return 1
  grep -Fq 'lib_dir="$(dirname "$launcher_dir")"' "$launcher" || return 1
  grep -Fq 'node "$lib_dir/codex-auto-reply.mjs"' "$launcher"
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

test_44d_codex_launcher_writes_outer_identity_files() {
  local d home_dir mockbin args_file state_dir
  d="$(new_test_dir 44d)"
  home_dir="$d/host-home"
  mockbin="$d/mock-bin"
  args_file="$d/bx-args.txt"
  state_dir="$d/.zcrew/state/codex-worker/4242"

  mkdir -p "$home_dir"
  make_mock_bx "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    HOME="$home_dir" PATH="$mockbin:$PATH" MOCK_BX_ARGS_FILE="$args_file" ZELLIJ_PANE_ID=4242 \
      "$REPO_ROOT/.zcrew/lib/launchers/codex.sh" >/dev/null 2>&1
  ) || return 1

  [[ -f "$state_dir/outer.pid" ]] || return 1
  [[ -f "$state_dir/outer.starttime" ]] || return 1
  [[ "$(tr -dc '0-9' < "$state_dir/outer.pid")" =~ ^[0-9]+$ ]] || return 1
  [[ "$(tr -dc '0-9' < "$state_dir/outer.starttime")" =~ ^[0-9]+$ ]]
}

test_44f_codex_launcher_tmux_pane_strips_percent_for_state_dir() {
  local d home_dir mockbin args_file state_dir
  d="$(new_test_dir 44f)"
  home_dir="$d/host-home"
  mockbin="$d/mock-bin"
  args_file="$d/bx-args.txt"
  state_dir="$d/.zcrew/state/codex-worker/4242"

  mkdir -p "$home_dir"
  make_mock_bx "$mockbin" "$args_file"

  (
    cd "$d" || exit 1
    HOME="$home_dir" PATH="$mockbin:$PATH" MOCK_BX_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME= ZELLIJ_PANE_ID= TMUX=/tmp/tmux-1000/mysock,12345,0 TMUX_PANE=%4242 \
      "$REPO_ROOT/.zcrew/lib/launchers/codex.sh" >/dev/null 2>&1
  ) || return 1

  [[ -f "$state_dir/outer.pid" ]] || return 1
  [[ -f "$state_dir/outer.starttime" ]]
}

test_44g_codex_launcher_tmux_session_name_feeds_port_hash() {
  local d mockbin port_file expected_port
  d="$(new_test_dir 44g)"
  mockbin="$d/mock-bin"
  port_file="$d/.zcrew/state/codex-worker/4242/port"
  mkdir -p "$mockbin" "$d/.zcrew/state/codex-worker/4242"

  cat > "$mockbin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "display-message" && "${2:-}" == "-p" && "${3:-}" == "#S" ]]; then
  printf 'mysess\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$mockbin/tmux"

  cat > "$mockbin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "app-server" ]]; then
  sleep 60 &
  wait
  exit 0
fi
exit 0
EOF
  chmod +x "$mockbin/codex"

  cat > "$mockbin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 60 &
wait
EOF
  chmod +x "$mockbin/node"

  cat > "$mockbin/nc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f ".zcrew/state/codex-worker/4242/port" ]]; then
  exit 0
fi
exit 1
EOF
  chmod +x "$mockbin/nc"

  (
    cd "$d" || exit 1
    PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME= ZELLIJ_PANE_ID= TMUX=/tmp/tmux-1000/mysock,12345,0 TMUX_PANE=%4242 \
      timeout 2 bash "$REPO_ROOT/.zcrew/lib/launchers/codex.sh" --zcrew-inner-codex-launcher >/dev/null 2>&1 || true
  ) || return 1

  [[ -f "$port_file" ]] || return 1
  expected_port="$(printf '%s' 'mysess:4242' | cksum | awk '{print 49152 + ($1 % 16384)}')" || return 1
  [[ "$(cat "$port_file")" == "$expected_port" ]]
}

test_44e_parse_proc_stat_starttime_handles_spaces_in_comm() {
  local d lib_copy out
  d="$(new_test_dir 44e)"
  lib_copy="$d/zcrew-lib.sh"

  source_zcrew_lib "$lib_copy"
  # shellcheck disable=SC1090
  source "$lib_copy"

  out="$(parse_proc_stat_starttime '1234 (some weird name) S 1 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 5555 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0')" || return 1
  [[ "$out" == "5555" ]]
}

test_44b_claude_launcher_drops_mcp_config() {
  # Claude worker uses the SessionStop hook for auto-reply, not MCP. The
  # launcher must NOT pass --mcp-config (which would reload the project
  # zcrew MCP server inside the worker and create dual-fire). Strict mode
  # without --mcp-config gives the worker zero MCP servers.
  local launcher="$REPO_ROOT/.zcrew/lib/launchers/claude.sh"
  grep -Fq -- '--strict-mcp-config' "$launcher" || return 1
  ! grep -Fq -- '--mcp-config' "$launcher"
}

test_44c_launchers_export_ai_kind() {
  local d="$REPO_ROOT/.zcrew/lib/launchers"
  grep -Fxq 'export AI_KIND=claude' "$d/claude.sh" || return 1
  grep -Fxq 'export AI_KIND=pi' "$d/pi.sh" || return 1
  # Codex sets AI_KIND in BOTH outer and inner sections (outer execs into bx).
  [[ "$(grep -Fxc 'export AI_KIND=codex' "$d/codex.sh")" -ge 2 ]]
}

test_45_install_self_install_no_crash() {
  local d fixture out
  d="$(new_test_dir 45)"
  fixture="$d/zcrew-fixture"
  cp -r "$REPO_ROOT" "$fixture" || return 1
  rm -rf "$fixture/.bx"
  find "$fixture/.zcrew" -mindepth 1 -maxdepth 1 ! -name bin ! -name lib -exec rm -rf {} + || return 1
  out=$(
    cd "$fixture" || exit 1
    ZCREW_AUTO_SYNC=0 "$fixture/.zcrew/bin/zcrew" install "$fixture" 2>&1
  ) || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "source == target" || return 1
  printf '%s\n' "$out" | grep -qi "cp: .*same file" && return 1
  [[ -d "$fixture/.bx" ]] || return 1
  [[ -x "$fixture/.zcrew/bin/zcrew" ]] || return 1
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

test_46b_resolve_sender_name_readonly_uses_tmux_pane_id_for_workers() {
  local d source_copy out before after
  d="$(new_test_dir 46b)"
  source_copy="$d/.zcrew/bin/zcrew-source"
  clear_mx_backend_state

  zcrew_cmd "$d" init >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  seed_local_lib_fixture "$d"
  mkdir -p "$d/.zcrew/bin"
  sed '$d' "$ZCREW_BIN" > "$source_copy" || { clear_mx_backend_state; return 1; }
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent claude --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  zcrew_cmd "$d" register claudio --paneId 5 --sessionId s5 --agent claude --cwd "$d" --pid 5 --status alive >/dev/null 2>&1 || { clear_mx_backend_state; return 1; }
  before="$(sha256sum "$d/.zcrew/registry.json")" || { clear_mx_backend_state; return 1; }

  out="$(
    cd "$d" || exit 1
    env -u BX_INSIDE -u ZELLIJ_PANE_ID -u ZELLIJ_SESSION_NAME ZCREW_AUTO_SYNC=0 TMUX=/tmp/tmux.sock,123,0 TMUX_PANE=%5 MOCK_TMUX_SESSION_NAME=sess bash -c 'set -euo pipefail; source "$1"; _resolve_and_set_project_dir stateful; ensure_registry_files; resolve_sender_name_readonly' bash "$source_copy"
  )" || { clear_mx_backend_state; return 1; }
  after="$(sha256sum "$d/.zcrew/registry.json")" || { clear_mx_backend_state; return 1; }

  [[ "$out" == "claudio" ]] || { clear_mx_backend_state; return 1; }
  [[ "$before" == "$after" ]] || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
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
  local d lib_copy
  d="$(new_test_dir 48)"
  lib_copy="$d/zcrew-lib.sh"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 50 --sessionId s50 --agent unknown --cwd "$d" --pid 50 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-99 --paneId 99 --sessionId s99 --agent unknown --cwd "$d" --pid 99 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$d/mock-bin" "$d/tell-args.txt" "50,99"
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 PATH="$d/mock-bin:$PATH" ZELLIJ_PANE_ID=99 ZELLIJ_SESSION_NAME=test-session bash -c 'set -euo pipefail; source "$1"; claim_main_for_send' bash "$lib_copy"
  ) || return 1

  jq -e '.panes.main.paneId == "50" and .panes["pane-99"].paneId == "99"' "$d/.zcrew/registry.json" >/dev/null
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
  printf '%s\n' "$out" | grep -Fq 'zcrew: worker panes cannot send directly to other workers.' || return 1
  printf '%s\n' "$out" | grep -Fq 'zcrew reply' || return 1
  [[ ! -e "$args_file" ]]
}

test_52_send_banner_host_only() {
  local d mockbin args_file sent
  local codex_footer
  d="$(new_test_dir 52)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"
  codex_footer=$'Call the mcp__zcrew__zcrew_reply tool with your message. If unavailable, run `zcrew reply "<your message>"` in your shell.\n\nOnly reply when you have a result, finding, blocker, or question. Never send acknowledgments. Never send to other workers.'

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register buddy --paneId 123 --sessionId s1 --agent claude --cwd "$d" --pid 2 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register piper --paneId 124 --sessionId s2 --agent pi --cwd "$d" --pid 3 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register coder --paneId 125 --sessionId s3 --agent codex --cwd "$d" --pid 4 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register mystery --paneId 126 --sessionId s4 --agent unknown --cwd "$d" --pid 5 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77,123,124,125,126"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" send buddy "hello claude" >/dev/null 2>&1) || return 1
  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" send piper "hello pi" >/dev/null 2>&1) || return 1
  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" send coder "hello codex" >/dev/null 2>&1) || return 1
  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" send mystery "hello unknown" >/dev/null 2>&1) || return 1
  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" send main "hello worker" >/dev/null 2>&1) || return 1

  sent="$(cat "$args_file")"
  # All managed agents (claude/codex/pi) auto-fire — message is verbatim, no footer.
  grep -Fxq "123 hello claude" <<< "$sent" || return 1
  grep -Fxq "124 hello pi" <<< "$sent" || return 1
  grep -Fxq "125 hello codex" <<< "$sent" || return 1
  # Unknown agent: fallback footer.
  grep -Fq "126 hello unknown" <<< "$sent" || return 1
  grep -Fq "$codex_footer" <<< "$sent" || return 1
  grep -Fq $'0 \n\nReply from pane-77:\nhello worker' <<< "$sent"
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
  # Claude target now has NO footer; verify message body landed on tell.
  grep -Fq 'hello after restart' "$args_file"
}


test_56_install_fresh_layout_writes_new_paths() {
  local d
  d="$(new_test_dir 56)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  assert_managed_zcrew_layout "$d" || return 1
  [[ ! -e "$d/bin/zcrew" ]] || return 1
  [[ ! -e "$d/lib/zcrew/tell" ]]
}

test_57_install_is_idempotent_on_migrated_target() {
  local d before after
  d="$(new_test_dir 57)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  before="$(find "$d/.zcrew/bin" "$d/.zcrew/lib" -type f -printf '%P %s\n' | sort)" || return 1
  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  after="$(find "$d/.zcrew/bin" "$d/.zcrew/lib" -type f -printf '%P %s\n' | sort)" || return 1

  [[ "$before" == "$after" ]]
}


test_59_install_migration_recovers_from_partial_copy() {
  local d
  d="$(new_test_dir 59)"
  seed_stale_zcrew_layout "$d"
  mkdir -p "$d/.zcrew/bin" "$d/.zcrew/lib"
  cp "$REPO_ROOT/.zcrew/bin/zcrew" "$d/.zcrew/bin/zcrew" || return 1

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  assert_managed_zcrew_layout "$d"
}


test_61_install_migration_keeps_mise_path_functional() {
  local d out
  d="$(new_test_dir 61)"
  seed_stale_zcrew_layout "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  out="$(cd "$d" && ZCREW_AUTO_SYNC=0 PATH="/usr/bin:/bin" bash -lc 'source .config/mise.toml >/dev/null 2>&1 || true; ./.zcrew/bin/zcrew init 2>&1')" || true

  [[ -f "$d/.zcrew/registry.json" ]]
}

test_62_install_keep_creates_bin_symlinks() {
  local d
  d="$(new_test_dir 62)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install --keep "$d" >/dev/null 2>&1 || return 1

  assert_managed_zcrew_layout "$d" || return 1
  [[ -L "$d/bin/zcrew" && "$(readlink "$d/bin/zcrew")" == '../.zcrew/bin/zcrew' ]] || return 1
  [[ -L "$d/bin/bx" && "$(readlink "$d/bin/bx")" == '../.zcrew/bin/bx' ]] || return 1
  [[ -L "$d/bin/ix" && "$(readlink "$d/bin/ix")" == '../.zcrew/bin/ix' ]]
}

test_63_install_keep_creates_lib_symlinks() {
  local d
  d="$(new_test_dir 63)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" --keep >/dev/null 2>&1 || return 1

  [[ -L "$d/lib/zcrew/tell" && "$(readlink "$d/lib/zcrew/tell")" == '../../.zcrew/lib/tell' ]] || return 1
  [[ -L "$d/lib/zcrew/launchers/claude.sh" && "$(readlink "$d/lib/zcrew/launchers/claude.sh")" == '../../../.zcrew/lib/launchers/claude.sh' ]] || return 1
  [[ -L "$d/lib/zcrew/launchers/codex.sh" && "$(readlink "$d/lib/zcrew/launchers/codex.sh")" == '../../../.zcrew/lib/launchers/codex.sh' ]] || return 1
  [[ -L "$d/lib/zcrew/launchers/pi.sh" && "$(readlink "$d/lib/zcrew/launchers/pi.sh")" == '../../../.zcrew/lib/launchers/pi.sh' ]]
}

test_64_install_keep_is_idempotent() {
  local d before after
  d="$(new_test_dir 64)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install --keep "$d" >/dev/null 2>&1 || return 1
  before="$(find "$d/bin" "$d/lib/zcrew" -type l -printf '%P -> %l\n' | sort)" || return 1
  zcrew_cmd "$TEST_ROOT" install "$d" --keep >/dev/null 2>&1 || return 1
  after="$(find "$d/bin" "$d/lib/zcrew" -type l -printf '%P -> %l\n' | sort)" || return 1

  [[ "$before" == "$after" ]]
}





test_69_install_keep_ignored_for_source_equals_target() {
  local d fixture out
  d="$(new_test_dir 69)"
  fixture="$d/zcrew-fixture"
  cp -r "$REPO_ROOT" "$fixture" || return 1
  rm -rf "$fixture/.bx"
  find "$fixture/.zcrew" -mindepth 1 -maxdepth 1 ! -name bin ! -name lib -exec rm -rf {} + || return 1

  out="$(cd "$fixture" && ZCREW_AUTO_SYNC=0 "$fixture/.zcrew/bin/zcrew" install --keep "$fixture" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }

  [[ ! -e "$fixture/bin/zcrew" ]] || return 1
  printf '%s\n' "$out" | grep -Fq 'source == target'
}

test_70_reply_rejects_host_usage() {
  local d out
  d="$(new_test_dir 70)"
  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1

  if out=$(cd "$d" && env -u BX_INSIDE ZELLIJ_SESSION_NAME=test-session "$ZCREW_BIN" reply "hello" 2>&1); then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew reply is for worker panes; from main, use: zcrew send <worker> "<message>"'
}

test_71_reply_requires_message() {
  local d mockbin out
  d="$(new_test_dir 71)"
  mockbin="$d/mock-bin"
  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$d/tell-args.txt" "0"

  if out=$(cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply 2>&1); then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'Usage: zcrew reply <message>'
}

test_72_reply_from_worker_sends_to_main() {
  local d mockbin args_file
  d="$(new_test_dir 72)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77"

  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply "foo" >/dev/null 2>&1) || return 1

  [[ "$(cat "$args_file")" == $'0 \n\nReply from pane-77:\nfoo' ]] || return 1
  grep -Fq $'\tsend\tinfo\tentry name=main' "$d/.zcrew/audit.log"
}

test_72k_reply_from_worker_preserves_multiline_body() {
  local d mockbin args_file sent expected
  d="$(new_test_dir 72k)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register sam --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77"

  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply $'line one\nline two' >/dev/null 2>&1) || return 1

  sent="$(cat "$args_file")"
  expected=$'0 \n\nReply from sam:\nline one\nline two'
  [[ "$sent" == "$expected" ]]
}

test_72l_reply_from_worker_with_empty_sender_uses_unknown() {
  local d mockbin args_file
  d="$(new_test_dir 72l)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77"

  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply "done" >/dev/null 2>&1) || return 1

  [[ "$(cat "$args_file")" == $'0 \n\nReply from unknown:\ndone' ]]
}

test_72m_reply_from_worker_with_slash_command_bypasses_prefix() {
  local d mockbin args_file
  d="$(new_test_dir 72m)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 0 --sessionId s0 --agent unknown --cwd "$d" --pid 1 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register sam --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "0,77"

  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply "/compact" >/dev/null 2>&1) || return 1

  [[ "$(cat "$args_file")" == '0 /compact' ]]
}

test_72b_claim_with_no_main_registers_caller() {
  local d mockbin out
  d="$(new_test_dir 72b)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$d/tell-args.txt" "42"

  out="$(cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=42 "$ZCREW_BIN" claim 2>&1)" || return 1
  [[ -z "$out" ]] || return 1
  jq -e '.panes.main.paneId == "42"' "$d/.zcrew/registry.json" >/dev/null
}

test_72c_claim_errors_when_live_main_owned_by_other_pane() {
  local d mockbin out
  d="$(new_test_dir 72c)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 50 --sessionId s50 --agent unknown --cwd "$d" --pid 50 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$d/tell-args.txt" "50,42"

  if out="$(cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=42 "$ZCREW_BIN" claim 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: main is already main (paneId 50). Use --replace to swap.'
}

test_72d_claim_is_idempotent_when_caller_is_live_main() {
  local d mockbin out
  d="$(new_test_dir 72d)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 42 --sessionId s42 --agent unknown --cwd "$d" --pid 42 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$d/tell-args.txt" "42"

  out="$(cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=42 "$ZCREW_BIN" claim 2>&1)" || return 1

  [[ -z "$out" ]] || return 1
  jq -e '.panes.main.paneId == "42"' "$d/.zcrew/registry.json" >/dev/null
}

test_72e_claim_replace_swaps_live_main_and_prints_old_info() {
  local d mockbin out
  d="$(new_test_dir 72e)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 50 --sessionId s50 --agent unknown --cwd "$d" --pid 50 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-42 --paneId 42 --sessionId s42 --agent unknown --cwd "$d" --pid 42 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$d/tell-args.txt" "50,42"

  out="$(cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=42 "$ZCREW_BIN" claim --replace 2>&1)" || return 1
  printf '%s\n' "$out" | grep -Fxq 'replacing main: main (paneId 50)' || return 1
  jq -e '.panes.main.paneId == "42" and (.panes | has("pane-42") | not)' "$d/.zcrew/registry.json" >/dev/null
}

test_72f_claim_from_worker_errors() {
  local d out
  d="$(new_test_dir 72f)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  if out="$(cd "$d" && BX_INSIDE=1 ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=42 "$ZCREW_BIN" claim 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew claim is host-only; run it in the orchestrator pane.'
}

test_72g_claim_outside_zellij_errors() {
  local d out
  d="$(new_test_dir 72g)"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  if out="$(cd "$d" && env -u BX_INSIDE -u ZELLIJ_PANE_ID -u ZELLIJ_SESSION_NAME "$ZCREW_BIN" claim 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: claim must be run inside a multiplexer pane'
}

test_72h_reply_without_main_shows_claim_hint() {
  local d mockbin args_file out
  d="$(new_test_dir 72h)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "77"

  if out="$(cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply "foo" 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: no main registered. Ask the user to run "zcrew claim" in the orchestrator pane.' || return 1
  [[ ! -e "$args_file" ]]
}

test_72i_reply_succeeds_after_orchestrator_claim() {
  local d mockbin args_file
  d="$(new_test_dir 72i)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "42,77"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=42 "$ZCREW_BIN" claim >/dev/null 2>&1) || return 1
  (cd "$d" && BX_INSIDE=1 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply "foo" >/dev/null 2>&1) || return 1

  [[ "$(cat "$args_file")" == $'42 \n\nReply from pane-77:\nfoo' ]]
}

test_72j_reply_with_stale_main_shows_claim_hint() {
  local d mockbin args_file out
  d="$(new_test_dir 72j)"
  mockbin="$d/mock-bin"
  args_file="$d/tell-args.txt"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register main --paneId 42 --sessionId s42 --agent unknown --cwd "$d" --pid 42 --status alive >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register pane-77 --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  prepare_send_test_tools "$d" "$mockbin" "$args_file" "77"

  if out="$(cd "$d" && BX_INSIDE=1 ZCREW_AUTO_SYNC=0 PATH="$mockbin:$PATH" MOCK_TELL_ARGS_FILE="$args_file" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=77 "$ZCREW_BIN" reply "foo" 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fxq 'zcrew: no live main registered. Ask the user to run "zcrew claim" in the orchestrator pane.' || return 1
  [[ ! -e "$args_file" ]]
}

test_73_reply_cmd_constant_is_single_source() {
  [[ "$(grep -Fc 'REPLY_CMD=' "$ZCREW_BIN")" -eq 1 ]] || return 1
  [[ "$(grep -Fc 'REPLY_CMD' "$ZCREW_BIN")" -ge 3 ]]
}

test_73_reply_cmd_constant_is_single_source() {
  [[ "$(grep -Fc 'REPLY_CMD=' "$ZCREW_BIN")" -eq 1 ]] || return 1
  [[ "$(grep -Fc 'REPLY_CMD' "$ZCREW_BIN")" -ge 3 ]]
}

test_74_skill_docs_reference_reply_mechanisms() {
  # Each worker type's auto-fire mechanism is documented somewhere in the skill.
  grep -Fq 'SessionStop hook' "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" || return 1
  grep -Fq 'app-server adapter' "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" || return 1
  grep -Fq 'agent_end' "$REPO_ROOT/.agents/skills/zcrew/SKILL.md" || return 1
  grep -Fq 'zcrew reply' "$REPO_ROOT/.claude/skills/zsend/SKILL.md" || return 1
  grep -Fq 'zcrew reply' "$REPO_ROOT/.pi/skills/zsend/SKILL.md"
}



test_77_upgrade_absent_file_is_noop_without_warning() {
  local d out
  d="$(new_test_dir 77)"
  mkdir -p "$d"

  out="$(zcrew_cmd "$TEST_ROOT" install "$d" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  ! printf '%s\n' "$out" | grep -Fq 'cannot verify bin/zcrew is zcrew-owned'
}





test_81b_verify_managed_copy_warns_on_mismatch() {
  local d lib_copy out rc
  d="$(new_test_dir 81b)"
  lib_copy="$d/zcrew-lib.sh"
  mkdir -p "$d/src/tree/sub" "$d/dst/tree/sub"
  printf 'one\n' > "$d/src/tree/SKILL.md"
  printf 'nested-good\n' > "$d/src/tree/sub/extra.txt"
  cp "$d/src/tree/SKILL.md" "$d/dst/tree/SKILL.md"
  printf 'nested-bad\n' > "$d/dst/tree/sub/extra.txt"
  source_zcrew_lib "$lib_copy"

  out="$(cd "$d" && bash -c 'set -euo pipefail; source "$1"; verify_managed_copy "$2" "$3"' bash "$lib_copy" "$d/src/tree" "$d/dst/tree" 2>&1; rc=$?; printf '\n__RC__=%s\n' "$rc")"
  rc="$(printf '%s\n' "$out" | sed -n 's/^__RC__=//p' | tail -n1)"
  out="$(printf '%s\n' "$out" | sed '/^__RC__=/d')"
  [[ "$rc" == "1" ]] || return 1
  printf '%s\n' "$out" | grep -Fxq 'warning: managed skill path was overwritten after install: dst/tree/sub/extra.txt' || return 1
  printf '%s\n' "$out" | grep -Fxq 'warning: some managed skill files do not match installed source content; investigate target post-install tooling'
}

test_81c_install_continues_when_verify_managed_copy_warns() {
  local d src_repo lib_copy target out
  d="$(new_test_dir 81c)"
  src_repo="$d/src-repo"
  lib_copy="$src_repo/.zcrew/bin/zcrew"
  target="$d/target"
  mkdir -p "$src_repo/.zcrew/bin" "$target"
  cp -r "$REPO_ROOT/.zcrew/lib" "$src_repo/.zcrew/" || return 1
  cp "$REPO_ROOT/.zcrew/bin/bx" "$src_repo/.zcrew/bin/bx" || return 1
  cp "$REPO_ROOT/.zcrew/bin/ix" "$src_repo/.zcrew/bin/ix" || return 1
  cp -r "$REPO_ROOT/.agents" "$src_repo/" || return 1
  cp -r "$REPO_ROOT/.claude" "$src_repo/" || return 1
  cp -r "$REPO_ROOT/.pi" "$src_repo/" || return 1
  cp -r "$REPO_ROOT/.codex" "$src_repo/" || return 1
  cp "$REPO_ROOT/AGENTS.md" "$src_repo/AGENTS.md" || return 1
  source_zcrew_lib "$lib_copy"

  out="$(bash -c '
    set -euo pipefail
    source "$1"
    verify_managed_copy() {
      echo "warning: managed skill path was overwritten after install: .claude/skills/zspawn/SKILL.md" >&2
      echo "warning: some managed skill files do not match installed source content; investigate target post-install tooling" >&2
      return 1
    }
    unset BX_INSIDE
    ZCREW_AUTO_SYNC=0
    cmd_install "$2"
  ' bash "$lib_copy" "$target" 2>&1)" || return 1

  printf '%s\n' "$out" | grep -Fxq 'warning: managed skill path was overwritten after install: .claude/skills/zspawn/SKILL.md' || return 1
  printf '%s\n' "$out" | grep -Fxq 'warning: some managed skill files do not match installed source content; investigate target post-install tooling' || return 1
  printf '%s\n' "$out" | grep -Fxq '    .claude/skills/zspawn' || return 1
  [[ -f "$target/.claude/skills/zspawn/SKILL.md" ]]
}

test_82_install_mount_block_rewrite_is_idempotent() {
  local d first second
  d="$(new_test_dir 82)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  first="$(cat "$d/.bx/mounts")"
  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  second="$(cat "$d/.bx/mounts")"
  [[ "$first" == "$second" ]]
}

test_82aa_write_managed_bx_mounts_uses_local_sources_when_project_lib_exists() {
  local d lib_copy target_abs
  d="$(new_test_dir 82aa)"
  lib_copy="$d/zcrew-lib.sh"
  target_abs="$(realpath "$d")"
  mkdir -p "$d/.bx" "$d/.zcrew/lib" "$d/.zcrew/bin" "$d/.config"
  seed_local_tell_sentinel "$d"
  printf 'dummy\n' > "$d/.config/mise.toml"
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    # shellcheck disable=SC1090
    source "$lib_copy"
    PROJECT_DIR="$d"
    HOME="$d/home"
    _RESOLVED_LIB_DIR=""
    write_managed_bx_mounts "$d" >/dev/null
  ) || return 1

  grep -Fqx "$target_abs/.zcrew/bin $target_abs/.zcrew/bin ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.zcrew/lib $target_abs/.zcrew/lib ro" "$d/.bx/mounts" || return 1
  grep -Fqx '# install-mode: local (.zcrew/bin + .zcrew/lib)' "$d/.bx/mounts"
}


test_82ac_write_managed_bx_mounts_is_idempotent() {
  local d lib_copy first second home_dir
  d="$(new_test_dir 82ac)"
  lib_copy="$d/zcrew-lib.sh"
  home_dir="$d/home"
  mkdir -p "$d/.bx" "$d/.zcrew" "$d/.config" "$home_dir"
  printf 'dummy\n' > "$d/.config/mise.toml"
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    # shellcheck disable=SC1090
    source "$lib_copy"
    PROJECT_DIR="$d"
    HOME="$home_dir"
    _RESOLVED_LIB_DIR=""
    write_managed_bx_mounts "$d" >/dev/null
  ) || return 1
  first="$(cat "$d/.bx/mounts")"

  (
    cd "$d" || exit 1
    # shellcheck disable=SC1090
    source "$lib_copy"
    PROJECT_DIR="$d"
    HOME="$home_dir"
    _RESOLVED_LIB_DIR=""
    write_managed_bx_mounts "$d" >/dev/null || true
  ) || return 1
  second="$(cat "$d/.bx/mounts")"
  [[ "$first" == "$second" ]]
}

test_44h_runtime_resolvers_drop_global_zcrew_fallbacks() {
  local d home_dir out legacy_bin_ref legacy_share_ref
  local codex_copy mcp_copy node_bin python_bin
  d="$(new_test_dir 44h)"
  home_dir="$d/home"
  codex_copy="$d/codex-auto-reply.mjs"
  mcp_copy="$d/mcp_server.py"
  node_bin=""
  if [[ -x /usr/bin/node ]]; then
    node_bin=/usr/bin/node
  fi
  if [[ -x /usr/bin/python3 ]]; then
    python_bin=/usr/bin/python3
  else
    python_bin="$(python3 -c 'import sys; print(sys.executable)')" || return 1
  fi
  cp "$REPO_ROOT/.zcrew/lib/codex-auto-reply.mjs" "$codex_copy" || return 1
  cp "$REPO_ROOT/.zcrew/lib/mcp_server.py" "$mcp_copy" || return 1
  mkdir -p "$home_dir"
  legacy_bin_ref='~/'".local/bin/"'zcrew'
  legacy_share_ref='.local/share/'"zcrew/lib"

  if [[ -n "$node_bin" ]]; then
    if out="$(env -i HOME="$home_dir" PATH=/nonexistent "$node_bin" "$codex_copy" 2>&1)"; then
      return 1
    fi
    printf '%s\n' "$out" | grep -Fq 'checked ZCREW_BIN, local ../bin/zcrew, and PATH' || return 1
    ! printf '%s\n' "$out" | grep -Fq "$legacy_bin_ref" || return 1
  else
    grep -Fq "checked ZCREW_BIN, local ../bin/zcrew, and PATH" "$codex_copy" || return 1
    ! grep -Fq "$legacy_bin_ref" "$codex_copy" || return 1
  fi

  if out="$(env -i HOME="$home_dir" PATH=/nonexistent "$python_bin" "$mcp_copy" 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq 'checked ZCREW_BIN, local ../bin/zcrew, and PATH' || return 1
  ! printf '%s\n' "$out" | grep -Fq "$legacy_bin_ref" || return 1

  ! grep -Fq "$legacy_bin_ref" .zcrew/lib/pi-zcrew-ext.ts || return 1
  ! grep -Fq "$legacy_share_ref" .zcrew/bin/bx
}



test_82af_write_managed_bx_mounts_uses_tmux_socket_dir_from_TMUX() {
  local d lib_copy target_abs
  d="$(new_test_dir 82af)"
  lib_copy="$d/zcrew-lib.sh"
  target_abs="$(realpath "$d")"
  clear_mx_backend_state
  mkdir -p "$d/.bx" "$d/.zcrew/lib" "$d/.zcrew/bin" "$d/.config"
  seed_local_tell_sentinel "$d"
  printf 'dummy\n' > "$d/.config/mise.toml"
  source_zcrew_lib "$lib_copy"

  (
    cd "$d" || exit 1
    # shellcheck disable=SC1090
    source "$lib_copy"
    PROJECT_DIR="$d"
    HOME="$d/home"
    TMUX="/tmp/tmux-1000/mysock,12345,0"
    _MX_BACKEND=tmux
    _MX_BACKEND_CHECKED=1
    _RESOLVED_LIB_DIR=""
    write_managed_bx_mounts "$d" >/dev/null
  ) || { clear_mx_backend_state; return 1; }

  grep -Fqx "/tmp/tmux-1000 /tmp/tmux-1000 rw" "$d/.bx/mounts" || { clear_mx_backend_state; return 1; }
  grep -Fqx "$target_abs/.zcrew/bin $target_abs/.zcrew/bin ro" "$d/.bx/mounts" || { clear_mx_backend_state; return 1; }
  clear_mx_backend_state
}

test_82ag_mx_socket_dir_tmux_empty_TMUX_hard_errors() {
  local out
  clear_mx_backend_state
  if out="$(
    env -u ZELLIJ_SESSION_NAME -u TMUX bash -lc '
      set -euo pipefail
      unset _MX_BACKEND _MX_BACKEND_CHECKED
      source "$1"
      _MX_BACKEND=tmux
      mx_socket_dir
    ' bash "$REPO_ROOT/.zcrew/lib/multiplexer.sh" 2>&1
  )"; then
    clear_mx_backend_state
    return 1
  fi
  clear_mx_backend_state
  printf '%s\n' "$out" | grep -Fq "zcrew: tmux backend selected but \$TMUX is empty (no live session?); cannot determine socket dir"
}

test_82b_install_preserves_corrupt_mount_markers_with_warning() {
  local d out before after custom_src custom_dst
  d="$(new_test_dir 82b)"
  custom_src="$d/custom-src"
  custom_dst="/opt/custom"
  mkdir -p "$d/.bx" "$custom_src"
  cat > "$d/.bx/mounts" <<EOF
$custom_src $custom_dst ro
# zcrew-managed begin
/old/zellij /run/user/$(id -u)/zellij rw
$custom_src /opt/after ro
EOF
  before="$(cat "$d/.bx/mounts")"

  out="$(zcrew_cmd "$TEST_ROOT" install "$d" 2>&1)" || return 1
  after="$(cat "$d/.bx/mounts")"
  [[ "$before" == "$after" ]] || return 1
  printf '%s\n' "$out" | grep -Fq 'warning: .bx/mounts has invalid zcrew-managed markers; preserving existing file:'
}

test_82c_install_preserves_misordered_mount_markers_with_warning() {
  local d out before after custom_src custom_dst
  d="$(new_test_dir 82c)"
  custom_src="$d/custom-src"
  custom_dst="/opt/custom"
  mkdir -p "$d/.bx" "$custom_src"
  cat > "$d/.bx/mounts" <<EOF
$custom_src $custom_dst ro
# zcrew-managed end
$custom_src /opt/between ro
# zcrew-managed begin
$custom_src /opt/after ro
EOF
  before="$(cat "$d/.bx/mounts")"

  out="$(zcrew_cmd "$TEST_ROOT" install "$d" 2>&1)" || return 1
  after="$(cat "$d/.bx/mounts")"
  [[ "$before" == "$after" ]] || return 1
  printf '%s\n' "$out" | grep -Fq 'warning: .bx/mounts has invalid zcrew-managed markers; preserving existing file:'
}

test_82d_install_mount_block_includes_managed_bx_files_ro() {
  local d target_abs sandbox_home
  d="$(new_test_dir 82d)"
  target_abs="$(realpath "$d")"
  sandbox_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
  sandbox_home="${sandbox_home:-$HOME}"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  grep -Fqx "$target_abs/.bx/config $target_abs/.bx/config ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.bx/mounts $target_abs/.bx/mounts ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.bx/.gitignore $target_abs/.bx/.gitignore ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.bx/home/.config/git/ignore $target_abs/.bx/home/.config/git/ignore ro" "$d/.bx/mounts" || return 1
  grep -Fqx "$target_abs/.bx/home/.config/git/ignore $sandbox_home/.config/git/ignore ro" "$d/.bx/mounts"
}

test_83_bx_ro_mount_blocks_zcrew_bin_and_lib_but_runtime_state_stays_writable() {
  local d host_home
  d="$(new_test_dir 83)"
  host_home="$d/host-home"
  mkdir -p "$d" "$host_home"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  (cd "$d" && env -u BX_INSIDE HOME="$host_home" TERM="${TERM:-xterm-256color}" "$d/.zcrew/bin/bx" run bash -lc '
    set +e
    failures=0
    rm -f .zcrew/bin/zcrew >/dev/null 2>&1
    status_bin_rm=$?
    rm -f .zcrew/lib/tell >/dev/null 2>&1
    status_lib_rm=$?
    printf runtime-audit >> .zcrew/audit.log || failures=1
    printf "{\"ok\":true}\n" > .zcrew/registry.json || failures=1
    : > .zcrew/registry.lock || failures=1
    mkdir -p .zcrew/feed .zcrew/outbox .zcrew/spawn || failures=1
    touch .zcrew/feed/probe .zcrew/outbox/probe .zcrew/spawn/probe || failures=1
    touch ~/.writable || failures=1
    if [[ $status_bin_rm -eq 0 || $status_lib_rm -eq 0 ]]; then
      failures=1
    fi
    exit $failures
  ' >/dev/null 2>&1) || return 1

  [[ -e "$d/.zcrew/bin/zcrew" ]] || return 1
  [[ -e "$d/.zcrew/lib/tell" ]] || return 1
  grep -Fq 'runtime-audit' "$d/.zcrew/audit.log" || return 1
  grep -Fxq '{"ok":true}' "$d/.zcrew/registry.json" || return 1
  [[ -f "$d/.zcrew/registry.lock" ]] || return 1
  [[ -f "$d/.zcrew/feed/probe" ]] || return 1
  [[ -f "$d/.zcrew/outbox/probe" ]] || return 1
  [[ -f "$d/.zcrew/spawn/probe" ]] || return 1
  [[ -f "$d/.bx/home/.writable" ]]
}

test_83b_bx_ro_mount_blocks_managed_bx_files_but_home_stays_writable() {
  local d host_home out
  d="$(new_test_dir 83b)"
  host_home="$d/host-home"
  mkdir -p "$d" "$host_home"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  out="$(cd "$d" && env -u BX_INSIDE HOME="$host_home" TERM="${TERM:-xterm-256color}" "$REPO_ROOT/.zcrew/bin/bx" run bash -lc '
    set +e
    failures=0
    for path in .bx/config .bx/mounts .bx/.gitignore .bx/home/.config/git/ignore ~/.config/git/ignore; do
      rm -f "$path" >/dev/null 2>&1
      status_rm=$?
      printf x > "$path" >/dev/null 2>&1
      status_write=$?
      if [[ $status_rm -eq 0 || $status_write -eq 0 ]]; then
        echo "unexpectedly writable: $path"
        failures=1
      fi
    done
    printf "# sandbox-write\n" >> ~/.bashrc || failures=1
    printf "sandbox-claude\n" > ~/.claude.json || failures=1
    exit $failures
  ' 2>&1 || true)"

  grep -Fq 'WORKDIR=' "$d/.bx/config" || return 1
  grep -Fq '# zcrew-managed begin' "$d/.bx/mounts" || return 1
  grep -Fq 'home/' "$d/.bx/.gitignore" || return 1
  grep -Fq '.zcrew/' "$d/.bx/home/.config/git/ignore" || return 1
  grep -Fq '# sandbox-write' "$d/.bx/home/.bashrc" || return 1
  grep -Fxq 'sandbox-claude' "$d/.bx/home/.claude.json" || return 1
  ! printf '%s\n' "$out" | grep -Fq 'unexpectedly writable:'
}

# ── Codex auto-reply hardening: state cleanup tests ─────────────────────

test_84_close_kills_outer_pid_and_removes_state_dir() {
  local d mockbin close_log state_dir pane_pid starttime
  d="$(new_test_dir 84)"
  mockbin="$d/mock-bin"
  close_log="$d/close.log"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register coder --paneId 125 --sessionId s125 --agent codex --cwd "$d" --pid 4 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  state_dir="$d/.zcrew/state/codex-worker/125"
  mkdir -p "$state_dir"
  bash -c 'exec -a "bash codex.sh" sleep 60' &
  pane_pid=$!
  starttime="$(read_proc_starttime "$pane_pid")" || { kill "$pane_pid" 2>/dev/null; return 1; }
  printf '%s\n' "$pane_pid" > "$state_dir/outer.pid"
  printf '%s\n' "$starttime" > "$state_dir/outer.starttime"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_CLOSE_LOG_FILE="$close_log" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" close coder >/dev/null 2>&1) || { kill "$pane_pid" 2>/dev/null; return 1; }

  ! kill -0 "$pane_pid" 2>/dev/null || { kill "$pane_pid" 2>/dev/null; return 1; }
  [[ ! -d "$state_dir" ]] || return 1
  grep -Fq 'close-pane -p 125' "$close_log"
}

test_84b_close_cleans_stale_state_when_outer_pid_is_dead() {
  local d mockbin state_dir dead_pid
  d="$(new_test_dir 84b)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register coder --paneId 126 --sessionId s126 --agent codex --cwd "$d" --pid 4 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  state_dir="$d/.zcrew/state/codex-worker/126"
  mkdir -p "$state_dir"
  sleep 0.1 &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '%s\n' "$dead_pid" > "$state_dir/outer.pid"
  printf '%s\n' "1" > "$state_dir/outer.starttime"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" close coder >/dev/null 2>&1) || return 1

  [[ ! -d "$state_dir" ]]
}

test_84c_close_skips_kill_when_outer_starttime_is_missing_and_cleans_state() {
  local d mockbin state_dir pid
  d="$(new_test_dir 84c)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register coder --paneId 127 --sessionId s127 --agent codex --cwd "$d" --pid 4 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  state_dir="$d/.zcrew/state/codex-worker/127"
  mkdir -p "$state_dir"
  sleep 60 &
  pid=$!
  printf '%s\n' "$pid" > "$state_dir/outer.pid"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" close coder >/dev/null 2>&1) || { kill "$pid" 2>/dev/null; return 1; }

  kill -0 "$pid" 2>/dev/null || return 1
  kill "$pid" 2>/dev/null || true
  [[ ! -d "$state_dir" ]]
}

test_85_reconcile_orphan_walk_cleans_not_live_preserves_live() {
  local d mockbin dead_dir live_dir dead_pid live_pid dead_starttime live_starttime
  d="$(new_test_dir 85)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  dead_dir="$d/.zcrew/state/codex-worker/888"
  live_dir="$d/.zcrew/state/codex-worker/777"
  mkdir -p "$dead_dir" "$live_dir"
  bash -c 'exec -a "bash codex.sh" sleep 60' & dead_pid=$!
  bash -c 'exec -a "bash codex.sh" sleep 60' & live_pid=$!
  dead_starttime="$(read_proc_starttime "$dead_pid")" || { kill "$dead_pid" "$live_pid" 2>/dev/null; return 1; }
  live_starttime="$(read_proc_starttime "$live_pid")" || { kill "$dead_pid" "$live_pid" 2>/dev/null; return 1; }
  printf '%s\n' "$dead_pid" > "$dead_dir/outer.pid"
  printf '%s\n' "$live_pid" > "$live_dir/outer.pid"
  printf '%s\n' "$dead_starttime" > "$dead_dir/outer.starttime"
  printf '%s\n' "$live_starttime" > "$live_dir/outer.starttime"

  (cd "$d" && env -u BX_INSIDE ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_777' ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" list --json >/dev/null 2>&1) || { kill "$dead_pid" "$live_pid" 2>/dev/null; return 1; }

  if kill -0 "$dead_pid" 2>/dev/null; then kill "$dead_pid" "$live_pid" 2>/dev/null; return 1; fi
  if ! kill -0 "$live_pid" 2>/dev/null; then kill "$live_pid" 2>/dev/null; return 1; fi
  kill "$live_pid" 2>/dev/null
  [[ ! -d "$dead_dir" ]] || return 1
  [[ -d "$live_dir" ]]
}

test_86_gc_force_ignores_live_filter_but_respects_freshness() {
  local d mockbin old_dir new_dir old_pid new_pid old_starttime new_starttime
  d="$(new_test_dir 86)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  old_dir="$d/.zcrew/state/codex-worker/901"
  new_dir="$d/.zcrew/state/codex-worker/902"
  mkdir -p "$old_dir" "$new_dir"
  bash -c 'exec -a "bash codex.sh" sleep 60' & old_pid=$!
  bash -c 'exec -a "bash codex.sh" sleep 60' & new_pid=$!
  old_starttime="$(read_proc_starttime "$old_pid")" || { kill "$old_pid" "$new_pid" 2>/dev/null; return 1; }
  new_starttime="$(read_proc_starttime "$new_pid")" || { kill "$old_pid" "$new_pid" 2>/dev/null; return 1; }
  printf '%s\n' "$old_pid" > "$old_dir/outer.pid"
  printf '%s\n' "$new_pid" > "$new_dir/outer.pid"
  printf '%s\n' "$old_starttime" > "$old_dir/outer.starttime"
  printf '%s\n' "$new_starttime" > "$new_dir/outer.starttime"
  touch -d '2 minutes ago' "$old_dir"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" "$ZCREW_BIN" gc --force >/dev/null 2>&1) || { kill "$old_pid" "$new_pid" 2>/dev/null; return 1; }

  if kill -0 "$old_pid" 2>/dev/null; then kill "$old_pid" "$new_pid" 2>/dev/null; return 1; fi
  if ! kill -0 "$new_pid" 2>/dev/null; then kill "$new_pid" 2>/dev/null; return 1; fi
  kill "$new_pid" 2>/dev/null
  [[ ! -d "$old_dir" ]] || return 1
  [[ -d "$new_dir" ]]
}

test_87_reconcile_empty_live_skips_orphan_walk() {
  local d mockbin state_dir pid starttime
  d="$(new_test_dir 87)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register alive --paneId 77 --sessionId s77 --agent unknown --cwd "$d" --pid 77 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  state_dir="$d/.zcrew/state/codex-worker/999"
  mkdir -p "$state_dir"
  bash -c 'exec -a "bash codex.sh" sleep 60' & pid=$!
  starttime="$(read_proc_starttime "$pid")" || { kill "$pid" 2>/dev/null; return 1; }
  printf '%s\n' "$pid" > "$state_dir/outer.pid"
  printf '%s\n' "$starttime" > "$state_dir/outer.starttime"

  (cd "$d" && env -u BX_INSIDE ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='' ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" list --json >/dev/null 2>&1) || { kill "$pid" 2>/dev/null; return 1; }

  if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
  kill "$pid" 2>/dev/null
  [[ -d "$state_dir" ]]
}

test_88_close_skips_kill_when_identity_mismatches_and_cleans_state() {
  local d mockbin state_dir fake_pid fake_starttime
  d="$(new_test_dir 88)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  zcrew_cmd "$d" register coder --paneId 200 --sessionId s200 --agent codex --cwd "$d" --pid 4 --status alive >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  state_dir="$d/.zcrew/state/codex-worker/200"
  mkdir -p "$state_dir"

  sleep 300 &
  fake_pid=$!
  fake_starttime="$(read_proc_starttime "$fake_pid")" || { kill "$fake_pid" 2>/dev/null; return 1; }
  printf '%s\n' "$fake_pid" > "$state_dir/outer.pid"
  printf '%s\n' "$((fake_starttime + 1))" > "$state_dir/outer.starttime"

  (cd "$d" && env -u BX_INSIDE PATH="$mockbin:$PATH" MOCK_ZELLIJ_CLOSE_LOG_FILE="$d/close.log" ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" close coder >/dev/null 2>&1) || { kill "$fake_pid" 2>/dev/null; return 1; }

  kill -0 "$fake_pid" 2>/dev/null || return 1
  kill "$fake_pid" 2>/dev/null || true
  [[ ! -d "$state_dir" ]]
}

test_89_orphan_walk_skips_kill_when_identity_mismatches_and_cleans_state() {
  local d mockbin orphan_dir fake_pid fake_starttime
  d="$(new_test_dir 89)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  orphan_dir="$d/.zcrew/state/codex-worker/333"
  mkdir -p "$orphan_dir"

  sleep 300 &
  fake_pid=$!
  fake_starttime="$(read_proc_starttime "$fake_pid")" || { kill "$fake_pid" 2>/dev/null; return 1; }
  printf '%s\n' "$fake_pid" > "$orphan_dir/outer.pid"
  printf '%s\n' "$((fake_starttime + 1))" > "$orphan_dir/outer.starttime"
  touch -d '2 minutes ago' "$orphan_dir"

  (cd "$d" && env -u BX_INSIDE ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_999' ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" list --json >/dev/null 2>&1) || { kill "$fake_pid" 2>/dev/null; return 1; }

  kill -0 "$fake_pid" 2>/dev/null || return 1
  kill "$fake_pid" 2>/dev/null || true
  [[ ! -d "$orphan_dir" ]]
}

test_89b_orphan_walk_skips_kill_when_outer_starttime_is_missing_and_cleans_state() {
  local d mockbin orphan_dir pid
  d="$(new_test_dir 89b)"
  mockbin="$d/mock-bin"

  zcrew_cmd "$d" init >/dev/null 2>&1 || return 1
  make_mock_zellij "$mockbin"

  orphan_dir="$d/.zcrew/state/codex-worker/334"
  mkdir -p "$orphan_dir"
  sleep 60 &
  pid=$!
  printf '%s\n' "$pid" > "$orphan_dir/outer.pid"
  touch -d '2 minutes ago' "$orphan_dir"

  (cd "$d" && env -u BX_INSIDE ZCREW_AUTO_SYNC=1 PATH="$mockbin:$PATH" MOCK_ZELLIJ_LIST_OUTPUT='terminal_999' ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID=0 "$ZCREW_BIN" list --json >/dev/null 2>&1) || { kill "$pid" 2>/dev/null; return 1; }

  kill -0 "$pid" 2>/dev/null || return 1
  kill "$pid" 2>/dev/null || true
  [[ ! -d "$orphan_dir" ]]
}

# ── Orchestrator-side seeding tests (codex MCP + pi extension) ──────────

test_90_install_seeds_codex_config_toml() {
  local d
  d="$(new_test_dir 90)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  # .codex/config.toml exists with [mcp_servers.zcrew] block
  [[ -f "$d/.codex/config.toml" ]] || return 1
  grep -Fxq '[mcp_servers.zcrew]' "$d/.codex/config.toml" || return 1
  grep -Fq 'command = "python3"' "$d/.codex/config.toml" || return 1
  grep -Fq "$(realpath "$d/.zcrew/lib/mcp_server.py")" "$d/.codex/config.toml"
}

test_91_install_seeds_pi_extension_symlink() {
  local d
  d="$(new_test_dir 91)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  # .pi/extensions/zcrew.ts is a relative symlink when project-local lib is used.
  [[ -L "$d/.pi/extensions/zcrew.ts" ]] || return 1
  [[ "$(readlink "$d/.pi/extensions/zcrew.ts")" == '../../.zcrew/lib/pi-zcrew-ext.ts' ]] || return 1
  # Symlink resolves to the real file
  [[ -f "$d/.pi/extensions/zcrew.ts" ]]
}

test_92_install_codex_and_pi_seeding_is_idempotent() {
  local d before_codex after_codex before_pi after_pi
  d="$(new_test_dir 92)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  before_codex=$(cat "$d/.codex/config.toml")
  before_pi=$(readlink "$d/.pi/extensions/zcrew.ts")

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  after_codex=$(cat "$d/.codex/config.toml")
  after_pi=$(readlink "$d/.pi/extensions/zcrew.ts")

  [[ "$before_codex" == "$after_codex" ]] || return 1
  [[ "$before_pi" == "$after_pi" ]]
}

test_93_install_codex_config_preserves_other_mcp_servers() {
  local d
  d="$(new_test_dir 93)"
  mkdir -p "$d/.codex"
  cat > "$d/.codex/config.toml" <<'TOML'
[model]
name = "gpt-4"

[mcp_servers.other_thing]
command = "echo"
args = ["hello"]
TOML

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  # other_thing block preserved
  grep -Fxq '[mcp_servers.other_thing]' "$d/.codex/config.toml" || return 1
  grep -Fq 'command = "echo"' "$d/.codex/config.toml" || return 1
  # Unrelated keys preserved
  grep -Fq 'name = "gpt-4"' "$d/.codex/config.toml" || return 1
  # zcrew block added
  grep -Fxq '[mcp_servers.zcrew]' "$d/.codex/config.toml"
}

test_94_install_codex_config_preserves_unrelated_keys() {
  local d
  d="$(new_test_dir 94)"
  mkdir -p "$d/.codex"
  cat > "$d/.codex/config.toml" <<'TOML'
[chat]
auto_compact = true

[notifications]
enabled = false
TOML

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  grep -Fq 'auto_compact = true' "$d/.codex/config.toml" || return 1
  grep -Fq 'enabled = false' "$d/.codex/config.toml" || return 1
  grep -Fxq '[mcp_servers.zcrew]' "$d/.codex/config.toml"
}

test_95_install_pi_extensions_preserves_other_extensions() {
  local d
  d="$(new_test_dir 95)"
  mkdir -p "$d/.pi/extensions"
  printf '// user extension\n' > "$d/.pi/extensions/user-ext.ts"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1

  # User extension still present
  [[ -f "$d/.pi/extensions/user-ext.ts" ]] || return 1
  [[ "$(cat "$d/.pi/extensions/user-ext.ts")" == '// user extension' ]] || return 1
  # zcrew symlink added
  [[ -L "$d/.pi/extensions/zcrew.ts" ]]
}


test_95c_seed_mcp_configs_fails_loud_when_server_missing() {
  local d home_dir lib_copy out
  d="$(new_test_dir 95c)"
  home_dir="$d/home"
  lib_copy="$d/zcrew-lib.sh"
  mkdir -p "$d/.zcrew/lib" "$home_dir"
  cat > "$d/.zcrew/lib/tell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$d/.zcrew/lib/tell"

  source_zcrew_lib "$lib_copy"
  # shellcheck disable=SC1090
  source "$lib_copy"
  PROJECT_DIR="$d"
  HOME="$home_dir"
  _RESOLVED_LIB_DIR=""
  if out="$(seed_mcp_configs "$d" 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq 'zcrew install: lib not found at'
  printf '%s\n' "$out" | grep -Fq 'Run .zcrew/bin/zcrew install'
}

test_95d_seed_orchestrator_configs_fails_loud_when_server_missing() {
  local d home_dir lib_copy out
  d="$(new_test_dir 95d)"
  home_dir="$d/home"
  lib_copy="$d/zcrew-lib.sh"
  mkdir -p "$d/.zcrew/lib" "$home_dir"
  cat > "$d/.zcrew/lib/tell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$d/.zcrew/lib/tell"

  source_zcrew_lib "$lib_copy"
  # shellcheck disable=SC1090
  source "$lib_copy"
  PROJECT_DIR="$d"
  HOME="$home_dir"
  _RESOLVED_LIB_DIR=""
  if out="$(seed_orchestrator_configs "$d" 2>&1)"; then
    return 1
  fi
  printf '%s\n' "$out" | grep -Fq 'zcrew install: lib not found at'
  printf '%s\n' "$out" | grep -Fq 'Run .zcrew/bin/zcrew install'
}

test_106_clone_mode_install_materializes_local_layout() {
  local d
  d="$(new_test_dir 106)"
  mkdir -p "$d"

  zcrew_cmd "$TEST_ROOT" install "$d" >/dev/null 2>&1 || return 1
  [[ -x "$d/.zcrew/bin/zcrew" ]] || return 1
  [[ -x "$d/.zcrew/bin/bx" ]] || return 1
  [[ -x "$d/.zcrew/lib/tell" ]] || return 1
  [[ -f "$d/.agents/skills/zcrew/SKILL.md" ]] || return 1
  [[ -f "$d/AGENTS.md" ]] || return 1
  [[ -f "$d/.bx/config" ]] || return 1
  [[ -f "$d/.zcrew/registry.json" ]]
}





main() {
  mkdir -p "$TEST_ROOT"

  run_test "0) source files have no hardcoded home path literals" test_0_no_hardcoded_home_paths_in_source_files
  run_test "xmx-a) multiplexer lazy init sets backend only on first use" test_xmx_a_multiplexer_lazy_init_sets_backend_only_on_first_use
  run_test "xmx-b) sourcing without mux does not error and register still succeeds" test_xmx_b_sourcing_without_mux_does_not_error_and_register_still_succeeds
  run_test "xmx-c) operational mx call errors when both mux envs are set" test_xmx_c_operational_call_errors_when_both_mux_envs_are_set
  run_test "xmx-d) mx_require_session errors when no mux env is set" test_xmx_d_require_session_errors_when_no_mux_env_is_set
  run_test "xmx-e) register and unregister succeed when both mux envs are set" test_xmx_e_register_and_unregister_succeed_when_both_mux_envs_are_set
  run_test "xmx-f) first mux op writes registry backend marker" test_xmx_f_backend_written_on_first_mux_op
  run_test "xmx-g) register does not write registry backend marker" test_xmx_g_backend_not_written_on_register
  run_test "xmx-h) same backend mux op does not reset panes" test_xmx_h_backend_no_reset_same_mux
  run_test "xmx-i) backend switch resets panes and logs audit event" test_xmx_i_backend_reset_wipes_panes_and_audits
  run_test "xmx-j) legacy registry adopts backend on first mux op" test_xmx_j_backend_legacy_adopts_on_first_mux_op
  run_test "xmx-k) tmux spawn parses % pane id from split-window" test_xmx_k_spawn_tmux_split_window_parses_pct_pane_id
  run_test "xmx-kb) tmux spawn sets pane title after split-window" test_xmx_kb_spawn_tmux_sets_pane_title_after_spawn
  run_test "xmx-kc) tmux spawn tiles layout after split-window" test_xmx_kc_spawn_tmux_tiles_layout_after_spawn
  run_test "xmx-l) tmux close kills % pane target" test_xmx_l_close_tmux_kill_pane_with_pct_prefix
  run_test "xmx-m) tmux list strips % from live pane ids" test_xmx_m_list_tmux_strips_percent_from_all_ids
  run_test "xmx-n) tmux rename uses select-pane -T" test_xmx_n_rename_tmux_select_pane_T
  run_test "xmx-nb) tmux send-text uses bracketed paste, settle delay, and C-m" test_xmx_nb_send_tmux_uses_bracketed_paste_and_cr
  run_test "xmx-o) tmux claim uses stripped TMUX_PANE" test_xmx_o_claim_uses_tmux_pane_stripped
  run_test "xmx-p) tmux stale session check hard-errors" test_xmx_p_session_check_tmux_stale_hard_errors
  run_test "xmx-q) tmux headless transport matrix" test_xmx_q_tmux_transport_text_matrix
  run_test "1) init creates .zcrew with empty registry" test_1_init_creates_registry
  run_test "2) list empty registry (plain + json)" test_2_list_empty_plain_and_json
  run_test "3) register creates then updates entry" test_3_register_create_then_update
  run_test "4) list outside zcrew project fails hard" test_4_list_outside_project_fails_hard
  run_test "5) parallel register keeps all entries" test_5_parallel_register_all_present
  run_test "6) sync --prune removes stale entries with mocked zellij" test_6_sync_prune_with_mocked_zellij
  run_test "6b) sync inside bx is a no-op" test_6b_reconcile_inside_bx_is_noop
  run_test "6c) sync prune empty live set warns and preserves registry" test_6c_sync_prune_empty_live_set_warns_and_preserves_registry
  run_test "6d) sync prune preserves named aliases for live panes" test_6d_sync_prune_preserves_named_aliases_for_live_panes
  # SKIP 7: placeholder promotion is for a later step (cmd_spawn currently minimal)
  # run_test "7) placeholder promotion leaves only main" test_7_placeholder_promotion_no_duplicate
  run_test "9) send calls tell with paneId and message" test_9_send_calls_tell_with_expected_args
  run_test "9h) send refuses target registered in different project" test_9h_send_refuses_target_registered_in_different_project
  run_test "9i) send backfills legacy entry when cwd resolves to same project" test_9i_send_backfills_legacy_entry_when_cwd_resolves_to_same_project
  run_test "9j) send refuses legacy entry when cwd resolves to different project" test_9j_send_refuses_legacy_entry_when_cwd_resolves_to_different_project
  run_test "9k) send refuses legacy entry when project ownership is unknown" test_9k_send_refuses_legacy_entry_when_project_ownership_is_unknown
  run_test "9b) send --compact calls tell twice with a compaction delay" test_9b_send_compact_calls_tell_twice_with_delay
  run_test "9c) send without --compact still calls tell once" test_9c_send_without_compact_calls_tell_once
  run_test "9d) send /compact from host skips banner" test_9d_send_slash_command_skips_banner_from_host
  run_test "9e) send arbitrary slash command from host skips banner" test_9e_send_arbitrary_slash_command_skips_banner_from_host
  run_test "9f) send path-like slash message from host keeps banner" test_9f_send_path_like_message_keeps_banner_from_host
  run_test "10) sync without prune marks stale but keeps entries" test_10_sync_no_prune_marks_stale_not_delete
  run_test "11) spawn unknown agent uses bx fallback" test_11_spawn_unknown_agent_uses_bx_fallback
  run_test "11b) spawn duplicate name fails before opening a pane" test_11b_spawn_duplicate_name_fails_before_new_pane
  run_test "11c) spawn reuses a name after auto-pruning a stale entry" test_11c_spawn_allows_name_after_pruning_stale_entry
  run_test "11d) spawn fresh name succeeds" test_11d_spawn_fresh_name_succeeds
  run_test "11e) spawn built-in agent uses launcher script" test_11e_spawn_builtin_agent_uses_launcher_script
  run_test "11i) spawn shell-quotes built-in launcher paths with spaces" test_11i_spawn_builtin_launcher_path_is_shell_quoted
  run_test "11f) spawn seeds missing managed bx mounts" test_11f_spawn_seeds_missing_managed_mounts
  run_test "11g) spawn repairs managed mounts preserving custom lines" test_11g_spawn_repairs_managed_mounts_preserving_custom_lines
  run_test "11h) spawn claims host as main when absent" test_11h_spawn_claims_host_as_main_when_absent
  run_test "11i) spawn does not churn when live main exists" test_11i_spawn_does_not_churn_when_live_main_exists
  run_test "11j) spawn outside multiplexer skips claim without error" test_11j_spawn_outside_zellij_skips_claim_without_error
  run_test "11k) spawn picks team.conf model when CLI omits --model" test_11k_spawn_uses_team_conf_model_when_cli_omits
  run_test "11l) spawn keeps model unset when team.conf row is dash placeholder" test_11l_spawn_team_conf_dash_keeps_model_unset
  run_test "11m) spawn CLI --model wins over team.conf" test_11m_spawn_cli_model_wins_over_team_conf
  run_test "11n) spawn keeps model unset when name missing from team.conf" test_11n_spawn_name_missing_from_team_conf_keeps_model_unset
  run_test "11o) spawn fails cleanly when zcrew is not on PATH for EXIT trap" test_11o_spawn_fails_when_zcrew_missing_on_path
  run_test "11p) spawn EXIT trap uses resolved zcrew binary path" test_11p_spawn_trap_uses_resolved_binary_not_project_literal
  run_test "11q) spawn EXIT trap canonicalizes symlinked zcrew path" test_11q_spawn_trap_canonicalizes_symlinked_zcrew_path
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
  run_test "18f) install trusts managed mise floor when mise exists" test_18f_install_trusts_managed_mise_floor_when_mise_exists
  run_test "18g) install writes sandbox git ignore and managed gitconfig" test_18g_install_writes_sandbox_git_ignore_and_managed_gitconfig
  run_test "18h) install preserves user sandbox gitconfig" test_18h_install_preserves_user_sandbox_gitconfig
  run_test "18i) install rewrites managed sandbox gitconfig" test_18i_install_rewrites_managed_sandbox_gitconfig
  run_test "18j) install preserves gitconfig with nonleading managed marker" test_18j_install_preserves_gitconfig_with_nonleading_managed_marker
  run_test "18k) dry-run exits zero without mutation" test_18k_dryrun_exits_zero_without_mutation
  run_test "18l) dry-run plan has REPLACE/KEEP/SKIP sections in order" test_18l_dryrun_plan_has_three_sections
  run_test "18m) dry-run plan includes core files" test_18m_dryrun_plan_includes_core_files
  run_test "18n) dry-run plan keeps runtime state" test_18n_dryrun_plan_keeps_runtime_state
  run_test "18o) dry-run plan keeps mixed-content files" test_18o_dryrun_plan_keeps_mixed_content
  run_test "18p) dry-run skips custom AGENTS.md" test_18p_dryrun_skips_user_agents_md
  run_test "18q) dry-run replaces custom skill content on zcrew-owned path" test_18q_dryrun_replaces_user_skill_path_owned_by_zcrew
  run_test "18qa) dry-run keeps existing managed AGENTS.md" test_18qa_dryrun_keeps_existing_managed_agents_md
  run_test "18r) dry-run distinguishes pristine vs modified managed files" test_18r_dryrun_classifies_pristine_vs_modified
  run_test "18s) dry-run classifies absent managed files as create" test_18s_dryrun_classifies_absent_as_create
  run_test "18t) dry-run treats pre-marker lib files as replace on zcrew-owned paths" test_18t_dryrun_path_owned_premarker_lib_file_is_replace_not_skip
  run_test "19) resolve_project_dir uses state from project root" test_19_resolve_project_dir_from_root_uses_local_state
  run_test "20) resolve_project_dir walks up from subdir" test_20_resolve_project_dir_walks_up_from_subdir
  run_test "20b) resolve_project_dir fails outside zcrew tree" test_20b_resolve_project_dir_fails_outside_zcrew_tree
  run_test "20c) resolve_project_dir redirects worktree to main registry" test_20c_resolve_project_dir_worktree_uses_main_registry
  run_test "96) resolver returns ZCREW_PROJECT_DIR when set and valid" test_96_resolver_returns_env_var_when_set_and_valid
  run_test "96a) resolver allows ZCREW_PROJECT_DIR when cwd resolves to same project" test_96a_resolver_allows_env_when_cwd_resolves_to_same_project
  run_test "96b) resolver allows ZCREW_PROJECT_DIR when cwd is same-project worktree" test_96b_resolver_allows_env_when_cwd_is_same_project_worktree
  run_test "96c) resolver allows ZCREW_PROJECT_DIR when cwd has no resolvable project" test_96c_resolver_allows_env_when_cwd_has_no_resolvable_project
  run_test "96e) resolver allows ZCREW_PROJECT_DIR when cwd is plain git repo without .zcrew" test_96e_resolver_allows_env_when_cwd_is_plain_git_repo_without_zcrew
  run_test "96d) resolver errors when env and cwd projects disagree" test_96d_resolver_errors_when_env_and_cwd_projects_disagree
  run_test "97) resolver ignores ZCREW_PROJECT_DIR when BX_INSIDE=1" test_97_resolver_ignores_env_var_inside_sandbox
  run_test "98) resolver stateful errors in git repo subdir without .zcrew" test_98_resolver_stateful_errors_in_git_repo_subdir_without_zcrew
  run_test "99) resolver stateful errors in git root without .zcrew" test_99_resolver_stateful_errors_in_git_root_without_zcrew
  run_test "100) resolver discovery returns git root for init" test_100_resolver_discovery_returns_git_root_for_init
  run_test "101) resolver worktree redirects to main repo" test_101_resolver_worktree_redirects_to_main_repo
  run_test "102) resolver canonicalizes via realpath" test_102_resolver_canonicalizes_via_realpath
  run_test "103) resolve_lib_dir prefers project-local lib when present" test_103_resolve_lib_dir_prefers_project_local
  run_test "104b) resolve_lib_dir cache hits for same project" test_104b_resolve_lib_dir_cache_hits_same_project
  run_test "105) resolve_lib_dir hard-errors when no lib dirs exist" test_105_resolve_lib_dir_errors_when_missing
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
  run_test "32b) install writes .zcrew/lib/tell" test_32b_install_writes_internal_tell_binary
  run_test "32bb) tell shim delegates to mx_send_text with zellij byte sequence" test_32bb_tell_shim_uses_mx_send_text_zellij_sequence
  run_test "32bc) install replaces old tell byte-sequence script with managed shim" test_32bc_install_replaces_old_tell_byte_sequence_with_managed_shim
  run_test "32c) install writes non-executable multiplexer library" test_32c_install_writes_nonexecutable_multiplexer_library
  run_test "33) install does not write host ~/.pi or ~/.agents" test_33_install_does_not_write_host_pi_dirs
  run_test "34) installed .pi skills have valid required frontmatter" test_34_pi_skill_frontmatter_sanity
  run_test "34b) install writes canonical .agents zcrew skill plus copied codex/pi/claude views" test_34b_install_writes_cross_tool_zcrew_skill_layout
  run_test "34c) second install overwrites .codex zcrew skill" test_34c_second_install_overwrites_codex_skill_with_latest_content
  run_test "34c-symlink) install materializes zcrew skill symlinks as real dirs" test_34c_install_materializes_zcrew_skill_symlinks_as_real_dirs
  run_test "34d) installed .codex zcrew skill has simplified frontmatter" test_34d_codex_skill_frontmatter_sanity
  run_test "34e) install writes AGENTS.md and CLAUDE.md symlink when both are missing" test_34e_install_seeds_agents_and_claude_symlink_when_both_missing
  run_test "34f) install skips AGENTS.md and CLAUDE.md when AGENTS.md already exists" test_34f_install_skips_agents_and_claude_when_agents_exists
  run_test "34g) install writes AGENTS.md only when CLAUDE.md already exists" test_34g_install_writes_agents_only_when_claude_exists
  run_test "34h) install seeds .zcrew/team.conf template" test_34h_install_seeds_team_conf_template
  run_test "34i) reinstall preserves existing .zcrew/team.conf" test_34i_reinstall_preserves_existing_team_conf
  run_test "34j) install seeds .mcp.json + sandbox MCP configs" test_34j_install_seeds_mcp_configs
  run_test "34k) reinstall preserves other MCP servers in .mcp.json" test_34k_reinstall_preserves_other_mcp_servers
  run_test "35) send to claude target refreshes auth in .bx/home" test_35_send_claude_target_refreshes_auth_files
  run_test "36) send to codex target skips claude auth refresh" test_36_send_codex_target_skips_claude_auth_refresh
  run_test "37) send to unknown target skips claude auth refresh" test_37_send_unknown_target_skips_claude_auth_refresh
  run_test "38) send with missing host .claude.json generates minimal target state" test_38_send_missing_host_claude_json_generates_minimal_target_state
  run_test "39) send with missing host credentials soft-fails" test_39_send_missing_host_credentials_soft_fails
  run_test "40) send without target .bx/home soft-fails" test_40_send_without_target_bx_home_soft_fails
  run_test "41) successful claude auth refresh leaves no tmp files" test_41_send_claude_refresh_leaves_no_tmp_files
  run_test "42) codex launcher runs inside bx (outer/inner re-entry)" test_42_codex_launcher_runs_inside_bx
  run_test "42c) stop-hook resolves to its own project from foreign cwd" test_42c_stop_hook_uses_own_project_when_cwd_is_other_project
  run_test "43) codex launcher forwards model through bx" test_43_codex_launcher_forwards_model_through_bx
  run_test "43b) codex launcher references adapter path relative to launcher location" test_43b_codex_launcher_uses_launcher_relative_adapter_path
  run_test "44) codex launcher does not mutate sandbox config before bx run" test_44_codex_launcher_does_not_mutate_sandbox_config_before_bx_run
  run_test "44d) codex launcher writes outer pid + starttime identity files" test_44d_codex_launcher_writes_outer_identity_files
  run_test "44f) codex launcher strips % from TMUX_PANE for state dir" test_44f_codex_launcher_tmux_pane_strips_percent_for_state_dir
  run_test "44g) codex launcher tmux session name feeds port hash" test_44g_codex_launcher_tmux_session_name_feeds_port_hash
  run_test "44h) runtime resolvers drop global zcrew fallbacks" test_44h_runtime_resolvers_drop_global_zcrew_fallbacks
  run_test "44e) parse_proc_stat_starttime handles spaces in comm" test_44e_parse_proc_stat_starttime_handles_spaces_in_comm
  run_test "44b) claude launcher does not pass --mcp-config (zero MCP for worker)" test_44b_claude_launcher_drops_mcp_config
  run_test "44c) all launchers export AI_KIND" test_44c_launchers_export_ai_kind
  run_test "45) install where src == target skips materialization without crashing" test_45_install_self_install_no_crash
  run_test "46) resolve_sender_name_readonly is pure and returns empty for unmapped panes" test_46_resolve_sender_name_readonly_is_pure
  run_test "46b) resolve_sender_name_readonly uses TMUX_PANE for worker sender resolution" test_46b_resolve_sender_name_readonly_uses_tmux_pane_id_for_workers
  run_test "47) claim_main_for_send promotes host pane to main when main is absent" test_47_claim_main_for_send_promotes_host_when_main_absent
  run_test "48) claim_main_for_send no-ops when a live main exists" test_48_claim_main_for_send_noops_when_live_main_exists
  run_test "49) claim_main_for_send no-ops inside workers" test_49_claim_main_for_send_worker_never_claims
  run_test "50) send rejects self-send" test_50_send_rejects_self_send
  run_test "51) send rejects worker-to-worker delivery" test_51_send_rejects_worker_to_worker
  run_test "52) send banner is host-only with exact literal" test_52_send_banner_host_only
  run_test "53) rename guards main alias" test_53_rename_main_alias_guards
  run_test "54) send reclaims main after host restart" test_54_send_claims_main_after_main_disappears
  run_test "56) fresh install writes only new .zcrew-owned paths" test_56_install_fresh_layout_writes_new_paths
  run_test "57) install is idempotent on migrated targets" test_57_install_is_idempotent_on_migrated_target
  run_test "59) migration recovers from partial new-layout copy" test_59_install_migration_recovers_from_partial_copy
  run_test "61) migrated .zcrew/bin zcrew remains functional" test_61_install_migration_keeps_mise_path_functional
  run_test "62) install --keep creates transitional bin symlinks" test_62_install_keep_creates_bin_symlinks
  run_test "63) install --keep creates transitional lib symlinks" test_63_install_keep_creates_lib_symlinks
  run_test "64) install --keep is idempotent" test_64_install_keep_is_idempotent
  run_test "69) source==target ignores --keep" test_69_install_keep_ignored_for_source_equals_target
  run_test "70) reply rejects host usage" test_70_reply_rejects_host_usage
  run_test "71) reply requires message" test_71_reply_requires_message
  run_test "72) reply from worker sends to main" test_72_reply_from_worker_sends_to_main
  run_test "72k) worker reply preserves multiline body" test_72k_reply_from_worker_preserves_multiline_body
  run_test "72l) worker reply with empty sender uses unknown" test_72l_reply_from_worker_with_empty_sender_uses_unknown
  run_test "72m) worker slash-command reply bypasses prefix" test_72m_reply_from_worker_with_slash_command_bypasses_prefix
  run_test "72b) claim with no main registers caller" test_72b_claim_with_no_main_registers_caller
  run_test "72c) claim errors when live main owned by other pane" test_72c_claim_errors_when_live_main_owned_by_other_pane
  run_test "72d) claim is idempotent when caller is live main" test_72d_claim_is_idempotent_when_caller_is_live_main
  run_test "72e) claim --replace swaps live main and prints old info" test_72e_claim_replace_swaps_live_main_and_prints_old_info
  run_test "72f) claim from worker errors" test_72f_claim_from_worker_errors
  run_test "72g) claim outside multiplexer errors" test_72g_claim_outside_zellij_errors
  run_test "72h) worker reply without main shows claim hint" test_72h_reply_without_main_shows_claim_hint
  run_test "72i) worker reply succeeds after orchestrator claim" test_72i_reply_succeeds_after_orchestrator_claim
  run_test "72j) worker reply with stale main shows claim hint" test_72j_reply_with_stale_main_shows_claim_hint
  run_test "73) REPLY_CMD constant is single-source" test_73_reply_cmd_constant_is_single_source
  run_test "74) skill docs reference per-agent reply mechanisms" test_74_skill_docs_reference_reply_mechanisms
  run_test "77) upgrade absent file is no-op without warning" test_77_upgrade_absent_file_is_noop_without_warning
  run_test "81b) verify_managed_copy warns on mismatch" test_81b_verify_managed_copy_warns_on_mismatch
  run_test "81c) install continues when verify_managed_copy warns" test_81c_install_continues_when_verify_managed_copy_warns
  run_test "82) install mount block rewrite is idempotent" test_82_install_mount_block_rewrite_is_idempotent
  run_test "82aa) write_managed_bx_mounts uses local sources when project lib exists" test_82aa_write_managed_bx_mounts_uses_local_sources_when_project_lib_exists
  run_test "82ac) write_managed_bx_mounts is idempotent" test_82ac_write_managed_bx_mounts_is_idempotent
  run_test "82af) write_managed_bx_mounts uses tmux socket dir from \$TMUX" test_82af_write_managed_bx_mounts_uses_tmux_socket_dir_from_TMUX
  run_test "82ag) mx_socket_dir tmux with empty \$TMUX hard-errors" test_82ag_mx_socket_dir_tmux_empty_TMUX_hard_errors
  run_test "82b) install preserves corrupt mount markers with warning" test_82b_install_preserves_corrupt_mount_markers_with_warning
  run_test "82c) install preserves misordered mount markers with warning" test_82c_install_preserves_misordered_mount_markers_with_warning
  run_test "82d) install mount block includes managed bx files ro" test_82d_install_mount_block_includes_managed_bx_files_ro
  run_test "83) bx RO mount blocks .zcrew bin/lib while runtime state stays writable" test_83_bx_ro_mount_blocks_zcrew_bin_and_lib_but_runtime_state_stays_writable
  run_test "83b) bx RO mount blocks managed bx files while HOME stays writable" test_83b_bx_ro_mount_blocks_managed_bx_files_but_home_stays_writable
  run_test "84) close kills outer.pid and removes codex worker state dir" test_84_close_kills_outer_pid_and_removes_state_dir
  run_test "84b) close cleans stale state when outer pid is dead" test_84b_close_cleans_stale_state_when_outer_pid_is_dead
  run_test "84c) close skips kill when outer starttime is missing and cleans state" test_84c_close_skips_kill_when_outer_starttime_is_missing_and_cleans_state
  run_test "85) reconcile orphan walk cleans not-live, preserves live" test_85_reconcile_orphan_walk_cleans_not_live_preserves_live
  run_test "86) gc --force ignores live filter, preserves fresh dirs" test_86_gc_force_ignores_live_filter_but_respects_freshness
  run_test "87) reconcile with empty live list skips orphan walk" test_87_reconcile_empty_live_skips_orphan_walk
  run_test "88) close skips kill on pid+starttime mismatch and cleans state" test_88_close_skips_kill_when_identity_mismatches_and_cleans_state
  run_test "89) orphan walk skips kill on pid+starttime mismatch and cleans state" test_89_orphan_walk_skips_kill_when_identity_mismatches_and_cleans_state
  run_test "89b) orphan walk skips kill when outer starttime is missing and cleans state" test_89b_orphan_walk_skips_kill_when_outer_starttime_is_missing_and_cleans_state
  run_test "90) install seeds .codex/config.toml with zcrew MCP entry" test_90_install_seeds_codex_config_toml
  run_test "91) install seeds .pi/extensions/zcrew.ts symlink" test_91_install_seeds_pi_extension_symlink
  run_test "92) install codex/pi seeding is idempotent" test_92_install_codex_and_pi_seeding_is_idempotent
  run_test "93) install codex config preserves other MCP servers" test_93_install_codex_config_preserves_other_mcp_servers
  run_test "94) install codex config preserves unrelated keys" test_94_install_codex_config_preserves_unrelated_keys
  run_test "95) install pi extensions preserves other extensions" test_95_install_pi_extensions_preserves_other_extensions
  run_test "95c) seed_mcp_configs fails loudly when resolved lib server is missing" test_95c_seed_mcp_configs_fails_loud_when_server_missing
  run_test "95d) seed_orchestrator_configs fails loudly when resolved lib server is missing" test_95d_seed_orchestrator_configs_fails_loud_when_server_missing
  run_test "106) clone-mode install still materializes local tooling + skills" test_106_clone_mode_install_materializes_local_layout

  echo ""
  echo "Total: $PASS_COUNT PASS, $FAIL_COUNT FAIL"

  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
