#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const WT = path.resolve(import.meta.dirname, '..');
const CASE_RUNNER = path.join(WT, 'tests/helpers/codex-auto-reply-case.mjs');
const ADAPTER = process.env.ADAPTER_PATH || path.join(WT, '.zcrew/lib/codex-auto-reply.mjs');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readCalls(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
}

function readRpcCalls(file) {
  return readCalls(file).map((line) => JSON.parse(line));
}

async function runCase({ caseName, expectedCalls, expectedExit, expectedRpcMethods = [], settleMs = 200, seedRepliedKeys = [], zcrewFail = false }) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-auto-reply-case-'));
  const callsFile = path.join(tmp, 'calls.txt');
  const rpcCallsFile = path.join(tmp, 'rpc-calls.txt');
  const zcrewBin = path.join(tmp, 'zcrew');
  const failLine = zcrewFail ? 'exit 1\n' : '';
  fs.writeFileSync(zcrewBin, `#!/usr/bin/env bash\n[[ "$1" == "log-error" ]] || printf '%s\n' "$*" >> "${callsFile}"\n${failLine}`, { mode: 0o755 });

  const stateDir = path.join(tmp, 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  if (seedRepliedKeys.length > 0) {
    fs.writeFileSync(path.join(stateDir, 'replied.json'), JSON.stringify(seedRepliedKeys));
  }

  const child = spawn(process.execPath, [CASE_RUNNER], {
    env: {
      ...process.env,
      CASE_NAME: caseName,
      CALLS_FILE: callsFile,
      RPC_CALLS_FILE: rpcCallsFile,
      ADAPTER_PATH: ADAPTER,
      ZCREW_BIN: zcrewBin,
      ZCREW_CODEX_STATE_DIR: stateDir,
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

  return { tmp, stateDir };
}

async function runCaseClean(opts) {
  const { tmp } = await runCase(opts);
  fs.rmSync(tmp, { recursive: true, force: true });
}

await runCaseClean({ caseName: 'one', expectedCalls: ['reply hello'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'multi', expectedCalls: ['reply second'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'live_after_idle', expectedCalls: ['reply first idle reply', 'reply live second turn'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read', 'thread/read'] });
await runCaseClean({ caseName: 'tool_only', expectedCalls: [], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'fallback_text', expectedCalls: ['reply fallback text'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'fallback_empty', expectedCalls: [], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'disconnect', expectedCalls: [], expectedExit: 3, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'loaded_sweep', expectedCalls: ['reply swept hello'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });
await runCaseClean({ caseName: 'multi_item_turn_completed', expectedCalls: ['reply detailed final answer'], expectedExit: 0, expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'] });

// #15: seeded replied.json suppresses resend on restart
{
  const { tmp } = await runCase({
    caseName: 'replied_persist_dedupe',
    expectedCalls: [],
    expectedExit: 0,
    seedRepliedKeys: ['th1:tu1'],
    expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'],
  });
  fs.rmSync(tmp, { recursive: true, force: true });
}

// #15: replied.json grows after successful send
{
  const { tmp, stateDir } = await runCase({
    caseName: 'replied_persist_write',
    expectedCalls: ['reply fresh reply'],
    expectedExit: 0,
    expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read'],
  });
  const repliedFile = path.join(stateDir, 'replied.json');
  assert.ok(fs.existsSync(repliedFile), 'replied.json should exist after send');
  const keys = JSON.parse(fs.readFileSync(repliedFile, 'utf8'));
  assert.ok(keys.includes('th1:tu1'), `replied.json should contain th1:tu1, got ${JSON.stringify(keys)}`);
  const initCall = readRpcCalls(path.join(tmp, 'rpc-calls.txt')).find((entry) => entry.method === 'initialize');
  assert.deepEqual(
    initCall?.params?.capabilities,
    undefined,
    `initialize should not include capabilities, got ${JSON.stringify(initCall?.params?.capabilities)}`,
  );
  fs.rmSync(tmp, { recursive: true, force: true });
}

// reply failure triggers turn/start steer message
{
  const { tmp, stateDir } = await runCase({
    caseName: 'reply_failure_triggers_turn_start',
    expectedCalls: ['reply fail me'],
    expectedExit: 0,
    zcrewFail: true,
    expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read', 'turn/start'],
  });
  const rpcCalls = readRpcCalls(path.join(tmp, 'rpc-calls.txt'));
  const turnStart = rpcCalls.find((c) => c.method === 'turn/start');
  assert.ok(turnStart, 'turn/start should be called on reply failure');
  assert.equal(turnStart.params.threadId, 'th1', 'turn/start should target th1');
  assert.ok(
    turnStart.params.input?.[0]?.text?.includes('ADAPTER ERROR'),
    `turn/start text should contain ADAPTER ERROR, got ${JSON.stringify(turnStart.params.input)}`,
  );
  const repliedFile = path.join(stateDir, 'replied.json');
  assert.ok(!fs.existsSync(repliedFile), 'replied.json should NOT be written on failed reply');
  fs.rmSync(tmp, { recursive: true, force: true });
}

// reply failure loop guard: steer-triggered turn does NOT trigger another notify
{
  const { tmp, stateDir } = await runCase({
    caseName: 'reply_failure_loop_guard',
    expectedCalls: ['reply fail me'],
    expectedExit: 0,
    zcrewFail: true,
    settleMs: 300,
    expectedRpcMethods: ['initialize', 'initialized', 'thread/loaded/list', 'thread/resume', 'thread/read', 'turn/start'],
  });
  const rpcCalls = readRpcCalls(path.join(tmp, 'rpc-calls.txt'));
  const turnStarts = rpcCalls.filter((c) => c.method === 'turn/start');
  assert.equal(turnStarts.length, 1, `expected exactly 1 turn/start, got ${turnStarts.length}`);
  const threadReads = rpcCalls.filter((c) => c.method === 'thread/read');
  assert.equal(threadReads.length, 1, `expected exactly 1 thread/read, got ${threadReads.length}`);
  const repliedFile = path.join(stateDir, 'replied.json');
  assert.ok(!fs.existsSync(repliedFile), 'replied.json should NOT be written on failed reply');
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log('ok');
