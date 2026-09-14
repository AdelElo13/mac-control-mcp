#!/usr/bin/env node
'use strict';

/**
 * prepack gate: the npm package version must equal the app version published
 * in server.json, because the postinstall script derives the GitHub release
 * tag from package.json's version. A mismatch would ship a package that can
 * only ever fail to install, so we refuse to build the tarball.
 *
 * Runs on `npm pack`, `npm pack --dry-run` and `npm publish`.
 */

const fs = require('node:fs');
const path = require('node:path');

const { checkVersionSync, checkMcpName } = require('../lib/version-sync');

const PKG_PATH = path.resolve(__dirname, '..', 'package.json');
const SERVER_JSON_PATH = path.resolve(__dirname, '..', '..', 'server.json');

function fail(lines) {
  process.stderr.write(`\nprepack: refusing to pack mac-control-mcp\n\n${lines.map((l) => `  - ${l}`).join('\n')}\n\n`);
  process.exit(1);
}

function main() {
  const pkg = JSON.parse(fs.readFileSync(PKG_PATH, 'utf8'));

  let serverJson;
  try {
    serverJson = JSON.parse(fs.readFileSync(SERVER_JSON_PATH, 'utf8'));
  } catch (err) {
    fail([
      `could not read ${SERVER_JSON_PATH}: ${err.message}`,
      'pack this package from a checkout of the mac-control-mcp repository.',
    ]);
    return;
  }

  const problems = [];
  const sync = checkVersionSync(pkg.version, serverJson);
  if (!sync.ok) problems.push(...sync.problems);
  const name = checkMcpName(pkg, serverJson);
  if (!name.ok) problems.push(...name.problems);

  if (problems.length > 0) fail(problems);

  process.stdout.write(
    `prepack: version ${pkg.version} matches server.json, mcpName ${pkg.mcpName} — ok\n`,
  );
}

main();
