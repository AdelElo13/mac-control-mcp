# mac-control-mcp v0.2.0

Native Swift MCP server for full macOS automation. 63 tools across accessibility, browser, screen capture, clipboard, window, app lifecycle, and system control — one signed binary, no Python/Node runtime.

## What's in the box

- **Proper `.app` bundle** (`Scripts/build-bundle.sh`) with `NSScreenCaptureUsageDescription`, `NSAccessibilityUsageDescription`, `NSAppleEventsUsageDescription` and ad-hoc codesign so TCC can actually see the process and prompt for permission. Unsigned CLI binaries silently fail on macOS 15+; this fixes that.
- **ScreenCaptureKit window capture** for macOS 14+/15+ — the legacy `CGWindowListCreateImage` returns nil for most per-window captures on recent macOS. SCK also handles cross-Space and multi-display with correct backing scale.
- **63 MCP tools** covering the full interactive surface: AX tree read/click/type, Safari + Chrome automation, screenshots (full/window/display), OCR, clipboard, window/app control, menus, Spotlight, volume, dark mode, displays, system info.
- **Swift 6 strict concurrency** — actors for shared mutable state, `@Sendable` value types across boundaries, `@preconcurrency` only where Apple frameworks force it.

## Critical fixes landed in this release

- **AX tree walker dropped 95% of nodes.** `Unmanaged.toOpaque()` as a dedup key hit CF pointer recycling. Now using `AXKey` (CFHash + CFEqual) — `find_elements` on big apps (Logic Pro, Figma) returns the full tree.
- **Interactive stdio hang.** `FileHandle.readData(ofLength: 4096)` blocked waiting for a full 4 KB. Switched to `availableData` + raw `Darwin.write` with EINTR retry and `fflush` so each MCP frame flushes immediately.
- **`browser.eval_js` locale bug.** `1+1` returned `"2,0"` on nl-NL because AppleScript coerces via locale. Now wraps user code in `(0, eval)(code)` IIFE and returns a JSON envelope `{ok, v}` / `{ok:false, err}` — period decimals and REPL semantics for `const x=1; x` style blocks.
- **`spotlight_search` not idempotent.** Popover UI automation had four compounding failure modes (Cmd+Space toggles, popover doesn't take regular activation, focus race, AX writes silently rejected, `postToPid` not delivered). Replaced the whole approach with `NSMetadataQuery` (Spotlight's own index) + `NSWorkspace.open` — idempotent by construction, 10 ranked results per call with paths, no popover.
- **`PathValidator` rejected `/tmp` paths.** Only `NSTemporaryDirectory()` (`/var/folders/…`) was whitelisted, so every `capture_*` call with a `/tmp/*.png` output path failed. `/tmp` and `/private/tmp` are now allowed.
- **`launch_app` parameter inconsistency.** Required `identifier` while sibling tools (`activate_app`, `quit_app`, `wait_for_app`) used `bundle_id`. Now accepts both.
- **`NSScreen.main!` crash on headless contexts.** SCK config now picks the `NSScreen` that intersects the target window's frame, falling back to 2.0 scale instead of crashing.
- **`browser.new_tab` / `navigate` failed on windowless browsers.** AppleScript now guards with `if (count of windows) = 0 then make new document`.
- **`KeyCodeMap` missing modifiers.** Added physical modifier keycodes for `shift` (56), `control` (59), `option` (58), `command` (55), `fn` (63), `caps_lock` (57).
- **Pasteboard restore race.** `PasteboardSnapshot.withSnapshot` closure now synchronously awaits restore instead of fire-and-forget `Task {}`.

## Known platform caveats (not code bugs)

- **Ad-hoc signing means TCC grants don't persist across rebuilds.** macOS keys Screen Recording / Accessibility grants on the code's cdhash; `codesign --sign -` changes that on every rebuild. For persistent grants, sign with a Developer ID certificate and notarise. Build script flags this clearly.
- **Cross-origin iframes block `browser.eval_js`.** Same-origin policy, not a bug. For content inside iframes from a different origin, use AX coordinates or synthetic CGEvents.

## Install

```bash
git clone https://github.com/AdelElo13/mac-control-mcp.git
cd mac-control-mcp
./Scripts/build-bundle.sh
```

Binary lands at `~/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP`. Point your MCP client at that path. First capture triggers the TCC consent dialog — grant Screen Recording, Accessibility, and Apple Events.

## Test coverage

- **Unit/integration** — `swift test`: 63 tests across 11 suites, all green. Covers AX, ElementCache, ToolRegistryV2, Phase 2/3/4/5 tool families, stdio framing.
- **ControlZoo matrix** — pure AppKit harness with 11 control types (text, secure field, toggle, stepper, popup, outline, button press+label, slider, meter).
- **Real-world matrix** — System Settings search, Finder rows, CFHash regression guard.
- **Live MCP probe** — 63 tools registered, 41/43 non-destructive probes pass with real I/O against a running binary; the two failures were probe-side schema mismatches, not tool bugs.
- **Interactive demo** — DuckDuckGo search via CGEvent navigate + JS popup dismissal in Safari.
