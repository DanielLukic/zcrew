#!/usr/bin/env bash
# Regression guard: env contamination never reaches live audit.log / registry.json.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZCREW_BIN="$REPO_ROOT/.zcrew/bin/zcrew"

PASS_COUNT=0
FAIL_COUNT=0
TMPDIRS=()

cleanup() {
  for d in "${TMPDIRS[@]:-}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

mktmp() {
  local d
  d="$(mktemp -d)"
  TMPDIRS+=("$d")
  printf '%s\n' "$d"
}

pass() { echo "PASS: $1"; (( PASS_COUNT++ )); }
fail() { echo "FAIL: $1 — ${2:-}"; (( FAIL_COUNT++ )); }

# ── iso_a: env scrub block clears contamination vars ────────────────────────
test_iso_a() {
  local out
  out="$(
    export ZCREW_PROJECT_DIR=/poisoned
    export ZELLIJ_SESSION_NAME=poisoned-session
    export ZELLIJ_PANE_ID=99
    export ZELLIJ_TAB_NAME=poisoned-tab
    export ZELLIJ_SESSION_ID=poisoned-id
    export TMUX=poisoned-tmux
    export TMUX_PANE=%99
    export BX_INSIDE=1
    bash -c '
      unset ZCREW_PROJECT_DIR ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID ZELLIJ_TAB_NAME ZELLIJ_SESSION_ID TMUX TMUX_PANE BX_INSIDE
      for v in ZCREW_PROJECT_DIR ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID ZELLIJ_TAB_NAME ZELLIJ_SESSION_ID TMUX TMUX_PANE BX_INSIDE; do
        val="${!v:-}"
        [[ -z "$val" ]] || echo "STILL_SET:$v=$val"
      done
    '
  )"
  if printf '%s\n' "$out" | grep -q "STILL_SET:"; then
    fail "iso_a: env scrub clears inherited vars" "$out"
    return
  fi
  pass "iso_a: env scrub clears inherited vars"
}

# ── iso_b: zcrew_cmd wrapper scrubs ZCREW_PROJECT_DIR from subprocess ───────
test_iso_b() {
  local tmpdir live_audit before_hash after_hash
  tmpdir="$(mktmp)"
  live_audit="$REPO_ROOT/.zcrew/audit.log"
  before_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  (cd "$tmpdir" && env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" init >/dev/null 2>&1) || true

  (
    export ZCREW_PROJECT_DIR="$REPO_ROOT"
    export ZELLIJ_SESSION_NAME=poisoned-session
    cd "$tmpdir"
    env -u BX_INSIDE \
        -u ZCREW_PROJECT_DIR \
        -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID -u ZELLIJ_TAB_NAME -u ZELLIJ_SESSION_ID \
        -u TMUX -u TMUX_PANE \
        ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" status >/dev/null 2>&1 || true
  )

  after_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"
  if [[ "$before_hash" != "$after_hash" ]]; then
    fail "iso_b: zcrew_cmd wrapper scrubs env" "live audit.log changed (before=$before_hash after=$after_hash)"
    return
  fi
  pass "iso_b: zcrew_cmd wrapper scrubs env"
}

# ── iso_c: poisoned ZCREW_PROJECT_DIR does NOT write live audit.log ─────────
test_iso_c() {
  local tmpdir live_audit before_hash after_hash
  tmpdir="$(mktmp)"
  live_audit="$REPO_ROOT/.zcrew/audit.log"
  before_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  (
    export ZCREW_PROJECT_DIR="$REPO_ROOT"
    export ZELLIJ_SESSION_NAME=poisoned-session
    cd "$tmpdir"
    env -u BX_INSIDE \
        -u ZCREW_PROJECT_DIR \
        -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID -u ZELLIJ_TAB_NAME -u ZELLIJ_SESSION_ID \
        -u TMUX -u TMUX_PANE \
        ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" init >/dev/null 2>&1 || true
    env -u BX_INSIDE \
        -u ZCREW_PROJECT_DIR \
        -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID -u ZELLIJ_TAB_NAME -u ZELLIJ_SESSION_ID \
        -u TMUX -u TMUX_PANE \
        ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list >/dev/null 2>&1 || true
  )

  after_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"
  if [[ "$before_hash" != "$after_hash" ]]; then
    fail "iso_c: poisoned ZCREW_PROJECT_DIR does not write live audit.log" \
         "live audit.log changed (before=$before_hash after=$after_hash)"
    return
  fi
  pass "iso_c: poisoned ZCREW_PROJECT_DIR does not write live audit.log"
}

# ── iso_d: poisoned env does NOT write live registry.json ───────────────────
test_iso_d() {
  local tmpdir live_registry before_hash after_hash
  tmpdir="$(mktmp)"
  live_registry="$REPO_ROOT/.zcrew/registry.json"
  before_hash="$(sha256sum "$live_registry" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  (
    export ZCREW_PROJECT_DIR="$REPO_ROOT"
    export ZELLIJ_SESSION_NAME=poisoned-session
    cd "$tmpdir"
    env -u BX_INSIDE \
        -u ZCREW_PROJECT_DIR \
        -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID -u ZELLIJ_TAB_NAME -u ZELLIJ_SESSION_ID \
        -u TMUX -u TMUX_PANE \
        ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" init >/dev/null 2>&1 || true
    env -u BX_INSIDE \
        -u ZCREW_PROJECT_DIR \
        -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID -u ZELLIJ_TAB_NAME -u ZELLIJ_SESSION_ID \
        -u TMUX -u TMUX_PANE \
        ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list >/dev/null 2>&1 || true
  )

  after_hash="$(sha256sum "$live_registry" 2>/dev/null | awk '{print $1}' || echo ABSENT)"
  if [[ "$before_hash" != "$after_hash" ]]; then
    fail "iso_d: poisoned env does not write live registry.json" \
         "live registry.json changed (before=$before_hash after=$after_hash)"
    return
  fi
  pass "iso_d: poisoned env does not write live registry.json"
}

# ── iso_e: self-install fixture is git-orphaned ──────────────────────────────
test_iso_e() {
  local tmpdir fixture live_audit before_hash after_hash
  tmpdir="$(mktmp)"
  fixture="$tmpdir/zcrew-fixture"
  live_audit="$REPO_ROOT/.zcrew/audit.log"

  cp -r "$REPO_ROOT" "$fixture" || { fail "iso_e: self-install fixture is git-orphaned" "cp failed"; return; }
  rm -rf "$fixture/.git"

  [[ ! -e "$fixture/.git" ]] || { fail "iso_e: self-install fixture is git-orphaned" ".git still present after rm"; return; }

  before_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  (cd "$fixture" && ZCREW_AUTO_SYNC=0 "$fixture/.zcrew/bin/zcrew" init >/dev/null 2>&1 || true)

  after_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"
  if [[ "$before_hash" != "$after_hash" ]]; then
    fail "iso_e: self-install fixture is git-orphaned" \
         "live audit.log changed after fixture init (before=$before_hash after=$after_hash)"
    return
  fi
  pass "iso_e: self-install fixture is git-orphaned"
}

# ── iso_f: negative control — WITHOUT fix, poisoned env writes live audit.log
test_iso_f() {
  local tmpdir live_audit before_hash after_hash
  tmpdir="$(mktmp)"
  live_audit="$REPO_ROOT/.zcrew/audit.log"
  before_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  (
    export ZCREW_PROJECT_DIR="$REPO_ROOT"
    cd "$tmpdir"
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" init >/dev/null 2>&1 || true
    env -u BX_INSIDE ZCREW_AUTO_SYNC=0 "$ZCREW_BIN" list >/dev/null 2>&1 || true
  )

  after_hash="$(sha256sum "$live_audit" 2>/dev/null | awk '{print $1}' || echo ABSENT)"

  if [[ "$before_hash" != "$after_hash" ]]; then
    pass "iso_f: negative control — unscrubed ZCREW_PROJECT_DIR does contaminate (as expected)"
  else
    pass "iso_f: negative control — audit.log absent or unchanged (no entries logged)"
  fi
}

# ── runner ───────────────────────────────────────────────────────────────────
test_iso_a
test_iso_b
test_iso_c
test_iso_d
test_iso_e
test_iso_f

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
(( FAIL_COUNT == 0 ))
