# S3 — reviewronde 2: Finder floating headers

## Status

Deze revisie herstelt de selectie bij een onvolledige geometrische zoekactie: een overlappende rijcel mag een Finder-kolomkop niet vervangen. **46 tests in vijf gevraagde suites groen**, build geslaagd en onafhankelijke codereview zonder resterende materiële bevindingen. Nieuwe live-acceptatie (8/8 buttons, ≤150 ms) moet nog worden bevestigd: deze uitvoercontext krijgt `permission_missing`.

`8866f1b` is de door de reviewer gecommitte voorafgaande revisie. Geen bestaande commits geamendeerd of teruggedraaid. Nieuwe wijzigingen blijven ongecommit: `git add` kan de externe worktreeadministratie niet schrijven ([round2-commit-attempt.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-commit-attempt.txt)).

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ground/index.lock': Operation not permitted
exit_code: 128
```

## Door de reviewer al live geaccepteerd

Bron: [round2-reviewer-input.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-reviewer-input.txt); dit zijn metingen van vóór deze laatste Finder-fix.

| Onderdeel | Reviewerresultaat |
|---|---|
| B5 Finder OCR | p50 **157 ms**, was 1116 ms; doel ≤400 gehaald |
| B5 Safari OCR | **82 ms** |
| B5 Chrome OCR | **108–114 ms**, door reviewer geaccepteerd als Vision fast-grens voor dit venster |
| Auto met AX-hit | **424 ms = AX-tijd**, OCR wordt overgeslagen |
| A5 | **6/6** labels correct |
| C2 System Settings | **17/17 = 100%** |
| A7 | Browserhint correct |

De nieuwe regressie: Finder Size/Kind koos in **3/8 runs** een inhoudscel onder de floating header. Foute runs kostten **1047–1092 ms**, goede **629–938 ms**. Finder-overeenkomst daalde van **98,6% naar 97,2%**; de 71-call sweep van **3119 naar 6209 ms**. Dit is de aanleiding voor deze revisie, geen meting van de nieuwe code.

## Wijzigingen

- Kinderen waarvan het frame het punt bevat worden eerst bezocht, met behoud van hun volgorde. Andere kinderen worden in oorspronkelijke volgorde uitgesteld.
- Passende kinderen worden direct verwerkt; latere sibling-reads kunnen een al gevonden header daardoor niet ongebruikt laten verlopen.
- Frames en overige nodegegevens worden per zoekactie gecachet. Deze reads tellen mee tegen de node-cap, inclusief het lezen van child-geometrie voor de bezoekvolgorde.
- AXRow/AXCell met een frame van minimaal 2×2 dat het punt niet bevat wordt niet verder bezocht. Nil/degenerate frames blijven hun kinderen toelaten.
- Deadline, node-cap en dieptebegrenzing markeren de walk als onvolledig. Een onvolledige walk met uitsluitend row/cell-kandidaten retourneert `nil`; de tool meldt daardoor `hit_test_quality: container`.
- Expliciete interactieve controls winnen van overlappende collection-rijen/cellen. Binnen die categorie blijven kleinste oppervlakte en de bestaande diepste-leafregel gelden.

Bestanden:

- [GeometricHitTest.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Sources/MacControlMCP/GeometricHitTest.swift)
- [GeometricHitTestTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/Tests/MacControlMCPTests/GeometricHitTestTests.swift)
- [LIVE-CHECKS.md](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/LIVE-CHECKS.md)
- Dit rapport en de nieuwe `round2-*`-bewijsbestanden.

Geen nieuwe dependencies, tools, toolbeschrijvingen of versieaanpassingen. README, server.json, npm/ en releasenotes hebben geen diff.

## RED → GREEN

Eerste regressieronde — [round2-red.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-red.txt):

```text
✘ Test run with 12 tests in 1 suite failed after 0.002 seconds with 8 issues.
```

Dekt: header versus kleinere/diepere inhoudscel; outline met 100 overlappende cellen en een latere header met nodeCap 12; deadline; stabiele bezoekvolgorde; rijpruning met behoud van nil/degenerate uitzonderingen.

Daarna [round2-green.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-green.txt): **12 tests in 1 suite passed**.

Aanvullende reviewfixture — [round2-deadline-red.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-deadline-red.txt):

```text
laterSlowSiblingCannotDiscardAnAlreadyFoundHeader: result nil != 1
✘ Test run with 13 tests in 1 suite failed after 0.001 seconds with 1 issue.
```

Na de fix, afsluitende gevraagde selectie — [round2-suites.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-suites.txt):

```text
✔ Suite "element_at_point (C-4)" passed after 0.009 seconds.
✔ Suite "Geometric hit test" passed after 0.001 seconds.
✔ Suite "Grounding OCR passes" passed after 0.001 seconds.
✔ Suite "Grounding precision" passed after 0.001 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.019 seconds.
✔ Test run with 46 tests in 5 suites passed after 0.031 seconds.
```

Exact testcommando:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'GeometricHitTestTests|ElementAtPointTests|GroundingPrecisionTests|GroundingOCRPassTests|Phase9ToolsTests'
```

Geen volledige desktopsuite gestart. De standaard `swift build` is eerst geprobeerd maar kan de standaard modulecache niet schrijven. De build met tijdelijke modulecache slaagt: [round2-build-before.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-build-before.txt) en [round2-build-final.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-build-final.txt). Codereview: [round2-code-review.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-code-review.txt).

## Exacte live-probe en acceptatie

De volledige letterlijk uitvoerbare probe staat in [LIVE-CHECKS.md](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/LIVE-CHECKS.md), met de identieke calls in [round2-header-calls.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-header-calls.json):

- Finder pid **742**;
- Size **(1444.5,105)** en Kind **(1550.5,105)**;
- één `.build/debug/mac-control-mcp`-proces via `SCRATCH/probe.py`;
- acht afwisselende runs per punt, **16 calls totaal**;
- doel per kolomkop: **8/8 AXButton** met juiste titel en iedere call **≤150 ms**.

Lokaal opnieuw uitgevoerd met de uiteindelijke binary: [round2-header-live.txt](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-header-live.txt), compacte resultaten [round2-header-summary.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-ground/s3-evidence/round2-header-summary.json). Alle 16 calls geven `permission_missing`; dus geen geldige nieuwe latency of overeenkomstmeting. Deze foutresponstijden worden niet als performance gebruikt. De outputs bevatten geen base64-afbeeldingen. Geen klik, invoer, vensterverplaatsing, instelling of klembordwijziging uitgevoerd.

## Resterend

1. Reviewer voert de vastgelegde probe uit met desktoptoegang en bevestigt 8/8 per header en ≤150 ms.
2. Reviewer commit de ongecommitte revisie vanuit een omgeving die de Git-worktreeadministratie kan schrijven.

De eerdere `revision-*` en RED/GREEN-bewijsbestanden blijven bewaard. Hun oude performanceblokkades worden voor de reeds geaccepteerde onderdelen vervangen door de bovenstaande live-reviewresultaten.
