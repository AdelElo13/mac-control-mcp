'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { parseArgs, HELP_TEXT, missingBundleMessage } = require('../lib/cli');
const { readPlistString, installedVersion, isInstalled, APP_PATH } = require('../lib/paths');

const BIN = path.resolve(__dirname, '..', 'bin', 'mac-control-mcp.js');
const PKG = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', 'package.json'), 'utf8'));

test('parseArgs intercepts only the standalone informational flags', () => {
  assert.deepEqual(parseArgs(['--version']).mode, 'version');
  assert.deepEqual(parseArgs(['-v']).mode, 'version');
  assert.deepEqual(parseArgs(['--app-path']).mode, 'app-path');
  assert.deepEqual(parseArgs(['--help']).mode, 'help');
  assert.deepEqual(parseArgs(['-h']).mode, 'help');
});

test('parseArgs forwards everything else to the binary', () => {
  assert.deepEqual(parseArgs([]), { mode: 'run', args: [] });
  assert.deepEqual(parseArgs(['--serve']), { mode: 'run', args: ['--serve'] });
  // Combined flags must not be swallowed by the wrapper.
  assert.deepEqual(parseArgs(['--version', '--json']).mode, 'run');
  assert.deepEqual(parseArgs(['--app-path', 'extra']).mode, 'run');
});

test('parseArgs tolerates a non-array argv', () => {
  assert.deepEqual(parseArgs(undefined), { mode: 'run', args: [] });
});

test('missingBundleMessage tells the user exactly how to recover', () => {
  const msg = missingBundleMessage('/x/MacControlMCP.app', '0.8.3');
  assert.match(msg, /npm rebuild mac-control-mcp/);
  assert.match(msg, /releases\/tag\/v0\.8\.3/);
  assert.match(msg, /\/x\/MacControlMCP\.app/);
});

test('readPlistString extracts a version from an Info.plist', () => {
  const xml = `<?xml version="1.0"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.canopylabs.MacControlMCP</string>
  <key>CFBundleShortVersionString</key><string>0.8.3</string>
</dict></plist>`;
  assert.equal(readPlistString(xml, 'CFBundleShortVersionString'), '0.8.3');
  assert.equal(readPlistString(xml, 'CFBundleIdentifier'), 'com.canopylabs.MacControlMCP');
  assert.equal(readPlistString(xml, 'NoSuchKey'), null);
  assert.equal(readPlistString(null, 'CFBundleShortVersionString'), null);
});

test('installedVersion and isInstalled degrade gracefully when the bundle is absent', () => {
  const missing = path.join(os.tmpdir(), 'definitely-not-here', 'Info.plist');
  assert.equal(installedVersion(missing), null);
  assert.equal(isInstalled(path.join(os.tmpdir(), 'definitely-not-here', 'MacControlMCP')), false);
});

test('bin --help prints usage and exits 0 without touching the bundle', () => {
  const res = spawnSync(process.execPath, [BIN, '--help'], { encoding: 'utf8' });
  assert.equal(res.status, 0);
  assert.equal(res.stdout, `${HELP_TEXT}\n`);
});

test('bin --app-path prints the bundle path and exits 0 even when not installed', () => {
  const res = spawnSync(process.execPath, [BIN, '--app-path'], { encoding: 'utf8' });
  assert.equal(res.status, 0);
  assert.equal(res.stdout.trim(), APP_PATH);
});

test('bin --version prints a version and exits 0', () => {
  const res = spawnSync(process.execPath, [BIN, '--version'], { encoding: 'utf8' });
  assert.equal(res.status, 0);
  assert.match(res.stdout.trim(), /^\d+\.\d+\.\d+/);
  if (!isInstalled()) {
    // With no bundle on disk the launcher falls back to the package version.
    assert.equal(res.stdout.trim(), PKG.version);
  }
});

test('bin exits 1 with recovery instructions when the bundle is missing', (t) => {
  if (isInstalled()) {
    t.skip('bundle is installed in this checkout; missing-bundle path not exercised');
    return;
  }
  const res = spawnSync(process.execPath, [BIN], { encoding: 'utf8' });
  assert.equal(res.status, 1);
  assert.match(res.stderr, /is not installed/);
  assert.match(res.stderr, /npm rebuild mac-control-mcp/);
});
