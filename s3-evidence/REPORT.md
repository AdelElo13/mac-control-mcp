# S3 — laatste hardening na reviewronde 3

## Resultaat en commits

Directe AX-hits met een bruikbaar frame buiten het punt (1 pt tolerantie) starten nu de geometrische zoekactie. Zonder vervanger wordt de kwaliteit `direct_out_of_frame`. Een enclosing sheet/popover/dialog blijft de grens van de herstelzoekactie.

Bestaande commits blijven intact: `0b2bd9e`, `187034e`, `8866f1b`, `f1d7da1`. De reviewer heeft `f1d7da1` live geaccepteerd; deze laatste hardening staat **ongecommit** in dezelfde worktree en branch. Staging blokkeert vóór commit ([uitvoer](round3-commit-attempt.txt)):

```text
fatal: Unable to create '/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ground/index.lock': Operation not permitted
exit_code: 128
```

Beoogde commit: `fix: reject out-of-frame direct AX hits`, met body: `A fresh AX connection can return an unrelated interactive control. Recover within the nearest overlay or window and label unresolved hits honestly; exercise cold-start probes and frame tolerance.`

## Bestanden

- `Sources/MacControlMCP/GeometricHitTest.swift`: framecontrole, herstelroot en eerlijke fallbackkwaliteit.
- `Sources/MacControlMCP/AccessibilityController.swift`: dichtstbijzijnde sheet/popover/dialog/window als herstelgrens.
- `Tests/MacControlMCPTests/GeometricHitTestTests.swift`: vier nieuwe tests voor afwijkende interactieve hit, geen vervanger, tolerantie/ontbrekende geometrie en overlaygrenzen.
- `Sources/MacControlMCP/Tools+V0_9AXCore.swift` en `docs/TOOLS.md`: nieuwe kwaliteitswaarde in toolbeschrijving.
- `LIVE-CHECKS.md`: eerste Name-hit meteen herhaald, daarna Size/Kind achtmaal elk.
- Dit rapport, archief `round2-report.md` en `round3-*` bewijsbestanden.

Geen toolcountwijziging of dependencies. Geen diff in README, releasenotes, server.json, npm/ of versies.

## RED → GREEN

Eerst de drie vereiste regressietests, vóór implementatie — [RED](round3-red.txt):

```text
interactiveOutOfFrameHitSearchesWindowForContainingHeader:
  (hit.element → 1) == 2
  (hit.quality → "direct") == "geometric"
outOfFrameHitWithoutReplacementIsLabelledHonestly:
  (hit.quality → "direct") == "direct_out_of_frame"
directHitFrameToleranceIsOnePointAndRequiresUsableGeometry:
  (beyond.quality → "direct") == "direct_out_of_frame"
✘ Test run with 16 tests in 1 suite failed after 0.001 seconds with 4 issues.
```

Na implementatie — [GREEN](round3-green.txt):

```text
✔ Test run with 36 tests in 3 suites passed after 0.032 seconds.
```

De aanvullende reviewfixture vond een achtergrondknop achter elke overlaysoort — [overlay RED](round3-overlay-red.txt):

```text
outOfFrameRecoveryStaysInsideOverlay: (result.element → 1) == 4
✘ Test run with 17 tests in 1 suite failed after 0.002 seconds with 3 issues.
```

Na begrenzing tot de dichtstbijzijnde overlay, definitieve [GREEN-suite-uitvoer](round3-suites.txt):

```text
✔ Suite "element_at_point (C-4)" passed after 0.008 seconds.
✔ Suite "Geometric hit test" passed after 0.001 seconds.
✔ Suite "Phase 9 tools — reliability + observability substrate" passed after 0.021 seconds.
✔ Suite "Tool docs drift" passed after 0.017 seconds.
✔ Test run with 41 tests in 4 suites passed after 0.049 seconds.
```

Exacte finale selectie:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache script -q /dev/null swift test --disable-sandbox --no-parallel --filter 'GeometricHitTestTests|ElementAtPointTests|Phase9ToolsTests|ToolDocsDriftTests'
```

De toolbeschrijving is vooraf geregenereerd met `UPDATE_TOOL_DOCS=1` en dezelfde PTY-wrapper: [4 tests groen](round3-docs.txt). De normale driftcontrole hierboven bevestigt de gegenereerde inhoud. Geen volledige suite gestart.

Build vóór tests: [round3-build-before.txt](round3-build-before.txt). Finale build met `CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache swift build --disable-sandbox`: [round3-build-final.txt](round3-build-final.txt), `Build complete! (0.16s)`. De tijdelijke modulecache is nodig wegens beperkte schrijfrechten op de standaardcache. [Codereview](round3-code-review.txt): APPROVE, geen resterende concrete issues; `git diff --check` slaagt.

## Live-uitvoer en verificatiegrens

De exacte probe staat in [LIVE-CHECKS.md](../LIVE-CHECKS.md), met identieke [18 calls](round3-header-calls.json). De eerste twee calls in hetzelfde nieuwe serverproces zijn Name `(809.5,105)`, zonder AX-warmup. Daarna Size `(1444.5,105)` en Kind `(1550.5,105)`, acht keer elk, Finder pid 742.

Uitgevoerd met de finale `.build/debug/mac-control-mcp`, `PROBE_MAX=300000` en de voorgeschreven `SCRATCH/probe.py`: [ruwe uitvoer](round3-header-live.txt), [compacte uitvoer](round3-header-summary.json). Alle **18/18** calls geven:

```json
{"ok":false,"error_code":"permission_missing","pane":"accessibility"}
```

Ook de koude eerste en direct herhaalde Name-call geven deze fout. Geen base64 aanwezig. Daarom is het zeldzame cold-start-herstel **niet lokaal live geverifieerd**; foutresponstijden tellen niet als performance. Geen desktopinteracties of instellingen gewijzigd.

## Reeds live geaccepteerd door reviewer

Bron: [reviewerbericht](round3-reviewer-input.txt), over commit `f1d7da1`, vóór deze laatste hardening. Dit zijn aangeleverde reviewerresultaten, geen nieuwe lokale metingen:

| Controle | Reviewerresultaat |
|---|---|
| Size/Kind | 8/8 elk, 17–41 ms |
| Finder sweep | 71/71 = 100%, totaal 489 ms |
| System Settings | 17/17 |
| Finder ground OCR | p50 175 ms |
| Auto met AX-hit | = AX-tijd |

De eerdere RED/GREEN-uitvoer, regressiemetingen en A5/B5/A7-acceptatie blijven beschikbaar in [het vorige rapport](round2-report.md) en de bestaande evidencebestanden. De daar genoemde openstaande acceptatie van `f1d7da1` is vervangen door bovenstaande revieweracceptatie. Voor deze hardening wordt geen nieuwe voor/na-performanceclaim gedaan: desktoptoegang ontbreekt in deze uitvoercontext.

## Niet verifieerbaar vanuit deze omgeving

- Live cold-start-correctheid en latency van de huidige hardening: `permission_missing`.
- Nieuwe commit: schrijven van de externe Git-worktreeadministratie geweigerd bij `index.lock`.
