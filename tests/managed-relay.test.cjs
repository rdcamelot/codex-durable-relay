'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ManagedController } = require(process.env.CODEX_RELAY_TEST_MODULE || '../src/managed-relay.cjs');
const { createRelay } = require('../src/codex-durable-relay.cjs');

function harness(results) {
  const dir = fs.mkdtempSync(path.join(__dirname, 'codex-managed-test-'));
  let now = Date.now();
  let maintenance = 0;
  const controller = new ManagedController({ stateDirectory: dir, clock: () => now, drainMs: 10,
    healthIntervalMs: 100, shutdownFile: path.join(dir, 'protected-shutdown.flag'), maintainHosts: async () => { maintenance++; return true; },
    probe: async () => results.shift() || { ok: true, reason: 'tls_verified' },
    relayFactory: (options) => createRelay({ ...options, listenHost: '127.0.0.1', listenPort: 0 }) });
  return { controller, dir, advance: (ms) => { now += ms; }, maintenance: () => maintenance,
    status: () => JSON.parse(fs.readFileSync(path.join(dir, 'status.json'), 'utf8')),
    cleanup: async () => {
      await controller.stop();
      if (path.dirname(path.resolve(dir)) !== path.resolve(__dirname) || !path.basename(dir).startsWith('codex-managed-test-')) throw new Error('Unexpected test cleanup path');
      fs.rmSync(dir, { recursive: true, force: true });
    } };
}

test('proxy absent at login leaves no listener or mapping request; recovery starts one', async () => {
  const h = harness([{ ok: false, reason: 'proxy_unavailable' }, { ok: true }]);
  try {
    await h.controller.tick();
    assert.equal(h.status().status, 'waiting_proxy');
    assert.equal(h.status().relayRunning, false);
    assert.equal(h.maintenance(), 0);
    h.advance(2100);
    await h.controller.tick();
    assert.equal(h.status().status, 'ready');
    assert.equal(h.status().relayRunning, true);
    assert.equal(h.maintenance(), 1);
  } finally { await h.cleanup(); }
});

test('an upstream interruption reports degraded without destroying the listener; recovery is automatic', async () => {
  const h = harness([{ ok: true }, { ok: false, reason: 'tls_failure' }, { ok: true }]);
  try {
    await h.controller.tick();
    const address = h.controller.relay.address();
    h.advance(101); await h.controller.tick();
    assert.equal(h.status().status, 'degraded');
    assert.deepEqual(h.controller.relay.address(), address);
    assert.equal(h.maintenance(), 1);
    h.advance(101); await h.controller.tick();
    assert.equal(h.status().status, 'ready');
    assert.equal(h.status().failures, 0);
    assert.deepEqual(h.controller.relay.address(), address);
  } finally { await h.cleanup(); }
});

test('a current stop request closes admission and publishes stopped; stale requests are ignored', async () => {
  const h = harness([{ ok: true }]);
  try {
    fs.writeFileSync(path.join(h.dir, 'stop.json'), JSON.stringify({ pid: process.pid, requestedAt: '2000-01-01T00:00:00Z' }));
    await h.controller.tick();
    assert.equal(h.status().status, 'ready');
    fs.writeFileSync(path.join(h.dir, 'stop.json'), JSON.stringify({ pid: process.pid, requestedAt: new Date(Date.now() + 1000).toISOString() }));
    await h.controller.tick();
    assert.equal(h.status().status, 'stopped');
    assert.equal(h.status().relayRunning, false);
    assert.equal(h.controller.relay.server.listening, false);
    assert.equal(h.maintenance(), 2);
  } finally { await h.cleanup(); }
});

test('occupied listening address reports blocked without mapping', async () => {
  const h = harness([{ ok: true }]);
  h.controller.relayFactory = () => ({ start: async () => { throw new Error('EADDRINUSE'); }, close: async () => {} });
  try {
    await h.controller.tick();
    assert.equal(h.status().status, 'blocked');
    assert.equal(h.status().reason, 'listener_unavailable');
    assert.equal(h.maintenance(), 0);
  } finally { await h.cleanup(); }
});

test('a protected lifecycle request stops a live relay and cannot admit new connections', async () => {
  const h = harness([{ ok: true }]);
  try {
    await h.controller.tick();
    assert.equal(h.status().status, 'ready');
    fs.writeFileSync(path.join(h.dir, 'protected-shutdown.flag'), 'shutdown');
    await h.controller.tick();
    assert.equal(h.status().status, 'stopped');
    assert.equal(h.controller.relay.server.listening, false);
    assert.equal(h.maintenance(), 2);
  } finally { await h.cleanup(); }
});

test('a protected lifecycle request during proxy wait prevents later startup', async () => {
  const h = harness([{ ok: false }, { ok: true }]);
  try {
    await h.controller.tick();
    fs.writeFileSync(path.join(h.dir, 'protected-shutdown.flag'), 'shutdown');
    h.advance(30000);
    await h.controller.tick();
    assert.equal(h.status().status, 'stopped');
    assert.equal(h.status().relayRunning, false);
  } finally { await h.cleanup(); }
});

test('configured proxy port reaches both the preflight probe and relay factory', async () => {
  const dir = fs.mkdtempSync(path.join(__dirname, 'codex-managed-test-'));
  const observed = [];
  const controller = new ManagedController({
    stateDirectory: dir,
    proxyPort: 43123,
    logger: () => {},
    probe: async (options) => {
      observed.push({ kind: 'probe', proxyPort: options.proxyPort, throughRelay: options.throughRelay });
      return { ok: true, reason: 'tls_verified' };
    },
    relayFactory: (options) => {
      observed.push({ kind: 'relay', proxyPort: options.proxyPort });
      return createRelay({ ...options, listenHost: '127.0.0.1', listenPort: 0 });
    },
    maintainHosts: async () => true,
  });
  try {
    await controller.tick();
    assert.deepEqual(observed, [
      { kind: 'probe', proxyPort: 43123, throughRelay: false },
      { kind: 'relay', proxyPort: 43123 },
    ]);
  } finally {
    await controller.stop();
    if (path.dirname(path.resolve(dir)) !== path.resolve(__dirname) || !path.basename(dir).startsWith('codex-managed-test-')) throw new Error('Unexpected test cleanup path');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
