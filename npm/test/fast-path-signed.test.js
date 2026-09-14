'use strict';

/**
 * The "already installed" fast path must apply the same trust checks as the
 * fresh download path. These tests run the *real* verifier (no injection)
 * against copies of a genuine notarized bundle, so they need a fixture and
 * skip when none is present — see test/helpers/fixture-app.js.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { APP_BUNDLE_NAME, BINARY_REL_PATH, needsInstall } = require('../lib/install-core');
const { EXPECTED_TEAM_ID } = require('../lib/release');
const { FIXTURE, SKIP_REASON, copyFixtureApp, adHocResign } = require('./helpers/fixture-app');

function tmpdir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcmcp-fastpath-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('fast path: a genuine Developer ID bundle at the install path is trusted', { skip: SKIP_REASON }, (t) => {
  const vendor = path.join(tmpdir(t), 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  copyFixtureApp(FIXTURE.appPath, appPath);

  const state = needsInstall({ appPath, expectedVersion: FIXTURE.version });
  assert.equal(state.install, false, state.reason);
  assert.equal(fs.existsSync(path.join(appPath, BINARY_REL_PATH)), true);
});

test('fast path: an ad-hoc signed leftover with the right plist is NOT trusted', { skip: SKIP_REASON }, (t) => {
  const vendor = path.join(tmpdir(t), 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  copyFixtureApp(FIXTURE.appPath, appPath);
  // Right bundle id, right version, valid (ad-hoc) signature, no Team ID.
  adHocResign(appPath);

  const state = needsInstall({ appPath, expectedVersion: FIXTURE.version });

  assert.equal(state.install, true, 'an ad-hoc signed bundle must trigger a reinstall');
  assert.match(state.reason, /Signing team mismatch/, state.reason);
  assert.match(state.reason, new RegExp(EXPECTED_TEAM_ID));
  // The rejected bundle no longer sits at the path the launcher execs; it was
  // moved aside for inspection, in the same directory.
  assert.equal(fs.existsSync(appPath), false, 'rejected bundle must not stay at the install path');
  assert.equal(typeof state.quarantinedTo, 'string');
  assert.equal(path.dirname(state.quarantinedTo), vendor);
  assert.match(path.basename(state.quarantinedTo), /^MacControlMCP\.app\.rejected-\d+$/);
  assert.equal(fs.existsSync(path.join(state.quarantinedTo, BINARY_REL_PATH)), true);
});

test('fast path: a version-mismatched genuine bundle is quarantined, not trusted', { skip: SKIP_REASON }, (t) => {
  const vendor = path.join(tmpdir(t), 'vendor');
  const appPath = path.join(vendor, APP_BUNDLE_NAME);
  copyFixtureApp(FIXTURE.appPath, appPath);

  const state = needsInstall({ appPath, expectedVersion: '99.99.99' });
  assert.equal(state.install, true);
  assert.match(state.reason, /Bundle version mismatch/);
  assert.equal(fs.existsSync(appPath), false);
  assert.match(path.basename(state.quarantinedTo), /\.rejected-\d+$/);
});
