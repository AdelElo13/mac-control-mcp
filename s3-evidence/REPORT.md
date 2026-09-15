# S3 — revisie na live review

## Resultaat

**De B5-regressie is live vastgesteld door de reviewer:** Finder `ground(ocr)` ging van de aangeleverde 0.9.0-baseline 948 ms naar p50 1116 ms. De eerdere tests bewezen de beslislogica, maar die logica veroorzaakte in echte UI-tekst onnodig twee Vision-passes. Deze revisie corrigeert dat; de nieuwe latencydoelen moeten nog worden nagemeten.

De reviewer heeft A5 (alle zes labels), A7 en Finder-hit-testing live goedgekeurd. System Settings stond op 16/18 = 88,9%; deze revisie richt zich op de twee scrollbar-misses.

**Lokale verificatie:** build geslaagd; 98 tests in 13 gefilterde suites groen; onafhankelijke codereview zonder materiële bevindingen. Nieuwe commits blijven geblokkeerd door `index.lock` buiten de schrijfbare sandbox. Deze revisie staat ongecommit in de worktree.

## Commits

- `0b2bd9e`: bestaande WIP, intact.
- `187034e`: voorafgaande implementatie door reviewer gecommit, intact.
- Nieuwe commitpoging stopte bij `git add`, exit 128:

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ground/index.lock': Operation not permitted
```

Bewijs: [revision-commit-attempt.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-commit-attempt.txt). Geen amend, revert, push, merge of rebase.

## Wijzigingen en bestanden

- **B5 OCR:** accurate alleen bij nul zichtbare fast-matches. Een exact/genormaliseerd label bij recognition-confidence 0,72 (ook 0 of 0,4) is een hit. De response behoudt die lagere confidence. Substringmatches blijven maximaal 0,6. Een werkelijk ontbrekend target en een onbruikbaar klein tekstvak veroorzaken nog wel fallback.
- **B5 auto:** een AX-topkandidaat met confidence 1,0, ook bij gelijke exact-matches, of een strikt hogere score dan de tweede kandidaat stopt vóór OCR. De bestaande sortering bepaalt de winnaar.
- **C2:** directe Outline/Table/Row/Cell-hits worden verfijnd. Rows/cells tellen binnen outlines/tables als selecteerbaar. Binnen 10% van het globaal kleinste oppervlak wint de diepere kandidaat. De echte misses lagen bij x=656 op een scrollbar: collection-hits mogen daarom hun dichtstbijzijnde scrollcontainer doorzoeken als die het punt bevat. Geen verbreding door sheet/popover/dialog/window-grenzen; gewone overlays behouden hun subtree. Eén zoekactie met maximaal diepte 24 en 2000 nodes.
- **A7 hint:** `js_error` verwijst naar de paginafout/Content Security Policy en AX-tools. De instructie om Apple Events toe te staan blijft bij de betreffende beleidsfout horen.
- Toolbeschrijving en `docs/TOOLS.md` bijgewerkt; toolaantal en versies ongewijzigd.

- [Sources/MacControlMCP/AccessibilityController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/AccessibilityController.swift)
- [Sources/MacControlMCP/BrowserDOMController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/BrowserDOMController.swift)
- [Sources/MacControlMCP/GeometricHitTest.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GeometricHitTest.swift)
- [Sources/MacControlMCP/GroundingController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GroundingController.swift)
- [Sources/MacControlMCP/GroundingPolicy.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GroundingPolicy.swift)
- [Sources/MacControlMCP/ScreenController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/ScreenController.swift)
- [Sources/MacControlMCP/Tools+V2Phase9.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/Tools+V2Phase9.swift)
- [Tests/MacControlMCPTests/BrowserDOMFailureTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/BrowserDOMFailureTests.swift)
- [Tests/MacControlMCPTests/GeometricHitTestTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GeometricHitTestTests.swift)
- [Tests/MacControlMCPTests/GroundingOCRPassTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GroundingOCRPassTests.swift)
- [Tests/MacControlMCPTests/GroundingPrecisionTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GroundingPrecisionTests.swift)
- [docs/TOOLS.md](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/docs/TOOLS.md)

## RED → GREEN

Eerste regressieronde, [revision-red.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-red.txt):

```text
✘ Test run with 24 tests in 4 suites failed after 0.003 seconds with 13 issues.
```

Onder meer: fast-confidence 0,72 geeft `[true, false]` in plaats van `[true]`; exact AX-ties stoppen niet; outline-leaf wordt gemist; CSP-hint noemt de verkeerde instelling. Vervolgens: [revision-green.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-green.txt) (`24 tests in 4 suites passed`).

Aanvullende fixture op basis van de scrollbar-geometrie uit de live-review:

- [revision-scrollbar-red.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-scrollbar-red.txt): `7 tests in 1 suite failed ... with 4 issues` — beide collection-hits bleven containers.
- [revision-scrollbar-green.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-scrollbar-green.txt): `7 tests in 1 suite passed` — beide kiezen de scrollbar-button; overlay blijft geïsoleerd.

Afsluitende volledige **gefilterde** selectie, inclusief aangescherpte overlay-fixture ([revision-suites.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-suites.txt)):

```text
✔ Suite "AXAttributeBatch" passed after 0.001 seconds.
✔ Suite "AX scope policy (Codex r2 #2)" passed after 0.002 seconds.
✔ Suite "Browser DOM failures" passed after 0.001 seconds.
✔ Suite "Browser error classification" passed after 0.001 seconds.
✔ Suite "element_at_point (C-4)" passed after 0.004 seconds.
✔ Suite "Geometric hit test" passed after 0.001 seconds.
✔ Suite "Grounding OCR pixel→point conversion" passed after 0.001 seconds.
✔ Suite "Grounding OCR passes" passed after 0.001 seconds.
✔ Suite "Grounding precision" passed after 0.001 seconds.
✔ Suite "Grounding depth + window-scoped OCR mapping" passed after 0.001 seconds.
✔ Suite "Phase 2 tools — browser + screen" passed after 0.006 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.017 seconds.
✔ Suite "Tool docs drift" passed after 0.013 seconds.
✔ Test run with 98 tests in 13 suites passed after 0.051 seconds.
```

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'Grounding.*Tests|GeometricHitTestTests|BrowserDOM.*Tests|BrowserErrorClassificationTests|AXAttributeBatchTests|AXScopePolicyTests|Phase9ToolsTests|ElementAtPointTests|Phase2ToolsTests|ToolDocsDriftTests'
```

Geen volledige desktopsuite gestart. Bestaande live-smoketests kunnen zonder AX-toestemming vroeg terugkeren; hun groene status is geen live bewijs. Eerdere RED/GREEN-logs blijven in deze map bewaard.

Build: [revision-build-before.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-build-before.txt) en [revision-build-final.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-build-final.txt). `swift build` werd eerst zonder opties geprobeerd; de standaard modulecache is niet schrijfbaar. De tijdelijke modulecache en `--disable-sandbox` maken de build hier uitvoerbaar. Tooldocs gegenereerd met `UPDATE_TOOL_DOCS=1` en de `script`-wrapper: [revision-docs-regenerate.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-docs-regenerate.txt); driftcheck daarna opnieuw zonder die variabele groen. Codereview: [revision-review.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-review.txt).

## Live-review: gemeten waarden en nieuwe meetdoelen

Bron: de door de gebruiker aangeleverde review, bewaard in [reviewer-live-review.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/reviewer-live-review.txt). Onderstaande meetwaarden zijn van **vóór deze revisie**, uit de revieweromgeving met desktoptoegang.

| Controle | Live vastgesteld vóór revisie | Verwacht acceptatiecriterium na revisie |
|---|---|---|
| Finder ground OCR, Downloads | p50 1116 ms, 7 runs; 0.9.0-baseline 948 ms | **≤400 ms** |
| Safari ground OCR | Nieuwe waarde niet aangeleverd | **≤100 ms** |
| Chrome ground OCR | Nieuwe waarde niet aangeleverd | **≤100 ms** |
| Finder ocr_screen fast | p50 158 ms | Blijft fast; geen accurate pass toegevoegd |
| Finder ocr_screen accurate | p50 947 ms | Accurate-route ongewijzigd |
| auto met correcte AX-ties | 2141 ms gemeld | **≤ AX-tijd + 5 ms** |
| Finder hit-test | **70/71 = 98,6%** same id, goedgekeurd | ≥90%, behoud controleren |
| System Settings hit-test | **16/18 = 88,9%** | **≥90%**, beide scrollbar-punten opnieuw testen |

De nieuwe getallen in de rechterkolom zijn **meetdoelen, geen gemeten uitkomsten**. Er wordt geen gerealiseerde snelheidswinst geclaimd. De reviewer zal opnieuw meten met dezelfde probe/cases. B5 is dus als regressie geverifieerd; herstel van de prestatiedoelen wacht op die nameting.

### A5 en A7

Volgens de live-review zijn alle zes A5-labels correct: `Untitled` via AXStaticText/value; `Recents`, `Shared`, `Add User…`, `account` correct; verkeerde hits als alternatieven gedemoteerd; `Skip to content` niet meer als verborgen 1×1-link gekozen. A7 geeft Safari `js_error` en Chrome `permission_policy_denied`, beide met hints. Deze revisie verfijnt de Safari-hint.

Ruwe revieweroutputs zijn beschikbaar als [/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/ground-after.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/ground-after.txt), [/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/eap-sys-out.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/eap-sys-out.txt) en [/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/eap-finder-out.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/eap-finder-out.txt). De System Settings-centra staan in [/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/eap-sys-centers.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/eap-sys-centers.json). De B5-probecases staan in [/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/b5-calls.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/b5-calls.json).

## Lokale live-hercontrole en beperkingen

De huidige `.build/debug/mac-control-mcp` is met `PROBE_MAX=300000 python3 SCRATCH/probe.py` opnieuw aangeroepen voor permissions, Finder Downloads (`ocr`/`auto`) en de twee gemiste System Settings-punten `(656,859)` en `(656,483.5)`. Volledige output: [revision-live.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/revision-live.txt).

```text
permissions_status: accessibility=not_granted, screen_recording=not_granted
ground Downloads ocr/auto: error_code=no_such_window
element_at_point beide scrollbar-centra: error_code=permission_missing
```

Daarom kan deze uitvoercontext geen geldige nieuwe p50 of nieuwe System Settings-overeenkomst leveren. De eerdere `perf-before.json`/`perf-after.json` in deze map bevatten sandbox-foutresponstijden; ze mogen niet als OCR-performance worden gebruikt. Er zijn geen base64-afbeeldingen in de nieuwe lokale probe-output. Geen desktopklik, tekstinvoer, vensterverplaatsing, instellingenwijziging of klembordwijziging uitgevoerd.

**Resterend:** reviewer-nameting van de nieuwe B5-doelen en C2-uitkomst; conventionele commits vanuit een omgeving die de Git-worktreeadministratie kan schrijven.
