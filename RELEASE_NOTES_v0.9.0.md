# mac-control-mcp v0.9.0

Built from a live audit of every read-only tool against the shipped v0.8.3 (`docs/` gap audit): eight capability gaps with measured evidence, each shipped with tests, an independent code review, and live probes. No tool was removed or renamed; every new parameter is optional and every existing response keeps its fields.

## Address windows by identity (#window_id)

- `list_windows` returns `window_id` (CGWindowID), `display_index`, `z_order` (front-to-back among on-screen windows; `null` when minimized or on another Space), `is_focused`, and `title` is always present. Two windows with the same title are now distinguishable.
- `window_id` is accepted, with precedence over `pid`/`index`/`title_contains`, on `capture_window`, `focus_window`, `move_window`, `resize_window`, `set_window_state`, `move_window_to_display`, `ground`, `ax_tree_augmented` and `ocr_screen`. Optional `expect_pid` / `expect_title_contains` guards return `window_mismatch` when an id has been recycled; every response echoes `owner_pid`, `owner_name`, `title`.
- A `window_id` maps to exactly one AX window: the window server's id is read from the AX element itself (`_AXUIElementGetWindow`), so two windows with identical frame and title — the case frame/title matching cannot tell apart — resolve correctly (verified live on two same-sized, same-titled Finder windows). When that id is unavailable, frame + title matching is used, and a remaining tie is refused (`ambiguous_window` with the candidates) rather than guessed from stacking order.
- Window-scoped `ground`, `capture_annotated` and `ax_tree_augmented` walk only that window's AX subtree (`ax_scope: window_subtree`). A window that exposes no AX window (a minimized window, some Electron apps) gets `ax_scope: none` with `ax_scope_reason` and an empty element list instead of elements borrowed from another window of the same app; OCR grounding on that window still works.
- `ocr_screen` names its coordinate space (`screen_image_pixels`, `region_image_pixels`, `window_image_pixels`) and returns `origin` (global points of the image's top-left) plus `pixels_per_point`, so block coordinates map back without guessing. With `window_id` it OCRs that window even when covered.
- Multi-display: grounding filters candidates against the union of all displays instead of the main display; `convert_coordinates` reports `display_index` and `in_display_bounds`.
- Cost: `list_windows` +2 ms over v0.8.3 (one window-server snapshot, no AppKit hop).

## Know what is under a point, and keep element handles stable

- `element_at_point` (x, y in global points; optional `pid`): role, title, value, bounds, enabled, app, `element_id`, and the ancestor chain. The inverse of `ground` and the cheapest check before a click.
- Element ids are content-addressed (pid + AX path + role/identifier per level). The same element gets the same id from `find_elements`, `get_ui_tree`, `element_at_point`, `ground` and `capture_annotated`, across calls. A stale id never resolves to a different control: role, identifier, title and subrole are verified at every level, the process identity (start time, bundle id) is checked, and a mismatch returns `error_code: stale_element` with the hint to re-run `find_elements`.
- `find_element` returns `element_id` and accepts `exact: true` (v0.8 substring matching let `"Button"` match `AXRadioButton`).
- One depth default (24) for every element search; `max_depth` accepted everywhere; responses report `max_depth_used`.

## Pay only for the tree you need

- `get_ui_tree`, `find_elements`, `query_elements`, `list_elements`: `fields` (pick the keys you want), `interactive_only` (actionable controls and their ancestors), `viewport_only` (inside the on-screen window frames), `max_bytes` (soft cap; the returned tree stays orphan-free). Every response carries `bytes`, `nodes_visited`, `truncated`.
- Measured on Finder: full tree 290 KB → `interactive_only` 73 KB → `interactive_only` + `fields` 25 KB.

## One round trip instead of three: `batch`

- `batch` runs up to 50 tool calls sequentially in one request: `stop_on_error` (default true), `delay_ms`, per-call `ms`, `error_code`, and results correlated by `id`. Each call keeps its own time limit; a batch whose summed budget exceeds 300 s is rejected up front instead of being cut off halfway. A call that hits its time limit always stops the batch (`aborted_reason: sub_call_timeout_not_cancellable`) because macOS cannot cancel a blocking AX call.

## Edit text without retyping it

- `text_get_value`, `text_get_selection`, `text_get_caret`, `text_set_selection`, `text_insert_at_caret`, `text_replace_range` operate on an element (`element_id`) or the app's focused element (`pid`) through `AXSelectedTextRange` / `AXSelectedText`: no keystrokes, no focus change. Ranges and counts are UTF-16 code units, as the Accessibility API defines them. Writes are read back; an app that accepts the call but ignores it returns `not_supported` instead of `ok`. Secure (password) fields are refused.

## See the screen with numbered controls: `capture_annotated`

- Captures a window or the display, draws numbered boxes around the interactive elements, and returns `elements[{index, element_id, role, title, x, y, width, height, center}]` in global points with `pixels_per_point` and `scale`. Box `n` on the image is `elements[n-1]`, whose `element_id` works with `perform_element_action` and `click`. The menu bar is skipped so the budget goes to the window.

## Clipboard with images, files, RTF and HTML

- `clipboard_read` `type`: `text` (default, unchanged shape), `rtf`, `html`, `image` (PNG file or `inline` base64), `files`, `all` (inventory with sizes; large binary representations are not copied to measure them).
- `clipboard_write`: `text`, `html`, `rtf`, `image_path`, `files`, in any combination. The write is proven on a private pasteboard first; the real clipboard is only replaced when it succeeds, and restored if it doesn't.

## Install with npm

- `npx -y mac-control-mcp` — the package downloads the notarized app for its version from GitHub Releases, verifies the SHA-256 and the Developer ID signature (Team A3W973JZ49), and launches it. `mac-control-mcp --app-path` prints the bundle to grant permissions to. Registered in the MCP Registry as an npm package next to the `.mcpb`.

## Also in this release

- `ground` (AX) searches 32 levels deep and returns `bounds` + `element_id`; `ground` (OCR) targets the window instead of the main display.
- `ax_snapshot_diff` reports nothing on an idle app; nodes are matched by structure and frame, title edits show as `changed`.
- Test suite no longer touches the developer's clipboard (private pasteboards).
- A relabelled control keeps its element id: "Start" → "Stop" used to be mistaken for an id collision, which evicted the stable id and handed out a random one.
- Text tools treat an app-reported selection range as untrusted input: a negative or overflowing `AXSelectedTextRange` is refused (`invalid_selection_range`) instead of trapping the server.
- `clipboard_write(image_path:)` decides "regular file, under 50 MB" on the open descriptor (`fstat`), so a path swapped to a FIFO after the initial check cannot block the server.
- Fixed (present since v0.8): a SwiftUI element with a non-finite AX frame (System Settings, an `AXImage` with `position = NaN`) made the JSON encoder reject the whole `get_ui_tree` response, and the server answered nothing — the client hung until its own timeout (90 s). Non-finite numbers now encode as `null` (that call takes 465 ms), and a response that still cannot be encoded is answered with a JSON-RPC `internalError` for the same id instead of silence.

## Upgrade notes

- Element ids from v0.8 are not valid in v0.9 (different scheme). Re-run `find_elements`.
- `get_ui_tree` default depth is 24 (was 12); use `max_depth` or `interactive_only` if a tree gets larger than you want.
- `list_windows` responses are ~40% larger (four new fields per window).
