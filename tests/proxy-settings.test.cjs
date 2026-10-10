'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { probeTls, readProxyPort, DEFAULT_PROXY_PORT } = require('../src/managed-relay.cjs');

function fixtureDirectory() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'codex-relay-settings-'));
}

function writeSettings(directory, value) {
  const file = path.join(directory, 'settings.json');
  fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), 'utf8');
  return file;
}

test('missing settings use the default port only when explicitly allowed', () => {
  const directory = fixtureDirectory();
  try {
    assert.equal(readProxyPort(path.join(directory, 'settings.json'), { allowMissing: true }), DEFAULT_PROXY_PORT);
    assert.throws(() => readProxyPort(path.join(directory, 'settings.json')), /could not be read/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('settings accept only exact integer proxy ports in the TCP range', () => {
  const directory = fixtureDirectory();
  try {
    for (const proxyPort of [1, 65535]) {
      assert.equal(readProxyPort(writeSettings(directory, { proxyPort })), proxyPort);
    }
    for (const proxyPort of [0, -1, 65536, 1.5, '7890', null, true]) {
      const file = writeSettings(directory, { proxyPort });
      assert.throws(() => readProxyPort(file), /invalid proxyPort/);
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('malformed settings are reported before the probe can run', () => {
  const directory = fixtureDirectory();
  try {
    const file = writeSettings(directory, '{"proxyPort":');
    assert.throws(() => readProxyPort(file, { allowMissing: true }), /malformed/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('preflight connects to the configured local proxy port', async () => {
  const requests = [];
  class FakeSocket extends EventEmitter {
    write(data) {
      requests.push(data.toString('ascii'));
      queueMicrotask(() => this.emit('data', Buffer.from('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n', 'ascii')));
      return true;
    }
    unshift() {}
    destroy() { this.destroyed = true; }
  }
  const connections = [];
  const result = await probeTls({
    proxyPort: 43124,
    timeoutMs: 1000,
    connect: (options) => {
      connections.push(options);
      const socket = new FakeSocket();
      queueMicrotask(() => socket.emit('connect'));
      return socket;
    },
  });
  assert.deepEqual(result, { ok: false, reason: 'proxy_connect_rejected' });
  assert.deepEqual(connections, [{ host: '127.0.0.1', port: 43124 }]);
  assert.equal(requests.length, 1);
  assert.match(requests[0], /^CONNECT codex-cloud-backend\.chatgpt\.com:443 HTTP\/1\.1\r\n/m);

  const relayConnections = [];
  const relayResult = await probeTls({
    throughRelay: true,
    proxyPort: 65535,
    timeoutMs: 5,
    connect: (options) => {
      relayConnections.push(options);
      return new FakeSocket();
    },
  });
  assert.deepEqual(relayResult, { ok: false, reason: 'probe_timeout' });
  assert.deepEqual(relayConnections, [{ host: '127.0.0.2', port: 443 }]);
});
