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
 *  - Integrity is checked against the published `.sha256` asset before a
 *    single byte is extracted, and the extracted bundle is then re-verified
 *    against the system's own signature and Gatekeeper policy.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { spawnSync } = require('node:child_process');

const { releaseUrls, parseSha256File, digestsMatch, isTransientError } = require('../lib/release');
const { openStream, fetchText } = require('../lib/download');
const { VENDOR_DIR, APP_PATH, BINARY_PATH, installedVersion } = require('../lib/paths');

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
 * Run a system tool without a shell. Returns the result rather than throwing
 * so callers can attach their own diagnostics.
 *
 * @param {string} file
 * @param {string[]} args
 */
function run(file, args) {
  return spawnSync(file, args, { encoding: 'utf8' });
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
  if (res.status !== 0 && res.status !== 1 && res.error) {
    warn(`could not clear quarantine xattr (${res.error.message}); continuing.`);
  }
}

/**
 * Verify the extracted bundle is the genuine signed+notarized artifact.
 * A checksum proves we got the bytes we asked for; this proves those bytes
 * are Apple-notarized and were not tampered with in the extraction step.
 */
function verifySignature() {
  const codesign = run('/usr/bin/codesign', ['--verify', '--deep', '--strict', APP_PATH]);
  if (codesign.status !== 0) {
    throw new Error(
      `codesign --verify --deep --strict failed for ${APP_PATH}\n${(codesign.stderr || '').trim()}`,
    );
  }
  const spctl = run('/usr/sbin/spctl', ['--assess', '--type', 'execute', APP_PATH]);
  if (spctl.status !== 0) {
    throw new Error(
      `spctl --assess --type execute failed for ${APP_PATH}\n${(spctl.stderr || '').trim()}`,
    );
  }
}

async function attemptInstall(version, urls, tmpDir) {
  const archivePath = path.join(tmpDir, urls.tarballName);

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

  fs.rmSync(APP_PATH, { recursive: true, force: true });
  fs.mkdirSync(VENDOR_DIR, { recursive: true });

  // System tar preserves extended attributes and the _CodeSignature
  // directory byte for byte; no file inside the bundle is rewritten.
  const untar = run('/usr/bin/tar', ['-xzf', archivePath, '-C', VENDOR_DIR]);
  if (untar.status !== 0) {
    throw new Error(`tar -xzf failed (exit ${untar.status})\n${(untar.stderr || '').trim()}`);
  }

  if (!fs.existsSync(BINARY_PATH)) {
    throw new Error(`archive did not contain ${path.relative(VENDOR_DIR, BINARY_PATH)}`);
  }

  verifySignature();
  log('signature verified (codesign --verify --deep --strict, spctl --assess)');
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

  const version = pkg.version;
  const urls = releaseUrls(version);

  if (installedVersion() === version && fs.existsSync(BINARY_PATH)) {
    log(`MacControlMCP.app ${version} already installed — nothing to do.`);
    return;
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mac-control-mcp-'));
  try {
    try {
      await attemptInstall(version, urls, tmpDir);
    } catch (err) {
      if (!isTransientError(err)) throw err;
      warn(`transient failure (${err.message}); retrying once…`);
      await attemptInstall(version, urls, tmpDir);
    }
  } catch (err) {
    process.exitCode = 1;
    process.stderr.write(
      `\nmac-control-mcp: installation failed.\n\n${err && err.message ? err.message : err}\n${manualFallback(version, urls)}\n`,
    );
    return;
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  const installed = installedVersion() ?? version;
  log(`installed MacControlMCP.app ${installed}`);
  log(`app path: ${APP_PATH}`);
  log('macOS permissions (Accessibility, Screen Recording, Apple Events) are granted');
  log('to the MCP host application that launches this server, on first tool call.');
}

main().catch((err) => {
  process.exitCode = 1;
  process.stderr.write(`mac-control-mcp: unexpected installer error\n${err && err.stack ? err.stack : err}\n`);
});
