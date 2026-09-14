#!/usr/bin/env node
'use strict';

/**
 * prepack gate. Two invariants, both of which have already bitten us:
 *
 *  1. The npm package version must equal the app version published in
 *     server.json, because the postinstall script derives the GitHub release
 *     tag from package.json's version. A mismatch would ship a package that
 *     can only ever fail to install, so we refuse to build the tarball.
 *
 *  2. The tool count advertised in the description must come from
 *     docs/TOOLS.md, which is generated from the live tool registry. v0.9.0
 *     shipped 151 tools while the description still said 142. The count is
 *     substituted into package.json here rather than merely compared, so the
 *     published description cannot drift from the server's actual tools/list.
 *     A missing marker fails the pack.
 *
 * Runs on `npm pack`, `npm pack --dry-run` and `npm publish`.
 */

const fs = require('node:fs');
const path = require('node:path');

const { checkVersionSync, checkMcpName } = require('../lib/version-sync');
const { parseToolCount, syncToolCountText } = require('../lib/tool-count');

const PKG_PATH = path.resolve(__dirname, '..', 'package.json');
const README_PATH = path.resolve(__dirname, '..', 'README.md');
const SERVER_JSON_PATH = path.resolve(__dirname, '..', '..', 'server.json');
const TOOLS_MD_PATH = path.resolve(__dirname, '..', '..', 'docs', 'TOOLS.md');

function fail(lines) {
  process.stderr.write(`\nprepack: refusing to pack mac-control-mcp\n\n${lines.map((l) => `  - ${l}`).join('\n')}\n\n`);
  process.exit(1);
}

/**
 * Read the generated tool count and write it into the description. Returns the
 * problems (if any) rather than throwing, so the pack reports every issue at
 * once instead of one per run.
 *
 * @param {{description?: string}} pkg parsed package.json (mutated on success)
 * @returns {string[]} problems
 */
function syncToolCount(pkg) {
  let markdown;
  try {
    markdown = fs.readFileSync(TOOLS_MD_PATH, 'utf8');
  } catch (err) {
    return [
      `could not read ${TOOLS_MD_PATH}: ${err.message}`,
      'pack this package from a checkout of the mac-control-mcp repository.',
    ];
  }

  let count;
  try {
    count = parseToolCount(markdown);
  } catch (err) {
    return [err.message];
  }

  let syncedDescription;
  let readme;
  let syncedReadme;
  try {
    syncedDescription = syncToolCountText(pkg.description, count, 'package.json description');
    readme = fs.readFileSync(README_PATH, 'utf8');
    syncedReadme = syncToolCountText(readme, count, 'npm/README.md');
  } catch (err) {
    return [err.message];
  }

  const drifted = [];
  if (syncedDescription !== pkg.description) {
    drifted.push(`package.json description\n    was: ${pkg.description}\n    now: ${syncedDescription}`);
    pkg.description = syncedDescription;
    fs.writeFileSync(PKG_PATH, `${JSON.stringify(pkg, null, 2)}\n`);
  }
  if (syncedReadme !== readme) {
    drifted.push('README.md');
    fs.writeFileSync(README_PATH, syncedReadme);
  }

  if (drifted.length > 0) {
    process.stdout.write(
      `prepack: tool count drifted — rewrote to ${count} tools from docs/TOOLS.md\n` +
        drifted.map((d) => `  - ${d}\n`).join(''),
    );
  } else {
    process.stdout.write(`prepack: tool count ${count} matches docs/TOOLS.md — ok\n`);
  }
  return [];
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
  problems.push(...syncToolCount(pkg));

  if (problems.length > 0) fail(problems);

  process.stdout.write(
    `prepack: version ${pkg.version} matches server.json, mcpName ${pkg.mcpName} — ok\n`,
  );
}

main();
