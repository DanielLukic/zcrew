#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';

const execFileAsync = promisify(execFile);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ZCREW_BIN = process.env.ZCREW_BIN || path.resolve(__dirname, '../bin/zcrew');
const WS_URL = process.env.ZCREW_CODEX_WS_URL || '';
const STATE_DIR = process.env.ZCREW_CODEX_STATE_DIR || '';
const REPLIED_FILE = STATE_DIR ? path.join(STATE_DIR, 'replied.json') : '';

function log(message) {
  console.error(`[codex-auto-reply] ${message}`);
}

class RpcClient {
  constructor(url) {
    this.url = url;
    this.ws = null;
    this.nextId = 1;
    this.pending = new Map();
    this.onNotify = null;
    this.onClose = null;
  }

  async connect() {
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;

      ws.addEventListener('open', () => resolve(), { once: true });
      ws.addEventListener('error', (ev) => reject(ev.error || new Error('websocket connect error')), { once: true });

      ws.addEventListener('message', (ev) => {
        let msg;
        try {
          msg = JSON.parse(String(ev.data));
        } catch {
          log('ignoring invalid JSON message');
          return;
        }
        if (Object.prototype.hasOwnProperty.call(msg, 'id')) {
          const p = this.pending.get(msg.id);
          if (!p) return;
          this.pending.delete(msg.id);
          if (Object.prototype.hasOwnProperty.call(msg, 'error')) {
            p.reject(new Error(msg.error?.message || JSON.stringify(msg.error)));
          } else {
            p.resolve(msg.result);
          }
          return;
        }
        if (msg.method && this.onNotify) this.onNotify(msg.method, msg.params || {});
      });

      ws.addEventListener('close', (ev) => {
        for (const [, p] of this.pending) p.reject(new Error('websocket closed'));
        this.pending.clear();
        if (this.onClose) this.onClose(ev);
      });
    });
  }

  request(method, params = {}) {
    const id = this.nextId++;
    const payload = { jsonrpc: '2.0', id, method, params };
    this.ws.send(JSON.stringify(payload));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  notify(method, params = {}) {
    this.ws.send(JSON.stringify({ jsonrpc: '2.0', method, params }));
  }

  close() {
    this.ws?.close();
  }
}

async function runZcrewReply(text) {
  const msg = text.trim();
  if (!msg) return false;
  try {
    const { stdout, stderr } = await execFileAsync(ZCREW_BIN, ['reply', msg]);
    const out = [stdout?.trim(), stderr?.trim()].filter(Boolean).join('\n');
    log(`zcrew reply sent${out ? `: ${out}` : ''}`);
    return true;
  } catch (err) {
    const e = err;
    const out = [e.stdout?.trim(), e.stderr?.trim(), e.message].filter(Boolean).join('\n');
    log(`zcrew reply failed: ${out}`);
    return false;
  }
}

function lastNonEmptyAgentMessageForTurn(threadReadResult, turnId) {
  const turns = threadReadResult?.thread?.turns || [];
  const turn = turns.find((t) => t.id === turnId);
  if (!turn) return '';
  const items = turn.items || [];
  for (let i = items.length - 1; i >= 0; i -= 1) {
    const item = items[i];
    if (item?.type !== 'agentMessage') continue;
    if (typeof item.text !== 'string') continue;
    const text = item.text.trim();
    if (text) return item.text;
  }
  return '';
}

function loadedThreadIds(result) {
  if (Array.isArray(result?.data)) return result.data;
  if (Array.isArray(result?.threadIds)) return result.threadIds;
  if (Array.isArray(result?.threads)) {
    return result.threads.map((thread) => thread?.id).filter(Boolean);
  }
  return [];
}

function lastCompletedTurn(threadReadResult) {
  const turns = threadReadResult?.thread?.turns || [];
  for (let i = turns.length - 1; i >= 0; i -= 1) {
    const turn = turns[i];
    if (!turn?.id) continue;
    if (turn.status?.type === 'completed' || turn.completedAt) return turn;
  }
  return turns.at(-1) || null;
}

function loadRepliedKeys() {
  if (!REPLIED_FILE) return new Set();
  try {
    const data = fs.readFileSync(REPLIED_FILE, 'utf8').trim();
    if (!data) return new Set();
    const arr = JSON.parse(data);
    if (!Array.isArray(arr)) return new Set();
    return new Set(arr.filter((k) => typeof k === 'string'));
  } catch (e) {
    if (e.code !== 'ENOENT') log(`warn: failed to read replied.json: ${e.message}`);
    return new Set();
  }
}

function saveRepliedKeys(sentTurns) {
  if (!REPLIED_FILE) return;
  try {
    const tmp = REPLIED_FILE + '.tmp.' + process.pid + '.' + Date.now();
    const data = JSON.stringify([...sentTurns], null, 2);
    fs.writeFileSync(tmp, data);
    fs.renameSync(tmp, REPLIED_FILE);
  } catch (e) {
    log(`warn: failed to save replied.json: ${e.message}`);
  }
}

async function main() {
  if (!WS_URL) throw new Error('missing ZCREW_CODEX_WS_URL');
  if (typeof WebSocket === 'undefined') throw new Error('WebSocket is unavailable in this Node runtime');

  const rpc = new RpcClient(WS_URL);
  const sentTurns = loadRepliedKeys();
  const pendingTurns = new Set();
  const openTurns = new Set();
  const subscribedThreads = new Set();
  const resumingThreads = new Map();
  let shuttingDown = false;

  const keyFor = (threadId, turnId) => `${threadId}:${turnId}`;

  const resumeThread = async (threadId) => {
    if (!threadId || subscribedThreads.has(threadId)) return;
    const inFlight = resumingThreads.get(threadId);
    if (inFlight) return inFlight;

    const promise = rpc
      .request('thread/resume', { threadId, excludeTurns: true })
      .then(() => {
        subscribedThreads.add(threadId);
        return true;
      })
      .catch((err) => {
        log(`thread/resume failed for ${threadId}: ${err}`);
        return false;
      })
      .finally(() => {
        resumingThreads.delete(threadId);
      });

    resumingThreads.set(threadId, promise);
    return promise;
  };

  rpc.onNotify = async (method, params) => {
    try {
      if (method === 'turn/started') {
        const key = keyFor(params.threadId, params.turn.id);
        openTurns.add(key);
        return;
      }

      if (method === 'thread/status/changed') {
        if (params.status?.type !== 'idle') return;
        const threadId = params.threadId || params.thread?.id;
        if (!threadId || subscribedThreads.has(threadId)) return;

        const resumed = await resumeThread(threadId);
        if (!resumed) return;

        const read = await rpc.request('thread/read', {
          threadId,
          includeTurns: true,
        });
        const turn = lastCompletedTurn(read);
        if (!turn?.id) return;

        const key = keyFor(threadId, turn.id);
        if (sentTurns.has(key) || pendingTurns.has(key)) return;

        const fallback = lastNonEmptyAgentMessageForTurn(read, turn.id);
        if (!fallback.trim()) {
          log(`no non-empty agentMessage for ${key}`);
          return;
        }

        pendingTurns.add(key);
        const ok = await runZcrewReply(fallback);
        pendingTurns.delete(key);
        if (ok) { sentTurns.add(key); saveRepliedKeys(sentTurns); }
        return;
      }

      if (method === 'item/completed') {
        // Track open turns for disconnect detection, but do NOT send reply here.
        // turn/completed handles the actual reply using lastNonEmptyAgentMessageForTurn,
        // which correctly picks the last (final) agentMessage instead of the first.
        return;
      }

      if (method === 'turn/completed') {
        const key = keyFor(params.threadId, params.turn.id);
        openTurns.delete(key);
        if (sentTurns.has(key) || pendingTurns.has(key)) return;

        const read = await rpc.request('thread/read', {
          threadId: params.threadId,
          includeTurns: true,
        });
        const fallback = lastNonEmptyAgentMessageForTurn(read, params.turn.id);
        if (fallback.trim()) {
          if (pendingTurns.has(key)) return;
          pendingTurns.add(key);
          const ok = await runZcrewReply(fallback);
          pendingTurns.delete(key);
          if (ok) { sentTurns.add(key); saveRepliedKeys(sentTurns); }
          log(`no non-empty agentMessage for ${key}`);
        }
      }
    } catch (err) {
      log(`notification handling error: ${err?.message || err}`);
    }
  };

  rpc.onClose = () => {
    if (shuttingDown) return;
    if (openTurns.size > 0) {
      log('websocket disconnected with active turns');
      process.exitCode = 3;
    }
    process.exit();
  };

  process.on('SIGINT', () => {
    shuttingDown = true;
    rpc.close();
    process.exit(0);
  });
  process.on('SIGTERM', () => {
    shuttingDown = true;
    rpc.close();
    process.exit(0);
  });

  await rpc.connect();
  await rpc.request('initialize', {
    clientInfo: { name: 'zcrew-codex-auto-reply', title: 'zcrew-codex-auto-reply', version: '0.1.0' },
    capabilities: null,
  });
  rpc.notify('initialized', {});

  try {
    const loaded = await rpc.request('thread/loaded/list', {});
    for (const threadId of loadedThreadIds(loaded)) {
      await resumeThread(threadId);
    }
  } catch (err) {
    log(`thread/loaded/list sweep failed: ${err}`);
  }

  log(`connected to ${WS_URL}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((err) => {
    log(`fatal: ${err?.stack || err}`);
    process.exit(2);
  });
}

export { lastNonEmptyAgentMessageForTurn, loadedThreadIds, RpcClient, runZcrewReply, main };
