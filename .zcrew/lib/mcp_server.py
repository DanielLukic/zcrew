#!/usr/bin/env python3
"""zcrew MCP server — stdio JSON-RPC 2.0.

Tool surface depends on BX_INSIDE at startup:
  worker (BX_INSIDE=1): zcrew_reply
  orchestrator (BX_INSIDE unset): zcrew_send, zcrew_list

All tools shell out to the existing zcrew CLI; this is a thin transport
layer, not a reimplementation. Identity (sender pane) is resolved by
the CLI from ZELLIJ_PANE_ID, which the agent inherits and propagates.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "zcrew", "version": "1"}

WORKER = bool(os.environ.get("BX_INSIDE"))

ZCREW_BIN = os.environ.get("ZCREW_BIN") or str(
    Path(__file__).resolve().parent.parent / "bin" / "zcrew"
)


def run_zcrew(args):
    proc = subprocess.run(
        [ZCREW_BIN, *args],
        capture_output=True,
        text=True,
    )
    text = proc.stdout
    if proc.stderr:
        text = (text + "\n" + proc.stderr).strip()
    return proc.returncode, text or ""


def tool_reply(arguments):
    message = arguments.get("message", "")
    if not isinstance(message, str) or not message:
        return 1, "zcrew_reply: 'message' is required (non-empty string)"
    return run_zcrew(["reply", message])


def tool_send(arguments):
    name = arguments.get("name", "")
    message = arguments.get("message", "")
    compact = bool(arguments.get("compact"))
    if not isinstance(name, str) or not name:
        return 1, "zcrew_send: 'name' is required"
    if not isinstance(message, str) or not message:
        return 1, "zcrew_send: 'message' is required"
    args = ["send"]
    if compact:
        args.append("--compact")
    args.extend([name, message])
    return run_zcrew(args)


def tool_list(arguments):
    return run_zcrew(["list", "--json"])


WORKER_TOOLS = {
    "zcrew_reply": {
        "handler": tool_reply,
        "definition": {
            "name": "zcrew_reply",
            "description": (
                "Send a result, finding, blocker, or question back to main. "
                "Worker-only. Target is always main; sender is resolved from "
                "your pane id."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "message": {"type": "string", "minLength": 1},
                },
                "required": ["message"],
            },
        },
    },
}

ORCHESTRATOR_TOOLS = {
    "zcrew_send": {
        "handler": tool_send,
        "definition": {
            "name": "zcrew_send",
            "description": (
                "Send a message to a registered worker pane by name. "
                "Orchestrator-only. Set compact=true to inject /compact "
                "before delivery (use when starting a new task on an "
                "existing agent)."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "minLength": 1},
                    "message": {"type": "string", "minLength": 1},
                    "compact": {"type": "boolean"},
                },
                "required": ["name", "message"],
            },
        },
    },
    "zcrew_list": {
        "handler": tool_list,
        "definition": {
            "name": "zcrew_list",
            "description": "Return the pane registry as JSON.",
            "inputSchema": {"type": "object", "properties": {}},
        },
    },
}

TOOLS = WORKER_TOOLS if WORKER else ORCHESTRATOR_TOOLS


def jsonrpc_error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def jsonrpc_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def handle(req):
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        return jsonrpc_result(
            req_id,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO,
            },
        )
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return jsonrpc_result(
            req_id,
            {"tools": [t["definition"] for t in TOOLS.values()]},
        )
    if method == "tools/call":
        name = params.get("name", "")
        arguments = params.get("arguments") or {}
        tool = TOOLS.get(name)
        if not tool:
            return jsonrpc_error(req_id, -32601, f"unknown tool: {name}")
        rc, text = tool["handler"](arguments)
        return jsonrpc_result(
            req_id,
            {
                "content": [{"type": "text", "text": text}],
                "isError": rc != 0,
            },
        )
    return jsonrpc_error(req_id, -32601, f"method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stdout.write(
                json.dumps(jsonrpc_error(None, -32700, f"parse error: {e}")) + "\n"
            )
            sys.stdout.flush()
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
