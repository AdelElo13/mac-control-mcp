# mac-control-mcp v0.7.0 — complete Mac surface

**141 tools** — voice, browser DOM-layers, Foundation Models wrapper,
App Intents, undo queue, artifact store, plus all the substrate
capabilities from v0.6.0.

## New tools (Phase 10, +14)

### Image-size discipline (A1)
- **`capture_screen_v2`** — content-addressed artifact store at
  `~/.mac-control-mcp/artifacts/<sha256>.png`, default `inline=false`
  to prevent claude-code context-size blowups (issues #13383, #45785).
  Optional `max_dimension` (4000 default) + `max_bytes` (4MB default)
  downscale before return.
- **`artifact_gc`** — force-sweep expired artifacts (1h TTL).

### Undo queue (F2)
- **`undo_last_action(steps?)`** — pops LRU queue (depth 20), replays
  snapshot-based inverses. Per-tool revert actions: restoreVolume,
  restoreDarkMode, restoreBrightness, restoreWifi, restoreAXAttribute,
  restoreWindowPosition/Size, restoreFile (put-back from Trash).
  Non-reversible tools (click/press_key/mouse_event) return
  `{reason: "not_reversible"}` instead of silently failing.
- **`undo_peek`** — read-only queue introspection.

### Voice + recording
- **`speech_to_text(audio_path, language?)`** — Apple Speech framework,
  on-device when supported. Triggers Speech Recognition TCC first use.
- **`text_to_speech(text, voice?, output_path?)`** — AVSpeechSynthesizer
  for spoken output, or `/usr/bin/say -o` for file output.
- **`audio_record(seconds, output_path?)`** — AVAudioRecorder at
  44.1kHz AAC/M4A. Triggers Microphone TCC on first use.
- **`record_screen(seconds, output_path?, include_audio?)`** —
  `screencapture -v -V <seconds>` (sanctioned macOS binary, auto-handles
  TCC).

### Browser DOM layers
- **`browser_dom_tree(browser?)`** — Shadow-DOM-aware walk. Returns
  `{tag, id, classes, text, role, isShadow, children}` recursively.
  Works in Safari + Chrome via `browser_eval_js`.
- **`browser_visible_text(browser?)`** — only rendered text (filters
  `display:none` / `visibility:hidden`).
- **`browser_iframes(browser?)`** — lists every `<iframe>`, same-origin
  status, size, + contentDocument summary when same-origin. Cross-origin
  iframes fail-closed with `sameOrigin: false`.

### Apple native (2026 macOS Tahoe+)
- **`foundation_models_generate(prompt, system?)`** — Apple Foundation
  Models framework (on-device, free, offline). Graceful hint when
  framework unavailable (Intel Macs / pre-Tahoe).
- **`list_app_intents`** — enumerate installed apps with App Intents
  metadata (Info.plist heuristic: AppShortcuts / Intents keys).
- **`invoke_app_intent(bundle_id, intent, input?)`** — invokes via
  `/usr/bin/shortcuts run`. User Shortcut must exist with that name.

## Tool count trajectory

```
v0.2.6  →   64  baseline
v0.3.0  →   70  (+6 Phase 6: tiered perms + AX observer)
v0.4.0  →   95  (+25 Phase 7: no-gap Mac surface)
v0.5.0  →  117  (+22 Phase 8: Apple apps + power + audio + dock)
v0.5.1  →  117  (hotfix; Codex 5-blocker close)
v0.6.0  →  127  (+10 Phase 9: reliability substrate)
v0.7.0  →  141  (+14 Phase 10: complete surface)
```

## Dependencies

- Foundation Models framework (macOS 26 Tahoe+ with Apple Intelligence):
  optional, graceful degrade when absent
- Speech framework: shipped with macOS; requires Speech Recognition TCC
- AVFoundation: shipped with macOS
- `/usr/bin/say`: shipped with macOS
- `/usr/sbin/screencapture`: shipped with macOS; requires Screen Recording TCC
- `/usr/bin/shortcuts`: shipped with macOS (Monterey+)

**No new third-party deps** beyond the existing optional `blueutil`,
`brightness`, `switchaudio-osx`, `nightlight`.

## What's explicitly NOT in v0.7.0

- **OAuth + DPoP + HTTPS remote transport** — this is a transport
  migration, not a tool addition. Scheduled as v1.0 scope when partner-
  submission becomes the explicit goal.
- **`schedule_action` + `on_event`** — Codex v3 flagged these need 5
  mandatory security test files (ScheduleTTL, OnEventThrottle,
  ScheduleRevocation, SchedulePersistence, ScheduleRecursion) before
  ship. Design is in the v0.6.0 masterplan; build lands when those
  gates are in CI.
- **agent-safehouse sandbox profile** — upstream project integration,
  tied to the OAuth/transport work.
- **OpenAPI 3.1 export** — deferred to v0.7.1.

The line between "useful for the user" and "partner-submission paperwork"
is intentional: v0.7.0 makes mac-control-mcp usable for actual work
(voice, screen recording, browser deep-inspection, Foundation Models
on-device, undo safety); v1.0 makes it submittable.

## Tests

Phase10ToolsTests: 14 tests — registry, validation for every tool,
undo-empty-queue, Luhn CC, app-intents smoke. All green.

## Install

```bash
open https://github.com/AdelElo13/mac-control-mcp/releases/tag/v0.7.0
# → download .mcpb, double-click, restart Claude Desktop
```
