#!/usr/bin/env node
'use strict';

/**
 * Launcher for the bundled MacControlMCP stdio MCP server.
 *
 * The MCP host speaks NDJSON over this process's stdin/stdout, so the child
 * inherits all three streams and this wrapper stays out of the byte path.
 */

const { spawn } = require('node:child_process');

const { parseArgs, HELP_TEXT, missingBundleMessage } = require('../lib/cli');
const { APP_PATH, BINARY_PATH, installedVersion, isInstalled } = require('../lib/paths');

const pkg = require('../package.json');

function main() {
  const { mode, args } = parseArgs(process.argv.slice(2));

  if (mode === 'help') {
    process.stdout.write(`${HELP_TEXT}\n`);
    return;
  }

  if (mode === 'app-path') {
    process.stdout.write(`${APP_PATH}\n`);
    return;
  }

  if (mode === 'version') {
    // Report what is actually on disk; fall back to the package version when
    // the bundle is missing so `--version` never hard-fails.
    process.stdout.write(`${installedVersion() ?? pkg.version}\n`);
    return;
  }

  if (!isInstalled()) {
    process.stderr.write(`${missingBundleMessage(APP_PATH, pkg.version)}\n`);
    process.exit(1);
  }

  const child = spawn(BINARY_PATH, args, { stdio: 'inherit' });

  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGQUIT'];
  const forward = (signal) => () => {
    if (!child.killed) child.kill(signal);
  };
  const handlers = new Map();
  for (const signal of signals) {
    const handler = forward(signal);
    handlers.set(signal, handler);
    process.on(signal, handler);
  }

  const cleanup = () => {
    for (const [signal, handler] of handlers) process.removeListener(signal, handler);
  };

  child.on('error', (err) => {
    cleanup();
    process.stderr.write(`mac-control-mcp: failed to launch ${BINARY_PATH}\n${err.message}\n`);
    process.exit(1);
  });

  child.on('exit', (code, signal) => {
    cleanup();
    if (signal) {
      // Re-raise so the parent sees the same termination cause we did.
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code ?? 0);
  });
}

main();
