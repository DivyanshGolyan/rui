"""Lifecycle for an ordinary conversation with all streams on one PTY."""

from contextlib import contextmanager
import fcntl
import os
import pty
import struct
import subprocess
import termios

from host_process import dispose_all, stop_process


# Conversations run full screen; tall enough that a short exchange stays in view.
COLUMNS, ROWS = 80, 50
# Every PTY here emulates a cursor-addressing terminal, so its callers inherit
# one rather than the runner's TERM (TERM=dumb is refused at entry). A case
# about TERM itself sets it explicitly.
os.environ["TERM"] = "xterm-256color"
# Screen observers by master descriptor. A new PTY can reuse a closed
# descriptor number, so opening one discards the previous terminal's screen.
CAPTURES = {}


def open_pty(columns=COLUMNS, rows=ROWS):
    """A PTY with real geometry, as every interactive terminal reports."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    CAPTURES.pop(master, None)
    return master, slave


@contextmanager
def terminal_process(args, *, env):
    """Borrow (process, master) until scope exit; collect and assert inside it.

    The caller owns response boundaries and explicit exit assertions. This owner
    only retires the child and descriptors, retaining the slave through collection
    and reap so Darwin does not discard unread output. Do not close borrowed handles.
    """
    master, slave = open_pty()
    process = None
    try:
        process = subprocess.Popen(args, env=env, stdin=slave, stdout=slave, stderr=slave)
        yield process, master
    finally:
        dispose_all(lambda: stop_process(process, timeout=5) if process is not None else None,
                    lambda: os.close(master), lambda: os.close(slave))
