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

---

# S3 C2 — Finder cold-start en floating headers

## Voorwaarden

Gebruik de bestaande Finder-lijstweergave uit de review: pid **742**, Name **(809.5,105)**, Size **(1444.5,105)**, Kind **(1550.5,105)**. Pas geen gebruikersvensters aan. Bij gewijzigde layout moeten de actuele coördinaten eerst read-only worden vastgesteld.

## Exacte probe: eerste hit direct herhalen

Start een nieuw serverproces via de onderstaande probe. De **eerste twee toolcalls** raken hetzelfde Name-punt: eerst koud, dan direct nogmaals. Daarna volgen acht afwisselende runs voor Size en Kind. Voer geen AX-warmup in hetzelfde proces uit vóór die eerste Name-call.

```sh
SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
PROBE_MAX=300000 python3 "$SCRATCH/probe.py" .build/debug/mac-control-mcp '[
  ["element_at_point",{"pid":742,"x":809.5,"y":105}],
  ["element_at_point",{"pid":742,"x":809.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}]
]' | tee s3-evidence/round3-header-live.txt
```

De identieke 18 calls staan in [round3-header-calls.json](s3-evidence/round3-header-calls.json). Om het zeldzame cold-start-geval opnieuw te bemonsteren kan de hele opdracht herhaald worden: iedere probe start een nieuw proces. Bewaar elke uitvoer afzonderlijk.

## Acceptatie

- Name: eerste én herhaalde hit zijn de betreffende `AXButton`; controleer dat het gerapporteerde frame het punt bevat met maximaal **1 punt tolerantie**.
- Een afwijkend direct AX-frame mag nooit `hit_test_quality: direct` opleveren. Een gevonden vervanger meldt `geometric`; zonder vervanger blijft de oorspronkelijke hit gemarkeerd als `direct_out_of_frame`. Dat is een eerlijke foutmarkering, geen correcte Name-hit.
- Size en Kind: elk **8/8 AXButton** met juiste titel; geen overlappende inhoudsrij/-cel.
- Header-latencydoel **≤150 ms**; rapporteer p50 en min/max en houd de koude eerste Name-call afzonderlijk zichtbaar.
- `permission_missing`, onbereikbare doelen en gewijzigde layout leveren geen bruikbare precisie- of snelheidsclaim op.

## Gerichte suites

```sh
script -q /dev/null swift test --no-parallel --filter 'GeometricHitTestTests|ElementAtPointTests|Phase9ToolsTests'
```

In de beperkte uitvoeromgeving worden aanvullend `CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache` en `--disable-sandbox` gebruikt. De volledige desktopsuite wordt niet gestart.

---

# S1 — live-checks voor de desktopreviewer

Codex heeft geen desktoptoegang. De hieronder beschreven checks zijn daarom **overgedragen, niet live geslaagd**. Voer ze uit vanuit Claude/de bestaande vertrouwde desktopsessie, in deze worktree. Wijzig geen permissies. Geen clicks, typing, window moves, clipboardwrites of wijzigingen aan bestaande documenten. Alleen A1 opent tijdelijk één eigen Finder-window; de cleanup sluit uitsluitend het geretourneerde nieuwe window-id.

## 1. Build en actuele discovery

```sh
export S1_WORKTREE="$PWD"
export S1_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
mkdir -p .s1-evidence/reviewer
swift build
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp '[["permissions_status",{}],["list_apps",{}],["list_windows",{}]]' | tee .s1-evidence/reviewer/discovery.txt
```

Verwacht: Accessibility en Screen Recording zijn verleend; Finder en Google Chrome hebben actuele pids en vensters. Bij ontbrekende toegang: meld de blokkade, pas geen instellingen aan. Gebruik geen pids of coördinaten uit de oude audit zonder nieuwe discovery.

## 2. Maak de persistente NDJSON-probe

`SCRATCH/probe.py` sluit zijn server na de laatste call. Losse invocaties kunnen daardoor geen gecachete id vasthouden terwijl AppleScript het menu verandert. Onderstaande volledige helper gebruikt hetzelfde `initialize`/`tools/call`-protocol, maar houdt één server open voor de afhankelijke A1/A2/A8-calls. Alle verzoeken, antwoorden en tijden worden gelogd. De losse stock-probe voor Chrome staat verderop.

```sh
cat > .s1-evidence/reviewer/session.py <<'PY'
import json
import os
import re
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

binary = os.environ.get("S1_BINARY", ".build/debug/mac-control-mcp")
mode = os.environ.get("S1_MODE", "check")
window_menu = os.environ.get("S1_WINDOW_MENU", "Window")
out = Path(os.environ.get("S1_OUTPUT", ".s1-evidence/reviewer"))
out.mkdir(parents=True, exist_ok=True)
server_errors = (out / "server-stderr.txt").open("w")
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=server_errors)
buffer = b""
request_id = 0
created_window = None


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rpc(method, params):
    global buffer, request_id
    request_id += 1
    rid = request_id
    started = time.perf_counter()
    request = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
    p.stdin.write((json.dumps(request) + "\n").encode())
    p.stdin.flush()
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == rid:
                elapsed = (time.perf_counter() - started) * 1000
                print(json.dumps({"request": request, "ms": elapsed, "response": response}, ensure_ascii=False), flush=True)
                require("error" not in response, "JSON-RPC error")
                return response["result"], elapsed
        ready, _, _ = select.select([p.stdout], [], [], 0.05)
        if ready:
            chunk = os.read(p.stdout.fileno(), 1 << 20)
            require(bool(chunk), "server closed stdout")
            buffer += chunk
    raise TimeoutError(f"request {rid}")


def tool(name, args):
    response, elapsed = rpc("tools/call", {"name": name, "arguments": args})
    payload = response.get("structuredContent")
    require(isinstance(payload, dict), f"missing structuredContent: {name}")
    return payload, elapsed


def success(name, args):
    payload, _ = tool(name, args)
    require(payload.get("ok") is True, f"{name} failed: {payload}")
    return payload


def app_pid(apps, bundle):
    matches = [a for a in apps if a.get("bundleIdentifier") == bundle or a.get("bundle_id") == bundle]
    require(len(matches) == 1, f"cannot uniquely discover {bundle}: {matches}")
    return int(matches[0]["pid"])


def applescript(source):
    result = subprocess.run(["osascript", "-e", source], text=True, capture_output=True, timeout=20, check=True)
    print(json.dumps({"osascript": source, "stdout": result.stdout, "stderr": result.stderr}), flush=True)
    return result.stdout.strip()


def finder_window_ids():
    raw = applescript('tell application "Finder" to get id of every Finder window')
    require(not raw or re.fullmatch(r"[0-9, ]+", raw), f"invalid Finder ids: {raw}")
    return {int(x.strip()) for x in raw.split(",") if x.strip()}


def paths(pid):
    return success("list_menu_paths", {"pid": pid, "max_depth": 6})["paths"]


def attributes(element_id):
    return tool("get_element_attributes", {"element_id": element_id, "names": ["AXRole", "AXTitle"]})[0]


def same_or_stale(saved, phase):
    remaining = {}
    stale = 0
    for element_id, original in saved.items():
        current = attributes(element_id)
        if current.get("error_code") == "stale_element":
            stale += 1
            continue  # stale entries are removed; do not query that id again.
        require(current.get("ok") is True, f"{phase}: unexpected id error: {current}")
        require(current.get("values") == original, f"{phase}: SILENT RETARGET {original} -> {current}")
        remaining[element_id] = original
    print(json.dumps({"check": "A1", "phase": phase, "same": len(remaining), "stale": stale, "wrong": 0}), flush=True)
    return remaining


def check_menu(finder):
    global created_window
    before_paths = paths(finder)
    window_paths = [q for q in before_paths if len(q) > 1 and q[0] == window_menu]
    require(window_paths, f"no {window_menu!r} menu; inspect list_menu_paths and set S1_WINDOW_MENU to the actual localized title")
    # A unique leaf title avoids minting a same-named item in another menu.
    leaf_counts = {}
    for q in before_paths:
        if q:
            leaf_counts[q[-1]] = leaf_counts.get(q[-1], 0) + 1
    candidates = sorted({q[-1] for q in window_paths if leaf_counts[q[-1]] == 1})
    saved = {}
    for title in candidates[:20]:
        found = success("find_elements", {"pid": finder, "role": "AXMenuItem", "title": title, "exact": True, "limit": 20})
        for row in found["elements"]:
            current = attributes(row["id"])
            values = current.get("values", {})
            if current.get("ok") and values.get("AXRole") == "AXMenuItem" and values.get("AXTitle") == title:
                saved[row["id"]] = values
    require(saved, "no readable Window-menu ids were minted; no window has been opened")
    before_ids = finder_window_ids()
    require(before_ids, "A1 needs an existing Finder window; do not alter an existing user window to prepare it")
    raw = applescript('tell application "Finder"\nset s1Window to make new Finder window\nreturn id of s1Window\nend tell')
    require(re.fullmatch(r"[0-9]+", raw) is not None, "window created but no numeric id returned: stop and report; do not guess a cleanup target")
    candidate_id = int(raw)
    require(candidate_id not in before_ids, "Finder returned a pre-existing id; refusing to close it")
    created_window = candidate_id
    try:
        require(created_window in finder_window_ids(), "new Finder window not visible to AppleScript")
        deadline = time.monotonic() + 5
        after_paths = paths(finder)
        while after_paths == before_paths and time.monotonic() < deadline:
            time.sleep(0.2)
            after_paths = paths(finder)
        require(after_paths != before_paths, "INCONCLUSIVE A1: Window/menu contents did not change in AX")
        saved = same_or_stale(saved, "own window open")
    finally:
        applescript(f'tell application "Finder" to close Finder window id {created_window}')
        created_window = None
    same_or_stale(saved, "own window closed")
    print(json.dumps({"check": "A1", "coverage": "menu_mutation_smoke", "live_relabel_reproduced": "not established by unchanged targets; inspect raw before/after values"}), flush=True)
    require(before_ids.issubset(finder_window_ids()), "a pre-existing Finder window disappeared; stop and report")


def check_chrome(chrome):
    listed = success("list_windows", {"pid": chrome})
    windows = [w for w in listed["windows"] if w.get("window_id") and not w.get("minimized")]
    require(windows, "Chrome has no identifiable non-minimized window")
    find_args = {"pid": chrome, "role": "AXLink", "exact": True, "max_depth": 32, "limit": 500}
    text_args = dict(find_args, role="AXStaticText")
    tree_args = {"pid": chrome, "max_depth": 32, "fields": ["id", "role", "children"]}
    found = success("find_elements", find_args)
    texts = success("find_elements", text_args)
    nodes = success("get_ui_tree", tree_args)["nodes"]
    tree_by_id = {node["id"]: node for node in nodes}
    by_id = {row["id"]: row for row in found["elements"] + texts["elements"]}
    warmed = False
    for row in found["elements"]:
        pos, size = row.get("position", {}), row.get("size", {})
        if size.get("width", 0) < 2 or size.get("height", 0) < 2:
            continue
        x, y = pos["x"] + size["width"] / 2, pos["y"] + size["height"] / 2
        owners = [w for w in windows if w["x"] <= x <= w["x"] + w["width"] and w["y"] <= y <= w["y"] + w["height"]]
        if not owners:
            continue
        # v0.10 A8 R2: rendered text belongs to a link but has its own id.
        child_ids = {nodes[i]["id"] for i in tree_by_id.get(row["id"], {}).get("children", [])}
        expected = [by_id[i] for i in {row["id"]} | child_ids if i in by_id]
        hit_args = {"pid": chrome, "x": x, "y": y}
        if not warmed:
            success("element_at_point", hit_args)  # Chrome may initially return AXWebArea.
            warmed = True
        hit = success("element_at_point", hit_args)
        matches = [candidate for candidate in expected
                   if hit.get("role") == candidate.get("role") and hit.get("title") == candidate.get("title")
                   and hit.get("bounds") == dict(candidate.get("position", {}), **candidate.get("size", {}))]
        if not matches or hit.get("pid") != chrome:
            continue
        require(hit.get("stable_id") is True and hit.get("element_id") in {m["id"] for m in matches},
                f"A8: web hit differs from link or direct child identity: {hit}")
        again = success("element_at_point", hit_args)
        require(again.get("stable_id") is True and again.get("element_id") == hit["element_id"]
                and all(again.get(k) == hit.get(k) for k in ("pid", "role", "title", "bounds")),
                "A8 repeated hit changed its identity")
        calls = [["list_windows", {"pid": chrome}], ["find_elements", find_args],
                 ["find_elements", text_args], ["get_ui_tree", tree_args],
                 ["element_at_point", hit_args], ["element_at_point", hit_args], ["element_at_point", hit_args]]
        (out / "chrome-probe-calls.json").write_text(json.dumps(calls))
        print(json.dumps({"check": "A8", "window_id": owners[0]["window_id"], "link_id": row["id"],
                          "id": hit["element_id"], "child_ids": sorted(child_ids), "stable_id": True}), flush=True)
        return hit["element_id"], attributes(hit["element_id"])["values"]
    raise RuntimeError("INCONCLUSIVE A8: no visible Chrome link or direct text child matched; do not navigate or click a user tab")


def check_retention(finder, other):
    buttons = success("find_elements", {"pid": finder, "role": "AXButton", "exact": True, "limit": 20})["elements"]
    require(buttons, "A2: no Finder button for the old-id check")
    old = buttons[0]["id"]
    expected = attributes(old)
    require(expected.get("ok") is True and expected.get("values", {}).get("AXRole"), "A2: unreadable initial handle")
    sizes = []
    for index in range(6):
        tree = success("get_ui_tree", {"pid": finder, "max_depth": 12})
        sizes.append(tree["nodes_visited"])
        for element_id, values in [(old, expected["values"]), other]:
            current = attributes(element_id)
            require(current.get("ok") is True and current.get("values") == values,
                    f"A2: retained id failed after tree {index + 1}: {current}")
    print(json.dumps({"check": "A2", "walk_sizes": sizes, "old_finder_id": old, "other_pid_id": other[0], "retained": True}), flush=True)
    require(all(n == 2000 for n in sizes), "INCONCLUSIVE A2 full-scale check: ids survived, but the current Finder view did not produce six 2000-node walks")


def check_visits(finder):
    tree = success("get_ui_tree", {"pid": finder, "max_depth": 1})
    for name, filt in [("find_elements", {"role": "AXS1ImpossibleRole"}), ("query_elements", {"role_regex": "^AXS1ImpossibleRole$"})]:
        result = success(name, {"pid": finder, "max_depth": 1, **filt})
        require(result["count"] == 0, "unexpected impossible-role match")
        require(result["nodes_visited"] == tree["nodes_visited"] and result["nodes_visited"] > 0,
                f"A6: visit count differs from same-depth tree: {result} vs {tree['nodes_visited']}")
    result = success("list_elements", {"pid": finder, "max_depth": 1})
    require(result["nodes_visited"] == tree["nodes_visited"], "A6 list_elements visit count differs from tree")
    print(json.dumps({"check": "A6", "visited": tree["nodes_visited"], "zero_matches_counted_honestly": True}), flush=True)


def measure(finder, chrome):
    # Seed one stable menu handle in THIS session; stock perf.py cannot
    # resolve an id minted by a previous server process.
    menu = success("find_elements", {"pid": finder, "role": "AXMenuItem", "title": os.environ.get("S1_PERF_MENU_TITLE", "Minimize"), "exact": True, "limit": 20})["elements"]
    require(len(menu) == 1, "choose a unique visible Window-menu title using S1_PERF_MENU_TITLE")
    element_id = menu[0]["id"]
    expected_fingerprint = attributes(element_id).get("values", {})
    require(expected_fingerprint.get("AXRole") == "AXMenuItem", "unreadable benchmark handle")
    cases = [
        ("resolveLive/get_element_attributes", "get_element_attributes", {"element_id": element_id, "names": ["AXRole", "AXTitle"]}),
        ("Finder tree", "get_ui_tree", {"pid": finder, "max_depth": 12}),
        ("Finder find", "find_elements", {"pid": finder, "role": "AXButton", "limit": 20}),
        ("Finder query", "query_elements", {"pid": finder, "title_regex": "^Eject$"}),
        ("Finder list", "list_elements", {"pid": finder}),
        ("Chrome links", "find_elements", {"pid": chrome, "role": "AXLink", "limit": 20}),
    ]
    validated_calls = json.loads(Path('.s1-evidence/reviewer/check/chrome-probe-calls.json').read_text())
    hit_args = next(args for name, args in validated_calls if name == 'element_at_point')
    require(hit_args['pid'] == chrome, 'Chrome pid changed since the link check; repeat discovery')
    cases.append(('Chrome hit', 'element_at_point', hit_args))
    results = []
    for label, name, args in cases:
        warm = success(name, args)
        if name == "element_at_point":
            # v0.10 A8 R2: first Chrome hit may be AXWebArea; compare a
            # second hit to its own AXStaticText/AXLink search identity.
            warm = success(name, args)
            require(warm.get("role") in ("AXLink", "AXStaticText", "AXImage"), "benchmark point no longer hits web content")
            reference = success("find_elements", {"pid": chrome, "role": warm["role"],
                "title": warm.get("title"), "exact": True, "max_depth": 32, "limit": 500})["elements"]
            matches = [row for row in reference if row.get("role") == warm.get("role")
                       and row.get("title") == warm.get("title")
                       and dict(row.get("position", {}), **row.get("size", {})) == warm.get("bounds")]
            require(matches, "benchmark hit is absent from fresh find_elements")
            if warm.get("stable_id"):
                require(warm.get("element_id") in {row["id"] for row in matches}, "benchmark id differs from search")
        samples = []
        for _ in range(7):
            value, elapsed = tool(name, args)
            require(value.get("ok") is True, f"benchmark error: {value}")
            if name == "get_element_attributes":
                require(value.get("values") == expected_fingerprint, "benchmark handle changed title or role")
            if name == "element_at_point":
                require(all(value.get(key) == warm.get(key) for key in ("pid", "role", "title", "bounds")), "benchmark link moved or changed")
                if warm.get("stable_id"):
                    require(value.get("stable_id") is True and value.get("element_id") == warm["element_id"], "benchmark id changed")
            if name == "get_ui_tree":
                require(value["nodes_visited"] > 1, "unreadable/empty tree cannot be benchmarked")
            samples.append(elapsed)
        results.append({"case": label, "tool": name, "args": args, "samples_ms": samples, "p50_ms": statistics.median(samples), "last_payload": value})
    (out / "measurements.json").write_text(json.dumps(results, indent=2))


exit_code = 0
try:
    rpc("initialize", {})
    permissions = success("permissions_status", {})
    require(permissions.get("accessibility") == "granted", "desktop Accessibility grant is required; do not change settings")
    apps = success("list_apps", {})["apps"]
    finder = app_pid(apps, "com.apple.finder")
    chrome = app_pid(apps, "com.google.Chrome")
    if mode == "measure":
        measure(finder, chrome)
    else:
        failures = []
        for label, check in [("A1", lambda: check_menu(finder)), ("A6", lambda: check_visits(finder))]:
            try:
                check()
            except Exception as error:
                failures.append(f"{label}: {error}")
        other = None
        try:
            other = check_chrome(chrome)
        except Exception as error:
            failures.append(f"A8: {error}")
        if other:
            try:
                check_retention(finder, other)
            except Exception as error:
                failures.append(f"A2: {error}")
        else:
            failures.append("A2: cross-pid retention could not run without a readable Chrome id")
        require(not failures, "\n".join(failures))
    print(json.dumps({"status": "PASS", "mode": mode}), flush=True)
except Exception as error:
    print(json.dumps({"status": "FAIL_OR_INCONCLUSIVE", "error": str(error)}), flush=True)
    exit_code = 1
finally:
    if created_window is not None:
        try:
            applescript(f'tell application "Finder" to close Finder window id {created_window}')
        except Exception as error:
            print(json.dumps({"cleanup_failed_window_id": created_window, "error": str(error)}), flush=True)
            exit_code = 1
    p.stdin.close()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
    server_errors.close()
sys.exit(exit_code)
PY
S1_MODE=check S1_OUTPUT=.s1-evidence/reviewer/check python3 .s1-evidence/reviewer/session.py > .s1-evidence/reviewer/check.jsonl
cat .s1-evidence/reviewer/check.jsonl
```

Verwachte uitkomsten:

- **A1 (menu-mutatie-smoketest):** vóór de mutatie bestaan leesbare Window-menu-ids. Openen verandert de menu-inhoud. Daarna retourneert iedere nog bekende id dezelfde `AXRole`/`AXTitle`, of `stale_element`; nooit `ok:true` voor een andere titel. Na sluiten van uitsluitend het nieuwe window geldt hetzelfde. `wrong:0`; een positief aantal stale-antwoorden is niet verplicht als deze menu-items hun identiteit behouden. De oorspronkelijke windows blijven bestaan. Als alle targets ongewijzigd blijven, is de concrete live relabelbug **niet gereproduceerd**, ook als de smoketest slaagt; de oude baseline kan zo ook slagen. Voor live-regressiebewijs moet minimaal één opgeslagen target aantoonbaar veranderen of verdwijnen. De deterministische relabel-regressie is apart afgedekt door de fake-test: terugzetten van de oude `isAlive`-route geeft RED, herstellen van de fingerprintcontrole GREEN. Label de revieweruitkomst dus niet sterker dan het bewijs.
- **A2:** zes Finder-walks van 2.000 nodes, terwijl zowel de oude Finder-id als een Chrome-id leesbaar blijven. `unknown_element_id`/`evicted_element_id` zijn hier fouten. Het echte overschrijden van 20.000 unieke cache-entries en de specifieke evictionfoutcode zijn afgedekt door de fake/unit-tests; stabiele herhaalde trees alleen overschrijden de cache niet.
- **A6:** bij nul zoekmatches is `nodes_visited` positief en gelijk aan de treewalk op dezelfde diepte. Bij een spontaan veranderende UI de read-only check opnieuw uitvoeren; stuur blijvende verschillen terug.
- **A8:** de gekozen link ligt binnen een expliciet gelogde `window_id`; search en beide hit-tests retourneren hetzelfde id, `stable_id:true`. Als geen pad mogelijk is, moet `stable_id_reason` aanwezig zijn. Een verklaarde fallback is eerlijk maar bewijst de Chrome-rootfix niet: stuur de volledige ancestor-chain terug.
- De algemene `status:PASS` betekent dat de beschreven checks en de A1-smoketest slagen; het is geen claim dat een positionele relabel live is gereproduceerd. `FAIL_OR_INCONCLUSIVE` en cleanupfouten zijn geen geslaagde live checks. Het script print fouten expliciet en stopt met exitcode 1.

Herhaal de concrete Chrome-calls ook met de voorgeschreven stock-probe:

```sh
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/check/chrome-probe-calls.json)" | tee .s1-evidence/reviewer/chrome-stock-probe.txt
```

Dit bestand bestaat alleen nadat een echte link is gevonden. De eerste `find_elements` mint de ids opnieuw binnen deze nieuwe server; de twee hit-tests moeten daarmee overeenkomen.

## 3. Voor/na: identieke probe en actuele desktop

De oude sandbox-na-meting in `.s1-evidence/perf-after.json` is ongeldig als snelheidsvergelijking: die zag geen desktop. Gebruik de volgende vergelijking. Deze bouwt de vastgepinde 0.9.0-baseline `cb435a8` (parent van WIP `9dcec32`) in een **submap van dezelfde worktree**, zonder checkout, rebase of wijziging van WIP-commits.

```sh
set -e
mkdir -p .build/s1-baseline-src
# Gebruik een lege baseline-map; stop als er al oude bronnen in staan.
test ! -e .build/s1-baseline-src/Package.swift
git archive cb435a8 | tar -x -C .build/s1-baseline-src
swift build --package-path .build/s1-baseline-src --scratch-path .build/s1-baseline-build
S1_BINARY=.build/s1-baseline-build/debug/mac-control-mcp S1_MODE=measure S1_OUTPUT=.s1-evidence/reviewer/before python3 .s1-evidence/reviewer/session.py > .s1-evidence/reviewer/before.jsonl
S1_BINARY=.build/debug/mac-control-mcp S1_MODE=measure S1_OUTPUT=.s1-evidence/reviewer/after python3 .s1-evidence/reviewer/session.py > .s1-evidence/reviewer/after.jsonl
python3 - <<'PY'
import json
from pathlib import Path
before = json.loads(Path('.s1-evidence/reviewer/before/measurements.json').read_text())
after = json.loads(Path('.s1-evidence/reviewer/after/measurements.json').read_text())
assert [r['case'] for r in before] == [r['case'] for r in after]
for old, new in zip(before, after):
    assert old['tool'] == new['tool'] and old['args'] == new['args'], 'App/path changed between measurements; rerun against the same UI'
    print(f"{old['case']}: p50 {old['p50_ms']:.3f} -> {new['p50_ms']:.3f} ms")
PY
```

Verwacht: beide JSONL-runs eindigen met `status:PASS`, alle calls `ok:true`, echte bomen met meer dan één node. Ze gebruiken dezelfde helper, warme sessies en zeven gemeten herhalingen. Laat de desktop tussen beide runs gelijk. `resolveLive/get_element_attributes` meet de nieuwe leafcontrole zonder een nieuwe zoekactie per sample. Rapporteer alle samples en p50, ook als de wijziging langzamer is.

De oorspronkelijke auditcases kunnen daarnaast met exact dezelfde `SCRATCH/perf.py` worden herhaald. Maak eerst een casebestand met de **actuele** pids uit discovery en bewaar datzelfde bestand voor beide binaries; gebruik de oude audit-pids niet blind. De sessiehelper hierboven dekt ook cached-id-resolutie, die de statische perf.py niet kan seeden.

De eis van maximaal één extra IPC betreft de intacte live-handle-route. De fake-cachetest verifieert één fingerprint-read, geen extra liveness-read, en geen repair. `AXPath.fingerprint` gebruikt één `AXAttributeBatch.fetch(...fallbackOnFailure:false)`: geen per-attribuut fallback. Padherstel bij een mismatch mag meerdere reads nodig hebben. **Latentie alleen bewijst geen aantal kernel-IPC-calls**; meld de tijden als tijden, niet als IPC-counts.

## 4. Bestaande live suites en resultaten terugsturen

```sh
script -q /dev/null swift test --no-parallel --filter AXPathTests > .s1-evidence/reviewer/AXPathTests.txt 2>&1
script -q /dev/null swift test --no-parallel --filter AnnotatedElementIdentityTests > .s1-evidence/reviewer/AnnotatedElementIdentityTests.txt 2>&1
script -q /dev/null swift test --no-parallel --filter AXHandleSafetyTests > .s1-evidence/reviewer/AXHandleSafetyTests.txt 2>&1
script -q /dev/null swift test --no-parallel --filter AXPayloadBudgetTests > .s1-evidence/reviewer/AXPayloadBudgetTests.txt 2>&1
```

Verwacht: geen assertion failures én geen trust-/Finder-/Screen Recording-skipmeldingen. Draai niet de volledige suite. De aangevraagde TextEditingTests zijn headless en al gedraaid; er is geen reden om een gebruikersdocument te wijzigen.

Stuur bij een fout de relevante JSONL-regels, pids/window_id, oorspronkelijke en actuele titel, eventuele `stable_id_reason`/ancestors en suite-output terug. Trim uitsluitend eventuele base64-afbeeldingsvelden uit teruggestuurde capture-output; bewaar foutcodes, bounds en ids. De probe hierboven maakt zelf geen screenshots en schrijft niet naar het clipboard.


## 5. Git-handoff wanneer de administratieve Git-map hier niet schrijfbaar is

Codex kon geen `index.lock` schrijven in `/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ids`. Indien dit bij overdracht nog zo is, kan de reviewer onderstaande conventionele commits op **dezelfde branch** maken. De bestaande WIP blijft intact; geen amend/rebase/merge/push. Controleer eerst `git status --short --branch` en commit uitsluitend de S1-bestanden.

```sh
git status --short --branch
git add Sources/MacControlMCP/ElementCache.swift Sources/MacControlMCP/TextEditingController.swift Sources/MacControlMCP/Tools+TextEditing.swift Tests/MacControlMCPTests/ElementCacheTests.swift Tests/MacControlMCPTests/TextEditingTests.swift
git commit -m 'fix: finish cache retention and live identity verification' -m 'v0.10 A1/A2: verify relabel and repair behavior with a fake AX resolver, reserve slots for repeated collision quarantine, and derive text hints from configured cache limits.'
git add Sources/MacControlMCP/Tools+V0_9AXCore.swift Sources/MacControlMCP/Tools+V2.swift docs/TOOLS.md
git commit -m 'fix: explain element identity and retention limits' -m 'v0.10 A2/A8: report the random-id fallback reason and document the independent walk and cache limits. Regenerated tool documentation matches the registry.'
git add LIVE-CHECKS.md
git commit -m 'test: document reproducible S1 desktop verification' -m 'Provide persistent NDJSON probes with owned-window cleanup, explicit expected outcomes, and a pinned before/after benchmark so a desktop-capable reviewer can finish the live checks.'
```

De headless RED/GREEN-logs en het eindrapport staan in `.s1-evidence/`. De nieuw te genereren `.s1-evidence/reviewer/`-output hoort bij de review; die is nog niet door Codex geproduceerd of geclaimd als geslaagd.

## 8. A8 herreview — gerenderde Chrome-webinhoud (tekstlinks én afbeelding)

Deze check is toegevoegd na de review waarin native toolbar-hits wel stabiel waren,
maar vier hits op drie webtargets geen pad kregen. A1/A2/A6 zijn volgens die review
afgerond. **Onderstaande A8-run is nog niet door Codex live uitgevoerd.**

De reconstructie probeert eerst de parent-chain (`parent_chain`). Bij gebroken
parents volgt `top_down`: eerst geometrisch begrensd, daarna onbegrensd door
geometrie als de eerste poging geen verifieerbare hit oplevert. Kinderen houden
hun originele AXChildren/AXSheets-ordinals; alleen bevattende frames en ontbrekende
of zero-size frames worden in de eerste poging verder doorzocht. CFEqual heeft
voorrang. Een alias na uitgesloten takken vereist de volledige fallback om verborgen
duplicaten/overflow te controleren. Maximaal 32 niveaus en 12.000 unieke node-reads
over alle pogingen samen; de memo wordt tussen pogingen hergebruikt. Een gedeeltelijke
of ambigue aliaszoekactie blijft `stable_id:false`, met bijvoorbeeld
`no_app_root;top_down_node_cap` of `parent_chain_break_at_depth_4;top_down_ambiguous`.

De snelle route veronderstelt dat een exacte hit niet ook onder een eerder,
geometrisch uitgesloten parent hangt. Bij zulke gedeelde overflow-handles met
ontbrekende parent-chain kan het gevonden pad afwijken van de eerste volledige
DFS-vindplaats. De handle is dan exact dezelfde, maar globale id-pariteit kan zonder
het doorzoeken van die uitgesloten takken niet worden gegarandeerd. Bekende
parent-paden met gedeelde handles behouden hun volledige canonieke DFS-controle.

Voer dit uit in de huidige worktree met dezelfde reeds geopende Hacker News-pagina
als bij de vorige review. De helper navigeert, klikt, scrollt of typt niet. Hij
vereist dat de targets via de child-indices van `get_ui_tree` onder een
`AXWebArea` vallen: een native toolbar-hit kan de check dus niet laten slagen.
Bij ontbrekende targets of gewijzigde/afgedekte pagina: rapporteer INCONCLUSIVE;
verander geen bestaande tab om de check passend te maken.

```sh
export S1_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
mkdir -p .s1-evidence/reviewer/a8-web
cat > .s1-evidence/reviewer/a8-web/check.py <<'PY'
import json
import os
import re
import shlex
import subprocess
from pathlib import Path

out = Path('.s1-evidence/reviewer/a8-web') / os.environ.get('S1_A8_LABEL', 'after')
out.mkdir(parents=True, exist_ok=True)
binary = os.environ.get('S1_BINARY', '.build/debug/mac-control-mcp')
probe = str(Path(os.environ['S1_SCRATCH']) / 'probe.py')
env = dict(os.environ, PROBE_MAX='300000')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(label, calls):
    argv = ['python3', probe, binary, json.dumps(calls)]
    (out / (label + '-calls.json')).write_text(json.dumps(calls, indent=2))
    (out / (label + '-command.sh')).write_text('PROBE_MAX=300000 ' + shlex.join(argv) + '\n')
    completed = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=900, check=True)
    (out / (label + '.txt')).write_text(completed.stdout)
    require(not completed.stderr, completed.stderr)
    headers = list(re.finditer(r'^--- [^\n]+\n', completed.stdout, re.MULTILINE))
    require(len(headers) == len(calls), 'missing stock-probe response headers')
    results = []
    for index, header in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(completed.stdout)
        payload = json.loads(completed.stdout[header.end():end])
        require(isinstance(payload, dict) and payload.get('ok') is True,
                f'{label} {calls[index]} failed: {payload}')
        results.append(payload)
    return results


apps, all_windows = run('discovery', [['list_apps', {}], ['list_windows', {}]])
chrome = [a for a in apps['apps'] if (a.get('bundleIdentifier') or a.get('bundle_id')) == 'com.google.Chrome']
require(len(chrome) == 1, 'INCONCLUSIVE: need one running Google Chrome')
pid = chrome[0]['pid']
windows = [w for w in all_windows['windows'] if w.get('pid') == pid and not w.get('minimized')]
require(windows, 'INCONCLUSIVE: no Chrome window')
link_args = {'pid': pid, 'role': 'AXLink', 'exact': True, 'max_depth': 32, 'limit': 500,
             'fields': ['id', 'role', 'title', 'position', 'size'], 'max_bytes': 100000}
image_args = dict(link_args, role='AXImage')
text_args = dict(link_args, role='AXStaticText')
tree_args = {'pid': pid, 'max_depth': 32, 'fields': ['id', 'role', 'children'], 'max_bytes': 180000}
tree, links, images = run('targets', [
    ['get_ui_tree', tree_args],
    ['find_elements', link_args], ['find_elements', image_args]])
nodes = tree['nodes']
web_ids = set()
seen = set()


def mark(index, in_web=False):
    if index in seen:
        return
    seen.add(index)
    node = nodes[index]
    in_web = in_web or node.get('role') == 'AXWebArea'
    if in_web:
        web_ids.add(node.get('id'))
    for child in node.get('children', []):
        mark(child, in_web)


if nodes:
    mark(0)


def point(row, fraction=0.5):
    pos, size = row.get('position') or {}, row.get('size') or {}
    if size.get('width', 0) < 4 or size.get('height', 0) < 4:
        return None
    x = pos['x'] + fraction * size['width']
    y = pos['y'] + size['height'] / 2
    owners = [w for w in windows if w['x'] <= x <= w['x'] + w['width']
              and w['y'] <= y <= w['y'] + w['height']]
    if not owners:
        return None
    return {'pid': pid, 'x': x, 'y': y}, owners[0]['window_id']


def select(rows, title=None):
    matches = [r for r in rows if r.get('id') in web_ids
               and (title is None or r.get('title') == title) and point(r)]
    require(matches, f'INCONCLUSIVE: no visible web target {title or "AXImage"}; tree may be truncated')
    return matches[0]


hn = select(links['elements'], 'Hacker News')
new = select(links['elements'], 'new')
image = select(images['elements'])
plan = [(hn, 0.25), (hn, 0.75), (new, 0.5), (image, 0.5)]
calls = [['get_ui_tree', tree_args], ['find_elements', link_args],
         ['find_elements', image_args], ['find_elements', text_args]]
# v0.10 A8 R2: discard exactly the first hit after this server starts.
calls.append(['element_at_point', point(plan[0][0], plan[0][1])[0]])
for row, fraction in plan:
    chosen = point(row, fraction)
    require(chosen, 'INCONCLUSIVE: target point outside current window')
    calls.extend([['element_at_point', chosen[0]], ['element_at_point', chosen[0]]])
responses = run('identity', calls)
current = {r['id']: r for p in responses[1:4] for r in p['elements']}
current_nodes = responses[0]['nodes']
current_tree = {node['id']: node for node in current_nodes}
report = []
for index, (row, fraction) in enumerate(plan):
    first, second = responses[5 + 2 * index:7 + 2 * index]
    args, window_id = point(row, fraction)
    live_row = current.get(row['id'])
    # v0.10 A8 R2: verify link OR direct child against its own search metadata.
    pos, size = row['position'], row['size']
    allowed = {row['id']} | {current_nodes[i]['id'] for i in current_tree.get(row['id'], {}).get('children', [])}
    expected = [current[i] for i in allowed if i in current]

    def matching(hit):
        return [r for r in expected if hit.get('pid') == pid and hit.get('role') == r.get('role')
                and hit.get('title') == r.get('title')
                and hit.get('bounds') == dict(r.get('position', {}), **r.get('size', {}))]

    valid_target = bool(live_row and live_row.get('position') == pos and live_row.get('size') == size
                        and live_row.get('title') == row.get('title') and live_row.get('role') == row.get('role')
                        and all(matching(h) for h in (first, second)))
    passed = valid_target and first.get('element_id') == second.get('element_id') and all(
        h.get('stable_id') is True and h.get('element_id') in {r['id'] for r in matching(h)}
        and h.get('stable_id_strategy') in ('parent_chain', 'top_down')
        and isinstance(h.get('stable_id_steps'), list) and bool(h['stable_id_steps'])
        and all(step in ('cf_equal', 'fingerprint_frame') for step in h['stable_id_steps'])
        and 'stable_id_reason' not in h for h in (first, second))
    entry = {'window_id': window_id, 'point': args, 'web_target': row,
             'allowed_ids': sorted(allowed), 'valid_target': valid_target, 'passed': passed, 'hits': [first, second]}
    report.append(entry)
    print(json.dumps(entry, ensure_ascii=False))
(out / 'comparison.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
require(all(r['valid_target'] for r in report), 'INCONCLUSIVE: page changed or point hit a different/covered target; inspect full outputs')
require(all(r['passed'] for r in report), 'FAIL A8: web hit is unstable or differs from find_elements id')
print('PASS A8: 4 points / 3 web targets / 8 hits, all stable_id:true and same id as link/direct-child find_elements')
PY
swift build
PROBE_MAX=300000 python3 .s1-evidence/reviewer/a8-web/check.py
```

De helper voert steeds exact de stock-probe uit:
`PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp '<calls>'`.
Elke concreet ingevulde calllijst én shellcommand wordt opgeslagen naast de ruwe
output. Herhaal dezelfde acht hit-tests rechtstreeks met:

```sh
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/a8-web/after/identity-calls.json)" | tee .s1-evidence/reviewer/a8-web/after/identity-repeat.txt
```

**Acceptatie:** vier punten op drie webtargets, ieder twee keer: `stable_id:true`,
`element_id` gelijk aan het link-id of een **direct child-id** uit de actuele
`get_ui_tree`-childrenlijst. Bij een AXStaticText-child worden rol/titel/bounds
vergeleken met diens eigen `find_elements(role=AXStaticText)`-resultaat. De eerste
hit na de processtart is een apart gelogde warm-up; daarna moeten beide hits
per punt hetzelfde id geven.
`stable_id_strategy` moet `parent_chain` of `top_down` zijn; `stable_id_steps`
registreert `cf_equal`/`fingerprint_frame`. Bij stabiele ids ontbreekt
`stable_id_reason`. Bij falen stuur de volledige specifieke reden en de ancestors
terug; een verklaarde random-id-fallback telt hier niet als geslaagd.

### Dezelfde probe vóór/na deze A8-correctie

Er is geen prestatieclaim voor deze wijziging. Om het functionele verschil en de
ruwe latenties met **dezelfde calls** vast te leggen, bouw de vorige reviewercommit
zonder checkout, branchwissel of wijziging buiten deze worktree:

```sh
mkdir -p .build/s1-a8-before
git archive a116065 | tar -x -C .build/s1-a8-before
swift build --package-path .build/s1-a8-before
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/s1-a8-before/.build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/a8-web/after/identity-calls.json)" | tee .s1-evidence/reviewer/a8-web/before-same-calls.txt
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/a8-web/after/identity-calls.json)" | tee .s1-evidence/reviewer/a8-web/after-same-calls.txt
```

Verwacht vóór: de eerder gemelde web-hits met `stable_id:false` en generieke reden
(alleen een daadwerkelijke reproductie geldt als bewijs). Verwacht na: alle acht
ids stabiel en gelijk aan hun eigen voorafgaande `find_elements`-resultaat. Laat
de pagina tussen runs ongemoeid. Bewaar de `--- tool ... -> N ms` regels; deze
losse timings bewijzen geen p50-prestatieverbetering. De herhaalde performanceprobe
uit §5 blijft beschikbaar voor een echte voor/na-meting.

## 9. Review ronde 2 — dezelfde Chrome-hits vóór/na de pruning

**Nog uit te voeren door de desktopreviewer.** Codex kan de ≤40 ms-doelstelling
niet meten. De Swift fake-tree-test gebruikt pagina's van 5.000 en 10.000 nodes;
een echte 10k-pagina is daarmee niet live geverifieerd. Gebruik hieronder de
reeds gemeten webpunten uit `reviewer2-check.jsonl`. De selectie neemt drie snelle
en drie trage verschillende punten; bij een gewijzigde pagina stopt de verse
`find_elements(role=AXStaticText)`-controle. Geen navigatie, scroll of andere
wijziging aan een bestaande tab uitvoeren. Ontbreekt een zichtbare 10k-pagina,
rapporteer die live-dekking als niet geverifieerd.

De scripts bewaren de exacte calllijst, alle stock-probe-antwoorden en timings.
Ze vergelijken de AXStaticText-hit met diens eigen zoek-id. De eerste hit per
proces en één hit vóór elke zeven samples zijn apart gelogde warm-ups. Zo wordt
Chrome's mogelijke eerste AXWebArea-hit niet als regressie of timing gebruikt.

```sh
export S1_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
mkdir -p .s1-evidence/reviewer/r2-perf
python3 - <<'PY'
import json
from pathlib import Path
rows = [json.loads(line) for line in Path('.s1-evidence/reviewer2-check.jsonl').read_text().splitlines()]
pids = {app['pid'] for r in rows for app in r.get('response', {}).get('result', {}).get('structuredContent', {}).get('apps', [])
        if (app.get('bundleIdentifier') or app.get('bundle_id')) == 'com.google.Chrome'}
assert len(pids) == 1, 'INCONCLUSIVE: no unique Chrome pid in previous trace'
pid = next(iter(pids))
points = {}
for row in rows:
    params = row.get('request', {}).get('params', {})
    hit = row.get('response', {}).get('result', {}).get('structuredContent', {})
    if params.get('name') != 'element_at_point' or params.get('arguments', {}).get('pid') != pid:
        continue
    if hit.get('role') != 'AXStaticText' or not hit.get('stable_id'):
        continue
    if not any(a.get('role') == 'AXLink' for a in hit.get('ancestors', [])):
        continue
    args = params['arguments']
    points[(args['x'], args['y'])] = {'args': args, 'expected': {k: hit.get(k) for k in ('pid', 'role', 'title', 'bounds')},
                                   'previous_ms': row['ms']}
ordered = sorted(points.values(), key=lambda p: p['previous_ms'])
assert len(ordered) >= 6, 'INCONCLUSIVE: fewer than six previously verified text-link points'
selected = ordered[:3] + ordered[-3:]
Path('.s1-evidence/reviewer/r2-perf/cases.json').write_text(json.dumps(selected, indent=2))
print(json.dumps(selected, indent=2))
PY
cat > .s1-evidence/reviewer/r2-perf/measure.py <<'PY'
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

binary, label = sys.argv[1:]
root = Path('.s1-evidence/reviewer/r2-perf')
cases = json.loads((root / 'cases.json').read_text())
calls = []
for case in cases:
    expected = case['expected']
    calls.append(['find_elements', {'pid': expected['pid'], 'role': expected['role'], 'title': expected['title'],
        'exact': True, 'max_depth': 32, 'limit': 500, 'fields': ['id', 'role', 'title', 'position', 'size'], 'max_bytes': 100000}])
calls.append(['element_at_point', cases[0]['args']])
for case in cases:
    calls.extend([['element_at_point', case['args']]] * 8)
(root / (label + '-calls.json')).write_text(json.dumps(calls, indent=2))
probe = str(Path(os.environ['S1_SCRATCH']) / 'probe.py')
completed = subprocess.run(['python3', probe, binary, json.dumps(calls)],
    env=dict(os.environ, PROBE_MAX='300000'), text=True, capture_output=True, timeout=1800, check=True)
(root / (label + '-raw.txt')).write_text(completed.stdout)
(root / (label + '-stderr.txt')).write_text(completed.stderr)
headers = list(re.finditer(r'^--- [^\n]+ -> ([0-9.]+) ms\n', completed.stdout, re.MULTILINE))
assert len(headers) == len(calls), 'missing stock-probe replies'
results = []
for index, header in enumerate(headers):
    end = headers[index + 1].start() if index + 1 < len(headers) else len(completed.stdout)
    payload = json.loads(completed.stdout[header.end():end])
    results.append((payload, float(header.group(1))))
report = []
for index, case in enumerate(cases):
    expected = case['expected']
    found = results[index][0]
    assert isinstance(found, dict) and found.get('ok'), f'INCONCLUSIVE: search failed: {found}'
    matches = [row for row in found.get('elements', []) if row.get('role') == expected['role']
               and row.get('title') == expected['title']
               and dict(row.get('position', {}), **row.get('size', {})) == expected['bounds']]
    assert len(matches) == 1, 'INCONCLUSIVE: point no longer names one fresh search result'
    wanted = matches[0]['id']
    start = len(cases) + 1 + index * 8
    reference, _ = results[start]
    samples = results[start + 1:start + 8]
    same_target = all(isinstance(hit, dict) and hit.get('ok') and
                      all(hit.get(k) == v for k, v in expected.items()) for hit, _ in samples)
    stable = same_target and all(hit.get('stable_id') is True and hit.get('element_id') == wanted for hit, _ in samples)
    times = [ms for _, ms in samples]
    report.append({'case': case, 'expected_id': wanted, 'warmup': reference, 'same_target': same_target,
                   'stable': stable, 'samples_ms': times, 'p50_ms': statistics.median(times),
                   'max_ms': max(times), 'payloads': [hit for hit, _ in samples]})
(root / (label + '-measurements.json')).write_text(json.dumps(report, indent=2))
for row in report:
    print(json.dumps({k: row[k] for k in ('case', 'expected_id', 'same_target', 'stable', 'samples_ms', 'p50_ms', 'max_ms')}))
assert all(row['same_target'] for row in report), 'INCONCLUSIVE: hit target changed; inspect raw output'
if label == 'after':
    assert all(row['stable'] for row in report), 'FAIL A8: unstable or different search id'
    assert all(row['max_ms'] <= 40 for row in report), 'FAIL performance target: a measured sample exceeded 40 ms'
print('PASS', label)
PY
mkdir -p .build/s1-r2-before
test ! -e .build/s1-r2-before/Package.swift
git archive 08fb0d3 | tar -x -C .build/s1-r2-before
swift build --package-path .build/s1-r2-before
swift build
PROBE_MAX=300000 python3 .s1-evidence/reviewer/r2-perf/measure.py .build/s1-r2-before/.build/debug/mac-control-mcp before
PROBE_MAX=300000 python3 .s1-evidence/reviewer/r2-perf/measure.py .build/debug/mac-control-mcp after
python3 - <<'PY'
import json
from pathlib import Path
root = Path('.s1-evidence/reviewer/r2-perf')
assert json.loads((root / 'before-calls.json').read_text()) == json.loads((root / 'after-calls.json').read_text())
before = json.loads((root / 'before-measurements.json').read_text())
after = json.loads((root / 'after-measurements.json').read_text())
for old, new in zip(before, after):
    assert old['case'] == new['case'] and old['expected_id'] == new['expected_id'], 'page or canonical path changed'
    print(json.dumps({'title': new['case']['expected']['title'], 'point': new['case']['args'],
        'p50_before_ms': old['p50_ms'], 'p50_after_ms': new['p50_ms'],
        'max_before_ms': old['max_ms'], 'max_after_ms': new['max_ms'], 'stable_after': new['stable']}))
PY
```

De onderliggende calls zijn zonder de helper exact te herhalen:

```sh
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/s1-r2-before/.build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/r2-perf/before-calls.json)"
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/r2-perf/after-calls.json)"
```

Verwacht na: zeven identieke content-addressed hit-ids per punt, gelijk aan de
AXStaticText-zoekresultaten, `stable_id:true`, geen `top_down_node_cap`, alle gemeten
samples ≤40 ms. Stock-probe-tijden zijn afgerond op milliseconden; rapporteer alle
samples, p50 en maximum zonder preciezere timing te suggereren. De verhoogde limiet
van 12.000 node-reads is geen onbegrensde garantie: ontbrekende geometrie, veel
siblings, aliases en overflow kunnen nog de fallback of die limiet raken. Een
10k-node live-case mag alleen als geverifieerd worden gemeld met bewijs van die
paginagrootte en echte meetoutput; de synthetische test bewijst alleen het algoritme.
