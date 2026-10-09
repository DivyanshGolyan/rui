#!/usr/bin/env python3
"""Coordinated Linux libc owner-boundary errors, not kernel stall qualification."""
import fcntl
import os
import pathlib
import pty
import select
import struct
import subprocess
import sys
import termios
import time

from host_process import assert_persistent_terminal_restored

binary = pathlib.Path(sys.argv[1]).resolve()
failed = False
for case, expected in (("interrupt", "TerminalCleanupFailed"),
                       ("canonical-ui", "CanonicalStoreFailure"),
                       ("restore-admission", "TerminalRestoreFailed")):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    original, flags = termios.tcgetattr(slave), fcntl.fcntl(slave, fcntl.F_GETFL)
    env = dict(os.environ)
    if case == "restore-admission": env["RUI_DRAIN_RESTORE_FAILURE"] = "1"
    process = subprocess.Popen([str(binary), case], stdin=slave, stdout=slave,
                               stderr=subprocess.PIPE, env=env)
    output = bytearray()
    deadline = time.monotonic() + 10
    try:
        while process.poll() is None:
            assert time.monotonic() < deadline, (case, "owner did not join", output)
            if select.select([master], [], [], .01)[0]: output.extend(os.read(master, 65536))
        while select.select([master], [], [], 0)[0]: output.extend(os.read(master, 65536))
        errors = process.stderr.read().decode()
        if case != "restore-admission":
            assert_persistent_terminal_restored(slave, original, flags)
        else:
            assert not termios.tcgetattr(slave)[3] & termios.ICANON
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == flags
        good = process.returncode != 0 and ("error: " + expected) in errors and b"Detached." not in output
        failed |= not good
        print(case, "PASS" if good else "FAIL", "exit", process.returncode,
              "expected", expected, "actual", next((line for line in errors.splitlines() if line.startswith("error:")), "none"), flush=True)
        assert "custody: drain joined once, restoration attempted once" in errors, errors
        if case == "restore-admission": assert "Admission failed canonically and joined once" in errors, errors
        assert "CustodyNotSettled" not in errors, errors
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        termios.tcsetattr(slave, termios.TCSANOW, original)
        os.close(master)
        os.close(slave)
if failed: raise SystemExit(1)
