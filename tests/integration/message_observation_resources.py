#!/usr/bin/env python3
"""Linux CLI-only observation diagnostic, not Host or release qualification.

Usage: python3 tests/integration/message_observation_resources.py BASELINE CANDIDATE
Use uninstrumented ReleaseSafe binaries. One baseline Host supplies the same
failed Message and held in-flight Message to both clients. No live provider.
"""
import hashlib
import json
import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile
import threading

import human_cli_integration as cli
from host_process import start_ready_process, stop_process
from saved_request_resources import resource_first, sample


def retained(state, binary, label, repetition, failed_key):
    home = state / f"{label}-{repetition}"
    home.mkdir()
    master, slave = pty.openpty()
    current = resource_first(binary)
    process = subprocess.Popen([str(binary), "session", *(["resume"] if current else []), "--store", str(state / "store"),
        "--session", "resources/message"], env={**os.environ, "HOME": str(home)},
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        prompt = "› " if current else os.environ.get("RUI_BASELINE_PROMPT", "rui> ")
        cli.read_terminal(master, prompt)
        samples = [sample(process.pid)]
        for _ in range(4):
            for _ in range(25):
                result = cli.terminal_step(master, f"/result {failed_key}", prompt)
                assert ("This saved Message failed" in result or "result: failed" in result) and "provider_http_422" in result, result
            samples.append(sample(process.pid))
        cli.terminal_step(master, "/exit", "Detached.")
        assert process.wait(timeout=5) == 0
        # Stdio plus the frontend's descriptor-owned render scratch; polling
        # owns at most one transient socket, never another retained reader.
        assert samples[0]["retained_fds"] in (3, 4), samples
        assert all(value["retained_fds"] == samples[0]["retained_fds"] and value["sockets"] <= 1 for value in samples), samples
        return {"binary": label, "repetition": repetition, "result_reads": 100, "samples": samples}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)


def held(state, binary, label, handle):
    if resource_first(binary):
        # The removed follow snapshot has no current equivalent. Measure the
        # completed one-shot owner explicitly, not a fabricated reply waiter.
        ready_read, ready_write = os.pipe()
        release_read, release_write = os.pipe()
        process = None
        try:
            process = subprocess.Popen([str(binary), "request", "inspect", handle],
                env={**os.environ, "HOME": str(state / "capture-home"),
                    "RUI_TEST_POST_COMMAND_READY_FD": str(ready_write),
                    "RUI_TEST_POST_COMMAND_RELEASE_FD": str(release_read)},
                pass_fds=(ready_write, release_read), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert select.select([ready_read], [], [], 5)[0], "one-shot inspection did not finish"
            assert os.read(ready_read, 1) == b"\x01"
            measured = sample(process.pid)
            assert measured["fds"] == 5, measured  # stdio plus two diagnostic hold descriptors.
            os.write(release_write, b"\x01")
            output, errors = process.communicate(timeout=5)
            assert process.returncode == 0 and not errors, (output, errors)
            observation = json.loads(output)["observation"]
            assert observation["status"] == "accepted" and observation.get("result") is None, observation
            return {"binary": label, "completed_one_shot": measured, "diagnostic_hold_fds": 2}
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            for fd in (ready_read, ready_write, release_read, release_write):
                os.close(fd)
    gate = state / f"{label}-gate"
    process = subprocess.Popen([str(binary), "follow", handle, "--json"],
        env={**os.environ, "HOME": str(state / "capture-home"), "RUI_TEST_FOLLOW_GATE": str(gate)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        cli.fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "decoded observation held")
        measured = sample(process.pid)
        assert measured["fds"] == 3, measured
        return {"binary": label, "decoded_snapshot": measured}
    finally:
        process.kill()
        process.communicate(timeout=5)


def main():
    if sys.platform != "linux":
        raise SystemExit("This diagnostic needs Linux /proc; macOS footprint is not measured")
    baseline, candidate = (pathlib.Path(value).resolve() for value in sys.argv[1:3])
    for label, binary in (("baseline", baseline), ("candidate", candidate)):
        with binary.open("rb") as executable:
            print(json.dumps({"binary": label, "sha256": hashlib.file_digest(executable, "sha256").hexdigest()}), flush=True)
    cli.fixture.RUI = candidate
    release = threading.Event()
    endpoint = cli.fixture.SuccessEndpoint([
        cli.fixture.ResponseSpec(b"permanent failure", {}, 422),
        (cli.fixture.sse_answer("held-answer", "held-reason", "held-message", "done")[0], release),
    ])
    threading.Thread(target=endpoint.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="rui-message-resources.") as temporary:
            state = pathlib.Path(temporary)
            home = state / "capture-home"
            home.mkdir()
            host, _ = start_ready_process([baseline, *(["host"] if resource_first(baseline) else []), "serve", "--store", state / "store",
                "--active-capacity", "1", "--provider-endpoint", f"http://127.0.0.1:{endpoint.server_port}/responses"])
            try:
                cli.run(home, "session", "configure", "--store", state / "store", "--session", "resources/message",
                    "--workspace", state, "--provider", "codex", "--model", "model-a")
                failed = cli.admit(home, "session", "send", "--store", state / "store", "--session", "resources/message", "fail")["context"]["key"]
                cli.fixture.wait_for(lambda: cli.fixture.command("request", "inspect", "--store", state / "store",
                    "--key", failed)["observation"].get("result"), "saved failure")
                for repetition in range(3):
                    for label, binary in (("baseline", baseline), ("candidate", candidate)):
                        print(json.dumps(retained(state, binary, label, repetition, failed)), flush=True)
                pending = cli.admit(home, "session", "send", "--store", state / "store", "--session", "resources/message", "hold")["context"]["key"]
                cli.fixture.wait_for(lambda: len(endpoint.requests) == 2, "held provider request")
                for label, binary in (("baseline", baseline), ("candidate", candidate)):
                    print(json.dumps(held(state, binary, label, pending)), flush=True)
                release.set()
                cli.fixture.wait_for(lambda: cli.fixture.completed_observation(state / "store", pending), "work survives detached readers")
            finally:
                release.set()
                stop_process(host)
    finally:
        release.set()
        endpoint.shutdown()
        endpoint.server_close()


if __name__ == "__main__":
    main()
