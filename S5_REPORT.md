# S5 — v0.10 C5, C6, C7: verificatierapport
> Historisch rapport van vóór de desktopreview. De reviewer heeft C5/C6/C7 inmiddels live bevestigd en het werk gecommit als `101c341`. Het huidige regressieherstel, actuele verificatie en de nog uit te voeren timings staan in [LIVE-CHECKS.md](LIVE-CHECKS.md).

## Status

**Niet volledig afgerond.** De huidige code bouwt en de gevraagde gefilterde suites slagen. Live-verificatie van de controls, een web-link met URL, de grens van maximaal +10% browserlatentie en de eigen TextEdit-documenttest zijn niet aangetoond. De debugbinary meldt geen Accessibility-toegang. Nieuwe commits zijn geblokkeerd doordat de sandbox de Git-administratie buiten de worktree niet kan schrijven.

Branch: `feat/v0.10-web`.
Debugbinary SHA-256: `9f820aa596e804f235c530e023d08e5d87b20f6e21f95be073a8512861ad7f89`.

## Commits

Bestaand en intact gelaten:

```text
7e7d907 wip(codex): partial S-web work before usage-limit stop (uncompiled, do not merge)
```

Er zijn geen nieuwe commits gemaakt. De poging voor de aanvullende C5-fixes:

```sh
git add Sources/MacControlMCP/AXSearch.swift Tests/MacControlMCPTests/SemanticSearchTests.swift && git commit -m 'fix: constrain semantic aliases and prefer search fields' -m 'v0.10 C5: prevent Book/Background/Research from matching control aliases, keep Search buttons as fallback only, and report actual role-regex match quality. Regression tests reproduce all three failures before the fix.'
```

Werkelijke uitvoer (exit 128):

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-web/index.lock': Operation not permitted
```

De vervolgwijzigingen staan dus ongecommit in de worktree. Geen amend, revert, push, merge of rebase uitgevoerd.

## Bestanden

Verschil ten opzichte van `integration/v0.10`, inclusief WIP en vervolgwijzigingen:

- [Sources/MacControlMCP/AXAttributeBatch.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/AXAttributeBatch.swift)
- [Sources/MacControlMCP/AXPayload.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/AXPayload.swift)
- [Sources/MacControlMCP/AXSearch.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/AXSearch.swift)
- [Sources/MacControlMCP/AccessibilityController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/AccessibilityController.swift)
- [Sources/MacControlMCP/TextEditingController.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/TextEditingController.swift)
- [Sources/MacControlMCP/Tools+TextEditing.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/Tools+TextEditing.swift)
- [Sources/MacControlMCP/Tools+V2.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/Tools+V2.swift)
- [Sources/MacControlMCP/Tools.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Sources/MacControlMCP/Tools.swift)
- [Tests/MacControlMCPTests/AXAttributeBatchTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Tests/MacControlMCPTests/AXAttributeBatchTests.swift)
- [Tests/MacControlMCPTests/AXPayloadBudgetTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Tests/MacControlMCPTests/AXPayloadBudgetTests.swift)
- [Tests/MacControlMCPTests/SemanticSearchTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Tests/MacControlMCPTests/SemanticSearchTests.swift)
- [Tests/MacControlMCPTests/TextEditingBackendTests.swift](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/Tests/MacControlMCPTests/TextEditingBackendTests.swift)
- [docs/TOOLS.md](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/docs/TOOLS.md)

Dit rapport: [S5_REPORT.md](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/S5_REPORT.md).

De tests oefenen de volgende veranderingen uit:

- C5: onafhankelijke titel/description/value/identifier-matching; exacte genormaliseerde rollen; rangschikking en matchherkomst; alle negen gevraagde semantische vormen. Negatieve regressies voor `Book`, `Background`, `Backup`, `Research` en een naamveld naast een Search-knop.
- C6: decoder voor URL-objecten, DOM-id en DOM-classlijsten; webvelden blijven beschikbaar bij veldprojectie. In de code worden de drie attributen alleen aan de bestaande batch toegevoegd wanneer het pad onder `AXWebArea` ligt. Dit is geen gemeten IPC- of latencyclaim.
- C7: FakeBackend met `Hello 👋 wereld 🇳🇱 café`; selectie van 👋 op UTF-16-offset 6, lengte 2; geselecteerde bereik-bounds; verouderd zichtbaar bereik 25 → 23 na verwijderen van 👋; beschikbare insertion-point-lijn 3. Alle zes teksttoolbeschrijvingen noemen UTF-16 en de emoji-lengtes.

## RED → GREEN

### RED vóór implementatie

De eerste compileerbare regressierun tegen het oorspronkelijke gedrag:

```text
✘ Test "selection clamps stale visible range after an emoji edit" recorded an issue at TextEditingBackendTests.swift:158:9: Expectation failed: (selection.visibleRange → TextRange(location: 0, length: 25)) == (.init(location: 0, length: 23) → TextRange(location: 0, length: 23))
✘ Test "selection reports bounds for the entire selected UTF-16 range" recorded an issue at TextEditingBackendTests.swift:167:9: Expectation failed: (bounds?.width → nil) == (2 → 2.0)
✘ Test run with 49 tests in 3 suites failed after 0.010 seconds with 9 issues.
```

Volledige uitvoer: [red.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/red.log).

Daarna aparte RED-runs voor de nieuwe semantische zoekfunctie (eerst lege testseam), webdecoder en reviewregressies, in deze volgorde:

```text
✘ Test run with 5 tests in 1 suite failed after 0.001 seconds with 16 issues.
✘ Test run with 10 tests in 1 suite failed after 0.003 seconds with 8 issues.
✘ Test run with 7 tests in 1 suite failed after 0.002 seconds with 5 issues.
✘ Test run with 8 tests in 1 suite failed after 0.044 seconds with 2 issues.
✘ Test run with 9 tests in 1 suite failed after 0.065 seconds with 1 issue.
```

Logs:

- [c5-red.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/c5-red.log)
- [c6-red.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/c6-red.log)
- [review-red.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/review-red.log)
- [provenance-red.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/provenance-red.log)
- [neighbor-red.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/neighbor-red.log)

### GREEN na implementatie

Eerste gerichte bevestigingen:

```text
✔ Test run with 26 tests in 1 suite passed after 0.002 seconds.
✔ Test run with 29 tests in 3 suites passed after 0.005 seconds.
✔ Test run with 7 tests in 1 suite passed after 0.046 seconds.
✔ Test run with 9 tests in 1 suite passed after 0.048 seconds.
```

Logs: [c7-green.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/c7-green.log), [c5-c6-green.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/c5-c6-green.log), [review-green.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/review-green.log), [neighbor-green.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/neighbor-green.log).

### Definitieve gefilterde suites

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'TextEditingBackendTests|TextEditingTests|CodexR2RegressionTests|Phase9ToolsTests|AXPayloadBudgetTests|ToolDocsDriftTests|AXAttributeBatchTests|SemanticSearchTests'
```

```text
✔ Suite "AXAttributeBatch" passed after 0.001 seconds.
✔ Suite "AX payload budget (C-9)" passed after 0.001 seconds.
✔ Suite "Codex r2 regressions" passed after 0.009 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.017 seconds.
✔ Suite "Semantic search (v0.10 C5)" passed after 0.046 seconds.
✔ Suite "Text editing — AX backend seam (C-7 review)" passed after 0.001 seconds.
✔ Suite "Text editing primitives (C-7)" passed after 0.007 seconds.
✔ Suite "Tool docs drift" passed after 0.015 seconds.
✔ Test run with 119 tests in 8 suites passed after 0.103 seconds.
```

Exit 0. Volledige uitvoer: [final-suites.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/final-suites.log). De volledige testsuite is niet gestart.

De originele `swift build` strandde op de niet-schrijfbare `/Users/a/.cache/clang/ModuleCache`. De herhaling en eindbuild gebruikten een schrijfbare compiler-cache. `--disable-sandbox` schakelt alleen de extra SwiftPM-manifest-sandbox uit; de uitvoeromgeving bleef beperkt.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache swift build --disable-sandbox
```

```text
Build complete! (0.15s)
```

Exit 0: [final-build.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/final-build.log). `git diff --check` gaf geen uitvoer en exit 0.

### Tooldocumentatie

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s5-clang-cache UPDATE_TOOL_DOCS=1 script -q /dev/null swift test --disable-sandbox --no-parallel --filter ToolDocsDriftTests
```

```text
✔ Test run with 4 tests in 1 suite passed after 0.035 seconds.
```

Log: [docs-final.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/docs-final.log). `docs/TOOLS.md` is gegenereerd. Er zijn geen tools toegevoegd; de verwachte toolcount is niet aangepast.

## Metingen vóór/na

Dezelfde bestaande `perf.py`, dezelfde browser-pids uit `res_ax.json`, `get_ui_tree`, default `max_depth=24`, zeven metingen na warming:

```sh
PROBE_MAX=300000 python3 ../perf.py .build/debug/mac-control-mcp .build/s5-evidence/perf-cases.json 7 .build/s5-evidence/perf-after.json
```

| App / audit-pid | Geleverde 0.9.0 p50 | Nodes vóór | Huidige probe-p50 | Nodes nu | Conclusie |
|---|---:|---:|---:|---:|---|
| Safari / 681 | 95.8 ms | 1114 | 0.7 ms | 1, role=null | Geen geldige vergelijking |
| Chrome / 41308 | 43.0 ms | 481 | 0.6 ms | 1, role=null | Geen geldige vergelijking |

Deze cijfers tonen **geen versnelling**. De huidige binary bereikt geen echte browserboom. De grens ≤ +10% is **niet geverifieerd**. Ook de huidige identiteit van de audit-pids kon de binary niet bevestigen.

Bronnen: [geleverde baseline](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/res_ax.json), [perf-cases.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/perf-cases.json), [perf-after.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/perf-after.log), [perf-after.json](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/perf-after.json).

Dezelfde NDJSON-probe is daarnaast vóór en na de edits uitgevoerd:

```sh
PROBE_MAX=300000 python3 ../probe.py .build/debug/mac-control-mcp '[["list_apps",{}],["get_ui_tree",{"pid":681}],["get_ui_tree",{"pid":41308}]]'
```

| Aanroep | Vóór | Na | Inhoud beide keren |
|---|---:|---:|---|
| Safari `get_ui_tree` | 2 ms | 2 ms | Eén lege AX-root |
| Chrome `get_ui_tree` | 1 ms | 1 ms | Eén lege AX-root |

Volledige uitvoer: [live-before.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/live-before.log), [live-after.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/live-after.log). Ook deze single-call timings zijn geen browserprestatiemeting.

## Live-probes

### Toegang

Uit `permissions_status` van de gebouwde debugbinary:

```json
{
  "accessibility": "not_granted",
  "screen_recording": "not_granted",
  "responsible_app": {"name": "claude", "bundle_id": "com.anthropic.claude-code"}
}
```

Uit `list_apps`:

```json
{"ok":true,"count":0,"apps":[]}
```

Volledige uitvoer, inclusief pad van de debugbinary: [live-permissions.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/live-permissions.log).
Een aparte, alleen-lezen desktopinventaris via CUA meldde Finder, Safari, Chrome en System Settings als actief en TextEdit als niet actief. Dit is geen verificatie van de gewijzigde binary.

### C5: één aanroep per target

De volgende acht aanroepen zijn uitgevoerd met `PROBE_MAX=300000 python3 ../probe.py .build/debug/mac-control-mcp`, steeds één `find_element` per target. Pids komen uit de aangeleverde audit; huidige procesidentiteit niet bevestigd.

| App | pid | semantic | Uitkomst | Element-id/titel |
|---|---:|---|---|---|
| Finder | 742 | search_field | ok:false | Geen |
| Finder | 742 | back | ok:false | Geen |
| Safari | 681 | search_field | ok:false | Geen |
| Safari | 681 | back | ok:false | Geen |
| Chrome | 41308 | search_field | ok:false | Geen |
| Chrome | 41308 | back | ok:false | Geen |
| System Settings | 76246 | search_field | ok:false | Geen |
| System Settings | 76246 | back | ok:false | Geen |
| TextEdit | — | search_field / back | Niet uitgevoerd: app draait niet, binary heeft geen AX-toegang | Geen |

Voorbeeld van de werkelijke gestructureerde uitvoer:

```json
{
  "pid":742,"max_depth_used":24,"ok":false,"role":null,"exact":false,"title":null,
  "ax_tree_hint":"This app (unknown) exposes no AX children or windows even after enabling AXManualAccessibility / AXEnhancedUserInterface. It likely does not implement NSAccessibility. Options: (a) use coord-based clicks via the `click` tool with x/y, (b) use `ocr_screen` to locate targets visually, (c) try a web alternative if one exists."
}
```

De hint is ruwe serveruitvoer; de gemeten ontbrekende Accessibility-toegang verhindert een conclusie over de AX-ondersteuning van de apps. Volledige acht resultaten: [live-semantic.log](/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-web/.build/s5-evidence/live-semantic.log).

### C6: link met URL

Geen live linknode bereikt. De browserprobes leverden alleen `role:null`, `title:null`, `children:[]`. De URL `https://example.org/path` is uitsluitend een decoder-testfixture; geen live-verificatie.

### C7: eigen TextEdit-document

Niet live uitgevoerd. Er is geen TextEdit-document geopend of gewijzigd: de binary heeft geen AX-toegang en kan het doel niet betrouwbaar vinden. De emoji-edit, bereik-bounds, zichtbare range en insertion-point-lijn zijn alleen met FakeBackend geverifieerd. Geen gebruikersvensters verplaatst, geen instellingen gewijzigd en geen clipboard-write uitgevoerd.

## Review en resterend werk

De onafhankelijke code-review vond twee fouten: onbegrensde semantische aliassen en een Search-knop die een echt veld kon verdringen. Beide kregen RED→GREEN-regressies. De tweede review meldde geen nieuwe belangrijke problemen in de aanvullende delta.

Nog vereist voordat S5 als afgerond kan gelden:

1. De debugbinary kunnen draaien met werkende AX-toegang en toegang tot de actuele app-pids.
2. Live `search_field` en `back` in alle vijf apps verifiëren en echte element-ids/titels rapporteren; afwezige controls expliciet onderscheiden van verkeerde matches.
3. Safari/Chrome op dezelfde echte pagina/boom vóór en na meten en de +10%-grens controleren; een live AXLink met `url` tonen.
4. Het eigen TextEdit-document met `Hello 👋 wereld 🇳🇱 café` openen, de gevraagde teksttools live controleren en uitsluitend dat document sluiten.
5. De huidige aanvullende wijzigingen en dit rapport in nieuwe conventionele commits vastleggen zodra de Git-administratie schrijfbaar is.
