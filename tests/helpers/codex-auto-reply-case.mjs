#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const ADAPTER = '/home/dl/Projects/zcrew/codex-auto-reply.sparky.mjs';
const caseName = process.env.CASE_NAME;
const callsFile = process.env.CALLS_FILE;
const debug = process.env.DEBUG_CASE === '1';
if (!caseName || !callsFile) throw new Error('CASE_NAME and CALLS_FILE required');

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
    afterInitialize: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: 'hello' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
  },
  multi: {
    afterInitialize: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: 'first' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: 'second' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
  },
  tool_only: {
    afterInitialize: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'toolCall', text: 'x' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
  },
  fallback_text: {
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', items: [{ type: 'agentMessage', text: 'fallback text' }] }] },
    }),
    afterInitialize: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: '   ' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
    afterThreadRead: () => {},
  },
  fallback_empty: {
    onThreadRead: () => ({
      thread: { turns: [{ id: 'tu1', items: [{ type: 'agentMessage', text: '  ' }] }] },
    }),
    afterInitialize: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'item/completed', params: { threadId: 'th1', turnId: 'tu1', item: { type: 'agentMessage', text: '' } } });
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/completed', params: { threadId: 'th1', turn: { id: 'tu1' } } });
    },
    afterThreadRead: () => {},
  },
  disconnect: {
    afterInitialize: (sock) => {
      sock.serverSend({ jsonrpc: '2.0', method: 'turn/started', params: { threadId: 'th1', turn: { id: 'tu1' } } });
      setTimeout(() => sock.close(), 10);
    },
  },
};

const script = scripts[caseName];
if (!script) throw new Error(`unknown case: ${caseName}`);

class FakeWsServer {
  onClientMessage(sock, msg) {
    if (msg.method === 'initialize') {
      setImmediate(() => {
        sock.serverSend({ jsonrpc: '2.0', id: msg.id, result: {} });
        script.afterInitialize?.(sock);
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
