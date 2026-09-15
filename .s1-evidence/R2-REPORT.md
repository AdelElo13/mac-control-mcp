# S1 review ronde 2 — bewijs en overdracht

## Resultaat en scope

Uitgangspunt: reviewercommit `08fb0d3`. Deze ronde wijzigt alleen de twee resterende
punten: de kosten van A8-padreconstructie en de Chrome-acceptatie/meethelpers.
A1/A2/A6 zijn niet aangepast. De gebruiker heeft A8-identiteit op de vorige commit
live goedgekeurd; de nieuwe pruning en ≤40 ms-doelstelling zijn hier **niet live gemeten**.

- Top-down probeert eerst geometrische pruning, met behoud van de originele
  AXChildren/AXSheets-ordinals. Alleen bevattende of ontbrekende/zero-size frames
  worden verder doorzocht. Een exacte handle gaat vóór een fingerprint-alias.
- Zonder verifieerbaar resultaat volgt de volledige DFS. Een alias na uitgesloten
  takken wordt nooit als uniek aangenomen zonder die fallback. De bestaande
  overflow-, aliasambiguïteit- en exacte-handle-regressies blijven GREEN.
- Eén memo en leesbudget worden gedeeld over alle pogingen. Een poging die geen
  nieuwe reads meer kan doen blokkeert geen fallback over reeds gecachete nodes.
- De limiet is 12.000 unieke snapshotreads en 32 niveaus. De toolbeschrijving noemt
  deze constante waarden en de mogelijke `stable_id_reason`-codes.
- Beide acceptatiehelpers herkennen de directe AXStaticText-child via de actuele
  tree-childrenlijst en diens eigen `find_elements`-metadata/id. De eerste hit na
  processtart wordt genegeerd als warm-up. De benchmarkhelper is ook aangepast.

## Commits

Bestaande HEAD:

```text
08fb0d3 fix(v0.10-ids): Codex fix round after live review, committed by reviewer (sandbox cannot write index.lock)
```

**Geen nieuwe commit gemaakt.** Staging eindigde met exit 128. Volgens de
gebruikersinstructie zijn de wijzigingen uncommitted gelaten; geen amend, revert,
push, merge, rebase of branchwissel.

[aankoppelpoging](r2-commit-attempt.txt):

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ids/index.lock': Operation not permitted
```

## Bestanden

| Bestand | Wijziging |
|---|---|
| `Sources/MacControlMCP/AXPathReconstruction.swift` | Geometrische eerste poging, volledige fallback, gedeelde memo, 12k-limiet en cached-only fallback. |
| `Sources/MacControlMCP/Tools+V0_9AXCore.swift` | Beschrijving met limieten en concrete foutredenen. |
| `Tests/MacControlMCPTests/AXPathReconstructionTests.swift` | Brede 5k/10k-pagina's, overflowfallback, zero-size container, exacte handle versus alias, gecachete fallback en harde limiet. |
| `docs/TOOLS.md` | Gegenereerde beschrijving; geen nieuwe tool of wijziging van toolaantal. |
| `.s1-evidence/reviewer/session.py` | Link/text-child-acceptatie en warm-up in check én benchmark. |
| `LIVE-CHECKS.md` | Gesynchroniseerde helpers; §8 controleert directe children; §9 bevat dezelfde stock-probes vóór/na tegen `08fb0d3`. |
| `.s1-evidence/r2-probe-tests.py` (nieuw) | Synthetische tests van de echte helpercode zonder subprocess of desktop. |
| `.s1-evidence/r2-*.txt`, dit rapport | Ruwe RED/GREEN-, suite-, build-, validatie- en Git-output. |

README, RELEASE_NOTES, server.json, npm, dependencies en versievelden zijn niet
gewijzigd. Bestaande ruwe reviewer-output is niet overschreven.

## RED → GREEN — Swift

Commando voor iedere ronde:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" script -q /dev/null swift test --disable-sandbox --no-parallel --filter AXPathTests
```

`--disable-sandbox` is nodig voor SwiftPM binnen de bestaande Codex-sandbox; het
geeft geen desktoprechten. De voorgeschreven PTY-wrapper is overal gebruikt.

### Brede pagina en pruning

RED: [r2-red.txt](r2-red.txt)

```text
✘ Test "A8 geometric reconstruction bounds reads on 5000/10000-node pages" recorded an issue with 1 argument pageNodes → 5000 at AXPathReconstructionTests.swift:313:9: Expectation failed: (result.path → nil) == (expected → [MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXGroup", index: 99, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXStaticText", index: 48, identifier: nil, title: Optional("Link 5899"), subrole: nil)])
✘ Test run with 38 tests in 1 suite failed after 0.022 seconds with 6 issues.
```

GREEN: [r2-green.txt](r2-green.txt)

```text
✔ Test run with 38 tests in 1 suite passed after 0.017 seconds.
```

### Gecachete fallback na uitgeputte pruned pass

RED: [r2-cache-red.txt](r2-cache-red.txt)

```text
✘ Test "A8 exhausted pruned pass can fall back through cached overflow nodes" recorded an issue at AXPathReconstructionTests.swift:364:9: Expectation failed: (result.path → nil) == ([nodes[1]!.component(index: 0), target.component(index: 0)] → [MacControlMCP.AXPathComponent(role: "AXGroup", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Target"), subrole: nil)])
✘ Test run with 39 tests in 1 suite failed after 0.017 seconds with 1 issue.
```

GREEN: [r2-cache-green.txt](r2-cache-green.txt)

```text
✔ Test run with 39 tests in 1 suite passed after 0.019 seconds.
```

## RED → GREEN — acceptatie en benchmark

De tests voeren de helpers uit met synthetische stock-NDJSON-antwoorden. Zij
starten geen probeproces en benaderen geen desktop. De positieve fixture geeft
eerst AXWebArea, daarna de AXStaticText-child van de link.

Command:

```sh
python3 .s1-evidence/r2-probe-tests.py
```

Eerste RED: [r2-probe-red.txt](r2-probe-red.txt), vijf tests, twee errors:

```text
RuntimeError: INCONCLUSIVE A8: no visible Chrome link returned a matching AXLink hit; do not navigate or click a user tab
RuntimeError: INCONCLUSIVE: page changed or point hit a different/covered target; inspect full outputs
Ran 5 tests in 0.013s
FAILED (errors=2)
```

Daarna GREEN: [r2-probe-green.txt](r2-probe-green.txt), vijf tests, OK.
De aanvullende benchmarkregressie werd opnieuw eerst RED uitgevoerd:
[r2-measure-red.txt](r2-measure-red.txt), zes tests, één error:

```text
RuntimeError: benchmark point no longer hits a Chrome link
Ran 6 tests in 0.015s
FAILED (errors=1)
```

GREEN: [r2-measure-green.txt](r2-measure-green.txt), zes tests, OK.
Definitieve verificatie inclusief de §9-meetmatrix, verkeerde IDs en >40 ms:
[r2-final-probe-tests.txt](r2-final-probe-tests.txt):

```text
test_measure_accepts_warmed_static_text_reference (__main__.ChromeProbeTests.test_measure_accepts_warmed_static_text_reference) ... ok
test_persistent_probe_accepts_static_text_child_after_warmup (__main__.ChromeProbeTests.test_persistent_probe_accepts_static_text_child_after_warmup) ... ok
test_persistent_probe_rejects_unrelated_child_id (__main__.ChromeProbeTests.test_persistent_probe_rejects_unrelated_child_id) ... ok
test_round2_measure_accepts_six_warmed_child_cases (__main__.ChromeProbeTests.test_round2_measure_accepts_six_warmed_child_cases) ... ok
test_round2_measure_rejects_samples_over_40ms (__main__.ChromeProbeTests.test_round2_measure_rejects_samples_over_40ms) ... ok
test_round2_measure_rejects_unstable_identity (__main__.ChromeProbeTests.test_round2_measure_rejects_unstable_identity) ... ok
test_stock_probe_accepts_static_text_children_after_warmup (__main__.ChromeProbeTests.test_stock_probe_accepts_static_text_children_after_warmup) ... ok
test_stock_probe_rejects_unrelated_child_id (__main__.ChromeProbeTests.test_stock_probe_rejects_unrelated_child_id) ... ok
test_stock_probe_rejects_unstable_child (__main__.ChromeProbeTests.test_stock_probe_rejects_unstable_child) ... ok

----------------------------------------------------------------------
Ran 9 tests in 0.020s

OK
```

## Voor/na: synthetische snapshotreads (geen live IPC- of timingmeting)

Exact dezelfde parametrische fake-tree-test vóór en na de productiecodewijziging:

| Paginanodes | Vóór, snapshotreads | Vóór, stabiel pad | Na, snapshotreads | Na, stabiel pad |
|---:|---:|---|---:|---|
| 5.000 | 2.000 | false, cap bereikt | 151 | true |
| 10.000 | 2.000 | false, cap bereikt | 201 | true |

Ruwe uitvoer uit [RED](r2-red.txt) en [definitieve GREEN](r2-final-AXPathTests.txt):

```text
[A8 R2 wide] page_nodes=5000 reads=2000 stable=false
[A8 R2 wide] page_nodes=10000 reads=2000 stable=false
[A8 R2 wide] page_nodes=5000 reads=151 stable=true
[A8 R2 wide] page_nodes=10000 reads=201 stable=true
```

De aanvullende flat-tree-test heeft geen bruikbare geometrie. Daarmee controleert
hij de volledige fallback en de resterende harde limiet:

```text
[A8 R2 flat] nodes=10000 reads=10001 stable=true
[A8 R2 flat] nodes=12500 reads=12000 stable=false
```

Deze output onderbouwt de verminderde snapshotreads voor de brede fixture, niet
≤40 ms op echte Chrome-pagina's. De onbegrensde DFS-fallback kan trager blijven.

## Definitieve gefilterde suite-output

Na de laatste bronwijziging afzonderlijk uitgevoerd met `script -q /dev/null`,
`--no-parallel --filter`. Geen volledige suite gedraaid.

[AXPathTests](r2-final-AXPathTests.txt), exit 0:

```text
✔ Suite "AX path identity (C-5)" passed after 0.051 seconds.
✔ Test run with 40 tests in 1 suite passed after 0.051 seconds.
```

[ElementCacheTests](r2-final-ElementCacheTests.txt), exit 0:

```text
✔ Suite "ElementCache" passed after 0.381 seconds.
✔ Test run with 25 tests in 1 suite passed after 0.381 seconds.
```

[CodexR2RegressionTests](r2-final-CodexR2RegressionTests.txt), exit 0:

```text
✔ Suite "Codex r2 regressions" passed after 0.012 seconds.
✔ Test run with 13 tests in 1 suite passed after 0.012 seconds.
```

[AnnotatedElementIdentityTests](r2-final-AnnotatedElementIdentityTests.txt), exit 0:

```text
✔ Suite "capture_annotated element identity (C-5)" passed after 0.003 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.003 seconds.
```

[Phase9ToolsTests](r2-final-Phase9ToolsTests.txt), exit 0:

```text
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.026 seconds.
✔ Test run with 14 tests in 1 suite passed after 0.026 seconds.
```

[ToolDocsDriftTests](r2-final-ToolDocsDriftTests.txt), exit 0:

```text
✔ Suite "Tool docs drift" passed after 0.034 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.035 seconds.
```

Totaal: 97 tests volgens de vijf gevraagde suite-uitvoeren, plus vier docstests.
De negen Python-fixturetests staan hierboven. Suite-PASS betekent geen live-dekking
voor tests met permissieguards. De annotatiesuite printte:

```text
[annotated-identity] skipped: no Accessibility trust
[annotated-identity] skipped: no Accessibility trust
[annotated-identity] skipped: no Accessibility trust
[annotated-identity] skipped: no AX trust / no Finder
[annotated-identity] skipped: no Accessibility trust
```

Docs zijn geregenereerd met:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" UPDATE_TOOL_DOCS=1 script -q /dev/null swift test --disable-sandbox --no-parallel --filter ToolDocsDriftTests
```

## Build, validatie en review

De eerste `swift build` faalde op de niet-schrijfbare globale Clang-modulecache:
`error opening '/Users/a/.cache/clang/ModuleCache/Swift-BF86GRDXI25I.swiftmodule' for output`.
De herhaling met cache in `.build/module-cache` slaagde ([r2-build-start.txt](r2-build-start.txt)).
De definitieve build eindigde met exit 0 ([r2-build-final.txt](r2-build-final.txt)):

```text
warning: /Users/a/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: /Users/a/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
warning: /Users/a/Library/Caches/org.swift.swiftpm is not accessible or not writable, disabling user-level cache features.
warning: 'wt10-ids': failed storing manifest for 'wt10-ids' in cache: attempt to write a readonly database
warning: 'wt10-ids': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target
    /private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ids/Sources/MacControlMCP/Resources/well-known-mcp.json
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.16s)
```

Helpervalidatie: [r2-doc-validation.txt](r2-doc-validation.txt):

```text
Python syntax: PASS (6 heredocs)
Embedded check_chrome matches tracked session.py: PASS
Embedded measure matches tracked session.py: PASS
Read-only case selection from reviewer trace: PASS (6 verified web points)
No desktop access or probe process used for this validation.
```

`git diff --check` slaagde zonder output. De onafhankelijke code-review en de
laatste review van de testfixtures eindigden met APPROVE, geen resterende actiepunten.

## Live-handoff en beperkingen

Er zijn **geen nieuwe live-probe-uitkomsten of live vóór/na-tijden** van Codex.
Desktoptoegang ontbreekt volgens de gebruiker en is niet opnieuw aangevraagd.

- `LIVE-CHECKS.md` §8 bevat de gecorrigeerde link/direct-child-regressie, inclusief
  herhaalde hits en eerste-hit-warm-up.
- §9 genereert uit de bestaande reviewertrace zes daadwerkelijk eerder geverifieerde
  tekst-linkpunten, waaronder de tragere punten. De verse zoek- en metadata-check
  weigert verplaatste/veranderde targets.
- Dezelfde stock-probe-calllijst wordt uitgevoerd op `08fb0d3` en de nieuwe binary.
  Per punt: aparte warm-up, zeven samples, verse AXStaticText-id, stabiliteit,
  p50 en maximum. De na-run vereist alle samples ≤40 ms.
- Ruwe resultaten gaan naar `.s1-evidence/reviewer/r2-perf/`; de exacte onderliggende
  `PROBE_MAX=300000 python3 SCRATCH/probe.py <binary> '<calls>'`-commands staan in §9.
- Een echte 10k-node-pagina en de ≤40 ms-doelstelling blijven door de desktopreviewer
  te verifiëren. Geen bestaande tab navigeren, scrollen of anders wijzigen om die
  dekking te verkrijgen; als die pagina ontbreekt, rapporteer dat expliciet.

Geometrische pruning kan niet bewijzen dat een exacte handle niet óók onder een
eerdere, uitgesloten overflow-parent voorkomt wanneer de parent-chain ontbreekt.
In dat uitzonderlijke AX-graafgeval kan het snelle pad een andere volledige-DFS-id
hebben, hoewel CFEqual hetzelfde object bewijst. Deze beperking staat expliciet in
§8; volledige verificatie van uitgesloten takken zou de gevraagde snelle route
ongedaan maken. Bekende multi-parent-paden behouden de bestaande canonieke controle.
Aliasambiguïteit blijft geweigerd: de overflow-ambiguïteitstest is GREEN.

## Commitoverdracht

Door de index.lock-blokkade moet de reviewer de volgende nieuwe commits maken vanuit
dezelfde worktree. Stage de ruwe reviewer2-output niet automatisch mee.

```sh
git add -- Sources/MacControlMCP/AXPathReconstruction.swift Sources/MacControlMCP/Tools+V0_9AXCore.swift Tests/MacControlMCPTests/AXPathReconstructionTests.swift docs/TOOLS.md
git commit -m "perf: prune Chrome hit path reconstruction by geometry" -m "v0.10 A8 R2: avoid walking off-target rendered subtrees before an exact web hit. Preserve ordinals, retain bounded DFS for overflow and alias verification, share reads across attempts, and disclose the remaining reconstruction limits."
git add -- LIVE-CHECKS.md .s1-evidence/reviewer/session.py .s1-evidence/r2-probe-tests.py .s1-evidence/r2-*.txt .s1-evidence/R2-REPORT.md
git commit -m "test: verify Chrome text-child hits and reconstruction costs" -m "Accept a link's direct AXStaticText child and discard Chrome's initial warm-up hit in acceptance and measurement. Preserve RED-to-GREEN evidence and provide identical before/after stock probes for the desktop reviewer."
```
