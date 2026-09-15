# A8 — Chrome web-content identity: final report

## Scope en resultaat

Vervolg op reviewercommit `a116065`; de reeds beoordeelde A1/A2/A6-implementatie is
in deze ronde niet aangepast. A8 heeft nu een fakebare boomadapter, siblingmatching
via CFEqual of unieke fingerprint/frame, en herstel vanaf de applicatieroot bij
overgeslagen/extra parentniveaus. Het herstel bewaart de gewone DFS-ordinals, ook
voor gedeelde handles. `element_at_point` rapporteert de gebruikte strategie en
matchstappen of een specifieke foutreden.

De fake regressies zijn GREEN. De Chrome-desktopuitkomst is **nog niet geverifieerd**.
`LIVE-CHECKS.md` §8 bevat de exacte stock-probes voor vier punten op drie webtargets,
herhaalde hits, vergelijking met `find_elements`, en dezelfde calls vóór/na.

Geometrie wordt gebruikt om aliasmatches te bevestigen, niet om subtrees uit te
sluiten. De RED overflow-test toont waarom de aanvankelijk gevraagde containment-
pruning onveilig is: een tweede identieke link kan buiten het parent-frame liggen.
De zoekactie blijft begrensd op 32 niveaus en 2.000 unieke node-reads over beide
strategieën samen. Gecapte, onleesbare of ambigue aliaszoekacties worden geweigerd.
Een onleesbare eerdere tak voorkomt ook een onbewezen canonieke exact-match-ID.

## Commits

- Bestaande HEAD: `a116065 feat(v0.10-ids): Codex (gpt-6-astra) implementation round, committed by reviewer (sandbox cannot write index.lock)`.
- **Geen nieuwe commit gemaakt.** Staging eindigde met exit 128; conform de laatste
  gebruikersinstructie blijven alle nieuwe wijzigingen uncommitted.
- Geen amend, revert, rebase, merge, push of branchwissel uitgevoerd.

Uit [a8-commit-attempt.txt](a8-commit-attempt.txt):

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ids/index.lock': Operation not permitted
```

## Gewijzigde bestanden

| Bestand | Verandering |
|---|---|
| `Sources/MacControlMCP/AXPathReconstruction.swift` (nieuw) | Generieke fakebare adapter; parent-chain, aliasmatching, begrensde canonieke DFS, strategieën en specifieke redenen. |
| `Sources/MacControlMCP/AXPath.swift` | Native AXKey/CFEqual-adapter met AXAttributeBatch; `upwardPath` behoudt zijn bestaande optionele returntype. |
| `Sources/MacControlMCP/AccessibilityController.swift` | Geeft reconstructiediagnostiek door in `HitTest`. |
| `Sources/MacControlMCP/Tools+V0_9AXCore.swift` | Encodeert `stable_id_strategy`, `stable_id_steps`, specifieke `stable_id_reason`; beschrijving bijgewerkt. |
| `Tests/MacControlMCPTests/AXPathReconstructionTests.swift` (nieuw) | 21 nieuwe fake regressietests als uitbreiding van `AXPathTests`. |
| `docs/TOOLS.md` | Gegenereerde toolbeschrijving; geen tool toegevoegd, toolaantal ongewijzigd. |
| `LIVE-CHECKS.md` | §8: zelfstandige, alleen-lezen Chrome-webprobes en exacte vóór/na-commands. |
| `.s1-evidence/A8-REPORT.md`, `.s1-evidence/a8-*.txt` | Dit rapport en ruwe build-, RED/GREEN-, suite-, probevalidatie- en commitoutput. |

Geen wijzigingen in README, RELEASE_NOTES, server.json, npm, versievelden of dependencies.
De bestaande `.s1-evidence/reviewer/`-resultaten zijn niet overschreven.

## RED → GREEN

De eerste adapter behield bewust de bestaande equal-handle-only ouderpadlogica;
de nieuwe gedragsassertions faalden daarop. Daarna is de reconstructie geïmplementeerd.
Latere reviewbevindingen zijn telkens eerst als falende tests uitgevoerd en daarna
gecorrigeerd. Alle runs gebruikten de vereiste PTY-wrapper:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" script -q /dev/null swift test --disable-sandbox --no-parallel --filter AXPathTests
```

`--disable-sandbox` schakelt alleen de SwiftPM-buildsandbox uit; het geeft geen
Codex-desktoptoegang of extra filesystemrechten.

### Parent-alias / skipped-level / virtual-parent / cap

RED: [a8-web-red.txt](a8-web-red.txt)

```text
✘ Test "A8 a relayed hit handle matches a unique sibling by fingerprint and frame" recorded an issue at AXPathReconstructionTests.swift:48:9: Expectation failed: (result.path → nil) == (fake.canonicalPath → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)])
✘ Test run with 21 tests in 1 suite failed after 0.010 seconds with 14 issues.
```

GREEN: [a8-web-green.txt](a8-web-green.txt)

```text
✔ Test run with 21 tests in 1 suite passed after 0.009 seconds.
```

### Overflowambiguïteit en frameloze exacte handle

RED: [a8-web-edge-red.txt](a8-web-edge-red.txt)

```text
✘ Test "A8 overflowing descendants cannot hide a second matching alias" recorded an issue at AXPathReconstructionTests.swift:127:9: Expectation failed: (result.path → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)]) == nil
✘ Test run with 23 tests in 1 suite failed after 0.009 seconds with 5 issues.
```

GREEN: [a8-web-edge-green.txt](a8-web-edge-green.txt)

```text
✔ Test run with 30 tests in 1 suite passed after 0.009 seconds.
```

### Onleesbare sibling en onbewezen aliasuniciteit

RED: [a8-web-unreadable-red.txt](a8-web-unreadable-red.txt)

```text
✘ Test "A8 an unreadable sibling cannot prove a hit alias unique" recorded an issue at AXPathReconstructionTests.swift:246:9: Expectation failed: (result.path → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)]) == nil
✘ Test run with 31 tests in 1 suite failed after 0.009 seconds with 2 issues.
```

GREEN: [a8-web-unreadable-green.txt](a8-web-unreadable-green.txt)

```text
✔ Test run with 31 tests in 1 suite passed after 0.009 seconds.
```

### Bekende app-root zonder rol

RED: [a8-web-root-red.txt](a8-web-root-red.txt)

```text
✘ Test "A8 the known application root need not publish a role" recorded an issue at AXPathReconstructionTests.swift:256:9: Expectation failed: (result.path → nil) == (fake.canonicalPath → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)])
✘ Test run with 32 tests in 1 suite failed after 0.010 seconds with 2 issues.
```

GREEN: [a8-web-root-green.txt](a8-web-root-green.txt)

```text
✔ Test run with 32 tests in 1 suite passed after 0.009 seconds.
```

### Gedeelde handle: eerste DFS-pad

RED: [a8-web-shared-red.txt](a8-web-shared-red.txt)

```text
✘ Test "A8 shared handles use the tree walk's first DFS path" recorded an issue at AXPathReconstructionTests.swift:267:9: Expectation failed: (result.path → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 1, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)]) == (expected → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)])
✘ Test run with 33 tests in 1 suite failed after 0.011 seconds with 3 issues.
```

GREEN: [a8-web-shared-green.txt](a8-web-shared-green.txt)

```text
✔ Test run with 33 tests in 1 suite passed after 0.010 seconds.
```

### Onleesbare eerdere DFS-tak

RED: [a8-web-prefix-red.txt](a8-web-prefix-red.txt)

```text
✘ Test "A8 an unreadable earlier branch prevents a canonical exact-match claim" recorded an issue at AXPathReconstructionTests.swift:279:9: Expectation failed: (result.path → [MacControlMCP.AXPathComponent(role: "AXWindow", index: 1, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXWebArea", index: 0, identifier: nil, title: nil, subrole: nil), MacControlMCP.AXPathComponent(role: "AXLink", index: 0, identifier: nil, title: Optional("Hacker News"), subrole: nil)]) == nil
✘ Test run with 34 tests in 1 suite failed after 0.010 seconds with 2 issues.
```

GREEN: [a8-web-prefix-green.txt](a8-web-prefix-green.txt)

```text
✔ Test run with 34 tests in 1 suite passed after 0.010 seconds.
```

## Definitieve gefilterde suites

Alle onderstaande suites zijn na de laatste bronwijziging afzonderlijk met de
PTY-wrapper en `--no-parallel --filter <Suite>` uitgevoerd. Geen volledige suite.
De docs-run gebruikte bovendien `UPDATE_TOOL_DOCS=1`.

[ElementCacheTests](a8-final-ElementCacheTests.txt) — exit 0

```text
✔ Suite "ElementCache" passed after 0.363 seconds.
✔ Test run with 25 tests in 1 suite passed after 0.363 seconds.
```

[AXPathTests](a8-final-AXPathTests.txt) — exit 0

```text
✔ Suite "AX path identity (C-5)" passed after 0.011 seconds.
✔ Test run with 34 tests in 1 suite passed after 0.011 seconds.
```

[CodexR2RegressionTests](a8-final-CodexR2RegressionTests.txt) — exit 0

```text
✔ Suite "Codex r2 regressions" passed after 0.013 seconds.
✔ Test run with 13 tests in 1 suite passed after 0.014 seconds.
```

[AnnotatedElementIdentityTests](a8-final-AnnotatedElementIdentityTests.txt) — exit 0

```text
✔ Suite "capture_annotated element identity (C-5)" passed after 0.005 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.005 seconds.
```

[Phase9ToolsTests](a8-final-Phase9ToolsTests.txt) — exit 0

```text
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.031 seconds.
✔ Test run with 14 tests in 1 suite passed after 0.031 seconds.
```

[TextEditingTests](a8-final-TextEditingTests.txt) — exit 0

```text
✔ Suite "Text editing primitives (C-7)" passed after 0.015 seconds.
✔ Test run with 30 tests in 1 suite passed after 0.015 seconds.
```

[ToolDocsDriftTests](a8-final-ToolDocsDriftTests.txt) — exit 0

```text
✔ Suite "Tool docs drift" passed after 0.035 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.035 seconds.
```

Totaal: **125 tests volgens de suite-output**. Dat is geen bewijs van 125 live
assertions: de suites bevatten guards die zonder desktoprechten vroeg terugkeren.
`AXPathTests.stableIDsAcrossCalls` vereist AX-trust en Finder. De annotatiesuite
printte expliciet de volgende skips:

```text
[annotated-identity] skipped: no Accessibility trust
[annotated-identity] skipped: no Accessibility trust
[annotated-identity] skipped: no Accessibility trust
[annotated-identity] skipped: no AX trust / no Finder
[annotated-identity] skipped: no Accessibility trust
```

## Build en review

De eerste handeling was `swift build`; die slaagde. Definitieve build: [a8-build-final.txt](a8-build-final.txt), exit 0. Volledige output:

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
Build complete! (0.17s)
```

`git diff --check` slaagde zonder output. De onafhankelijke code-review eindigde
met **APPROVE**, zonder resterende actionable bevindingen; de reviewer voerde hier
geen desktopcommando's uit.

## Live probes en metingen

**Niet uitgevoerd in deze sandbox**, conform de expliciete gebruikersinstructie.
Er zijn geen nieuwe live-outputclaims en geen prestatieverbeteringsclaims.
De oorspronkelijke review meldde `stable_id:false` bij vier webpunten; dat is de
reproductieaanleiding, niet een door Codex opnieuw gemeten resultaat.

`LIVE-CHECKS.md` §8 bevat:

1. Discovery van Chrome-pid en window_id.
2. `get_ui_tree` met geprojecteerde fields om webdescendants via AXWebArea aan te tonen.
3. `find_elements` voor Hacker News/new-links en een afbeelding in de pagina.
4. Vier punten × twee `element_at_point`-calls; verwacht dezelfde id als `find_elements`,
   `stable_id:true`, geldige strategie/stappen, geen foutreden.
5. Concrete JSON-calllijsten én complete `PROBE_MAX=300000 python3 SCRATCH/probe.py ...`
   shellcommands in de revieweroutput, plus herhaalcommand.
6. Exact dezelfde calllijst voor de vorige reviewercommit `a116065` en de nieuwe
   debugbinary; ruwe timings blijven in de stock-output. Geen p50-claim op losse timings.

Geen clicks, navigatie, scrolls, typen, vensterverplaatsingen, instellingen of
clipboardwrites zijn onderdeel van deze A8-probe. Bij ontbrekende/gewijzigde targets
wordt de check INCONCLUSIVE; bij een matching webtarget met random/ander id FAIL.

De helper is lokaal uitsluitend met synthetische stock-probe-antwoorden gecontroleerd:
[a8-probe-validation.txt](a8-probe-validation.txt).

```text
Reviewer helper Python syntax: PASS
Synthetic matching web-link/image responses accepted: PASS
Synthetic unstable-hit responses rejected: PASS
No desktop, probe process, or real application accessed by this validation.
```

Nog te verifiëren door de desktopreviewer: de acht werkelijke Chrome-hits, id-pariteit
met de echte Chrome-tree, en de werkelijk gemeten vóór/na-latenties. Een fallback
zoals `top_down_node_cap` is diagnostisch verklaard, maar telt niet als geslaagde
live A8-regressie. Het extra werk voor canonieke DFS is hier niet live getimed.

## Commitoverdracht aan reviewer

Voer uit vanuit deze worktree; stage geen bestaande live-output automatisch mee.
De eerste commit bevat de fix, tests en gegenereerde toolbeschrijving; de tweede
bevat de exacte live-checks en het bewijs.

```sh
git add -- Sources/MacControlMCP/AXPath.swift Sources/MacControlMCP/AXPathReconstruction.swift Sources/MacControlMCP/AccessibilityController.swift Sources/MacControlMCP/Tools+V0_9AXCore.swift Tests/MacControlMCPTests/AXPathReconstructionTests.swift docs/TOOLS.md
git commit -m "fix: recover canonical Chrome web element paths" -m "Chromium hit-test handles can skip or alias parent levels. Verify sibling identity and recover bounded canonical DFS paths so web hits share tree-walk ids, with explicit diagnostics when identity cannot be proved."
git add -- LIVE-CHECKS.md .s1-evidence/A8-REPORT.md .s1-evidence/a8-*.txt
git commit -m "test: document Chrome web identity regression evidence" -m "Preserve the RED-to-GREEN fake-tree regressions and filtered-suite output, and hand exact read-only web-content probes to the desktop reviewer because Codex has no desktop access."
```
