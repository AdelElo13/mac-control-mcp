# mac-control-mcp v0.10.0

Built from a measured audit of v0.9.0 (perf run 7× per case, precision run over five apps with every annotated element hit-tested, plus code reading — `scratchpad/audit-v0.9.0-findings.md` in the working tree, `docs/audits/` in the repo). Every finding was fixed with a regression test, implemented by Codex (gpt-6-astra) in five parallel streams, reviewed live on a real desktop and merged on `integration/v0.10`. No tool was removed or renamed; every new parameter is optional. Two behaviours changed by default and are listed first.

## Changed defaults (read these)

- **Read tools skip the menu bar.** `get_ui_tree`, `find_elements`, `find_element`, `query_elements` and `list_elements` no longer descend into `AXMenuBar` unless `include_menus: true`. In Safari 86 % of the AX tree was menu items; searches for window content were paying for them on every call. Responses report `menus_excluded`. `list_menu_titles`, `list_menu_paths`, `click_menu_path`, `wait_for_element` and `scroll_to_element` keep seeing menus.
- **Tree walks are bounded.** `get_ui_tree` walks at most 2000 nodes (`node_cap`, up to the element-cache capacity) within 5 s; `query_elements` and `list_elements` are capped at 2000 nodes / 1000 ms (`node_cap`, `time_budget_ms`, clamp 10 000). Responses report `nodes_visited`, `node_cap_reached`, `truncated` and `timings_ms` (`queue`, `prepare`, `walk`, `ax_fetch`), so a cut-off walk is visible instead of silent.

## Element ids you can trust (A1, A2, A6, A8)

- A stale id never resolves to a different control. Menu and list handles are positional in the Accessibility API; v0.9 returned the stored handle whenever it was alive, so an id captured for "Close All Windows" could act on "Close Window" after the menu changed. The live handle's role, identifier, title and subrole are now verified against the recorded path on every resolve (one batched read); a mismatch re-resolves by path, then returns `error_code: stale_element`.
- Ids no longer expire after a few large walks. The cache holds 20 000 entries; a new walk of the same app evicts that app's older snapshots first, other apps' entries are kept by recency of use. An id that was evicted returns `error_code: evicted_element_id` with the walk that replaced it, instead of `unknown_element_id` with a wrong "5 minutes idle" hint.
- Chrome and other web views get stable ids. `AXPath.upwardPath` failed when the app root role is not `AXApplication`; ids were minted at random (`stable_id: false`) so `element_at_point` and `capture_annotated` could never agree. Paths are now reconstructed from the parent chain, top-down with geometric pruning, and ids never mint silently.
- `nodes_visited` is the real visited count on every search tool (v0.9 reported `matches.count`).

## Grounding that says what it matched (A5, C2, C5)

- `ground` matches title, value and description, normalises `…`/`...`, filters `AXWindow`/`AXSheet`/`AXApplication`/`AXScrollArea` and anything under 2 pt or outside every display, prefers the smallest candidate on a tie, and reports `matched_field` and an honest `confidence` (1.0 only for an exact label). v0.9 returned the whole window for "Untitled" with confidence 1.0 and a 1×1 pt hidden link for "Skip to content".
- `element_at_point` falls back to a geometric search over the interactive frames when the AX hit-test returns a window-sized group (SwiftUI, Finder: 41 % / 92 % wrong in v0.9). The result carries `hit_test_quality` (`direct`, `geometric`, `direct_out_of_frame`) and a deterministic ordering.
- `find_elements` / `find_element` / `query_elements` search title, description, value and identifier, rank window content before menu items, and return `matched_field`, `match` (`exact` / `prefix` / `substring`) and `rank_reason`. `semantic` aliases: `search_field`, `back`, `forward`, `close`, `ok`, `cancel`, `sidebar_item(<label>)`, `tab(<label>)`, `link(<label>)` — Finder's search button, System Settings' untitled field and SwiftUI identifier-only labels resolve without app knowledge.
- OCR runs the fast recognizer first and falls back to the accurate pass only when nothing was found (B5).

## Act on an element, not on a point (C1, C3, C4, C8, A3)

- `click`, `double_click`, `right_click`, `drag_and_drop`, `scroll` and `type_text` accept `element_id`. Pointer tools press via `AXPress` when supported and otherwise click the visible centre; `type_text` focuses the element (`AXFocused`) and verifies focus before typing. Every element action checks the element's owner is the expected app/window (`expected_app`, `expected_window`) and returns `verified: true | false | null` — `null` means verification was unavailable, never success.
- New `wait_for`: one target (`element_id`, `window_id`, or `pid` + role/title/value) and one condition (`appears`, `disappears`, `enabled`, `disabled`, `focused`, `value_equals`, `value_contains`, `title_contains`), `timeout_seconds` 0…60. `wait_for_element` and `wait_for_window` remain as wrappers.
- New `act`: resolve + action + verification in one round trip (`press`, `click`, `double_click`, `right_click`, `set_value`, `focus`, `type`, `key`) with a `wait_for` condition as the post-check. Returns `acted`, `verified`, `before`, `after` and the element.
- `batch` budgets each call at its own realistic limit (read and pointer tools 10 s, capture tools 30 s, others 90 s) instead of 90 s each, so a batch of ten reads is accepted (v0.9 rejected five).

## Faster walks (B1, B2, B3, B4, B6, B7)

- Viewport pruning happens during the walk: subtrees whose frame lies outside the window frames (`viewport_only`) or outside the capture rect (`capture_annotated`) are not descended into. Output is identical to the post-filtered v0.9 tree.
- `find_element` and `ground` walk breadth-first (shallow before deep) and stop at the first exact, usable label. A nine-level-deep earlier sibling no longer delays a depth-1 hit.
- Non-interactive nodes are emitted compactly by default and payload bytes are computed once (`bytes` no longer costs a second encode).
- Walks for different apps run on separate serial queues; three concurrent app walks take about the longest one, not the sum.
- Web nodes emit `url`, `dom_id` and `dom_class` (C6).

## Measured (this machine, warm, single Retina display, p50 of 7 runs, same harness as the v0.9 audit)

| Case | v0.9.0 | v0.10.0 |
|---|---|---|
| `ground` ax "Downloads" / Finder | 443 ms | 12 ms |
| `ground` ocr "Downloads" / Finder | 948 ms | 158 ms |
| `find_element` "Search" / System Settings | 344 ms | 17 ms |
| `list_elements` / Finder | 882 ms | 192 ms |
| `list_elements` / System Settings | 356 ms | 50 ms |
| `query_elements` `^Eject$` / Finder | 890 ms | 499 ms |
| `capture_annotated` / Finder | 502 ms | 189 ms |
| `capture_annotated` / System Settings | 313 ms | 97 ms |
| `ocr_screen` fast / Finder | 340 ms | 154 ms |
| `get_ui_tree` / Safari (menus now excluded: 1114 → 70 nodes) | 96 ms, 222 KB | 13 ms, 14 KB |
| `get_ui_tree` interactive+fields / System Settings | 380 ms | 205 ms |
| `get_ui_tree` / Finder (2000-node cap, no viewport) | 724 ms | 749 ms |
| `find_element` "Eject" / Finder (deep sidebar item, breadth-first now reads 545 nodes first) | 8 ms | 45 ms |
| `element_at_point` / Finder, System Settings (geometric fallback instead of the wrong window-sized group) | 5 ms, 5 ms | 42 ms, 304 ms |

The last three rows are the cost of the new defaults, listed so nobody has to discover them: a full uncapped Finder tree is not faster (use `viewport_only` / `interactive_only`), breadth-first favours shallow targets over deep ones, and a correct `element_at_point` in SwiftUI apps costs a bounded walk. Chrome rows are omitted because the page open during the two runs differed (481 vs 1290 nodes). Raw runs: `scratchpad/res_ax.json`, `res_cap.json` (v0.9) and `res_ax_v10.json`, `res_cap_v10.json` (v0.10); per-stream evidence in `docs/audits/` and `LIVE-CHECKS.md`.

## Verification

- `swift test`: 770 tests in 70 suites on `integration/v0.10` (ControlZoo AppKit matrix and the real-app matrix included).
- Live probe: 23 v0.9 checks re-run against the v0.10 binary, plus the per-stream live reviews in `LIVE-CHECKS.md`.
- Tool count 153 (`wait_for`, `act`); `docs/TOOLS.md` regenerated.
