'use strict';

/**
 * The npm package advertises a tool count in two published places — the
 * package.json description and the first line of the README — and a
 * hand-maintained number drifts the moment a tool is added: v0.9.0 shipped 151
 * tools while both still claimed 142. `docs/TOOLS.md` is generated from
 * `ToolRegistry.toolDefinitions`, the exact list the running server returns
 * from `tools/list`, so it is the only number that cannot lie. prepack reads
 * the marker from there and substitutes it, and fails the pack if the marker
 * is gone.
 */

/** The machine-readable marker embedded in docs/TOOLS.md. */
const TOOL_COUNT_RE = /<!--\s*tool-count\s*-->\s*(\d+)\s*<!--\s*\/tool-count\s*-->/;

/** The `— <n> tools` phrase as written in the description and the README. */
const TOOL_COUNT_PHRASE_RE = /—\s*\d+\s+tools\b/g;

/**
 * @param {string} markdown contents of docs/TOOLS.md
 * @returns {number} the generated tool count
 * @throws when the marker is absent or not a positive integer
 */
function parseToolCount(markdown) {
  if (typeof markdown !== 'string' || markdown.trim() === '') {
    throw new Error('docs/TOOLS.md is empty — regenerate it with UPDATE_TOOL_DOCS=1 swift test.');
  }
  const m = markdown.match(TOOL_COUNT_RE);
  if (!m) {
    throw new Error(
      'docs/TOOLS.md has no <!-- tool-count -->N<!-- /tool-count --> marker — ' +
        'regenerate it with UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests.',
    );
  }
  const count = Number(m[1]);
  if (!Number.isInteger(count) || count <= 0) {
    throw new Error(
      `docs/TOOLS.md tool-count marker is not a positive integer: ${JSON.stringify(m[1])}`,
    );
  }
  return count;
}

/**
 * Substitute the authoritative count into every `— <n> tools` phrase.
 *
 * @param {string} text description or README body
 * @param {number} count authoritative tool count
 * @param {string} what human-readable name used in the error
 * @returns {string} the text with the count substituted
 * @throws when there is no phrase to substitute (a silent no-op would be worse
 *         than a failed pack: it is how the count drifted in the first place)
 */
function syncToolCountText(text, count, what = 'text') {
  if (typeof text !== 'string' || !new RegExp(TOOL_COUNT_PHRASE_RE.source).test(text)) {
    throw new Error(`${what} has no "— <n> tools" phrase to keep in sync with docs/TOOLS.md.`);
  }
  return text.replace(TOOL_COUNT_PHRASE_RE, `— ${count} tools`);
}

module.exports = { TOOL_COUNT_RE, TOOL_COUNT_PHRASE_RE, parseToolCount, syncToolCountText };
