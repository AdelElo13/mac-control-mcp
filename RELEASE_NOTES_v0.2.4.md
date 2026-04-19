# mac-control-mcp v0.2.4

Fixes three tools that returned empty results in production tests: `spotlight_search`, `list_windows`, and `list_menu_titles` / `list_menu_paths`. Closes the gap left by v0.2.3's Electron unlock by extending the same treatment to window enumeration, and adds a Window-Server fallback for apps whose windows are never registered with Accessibility at all.

## What's in

### `spotlight_search` — now returns files, not just recent apps

- Replaced `LIKE[cd] *query*` with `CONTAINS[cd] query` across `kMDItemDisplayName`, `kMDItemFSName`, and `kMDItemTitle`. No wildcard parsing means dotted names like `Claude-Jarvis.command` match cleanly, and filesystem-only entries (no display name) now surface.
- Removed the `kMDItemLastUsedDate`-desc sort descriptor. It demoted never-opened files past `limit: 10`, so a freshly-written `.command` shortcut on the Desktop appeared as "no results". Spotlight's native ranking now applies (same ranking the system popover uses).

### `list_windows` — Electron-aware, with CG fallback

- `WindowController` now flips `AXManualAccessibility` + `AXEnhancedUserInterface` per pid before reading `kAXWindowsAttribute`. Same trick v0.2.3 used for element walks, extended to window enumeration. Cached per-pid in an in-actor `Set<pid_t>` so the IPC cost is paid once.
- Added a fallback chain on the AX side: `kAXWindowsAttribute` → `kAXFocusedWindowAttribute` → `kAXMainWindowAttribute`. `listAppWindows`, `listWindows`, `focusWindow`, and `window(pid:index:)` all share the same resolver, so `move_window` / `resize_window` benefit without separate patches.
- Added `windowsViaCGWindowList(pid:appName:)` — when AX reports nothing or all zero-sized windows, query `CGWindowListCopyWindowInfo` (Window Server level, independent of AX). Chrome, Claude Desktop, and other Electron apps whose windows are never registered with AX now enumerate correctly, with real `x/y/width/height` instead of `0/0/0/0`. Windows surfaced only via CG can't be mutated by AX (`move_window`/`resize_window` still need an AX handle) — a known and honest Chrome-side limitation.
- Defensive `CFArray → NSArray → [AXUIElement]` bridging so a malformed AX response degrades to `[]` rather than trapping.

### `list_menu_titles` / `list_menu_paths` — resilient to AX cold-start

- `MenuController.copyMenuBar(forPid:)` polls `kAXMenuBarAttribute` up to 1s (10×100ms) instead of failing on the first empty read. Apps freshly activated or still finishing AX wiring no longer respond with `titles: []`.
- System-wide fallback via `kAXFocusedApplicationAttribute` for apps whose menu bar is reachable only through the system element. Gated on pid-match so we never describe the wrong app's menus to the caller.
- The empty-title Apple-submenu sibling is skipped so top-level counts reflect the user-visible bar.

## Why this matters

v0.2.3 unlocked the widget-level AX tree for Electron/iWork, but left `list_windows` and the adjacent window-mutation tools still going through the unprotected `kAXWindowsAttribute` path. The result was that on the very apps v0.2.3 was proud to support (Claude Desktop, Slack, VS Code, Discord, …), `list_windows` kept returning `count: 0`, and every downstream window tool then failed with "invalid pid or index". This release closes that gap.

The Window Server fallback is the genuinely new mechanism — it handles the case where AX isn't slow, it's *absent*, which is what actually happens for Chrome's browser windows.

## Upgrade

- **Claude Desktop**: remove the old extension, double-click the v0.2.4 `.mcpb`.
- **Manual**: replace `~/Applications/MacControlMCP.app` from the v0.2.4 tarball.
- **Source**: `git pull && NOTARIZE_PROFILE=mac-control-mcp ./scripts/build-bundle.sh`.

Bundle ID unchanged (`dev.macmcp.server`), so TCC grants carry over from v0.2.2 / v0.2.3.

## Verification

Smoke-tested against the deployed bundle:

- `spotlight_search("Claude-Jarvis.command")` → `/Users/a/Desktop/Claude-Jarvis.command` (previously empty).
- `list_windows(pid: <Claude Desktop>)` → 1 window, 600×907 (previously `count: 0` or `0×0`).
- `list_windows(pid: <Finder>)` → 2 windows, second with real 1800×1169 bounds.
- `list_menu_titles(pid: <Claude Desktop>)` → 7 titles (Apple, Claude, File, …).

## Tests

Full suite 62/62 green in the source-level paths touched by this release. 12 pre-existing ControlZoo AppKit compat assertions (AXSecureTextField missing id, AXPopUpButton missing id, AXOutline row count 0) remain red and are unrelated to this change. Developer-ID signed + Apple notarised + stapled on the distributed `.mcpb`.
