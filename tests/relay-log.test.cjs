'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { createRotatingLogger } = require('../src/relay-log.cjs');

const WORK_ROOT = path.resolve(__dirname);

function temporaryDirectory() {
  return fs.mkdtempSync(path.join(WORK_ROOT, '.relay-log-test-'));
}

function removeTemporaryDirectory(directory) {
  const resolved = path.resolve(directory);
  assert.equal(path.dirname(resolved), WORK_ROOT);
  assert.match(path.basename(resolved), /^\.relay-log-test-/);
  fs.rmSync(resolved, { recursive: true, force: true });
}

test('rotating logger bounds files and adds UTC timestamps', () => {
  const directory = temporaryDirectory();
  const filePath = path.join(directory, 'relay.jsonl');
  const logger = createRotatingLogger(filePath, { maxBytes: 180, maxFiles: 2 });
  try {
    for (let index = 0; index < 12; index += 1) assert.equal(logger({ event: 'test', index }), true);
    const files = fs.readdirSync(directory).filter((name) => name.startsWith('relay.jsonl'));
    assert.deepEqual(files.sort(), ['relay.jsonl', 'relay.jsonl.1']);
    for (const name of files) assert.ok(fs.statSync(path.join(directory, name)).size <= 180);
    const lines = fs.readFileSync(filePath, 'utf8').trim().split('\n');
    assert.ok(lines.length > 0);
    assert.match(JSON.parse(lines[0]).timestamp, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    assert.equal(logger.getStats().rotations > 0, true);
    logger.close();
    assert.equal(logger({ event: 'ignored' }), false);
  } finally {
    removeTemporaryDirectory(directory);
  }
});

test('refuses an append when rotation fails and reports only an error code', () => {
  const directory = temporaryDirectory();
  const filePath = path.join(directory, 'relay.jsonl');
  const logger = createRotatingLogger(filePath, { maxBytes: 180, maxFiles: 2 });
  const originalRenameSync = fs.renameSync;
  try {
    assert.equal(logger({ event: 'seed', payload: 'x'.repeat(50) }), true);
    fs.renameSync = () => {
      throw new Error('simulated rename failure');
    };
    assert.equal(logger({ event: 'overflow', payload: 'y'.repeat(50) }), false);
    assert.equal(logger.getStats().errorCode, 'rotation_failed');
    assert.equal(Object.hasOwn(logger.getStats(), 'lastError'), false);
    assert.ok(fs.statSync(filePath).size <= 180);
  } finally {
    fs.renameSync = originalRenameSync;
    logger.close();
    removeTemporaryDirectory(directory);
  }
});
