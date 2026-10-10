#!/usr/bin/env python3
"""Failure-sensitive checks for bounded Host process startup."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

from host_process import (
    READINESS_LIMIT,
    STDERR_TAIL_LIMIT,
    HostDiagnostics,
    HostStartError,
    ReleaseGate,
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


if __name__ == "__main__":
    main()
