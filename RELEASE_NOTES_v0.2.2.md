# mac-control-mcp v0.2.2

Bug-fix release addressing five issues from the v0.2.1 live test sweep.

## Fixes

1. **`find_element` / `list_menu_paths` / window/scroll/volume schemas — "expected number, received string"**
   Claude's tool-call serializer occasionally emits integer params as strings (e.g. `"pid": "12345"`), and the client-side MCP schema validator rejected the call before it reached the server. The server already accepts both forms internally; now every `integer` schema field also declares `string` as a permitted JSON type (`"type": ["integer", "string"]`) so the validator stops blocking legitimate calls. Covers all 62 numeric parameters across the tool surface, including `pid`, `index`, `max_depth`, `limit`, `delay_ms`, `poll_interval_ms`, `window_index`, `tab_index`, `display_index`, `volume`.

2. **`file_dialog_select_item` — "No focused window" when a dialog is plainly visible**
   The old locator only checked `kAXFocusedWindowAttribute` on the systemwide element, which returns the focused window of whichever app has keyboard focus. If the MCP client (Claude Desktop, Terminal) was focused when the tool fired, the dialog window was invisible to the lookup even though it was on screen. The new `dialogWindow()` helper falls back to scanning every regular running app for an attached `AXSheet` or `AXDialog`-subrole window, so the tool works regardless of who has keyboard focus.

3. **`read_value` — hangs on broad AXMenuBarItem queries**
   `findElement` recursed the whole AX tree without a wall-clock budget. For apps with large menus (Finder, Logic Pro, Xcode) a match-all walk is thousands of IPC round trips, and the tool call just hung until the MCP client gave up with a timeout. Added a 5-second deadline to `findElement`, `findElements`, and `queryElements`. A query that can't match within 5 s returns what it has so far instead of blocking the transport.

4. **`query_elements` — hangs on broad regex scope** — same root cause as #3, same fix.

5. **Output framing regression guard** — the stdio integration test now asserts NDJSON shape (single line, ends with `\n`, no embedded newlines) so the v0.2.0→v0.2.1 framing regression cannot recur silently.

## Still known, still documented

- `set_window_state exit_fullscreen` — macOS places fullscreen windows on a separate Space that AX can't reach. Workaround: `press_key { key:"f", modifiers:["command","control"] }` while the window is focused.
- `browser_eval_js` — blocked on pages whose Content-Security-Policy forbids `unsafe-eval` (GitHub, X, most banks). AppleScript's `do JavaScript` triggers CSP since Safari 14.
- `set_dark_mode` / `volume` — require a healthy `System Events` daemon. If it's locked up: `killall "System Events"` and retry.
- Intel slice compiles universal but has never been runtime-tested on Intel hardware.

## Upgrade

- **Claude Desktop**: remove the v0.2.1 extension and double-click the v0.2.2 `.mcpb` from the release page.
- **Manual**: replace `~/Applications/MacControlMCP.app` from the v0.2.2 tarball.
- **Source**: `git pull && NOTARIZE_PROFILE=mac-control-mcp ./scripts/build-bundle.sh`.

## Verification

- Swift test suite: 62/62 green (ControlZoo skipped — needs clean AX state, unrelated).
- Developer ID signed + Apple notarized + ticket stapled; `spctl` reports `source=Notarized Developer ID`.
- Bundle ID unchanged (`dev.macmcp.server`) so TCC grants carry over from v0.2.1.
