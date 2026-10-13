'use strict';

// Pins the npm Trusted Publishing (OIDC) workflow. Each assertion guards a
// way the publish silently breaks:
//  - registry-url on setup-node writes a placeholder-token .npmrc; npm then
//    authenticates with it and never tries OIDC (E404 on PUT).
//  - without id-token: write GitHub mints no OIDC token.
//  - npm < 11.5.1 cannot do Trusted Publishing.
//  - the package is darwin-only, so `npm ci` fails on a Linux runner.
//  - publishing before the release assets exist ships a broken postinstall.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WORKFLOW = path.join(__dirname, '..', '..', '.github', 'workflows', 'npm-publish.yml');
const RELEASE_SH = path.join(__dirname, '..', '..', 'scripts', 'release.sh');

const src = fs.readFileSync(WORKFLOW, 'utf8');

test('publishes on a published GitHub release', () => {
  assert.match(src, /release:\s*\n\s*types:\s*\[published\]/);
});

test('grants the OIDC token permission', () => {
  assert.match(src, /id-token:\s*write/);
});

test('does not configure an npm registry/auth on setup-node', () => {
  assert.doesNotMatch(src, /^\s*registry-url:/m);
  assert.doesNotMatch(src, /NODE_AUTH_TOKEN|NPM_TOKEN/);
});

test('upgrades npm to a Trusted-Publishing capable major', () => {
  assert.match(src, /npm install -g npm@\^11/);
});

test('runs on macOS (package is darwin-only)', () => {
  assert.match(src, /runs-on:\s*macos-/);
});

test('checks the release assets postinstall downloads before publishing', () => {
  const assetCheck = src.indexOf('macos-universal.tar.gz');
  const publish = src.indexOf('npm publish');
  assert.ok(assetCheck > 0 && publish > assetCheck, 'asset check must precede npm publish');
});

test('validates the tag format and only passes it through env', () => {
  assert.match(src, /\^v\[0-9\]\+/);
  assert.doesNotMatch(src, /run:[^\n]*\$\{\{\s*(github\.event|inputs)/);
});

test('release.sh waits for the CI publish by default', () => {
  const sh = fs.readFileSync(RELEASE_SH, 'utf8');
  assert.match(sh, /NPM_MODE="\$\{NPM_PUBLISH:-ci\}"/);
  assert.match(sh, /npm-publish\.yml/);
});
