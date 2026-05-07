#!/usr/bin/env bash
# Tests for .zcrew/lib/mcp_server.py (stdio JSON-RPC).
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_SERVER="$ROOT_DIR/.zcrew/lib/mcp_server.py"

PASS=0
FAIL=0

run_test() {
    local name="$1"; shift
    if "$@"; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# Send a sequence of JSON-RPC lines to the server and return the last
# response on stdout. Caller passes the messages as args.
mcp_call() {
    local mode="$1"; shift   # "worker" or "host"
    local input
    input="$(printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}' "$@")"
    if [[ "$mode" == "worker" ]]; then
        BX_INSIDE=1 ZCREW_BIN="$FAKE_ZCREW" python3 "$MCP_SERVER" <<<"$input" 2>/dev/null | tail -1
    else
        env -u BX_INSIDE ZCREW_BIN="$FAKE_ZCREW" python3 "$MCP_SERVER" <<<"$input" 2>/dev/null | tail -1
    fi
}

# Fake zcrew that records its argv to a file and prints back the args.
new_fake_zcrew() {
    local d
    d="$(mktemp -d)"
    FAKE_ZCREW_LOG="$d/argv.log"
    FAKE_ZCREW="$d/zcrew"
    cat > "$FAKE_ZCREW" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$FAKE_ZCREW_LOG"
echo "fake-zcrew called: \$*"
exit 0
EOF
    chmod +x "$FAKE_ZCREW"
}

test_1_initialize_handshake() {
    new_fake_zcrew
    local out
    out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        | env -u BX_INSIDE ZCREW_BIN="$FAKE_ZCREW" python3 "$MCP_SERVER" 2>/dev/null \
        | jq -r '.result.serverInfo.name')"
    [[ "$out" == "zcrew" ]]
}

test_2_tools_list_orchestrator() {
    new_fake_zcrew
    local out
    out="$(mcp_call host '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
        | jq -r '.result.tools | map(.name) | sort | join(",")')"
    [[ "$out" == "zcrew_list,zcrew_send" ]]
}

test_3_tools_list_worker() {
    new_fake_zcrew
    local out
    out="$(mcp_call worker '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
        | jq -r '.result.tools | map(.name) | join(",")')"
    [[ "$out" == "zcrew_reply" ]]
}

test_4_worker_cannot_call_send() {
    new_fake_zcrew
    local out
    out="$(mcp_call worker '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_send","arguments":{"name":"x","message":"y"}}}' \
        | jq -r '.error.code')"
    [[ "$out" == "-32601" ]]
}

test_5_orchestrator_cannot_call_reply() {
    new_fake_zcrew
    local out
    out="$(mcp_call host '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_reply","arguments":{"message":"x"}}}' \
        | jq -r '.error.code')"
    [[ "$out" == "-32601" ]]
}

test_6_send_shells_out_with_args() {
    new_fake_zcrew
    mcp_call host '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_send","arguments":{"name":"piper","message":"do thing"}}}' >/dev/null
    local logged
    logged="$(tr '\n' ' ' <"$FAKE_ZCREW_LOG")"
    [[ "$logged" == "send piper do thing " ]]
}

test_7_send_compact_passes_flag() {
    new_fake_zcrew
    mcp_call host '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_send","arguments":{"name":"piper","message":"x","compact":true}}}' >/dev/null
    local logged
    logged="$(tr '\n' ' ' <"$FAKE_ZCREW_LOG")"
    [[ "$logged" == "send --compact piper x " ]]
}

test_8_reply_shells_out_to_reply() {
    new_fake_zcrew
    mcp_call worker '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_reply","arguments":{"message":"done"}}}' >/dev/null
    local logged
    logged="$(tr '\n' ' ' <"$FAKE_ZCREW_LOG")"
    [[ "$logged" == "reply done " ]]
}

test_9_list_shells_out_with_json_flag() {
    new_fake_zcrew
    mcp_call host '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_list","arguments":{}}}' >/dev/null
    local logged
    logged="$(tr '\n' ' ' <"$FAKE_ZCREW_LOG")"
    [[ "$logged" == "list --json " ]]
}

test_10_send_missing_name_fails_without_shelling() {
    new_fake_zcrew
    local resp
    resp="$(mcp_call host '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_send","arguments":{"message":"x"}}}')"
    [[ "$(jq -r '.result.isError' <<<"$resp")" == "true" ]] || return 1
    [[ ! -e "$FAKE_ZCREW_LOG" ]]
}

test_11_reply_empty_message_fails() {
    new_fake_zcrew
    local err
    err="$(mcp_call worker '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_reply","arguments":{"message":""}}}' \
        | jq -r '.result.isError')"
    [[ "$err" == "true" ]]
}

test_12_multiline_message_passes_through_intact() {
    new_fake_zcrew
    mcp_call worker '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zcrew_reply","arguments":{"message":"line1\nline2\nline3"}}}' >/dev/null
    # Fake zcrew uses printf '%s\n' "$@" so two args ('reply', body) span 4 lines.
    [[ "$(head -1 "$FAKE_ZCREW_LOG")" == "reply" ]] || return 1
    [[ "$(tail -1 "$FAKE_ZCREW_LOG")" == "line3" ]] || return 1
    [[ "$(wc -l <"$FAKE_ZCREW_LOG")" -eq 4 ]]
}

test_13_unknown_method_returns_error() {
    new_fake_zcrew
    local code
    code="$(mcp_call host '{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}' \
        | jq -r '.error.code')"
    [[ "$code" == "-32601" ]]
}

test_14_invalid_json_returns_parse_error() {
    new_fake_zcrew
    local code
    code="$(printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{not-json' \
        | env -u BX_INSIDE ZCREW_BIN="$FAKE_ZCREW" python3 "$MCP_SERVER" 2>/dev/null \
        | tail -1 | jq -r '.error.code')"
    [[ "$code" == "-32700" ]]
}

main() {
    [[ -x "$MCP_SERVER" ]] || { echo "FAIL: $MCP_SERVER missing or not executable"; exit 1; }

    run_test "1) initialize handshake returns server info" test_1_initialize_handshake
    run_test "2) orchestrator tools/list = zcrew_send + zcrew_list" test_2_tools_list_orchestrator
    run_test "3) worker tools/list = zcrew_reply only" test_3_tools_list_worker
    run_test "4) worker calling zcrew_send rejected (unknown tool)" test_4_worker_cannot_call_send
    run_test "5) orchestrator calling zcrew_reply rejected (unknown tool)" test_5_orchestrator_cannot_call_reply
    run_test "6) zcrew_send shells out with positional name + message" test_6_send_shells_out_with_args
    run_test "7) zcrew_send compact=true injects --compact flag" test_7_send_compact_passes_flag
    run_test "8) zcrew_reply shells out to 'reply <msg>'" test_8_reply_shells_out_to_reply
    run_test "9) zcrew_list shells out to 'list --json'" test_9_list_shells_out_with_json_flag
    run_test "10) zcrew_send missing name fails before shell-out" test_10_send_missing_name_fails_without_shelling
    run_test "11) zcrew_reply empty message returns isError=true" test_11_reply_empty_message_fails
    run_test "12) multi-line message passes through intact" test_12_multiline_message_passes_through_intact
    run_test "13) unknown jsonrpc method returns -32601" test_13_unknown_method_returns_error
    run_test "14) invalid json returns -32700 parse error" test_14_invalid_json_returns_parse_error

    echo "Total: $PASS PASS, $FAIL FAIL"
    [[ $FAIL -eq 0 ]]
}

main "$@"
