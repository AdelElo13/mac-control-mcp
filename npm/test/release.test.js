'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const {
  releaseTag,
  tarballName,
  sha256Name,
  releaseUrls,
  parseSha256File,
  digestsMatch,
  isTransientError,
  assertSafeArchivePaths,
  assertSafeArchiveLinks,
  parseTeamIdentifier,
  EXPECTED_TEAM_ID,
} = require('../lib/release');

test('releaseUrls builds the published asset URLs for a version', () => {
  const u = releaseUrls('0.8.3');
  assert.equal(u.tag, 'v0.8.3');
  assert.equal(u.tarballName, 'MacControlMCP-v0.8.3-macos-universal.tar.gz');
  assert.equal(u.sha256Name, 'MacControlMCP-v0.8.3-macos-universal.sha256');
  assert.equal(
    u.tarballUrl,
    'https://github.com/AdelElo13/mac-control-mcp/releases/download/v0.8.3/MacControlMCP-v0.8.3-macos-universal.tar.gz',
  );
  assert.equal(
    u.sha256Url,
    'https://github.com/AdelElo13/mac-control-mcp/releases/download/v0.8.3/MacControlMCP-v0.8.3-macos-universal.sha256',
  );
});

test('releaseUrls handles prerelease versions', () => {
  const u = releaseUrls('0.9.0-rc.1');
  assert.equal(u.tag, 'v0.9.0-rc.1');
  assert.equal(u.tarballName, 'MacControlMCP-v0.9.0-rc.1-macos-universal.tar.gz');
});

test('version helpers reject anything that is not a plain version', () => {
  for (const bad of ['', 'latest', '^1.2.3', 'v1.2.3', '1.2', '../../etc/passwd', null, 42]) {
    assert.throws(() => releaseTag(bad), /Invalid version/, `should reject ${JSON.stringify(bad)}`);
    assert.throws(() => tarballName(bad), /Invalid version/);
    assert.throws(() => sha256Name(bad), /Invalid version/);
  }
});

test('parseSha256File reads the real shasum output format', () => {
  const text =
    'd4ab8c3ffe021f8d7caa841d3fc8e82ae251bafa33f8f73ac343d7fa14c72be4  MacControlMCP-v0.8.3-macos-universal.tar.gz\n';
  assert.equal(
    parseSha256File(text, 'MacControlMCP-v0.8.3-macos-universal.tar.gz'),
    'd4ab8c3ffe021f8d7caa841d3fc8e82ae251bafa33f8f73ac343d7fa14c72be4',
  );
});

test('parseSha256File accepts binary-mode (*) and bare-digest files', () => {
  const digest = 'a'.repeat(64);
  assert.equal(parseSha256File(`${digest} *thing.tar.gz\n`, 'thing.tar.gz'), digest);
  assert.equal(parseSha256File(`${digest}\n`, 'thing.tar.gz'), digest);
});

test('parseSha256File picks the line matching the requested asset', () => {
  const a = 'a'.repeat(64);
  const b = 'b'.repeat(64);
  const text = `${a}  other.tar.gz\n${b}  wanted.tar.gz\n`;
  assert.equal(parseSha256File(text, 'wanted.tar.gz'), b);
});

test('parseSha256File fails loudly when the asset is absent', () => {
  const text = `${'a'.repeat(64)}  other.tar.gz\n`;
  assert.throws(() => parseSha256File(text, 'wanted.tar.gz'), /no entry for wanted.tar.gz/);
});

test('parseSha256File rejects empty and malformed input', () => {
  assert.throws(() => parseSha256File(''), /empty/);
  assert.throws(() => parseSha256File('   \n'), /empty/);
  assert.throws(() => parseSha256File('not a checksum\n'), /Malformed/);
  assert.throws(() => parseSha256File('# only a comment\n'), /no digest/);
});

test('digestsMatch compares a real computed digest against the published one', () => {
  const payload = Buffer.from('MacControlMCP');
  const digest = crypto.createHash('sha256').update(payload).digest('hex');
  assert.equal(digestsMatch(digest, digest), true);
  assert.equal(digestsMatch(digest, digest.toUpperCase()), true);
  assert.equal(digestsMatch(digest, `${'0'.repeat(63)}1`), false);
});

test('digestsMatch refuses to compare values that are not SHA-256 digests', () => {
  const ok = 'a'.repeat(64);
  assert.throws(() => digestsMatch('deadbeef', ok), /Computed digest/);
  assert.throws(() => digestsMatch(ok, 'deadbeef'), /Expected digest/);
  // A truncated digest must never silently "match" a prefix.
  assert.throws(() => digestsMatch(ok.slice(0, 32), ok), /Computed digest/);
});

// The real `tar -tzf` listing of MacControlMCP-v0.8.3-macos-universal.tar.gz.
const REAL_LISTING = [
  'MacControlMCP.app/',
  'MacControlMCP.app/Contents/',
  'MacControlMCP.app/Contents/CodeResources',
  'MacControlMCP.app/Contents/_CodeSignature/',
  'MacControlMCP.app/Contents/MacOS/',
  'MacControlMCP.app/Contents/Resources/',
  'MacControlMCP.app/Contents/Info.plist',
  'MacControlMCP.app/Contents/Resources/AppIcon.icns',
  'MacControlMCP.app/Contents/MacOS/MacControlMCP',
  'MacControlMCP.app/Contents/_CodeSignature/CodeResources',
  '',
];

test('assertSafeArchivePaths accepts the real v0.8.3 release listing', () => {
  assert.equal(assertSafeArchivePaths(REAL_LISTING).length, 10);
});

test('assertSafeArchivePaths rejects tar-slip entries', () => {
  assert.throws(
    () => assertSafeArchivePaths(['/etc/passwd']),
    /absolute path entry/,
  );
  assert.throws(
    () => assertSafeArchivePaths(['MacControlMCP.app/../../../etc/passwd']),
    /parent-directory entry/,
  );
  assert.throws(
    () => assertSafeArchivePaths(['../evil']),
    /parent-directory entry/,
  );
  assert.throws(
    () => assertSafeArchivePaths(['SomethingElse.app/Contents/MacOS/x']),
    /outside MacControlMCP\.app/,
  );
  assert.throws(() => assertSafeArchivePaths(['', '   ']), /listing is empty/);
});

test('assertSafeArchivePaths rejects a poisoned entry hidden among good ones', () => {
  const listing = [...REAL_LISTING, '../../.zshrc'];
  assert.throws(() => assertSafeArchivePaths(listing), /parent-directory entry/);
});

test('assertSafeArchiveLinks ignores a listing with no links', () => {
  assert.doesNotThrow(() =>
    assertSafeArchiveLinks([
      '-rwxr-xr-x  0 a staff  123 Jan  1 00:00 MacControlMCP.app/Contents/MacOS/MacControlMCP',
      'drwxr-xr-x  0 a staff    0 Jan  1 00:00 MacControlMCP.app/Contents/',
    ]),
  );
});

test('assertSafeArchiveLinks rejects every symlink, escaping or not', () => {
  assert.throws(
    () => assertSafeArchiveLinks(['lrwxr-xr-x 0 a staff 0 Jan 1 00:00 a/b -> /etc/passwd']),
    /symlink entry/,
  );
  assert.throws(
    () => assertSafeArchiveLinks(['lrwxr-xr-x 0 a staff 0 Jan 1 00:00 a/b -> ../../../root']),
    /symlink entry/,
  );
  // A "contained" target is still a link, and the bundle has none.
  assert.throws(
    () => assertSafeArchiveLinks(['lrwxr-xr-x 0 a staff 0 Jan 1 00:00 a/b -> c']),
    /symlink entry/,
  );
});

test('assertSafeArchiveLinks rejects hardlinks — the "link to" form the old scan missed', () => {
  assert.throws(
    () =>
      assertSafeArchiveLinks([
        'hrw-r--r--  0 a wheel 0 Jan 1 00:00 MacControlMCP.app/Contents/MacOS/MacControlMCP link to MacControlMCP.app/Contents/hard',
      ]),
    /hardlink entry/,
  );
});

test('assertSafeArchiveLinks rejects device, FIFO and socket members', () => {
  for (const flag of ['b', 'c', 'p', 's']) {
    assert.throws(
      () => assertSafeArchiveLinks([`${flag}rw-r--r-- 0 a staff 0 Jan 1 00:00 MacControlMCP.app/x`]),
      /non-regular member/,
      `type ${flag} must be refused`,
    );
  }
});

test('assertSafeArchiveLinks tolerates xattr/ACL markers on regular members', () => {
  assert.doesNotThrow(() =>
    assertSafeArchiveLinks([
      '-rwxr-xr-x@ 0 a staff 123 Jan  1 00:00 MacControlMCP.app/Contents/MacOS/MacControlMCP',
      'drwxr-xr-x+ 0 a staff   0 Jan  1 00:00 MacControlMCP.app/Contents/',
      '',
    ]),
  );
});

test('parseTeamIdentifier pins the signing identity', () => {
  const codesignOutput = [
    'Executable=/x/MacControlMCP.app/Contents/MacOS/MacControlMCP',
    'Identifier=com.canopylabs.MacControlMCP',
    'Authority=Developer ID Application: Adil El-Ouariachi (A3W973JZ49)',
    'TeamIdentifier=A3W973JZ49',
    'Sealed Resources version=2 rules=13 files=2',
  ].join('\n');
  assert.equal(parseTeamIdentifier(codesignOutput), EXPECTED_TEAM_ID);
  assert.equal(parseTeamIdentifier('TeamIdentifier=not set'), null);
  assert.equal(parseTeamIdentifier('Identifier=com.evil.app'), null);
  assert.notEqual(parseTeamIdentifier('TeamIdentifier=XXXXXXXXXX'), EXPECTED_TEAM_ID);
});

test('isTransientError only retries network blips and server-side failures', () => {
  assert.equal(isTransientError(Object.assign(new Error('x'), { code: 'ECONNRESET' })), true);
  assert.equal(isTransientError(Object.assign(new Error('x'), { code: 'ETIMEDOUT' })), true);
  assert.equal(isTransientError(Object.assign(new Error('x'), { statusCode: 503 })), true);
  assert.equal(isTransientError(Object.assign(new Error('x'), { statusCode: 429 })), true);
  assert.equal(isTransientError(Object.assign(new Error('x'), { statusCode: 404 })), false);
  assert.equal(isTransientError(new Error('SHA-256 mismatch')), false);
  assert.equal(isTransientError(null), false);
});
