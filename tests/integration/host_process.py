"""Bounded startup and cleanup for Host processes used by integration evidence."""

import http.server
import ctypes
import functools
import json
import mmap
import os
import pathlib
import selectors
import struct
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter


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
OBSERVATION_SEALED = 1 << 63
OBSERVATION_FIELDS = (
    "rui_test_phase", "at_ns", "subject_kind", "subject", "turn", "operation",
    "attempt", "action", "scratch_used_bytes", "command_key", "kind", "control_key",
    "store_queued_at_ns", "lock_acquired_at_ns", "store_complete_at_ns",
    "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns",
    "post_commit_reply_ns", "host_total_ns", "start_ns", "wait_ns", "custody_occupied",
)


@functools.cache
def _observation_atomics():
    """Two native atomics on the existing mapping, not torn Python stores.

    One small library per fixture interpreter; private temporary custody ends
    at interpreter exit. Built only when observation is enabled, before startup.
    """
    directory = tempfile.TemporaryDirectory(prefix="rui-observation-atomics-")
    library = pathlib.Path(directory.name) / "atomics.so"
    source = r"""
#include <stdatomic.h>
#include <stdint.h>
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2, "native lock-free u64 required");
_Static_assert(sizeof(_Atomic(uint64_t)) == 8, "observation codec width");
uint64_t observation_seal(void *p) {
    return atomic_fetch_or_explicit((_Atomic(uint64_t) *)p,
        UINT64_C(1) << 63, memory_order_acq_rel);
}
uint64_t observation_load(void *p) {
    return atomic_load_explicit((_Atomic(uint64_t) *)p, memory_order_acquire);
}
"""
    subprocess.run(["cc", "-std=c11", "-shared", "-fPIC", "-x", "c", "-", "-o", str(library)],
                   input=source, text=True, check=True, timeout=10)
    assert library.stat().st_size <= 64 * 1024, "fixed-source atomic accessor exceeds fixture setup bound"
    native = ctypes.CDLL(str(library))
    native.directory = directory
    for name in ("observation_seal", "observation_load"):
        operation = getattr(native, name)
        operation.argtypes = [ctypes.c_void_p]
        operation.restype = ctypes.c_uint64
    return native


class _Observations:
    """Fixture-owned bounded native channel; arrivals need not be sequence ordered."""

    def __init__(self, process, reader, plan, state):
        self.process, self.reader, self.limit = process, reader, OBSERVATION_LIMITS[plan]
        self.state = state
        self.final_state = None
        self.sealed = False
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

    def dispose(self, deadline):
        """Revoke new publications, then drain existing custody before SIGKILL.

        Required owner endpoints/populations remain the caller's independent
        oracle. This is channel closure, never proof of semantic quiescence.
        """
        version, process, run, _, _ = struct.unpack("<QQQQQ", self.state[:])
        assert version == 1 and process == self.process.pid and run > 0, "missing/foreign disposal state"
        address = ctypes.addressof(ctypes.c_char.from_buffer(self.state))
        native = _observation_atomics()
        native.observation_seal(address + 32)
        self.sealed = True
        while True:
            active = native.observation_load(address + 32)
            count_loss = native.observation_load(address + 24)
            with self.condition:
                assert self.error is None, f"Host observation failed: {self.error}"
                assert not count_loss & 1, "native loss during observation disposal"
                if active == OBSERVATION_SEALED and count_loss >> 1 == len(self.records):
                    return
            assert self.process.poll() is None, "Host exited during observation disposal"
            assert time.monotonic() < deadline, "observation custody did not retire within disposal budget"
            time.sleep(.001)

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
        assert active & ~OBSERVATION_SEALED == 0, "Host exited during observation publication"
        assert bool(active & OBSERVATION_SEALED) == self.sealed, "foreign/reopened observation admission"
        assert not state & 1, "final native observation loss invalidates evidence"
        assert state >> 1 == len(self.records), "missing final observation sequence"
        assert all(item["run"] == str(run) for item in self.records), "mixed final observation run"

    def snapshot(self):
        # Bounded detached values before kill. Persistence must not spend reap
        # credit; these sampled facts never claim an atomic owner-state census.
        with self.condition:
            return {
                "stage": "pre_kill" if self.process.poll() is None else "already_reaped",
                "atomic_census": False, "process": self.process.pid,
                "returncode": self.process.poll(),
                "shared_state": self.final_state or struct.unpack("<QQQQQ", self.state[:]),
                "records": list(self.records), "pending": dict(self.pending_records),
                "reader_error": type(self.error).__name__ if self.error is not None else None,
            }

    def preserve_failure(self, snapshot):
        """Persist sampled facts after reap, before fixture-root deletion."""
        arguments = list(map(str, getattr(self.process, "args", ())))
        if "--store" not in arguments or snapshot is None:
            return
        root = pathlib.Path(arguments[arguments.index("--store") + 1]).parent
        path = root / f"observation-failure-{self.process.pid}.json"
        snapshot = dict(snapshot, post_reap_state=self.final_state,
                        final_error=type(sys.exc_info()[1]).__name__ if sys.exc_info()[1] is not None else None)
        if not preserve_failure_metadata(path, lambda: snapshot):
            return
        try:
            destination = os.environ.get("RUI_FAILURE_ARTIFACTS")
            if destination:
                # Same existing job-wide helper/caps, while root still exists.
                ci = str(pathlib.Path(__file__).resolve().parents[1] / "ci")
                sys.path.insert(0, ci)
                try:
                    from run_selected import retain_failure_logs
                    retain_failure_logs([root], pathlib.Path(destination))
                finally:
                    sys.path.remove(ci)
        except Exception as error:
            try:
                print(f"Native failure copy unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
            except Exception:
                pass
        finally:
            try:
                print(f"retained native observation failure state: {root}", file=sys.stderr, flush=True)
            except Exception:
                pass  # Optional reporting must never replace teardown failure.


def preserve_failure_metadata(path, collect):
    """Best-effort bounded fixture facts, including fallible metadata sampling."""
    try:
        data = (json.dumps(collect(), ensure_ascii=False) + "\n").encode()
        assert len(data) <= 1024 * 1024, "fixture failure metadata exceeds file bound"
        with path.open("xb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(data)
        return True
    except Exception as error:
        try:
            print(f"Fixture failure metadata unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
        except Exception:
            pass
        return False  # Evidence is unavailable, not grounds to skip mandatory cleanup.


def canonical_fixture_root(path):
    """Resolve a newly created private root before deriving fixture identities."""
    return pathlib.Path(path).resolve(strict=True)


def wait_for_execution_release(inspect, deadline):
    """Observe both accounting totals in one timely reply, not permanent idleness."""
    execution = None
    while True:
        remaining = min(15, deadline - time.monotonic())
        assert remaining > 0, ("custody drainage exhausted original deadline", execution)
        execution = inspect(remaining)
        assert time.monotonic() < deadline, ("custody drainage exceeded original deadline", execution)
        assert execution["dispatch_fenced"] is False, execution
        if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0":
            return execution
        time.sleep(min(0.025, max(0, deadline - time.monotonic())))


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
        self.inspection_attempts = 0
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

    def claim_inspection(self, limit=50):
        # Caller-issued attempts, not a native prefix that can still be in flight.
        assert self.inspection_attempts < limit, "custody drainage exhausted inspection population"
        self.inspection_attempts += 1

    def wait_model_cleanup(self, processing, deadline):
        remaining = deadline - time.monotonic()
        assert remaining > 0, "result exhausted physical cleanup deadline"
        records = self.wait(
            "cleanup_completed", timeout=remaining,
            turn=processing["turn"], operation=processing["operation"],
            attempt=processing["attempt"], action=None,
        )
        assert len(records) == 1, records
        assert time.monotonic() < deadline, "cleanup endpoint arrived after original deadline"
        return records[0]

    def assert_model_cleanup_census(self, *processings):
        # After reap/drain, reject extra or duplicate owners. Final census
        # cannot supply an endpoint missing within its original wait budget.
        expected = Counter(
            (value["turn"], value["operation"], value["attempt"], None)
            for value in processings
        )
        actual = Counter(
            (value.get("turn"), value.get("operation"), value.get("attempt"), value.get("action"))
            for value in self.matching("cleanup_completed")
        )
        assert actual == expected, (actual, expected)

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

    def borrower_release(self, started, deadline):
        records = self.wait("connection_resources_released", subject_kind="request_number",
            subject=started["subject"], timeout=max(0, deadline - time.monotonic()))
        assert len(records) == 1, (started, records)
        released = records[0]
        assert released["process"] == started["process"] == str(self.process.pid), (started, released)
        assert released["run"] == started["run"] and released["clock"] == started["clock"] == "awake_ns", (started, released)
        assert int(released["sequence"]) > int(started["sequence"]), (started, released)
        assert int(released["at_ns"]) >= int(started["at_ns"]), (started, released)
        return released

    def borrower_census(self, deadline, expected_routes):
        # Fixture-issued exchanges, not received records, define this population.
        with self.condition:
            while sum(record["rui_test_phase"].startswith("connection_request_")
                      for record in self.records) < len(expected_routes):
                assert self.read_error is None, self.read_error
                remaining = deadline - time.monotonic()
                assert remaining > 0, "missing required borrower start population"
                self.condition.wait(remaining)
            started = [record for record in self.records
                       if record["rui_test_phase"].startswith("connection_request_")]
        assert len(started) == len(expected_routes), (expected_routes, started)
        assert sorted(int(record["subject"]) for record in started) == list(range(len(expected_routes))), started
        for record in started:
            assert record["subject_kind"] == "request_number", record
            assert record["rui_test_phase"] == f"connection_request_{expected_routes[int(record['subject'])]}", record
        released = [self.borrower_release(record, deadline) for record in started]
        assert len(self.matching("connection_resources_released")) == len(expected_routes), released
        return released

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
    deadline = time.monotonic() + timeout
    disposal_error = None
    incoming_error = sys.exc_info()[1]
    snapshot = None
    observations = getattr(process, "rui_observations", None)
    if process.poll() is None and observations is not None:
        try:
            # Leave bounded reap credit even when publication retirement fails.
            observations.dispose(deadline - min(1, timeout / 2))
        except BaseException as error:
            disposal_error = error  # Still kill/reap; failed disposal never becomes acceptance.
    if observations is not None:
        try:
            snapshot = observations.snapshot()
        except Exception:
            pass  # Final native validity remains mandatory even if capture fails.
    try:
        try:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=max(0, deadline - time.monotonic()))
        finally:
            if observations is not None:
                observations.close()
        if disposal_error is not None:
            raise disposal_error
    finally:
        failed = incoming_error is not None or disposal_error is not None or sys.exc_info()[1] is not None
        try:
            if process.stdout is not None:
                process.stdout.close()
        finally:
            try:
                if process.stderr is not None:
                    process.stderr.close()
            finally:
                if failed and observations is not None:
                    observations.preserve_failure(snapshot)


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
            _observation_atomics()  # Test setup is outside the original readiness deadline.
            reader, writer = os.pipe()
            os.set_blocking(writer, False)
            assert os.fpathconf(writer, "PC_PIPE_BUF") >= 512
            state_file = tempfile.TemporaryFile()
            state_file.truncate(OBSERVATION_STATE_BYTES)
            state = mmap.mmap(state_file.fileno(), OBSERVATION_STATE_BYTES, access=mmap.ACCESS_WRITE)
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
