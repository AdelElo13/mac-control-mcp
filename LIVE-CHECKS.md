# S5 — round 2: semantic alias cost and live checks

## Current scope and reviewer baseline

Base commit: `774885b` (previous repair committed by the reviewer). This round changes only `AXSearch.swift`, `SemanticSearchTests.swift`, and this document.

Reviewer-supplied round-2 results:

- Finder `find_element role=AXButton`: 19.4 ms versus baseline 21.7 ms; exact Eject: 9.8 ms.
- Back resolves to the AXButton; substring-only orward ranks the forward button above its group.
- Settings semantic search_field resolves to its text field in 297 ms.
- Finder semantic search_field still took 2.6–3.0 seconds at 3352 nodes, versus 0.9–1.5 seconds for the ordinary complete walk and 0.93 seconds for semantic back.
- Finder `find_elements role=AXButton limit=5`: 815 ms versus baseline 720 ms. This remains a measurement-only item; its ≤400 ms target is deferred until S2's pruning changes are merged.

This round caches every constant semantic-name regex, the prefix prefilters, and both camelCase splitters in `private static let` properties. A conservative first-word prefix check rejects ordinary file labels before normalization and token-boundary matching. Traversal, node/deadline budgets and ranking rules are unchanged.

## RED → GREEN evidence

The test constructs 5000 ordinary AXTextField file rows outside the timed section, warms the semantic matcher once, then times the complete `AXSearch.search(..., semantic: "search_field")` call. No desktop IPC is involved. It asserts zero matches and elapsed time <50 ms.

RED before caching:

```text
C5 search_field synthetic_fields=5000 elapsed_ms=8535.256249946542 hits=0
✘ Test "search aliases reject 5000 ordinary file fields in under 50 ms" recorded an issue at SemanticSearchTests.swift:27:9: Expectation failed: (milliseconds → 8535.256249946542) < (50 → 50.0)
✘ Test run with 11 tests in 1 suite failed after 8.603 seconds with 1 issue.
```

Log: [round2-red.log](.build/s5-evidence/round2-red.log).

First GREEN after caching and prefix rejection:

```text
C5 search_field synthetic_fields=5000 elapsed_ms=24.949583341367543 hits=0
✔ Test run with 11 tests in 1 suite passed after 0.040 seconds.
```

Log: [round2-green.log](.build/s5-evidence/round2-green.log).

Extra correctness cases preserve camelCase identifiers, acronyms, multiword aliases, prefix/substring match kinds, and rejection of Research as a search-field alias. The independent reviewer found no new important issues. The synthetic negative-field benchmark does not prove the total Finder response time.

## Final named suites and build

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'SemanticSearchTests|AXSearchTraversalTests|Phase9ToolsTests|ToolDocsDriftTests'
```

```text
✔ Suite "AX search traversal (v0.10 C5)" passed after 0.008 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.027 seconds.
C5 search_field synthetic_fields=5000 elapsed_ms=26.535958284512162 hits=0
✔ Suite "Semantic search (v0.10 C5)" passed after 0.034 seconds.
✔ Suite "Tool docs drift" passed after 0.016 seconds.
✔ Test run with 36 tests in 4 suites passed after 0.088 seconds.
```

Exit 0: [round2-suites.log](.build/s5-evidence/round2-suites.log). No full suite was run. No tool descriptions or schemas changed, so `docs/TOOLS.md` did not require regeneration.

The initial `swift build` again failed on the non-writable default compiler cache. With the writable cache:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache swift build --disable-sandbox
```

```text
Build complete! (0.15s)
```

Exit 0: [round2-build-final.log](.build/s5-evidence/round2-build-final.log).

## Exact semantic timing probes for the desktop reviewer

Run from this worktree, preserving the same 3352-node Finder window. No click, typing, window movement or settings changes are required.

```sh
swift build
SCRATCH='/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad'
PROBE_MAX=300000 python3 "$SCRATCH/probe.py" .build/debug/mac-control-mcp '[["permissions_status",{}],["find_elements",{"pid":742,"title":"Back","limit":5}],["find_element",{"pid":742,"semantic":"search_field"}],["find_element",{"pid":742,"semantic":"back"}]]'
```

Require Accessibility access, the correct existing Search control, and `nodes_visited:3352` for both the ordinary and semantic search calls. `search_stopped_early` must be false in both; if the Back comparison now stops early or the tree changes, it is not a valid full-walk comparison. Update the pid consistently if Finder has restarted.

Measure the same inputs with the existing warm-session harness (one warmup, seven samples):

```sh
mkdir -p .build/s5-evidence
cat > .build/s5-evidence/round2-reviewer-cases.json <<'JSON'
[
  ["Finder/plain/full/Back/limit5", "find_elements", {"pid":742,"title":"Back","limit":5}],
  ["Finder/semantic/search_field", "find_element", {"pid":742,"semantic":"search_field"}],
  ["Finder/semantic/back", "find_element", {"pid":742,"semantic":"back"}],
  ["Finder/role/AXButton/limit5", "find_elements", {"pid":742,"role":"AXButton","limit":5}]
]
JSON
PROBE_MAX=300000 python3 "$SCRATCH/perf.py" .build/debug/mac-control-mcp .build/s5-evidence/round2-reviewer-cases.json 7 .build/s5-evidence/round2-reviewer-after.json
```

Acceptance for semantic search_field: **p50 ≤1000 ms AND p50 ≤1.10 × the ordinary full-walk p50**, on the same Finder tree. Preserve the result's element id/title and the JSON measurement output. The AXButton limit=5 case is recorded only, without a new optimization or the deferred 400 ms gate.

No new desktop latency is claimed in this round. The session's previously established lack of AX access prevents a valid live timing result here; the commands above are for the reviewer with desktop access.

## Commit status

The existing reviewer commits remain intact. The outcome of the new commit attempt is recorded at the end of this document.

---

## Archived round-1 evidence

The following records precede round 2. Their pending live checks and commit state were superseded by reviewer commit `774885b` and the round-2 results above.

### Current status

Base commit: `101c341` (reviewer committed the previous S5 implementation). Earlier commits remain intact.

The reviewer confirmed C5, C6 and C7 live before this follow-up: all nine semantic probes matched ground truth; Safari tree cost +8.7%, Chrome +1.2%; range bounds, visible range 25 → 23 and insertion-point line 0 were correct. These are reviewer-supplied results, not measurements made by this sandboxed session.

This follow-up restores bounded early exit for non-semantic searches, omits empty DOM metadata, and documents role-filter migration. It does not claim that the new Finder latency targets have been met: this session's debugbinary still reports `accessibility: not_granted`.

### Verified synthetic before/after

The tests use the **same `AXSearch.walk` implementation as AccessibilityController**, substituting synthetic handles for AX IPC. `nodes_visited` is the number of reads; tests also check the read callback count against the number of returned traversal entries.

| Query on a 1001-node tree | Before | After |
|---|---:|---:|
| `role=AXButton`, limit 1 | 1001 nodes | 2 nodes |
| `role=AXButton,title=Save`, limit 1 | 1001 nodes | 2 nodes |
| `role=AXButton`, limit 5 | 1001 nodes | 6 nodes |

These are node-read reductions, not desktop latency measurements. The four-node semantic `search_field` fixture still visits all four nodes. Prefix/substring-only searches still scan and rank, and menu hits cannot trigger early exit. Separate tests cover node cap, expired deadline, interactive-only and viewport-only eligibility.

#### RED

The first regression run, after extracting the existing full traversal without enabling the shortcut:

```text
C5 early limit=1 nodes_visited=1001 tree_size=1001
C5 early limit=1 nodes_visited=1001 tree_size=1001
C5 role limit=5 nodes_visited=1001 tree_size=1001
✘ Test run with 16 tests in 2 suites failed after 0.027 seconds with 14 issues.
```

Failures cover early-exit counts, menu/combined-filter handling, and empty DOM metadata. Full output: [.build/s5-evidence/revision-red.log](.build/s5-evidence/revision-red.log).

Review then found that payload-ineligible exact matches could consume the limit. The new tests first failed:

```text
✘ Test run with 7 tests in 1 suite failed after 0.011 seconds with 4 issues.
```

Full output: [.build/s5-evidence/revision-filter-red.log](.build/s5-evidence/revision-filter-red.log).

#### GREEN

After the initial fix:

```text
C5 early limit=1 nodes_visited=2 tree_size=1001
C5 early limit=1 nodes_visited=2 tree_size=1001
C5 role limit=5 nodes_visited=6 tree_size=1001
✔ Test run with 25 tests in 3 suites passed after 0.053 seconds.
```

After applying interactive/viewport eligibility before top-limit and early exit:

```text
✔ Test run with 16 tests in 2 suites passed after 0.059 seconds.
```

Logs: [revision-green.log](.build/s5-evidence/revision-green.log), [revision-filter-green.log](.build/s5-evidence/revision-filter-green.log).

#### Final named suites and build

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'TextEditingBackendTests|TextEditingTests|CodexR2RegressionTests|Phase9ToolsTests|AXPayloadBudgetTests|ToolDocsDriftTests|AXAttributeBatchTests|SemanticSearchTests|AXSearchTraversalTests'
```

```text
✔ Suite "AXAttributeBatch" passed after 0.002 seconds.
✔ Suite "AX payload budget (C-9)" passed after 0.001 seconds.
✔ Suite "AX search traversal (v0.10 C5)" passed after 0.012 seconds.
✔ Suite "Codex r2 regressions" passed after 0.012 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.017 seconds.
✔ Suite "Semantic search (v0.10 C5)" passed after 0.047 seconds.
✔ Suite "Text editing — AX backend seam (C-7 review)" passed after 0.002 seconds.
✔ Suite "Text editing primitives (C-7)" passed after 0.008 seconds.
✔ Suite "Tool docs drift" passed after 0.017 seconds.
✔ Test run with 127 tests in 9 suites passed after 0.122 seconds.
```

Exit 0: [revision-suites-final.log](.build/s5-evidence/revision-suites-final.log). No full suite was run.

The initial plain `swift build` could not write `/Users/a/.cache/clang/ModuleCache`. With a writable cache, the final build succeeded:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache swift build --disable-sandbox
```

```text
Build complete! (0.14s)
```

Exit 0: [revision-build-final.log](.build/s5-evidence/revision-build-final.log). The additional SwiftPM sandbox flag does not remove this session's host restrictions.

Tool docs were regenerated and verified with:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache UPDATE_TOOL_DOCS=1 script -q /dev/null swift test --disable-sandbox --no-parallel --filter ToolDocsDriftTests
```

Exit 0, four tests: [revision-docs-final.log](.build/s5-evidence/revision-docs-final.log). No tool count changed.

### Exact commands for the desktop reviewer

Run from this worktree on the current branch. The commands only read the existing apps. Preserve the same Finder and Settings windows used for the earlier measurements.

#### 1. Build and confirm target access

```sh
swift build
SCRATCH='/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad'
PROBE_MAX=300000 python3 "$SCRATCH/probe.py" .build/debug/mac-control-mcp '[["permissions_status",{}],["list_apps",{}]]'
```

Require Accessibility access and confirm Finder pid `742` and System Settings pid `76246`. If either pid changed, replace it consistently in the calls below. Empty AX roots or `ok:false` responses are invalid performance samples.

#### 2. Inspect actual results and traversal counts

```sh
PROBE_MAX=300000 python3 "$SCRATCH/probe.py" .build/debug/mac-control-mcp '[["find_element",{"pid":742,"role":"AXButton"}],["find_elements",{"pid":742,"role":"AXButton","limit":5}],["find_element",{"pid":76246,"semantic":"search_field"}]]'
```

Check:

- Finder single: a real `AXButton`, valid `element_id`, and `search_stopped_early:true`.
- Finder plural: five real `AXButton` results and `search_stopped_early:true`.
- Both Finder calls: `nodes_visited` substantially below their full tree size.
- Settings: the same search-field id/title as the saved semantic ground truth, and `search_stopped_early:false`. The semantic query still needs its bounded full traversal.

#### 3. Measure warm-session p50 with the same existing harness

```sh
mkdir -p .build/s5-evidence
cat > .build/s5-evidence/reviewer-perf-cases.json <<'JSON'
[
  ["Finder/find_element/AXButton", "find_element", {"pid":742,"role":"AXButton"}],
  ["Finder/find_elements/AXButton/limit5", "find_elements", {"pid":742,"role":"AXButton","limit":5}],
  ["Settings/semantic/search_field", "find_element", {"pid":76246,"semantic":"search_field"}]
]
JSON
PROBE_MAX=300000 python3 "$SCRATCH/perf.py" .build/debug/mac-control-mcp .build/s5-evidence/reviewer-perf-cases.json 7 .build/s5-evidence/reviewer-perf-after.json
```

| Target | integration/v0.10 (reviewer) | Regressed S5 (reviewer) | Required after |
|---|---:|---:|---:|
| Finder `find_element role=AXButton` | 26 ms | 838 ms | p50 ≤ 40 ms |
| Finder `find_elements role=AXButton limit=5` | 369 ms | 909 ms | p50 ≤ 400 ms |
| Settings `semantic=search_field` | Numeric baseline not supplied | Previously correct | Same control and unchanged latency versus saved reviewer baseline |

Save the full NDJSON inspection output and `reviewer-perf-after.json`. Do not infer latency from the synthetic node counts.

### Current session's live attempt

The same built debugbinary was probed with permissions plus the three targets above. Full output: [revision-live-probe.log](.build/s5-evidence/revision-live-probe.log).

```text
permissions_status: accessibility = not_granted
find_element Finder: ok=false, nodes_visited=1, search_stopped_early=false
find_elements Finder: ok=true, count=0, nodes_visited=1, search_stopped_early=false
find_element Settings: ok=false, nodes_visited=1, search_stopped_early=false
```

These are blocked/no-result calls, not accepted latency measurements. Fresh Finder and Settings timings remain for the desktop reviewer.

### Ranking trade-off and migration

The fast route stops after enough exact non-menu hits. It ranks the visited candidates, so a later equally exact but smaller/more interactive control may not be considered. This is now stated in both find-tool descriptions. `query_elements` preserves full bounded ranking and role-regex behavior. Semantic targets are never put on the fast route.

See [Migration notes](docs/MIGRATION-0.10.md): `role:"Button"` now means only `AXButton`; use `query_elements role_regex:"Button"` for the previous broad role match.

### Files and review

Changed production paths:

- `Sources/MacControlMCP/AXSearch.swift`: shared traversal, bounded running results, eligibility-aware early exit.
- `Sources/MacControlMCP/AccessibilityController.swift`: live traversal adapter and real read counts.
- `Sources/MacControlMCP/Tools.swift`, `Sources/MacControlMCP/Tools+V2.swift`: metrics, filter wiring, and honest descriptions.
- `Sources/MacControlMCP/AXAttributeBatch.swift`: omit empty DOM id/class metadata.

Tests: `AXSearchTraversalTests.swift` and `AXAttributeBatchTests.swift`. Docs: `docs/TOOLS.md`, `docs/MIGRATION-0.10.md`, this file, and a supersession note in the historical `S5_REPORT.md`.

The independent reviewer approved the final code delta after the eligibility regression was fixed. Existing commits were not amended or reverted. Commit-attempt outcome is recorded below.

### Commit outcome

During this work, the reviewer committed the initial regression repair as:

```text
15f412b feat(v0.10-web): Codex (gpt-6-astra) implementation round, committed by reviewer (sandbox cannot write index.lock)
```

The eligibility fix and final documentation remain uncommitted. Attempted conventional commit:

```text
fix: apply search eligibility before early exit

v0.10 C5: only interactive and visible candidates may consume the ranked result limit. Preserve semantic traversal and document the exact-hit shortcut, role migration and reproducible regression probes.
```

`git add` failed before the commit could run (exit 128):

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-web/index.lock': Operation not permitted
```

No commits were amended, reverted, pushed, merged or rebased. The final tests above cover the working tree including the uncommitted eligibility fix.

## Round-2 commit attempt

Attempted commit:

```text
perf: reuse semantic alias regular expressions

v0.10 C5: Finder exposes a text field per file row. Cache constant alias and camelCase patterns once, and reject unrelated labels before normalization. The 5000-field regression benchmark drops from 8535 ms to 27 ms; preserve alias boundaries and document the desktop timing probe.
```

`git add` failed before the commit could run (exit 128):

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-web/index.lock': Operation not permitted
```

The three round-2 files remain uncommitted: `Sources/MacControlMCP/AXSearch.swift`, `Tests/MacControlMCPTests/SemanticSearchTests.swift`, and `LIVE-CHECKS.md`.
