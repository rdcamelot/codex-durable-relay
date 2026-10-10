'use strict';

const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const tls = require('node:tls');
const { execFile } = require('node:child_process');
const { createRelay } = require('./codex-durable-relay.cjs');
const HOST = 'codex-cloud-backend.chatgpt.com';
const HELPER_TASK = 'Codex Durable Relay - Hosts';
const DEFAULT_PROXY_PORT = 7890;
const SETTINGS_FILE = path.join(__dirname, 'settings.json');

function settingsError(message) {
  const error = new Error(message);
  error.code = 'ERR_RELAY_SETTINGS';
  return error;
}

function assertProxyPort(value) {
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new TypeError('proxyPort must be an integer from 1 to 65535');
  }
  return value;
}

function readSettingsFile(settingsPath, { allowMissing = false } = {}) {
  let raw;
  try {
    raw = fs.readFileSync(settingsPath, 'utf8');
  } catch (error) {
    if (allowMissing && error?.code === 'ENOENT') return {};
    throw settingsError('settings.json could not be read');
  }
  let settings;
  try {
    settings = JSON.parse(raw);
  } catch {
    throw settingsError('settings.json is malformed');
  }
  if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) {
    throw settingsError('settings.json must contain a JSON object');
  }
  return settings;
}

function getProxyPort(settings) {
  if (!Object.prototype.hasOwnProperty.call(settings, 'proxyPort')) return DEFAULT_PROXY_PORT;
  try {
    return assertProxyPort(settings.proxyPort);
  } catch {
    throw settingsError('settings.json has invalid proxyPort; expected an integer from 1 to 65535');
  }
}

function readProxyPort(settingsPath = SETTINGS_FILE, options = {}) {
  return getProxyPort(readSettingsFile(settingsPath, options));
}

// This probe sends no account credentials or application messages.
function probeTls({ throughRelay = false, proxyPort = DEFAULT_PROXY_PORT, timeoutMs = 8000, signal,
  connect = net.createConnection } = {}) {
  assertProxyPort(proxyPort);
  return new Promise((resolve) => {
    let socket;
    let secure;
    let done = false;
    let stage = throughRelay ? 'tls_failure' : 'proxy_unavailable';
    let header = Buffer.alloc(0);
    const finish = (ok, reason) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      secure?.destroy();
      socket?.destroy();
      resolve({ ok, reason });
    };
    const abort = () => finish(false, 'cancelled');
    const timer = setTimeout(() => finish(false, 'probe_timeout'), timeoutMs);
    if (signal?.aborted) return abort();
    signal?.addEventListener('abort', abort, { once: true });
    const startTls = () => {
      stage = 'tls_failure';
      secure = tls.connect({ socket, servername: HOST, rejectUnauthorized: true });
      secure.once('secureConnect', () => finish(secure.authorized, secure.authorized ? 'tls_verified' : 'tls_failure'));
      secure.once('error', () => finish(false, 'tls_failure'));
      secure.once('end', () => finish(false, 'tls_closed'));
    };
    socket = connect({
      host: throughRelay ? '127.0.0.2' : '127.0.0.1',
      port: throughRelay ? 443 : proxyPort,
    });
    socket.once('error', () => finish(false, stage));
    socket.once('close', () => finish(false, stage));
    socket.once('connect', () => {
      if (throughRelay) return startTls();
      socket.write(`CONNECT ${HOST}:443 HTTP/1.1\r\nHost: ${HOST}:443\r\n\r\n`);
      const onData = (chunk) => {
        header = Buffer.concat([header, chunk]);
        const end = header.indexOf('\r\n\r\n');
        if (end < 0) {
          if (header.length > 8192) finish(false, 'proxy_response_invalid');
          return;
        }
        socket.removeListener('data', onData);
        if (end > 8192 || !/^HTTP\/1\.[01] 200(?: |\r)/.test(header.toString('ascii', 0, end + 2))) {
          return finish(false, 'proxy_connect_rejected');
        }
        if (header.length > end + 4) socket.unshift(header.subarray(end + 4));
        startTls();
      };
      socket.on('data', onData);
    });
  });
}

function writeJsonAtomic(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function requestHostsMaintenance() {
  const executable = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return new Promise((resolve) => {
    execFile(executable, ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', `Start-ScheduledTask -TaskName '${HELPER_TASK}' -ErrorAction Stop`],
      { windowsHide: true, timeout: 12000, maxBuffer: 8192 }, (error) => resolve(!error));
  });
}

class ManagedController {
  constructor({ stateDirectory, logger = () => {}, probe = probeTls, maintainHosts = requestHostsMaintenance,
    relayFactory = createRelay, clock = () => Date.now(), healthIntervalMs = 30000, drainMs = 5000,
    shutdownFile = null, proxyPort = DEFAULT_PROXY_PORT }) {
    assertProxyPort(proxyPort);
    this.directory = stateDirectory;
    this.logger = logger;
    this.probe = probe;
    this.maintainHosts = maintainHosts;
    this.relayFactory = relayFactory;
    this.clock = clock;
    this.healthIntervalMs = healthIntervalMs;
    this.drainMs = drainMs;
    this.shutdownFile = shutdownFile;
    this.proxyPort = proxyPort;
    this.started = this.clock();
    this.state = { version: 2, pid: process.pid, startedAt: new Date(this.started).toISOString(), status: 'waiting_proxy',
      relayRunning: false, tlsVerifiedAt: null, failures: 0, reason: 'starting' };
    this.nextProbeAt = 0;
    this.lastWriteAt = 0;
    this.abort = new AbortController();
    this.stopping = false;
    fs.mkdirSync(stateDirectory, { recursive: true });
    this.publish();
  }

  publish() {
    this.state.updatedAt = new Date(this.clock()).toISOString();
    this.state.activeConnections = this.relay?.activeCount() || 0;
    this.state.statistics = this.relay?.getStats?.() || null;
    const logStats = this.logger.getStats?.();
    this.state.logWriteHealthy = !logStats?.errorCode;
    writeJsonAtomic(path.join(this.directory, 'status.json'), this.state);
    this.lastWriteAt = this.clock();
  }

  transition(status, reason) {
    if (status !== this.state.status || reason !== this.state.reason) {
      this.logger({ time: new Date(this.clock()).toISOString(), event: 'supervisor_state', status, reason });
    }
    this.state.status = status;
    this.state.reason = reason;
    this.publish();
  }

  stopRequested() {
    // Only the lifecycle service can create this file in the protected install.
    if (this.shutdownFile && fs.existsSync(this.shutdownFile)) return true;
    try {
      const request = JSON.parse(fs.readFileSync(path.join(this.directory, 'stop.json'), 'utf8'));
      return request.pid === process.pid && Date.parse(request.requestedAt) >= this.started;
    } catch { return false; }
  }

  async tick() {
    if (this.stopping) return;
    if (this.stopRequested()) { await this.stop(); return; }
    if (this.clock() < this.nextProbeAt) {
      if (this.clock() - this.lastWriteAt >= 10000) this.publish();
      return;
    }
    const result = await this.probe({ throughRelay: !!this.relay, proxyPort: this.proxyPort, signal: this.abort.signal });
    if (this.stopping) return;
    if (!result.ok) {
      this.state.failures += 1;
      this.nextProbeAt = this.clock() + (this.relay ? this.healthIntervalMs : Math.min(30000, 2000 * 2 ** Math.min(this.state.failures - 1, 4)));
      this.transition(this.relay ? 'degraded' : 'waiting_proxy', result.reason);
      return;
    }
    this.state.failures = 0;
    this.state.tlsVerifiedAt = new Date(this.clock()).toISOString();
    if (!this.relay) {
      const relay = this.relayFactory({ logger: this.logger, proxyPort: this.proxyPort });
      try { await relay.start(); }
      catch {
        await relay.close().catch(() => {});
        this.nextProbeAt = this.clock() + 30000;
        this.transition('blocked', 'listener_unavailable');
        return;
      }
      if (this.stopping) { await relay.close(); return; }
      this.relay = relay;
      this.state.relayRunning = true;
      this.state.helperRequested = await this.maintainHosts();
    }
    this.nextProbeAt = this.clock() + this.healthIntervalMs;
    this.transition('ready', 'tls_verified');
  }

  async stop() {
    if (this.stopping) return this.stopPromise;
    this.stopping = true;
    this.abort.abort();
    this.stopPromise = (async () => {
      this.transition('stopping', 'user_or_session_stop');
      if (this.relay) {
        // Stop admission first. Existing sockets receive a bounded chance to finish.
        if (this.relay.server.listening) this.relay.server.close();
        await this.maintainHosts();
        const deadline = Date.now() + this.drainMs;
        while (this.relay.activeCount() > 0 && Date.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        await this.relay.close();
      } else {
        await this.maintainHosts();
      }
      this.state.relayRunning = false;
      this.transition('stopped', 'clean_stop');
    })();
    return this.stopPromise;
  }
}

async function run() {
  if (process.argv.length !== 3 || !['--run', '--probe'].includes(process.argv[2])) throw new Error('invalid arguments');
  if (process.argv[2] === '--probe') {
    const result = await probeTls({ proxyPort: readProxyPort(SETTINGS_FILE, { allowMissing: true }) });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exitCode = result.ok ? 0 : 1;
    return;
  }
  const settings = readSettingsFile(SETTINGS_FILE);
  const proxyPort = getProxyPort(settings);
  const { createRotatingLogger } = require('./relay-log.cjs');
  const logger = createRotatingLogger(path.join(settings.stateDirectory, 'relay.jsonl'), { maxBytes: 1024 * 1024, maxFiles: 3 });
  const controller = new ManagedController({ stateDirectory: settings.stateDirectory, logger, proxyPort,
    shutdownFile: path.join(__dirname, 'shutdown-request.flag') });
  // Observe shutdown even while a network probe is waiting for its timeout.
  const stopWatcher = setInterval(() => {
    if (!controller.stopping && controller.stopRequested()) {
      void controller.stop().catch(() => { process.exitCode = 1; });
    }
  }, 250);
  process.once('SIGINT', () => { void controller.stop(); });
  process.once('SIGTERM', () => { void controller.stop(); });
  try {
    while (!controller.stopping) {
      await controller.tick();
      if (!controller.stopping) await new Promise((resolve) => setTimeout(resolve, 500));
    }
    await controller.stopPromise;
  } catch {
    try { await controller.stop(); } catch { /* scheduled maintenance also restores orphan mappings */ }
    process.exitCode = 1;
  } finally {
    clearInterval(stopWatcher);
    logger.close?.();
  }
}

module.exports = { ManagedController, probeTls, writeJsonAtomic, readProxyPort, assertProxyPort,
  DEFAULT_PROXY_PORT };
if (require.main === module) run().catch((error) => {
  if (error?.code === 'ERR_RELAY_SETTINGS') process.stderr.write(`${error.message}\n`);
  else process.stderr.write('Managed relay could not start.\n');
  process.exitCode = 1;
});
