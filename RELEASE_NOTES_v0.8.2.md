# v0.8.2 — 57 verified bug-hunt findings closed

Patch release. No API surface change. Tool count unchanged at 143.

Every fix below comes from a structured bug-hunt over all 55 Swift files
(~15.6K LOC): 16 parallel reviewers + 5 cross-cutting lenses, every finding
adversarially verified by 3 independent skeptics before it made the list.
Total confirmed: 57 (4 critical, 19 high, 30 medium, 4 low) — all fixed
across PRs #3, #5, #6, #7, #8. Full report: `docs/BUG-HUNT-v0.8.1.md`.

## Critical — crashes, hangs, data loss (PR #3)

- **Whole-server crash on large numeric arguments.** `JSONValue.intValue`
  force-converted `Int(Double)` without a range check; a single
  `tools/call` with e.g. `{"pid": 1e300}` aborted the process (exit 133).
  Now range-checked — returns a clean per-request error.
- **Whole-server crash on oversized `Content-Length` header.**
  `bodyStart + contentLength` used checked arithmetic that trapped on
  `Int.max`; one malformed frame killed the server. Now overflow-safe with
  a 256 MB frame cap and a `-32700` parse error.
- **`osascript` calls could hang the server forever.** `OsascriptRunner`
  had no timeout and read pipes only after `waitUntilExit` (deadlock past
  64 KB of output, permanent actor wedge on TCC consent dialogs). Now
  watchdog-bounded with concurrent pipe draining, same as `ProcessRunner`.
- **`swift test` wiped the user's real `~/.mac-control-mcp/` state.**
  Permission grants, audit log and agent memory were overwritten by test
  junk on every test run. New `StoreLocation` redirects all persisted
  stores to a temp dir under test (positively detected — production can
  never be misdirected).

## Silent no-ops — tools that reported success but did nothing (PR #6)

14 findings, batched: bluetooth toggles, night shift, app intents,
audit-log append, brightness keys, text-to-speech, space switching,
AX snapshot values, reminders parsing, `scroll_to_element`, region
capture. Each either works now or returns an honest error. Also carried
forward: contacts via `CNContactStore` (no more -600 when Contacts.app is
closed), disk usage via `df -k` (real GB), `list_menu_titles` frontmost
fallback, bounded AX tree walks, observer/speech hang fixes.

## Escaping & display scale (PR #5)

- **AppleScript string escaping** (`imessage_send`, `trash_file`): only
  `"` was escaped, not `\` — broken scripts and an injection surface.
  New shared `AppleScriptString.escape` (backslash first, then quote).
- **`list_displays`** now reports the real Retina backing scale
  (was hardcoded 1.0).

## Misc logic (PR #7)

8 findings: `set_focus_mode` inverted on/off for custom modes,
`permissions_status` always listed location as missing,
`press_key_sequence` delay clamped to [0, 5000] ms, `list_menu_titles`
pid handling, iMessage and file-dialog edge cases.

## Retina grounding (PR #8)

OCR emits coordinates in **image pixels**, AX and click tools work in
**points** — on 2× Retina displays the `ground()` OCR fallback and
`ocr_screen`-driven clicks landed 2× off target. Pixel→point conversion
now applied at the grounding boundary; `ocr_screen`/`OCRBlock` coordinate
space documented.

## Verification

- 183 tests in 24 suites, all green (`swift test`, exit 0).
- Critical crash payloads replayed end-to-end against the built binary:
  clean JSON-RPC errors, exit 0 (previously exit 133).
- `~/.mac-control-mcp/permissions.json` checksum-identical before and
  after a full test run.
