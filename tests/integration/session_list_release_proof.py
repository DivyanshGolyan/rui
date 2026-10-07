#!/usr/bin/env python3
"""Opt-in Linux owner-boundary negatives: RUI CLIENT [--charge-negative]."""

import copy
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

import host_process
import session_list_integration as fixture


def expect_failure(operation, message):
    try:
        operation()
    except AssertionError as error:
        assert message in str(error), (message, error)
        return str(error)
    raise AssertionError(f"negative did not fail: {message}")


def oracle_controls():
    def record(phase, sequence, subject, charge=None):
        result = dict(rui_test_phase=phase, process="1", run="2", clock="awake_ns",
                      sequence=str(sequence), at_ns=str(100 + sequence), trace_lost=False,
                      subject_kind="request_number", subject=str(subject))
        if charge is not None:
            result["scratch_used_bytes"] = charge
        return result
    # The selected call releases first, while an earlier owner retains charge.
    # Zero must come from the latest release, not the selected request's record.
    records = [record("connection_request_configure", 1, 0),
               record("connection_request_list_sessions", 2, 1),
               record("connection_resources_released", 3, 1, "63"),
               record("connection_resources_released", 4, 0, "0")]
    diagnostics = SimpleNamespace(records=records, read_error=None, condition=threading.Condition())
    invocation = (102, 102, time.monotonic() + 10)
    with patch.object(fixture, "linux_resources", return_value={"census": "observed"}):
        assert fixture.released_resources(1, diagnostics, invocation) == {"census": "observed"}
        for charge in (None, 0, "00", "-1", str(2**64)):
            diagnostics.records = copy.deepcopy(records)
            release = diagnostics.records[2]
            release.pop("scratch_used_bytes")
            if charge is not None:
                release["scratch_used_bytes"] = charge
            expect_failure(lambda: fixture.released_resources(1, diagnostics, invocation), "scratch")
        diagnostics.records = copy.deepcopy(records)
        diagnostics.records[-1]["scratch_used_bytes"] = "1"
        expect_failure(lambda: fixture.released_resources(1, diagnostics, invocation), "retained scratch charge")
        diagnostics.records = copy.deepcopy(records)
        diagnostics.records[1]["trace_lost"] = True
        expect_failure(lambda: fixture.released_resources(1, diagnostics, invocation), "trace_lost")
        diagnostics.records = [records[0], records[2], records[3]]
        expect_failure(lambda: fixture.released_resources(1, diagnostics, invocation), "trace sequence gap")
        diagnostics.records = records + [records[-1]]
        expect_failure(lambda: fixture.released_resources(1, diagnostics, invocation), "duplicate exchange")
        diagnostics.records = [record("connection_resources_released", 1, 0, "0")]
        expect_failure(lambda: fixture.released_resources(1, diagnostics, invocation), "orphan release")
        diagnostics.records = []
        expect_failure(lambda: fixture.released_resources(1, diagnostics, (0, 0, time.monotonic())), "missing exchange release")


def remaining(invocation):
    value = invocation[2] - time.monotonic()
    assert value > 0, "proof exceeded original 10-second command budget"
    return value


def listing(store):
    began_ns = time.monotonic_ns()
    deadline = time.monotonic() + 10
    result = subprocess.run([fixture.CLIENT, store, "-", "0", "0"], capture_output=True, timeout=10)
    invocation = (began_ns, time.monotonic_ns(), deadline)
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert json.loads(result.stdout) == {"version": "1", "type": "session_list", "sessions": [], "next": None}
    return invocation


def retained_report(process, diagnostics, store, request, mode, invocation):
    receipts = diagnostics.wait(f"release_probe_{mode}", timeout=remaining(invocation))
    assert len(receipts) == 1, receipts
    receipt = receipts[0]
    assert receipt["pid"] == process.pid and receipt["request"] == str(request), receipt
    census = fixture.linux_resources(process.pid)
    identity = census["identities"][receipt["fd"]]
    assert identity[:2] == (receipt["device"], receipt["inode"]), (receipt, identity)
    assert stat.S_ISREG(identity[2]), identity
    assert identity[3] == str(store / "scratch" / f"report-{request}-1.tmp") + " (deleted)", identity
    return receipt, census


def case(binary, probe, mode):
    with tempfile.TemporaryDirectory(prefix="rui-list-release-") as directory:
        store = pathlib.Path(directory) / "store"
        store.mkdir(mode=0o700)
        request = 1 if mode == "leak" else 0
        env = os.environ.copy()
        env.update(LD_PRELOAD=str(probe), RUI_CENSUS_PROBE_MODE="leak" if mode == "leak" else "hold",
                   RUI_CENSUS_PROBE_PARENT=str(store / "scratch"), RUI_CENSUS_PROBE_REQUEST=str(request))
        original_popen = subprocess.Popen
        # Only Host launch gets interception and replaces its existing stdin.
        # Reuse readiness; do not add a second stderr reader or shared helper API.
        def popen(*args, **kwargs):
            return original_popen(*args, env=env, stdin=subprocess.PIPE, **kwargs)
        with patch.object(host_process.subprocess, "Popen", popen):
            process, _ = fixture.start_ready_process(
                [binary, "serve", "--store", store, "--active-capacity", "1", "--test-phase-trace"],
                required_fields={"execution": "unavailable"})
        diagnostics = host_process.HostDiagnostics(process)
        worker = None
        outcome = {}
        try:
            invocation = listing(store)
            if mode == "leak":
                baseline = fixture.released_resources(process.pid, diagnostics, invocation)
                invocation = listing(store)
                current = fixture.released_resources(process.pid, diagnostics, invocation)
                receipt, retained = retained_report(process, diagnostics, store, 1, "leaked", invocation)
                assert current["identities"][receipt["fd"]] == retained["identities"][receipt["fd"]]
                assert current["fds"] == baseline["fds"] + 1, (baseline, current)
                assert current["identities"] != baseline["identities"], (baseline, current)
                failure = expect_failure(lambda: fixture.assert_resources(baseline, current), "fds")
            else:
                receipt, held = retained_report(process, diagnostics, store, 0, "held", invocation)
                assert not diagnostics.matching("connection_resources_released", subject="0")
                if mode == "premature":
                    baseline = held  # Content-Length completion is deliberately the wrong witness.
                else:
                    waiting = threading.Event()
                    original_wait = diagnostics.condition.wait
                    def wait(timeout=None):
                        waiting.set()  # Under the oracle's condition lock, immediately before its real wait.
                        return original_wait(timeout)
                    def census():
                        try:
                            outcome["census"] = fixture.released_resources(process.pid, diagnostics, invocation)
                        except BaseException as error:
                            outcome["error"] = error
                    diagnostics.condition.wait = wait
                    worker = threading.Thread(target=census)
                    worker.start()
                    assert waiting.wait(remaining(invocation)), outcome
                    with diagnostics.condition:
                        assert not outcome and not diagnostics.matching("connection_resources_released", subject="0"), outcome
                    retained_report(process, diagnostics, store, 0, "held", invocation)
                process.stdin.write(b"r")
                process.stdin.flush()
                if worker is not None:
                    worker.join(remaining(invocation))
                    assert not worker.is_alive(), "census did not resume after real cleanup"
                    assert "error" not in outcome, outcome
                    baseline = outcome["census"]
                    diagnostics.condition.wait = original_wait
                else:
                    fixture.released_resources(process.pid, diagnostics, invocation)
                invocation = listing(store)
                current = fixture.released_resources(process.pid, diagnostics, invocation)
                if mode == "premature":
                    assert receipt["fd"] not in current["identities"], current
                    failure = expect_failure(lambda: fixture.assert_resources(baseline, current), "fds")
                else:
                    fixture.assert_resources(baseline, current)
                    failure = None
            assert process.poll() is None, "Host exited instead of completing proof"
            assert len(diagnostics.matching("release_probe_leaked" if mode == "leak" else "release_probe_held")) == 1
            print(json.dumps(dict(case=mode, receipt=receipt, baseline=baseline, final=current,
                                  expected_failure=failure, milestones=diagnostics.records), sort_keys=True))
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            if worker is not None and worker.is_alive():
                with diagnostics.condition:
                    original_error = diagnostics.read_error
                    diagnostics.read_error = "proof Host disposed"
                    diagnostics.condition.notify_all()
                worker.join(timeout=10)
                # The artificial wake is cleanup only, never a passing witness.
                diagnostics.read_error = original_error
                assert not worker.is_alive(), "proof census worker retained"
            diagnostics.close()
            process.stdin.close()
            fixture.stop_process(process)


def charge_negative(binary):
    # Use a disposable binary whose release sample alone is actual charge + 1.
    # This is separate from schema rejection and requires real native Client I/O.
    with tempfile.TemporaryDirectory(prefix="rui-list-charge-") as directory:
        store = pathlib.Path(directory) / "store"
        store.mkdir(mode=0o700)
        process, _ = fixture.start_ready_process(
            [binary, "serve", "--store", store, "--active-capacity", "1", "--test-phase-trace"],
            required_fields={"execution": "unavailable"})
        diagnostics = host_process.HostDiagnostics(process)
        try:
            invocation = listing(store)
            failure = expect_failure(lambda: fixture.released_resources(process.pid, diagnostics, invocation), "retained scratch charge")
            releases = diagnostics.matching("connection_resources_released", subject="0")
            assert len(releases) == 1 and releases[0]["scratch_used_bytes"] == "1", releases
            print(json.dumps(dict(case="native-charge-negative", expected_failure=failure, milestones=diagnostics.records)))
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            diagnostics.close()
            fixture.stop_process(process)


def main():
    if sys.platform != "linux":
        print("SKIP: real report-close and /proc proof requires native Linux")
        return
    binary = pathlib.Path(sys.argv[1]).resolve()
    print(json.dumps({"rui_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                      "client_sha256": hashlib.sha256(fixture.CLIENT.read_bytes()).hexdigest()}))
    oracle_controls()
    if len(sys.argv) == 4:
        assert sys.argv[3] == "--charge-negative"
        charge_negative(binary)
        return
    assert len(sys.argv) == 3, "usage: session_list_release_proof.py RUI CLIENT [--charge-negative]"
    with tempfile.TemporaryDirectory(prefix="rui-list-probe-") as directory:
        source = pathlib.Path(__file__).with_name("session_list_release_probe.c")
        probe = pathlib.Path(directory) / "close-probe.so"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        source, "-ldl", "-o", probe], check=True, timeout=10)
        print(json.dumps({"probe_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                          "probe_sha256": hashlib.sha256(probe.read_bytes()).hexdigest()}))
        for mode in ("premature", "held", "leak"):
            case(binary, probe, mode)


if __name__ == "__main__":
    main()
