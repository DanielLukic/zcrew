#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ZCREW_BIN = process.env.ZCREW_BIN || path.resolve(__dirname, '../bin/zcrew');
const WS_URL = process.env.ZCREW_CODEX_WS_URL || '';

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
          console.error('[codex-auto-reply] ignoring invalid JSON message');
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
    console.error(`[codex-auto-reply] zcrew reply sent${out ? `: ${out}` : ''}`);
    return true;
  } catch (err) {
    const e = err;
    const out = [e.stdout?.trim(), e.stderr?.trim(), e.message].filter(Boolean).join('\n');
    console.error(`[codex-auto-reply] zcrew reply failed: ${out}`);
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

async function main() {
  if (!WS_URL) throw new Error('missing ZCREW_CODEX_WS_URL');
  if (typeof WebSocket === 'undefined') throw new Error('WebSocket is unavailable in this Node runtime');

  const rpc = new RpcClient(WS_URL);
  const sentTurns = new Set();
  const pendingTurns = new Set();
  const openTurns = new Set();
  let shuttingDown = false;

  const keyFor = (threadId, turnId) => `${threadId}:${turnId}`;

  rpc.onNotify = async (method, params) => {
    try {
      if (method === 'turn/started') {
        const key = keyFor(params.threadId, params.turn.id);
        openTurns.add(key);
        return;
      }

      if (method === 'item/completed') {
        const item = params.item;
        if (item?.type !== 'agentMessage') return;
        const key = keyFor(params.threadId, params.turnId);
        const text = typeof item.text === 'string' ? item.text : '';
        if (text.trim()) {
          if (sentTurns.has(key) || pendingTurns.has(key)) return;
          pendingTurns.add(key);
          const ok = await runZcrewReply(text);
          pendingTurns.delete(key);
          if (ok) sentTurns.add(key);
          return;
        }

        return;
      }

      if (method === 'turn/completed') {
        const key = keyFor(params.threadId, params.turn.id);
        openTurns.delete(key);
        if (sentTurns.has(key)) return;

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
          if (ok) sentTurns.add(key);
        } else {
          console.error(`[codex-auto-reply] no non-empty agentMessage for ${key}`);
        }
      }
    } catch (err) {
      console.error(`[codex-auto-reply] notification handling error: ${err?.message || err}`);
    }
  };

  rpc.onClose = () => {
    if (shuttingDown) return;
    if (openTurns.size > 0) {
      console.error('[codex-auto-reply] websocket disconnected with active turns');
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
  console.error(`[codex-auto-reply] connected to ${WS_URL}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((err) => {
    console.error(`[codex-auto-reply] fatal: ${err?.stack || err}`);
    process.exit(2);
  });
}

export { lastNonEmptyAgentMessageForTurn, RpcClient, runZcrewReply, main };
