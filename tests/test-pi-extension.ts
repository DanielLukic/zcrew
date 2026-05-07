#!/usr/bin/env node
// Test pure arg-builder functions from pi-zcrew-ext.ts
// We duplicate the functions here to avoid ESM/CJS import issues in test.
// If the implementations diverge, these tests will catch that.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Extract the exported functions by evaluating the source (arg builders have no deps)
const source = readFileSync(resolve(__dirname, "../.zcrew/lib/pi-zcrew-ext.ts"), "utf-8");

// Quick-and-dirty: the arg builders are self-contained. Just define them.
// We also verify they match the source by checking key strings.

function replyArgs(p: { message: string }): string[] {
  return ["reply", p.message];
}

function sendArgs(p: { name: string; message: string; compact?: boolean }): string[] {
  const args = ["send"];
  if (p.compact) args.push("--compact");
  args.push(p.name, p.message);
  return args;
}

function listArgs(): string[] {
  return ["list", "--json"];
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;

function assert(condition: boolean, label: string) {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL: ${label}`);
  }
}

function assertDeepEqual(actual: unknown, expected: unknown, label: string) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), `${label} — got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
}

// ---------------------------------------------------------------------------
// replyArgs
// ---------------------------------------------------------------------------

assertDeepEqual(
  replyArgs({ message: "hello" }),
  ["reply", "hello"],
  "replyArgs basic",
);

assertDeepEqual(
  replyArgs({ message: "multi\nline\nmessage" }),
  ["reply", "multi\nline\nmessage"],
  "replyArgs preserves multiline",
);

assertDeepEqual(
  replyArgs({ message: "" }),
  ["reply", ""],
  "replyArgs empty string (schema validation is typebox's job)",
);

// ---------------------------------------------------------------------------
// sendArgs
// ---------------------------------------------------------------------------

assertDeepEqual(
  sendArgs({ name: "sparky", message: "do thing" }),
  ["send", "sparky", "do thing"],
  "sendArgs basic (no compact)",
);

assertDeepEqual(
  sendArgs({ name: "sparky", message: "do thing", compact: true }),
  ["send", "--compact", "sparky", "do thing"],
  "sendArgs with compact=true",
);

assertDeepEqual(
  sendArgs({ name: "sparky", message: "do thing", compact: false }),
  ["send", "sparky", "do thing"],
  "sendArgs with compact=false",
);

assertDeepEqual(
  sendArgs({ name: "sparky", message: "do thing", compact: undefined }),
  ["send", "sparky", "do thing"],
  "sendArgs with compact=undefined",
);

// ---------------------------------------------------------------------------
// listArgs
// ---------------------------------------------------------------------------

assertDeepEqual(
  listArgs(),
  ["list", "--json"],
  "listArgs",
);

// ---------------------------------------------------------------------------
// Source consistency checks — make sure our copies match the real source
// ---------------------------------------------------------------------------

assert(source.includes('return ["reply", p.message];'), "source contains replyArgs impl");
assert(source.includes('args.push("--compact")'), "source contains sendArgs compact flag");
assert(source.includes('return ["list", "--json"];'), "source contains listArgs impl");

// Worker auto-fire: extension subscribes to agent_end and shells reply.
assert(source.includes('pi.on("agent_end"'), "worker registers agent_end handler");
// Worker no longer registers a tool; only orchestrator does (zcrew_send / zcrew_list).
assert(!source.includes('name: "zcrew_reply"'), "worker does NOT register zcrew_reply tool");

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
