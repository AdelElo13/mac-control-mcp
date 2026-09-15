# S2 — reviewer-hermeting na correctieronde

Voer dit alleen uit vanuit Claude met bestaande desktoprechten. Codex heeft geen
AX-/Screen Recording-toegang. Alle app-aanroepen hieronder zijn read-only: niet
klikken, typen, scrollen, vensters verplaatsen, instellingen of clipboard wijzigen.
Laat dezelfde Finder-/System Settings-inhoud staan tussen baseline en branch.
De baseline is de huidige `integration/v0.10` inclusief actions; geen checkout,
rebase of wijziging van de bestaande commits.

De vorige reviewer bevestigde B1/B2/B3/A4/B6/B7. Deze ronde verifieert de vier
resterende punten. De oude tijdtargets uit de eerste versie van dit document
worden voor viewport vervangen door **≤260 ms**, zoals gevraagd in de review.

## 1. Builds, PID's en trust

Alle blokken gebruiken dezelfde shell en worktree:

```sh
cd /private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-walk
export S2_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
export S2_OUT="$PWD/.build/s2-review-r2"
export S2_NEW="$PWD/.build/debug/mac-control-mcp"
export S2_OLD="$PWD/.build/s2-review-r2-baseline/debug/mac-control-mcp"
mkdir -p "$S2_OUT" .build/s2-review-r2-src
swift build > "$S2_OUT/build-after.log" 2>&1
git rev-parse HEAD integration/v0.10 > "$S2_OUT/revisions.txt"
git diff --binary HEAD > "$S2_OUT/uncommitted.patch"
git archive integration/v0.10 | tar -x -C .build/s2-review-r2-src
swift build --package-path .build/s2-review-r2-src --scratch-path .build/s2-review-r2-baseline > "$S2_OUT/build-before.log" 2>&1
shasum -a 256 "$S2_OLD" "$S2_NEW" > "$S2_OUT/binary-hashes.txt"
export S2_FINDER_PID="$(pgrep -x Finder)"
export S2_SETTINGS_PID="$(pgrep -x 'System Settings')"
python3 - <<'PY'
import json, os
from pathlib import Path
pids = {k: int(os.environ['S2_' + k.upper() + '_PID']) for k in ('finder', 'settings')}
assert all(v > 0 for v in pids.values()) and len(set(pids.values())) == 2, pids
Path(os.environ['S2_OUT'], 'pids.json').write_text(json.dumps(pids, indent=2) + '\n')
print(pids)
PY
PROBE_MAX=300000 python3 "$S2_SCRATCH/probe.py" "$S2_NEW" '[["permissions_status",{}],["list_apps",{}]]' > "$S2_OUT/preflight.log"
cat "$S2_OUT/preflight.log"
```

**Verwacht:** beide builds slagen, beide apps bestaan, AX/Screen Recording zijn
`granted`. Stop bij ontbrekende rechten, mislukte build of verkeerde PID; verleen
geen rechten of wijzig apps als onderdeel van deze procedure.

## 2. Exacte NDJSON-probes voor de vier reviewpunten

```sh
python3 - <<'PY'
import json, os
from pathlib import Path
f, s = int(os.environ['S2_FINDER_PID']), int(os.environ['S2_SETTINGS_PID'])
probes = [
    ['get_ui_tree', {'pid': f}],
    ['get_ui_tree', {'pid': f, 'viewport_only': True}],
    ['get_ui_tree', {'pid': f, 'node_cap': 2000, 'time_budget_ms': 5000}],
    ['get_ui_tree', {'pid': f, 'viewport_only': True}],
    ['find_element', {'pid': s, 'title': 'Search'}],
    ['find_element', {'pid': s, 'title': 'Search', 'max_depth': 6}],
    ['ground', {'pid': s, 'target': 'Search', 'strategy': 'ax'}],
    ['query_elements', {'pid': f, 'title_regex': '^Eject$'}],
    ['query_elements', {'pid': f, 'title_regex': '^Eject$', 'limit': 1}],
    ['list_elements', {'pid': f}],
    ['list_elements', {'pid': f, 'include_offscreen': True}],
    ['query_elements', {'pid': f, 'title_regex': '^Eject$', 'node_cap': 2000, 'time_budget_ms': 5000}],
    ['list_elements', {'pid': f, 'node_cap': 2000, 'time_budget_ms': 5000}],
]
Path(os.environ['S2_OUT'], 'probes.json').write_text(json.dumps(probes) + '\n')
PY
PROBE_MAX=300000 python3 "$S2_SCRATCH/probe.py" "$S2_OLD" "$(cat "$S2_OUT/probes.json")" > "$S2_OUT/raw-before.log"
PROBE_MAX=300000 python3 "$S2_SCRATCH/probe.py" "$S2_NEW" "$(cat "$S2_OUT/probes.json")" > "$S2_OUT/raw-after.log"
```

**Verwachte branch-output:**

1. Tree default: `node_cap:1000`, `time_budget_ms:350`, echte AXWindow en
   `nodes_visited ≤1000`. Een cutoff meldt `truncated:true` en
   `node_cap_reached:true` of `timed_out:true`. De expliciete 2000/5000-call
   controleert dezelfde grotere zoekruimte; die mag langer duren.
2. Viewport: tijdens de walk prunen, `time_budget_ms:200`; dezelfde resultaten
   en node-aantallen bij gelijke UI ongeacht de voorafgaande call, tenzij een
   expliciet gemelde tijdgrens de walk afbreekt. Een snellere maar veel kortere
   afgebroken tweede walk bewijst geen verholpen volgordeafhankelijkheid.
3. Search: succesvolle `element_id`, `nodes_visited` en `timings_ms`; default
   en ground zoeken BFS zonder tweede pass. Diepte-6 blijft een referentie.
4. Query/list: default `node_cap:500`, `time_budget_ms:250`, eerlijke cutoff.
   `limit:1` bij de exacte Eject-query stopt op de eerste passende node; bij
   geen Eject is dat geen early-exit-bewijs. List meldt
   `offscreen_excluded:true`; de opt-in meldt false. Voor de baseline worden
   nieuwe argumenten mogelijk genegeerd: bewaar daarom de gerapporteerde caps.

`timings_ms.walk` omvat `ax_fetch`; tel die dus niet bij elkaar op. `queue`
is wachttijd vóór uitvoering, `prepare` is eenmalige appvoorbereiding. `windows`
omvat het ophalen van verse windowframes plus zijn eigen queue/preparatie.
Tree splitst verder `shape`, `cache`, `payload`, `byte_accounting`; query combineert
payload/cache. Byte-accounting meet de volledige teller, exclusief de kleine
scalar-correctie voor het timingveld zelf. MCP-transport/definitieve JSON-encoding
staan niet in de payloadfasen: die zitten wel in de gemeten client-walltime.

De raw probe kapt zeer grote antwoorden af op 300000 tekens. Stap 3 bewaart de
volledige structured payloads zonder afkapping en is het meetbewijs. Er zijn geen
captures of base64 in deze vier reviewpunten.

## 3. Zelfde probe, zeven warme runs; geïsoleerd én direct na de grote walk

Dit gebruikt de bestaande gevalideerde NDJSON-transportklasse uit
`TestHarness/s2_concurrency.py`. Elke sequence heeft één server/controller voor
één warmup en zeven meetrondes. De baseline en branch krijgen exact dezelfde
requests. Bij de twee order-sequences volgt viewport **direct** op de grote
walk binnen dezelfde server, zonder slaap of herstart ertussen.

```sh
python3 - <<'PY' > "$S2_OUT/measurements.log" 2>&1
import json, os, statistics, sys, time
from pathlib import Path
sys.path.insert(0, str(Path.cwd() / 'TestHarness'))
from s2_concurrency import Server, has_window
out = Path(os.environ['S2_OUT'])
f, s = int(os.environ['S2_FINDER_PID']), int(os.environ['S2_SETTINGS_PID'])
viewport = ('viewport', 'get_ui_tree', {'pid': f, 'viewport_only': True})
default = ('default', 'get_ui_tree', {'pid': f})
expanded = ('expanded', 'get_ui_tree', {'pid': f, 'node_cap': 2000, 'time_budget_ms': 5000})
sequences = {
    'isolated': [viewport],
    'after-default': [default, viewport],
    'after-expanded': [expanded, viewport],
    'reverse': [viewport, default],
    'find': [('find', 'find_element', {'pid': s, 'title': 'Search'})],
    'find-depth6': [('find6', 'find_element', {'pid': s, 'title': 'Search', 'max_depth': 6})],
    'ground': [('ground', 'ground', {'pid': s, 'target': 'Search', 'strategy': 'ax'})],
    'query': [('query', 'query_elements', {'pid': f, 'title_regex': '^Eject$'})],
    'query-limit1': [('query1', 'query_elements', {'pid': f, 'title_regex': '^Eject$', 'limit': 1})],
    'list': [('list', 'list_elements', {'pid': f})],
    'list-offscreen': [('list-offscreen', 'list_elements', {'pid': f, 'include_offscreen': True})],
    'query-expanded': [('query-expanded', 'query_elements', {'pid': f, 'title_regex': '^Eject$', 'node_cap': 2000, 'time_budget_ms': 5000})],
    'list-expanded': [('list-expanded', 'list_elements', {'pid': f, 'node_cap': 2000, 'time_budget_ms': 5000})],
}
all_results = {}
for phase, binary in [('before', os.environ['S2_OLD']), ('after', os.environ['S2_NEW'])]:
    rows = {}
    for sequence_name, sequence in sequences.items():
        server = Server(binary)
        try:
            server.receive(server.send('initialize', {}))
            for iteration in range(8):
                for label, tool, args in sequence:
                    start = time.perf_counter()
                    response = server.receive(server.send('tools/call', {'name': tool, 'arguments': args}))
                    ms = (time.perf_counter() - start) * 1000
                    result = response.get('result', {})
                    payload = result.get('structuredContent', {})
                    assert 'error' not in response and not result.get('isError') and payload.get('ok') is True, (phase, sequence_name, response)
                    if tool == 'get_ui_tree': assert has_window(response), (phase, sequence_name, payload)
                    if tool in ('find_element', 'ground'): assert payload.get('element_id'), (phase, sequence_name, payload)
                    if iteration:
                        key = sequence_name + '/' + label
                        rows.setdefault(key, []).append({'ms': ms, 'args': args, 'tool': tool, 'payload': payload})
        finally:
            server.close()
    (out / (phase + '-samples.json')).write_text(json.dumps(rows, ensure_ascii=False) + '\n')
    all_results[phase] = rows
before, after = all_results['before'], all_results['after']
def p50(rows): return statistics.median(row['ms'] for row in rows)
failures = []
for key in before:
    a, b = before[key], after[key]
    assert len(a) == len(b) == 7
    print(f"{key}: p50 {p50(a):.1f} -> {p50(b):.1f} ms; after range {min(r['ms'] for r in b):.1f}..{max(r['ms'] for r in b):.1f}")
    print('  visited:', [r['payload'].get('nodes_visited') for r in b],
          'count:', [r['payload'].get('count') for r in b],
          'truncated:', [r['payload'].get('truncated') for r in b])
    phase_keys = set().union(*(r['payload'].get('timings_ms', {}) for r in b))
    print('  phase p50 ms:', {k: round(statistics.median(r['payload'].get('timings_ms', {}).get(k, 0) for r in b), 3) for k in sorted(phase_keys)})
    if key.endswith('/default') and p50(b) > p50(a): failures.append((key, 'default slower than baseline'))
    if key.endswith('/viewport') and max(r['ms'] for r in b) > 260: failures.append((key, 'viewport exceeds 260 ms'))
    if key == 'find/find' and p50(b) > 40: failures.append((key, 'Search exceeds 40 ms'))
    if key in ('query/query', 'list/list') and p50(b) > 300:
        print('  TARGET NOT MET: inspect nodes/phase costs; bounded fallback must be <=500 ms with truncation')
        if max(r['ms'] for r in b) > 500 or not all(r['payload'].get('truncated') for r in b):
            failures.append((key, 'fallback exceeds 500 ms or hides truncation'))
isolated = p50(after['isolated/viewport'])
for key in ('after-default/viewport', 'after-expanded/viewport'):
    ratio = p50(after[key]) / isolated
    print(key, 'ratio to isolated:', round(ratio, 3))
    if ratio > 1.2: failures.append((key, 'order dependence >20%'))
(out / 'acceptance.json').write_text(json.dumps({'failures': failures}, indent=2) + '\n')
assert not failures, failures
PY
cat "$S2_OUT/measurements.log"
```

**Acceptatie:** default ≤ dezelfde baseline; viewport iedere gemeten call ≤260 ms
en p50 na grote walk ≤1,2× geïsoleerd; Search p50 ≤40 ms; query/list p50 ≤300 ms.
Als de on-screen subtree zelf te duur is, rapporteer de gemeten `nodes_visited`,
`ax_fetch`, `truncated` en p50; de begrensde fallback mag maximaal 500 ms kosten.
Vergelijk ook de node-aantallen/IDs: tijdwinst door een kleinere expliciet gemelde
zoekruimte wordt apart gerapporteerd en bewijst geen snellere volledige walk.
De expanded-cases isoleren dat verschil. Een ontbrekende AXWindow, foutantwoord,
veranderde UI of ontbrekende Search-match is geen geldige snelle meting.

## 4. Gerichte tests en terugrapportage

```sh
for suite in AXWalkPerformanceTests AXPayloadBudgetTests Phase9ToolsTests WindowScopedTreeTests CaptureAnnotatedToolTests GroundingWindowScopeTests ToolDocsDriftTests; do
  script -q /dev/null swift test --no-parallel --filter "$suite" > "$S2_OUT/$suite.log" 2>&1 || break
done
```

Bekende geërfde afwijking: ToolDocsDriftTests faalt op README/server.json
(151 versus 153 tools), ook op ongewijzigde HEAD 917e7a6. De gegenereerde
docs/TOOLS.md-check slaagt. Deze releasebestanden vallen buiten S2.

Geen volledige suite. Bewaar en stuur terug: `revisions.txt`, `uncommitted.patch`,
`binary-hashes.txt`, `pids.json`, beide raw logs, beide volledige samples-JSON's,
`measurements.log`, `acceptance.json` en eventuele falende suite-output.
Bij een orde-afhankelijk verschil zijn vooral de `queue`, `windows`, `ax_fetch`,
`cache` en `byte_accounting` fasen plus node-aantallen van dezelfde sequence nodig.
Geen van deze live-resultaten is door Codex gemeten of als geslaagd geclaimd.
