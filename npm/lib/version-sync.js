'use strict';

/**
 * The npm package version IS the release version: the postinstall script
 * derives the GitHub release tag from it. If package.json and server.json
 * ever drift, `npm install mac-control-mcp@x` would try to download a release
 * that does not exist. `scripts/prepack.js` uses this to fail the pack.
 */

/**
 * @param {string} pkgVersion version field of npm/package.json
 * @param {{version?: string, packages?: Array<Record<string, unknown>>}} serverJson parsed server.json
 * @returns {{ok: true} | {ok: false, problems: string[]}}
 */
function checkVersionSync(pkgVersion, serverJson) {
  const problems = [];

  if (!serverJson || typeof serverJson !== 'object') {
    return { ok: false, problems: ['server.json could not be parsed as an object.'] };
  }

  if (serverJson.version !== pkgVersion) {
    problems.push(
      `server.json version is ${JSON.stringify(serverJson.version)} but npm/package.json is ${JSON.stringify(pkgVersion)}.`,
    );
  }

  const packages = Array.isArray(serverJson.packages) ? serverJson.packages : [];
  const npmEntry = packages.find((p) => p && p.registryType === 'npm');
  if (!npmEntry) {
    problems.push('server.json has no packages[] entry with registryType "npm".');
  } else {
    if (npmEntry.identifier !== 'mac-control-mcp') {
      problems.push(
        `server.json npm package identifier is ${JSON.stringify(npmEntry.identifier)}, expected "mac-control-mcp".`,
      );
    }
    if (npmEntry.version !== pkgVersion) {
      problems.push(
        `server.json npm package version is ${JSON.stringify(npmEntry.version)} but npm/package.json is ${JSON.stringify(pkgVersion)}.`,
      );
    }
  }

  return problems.length === 0 ? { ok: true } : { ok: false, problems };
}

/**
 * The MCP registry verifies npm ownership by requiring the published tarball's
 * package.json to carry an `mcpName` matching the server name.
 *
 * @param {{mcpName?: string}} pkgJson
 * @param {{name?: string}} serverJson
 * @returns {{ok: true} | {ok: false, problems: string[]}}
 */
function checkMcpName(pkgJson, serverJson) {
  const expected = serverJson && serverJson.name;
  if (!expected) return { ok: false, problems: ['server.json has no "name".'] };
  if (pkgJson.mcpName !== expected) {
    return {
      ok: false,
      problems: [
        `package.json "mcpName" is ${JSON.stringify(pkgJson.mcpName)}, expected ${JSON.stringify(expected)} (required by the MCP registry for npm packages).`,
      ],
    };
  }
  return { ok: true };
}

module.exports = { checkVersionSync, checkMcpName };
