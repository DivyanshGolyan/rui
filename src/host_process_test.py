#!/usr/bin/env python3
"""Failure-sensitive checks for bounded Host process startup."""

import os
import pathlib
import sys
import tempfile
import time

from host_process import HostStartError, start_ready_process, stop_process


def child(source, pid_file):
    return [
        sys.executable,
        "-u",
        "-c",
        "import os, pathlib, sys, time; "
        f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
        + source,
    ]


def assert_reaped(source, description):
    with tempfile.TemporaryDirectory(prefix="latifa-host-start-test-") as temporary:
        pid_file = pathlib.Path(temporary) / "pid"
        started = time.monotonic()
        try:
            start_ready_process(child(source, pid_file), timeout=0.2)
        except HostStartError as error:
            assert time.monotonic() - started < 2, description
            assert error.pid == int(pid_file.read_text()), description
            try:
                os.kill(error.pid, 0)
            except ProcessLookupError:
                return error
            raise AssertionError(f"{description} child was not reaped")
        raise AssertionError(f"{description} unexpectedly became ready")


def main():
    assert_reaped("time.sleep(10)", "silent alive")
    assert_reaped("sys.stdout.write('rea'); sys.stdout.flush(); time.sleep(10)", "partial line")
    assert_reaped("print('not-ready'); time.sleep(10)", "malformed readiness")
    assert_reaped("sys.exit(7)", "early exit")
    flood_error = assert_reaped(
        "sys.stderr.write('x' * (1024 * 1024)); sys.stderr.flush(); time.sleep(10)",
        "stderr flood",
    )
    assert "stderr_tail=" in str(flood_error)
    assert 16 * 1024 <= len(str(flood_error)) < 40 * 1024
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
