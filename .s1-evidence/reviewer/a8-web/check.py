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
