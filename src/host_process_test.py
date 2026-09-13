#!/usr/bin/env python3
"""Failure-sensitive checks for bounded Host process startup."""

import os
import pathlib
import sys
import tempfile
import time

from host_process import (
    READINESS_LIMIT,
    STDERR_TAIL_LIMIT,
    HostStartError,
    start_ready_process,
    stop_process,
)


def child(source, pid_file):
    return [
        sys.executable,
        "-u",
        "-c",
        "import os, pathlib, sys, time; "
        f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
        + source,
    ]


def assert_reaped(source, description, *, timeout=0.2, required_fields=None):
    with tempfile.TemporaryDirectory(prefix="latifa-host-start-test-") as temporary:
        pid_file = pathlib.Path(temporary) / "pid"
        started = time.monotonic()
        try:
            start_ready_process(
                child(source, pid_file),
                timeout=timeout,
                required_fields=required_fields,
            )
        except HostStartError as error:
            elapsed = time.monotonic() - started
            assert elapsed < timeout + 2, description
            assert error.pid == int(pid_file.read_text()), description
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
    with tempfile.TemporaryDirectory(prefix="latifa-host-start-test-") as temporary:
        pid_file = pathlib.Path(temporary) / "pid"
        process, fields = start_ready_process(
            child("print('ready execution=enabled curl=8.22.0'); time.sleep(10)", pid_file),
            timeout=1,
            required_fields={"execution": "enabled", "curl": "8.22.0"},
        )
        try:
            assert fields == {"execution": "enabled", "curl": "8.22.0"}
            assert process.poll() is None
        finally:
            stop_process(process)


if __name__ == "__main__":
    main()
