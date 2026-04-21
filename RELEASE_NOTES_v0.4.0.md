# mac-control-mcp v0.4.0 — no-gap Mac control (95 tools)

v0.4.0 closes the "everything a human does on a Mac" gap that v0.3.0
left open. 25 new tools push the total 70 → 95, covering system
telemetry, Mission Control, hardware toggles, Apple Shortcuts, Finder
actions, Notification Center, and ergonomic input wrappers.

## New tools (+25)

### System telemetry (5)
- **`battery_status`** — % charged, charging/plugged state, time-remaining
- **`system_load`** — CPU user/sys/idle %, 1/5/15-min load avg, memory MB
- **`network_info`** — Wi-Fi SSID + every interface's IP/MAC
- **`bluetooth_devices`** — paired devices with connected state
- **`disk_usage`** — per-volume total/used/available GB

### Mission Control + Spaces (5)
- **`mission_control`** — toggle (F3)
- **`app_expose`** — all windows of frontmost app (Ctrl+Down)
- **`launchpad`** — open Launchpad (F4)
- **`show_desktop`** — reveal desktop (F11 / Fn+F11)
- **`switch_to_space`** — switch to Space 1-9 via Ctrl+N

### Hardware toggles (5)
- **`wifi_set`** — on/off/toggle via `networksetup` (no third-party)
- **`bluetooth_set`** — on/off/toggle via `blueutil` (brew install blueutil)
- **`set_brightness`** — absolute level 0-1 via `brightness` CLI, or
  direction='up'|'down' via F14/F15 keystrokes (no CLI needed)
- **`night_shift_set`** — on/off/toggle via `nightlight`
- **`open_airplay_preferences`** — opens Displays pane for AirPlay

### Apple Shortcuts + URL schemes (3)
- **`list_shortcuts`** — enumerate every Shortcut
- **`run_shortcut`** — invoke by name, optional `input` pipes magic var
- **`open_url_scheme`** — generic `/usr/bin/open`, works for
  `x-apple.systempreferences://`, `shortcuts://`, `mailto:`, app schemes

### Finder actions (3)
- **`reveal_in_finder`** — `open -R <path>`, selects file in Finder
- **`quick_look`** — QuickLook preview with auto-close timeout
- **`trash_file`** — move to Trash (reversible; refuses paths outside
  `$HOME` so agents can't auto-trash system files)

### Notification + Control Center (2)
- **`notification_center_toggle`** — Fn+F12 via System Events
- **`control_center_toggle`** — click the menu-bar item directly

### Ergonomic click wrappers (2)
- **`right_click`** — right-click at (x,y); wraps `mouse_event`
- **`double_click`** — double-click at (x,y) with optional button

## Implementation philosophy

Every new tool prefers Apple-shipped binaries (`pmset`, `networksetup`,
`shortcuts`, `system_profiler`, `open`, `qlmanage`, `defaults`) over
third-party CLIs. The few third-party dependencies (`blueutil`,
`brightness`, `nightlight`) return a structured hint with brew-install
instructions when missing instead of silently failing — keeps the MCP
useful on a vanilla Mac and helpful on one customised for power use.

Subprocess calls go through a new `ProcessRunner` helper with a
watchdog-driven timeout so a stuck `system_profiler` can never wedge
the MCP stdio loop (see `Sources/MacControlMCP/ProcessRunner.swift`).

## Architectural notes

Six new actor controllers, one per theme:
- `SystemInfoController` — pmset/top/df/networksetup/system_profiler parsers
- `MissionControlController` — CGEvent keyboard-shortcut invoker
- `HardwareController` — wifi/BT/brightness/night-shift toggles
- `ShortcutsController` — shortcuts CLI + URL-scheme opener
- `FinderController` — reveal/QuickLook/trash
- `NotificationCenterController` — Fn+F12 + menubar-click fallback

Each is wired into `ToolRegistry` as a default-constructed property so
existing call sites don't need to change.

## Tool count

```
v0.2.6 →  64
v0.3.0 →  70 (+6 Phase 6: tiered perms, AX observer event-waits)
v0.4.0 →  95 (+25 Phase 7: no-gap Mac control surface)
```

`Phase5ToolsTests.totalToolCount` asserts the current count exactly so
a miscount during tool authoring fails CI.

## Tests

`Tests/MacControlMCPTests/Phase7ToolsTests.swift` — 23 tests:
- registry smoke: all 25 tools discoverable
- system-info live calls (battery, system_load, network_info, disk_usage)
  all return non-error results
- argument validation for every tool that takes input
- security rail: `trash_file` refuses `/etc/hosts`
- hot-path ergonomics: right/double click reject missing coords

## Upgrade

```bash
# Via Claude Desktop:
open https://github.com/AdelElo13/mac-control-mcp/releases/tag/v0.4.0
# → download .mcpb, double-click to install, restart Claude Desktop.

# Via MCP registry (io.github.AdelElo13/mac-control-mcp):
mcp-publisher will show v0.4.0 as the latest version.
```

No breaking changes. Existing tools and their schemas unchanged; the
permission-enforcement flag introduced in v0.3.0 remains opt-in via
`MAC_CONTROL_MCP_ENFORCE_TIERS=1`.

## What's next (v0.5.0)

- ScreenCaptureKit replacement for the remaining deprecated
  `CGWindowListCreateImage` calls
- Trackpad gestures (pinch, rotate, 3-finger swipe)
- Audio session observing (what's playing, per-app mute)
- Cross-Space window dialogs
