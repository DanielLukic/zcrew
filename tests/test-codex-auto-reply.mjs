#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const CASE_RUNNER = '/home/dl/Projects/zcrew/tests/helpers/codex-auto-reply-case.mjs';
const ADAPTER = process.env.ADAPTER_PATH || '/home/dl/Projects/zcrew/.zcrew/lib/codex-auto-reply.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readCalls(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
}

function readRpcCalls(file) {
  return readCalls(file).map((line) => JSON.parse(line));
}

async function runCase({ caseName, expectedCalls, expectedExit, expectedRpcMethods = [], settleMs = 200 }) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-auto-reply-case-'));
  const callsFile = path.join(tmp, 'calls.txt');
  const rpcCallsFile = path.join(tmp, 'rpc-calls.txt');
  const zcrewBin = path.join(tmp, 'zcrew');
  fs.writeFileSync(zcrewBin, `#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"${callsFile}\"\n`, { mode: 0o755 });

  const child = spawn(process.execPath, [CASE_RUNNER], {
    env: {
      ...process.env,
      CASE_NAME: caseName,
      CALLS_FILE: callsFile,
      RPC_CALLS_FILE: rpcCallsFile,
      ADAPTER_PATH: ADAPTER,
      ZCREW_BIN: zcrewBin,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => (stdout += String(d)));
  child.stderr.on('data', (d) => (stderr += String(d)));

  let exitCode = null;
  child.on('exit', (code) => {
    exitCode = code;
  });

  if (expectedExit === 3) {
    const deadline = Date.now() + 2000;
    while (exitCode === null && Date.now() < deadline) await sleep(20);
    assert.equal(exitCode, 3, `${caseName}: expected exit 3\nstdout=${stdout}\nstderr=${stderr}`);
    assert.deepEqual(readCalls(callsFile), expectedCalls, `${caseName}: calls mismatch\nstdout=${stdout}\nstderr=${stderr}`);
    assert.deepEqual(readRpcCalls(rpcCallsFile).map((entry) => entry.method), expectedRpcMethods, `${caseName}: rpc mismatch\nstdout=${stdout}\nstderr=${stderr}`);
  } else {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const calls = readCalls(callsFile);
      if (expectedCalls.length > 0 && calls.length >= expectedCalls.length) break;
      await sleep(20);
    }

    await sleep(settleMs);
    child.kill('SIGTERM');
    const killDeadline = Date.now() + 1000;
    while (exitCode === null && Date.now() < killDeadline) await sleep(10);

    assert.equal(exitCode, 0, `${caseName}: expected exit 0 after SIGTERM\nstdout=${stdout}\nstderr=${stderr}`);
    assert.deepEqual(readCalls(callsFile), expectedCalls, `${caseName}: calls mismatch\nstdout=${stdout}\nstderr=${stderr}`);
    assert.deepEqual(readRpcCalls(rpcCallsFile).map((entry) => entry.method), expectedRpcMethods, `${caseName}: rpc mismatch\nstdout=${stdout}\nstderr=${stderr}`);
  }

  fs.rmSync(tmp, { recursive: true, force: true });
}

await runCase({ caseName: 'one', expectedCalls: ['reply hello'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'multi', expectedCalls: ['reply second'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'live_after_idle', expectedCalls: ['reply first idle reply', 'reply live second turn'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read', 'thread/read'] });
await runCase({ caseName: 'tool_only', expectedCalls: [], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'fallback_text', expectedCalls: ['reply fallback text'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'fallback_empty', expectedCalls: [], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'disconnect', expectedCalls: [], expectedExit: 3, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'loaded_sweep', expectedCalls: ['reply swept hello'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCase({ caseName: 'multi_item_turn_completed', expectedCalls: ['reply detailed final answer'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });

console.log('ok');
