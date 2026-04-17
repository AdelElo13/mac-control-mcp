# mac-control-mcp

Native Swift MCP server for full macOS automation. 63 tools in one signed `.app` bundle — no Python, no Node runtime, no Electron.

Gives any MCP-compatible client (Claude Desktop, Claude Code, Cursor, etc.) the ability to:

- Read and mutate the Accessibility tree of any running app
- Drive Safari and Chrome (tabs, navigation, JS eval)
- Capture the screen, a display, or a specific window (ScreenCaptureKit)
- OCR what's on screen
- Click, type, scroll, drag, send key events
- Control windows (move / resize / fullscreen / minimize / main)
- Manage the clipboard
- Launch / activate / quit apps
- Search Spotlight's index (NSMetadataQuery) and launch results
- Toggle dark mode, volume, list displays, inspect menus

## Install

```bash
git clone https://github.com/AdelElo13/mac-control-mcp.git
cd mac-control-mcp
./scripts/build-bundle.sh
```

This produces `~/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP`. Point your MCP client at that path.

Requires macOS 14.0+ and Swift 6 (Xcode 16+).

## Configure your MCP client

Add to your `claude_desktop_config.json` (Claude Desktop) or `~/.claude.json` → `mcpServers` (Claude Code):

```json
{
  "mcpServers": {
    "mac-control-mcp": {
      "type": "stdio",
      "command": "/Users/you/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"
    }
  }
}
```

On first tool call, macOS will prompt for Screen Recording, Accessibility, and Apple Events permissions. Grant all three — the `.app` bundle has the usage-description strings wired up so the consent dialogs appear.

## Tool surface

| Category | Tools |
|---|---|
| Permissions | `permissions_status`, `request_permissions` |
| Accessibility | `find_element(s)`, `query_elements`, `list_elements`, `get_ui_tree`, `get_element_attributes`, `set_element_attribute`, `read_value`, `perform_element_action`, `wait_for_element`, `scroll_to_element` |
| App lifecycle | `list_apps`, `launch_app`, `activate_app`, `quit_app`, `force_quit_app`, `wait_for_app`, `focused_app` |
| Windows | `list_windows`, `focus_window`, `move_window`, `resize_window`, `set_window_state`, `wait_for_window`, `move_window_to_display` |
| Input | `click`, `mouse_event`, `drag_and_drop`, `scroll`, `type_text`, `press_key`, `press_key_sequence`, `key_down`, `key_up`, `convert_coordinates` |
| Menus | `click_menu_path`, `list_menu_paths`, `list_menu_titles` |
| Browser | `browser_list_tabs`, `browser_get_active_tab`, `browser_navigate`, `browser_new_tab`, `browser_close_tab`, `browser_eval_js` |
| Screen | `capture_screen`, `capture_window`, `capture_display`, `ocr_screen` |
| Clipboard | `clipboard_read`, `clipboard_write`, `clipboard_clear` |
| Spotlight | `spotlight_search`, `spotlight_open_result` |
| System | `set_volume`, `set_dark_mode`, `list_displays` |
| File dialogs | `file_dialog_set_path`, `file_dialog_select_item`, `file_dialog_confirm`, `file_dialog_cancel`, `wait_for_file_dialog` |

Total: **63 tools**.

## Security model

- Tools that write files (`capture_*`, `ocr_screen`) validate `output_path` via a strict allow-list — only the user-scoped temp dir (`NSTemporaryDirectory()`) and `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Pictures` are accepted. Symlinks at the target path are rejected to prevent redirection. `/tmp` is deliberately excluded because it's shared across users and opens a TOCTOU window.
- AppleScript string interpolation for `browser_eval_js` wraps user code in `(0, eval)(…)` via `JSON.stringify`, so quotes/newlines/unicode can't break out of the wrapper.
- No network calls. Everything is local system integration.

## Caveats

- **Ad-hoc codesigning means TCC grants don't persist across rebuilds.** macOS keys Screen Recording / Accessibility grants on the code's cdhash, which changes every build. For persistent grants, sign with a Developer ID certificate and notarise (requires an Apple Developer account).
- **Cross-origin iframes** block `browser_eval_js` — same-origin policy, not a limitation of the tool. Use AX coords or synthetic CGEvents for content inside embedded iframes from other origins.

## Development

```bash
# Run the test suite (63 tests in 11 suites)
swift test

# Build without packaging
swift build -c release

# Live probe the running binary via MCP stdio
python3 scripts/mcp-sweep.py  # if included
```

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome. Adversarial reviews especially — prior releases went through 11 rounds of external review before shipping.
