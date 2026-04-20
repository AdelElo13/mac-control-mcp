# mac-control-mcp v0.2.5

Fixes two concrete bugs hit during v0.2.4 production testing: `find_elements(role: "AXSheet")` returned 0 matches even when a sheet was visibly presented, and `get_ui_tree` with `max_depth >= 20` could hang the MCP client until disconnect on apps with large AX trees (Mail preview pane, Finder list view, Logic Pro). Also sharpens the `PathValidator` error message so callers learn the correct `$TMPDIR` path instead of guessing at "outside allowed roots".

## What's in

### `find_elements` / `query_elements` / `get_ui_tree` — sheets are no longer invisible

- `AccessibilityController.childElements(of:)` now merges `kAXChildrenAttribute` with the raw `"AXSheets"` attribute. On macOS a presented sheet is attached to its host window via `AXSheets` and is NOT always reflected in `kAXChildren`. Before this fix, `find_elements(role: "AXSheet")` returned 0 even when Mail's Add Attachments panel or a `Finder` Save dialog was visible, and every downstream query for widgets inside the sheet returned a partial subtree.
- Dedup is handled upstream by the `AXKey` visited-set, so listing a child twice is safe — we don't need a second pass to filter duplicates.
- Extraction into a shared `axElementArray(of:attribute:)` helper also tightens the `CFArray → NSArray → [AXUIElement]` bridging for all attribute reads, not just the children call.

### `get_ui_tree` — wall-clock deadline + node cap

- `AccessibilityController.treeWalk(pid:maxDepth:)` now carries the same 5-second deadline and 5000-node cap that `findElement` / `findElements` / `queryElements` already had. Without it, `max_depth=30` on Mail's main window produced thousands of `AXUIElementCopyAttributeValue` IPC round trips and the MCP client sat waiting until the client-side timeout fired.
- The inner `for child in childElements(...)` loop also checks the deadline before each recursion, so aborting happens at O(siblings) granularity instead of only at leaf-return.
- The existing `max_depth` argument still clamps to `[1, 64]` — the deadline is belt-and-braces for apps where even shallow trees are wide.

### `PathValidator` — clearer error message

- `outsideAllowedRoots` now names the actual user-scoped temp directory (resolved from `NSTemporaryDirectory()`) rather than just "temp dir, Desktop, Documents, Downloads, Pictures". The previous message led callers to try `/tmp/` and get rejected without a hint at the right path.
- Also records the *reason* `/tmp` and `/private/tmp` are rejected (TOCTOU symlink risk) so the rejection doesn't read like an arbitrary restriction.
- Policy is unchanged — this is a message-only edit, not a relaxation of the allowed-roots set from v0.2.2.

## Why this matters

v0.2.4's window and menu fixes made the AX graph reachable on Electron / iWork / Chrome, but `find_elements` was still missing any subtree attached as a modal sheet. On any Save/Open dialog — which is exactly where most "let the agent click through a flow" scenarios need to drive — callers would see textfields but no sheet container, which breaks higher-level helpers that scope by sheet.

The `treeWalk` deadline is the same kind of guarantee the other accessibility queries already had; leaving it out was a latent footgun that finally got tripped in v0.2.4 testing against Mail with `max_depth=30`.

## Upgrade

- **Claude Desktop**: remove the old extension, double-click the v0.2.5 `.mcpb` (once released).
- **Manual**: replace `~/Applications/MacControlMCP.app` from the v0.2.5 tarball.
- **Source**: `git pull && ./scripts/build-bundle.sh` (add `NOTARIZE_PROFILE=<profile>` for a notarised bundle).

Bundle ID unchanged (`dev.macmcp.server`), so TCC grants from v0.2.2 / v0.2.3 / v0.2.4 carry over.

## Verification

Smoke-tested against the deployed bundle:

- `get_ui_tree(pid: <Mail>, max_depth: 30)` → returns within ~5s with a truncated tree, no hang. Previously: client disconnect.
- `find_elements(pid: <Finder during Save dialog>, role: "AXSheet")` → 1 match (the AXSheet container). Previously: `count: 0`.
- `PathValidator.validate("/tmp/foo.png")` → error now spells out the real `$TMPDIR` path.

## Tests

Full suite green on source-level paths touched by this release. The same 12 pre-existing ControlZoo AppKit assertions noted in v0.2.4 remain red and are unrelated to this change. Developer-ID signed on the distributed bundle; notarisation available via `NOTARIZE_PROFILE`.
