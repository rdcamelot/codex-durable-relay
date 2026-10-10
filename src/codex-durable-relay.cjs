'use strict';

const net = require('node:net');

const DEFAULTS = Object.freeze({
  listenHost: '127.0.0.2',
  listenPort: 443,
  proxyHost: '127.0.0.1',
  proxyPort: 7890,
  targetHost: 'codex-cloud-backend.chatgpt.com',
  targetPort: 443,
  maxConnections: 16,
  maxAcceptsPerSecond: 8,
  maxHeaderBytes: 8 * 1024,
  handshakeTimeoutMs: 10 * 1000,
  maxPreHandshakeBytes: 1024 * 1024,
  rejectionLogWindowMs: 1000,
});

const CRLFCRLF = Buffer.from('\r\n\r\n', 'ascii');

function assertPort(value, name, { allowZero = true } = {}) {
  if (!Number.isInteger(value) || value < 0 || value > 65535 || (!allowZero && value === 0)) {
    throw new TypeError(`${name} must be an integer TCP port`);
  }
  return value;
}

function assertPositiveInteger(value, name) {
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive integer`);
  }
  return value;
}

function assertBoundedPositiveInteger(value, name, maximum) {
  assertPositiveInteger(value, name);
  if (value > maximum) throw new RangeError(`${name} cannot exceed ${maximum}`);
  return value;
}

function assertLoopbackHost(value, name) {
  const host = String(value).toLowerCase();
  if (host !== '::1' && !(net.isIP(host) === 4 && host.startsWith('127.'))) {
    throw new TypeError(`${name} must be a loopback host`);
  }
  return value;
}

function defaultLogger(entry) {
  // Keep the event schema deliberately small: no endpoints, headers, payloads,
  // error text, or credentials are ever emitted.
  process.stderr.write(`${JSON.stringify(entry)}\n`);
}

function emit(logger, event, connectionId, startedAt, status, extra = {}) {
  if (typeof logger !== 'function') return;
  const entry = {
    timestamp: new Date().toISOString(),
    event,
    status,
    connectionId,
  };
  if (startedAt !== undefined) entry.durationMs = Math.max(0, Date.now() - startedAt);
  Object.assign(entry, extra);
  try {
    logger(entry);
  } catch {
    // Logging must never change relay behavior.
  }
}

function makeConnectRequest(targetHost, targetPort, maxHeaderBytes) {
  const text = [
    `CONNECT ${targetHost}:${targetPort} HTTP/1.1`,
    `Host: ${targetHost}:${targetPort}`,
    'Proxy-Connection: Keep-Alive',
    'Connection: Keep-Alive',
    '',
    '',
  ].join('\r\n');
  const request = Buffer.from(text, 'ascii');
  if (request.length > maxHeaderBytes) {
    throw new RangeError('CONNECT request exceeds the header limit');
  }
  return request;
}

function parseProxyStatus(header) {
  const firstLineEnd = header.indexOf('\r\n');
  if (firstLineEnd < 0) return undefined;
  const firstLine = header.slice(0, firstLineEnd);
  const match = /^HTTP\/\d(?:\.\d)?\s+(\d{3})(?:\s|$)/.exec(firstLine);
  return match ? Number(match[1]) : undefined;
}

function createRelay(options = {}) {
  const config = {
    ...DEFAULTS,
    ...options,
  };

  // The public CLI supplies fixed loopback values. The factory also accepts
  // loopback overrides so tests can use random local ports only.
  assertLoopbackHost(config.listenHost, 'listenHost');
  assertLoopbackHost(config.proxyHost, 'proxyHost');
  assertPort(config.listenPort, 'listenPort');
  assertPort(config.proxyPort, 'proxyPort', { allowZero: false });
  assertPort(config.targetPort, 'targetPort', { allowZero: false });
  assertPositiveInteger(config.maxConnections, 'maxConnections');
  assertPositiveInteger(config.maxAcceptsPerSecond, 'maxAcceptsPerSecond');
  assertPositiveInteger(config.maxHeaderBytes, 'maxHeaderBytes');
  assertPositiveInteger(config.handshakeTimeoutMs, 'handshakeTimeoutMs');
  assertPositiveInteger(config.maxPreHandshakeBytes, 'maxPreHandshakeBytes');
  assertBoundedPositiveInteger(config.rejectionLogWindowMs, 'rejectionLogWindowMs', 60 * 1000);
  if (config.maxConnections > DEFAULTS.maxConnections) {
    throw new RangeError(`maxConnections cannot exceed ${DEFAULTS.maxConnections}`);
  }
  if (config.maxHeaderBytes > DEFAULTS.maxHeaderBytes) {
    throw new RangeError(`maxHeaderBytes cannot exceed ${DEFAULTS.maxHeaderBytes}`);
  }
  if (typeof config.targetHost !== 'string' || config.targetHost.length === 0) {
    throw new TypeError('targetHost must be a non-empty string');
  }

  const logger = config.logger === undefined ? defaultLogger : config.logger;
  const active = new Set();
  const acceptedAt = [];
  const rejectionLogBuckets = new Map();
  let nextConnectionId = 0;
  let closing = false;
  let closePromise;
  let rejectionFlushTimer;
  const stats = {
    connectionsAccepted: 0,
    connectionsRejected: 0,
    connectionsClosed: 0,
    tunnelsEstablished: 0,
    bytesFromClient: 0,
    bytesToClient: 0,
    rejectionsByReason: Object.create(null),
  };

  function recordClosed(state) {
    if (state.statsClosed) return;
    state.statsClosed = true;
    stats.connectionsClosed += 1;
  }

  function flushRejectionLogs(force = false) {
    const now = Date.now();
    let nextDelay;
    for (const [reason, bucket] of rejectionLogBuckets) {
      const remaining = bucket.startedAt + config.rejectionLogWindowMs - now;
      if (!force && remaining > 0) {
        nextDelay = nextDelay === undefined ? remaining : Math.min(nextDelay, remaining);
        continue;
      }
      const suppressed = bucket.count - 1;
      if (suppressed > 0) {
        emit(logger, 'connection_rejected_summary', undefined, undefined, reason, {
          count: suppressed,
          windowMs: Math.max(0, now - bucket.startedAt),
        });
      }
      rejectionLogBuckets.delete(reason);
    }
    if (!force && rejectionLogBuckets.size > 0) {
      rejectionFlushTimer = setTimeout(() => {
        rejectionFlushTimer = undefined;
        flushRejectionLogs();
      }, Math.max(1, nextDelay || config.rejectionLogWindowMs));
      rejectionFlushTimer.unref?.();
    }
  }

  function scheduleRejectionFlush() {
    if (rejectionFlushTimer || rejectionLogBuckets.size === 0) return;
    rejectionFlushTimer = setTimeout(() => {
      rejectionFlushTimer = undefined;
      flushRejectionLogs();
    }, config.rejectionLogWindowMs);
    rejectionFlushTimer.unref?.();
  }

  function recordRejection(connectionId, startedAt, reason) {
    stats.connectionsRejected += 1;
    stats.rejectionsByReason[reason] = (stats.rejectionsByReason[reason] || 0) + 1;
    const now = Date.now();
    let bucket = rejectionLogBuckets.get(reason);
    if (!bucket || now - bucket.startedAt >= config.rejectionLogWindowMs) {
      if (bucket) {
        const suppressed = bucket.count - 1;
        if (suppressed > 0) {
          emit(logger, 'connection_rejected_summary', undefined, undefined, reason, {
            count: suppressed,
            windowMs: Math.max(0, now - bucket.startedAt),
          });
        }
      }
      bucket = { startedAt: now, count: 0 };
      rejectionLogBuckets.set(reason, bucket);
      emit(logger, 'connection_rejected', connectionId, startedAt, reason, { count: 1 });
    }
    bucket.count += 1;
    scheduleRejectionFlush();
  }

  function finishContext(state, event = 'closed', status = 'closed') {
    if (state.finished) return;
    state.finished = true;
    if (state.handshakeTimer) {
      clearTimeout(state.handshakeTimer);
      state.handshakeTimer = undefined;
    }
    active.delete(state);
    recordClosed(state);
    emit(logger, event, state.connectionId, state.startedAt, status);
  }

  function terminateContext(state, event, status) {
    if (state.finished) return;
    if (state.handshakeTimer) {
      clearTimeout(state.handshakeTimer);
      state.handshakeTimer = undefined;
    }
    state.terminated = true;
    active.delete(state);
    recordClosed(state);
    if (event === 'connection_rejected') recordRejection(state.connectionId, state.startedAt, status);
    else emit(logger, event, state.connectionId, state.startedAt, status);
    // destroy() is idempotent and the error listeners below prevent an
    // unhandled error from changing cleanup behavior.
    if (state.client && !state.client.destroyed) state.client.destroy();
    if (state.proxy && !state.proxy.destroyed) state.proxy.destroy();
    state.finished = true;
  }

  function admitConnection(now) {
    const cutoff = now - 1000;
    while (acceptedAt.length > 0 && acceptedAt[0] <= cutoff) acceptedAt.shift();
    if (acceptedAt.length >= config.maxAcceptsPerSecond) return false;
    acceptedAt.push(now);
    return true;
  }

  function handleClient(client) {
    if (closing) {
      client.destroy();
      return;
    }
    const incomingConnectionId = ++nextConnectionId;
    if (!admitConnection(Date.now())) {
      recordRejection(incomingConnectionId, undefined, 'rate_limit');
      client.destroy();
      return;
    }
    if (active.size >= config.maxConnections) {
      recordRejection(incomingConnectionId, undefined, 'capacity');
      client.destroy();
      return;
    }

    const state = {
      client,
      proxy: undefined,
      connectionId: incomingConnectionId,
      startedAt: Date.now(),
      established: false,
      terminated: false,
      finished: false,
      statsClosed: false,
      responseBuffer: Buffer.alloc(0),
      pendingClientChunks: [],
      pendingClientBytes: 0,
      clientEnded: false,
      proxyEnded: false,
      proxyReadableEnded: false,
      proxyEndPending: false,
      clientPausedForProxy: false,
      proxyPausedForClient: false,
      handshakeTimer: undefined,
    };
    active.add(state);
    stats.connectionsAccepted += 1;
    emit(logger, 'connection_accepted', state.connectionId, state.startedAt, 'accepted');

    client.pause();
    client.on('error', () => {
      if (!state.terminated) terminateContext(state, 'connection_closed', 'client_error');
    });
    client.on('close', () => {
      if (!state.terminated) {
        if (state.proxy && !state.proxy.destroyed) state.proxy.destroy();
        finishContext(state, 'connection_closed', 'client_closed');
      } else {
        state.finished = true;
      }
    });
    client.on('end', () => {
      state.clientEnded = true;
      if (state.established) endProxyWhenReady();
    });

    function endProxyWhenReady() {
      if (!state.established || !state.clientEnded || state.proxyEnded || !state.proxy || state.proxy.destroyed) return;
      if (state.pendingClientChunks.length > 0 || state.clientPausedForProxy) {
        state.proxyEndPending = true;
        return;
      }
      state.proxyEndPending = false;
      state.proxyEnded = true;
      state.proxy.end();
    }

    function writePendingToProxy() {
      if (!state.proxy || state.proxy.destroyed) return;
      const pending = state.pendingClientChunks;
      let index = 0;
      for (; index < pending.length; index += 1) {
        stats.bytesFromClient += pending[index].length;
        if (!state.proxy.write(pending[index])) {
          index += 1;
          state.clientPausedForProxy = true;
          break;
        }
      }
      state.pendingClientChunks = pending.slice(index);
      state.pendingClientBytes = state.pendingClientChunks.reduce((sum, chunk) => sum + chunk.length, 0);
      if (state.pendingClientChunks.length === 0 && !state.clientPausedForProxy && state.clientEnded) {
        endProxyWhenReady();
      } else if (!state.clientPausedForProxy && !state.clientEnded) {
        client.resume();
      }
    }

    function establishTunnel(responseTail) {
      if (state.terminated || state.established) return;
      state.established = true;
      if (state.handshakeTimer) {
        clearTimeout(state.handshakeTimer);
        state.handshakeTimer = undefined;
      }
      stats.tunnelsEstablished += 1;
      emit(logger, 'tunnel_established', state.connectionId, state.startedAt, 'ready');

      // Install both directions before writing either buffered tail. This
      // preserves the response bytes that followed the proxy's header.
      state.proxy.on('drain', () => {
        if (!state.established || state.terminated) return;
        if (state.clientPausedForProxy) {
          state.clientPausedForProxy = false;
          if (state.pendingClientChunks.length > 0) writePendingToProxy();
          else if (state.clientEnded) endProxyWhenReady();
          else client.resume();
        }
      });
      client.on('drain', () => {
        if (!state.established || state.terminated) return;
        if (state.proxyPausedForClient) {
          state.proxyPausedForClient = false;
          if (!state.proxy.destroyed) state.proxy.resume();
        }
      });

      writePendingToProxy();
      if (responseTail.length > 0 && !client.destroyed) {
        stats.bytesToClient += responseTail.length;
        if (!client.write(responseTail)) {
          state.proxyPausedForClient = true;
          state.proxy.pause();
        }
      }
      if (!state.clientPausedForProxy && !state.clientEnded) client.resume();
      else if (state.clientEnded) endProxyWhenReady();
    }

    client.on('data', (chunk) => {
      if (state.terminated) return;
      if (!state.established) {
        state.pendingClientChunks.push(chunk);
        state.pendingClientBytes += chunk.length;
        if (state.pendingClientBytes > config.maxPreHandshakeBytes) {
          terminateContext(state, 'connection_rejected', 'client_buffer_limit');
        }
        return;
      }
      if (state.proxy && !state.proxy.destroyed && !state.proxy.write(chunk)) {
        stats.bytesFromClient += chunk.length;
        state.clientPausedForProxy = true;
        client.pause();
      } else if (state.proxy && !state.proxy.destroyed) {
        stats.bytesFromClient += chunk.length;
      }
    });

    const proxy = net.createConnection({
      host: config.proxyHost,
      port: config.proxyPort,
      allowHalfOpen: true,
    });
    state.proxy = proxy;
    if (state.terminated) {
      proxy.destroy();
      return;
    }
    proxy.on('error', () => {
      if (!state.terminated) terminateContext(state, 'connection_closed', 'proxy_error');
    });
    proxy.on('close', () => {
      if (!state.terminated) {
        if (state.proxyReadableEnded) {
          if (state.client && !state.client.destroyed && !state.client.writableEnded) state.client.end();
        } else if (state.client && !state.client.destroyed) {
          state.client.destroy();
        }
        finishContext(state, 'connection_closed', 'proxy_closed');
      }
    });
    proxy.on('end', () => {
      state.proxyReadableEnded = true;
      if (state.established && !state.terminated && !client.destroyed) client.end();
      if (!proxy.destroyed && !proxy.writableEnded) proxy.end();
    });
    proxy.on('connect', () => {
      if (state.terminated) return;
      const request = makeConnectRequest(config.targetHost, config.targetPort, config.maxHeaderBytes);
      if (!proxy.write(request)) proxy.pause();
    });
    proxy.on('drain', () => {
      if (!state.established && !state.terminated) proxy.resume();
    });
    proxy.on('data', (chunk) => {
      if (state.terminated) return;
      if (state.established) {
        if (client.destroyed) return;
        stats.bytesToClient += chunk.length;
        if (!client.write(chunk)) {
          state.proxyPausedForClient = true;
          proxy.pause();
        }
        return;
      }

      state.responseBuffer = state.responseBuffer.length === 0
        ? chunk
        : Buffer.concat([state.responseBuffer, chunk]);
      const marker = state.responseBuffer.indexOf(CRLFCRLF);
      if (marker < 0) {
        if (state.responseBuffer.length > config.maxHeaderBytes) {
          terminateContext(state, 'connection_rejected', 'proxy_header_too_large');
        }
        return;
      }
      const headerEnd = marker + CRLFCRLF.length;
      if (headerEnd > config.maxHeaderBytes) {
        terminateContext(state, 'connection_rejected', 'proxy_header_too_large');
        return;
      }
      const header = state.responseBuffer.subarray(0, headerEnd).toString('latin1');
      const statusCode = parseProxyStatus(header);
      const tail = state.responseBuffer.subarray(headerEnd);
      state.responseBuffer = Buffer.alloc(0);
      if (statusCode !== 200) {
        terminateContext(state, 'connection_rejected', 'proxy_status');
        return;
      }
      establishTunnel(tail);
    });

    state.handshakeTimer = setTimeout(() => {
      if (!state.established && !state.terminated) {
        terminateContext(state, 'connection_rejected', 'handshake_timeout');
      }
    }, config.handshakeTimeoutMs);
    state.handshakeTimer.unref?.();
  }

  const server = net.createServer({ pauseOnConnect: true, allowHalfOpen: true }, handleClient);

  async function start() {
    if (server.listening) return server.address();
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        server.off('listening', onListening);
        reject(error);
      };
      const onListening = () => {
        server.off('error', onError);
        resolve();
      };
      server.once('error', onError);
      server.once('listening', onListening);
      server.listen({ host: config.listenHost, port: config.listenPort });
    });
    return server.address();
  }

  async function close() {
    if (closePromise) return closePromise;
    closing = true;
    if (rejectionFlushTimer) {
      clearTimeout(rejectionFlushTimer);
      rejectionFlushTimer = undefined;
    }
    flushRejectionLogs(true);
    for (const state of [...active]) {
      terminateContext(state, 'connection_closed', 'relay_closed');
    }
    closePromise = new Promise((resolve, reject) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.close((error) => (error ? reject(error) : resolve()));
    });
    return closePromise;
  }

  function getStats() {
    const now = Date.now();
    const cutoff = now - 1000;
    while (acceptedAt.length > 0 && acceptedAt[0] <= cutoff) acceptedAt.shift();
    return {
      listening: Boolean(server.listening),
      closing,
      activeConnections: active.size,
      acceptsInCurrentSecond: acceptedAt.length,
      connectionsAccepted: stats.connectionsAccepted,
      connectionsRejected: stats.connectionsRejected,
      connectionsClosed: stats.connectionsClosed,
      tunnelsEstablished: stats.tunnelsEstablished,
      bytesFromClient: stats.bytesFromClient,
      bytesToClient: stats.bytesToClient,
      rejectionsByReason: { ...stats.rejectionsByReason },
    };
  }

  return {
    server,
    start,
    close,
    address: () => server.address(),
    activeCount: () => active.size,
    getStats,
    config: Object.freeze({ ...config }),
  };
}

function parseListenPort(argv) {
  let listenPort = DEFAULTS.listenPort;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') return { help: true };
    if (arg === '--listen-port') {
      const raw = argv[++index];
      if (raw === undefined || !/^\d+$/.test(raw)) throw new Error('invalid --listen-port');
      listenPort = Number(raw);
      assertPort(listenPort, 'listenPort');
      continue;
    }
    throw new Error('unknown argument');
  }
  return { listenPort, help: false };
}

async function runCli() {
  let parsed;
  try {
    parsed = parseListenPort(process.argv.slice(2));
  } catch {
    process.stderr.write('Usage: node codex-durable-relay.cjs [--listen-port PORT]\n');
    process.exitCode = 2;
    return;
  }
  if (parsed.help) {
    process.stdout.write('Usage: node codex-durable-relay.cjs [--listen-port PORT]\n');
    return;
  }

  const relay = createRelay({
    listenHost: DEFAULTS.listenHost,
    listenPort: parsed.listenPort,
    proxyHost: DEFAULTS.proxyHost,
    proxyPort: DEFAULTS.proxyPort,
    targetHost: DEFAULTS.targetHost,
    targetPort: DEFAULTS.targetPort,
  });
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await relay.close().catch(() => {});
    process.exitCode = 0;
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  try {
    await relay.start();
    emit(defaultLogger, 'listening', undefined, undefined, 'ready');
  } catch {
    process.stderr.write(`${JSON.stringify({ event: 'listening', status: 'error' })}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  createRelay,
  DEFAULTS,
};

if (require.main === module) {
  runCli();
}
