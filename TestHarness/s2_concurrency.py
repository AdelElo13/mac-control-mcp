#!/usr/bin/env python3
"""Three-app NDJSON experiment based on SCRATCH/conc.py.
Usage: s2_concurrency.py BINARY PID1,PID2,PID3 [RUNS=7] [--same-pid]
Every warm/timed response must contain an AXWindow to count as valid.
"""
import argparse
import json
import os
import select
import statistics
import subprocess
import time


class Server:
    def __init__(self, binary):
        self.process = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.buffer = b""
        self.next_id = 1
        self.pending = {}

    def send(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()
        return request_id

    def receive(self, request_id, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if "id" in message:
                    self.pending[message["id"]] = message
            if request_id in self.pending:
                return self.pending.pop(request_id)
            ready, _, _ = select.select(
                [self.process.stdout], [], [], max(0, deadline - time.monotonic()),
            )
            if ready:
                chunk = os.read(self.process.stdout.fileno(), 1 << 22)
                if not chunk:
                    raise EOFError(f"Server closed stdout before response {request_id}")
                self.buffer += chunk
        raise TimeoutError(request_id)

    def tree_request(self, pid):
        return self.send("tools/call", {
            "name": "get_ui_tree", "arguments": {"pid": pid},
        })

    def tree(self, pid):
        started = time.perf_counter()
        response = self.receive(self.tree_request(pid))
        return (time.perf_counter() - started) * 1000, response

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def has_window(response):
    result = response.get("result", {})
    payload = result.get("structuredContent", {})
    return (
        "error" not in response and not result.get("isError", False)
        and payload.get("ok") is True
        and any(node.get("role") == "AXWindow" for node in payload.get("nodes", []))
    )


def median(values):
    return round(statistics.median(values), 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("pids")
    parser.add_argument("runs", type=int, nargs="?", default=7)
    parser.add_argument("--same-pid", action="store_true")
    args = parser.parse_args()
    pids = [int(pid) for pid in args.pids.split(",")]
    unique_count = 1 if args.same_pid else 3
    if len(pids) != 3 or len(set(pids)) != unique_count or min(pids) <= 0:
        parser.error("Require three positive PIDs: identical with --same-pid, otherwise distinct")
    runs = args.runs
    if runs < 1:
        parser.error("RUNS must be positive")
    print(f"mode={'same-pid' if args.same_pid else 'three-app'}")
    server = Server(args.binary)
    valid = True
    try:
        server.receive(server.send("initialize", {}))
        per_app = []
        for pid in pids:
            _, warm = server.tree(pid)
            valid &= has_window(warm)
            samples = []
            for _ in range(runs):
                milliseconds, response = server.tree(pid)
                samples.append(milliseconds)
                valid &= has_window(response)
            per_app.append(median(samples))
            print(f"pid={pid} p50={median(samples)} ms has_AXWindow={has_window(warm)}")
        sequential = []
        for _ in range(runs):
            started = time.perf_counter()
            for pid in pids:
                _, response = server.tree(pid)
                valid &= has_window(response)
            sequential.append((time.perf_counter() - started) * 1000)
        concurrent = []
        for _ in range(runs):
            started = time.perf_counter()
            deadline = time.monotonic() + 20
            requests = [server.tree_request(pid) for pid in pids]
            for request_id in requests:
                response = server.receive(request_id, timeout=max(0, deadline - time.monotonic()))
                valid &= has_window(response)
            concurrent.append((time.perf_counter() - started) * 1000)
        print(f"runs={runs}, sequential_3app_p50={median(sequential)} ms, concurrent_3app_p50={median(concurrent)} ms")
        print(f"sum_app_p50={sum(per_app):.1f} ms, max_app_p50={max(per_app):.1f} ms")
        print(f"measurement_valid={valid}; every response must contain an AXWindow")
    finally:
        server.close()
    # v0.10 B7: failed AX reads must never masquerade as fast measurements.
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
