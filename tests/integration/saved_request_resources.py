#!/usr/bin/env python3
"""Comparable Linux CLI-only capture/retained-reader observations, not qualification.

Usage: python3 tests/integration/saved_request_resources.py BASELINE CANDIDATE
Both executables should be uninstrumented ReleaseSafe builds. The unchanged
baseline Host serves the same Store to both PTYs; no provider work is submitted.
"""
import hashlib
import json
import os
import pathlib
import pty
import subprocess
import sys
import tempfile

import human_cli_integration as cli
from host_process import start_ready_process, stop_process


def sample(pid):
    root = pathlib.Path(f"/proc/{pid}")
    fields = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines())
    return {"rss_kib": int(fields["VmRSS"].split()[0]),
        "peak_kib": int(fields["VmHWM"].split()[0]), "fds": len(list((root / "fd").iterdir()))}


def capture(state, binary, label, size, repetition):
    home = state / f"{label}-{size}-{repetition}"
    home.mkdir()
    source = state / "input"
    with source.open("wb") as output:
        for offset in range(0, size, 4096):
            output.write(b"x" * min(4096, size - offset))
    gate = home / "gate"
    process = subprocess.Popen([str(binary), "message", "--store", str(state / "offline-store"),
        "--session", "resources/original", "--text", str(source), "--json"],
        env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        cli.fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "resource capture publication")
        observation = sample(process.pid)
        pathlib.Path(f"{gate}.release").touch()
        output, errors = process.communicate(timeout=20)
        assert process.returncode != 0 and "FileNotFound" in errors, (output, errors)
        handle = json.loads(output)["request"]
        record = home / ".config/rui/requests" / f"{handle}.json"
        expected = hashlib.sha256()
        prefix = ('{"version":"1","kind":"message","store":' + json.dumps(str((state / "offline-store").resolve()))
            + ',"key":' + json.dumps(handle) + ',"session":"resources/original","text":{"state":"value","value":"').encode()
        expected.update(prefix)
        for offset in range(0, size, 4096):
            expected.update(b"x" * min(4096, size - offset))
        expected.update(b'"}}')
        actual = hashlib.sha256()
        with record.open("rb") as saved:
            while chunk := saved.read(4096):
                actual.update(chunk)
        assert actual.digest() == expected.digest(), "captured byte integrity"
        assert record.stat().st_size == len(prefix) + size + 3
        return {"binary": label, "payload_bytes": size, "repetition": repetition, **observation}
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)


def retained(state, binary, label):
    home = state / f"{label}-session"
    records = home / ".config/rui/requests"
    records.mkdir(parents=True, mode=0o700)
    for number in range(100):
        (records / f"01234567-89ab-4cde-8012-{number:012x}.json").write_text("invalid but enumerable")
    master, slave = pty.openpty()
    process = subprocess.Popen([str(binary), "session", "--store", str(state / "live-store"),
        "--session", "resources/original"], env={**os.environ, "HOME": str(home)},
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        cli.read_terminal(master, "rui> ")
        samples = [sample(process.pid)]
        for _ in range(3):
            for _ in range(10):
                assert "Configured." in cli.terminal_step(master, "/configure --model model-a")
                listing = cli.terminal_step(master, "/requests")
                assert "01234567-89ab-4cde-8012-" not in listing
                cli.terminal_step(master, "/status")
            samples.append(sample(process.pid))
        cli.terminal_step(master, "/exit", "Detached.")
        assert process.wait(timeout=5) == 0
        assert all(value["fds"] == 3 for value in samples), samples
        return {"binary": label, "retained_samples": samples, "configuration_cycles": 30, "invalid_records": 100}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)


def main():
    if sys.platform != "linux":
        raise SystemExit("This diagnostic needs Linux /proc; macOS footprint is not measured here")
    baseline, candidate = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])
    with tempfile.TemporaryDirectory(prefix="rui-saved-resources.") as temporary:
        state = pathlib.Path(temporary)
        (state / "offline-store").mkdir(mode=0o700)
        for size in (1, 100_000, 32 * 1024 * 1024):
            for repetition in range(3):
                for label, binary in (("baseline", baseline), ("candidate", candidate)):
                    print(json.dumps(capture(state, binary, label, size, repetition)), flush=True)
        host, _ = start_ready_process([baseline, "serve", "--store", state / "live-store", "--active-capacity", "1"])
        try:
            cli.fixture.RUI = baseline
            cli.fixture.command("configure", "--store", state / "live-store", "--session", "resources/original",
                "--record", state / "configure-record", "--key", "resources-configure",
                "--workspace", state, "--provider", "codex", "--model", "model-a")
            for label, binary in (("baseline", baseline), ("candidate", candidate)):
                print(json.dumps(retained(state, binary, label)), flush=True)
        finally:
            stop_process(host)


if __name__ == "__main__":
    main()
