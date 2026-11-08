#!/usr/bin/env python3
"""Probe /dev/tty custody without running Rui or starting a Host."""
import fcntl
import os
import pty
import subprocess
import sys
import termios


def child(control):
    if control:
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError as error:
        print(f"control={control} stdin_tty={os.isatty(0)} stdout_tty={os.isatty(1)} errno={error.errno}", file=sys.stderr)
        return 1
    else:
        print(f"control={control} stdin_tty={os.isatty(0)} stdout_tty={os.isatty(1)} dev_tty_open=true", file=sys.stderr)
        os.close(fd)
        return 0


def run(control):
    master, slave = pty.openpty()
    try:
        result = subprocess.run([sys.executable, __file__, "--child", str(int(control))],
                                stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                                timeout=10, check=False, text=True)
        print(result.stderr.strip())
        print(f"exit={result.returncode}")
        return result.returncode
    finally:
        os.close(master)
        os.close(slave)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--child"]:
        sys.exit(child(bool(int(sys.argv[2]))))
    first = run(False)
    second = run(True)
    if first != 1 or second != 0:
        sys.exit(1)
