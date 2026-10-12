#!/usr/bin/env python3
"""Failure-sensitive checks for bounded Host process startup."""

import json
import io
import contextlib
import mmap
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

from host_process import (
    READINESS_LIMIT,
    STDERR_TAIL_LIMIT,
    HostDiagnostics,
    HostStartError,
    ReleaseGate,
    _Observations,
    start_ready_process,
    stop_process,
)


def child(source):
    return [
        sys.executable,
        "-u",
        "-c",
        "import sys, time; " + source,
    ]


def assert_reaped(source, description, *, timeout=0.2, required_fields=None):
    started = time.monotonic()
    try:
        start_ready_process(
            child(source),
            timeout=timeout,
            required_fields=required_fields,
        )
    except HostStartError as error:
        elapsed = time.monotonic() - started
        assert elapsed < timeout + 2, description
        assert error.pid > 0, description
        try:
            os.kill(error.pid, 0)
        except ProcessLookupError:
            return error, elapsed
        raise AssertionError(f"{description} child was not reaped")
    raise AssertionError(f"{description} unexpectedly became ready")


def main():
    prove_execution_release_oracles()
    assert_reaped("time.sleep(10)", "silent alive")
    assert_reaped("sys.stdout.write('rea'); sys.stdout.flush(); time.sleep(10)", "partial line")
    assert_reaped("print('not-ready'); time.sleep(10)", "malformed readiness")
    assert_reaped("sys.exit(7)", "early exit")
    assert_reaped(
        "print('ready execution=unavailable'); time.sleep(10)",
        "mismatched readiness",
        required_fields={"execution": "enabled"},
    )
    flood_error, _ = assert_reaped(
        "sys.stderr.write('x' * (1024 * 1024)); sys.stderr.flush(); time.sleep(10)",
        "stderr flood",
    )
    assert "stderr_tail=" in str(flood_error)
    assert STDERR_TAIL_LIMIT <= len(str(flood_error))
    error_text_limit = 4 * (READINESS_LIMIT + STDERR_TAIL_LIMIT) + 512
    assert len(str(flood_error)) <= error_text_limit
    stdout_error, stdout_elapsed = assert_reaped(
        "sys.stdout.write('x' * (1024 * 1024)); sys.stdout.flush(); time.sleep(10)",
        "stdout flood",
        timeout=5,
    )
    assert stdout_elapsed < 1
    assert "readiness exceeded 16 KiB" in str(stdout_error)
    assert len(str(stdout_error)) <= error_text_limit
    process, fields = start_ready_process(
        child("print('ready execution=enabled curl=8.22.0'); time.sleep(10)"),
        timeout=1,
        required_fields={"execution": "enabled", "curl": "8.22.0"},
    )
    try:
        assert fields == {"execution": "enabled", "curl": "8.22.0"}
        assert process.poll() is None
    finally:
        stop_process(process)
    prove_private_environment()
    prove_coalesced_phase_records()
    prove_observation_channel()
    prove_observation_disposal()
    prove_short_optional_receipt()
    prove_gate_broadcast()


def prove_private_environment():
    with tempfile.TemporaryDirectory(prefix="rui-host-environment-") as directory:
        inherited = "RUI_TEST_PARENT_ENV"
        previous = os.environ.get(inherited)
        os.environ[inherited] = "parent-only"
        try:
            process, fields = start_ready_process(
                child("import os; print('ready home=' + os.environ['HOME'].encode().hex() "
                      "+ ' inherited=' + os.environ.get('RUI_TEST_PARENT_ENV', 'absent')); time.sleep(10)"),
                env={"HOME": directory},
                timeout=1,
            )
            try:
                assert fields == {"home": directory.encode().hex(), "inherited": "absent"}, fields
                assert os.environ[inherited] == "parent-only"
            finally:
                stop_process(process)
        finally:
            if previous is None:
                del os.environ[inherited]
            else:
                os.environ[inherited] = previous


def prove_gate_broadcast():
    with tempfile.TemporaryDirectory(prefix="rui-release-gate-") as directory:
        gate = ReleaseGate(pathlib.Path(directory) / "gate")
        readers = []
        try:
            for _ in range(2):
                reader = os.open(gate.path, os.O_RDONLY | os.O_NONBLOCK)
                readers.append(reader)
                try:
                    os.read(reader, 1)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("gate did not hold reader")
            gate.release()
            for reader in readers:
                assert os.read(reader, 1) == b"", "release did not broadcast EOF"
            assert not gate.path.exists(), "later native arrivals would block"
            gate.release()
        finally:
            gate.release()
            for reader in readers:
                os.close(reader)


def prove_coalesced_phase_records():
    first = {
        "rui_test_phase": "control_durable_acceptance",
        "subject_kind": "command_key",
        "subject": "stopped-pipes-stop",
    }
    second = {
        "rui_test_phase": "control_store_complete",
        "subject_kind": "command_key",
        "subject": "stopped-pipes-stop",
    }
    payload = json.dumps(first) + "\n" + json.dumps(second) + "\n"
    process = subprocess.Popen(
        [
            sys.executable,
            "-u",
            "-c",
            "import sys, time; sys.stderr.write(sys.argv[1]); sys.stderr.flush(); time.sleep(10)",
            payload,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    diagnostics = HostDiagnostics(process)
    try:
        matches = diagnostics.wait(
            "control_store_complete",
            timeout=2,
            subject_kind="command_key",
            subject="stopped-pipes-stop",
        )
        assert matches == [second], matches
        assert diagnostics.matching(
            "control_durable_acceptance",
            subject_kind="command_key",
            subject="stopped-pipes-stop",
        ) == [first]
    finally:
        stop_process(process)
        diagnostics.close()


def prove_short_optional_receipt():
    reader, writer = os.pipe()
    process = subprocess.Popen(child("sys.stderr.write('short fixture receipt\\n'); sys.stderr.flush(); sys.stdin.read(1)"),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.rui_observations = _Observations(process, reader, "list", observation_state(process.pid, 0))
    diagnostics = HostDiagnostics(process)
    try:
        deadline = time.monotonic() + 1
        while diagnostics.tail() != b"short fixture receipt\n":
            assert diagnostics.read_error is None, diagnostics.read_error
            assert time.monotonic() < deadline, "short receipt withheld until filler output or EOF"
            time.sleep(.01)
        assert process.poll() is None, "receipt required writer exit"
        assert not diagnostics.records, "optional receipt became native owner evidence"
        process.stdin.write(b"r")
        process.stdin.flush()
        assert process.wait(timeout=1) == 0
    finally:
        os.close(writer)
        stop_process(process)
        diagnostics.close()
        process.stdin.close()
    print("Host optional receipt: short write visible with writer open and no filler, no native evidence")


def observation_frame(sequence, *, phase="ordinary_classification_released", subject="message", action=None, process=None, lost=0):
    # Independent native codec golden: phase=0, timestamp=1, subject kind=2,
    # subject=3, action=7. Keep the asymmetric route/subject distinct.
    fields = ((0, phase), (1, "1234567"), (2, "route"), (3, subject))
    if action is not None:
        fields += ((7, action),)
    body = b"".join(struct.pack("<BH", index, len(value.encode())) + value.encode()
                    for index, value in fields)
    return struct.pack("<HBBQQQ", 28 + len(body), 1, lost, sequence, 37,
                       os.getpid() if process is None else process) + body


def observation_state(process, state, *, run=37, active=0, version=1):
    mapping = mmap.mmap(-1, 40)
    mapping[:] = struct.pack("<QQQQQ", version, process, run, state, active)
    return mapping


def prove_observation_channel():
    for case in ("reordered", "missing", "wrong-process", "loss", "duplicate", "overflow", "wrong-subject", "missing-final", "wrong-action", "missing-handoff"):
        reader, writer = os.pipe()
        process = SimpleNamespace(pid=os.getpid(), poll=lambda: 0, stderr=io.BytesIO())
        count = 2 if case == "reordered" else (0 if case == "missing-handoff" else 1)
        process.rui_observations = _Observations(process, reader, "stop", observation_state(process.pid, count * 2))
        observations = process.rui_observations
        diagnostics = HostDiagnostics(process)
        try:
            if case == "reordered":
                os.write(writer, observation_frame(2, subject="observe"))
                deadline = time.monotonic() + 1
                with observations.condition:
                    while not observations.pending_records and observations.error is None:
                        remaining = deadline - time.monotonic()
                        assert remaining > 0, "withheld-prefix controller did not reach reader"
                        observations.condition.wait(remaining)
                    assert not observations.records, "later arrival exposed an incomplete prefix"
                os.write(writer, observation_frame(1))
                assert diagnostics.wait("ordinary_classification_released", count=2, timeout=1) == [
                    dict(rui_test_phase="ordinary_classification_released", at_ns="1234567",
                         subject_kind="route", subject=subject, process=str(os.getpid()), run="37",
                         sequence=str(sequence), clock="awake_ns", trace_lost=False)
                    for sequence, subject in ((1, "message"), (2, "observe"))]
            elif case == "missing":
                os.write(writer, observation_frame(2))
            elif case == "wrong-process":
                os.write(writer, observation_frame(1, process=os.getpid() + 1))
            elif case == "loss":
                os.write(writer, observation_frame(1, lost=1))
            elif case == "duplicate":
                os.write(writer, observation_frame(1) * 2)
            elif case == "overflow":
                observations.limit = 1
                os.write(writer, observation_frame(1) + observation_frame(2))
            elif case in ("wrong-action", "missing-handoff"):
                if case == "wrong-action":
                    os.write(writer, observation_frame(1, phase="bash_handoff_committed", action="19"))
                try:
                    diagnostics.wait("bash_handoff_committed", action="17", timeout=.05)
                except AssertionError as error:
                    assert "timed out waiting" in str(error), error
                else:
                    raise AssertionError("another Action or missing handoff accepted")
            else:
                os.write(writer, observation_frame(1, subject="other" if case == "wrong-subject" else "message"))
                try:
                    diagnostics.wait("ordinary_classification_released", count=2 if case == "missing-final" else 1,
                                     subject="message", timeout=.05)
                except AssertionError as error:
                    assert "timed out waiting" in str(error), error
                else:
                    raise AssertionError("missing/wrong-subject evidence accepted")
            os.close(writer)
            writer = None
            if case in ("reordered", "wrong-subject", "missing-final", "wrong-action", "missing-handoff"):
                diagnostics.close()
            else:
                try:
                    diagnostics.close()
                except AssertionError as error:
                    expected = {"missing": "missing observation sequence", "wrong-process": "foreign observation",
                                "loss": "observation loss", "duplicate": "duplicate observation sequence",
                                "overflow": "population exceeded"}[case]
                    assert expected in str(error), error
                else:
                    raise AssertionError("invalid observation accepted")
        finally:
            if writer is not None:
                os.close(writer)
            observations.thread.join(1)
            assert not observations.thread.is_alive(), "observation custody leaked"
    print("Host observation channel: withheld prefix, reordered arrival, missing middle/final/handoff, wrong Action, foreign subject/process, loss, duplicate and bounded overflow controls passed")
    prove_final_observation_state()


def prove_final_observation_state():
    from host_process import OBSERVATION_LIMITS
    for plan in OBSERVATION_LIMITS:
        for case in ("normal", "tail-loss", "encoding-loss", "missing-tail", "in-flight", "missing-state", "foreign-process", "foreign-run"):
            reader, writer = os.pipe()
            process = SimpleNamespace(pid=os.getpid(), poll=lambda: -9)
            state = observation_state(process.pid, {"tail-loss": 5, "encoding-loss": 3, "missing-tail": 4}.get(case, 2),
                                      active=int(case == "in-flight"), version=0 if case == "missing-state" else 1,
                                      run=38 if case == "foreign-run" else 37)
            if case == "foreign-process":
                state = observation_state(process.pid + 1, 2)
            observations = _Observations(process, reader, plan, state)
            os.write(writer, observation_frame(1))
            os.close(writer)  # A complete received prefix and EOF, never a later loss-bearing frame.
            try:
                observations.close()
            except AssertionError as error:
                expected = {"tail-loss": "final native observation loss", "encoding-loss": "final native observation loss",
                            "missing-tail": "missing final observation sequence", "in-flight": "during observation publication",
                            "missing-state": "missing/foreign final observation state", "foreign-process": "missing/foreign final observation state",
                            "foreign-run": "mixed final observation run"}.get(case)
                assert expected and expected in str(error), (plan, case, error)
            else:
                assert case == "normal", (plan, case, "terminal channel loss accepted")
                observations.close()  # Idempotent readback after mapping custody ends.
    print("Host final observation helper: every plan rejects final loss, encoding loss, missing tail, interrupted publication and missing/foreign state with kill status; normal prefix accepted")


def prove_observation_disposal():
    import ctypes
    from host_process import OBSERVATION_LIMITS, OBSERVATION_SEALED, _observation_atomics
    native = _observation_atomics()
    for plan in OBSERVATION_LIMITS:
        for case in ("held-final", "late-loss", "missing-tail", "missing-endpoint"):
            reader, writer = os.pipe()
            process = SimpleNamespace(pid=os.getpid(), poll=lambda: None, stderr=io.BytesIO())
            state = observation_state(process.pid, 4 if case == "missing-tail" else 2,
                                      active=int(case == "held-final"))
            observations = _Observations(process, reader, plan, state)
            process.rui_observations = observations
            diagnostics = HostDiagnostics(process)
            os.write(writer, observation_frame(1))
            diagnostics.wait("ordinary_classification_released", timeout=1)
            address = ctypes.addressof(ctypes.c_char.from_buffer(state))
            result = []
            def dispose():
                try:
                    observations.dispose(time.monotonic() + .2)
                except BaseException as error:
                    result.append(error)
                else:
                    result.append(None)
            if case == "late-loss":
                # Synthetic post-seal loss stays sticky; the real native
                # late-attempt/SIGKILL ordering is separately exercised in Zig.
                state[24] = 3
            worker = threading.Thread(target=dispose)
            worker.start()
            deadline = time.monotonic() + 1
            while not native.observation_load(address + 32) & OBSERVATION_SEALED:
                assert time.monotonic() < deadline, "fixture failed to seal native admission"
                time.sleep(.001)
            if case == "held-final":
                assert worker.is_alive() and not result, "received final frame falsely proved retirement"
                # Synthetic retirement shadow: only the count byte changes.
                # The native regression holds the actual record call here.
                state[32] = 0
            worker.join(1)
            assert not worker.is_alive(), "bounded disposal worker leaked"
            if case in ("held-final", "missing-endpoint"):
                assert result == [None], result
                assert native.observation_load(address + 32) == OBSERVATION_SEALED
                if case == "missing-endpoint":
                    try:
                        diagnostics.wait("cleanup_completed", operation="7", timeout=.02)
                    except AssertionError as error:
                        assert "timed out waiting" in str(error), error
                    else:
                        raise AssertionError("sealed zero-active channel invented a required endpoint")
            else:
                assert len(result) == 1 and isinstance(result[0], AssertionError), result
                assert ("native loss" if case == "late-loss" else "disposal budget") in str(result[0]), result
            os.close(writer)
            process.poll = lambda: -9
            try:
                diagnostics.close()
            except AssertionError as error:
                assert case in ("late-loss", "missing-tail"), error
            else:
                assert case in ("held-final", "missing-endpoint")
    # Actual pre-teardown helper copy survives deletion of its private root,
    # without Store/HOME reads or a new retention service.
    with tempfile.TemporaryDirectory() as destination:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "store").mkdir()
            (root / "store/private").write_bytes(b"private Store bytes")
            process = SimpleNamespace(pid=os.getpid(), poll=lambda: None,
                                      args=["rui", "serve", "--store", root / "store"])
            reader, writer = os.pipe()
            observations = _Observations(process, reader, "status", observation_state(process.pid, 0))
            snapshot = observations.snapshot()
            os.close(writer)
            process.poll = lambda: -9
            observations.close()
            with patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=destination):
                observations.preserve_failure(snapshot)
        paths = list(pathlib.Path(destination).rglob("observation-failure-*.json"))
        assert len(paths) == 1 and not list(pathlib.Path(destination).rglob("private"))
        snapshot = json.loads(paths[0].read_bytes())
        assert snapshot["returncode"] is None and not snapshot["atomic_census"]
        assert snapshot["records"] == [] and snapshot["shared_state"] == [1, os.getpid(), 37, 0, 0]
    print("Host disposal: every plan drains held final custody, seals admission, refuses late loss/missing tail and missing endpoint; pre-teardown retention survives root removal")
    prove_retention_does_not_own_teardown()


def prove_retention_does_not_own_teardown():
    import host_process
    import run_selected  # Loaded by the preceding real retention helper call.
    # Sampling itself is optional, including failures before write_text/open.
    with tempfile.TemporaryDirectory() as directory:
        try:
            raise AssertionError("original fixture failure")
        except AssertionError as original:
            assert not host_process.preserve_failure_metadata(pathlib.Path(directory) / "pty-failure.json",
                lambda: os.read(-1, 1))
            assert sys.exc_info()[1] is original, "metadata sampling replaced original failure"
    for case in ("write-failure", "copy-failure", "late-loss"):
        with tempfile.TemporaryDirectory() as destination, tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            reader, writer = os.pipe()
            process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                "--store", str(root / "store")], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                pass_fds=(writer,))
            os.close(writer)  # Only child custody now; kill must produce EOF.
            state = observation_state(process.pid, 0)
            observations = _Observations(process, reader, "status", state)
            process.rui_observations = observations
            copied = []
            def copy(*args):
                assert process.returncode == -9 and process.stdout.closed and process.stderr.closed
                copied.append(True)
                if case == "copy-failure":
                    raise OSError("unavailable hosted destination")
            original_kill = process.kill
            def kill():
                if case == "late-loss":
                    state[24] = 1  # Synthetic native loss after successful seal.
                original_kill()
            original_open = pathlib.Path.open
            def open_path(path, *args, **kwargs):
                if case == "write-failure" and path.name.startswith("observation-failure-"):
                    raise OSError("unavailable fixture destination")
                return original_open(path, *args, **kwargs)
            try:
                with patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=destination), \
                        patch.object(run_selected, "retain_failure_logs", copy), \
                        patch.object(pathlib.Path, "open", open_path), patch.object(process, "kill", kill):
                    if case == "late-loss":
                        try:
                            stop_process(process, timeout=1)
                        except AssertionError as error:
                            assert "final native observation loss" in str(error), error
                        else:
                            raise AssertionError("post-seal loss became acceptance")
                    else:
                        try:
                            raise AssertionError("original fixture failure")
                        except AssertionError as original:
                            stop_process(process, timeout=1)
                            assert sys.exc_info()[1] is original, "optional retention replaced original failure"
                assert process.returncode == -9 and process.stdout.closed and process.stderr.closed
                assert not observations.thread.is_alive() and observations.final_state is not None
                assert copied == ([] if case == "write-failure" else [True]), copied
                if case == "late-loss":
                    snapshot = json.loads(next(root.glob("observation-failure-*.json")).read_bytes())
                    assert snapshot["stage"] == "pre_kill" and snapshot["shared_state"][3] == 0
                    assert snapshot["post_reap_state"][3] == 1 and snapshot["final_error"] == "AssertionError"
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
    print("Host retention: sampling/write/copy refusal preserves original failure and actual SIGKILL/reap/closed custody; post-seal loss retains distinct pre/post states")


def prove_execution_release_oracles():
    import host_process

    def refused(invoke, description):
        try:
            invoke()
        except AssertionError as error:
            assert description in str(error), error
        else:
            raise AssertionError(f"accepted {description}")

    clean = dict(dispatch_fenced=False, custody_occupied="0", scratch_used_bytes="0")
    # Independently authored accounting snapshots: separate zeros do not add
    # up to a release, and a clean reply at the deadline is already too late.
    for sequence, accepted, finished_at in (
        ([dict(clean, custody_occupied="1"), clean], True, 0.1),
        ([dict(clean, custody_occupied="1")], False, 0.1),
        ([dict(clean, scratch_used_bytes="4096")], False, 0.1),
        ([dict(clean, custody_occupied="1"), dict(clean, scratch_used_bytes="4096")], False, 0.1),
        ([clean], False, 0.5),
        ([clean], False, 0.6),
    ):
        now = [0.0]
        replies = iter(sequence)
        def inspect(remaining):
            assert 0 < remaining <= 0.5 - now[0], remaining
            now[0] += finished_at
            return next(replies, sequence[-1])
        clock = SimpleNamespace(monotonic=lambda: now[0], sleep=lambda delay: None)
        with patch.object(host_process, "time", clock):
            invoke = lambda: host_process.wait_for_execution_release(inspect, 0.5)
            if accepted:
                assert invoke() == clean
            else:
                refused(invoke, "custody drainage")
    with patch.object(host_process.time, "monotonic", return_value=100):
        for deadline, expected in ((145, 15), (101, 1)):
            def inspect(remaining):
                assert remaining == expected, remaining
                return clean
            assert host_process.wait_for_execution_release(inspect, deadline) == clean
        refused(lambda: host_process.wait_for_execution_release(lambda _: dict(clean, dispatch_fenced=True), 101), "dispatch_fenced")

    for limit in (49, 50):
        diagnostics = HostDiagnostics(SimpleNamespace(stderr=io.BytesIO(), poll=lambda: 0))
        diagnostics.close()
        for _ in range(limit):
            diagnostics.claim_inspection(limit)
        assert diagnostics.records == [], "missing receipts must not refund issued inspections"
        refused(lambda: diagnostics.claim_inspection(limit), "inspection population")

    processing = dict(turn="7", operation="11", attempt="2")
    endpoint = dict(processing, rui_test_phase="cleanup_completed", action=None)
    # Drive the actual diagnostics reader and identity selector. Synthetic
    # frames test the oracle; they do not qualify a native Host's reclamation.
    for records, accepted in (
        ([endpoint], True), ([], False), ([dict(endpoint, turn="8")], False),
        ([dict(endpoint, operation="12")], False), ([dict(endpoint, attempt="3")], False),
        ([dict(endpoint, action="19")], False), ([endpoint, endpoint], False),
    ):
        reader = io.BytesIO(b"".join(json.dumps(value).encode() + b"\n" for value in records))
        diagnostics = HostDiagnostics(SimpleNamespace(stderr=reader, poll=lambda: 0))
        diagnostics.close()
        invoke = lambda: diagnostics.wait_model_cleanup(processing, time.monotonic() + 0.001)
        if accepted:
            assert invoke() == endpoint
            diagnostics.assert_model_cleanup_census(processing)
            with patch.object(host_process.time, "monotonic", return_value=10):
                refused(lambda: diagnostics.wait_model_cleanup(processing, 10), "physical cleanup deadline")
            original_wait = diagnostics.wait
            for completed_at in (9.999, 10.0, 10.5):
                now = [9.0]
                def wait(*args, **kwargs):
                    records = original_wait(*args, **kwargs)
                    now[0] = completed_at
                    return records
                clock = SimpleNamespace(monotonic=lambda: now[0])
                with patch.object(host_process, "time", clock), patch.object(diagnostics, "wait", wait):
                    if completed_at < 10:
                        assert diagnostics.wait_model_cleanup(processing, 10) == endpoint
                    else:
                        refused(lambda: diagnostics.wait_model_cleanup(processing, 10), "cleanup endpoint arrived")
            # A duplicate or unrelated owner discovered after first success
            # must still fail the complete post-reap population.
            for late in (endpoint, dict(endpoint, operation="12")):
                diagnostics.records.append(late)
                refused(lambda: diagnostics.assert_model_cleanup_census(processing), "Counter")
                diagnostics.records.pop()
        elif records == [endpoint, endpoint]:
            refused(invoke, "cleanup_completed")
        else:
            refused(invoke, "timed out")
    print("Execution release oracle: simultaneous accounting, exact cleanup owners/final population, withheld custody/scratch, late replies, caller and inspection bounds")


def prove_control_disposal_oracle(dispose):
    module = sys.modules[dispose.__module__]
    for broken in ((), ("connection",), ("stop",), ("gate",), ("diagnostics",),
                   ("shutdown",), ("server",), ("join",), ("stop", "gate", "shutdown")):
        for failing_body in (False, True):
            closed = set()
            failures = {name: RuntimeError(name) for name in broken}
            primary = AssertionError("original Control assertion")

            def close(name):
                closed.add(name)
                if name in failures:
                    raise failures[name]

            endpoint = SimpleNamespace(release=SimpleNamespace(set=lambda: close("release")),
                                       shutdown=lambda: close("shutdown"), server_close=lambda: close("server"))
            thread = SimpleNamespace(join=lambda timeout: close("join"), is_alive=lambda: "join" not in closed)
            diagnostics = SimpleNamespace(close=lambda: close("diagnostics"))
            connection = SimpleNamespace(close=lambda: close("connection"))
            with patch.object(module, "stop_process", lambda process: close("stop")), \
                    contextlib.redirect_stderr(io.StringIO()):
                try:
                    try:
                        if failing_body:
                            raise primary
                    finally:
                        dispose(object(), diagnostics, endpoint, thread, lambda: close("gate"),
                                connections=[connection])
                except BaseException as error:
                    assert error is (primary if failing_body else failures[broken[0]]), error
                else:
                    assert not failing_body and not broken
            assert closed == {"connection", "stop", "gate", "diagnostics", "release", "shutdown", "server", "join"}, closed
    print("Control disposal oracle: original assertion survives every cleanup failure; every owned resource still receives disposal")


if __name__ == "__main__":
    main()
