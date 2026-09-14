'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { checkVersionSync, checkMcpName } = require('../lib/version-sync');

const PKG = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', 'package.json'), 'utf8'));
const SERVER_JSON_PATH = path.resolve(__dirname, '..', '..', 'server.json');

function serverJson(overrides = {}) {
  return {
    name: 'io.github.AdelElo13/mac-control-mcp',
    version: '0.8.3',
    packages: [
      { registryType: 'mcpb', identifier: 'https://example/x.mcpb', transport: { type: 'stdio' } },
      {
        registryType: 'npm',
        identifier: 'mac-control-mcp',
        version: '0.8.3',
        transport: { type: 'stdio' },
      },
    ],
    ...overrides,
  };
}

test('the checked-in package.json and server.json are in sync', () => {
  const real = JSON.parse(fs.readFileSync(SERVER_JSON_PATH, 'utf8'));
  assert.deepEqual(checkVersionSync(PKG.version, real), { ok: true });
  assert.deepEqual(checkMcpName(PKG, real), { ok: true });
});

test('checkVersionSync passes when every version agrees', () => {
  assert.deepEqual(checkVersionSync('0.8.3', serverJson()), { ok: true });
});

test('checkVersionSync catches a server.json top-level version drift', () => {
  const res = checkVersionSync('0.9.0', serverJson());
  assert.equal(res.ok, false);
  assert.match(res.problems.join('\n'), /server\.json version is "0\.8\.3"/);
});

test('checkVersionSync catches a missing npm package entry', () => {
  const res = checkVersionSync('0.8.3', serverJson({ packages: [{ registryType: 'mcpb' }] }));
  assert.equal(res.ok, false);
  assert.match(res.problems.join('\n'), /no packages\[\] entry with registryType "npm"/);
});

test('checkVersionSync catches an npm package entry pinned to the wrong version', () => {
  const sj = serverJson();
  sj.packages[1].version = '0.8.2';
  const res = checkVersionSync('0.8.3', sj);
  assert.equal(res.ok, false);
  assert.match(res.problems.join('\n'), /npm package version is "0\.8\.2"/);
});

test('checkVersionSync catches a wrong npm identifier', () => {
  const sj = serverJson();
  sj.packages[1].identifier = 'mac-control';
  const res = checkVersionSync('0.8.3', sj);
  assert.equal(res.ok, false);
  assert.match(res.problems.join('\n'), /identifier is "mac-control"/);
});

test('checkMcpName enforces the registry ownership field', () => {
  assert.deepEqual(checkMcpName({ mcpName: 'io.github.AdelElo13/mac-control-mcp' }, serverJson()), {
    ok: true,
  });
  const res = checkMcpName({}, serverJson());
  assert.equal(res.ok, false);
  assert.match(res.problems.join('\n'), /required by the MCP registry/);
});
