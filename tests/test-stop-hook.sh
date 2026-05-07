#!/usr/bin/env bash
# tests/test-stop-hook.sh — tests for .zcrew/lib/stop-hook.sh
set -euo pipefail

# ── test harness ─────────────────────────────────────────────────────
pass=0 fail=0
HOOK_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
HOOK="$HOOK_DIR/stop-hook.piper.sh"
MOCK_ZCREW_DIR="$(mktemp -d)"
MOCK_ZCREW="$MOCK_ZCREW_DIR/zcrew"
TRANSCRIPT_DIR="$(mktemp -d)"
PROJECT_DIR="$(mktemp -d)"
SETTINGS_DIR="$(mktemp -d)"

cleanup() { rm -rf "$MOCK_ZCREW_DIR" "$TRANSCRIPT_DIR" "$PROJECT_DIR" "$SETTINGS_DIR"; }
trap cleanup EXIT

# Create mock zcrew that records argv to a file and exits 0
cat > "$MOCK_ZCREW" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/reply-calls.txt"
exit 0
MOCK
chmod +x "$MOCK_ZCREW"

# Create a fake .zcrew project
mkdir -p "$PROJECT_DIR/.zcrew"

# ── helper: make a transcript with given assistant text blocks ───────
# Each arg is a text block string for one assistant message.
# Produces a single-element transcript (one "turn" with N text blocks).
make_transcript() {
  local session_id="${1:-sid-test}"
  shift
  local items=""
  for text in "$@"; do
    escaped="$(jq -Rs . <<<"$text")"
    items+="{\"type\":\"text\",\"text\":$escaped},"
  done
  items="${items%,}"
  printf '{"type":"assistant","message":{"role":"assistant","content":[%s]}}\n' "$items"
}

# ── helper: run hook with given session_id and transcript content ────
run_hook() {
  local session_id="${1:-}"
  local transcript_content="${2:-}"
  local session_file="$TRANSCRIPT_DIR/$session_id.jsonl"
  printf '%s' "$transcript_content" > "$session_file"

  # Build sanitized cwd path matching the hook's logic
  local sanitized="${PROJECT_DIR//\//-}"

  # We need to set HOME to our TRANSCRIPT_DIR parent structure
  # The hook computes: $HOME/.claude/projects/$sanitized/$session_id.jsonl
  local fake_home
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.claude/projects/$sanitized"
  ln -s "$session_file" "$fake_home/.claude/projects/$sanitized/$session_id.jsonl"

  ZCREW_BIN="$MOCK_ZCREW" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
  HOME="$fake_home" \
  bash "$HOOK" <<< "{\"session_id\":\"$session_id\"}" 2>/dev/null || true

  # Return fake_home for cleanup
  REPLY_FAKE_HOME="$fake_home"
}

# ── helper: check recorded zcrew reply calls ────────────────────────
reply_calls() {
  if [[ -f "$MOCK_ZCREW_DIR/reply-calls.txt" ]]; then
    cat "$MOCK_ZCREW_DIR/reply-calls.txt"
  else
    echo ""
  fi
}

reset_calls() {
  rm -f "$MOCK_ZCREW_DIR/reply-calls.txt"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
  fi
}

assert_no_calls() {
  local label="$1"
  if [[ -f "$MOCK_ZCREW_DIR/reply-calls.txt" ]]; then
    fail=$((fail + 1))
    echo "FAIL: $label — expected no zcrew reply calls, got:"
    cat "$MOCK_ZCREW_DIR/reply-calls.txt"
  else
    pass=$((pass + 1))
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# Test 1: Marker on last line → reply fires
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_transcript "sid-1" "Here is my work."$'\n'"<<DONE: hello world>>")"
run_hook "sid-1" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "marker last line fires reply" "reply hello world" "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 2: Marker mid-text but NOT last line → no reply
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_transcript "sid-2" "<<DONE: mid marker>>"$'\n'"This is a follow-up line.")"
run_hook "sid-2" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_no_calls "marker mid-text does not fire reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 3: No marker at all → no reply
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_transcript "sid-3" "Just a normal message with no marker.")"
run_hook "sid-3" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_no_calls "no marker does not fire reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 4: Exact reply content: <<DONE: hello world>>
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_transcript "sid-4" "<<DONE: hello world>>")"
run_hook "sid-4" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "exact reply content" "reply hello world" "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 5: Multi-line payload
# ═══════════════════════════════════════════════════════════════════════
reset_calls
multiline=$'line1\nline2'
transcript="$(make_transcript "sid-5" "<<DONE: ${multiline}>>")"
run_hook "sid-5" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
# The mock records everything after "reply " on one invocation
expected=$'reply line1\nline2'
assert_eq "multi-line payload" "$expected" "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 6: Hook fail-closed: malformed JSON on stdin → exit 0
# ═══════════════════════════════════════════════════════════════════════
reset_calls
# Feed garbage JSON; hook should exit 0 and not crash
ZCREW_BIN="$MOCK_ZCREW" \
CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
bash "$HOOK" <<< "not json at all" 2>/dev/null
rc=$?
assert_eq "malformed json exit 0" "0" "$rc"
assert_no_calls "malformed json no reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 7: Hook fail-closed: missing transcript → exit 0
# ═══════════════════════════════════════════════════════════════════════
reset_calls
# Valid session_id but no transcript file
fake_home2="$(mktemp -d)"
sanitized="${PROJECT_DIR//\//-}"
mkdir -p "$fake_home2/.claude/projects/$sanitized"
# No jsonl file created
ZCREW_BIN="$MOCK_ZCREW" \
CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
HOME="$fake_home2" \
bash "$HOOK" <<< '{"session_id":"sid-missing"}' 2>/dev/null
rc=$?
rm -rf "$fake_home2"
assert_eq "missing transcript exit 0" "0" "$rc"
assert_no_calls "missing transcript no reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 8: Hook fail-closed: jq error → exit 0
# ═══════════════════════════════════════════════════════════════════════
reset_calls
# Create a transcript with invalid JSON to trigger jq parse failure
bad_transcript_dir="$(mktemp -d)"
bad_file="$bad_transcript_dir/bad.jsonl"
printf 'not valid jsonl\n' > "$bad_file"
fake_home3="$(mktemp -d)"
sanitized="${PROJECT_DIR//\//-}"
mkdir -p "$fake_home3/.claude/projects/$sanitized"
ln -s "$bad_file" "$fake_home3/.claude/projects/$sanitized/sid-bad.jsonl"
ZCREW_BIN="$MOCK_ZCREW" \
CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
HOME="$fake_home3" \
bash "$HOOK" <<< '{"session_id":"sid-bad"}' 2>/dev/null
rc=$?
rm -rf "$fake_home3" "$bad_transcript_dir"
assert_eq "jq error exit 0" "0" "$rc"
assert_no_calls "jq error no reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 9: Launcher jq merge idempotency
# ═══════════════════════════════════════════════════════════════════════
# Simulate the jq merge the launcher would do, run it twice, verify same output
settings_file="$SETTINGS_DIR/settings.local.json"
printf '{}\n' > "$settings_file"
stop_hook_cmd='${CLAUDE_PROJECT_DIR}/.zcrew/lib/stop-hook.sh'

# First merge
jq --arg cmd "$stop_hook_cmd" '
  .hooks = (.hooks // {})
  | .hooks.Stop = (.hooks.Stop // [])
  | if ([.hooks.Stop[]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length) > 0 then
      .
    else
      .hooks.Stop += [{"matcher":"*","hooks":[{"type":"command","command":$cmd}]}]
    end
' "$settings_file" > "$settings_file.tmp1"
mv "$settings_file.tmp1" "$settings_file"

first="$(cat "$settings_file")"

# Second merge
jq --arg cmd "$stop_hook_cmd" '
  .hooks = (.hooks // {})
  | .hooks.Stop = (.hooks.Stop // [])
  | if ([.hooks.Stop[]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length) > 0 then
      .
    else
      .hooks.Stop += [{"matcher":"*","hooks":[{"type":"command","command":$cmd}]}]
    end
' "$settings_file" > "$settings_file.tmp2"
mv "$settings_file.tmp2" "$settings_file"

second="$(cat "$settings_file")"
assert_eq "idempotent merge" "$first" "$second"

# Also verify the merge looks correct
hooks_count="$(jq '.hooks.Stop | length' "$settings_file")"
assert_eq "one Stop hook entry" "1" "$hooks_count"
entry_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings_file")"
expected_cmd="\${CLAUDE_PROJECT_DIR}/.zcrew/lib/stop-hook.sh"
assert_eq "correct hook command" "$expected_cmd" "$entry_cmd"

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
