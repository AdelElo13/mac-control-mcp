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
 * Apple Team ID of the only identity allowed to sign what we install.
 *
 * `codesign --verify` proves the bundle is intact and `spctl --assess` proves
 * Gatekeeper is satisfied, but both are happy with *any* valid Developer ID —
 * including an attacker's own notarized account. Pinning the team makes those
 * checks assert authorship, not just validity.
 */
const EXPECTED_TEAM_ID = 'A3W973JZ49';

/** Top-level directory every archive entry must live under. */
const ARCHIVE_ROOT = 'MacControlMCP.app';

/**
 * Reject a "tar slip" archive before extracting it.
 *
 * The checksum only proves we received the bytes the release advertises; it
 * says nothing about what those bytes contain. An archive carrying absolute
 * paths or `../` segments would write outside the package directory, so the
 * listing is validated first and extraction only happens if every entry stays
 * inside the expected bundle.
 *
 * @param {string[]} paths output lines of `tar -tzf`
 * @param {string} [root]
 * @returns {string[]} the validated paths
 */
function assertSafeArchivePaths(paths, root = ARCHIVE_ROOT) {
  const entries = paths.map((p) => p.trim()).filter((p) => p !== '');
  if (entries.length === 0) throw new Error('Archive listing is empty.');

  for (const entry of entries) {
    if (entry.startsWith('/') || /^[A-Za-z]:[\\/]/.test(entry)) {
      throw new Error(`Refusing archive: absolute path entry ${JSON.stringify(entry)}`);
    }
    const segments = entry.split('/');
    if (segments.includes('..')) {
      throw new Error(`Refusing archive: parent-directory entry ${JSON.stringify(entry)}`);
    }
    if (segments[0] !== root) {
      throw new Error(
        `Refusing archive: entry ${JSON.stringify(entry)} is outside ${root}/`,
      );
    }
  }
  return entries;
}

/**
 * First column of a `tar -tv` line: the type flag plus the nine permission
 * bits, optionally followed by an xattr (`@`) / ACL (`+`) / MAC-label (`.`)
 * marker. BSD tar on macOS prints `l` for a symlink and `h` for a hardlink;
 * `b`/`c`/`p`/`s` are device, FIFO and socket members.
 */
const TAR_MODE_RE = /^([-dlhbcpsL])([rwxsStT-]{9})[@+.]?(?:\s|$)/;

/** Type flags a legitimate .app bundle listing may contain. */
const ALLOWED_TYPE_FLAGS = new Set(['-', 'd']);

/**
 * Reject every link member in the archive before a byte is extracted.
 *
 * A symlink is the other half of the tar-slip trick: the path stays innocent
 * while the target points at `/` or climbs out with `..`. A hardlink is the
 * quieter variant — `tar -tv` prints it as `h... a/b link to a/c`, the old
 * ` -> ` scan never saw it, and on extraction it can be aimed at a file that a
 * later member then rewrites in place. Device, FIFO and socket members are
 * refused for the same reason: nothing in a signed .app needs them.
 *
 * The real bundle contains only directories and regular files, so this is a
 * whitelist rather than a target-sanitising exercise: any link member at all
 * means the archive is not the artifact we published, and it is rejected as a
 * whole. Path containment itself is enforced separately by
 * {@link assertSafeArchivePaths} over the `tar -tzf` listing, which sees every
 * member name without the ambiguity of parsing verbose columns.
 *
 * @param {string[]} verboseLines output lines of `tar -tvzf`
 */
function assertSafeArchiveLinks(verboseLines) {
  for (const raw of verboseLines) {
    const line = String(raw).replace(/\r$/, '');
    if (line.trim() === '') continue;

    const m = TAR_MODE_RE.exec(line);
    const typeFlag = m ? m[1] : null;

    if (typeFlag === 'l' || typeFlag === 'L') {
      throw new Error(`Refusing archive: symlink entry ${JSON.stringify(line.trim())}`);
    }
    if (typeFlag === 'h') {
      throw new Error(`Refusing archive: hardlink entry ${JSON.stringify(line.trim())}`);
    }
    if (typeFlag !== null && !ALLOWED_TYPE_FLAGS.has(typeFlag)) {
      throw new Error(
        `Refusing archive: non-regular member (type ${JSON.stringify(typeFlag)}) ${JSON.stringify(line.trim())}`,
      );
    }

    // Belt and braces for listings whose first column we could not parse (a
    // different tar build, a localised or padded format): the textual markers
    // BSD and GNU tar both emit still give the member away. Fail closed.
    if (line.includes(' -> ')) {
      throw new Error(`Refusing archive: symlink entry ${JSON.stringify(line.trim())}`);
    }
    if (line.includes(' link to ')) {
      throw new Error(`Refusing archive: hardlink entry ${JSON.stringify(line.trim())}`);
    }
  }
}

/**
 * Pull the TeamIdentifier out of `codesign -dv --verbose=4` output.
 *
 * @param {string} output combined stdout+stderr of codesign
 * @returns {string|null}
 */
function parseTeamIdentifier(output) {
  const m = /^TeamIdentifier=(.+)$/m.exec(String(output));
  if (!m) return null;
  const value = m[1].trim();
  return value === '' || value === 'not set' ? null : value;
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
  EXPECTED_TEAM_ID,
  ARCHIVE_ROOT,
  assertSafeArchivePaths,
  assertSafeArchiveLinks,
  parseTeamIdentifier,
  releaseTag,
  tarballName,
  sha256Name,
  releaseUrls,
  parseSha256File,
  digestsMatch,
  isTransientError,
};
