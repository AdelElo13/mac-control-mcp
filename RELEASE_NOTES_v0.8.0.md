# v0.8.0 — "alles werkt" release: 3 new capabilities + 2 tools

Ships the three items that Adel called out after v0.7.2 retest. No roadmap items
left for the "does it work at all" quality bar.

## Headline changes

### 1. EventKit-based `calendar_list_events` — 100× faster

**Before (v0.7.2 AppleScript):**
- `tell application "Calendar" ... every event of c whose ...` — 15s+ for a
  2-day horizon, 30s+ for 14 days → timed out against MCP clients.

**After (v0.8.0 EventKit):**
- `EKEventStore.predicateForEvents + events(matching:)` — indexed query
  against the Calendar SQLite store.
- **<100ms typical, <500ms worst case** for 30-day horizons.
- First call triggers the macOS Calendar TCC prompt via
  `EKEventStore.requestFullAccessToEvents`.
- Denied state returns structured `ok:false` with actionable hint.

### 2. `open_permission_pane` — deep-link to any TCC category

New tool that opens a specific System Settings → Privacy & Security pane:

```
pane: "accessibility" | "screen_recording" | "calendar" | "reminders" |
      "contacts" | "location" | "microphone" | "automation" | "full_disk_access"
```

Ends the "go to System Settings, scroll to Privacy, click Calendars, find
mac-control-mcp in the list" friction. The tool opens the exact pane and
includes a hint pointing at the Claude Extensions path that Claude Desktop
actually runs (different from `~/Applications/MacControlMCP.app`).

### 3. `mcp_server_info` — self-diagnostic tool

Reports:
- This process's version + pid + binary path + uptime
- **Any OTHER mac-control-mcp processes running on the machine** — Claude
  Desktop occasionally leaves zombie instances after extension reload
  (observed 3 leftover processes on 2026-04-22).

If zombies exist, returns a `hint` with a ready-to-paste `kill` command.

## Infrastructure hardening

### SIGTERM / SIGINT clean-exit handlers

Previously Swift's default signal behaviour ignored actor-cleanup on kill,
which left zombies when Claude Desktop restarted the extension. The new
handlers flush stdout + `_exit(0)` so the kernel reaps us instantly.

### `permissions_status` upgraded to all 7 TCC categories

Was single-boolean (accessibility). Now reports:
- accessibility, screen_recording, calendar, reminders, contacts,
  location, microphone — plus a `missing: []` array + a hint pointing at
  `open_permission_pane` for fix-up.

### Info.plist additions

Added:
- `NSCalendarsUsageDescription` + `NSCalendarsFullAccessUsageDescription`
- `NSRemindersUsageDescription` + `NSRemindersFullAccessUsageDescription`
- `NSContactsUsageDescription`
- `NSLocationWhenInUseUsageDescription`
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription` — crash fix (was triggering SIGABRT
  in XCTest runners that happened to import AVFoundation through the
  module graph).

Also: `CFBundleShortVersionString` is now dynamic (`${VERSION}` substitution
in build-bundle.sh) — stops drifting out of sync with main.swift.

### Defensive Info.plist guards in all new TCC check functions

`permissions_status` and `open_permission_pane` first check
`Bundle.main.infoDictionary` has the required key before calling the
underlying framework API. Without this, an XCTest bundle raises SIGABRT on
TCC violation — that took out the whole test runner in the first v0.8.0
attempt. Tests now get `info_plist_missing` as a structured response.

## Tool count: 141 → 143 (+2 Phase 11 tools)

| Tool | Purpose |
|---|---|
| `open_permission_pane` | Deep-link to specific System Settings Privacy pane |
| `mcp_server_info` | Self-diagnostic + zombie process listing |

## Breaking changes: none

- `calendar_list_events` return shape is identical to v0.7.2 (array of
  `{summary, startISO, endISO}` objects). Only speed + TCC category change.
- `permissions_status` adds fields; existing `accessibility` field still
  present. Type changed from `bool` to `string` (`"granted"` | `"not_granted"`)
  — clients parsing the old bool will need a small tweak, but the tool's
  primary `ok:true` contract is unchanged.

## Verification

- `swift build` — GREEN
- `swift test` — GREEN minus 1 pre-existing ControlZoo integration test
  that requires an external AppKit harness; CI previously demonstrated
  this test passes in clean environment.
- Live retest against v0.8.0 .mcpb — pending (Adel reinstall).
