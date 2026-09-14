'use strict';

/**
 * Locate a real, Developer-ID-signed MacControlMCP.app to use as a fixture.
 *
 * The signature / Team ID / Gatekeeper checks cannot be exercised against a
 * fake bundle — codesign needs real CMS blobs — so the tests that cover them
 * look for a genuine notarized build on the machine and skip when none is
 * present. The fixture is only ever *read*: tests copy it into a temp dir
 * before touching it.
 *
 * Search order:
 *   1. $MAC_CONTROL_MCP_TEST_FIXTURE_APP (CI sets this after downloading a
 *      published release)
 *   2. ~/Applications/MacControlMCP.app
 *   3. /Applications/MacControlMCP.app
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { parseTeamIdentifier, EXPECTED_TEAM_ID } = require('../../lib/release');
const { EXPECTED_BUNDLE_ID, readBundleIdentity, BINARY_REL_PATH } = require('../../lib/install-core');

function candidates() {
  const list = [];
  const fromEnv = process.env.MAC_CONTROL_MCP_TEST_FIXTURE_APP;
  if (fromEnv && fromEnv.trim() !== '') list.push(fromEnv.trim());
  list.push(path.join(os.homedir(), 'Applications', 'MacControlMCP.app'));
  list.push('/Applications/MacControlMCP.app');
  return list;
}

/**
 * @param {string} appPath
 * @returns {{ok: true, version: string}|{ok: false, why: string}}
 */
function inspect(appPath) {
  if (!fs.existsSync(path.join(appPath, BINARY_REL_PATH))) {
    return { ok: false, why: 'no binary' };
  }
  let identity;
  try {
    identity = readBundleIdentity(appPath);
  } catch (err) {
    return { ok: false, why: err.message };
  }
  if (identity.bundleId !== EXPECTED_BUNDLE_ID || !identity.version) {
    return { ok: false, why: `bundle id ${identity.bundleId}` };
  }
  const info = spawnSync('/usr/bin/codesign', ['-dv', '--verbose=4', appPath], { encoding: 'utf8' });
  const team = parseTeamIdentifier(`${info.stdout || ''}\n${info.stderr || ''}`);
  if (team !== EXPECTED_TEAM_ID) {
    return { ok: false, why: `team ${team ?? '<none>'}` };
  }
  return { ok: true, version: identity.version };
}

/**
 * @returns {{appPath: string, version: string}|null}
 */
function findFixtureApp() {
  if (process.platform !== 'darwin') return null;
  for (const appPath of candidates()) {
    const res = inspect(appPath);
    if (res.ok) return { appPath, version: res.version };
  }
  return null;
}

/**
 * Copy the fixture bundle to `dest` byte for byte (xattrs and the
 * _CodeSignature seal included) so the copy still verifies.
 *
 * @param {string} srcApp
 * @param {string} destApp
 */
function copyFixtureApp(srcApp, destApp) {
  fs.mkdirSync(path.dirname(destApp), { recursive: true });
  const res = spawnSync('/bin/cp', ['-Rp', srcApp, destApp], { encoding: 'utf8' });
  if (res.status !== 0) throw new Error(`cp -Rp failed: ${res.stderr}`);
}

/**
 * Re-sign a bundle ad hoc. The result has a valid signature (so plain
 * `codesign --verify` passes) but no Team ID — the exact shape a leftover
 * planted at the install path would have.
 *
 * @param {string} appPath
 */
function adHocResign(appPath) {
  const res = spawnSync('/usr/bin/codesign', ['-s', '-', '--force', '--deep', appPath], {
    encoding: 'utf8',
  });
  if (res.status !== 0) throw new Error(`ad-hoc codesign failed: ${res.stderr}`);
}

const FIXTURE = findFixtureApp();

const SKIP_REASON = FIXTURE
  ? false
  : 'no Developer-ID-signed MacControlMCP.app fixture found (set MAC_CONTROL_MCP_TEST_FIXTURE_APP)';

module.exports = { FIXTURE, SKIP_REASON, findFixtureApp, copyFixtureApp, adHocResign };
