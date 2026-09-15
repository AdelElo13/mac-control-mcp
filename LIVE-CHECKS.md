# S2 — live verificatie door reviewer Claude

Codex heeft geen desktoptoegang en vraagt die niet opnieuw aan. Voer deze
commando's uit vanuit de bestaande vertrouwde Claude-desktopomgeving. Alle
handelingen hieronder lezen alleen. Niet klikken, typen, scrollen, vensters
verplaatsen, instellingen wijzigen of het klembord schrijven. Open/sluit geen
gebruikersvensters. Verander Finder/Safari/System Settings niet tussen de
baseline- en nieuwe metingen.

Een fout, ontbrekende AXWindow, lege annotatielijst of gewijzigde window_id is
**geen geslaagde check**. Bewaar de output en stuur die terug. Een veranderde UI
maakt een identiteitsdiff inconclusief; herhaal dan op een stabiele desktop.

## 1. Build en verse PID's

Voer de blokken in volgorde uit, in dezelfde shell:

```sh
cd /private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad/wt10-walk
export S2_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
export S2_OUT="$PWD/.build/s2-review"
export S2_NEW="$PWD/.build/debug/mac-control-mcp"
mkdir -p "$S2_OUT"
swift build > "$S2_OUT/build-new.log" 2>&1

# Bouw de ongewijzigde baseline binnen deze worktree; geen checkout/rebase.
mkdir -p .build/s2-review-baseline-src
git archive integration/v0.10 | tar -x -C .build/s2-review-baseline-src
swift build --package-path .build/s2-review-baseline-src --scratch-path .build/s2-review-baseline-build > "$S2_OUT/build-before.log" 2>&1
export S2_OLD="$PWD/.build/s2-review-baseline-build/debug/mac-control-mcp"
shasum -a 256 "$S2_OLD" "$S2_NEW" > "$S2_OUT/binary-hashes.txt"
git rev-parse HEAD integration/v0.10 > "$S2_OUT/revisions.txt"

# Alleen procesnamen lezen; geen historische audit-PID's hergebruiken.
export S2_FINDER_PID="$(pgrep -x Finder)"
export S2_SAFARI_PID="$(pgrep -x Safari)"
export S2_CHROME_PID="$(pgrep -x 'Google Chrome')"
export S2_SETTINGS_PID="$(pgrep -x 'System Settings')"
python3 - <<'PY'
import json, os
from pathlib import Path
pids = {name: int(os.environ['S2_' + name.upper() + '_PID'])
        for name in ('finder', 'safari', 'chrome', 'settings')}
assert len(set(pids.values())) == 4 and min(pids.values()) > 0, pids
Path(os.environ['S2_OUT'], 'pids.json').write_text(json.dumps(pids, indent=2) + '\n')
print(pids)
PY
PROBE_MAX=300000 python3 "$S2_SCRATCH/probe.py" "$S2_NEW" '[["permissions_status",{}],["list_apps",{}]]' > "$S2_OUT/preflight.log"
cat "$S2_OUT/preflight.log"
```

**Verwacht:** beide builds slagen; vier verschillende PID's; accessibility en
screen_recording zijn granted; list_apps bevat de vier doelapps. Stop bij een
build-/permissionfout. Verleen geen rechten of wijzig geen apps als onderdeel van
deze checks. De baseline is `integration/v0.10`, niet de bewaarde WIP-commit.

## 2. Identieke cases voor beide binaries voorbereiden

```sh
python3 - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ['S2_OUT'])
p = json.loads((out / 'pids.json').read_text())
f, s, c, settings = (p[k] for k in ('finder', 'safari', 'chrome', 'settings'))
cases = [
    ['tree/Finder', 'get_ui_tree', {'pid': f}],
    ['tree-depth6/Finder', 'get_ui_tree', {'pid': f, 'max_depth': 6}],
    ['tree-viewport/Finder', 'get_ui_tree', {'pid': f, 'viewport_only': True}],
    ['capture/Finder', 'capture_annotated', {'pid': f}],
    ['capture/Safari', 'capture_annotated', {'pid': s}],
    ['query-Eject/Finder', 'query_elements', {'pid': f, 'title_regex': '^Eject$'}],
    ['list/Finder', 'list_elements', {'pid': f}],
    ['find-buttons/Finder', 'find_elements', {'pid': f, 'role': 'AXButton', 'limit': 20}],
    ['find-Search/Settings', 'find_element', {'pid': settings, 'title': 'Search'}],
    ['find-Search-depth6/Settings', 'find_element', {'pid': settings, 'title': 'Search', 'max_depth': 6}],
    ['ground-Search/Settings', 'ground', {'pid': settings, 'target': 'Search', 'strategy': 'ax'}],
    ['rows-viewport-limit5/Settings', 'find_elements', {'pid': settings, 'role': 'AXRow', 'viewport_only': True, 'limit': 5}],
]
(out / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
# Compact fields keep probe.py's 300000-character output limit safe. Performance
# measurements above use the normal, unchanged fields for both binaries.
probes = [
    ['get_ui_tree', {'pid': f, 'fields': ['id', 'role', 'children']}],
    ['get_ui_tree', {'pid': f, 'viewport_only': True, 'fields': ['id', 'role', 'children']}],
    ['get_ui_tree', {'pid': f, 'max_depth': 6}],
    ['capture_annotated', {'pid': f, 'inline': False}],
    ['capture_annotated', {'pid': s, 'inline': False}],
    ['find_elements', {'pid': settings, 'role': 'AXRow', 'viewport_only': True, 'limit': 500}],
    ['find_elements', {'pid': settings, 'role': 'AXRow', 'viewport_only': True, 'limit': 5}],
    ['find_elements', {'pid': settings, 'interactive_only': True, 'limit': 500}],
    ['find_elements', {'pid': settings, 'interactive_only': True, 'limit': 5}],
    ['query_elements', {'pid': f, 'title_regex': '^Eject$', 'node_cap': 10}],
    ['list_elements', {'pid': f, 'node_cap': 10}],
    ['find_element', {'pid': settings, 'title': 'Search'}],
    ['ground', {'pid': settings, 'target': 'Search', 'strategy': 'ax'}],
    ['list_menu_titles', {'pid': f}],
]
for included in (False, True):
    for tool, extra in [
        ('get_ui_tree', {}),
        ('find_elements', {'role': 'AXMenuBar', 'exact': True}),
        ('find_element', {'role': 'AXMenuBar', 'exact': True}),
        ('query_elements', {'role_regex': '^AXMenuBar$'}),
        ('list_elements', {}),
    ]:
        probes.append([tool, {'pid': f, 'max_depth': 2, 'include_menus': included, **extra}])
    probes.append(['ground', {'pid': settings, 'target': 'Search', 'strategy': 'ax', 'include_menus': included}])
(out / 'probes.json').write_text(json.dumps(probes) + '\n')
print('Prepared', len(cases), 'performance cases and', len(probes), 'read-only probes')
PY
```

## 3. B1/B2/B3/B4/A4/B6 — echte voor/na-probes

```sh
PROBE_MAX=300000 python3 "$S2_SCRATCH/probe.py" "$S2_OLD" "$(cat "$S2_OUT/probes.json")" > "$S2_OUT/probes-before.log"
PROBE_MAX=300000 python3 "$S2_SCRATCH/probe.py" "$S2_NEW" "$(cat "$S2_OUT/probes.json")" > "$S2_OUT/probes-after.log"
```

De twee menubar-zoekopdrachten zonder opt-in mogen op de nieuwe binary een
expliciete no-match geven. Dat is hieronder apart gecontroleerd. Capture gebruikt
`inline:false`: geen base64 in de logs; de screenshot-artifacts blijven beschikbaar
op de door de server gerapporteerde paden.

Onderstaand blok parseert de complete antwoorden, bewaart volledige geordende
`elements`-lijsten en schrijft letterlijke diffs. Een afgekapte probe-output geeft
een JSON-fout en mag niet als lege lijst worden geïnterpreteerd.

```sh
python3 - <<'PY'
import difflib, json, os, re
from pathlib import Path
out = Path(os.environ['S2_OUT'])
p = json.loads((out / 'pids.json').read_text())
f, settings = p['finder'], p['settings']

def read_log(name):
    text = (out / name).read_text()
    records = []
    headers = list(re.finditer(r'^--- (\w+) (.+) -> [0-9]+ ms\n', text, re.M))
    for i, header in enumerate(headers):
        end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
        payload = json.loads(text[header.end():end].strip())
        assert isinstance(payload, dict), (name, header.group(1), payload)
        records.append((header.group(1), json.loads(header.group(2)), payload))
    expected = json.loads((out / 'probes.json').read_text())
    assert [(tool, args) for tool, args, _ in records] == [(tool, args) for tool, args in expected]
    return records

def pick(records, tool, **args):
    hits = [payload for name, arguments, payload in records if name == tool and arguments == args]
    assert len(hits) == 1, (tool, args, len(hits))
    return hits[0]

before, after = read_log('probes-before.log'), read_log('probes-after.log')
for name, records in [('before', before), ('after', after)]:
    (out / ('probes-' + name + '.json')).write_text(json.dumps(records, indent=2, ensure_ascii=False) + '\n')
    for tool, args, payload in records:
        expected_absence = (name == 'after' and tool == 'find_element'
                            and args.get('role') == 'AXMenuBar' and not args.get('include_menus'))
        assert payload.get('ok') is True or (expected_absence and payload.get('ok') is False), (name, tool, args, payload)

# B1: an actual window, fewer visited nodes, and no silent payload cutoff.
full = pick(after, 'get_ui_tree', pid=f, fields=['id', 'role', 'children'])
viewport = pick(after, 'get_ui_tree', pid=f, viewport_only=True, fields=['id', 'role', 'children'])
assert any(n.get('role') == 'AXWindow' for n in full['nodes'])
assert viewport['count'] > 1 and not viewport['truncated'], viewport
assert viewport['nodes_visited'] < full['nodes_visited'], (viewport['nodes_visited'], full['nodes_visited'])
print('B1 visited:', full['nodes_visited'], '->', viewport['nodes_visited'])

# B2: compare ALL element fields, preserving array order and IDs.
for app in ('finder', 'safari'):
    a = pick(before, 'capture_annotated', pid=p[app], inline=False)
    b = pick(after, 'capture_annotated', pid=p[app], inline=False)
    assert a['window_id'] == b['window_id'], (app, 'window changed')
    assert a.get('ax_scope') == b.get('ax_scope') == 'window_subtree', (app, a.get('ax_scope'), b.get('ax_scope'))
    assert a.get('annotated') and b.get('annotated') and a['elements'] and b['elements'], (app, 'no annotation evidence')
    left = json.dumps(a['elements'], indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    right = json.dumps(b['elements'], indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    (out / (app + '-before.elements.json')).write_text(left)
    (out / (app + '-after.elements.json')).write_text(right)
    delta = ''.join(difflib.unified_diff(left.splitlines(True), right.splitlines(True), fromfile='before', tofile='after'))
    (out / (app + '-elements.diff')).write_text(delta)
    assert not delta, (app, 'element diff', str(out / (app + '-elements.diff')))
    print('B2', app, 'identical full elements:', len(a['elements']))

# A4: limit must select the first five AFTER each filter, not before it.
for filters in ({'role': 'AXRow', 'viewport_only': True}, {'interactive_only': True}):
    broad = pick(after, 'find_elements', pid=settings, limit=500, **filters)
    limited = pick(after, 'find_elements', pid=settings, limit=5, **filters)
    assert broad['count'] >= 5, ('inconclusive: fewer than five fixture candidates on this desktop', filters, broad)
    assert limited['count'] == 5 and limited['limit_reached'] is True, limited
    assert [e['id'] for e in limited['elements']] == [e['id'] for e in broad['elements'][:5]]
    print('A4 filter-before-limit:', filters, 'count=5, IDs equal to filtered prefix')

# B3: menu flags for all six tools, opt-in reachability, bounded query/list.
for tool, args, payload in after:
    if 'include_menus' in args:
        assert payload.get('menus_excluded') == (not args['include_menus']), (tool, args, payload)
        included = args['include_menus']
        if tool == 'get_ui_tree':
            assert any(n.get('role') == 'AXMenuBar' for n in payload['nodes']) == included
        elif tool in ('find_elements', 'query_elements'):
            assert (payload['count'] > 0) == included
        elif tool == 'find_element':
            assert payload['ok'] == included
    if args.get('node_cap') == 10:
        assert payload['nodes_visited'] <= 10 and payload['node_cap'] == 10, payload
        assert payload['node_cap_reached'] and payload['truncated'], payload
assert pick(before, 'list_menu_titles', pid=f) == pick(after, 'list_menu_titles', pid=f)
print('B3 menu opt-in, unchanged menu titles and node caps: PASS')

# B4: successful shallow-first Search on the actual System Settings tree.
found = pick(after, 'find_element', pid=settings, title='Search')
grounded = pick(after, 'ground', pid=settings, target='Search', strategy='ax')
assert found.get('element_id') and grounded.get('element_id'), (found, grounded)
assert grounded['result']['strategyUsed'] == 'ax', grounded
print('B4 Search find/ground:', found['element_id'], grounded['element_id'])

# B6: report the production byte count; exact encoding is covered by Swift tests.
payload = pick(after, 'get_ui_tree', pid=f, max_depth=6)
assert isinstance(payload['bytes'], int) and payload['bytes'] > 0, payload
print('B6 reported byte count (exact accounting verified by AXPayloadBudgetTests):', payload['bytes'])
PY
```

**Verwachte uitkomsten:** alle assertions slagen; beide `*-elements.diff` zijn
leeg met niet-lege lijsten; A4 geeft vijf resultaten met dezelfde eerste vijf
ID's als de gefilterde brede query. Zonder genoeg offscreen nodes/zichtbare rijen
is de huidige desktop geen reproductie van de oorspronkelijke workload: rapporteer
het verschil; wijzig gebruikersapps niet om de check te forceren. Geen live boom
bewijst afwezigheid van iedere diepe duplicate Search-match: de geslaagde
`shallowFirst`/`groundShallowFirst` fake-tests leveren dat deterministische bewijs.

## 4. Performance — 7 warme runs met exact dezelfde perf.py

```sh
python3 "$S2_SCRATCH/perf.py" "$S2_OLD" "$S2_OUT/cases.json" 7 "$S2_OUT/perf-before.json" > "$S2_OUT/perf-before.log" 2>&1
python3 "$S2_SCRATCH/perf.py" "$S2_NEW" "$S2_OUT/cases.json" 7 "$S2_OUT/perf-after.json" > "$S2_OUT/perf-after.log" 2>&1
python3 - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ['S2_OUT'])
before, after = [json.loads((out / ('perf-' + phase + '.json')).read_text()) for phase in ('before', 'after')]
cases = json.loads((out / 'cases.json').read_text())
assert len(before) == len(after) == len(cases), 'Missing/timed-out cases'
limits = {'tree-viewport/Finder': 200, 'capture/Finder': 200,
          'query-Eject/Finder': 300, 'list/Finder': 300, 'find-Search/Settings': 40}
failures = []
for a, b, (label, tool, args) in zip(before, after, cases):
    assert (a['label'], a['tool'], a['args']) == (b['label'], b['tool'], b['args']) == (label, tool, args)
    for row in (a, b):
        assert row['n'] == 7 and row['errors'] == 0, row
        if tool == 'get_ui_tree': assert row['info']['count'] > 1, row
        if tool == 'capture_annotated': assert row['info']['n_elements'] > 0, row
    if label == 'rows-viewport-limit5/Settings': assert b['info']['count'] == 5, b
    print(f"{label}: {a['p50']} -> {b['p50']} ms; payload {a['bytes']} -> {b['bytes']} bytes")
    if label in limits and b['p50'] > limits[label]: failures.append((label, b['p50'], limits[label]))
assert not failures, ('Targets exceeded', failures)
PY
```

**Targets:** Finder viewport ≤ 200 ms; Finder capture ≤ 200 ms met de identieke
lijsten uit stap 3; Finder query/list elk ≤ 300 ms; Search/System Settings ≤ 40 ms.
Safari capture, gewone/depth-6 trees, AXButton limit 20, ground(ax) en A4 worden
ook voor/na gerapporteerd, zonder extra niet-gespecificeerde harde tijdslimieten.
Historische p50's zijn workloadreferenties, geen eis dat de nieuwe baseline exact
771/502/890/882/344 ms moet reproduceren. Rapporteer verschillen in aantallen,
truncatie, vensterinhoud en payload naast de tijden. `perf.py` bewaart vooral
samenvattingen: de succesvolle echte AX/capture-probes uit stap 3 zijn daarom
noodzakelijk voordat lage timingcijfers als performancebewijs tellen.

## 5. B7 — drie verschillende apps en dezelfde PID

```sh
python3 TestHarness/s2_concurrency.py "$S2_OLD" "$S2_FINDER_PID,$S2_SAFARI_PID,$S2_CHROME_PID" 7 > "$S2_OUT/concurrency-before.log"
python3 TestHarness/s2_concurrency.py "$S2_NEW" "$S2_FINDER_PID,$S2_SAFARI_PID,$S2_CHROME_PID" 7 > "$S2_OUT/concurrency-after.log"
python3 TestHarness/s2_concurrency.py "$S2_OLD" "$S2_FINDER_PID,$S2_FINDER_PID,$S2_FINDER_PID" 7 --same-pid > "$S2_OUT/same-pid-before.log"
python3 TestHarness/s2_concurrency.py "$S2_NEW" "$S2_FINDER_PID,$S2_FINDER_PID,$S2_FINDER_PID" 7 --same-pid > "$S2_OUT/same-pid-after.log"
cat "$S2_OUT/concurrency-before.log" "$S2_OUT/concurrency-after.log"
cat "$S2_OUT/same-pid-before.log" "$S2_OUT/same-pid-after.log"
```

**Verwacht:** alle vier logs melden `measurement_valid=True` en alle vier commando’s eindigen met exitcode 0. De nieuwe
`concurrent_3app_p50` benadert `max_app_p50` (plus serialisatie/transportkosten),
terwijl `sequential_3app_p50` bij de som ligt. Rapporteer de ruwe waarden en de
verhoudingen concurrent/max en concurrent/sequentieel; de specificatie geeft
geen numerieke tolerantie voor “≈”. Een gelijke sequentiële/concurrente tijd
bij vergelijkbaar zware apps is geen bewijs van B7. Een sterk dominerende app
maakt de verhouding weinig onderscheidend; stuur dan de drie individuele
metingen mee. De modus `--same-pid` meet drie gelijke Finder-PID-aanvragen:
die blijven ongeveer de som van drie losse walks kosten. Ook deze modus
valideert ieder AX-antwoord en breekt af bij EOF of een verlopen deadline.

## 6. Live suites en terugrapportage

```sh
script -q /dev/null swift test --no-parallel --filter AnnotatedElementIdentityTests > "$S2_OUT/AnnotatedElementIdentityTests.log" 2>&1
script -q /dev/null swift test --no-parallel --filter AXPayloadBudgetTests > "$S2_OUT/AXPayloadBudgetTests.log" 2>&1
script -q /dev/null swift test --no-parallel --filter ElementAtPointTests > "$S2_OUT/ElementAtPointTests.log" 2>&1
```

**Verwacht:** alle checks slagen en er zijn geen Accessibility-/capture-skips in
de vijf AnnotatedElementIdentityTests. De test die alleen ontbrekende trust
verifieert in ElementAtPointTests hoort op deze vertrouwde omgeving zijn guard
te nemen. Voer nooit de volledige Swift-suite uit.

Stuur bij een fout de betreffende raw probe-log, JSON-resultaten, `*.diff`,
`pids.json`, `binary-hashes.txt`, `revisions.txt` en de suite-summary terug.
Bij succes: stuur beide p50-tabellen, beide drie-app/same-PID-logs en bevestig
expliciet dat beide volledige annotatiediffs leeg zijn. Alles staat in
`.build/s2-review/`. Screenshots worden alleen als artifactpaden gerapporteerd;
geen base64 kopiëren in het verslag. Geen van deze live uitkomsten is door de
Codex-sandbox geclaimd.
