'use strict';

/**
 * End-to-end archive guards, exercised against *real* tarballs produced by the
 * same /usr/bin/tar the installer shells out to — not hand-written fixtures.
 * A fixture only proves the parser handles the string we imagined; a crafted
 * archive proves it handles the string tar actually prints.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { assertSafeArchivePaths, assertSafeArchiveLinks } = require('../lib/release');

const TAR = '/usr/bin/tar';

function tmpdir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcmcp-archive-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

/** Run tar without a shell and fail the test loudly if it errors. */
function tar(args, cwd) {
  const res = spawnSync(TAR, args, { cwd, encoding: 'utf8' });
  assert.equal(res.status, 0, `tar ${args.join(' ')} failed: ${res.stderr}`);
  return res.stdout;
}

/** Listings exactly as the installer gathers them. */
function listings(dir, archive) {
  return {
    plain: tar(['-tzf', archive], dir).split('\n'),
    verbose: tar(['-tvzf', archive], dir).split('\n'),
  };
}

/** A minimal but structurally real MacControlMCP.app. */
function seedBundle(dir) {
  const app = path.join(dir, 'MacControlMCP.app');
  fs.mkdirSync(path.join(app, 'Contents', 'MacOS'), { recursive: true });
  fs.mkdirSync(path.join(app, 'Contents', '_CodeSignature'), { recursive: true });
  fs.writeFileSync(path.join(app, 'Contents', 'Info.plist'), '<plist/>\n');
  fs.writeFileSync(path.join(app, 'Contents', 'MacOS', 'MacControlMCP'), 'binary\n');
  fs.writeFileSync(path.join(app, 'Contents', '_CodeSignature', 'CodeResources'), 'seal\n');
  return app;
}

test('a clean bundle archive passes both guards', (t) => {
  const dir = tmpdir(t);
  seedBundle(dir);
  tar(['-czf', 'clean.tar.gz', 'MacControlMCP.app'], dir);
  const { plain, verbose } = listings(dir, 'clean.tar.gz');

  assert.doesNotThrow(() => assertSafeArchivePaths(plain));
  assert.doesNotThrow(() => assertSafeArchiveLinks(verbose));
});

test('a crafted symlink archive is rejected before extraction', (t) => {
  const dir = tmpdir(t);
  const app = seedBundle(dir);
  fs.symlinkSync('/etc/passwd', path.join(app, 'Contents', 'leak'));
  tar(['-czf', 'sym.tar.gz', 'MacControlMCP.app'], dir);
  const { verbose } = listings(dir, 'sym.tar.gz');

  assert.throws(() => assertSafeArchiveLinks(verbose), /symlink entry/);
});

test('a crafted symlink with a relative, contained target is rejected too', (t) => {
  // The bundle has no links at all, so "contained" is not a reason to allow one.
  const dir = tmpdir(t);
  const app = seedBundle(dir);
  fs.symlinkSync('Info.plist', path.join(app, 'Contents', 'alias.plist'));
  tar(['-czf', 'sym2.tar.gz', 'MacControlMCP.app'], dir);

  assert.throws(() => assertSafeArchiveLinks(listings(dir, 'sym2.tar.gz').verbose), /symlink entry/);
});

test('a crafted HARDLINK archive is rejected — the case the old " -> " scan missed', (t) => {
  const dir = tmpdir(t);
  const app = seedBundle(dir);
  fs.linkSync(
    path.join(app, 'Contents', 'MacOS', 'MacControlMCP'),
    path.join(app, 'Contents', 'MacOS', 'MacControlMCP-alias'),
  );
  tar(['-czf', 'hard.tar.gz', 'MacControlMCP.app'], dir);
  const { plain, verbose } = listings(dir, 'hard.tar.gz');

  // The path guard sees nothing wrong: every name is inside the bundle.
  assert.doesNotThrow(() => assertSafeArchivePaths(plain));
  // tar prints it as "h... a link to b", with no " -> " anywhere.
  assert.equal(
    verbose.some((l) => l.includes(' -> ')),
    false,
    'sanity: the hardlink must not be printed with " -> "',
  );
  assert.equal(verbose.some((l) => l.includes(' link to ')), true, 'sanity: tar printed "link to"');

  assert.throws(() => assertSafeArchiveLinks(verbose), /hardlink entry/);
});

test('a crafted absolute-path archive is rejected', (t) => {
  const dir = tmpdir(t);
  seedBundle(dir);
  // -P keeps the leading slash, which is exactly the hostile shape.
  tar(['-czPf', 'abs.tar.gz', path.join(dir, 'MacControlMCP.app')], dir);
  const { plain } = listings(dir, 'abs.tar.gz');

  assert.throws(() => assertSafeArchivePaths(plain), /absolute path entry/);
});

test('a crafted ".." archive is rejected', (t) => {
  const dir = tmpdir(t);
  const nested = path.join(dir, 'nested');
  fs.mkdirSync(nested, { recursive: true });
  seedBundle(nested);
  fs.writeFileSync(path.join(dir, 'escape.txt'), 'pwned\n');
  // -P also preserves ../ members.
  tar(['-czPf', path.join(nested, 'dots.tar.gz'), 'MacControlMCP.app', '../escape.txt'], nested);
  const { plain } = listings(nested, 'dots.tar.gz');

  assert.throws(() => assertSafeArchivePaths(plain), /parent-directory entry/);
});

test('a crafted FIFO member is rejected', (t) => {
  const dir = tmpdir(t);
  const app = seedBundle(dir);
  const mkfifo = spawnSync('/usr/bin/mkfifo', [path.join(app, 'Contents', 'pipe')], {
    encoding: 'utf8',
  });
  if (mkfifo.status !== 0) {
    t.skip(`mkfifo unavailable: ${mkfifo.stderr}`);
    return;
  }
  tar(['-czf', 'fifo.tar.gz', 'MacControlMCP.app'], dir);

  assert.throws(
    () => assertSafeArchiveLinks(listings(dir, 'fifo.tar.gz').verbose),
    /non-regular member/,
  );
});

test('assertSafeArchiveLinks fails closed on an unparseable line carrying a link marker', () => {
  assert.throws(
    () => assertSafeArchiveLinks(['?????????? weird tar output a/b -> /etc/passwd']),
    /symlink entry/,
  );
  assert.throws(
    () => assertSafeArchiveLinks(['?????????? weird tar output a/b link to a/c']),
    /hardlink entry/,
  );
});
