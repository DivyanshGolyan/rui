"""Lifecycle for an ordinary conversation with all streams on one PTY."""

from contextlib import contextmanager
import os
import pty
import subprocess

from host_process import dispose_all, stop_process


@contextmanager
def terminal_process(args, *, env):
    """Borrow (process, master) until scope exit; collect and assert inside it.

    The caller owns response boundaries and explicit exit assertions. This owner
    only retires the child and descriptors, retaining the slave through collection
    and reap so Darwin does not discard unread output. Do not close borrowed handles.
    """
    master, slave = pty.openpty()
    process = None
    try:
        process = subprocess.Popen(args, env=env, stdin=slave, stdout=slave, stderr=slave)
        yield process, master
    finally:
        dispose_all(lambda: stop_process(process, timeout=5) if process is not None else None,
                    lambda: os.close(master), lambda: os.close(slave))
