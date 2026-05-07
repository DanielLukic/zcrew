#!/usr/bin/env bash
# tests/test-stop-hook.sh — tests for .zcrew/lib/stop-hook.sh
#
# Contract: hook fires every claude SessionStop. It reads the worker's last
# assistant text (preferring stdin.last_assistant_message, then stdin.transcript_path,
# then HOME-based path) and forwards it verbatim via `zcrew reply <text>`.
# No DONE marker, no parsing of the body — whatever the worker said becomes
# the reply.
set -euo pipefail

# ── test harness ─────────────────────────────────────────────────────
pass=0 fail=0
HOOK_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
HOOK="$HOOK_DIR/.zcrew/lib/stop-hook.sh"
MOCK_ZCREW_DIR="$(mktemp -d)"
MOCK_ZCREW="$MOCK_ZCREW_DIR/zcrew"
TRANSCRIPT_DIR="$(mktemp -d)"
PROJECT_DIR="$(mktemp -d)"
SETTINGS_DIR="$(mktemp -d)"

cleanup() { rm -rf "$MOCK_ZCREW_DIR" "$TRANSCRIPT_DIR" "$PROJECT_DIR" "$SETTINGS_DIR"; }
trap cleanup EXIT

# Mock zcrew: records `$*` to reply-calls.txt and exits 0.
cat > "$MOCK_ZCREW" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/reply-calls.txt"
exit 0
MOCK
chmod +x "$MOCK_ZCREW"

mkdir -p "$PROJECT_DIR/.zcrew"

# Build a single-element JSONL transcript: one assistant message with N text blocks.
make_transcript() {
  local _sid="$1"; shift
  local items=""
  for text in "$@"; do
    escaped="$(jq -Rs . <<<"$text")"
    items+="{\"type\":\"text\",\"text\":$escaped},"
  done
  items="${items%,}"
  printf '{"type":"assistant","message":{"role":"assistant","content":[%s]}}\n' "$items"
}

# Multi-line raw transcript: each arg is one JSONL entry.
make_raw_transcript() { printf '%s\n' "$@"; }

# Run the hook with a session_id pointing at a transcript created on the fly.
run_hook() {
  local session_id="${1:-}"
  local transcript_content="${2:-}"
  local session_file="$TRANSCRIPT_DIR/$session_id.jsonl"
  printf '%s' "$transcript_content" > "$session_file"

  local sanitized="${PROJECT_DIR//\//-}"
  local fake_home
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.claude/projects/$sanitized"
  ln -s "$session_file" "$fake_home/.claude/projects/$sanitized/$session_id.jsonl"

  BX_INSIDE=1 \
  ZCREW_BIN="$MOCK_ZCREW" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
  HOME="$fake_home" \
  bash "$HOOK" <<< "{\"session_id\":\"$session_id\"}" 2>/dev/null || true

  REPLY_FAKE_HOME="$fake_home"
}

# Run the hook with arbitrary stdin JSON (useful for testing the
# last_assistant_message / transcript_path stdin fields directly).
run_hook_raw_input() {
  local input_json="${1:-{}}"
  local fake_home
  fake_home="$(mktemp -d)"

  BX_INSIDE=1 \
  ZCREW_BIN="$MOCK_ZCREW" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
  HOME="$fake_home" \
  bash "$HOOK" <<< "$input_json" 2>/dev/null || true

  REPLY_FAKE_HOME="$fake_home"
}

reply_calls() {
  if [[ -f "$MOCK_ZCREW_DIR/reply-calls.txt" ]]; then
    cat "$MOCK_ZCREW_DIR/reply-calls.txt"
  else
    echo ""
  fi
}

reset_calls() { rm -f "$MOCK_ZCREW_DIR/reply-calls.txt"; }

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
# Test 1: any non-empty assistant text fires reply with that text verbatim.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_transcript "sid-1" "Here is my work.")"
run_hook "sid-1" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "non-empty text fires reply verbatim" "reply Here is my work." "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 2: empty assistant text → no reply.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_transcript "sid-2" "")"
run_hook "sid-2" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_no_calls "empty text does not fire reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 3: multi-line text preserved intact.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
multiline=$'line1\nline2\nline3'
transcript="$(make_transcript "sid-3" "$multiline")"
run_hook "sid-3" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "multi-line text preserved" "reply $multiline" "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 4: last assistant entry is tool_use; hook falls back to most-recent
# text-bearing entry.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
transcript="$(make_raw_transcript \
  "$(jq -cn --arg t 'work complete' '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}')" \
  "$(jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"t1",name:"Bash",input:{cmd:"echo x"}}]}}')" \
)"
run_hook "sid-4" "$transcript"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "tool_use after text falls back to text turn" "reply work complete" "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 5: malformed JSON on stdin → exit 0, no reply.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
ZCREW_BIN="$MOCK_ZCREW" \
BX_INSIDE=1 \
CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
bash "$HOOK" <<< "not json at all" 2>/dev/null
rc=$?
assert_eq "malformed json exit 0" "0" "$rc"
assert_no_calls "malformed json no reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 6: missing transcript → exit 0, no reply.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
fake_home2="$(mktemp -d)"
sanitized="${PROJECT_DIR//\//-}"
mkdir -p "$fake_home2/.claude/projects/$sanitized"
ZCREW_BIN="$MOCK_ZCREW" \
BX_INSIDE=1 \
CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
HOME="$fake_home2" \
bash "$HOOK" <<< '{"session_id":"sid-missing"}' 2>/dev/null
rc=$?
rm -rf "$fake_home2"
assert_eq "missing transcript exit 0" "0" "$rc"
assert_no_calls "missing transcript no reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 7: invalid jsonl in transcript → exit 0, no reply.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
bad_transcript_dir="$(mktemp -d)"
bad_file="$bad_transcript_dir/bad.jsonl"
printf 'not valid jsonl\n' > "$bad_file"
fake_home3="$(mktemp -d)"
sanitized="${PROJECT_DIR//\//-}"
mkdir -p "$fake_home3/.claude/projects/$sanitized"
ln -s "$bad_file" "$fake_home3/.claude/projects/$sanitized/sid-bad.jsonl"
ZCREW_BIN="$MOCK_ZCREW" \
BX_INSIDE=1 \
CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
HOME="$fake_home3" \
bash "$HOOK" <<< '{"session_id":"sid-bad"}' 2>/dev/null
rc=$?
rm -rf "$fake_home3" "$bad_transcript_dir"
assert_eq "jq error exit 0" "0" "$rc"
assert_no_calls "jq error no reply"

# ═══════════════════════════════════════════════════════════════════════
# Test 8: launcher jq merge idempotency (settings.local.json).
# ═══════════════════════════════════════════════════════════════════════
settings_file="$SETTINGS_DIR/settings.local.json"
printf '{}\n' > "$settings_file"
stop_hook_cmd="$PROJECT_DIR/.zcrew/lib/stop-hook.sh"

merge_filter='
  .hooks = (.hooks // {})
  | .hooks.Stop = (.hooks.Stop // [])
  | if ([.hooks.Stop[]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length) > 0 then .
    else .hooks.Stop += [{"matcher":"*","hooks":[{"type":"command","command":$cmd}]}]
    end
'
jq --arg cmd "$stop_hook_cmd" "$merge_filter" "$settings_file" > "$settings_file.tmp1"
mv "$settings_file.tmp1" "$settings_file"
first="$(cat "$settings_file")"
jq --arg cmd "$stop_hook_cmd" "$merge_filter" "$settings_file" > "$settings_file.tmp2"
mv "$settings_file.tmp2" "$settings_file"
second="$(cat "$settings_file")"
assert_eq "idempotent merge" "$first" "$second"
assert_eq "one Stop hook entry" "1" "$(jq '.hooks.Stop | length' "$settings_file")"
assert_eq "correct hook command" "$stop_hook_cmd" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings_file")"

# ═══════════════════════════════════════════════════════════════════════
# Test 9: BX_INSIDE unset → exit 0, no reply (host orchestrator no-op).
# ═══════════════════════════════════════════════════════════════════════
reset_calls
env -u BX_INSIDE \
  ZCREW_BIN="$MOCK_ZCREW" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
  bash "$HOOK" <<< '{"session_id":"sid-host","last_assistant_message":"would-be-reply"}' 2>/dev/null
rc=$?
assert_eq "host mode exits 0" "0" "$rc"
assert_no_calls "host mode does not invoke zcrew"

# ═══════════════════════════════════════════════════════════════════════
# Test 10: stdin.last_assistant_message wins over transcript content.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
noisy_transcript="$(make_transcript "sid-10" "from transcript")"
noisy_file="$TRANSCRIPT_DIR/sid-10-noisy.jsonl"
printf '%s' "$noisy_transcript" > "$noisy_file"
input_json="$(jq -cn \
  --arg sid "sid-10" \
  --arg tp "$noisy_file" \
  --arg msg "from stdin" \
  '{session_id:$sid, transcript_path:$tp, last_assistant_message:$msg}')"
run_hook_raw_input "$input_json"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "stdin last_assistant_message wins" "reply from stdin" "$(reply_calls)"

# ═══════════════════════════════════════════════════════════════════════
# Test 11: stdin.transcript_path used when last_assistant_message missing.
# ═══════════════════════════════════════════════════════════════════════
reset_calls
tp_file="$TRANSCRIPT_DIR/sid-11-transcript.jsonl"
printf '%s' "$(make_transcript "sid-11" "from transcript_path")" > "$tp_file"
input_json="$(jq -cn --arg sid "sid-11" --arg tp "$tp_file" '{session_id:$sid, transcript_path:$tp}')"
run_hook_raw_input "$input_json"
rm -rf "${REPLY_FAKE_HOME:-/tmp/noop}"
assert_eq "transcript_path fallback works" "reply from transcript_path" "$(reply_calls)"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
