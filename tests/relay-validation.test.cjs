'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createRelay } = require('../src/codex-durable-relay.cjs');

test('rejects nonnumeric and invalid loopback hosts before opening sockets', () => {
  for (const field of ['proxyHost', 'listenHost']) {
    for (const host of ['127.999.999.999', '127.0.0.999', 'localhost', 'example.test', '192.0.2.1', '::2']) {
      assert.throws(() => createRelay({ [field]: host }), /loopback host/);
    }
  }
});
