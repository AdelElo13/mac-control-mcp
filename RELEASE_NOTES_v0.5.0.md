# mac-control-mcp v0.5.0 — "10/10" no-gap release

v0.4.0 got a 4/10 from Codex because of silent-success bugs, path-traversal
holes, wildcard URL schemes, and missing top-5 Mac capabilities. v0.5.0 is
the fix-and-fill pass:

1. **Codex P0/P1 hardening** — every finding from the v0.4.0 review closed
2. **Top-5 capability gaps** — Messages/Mail/Calendar/Reminders/Contacts,
   power, audio devices, Wi-Fi scan/join, Focus mode, Dock — all shipped

Tool count: 95 → **117** (+22 new). **Codex P0/P1 regression tests** in
`Phase7HardeningTests.swift` pin the security fixes — if a future release
accidentally reopens one of the holes, CI breaks.

## Codex hardening (v0.4.0 → v0.5.0)

### P0 #1 — Silent-success in 5 SystemInfo tools
`battery_status`, `system_load`, `network_info`, `bluetooth_devices`,
`disk_usage` previously returned `ok:true` with nil fields when the
underlying subprocess failed. Now each returns a `Result<T>` envelope with
`ok:false + error + exit_code` on subprocess failure. Callers can
distinguish "no battery on this desktop Mac" from "pmset crashed".

### P0 #2 — `trash_file` path-traversal
`~/../etc/hosts` and symlink escapes bypassed the `hasPrefix($HOME)` check.
Now paths are `resolvingSymlinksInPath().standardizedFileURL`-canonicalized
BEFORE the prefix check. Added a sensitive-directory denylist:

```
.ssh, Library/Keychains, Library/Mail, Library/Messages,
Library/Calendars, Library/Cookies, Library/IdentityServices,
Library/Preferences/com.apple.security, Library/Application Support/{Chrome,Firefox,com.apple.TCC},
.config/mcp-publisher, .mac-control-mcp, .gnupg, .aws, .kube
```

Matches the tail of the canonical path against each entry, so
`~/.ssh/id_ed25519`, `~/safe/symlink -> ~/.ssh/anything`, and
`~/.ssh/../.ssh/id_rsa` all fail closed.

### P0 #3 — `open_url_scheme` wildcard
v0.4.0 passed any URL to `/usr/bin/open`. v0.5.0 enforces a **scheme
allowlist** (http, https, mailto, shortcuts, x-apple.systempreferences,
obsidian, raycast, notion, linear, slack, zoommtg, vscode, cursor, spotify,
music, podcasts, …) AND an explicit **blocklist** (`javascript`, `file`,
`applescript`, `vnc`, `ssh`, `smb`, `tel`, `facetime`, `sms`, `data`,
`vbscript`). Rejected calls return `blocked:true` with a human-readable
`block_reason`.

### P1 #1 — `mission_control` / `app_expose` unverified
Previously returned `ok:true` after posting keys even if the panel never
opened. v0.5.0 uses `AXObserverBridge` to wait up to 500 ms for the
expected `AXApplicationActivated` notification on `com.apple.dock` and
surfaces a `verified:bool` field so the agent knows whether to retry.

### P1 #2 — Phase 7 tools not using tiered perms
`PermissionStore.enforceIfEnabled(bundleId:required:)` is now called at
the top of every destructive Phase 7/8 tool: `wifi_set`, `bluetooth_set`,
`trash_file`, `run_shortcut`, `open_url_scheme`, `system_{sleep,restart,
shutdown,logout,lock_screen}`, `imessage_send`, `mail_send`,
`calendar_create_event`, `reminders_create`, `set_audio_*`, `mic_mute`,
`wifi_join`, `set_focus_mode`, `click_dock_item`. System-wide capabilities
use pseudo-bundle IDs (`system:wifi`, `system:audio`, `system:power`, …)
so users can grant them separately.

## New tools (Phase 8, +22)

### Apple apps (8)
- **`imessage_send(to, body)`** — send iMessage via Messages.app
- **`imessage_list_recent(limit)`** — recent thread participants
- **`mail_send(to, subject, body, cc?, bcc?, send_now?)`** — Mail.app compose+send
- **`calendar_create_event(summary, start_iso, end_iso, calendar?)`**
- **`calendar_list_events(horizon_days)`** — upcoming 1-90 days
- **`reminders_create(title, due_iso?, list?)`**
- **`reminders_list(include_completed?, limit)`**
- **`contacts_search(query, limit)`** — phones + emails

### Power (5)
- **`system_sleep`** — pmset sleepnow (reversible)
- **`lock_screen`** — pmset displaysleepnow
- **`system_restart(confirm)`** — requires confirm:true
- **`system_shutdown(confirm)`** — requires confirm:true
- **`system_logout(confirm)`** — requires confirm:true

### Audio (4)
- **`list_audio_devices`** — output + input + current selection
- **`set_audio_output(name)`** / **`set_audio_input(name)`**
- **`mic_mute(mute)`** — input-volume based

### Wi-Fi extended (2)
- **`wifi_scan`** — visible networks + RSSI + channel + security
- **`wifi_join(ssid, password?)`** — password stored in Keychain on success

### Focus (1)
- **`set_focus_mode(mode, state)`** — dnd/work/personal/sleep via shortcuts

### Dock (2)
- **`list_dock_items`** — via AX on com.apple.dock
- **`click_dock_item(title)`** — case-insensitive substring match + AXPress

## Dependencies

v0.5.0 optional third-party CLIs (all graceful-degrade with a brew-install
hint when missing):

| Tool | Homebrew | Used for |
|---|---|---|
| `blueutil` | `brew install blueutil` | `bluetooth_set` |
| `brightness` | `brew install brightness` | `set_brightness` (absolute level) |
| `switchaudio-osx` | `brew install switchaudio-osx` | `list_audio_devices`, `set_audio_*` |
| `nightlight` | `brew install smudge/smudge/nightlight` | `night_shift_set` |

## Tool count

```
v0.2.6 →  64
v0.3.0 →  70 (+6 Phase 6: tiered perms + AX observer)
v0.4.0 →  95 (+25 Phase 7: system info, mission control, finder, shortcuts, …)
v0.5.0 → 117 (+22 Phase 8: Apple apps, power, audio, dock, wifi extended, focus)
```

## Tests

- `Phase7HardeningTests.swift` — 11 regression tests pinning every Codex
  P0/P1 fix. If any of these fail, ship is blocked.
- `Phase8ToolsTests.swift` — 18 tests for the 22 new tools (registry +
  arg validation + confirm-gate).
- `Phase5ToolsTests.totalToolCount` — now asserts 117.

## Upgrade

```bash
# Via Claude Desktop:
open https://github.com/AdelElo13/mac-control-mcp/releases/tag/v0.5.0
# → download .mcpb, double-click to install, restart Claude Desktop.

# Via MCP registry:
# io.github.AdelElo13/mac-control-mcp will show v0.5.0 as the latest.
```

Existing tools and their schemas are unchanged. Permission enforcement
remains opt-in via `MAC_CONTROL_MCP_ENFORCE_TIERS=1` — when off, Phase 8
tools still validate inputs and confirm gates, but don't require grants.
The `/setup` skill that auto-seeds grants is still a v0.6.0 item.

## What's next (v0.6.0 scope, per Codex)

- `/setup` skill that seeds grants from the user's top-10 used apps
- ScreenCaptureKit migration (3× CGWindowListCreateImage deprecations)
- Software update check (`softwareupdate -l`)
- Firewall state + Gatekeeper/Keychain status
- Printer mgmt (`lpstat`, `lpr`)
- Menubar extras (third-party status icons)
- Trackpad gestures (pinch/rotate/3-finger)
