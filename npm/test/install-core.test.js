'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  EXPECTED_BUNDLE_ID,
  APP_BUNDLE_NAME,
  BINARY_REL_PATH,
  assertBundleIdentity,
  readBundleIdentity,
  needsInstall,
  atomicSwap,
  promoteStagedBundle,
  makeStagingDir,
  cleanStagingLeftovers,
} = require('../lib/install-core');

/** Build a throwaway .app that looks real enough for everything but codesign. */
function makeFakeBundle(appPath, { bundleId = EXPECTED_BUNDLE_ID, version = '0.9.0', marker } = {}) {
  fs.mkdirSync(path.join(appPath, 'Contents', 'MacOS'), { recursive: true });
  fs.writeFileSync(
    path.join(appPath, 'Contents', 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
</dict></plist>
`,
  );
  fs.writeFileSync(path.join(appPath, BINARY_REL_PATH), marker ?? `binary-${version}`);
  return appPath;
}

function tmpdir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcmcp-install-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('readBundleIdentity reads the two pinned Info.plist fields', (t) => {
  const dir = tmpdir(t);
  const app = makeFakeBundle(path.join(dir, APP_BUNDLE_NAME), { version: '0.8.3' });
  assert.deepEqual(readBundleIdentity(app), {
    bundleId: EXPECTED_BUNDLE_ID,
    version: '0.8.3',
  });
});

test('assertBundleIdentity pins the bundle id and the version', (t) => {
  const dir = tmpdir(t);
  const good = makeFakeBundle(path.join(dir, 'good.app'), { version: '0.9.0' });
  assert.doesNotThrow(() => assertBundleIdentity(good, '0.9.0'));

  assert.throws(() => assertBundleIdentity(good, '0.8.3'), /Bundle version mismatch/);

  const impostor = makeFakeBundle(path.join(dir, 'impostor.app'), {
    bundleId: 'com.evil.server',
    version: '0.9.0',
  });
  assert.throws(() => assertBundleIdentity(impostor, '0.9.0'), /Bundle identifier mismatch/);
});

test('atomicSwap replaces the destination and removes the old bundle', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  makeFakeBundle(appPath, { version: '0.8.3', marker: 'OLD' });

  const staging = makeStagingDir(vendor);
  makeFakeBundle(path.join(staging, APP_BUNDLE_NAME), { version: '0.9.0', marker: 'NEW' });

  atomicSwap(path.join(staging, APP_BUNDLE_NAME), appPath);

  assert.equal(fs.readFileSync(path.join(appPath, BINARY_REL_PATH), 'utf8'), 'NEW');
  // No `.MacControlMCP.app.old-*` residue left behind.
  assert.deepEqual(
    fs.readdirSync(vendor).filter((n) => n.includes('.old-')),
    [],
  );
});

test('a failing verifier leaves the installed bundle byte-for-byte untouched', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  makeFakeBundle(appPath, { version: '0.8.3', marker: 'GOOD-INSTALLED' });

  const staging = makeStagingDir(vendor);
  makeFakeBundle(path.join(staging, APP_BUNDLE_NAME), { version: '0.9.0', marker: 'UNVERIFIED' });

  let sawStagedPath = null;
  assert.throws(
    () =>
      promoteStagedBundle({
        stagingDir: staging,
        appPath,
        expectedVersion: '0.9.0',
        verify: (p) => {
          sawStagedPath = p;
          throw new Error('spctl --assess --type execute failed (exit 3)');
        },
      }),
    /spctl --assess/,
  );

  // The verifier ran against staging, never against the live path.
  assert.equal(sawStagedPath, path.join(staging, APP_BUNDLE_NAME));
  // And the previously installed, previously verified bundle is still there.
  assert.equal(fs.readFileSync(path.join(appPath, BINARY_REL_PATH), 'utf8'), 'GOOD-INSTALLED');
  assert.equal(readBundleIdentity(appPath).version, '0.8.3');

  fs.rmSync(staging, { recursive: true, force: true });
  assert.equal(fs.existsSync(appPath), true);
});

test('a failing verifier with no prior install leaves nothing behind', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);

  const staging = makeStagingDir(vendor);
  makeFakeBundle(path.join(staging, APP_BUNDLE_NAME), { version: '0.9.0' });

  assert.throws(
    () =>
      promoteStagedBundle({
        stagingDir: staging,
        appPath,
        expectedVersion: '0.9.0',
        verify: () => {
          throw new Error('Signing team mismatch');
        },
      }),
    /Signing team mismatch/,
  );

  fs.rmSync(staging, { recursive: true, force: true });
  assert.equal(fs.existsSync(appPath), false, 'final path must not hold an unverified bundle');
});

test('promoteStagedBundle installs the bundle when verification passes', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  makeFakeBundle(appPath, { version: '0.8.3', marker: 'OLD' });

  const staging = makeStagingDir(vendor);
  makeFakeBundle(path.join(staging, APP_BUNDLE_NAME), { version: '0.9.0', marker: 'NEW' });

  const calls = [];
  promoteStagedBundle({
    stagingDir: staging,
    appPath,
    expectedVersion: '0.9.0',
    verify: (p, v) => calls.push([p, v]),
  });

  assert.equal(calls.length, 1);
  assert.equal(fs.readFileSync(path.join(appPath, BINARY_REL_PATH), 'utf8'), 'NEW');
  assert.equal(readBundleIdentity(appPath).version, '0.9.0');
});

test('promoteStagedBundle refuses a staging dir with no .app in it', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const staging = makeStagingDir(vendor);
  assert.throws(
    () =>
      promoteStagedBundle({
        stagingDir: staging,
        appPath: path.join(vendor, APP_BUNDLE_NAME),
        expectedVersion: '0.9.0',
        verify: () => {},
      }),
    /did not contain MacControlMCP\.app/,
  );
});

// --- the fast path must never trust a leftover -------------------------------

test('needsInstall skips work only when the installed bundle re-verifies', (t) => {
  const dir = tmpdir(t);
  const appPath = path.join(dir, 'vendor', APP_BUNDLE_NAME);
  makeFakeBundle(appPath, { version: '0.9.0' });

  const ok = needsInstall({ appPath, expectedVersion: '0.9.0', verify: () => {} });
  assert.deepEqual(ok.install, false);
  assert.match(ok.reason, /already installed/);
});

test('needsInstall reinstalls a corrupted leftover that a version check alone would accept', (t) => {
  const dir = tmpdir(t);
  const appPath = path.join(dir, 'vendor', APP_BUNDLE_NAME);
  // Exactly the state the old installer could leave behind: right version
  // string, binary present, but the signature does not verify.
  makeFakeBundle(appPath, { version: '0.9.0', marker: 'TAMPERED' });

  const state = needsInstall({
    appPath,
    expectedVersion: '0.9.0',
    verify: () => {
      throw new Error('codesign --verify failed (exit 1)\na sealed resource is missing or invalid');
    },
  });

  assert.equal(state.install, true);
  assert.match(state.reason, /failed re-verification/);
  assert.match(state.reason, /codesign --verify failed/);
  // Only the first line of the verifier's message leaks into the reason.
  assert.equal(state.reason.includes('\n'), false);
});

test('needsInstall reinstalls when the leftover is the wrong version or wrong app', (t) => {
  const dir = tmpdir(t);

  const stale = path.join(dir, 'stale', APP_BUNDLE_NAME);
  makeFakeBundle(stale, { version: '0.8.3' });
  assert.equal(
    needsInstall({
      appPath: stale,
      expectedVersion: '0.9.0',
      verify: (p, v) => assertBundleIdentity(p, v),
    }).install,
    true,
  );

  const impostor = path.join(dir, 'impostor', APP_BUNDLE_NAME);
  makeFakeBundle(impostor, { bundleId: 'com.evil.server', version: '0.9.0' });
  assert.equal(
    needsInstall({
      appPath: impostor,
      expectedVersion: '0.9.0',
      verify: (p, v) => assertBundleIdentity(p, v),
    }).install,
    true,
  );
});

test('needsInstall installs when there is nothing on disk', (t) => {
  const dir = tmpdir(t);
  const state = needsInstall({
    appPath: path.join(dir, 'vendor', APP_BUNDLE_NAME),
    expectedVersion: '0.9.0',
    verify: () => {},
  });
  assert.deepEqual(state, { install: true, reason: 'no bundle installed' });
});

test('cleanStagingLeftovers removes interrupted staging dirs and swap backups', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  makeFakeBundle(appPath, { version: '0.9.0', marker: 'KEEP' });

  const staging = makeStagingDir(vendor);
  fs.mkdirSync(path.join(vendor, '.MacControlMCP.app.old-123-456'), { recursive: true });

  cleanStagingLeftovers(vendor);

  assert.equal(fs.existsSync(staging), false);
  assert.equal(fs.existsSync(path.join(vendor, '.MacControlMCP.app.old-123-456')), false);
  // The real install is untouched.
  assert.equal(fs.readFileSync(path.join(appPath, BINARY_REL_PATH), 'utf8'), 'KEEP');
});

test('makeStagingDir stages inside the vendor dir so promotion is a rename', (t) => {
  const dir = tmpdir(t);
  const vendor = path.join(dir, 'vendor');
  const staging = makeStagingDir(vendor);
  assert.equal(path.dirname(staging), vendor);
  assert.match(path.basename(staging), /^\.staging-/);
});
