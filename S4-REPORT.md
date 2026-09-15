# S4 — verificatierapport

## Status

De wijzigingen staan in `feat/v0.10-actions`. De build slaagt. Negen functionele suites slagen; de twee tests voor releasebestanden binnen ToolDocsDriftTests falen. Live TextEdit-acties en nieuwe commits konden niet worden uitgevoerd vanuit de opgelegde sandbox. De opdracht is daarom **niet volledig afgerond**.

## Commits

Bestaande WIP-commits, ongewijzigd behouden:

```text
9e474d7 wip(codex): partial S-actions work, second snapshot before usage-limit stop (uncompiled, do not merge)
1a68c6c wip(codex): partial S-actions work before usage-limit stop (uncompiled, do not merge)
```

Nieuwe commits: geen. De poging om de eerste kleine budgetcommit te stagen faalt; er is geen amend, revert, push, merge of rebase uitgevoerd.

```text
git add Sources/MacControlMCP/ServerLifecycle.swift Tests/MacControlMCPTests/ServerLifecycleTests.swift
exit_code=128
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-actions/index.lock': Operation not permitted
```

Bewijs: [commits.txt](.build/s4-evidence/commits.txt), [branch.txt](.build/s4-evidence/branch.txt), [commit-attempt.txt](.build/s4-evidence/commit-attempt.txt). Alle vervolgwijzigingen zijn lokaal en ongecommit.

## Bestanden

Gewijzigde bestanden ten opzichte van `integration/v0.10`, inclusief nieuwe bron- en testbestanden:

- [Sources/MacControlMCP/ConditionWait.swift](Sources/MacControlMCP/ConditionWait.swift)
- [Sources/MacControlMCP/ElementInput.swift](Sources/MacControlMCP/ElementInput.swift)
- [Sources/MacControlMCP/MouseController.swift](Sources/MacControlMCP/MouseController.swift)
- [Sources/MacControlMCP/ServerLifecycle.swift](Sources/MacControlMCP/ServerLifecycle.swift)
- [Sources/MacControlMCP/Tools+ActionDefinitions.swift](Sources/MacControlMCP/Tools+ActionDefinitions.swift)
- [Sources/MacControlMCP/Tools+Batch.swift](Sources/MacControlMCP/Tools+Batch.swift)
- [Sources/MacControlMCP/Tools+ElementActions.swift](Sources/MacControlMCP/Tools+ElementActions.swift)
- [Sources/MacControlMCP/Tools+V2Phase3.swift](Sources/MacControlMCP/Tools+V2Phase3.swift)
- [Sources/MacControlMCP/Tools+V2Phase5.swift](Sources/MacControlMCP/Tools+V2Phase5.swift)
- [Sources/MacControlMCP/Tools+V2Phase7.swift](Sources/MacControlMCP/Tools+V2Phase7.swift)
- [Sources/MacControlMCP/Tools+WaitAndAct.swift](Sources/MacControlMCP/Tools+WaitAndAct.swift)
- [Sources/MacControlMCP/Tools.swift](Sources/MacControlMCP/Tools.swift)
- [Tests/MacControlMCPTests/BatchToolTests.swift](Tests/MacControlMCPTests/BatchToolTests.swift)
- [Tests/MacControlMCPTests/ConditionWaitTests.swift](Tests/MacControlMCPTests/ConditionWaitTests.swift)
- [Tests/MacControlMCPTests/ElementActionTests.swift](Tests/MacControlMCPTests/ElementActionTests.swift)
- [Tests/MacControlMCPTests/ElementInputTests.swift](Tests/MacControlMCPTests/ElementInputTests.swift)
- [Tests/MacControlMCPTests/FocusGuardTests.swift](Tests/MacControlMCPTests/FocusGuardTests.swift)
- [Tests/MacControlMCPTests/MouseControllerTests.swift](Tests/MacControlMCPTests/MouseControllerTests.swift)
- [Tests/MacControlMCPTests/Phase5ToolsTests.swift](Tests/MacControlMCPTests/Phase5ToolsTests.swift)
- [Tests/MacControlMCPTests/ServerLifecycleTests.swift](Tests/MacControlMCPTests/ServerLifecycleTests.swift)
- [Tests/MacControlMCPTests/ToolDocsDriftTests.swift](Tests/MacControlMCPTests/ToolDocsDriftTests.swift)
- [docs/TOOLS.md](docs/TOOLS.md)

Dit rapport is toegevoegd als `S4-REPORT.md`. Ruwe uitvoer staat onder `.build/s4-evidence/` (lokaal, niet door Git gevolgd).

## RED → GREEN

De volgende uitvoer is vastgelegd vóór de bijbehorende correcties. De volledige logs bevatten de afzonderlijke assertions; compilerfouten zijn niet als geslaagde RED-bewijzen gebruikt.

### A3 — tien goedkope calls

[a3-red.txt](.build/s4-evidence/a3-red.txt)

```text
✘ Test run with 2 tests in 2 suites failed after 0.005 seconds with 5 issues.
```

### C1/C3/C4/C8 — nieuwe ingangen

[actions-red.txt](.build/s4-evidence/actions-red.txt)

```text
✘ Test run with 6 tests in 1 suite failed after 0.010 seconds with 31 issues.
```

### C3 — deadline en C1 — geometrie

[resume-red.txt](.build/s4-evidence/resume-red.txt)

```text
✘ Test run with 14 tests in 3 suites failed after 0.123 seconds with 23 issues.
```

### C4 — secure focus

[focus-red.txt](.build/s4-evidence/focus-red.txt)

```text
✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 4 issues.
```

### C8 — validatie vóór actie

[validation-red.txt](.build/s4-evidence/validation-red.txt)

```text
✘ Test run with 2 tests in 2 suites failed after 0.003 seconds with 11 issues.
```

### C8 — foutantwoord

[envelope-red.txt](.build/s4-evidence/envelope-red.txt)

```text
✘ Test run with 1 test in 1 suite failed after 0.002 seconds with 3 issues.
```

### A3 — lange toetsreeksen

[sequence-red.txt](.build/s4-evidence/sequence-red.txt)

```text
✘ Test run with 6 tests in 2 suites failed after 0.092 seconds with 2 issues.
```

### A3 — overige read-budgetten

[read-budgets-red.txt](.build/s4-evidence/read-budgets-red.txt)

```text
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 4 issues.
```

### C1 — mouseUp-voorbereiding

[mouse-release-red.txt](.build/s4-evidence/mouse-release-red.txt)

```text
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
```

### Definitieve build en gefilterde suites

Eerste verplichte `swift build` faalde op een niet-schrijfbare standaardmodulecache. De werkende variant houdt caches in deze worktree en schakelt uitsluitend SwiftPM's geneste sandbox uit:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift build --disable-sandbox
```

```text
Build complete! (2.09s)
```

Definitief testcommando; geen volledige suite uitgevoerd:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'ElementInputTests|ElementActionTests|FocusGuardTests|MouseControllerTests|ConditionWaitTests|BatchToolTests|ServerLifecycleTests|Phase5ToolsTests|TextEditingBackendTests|ToolDocsDriftTests'
```

```text
✔ Suite "Batch tool" passed after 1.532 seconds.
✔ Suite "Condition waits" passed after 0.115 seconds.
✔ Suite "Element actions" passed after 0.119 seconds.
✔ Suite "Verified element input" passed after 0.001 seconds.
✔ Suite "FocusGuard — input focus matching" passed after 0.001 seconds.
✔ Suite "Mouse visible targeting" passed after 0.001 seconds.
✔ Suite "Phase 5 tools — SHOULD + NICE" passed after 0.208 seconds.
✔ Suite "v0.8.3 server lifecycle" passed after 7.767 seconds.
✔ Suite "Text editing — AX backend seam (C-7 review)" passed after 0.003 seconds.
✔ Test "docs/TOOLS.md matches the live tool registry" passed after 0.006 seconds.
✘ Suite "Tool docs drift" failed after 0.053 seconds with 3 issues.
✘ Test run with 110 tests in 10 suites failed after 9.804 seconds with 3 issues.
```

Bewijs: [final-build.txt](.build/s4-evidence/final-build.txt), [final-verification.txt](.build/s4-evidence/final-verification.txt). De gerichte muisregressie eindigde ook zelfstandig met:

```text
✔ Test run with 6 tests in 1 suite passed after 0.001 seconds.
```

Testwijzigingen met reden: batch-/lifecycle-tests gebruiken `list_apps` in plaats van `focused_app` om budgetten en volgorde zonder desktopfocus te testen. De positieve FocusGuard-test gebruikt een expliciete snapshot. ElementInput en MouseController hebben fakes vóór desktop-API's. Er zijn geen echte muisevents uit de muisfakes verstuurd.

### Documentatie

Uitgevoerd:

```sh
UPDATE_TOOL_DOCS=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" script -q /dev/null swift test --disable-sandbox --no-parallel --filter ToolDocsDriftTests
```

`docs/TOOLS.md` is gegenereerd en de latere vergelijking met de registry slaagt. Phase5ToolsTests controleert 153 tools. De generator wijzigt README alleen nog met aanvullend `UPDATE_RELEASE_TOOL_DOCS=1`; dat is hier niet gezet.

Resterende failures: README heeft twee markers met 151 tegenover 153 geregistreerde tools; server.json vermeldt eveneens de oude count. Dat zijn **twee falende tests, drie issues**. Deze bestanden zijn volgens de opdracht niet gewijzigd. Bewijs: [docs-regenerate.txt](.build/s4-evidence/docs-regenerate.txt), [final-verification.txt](.build/s4-evidence/final-verification.txt).

## Dezelfde probe vóór en na

Gebruikt: `PROBE_MAX=300000 python3 ../probe.py .build/debug/mac-control-mcp '<calls>'`. De batchpayload is in beide runs exact dezelfde: tien `list_apps`-calls, zonder testoverride.

```text
--- batch {"calls": [{"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}]} -> 2 ms
--- batch {"calls": [{"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}, {"name": "list_apps"}]} -> 3 ms
```

Voor:

```json
{"ok":false,"error_code":"invalid_argument","error":"batch budget 900s (sum of each call's timeout, plus delay_ms overhead) exceeds the 295s cap (300s minus 5s reserved for the outer call handler); split it into smaller batches or reduce delay_ms."}
```

Na, geselecteerde velden uit de onverkorte uitvoer:

```json
{"ok":true,"completed":10,"stopped_at":null,"total_ms":2}
```

Alle tien subresultaten hebben `ok:true`. In deze sandbox geeft elke read `count:0, apps:[]`. Dit toont acceptatie en uitvoering van tien calls; het is **geen claim van lagere latency**. Eén afgewezen request en één uitgevoerde batch zijn geen vergelijkbare prestatiebenchmark. Er wordt geen p50/p95- of UI-snelheidswinst geclaimd.

Onverkorte probe-uitvoer: [batch-before.txt](.build/s4-evidence/batch-before.txt), [batch-after.txt](.build/s4-evidence/batch-after.txt).

## Round-trip-aantallen

Dit zijn aantallen `tools/call`-requests afgeleid uit de bestaande en nieuwe ingangen, **geen succesvol gemeten live workflows**:

| Workflow / startpunt | Voor | Na |
|---|---:|---:|
| Bekend veld-ID: AXFocused zetten, tekst typen | 2 (`set_element_attribute`, `type_text`) | 1 (`type_text` met element_id) |
| Knop via pid/role/title klikken, daarna op sheet wachten | 2 (`click`, `wait_for_element`) | 1 (`act` met selector en verify op AXSheet) |
| Expliciet find → klik → wacht op sheet | 3 | 1 (`act`) |

De bestaande `click` kon al zelf een pid/role/title-selector oplossen; daarom was een afzonderlijke find-call niet in ieder scenario nodig. Relevante routes: [Tools.swift](Sources/MacControlMCP/Tools.swift), [Tools+WaitAndAct.swift](Sources/MacControlMCP/Tools+WaitAndAct.swift), [toolschema's](Sources/MacControlMCP/Tools+ActionDefinitions.swift). De live aantallen en doorlooptijden voor succesvolle veld-/sheetacties blijven ongeverifieerd.

## Live probe-uitvoer

De debugbinary is daadwerkelijk via de voorgeschreven NDJSON-probe aangeroepen. Veilige foutpaden:

```text
click(element_id=el_missing) -> unknown_element_id
 type_text(element_id=el_missing, strategy=keys) -> unknown_element_id
 double_click/right_click/scroll/drag_and_drop(element_id=el_missing) -> unknown_element_id
wait_for(element_id=el_missing) -> unknown_element_id
act(target=el_missing, action=set_value) -> acted:false, verified:null, before:null, after:null
```

Voor de exacte verzoeken en antwoorden: [batch-after-and-safe-probes.txt](.build/s4-evidence/batch-after-and-safe-probes.txt), [final-safe-probes.txt](.build/s4-evidence/final-safe-probes.txt). Die laatste bevat ook window-ID-waits op het niet-bestaande ID 4294967295. Geen base64 aanwezig.

Omgevingsprobe:

```text
list_apps: {"count":0,"apps":[],"ok":true}
focused_app: {"ok":false}
permissions_status: accessibility="not_granted", screen_recording="not_granted"
```

Volledige uitvoer: [environment-probe.txt](.build/s4-evidence/environment-probe.txt).

Eigen document aangemaakt op `.build/s4-evidence/s4-textedit.txt`; beide pogingen om uitsluitend dat bestand in TextEdit te openen faalden:

```text
Unable to find application named 'TextEdit'
The application /System/Applications/TextEdit.app cannot be opened for an unexpected reason, error=Error Domain=NSOSStatusErrorDomain Code=-10827 "kLSNoExecutableErr: The executable is missing" UserInfo={_LSLine=4277, _LSFunction=_LSOpenStuffCallLocal, _LSFile=LSOpenCore.mm, _LSErrorMessage=kLSNoExecutableErr}
```

Er is geen TextEdit-window geopend dat kon worden bewerkt of gesloten. De live writecontroles zijn daarom niet uitgevoerd. De vastgelegde actieprobes gebruiken onbekende IDs en worden vóór invoer geweigerd.

## Niet geverifieerd / resterend

- Succesvolle live veldfocus/typing, AXPress/coördinaatklik, `act(set_value)` en sheettransities op een eigen TextEdit-document: geblokkeerd door ontbrekende desktop-/AX-toegang.
- Succesvolle round-tripmetingen voor de twee UI-workflows: dezelfde blokkade.
- Nieuwe conventionele commits: Git-index buiten de schrijfbare sandbox, exit 128.
- Twee release-metadata-tests: mogen alleen groen worden na de apart verboden updates van README/server.json.
- Volledig samengestelde succesvolle ToolRegistry-acties zijn niet met een fake AX-app uitgevoerd; tests dekken resolutiefouten, procesidentiteit, focusvolgorde, predicates, eventtransport, budgetten en wrappers afzonderlijk.
- `act` weigert twee gevonden selectormatches; de bestaande begrensde AX-zoekactie geeft geen volledigheidssignaal. Eén match in een door tijd/diepte afgebroken zoekactie bewijst geen globale uniciteit.

De reviewbevindingen over verdwijn-verificatie, owner guards, disabled clicks, deadlines, het aparte after-snapshot, toetsreeksbudgetten en voorbereiding van muiseventparen zijn gecorrigeerd. De laatste gerichte review keurde de muisvoorbereiding goed; de reviewer heeft de tests niet zelfstandig uitgevoerd.

`git diff --check`: exit_code=0.
