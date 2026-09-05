#!/usr/bin/env python3
"""Throwaway macOS probe. All load-generation memory is outside the measured PID."""
import concurrent.futures as cf
import json
import pathlib
import socket
import statistics
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
BIN = "/tmp/onepage-http-probe"
subprocess.run(["zig", "build-obj", str(ROOT / "parser.zig"), "-O", "ReleaseFast", "-femit-bin=/tmp/onepage-http-parser.o"], check=True)
subprocess.run(["clang", "-O2", "-Wall", "-Wextra", "-mmacosx-version-min=15.7", str(ROOT / "probe.c"), "/tmp/onepage-http-parser.o", "-o", BIN], check=True)

class Probe:
    def __init__(self, baseline=False, reuse=False):
        self.p = subprocess.Popen([BIN, "baseline" if baseline else "reuse" if reuse else "http"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.port = int(self.p.stdout.readline())
        self.sample()  # Warm the measurement path, identically in every process.
    def sample(self):
        self.p.stdin.write("s"); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def connect(self):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        return s
    def close(self):
        self.p.stdin.write("q"); self.p.stdin.flush(); self.p.wait(timeout=10)
        assert self.p.returncode == 0

results = []
def record(name, samples, **extra):
    result = dict(case=name, median_physical=statistics.median(x["physical"] for x in samples),
                  peak_physical=max(x["physical"] for x in samples), peak_rss=max(x["rss"] for x in samples),
                  max_threads=max(x["threads"] for x in samples), final=samples[-1], **extra)
    results.append(result)
    print(json.dumps(result), flush=True)

cases = ["baseline", "listener", "clients1", "clients16", "clients100"]
for rotation in range(5):
    for name in cases[rotation:] + cases[:rotation]:
        p = Probe(name == "baseline")
        sockets = []
        try:
            count = int(name[7:]) if name.startswith("clients") else 0
            for _ in range(count):
                s = p.connect(); s.sendall(b"GET /status HTTP/1.1\r\nX-Slow: "); sockets.append(s)
            deadline = time.monotonic() + 5
            while p.sample()["active"] != count:
                assert time.monotonic() < deadline
                time.sleep(.01)
            samples = []
            for _ in range(8):
                time.sleep(.05); samples.append(p.sample())
            record(name, samples, rotation=rotation)
        finally:
            for s in sockets: s.close()
            p.close()

def request(p, mode):
    with p.connect() as s:
        size = 32 * 1024 * 1024
        if mode == "upload":
            s.sendall(f"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: {size}\r\n\r\n".encode())
            for _ in range(size // 8192):
                s.sendall(b"x" * 8192); time.sleep(.0005)
        else:
            path = "/large" if mode == "download" else "/status"
            s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
        initial = b""
        while b"\r\n\r\n" not in initial: initial += s.recv(8192)
        head, body = initial.split(b"\r\n\r\n", 1)
        assert head.startswith(b"HTTP/1.1 200 OK")
        expected = size if mode == "download" else 2
        assert f"Content-Length: {expected}".encode() in head
        assert body == b"x" * len(body)
        received = len(body)
        while True:
            data = s.recv(8192)
            if not data: break
            assert data == b"x" * len(data)
            received += len(data)
            if mode == "download": time.sleep(.0005)
        assert received == expected, (received, expected)

for mode, count, total in [("status", 16, 2000), ("upload", 16, 16), ("download", 16, 16)]:
    for repetition in range(3):
        p = Probe()
        try:
            before = p.sample()
            samples = []
            start = time.monotonic()
            with cf.ThreadPoolExecutor(max_workers=count) as pool:
                jobs = [pool.submit(request, p, mode) for _ in range(total)]
                while not all(f.done() for f in jobs):
                    samples.append(p.sample()); time.sleep(.02)
                for f in jobs: f.result()
            elapsed = time.monotonic() - start
            time.sleep(.1); after = p.sample(); samples.append(after)
            assert after["completed"] == total
            record(mode, samples, repetition=repetition, seconds=elapsed, before=before, after=after)
        finally:
            p.close()

# Check hard admission and header bounds, independently from capacity runs.
p = Probe()
sockets = []
try:
    for _ in range(100): sockets.append(p.connect())
    deadline = time.monotonic() + 5
    while p.sample()["active"] != 100:
        assert time.monotonic() < deadline; time.sleep(.01)
    with p.connect() as extra: assert extra.recv(1) == b""
    assert p.sample()["rejected"] == 1
    for s in sockets: s.close()
    sockets = []
    deadline = time.monotonic() + 5
    while p.sample()["active"]:
        assert time.monotonic() < deadline; time.sleep(.01)
    with p.connect() as s:
        s.sendall(b"GET / HTTP/1.1\r\nX: " + b"x" * 8192)
        try: assert s.recv(1) == b""
        except ConnectionResetError: pass
finally:
    for s in sockets: s.close()
    p.close()

for reuse in [False, True]:
    p = Probe(reuse=reuse)
    try:
        for batch in range(10):
            samples = []
            with cf.ThreadPoolExecutor(max_workers=16) as pool:
                jobs = [pool.submit(request, p, "status") for _ in range(2000)]
                while not all(f.done() for f in jobs):
                    samples.append(p.sample()); time.sleep(.02)
                for f in jobs: f.result()
            time.sleep(.1); samples.append(p.sample())
            assert samples[-1]["completed"] == (batch+1)*2000
            record("churn_reuse" if reuse else "churn_malloc", samples, batch=batch)
    finally:
        p.close()

(ROOT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print("All response lengths, byte contents, completion counts, connection cap and header cap checks passed.")
