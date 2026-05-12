#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ADAPTER = process.env.ADAPTER_PATH || path.resolve(__dirname, '..', '..', '.zcrew/lib/codex-auto-reply.mjs');
const caseName = process.env.CASE_NAME;
const callsFile = process.env.CALLS_FILE;
const rpcCallsFile = process.env.RPC_CALLS_FILE;
const debug = process.env.DEBUG_CASE === '1';
if (!caseName || !callsFile || !rpcCallsFile) throw new Error('CASE_NAME, CALLS_FILE and RPC_CALLS_FILE required');

function recordRpcCall(method, params) {
  fs.appendFileSync(rpcCallsFile, `${JSON.stringify({ method, params })}\n`);
}

class FakeSocket {
  constructor(server) {
    this.server = server;
    this.listeners = new Map();
    setImmediate(() => this.emit('open', {}));
  }
  addEventListener(name, fn, opts) {
    const arr = this.listeners.get(name) || [];
    arr.push({ fn, once: !!opts?.once });
    this.listeners.set(name, arr);
  }
  send(raw) {
    if (debug) process.stderr.write(`[fakews] client->server ${raw}\n`);
    this.server.onClientMessage(this, JSON.parse(raw));
  }
  close() {
    this.emit('close', { code: 1000 });
  }
  serverSend(msg) {
    if (debug) process.stderr.write(`[fakews] server->client ${JSON.stringify(msg)}\n`);
    this.emit('message', { data: JSON.stringify(msg) });
  }
  emit(name, ev) {
    const arr = this.listeners.get(name) || [];
    const keep = [];
    for (const l of arr) {
      l.fn(ev);
      if (!l.once) keep.push(l);
    }
    this.listeners.set(name, keep);
  }
}

const scripts = {
  one: {
    threadStarted: 'th1',
    idleThread: 'th1',
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'hello' }] }] },
    }),
  },
  multi: {
    threadStarted: 'th1',
    idleThread: 'th1',
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'first' }, { type: 'agentMessage', text: 'second' }] }] },
    }),
  },
  live_after_idle: {
    threadStarted: 'th1',
    idleThread: 'th1',
    readCount: 0,
    onThreadRead() {
      this.readCount += 1;
      if (this.readCount === 1) {
        return {
          thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'first idle reply' }] }] },
        };
      }
      return {
        thread: {
          turns: [
            { id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'first idle reply' }] },
            { id: 'tu2', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'live second turn' }] },
          ],
        },
      };
    },
    afterFirstResume: (sock) => {
      setTimeout(() => {
        sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu2' } } });
        sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu2', item: { type: 'agentMessage', text: 'live second turn' } } });
        sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu2' } } });
      }, 20);
    },
  },
  tool_only: {
    threadStarted: 'th1',
    idleThread: 'th1',
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'toolCall', text: 'x' }] }] },
    }),
  },
  fallback_text: {
    threadStarted: 'th1',
    idleThread: 'th1',
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'fallback text' }] }] },
    }),
  },
  fallback_empty: {
    threadStarted: 'th1',
    idleThread: 'th1',
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: '  ' }] }] },
    }),
  },
  disconnect: {
    threadStarted: 'th1',
    idleThread: 'th1',
    closeAfterIdle: true,
    afterFirstResume: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      setTimeout(() => sock.close(), 10);
    },
  },
  loaded_sweep: {
    loadedThreads: ['th1'],
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'swept hello' }] }] },
    }),
    afterFirstResume: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: 'swept hello' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
  },
  multi_item_turn_completed: {
    loadedThreads: ['th1'],
    onThreadRead: () => ({
      thread: {
        turns: [
          {
            id: 'tu1',
            status: { type: 'completed' },
            items: [
              { type: 'agentMessage', text: 'short ack' },
              { type: 'agentMessage', text: 'detailed final answer' },
            ],
          },
        ],
      },
    }),
    afterFirstResume: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: 'short ack' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: 'detailed final answer' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
  },
  replied_persist_dedupe: {
    idleThread: 'th1',
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'already replied' }] }] },
    }),
  },
  replied_persist_write: {
    loadedThreads: ['th1'],
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', status: { type: 'completed' }, items: [{ type: 'agentMessage', text: 'fresh reply' }] }] },
    }),
    afterFirstResume: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
  },
};

const script = scripts[caseName];
if (!script) throw new Error(`unknown case: ${caseName}`);

class FakeWsServer {
  constructor() {
    this.resumed = new Set();
    this.idleSent = new Set();
    this.capabilities = null;
  }

  onClientMessage(sock, msg) {
    if (msg.method) recordRpcCall(msg.method, msg.params || {});

    if (msg.method === 'initialize') {
      this.capabilities = msg.params?.capabilities ?? null;
      setImmediate(() => {
        sock.serverSend({ jsonrpc: '2.0', id: msg.id, result: {} });
      });
      return;
    }
    if (msg.method === 'initialized') {
      setImmediate(() => {
        if (script.threadStarted) {
          sock.serverSend({ jsonrpc: '2.0', method: 'thread/started', params: { thread: { id: script.threadStarted } } });
        }
        if (script.idleThread && !this.idleSent.has(script.idleThread)) {
          this.idleSent.add(script.idleThread);
          setTimeout(() => {
            sock.serverSend({
              jsonrpc: '2.0',
              method: 'thread/status/changed',
              params: { threadId: script.idleThread, status: { type: 'idle' } },
            });
            if (script.closeAfterIdle) setTimeout(() => sock.close(), 10);
          }, 10);
        }
      });
      return;
    }
    if (msg.method === 'thread/loaded/list') {
      setImmediate(() => {
        sock.serverSend({ jsonrpc: '2.0', id: msg.id, result: { data: script.loadedThreads || [] } });
      });
      return;
    }
    if (msg.method === 'thread/resume') {
      setImmediate(() => {
        sock.serverSend({ jsonrpc: '2.0', id: msg.id, result: { thread: { id: msg.params.threadId, turns: [] } } });
        if (!this.resumed.has(msg.params.threadId)) {
          this.resumed.add(msg.params.threadId);
          script.afterFirstResume?.(sock, msg.params.threadId);
        }
      });
      return;
    }
    if (msg.method === 'thread/read') {
      setImmediate(() => {
        sock.serverSend({ jsonrpc: '2.0', id: msg.id, result: script.onThreadRead?.() || { thread: { turns: [] } } });
        script.afterThreadRead?.(sock);
      });
      return;
    }
    if (Object.prototype.hasOwnProperty.call(msg, 'id')) {
      setImmediate(() => {
        sock.serverSend({ jsonrpc: '2.0', id: msg.id, result: {} });
      });
    }
  }
}

global.WebSocket = class {
  constructor() {
    return new FakeSocket(new FakeWsServer());
  }
};

process.env.ZCREW_CODEX_WS_URL = 'ws://fake.local/ws';

await import(ADAPTER);
const { main } = await import(ADAPTER + `?run=${Date.now()}`);
setInterval(() => {}, 1000);
await main();
