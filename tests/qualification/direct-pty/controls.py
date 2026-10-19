#!/usr/bin/env python3
"""Real-artifact negative and signal controls; retain expected RED results."""
import argparse
import json
import os
import pathlib
import signal
import shutil
import subprocess
import sys
import time
from unittest.mock import patch

from matrix import HERE, inventory, worker


def absent(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def probe(binary, output, name):
    """Faults live only in the control interpreter, never production helpers."""
    import driver
    import scenarios
    import tmux_smoke
    owned = []
    original_init = scenarios.Fixture.__init__
    def remember(instance, *args):
        original_init(instance, *args)
        owned.append(instance)
    def signal_after(operation):
        def call(*args, **kwargs):
            value = operation(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGTERM)
            return value
        return call
    vector = next(row for row in inventory() if row["name"] == (
        "tmux-typing" if name.startswith("tmux-") else "typing"))
    with patch.object(scenarios.Fixture, "__init__", remember):
        if name == "provider-before-start":
            target = patch.object(scenarios.threading.Thread, "start", lambda self: os.kill(os.getpid(), signal.SIGTERM))
        elif name == "provider-after-start":
            target = patch.object(scenarios.threading.Thread, "start", signal_after(scenarios.threading.Thread.start))
        elif name == "host-after-start":
            target = patch.object(scenarios.model, "start_host", signal_after(scenarios.model.start_host))
        elif name == "pty-after-open":
            target = patch.object(driver, "open_pty", signal_after(driver.open_pty))
        elif name == "caller-after-launch":
            original = subprocess.Popen
            def launch(args, *rest, **kwargs):
                value = original(args, *rest, **kwargs)
                if args[1:3] == ["session", "resume"]:
                    os.kill(os.getpid(), signal.SIGTERM)
                return value
            target = patch.object(subprocess, "Popen", launch)
        elif name == "tmux-signal":
            original = tmux_smoke.Tmux.wait
            def ready(self, *args):
                original(self, *args)
                os.kill(os.getpid(), signal.SIGTERM)
            target = patch.object(tmux_smoke.Tmux, "wait", ready)
        elif name == "tmux-failed-disposal":
            vector["expected"] = "wrong tmux expectation"
            original = subprocess.run
            def fail(args, *rest, **kwargs):
                if "kill-server" in args:
                    return subprocess.CompletedProcess(args, 17, b"", b"injected kill-server failure")
                return original(args, *rest, **kwargs)
            target = patch.object(subprocess, "run", fail)
        else:
            raise ValueError(name)
        with target:
            code = worker(binary, output, vector)
    fixture = owned[0]
    pids = [process.pid for process in (fixture.host, fixture.tty.process if fixture.tty else None,
            fixture.tmux.server if fixture.tmux else None) if process is not None]
    if fixture.tmux:
        pids += [pid for pid in (fixture.tmux.pid, fixture.tmux.caller_pid) if pid is not None]
    (output / "probe-owners.json").write_text(json.dumps({"pids": pids, "root": str(fixture.root)}))
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--probe", help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    if args.probe:
        return probe(args.binary.resolve(), root, args.probe)
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
    navigation = []
    for name, source in (("wrong-arrow-distance", "key-up-csi"), ("wrong-wheel-distance", "wheel-alt-scroll"),
                         ("wrong-wheel-direction", "wheel-alt-scroll"), ("wrong-pgdn-distance", "key-pgdn"),
                         ("wrong-arrow-overshoot", "key-up-csi"), ("wrong-wheel-overshoot", "wheel-alt-scroll"),
                         ("wrong-page-overshoot", "key-pgup")):
        vector = next(row for row in inventory() if row["name"] == source)
        vector["name"] = name
        if name == "wrong-arrow-distance":
            vector["chunks"] = [{"hex": b"\x1b[5~".hex()}]
        elif name == "wrong-wheel-distance":
            vector["chunks"] = [{"hex": (b"\x1b[5~" * 3).hex()}]
            vector["return_chunks"] = [{"hex": (b"\x1b[6~" * 3).hex()}]
        elif name == "wrong-arrow-overshoot":
            vector["chunks"] = [{"hex": b"\x1b[A".hex()}, {"hex": b"\x1b[A".hex(), "delay_before": 0.05}]
        elif name == "wrong-wheel-overshoot":
            vector["chunks"] = [{"hex": (b"\x1b[A" * 3).hex()}, {"hex": (b"\x1b[A" * 3).hex(), "delay_before": 0.05}]
            vector["return_chunks"] = [{"hex": (b"\x1b[B" * 6).hex()}]
        elif name == "wrong-page-overshoot":
            vector["chunks"] = [{"hex": b"\x1b[5~".hex()}, {"hex": b"\x1b[5~".hex(), "delay_before": 0.05}]
        else:
            vector["middle"][0]["chunks"] = [{"hex": (b"\x1b[A" if source == "wheel-alt-scroll" else b"\x1b[B").hex()}]
        navigation.append(vector)
    vectors = root / "navigation-negative.json"
    vectors.write_text(json.dumps(navigation))
    with open(root / "navigation-negative.log", "wb") as log:
        wrong = subprocess.run([*command, "--jobs", "4", "--output", str(root / "navigation-negative"), "--vectors", str(vectors)],
                               stdout=log, stderr=subprocess.STDOUT, timeout=30)
    assert wrong.returncode == 1, "wrong navigation movement accepted"
    for vector in navigation:
        output = root / "navigation-negative" / vector["name"]
        result = json.loads((output / "result.json").read_text())
        assert result["status"] == "assertion" and "navigation history anchor/distance" in result["error"], result
        assert all(json.loads((output / "cleanup.json").read_text()).values()), "navigation control leaked owners"
        print(f"{vector['name']}: expected RED at exact history anchor/distance", flush=True)
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
    for name in ("provider-before-start", "provider-after-start", "host-after-start", "pty-after-open",
                 "caller-after-launch", "tmux-signal", "tmux-failed-disposal"):
        output = root / name
        with open(root / f"{name}.log", "wb") as log:
            result = subprocess.run([sys.executable, str(__file__), str(args.binary.resolve()),
                "--output", str(output), "--probe", name], stdout=log, stderr=subprocess.STDOUT, timeout=20)
        facts = json.loads((output / "result.json").read_text())
        owners = json.loads((output / "probe-owners.json").read_text())
        assert all(absent(pid) for pid in owners["pids"]), (name, "owned process survived", owners)
        if name == "tmux-failed-disposal":
            assert result.returncode == 1 and facts["status"] == "assertion", facts
            assert "exact submitted Message bytes" in facts["error"], facts
            assert "kill-server" in facts["traceback"], facts
            assert not (output / "cleanup.json").exists(), "failed disposal claimed success"
            assert pathlib.Path(owners["root"]).exists(), "failed disposal deleted its control root"
            shutil.rmtree(owners["root"])  # All owners independently proven absent above.
        else:
            assert result.returncode == 143 and facts["status"] == "interrupted", facts
            assert (output / "cleanup.json").exists(), (name, "missing cleanup receipt")
            assert not pathlib.Path(owners["root"]).exists(), (name, "root survived")
        print(f"{name}: expected failure retained; no owned survivors", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
