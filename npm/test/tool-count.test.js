'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { parseToolCount, syncToolCountText } = require('../lib/tool-count');

const TOOLS_MD_PATH = path.resolve(__dirname, '..', '..', 'docs', 'TOOLS.md');
const README_PATH = path.resolve(__dirname, '..', 'README.md');
const PKG = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', 'package.json'), 'utf8'));

test('parseToolCount reads the marker generated into docs/TOOLS.md', () => {
  assert.equal(parseToolCount('<!-- tool-count -->151<!-- /tool-count --> tools total.'), 151);
  assert.equal(parseToolCount('<!--tool-count-->7<!--/tool-count-->'), 7);
  assert.equal(parseToolCount('preamble\n<!-- tool-count --> 42 <!-- /tool-count -->\nrest'), 42);
});

test('parseToolCount fails loudly rather than guessing', () => {
  assert.throws(() => parseToolCount(''), /empty/);
  assert.throws(() => parseToolCount('# Tool Reference\n\n151 tools total.\n'), /no <!-- tool-count/);
  assert.throws(() => parseToolCount(null), /empty/);
});

test('syncToolCountText substitutes the count in both published phrasings', () => {
  const desc = 'Native Swift macOS automation over MCP — 142 tools: Accessibility tree, OCR.';
  assert.equal(
    syncToolCountText(desc, 151),
    'Native Swift macOS automation over MCP — 151 tools: Accessibility tree, OCR.',
  );

  const readme = 'Native Swift MCP server for full macOS automation — 142 tools in one `.app`.\n';
  assert.equal(
    syncToolCountText(readme, 151),
    'Native Swift MCP server for full macOS automation — 151 tools in one `.app`.\n',
  );

  // Idempotent, and every occurrence is rewritten — a lagging second mention
  // is exactly the kind of drift this is meant to stop.
  assert.equal(syncToolCountText(syncToolCountText(desc, 151), 151), syncToolCountText(desc, 151));
  assert.equal(syncToolCountText('a — 1 tools b — 2 tools c', 151), 'a — 151 tools b — 151 tools c');
});

test('syncToolCountText refuses text with nothing to sync', () => {
  assert.throws(() => syncToolCountText('No count here.', 151, 'thing'), /thing has no "— <n> tools" phrase/);
  assert.throws(() => syncToolCountText(undefined, 151), /has no "— <n> tools" phrase/);
});

test('the published description and README already match the generated tool count', () => {
  // This is the drift the prepack gate exists to stop — assert it here too, so
  // a stale count shows up in `node --test` and not only at pack time.
  const count = parseToolCount(fs.readFileSync(TOOLS_MD_PATH, 'utf8'));
  const readme = fs.readFileSync(README_PATH, 'utf8');

  assert.equal(PKG.description, syncToolCountText(PKG.description, count));
  assert.equal(readme, syncToolCountText(readme, count));
  assert.match(PKG.description, new RegExp(`— ${count} tools:`));
});
