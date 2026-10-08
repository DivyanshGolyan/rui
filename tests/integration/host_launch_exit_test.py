#!/usr/bin/env python3
"""Host-launch reader oracle, run by its fixture; not native Host qualification."""

from contextlib import contextmanager
import os
import pty
import subprocess
import sys
import time
from unittest.mock import patch


@contextmanager
def child_pty(source):
    master, slave = pty.openpty()
    caller = None
    try:
        caller = subprocess.Popen([sys.executable, "-c", source],
            stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
        os.close(slave)
        slave = None
        yield caller, master
    finally:
        try:
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
        finally:
            try:
                os.close(master)
            finally:
                if slave is not None:
                    os.close(slave)


def check_exit_reader(wait_for_exit):
    # More than three read windows, asymmetric ends, and a nonzero exit:
    # neither waiting before reading nor dropping late bytes can pass.
    payload = b"head:" + b"a" * 131072 + b"b" * 65531 + b":tail"
    source = """
import os
payload = b'head:' + b'a' * 131072 + b'b' * 65531 + b':tail'
while payload:
    count = os.write(1, payload)
    payload = payload[count:]
raise SystemExit(17)
"""
    with child_pty(source) as (caller, master):
        output = bytearray(b"entry:")
        assert wait_for_exit(caller, master, output, time.monotonic() + 5) == 17
        assert output == b"entry:" + payload, "reader lost or reordered transcript bytes"
        assert caller.returncode == 17, "reader did not reap actual caller outcome"

    # EOF is not child exit. Observe the actual monotonic operand to require
    # exactly the remaining allowance, not a fresh five seconds at reap.
    with child_pty("import os,time; os.close(1); os.close(2); time.sleep(30)") as (caller, master):
        owner = sys.modules[wait_for_exit.__module__]
        deadline = time.monotonic() + 0.2
        original_wait = caller.wait
        original_clock = time.monotonic
        last_sample = None
        waited = False

        def sample():
            nonlocal last_sample
            last_sample = original_clock()
            return last_sample

        def reap(*, timeout):
            nonlocal waited
            waited = True
            assert last_sample is not None
            assert timeout == max(0, deadline - last_sample), "renewed reap budget"
            return original_wait(timeout=timeout)

        with patch.object(owner.time, "monotonic", sample), patch.object(caller, "wait", reap):
            try:
                wait_for_exit(caller, master, bytearray(), deadline)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("EOF accepted without caller exit")
        assert waited, "reader did not exercise EOF-to-reap boundary"

    with child_pty("import os; os.write(1,b'z')") as (caller, master):
        output = bytearray(b"x" * (1024 * 1024 - 2))
        assert wait_for_exit(caller, master, output, time.monotonic() + 5) == 0
        assert output == b"x" * (1024 * 1024 - 2) + b"z", "below-bound bytes lost"

    # Cross the fixture's strict 1-MiB retained transcript bound with one
    # actual byte; failure must preserve, not silently truncate, prior bytes.
    with child_pty("import os; os.write(1,b'z')") as (caller, master):
        output = bytearray(b"x" * (1024 * 1024 - 1))
        try:
            wait_for_exit(caller, master, output, time.monotonic() + 5)
        except AssertionError as error:
            assert str(error) == "unexpected unbounded terminal output", error
        else:
            raise AssertionError("crossing output was silently accepted")
        assert output == b"x" * (1024 * 1024 - 1), "overflow altered retained bytes"

    print("host-launch exit reader: exact transcript/outcome/reap, remaining budget and overflow passed")
