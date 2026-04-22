# mac-control-mcp v0.7.1 — E2E test patch

Post-ship E2E validation against the v0.7.0 binary (running in Claude
Desktop) surfaced **7 concrete bugs**. This patch closes all of them
with line-level fixes. No new tools — only behaviour corrections.
Tool count unchanged at 141.

## Bugs fixed

### BUG 1 — `wifi_scan` unclear hint when Location Services is missing
macOS 14+ hides Wi-Fi SSIDs unless the calling process has Location
Services. Previously 17 networks returned all labeled `(hidden)` with
no indication why. Now, when ≥3 networks come back but every SSID is
nil, the result includes a specific hint telling the user to grant
Location Services in System Settings. (`HardwareController.swift`)

### BUG 2 — `list_app_intents` missed Apple's first-party apps
Heuristic only checked Info.plist keys, which Calendar / Reminders /
Notes / Messages / Safari don't ship. They DO have a compiled
`Contents/Resources/Metadata.appintents/` bundle — the authoritative
signal. Heuristic now checks for that directory first.
(`AppleNativeController.swift`)

### BUG 3 — `calendar_list_events` `endISO` trailing `\n`
AppleScript parser split on `, ` but didn't trim newlines inside
records. `endISO` values ended with `\n`, breaking downstream ISO-8601
parsing. Added `.trimmingCharacters(in: .whitespacesAndNewlines)` on
every split part. (`AppleAppsController.swift`)

### BUG 4 — `contacts_search` phone/email formatting corrupt
Phones came back as `"(+31 (6) 14868584"` (stray leading paren) and
empty emails as `"\n"`. New `cleanPhone` / `cleanEmail` sanitizers
trim whitespace + newlines, drop empties, strip the `(+` prefix.
(`AppleAppsController.swift`)

### BUG 5 — `ground` returned off-screen AX candidates
Hidden menu items sit at position `(0, screen_height)` with size
`(0,0)`. An agent clicking those coordinates would hit dock area.
Now filters: `AXApplication` role (container, not clickable),
zero-size, parked-at-bottom default, coordinates far off display.
(`GroundingController.swift`)

### BUG 6 — `ax_tree_augmented` blew past Claude context limits
A Terminal window (~370 AX nodes) produced 564 KB JSON — over the
claude-code 20 MB context budget. Added `maxNodes` (default 300,
range 50–1000). When over cap, labelled nodes (AX title/value OR OCR)
preferred over unlabelled. Response carries `"truncated to N of M"`
error so callers can raise the cap.
(`GroundingController.swift` + `Tools+V2Phase9.swift`)

### BUG 7 — `browser_visible_text` silent-success on closed browser
If Safari had no tab, returned `ok:true charCount:0 text:""` — looked
identical to "page is empty". Now pre-checks tab count via
`listTabs`; zero tabs → `ok:false` with
`"<browser> is not running or has no open tab"` hint.
(`BrowserDOMController.swift`)

## Install

```bash
open /Users/a/projects/mac-control-mcp/release-artifacts/mac-control-mcp-v0.7.1.mcpb
```
