# mac-control-mcp v0.8.3

Fixes measured on a second Mac (macOS 26.6.2, Apple Silicon) running v0.8.2 under Claude Desktop, Claude Code and the ChatGPT app. The goal of this release: every tool works in every MCP client, failures say what to do, and one slow tool never stalls the server.

## Calendar, Contacts and Microphone work under Claude Desktop (#10)

v0.8.2 was signed with hardened runtime but lacked the resource-access entitlements. When Claude Desktop launches the server (via `disclaimer`), MacControlMCP.app is the process macOS attributes privacy requests to, so Calendar, Contacts and Microphone were refused **without a prompt**. The ChatGPT app worked because its own entitlements applied there.

- Added `personal-information.calendars`, `personal-information.addressbook`, `personal-information.location` and `device.audio-input` (was `false`).
- New `scripts/check-entitlements.sh` verifies every Info.plist usage description against the **signed** entitlements (`codesign -d --entitlements -`). It runs in `build-bundle.sh` after signing, in CI, and in `swift test`, so this can't ship again.

## Permission reports you can act on (#11)

- `permissions_status` now reports `responsible_app`: the app macOS attributes requests to (Claude, ChatGPT, Terminal, …). Grants belong to that app, which is why status differed per client. It also lists categories that would be refused without a prompt.
- Calendar and Contacts errors separate *macOS refused without asking* (`permission_policy_denied`, status still `not_determined`) from *the user denied it* (`permission_missing`), *write-only calendar access*, and *an unanswered prompt* (`timeout`). `contacts_search` now actually requests access.
- Every `permission_*` error from any tool names the app to enable.
- `open_permission_pane` points at the real app bundle instead of a hard-coded Claude Extensions path.
- `request_permissions` no longer hangs: it triggers prompts without waiting and returns the current status immediately. New optional `categories`: accessibility, screen_recording, calendar, contacts, microphone, folders.

## No more stalls or leftover processes (#12)

- Requests are handled concurrently. A hung AppleScript or an unanswered permission prompt no longer blocks other tools.
- Per-tool time limit: 90 s default, longer for `foundation_models_generate` and `speech_to_text`, and it follows requested `seconds` / `timeout_seconds`. On expiry the tool returns `error_code: timeout`. Override with `MAC_CONTROL_MCP_TOOL_TIMEOUT`.
- The server exits when the client closes stdin (2 s grace for in-flight work), when stdout breaks, or when the launching process dies. This fixes the leftover instances after Claude Desktop restarts.

## Browser tools report failures (#13)

- `browser_*` tools return `permission_missing` (Automation, -1743), `permission_policy_denied` with menu instructions when "Allow JavaScript from Apple Events" is off (Chrome and Safari), `not_running` or `timeout`, instead of empty results.
- `browser_get_active_tab` queries the front window's active tab directly.
- Tab titles containing tabs or newlines parse correctly.

## capture_window picks the right window (#14)

With `title_contains`, the largest visible matching window wins, not a tiny helper window with the same title. Failures report which window was chosen.

## Safer input when several clients drive the Mac (#16)

Input tools accept optional `expected_app` / `expected_window`. If another app came to the front, nothing is sent and the tool returns `focus_mismatch`. AX actions (`perform_element_action`, `set_element_attribute`) remain the focus-independent option.

## wifi_scan shows real network names (#17)

`wifi_scan` never asked for Location access, which macOS requires before revealing SSIDs, so every network came back as "(hidden)". It now requests Location without blocking the scan. Until access is granted, `ssid` is `null` with `ssids_redacted: true`, `location_status`, `location_prompt_requested` and a hint naming the app to enable. `hidden: true` only appears for genuinely hidden networks. `permissions_status.location` reports the per-app status, and `request_permissions` accepts `location`.

## Faster (measured, release builds, back-to-back, median)

| tool | v0.8.2 | v0.8.3 |
|---|---|---|
| get_ui_tree (Chrome, depth 10) | 1177 ms | **31 ms** |
| list_windows | 131 ms | **33 ms** |
| capture_window | 117 ms | **60 ms** |
| capture_screen_v2 | 221 ms | **100 ms** |
| ocr_screen (default) | 764 ms | 622–646 ms |
| ocr_screen `level=fast` (new) | – | 220 ms |
| capture_screen `max_width=1280, format=jpeg` (new) | – | 38 ms |
| cold start → tools/list | 22 ms | 23 ms |

- get_ui_tree no longer degrades as the element cache fills (a full sort ran on every stored node); attributes are read in one AX call per node. It now walks at most 2000 nodes (the cache capacity) and reports `node_cap_reached`.
- list_windows reads the window server once and queries apps on a bounded pool with a per-app deadline; a hanging app is marked `ax_timeout: true` instead of stalling the call.
- OCR runs in memory; new opt-in `level`, `language_correction`, `include_blocks`, `max_blocks`.
- Capture tools accept opt-in `format` (png/jpeg), `quality`, `max_width` and report `scale` / `pixels_per_point`.
- Tool descriptions state when to use which of the overlapping capture and element-lookup tools.

## Docs

`docs/TOOLS.md` is generated from the registered tools and a test fails on drift. The README install links follow the latest release (#15).

## Upgrade notes

- After installing, macOS may ask again for Calendar, Contacts and Microphone. That is expected: those prompts could not appear before.
- `wifi_scan`: `ssid` can now be `null` (redacted) instead of the string "(hidden)".
- `request_permissions` returns immediately. Call `permissions_status` after answering the dialogs.
- Responses to concurrent requests can arrive out of order; they are matched by JSON-RPC id, as the spec requires.
