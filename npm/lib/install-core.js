'use strict';

/**
 * Staging, verification and atomic promotion of the downloaded .app bundle.
 *
 * The rule this module exists to enforce: **an unverified bundle never occupies
 * the final path, not even for a moment.** The previous flow deleted the
 * installed bundle, extracted the download straight over it and only then ran
 * codesign/spctl — so a failing verification left the rejected bundle sitting
 * at the path the launcher execs, and the next `npm rebuild` skipped every
 * check because an Info.plist version and a binary were present. A single
 * corrupt (or hostile) download therefore became permanently trusted.
 *
 * So: extract into a throwaway staging directory next to the destination,
 * verify there, and only then swap. Every failure path leaves the previously
 * installed, previously verified bundle exactly where it was.
 *
 * The same rule applies on the way *back in*: a bundle already sitting at the
 * final path is re-verified with exactly the checks a fresh download gets
 * (see verifyBundle) and is moved aside the moment any of them fails.
 *
 * Kept separate from scripts/install.js so the promotion and re-check logic can
 * be tested without a network, a notarized bundle, or codesign — every
 * verifier is injectable.
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { parseTeamIdentifier, EXPECTED_TEAM_ID } = require('./release');
const { readPlistString } = require('./paths');

/** Bundle identifier baked into scripts/build-bundle.sh. TCC grants key off it. */
const EXPECTED_BUNDLE_ID = 'dev.macmcp.server';

/** The single top-level directory the release tarball unpacks to. */
const APP_BUNDLE_NAME = 'MacControlMCP.app';

/** Relative path of the stdio server executable inside the bundle. */
const BINARY_REL_PATH = path.join('Contents', 'MacOS', 'MacControlMCP');

/** Relative path of the bundle's Info.plist. */
const INFO_PLIST_REL_PATH = path.join('Contents', 'Info.plist');

/**
 * Run a system tool without a shell. Returns the result rather than throwing
 * so callers can attach their own diagnostics.
 *
 * @param {string} file absolute path to the tool
 * @param {string[]} args
 */
function run(file, args) {
  const res = spawnSync(file, args, { encoding: 'utf8' });
  if (res.error && res.error.code === 'ENOENT') {
    throw new Error(
      `${file} is missing from this system — it is required to install MacControlMCP.app.`,
    );
  }
  return res;
}

/**
 * Same as run(), but turns a non-zero exit into a labelled error.
 *
 * @param {string} file
 * @param {string[]} args
 * @param {string} what human-readable description used in the error
 */
function runOrThrow(file, args, what) {
  const res = run(file, args);
  if (res.status !== 0) {
    throw new Error(
      `${what} failed (exit ${res.status})\n${((res.stderr || '') + (res.stdout || '')).trim()}`,
    );
  }
  return res;
}

/**
 * Read the two identity fields we pin from a bundle's Info.plist.
 *
 * @param {string} appPath
 * @returns {{bundleId: string|null, version: string|null}}
 */
function readBundleIdentity(appPath) {
  const plistPath = path.join(appPath, INFO_PLIST_REL_PATH);
  let xml;
  try {
    xml = fs.readFileSync(plistPath, 'utf8');
  } catch (err) {
    throw new Error(`could not read ${plistPath}: ${err.message}`);
  }
  return {
    bundleId: readPlistString(xml, 'CFBundleIdentifier'),
    version: readPlistString(xml, 'CFBundleShortVersionString'),
  };
}

/**
 * The bundle must be *our* app at *this* package's version.
 *
 * The signature checks prove a bundle is intact and notarized; they say
 * nothing about which app or which version it is. Without this, a release
 * asset accidentally (or deliberately) pointing at a different build would
 * install happily and the launcher would exec it.
 *
 * @param {string} appPath
 * @param {string} expectedVersion
 */
function assertBundleIdentity(appPath, expectedVersion) {
  const { bundleId, version } = readBundleIdentity(appPath);
  if (bundleId !== EXPECTED_BUNDLE_ID) {
    throw new Error(
      [
        `Bundle identifier mismatch — refusing to install ${appPath}`,
        `  expected CFBundleIdentifier: ${EXPECTED_BUNDLE_ID}`,
        `  actual CFBundleIdentifier:   ${bundleId ?? '<none>'}`,
      ].join('\n'),
    );
  }
  if (version !== expectedVersion) {
    throw new Error(
      [
        `Bundle version mismatch — refusing to install ${appPath}`,
        `  expected CFBundleShortVersionString: ${expectedVersion}`,
        `  actual CFBundleShortVersionString:   ${version ?? '<none>'}`,
      ].join('\n'),
    );
  }
}

/**
 * Pin the signing team. `codesign --verify` and `spctl --assess` are satisfied
 * by any valid, notarized Developer ID — an attacker's own account included.
 * Pinning the team makes those checks assert authorship, not just validity.
 *
 * @param {string} appPath
 */
function assertTeamIdentifier(appPath) {
  const info = run('/usr/bin/codesign', ['-dv', '--verbose=4', appPath]);
  const teamId = parseTeamIdentifier(`${info.stdout || ''}\n${info.stderr || ''}`);
  if (teamId !== EXPECTED_TEAM_ID) {
    throw new Error(
      [
        `Signing team mismatch (expected TeamIdentifier ${EXPECTED_TEAM_ID}, got ${teamId ?? '<none>'}) — refusing to install ${appPath}`,
        `  expected TeamIdentifier: ${EXPECTED_TEAM_ID}`,
        `  actual TeamIdentifier:   ${teamId ?? '<none>'}`,
        '',
        'The bundle is signed by someone other than the project owner. Do not use it.',
      ].join('\n'),
    );
  }
}

/**
 * The one set of trust checks a bundle must pass, wherever it sits.
 *
 * Order is cheapest-first so a bad bundle fails fast, and every check names
 * itself in the first line of its error so the caller can say which one
 * rejected the bundle:
 *
 *   1. the stdio binary exists at its pinned relative path
 *   2. `codesign --verify --deep --strict` — the seal is intact
 *   3. TeamIdentifier == {@link EXPECTED_TEAM_ID} — *we* signed it; this is
 *      the trust anchor, since 2 and 5 accept any valid Developer ID
 *   4. CFBundleIdentifier / CFBundleShortVersionString — our app, this version
 *   5. `spctl --assess --type execute` — Gatekeeper (notarization) still
 *      accepts it; runs last because it is by far the slowest (~1-2 s) and
 *      the only one that consults system policy that can change over time
 *      (a revoked notarization ticket)
 *
 * The fresh-download path and the "already installed" fast path both call
 * this. They used to differ — the fast path ran only a shallow `codesign
 * --verify` plus the plist pins, no Team ID and no spctl — which meant a
 * leftover bundle with the right bundle id and version but an ad-hoc or
 * third-party signature was accepted on `npm rebuild`. There is no cheaper
 * check that is also sufficient, so the fast path pays the full price.
 *
 * @param {string} appPath
 * @param {string} expectedVersion
 * @param {string} what "staged" | "installed" — only used in messages
 */
function verifyBundle(appPath, expectedVersion, what) {
  if (!fs.existsSync(path.join(appPath, BINARY_REL_PATH))) {
    throw new Error(`${what} bundle has no ${BINARY_REL_PATH}`);
  }
  runOrThrow(
    '/usr/bin/codesign',
    ['--verify', '--deep', '--strict', appPath],
    'codesign --verify --deep --strict',
  );
  assertTeamIdentifier(appPath);
  assertBundleIdentity(appPath, expectedVersion);
  runOrThrow(
    '/usr/sbin/spctl',
    ['--assess', '--type', 'execute', appPath],
    'spctl --assess --type execute',
  );
}

/**
 * Full verification, run against the *staged* bundle before it is promoted.
 *
 * @param {string} appPath staged bundle
 * @param {string} expectedVersion
 */
function verifyStagedBundle(appPath, expectedVersion) {
  verifyBundle(appPath, expectedVersion, 'staged');
}

/**
 * Re-check of an already-installed bundle. Identical to the staged check —
 * see {@link verifyBundle} for why nothing weaker is acceptable here.
 *
 * @param {string} appPath
 * @param {string} expectedVersion
 */
function verifyInstalledBundle(appPath, expectedVersion) {
  verifyBundle(appPath, expectedVersion, 'installed');
}

/**
 * Move a bundle that failed re-verification out of the launcher's exec path.
 *
 * It is renamed, not deleted, so whoever planted or corrupted it can be
 * investigated: `<name>.rejected-<timestamp>` in the same directory. The
 * rename is atomic, so at no point is a half-removed bundle at the path.
 *
 * @param {string} appPath
 * @returns {string} where the bundle went
 */
function quarantineBundle(appPath) {
  const dest = `${appPath}.rejected-${Date.now()}`;
  fs.renameSync(appPath, dest);
  return dest;
}

/**
 * Decide whether the postinstall has any work to do.
 *
 * A bundle that exists but fails any check is *not* left in place: it is
 * quarantined (see {@link quarantineBundle}) before the fresh download runs,
 * so a failed download cannot leave an untrusted bundle for the launcher.
 *
 * @param {object} o
 * @param {string} o.appPath
 * @param {string} o.expectedVersion
 * @param {(appPath: string, expectedVersion: string) => void} [o.verify]
 *        injectable re-check; defaults to {@link verifyInstalledBundle}
 * @param {boolean} [o.quarantine] move a rejected bundle aside (default true)
 * @returns {{install: boolean, reason: string, failedCheck?: string, quarantinedTo?: string}}
 */
function needsInstall({ appPath, expectedVersion, verify = verifyInstalledBundle, quarantine = true }) {
  if (!fs.existsSync(appPath)) {
    return { install: true, reason: 'no bundle installed' };
  }
  try {
    verify(appPath, expectedVersion);
  } catch (err) {
    const failedCheck = err && err.message ? err.message.split('\n')[0] : String(err);
    const result = {
      install: true,
      reason: `existing bundle failed re-verification (${failedCheck})`,
      failedCheck,
    };
    if (quarantine) result.quarantinedTo = quarantineBundle(appPath);
    return result;
  }
  return { install: false, reason: `verified ${expectedVersion} already installed` };
}

/**
 * Replace `appPath` with `stagedApp` in a way that never leaves the
 * destination holding a half-written bundle.
 *
 * rename(2) within one filesystem is atomic, and staging lives in the same
 * parent directory as the destination precisely so that holds. The old bundle
 * is renamed aside first (not deleted) so a failure in the second rename can
 * put it straight back.
 *
 * @param {string} stagedApp
 * @param {string} appPath
 */
function atomicSwap(stagedApp, appPath) {
  const parent = path.dirname(appPath);
  fs.mkdirSync(parent, { recursive: true });

  const backup = path.join(
    parent,
    `.${path.basename(appPath)}.old-${process.pid}-${Date.now()}`,
  );

  let backedUp = false;
  if (fs.existsSync(appPath)) {
    fs.renameSync(appPath, backup);
    backedUp = true;
  }

  try {
    fs.renameSync(stagedApp, appPath);
  } catch (err) {
    if (backedUp) {
      try {
        fs.renameSync(backup, appPath);
      } catch {
        /* nothing better to do; the original error is the useful one */
      }
    }
    throw err;
  }

  if (backedUp) fs.rmSync(backup, { recursive: true, force: true });
}

/**
 * Verify a staged bundle and, only if it passes, move it into place.
 *
 * On any failure the destination is left untouched — that is the whole point —
 * and the caller is responsible for removing the staging directory.
 *
 * @param {object} o
 * @param {string} o.stagingDir directory the tarball was extracted into
 * @param {string} o.appPath final destination
 * @param {string} o.expectedVersion
 * @param {(appPath: string, expectedVersion: string) => void} [o.verify]
 *        injectable verifier; defaults to {@link verifyStagedBundle}
 * @returns {string} the staged bundle path that was promoted
 */
function promoteStagedBundle({ stagingDir, appPath, expectedVersion, verify = verifyStagedBundle }) {
  const stagedApp = path.join(stagingDir, APP_BUNDLE_NAME);
  if (!fs.existsSync(stagedApp)) {
    throw new Error(`archive did not contain ${APP_BUNDLE_NAME}`);
  }
  verify(stagedApp, expectedVersion);
  atomicSwap(stagedApp, appPath);
  return stagedApp;
}

/**
 * Create a staging directory in the same filesystem as the destination, so the
 * promotion is a rename rather than a copy.
 *
 * @param {string} vendorDir
 * @returns {string}
 */
function makeStagingDir(vendorDir) {
  fs.mkdirSync(vendorDir, { recursive: true });
  return fs.mkdtempSync(path.join(vendorDir, '.staging-'));
}

/**
 * Remove leftovers from a previous interrupted run. Staging dirs and swap
 * backups are dot-prefixed and disposable by construction.
 *
 * @param {string} vendorDir
 */
function cleanStagingLeftovers(vendorDir) {
  let entries;
  try {
    entries = fs.readdirSync(vendorDir);
  } catch {
    return;
  }
  for (const name of entries) {
    if (name.startsWith('.staging-') || /^\..*\.old-/.test(name)) {
      fs.rmSync(path.join(vendorDir, name), { recursive: true, force: true });
    }
  }
}

module.exports = {
  EXPECTED_BUNDLE_ID,
  APP_BUNDLE_NAME,
  BINARY_REL_PATH,
  INFO_PLIST_REL_PATH,
  run,
  runOrThrow,
  readBundleIdentity,
  assertBundleIdentity,
  assertTeamIdentifier,
  verifyBundle,
  verifyStagedBundle,
  verifyInstalledBundle,
  quarantineBundle,
  needsInstall,
  atomicSwap,
  promoteStagedBundle,
  makeStagingDir,
  cleanStagingLeftovers,
};
