'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_MAX_BYTES = 1024 * 1024;
const DEFAULT_MAX_FILES = 3;

function assertPositiveInteger(value, name, maximum) {
  if (!Number.isInteger(value) || value <= 0 || (maximum !== undefined && value > maximum)) {
    throw new TypeError(`${name} must be a positive integer${maximum ? ` <= ${maximum}` : ''}`);
  }
}

function timestampedEntry(entry) {
  if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
    return { ...entry, timestamp: new Date().toISOString() };
  }
  return { timestamp: new Date().toISOString(), message: String(entry) };
}

function createRotatingLogger(filePath, options = {}) {
  if (typeof filePath !== 'string' || filePath.length === 0) throw new TypeError('filePath must be a non-empty string');
  const maxBytes = options.maxBytes === undefined ? DEFAULT_MAX_BYTES : options.maxBytes;
  const maxFiles = options.maxFiles === undefined ? DEFAULT_MAX_FILES : options.maxFiles;
  assertPositiveInteger(maxBytes, 'maxBytes', 64 * 1024 * 1024);
  assertPositiveInteger(maxFiles, 'maxFiles', 10);

  const resolvedPath = path.resolve(filePath);
  let closed = false;
  let writes = 0;
  let bytesWritten = 0;
  let rotations = 0;
  let errorCode;

  function fail(code) {
    errorCode = code;
    return false;
  }

  function ensureParent() {
    fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  }

  function rotate() {
    for (let index = maxFiles - 2; index >= 1; index -= 1) {
      const source = `${resolvedPath}.${index}`;
      const target = `${resolvedPath}.${index + 1}`;
      if (fs.existsSync(source)) {
        try {
          fs.rmSync(target, { force: true });
          fs.renameSync(source, target);
        } catch (error) {
          return false;
        }
      }
    }
    if (fs.existsSync(resolvedPath)) {
      try {
        if (maxFiles === 1) {
          fs.rmSync(resolvedPath, { force: true });
        } else {
          fs.rmSync(`${resolvedPath}.1`, { force: true });
          fs.renameSync(resolvedPath, `${resolvedPath}.1`);
        }
        rotations += 1;
      } catch (error) {
        return false;
      }
    }
    return true;
  }

  function write(entry) {
    if (closed) return fail('closed');
    const line = `${JSON.stringify(timestampedEntry(entry))}\n`;
    const bytes = Buffer.byteLength(line, 'utf8');
    if (bytes > maxBytes) return fail('entry_too_large');
    try {
      ensureParent();
      let currentBytes = 0;
      try {
        currentBytes = fs.statSync(resolvedPath).size;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      if (currentBytes > 0 && currentBytes + bytes > maxBytes) {
        if (!rotate()) return fail('rotation_failed');
        let rotatedBytes = 0;
        try {
          rotatedBytes = fs.statSync(resolvedPath).size;
        } catch (error) {
          if (error.code !== 'ENOENT') return fail('rotation_stat_failed');
        }
        if (rotatedBytes + bytes > maxBytes) return fail('rotation_capacity_exceeded');
      }
      fs.appendFileSync(resolvedPath, line, 'utf8');
      writes += 1;
      bytesWritten += bytes;
      return true;
    } catch (error) {
      return fail('write_failed');
    }
  }

  write.close = () => {
    closed = true;
  };
  write.getStats = () => ({
    filePath: resolvedPath,
    maxBytes,
    maxFiles,
    writes,
    bytesWritten,
    rotations,
    closed,
    errorCode,
  });
  return write;
}

module.exports = {
  createRotatingLogger,
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_FILES,
};
