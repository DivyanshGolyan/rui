#!/usr/bin/env python3
"""Draft/loan owner with real Client captures and two offline protected Hosts."""

import hashlib
import json
import os
import pathlib
import select
import subprocess
import sys
import tempfile
import time

from control_integration import configure, observe, start_host
from host_process import HostDiagnostics, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
CLIENT = pathlib.Path(sys.argv[2]).resolve()


def boundary(process, deadline):
    line = bytearray()
    while not line.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], "native input deadline"
        chunk = os.read(process.stdout.fileno(), 1024)
        if not chunk:
            output, errors = process.communicate(timeout=max(0, deadline - time.monotonic()))
            raise AssertionError(("native input EOF", process.returncode, output, errors))
        line.extend(chunk)
        assert len(line) <= 1024, line
    return line.decode()


def resources(pid):
    if sys.platform != "linux":
        return None  # Native Mac resources need their own counters/receipt.
    lines = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
    fields = {line.split(":", 1)[0]: line.split(":", 1)[1].strip() for line in lines}
    fds = {entry.name: os.readlink(entry) for entry in pathlib.Path(f"/proc/{pid}/fd").iterdir()}
    return {"rss_kib": int(fields["VmRSS"].split()[0]), "peak_rss_kib": int(fields["VmHWM"].split()[0]), "fds": fds}


def main():
    with tempfile.TemporaryDirectory(prefix="rui-input-") as temporary:
        root = pathlib.Path(temporary)
        records = root / "records"
        records.mkdir(mode=0o700)
        (records / "blocked").mkdir(mode=0o755)
        stores = [root / "first", root / "second"]
        hosts, diagnostics = [], []
        try:
            for store, session in zip(stores, ("opening/original", "selected/later")):
                store.mkdir(mode=0o700)
                host, _ = start_host(store)
                hosts.append(host)
                diagnostics.append(HostDiagnostics(host))
                configure(records, store, f"configure-{store.name}", session)
            deadline = time.monotonic() + 10
            native = subprocess.Popen([CLIENT, *stores, records], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                assert boundary(native, deadline) == "input-baseline\n"
                baseline = resources(native.pid)
                native.stdin.write(b"x")
                native.stdin.flush()
                result = boundary(native, deadline)
                retained = resources(native.pid)
                native.stdin.write(b"x")
                native.stdin.flush()
                output, errors = native.communicate(timeout=max(0, deadline - time.monotonic()))
                assert native.returncode == 0 and not output, (native.returncode, output, errors)
                if baseline:
                    assert retained["fds"] == baseline["fds"], (baseline, retained)
            finally:
                stop_process(native)
            expected = {
                "01234567-89ab-4cde-8fab-0123456789ab": (0, "opening/original", "published", "accepted"),
                "original": (0, "opening/original", "aéZ", "accepted"),
                "next": (1, "selected/later", "next!", "accepted"),
                "restore": (0, "missing", "badé!", "rejected"),
                "retain": (0, "missing", "badé!", "rejected"),
                "complete": (0, "opening/original", "x" * 65_532 + "\nµZ", "accepted"),
            }
            for key, (index, session, text, status) in expected.items():
                record = json.loads((records / f"{key}.json").read_bytes())
                assert record == {"version": "1", "kind": "message", "store": str(stores[index]), "key": key, "session": session,
                                  "text": {"state": "value", "value": text}}, record
                observation = observe(stores[index], key)
                assert observation["status"] == status and observation["target"] == session, observation
                if status == "accepted":
                    encoded = text.encode()
                    domain = b"rui/content/v1"
                    digest = hashlib.sha256(len(domain).to_bytes(8, "big") + domain + encoded).hexdigest()
                    assert observation["input"] == {"type": "text", "bytes": str(len(encoded)), "sha256": digest}, observation
                    assert observation["queue"]["status"] == "queued", observation
                assert observe(stores[1 - index], key)["status"] == "absent"
            assert sorted(path.stem for path in records.glob("*.json")) == sorted([*expected, "configure-first", "configure-second"])
            assert not list((records / "blocked").glob("*.json"))
            for store in stores:
                assert not list((store / "scratch").iterdir()), store
            print(result.strip())
            print(f"Native input caller baseline→retained (RSS is not allocator/physical/aggregate): {baseline}→{retained}")
            print("Session input public proof: exact six records/targets/domain digests, absent foreign-store keys, queued admissions, explicit post-publication recovery, no automatic recapture or scratch")
        finally:
            for host, diagnostic in zip(hosts, diagnostics):
                if host.poll() is None:
                    host.kill()
                host.wait(timeout=10)
                diagnostic.close()
                stop_process(host)


if __name__ == "__main__":
    main()
