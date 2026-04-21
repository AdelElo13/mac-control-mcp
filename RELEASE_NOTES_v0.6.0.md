# mac-control-mcp v0.6.0 — reliability + observability substrate

v0.6.0 is the **substrate release**: audit log, snapshot-based undo
queue, PII redaction, grounding mixture, AX tree augmentation, and
hierarchical permission scopes. 10 new tools (117 → 127).

**Framing**: this is NOT yet the Anthropic-partner-submission release —
that is v0.7.0, which ships OAuth+DPoP on a public HTTPS transport
plus scheduled actions, events, Foundation Models, App Intents, and
browser DOM layers. v0.6.0 lays the ground that v0.7.0 sits on.

## Masterplan review history

Four iterations of Codex review on the masterplan before coding
started:

- v1: 6/10 — scope lie, A1 contract break, Screen2AX dependency,
  5 security rules missing
- v2: 7/10 — scope split adopted, but B2 per-node OCR = perf trap,
  F2 blind-keystroke undo = state corruption, A3 credibility claim
- v3: 8.4/10 — design fixes in, but no executable CI gates
- v4: 9.3/10 — CI gates named, **GREEN → proceed to code**

## New tools (Phase 9, +10)

### B. Grounding + AX augmentation

- **`ground(target, pid, strategy?)`** — Agent S2 mixture-of-grounding:
  AX first (fastest), OCR fallback (works on any app including
  Electron/Canvas), auto (AX → OCR if zero or ambiguous). Returns
  `(x, y)` with confidence 0..1 plus full candidate list. Swift-only;
  no Python sidecar.
- **`ax_tree_augmented(pid, max_depth?)`** — single-pass OCR +
  geometric join. Attaches OCR-derived text labels to AX elements
  that lack `title`/`value`. Fixes the "Electron shows AXGroup with
  no label" class of problem. Overlapping-frame cases marked with
  confidence ≤0.5.
- **`ax_snapshot_capture(pid, max_depth?)`** + **`ax_snapshot_diff(from, to)`**
  — capture AX tree into a named snapshot (LRU 16), then diff two
  snapshots to see what changed. Lets agents observe "what happened
  after I clicked" without re-screenshoting.

### F. Audit + memory + redaction

- **`audit_log_append(event, tool?, bundle_id?, result?)`** +
  **`audit_log_read(since_iso?, filter_*?, limit?)`** — append-only
  JSONL at `~/.mac-control-mcp/audit.jsonl`, one line per event.
  Session ID auto-included so entries group by MCP boot.
- **`agent_memory_store(key, value, tags?)`** +
  **`agent_memory_recall(query, tag?, limit?)`** — A-Mem pattern:
  memory as explicit tool calls, not black-box side effects.
  Persisted JSONL; substring + tag match (embedding recall is
  v0.7.0 scope).
- **`redact_pii_text(text, categories?)`** — replace emails, phones
  (E.164 + US), SSN, credit-cards (Luhn-validated), API keys (AWS
  AKID, Stripe sk_live/pk_live, GitHub `ghp_`/`gho_`, Anthropic
  `sk-ant-`, OpenAI `sk-`, generic JWT) with `[REDACTED:<category>]`.
- **`redact_image_regions(path, regions, mode?, output_path?)`** —
  blur (pixelate) or black-out rectangular regions in an image.
  Useful before `screenshot → share` flows.

## Architectural changes (6)

### A3. `.well-known/mcp.json` Server Card

- Static JSON in `Resources/well-known-mcp.json`
- Fields: name, version, capabilities, permission_model, observability,
  safety (redaction categories + path-sandbox counts + URL-scheme
  policy)
- **`directory_submission_ready: false`** with explicit blockers listed
  (no OAuth+DPoP, no public HTTPS, no OpenAPI yet). Flips to true in
  v0.7.0.

### A5. CoreWLAN-native `wifi_scan`

- Replaces shell-out to the `airport` utility (removed in Sonoma 14.4)
- Uses `CWWiFiClient.shared().interface().scanForNetworks(withName: nil)`
- Security tier: WPA3 → WPA2 → WPA → WEP → Open detection
- Graceful degrade: MDM-blocked scans return `ok: false` with
  descriptive hint

### A6. Hierarchical permission scopes

- `PermissionGrant` now has `allowSubDelegation: Bool` (default `true`
  for back-compat with v0.5.x grants loaded from disk)
- Deny entries always set `allowSubDelegation: false`
- Foundation laid for v0.7.0 per-tool sub-call enforcement

### A1/A2/A4 (deferred to v0.6.1)

- A1 image-size discipline — substrate complete (content_ref file paths
  + TTL GC actor) but opt-in flag wiring landed in v0.6.1
- A2 OTel 1.40.0 tracing — audit log (F1) provides equivalent
  observability at JSONL-file level for v0.6.0; full OTel span emission
  deferred to v0.7.0 where the remote transport will need it
- A4 structured outputs audit — Phase9ToolsTests + existing Phase 5-8
  tests provide the coverage; full cross-registry audit landed as
  `AllToolsReturnStructuredContent` in v0.6.1

## Codex v0.5.0 blocker fixes (carried forward from v0.5.1)

All 5 Codex-flagged blockers from the v0.5.0 → v0.5.1 review stay
closed:

1. `trash_file("~")` home-root refused
2. Trash denylist expanded to 43 paths + 12 extensions (credentials,
   browser profiles, 1Password/Bitwarden/Dashlane/LastPass/KeePassXC,
   keychains, Mail/Messages/Calendars, `*.pem`/`*.key`/`*.env`/etc.)
3. SystemInfo parser silent-success closed in network + disk
4. `enforceIfEnabled` wired on set_brightness / night_shift_set /
   open_airplay_preferences (v0.5.1) — remains wired in v0.6.0
5. Phase7HardeningTests count = 15 (not 10)

## Tool count trajectory

```
v0.2.6 →   64  baseline
v0.3.0 →   70  (+6 Phase 6: tiered perms + AX observer)
v0.4.0 →   95  (+25 Phase 7: no-gap Mac surface)
v0.5.0 →  117  (+22 Phase 8: Apple apps + power + audio + dock)
v0.5.1 →  117  (hotfix; Codex 5-blocker close)
v0.6.0 →  127  (+10 Phase 9: reliability substrate)
```

## Tests

- Phase9ToolsTests: 14 tests (registry, validation, audit round-trip,
  memory round-trip, Luhn-validated credit-card, hierarchical
  permission default)
- Phase5ToolsTests.totalToolCount: asserts 127

## Install

```bash
open https://github.com/AdelElo13/mac-control-mcp/releases/tag/v0.6.0
# → download .mcpb, double-click, restart Claude Desktop
```

## What's next (v0.7.0 — partner submission)

- OAuth + DPoP on HTTPS remote transport
- `.well-known/mcp.json` served on public HTTPS (flips
  `directory_submission_ready: true`)
- OTel 1.40.0 MCP semantic-convention tracing
- OpenAPI 3.1 export of all tools via `@MCPTool` introspection
- `schedule_action` + `on_event` with Codex's 5 security rules
  as mandatory CI gates (ScheduleTTL, OnEventThrottle,
  ScheduleRevocation, SchedulePersistence, ScheduleRecursion)
- Foundation Models wrapper (`fm_generate`) + App Intents
  (`list_app_intents`, `invoke_app_intent`)
- Browser DOM layer tools (`browser_dom_tree`,
  `browser_visible_text`, `browser_iframes`)
- agent-safehouse sandbox profile upstreamed
- Anthropic MCP Directory submission
