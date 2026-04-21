# mac-control-mcp v0.3.0 — control plane + event-driven waits

Minor-version bump from v0.2.6. Closes the two biggest gaps Codex flagged
in the state-of-the-art audit: there was no per-app permission model, and
every `wait_for_*` tool polled at 250 ms. v0.3.0 adds both a tiered
permission store and AXObserver-backed event waits, plus the plumbing to
let v0.4.0 flip permission enforcement on by default.

## New tools (6)

### Control plane

- **`request_access(bundle_id, tier, ttl_seconds?, reason?)`** — grant
  `view | click | full` to a bundle id for a bounded TTL (default 24 h,
  clamped 60 s … 30 days). Persists to
  `~/.mac-control-mcp/permissions.json` so grants survive restarts inside
  their TTL. An existing deny-list entry blocks the call; caller must
  `revoke_access` first.
- **`list_granted_applications()`** — enumerate every live grant (expired
  entries filtered on read). Includes deny-list entries + a top-level
  `enforcement` flag showing whether `MAC_CONTROL_MCP_ENFORCE_TIERS` is on.
- **`revoke_access(bundle_id)`** — idempotent delete of a grant or deny
  entry.
- **`deny_access(bundle_id, reason?)`** — add a bundle to the deny list.
  Takes precedence over any grant. Deny entries self-heal after 30 days so
  a forgotten deny-list entry doesn't permanently block an app.

Tiers are ordered `denied < none < view < click < full`. A `view` grant is
enough for read-only AX queries (`get_ui_tree`, `list_elements`,
`capture_*`, `clipboard_read`). `click` covers mouse/keyboard events.
`full` additionally permits menus, file dialogs, `set_element_attribute`,
`set_volume`, `set_dark_mode`. The structured gate returns stable reason
codes: `"denied" | "no_grant" | "insufficient_tier" | "expired" | "ok"`.

**Rollout**: v0.3.0 adds the store and the `enforceIfEnabled(bundleId:
required:)` helper but keeps the check opt-in behind
`MAC_CONTROL_MCP_ENFORCE_TIERS=1`. Flipping the default to on is the
v0.4.0 work, paired with a `/setup` seeding flow so existing Claude
Desktop installs don't break on upgrade.

### Event-driven waits

- **`wait_for_ax_notification(pid|element_id, notification, timeout_seconds?)`**
  — block until an AX notification fires, or timeout. Replaces the
  250 ms polling loop with an `AXObserver` callback; typical reaction
  latency drops from ~250 ms (best case) to ~1 frame (~16 ms).
- **`wait_for_window_state_change(pid, change, timeout_seconds?)`** —
  convenience wrapper over `wait_for_ax_notification` for the common
  window lifecycle events: `created | moved | resized | focused`.

Supported notifications (allowlisted to keep the surface stable across
apps): `AXApplicationActivated`, `AXApplicationDeactivated`,
`AXApplicationHidden`, `AXApplicationShown`, `AXWindowCreated`,
`AXWindowMoved`, `AXWindowResized`, `AXWindowMiniaturized`,
`AXWindowDeminiaturized`, `AXMainWindowChanged`,
`AXFocusedWindowChanged`, `AXUIElementDestroyed`,
`AXFocusedUIElementChanged`, `AXValueChanged`, `AXTitleChanged`,
`AXSelectedTextChanged`, `AXSelectedChildrenChanged`,
`AXSelectedRowsChanged`, `AXMenuOpened`, `AXMenuClosed`,
`AXMenuItemSelected`, `AXRowCountChanged`, `AXLayoutChanged`.

Return status is machine-readable (`fired | timed_out | setup_failed |
unsupported`) and the payload includes `elapsed_seconds` so callers can
log real reaction latency.

## Architectural notes

- **`AXObserverBridge`** owns a single dedicated `CFRunLoop` on its own
  `Thread` (QoS `.userInitiated`). Observer sources attach there, which
  keeps the MCP's stdio loop responsive even when many concurrent wait
  calls are in flight. Per-wait state lives in a reference box protected
  by `NSLock`; the AX callback and the DispatchQueue timeout race to
  resolve the continuation, and whichever arrives first wins.
- **`PermissionStore`** is an actor — serialised disk I/O means two
  concurrent tool calls never race on the JSON writes. Grants expire on
  read, so no background sweeper needed.

## Tool count

v0.2.6 shipped 64 tools; v0.3.0 ships **70** (64 + 6 Phase 6 tools). The
`Phase5ToolsTests.totalToolCount` assertion is updated accordingly, and
the server.json description is rewritten to reflect the new capability
set.

## Tests

`Tests/MacControlMCPTests/Phase6ToolsTests.swift` — 12 tests covering:

- Registry smoke: all 6 new tools registered
- PermissionStore: grant → check → list → revoke round trip
- Deny beats grant; revoke clears deny
- Expired grants return `reason: "expired"`
- Tier ordering sanity
- `request_access` input validation + round trip
- `deny_access` + subsequent check
- AXObserverBridge: unsupported notification returns instantly
- `wait_for_ax_notification` times out cleanly on bogus pid
- `wait_for_window_state_change` validates `change` values

Full suite: **81/82 tests pass** on this release. The one failure
(`ControlZooMatrixTests`) is a pre-existing environmental flake that
fails identically on pristine v0.2.6 and is not caused by v0.3.0.

## Upgrade

Existing Claude Desktop + npx + MCP-registry consumers continue to work
unchanged — no existing tool schema changed, and permission enforcement
is off by default. The new tools show up after a server restart.

```bash
npx @adelelo13/mac-control-mcp@0.3.0
```

## What's next (v0.4.0)

- Flip `MAC_CONTROL_MCP_ENFORCE_TIERS` to on by default
- `/setup` skill that seeds grants for the common Claude workflows
- `run_sequence` primitive for batched operations with a structured trace
- ScreenCaptureKit modernization (replace deprecated CGWindowListCreateImage)
