# v0.7.2 — E2E retest patch (3 regression fixes found in live v0.7.1 validation)

After Adel restarted Claude Desktop with v0.7.1 loaded, retest surfaced three
regressions where the v0.7.1 source fixes didn't translate into live behavior:

## Fixes

### BUG 1 — wifi_scan hint pass-through (`Tools+V2Phase8.swift`)

**Symptom:** v0.7.1 set `hint` in `HardwareController.wifiScan` when Location
Services was missing, but the `callWifiScan` handler dropped it on the
`ok:true` path. Users never saw the Location Services diagnostic.

**Fix:** handler now always forwards `r.hint` into the payload regardless of
the ok/error branch.

### BUG 3 — calendar_list_events trailing newline (`AppleAppsController.swift`)

**Symptom:** v0.7.1 trim via `.trimmingCharacters(in: .whitespacesAndNewlines)`
worked for most locales but `endISO` still carried `\n` for certain UTC events.
Raw osascript capture proved the stdout has a trailing `\n` (byte 66 in test).

**Fix:** belt+suspenders — also split on `\n` as a record separator AND apply
`replacingOccurrences` for `\n`/`\r`/`\t` inside every field after split.
Defense-in-depth against any future AppleScript locale quirk.

### BUG 6 — ax_tree_augmented per-node string truncation (`GroundingController.swift`)

**Symptom:** v0.7.1 added a `maxNodes` cap (default 300) which capped node
count — but a SINGLE Terminal node carried a 707,114-char `AXValue` (scrollback
buffer). A 300-node response was still 607KB because one fat node dominated.

**Fix:** `truncateAXString` helper at node construction time:
- `title` max 200 chars
- `value` max 1000 chars
- `inferredLabel` (OCR) max 200 chars
- Clipped strings get a `…[truncated N chars]` suffix so callers know.

## Verification

- `swift build` — GREEN (exit 0)
- `swift test` — GREEN (exit 0)
- Live retest against v0.7.2 .mcpb after reinstall — pending (Adel's step)

## No behavior changes

Tool count unchanged at 141. All three fixes are internal hardening — no API
surface change, no new permissions required.
