'use strict';

/**
 * End-to-end test of the real postinstall: `scripts/install.js` is run as a
 * child process against a local HTTPS "release mirror" that serves a tarball
 * built from a genuine notarized MacControlMCP.app. Nothing is mocked — the
 * download, sha256, tar containment, codesign, Team ID, plist pins, spctl and
 * atomic promotion are all the production code paths.
 *
 * Why it exists: `npm publish --dry-run` runs *prepack*, not postinstall, so
 * until this test nothing exercised install.js end to end short of a real
 * publish. It needs a signed fixture (test/helpers/fixture-app.js) and skips
 * when none is available.
 *
 * The package files are copied into a temp dir first, so `vendor/` is written
 * there and never inside the checkout.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');

const { tarballName, sha256Name, EXPECTED_TEAM_ID, parseTeamIdentifier } = require('../lib/release');
const { APP_BUNDLE_NAME, BINARY_REL_PATH } = require('../lib/install-core');
const { makeSelfSignedCert } = require('./helpers/tls');
const { FIXTURE, SKIP_REASON, copyFixtureApp, adHocResign } = require('./helpers/fixture-app');

const PACKAGE_ROOT = path.resolve(__dirname, '..');
const CERT = SKIP_REASON ? null : makeSelfSignedCert();
const SKIP = SKIP_REASON || (!CERT && 'openssl could not produce a localhost certificate');

function tmpdir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcmcp-e2e-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

/**
 * Build the two release assets from the fixture, exactly as
 * scripts/build-bundle.sh publishes them.
 *
 * @returns {{dir: string, tarball: string, sha256: string, version: string}}
 */
function buildReleaseAssets(root) {
  const version = FIXTURE.version;
  const stage = path.join(root, 'assets-src');
  copyFixtureApp(FIXTURE.appPath, path.join(stage, APP_BUNDLE_NAME));

  const dir = path.join(root, 'assets');
  fs.mkdirSync(dir, { recursive: true });
  const tarball = tarballName(version);
  const tar = spawnSync('/usr/bin/tar', ['-czf', path.join(dir, tarball), '-C', stage, APP_BUNDLE_NAME], {
    encoding: 'utf8',
  });
  if (tar.status !== 0) throw new Error(`tar failed: ${tar.stderr}`);

  const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, tarball))).digest('hex');
  fs.writeFileSync(path.join(dir, sha256Name(version)), `${digest}  ${tarball}\n`);
  return { dir, tarball, sha256: sha256Name(version), version };
}

/**
 * Local HTTPS release mirror. Serves `/releases/download/v<ver>/<asset>` and
 * records every request; `mutate` lets a test corrupt what is served.
 */
async function startMirror(t, assets, { mutate } = {}) {
  const hits = [];
  const prefix = `/releases/download/v${assets.version}/`;
  const server = https.createServer({ key: CERT.key, cert: CERT.cert }, (req, res) => {
    hits.push(req.url);
    if (!req.url.startsWith(prefix)) {
      res.writeHead(404).end('not found');
      return;
    }
    const name = req.url.slice(prefix.length);
    const file = path.join(assets.dir, name);
    if (!fs.existsSync(file)) {
      res.writeHead(404).end('not found');
      return;
    }
    let body = fs.readFileSync(file);
    if (mutate) body = mutate(name, body);
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': body.length });
    res.end(body);
  });
  const port = await new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
  t.after(() => new Promise((resolve) => server.close(() => resolve())));
  return { hits, baseUrl: `https://localhost:${port}/releases/download` };
}

/** A private copy of the published package files, with its own vendor/. */
function copyPackage(root) {
  const pkgDir = path.join(root, 'pkg');
  for (const rel of ['package.json', 'bin', 'lib', 'scripts']) {
    fs.cpSync(path.join(PACKAGE_ROOT, rel), path.join(pkgDir, rel), { recursive: true });
  }
  return pkgDir;
}

/**
 * Run a node script and collect its output. Asynchronous on purpose: the
 * mirror lives in *this* process, so a spawnSync here would block the event
 * loop and the child's request would never be answered.
 *
 * @returns {Promise<{status: number|null, stdout: string, stderr: string}>}
 */
function runNode(args, { cwd, env }) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (d) => (stdout += d));
    child.stderr.setEncoding('utf8').on('data', (d) => (stderr += d));
    const timer = setTimeout(() => child.kill('SIGKILL'), 120_000);
    child.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.once('close', (status) => {
      clearTimeout(timer);
      resolve({ status, stdout, stderr });
    });
  });
}

/** Run the real postinstall entry point as npm would, against the mirror. */
function runPostinstall(pkgDir, mirror, certFile, version) {
  return runNode(['scripts/install.js'], {
    cwd: pkgDir,
    env: {
      ...process.env,
      MAC_CONTROL_MCP_RELEASE_BASE_URL: mirror.baseUrl,
      MAC_CONTROL_MCP_TEST_VERSION: version,
      // The child validates the mirror's certificate chain like any other
      // TLS peer; the only concession is trusting our throwaway localhost CA.
      NODE_EXTRA_CA_CERTS: certFile,
      MAC_CONTROL_MCP_SKIP_DOWNLOAD: '',
    },
  });
}

function teamOf(appPath) {
  const info = spawnSync('/usr/bin/codesign', ['-dv', '--verbose=4', appPath], { encoding: 'utf8' });
  return parseTeamIdentifier(`${info.stdout || ''}\n${info.stderr || ''}`);
}

test('postinstall e2e: download → verify → promote, fast path, quarantine + reinstall', { skip: SKIP }, async (t) => {
  const root = tmpdir(t);
  const certFile = path.join(root, 'ca.pem');
  fs.writeFileSync(certFile, CERT.cert);
  const assets = buildReleaseAssets(root);
  const mirror = await startMirror(t, assets);
  const pkgDir = copyPackage(root);
  const appPath = path.join(pkgDir, 'vendor', APP_BUNDLE_NAME);

  // 1. Fresh install: both assets fetched from the mirror, bundle promoted.
  const first = await runPostinstall(pkgDir, mirror, certFile, assets.version);
  assert.equal(first.status, 0, `fresh install failed:\n${first.stdout}\n${first.stderr}`);
  assert.match(first.stderr, /MAC_CONTROL_MCP_RELEASE_BASE_URL=https:\/\/localhost:\d+/);
  assert.match(first.stdout, /installing: no bundle installed/);
  assert.match(first.stdout, /checksum verified/);
  assert.match(first.stdout, /archive contents verified/);
  assert.match(first.stdout, /signature verified in staging .* promoted atomically/);
  assert.match(first.stdout, new RegExp(`installed MacControlMCP\\.app ${assets.version.replace(/\\./g, '\\.')}`));
  assert.deepEqual(
    mirror.hits.map((u) => path.basename(u)).sort(),
    [assets.sha256, assets.tarball].sort(),
  );
  assert.equal(fs.existsSync(path.join(appPath, BINARY_REL_PATH)), true);
  assert.equal(teamOf(appPath), EXPECTED_TEAM_ID);
  // Staging dir removed, nothing else in vendor/.
  assert.deepEqual(fs.readdirSync(path.join(pkgDir, 'vendor')), [APP_BUNDLE_NAME]);

  // 2. Re-run (npm rebuild): fast path re-verifies, nothing downloaded.
  const hitsBefore = mirror.hits.length;
  const second = await runPostinstall(pkgDir, mirror, certFile, assets.version);
  assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, /already installed and re-verified .*team A3W973JZ49.*spctl --assess.*nothing to do/);
  assert.equal(mirror.hits.length, hitsBefore, 'fast path must not touch the network');

  // 3. Plant an ad-hoc signed bundle (right plist, no Team ID) at the install
  //    path: it must be quarantined, named in a warning, and replaced.
  adHocResign(appPath);
  assert.equal(teamOf(appPath), null, 'sanity: ad-hoc re-sign dropped the Team ID');
  const third = await runPostinstall(pkgDir, mirror, certFile, assets.version);
  assert.equal(third.status, 0, `reinstall after quarantine failed:\n${third.stdout}\n${third.stderr}`);
  assert.match(
    third.stderr,
    /WARNING: existing MacControlMCP\.app failed re-verification \[Signing team mismatch \(expected TeamIdentifier A3W973JZ49, got <none>\)/,
  );
  assert.match(third.stderr, /moved aside to .*MacControlMCP\.app\.rejected-\d+/);
  assert.match(third.stdout, /promoted atomically/);
  assert.equal(mirror.hits.length, hitsBefore + 2, 'a rejected leftover triggers a fresh download');
  assert.equal(teamOf(appPath), EXPECTED_TEAM_ID, 'the bundle at the exec path is ours again');
  const rejected = fs.readdirSync(path.join(pkgDir, 'vendor')).filter((n) => /\.rejected-\d+$/.test(n));
  assert.equal(rejected.length, 1, 'the rejected bundle is kept aside for inspection');
  assert.equal(teamOf(path.join(pkgDir, 'vendor', rejected[0])), null);
});

test('postinstall e2e: a tampered tarball never reaches the install path', { skip: SKIP }, async (t) => {
  const root = tmpdir(t);
  const certFile = path.join(root, 'ca.pem');
  fs.writeFileSync(certFile, CERT.cert);
  const assets = buildReleaseAssets(root);
  // Serve a tarball whose bytes differ from what the .sha256 asset promises.
  const mirror = await startMirror(t, assets, {
    mutate: (name, body) => (name.endsWith('.tar.gz') ? Buffer.concat([body, Buffer.from('\0')]) : body),
  });
  const pkgDir = copyPackage(root);
  const appPath = path.join(pkgDir, 'vendor', APP_BUNDLE_NAME);

  const res = await runPostinstall(pkgDir, mirror, certFile, assets.version);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /SHA-256 mismatch — refusing to install/);
  assert.match(res.stderr, /Manual install fallback/);
  assert.equal(fs.existsSync(appPath), false, 'nothing may occupy the install path');
  assert.deepEqual(
    fs.readdirSync(path.join(pkgDir, 'vendor')).filter((n) => n.startsWith('.staging-')),
    [],
    'staging directory must be cleaned up',
  );
});

test('postinstall e2e: the mirror override cannot downgrade to plaintext http', { skip: SKIP }, async (t) => {
  const pkgDir = copyPackage(tmpdir(t));
  const res = await runNode(['scripts/install.js'], {
    cwd: pkgDir,
    env: { ...process.env, MAC_CONTROL_MCP_RELEASE_BASE_URL: 'http://127.0.0.1:1/r', MAC_CONTROL_MCP_SKIP_DOWNLOAD: '' },
  });
  assert.equal(res.status, 1);
  assert.match(res.stderr, /MAC_CONTROL_MCP_RELEASE_BASE_URL must use https/);
  assert.equal(fs.existsSync(path.join(pkgDir, 'vendor')), false);
});
