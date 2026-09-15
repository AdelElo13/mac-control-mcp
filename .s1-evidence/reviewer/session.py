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
