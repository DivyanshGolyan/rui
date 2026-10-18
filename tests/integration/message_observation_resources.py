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
import subprocess
import sys
import tempfile
import threading

import human_cli_integration as cli
from host_process import start_ready_process, stop_process
from saved_request_resources import sample


def retained(state, binary, label, repetition, failed_key):
    home = state / f"{label}-{repetition}"
    home.mkdir()
    master, slave = pty.openpty()
    # Keep the historical baseline's original entry; migrate only the candidate.
    entry = (["session", "--store", str(state / "store"), "--session", "resources/message"]
        if label == "baseline" else ["session", "resume", "--store", str(state / "store"), "--", "resources/message"])
    process = subprocess.Popen([str(binary), *entry], env={**os.environ, "HOME": str(home)},
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        prompt = "rui> " if label == "baseline" else "› "
        cli.read_terminal(master, prompt)
        samples = [sample(process.pid)]
        for _ in range(4):
            for _ in range(25):
                result = cli.terminal_step(master, f"/result {failed_key}",
                    prompt if label == "baseline" else "result: failed", composer=label != "baseline")
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
    if label == "baseline":
        # The historical baseline holds its decoded follow snapshot at a gate.
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
    # The candidate observes once. Hold it after its decoded observation is
    # written: it may own only stdio plus the two hold descriptors.
    release_read, release_write = os.pipe()
    ready_read, ready_write = os.pipe()
    process = subprocess.Popen([str(binary), "request", "inspect", handle],
        env={**os.environ, "HOME": str(state / "capture-home"),
            "RUI_TEST_POST_COMMAND_RELEASE_FD": str(release_read), "RUI_TEST_POST_COMMAND_READY_FD": str(ready_write)},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(release_read, ready_write))
    os.close(release_read)
    os.close(ready_write)
    try:
        assert os.read(ready_read, 1) == b"\x01", "decoded observation held"
        measured = sample(process.pid)
        assert measured["fds"] == 5 and measured["sockets"] == 0, measured
        os.write(release_write, b"\x01")
        output, errors = process.communicate(timeout=5)
        assert process.returncode == 0, (output, errors)
        reply = json.loads(output)
        observation = reply["observation"]
        assert reply["key"] == handle and observation["progress"]["status"] == "in_flight", reply
        assert "result" not in observation, reply
        return {"binary": label, "decoded_snapshot": measured}
    finally:
        os.close(ready_read)
        os.close(release_write)
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)


def baseline_admit(home, *args):
    # Setup drives the baseline with its own historical two-line receipt.
    captured, admission = map(json.loads, cli.run(home, *args, "--json").splitlines())
    assert captured == {"event": "captured", "request": admission["request"]}, (captured, admission)
    assert admission["event"] == "admission", admission
    return admission["request"]


def baseline_observation(state, key):
    return cli.fixture.command("observe-command", "--store", state / "store", "--key", key)["observation"]


def main():
    if sys.platform != "linux":
        raise SystemExit("This diagnostic needs Linux /proc; macOS footprint is not measured")
    baseline, candidate = (pathlib.Path(value).resolve() for value in sys.argv[1:3])
    for label, binary in (("baseline", baseline), ("candidate", candidate)):
        with binary.open("rb") as executable:
            print(json.dumps({"binary": label, "sha256": hashlib.file_digest(executable, "sha256").hexdigest()}), flush=True)
    cli.fixture.RUI = baseline
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
            host, _ = start_ready_process([baseline, "serve", "--store", state / "store",
                "--active-capacity", "1", "--provider-endpoint", f"http://127.0.0.1:{endpoint.server_port}/responses"])
            try:
                cli.run(home, "configure", "--store", state / "store", "--session", "resources/message",
                    "--workspace", state, "--provider", "codex", "--model", "model-a")
                failed = baseline_admit(home, "message", "--store", state / "store", "--session", "resources/message", "fail")
                cli.fixture.wait_for(lambda: baseline_observation(state, failed).get("result"), "saved failure")
                for repetition in range(3):
                    for label, binary in (("baseline", baseline), ("candidate", candidate)):
                        print(json.dumps(retained(state, binary, label, repetition, failed)), flush=True)
                pending = baseline_admit(home, "message", "--store", state / "store", "--session", "resources/message", "hold")
                cli.fixture.wait_for(lambda: len(endpoint.requests) == 2, "held provider request")
                for label, binary in (("baseline", baseline), ("candidate", candidate)):
                    print(json.dumps(held(state, binary, label, pending)), flush=True)
                release.set()
                cli.fixture.wait_for(lambda: baseline_observation(state, pending).get("result", {}).get("status") == "completed",
                    "work survives detached readers")
            finally:
                release.set()
                stop_process(host)
    finally:
        release.set()
        endpoint.shutdown()
        endpoint.server_close()


if __name__ == "__main__":
    main()
