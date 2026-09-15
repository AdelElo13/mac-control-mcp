"""v0.10 A8 R2: exercise reviewer acceptance with synthetic NDJSON only."""
import ast
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import statistics
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


class ChromeFixture:
    def __init__(self, unrelated=False, unstable=False, slow=False):
        self.hits = 0
        self.unrelated = unrelated
        self.unstable = unstable
        self.slow = slow
        self.links = [self.row('hn', 'AXLink', 'Hacker News', 50, 90),
                      self.row('new', 'AXLink', 'new', 150, 30)]
        self.image = self.row('image', 'AXImage', 'logo', 200, 18)
        self.texts = [dict(row, id=row['id'] + '-text', role='AXStaticText') for row in self.links]
        self.nodes = [dict(id='root', role='AXApplication', children=[1]),
                      dict(id='web', role='AXWebArea', children=[2, 4, 6]),
                      dict(self.links[0], children=[3]), dict(self.texts[0], children=[]),
                      dict(self.links[1], children=[5]), dict(self.texts[1], children=[]),
                      dict(self.image, children=[])]

    @staticmethod
    def row(identifier, role, title, x, width):
        return dict(id=identifier, role=role, title=title,
                    position=dict(x=x, y=100), size=dict(width=width, height=20))

    def call(self, name, args):
        if name == 'list_apps':
            return dict(ok=True, apps=[dict(pid=42, bundleIdentifier='com.google.Chrome')])
        if name == 'list_windows':
            return dict(ok=True, windows=[dict(pid=42, window_id=7, x=0, y=0, width=800, height=600)])
        if name == 'get_ui_tree':
            return dict(ok=True, nodes=self.nodes)
        if name == 'find_elements':
            rows = self.links + self.texts + [self.image]
            return dict(ok=True, elements=[row for row in rows if row['role'] == args['role']])
        if name == 'element_at_point':
            self.hits += 1
            if self.hits == 1:
                return dict(ok=True, pid=42, role='AXWebArea', element_id='web', stable_id=True)
            row = next(row for row in self.texts + [self.image]
                       if row['position']['x'] <= args['x'] <= row['position']['x'] + row['size']['width'])
            return dict(ok=True, pid=42, role=row['role'], title=row['title'],
                        bounds=dict(row['position'], **row['size']), stable_id=not self.unstable,
                        element_id='unrelated' if self.unrelated else row['id'],
                        stable_id_strategy='top_down', stable_id_steps=['cf_equal'])
        raise AssertionError(name)

    def run(self, argv, **kwargs):
        self.hits = 0  # Each stock-probe invocation starts a new server.
        output = 'initialize: 1 ms, serverInfo={}\n'
        for name, args in json.loads(argv[-1]):
            elapsed = 41 if self.slow else 1
            output += f'--- {name} {json.dumps(args)} -> {elapsed} ms\n'
            output += json.dumps(self.call(name, args), indent=1) + '\n'
        return subprocess.CompletedProcess(argv, 0, stdout=output, stderr='')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def legacy_check(fixture):
    source = (ROOT / '.s1-evidence/reviewer/session.py').read_text()
    function = next(node for node in ast.parse(source).body
                    if isinstance(node, ast.FunctionDef) and node.name == 'check_chrome')
    namespace = dict(success=fixture.call, require=require, out=Path('/fake'), json=json,
                     attributes=lambda element_id: dict(values=dict(AXRole='AXStaticText')))
    exec(compile(ast.Module(body=[function], type_ignores=[]), 'session.py', 'exec'), namespace)
    with patch.object(Path, 'write_text'), contextlib.redirect_stdout(io.StringIO()):
        return namespace['check_chrome'](42)


def section8_check(fixture):
    doc = (ROOT / 'LIVE-CHECKS.md').read_text()
    marker = "cat > .s1-evidence/reviewer/a8-web/check.py <<'PY'\n"
    start = doc.index(marker) + len(marker)
    source = doc[start:doc.index('\nPY\n', start)]
    with patch.dict(os.environ, S1_SCRATCH='/fake'), patch('subprocess.run', fixture.run), \
         patch.object(Path, 'mkdir'), patch.object(Path, 'write_text'), contextlib.redirect_stdout(io.StringIO()):
        exec(compile(source, 'LIVE-CHECKS.md/check.py', 'exec'), {'__name__': '__main__'})


def round2_measure(fixture):
    doc = (ROOT / 'LIVE-CHECKS.md').read_text()
    marker = "cat > .s1-evidence/reviewer/r2-perf/measure.py <<'PY'\n"
    start = doc.index(marker) + len(marker)
    source = doc[start:doc.index('\nPY\n', start)]
    cases = []
    for row in fixture.texts * 3:
        cases.append(dict(args=dict(pid=42, x=row['position']['x'] + 2, y=110),
                          expected=dict(pid=42, role=row['role'], title=row['title'],
                                        bounds=dict(row['position'], **row['size']))))
    with patch.dict(os.environ, S1_SCRATCH='/fake'), patch.object(sys, 'argv', ['measure.py', '/fake', 'after']), \
         patch('subprocess.run', fixture.run), patch.object(Path, 'write_text'), \
         patch.object(Path, 'read_text', return_value=json.dumps(cases)), contextlib.redirect_stdout(io.StringIO()):
        exec(compile(source, 'LIVE-CHECKS.md/r2-measure.py', 'exec'), {'__name__': '__main__'})


class ChromeProbeTests(unittest.TestCase):
    def test_persistent_probe_accepts_static_text_child_after_warmup(self):
        identifier, _ = legacy_check(ChromeFixture())
        self.assertEqual(identifier, 'hn-text')

    def test_stock_probe_accepts_static_text_children_after_warmup(self):
        section8_check(ChromeFixture())

    def test_persistent_probe_rejects_unrelated_child_id(self):
        with self.assertRaises(RuntimeError):
            legacy_check(ChromeFixture(unrelated=True))

    def test_stock_probe_rejects_unrelated_child_id(self):
        with self.assertRaises(RuntimeError):
            section8_check(ChromeFixture(unrelated=True))

    def test_measure_accepts_warmed_static_text_reference(self):
        fixture = ChromeFixture()
        source = (ROOT / '.s1-evidence/reviewer/session.py').read_text()
        function = next(node for node in ast.parse(source).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'measure')

        def success(name, args):
            if name == 'get_element_attributes':
                return dict(ok=True, values=dict(AXRole='AXMenuItem'))
            if args.get('pid') == 7:
                return dict(ok=True, nodes_visited=2, elements=[dict(id='menu')])
            return fixture.call(name, args)

        namespace = dict(success=success, require=require, out=Path('/fake'), json=json,
                         Path=Path, os=os, statistics=statistics,
                         attributes=lambda identifier: dict(values=dict(AXRole='AXMenuItem')),
                         tool=lambda name, args: (success(name, args), 1.0))
        exec(compile(ast.Module(body=[function], type_ignores=[]), 'session.py', 'exec'), namespace)
        calls = json.dumps([['element_at_point', dict(pid=42, x=95, y=110)]])
        with patch.object(Path, 'read_text', return_value=calls), patch.object(Path, 'write_text'):
            namespace['measure'](7, 42)

    def test_round2_measure_accepts_six_warmed_child_cases(self):
        round2_measure(ChromeFixture())

    def test_round2_measure_rejects_unstable_identity(self):
        with self.assertRaisesRegex(AssertionError, 'FAIL A8'):
            round2_measure(ChromeFixture(unstable=True))

    def test_round2_measure_rejects_samples_over_40ms(self):
        with self.assertRaisesRegex(AssertionError, 'FAIL performance target'):
            round2_measure(ChromeFixture(slow=True))

    def test_stock_probe_rejects_unstable_child(self):
        with self.assertRaises(RuntimeError):
            section8_check(ChromeFixture(unstable=True))


if __name__ == '__main__':
    unittest.main(verbosity=2)
