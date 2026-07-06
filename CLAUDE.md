# Project: mac-control-mcp

## Context
- **What this builds**: Native macOS MCP server (Model Context Protocol) for controlling macOS via Accessibility API, AppleScript, and system frameworks
- **Stack**: Swift 6, Swift Package Manager, macOS 14+, AX API (ApplicationServices), AppKit, EventKit, Contacts, CoreLocation, AVFoundation
- **Platform**: macOS
- **Phase**: Active development / production (v0.8.x)
- **Repo**: AdelElo13/mac-control-mcp (public on GitHub)
- **Binary**: `.build/debug/mac-control-mcp` (debug), `.build/release/mac-control-mcp` (release)

## Build

```bash
swift build           # debug
swift build -c release # release (for shipping/notarization)
swift test            # run test suite
```

## Architecture

- `Sources/MacControlMCP/` — all source files
  - `Tools.swift` — main dispatch router + tool registry
  - `Tools+V2.swift`, `Tools+V2Phase*.swift` — tool definitions split by phase
  - `*Controller.swift` — domain controllers (Accessibility, Window, Menu, etc.)
  - `AppleAppsController.swift` — Messages, Mail, Calendar, Reminders, Contacts
  - `SystemInfoController.swift` — disk, battery, network, bluetooth, system load
  - `HardwareController.swift` — brightness, volume, night shift
- `Tests/` — unit + integration tests
- `TestHarness/` — manual test scripts

## Tool routing rules

| Task | Use |
|------|-----|
| macOS UI automation | AX API via `AccessibilityController` |
| Contacts lookup | `CNContactStore` (NOT AppleScript — Contacts.app may not be running) |
| Calendar/Reminders | `EventKit` directly |
| Browser control | `BrowserController` (AppleScript fallback) |
| Disk/system info | `SystemInfoController` via `df -k -P` (KB → GB conversion applied) |

## Known pitfalls

- `df -g` on macOS does NOT reliably return GB values — always use `df -k` and divide by 1024² to get real GB
- `list_menu_titles` defaults to frontmost app when `pid` is omitted — no need to call `focused_app` first
- AppleScript `tell application "Contacts"` fails with -600 when Contacts.app isn't running — use `CNContactStore` instead
- `parsePID(nil)` returns `nil` same as an invalid pid — check `arguments["pid"] == nil` to distinguish "not provided" from "invalid"
- Always wrap framework imports in `#if canImport(...)` guards (EventKit, Contacts, CoreLocation not available on all platforms)

## Signing & distribution

- Team ID: A3W973JZ49 (Adil El-Ouariachi / Canopy Labs)
- Notarized `.app` bundle in `release-artifacts/`
- `.mcpb` extension installable via Claude Desktop double-click

## Working style

- Always start with `swift build` before running tests to catch compile errors early
- Deliver full files, not snippets
- Verify with a real invocation when possible
- Do not add dependencies without discussion
