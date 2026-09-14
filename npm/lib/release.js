'use strict';

/**
 * Pure helpers describing where a release lives and how its integrity is
 * checked. Kept free of I/O so the install logic can be unit-tested without
 * touching the network or the filesystem.
 */

const REPO_SLUG = 'AdelElo13/mac-control-mcp';
const RELEASE_BASE = `https://github.com/${REPO_SLUG}/releases/download`;

/** Semver (optionally with a prerelease/build suffix) as used by our tags. */
const VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;

/** Lowercase hex SHA-256 digest. */
const SHA256_RE = /^[a-f0-9]{64}$/;

/**
 * @param {string} version e.g. "0.8.3"
 * @returns {string} the release tag, e.g. "v0.8.3"
 */
function releaseTag(version) {
  assertVersion(version);
  return `v${version}`;
}

/**
 * @param {string} version
 * @returns {string} the tarball asset filename
 */
function tarballName(version) {
  assertVersion(version);
  return `MacControlMCP-v${version}-macos-universal.tar.gz`;
}

/**
 * @param {string} version
 * @returns {string} the checksum asset filename
 */
function sha256Name(version) {
  return `${tarballName(version).replace(/\.tar\.gz$/, '')}.sha256`;
}

/**
 * Build every URL the installer needs for a given version.
 *
 * @param {string} version
 * @returns {{tag: string, tarballName: string, sha256Name: string, tarballUrl: string, sha256Url: string}}
 */
function releaseUrls(version) {
  const tag = releaseTag(version);
  const tar = tarballName(version);
  const sha = sha256Name(version);
  return {
    tag,
    tarballName: tar,
    sha256Name: sha,
    tarballUrl: `${RELEASE_BASE}/${tag}/${tar}`,
    sha256Url: `${RELEASE_BASE}/${tag}/${sha}`,
  };
}

function assertVersion(version) {
  if (typeof version !== 'string' || !VERSION_RE.test(version)) {
    throw new Error(`Invalid version: ${JSON.stringify(version)}`);
  }
}

/**
 * Parse a `shasum -a 256` style checksum file.
 *
 * Format is `<64 hex chars><whitespace>[*]<filename>`, one entry per line.
 * When `expectedName` is given the matching line is required, so a checksum
 * file that covers several assets cannot be confused for the wrong one.
 *
 * @param {string} text contents of the `.sha256` asset
 * @param {string} [expectedName] filename the digest must belong to
 * @returns {string} lowercase hex digest
 */
function parseSha256File(text, expectedName) {
  if (typeof text !== 'string' || text.trim() === '') {
    throw new Error('Checksum file is empty.');
  }
  const entries = [];
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (line === '' || line.startsWith('#')) continue;
    const m = /^([a-fA-F0-9]{64})\s+\*?(.+)$/.exec(line);
    if (!m) {
      // Some publishers emit a bare digest with no filename.
      const bare = /^([a-fA-F0-9]{64})$/.exec(line);
      if (bare) {
        entries.push({ digest: bare[1].toLowerCase(), name: null });
        continue;
      }
      throw new Error(`Malformed checksum line: ${JSON.stringify(rawLine)}`);
    }
    entries.push({ digest: m[1].toLowerCase(), name: m[2].trim() });
  }
  if (entries.length === 0) {
    throw new Error('Checksum file contained no digest.');
  }
  if (!expectedName) return entries[0].digest;

  const base = expectedName.split('/').pop();
  const hit = entries.find((e) => e.name === null || e.name.split('/').pop() === base);
  if (!hit) {
    throw new Error(
      `Checksum file has no entry for ${base} (found: ${entries
        .map((e) => e.name ?? '<unnamed>')
        .join(', ')}).`,
    );
  }
  return hit.digest;
}

/**
 * Digest comparison. Both sides are normalised to lowercase and validated, so
 * a truncated or non-hex value is a hard error rather than an accidental match.
 *
 * @param {string} actual
 * @param {string} expected
 * @returns {boolean}
 */
function digestsMatch(actual, expected) {
  const a = String(actual).trim().toLowerCase();
  const b = String(expected).trim().toLowerCase();
  if (!SHA256_RE.test(a)) throw new Error(`Computed digest is not a SHA-256 hex string: ${actual}`);
  if (!SHA256_RE.test(b)) throw new Error(`Expected digest is not a SHA-256 hex string: ${expected}`);
  return a === b;
}

/**
 * Decide whether an error hit while downloading is worth one retry.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
function isTransientError(err) {
  if (!err) return false;
  const code = /** @type {any} */ (err).code;
  if (
    [
      'ECONNRESET',
      'ECONNREFUSED',
      'ETIMEDOUT',
      'EAI_AGAIN',
      'ENOTFOUND',
      'EPIPE',
      'ENETUNREACH',
      'EHOSTUNREACH',
      'ERR_STREAM_PREMATURE_CLOSE',
    ].includes(code)
  ) {
    return true;
  }
  const status = /** @type {any} */ (err).statusCode;
  if (typeof status === 'number' && (status === 408 || status === 429 || status >= 500)) {
    return true;
  }
  return false;
}

module.exports = {
  REPO_SLUG,
  RELEASE_BASE,
  SHA256_RE,
  VERSION_RE,
  releaseTag,
  tarballName,
  sha256Name,
  releaseUrls,
  parseSha256File,
  digestsMatch,
  isTransientError,
};
