# mac-control-mcp v0.2.3

Unlocks the AX tree for **Electron / Chromium apps** and iWork — every AX walk now auto-enables `AXManualAccessibility` on the target process.

## Why this matters

Electron apps (VS Code, Slack, Discord, Cursor, 1Password, Obsidian, Postman, …) and iWork apps (Pages, Keynote, Numbers) ship with their Accessibility tree turned off by default. Walk their AX tree and you get the window frame — nothing else. No buttons, no text, no widgets. This was the single biggest hole in mac-control-mcp's coverage: a full-surface AX server that couldn't see inside half of the apps people actually use.

Apple exposes a private attribute, `AXManualAccessibility`, that flips the renderer into "expose everything over AX" mode. Flipping it to `true` on the application element tells Chromium / WebKit / iWork to populate the full tree on demand. This is the same trick serious macOS agents (Fazm, Scoot, Hyperkey, accessibility inspectors) have used for years.

## What's in

- `AccessibilityController.enableManualAccessibility(pid:)` — sets `AXManualAccessibility = true` and the fallback `AXEnhancedUserInterface = true` on the application element for a given pid. Cached per-pid in an in-actor `Set<pid_t>` so the IPC cost is paid once.
- Called automatically from every AX walk entry point: `listElements`, `findElement`, `findElements`, `queryElements`, `treeWalk`. Users don't need to think about it.
- Safe no-op on non-Electron apps — the attribute set just returns and the tree is unchanged.

## Verification

Tested against Claude Desktop (Electron). Before the flag: 1 AXApplication + 1 AXWindow + menu chrome (~50 nodes, no web content). After the flag at `max_depth=25`: the React DOM is fully walked, `AXStaticText` matches return actual chat labels ("Skip to content", "New session", "⌘B"), `AXButton` matches return real UI buttons ("Routines", "Customize", "Pinned", …).

## Upgrade

- **Claude Desktop**: remove the old extension, double-click the v0.2.3 `.mcpb`.
- **Manual**: replace `~/Applications/MacControlMCP.app` from the v0.2.3 tarball.
- **Source**: `git pull && NOTARIZE_PROFILE=mac-control-mcp ./scripts/build-bundle.sh`.

Bundle ID unchanged (`dev.macmcp.server`), so TCC grants carry over from v0.2.2.

## Tests

Full suite 62/62 green. Developer-ID signed + Apple notarised + stapled; `spctl` reports `source=Notarized Developer ID`.
