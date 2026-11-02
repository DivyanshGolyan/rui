#!/usr/bin/env python3
"""Idle Host memory of two rui binaries, alternating: idle.py BEFORE AFTER [ROUNDS].

Run `sync` first: a freshly built binary's code pages count as private dirty
until the kernel writes the file back.
"""
import os
import statistics
import subprocess
import sys
import tempfile
import time

FIELDS = ("Rss", "Pss", "Private_Dirty", "Anonymous")


def sample(binary):
    with tempfile.TemporaryDirectory() as home:
        host = subprocess.Popen([binary, "host", "serve", "--store", home + "/store"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                env=dict(os.environ, HOME=home))
        try:
            time.sleep(3)
            if host.poll() is not None:
                raise SystemExit(f"{binary} exited {host.returncode}: {host.stderr.read()[:300]!r}")
            with open(f"/proc/{host.pid}/smaps_rollup") as rollup:
                lines = (line.partition(":") for line in rollup)
                return {key: int(value.split()[0]) for key, _, value in lines if key in FIELDS}
        finally:
            host.terminate()
            host.wait()


def main():
    binaries = {"before": sys.argv[1], "after": sys.argv[2]}
    rounds = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    samples = {name: [] for name in binaries}
    for _ in range(rounds):
        for name, binary in binaries.items():
            samples[name].append(sample(binary))
    for name, rows in samples.items():
        summary = ", ".join(f"{key} {statistics.median(r[key] for r in rows)} "
                            f"({min(r[key] for r in rows)} to {max(r[key] for r in rows)})" for key in FIELDS)
        print(f"{name} KiB median (range): {summary}")


if __name__ == "__main__":
    main()
