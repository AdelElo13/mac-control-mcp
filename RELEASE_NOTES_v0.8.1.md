# v0.8.1 — 2 live bugs from v0.8.0 retest, closed

Patch release. No API surface change. Tool count unchanged at 143.

## Fixes

### 1. `mcp_server_info` timeout (pipe-buffer deadlock)

**Symptom:** Calling `mcp_server_info` against a live Claude Desktop MCP
process returned `Error: MCP error -32001: Request timed out` after 30s.

**Root cause:** `otherMcpProcesses()` in Tools+V2Phase11.swift called
`Process.waitUntilExit()` *before* draining the stdout pipe. `ps -eo
pid,lstart,command` on a machine with ~300 processes produces 30-50KB of
output, well past the 16KB default pipe buffer (`PIPE_BUF`). The child
blocked on `write(2)` to the full pipe; the parent blocked on
`waitUntilExit()` waiting for the child; classic pipe-buffer deadlock.

**Fix:** Reorder to `run → readDataToEndOfFile (blocks until child
closes pipe i.e. exits) → waitUntilExit (no-op zombie reap)`. Also drain
stderr concurrently via a discard pipe so it can't back-pressure either.

### 2. `calendar_list_events` misleading "denied" for write-only grants

**Symptom:** Calling `calendar_list_events` against a live Claude Desktop
process returned `"Calendar access denied. Grant in System Settings …"`
despite the user having actually granted partial access.

**Root cause:** EventKit's `EKEventStore.authorizationStatus(for: .event)`
returns five states: `.notDetermined`, `.restricted`, `.denied`,
`.writeOnly`, `.fullAccess`. The v0.8.0 `requestCalendarAccess()` treated
`.writeOnly` identically to `.denied` and returned a bland message that
pointed the user to toggle "enable" — but the user had already enabled
write-only in an earlier session. Correct UX: tell them to upgrade to
Full Access.

**Fix:** `requestCalendarAccess()` now returns `(granted: Bool, status:
String)`. `listCalendarEvents` switches on the status and emits a
different error for each:

- `.writeOnly` → "Calendar access is write-only. listCalendarEvents needs
  FULL access to read events. In System Settings → Privacy & Security →
  Calendars, toggle mac-control-mcp to 'Full Access' (not 'Add Events
  Only'), then restart the MCP server."
- `.denied` → existing grant-from-scratch message.
- `.restricted` → "Calendar access restricted by MDM / parental controls.
  An administrator must unblock Calendar access for this user account."

## Verification

- swift build: GREEN (exit 0)
- swift test: GREEN (165 tests, 0 failures, 0 crashes, exit 0)
- Live retest against v0.8.1 .mcpb after reinstall: pending (Adel step)
