#!/usr/bin/env python3
"""Failure-sensitive checks for bounded Host process startup."""

import json
import io
import mmap
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

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


if __name__ == "__main__":
    main()
