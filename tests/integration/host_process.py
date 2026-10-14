"""Bounded startup and cleanup for Host processes used by integration evidence."""

import atexit
import http.server
import ctypes
import functools
import json
import mmap
import os
import pathlib
import selectors
import stat
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
# setup/guard probes, three phases per connection, two boundaries and two Bash admissions.
# stop: at most 321 Action probes (8 seconds / 25ms interval + final probe)
# plus twenty non-poll numbered exchanges, each with a release; five stop
# issuers, twelve observe classifications, three two-phase cleanup owners,
# capture entry and Bash handoff. No release is filtered out by request kind.
# control: at most 50 inspection attempts (capture + gate), four model owners
# (ten selected phases), three controls (hint + timing), two boundaries.
# control_peers: gated contention owns four 8s/25ms observation polls (321 each,
# conservatively including a boundary probe), fifty total inspections, and six
# setup/control exchanges. This exceeds real contention (2*321+38), delivery
# (321+21), capacity (37), admission (11), and delivery restart (2).
# Each exchange has start/release and at most two inspection/control phases;
# four model owners have ten phases, plus two lifecycle boundaries and eight
# separately issued unnumbered releases. These are test-only retained records.
# PeerCensus enforces issuance bounds before traffic, not on received records.
# dispatch: seven controls with queued/acquired/released endpoints; the first
# rollback or preparation advance per separately observed Host, not retry history.
# capture: one gate, one exact cancellation and one injected resume failure.
# No cleanup or polling history; public drainage remains its separate oracle.
# recovery: two Bash Attempts with handoff + three cuts, two model proposal handoffs.
# managed: three preparations/transfers, at most three injected delayed handoffs.
# bash_cleanup: reuse has four model attempts and two Bash owners, three
# endpoints each. Inspections: three 8s polls, one 15s drain, one 5s
# emergency drain (25ms intervals, including final probes), six fixed reads.
# bash_pipes: one held leader observation, one permission and one Session stop.
PEER_EXCHANGE_LIMIT = 4 * 321 + 50 + 6
OBSERVATION_LIMITS = {"list": 2 * (101 + 37), "status": 3 * (12 + 40 + 20) + 2 + 2,
                      "stop": 321 + 20 + 5 + 12 + 3 * 2 + 1 + 1,
                      "control": 50 * 2 + 4 * 10 + 3 * 2 + 2, "dispatch": 7 * 3 + 1,
                      "control_peers": 4 * PEER_EXCHANGE_LIMIT + 4 * 10 + 2 + 8,
                      "capture": 3, "recovery": 2 * 4 + 2, "managed": 9,
                      "bash_cleanup": 6 * 3 + 3 * 321 + 601 + 201 + 6,
                      "bash_pipes": 1 + 2}
OBSERVATION_STATE_BYTES = 5 * 8  # version, pid, run, reserved count/loss, active writers.
OBSERVATION_SEALED = 1 << 63
OBSERVATION_FIELDS = (
    "rui_test_phase", "at_ns", "subject_kind", "subject", "turn", "operation",
    "attempt", "action", "scratch_used_bytes", "command_key", "kind", "control_key",
    "store_queued_at_ns", "lock_acquired_at_ns", "store_complete_at_ns",
    "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns",
    "post_commit_reply_ns", "host_total_ns", "start_ns", "wait_ns", "custody_occupied",
    "written_bytes", "http_version", "connection_id", "new_connections",
)


@functools.cache
def _failure_destination(configured):
    # One bounded allowlisted destination per interpreter, outside disposable
    # fixture roots. Local runs need the same preservation as hosted runs.
    destination = pathlib.Path(configured or tempfile.mkdtemp(prefix="rui-fixture-failures-"))
    assert not destination.is_symlink(), "failure retention destination is a symlink"
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    assert destination.is_dir(), "failure retention destination is not a directory"
    if configured is None:
        atexit.register(lambda: destination.rmdir() if destination.exists() and not any(destination.iterdir()) else None)
    return destination.resolve()


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
        self.plan = plan
        self.state = state
        self.final_state = None
        self.sealed = False
        self.failure_preserved = False
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

    def wait_for_publication_retirement(self, deadline):
        """Drain received publication custody without sealing an intentional cut.

        The caller's held workload gate supplies its semantic cut. This sample
        does not exclude future publishers; immutable post-reap validity does.
        """
        version, process, run, _, _ = struct.unpack("<QQQQQ", self.state[:])
        assert version == 1 and process == self.process.pid and run > 0, "missing/foreign crash observation state"
        address = ctypes.addressof(ctypes.c_char.from_buffer(self.state))
        native = _observation_atomics()
        while True:
            active = native.observation_load(address + 32)
            count_loss = native.observation_load(address + 24)
            with self.condition:
                assert self.error is None, f"Host observation failed: {self.error}"
                assert not active & OBSERVATION_SEALED, "intentional crash observation admission was sealed"
                assert not count_loss & 1, "native loss before intentional crash"
                assert all(item["run"] == str(run) for item in self.records), "mixed crash observation runs"
                assert self.process.poll() is None, "Host exited before intentional crash"
                assert time.monotonic() < deadline, "publication custody did not retire within crash budget"
                if active == 0 and count_loss >> 1 == len(self.records):
                    return
            time.sleep(.001)

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
        if self.failure_preserved:
            return
        arguments = list(map(str, getattr(self.process, "args", ())))
        if "--store" not in arguments or snapshot is None:
            return
        root = pathlib.Path(arguments[arguments.index("--store") + 1]).parent
        path = root / f"observation-failure-{self.process.pid}.json"
        snapshot = dict(snapshot, post_reap_state=self.final_state,
                        final_error=type(sys.exc_info()[1]).__name__ if sys.exc_info()[1] is not None else None)
        if not preserve_failure_metadata(path, lambda: snapshot):
            return
        self.failure_preserved = True
        try:
            destination = getattr(self.process, "rui_failure_destination", None)
            if destination is None:
                destination = _failure_destination(os.environ.get("RUI_FAILURE_ARTIFACTS"))
            # Same existing job-wide helper/caps, while root still exists.
            ci = str(pathlib.Path(__file__).resolve().parents[1] / "ci")
            sys.path.insert(0, ci)
            try:
                from run_selected import retain_failure_logs
                retain_failure_logs([root], destination)
            finally:
                sys.path.remove(ci)
            print(f"bounded fixture failure destination: {destination}", file=sys.stderr, flush=True)
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

    def assert_held(self):
        """Require the owned empty FIFO, not absence of a later effect."""
        assert self.fd is not None, "transition gate was released"
        descriptor, name = os.fstat(self.fd), self.path.lstat()
        assert stat.S_ISFIFO(name.st_mode), "transition gate is not a FIFO"
        assert (descriptor.st_dev, descriptor.st_ino) == (name.st_dev, name.st_ino), "transition gate was replaced"
        try:
            credit = os.read(self.fd, 1)
        except BlockingIOError:
            return
        raise AssertionError(f"transition gate was not held: {credit!r}")

    def release(self):
        if self.fd is not None:
            try:
                self.path.unlink()
            finally:
                # Native readers observe persistent EOF; unlink refusal must
                # still retire the fixture's descriptor, never skip cleanup.
                descriptor, self.fd = self.fd, None
                os.close(descriptor)


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
        process.rui_diagnostics = self  # Process disposal owns its sole stderr collector.

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
        self.require_native_receipt(phase)
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
        self.require_native_receipt(phase)
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

    def require_native_receipt(self, phase):
        plans = None
        if phase in ("capture_write_gate_entered", "transport_resume_capture_failure", "effect_stop_requested"):
            plans = ("capture", "stop") if phase == "capture_write_gate_entered" else ("capture",)
        elif phase in ("action_attempt_admitted", "action_result_ready", "action_result_committed"):
            plans = ("recovery", "status") if phase == "action_attempt_admitted" else ("recovery",)
        elif phase in ("preparation_completed", "codex_transfer"):
            plans = ("managed",)
        elif phase == "prepared_before_handoff":
            plans = ("managed", "control", "control_peers", "recovery")
        elif phase in ("cleanup_started", "cleanup_completed"):
            plans = ("control", "control_peers", "stop", "bash_cleanup")
        elif phase == "cleanup_release_observed":
            plans = ("bash_cleanup",)
        elif phase == "inspection_captured":
            plans = ("control", "control_peers", "bash_cleanup")
        elif phase in ("bash_leader_observed_with_open_pipes", "control_store_complete"):
            plans = ("bash_pipes",)
        if plans is not None:
            assert self.observations is not None and self.observations.plan in plans, (
                "required receipt needs native observation authority", phase)

    def snapshot_failure(self, collect):
        if sys.exc_info()[1] is None or hasattr(self.process, "rui_failure_snapshot"):
            return
        try:
            self.process.rui_failure_snapshot = dict(self.observations.snapshot(), fixture=collect())
        except Exception as error:
            try:
                print(f"Fixture boundary snapshot unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
            except Exception:
                pass  # Failure sampling cannot own release/reap or the primary error.

    def dispose_capture(self, gate, collect, *, resume_failures=0, controls=()):
        incoming_error = sys.exc_info()[1]
        self.snapshot_failure(collect)  # Before emergency release, not a later reconstruction.
        errors = []
        for dispose in (gate.release, lambda: stop_process(self.process)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        try:
            if errors:
                for error in errors:
                    try:
                        print(f"Capture fixture cleanup failed: {error}", file=sys.stderr)
                    except Exception:
                        pass
                if incoming_error is not None:
                    raise incoming_error from errors[0]
                raise errors[0]
            if incoming_error is None:
                assert len(self.matching("capture_write_gate_entered")) == 1, self.records
                assert len(self.matching("transport_resume_capture_failure", subject_kind="cause", subject="local_capture")) == resume_failures, self.records
                assert Counter(record.get("control_key") for record in self.matching("effect_stop_requested")) == Counter(controls), self.records
                assert len(self.records) == 1 + resume_failures + len(controls), self.records
        except BaseException:
            self.snapshot_failure(collect)
            self.observations.preserve_failure(getattr(self.process, "rui_failure_snapshot", None))
            raise

    def borrower_release(self, started, deadline):
        records = self.wait("connection_resources_released", subject_kind="request_number",
            subject=started["subject"], timeout=max(0, deadline - time.monotonic()))
        assert len(records) == 1, (started, records)
        released = records[0]
        assert released["process"] == started["process"] == str(self.process.pid), (started, released)
        assert released["run"] == started["run"] and released["clock"] == started["clock"] == "awake_ns", (started, released)
        assert int(released["sequence"]) > int(started["sequence"]), (started, released)
        assert int(released["at_ns"]) >= int(started["at_ns"]), (started, released)
        assert int(released["at_ns"]) <= int(deadline * 1e9), ("release exceeded original deadline", released)
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
        assert self._read_error is None, f"Host stderr reader failed: {self._read_error}"

    def tail(self):
        with self.condition:
            return bytes(self.stderr_tail)


class PeerCensus:
    """Caller-issued exchanges; reply completion never refunds admission."""

    def __init__(self, diagnostics):
        assert diagnostics.observations is not None and diagnostics.observations.plan == "control_peers"
        self.diagnostics = diagnostics
        self.routes = []
        self.places = []
        self.borrowers = {}

    def expect(self, route):
        assert len(self.routes) < PEER_EXCHANGE_LIMIT, "peer fixture exhausted numbered exchange population"
        request = len(self.routes)
        self.routes.append(route)
        return request

    def started(self, request, deadline):
        records = self.diagnostics.wait(
            "connection_request_" + self.routes[request], subject_kind="request_number",
            subject=str(request), timeout=max(0, deadline - time.monotonic()))
        assert len(records) == 1, records
        assert time.monotonic() <= deadline, "peer start exceeded original deadline"
        return records[0]

    def release(self, request, deadline):
        record = self.diagnostics.borrower_release(self.started(request, deadline), deadline)
        assert time.monotonic() <= deadline, "peer release exceeded original deadline"
        return record

    def call(self, route, invoke, *, timeout=15, deadline=None):
        if deadline is None:
            deadline = time.monotonic() + timeout
        assert time.monotonic() < deadline, "peer invocation exhausted original deadline"
        request = self.expect(route)
        value = invoke()
        self.release(request, deadline)
        return value

    def held(self, requests):
        for request in requests:
            assert not self.diagnostics.matching("connection_resources_released", subject=str(request)), request

    def open(self, route, invoke, *, timeout=15):
        deadline = time.monotonic() + timeout
        request = self.expect(route)
        connection = invoke()
        try:
            self.started(request, deadline)
            self.held([request])
        except BaseException:
            connection.close()
            raise
        self.borrowers[connection] = request
        return connection

    def close(self, connections, deadline):
        for connection in connections:
            request = self.borrowers[connection]
            connection.close()
            self.release(request, deadline)
            del self.borrowers[connection]

    def release_place(self, place, invoke, *, timeout=3):
        assert len(self.places) < 8, "peer fixture exhausted unnumbered place population"
        self.places.append(place)
        began_ns = time.monotonic_ns()
        deadline = time.monotonic() + timeout
        value = invoke()
        records = self.diagnostics.wait("connection_place_released", count=len(self.places),
            timeout=max(0, deadline - time.monotonic()))
        assert len(records) == len(self.places), records
        record = records[-1]
        assert record["subject_kind"] == "place" and record["subject"] == place, record
        assert began_ns <= int(record["at_ns"]) <= int(deadline * 1e9), record
        assert time.monotonic() <= deadline, "place release exceeded original deadline"
        return value

    def finish(self, deadline):
        assert not self.borrowers, "fixture retained peer sockets"
        self.diagnostics.borrower_census(deadline, self.routes)
        places = self.diagnostics.matching("connection_place_released")
        assert [record["subject"] for record in places] == self.places, places


class HostStartError(RuntimeError):
    def __init__(self, message, pid):
        super().__init__(message)
        self.pid = pid


def cleanup_failure(error):
    """Bound secondary diagnostics while retaining the failing owner and action."""
    try:
        detail = str(error)
        if len(detail) > 512:
            marker = " [truncated]"
            detail = detail[:512 - len(marker)] + marker
    except BaseException:
        detail = "<message unavailable>"
    trace = error.__traceback__
    while trace is not None and trace.tb_next is not None:
        trace = trace.tb_next
    location = (f" at {pathlib.Path(trace.tb_frame.f_code.co_filename).name}:{trace.tb_lineno}"
                if trace is not None else "")
    return f"{type(error).__name__}{location}: {detail}"


def dispose_all(*disposals):
    """Run ordered fixture disposals without replacing an active body failure."""
    incoming_error = sys.exception()
    errors = []
    for index, dispose in enumerate(disposals, 1):
        try:
            dispose()
        except BaseException as error:
            errors.append((index, error))
    if errors:
        primary = incoming_error if incoming_error is not None else errors[0][1]
        for index, error in errors:
            try:
                primary.add_note(f"Fixture disposal {index} failed: {cleanup_failure(error)}")
            except BaseException:
                pass  # Secondary reporting cannot replace the primary failure.
        if incoming_error is None:
            raise primary


def stop_process(process, timeout=10, *, seal_observations=True):
    deadline = time.monotonic() + timeout
    errors = []
    incoming_error = sys.exc_info()[1]
    snapshot = None
    observations = getattr(process, "rui_observations", None)
    if seal_observations and process.poll() is None and observations is not None:
        try:
            # Leave bounded reap credit even when publication retirement fails.
            observations.dispose(deadline - min(1, timeout / 2))
        except BaseException as error:
            errors.append(error)  # Still kill/reap; failed disposal never becomes acceptance.
    if observations is not None:
        try:
            snapshot = getattr(process, "rui_failure_snapshot", None) or observations.snapshot()
        except Exception:
            pass  # Final native validity remains mandatory even if capture fails.
    try:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=max(0, deadline - time.monotonic()))
    except BaseException as error:
        errors.append(error)
    diagnostics = getattr(process, "rui_diagnostics", None)
    for close in (observations.close if observations else None, diagnostics.close if diagnostics else None,
                  process.stdout.close if process.stdout else None, process.stderr.close if process.stderr else None):
        if close is None:
            continue
        try:
            close()
        except BaseException as error:
            errors.append(error)
    try:
        if errors:
            for error in errors:
                try:
                    print(f"Host cleanup failed: {cleanup_failure(error)}", file=sys.stderr)
                except BaseException:
                    pass
            if incoming_error is None:
                raise errors[0]
            try:
                incoming_error.add_note("Host cleanup failed: " + ", ".join(cleanup_failure(error) for error in errors))
            except BaseException:
                pass  # Secondary reporting cannot replace the primary failure.
    finally:
        if (incoming_error is not None or errors) and observations is not None:
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
    if "--test-response-capture-gate-path" in args:
        observations = observations or "capture"
        assert observations in ("capture", "stop"), "capture gate requires a selecting native plan"
        if "--test-phase-trace" not in args:
            args.append("--test-phase-trace")
    if "--test-transition" in args and args[args.index("--test-transition") + 1] in (
            "action-attempt-admitted", "prepared-before-handoff", "action-result-ready", "action-result-committed"):
        transition = args[args.index("--test-transition") + 1]
        observations = observations or "recovery"
        plans = ("recovery", "status") if transition == "action-attempt-admitted" else ("recovery",)
        assert observations in plans, "Bash crash cut requires a selecting native plan"
    destination = _failure_destination((env if env is not None else os.environ).get("RUI_FAILURE_ARTIFACTS")) if observations is not None else None
    if destination is not None and "--store" in args:
        root = pathlib.Path(args[args.index("--store") + 1]).resolve().parent
        assert not destination.is_relative_to(root), "failure retention must survive fixture-root deletion"
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
            process.rui_failure_destination = destination
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
