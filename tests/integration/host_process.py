"""Bounded startup and cleanup for Host processes used by integration evidence."""

import http.server
import json
import mmap
import os
import pathlib
import selectors
import struct
import subprocess
import tempfile
import threading
import time


READINESS_LIMIT = 16 * 1024
STDERR_TAIL_LIMIT = 16 * 1024
# Explicit finite native populations, not an execution-duration history.
# list: 101 configuration + 37 list exchanges, two endpoints each.
# status: 12 simultaneous clients + 40 repeated status calls + at most 20
# setup/guard probes, three phases per connection, plus two boundaries.
# stop: at most 321 Action probes (8 seconds / 25ms interval + final probe)
# plus twenty non-poll numbered exchanges, each with a release; five stop
# issuers, twelve observe classifications, three two-phase cleanup owners,
# capture entry and Bash handoff. No release is filtered out by request kind.
# control: at most 50 inspection attempts (capture + gate), four model owners
# (ten selected phases), three controls (hint + timing), two boundaries.
# dispatch: seven controls with queued/acquired/released endpoints; the first
# rollback or preparation advance per separately observed Host, not retry history.
OBSERVATION_LIMITS = {"list": 2 * (101 + 37), "status": 3 * (12 + 40 + 20) + 2,
                      "stop": 321 + 20 + 5 + 12 + 3 * 2 + 1 + 1,
                      "control": 50 * 2 + 4 * 10 + 3 * 2 + 2, "dispatch": 7 * 3 + 1}
OBSERVATION_STATE_BYTES = 5 * 8  # version, pid, run, reserved count/loss, active writers.
OBSERVATION_FIELDS = (
    "rui_test_phase", "at_ns", "subject_kind", "subject", "turn", "operation",
    "attempt", "action", "scratch_used_bytes", "command_key", "kind", "control_key",
    "store_queued_at_ns", "lock_acquired_at_ns", "store_complete_at_ns",
    "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns",
    "post_commit_reply_ns", "host_total_ns", "start_ns", "wait_ns", "custody_occupied",
)


class _Observations:
    """Fixture-owned bounded native channel; arrivals need not be sequence ordered."""

    def __init__(self, process, reader, plan, state):
        self.process, self.reader, self.limit = process, reader, OBSERVATION_LIMITS[plan]
        self.state = state
        self.final_state = None
        self.condition = threading.Condition()
        self.records = []
        self.pending_records = {}
        self.error = None
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        pending = bytearray()
        try:
            while chunk := os.read(self.reader, 512):
                pending.extend(chunk)  # At most one partial frame + one 512-byte read.
                while len(pending) >= 2:
                    length = struct.unpack_from("<H", pending)[0]
                    assert 28 <= length <= 512, "invalid observation frame length"
                    if len(pending) < length:
                        break
                    frame = bytes(pending[:length])
                    del pending[:length]
                    self._accept(frame)
            assert not pending, "incomplete observation at Host exit"
            assert not self.pending_records, "missing observation sequence at Host exit"
        except Exception as error:
            with self.condition:
                self.error = error
                self.condition.notify_all()
        finally:
            os.close(self.reader)

    def _accept(self, frame):
        length, version, lost, sequence, run, process = struct.unpack_from("<HBBQQQ", frame)
        assert length == len(frame) and version == 1 and lost in (0, 1), "invalid observation header"
        assert not lost, "native observation loss invalidates evidence"
        assert process == self.process.pid and run > 0 and sequence > 0, "foreign observation"
        record = {"process": str(process), "run": str(run), "sequence": str(sequence),
                  "clock": "awake_ns", "trace_lost": bool(lost)}
        offset = 28
        while offset < length:
            assert offset + 3 <= length, "incomplete observation field"
            field, size = struct.unpack_from("<BH", frame, offset)
            offset += 3
            assert field < len(OBSERVATION_FIELDS) and offset + size <= length, "invalid observation field"
            name = OBSERVATION_FIELDS[field]
            assert name not in record, "duplicate observation field"
            record[name] = frame[offset:offset + size].decode("utf-8")
            offset += size
        assert "rui_test_phase" in record, "missing observation phase"
        with self.condition:
            assert len(self.records) + len(self.pending_records) < self.limit, "observation population exceeded fixture bound"
            assert sequence > len(self.records) and sequence not in self.pending_records, "duplicate observation sequence"
            assert all(item["run"] == record["run"] for item in self.records), "mixed observation runs"
            assert all(item["run"] == record["run"] for item in self.pending_records.values()), "mixed observation runs"
            self.pending_records[sequence] = record
            # Expose only a complete selected prefix, never 'sorted so far'.
            while len(self.records) + 1 in self.pending_records:
                self.records.append(self.pending_records.pop(len(self.records) + 1))
            self.condition.notify_all()

    def close(self):
        assert self.process.poll() is not None, "observation custody ended before reap"
        self.thread.join(timeout=3)
        assert not self.thread.is_alive(), "observation channel did not drain after reap"
        if self.final_state is None:
            try:
                self.final_state = struct.unpack("<QQQQQ", self.state[:])
            finally:
                self.state.close()
        assert self.error is None, f"Host observation failed: {self.error}"
        version, process, run, state, active = self.final_state
        assert version == 1 and process == self.process.pid and run > 0, "missing/foreign final observation state"
        assert active == 0, "Host exited during observation publication"
        assert not state & 1, "final native observation loss invalidates evidence"
        assert state >> 1 == len(self.records), "missing final observation sequence"
        assert all(item["run"] == str(run) for item in self.records), "mixed final observation run"


def canonical_fixture_root(path):
    """Resolve a newly created private root before deriving fixture identities."""
    return pathlib.Path(path).resolve(strict=True)


class TestHTTPServer(http.server.ThreadingHTTPServer):
    """Stop fixture accept loops promptly; response timing belongs to each case."""

    def serve_forever(self, poll_interval=0.01):
        super().serve_forever(poll_interval=poll_interval)


class ReleaseGate:
    """Hold native FIFO readers until release; later arrivals pass the removed name."""

    def __init__(self, path):
        self.path = path
        os.mkfifo(path, mode=0o600)
        try:
            self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        except BaseException:
            path.unlink()
            raise

    def release(self):
        if self.fd is not None:
            self.path.unlink()
            # Native nonblocking readers observe persistent EOF on their next
            # check; closing a FIFO does not wake every blocked read on macOS.
            os.close(self.fd)
            self.fd = None


class HostDiagnostics:
    """Sole stderr owner: retain bounded diagnostics and parse Host milestones."""

    def __init__(self, process):
        self.process = process
        self.observations = getattr(process, "rui_observations", None)
        self.condition = self.observations.condition if self.observations else threading.Condition()
        self.records = self.observations.records if self.observations else []
        self.stderr_tail = bytearray()
        self._read_error = None
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    @property
    def read_error(self):
        return self._read_error or (self.observations.error if self.observations else None)

    def _read(self):
        try:
            if self.observations:
                # Do not withhold a short fixture receipt waiting for filler
                # diagnostics or EOF. There is still exactly one stderr owner.
                while chunk := self.process.stderr.read1(4096):
                    with self.condition:
                        _tail(self.stderr_tail, chunk, STDERR_TAIL_LIMIT)
                return  # Optional stderr is never positive native evidence.
            for raw_line in self.process.stderr:
                with self.condition:
                    _tail(self.stderr_tail, raw_line, STDERR_TAIL_LIMIT)
                try:
                    record = json.loads(raw_line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(record, dict) or "rui_test_phase" not in record:
                    continue
                with self.condition:
                    self.records.append(record)
                    self.condition.notify_all()
        except Exception as error:
            self._read_error = error
            with self.condition:
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
                assert self.read_error is None, self.read_error
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
        assert self.process.poll() is not None, "Host diagnostics closed before process exit"
        self.thread.join(timeout=3)
        assert not self.thread.is_alive(), "Host stderr reader did not drain within 3 seconds"
        if self.observations:
            self.observations.close()
        assert self.read_error is None, f"Host stderr reader failed: {self.read_error}"

    def tail(self):
        with self.condition:
            return bytes(self.stderr_tail)


class HostStartError(RuntimeError):
    def __init__(self, message, pid):
        super().__init__(message)
        self.pid = pid


def stop_process(process, timeout=10):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=timeout)
    try:
        if getattr(process, "rui_observations", None):
            process.rui_observations.close()
    finally:
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


def start_ready_process(args, *, timeout=10, required_fields=None, env=None, stderr_pipe=None, observations=None):
    """Start a Host and transfer ownership only after one valid ready line."""
    # The caller retains the write descriptor; startup and reap own the reader.
    args = list(map(str, args))
    reader = writer = None
    state_file = state = None
    try:
        if observations is not None:
            assert observations in OBSERVATION_LIMITS
            reader, writer = os.pipe()
            os.set_blocking(writer, False)
            assert os.fpathconf(writer, "PC_PIPE_BUF") >= 512
            state_file = tempfile.TemporaryFile()
            state_file.truncate(OBSERVATION_STATE_BYTES)
            state = mmap.mmap(state_file.fileno(), OBSERVATION_STATE_BYTES, access=mmap.ACCESS_READ)
            args += ["--test-observation-fd", str(writer), "--test-observation-plan", observations,
                     "--test-observation-state-fd", str(state_file.fileno())]
        process = subprocess.Popen(
            args, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if stderr_pipe is None else stderr_pipe[1], env=env,
            pass_fds=() if writer is None else (writer, state_file.fileno()),
        )
        if observations is not None:
            process.rui_observations = _Observations(process, reader, observations, state)
            reader = None  # Reader custody starts before readiness collection.
            state = None  # Mapping custody persists through reap, including SIGKILL.
    finally:
        if state_file is not None:
            state_file.close()
        if state is not None:
            state.close()
        if writer is not None:
            os.close(writer)
        if reader is not None:
            os.close(reader)
    if stderr_pipe is not None:
        process.stderr = stderr_pipe[0]
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
                process.rui_ready_fields = fields
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
