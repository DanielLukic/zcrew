#!/usr/bin/env bash
# Real-multiplexer integration tests using ephemeral private sessions.
# Each backend is gated behind an availability probe and skips cleanly
# when headless or unavailable — never hangs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZCREW_BIN="$REPO_ROOT/.zcrew/bin/zcrew"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass()  { echo "PASS: $1"; (( PASS_COUNT++ )); }
fail()  { echo "FAIL: $1"; (( FAIL_COUNT++ )); }
skip()  { echo "SKIP: $1"; (( SKIP_COUNT++ )); }

# ── tmux probe ───────────────────────────────────────────────────────────────
TMUX_SOCK=""
TMUX_SESSION=""
TMUX_AVAILABLE=0

tmux_probe() {
  command -v tmux >/dev/null 2>&1 || return 1
  TMUX_SOCK="/tmp/zcrew-test-tmux-$$"
  TMUX_SESSION="zcrew-test-$$"
  tmux -S "$TMUX_SOCK" new-session -d -s "$TMUX_SESSION" 2>/dev/null || return 1
  TMUX_AVAILABLE=1
}

tmux_teardown() {
  [[ "$TMUX_AVAILABLE" -eq 0 ]] && return
  tmux -S "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -f "$TMUX_SOCK"
}

# ── zellij probe ─────────────────────────────────────────────────────────────
ZELLIJ_AVAILABLE=0

zellij_probe() {
  command -v zellij >/dev/null 2>&1 || return 1
  timeout 5 zellij list-sessions >/dev/null 2>&1 || return 1
  ZELLIJ_AVAILABLE=1
}

cleanup() {
  tmux_teardown
}
trap cleanup EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
zcrew_in() {
  local dir="$1"; shift
  (
    cd "$dir"
    env -u BX_INSIDE \
        -u ZCREW_PROJECT_DIR \
        -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID -u ZELLIJ_TAB_NAME -u ZELLIJ_SESSION_ID \
        -u TMUX -u TMUX_PANE \
        ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" "$@"
  )
}

# ── tmux tests ───────────────────────────────────────────────────────────────

# tmux-int-a: ephemeral session is visible in tmux list-sessions
test_tmux_int_a_session_name() {
  local found
  found="$(tmux -S "$TMUX_SOCK" list-sessions -F '#{session_name}' 2>/dev/null | grep -Fx "$TMUX_SESSION" || true)"
  [[ "$found" == "$TMUX_SESSION" ]]
}

# tmux-int-b: list panes returns at least one
test_tmux_int_b_list_panes() {
  local count
  count="$(tmux -S "$TMUX_SOCK" list-panes -t "$TMUX_SESSION" 2>/dev/null | wc -l)"
  (( count >= 1 ))
}

# tmux-int-c: spawn a pane and verify it appears in pane list
test_tmux_int_c_pane_spawn_visible() {
  local pane_count_before pane_count_after new_pane_id
  pane_count_before="$(tmux -S "$TMUX_SOCK" list-panes -a 2>/dev/null | wc -l)"

  new_pane_id="$(
    tmux -S "$TMUX_SOCK" split-window -d -P -F '#{pane_id}' \
      -t "$TMUX_SESSION" -- bash -c 'sleep 5' 2>/dev/null || true
  )"
  new_pane_id="${new_pane_id#%}"

  pane_count_after="$(tmux -S "$TMUX_SOCK" list-panes -a 2>/dev/null | wc -l)"
  [[ -n "$new_pane_id" ]] && tmux -S "$TMUX_SOCK" kill-pane -t "%$new_pane_id" 2>/dev/null || true

  (( pane_count_after > pane_count_before ))
}

# tmux-int-d: rename a pane via tmux select-pane -T
test_tmux_int_d_pane_rename() {
  local pane_id title_result
  pane_id="$(tmux -S "$TMUX_SOCK" list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1 || true)"
  pane_id="${pane_id#%}"
  [[ -n "$pane_id" ]] || return 1

  tmux -S "$TMUX_SOCK" select-pane -t "%$pane_id" -T "zcrew-test-title" 2>/dev/null || return 1
  title_result="$(tmux -S "$TMUX_SOCK" display-message -p -t "%$pane_id" '#{pane_title}' 2>/dev/null || true)"
  [[ "$title_result" == "zcrew-test-title" ]]
}

# tmux-int-e: zcrew init + register round-trip inside ephemeral session
test_tmux_int_e_init_register_roundtrip() {
  local tmpdir out pane_id
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  pane_id="$(tmux -S "$TMUX_SOCK" list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1 || true)"
  pane_id="${pane_id#%}"
  [[ -n "$pane_id" ]] || return 1

  zcrew_in "$tmpdir" init >/dev/null 2>&1 || return 1
  zcrew_in "$tmpdir" register "test-worker" \
    --paneId "$pane_id" --sessionId "$TMUX_SESSION" \
    --agent claude --cwd "$tmpdir" --pid $$ --status alive \
    >/dev/null 2>&1 || return 1

  out="$(zcrew_in "$tmpdir" list 2>&1)" || return 1
  printf '%s\n' "$out" | grep -Fq "test-worker"
}

# tmux-int-f: zcrew list shows registered pane
test_tmux_int_f_list_shows_pane() {
  local tmpdir out pane_id
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  pane_id="$(tmux -S "$TMUX_SOCK" list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1 || true)"
  pane_id="${pane_id#%}"
  [[ -n "$pane_id" ]] || return 1

  zcrew_in "$tmpdir" init >/dev/null 2>&1 || return 1
  zcrew_in "$tmpdir" register "monitor" \
    --paneId "$pane_id" --sessionId "$TMUX_SESSION" \
    --agent claude --cwd "$tmpdir" --pid $$ --status alive \
    >/dev/null 2>&1 || return 1

  out="$(zcrew_in "$tmpdir" list 2>&1)"
  printf '%s\n' "$out" | grep -Fq "monitor"
}

# tmux-int-g: zcrew does NOT write to live REPO_ROOT audit.log
test_tmux_int_g_no_live_audit_contamination() {
  local tmpdir live_audit before_hash after_hash pane_id
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  live_audit="$REPO_ROOT/.zcrew/audit.log"
  before_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  pane_id="$(tmux -S "$TMUX_SOCK" list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1 || true)"
  pane_id="${pane_id#%}"

  zcrew_in "$tmpdir" init >/dev/null 2>&1 || true
  [[ -n "$pane_id" ]] && zcrew_in "$tmpdir" register "canary" \
    --paneId "$pane_id" --sessionId "$TMUX_SESSION" \
    --agent claude --cwd "$tmpdir" --pid $$ --status alive \
    >/dev/null 2>&1 || true
  zcrew_in "$tmpdir" list >/dev/null 2>&1 || true

  after_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"
  [[ "$before_hash" == "$after_hash" ]]
}

# tmux-int-h: zcrew register then unregister leaves registry clean
test_tmux_int_h_register_unregister_clean() {
  local tmpdir out pane_id
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  pane_id="$(tmux -S "$TMUX_SOCK" list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1 || true)"
  pane_id="${pane_id#%}"
  [[ -n "$pane_id" ]] || return 1

  zcrew_in "$tmpdir" init >/dev/null 2>&1 || return 1
  zcrew_in "$tmpdir" register "ephemeral" \
    --paneId "$pane_id" --sessionId "$TMUX_SESSION" \
    --agent claude --cwd "$tmpdir" --pid $$ --status alive \
    >/dev/null 2>&1 || return 1

  out="$(zcrew_in "$tmpdir" list 2>&1)"
  printf '%s\n' "$out" | grep -Fq "ephemeral" || return 1

  zcrew_in "$tmpdir" unregister "ephemeral" >/dev/null 2>&1 || return 1

  out="$(zcrew_in "$tmpdir" list 2>&1)"
  ! printf '%s\n' "$out" | grep -Fq "ephemeral"
}

wait_for_file_nonempty() {
  local file="$1"
  local timeout_sec="${2:-5}"
  local deadline
  deadline=$((SECONDS + timeout_sec))

  while (( SECONDS < deadline )); do
    [[ -s "$file" ]] && return 0
    sleep 0.05
  done

  [[ -s "$file" ]]
}

wait_for_pane_mode() {
  local pane_id="$1"
  local expected="$2"
  local timeout_sec="${3:-5}"
  local deadline mode
  deadline=$((SECONDS + timeout_sec))

  while (( SECONDS < deadline )); do
    mode="$(tmux -S "$TMUX_SOCK" display-message -p -t "%$pane_id" '#{pane_key_mode}' 2>/dev/null || true)"
    [[ "$mode" == "$expected" ]] && return 0
    sleep 0.05
  done

  mode="$(tmux -S "$TMUX_SOCK" display-message -p -t "%$pane_id" '#{pane_key_mode}' 2>/dev/null || true)"
  [[ "$mode" == "$expected" ]]
}

tmux_send_text_submits() {
  local extended_keys="$1"
  local extended_format="$2"
  local request_ext2="$3"
  local tmpdir capture_file pane_id payload status
  tmpdir="$(mktemp -d)"
  capture_file="$tmpdir/submitted.txt"
  payload="zcrew-submit-${extended_keys}-${extended_format}-$$"
  status=0

  tmux -S "$TMUX_SOCK" set-option -g extended-keys "$extended_keys" >/dev/null 2>&1 || status=1
  tmux -S "$TMUX_SOCK" set-option -g extended-keys-format "$extended_format" >/dev/null 2>&1 || status=1

  if [[ "$status" -eq 0 ]]; then
    pane_id="$(
      tmux -S "$TMUX_SOCK" split-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -- \
        env CAPTURE_FILE="$capture_file" ZCREW_REQUEST_EXT2="$request_ext2" bash -lc '
          [[ "$ZCREW_REQUEST_EXT2" == "1" ]] && printf "\033[>4;2m"
          IFS= read -r line
          printf "%s\n" "$line" > "$CAPTURE_FILE"
          sleep 5
        ' 2>/dev/null || true
    )"
    pane_id="${pane_id#%}"
    [[ -n "$pane_id" ]] || status=1
  fi

  if [[ "$status" -eq 0 && "$request_ext2" == "1" ]]; then
    wait_for_pane_mode "$pane_id" "Ext 2" 5 || status=1
  fi

  if [[ "$status" -eq 0 ]]; then
    (
      export TMUX="$TMUX_SOCK,0,0"
      export TMUX_PANE="%$pane_id"
      unset ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID BASH_ENV ENV REGISTRY_FILE PROJECT_DIR _MX_BACKEND _MX_BACKEND_CHECKED
      source "$REPO_ROOT/.zcrew/lib/multiplexer.sh"
      mx_send_text "$pane_id" "$payload"
    ) >/dev/null 2>&1 || status=1
  fi

  if [[ "$status" -eq 0 ]]; then
    wait_for_file_nonempty "$capture_file" 5 || status=1
  fi

  if [[ "$status" -eq 0 ]]; then
    python3 - "$capture_file" "$payload" <<'PY' || status=1
import sys

path, payload = sys.argv[1], sys.argv[2].encode()
expected = b"\x1b[200~" + payload + b"\x1b[201~\n"
with open(path, "rb") as fh:
    data = fh.read()
if data != expected:
    raise SystemExit(f"unexpected submitted bytes: {data!r}")
PY
  fi

  [[ -z "${pane_id:-}" ]] || tmux -S "$TMUX_SOCK" kill-pane -t "%$pane_id" 2>/dev/null || true
  rm -rf "$tmpdir"
  return "$status"
}

# tmux-int-i: mx_send_text submits with extended keys disabled
test_tmux_int_i_send_text_submits_extended_keys_off() {
  tmux_send_text_submits "off" "xterm" "0"
}

# tmux-int-j: mx_send_text submits with xterm extended keys in Ext 2 mode
test_tmux_int_j_send_text_submits_extended_keys_xterm() {
  tmux_send_text_submits "on" "xterm" "1"
}

# tmux-int-k: mx_send_text submits with csi-u extended keys in Ext 2 mode
test_tmux_int_k_send_text_submits_extended_keys_csi_u() {
  tmux_send_text_submits "on" "csi-u" "1"
}

# ── runner ───────────────────────────────────────────────────────────────────
run_test() {
  local desc="$1"
  local fn="$2"
  local output
  if output="$("$fn" 2>&1)"; then
    pass "$desc"
  else
    fail "$desc"
    [[ -z "$output" ]] || printf '  %s\n' "$output"
  fi
}

echo "==> Probing tmux..."
if tmux_probe; then
  echo "    tmux available (session=$TMUX_SESSION sock=$TMUX_SOCK)"
  run_test "tmux-int-a: session name resolves" test_tmux_int_a_session_name
  run_test "tmux-int-b: list panes returns >=1" test_tmux_int_b_list_panes
  run_test "tmux-int-c: spawn pane visible" test_tmux_int_c_pane_spawn_visible
  run_test "tmux-int-d: rename pane" test_tmux_int_d_pane_rename
  run_test "tmux-int-e: init+register roundtrip" test_tmux_int_e_init_register_roundtrip
  run_test "tmux-int-f: list shows pane" test_tmux_int_f_list_shows_pane
  run_test "tmux-int-g: no live audit.log contamination" test_tmux_int_g_no_live_audit_contamination
  run_test "tmux-int-h: register then unregister" test_tmux_int_h_register_unregister_clean
  run_test "tmux-int-i: send-text submits with extended-keys off" test_tmux_int_i_send_text_submits_extended_keys_off
  run_test "tmux-int-j: send-text submits with extended-keys xterm Ext 2" test_tmux_int_j_send_text_submits_extended_keys_xterm
  run_test "tmux-int-k: send-text submits with extended-keys csi-u Ext 2" test_tmux_int_k_send_text_submits_extended_keys_csi_u
else
  skip "tmux-int-a through tmux-int-k (tmux unavailable)"
fi

echo "==> Probing zellij..."
if zellij_probe; then
  echo "    zellij available"
  skip "zellij-int (no headless session support yet)"
else
  skip "zellij-int (zellij unavailable or headless)"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
(( FAIL_COUNT == 0 ))
