# S1 — live-checks voor de desktopreviewer

Codex heeft geen desktoptoegang. De hieronder beschreven checks zijn daarom **overgedragen, niet live geslaagd**. Voer ze uit vanuit Claude/de bestaande vertrouwde desktopsessie, in deze worktree. Wijzig geen permissies. Geen clicks, typing, window moves, clipboardwrites of wijzigingen aan bestaande documenten. Alleen A1 opent tijdelijk één eigen Finder-window; de cleanup sluit uitsluitend het geretourneerde nieuwe window-id.

## 1. Build en actuele discovery

```sh
export S1_WORKTREE="$PWD"
export S1_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
mkdir -p .s1-evidence/reviewer
swift build
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp '[["permissions_status",{}],["list_apps",{}],["list_windows",{}]]' | tee .s1-evidence/reviewer/discovery.txt
```

Verwacht: Accessibility en Screen Recording zijn verleend; Finder en Google Chrome hebben actuele pids en vensters. Bij ontbrekende toegang: meld de blokkade, pas geen instellingen aan. Gebruik geen pids of coördinaten uit de oude audit zonder nieuwe discovery.

## 2. Maak de persistente NDJSON-probe

`SCRATCH/probe.py` sluit zijn server na de laatste call. Losse invocaties kunnen daardoor geen gecachete id vasthouden terwijl AppleScript het menu verandert. Onderstaande volledige helper gebruikt hetzelfde `initialize`/`tools/call`-protocol, maar houdt één server open voor de afhankelijke A1/A2/A8-calls. Alle verzoeken, antwoorden en tijden worden gelogd. De losse stock-probe voor Chrome staat verderop.

```sh
cat > .s1-evidence/reviewer/session.py <<'PY'
import json
import os
import re
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

binary = os.environ.get("S1_BINARY", ".build/debug/mac-control-mcp")
mode = os.environ.get("S1_MODE", "check")
window_menu = os.environ.get("S1_WINDOW_MENU", "Window")
out = Path(os.environ.get("S1_OUTPUT", ".s1-evidence/reviewer"))
out.mkdir(parents=True, exist_ok=True)
server_errors = (out / "server-stderr.txt").open("w")
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=server_errors)
buffer = b""
request_id = 0
created_window = None


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rpc(method, params):
    global buffer, request_id
    request_id += 1
    rid = request_id
    started = time.perf_counter()
    request = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
    p.stdin.write((json.dumps(request) + "\n").encode())
    p.stdin.flush()
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == rid:
                elapsed = (time.perf_counter() - started) * 1000
                print(json.dumps({"request": request, "ms": elapsed, "response": response}, ensure_ascii=False), flush=True)
                require("error" not in response, "JSON-RPC error")
                return response["result"], elapsed
        ready, _, _ = select.select([p.stdout], [], [], 0.05)
        if ready:
            chunk = os.read(p.stdout.fileno(), 1 << 20)
            require(bool(chunk), "server closed stdout")
            buffer += chunk
    raise TimeoutError(f"request {rid}")


def tool(name, args):
    response, elapsed = rpc("tools/call", {"name": name, "arguments": args})
    payload = response.get("structuredContent")
    require(isinstance(payload, dict), f"missing structuredContent: {name}")
    return payload, elapsed


def success(name, args):
    payload, _ = tool(name, args)
    require(payload.get("ok") is True, f"{name} failed: {payload}")
    return payload


def app_pid(apps, bundle):
    matches = [a for a in apps if a.get("bundleIdentifier") == bundle or a.get("bundle_id") == bundle]
    require(len(matches) == 1, f"cannot uniquely discover {bundle}: {matches}")
    return int(matches[0]["pid"])


def applescript(source):
    result = subprocess.run(["osascript", "-e", source], text=True, capture_output=True, timeout=20, check=True)
    print(json.dumps({"osascript": source, "stdout": result.stdout, "stderr": result.stderr}), flush=True)
    return result.stdout.strip()


def finder_window_ids():
    raw = applescript('tell application "Finder" to get id of every Finder window')
    require(not raw or re.fullmatch(r"[0-9, ]+", raw), f"invalid Finder ids: {raw}")
    return {int(x.strip()) for x in raw.split(",") if x.strip()}


def paths(pid):
    return success("list_menu_paths", {"pid": pid, "max_depth": 6})["paths"]


def attributes(element_id):
    return tool("get_element_attributes", {"element_id": element_id, "names": ["AXRole", "AXTitle"]})[0]


def same_or_stale(saved, phase):
    remaining = {}
    stale = 0
    for element_id, original in saved.items():
        current = attributes(element_id)
        if current.get("error_code") == "stale_element":
            stale += 1
            continue  # stale entries are removed; do not query that id again.
        require(current.get("ok") is True, f"{phase}: unexpected id error: {current}")
        require(current.get("values") == original, f"{phase}: SILENT RETARGET {original} -> {current}")
        remaining[element_id] = original
    print(json.dumps({"check": "A1", "phase": phase, "same": len(remaining), "stale": stale, "wrong": 0}), flush=True)
    return remaining


def check_menu(finder):
    global created_window
    before_paths = paths(finder)
    window_paths = [q for q in before_paths if len(q) > 1 and q[0] == window_menu]
    require(window_paths, f"no {window_menu!r} menu; inspect list_menu_paths and set S1_WINDOW_MENU to the actual localized title")
    # A unique leaf title avoids minting a same-named item in another menu.
    leaf_counts = {}
    for q in before_paths:
        if q:
            leaf_counts[q[-1]] = leaf_counts.get(q[-1], 0) + 1
    candidates = sorted({q[-1] for q in window_paths if leaf_counts[q[-1]] == 1})
    saved = {}
    for title in candidates[:20]:
        found = success("find_elements", {"pid": finder, "role": "AXMenuItem", "title": title, "exact": True, "limit": 20})
        for row in found["elements"]:
            current = attributes(row["id"])
            values = current.get("values", {})
            if current.get("ok") and values.get("AXRole") == "AXMenuItem" and values.get("AXTitle") == title:
                saved[row["id"]] = values
    require(saved, "no readable Window-menu ids were minted; no window has been opened")
    before_ids = finder_window_ids()
    require(before_ids, "A1 needs an existing Finder window; do not alter an existing user window to prepare it")
    raw = applescript('tell application "Finder"\nset s1Window to make new Finder window\nreturn id of s1Window\nend tell')
    require(re.fullmatch(r"[0-9]+", raw) is not None, "window created but no numeric id returned: stop and report; do not guess a cleanup target")
    candidate_id = int(raw)
    require(candidate_id not in before_ids, "Finder returned a pre-existing id; refusing to close it")
    created_window = candidate_id
    try:
        require(created_window in finder_window_ids(), "new Finder window not visible to AppleScript")
        deadline = time.monotonic() + 5
        after_paths = paths(finder)
        while after_paths == before_paths and time.monotonic() < deadline:
            time.sleep(0.2)
            after_paths = paths(finder)
        require(after_paths != before_paths, "INCONCLUSIVE A1: Window/menu contents did not change in AX")
        saved = same_or_stale(saved, "own window open")
    finally:
        applescript(f'tell application "Finder" to close Finder window id {created_window}')
        created_window = None
    same_or_stale(saved, "own window closed")
    print(json.dumps({"check": "A1", "coverage": "menu_mutation_smoke", "live_relabel_reproduced": "not established by unchanged targets; inspect raw before/after values"}), flush=True)
    require(before_ids.issubset(finder_window_ids()), "a pre-existing Finder window disappeared; stop and report")


def check_chrome(chrome):
    listed = success("list_windows", {"pid": chrome})
    windows = [w for w in listed["windows"] if w.get("window_id") and not w.get("minimized")]
    require(windows, "Chrome has no identifiable non-minimized window")
    found = success("find_elements", {"pid": chrome, "role": "AXLink", "exact": True, "max_depth": 32, "limit": 500})
    for row in found["elements"]:
        pos, size = row.get("position", {}), row.get("size", {})
        if size.get("width", 0) < 2 or size.get("height", 0) < 2:
            continue
        x, y = pos["x"] + size["width"] / 2, pos["y"] + size["height"] / 2
        owners = [w for w in windows if w["x"] <= x <= w["x"] + w["width"] and w["y"] <= y <= w["y"] + w["height"]]
        if not owners:
            continue
        hit_args = {"pid": chrome, "x": x, "y": y}
        hit = success("element_at_point", hit_args)
        if hit.get("role") != "AXLink" or hit.get("title") != row.get("title"):
            continue  # Hit testing may return a parent; this is not identity evidence.
        if not hit.get("stable_id"):
            require(bool(hit.get("stable_id_reason")), "A8: random id has no reason")
            raise RuntimeError(f"A8 fallback still needed; report exact reason and ancestor chain: {hit}")
        require(hit["element_id"] == row["id"], f"A8 search/hit ids differ: {row} vs {hit}")
        again = success("element_at_point", hit_args)
        require(again.get("stable_id") is True and again["element_id"] == hit["element_id"], "A8 repeated hit changed its id")
        calls = [["list_windows", {"pid": chrome}], ["find_elements", {"pid": chrome, "role": "AXLink", "exact": True, "max_depth": 32, "limit": 500}], ["element_at_point", hit_args], ["element_at_point", hit_args]]
        (out / "chrome-probe-calls.json").write_text(json.dumps(calls))
        print(json.dumps({"check": "A8", "window_id": owners[0]["window_id"], "id": row["id"], "stable_id": True}), flush=True)
        return row["id"], attributes(row["id"])["values"]
    raise RuntimeError("INCONCLUSIVE A8: no visible Chrome link returned a matching AXLink hit; do not navigate or click a user tab")


def check_retention(finder, other):
    buttons = success("find_elements", {"pid": finder, "role": "AXButton", "exact": True, "limit": 20})["elements"]
    require(buttons, "A2: no Finder button for the old-id check")
    old = buttons[0]["id"]
    expected = attributes(old)
    require(expected.get("ok") is True and expected.get("values", {}).get("AXRole"), "A2: unreadable initial handle")
    sizes = []
    for index in range(6):
        tree = success("get_ui_tree", {"pid": finder, "max_depth": 12})
        sizes.append(tree["nodes_visited"])
        for element_id, values in [(old, expected["values"]), other]:
            current = attributes(element_id)
            require(current.get("ok") is True and current.get("values") == values,
                    f"A2: retained id failed after tree {index + 1}: {current}")
    print(json.dumps({"check": "A2", "walk_sizes": sizes, "old_finder_id": old, "other_pid_id": other[0], "retained": True}), flush=True)
    require(all(n == 2000 for n in sizes), "INCONCLUSIVE A2 full-scale check: ids survived, but the current Finder view did not produce six 2000-node walks")


def check_visits(finder):
    tree = success("get_ui_tree", {"pid": finder, "max_depth": 1})
    for name, filt in [("find_elements", {"role": "AXS1ImpossibleRole"}), ("query_elements", {"role_regex": "^AXS1ImpossibleRole$"})]:
        result = success(name, {"pid": finder, "max_depth": 1, **filt})
        require(result["count"] == 0, "unexpected impossible-role match")
        require(result["nodes_visited"] == tree["nodes_visited"] and result["nodes_visited"] > 0,
                f"A6: visit count differs from same-depth tree: {result} vs {tree['nodes_visited']}")
    result = success("list_elements", {"pid": finder, "max_depth": 1})
    require(result["nodes_visited"] == tree["nodes_visited"], "A6 list_elements visit count differs from tree")
    print(json.dumps({"check": "A6", "visited": tree["nodes_visited"], "zero_matches_counted_honestly": True}), flush=True)


def measure(finder, chrome):
    # Seed one stable menu handle in THIS session; stock perf.py cannot
    # resolve an id minted by a previous server process.
    menu = success("find_elements", {"pid": finder, "role": "AXMenuItem", "title": os.environ.get("S1_PERF_MENU_TITLE", "Minimize"), "exact": True, "limit": 20})["elements"]
    require(len(menu) == 1, "choose a unique visible Window-menu title using S1_PERF_MENU_TITLE")
    element_id = menu[0]["id"]
    expected_fingerprint = attributes(element_id).get("values", {})
    require(expected_fingerprint.get("AXRole") == "AXMenuItem", "unreadable benchmark handle")
    cases = [
        ("resolveLive/get_element_attributes", "get_element_attributes", {"element_id": element_id, "names": ["AXRole", "AXTitle"]}),
        ("Finder tree", "get_ui_tree", {"pid": finder, "max_depth": 12}),
        ("Finder find", "find_elements", {"pid": finder, "role": "AXButton", "limit": 20}),
        ("Finder query", "query_elements", {"pid": finder, "title_regex": "^Eject$"}),
        ("Finder list", "list_elements", {"pid": finder}),
        ("Chrome links", "find_elements", {"pid": chrome, "role": "AXLink", "limit": 20}),
    ]
    validated_calls = json.loads(Path('.s1-evidence/reviewer/check/chrome-probe-calls.json').read_text())
    hit_args = next(args for name, args in validated_calls if name == 'element_at_point')
    require(hit_args['pid'] == chrome, 'Chrome pid changed since the link check; repeat discovery')
    cases.append(('Chrome hit', 'element_at_point', hit_args))
    results = []
    for label, name, args in cases:
        warm = success(name, args)
        if name == "element_at_point":
            require(warm.get("role") == "AXLink", "benchmark point no longer hits a Chrome link")
        samples = []
        for _ in range(7):
            value, elapsed = tool(name, args)
            require(value.get("ok") is True, f"benchmark error: {value}")
            if name == "get_element_attributes":
                require(value.get("values") == expected_fingerprint, "benchmark handle changed title or role")
            if name == "element_at_point":
                require(all(value.get(key) == warm.get(key) for key in ("role", "title", "bounds")), "benchmark link moved or changed")
            if name == "get_ui_tree":
                require(value["nodes_visited"] > 1, "unreadable/empty tree cannot be benchmarked")
            samples.append(elapsed)
        results.append({"case": label, "tool": name, "args": args, "samples_ms": samples, "p50_ms": statistics.median(samples), "last_payload": value})
    (out / "measurements.json").write_text(json.dumps(results, indent=2))


exit_code = 0
try:
    rpc("initialize", {})
    permissions = success("permissions_status", {})
    require(permissions.get("accessibility") == "granted", "desktop Accessibility grant is required; do not change settings")
    apps = success("list_apps", {})["apps"]
    finder = app_pid(apps, "com.apple.finder")
    chrome = app_pid(apps, "com.google.Chrome")
    if mode == "measure":
        measure(finder, chrome)
    else:
        failures = []
        for label, check in [("A1", lambda: check_menu(finder)), ("A6", lambda: check_visits(finder))]:
            try:
                check()
            except Exception as error:
                failures.append(f"{label}: {error}")
        other = None
        try:
            other = check_chrome(chrome)
        except Exception as error:
            failures.append(f"A8: {error}")
        if other:
            try:
                check_retention(finder, other)
            except Exception as error:
                failures.append(f"A2: {error}")
        else:
            failures.append("A2: cross-pid retention could not run without a readable Chrome id")
        require(not failures, "\n".join(failures))
    print(json.dumps({"status": "PASS", "mode": mode}), flush=True)
except Exception as error:
    print(json.dumps({"status": "FAIL_OR_INCONCLUSIVE", "error": str(error)}), flush=True)
    exit_code = 1
finally:
    if created_window is not None:
        try:
            applescript(f'tell application "Finder" to close Finder window id {created_window}')
        except Exception as error:
            print(json.dumps({"cleanup_failed_window_id": created_window, "error": str(error)}), flush=True)
            exit_code = 1
    p.stdin.close()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
    server_errors.close()
sys.exit(exit_code)
PY
S1_MODE=check S1_OUTPUT=.s1-evidence/reviewer/check python3 .s1-evidence/reviewer/session.py > .s1-evidence/reviewer/check.jsonl
cat .s1-evidence/reviewer/check.jsonl
```

Verwachte uitkomsten:

- **A1 (menu-mutatie-smoketest):** vóór de mutatie bestaan leesbare Window-menu-ids. Openen verandert de menu-inhoud. Daarna retourneert iedere nog bekende id dezelfde `AXRole`/`AXTitle`, of `stale_element`; nooit `ok:true` voor een andere titel. Na sluiten van uitsluitend het nieuwe window geldt hetzelfde. `wrong:0`; een positief aantal stale-antwoorden is niet verplicht als deze menu-items hun identiteit behouden. De oorspronkelijke windows blijven bestaan. Als alle targets ongewijzigd blijven, is de concrete live relabelbug **niet gereproduceerd**, ook als de smoketest slaagt; de oude baseline kan zo ook slagen. Voor live-regressiebewijs moet minimaal één opgeslagen target aantoonbaar veranderen of verdwijnen. De deterministische relabel-regressie is apart afgedekt door de fake-test: terugzetten van de oude `isAlive`-route geeft RED, herstellen van de fingerprintcontrole GREEN. Label de revieweruitkomst dus niet sterker dan het bewijs.
- **A2:** zes Finder-walks van 2.000 nodes, terwijl zowel de oude Finder-id als een Chrome-id leesbaar blijven. `unknown_element_id`/`evicted_element_id` zijn hier fouten. Het echte overschrijden van 20.000 unieke cache-entries en de specifieke evictionfoutcode zijn afgedekt door de fake/unit-tests; stabiele herhaalde trees alleen overschrijden de cache niet.
- **A6:** bij nul zoekmatches is `nodes_visited` positief en gelijk aan de treewalk op dezelfde diepte. Bij een spontaan veranderende UI de read-only check opnieuw uitvoeren; stuur blijvende verschillen terug.
- **A8:** de gekozen link ligt binnen een expliciet gelogde `window_id`; search en beide hit-tests retourneren hetzelfde id, `stable_id:true`. Als geen pad mogelijk is, moet `stable_id_reason` aanwezig zijn. Een verklaarde fallback is eerlijk maar bewijst de Chrome-rootfix niet: stuur de volledige ancestor-chain terug.
- De algemene `status:PASS` betekent dat de beschreven checks en de A1-smoketest slagen; het is geen claim dat een positionele relabel live is gereproduceerd. `FAIL_OR_INCONCLUSIVE` en cleanupfouten zijn geen geslaagde live checks. Het script print fouten expliciet en stopt met exitcode 1.

Herhaal de concrete Chrome-calls ook met de voorgeschreven stock-probe:

```sh
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/check/chrome-probe-calls.json)" | tee .s1-evidence/reviewer/chrome-stock-probe.txt
```

Dit bestand bestaat alleen nadat een echte link is gevonden. De eerste `find_elements` mint de ids opnieuw binnen deze nieuwe server; de twee hit-tests moeten daarmee overeenkomen.

## 3. Voor/na: identieke probe en actuele desktop

De oude sandbox-na-meting in `.s1-evidence/perf-after.json` is ongeldig als snelheidsvergelijking: die zag geen desktop. Gebruik de volgende vergelijking. Deze bouwt de vastgepinde 0.9.0-baseline `cb435a8` (parent van WIP `9dcec32`) in een **submap van dezelfde worktree**, zonder checkout, rebase of wijziging van WIP-commits.

```sh
set -e
mkdir -p .build/s1-baseline-src
# Gebruik een lege baseline-map; stop als er al oude bronnen in staan.
test ! -e .build/s1-baseline-src/Package.swift
git archive cb435a8 | tar -x -C .build/s1-baseline-src
swift build --package-path .build/s1-baseline-src --scratch-path .build/s1-baseline-build
S1_BINARY=.build/s1-baseline-build/debug/mac-control-mcp S1_MODE=measure S1_OUTPUT=.s1-evidence/reviewer/before python3 .s1-evidence/reviewer/session.py > .s1-evidence/reviewer/before.jsonl
S1_BINARY=.build/debug/mac-control-mcp S1_MODE=measure S1_OUTPUT=.s1-evidence/reviewer/after python3 .s1-evidence/reviewer/session.py > .s1-evidence/reviewer/after.jsonl
python3 - <<'PY'
import json
from pathlib import Path
before = json.loads(Path('.s1-evidence/reviewer/before/measurements.json').read_text())
after = json.loads(Path('.s1-evidence/reviewer/after/measurements.json').read_text())
assert [r['case'] for r in before] == [r['case'] for r in after]
for old, new in zip(before, after):
    assert old['tool'] == new['tool'] and old['args'] == new['args'], 'App/path changed between measurements; rerun against the same UI'
    print(f"{old['case']}: p50 {old['p50_ms']:.3f} -> {new['p50_ms']:.3f} ms")
PY
```

Verwacht: beide JSONL-runs eindigen met `status:PASS`, alle calls `ok:true`, echte bomen met meer dan één node. Ze gebruiken dezelfde helper, warme sessies en zeven gemeten herhalingen. Laat de desktop tussen beide runs gelijk. `resolveLive/get_element_attributes` meet de nieuwe leafcontrole zonder een nieuwe zoekactie per sample. Rapporteer alle samples en p50, ook als de wijziging langzamer is.

De oorspronkelijke auditcases kunnen daarnaast met exact dezelfde `SCRATCH/perf.py` worden herhaald. Maak eerst een casebestand met de **actuele** pids uit discovery en bewaar datzelfde bestand voor beide binaries; gebruik de oude audit-pids niet blind. De sessiehelper hierboven dekt ook cached-id-resolutie, die de statische perf.py niet kan seeden.

De eis van maximaal één extra IPC betreft de intacte live-handle-route. De fake-cachetest verifieert één fingerprint-read, geen extra liveness-read, en geen repair. `AXPath.fingerprint` gebruikt één `AXAttributeBatch.fetch(...fallbackOnFailure:false)`: geen per-attribuut fallback. Padherstel bij een mismatch mag meerdere reads nodig hebben. **Latentie alleen bewijst geen aantal kernel-IPC-calls**; meld de tijden als tijden, niet als IPC-counts.

## 4. Bestaande live suites en resultaten terugsturen

```sh
script -q /dev/null swift test --no-parallel --filter AXPathTests > .s1-evidence/reviewer/AXPathTests.txt 2>&1
script -q /dev/null swift test --no-parallel --filter AnnotatedElementIdentityTests > .s1-evidence/reviewer/AnnotatedElementIdentityTests.txt 2>&1
script -q /dev/null swift test --no-parallel --filter AXHandleSafetyTests > .s1-evidence/reviewer/AXHandleSafetyTests.txt 2>&1
script -q /dev/null swift test --no-parallel --filter AXPayloadBudgetTests > .s1-evidence/reviewer/AXPayloadBudgetTests.txt 2>&1
```

Verwacht: geen assertion failures én geen trust-/Finder-/Screen Recording-skipmeldingen. Draai niet de volledige suite. De aangevraagde TextEditingTests zijn headless en al gedraaid; er is geen reden om een gebruikersdocument te wijzigen.

Stuur bij een fout de relevante JSONL-regels, pids/window_id, oorspronkelijke en actuele titel, eventuele `stable_id_reason`/ancestors en suite-output terug. Trim uitsluitend eventuele base64-afbeeldingsvelden uit teruggestuurde capture-output; bewaar foutcodes, bounds en ids. De probe hierboven maakt zelf geen screenshots en schrijft niet naar het clipboard.


## 5. Git-handoff wanneer de administratieve Git-map hier niet schrijfbaar is

Codex kon geen `index.lock` schrijven in `/Users/a/projects/mac-control-mcp/.git/worktrees/wt10-ids`. Indien dit bij overdracht nog zo is, kan de reviewer onderstaande conventionele commits op **dezelfde branch** maken. De bestaande WIP blijft intact; geen amend/rebase/merge/push. Controleer eerst `git status --short --branch` en commit uitsluitend de S1-bestanden.

```sh
git status --short --branch
git add Sources/MacControlMCP/ElementCache.swift Sources/MacControlMCP/TextEditingController.swift Sources/MacControlMCP/Tools+TextEditing.swift Tests/MacControlMCPTests/ElementCacheTests.swift Tests/MacControlMCPTests/TextEditingTests.swift
git commit -m 'fix: finish cache retention and live identity verification' -m 'v0.10 A1/A2: verify relabel and repair behavior with a fake AX resolver, reserve slots for repeated collision quarantine, and derive text hints from configured cache limits.'
git add Sources/MacControlMCP/Tools+V0_9AXCore.swift Sources/MacControlMCP/Tools+V2.swift docs/TOOLS.md
git commit -m 'fix: explain element identity and retention limits' -m 'v0.10 A2/A8: report the random-id fallback reason and document the independent walk and cache limits. Regenerated tool documentation matches the registry.'
git add LIVE-CHECKS.md
git commit -m 'test: document reproducible S1 desktop verification' -m 'Provide persistent NDJSON probes with owned-window cleanup, explicit expected outcomes, and a pinned before/after benchmark so a desktop-capable reviewer can finish the live checks.'
```

De headless RED/GREEN-logs en het eindrapport staan in `.s1-evidence/`. De nieuw te genereren `.s1-evidence/reviewer/`-output hoort bij de review; die is nog niet door Codex geproduceerd of geclaimd als geslaagd.

## 8. A8 herreview — gerenderde Chrome-webinhoud (tekstlinks én afbeelding)

Deze check is toegevoegd na de review waarin native toolbar-hits wel stabiel waren,
maar vier hits op drie webtargets geen pad kregen. A1/A2/A6 zijn volgens die review
afgerond. **Onderstaande A8-run is nog niet door Codex live uitgevoerd.**

De nieuwe reconstructie probeert eerst de parent-chain (`parent_chain`), met per
niveau `cf_equal` of een unieke `fingerprint_frame`-match. Bij ontbrekende/virtuele
parents volgt `top_down`, maximaal 32 niveaus en 2.000 unieke node-reads over beide
strategieën samen. Niet uitsluitend uit eerste kinderen bestaande parent-paden
worden ook tegen de eerste DFS-vindplaats gecontroleerd: gedeelde handles kunnen
anders een ander id krijgen dan de gewone walk. De top-down stappenlijst bevat
de uiteindelijke target-match.
Frames bevestigen aliasmatches; ze sluiten geen takken uit: overflow kan een
webchild buiten zijn parent-frame plaatsen. Een fingerprint-match wordt alleen
geaccepteerd na een volledige, niet-ambigue zoekactie binnen de limieten. Een
exact gelijke handle kan direct worden herkend. Specifieke fouten combineren de
parent-oorzaak met de fallback-oorzaak, bijvoorbeeld
`parent_chain_break_at_depth_4;top_down_node_cap` of
`no_app_root;top_down_ambiguous`.

Voer dit uit in de huidige worktree met dezelfde reeds geopende Hacker News-pagina
als bij de vorige review. De helper navigeert, klikt, scrollt of typt niet. Hij
vereist dat de targets via de child-indices van `get_ui_tree` onder een
`AXWebArea` vallen: een native toolbar-hit kan de check dus niet laten slagen.
Bij ontbrekende targets of gewijzigde/afgedekte pagina: rapporteer INCONCLUSIVE;
verander geen bestaande tab om de check passend te maken.

```sh
export S1_SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
mkdir -p .s1-evidence/reviewer/a8-web
cat > .s1-evidence/reviewer/a8-web/check.py <<'PY'
import json
import os
import re
import shlex
import subprocess
from pathlib import Path

out = Path('.s1-evidence/reviewer/a8-web') / os.environ.get('S1_A8_LABEL', 'after')
out.mkdir(parents=True, exist_ok=True)
binary = os.environ.get('S1_BINARY', '.build/debug/mac-control-mcp')
probe = str(Path(os.environ['S1_SCRATCH']) / 'probe.py')
env = dict(os.environ, PROBE_MAX='300000')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(label, calls):
    argv = ['python3', probe, binary, json.dumps(calls)]
    (out / (label + '-calls.json')).write_text(json.dumps(calls, indent=2))
    (out / (label + '-command.sh')).write_text('PROBE_MAX=300000 ' + shlex.join(argv) + '\n')
    completed = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=900, check=True)
    (out / (label + '.txt')).write_text(completed.stdout)
    require(not completed.stderr, completed.stderr)
    headers = list(re.finditer(r'^--- [^\n]+\n', completed.stdout, re.MULTILINE))
    require(len(headers) == len(calls), 'missing stock-probe response headers')
    results = []
    for index, header in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(completed.stdout)
        payload = json.loads(completed.stdout[header.end():end])
        require(isinstance(payload, dict) and payload.get('ok') is True,
                f'{label} {calls[index]} failed: {payload}')
        results.append(payload)
    return results


apps, all_windows = run('discovery', [['list_apps', {}], ['list_windows', {}]])
chrome = [a for a in apps['apps'] if (a.get('bundleIdentifier') or a.get('bundle_id')) == 'com.google.Chrome']
require(len(chrome) == 1, 'INCONCLUSIVE: need one running Google Chrome')
pid = chrome[0]['pid']
windows = [w for w in all_windows['windows'] if w.get('pid') == pid and not w.get('minimized')]
require(windows, 'INCONCLUSIVE: no Chrome window')
link_args = {'pid': pid, 'role': 'AXLink', 'exact': True, 'max_depth': 32, 'limit': 500,
             'fields': ['id', 'role', 'title', 'position', 'size'], 'max_bytes': 100000}
image_args = dict(link_args, role='AXImage')
tree, links, images = run('targets', [
    ['get_ui_tree', {'pid': pid, 'max_depth': 32, 'fields': ['id', 'role', 'children'], 'max_bytes': 180000}],
    ['find_elements', link_args], ['find_elements', image_args]])
nodes = tree['nodes']
web_ids = set()
seen = set()


def mark(index, in_web=False):
    if index in seen:
        return
    seen.add(index)
    node = nodes[index]
    in_web = in_web or node.get('role') == 'AXWebArea'
    if in_web:
        web_ids.add(node.get('id'))
    for child in node.get('children', []):
        mark(child, in_web)


if nodes:
    mark(0)


def point(row, fraction=0.5):
    pos, size = row.get('position') or {}, row.get('size') or {}
    if size.get('width', 0) < 4 or size.get('height', 0) < 4:
        return None
    x = pos['x'] + fraction * size['width']
    y = pos['y'] + size['height'] / 2
    owners = [w for w in windows if w['x'] <= x <= w['x'] + w['width']
              and w['y'] <= y <= w['y'] + w['height']]
    if not owners:
        return None
    return {'pid': pid, 'x': x, 'y': y}, owners[0]['window_id']


def select(rows, title=None):
    matches = [r for r in rows if r.get('id') in web_ids
               and (title is None or r.get('title') == title) and point(r)]
    require(matches, f'INCONCLUSIVE: no visible web target {title or "AXImage"}; tree may be truncated')
    return matches[0]


hn = select(links['elements'], 'Hacker News')
new = select(links['elements'], 'new')
image = select(images['elements'])
plan = [(hn, 0.25), (hn, 0.75), (new, 0.5), (image, 0.5)]
calls = [['find_elements', link_args], ['find_elements', image_args]]
for row, fraction in plan:
    chosen = point(row, fraction)
    require(chosen, 'INCONCLUSIVE: target point outside current window')
    calls.extend([['element_at_point', chosen[0]], ['element_at_point', chosen[0]]])
responses = run('identity', calls)
current = {r['id']: r for p in responses[:2] for r in p['elements']}
report = []
for index, (row, fraction) in enumerate(plan):
    first, second = responses[2 + 2 * index:4 + 2 * index]
    args, window_id = point(row, fraction)
    live_row = current.get(row['id'])
    # A different role/title/frame is a different hit target, not A8 identity evidence.
    pos, size = row['position'], row['size']
    bounds = dict(pos, **size)
    valid_target = bool(live_row and live_row.get('position') == pos and live_row.get('size') == size
                        and live_row.get('title') == row.get('title') and live_row.get('role') == row.get('role')
                        and all(h.get('pid') == pid and h.get('role') == row.get('role')
                                and h.get('title') == row.get('title') and h.get('bounds') == bounds
                                for h in (first, second)))
    passed = valid_target and all(h.get('stable_id') is True and h.get('element_id') == row['id']
                                 and h.get('stable_id_strategy') in ('parent_chain', 'top_down')
                                 and isinstance(h.get('stable_id_steps'), list) and bool(h['stable_id_steps'])
                                 and all(step in ('cf_equal', 'fingerprint_frame') for step in h['stable_id_steps'])
                                 and 'stable_id_reason' not in h for h in (first, second))
    entry = {'window_id': window_id, 'point': args, 'web_target': row,
             'valid_target': valid_target, 'passed': passed, 'hits': [first, second]}
    report.append(entry)
    print(json.dumps(entry, ensure_ascii=False))
(out / 'comparison.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
require(all(r['valid_target'] for r in report), 'INCONCLUSIVE: page changed or point hit a different/covered target; inspect full outputs')
require(all(r['passed'] for r in report), 'FAIL A8: web hit is unstable or differs from find_elements id')
print('PASS A8: 4 points / 3 web targets / 8 hits, all stable_id:true and same id as find_elements')
PY
swift build
PROBE_MAX=300000 python3 .s1-evidence/reviewer/a8-web/check.py
```

De helper voert steeds exact de stock-probe uit:
`PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp '<calls>'`.
Elke concreet ingevulde calllijst én shellcommand wordt opgeslagen naast de ruwe
output. Herhaal dezelfde acht hit-tests rechtstreeks met:

```sh
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/a8-web/after/identity-calls.json)" | tee .s1-evidence/reviewer/a8-web/after/identity-repeat.txt
```

**Acceptatie:** vier punten op drie webtargets, ieder twee keer: `stable_id:true`,
`element_id` gelijk aan het id van dezelfde rol/titel/bounds uit `find_elements`.
`stable_id_strategy` moet `parent_chain` of `top_down` zijn; `stable_id_steps`
registreert `cf_equal`/`fingerprint_frame`. Bij stabiele ids ontbreekt
`stable_id_reason`. Bij falen stuur de volledige specifieke reden en de ancestors
terug; een verklaarde random-id-fallback telt hier niet als geslaagd.

### Dezelfde probe vóór/na deze A8-correctie

Er is geen prestatieclaim voor deze wijziging. Om het functionele verschil en de
ruwe latenties met **dezelfde calls** vast te leggen, bouw de vorige reviewercommit
zonder checkout, branchwissel of wijziging buiten deze worktree:

```sh
mkdir -p .build/s1-a8-before
git archive a116065 | tar -x -C .build/s1-a8-before
swift build --package-path .build/s1-a8-before
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/s1-a8-before/.build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/a8-web/after/identity-calls.json)" | tee .s1-evidence/reviewer/a8-web/before-same-calls.txt
PROBE_MAX=300000 python3 "$S1_SCRATCH/probe.py" .build/debug/mac-control-mcp "$(cat .s1-evidence/reviewer/a8-web/after/identity-calls.json)" | tee .s1-evidence/reviewer/a8-web/after-same-calls.txt
```

Verwacht vóór: de eerder gemelde web-hits met `stable_id:false` en generieke reden
(alleen een daadwerkelijke reproductie geldt als bewijs). Verwacht na: alle acht
ids stabiel en gelijk aan hun eigen voorafgaande `find_elements`-resultaat. Laat
de pagina tussen runs ongemoeid. Bewaar de `--- tool ... -> N ms` regels; deze
losse timings bewijzen geen p50-prestatieverbetering. De herhaalde performanceprobe
uit §5 blijft beschikbaar voor een echte voor/na-meting.
