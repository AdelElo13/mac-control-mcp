# S1 — bewijsrapport

## Status

De code en alle uitvoerbare headless controles voor A1, A2, A6 en A8 zijn afgerond. Per de laatste gebruikersinstructie zijn de desktopchecks en geldige voor/na-metingen overgedragen aan de reviewer in [LIVE-CHECKS.md](../LIVE-CHECKS.md), met exacte commando’s en verwachte uitkomsten. Er is niet opnieuw om desktoptoegang gevraagd en er zijn geen nieuwe desktopprobes uitgevoerd.

**Nieuwe commits blijven geblokkeerd door de schrijfrechten op de externe Git-administratiemap.** De code, rootdocumentatie en het bewijs staan volledig in deze worktree; WIP 9dcec32 is intact.

## Commits

- Branch: `feat/v0.10-ids`.
- Bestaande WIP: `9dcec32 wip(codex): partial S-ids work before usage-limit stop (uncompiled, do not merge)`; intact gelaten.
- Nieuwe commits: geen. `git add` faalt vóór commit:

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ids/index.lock': Operation not permitted
```

De administratieve Git-map ligt buiten de schrijfbare sandbox. Geen amend, revert, push, merge of rebase uitgevoerd. De resterende wijzigingen staan in de worktree; zie [status](git-status-final.txt) en de [laatste commitpoging](commit-attempt.txt). LIVE-CHECKS.md bevat ook de exacte drie conventionele commitcommando’s voor de reviewer.

## Bestanden en gedrag

- A1: `resolveLive` vergelijkt iedere geregistreerde leaf met de fingerprint uit één batch; mismatch loopt het pad opnieuw, onleesbare/verdwenen identiteit wordt stale. Pathless gedrag blijft aanwezig. De batchcontrole heeft geen per-attribuut fallback. Dit is broncodecontrole, geen gemeten IPC-trace.
- A2: maximaal 20.000 handles, onafhankelijk van de 2.000-node boomlimiet. Capaciteit verwijdert oudste captures van dezelfde pid eerst; refresh reserveert uitsluitend de benodigde slots. Collision-quarantaine wordt in de reservering meegenomen. Bekende capaciteitsverwijderingen geven `evicted_element_id`, met begrensde historie tot de TTL. Hints gebruiken de geconfigureerde limieten.
- A6: find/query/list melden de door de walk bezochte nodes vóór resultaatfiltering.
- A8: upwardPath herkent het echte applicatiehandle met CFEqual, inclusief een applicatieroot als lege path. De bestaande AXApplication-route blijft beschikbaar. Hit-tests zonder pad geven `stable_id:false` en een reden.

Gewijzigde bron-, test- en documentatiebestanden ten opzichte van integration/v0.10:

- [Sources/MacControlMCP/AXAttributeBatch.swift](../Sources/MacControlMCP/AXAttributeBatch.swift)
- [Sources/MacControlMCP/AXPath.swift](../Sources/MacControlMCP/AXPath.swift)
- [Sources/MacControlMCP/AccessibilityController.swift](../Sources/MacControlMCP/AccessibilityController.swift)
- [Sources/MacControlMCP/ElementCache.swift](../Sources/MacControlMCP/ElementCache.swift)
- [Sources/MacControlMCP/TextEditingController.swift](../Sources/MacControlMCP/TextEditingController.swift)
- [Sources/MacControlMCP/Tools+Annotate.swift](../Sources/MacControlMCP/Tools+Annotate.swift)
- [Sources/MacControlMCP/Tools+TextEditing.swift](../Sources/MacControlMCP/Tools+TextEditing.swift)
- [Sources/MacControlMCP/Tools+V0_9AXCore.swift](../Sources/MacControlMCP/Tools+V0_9AXCore.swift)
- [Sources/MacControlMCP/Tools+V2.swift](../Sources/MacControlMCP/Tools+V2.swift)
- [Sources/MacControlMCP/Tools+V2Phase6.swift](../Sources/MacControlMCP/Tools+V2Phase6.swift)
- [Sources/MacControlMCP/Tools.swift](../Sources/MacControlMCP/Tools.swift)
- [Tests/MacControlMCPTests/AXPathTests.swift](../Tests/MacControlMCPTests/AXPathTests.swift)
- [Tests/MacControlMCPTests/ElementCacheTests.swift](../Tests/MacControlMCPTests/ElementCacheTests.swift)
- [Tests/MacControlMCPTests/TextEditingTests.swift](../Tests/MacControlMCPTests/TextEditingTests.swift)
- [docs/TOOLS.md](../docs/TOOLS.md)
- [LIVE-CHECKS.md](../LIVE-CHECKS.md)


Geen nieuwe dependencies of tools. Toolcount bleef ongewijzigd. `docs/TOOLS.md` is met de drift-test gegenereerd; README, RELEASE_NOTES, server.json, npm en versieconstanten zijn niet gewijzigd.

## RED → GREEN

Alle genoemde RED-bestanden bevatten testassertiefouten vóór de bijbehorende correctie. De oudere tussenruns `red-tree-eviction.txt` en `red-unreadable.txt` bevatten ook fout gespelde toolnamen in een test; die zijn gecorrigeerd vóór de geldige RED-run `red-edge-cases.txt` en worden hieronder niet als bewijs gebruikt.


### A1/A2/A6/A8 eerste regressies

[RED](red.txt), daarna [GREEN](green-initial.txt).

```text
✘ Test run with 29 tests in 2 suites failed after 0.370 seconds with 11 issues.
✔ Test run with 29 tests in 2 suites passed after 0.363 seconds.
```


### A1 onleesbare fingerprint; A2 tree-age/collision/notification

[RED](red-edge-cases.txt), daarna [GREEN](green-edge-cases.txt).

```text
✘ Test run with 21 tests in 1 suite failed after 0.351 seconds with 7 issues.
✔ Test run with 48 tests in 3 suites passed after 0.373 seconds.
```


### A6 list_elements

[RED](red-list-metadata.txt), daarna [GREEN](green-stability-reason.txt).

```text
✘ Test run with 12 tests in 1 suite failed after 0.011 seconds with 1 issue.
✔ Test run with 13 tests in 1 suite passed after 0.009 seconds.
```


### A8 random-id reden

[RED](red-stability-reason.txt), daarna [GREEN](green-stability-reason.txt).

```text
✘ Test run with 13 tests in 1 suite failed after 0.007 seconds with 1 issue.
✔ Test run with 13 tests in 1 suite passed after 0.009 seconds.
```


### A2 teksthint

[RED](red-text-hint.txt), daarna [GREEN](green-text-hint.txt).

```text
✘ Test run with 30 tests in 1 suite failed after 0.012 seconds with 2 issues.
✔ Test run with 54 tests in 2 suites passed after 0.014 seconds.
```


### A2 herhaalde hashbotsingen

[RED](red-repeated-collision.txt), daarna [GREEN](green-repeated-collision.txt).

```text
✘ Test run with 22 tests in 1 suite failed after 0.483 seconds with 1 issue.
✔ Test run with 22 tests in 1 suite passed after 0.353 seconds.
```


Voorbeelden van de daadwerkelijke RED-asserties:

```text
v0.10 A1: live handle silently resolved a different control
(payload?["nodes_visited"]?.intValue → 0) == 1
AXPath.upwardPath(of: AXUIElementCreateApplication(getpid())) → nil, expected []
(payload["stable_id_reason"]?.stringValue?.isEmpty → nil) == false
await cache.count <= 5
```

## Aanvullende fake-tests en mutatiecontrole

ElementCache heeft nu injecteerbare, `@Sendable` AX-operaties met dezelfde native defaults. De lock-beveiligde fake verifieert drie desktop-onafhankelijke gevallen: dezelfde menuhandle wordt hernoemd en afgewezen; een mismatch wordt via het pad hersteld en onder hetzelfde id gecachet; een pathless id gebruikt uitsluitend de bestaande livenesscontrole. De intacte leaf gebruikt precies één fingerprint-read, geen aparte liveness-read en geen repair.

Deze aanvullende tests zijn eerst tegen de reeds correcte implementatie gedraaid ([uitvoer](fake-baseline.txt)). Daarna is uitsluitend voor de mutatiecontrole tijdelijk de oorspronkelijke `isAlive`-fastpath teruggezet. De test faalde; de fingerprintcode is in een `finally`-blok hersteld en opnieuw getest. Dit is extra mutatiebewijs, niet een claim dat de nieuwe fake-tests zelf vóór de eerdere A1-implementatie zijn geschreven. De oorspronkelijke A1 RED→GREEN staat hierboven.

[Mutatie-RED](red-fake-live-fastpath.txt), daarna [GREEN](green-fake-live-fastpath.txt):

```text
✘ Test run with 25 tests in 1 suite failed after 0.388 seconds with 9 issues.
✔ Test run with 25 tests in 1 suite passed after 0.381 seconds.
```

[LIVE-CHECKS-validatie](live-checks-validation.txt): zes shellblokken en twee Python-programma’s zijn syntax-gecontroleerd zonder ze op de desktop uit te voeren. Fake-antwoordtests accepteren dezelfde/stale identiteit en weigeren een andere titel. Een gesimuleerde fout na windowcreatie sluit alleen nieuw window 11, niet bestaand window 10. De laatste broncode-/documentatiereview heeft geen materiële bevindingen.

## Definitieve gefilterde suites

Iedere suite is apart uitgevoerd met:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" script -q /dev/null swift test --disable-sandbox --no-parallel --filter <Suite>
```

`--disable-sandbox` betreft de SwiftPM-buildsandbox; de externe Codex-sandbox bleef actief. De initiële standaardbuild kon niet naar de Clang-cache onder /Users/a schrijven. De modulecache is voor de definitieve runs binnen `.build` geplaatst. De volledige suite is niet gestart.


[ElementCacheTests](final-ElementCacheTests.txt)

```text
✔ Suite "ElementCache" passed after 0.368 seconds.
✔ Test run with 25 tests in 1 suite passed after 0.368 seconds.
```

[AXPathTests](final-AXPathTests.txt)

```text
✔ Suite "AX path identity (C-5)" passed after 0.008 seconds.
✔ Test run with 13 tests in 1 suite passed after 0.008 seconds.
```

[CodexR2RegressionTests](final-CodexR2RegressionTests.txt)

```text
✔ Suite "Codex r2 regressions" passed after 0.014 seconds.
✔ Test run with 13 tests in 1 suite passed after 0.015 seconds.
```

[AnnotatedElementIdentityTests](final-AnnotatedElementIdentityTests.txt)

```text
✔ Suite "capture_annotated element identity (C-5)" passed after 0.008 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.008 seconds.
```

[TextEditingTests](final-TextEditingTests.txt)

```text
✔ Suite "Text editing primitives (C-7)" passed after 0.013 seconds.
✔ Test run with 30 tests in 1 suite passed after 0.013 seconds.
```

[Phase9ToolsTests](final-Phase9ToolsTests.txt)

```text
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.023 seconds.
✔ Test run with 14 tests in 1 suite passed after 0.023 seconds.
```

[AXHandleSafetyTests](final-AXHandleSafetyTests.txt)

```text
✔ Suite "AX handle safety (C-5 review)" passed after 0.003 seconds.
✔ Test run with 15 tests in 1 suite passed after 0.004 seconds.
```

[AXAttributeBatchTests](final-AXAttributeBatchTests.txt)

```text
✔ Suite "AXAttributeBatch" passed after 0.001 seconds.
✔ Test run with 8 tests in 1 suite passed after 0.001 seconds.
```

[Phase6ToolsTests](final-Phase6ToolsTests.txt)

```text
✔ Suite "Phase 6 tools — control plane + event waits" passed after 1.251 seconds.
✔ Test run with 12 tests in 1 suite passed after 1.251 seconds.
```

[TextEditingBackendTests](final-TextEditingBackendTests.txt)

```text
✔ Suite "Text editing — AX backend seam (C-7 review)" passed after 0.001 seconds.
✔ Test run with 24 tests in 1 suite passed after 0.001 seconds.
```

[AXPayloadBudgetTests](final-AXPayloadBudgetTests.txt)

```text
✔ Suite "AX payload budget (C-9)" passed after 0.002 seconds.
✔ Test run with 13 tests in 1 suite passed after 0.002 seconds.
```


De runner meldt samen 172 tests in 11 suites. Dat is **geen bewijs van 172 uitgevoerde live checks**: alle vijf AnnotatedElementIdentityTests melden expliciet dat zij vroeg terugkeren zonder AX-trust. Ook de Finder-branches in AXPathTests, AXHandleSafetyTests en AXPayloadBudgetTests zijn niet uitgevoerd door hun trust/Finder-guards.

[Build-output](build-final.txt):

```text
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.15s)
```

[Tooldocumentatiecontrole](tool-docs-final.txt), uitgevoerd met `UPDATE_TOOL_DOCS=1` en dezelfde PTY-wrapper:

```text
✔ Suite "Tool docs drift" passed after 0.042 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.042 seconds.
```

Broncodereview is uitgevoerd met de requesting-code-review-skill. Laatste revieweruitkomst: geen resterende materiële bevindingen; geen desktoptests door de reviewer uitgevoerd.

## Historische sandboxmetingen — geen performancebewijs

De aangeleverde `res_ax.json` is de vóór-meting (0.9.0, perf.py, 7 warme herhalingen). Dezelfde 24 AX-cases en argumenten zijn in de vorige uitvoeringsronde met dezelfde `perf.py` tegen de toen bijgewerkte `.build/debug/mac-control-mcp` uitgevoerd, opnieuw 7 herhalingen na warm-up. Deze poging dateert van vóór de nieuwe fake-injectie en was wegens ontbrekende desktoptoegang niet bruikbaar. Er zijn nu geen nieuwe sandboxmetingen gedaan; de actuele vergelijking staat exact uitgeschreven in LIVE-CHECKS.md.

```sh
python3 SCRATCH/perf.py .build/debug/mac-control-mcp .s1-evidence/perf-cases.json 7 .s1-evidence/perf-after.json
```

[Cases](perf-cases.json), [aangeleverde baseline](perf-before-supplied.json), [na-meting](perf-after.json), [ruwe uitvoer](perf-after-run.txt).

**De onderstaande na-tijden meten onleesbare roots of foutantwoorden. Er is geen geldige snelheidswinst, regressie of ≤1-extra-IPC-runtimeclaim uit af te leiden.** Alle walks zagen één node; iedere hit-test faalde 7/7 met `permission_missing`.

| Case | Vóór p50 ms | Na p50 ms | Na-context |
|---|---:|---:|---|

| get_ui_tree/Finder | 724.2 | 0.7 | slechts 1 onleesbare root |

| get_ui_tree(interactive,fields)/Finder | 639.7 | 0.6 | slechts 1 onleesbare root |

| find_elements(AXButton,20)/Finder | 428.3 | 0.8 | slechts 1 onleesbare root |

| query_elements(^Eject$)/Finder | 890.3 | 0.7 | slechts 1 onleesbare root |

| list_elements/Finder | 881.9 | 0.7 | slechts 1 onleesbare root |

| element_at_point/Finder | 5.0 | 0.1 | permission_missing, 7/7 fouten |

| get_ui_tree/Safari | 95.8 | 0.7 | slechts 1 onleesbare root |

| get_ui_tree(interactive,fields)/Safari | 66.3 | 0.6 | slechts 1 onleesbare root |

| find_elements(AXButton,20)/Safari | 67.1 | 0.7 | slechts 1 onleesbare root |

| query_elements(^Go back$)/Safari | 66.9 | 0.7 | slechts 1 onleesbare root |

| list_elements/Safari | 64.8 | 0.7 | slechts 1 onleesbare root |

| element_at_point/Safari | 2.7 | 0.1 | permission_missing, 7/7 fouten |

| get_ui_tree/Chrome | 43.0 | 0.7 | slechts 1 onleesbare root |

| get_ui_tree(interactive,fields)/Chrome | 32.6 | 0.6 | slechts 1 onleesbare root |

| find_elements(AXButton,20)/Chrome | 8.1 | 0.7 | slechts 1 onleesbare root |

| query_elements(^Reload$)/Chrome | 31.8 | 0.7 | slechts 1 onleesbare root |

| list_elements/Chrome | 28.8 | 0.7 | slechts 1 onleesbare root |

| element_at_point/Chrome | 2.8 | 0.2 | permission_missing, 7/7 fouten |

| get_ui_tree/SysSettings | 376.0 | 0.7 | slechts 1 onleesbare root |

| get_ui_tree(interactive,fields)/SysSettings | 379.8 | 0.6 | slechts 1 onleesbare root |

| find_elements(AXButton,20)/SysSettings | 246.6 | 0.7 | slechts 1 onleesbare root |

| query_elements(^Search$)/SysSettings | 371.2 | 0.7 | slechts 1 onleesbare root |

| list_elements/SysSettings | 356.0 | 0.7 | slechts 1 onleesbare root |

| element_at_point/SysSettings | 5.1 | 0.1 | permission_missing, 7/7 fouten |


## Live-probes

Alle probes hieronder gebruiken de debugbinary en de opgegeven `SCRATCH/probe.py`, met `PROBE_MAX=300000`. Er is geen base64-output om te trimmen.

- [Vóór: app-/window-/permissiondiscovery](live-before.txt).
- [Na: permissions, apps, windows, hit-test](live-after.txt).
- [Finder/Chrome gerichte pogingen](live-finder-chrome.txt). Omdat discovery leeg was, gebruiken deze pogingen de pids en Chrome-coördinaat uit de aangeleverde baseline; actuele pid/window-identiteit kon niet worden bevestigd.

Belangrijkste uitvoer:

```text
permissions_status: accessibility = not_granted; screen_recording = not_granted
list_apps: apps = [], count = 0
list_windows: windows = [], count = 0
Finder find_elements(AXMenuItem, Minimize): elements = [], nodes_visited = 1
Chrome find_elements(AXLink): elements = [], nodes_visited = 1
element_at_point: ok = false, error_code = permission_missing
```

`responsible_app` is `com.anthropic.claude-code`. Geen nieuwe Finder-window geopend: er kon vooraf geen Window-menu-id worden gemint of geverifieerd. Geen gebruikersvensters gesloten, geen clicks/typing/moves/clipboardwrites of wijzigingen aan permissies/instellingen uitgevoerd.

## Overgedragen en geblokkeerd

[**LIVE-CHECKS.md**](../LIVE-CHECKS.md) bevat complete, uitvoerbare reviewercommando’s voor:

1. Actuele permission/app/window-discovery met de opgegeven stock-probe.
2. Een persistente A1-menu-smoketest: ids minten, een eigen tweede Finder-window openen/sluiten, daarna dezelfde titel of stale_element eisen. Ongewijzigde targets worden expliciet niet als live relabelbewijs aangemerkt.
3. A2: zes echte 2.000-node Finder-walks en behoud van oude ids uit Finder en Chrome.
4. A6: nul-match queries met echte bezochte-nodeaantallen, vergeleken met een treewalk op dezelfde diepte.
5. A8: Chrome window_id → linkzoekresultaat → herhaalde hit-tests; ids moeten overeenkomen. Random fallback vereist een reden en wordt niet als bewezen Chrome-fix aangemerkt.
6. Een baselinebuild van cb435a8 binnen deze worktree, en dezelfde persistente meetprobe tegen baseline en huidige debugbinary: warme sessies, zeven samples, inclusief cached-id-resolutie en Chrome-hit-test. Geen checkout/rebase/amend vereist.
7. De bestaande desktopafhankelijke gefilterde suites, zonder full-suite-run.

Deze livechecks zijn per gebruikersinstructie overgedragen, niet stilzwijgend overgeslagen of als geslaagd gerapporteerd. De nieuwe conventionele commits konden ondanks een nieuwe poging niet worden gemaakt: `git add` eindigt met exitcode 128 omdat `index.lock` buiten de schrijfbare sandbox ligt. De benodigde commitcommando’s staan eveneens in LIVE-CHECKS.md.
