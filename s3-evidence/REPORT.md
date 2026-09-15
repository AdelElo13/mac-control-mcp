# S3 — eindrapport, 15 september 2026

## Status

Codewijzigingen aanwezig; build en 90 tests in 13 gefilterde suites geslaagd. Onafhankelijke review meldt geen resterende materiële bevindingen ([review.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/review.txt)). **De opdracht is niet volledig afgevinkt:** echte desktopprecisie, OCR-recall, geldige prestatiewaarden en nieuwe commits zijn geblokkeerd door deze uitvoeromgeving.

## Commits

- Branch: `feat/v0.10-ground`; baseline `cb435a8` (`integration/v0.10`).
- Bestaande WIP: `0b2bd9e` — `wip(codex): partial S-ground work before usage-limit stop (uncompiled, do not merge)`. Niet geamendeerd of teruggedraaid.
- Geen nieuwe commits: `git add` faalde vóór de afhankelijke commit kon starten. Vervolgwijzigingen staan ongecommit in deze worktree.

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ground/index.lock': Operation not permitted
exit_code: 128
```

Bewijs: [commit-attempt.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/commit-attempt.txt). Geen push, merge of rebase uitgevoerd.

## Bestanden sinds integration/v0.10

- [Sources/MacControlMCP/AXAttributeBatch.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/AXAttributeBatch.swift)
- [Sources/MacControlMCP/AccessibilityController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/AccessibilityController.swift)
- [Sources/MacControlMCP/BrowserDOMController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/BrowserDOMController.swift)
- [Sources/MacControlMCP/BrowserErrorClassifier.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/BrowserErrorClassifier.swift)
- [Sources/MacControlMCP/GeometricHitTest.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GeometricHitTest.swift)
- [Sources/MacControlMCP/GroundingController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GroundingController.swift)
- [Sources/MacControlMCP/GroundingPolicy.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GroundingPolicy.swift)
- [Sources/MacControlMCP/ScreenController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/ScreenController.swift)
- [Sources/MacControlMCP/Tools+V0_9AXCore.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/Tools+V0_9AXCore.swift)
- [Sources/MacControlMCP/Tools+V2Phase2.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/Tools+V2Phase2.swift)
- [Sources/MacControlMCP/Tools+V2Phase9.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/Tools+V2Phase9.swift)
- [Tests/MacControlMCPTests/BrowserDOMFailureTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/BrowserDOMFailureTests.swift)
- [Tests/MacControlMCPTests/GeometricHitTestTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GeometricHitTestTests.swift)
- [Tests/MacControlMCPTests/GroundingOCRPassTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GroundingOCRPassTests.swift)
- [Tests/MacControlMCPTests/GroundingPrecisionTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GroundingPrecisionTests.swift)
- [docs/TOOLS.md](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/docs/TOOLS.md)

Aanvullende test- en probe-uitvoer staat in `s3-evidence/`. De baseline is uitsluitend onder de genegeerde `.build/` geëxporteerd en gebouwd; geen branchwissel. `README.md`, `RELEASE_NOTES*`, `server.json`, `npm/` en versies hebben geen diff. Toolaantal bleef gelijk.

## Getoetst gedrag

- **A5:** titel/waarde/beschrijving; NFKC, case-folding en ellipsis; uitgesloten containerrollen; minimaal 2 punten en intersectie met een werkelijk display; kleinere match bij gelijke score; substringscore maximaal 0,6; OCR-afstandsstraf; `matched_field` en maximaal drie alternatieven. Fake AX-labels en OCR-resultaten toetsen deze regels.
- **B5:** fast met taalcorrectie uit; accurate alleen als geen zichtbare kandidaat score ≥0,8 heeft. Beide passes gebruiken dezelfde capture. Fast-only labels blijven bewaard; overlappende OCR-dubbelen worden samengevoegd. `ocr_screen(level=fast)` gebruikt standaard taalcorrectie uit; expliciete instelling blijft mogelijk.
- **C2:** geometrische zoekactie binnen de geraakte container, kleinste interactieve kandidaat, maximaal diepte 24 / 2000 nodes, met tijdsgrens; kwaliteit `direct`, `geometric` of `container`. Fake tree toetst ook cycli, budget en overlappende zustergroepen.
- **A7:** DOM-fouten krijgen codes en herstelhints; fixtures toetsen Safari `missing value`, ontbrekend document, kapotte JSON, browserbeleid en generieke evaluatiefouten. Live Safari-classificatie blijft onbevestigd.

## RED → GREEN

RED-logbestanden uit de oorspronkelijke en hervatte cyclus, vóór de betreffende fixes:

- [red-grounding.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-grounding.txt): `✘ Test run with 5 tests in 1 suite failed after 0.001 seconds with 19 issues.`
- [red-hit-browser.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-hit-browser.txt): `✘ Test run with 5 tests in 2 suites failed after 0.002 seconds with 11 issues.`
- [red-ocr-duplicates.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-ocr-duplicates.txt): `✘ Test run with 6 tests in 1 suite failed after 0.001 seconds with 1 issue.`
- [red-ocr-passes.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-ocr-passes.txt): `✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 4 issues.`
- [red-browser-hint.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-browser-hint.txt): `✘ Test run with 4 tests in 1 suite failed after 0.001 seconds with 2 issues.`
- [red-hit-scope.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-hit-scope.txt): `✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 1 issue.`
- [red-ocr-anchor.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/red-ocr-anchor.txt): `✘ Test run with 4 tests in 1 suite failed after 0.001 seconds with 1 issue.`

GREEN op de uiteindelijke code:

```text
✔ Suite "AXAttributeBatch" passed after 0.003 seconds.
✔ Suite "AX scope policy (Codex r2 #2)" passed after 0.007 seconds.
✔ Suite "Browser DOM failures" passed after 0.001 seconds.
✔ Suite "Browser error classification" passed after 0.001 seconds.
✔ Suite "element_at_point (C-4)" passed after 0.007 seconds.
✔ Suite "Geometric hit test" passed after 0.001 seconds.
✔ Suite "Grounding OCR pixel→point conversion" passed after 0.001 seconds.
✔ Suite "Grounding OCR passes" passed after 0.001 seconds.
✔ Suite "Grounding precision" passed after 0.001 seconds.
✔ Suite "Grounding depth + window-scoped OCR mapping" passed after 0.001 seconds.
✔ Suite "Phase 2 tools — browser + screen" passed after 0.007 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.021 seconds.
✔ Suite "Tool docs drift" passed after 0.017 seconds.
✔ Test run with 90 tests in 13 suites passed after 0.068 seconds.
```

Volledige uitvoer: [green-final.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/green-final.txt). Command:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'Grounding.*Tests|GeometricHitTestTests|BrowserDOM.*Tests|BrowserErrorClassificationTests|AXAttributeBatchTests|AXScopePolicyTests|Phase9ToolsTests|ElementAtPointTests|Phase2ToolsTests|ToolDocsDriftTests'
```

Geen volledige testsuite gestart. Sommige bestaande live-smoketests keren zonder AX-toestemming vroeg terug; hun groene status bewijst geen desktopresultaat.

`swift build` werd eerst uitgevoerd maar kon de standaard modulecache niet schrijven. Met de tijdelijke modulecache en `--disable-sandbox` slaagde de afsluitende build: `Build complete! (0.16s)`. [build-final.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/build-final.txt) bevat de resterende cache/resourcewaarschuwingen; [build-baseline.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/build-baseline.txt) bevat de baseline-build.

Tooldocs zijn gegenereerd met `UPDATE_TOOL_DOCS=1` en dezelfde `script`-wrapper: [docs-regenerate.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/docs-regenerate.txt) (`4 tests in 1 suite passed`). Daarna slaagde de driftcheck zonder die variabele in de 90-testselectie.

## Voor/na-metingen

Exact dezelfde cases, hetzelfde `SCRATCH/perf.py`, één opwarming en zeven metingen per case. Voor: `.build/s3-baseline-build/debug/mac-control-mcp` (gebouwd uit `integration/v0.10`); na: `.build/debug/mac-control-mcp`.

Cases: [perf-cases.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/perf-cases.json). Ruwe data: [perf-before.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/perf-before.json) en [perf-after.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/perf-after.json).

**Alle metingen faalden met `no_such_window`. Onderstaande p50-waarden zijn uitsluitend foutresponstijden; ze meten geen OCR en onderbouwen geen snelheidswinst.**

| Case | Voor p50 ms | Na p50 ms | Fouten voor → na |
|---|---:|---:|---:|
| ground(ocr,Downloads)/Finder | 0.2 | 0.2 | 7/7 → 7/7 |
| ground(ocr,Manage cookies)/Safari | 0.2 | 0.2 | 7/7 → 7/7 |
| ground(ocr,Sign in)/Chrome | 0.2 | 0.1 | 7/7 → 7/7 |
| ground(ocr,Users)/SysSettings | 0.3 | 0.1 | 7/7 → 7/7 |
| ocr_screen(accurate)/Finder | 0.2 | 0.1 | 7/7 → 7/7 |
| ocr_screen(fast)/Finder | 0.3 | 0.1 | 7/7 → 7/7 |

De aangeleverde historische audit noemt Finder ground-OCR 948 ms en ocr_screen accurate 1045 ms. Deze omgeving kan die succesvolle calls niet reproduceren. De doelen Finder ≤400 ms en Safari/Chrome ≤100 ms zijn dus **niet geverifieerd**.

## Live-probes

Op beide binaries zijn dezelfde 30 NDJSON-calls uitgevoerd via `PROBE_MAX=300000 python3 SCRATCH/probe.py <binary> <calls>`. Cases: [live-calls.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/live-calls.json). Volledige outputs: [baseline-probes.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/baseline-probes.txt) en [after-probes.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/after-probes.txt); compact: [baseline-summary.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/baseline-summary.json) en [after-summary.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/after-summary.json).

De na-probe rapporteert:

```json
{"list_apps":{"ok":true,"count":0},"list_windows":{"ok":true,"count":0},"permissions_status":{"accessibility":"not_granted","screen_recording":"not_granted"}}
```

De responsible app is `com.anthropic.claude-code`. Browsercalls krijgen een ongeldige XPC-verbinding / osascript-fout (`error_code: failed`); de huidige DOM-response bevat een herstelhint.

Alle zes gevraagde labels zijn met `ax`, `ocr` en `auto` aangeroepen; `Skip to content` bovendien in beide browsers. De gebruikte pids kwamen uit de audit en konden niet actueel bevestigd worden:

| Label | App | AX | OCR / auto |
|---|---|---|---|
| Untitled | TextEdit | not_found | capture_failed |
| Skip to content | Safari en Chrome | not_found | capture_failed |
| Shared | Finder | not_found | capture_failed |
| Recents | Finder | not_found | capture_failed |
| Add User… | System Settings | not_found | capture_failed |
| account | System Settings | not_found | capture_failed |

Dit is **geen bewijs van labelrecall of een recallregressie**: de server kon de doelapps niet lezen. Geen TextEdit-document aangemaakt omdat de server geen bereikbare desktop kon vaststellen. Geen klik, tekstinvoer, vensterverplaatsing, klembordwijziging of instellingenwijziging uitgevoerd.

### C2-overeenkomst

De verse `capture_annotated`-calls voor Finder (window 31954, pid 742) en System Settings (window 29712, pid 76246) geven beide `no_such_window`. Daardoor zijn geen verse annotatiecentra beschikbaar.

Als diagnose zijn daarnaast de 88 opgeslagen centra uit `SCRATCH/audit/exp1.json` door `element_at_point` gehaald; alle 88 geven `permission_missing`. De 90 calls en outputs staan in [agreement-calls.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/agreement-calls.json), [agreement-probes.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/agreement-probes.txt) en [agreement-summary.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/agreement-summary.json). Historische centra leveren geen geldige verse overeenkomstmeting. **≥90% is niet geverifieerd.** Er zijn geen base64-afbeeldingen in deze outputs.

## Nog geblokkeerd

1. Nieuwe conventionele commits: Git-worktreeadministratie buiten de schrijfbare sandbox.
2. Live labelprecisie en ongewijzigde OCR-recall: AX/Screen Recording niet toegekend aan deze uitvoercontext; apps/vensters onzichtbaar.
3. Succesvolle voor/na-OCR-metingen en de prestatiedoelen: dezelfde desktopblokkade.
4. Verse Finder/System Settings-overeenkomst en Safari/Chrome-beleidsclassificatie: dezelfde desktop/XPC-blokkade.

De toegankelijke code-, test-, documentatie- en reviewwerkzaamheden zijn uitgevoerd; bovenstaande punten moeten in een uitvoercontext met de benodigde desktop- en Git-toegang worden voltooid.
