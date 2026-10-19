#!/usr/bin/env python3
"""Real-artifact negative and signal controls; retain expected RED results."""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

from matrix import HERE, inventory


def absent(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    vector = next(row for row in inventory() if row["name"] == "typing")
    vector["name"] = "wrong-exact-bytes"
    vector["expected"] = "A中é?"
    vectors = root / "negative.json"
    vectors.write_text(json.dumps([vector]))
    command = [sys.executable, str(HERE / "matrix.py"), str(args.binary.resolve()), "--jobs", "1"]
    with open(root / "negative.log", "wb") as log:
        wrong = subprocess.run([*command, "--output", str(root / "negative"), "--vectors", str(vectors)],
                               stdout=log, stderr=subprocess.STDOUT, timeout=30)
    result = json.loads((root / "negative/wrong-exact-bytes/result.json").read_text())
    assert wrong.returncode == 1 and result["status"] == "assertion", result
    assert "exact submitted Message bytes" in result["error"], result
    assert (root / "negative/wrong-exact-bytes/cleanup.json").exists(), "negative assertion leaked owners"
    print("wrong exact bytes: expected RED at submitted-Message assertion", flush=True)
    for number in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
        name = signal.Signals(number).name
        vector = {"name": "held-input", "scenario": "editor", "expected": "late",
                  "chunks": [{"hex": b"late\r".hex(), "delay_before": 30}]}
        vectors = root / f"{name}.json"
        vectors.write_text(json.dumps([vector]))
        output = root / name
        with open(root / f"{name}.log", "wb") as log:
            controller = subprocess.Popen([*command, "--output", str(output), "--vectors", str(vectors)],
                                          stdout=log, stderr=subprocess.STDOUT)
            try:
                events = output / "held-input/events.jsonl"
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if events.exists() and '"event": "observed"' in events.read_text():
                        break
                    assert controller.poll() is None, f"{name} setup exited before readiness"
                    time.sleep(0.02)
                else:
                    raise TimeoutError(f"{name} fixture did not reach owned caller readiness")
                ownership = json.loads((output / "held-input/ownership.json").read_text())
                records = [json.loads(line) for line in events.read_text().splitlines()]
                caller_pid = next(record["pid"] for record in records if record["event"] == "launch")
                controller.send_signal(number)
                assert controller.wait(timeout=15) == 128 + number, f"{name} signal status lost"
            finally:
                if controller.poll() is None:
                    controller.terminate()
                    controller.wait(timeout=15)
        result = json.loads((output / "held-input/result.json").read_text())
        assert result["status"] == "interrupted", result
        assert absent(ownership["host_pid"]) and absent(caller_pid), f"{name} owned process survived"
        assert not pathlib.Path(ownership["root"]).exists(), f"{name} private root survived"
        assert (output / "held-input/cleanup.json").exists(), f"{name} disposal incomplete"
        print(f"{name}: exit {128 + number}; Host/caller reaped; private HOME/Store removed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
