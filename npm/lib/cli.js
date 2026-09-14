'use strict';

/**
 * Argument handling for bin/mac-control-mcp.js.
 *
 * Only a tiny surface is intercepted: everything else is forwarded verbatim
 * to the Swift binary, because the MCP host launches this as a stdio server
 * and must stay in control of the real argument list.
 */

/**
 * @param {string[]} argv arguments after `node script`
 * @returns {{mode: 'version'|'app-path'|'help'|'run', args: string[]}}
 */
function parseArgs(argv) {
  const args = Array.isArray(argv) ? argv.slice() : [];
  const first = args[0];

  // Intercept only when the flag is the sole argument, so a future
  // `MacControlMCP --version --json` style invocation still reaches the
  // binary untouched.
  if (args.length === 1) {
    if (first === '--version' || first === '-v') return { mode: 'version', args };
    if (first === '--app-path') return { mode: 'app-path', args };
    if (first === '--help' || first === '-h') return { mode: 'help', args };
  }
  return { mode: 'run', args };
}

const HELP_TEXT = `mac-control-mcp — native macOS automation over MCP (stdio)

Usage:
  mac-control-mcp              start the MCP server on stdio
  mac-control-mcp --version    print the bundled MacControlMCP.app version
  mac-control-mcp --app-path   print the path to MacControlMCP.app
  mac-control-mcp --help       show this message

The .app bundle is downloaded from the matching GitHub release during
npm install. macOS TCC permissions (Accessibility, Screen Recording,
Apple Events) are granted to the MCP host application that launches this
process, not to this script.`;

/**
 * Message shown when the bundle is missing — the one failure mode a user is
 * most likely to hit (install ran with --ignore-scripts, or the download was
 * skipped in CI).
 *
 * @param {string} appPath
 * @param {string} version
 * @returns {string}
 */
function missingBundleMessage(appPath, version) {
  return [
    `mac-control-mcp: MacControlMCP.app is not installed at ${appPath}`,
    '',
    'The bundle is fetched by the package postinstall script. Re-run it with:',
    '',
    '  npm rebuild mac-control-mcp',
    '',
    'or reinstall the package (without --ignore-scripts):',
    '',
    `  npm install -g mac-control-mcp@${version}`,
    '',
    'If your environment blocks the download, install the .app manually from',
    `  https://github.com/AdelElo13/mac-control-mcp/releases/tag/v${version}`,
    'and point your MCP client at MacControlMCP.app/Contents/MacOS/MacControlMCP.',
  ].join('\n');
}

module.exports = { parseArgs, HELP_TEXT, missingBundleMessage };
