#!/usr/bin/env node
'use strict';

/**
 * postinstall: fetch the notarized MacControlMCP.app for this package version.
 *
 * Design constraints:
 *  - Zero runtime dependencies. Everything is node: built-ins plus the macOS
 *    system `tar`, `codesign` and `spctl` binaries, which are always present.
 *  - The .app is extracted verbatim and never rewritten. Touching any file
 *    inside a signed bundle invalidates the Developer ID signature, which
 *    would break notarization and force TCC to re-prompt on every launch.
 *  - The tarball is checked against the published `.sha256` asset before a
 *    single byte is extracted. Note what that does and does not buy: both
 *    assets come from the same GitHub release, so the checksum only proves
 *    the bytes arrived uncorrupted, not that they are what the maintainer
 *    built. The actual trust anchor is the signature check, which pins our
 *    Team ID — an attacker who could replace release assets still cannot
 *    produce a bundle signed by our Developer ID team.
 *  - Nothing unverified ever occupies the final path. Download and extraction
 *    happen in a staging directory alongside the destination; codesign, spctl,
 *    Team ID, bundle identifier and version are all checked *there*; only then
 *    is the bundle renamed into place. Any failure leaves the previously
 *    installed, previously verified bundle untouched.
 *  - The "already installed" fast path re-runs the cheap checks rather than
 *    trusting a leftover: a bundle that exists is not a bundle that passed.
 *
 * Testing hook: MAC_CONTROL_MCP_TEST_VERSION pins the release version to
 * download, so a package whose own release assets are not published yet can be
 * exercised against an existing release. It never changes what gets verified —
 * the bundle's CFBundleShortVersionString must equal whatever version is used.
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const {
  releaseUrls,
  parseSha256File,
  digestsMatch,
  isTransientError,
  assertSafeArchivePaths,
  assertSafeArchiveLinks,
  EXPECTED_TEAM_ID,
} = require('../lib/release');
const { openStream, fetchText } = require('../lib/download');
const { VENDOR_DIR, APP_PATH } = require('../lib/paths');
const {
  EXPECTED_BUNDLE_ID,
  run,
  runOrThrow,
  needsInstall,
  promoteStagedBundle,
  makeStagingDir,
  cleanStagingLeftovers,
} = require('../lib/install-core');

const pkg = require('../package.json');

function log(msg) {
  process.stdout.write(`mac-control-mcp: ${msg}\n`);
}

function warn(msg) {
  process.stderr.write(`mac-control-mcp: ${msg}\n`);
}

function manualFallback(version, urls) {
  return [
    '',
    'Manual install fallback:',
    `  1. Download ${urls.tarballUrl}`,
    `  2. Verify it against ${urls.sha256Url}:`,
    `       shasum -a 256 ${urls.tarballName}`,
    '  3. Extract it and move MacControlMCP.app wherever you like:',
    `       tar -xzf ${urls.tarballName}`,
    '  4. Point your MCP client at the binary directly:',
    '       <path>/MacControlMCP.app/Contents/MacOS/MacControlMCP',
    '',
    `Release page: https://github.com/AdelElo13/mac-control-mcp/releases/tag/v${version}`,
    '',
    'To skip this download entirely (CI, sandboxed builds), set',
    '  MAC_CONTROL_MCP_SKIP_DOWNLOAD=1',
  ].join('\n');
}

/**
 * Stream a URL to disk while hashing it in one pass.
 *
 * @param {string} url
 * @param {string} destPath
 * @returns {Promise<string>} lowercase hex sha256 of the downloaded bytes
 */
async function downloadAndHash(url, destPath) {
  const res = await openStream(url);
  const hash = crypto.createHash('sha256');
  // Hash inside the pipeline rather than via a 'data' listener, so no chunk
  // can be observed by one consumer and missed by the other.
  const tap = new Transform({
    transform(chunk, _enc, cb) {
      hash.update(chunk);
      cb(null, chunk);
    },
  });
  await pipeline(res, tap, fs.createWriteStream(destPath));
  return hash.digest('hex');
}

/**
 * macOS attaches com.apple.quarantine to anything downloaded by a browser or
 * a network client. On the *archive* it is harmless, but it propagates to the
 * extracted bundle and then Gatekeeper puts up a blocking dialog the first
 * time a headless MCP host tries to launch the binary — with no UI to click.
 *
 * We therefore clear the xattr on the downloaded archive only, before
 * extraction. The .app's own contents are never modified, so its Developer ID
 * signature and notarization ticket stay intact and are re-verified below.
 */
function clearQuarantine(archivePath) {
  const res = run('/usr/bin/xattr', ['-d', 'com.apple.quarantine', archivePath]);
  // Exit code 1 simply means the attribute was not set — not an error.
  if (res.status !== 0 && res.status !== 1) {
    warn(
      `could not clear quarantine xattr (exit ${res.status}): ${(res.stderr || '').trim()} — continuing.`,
    );
  }
}

/**
 * Inspect the archive's table of contents before writing anything to disk.
 *
 * The checksum proves we got the advertised bytes; it does not prove those
 * bytes are harmless. This is the one step where a hostile archive could
 * touch paths outside the package, so it is checked explicitly rather than
 * left to whatever containment the system tar happens to implement.
 */
function assertArchiveIsContained(archivePath) {
  const plain = runOrThrow('/usr/bin/tar', ['-tzf', archivePath], 'tar -tzf (listing archive)');
  const verbose = runOrThrow(
    '/usr/bin/tar',
    ['-tvzf', archivePath],
    'tar -tvzf (listing archive)',
  );
  assertSafeArchivePaths((plain.stdout || '').split('\n'));
  assertSafeArchiveLinks((verbose.stdout || '').split('\n'));
}

/**
 * One full download → verify → promote cycle inside a fresh staging directory.
 *
 * @param {string} version
 * @param {ReturnType<typeof releaseUrls>} urls
 */
async function attemptInstall(version, urls) {
  const stagingDir = makeStagingDir(VENDOR_DIR);
  try {
    const archivePath = path.join(stagingDir, urls.tarballName);

    log(`fetching checksum ${urls.sha256Name}`);
    const expected = parseSha256File(await fetchText(urls.sha256Url), urls.tarballName);

    log(`downloading ${urls.tarballName}`);
    const actual = await downloadAndHash(urls.tarballUrl, archivePath);

    if (!digestsMatch(actual, expected)) {
      throw new Error(
        [
          'SHA-256 mismatch — refusing to install.',
          `  expected: ${expected}`,
          `  actual:   ${actual}`,
          `  url:      ${urls.tarballUrl}`,
          '',
          'This means the download was corrupted or tampered with. Do not use it.',
        ].join('\n'),
      );
    }
    log(`checksum verified (${expected.slice(0, 12)}…)`);

    clearQuarantine(archivePath);

    assertArchiveIsContained(archivePath);
    log('archive contents verified (no absolute, parent-directory, symlink or hardlink entries)');

    // System tar preserves extended attributes and the _CodeSignature
    // directory byte for byte; no file inside the bundle is rewritten.
    runOrThrow('/usr/bin/tar', ['-xzf', archivePath, '-C', stagingDir], 'tar -xzf');
    fs.rmSync(archivePath, { force: true });

    // Verifies in staging and only then renames into place. A throw here
    // leaves whatever was installed before exactly where it was.
    promoteStagedBundle({ stagingDir, appPath: APP_PATH, expectedVersion: version });
    log(
      `signature verified in staging (codesign --verify --deep --strict, spctl --assess, team ${EXPECTED_TEAM_ID}, bundle id ${EXPECTED_BUNDLE_ID}, version ${version}) — promoted atomically`,
    );
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }
}

async function main() {
  if (process.env.MAC_CONTROL_MCP_SKIP_DOWNLOAD === '1') {
    log('MAC_CONTROL_MCP_SKIP_DOWNLOAD=1 — skipping binary download.');
    return;
  }

  if (process.platform !== 'darwin') {
    warn(`platform is ${process.platform}; MacControlMCP.app only runs on macOS. Skipping download.`);
    return;
  }

  const pinned = process.env.MAC_CONTROL_MCP_TEST_VERSION;
  const version = pinned && pinned.trim() !== '' ? pinned.trim() : pkg.version;
  if (version !== pkg.version) {
    warn(`MAC_CONTROL_MCP_TEST_VERSION=${version} — installing that release instead of ${pkg.version}.`);
  }

  // releaseUrls() validates the version string, so a hostile env var cannot
  // steer the download at an arbitrary path.
  const urls = releaseUrls(version);

  cleanStagingLeftovers(VENDOR_DIR);

  const state = needsInstall({ appPath: APP_PATH, expectedVersion: version });
  if (!state.install) {
    log(`MacControlMCP.app ${version} already installed and re-verified — nothing to do.`);
    return;
  }
  log(`installing: ${state.reason}`);

  try {
    try {
      await attemptInstall(version, urls);
    } catch (err) {
      if (!isTransientError(err)) throw err;
      warn(`transient failure (${err.message}); retrying once…`);
      await attemptInstall(version, urls);
    }
  } catch (err) {
    process.exitCode = 1;
    process.stderr.write(
      `\nmac-control-mcp: installation failed.\n\n${err && err.message ? err.message : err}\n${manualFallback(version, urls)}\n`,
    );
    return;
  }

  log(`installed MacControlMCP.app ${version}`);
  log(`app path: ${APP_PATH}`);
  log('macOS permissions (Accessibility, Screen Recording, Apple Events) are granted');
  log('to the MCP host application that launches this server, on first tool call.');
}

main().catch((err) => {
  process.exitCode = 1;
  process.stderr.write(`mac-control-mcp: unexpected installer error\n${err && err.stack ? err.stack : err}\n`);
});
