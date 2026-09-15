"""v0.10 B7: validate the reviewer probe against a fake NDJSON process."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROBE = Path(__file__).with_name("s2_concurrency.py")
FAKE_SERVER = '''import json, os, sys
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        result = {"serverInfo": {"name": "s2-fixture", "version": "test"}}
    else:
        mode = os.environ.get("S2_FAKE_MODE", "valid")
        if mode == "eof":
            sys.exit(0)
        nodes = [] if mode == "empty" else [{"role": "AXApplication"}, {"role": "AXWindow"}]
        result = {"structuredContent": {"ok": True, "count": len(nodes), "nodes": nodes}}
        if mode == "error":
            result["isError"] = True
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
'''


class S2ConcurrencyTests(unittest.TestCase):
    def run_probe(self, pids="101,102,103", mode="valid", extra=()):
        with tempfile.TemporaryDirectory(prefix="s2-ndjson-fixture-") as directory:
            server = Path(directory, "server")
            server.write_text(f"#!{sys.executable}\n{FAKE_SERVER}")
            server.chmod(0o700)
            return subprocess.run(
                [sys.executable, str(PROBE), str(server), pids, "1", *extra],
                env={**os.environ, "S2_FAKE_MODE": mode},
                capture_output=True, text=True, timeout=10,
            )

    def test_three_distinct_pids_are_validated(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("measurement_valid=True", result.stdout)

    def test_same_pid_mode_runs_three_serialized_requests(self):
        result = self.run_probe("101,101,101", extra=("--same-pid",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mode=same-pid", result.stdout)
        self.assertIn("measurement_valid=True", result.stdout)

    def test_same_pid_mode_rejects_different_pids(self):
        result = self.run_probe(extra=("--same-pid",))
        self.assertNotEqual(result.returncode, 0)

    def test_empty_tree_samples_fail_the_probe(self):
        result = self.run_probe(mode="empty")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("measurement_valid=False", result.stdout)

    def test_error_samples_fail_even_if_the_payload_has_a_window(self):
        result = self.run_probe(mode="error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("measurement_valid=False", result.stdout)

    def test_server_exit_is_an_error_and_does_not_hang(self):
        result = self.run_probe(mode="eof")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EOFError", result.stderr)


if __name__ == "__main__":
    unittest.main()
