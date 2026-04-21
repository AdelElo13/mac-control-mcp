# mac-control-mcp v0.2.6 — bug-fix sweep from the responder production run

This release clears the 10 findings logged in `docs/BUGS-v0.2.4.md` during
the hackathon-era production run of mac-control-mcp. Every fix has a
regression test in `Tests/MacControlMCPTests/BugFixesV0_2_6Tests.swift` +
an inline comment in source pointing back to this list.

## HIGH

- **#3 — `perform_element_action` no longer silently "succeeds" on disabled
  targets.** AX used to return `.success` when the action was routed to a
  greyed-out control; callers believed the click landed. We now read
  `AXEnabled` up front and refuse the call with `strategy="rejected_disabled"`
  + a machine-readable `reason` and operator `hint`.

- **#4 — `find_element`, `find_elements`, `query_elements` now match
  aria-labelled buttons (AXDescription) even when AXTitle is a present-
  but-empty string.** The old `??` fallback chain preferred AXTitle
  whether or not it was meaningful, which meant every Shadcn / MUI /
  Tailwind button slipped through. Empty / whitespace-only title strings
  now fall through to AXDescription → AXIdentifier.

- **#6 — `type_text` is no longer AX-set-value-first.** On React /
  Angular / Material inputs the AX path appears to succeed but never
  fires `onChange`, leaving counters at 0/100 and submits disabled.
  Default is now `strategy="auto"` which tries clipboard paste → CGEvent
  unicode → AX set-value in that order. Callers can force a specific
  path via `strategy="clipboard" | "keys" | "ax"`.

- **#8 — empty AX-tree detection.** Apps like the native Telegram macOS
  client expose zero AX nodes (TGModernGrowing toolkit instead of
  NSAccessibility). `find_element` / `find_elements` / `query_elements`
  / `list_elements` now include `ax_tree_hint` in the payload when the
  app itself is AX-empty, so agents stop spinning on queries that can
  never succeed. A new standalone tool `probe_ax_tree` does the same
  check explicitly.

## MEDIUM

- **#5 — `perform_element_action` falls back to a coordinate click when
  AXPress returns -25202 (kAXErrorActionUnsupported).** Parity with
  `clickElement`, which already did this. The result surfaces
  `strategy="coord_fallback"` so callers can tell from the payload that
  the action happened via a synthesized click rather than AX.

- **#1 — `browser_list_tabs` multi-process hint.** When AppleScript
  returns zero tabs but multiple `com.google.Chrome` / `com.apple.Safari`
  processes are running (e.g. detached Claude-in-Chrome window), the
  payload now includes `multi_process_hint` pointing callers to the
  `list_windows` + AX-based fallback.

## LOW

- **#10 — `triple_click` added to `mouse_event`.** Needed for
  range-select on text surfaces where double_click ("select word") is
  too narrow. Also exposes `multiClick(count:)` internally for future
  click-count extensions (quintuple-click, anyone?).

- **#9 + #2 — docs:** `README.md` picks up a paragraph on OCR
  reliability on monospace tokens (`l`/`1`, `O`/`0` confusion) and
  points callers to `clipboard_read` for security-critical strings.
  The AppleScript-Apple-Events hint stays surfaced in the existing
  `browser_eval_js` error string.

## #7 — *not* a mac-control-mcp bug

The `readLine` stdin hang was in the consumer repo (`responder`), fixed
there in commit `34953cc`. Left on the record because the symptom
looked like an MCP issue on first encounter — documented so future
searchers find the real cause fast.

## Breaking change scoreboard

One: `AccessibilityController.performAction(element:action:)` returned
`Int32` and now returns `ActionResult`. The public MCP tool
(`perform_element_action`) is unchanged in shape — callers get the same
`ok`/`ax_status` keys plus new `strategy` / `reason` / `hint` fields.

Test callers that hit the actor directly need to read `outcome.axStatus`
instead of the raw `Int32`.

## Regression coverage

- `Tests/MacControlMCPTests/BugFixesV0_2_6Tests.swift` — one `@Test`
  per bug. `swift test` runs green on an AppKit-backed test host.
- Existing suites (`ControlZooMatrix`, `HardeningTests`,
  `Phase{2,3,4,5}ToolsTests`, `RealAppMatrixTests`, `StdioIntegrationTests`)
  all still pass.

## Versioning

- `Sources/MacControlMCP/main.swift`: `0.2.6`
- `scripts/build-bundle.sh`: `0.2.6`
- `server.json`: `0.2.6`
- `README.md` download URLs are bumped when the release artifacts are
  built + uploaded (standard release flow — `scripts/build-bundle.sh`
  followed by `gh release create`).
