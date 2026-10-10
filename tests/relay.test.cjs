'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');

const { createRelay } = require('../src/codex-durable-relay.cjs');

const LOOPBACK = '127.0.0.1';
const CONNECTED = Buffer.from('HTTP/1.1 200 Connection Established\r\n\r\n', 'ascii');

function listen(server, port = 0) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off('listening', onListening);
      reject(error);
    };
    const onListening = () => {
      server.off('error', onError);
      resolve(server.address());
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen({ host: LOOPBACK, port });
  });
}

function waitFor(predicate, timeoutMs = 1500) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const check = () => {
      let result = false;
      try {
        result = Boolean(predicate());
      } catch {
        result = false;
      }
      if (result) {
        resolve();
        return;
      }
      if (Date.now() >= deadline) {
        reject(new Error('condition timed out'));
        return;
      }
      setTimeout(check, 5).unref?.();
    };
    check();
  });
}

function waitForClose(socket, timeoutMs = 1500) {
  if (socket.destroyed) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('socket close timed out')), timeoutMs);
    timer.unref?.();
    socket.once('close', () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function connectClient(port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: LOOPBACK, port });
    socket.on('error', (error) => {
      if (!socket.connectedForTest) reject(error);
    });
    socket.once('connect', () => {
      socket.connectedForTest = true;
      resolve(socket);
    });
  });
}

async function startMockProxy({
  response = CONNECTED,
  responseDelayMs = 0,
  respond = true,
  allowHalfOpen = false,
} = {}) {
  const state = {
    requests: [],
    payloads: [],
    sockets: new Set(),
    connectionCount: 0,
    closedCount: 0,
    endedCount: 0,
  };
  const server = net.createServer({ allowHalfOpen }, (socket) => {
    state.connectionCount += 1;
    state.sockets.add(socket);
    let buffer = Buffer.alloc(0);
    let requestComplete = false;
    socket.on('error', () => {});
    socket.on('close', () => {
      state.closedCount += 1;
      state.sockets.delete(socket);
    });
    socket.on('end', () => {
      state.endedCount += 1;
    });
    socket.on('data', (chunk) => {
      if (!requestComplete) {
        buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
        const marker = buffer.indexOf(Buffer.from('\r\n\r\n', 'ascii'));
        if (marker < 0) return;
        const end = marker + 4;
        state.requests.push(buffer.subarray(0, end).toString('ascii'));
        requestComplete = true;
        const tail = buffer.subarray(end);
        if (tail.length > 0) state.payloads.push(Buffer.from(tail));
        if (respond) {
          const sendResponse = () => {
            if (!socket.destroyed) socket.write(response);
          };
          if (responseDelayMs > 0) setTimeout(sendResponse, responseDelayMs);
          else sendResponse();
        }
        return;
      }
      state.payloads.push(Buffer.from(chunk));
    });
  });
  const address = await listen(server);
  return {
    requests: state.requests,
    payloads: state.payloads,
    sockets: state.sockets,
    server,
    port: address.port,
    get connectionCount() {
      return state.connectionCount;
    },
    get closedCount() {
      return state.closedCount;
    },
    get endedCount() {
      return state.endedCount;
    },
    sendToTunnel(data) {
      const socket = [...state.sockets][0];
      if (!socket || socket.destroyed) throw new Error('mock proxy has no open socket');
      socket.write(data);
    },
    endTunnel() {
      const socket = [...state.sockets][0];
      if (!socket || socket.destroyed) throw new Error('mock proxy has no open socket');
      socket.end();
    },
    async close() {
      for (const socket of state.sockets) socket.destroy();
      if (!server.listening) return;
      await new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    },
  };
}

async function startFixture(mockOptions = {}, relayOptions = {}) {
  const mock = await startMockProxy(mockOptions);
  const relay = createRelay({
    listenHost: LOOPBACK,
    listenPort: 0,
    proxyHost: LOOPBACK,
    proxyPort: mock.port,
    targetHost: 'codex-cloud-backend.chatgpt.com',
    targetPort: 443,
    logger: () => {},
    ...relayOptions,
  });
  await relay.start();
  return { mock, relay, port: relay.address().port };
}

async function stopFixture(fixture, clients = []) {
  for (const client of clients) {
    if (client && !client.destroyed) client.destroy();
  }
  await fixture.relay.close();
  await fixture.mock.close();
}

test('forwards both directions and keeps response bytes after CONNECT headers', async () => {
  const fixture = await startFixture({
    response: Buffer.concat([CONNECTED, Buffer.from('upstream-first', 'ascii')]),
  });
  let client;
  try {
    client = await connectClient(fixture.port);
    const received = [];
    client.on('data', (chunk) => received.push(Buffer.from(chunk)));
    const clientPayload = Buffer.from('client-before-response', 'ascii');
    client.write(clientPayload);
    await waitFor(() => fixture.mock.requests.length === 1);
    assert.match(fixture.mock.requests[0], /^CONNECT codex-cloud-backend\.chatgpt\.com:443 HTTP\/1\.1\r\n/);
    await waitFor(() => Buffer.concat(fixture.mock.payloads).equals(clientPayload));
    await waitFor(() => Buffer.concat(received).equals(Buffer.from('upstream-first', 'ascii')));

    fixture.mock.sendToTunnel(Buffer.from('upstream-later', 'ascii'));
    await waitFor(() => Buffer.concat(received).equals(Buffer.from('upstream-firstupstream-later', 'ascii')));
    assert.deepEqual(Buffer.concat(fixture.mock.payloads), clientPayload);
  } finally {
    await stopFixture(fixture, [client]);
  }
});

test('rejects a non-200 proxy response without leaking client payload or proxy body', async () => {
  const fixture = await startFixture({
    response: Buffer.from('HTTP/1.1 403 Forbidden\r\nContent-Length: 12\r\n\r\nproxy-body!!', 'ascii'),
  });
  let client;
  const received = [];
  try {
    client = await connectClient(fixture.port);
    client.on('data', (chunk) => received.push(Buffer.from(chunk)));
    client.write(Buffer.from('must-not-reach-upstream', 'ascii'));
    await waitFor(() => fixture.relay.activeCount() === 0);
    assert.equal(Buffer.concat(received).length, 0);
    assert.equal(Buffer.concat(fixture.mock.payloads).length, 0);
  } finally {
    await stopFixture(fixture, [client]);
  }
});

test('rejects malformed and overlong proxy response headers', async () => {
  for (const response of [
    Buffer.from('not-an-http-response\r\n\r\n', 'ascii'),
    Buffer.concat([Buffer.from('HTTP/1.1 200 Connection Established\r\nX-Test: ', 'ascii'), Buffer.alloc(8200, 0x61)]),
  ]) {
    const fixture = await startFixture({ response });
    let client;
    try {
      client = await connectClient(fixture.port);
      await waitFor(() => fixture.relay.activeCount() === 0);
      assert.equal(fixture.mock.payloads.length, 0);
    } finally {
      await stopFixture(fixture, [client]);
    }
  }
});

test('closes both sockets when the proxy handshake times out', async () => {
  const fixture = await startFixture({ respond: false }, { handshakeTimeoutMs: 40 });
  let client;
  try {
    client = await connectClient(fixture.port);
    await waitFor(() => fixture.mock.requests.length === 1);
    await waitFor(() => fixture.relay.activeCount() === 0);
    await waitFor(() => fixture.mock.closedCount === 1);
    assert.equal(client.destroyed, true);
  } finally {
    await stopFixture(fixture, [client]);
  }
});

test('closes the proxy connection when the client cancels during handshake', async () => {
  const fixture = await startFixture({ respond: false }, { handshakeTimeoutMs: 500 });
  let client;
  try {
    client = await connectClient(fixture.port);
    await waitFor(() => fixture.mock.requests.length === 1);
    client.destroy();
    await waitFor(() => fixture.relay.activeCount() === 0);
    await waitFor(() => fixture.mock.closedCount === 1);
  } finally {
    await stopFixture(fixture, [client]);
  }
});

test('rejects connections above the configured concurrency limit', async () => {
  const fixture = await startFixture({ respond: false }, { maxConnections: 2, handshakeTimeoutMs: 500 });
  const clients = [];
  try {
    clients.push(await connectClient(fixture.port));
    clients.push(await connectClient(fixture.port));
    const third = await connectClient(fixture.port);
    clients.push(third);
    await waitFor(() => fixture.mock.connectionCount === 2);
    await waitFor(() => third.destroyed);
    assert.equal(fixture.mock.connectionCount, 2);
    assert.equal(fixture.relay.activeCount(), 2);
  } finally {
    await stopFixture(fixture, clients);
  }
});

test('rejects bursts above the configured per-second admission rate', async () => {
  const fixture = await startFixture(
    { respond: false },
    { maxAcceptsPerSecond: 2, handshakeTimeoutMs: 500 },
  );
  const clients = [];
  try {
    clients.push(await connectClient(fixture.port));
    clients.push(await connectClient(fixture.port));
    clients.push(await connectClient(fixture.port));
    await waitFor(() => fixture.mock.connectionCount === 2);
    await waitFor(() => clients[2].destroyed);
    assert.equal(fixture.mock.connectionCount, 2);
    assert.equal(fixture.relay.activeCount(), 2);
  } finally {
    await stopFixture(fixture, clients);
  }
});

test('preserves an 8KiB response after the client half-closes', async () => {
  const fixture = await startFixture({ response: CONNECTED, allowHalfOpen: true });
  let client;
  const received = [];
  const payload = Buffer.alloc(8 * 1024, 0x5a);
  const response = Buffer.alloc(8 * 1024, 0xa5);
  try {
    client = await connectClient(fixture.port);
    client.on('data', (chunk) => received.push(Buffer.from(chunk)));
    client.end(payload);
    await waitFor(() => fixture.mock.requests.length === 1);
    await waitFor(() => Buffer.concat(fixture.mock.payloads).equals(payload));
    await waitFor(() => fixture.mock.endedCount === 1);
    fixture.mock.sendToTunnel(response);
    await waitFor(() => Buffer.concat(received).equals(response));
    fixture.mock.endTunnel();
    await waitForClose(client);
    assert.deepEqual(Buffer.concat(received), response);
  } finally {
    await stopFixture(fixture, [client]);
  }
});

test('maintains exact bytes with large bidirectional transfers and backpressure', async () => {
  const fixture = await startFixture({ response: CONNECTED });
  let client;
  const received = [];
  const clientPayload = Buffer.alloc(512 * 1024, 0x31);
  const upstreamPayload = Buffer.alloc(2 * 1024 * 1024, 0x8e);
  try {
    client = await connectClient(fixture.port);
    client.on('data', (chunk) => received.push(Buffer.from(chunk)));
    await waitFor(() => fixture.relay.getStats().tunnelsEstablished === 1);
    client.write(clientPayload);
    await waitFor(() => Buffer.concat(fixture.mock.payloads).equals(clientPayload), 3000);

    client.pause();
    fixture.mock.sendToTunnel(upstreamPayload);
    await new Promise((resolve) => setTimeout(resolve, 25));
    client.resume();
    await waitFor(() => Buffer.concat(received).equals(upstreamPayload), 5000);
    assert.deepEqual(Buffer.concat(received), upstreamPayload);
    const stats = fixture.relay.getStats();
    assert.equal(stats.bytesFromClient, clientPayload.length);
    assert.equal(stats.bytesToClient, upstreamPayload.length);
  } finally {
    await stopFixture(fixture, [client]);
  }
});

test('aggregates repeated rejection logs and exposes bounded supervisor stats', async () => {
  const logs = [];
  const fixture = await startFixture(
    { respond: false },
    {
      logger: (entry) => logs.push(entry),
      maxConnections: 1,
      rejectionLogWindowMs: 30,
      handshakeTimeoutMs: 500,
    },
  );
  const clients = [];
  try {
    clients.push(await connectClient(fixture.port));
    clients.push(await connectClient(fixture.port));
    clients.push(await connectClient(fixture.port));
    await waitFor(() => clients[1].destroyed && clients[2].destroyed);
    await new Promise((resolve) => setTimeout(resolve, 60));
    const direct = logs.filter((entry) => entry.event === 'connection_rejected');
    const summaries = logs.filter((entry) => entry.event === 'connection_rejected_summary');
    assert.equal(direct.length, 1);
    assert.equal(summaries.length, 1);
    assert.equal(summaries[0].count, 1);
    assert.match(direct[0].timestamp, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    assert.equal(fixture.relay.getStats().rejectionsByReason.capacity, 2);
  } finally {
    await stopFixture(fixture, clients);
  }
});
