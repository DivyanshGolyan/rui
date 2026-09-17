"""Bounded startup and cleanup for Host processes used by integration evidence."""

import json
import os
import selectors
import subprocess
import threading
import time


READINESS_LIMIT = 16 * 1024
STDERR_TAIL_LIMIT = 16 * 1024


class MilestoneLog:
    """Collect test-only Host phase records without competing stderr readers."""

    def __init__(self, process):
        self.process = process
        self.condition = threading.Condition()
        self.records = []
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        for raw_line in self.process.stderr:
            try:
                record = json.loads(raw_line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if "rui_test_phase" not in record:
                continue
            with self.condition:
                self.records.append(record)
                self.condition.notify_all()

    def matching(self, phase, **fields):
        with self.condition:
            return [
                record
                for record in self.records
                if record["rui_test_phase"] == phase
                and all(record.get(name) == value for name, value in fields.items())
            ]

    def wait(self, phase, count=1, timeout=10, **fields):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                matches = [
                    record
                    for record in self.records
                    if record["rui_test_phase"] == phase
                    and all(record.get(name) == value for name, value in fields.items())
                ]
                if len(matches) >= count:
                    return matches
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(
                        f"timed out waiting for {count} {phase} milestones: "
                        f"{self.records[-12:]}"
                    )
                self.condition.wait(remaining)

    def close(self):
        self.thread.join(timeout=3)


class HostStartError(RuntimeError):
    def __init__(self, message, pid):
        super().__init__(message)
        self.pid = pid


def stop_process(process, timeout=10):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=timeout)
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()


def _tail(buffer, chunk, limit):
    buffer.extend(chunk)
    if len(buffer) > limit:
        del buffer[: len(buffer) - limit]


def _start_error(reason, process, stdout, stderr_tail):
    return HostStartError(
        f"{reason}; stdout={bytes(stdout)!r}; stderr_tail={bytes(stderr_tail)!r}",
        process.pid,
    )


def start_ready_process(args, *, timeout=10, required_fields=None):
    """Start a Host and transfer ownership only after one valid ready line."""
    process = subprocess.Popen(
        list(map(str, args)),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = bytearray()
    stderr_tail = bytearray()
    selector = selectors.DefaultSelector()
    try:
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise _start_error("Host readiness timed out", process, stdout, stderr_tail)
            for key, _ in selector.select(min(remaining, 0.1)):
                try:
                    read_limit = (
                        64 * 1024
                        if key.data == "stderr"
                        else READINESS_LIMIT + 1 - len(stdout)
                    )
                    chunk = os.read(key.fileobj.fileno(), read_limit)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stderr":
                    _tail(stderr_tail, chunk, STDERR_TAIL_LIMIT)
                    continue
                stdout.extend(chunk)
                if len(stdout) > READINESS_LIMIT:
                    raise _start_error(
                        "Host readiness exceeded 16 KiB", process, stdout, stderr_tail
                    )
                if b"\n" not in stdout:
                    continue
                raw_line = bytes(stdout).split(b"\n", 1)[0]
                try:
                    line = raw_line.decode("utf-8")
                    parts = line.split()
                    if not parts or parts[0] != "ready":
                        raise ValueError
                    fields = dict(part.split("=", 1) for part in parts[1:])
                except (UnicodeDecodeError, ValueError):
                    raise _start_error(
                        f"malformed Host readiness: {raw_line!r}",
                        process,
                        stdout,
                        stderr_tail,
                    ) from None
                for name, expected in (required_fields or {}).items():
                    if name not in fields or (
                        expected is not None and fields[name] != expected
                    ):
                        requirement = name if expected is None else f"{name}={expected}"
                        raise _start_error(
                            f"Host readiness missing {requirement}: {line}",
                            process,
                            stdout,
                            stderr_tail,
                        )
                os.set_blocking(process.stdout.fileno(), True)
                os.set_blocking(process.stderr.fileno(), True)
                return process, fields
            if process.poll() is not None:
                raise _start_error(
                    "Host exited before ready", process, stdout, stderr_tail
                )
    except BaseException:
        stop_process(process)
        raise
    finally:
        selector.close()
