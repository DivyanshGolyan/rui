"""Bounded startup and cleanup for Host processes used by integration evidence."""

import atexit
import http.client
import http.server
import ctypes
import errno
import functools
import io
import json
import mmap
import os
import pathlib
import selectors
import socket
import socketserver
import sqlite3
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter

import h2.config
import h2.connection
import h2.errors
import h2.events
import h2.exceptions
import h2.settings


class _ClosingConnection(sqlite3.Connection):
    """Plain sqlite3 only commits at the end of `with`. A Host cannot open a
    Store that any other connection holds (ARCHITECTURE.md, "Store
    durability"), so every fixture connection closes with its block."""

    def __exit__(self, *failure):
        try:
            return super().__exit__(*failure)
        finally:
            self.close()


sqlite3.connect = functools.partial(sqlite3.connect, factory=_ClosingConnection)

READINESS_LIMIT = 16 * 1024
STDERR_TAIL_LIMIT = 16 * 1024
# Ten held inspections can each emit request, capture and gate-wait receipts
# before their FIFO stops them. Provision this cohort before concurrent writes;
# this is not whole-plan capacity or a guarantee against reader starvation.
OBSERVATION_STARTUP_CREDIT = 10 * 3 * 512
# Explicit finite native populations, not an execution-duration history.
# list: 102 configuration + 42 list exchanges, two endpoints each. Five list
# exchanges and one relabel are the `--since` cases.
# status: 12 simultaneous clients + 40 repeated status calls + at most 20
# setup/guard probes, three phases per connection, two boundaries and two Bash admissions.
# stop: at most 321 Action probes (8 seconds / 25ms interval + final probe)
# plus twenty-three non-poll numbered exchanges, each with a release; five stop
# issuers, twelve observe classifications, three two-phase cleanup owners,
# Bash handoff, three Message classification/header pairs and
# one owned report gate. No release is filtered out by request kind.
# control: at most 50 inspection attempts (capture + gate), four model owners
# (ten selected phases), three controls (hint + timing), two boundaries.
# control_peers: gated contention owns four 8s/25ms observation polls (321 each,
# conservatively including a boundary probe), fifty total inspections, and six
# setup/control exchanges. This also covers the smaller capacity and delivery
# populations and admission's 103 numbered exchanges.
# Each exchange has start/release and at most two inspection/control phases;
# four model owners have ten phases, plus two lifecycle boundaries and eight
# separately issued unnumbered releases. These are test-only retained records.
# PeerCensus enforces issuance bounds before traffic, not on received records.
# transport: at most 100 configurations and twenty waves of 100 Messages,
# 100 result reads, 100 initial result probes plus 1,801 failed probes within
# the shared 45s/25ms budget, and 801 drain inspections within 20s/25ms.
# The smaller two-wave held-stream case has a shared 40s result/drain budget.
# HostRequests enforces issuance before traffic; retain both native endpoints.
# dispatch: seven routed controls with queued/acquired/released endpoints; the first
# rollback or preparation advance and one exhausted-recovery hold per separately
# observed Host, not retry history.
# interrupt: one exact cancellation. No cleanup or polling history; public
# drainage remains its separate oracle.
# recovery: two Bash Attempts with handoff + three cuts, two model proposal handoffs.
# managed: three preparations/transfers, at most three injected delayed handoffs.
# bash_cleanup: reuse has four model attempts and two Bash owners, three
# endpoints each. Inspections: three 8s polls, one 15s drain, one 5s
# emergency drain (25ms intervals, including final probes), six fixed reads.
# bash_pipes: one held leader observation, one permission and one Session stop.
PEER_EXCHANGE_LIMIT = 4 * 321 + 50 + 6
TRANSPORT_EXCHANGE_LIMIT = 100 + 20 * (3 * 100 + 1801 + 801)
OBSERVATION_LIMITS = {"list": 2 * (102 + 42), "status": 3 * (12 + 40 + 20) + 2 + 2,
                      "stop": 321 + 23 + 5 + 12 + 3 * 2 + 1 + 3 * 2 + 1,
                      "control": 50 * 2 + 4 * 10 + 3 * 2 + 2, "dispatch": 7 * 4 + 1 + 1,
                      "control_peers": 4 * PEER_EXCHANGE_LIMIT + 4 * 10 + 2 + 8,
                      "transport": 2 * TRANSPORT_EXCHANGE_LIMIT,
                      "interrupt": 1, "recovery": 2 * 4 + 2, "managed": 9,
                      "bash_cleanup": 6 * 3 + 3 * 321 + 601 + 201 + 6,
                      "bash_pipes": 1 + 2}
OBSERVATION_STATE_BYTES = 5 * 8  # version, pid, run, reserved count/loss, active writers.
OBSERVATION_SEALED = 1 << 63
# Checked against native FieldId and the current schema by test_harness_contracts.py.
OBSERVATION_FIELDS = {
    0: "rui_test_phase",
    1: "at_ns",
    2: "subject_kind",
    3: "subject",
    4: "turn",
    5: "operation",
    6: "attempt",
    7: "action",
    8: "scratch_used_bytes",
    9: "command_key",
    10: "kind",
    11: "control_key",
    12: "store_queued_at_ns",
    13: "lock_acquired_at_ns",
    14: "store_complete_at_ns",
    15: "reply_complete_at_ns",
    16: "queue_wait_ns",
    17: "store_lock_wait_ns",
    18: "store_service_ns",
    19: "post_commit_reply_ns",
    20: "host_total_ns",
    21: "start_ns",
    22: "wait_ns",
    23: "custody_occupied",
    24: "new_connections",
    25: "replays",
    26: "work_bytes",
    27: "work_items",
    28: "request_bytes",
    29: "process_memory_current_bytes",
    30: "process_memory_highwater_bytes",
    31: "cache_used_bytes",
    32: "cache_spills",
    33: "hard_heap_limit_bytes",
    34: "page_size_bytes",
    35: "cache_size_setting",
    36: "cache_spill_threshold",
    37: "mmap_size_bytes",
    38: "synchronous",
    39: "temp_store",
    40: "busy_timeout_ms",
    41: "journal_mode",
}


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
            assert field in OBSERVATION_FIELDS and offset + size <= length, "invalid observation field"
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

        def retired():
            active = native.observation_load(address + 32)
            count_loss = native.observation_load(address + 24)
            with self.condition:
                assert self.error is None, f"Host observation failed: {self.error}"
                assert not active & OBSERVATION_SEALED, "intentional crash observation admission was sealed"
                assert not count_loss & 1, "native loss before intentional crash"
                assert all(item["run"] == str(run) for item in self.records), "mixed crash observation runs"
                assert self.process.poll() is None, "Host exited before intentional crash"
                return active == 0 and count_loss >> 1 == len(self.records)
        wait_for(retired, "publication custody to retire within crash budget", interval=.001, deadline=deadline)

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

        def retired():
            active = native.observation_load(address + 32)
            count_loss = native.observation_load(address + 24)
            with self.condition:
                assert self.error is None, f"Host observation failed: {self.error}"
                assert not count_loss & 1, "native loss during observation disposal"
                if active == OBSERVATION_SEALED and count_loss >> 1 == len(self.records):
                    return True
            assert self.process.poll() is None, "Host exited during observation disposal"
            return False
        wait_for(retired, "observation custody to retire within disposal budget", interval=.001, deadline=deadline)

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
            copy_failure_diagnostics(root, destination)  # While root still exists.
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


# The Store format fixtures expect, stated independently of src/store.zig so a
# format change must update its fixtures deliberately.
STORE_SCHEMA = 38


# Job-wide totals: sixteen roots, each with an equal share of 128 files and
# 16 MiB. Each root reserves one fixed slot by atomic mkdir, so concurrent
# fixtures (processes or threads) never overcommit and need no lock.
MAX_RETAINED_ROOTS = 16
MAX_RETAINED_FILES_PER_ROOT = 8
MAX_RETAINED_BYTES_PER_ROOT = 1024 * 1024
_PRIVATE_WORDS = ("store", "home", "credential", "auth", "scratch", "request", "provider")


def _labelled_diagnostic(name):
    number = name[len("observation-failure-"):-len(".json")]
    return name in ("probe.log", "pty-failure.json") or (
        name.startswith("observation-failure-") and name.endswith(".json")
        and number.isascii() and number.isdigit() and not number.startswith("0"))


def _reserve_slot(destination):
    for index in range(MAX_RETAINED_ROOTS):
        slot = pathlib.Path(destination) / f"root-{index:02d}"
        try:
            slot.mkdir(mode=0o700)
            return slot
        except FileExistsError:
            continue
    return None


def copy_failure_diagnostics(state, destination):
    """Copy one fixture root's labelled diagnostics; never open or query a Store.

    Only probe.log, pty-failure.json and observation-failure-N.json, never
    SQLite, HOME, credentials, request records, provider capture or scratch.
    Symlinks and special files are not followed. Oversized files are omitted
    whole, not truncated. Each call copies into its own reserved slot, so
    concurrent fixtures never share, replace or overcommit one.
    """
    state = pathlib.Path(state)
    if state.is_symlink() or not state.is_dir():
        return
    target, files, remaining = None, 0, MAX_RETAINED_BYTES_PER_ROOT
    for directory, children, names in os.walk(state, followlinks=False):
        children[:] = sorted(name for name in children if not (
            name.startswith(".") or any(word in name.lower() for word in _PRIVATE_WORDS)
            or (pathlib.Path(directory) / name).is_symlink()))
        for name in sorted(names):
            if not _labelled_diagnostic(name):
                continue
            if files >= MAX_RETAINED_FILES_PER_ROOT:
                return
            source = pathlib.Path(directory) / name
            limit = remaining
            try:
                with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                        continue
                    data = stream.read(limit + 1)
            except OSError as error:
                print(f"Failure diagnostic copy unavailable: {error}", file=sys.stderr, flush=True)
                continue
            if len(data) > limit:
                continue
            if target is None:
                target = _reserve_slot(destination)
                if target is None:
                    return  # Every job-wide slot is taken.
            output = target / source.relative_to(state)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            remaining -= len(data)
            files += 1


def retain_failure_state(label, state):
    """Report a retained fixture root; in CI also copy its labelled diagnostics.

    Best effort throughout: nothing here may replace the fixture's original
    failure or skip the caller's later disposal.
    """
    try:
        print(f"retained {label}: {state}", file=sys.stderr, flush=True)
        if os.environ.get("RUI_FAILURE_ARTIFACTS"):
            copy_failure_diagnostics(state, _failure_destination(os.environ["RUI_FAILURE_ARTIFACTS"]))
    except Exception as error:
        try:
            print(f"Failure diagnostic retention unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
        except Exception:
            pass


def canonical_fixture_root(path):
    """Resolve a newly created private root before deriving fixture identities."""
    return pathlib.Path(path).resolve(strict=True)


def is_peer_disconnect(error):
    """Classify socket closure; callers decide whether closure is expected."""
    return isinstance(error, (BrokenPipeError, ConnectionResetError)) or (
        isinstance(error, OSError) and error.errno == errno.ENOTCONN)


class WaitTimeout(AssertionError):
    pass


def wait_for(observe, description, timeout=8, interval=0.025, *, deadline=None, ready=bool):
    """The one place a test sleeps to wait (CODING_STANDARDS.md#evidence).

    Returns the first observation `ready` accepts that finished before the
    deadline. An inspection can block past its caller's budget, and a clean
    observation after the deadline is not evidence of timely reclamation.
    """
    if deadline is None:
        deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        value = observe()
        if time.monotonic() >= deadline:
            break
        if ready(value):
            return value
        time.sleep(interval)
    raise WaitTimeout(f"timed out waiting for {description}; last observed {value!r}")


def wait_for_execution_release(inspect, deadline):
    """Observe both accounting totals in one timely reply, not permanent idleness."""
    def execution():
        remaining = min(15, deadline - time.monotonic())
        assert remaining > 0, "custody drainage exhausted original deadline"
        observed = inspect(remaining)
        # An inspection can block past its caller's budget. A clean reply after
        # the deadline is not evidence of timely physical reclamation.
        assert time.monotonic() < deadline, ("custody drainage exceeded original deadline", observed)
        assert observed["dispatch_fenced"] is False, observed
        return observed
    return wait_for(execution, "custody drainage within the original deadline", deadline=deadline,
                    ready=lambda observed: observed["custody_occupied"] == "0" and observed["scratch_used_bytes"] == "0")


class TestHTTPServer(http.server.ThreadingHTTPServer):
    """Stop fixture accept loops promptly; response timing belongs to each case.

    Serves HTTP/1.1 and HTTP/2 by prior knowledge (h2c) on one listener, so
    every fixture works with Rui's HTTP/2 client. A
    cleartext connection that opens with the HTTP/2 preface runs each request
    stream's handler on its own thread through `_H2Connection`; any other
    connection, TLS included, takes the stock HTTP/1.1 path.
    """

    #: The SETTINGS_MAX_CONCURRENT_STREAMS an h2c connection advertises.
    h2_max_concurrent_streams = 100

    def server_bind(self):
        # HTTPServer resolves a descriptive hostname after TCP binding. These
        # numeric loopback fixtures must not depend on the machine's resolver.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def serve_forever(self, poll_interval=0.01):
        super().serve_forever(poll_interval=poll_interval)

    #: h2c connections accepted so far.
    h2_connections = 0

    def finish_request(self, request, client_address):
        if not isinstance(request, ssl.SSLSocket) and _opens_with_h2_preface(request):
            with _h2_connection_lock:
                self.h2_connections += 1
            _H2Connection(self, request, client_address).serve()
        else:
            super().finish_request(request, client_address)


H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
_h2_connection_lock = threading.Lock()


def _opens_with_h2_preface(sock, timeout=5):
    """Peek until the bytes rule the preface in or out, without consuming.
    A client that stalls inside a prefix of the preface gets the HTTP/1.1
    path, which answers it as that server would."""
    try:
        head = wait_for(lambda: sock.recv(len(H2_PREFACE), socket.MSG_PEEK), "a decisive preface prefix",
                        timeout=timeout, interval=0.001,
                        ready=lambda head: not head or not H2_PREFACE.startswith(head) or head == H2_PREFACE)
    except WaitTimeout:
        return False
    return head == H2_PREFACE


class _H2Stream:
    def __init__(self, stream_id, fields):
        self.stream_id = stream_id
        pseudo = {name: value for name, value in fields if name.startswith(b":")}
        self.method = pseudo.get(b":method", b"").decode("latin-1")
        self.path = pseudo.get(b":path", b"").decode("latin-1")
        lines = [b"Host: " + pseudo.get(b":authority", b"")]
        lines += [name + b": " + value for name, value in fields if not name.startswith(b":")]
        self.headers = http.client.parse_headers(io.BytesIO(b"\r\n".join(lines) + b"\r\n\r\n"))
        self.body = bytearray()
        self.reset = False


class _H2Connection:
    """One h2c connection. Its thread reads and decodes; each stream's handler
    thread writes. python-h2 is not thread-safe, so every use of its state
    and of the socket holds `cond`. A send that blocks because the client is
    not reading holds it too, which stalls only this test connection."""

    def __init__(self, server, sock, client_address):
        self.server, self.sock, self.client_address = server, sock, client_address
        # Each frame is its own send. Without TCP_NODELAY, Nagle holds a frame
        # until the client's delayed ACK, about 40 ms, so a large body crawls.
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.h2 = h2.connection.H2Connection(h2.config.H2Configuration(client_side=False, header_encoding=None))
        self.cond = threading.Condition()
        self.streams = {}
        self.handlers = []
        self.closed = False

    def serve(self):
        with self.cond:
            self.h2.local_settings = h2.settings.Settings(client=False, initial_values={
                h2.settings.SettingCodes.MAX_CONCURRENT_STREAMS: self.server.h2_max_concurrent_streams})
            self.h2.initiate_connection()
            self._flush()
        try:
            while not self.closed:
                try:
                    data = self.sock.recv(65536)
                except OSError:
                    break
                if not data:
                    break
                with self.cond:
                    try:
                        events = self.h2.receive_data(data)
                    except h2.exceptions.ProtocolError:
                        self._flush()
                        break
                    for event in events:
                        self._receive(event)
                    self._flush()
                    self.cond.notify_all()
        finally:
            self.close()
            for handler in self.handlers:
                handler.join()

    def _receive(self, event):
        if isinstance(event, h2.events.RequestReceived):
            self.streams[event.stream_id] = _H2Stream(event.stream_id, event.headers)
        elif isinstance(event, h2.events.DataReceived):
            self.streams[event.stream_id].body += event.data
            # Fixtures are not the flow-control subject: credit returns at once.
            self.h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
        elif isinstance(event, h2.events.StreamEnded):
            handler = threading.Thread(target=self._run_handler, args=(self.streams[event.stream_id],), daemon=True)
            self.handlers.append(handler)
            handler.start()
        elif isinstance(event, h2.events.StreamReset) and event.stream_id in self.streams:
            self.streams[event.stream_id].reset = True

    def _flush(self):
        data = self.h2.data_to_send()
        if data:
            try:
                self.sock.sendall(data)
            except OSError:
                self.closed = True

    def _run_handler(self, stream):
        """The subclass's handler, against the request this stream carried."""
        handler = object.__new__(self.server.RequestHandlerClass)
        handler.server = self.server
        handler.client_address = self.client_address
        handler.command = stream.method
        handler.path = stream.path
        handler.request_version = "HTTP/2.0"
        handler.requestline = f"{stream.method} {stream.path} HTTP/2.0"
        handler.headers = stream.headers
        handler.rfile = io.BytesIO(stream.body)
        handler.wfile = _H2StreamWriter(self, stream)
        handler.close_connection = False
        try:
            method = getattr(handler, "do_" + stream.method, None)
            if method is None:
                handler.send_error(http.HTTPStatus.NOT_IMPLEMENTED, f"Unsupported method ({stream.method!r})")
            else:
                method()
        except Exception:
            self.server.handle_error(self.sock, self.client_address)
            self.reset(stream, h2.errors.ErrorCodes.INTERNAL_ERROR)
        else:
            if handler.wfile.head_sent:
                self.end(stream)
            else:
                # As an HTTP/1.1 handler that returns without answering.
                self.close()
        finally:
            with self.cond:
                self.streams.pop(stream.stream_id, None)

    # Writes from handler threads. A write after the client reset the
    # stream, or after the connection went, raises BrokenPipeError, as a
    # closed socket would.

    def send_head(self, stream, fields):
        with self.cond:
            self._check_open(stream)
            self.h2.send_headers(stream.stream_id, fields)
            self._flush()

    def send_body(self, stream, data):
        """One DATA frame per call, unless the window or frame size splits it."""
        view = memoryview(data)
        # An empty write still reports a reset stream or a closed connection.
        with self.cond:
            self._check_open(stream)
        while view:
            with self.cond:
                while True:
                    self._check_open(stream)
                    try:
                        window = self.h2.local_flow_control_window(stream.stream_id)
                    except h2.exceptions.StreamClosedError:
                        raise BrokenPipeError(errno.EPIPE, "stream closed")
                    if window > 0:
                        break
                    self.cond.wait()
                size = min(window, self.h2.max_outbound_frame_size, len(view))
                self.h2.send_data(stream.stream_id, bytes(view[:size]))
                self._flush()
            view = view[size:]

    def end(self, stream):
        with self.cond:
            if stream.reset or self.closed:
                return
            try:
                self.h2.end_stream(stream.stream_id)
            except h2.exceptions.StreamClosedError:
                return
            self._flush()

    def reset(self, stream, code):
        with self.cond:
            if stream.reset or self.closed:
                return
            try:
                self.h2.reset_stream(stream.stream_id, code)
            except h2.exceptions.StreamClosedError:
                return
            self._flush()

    def close(self):
        """Drop the whole connection."""
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def _check_open(self, stream):
        if stream.reset or self.closed:
            raise BrokenPipeError(errno.EPIPE, "stream reset or connection closed")


class _H2StreamWriter:
    """A handler's wfile. The head that send_response, send_header and
    end_headers write becomes one HEADERS frame (names lowercased,
    connection-specific fields dropped); each later write is DATA, so a
    handler's write sizes are its frame sizes."""

    CONNECTION_FIELDS = {b"connection", b"keep-alive", b"proxy-connection", b"transfer-encoding", b"upgrade"}

    def __init__(self, connection, stream):
        self.connection, self.stream = connection, stream
        self.head = bytearray()
        self.head_sent = False

    def write(self, data):
        data = bytes(data)
        if self.head_sent:
            self.connection.send_body(self.stream, data)
            return len(data)
        self.head += data
        end = self.head.find(b"\r\n\r\n")
        if end >= 0:
            status_line, *lines = bytes(self.head[:end]).split(b"\r\n")
            fields = [(b":status", status_line.split(b" ")[1])]
            for line in lines:
                name, _, value = line.partition(b":")
                name = name.strip().lower()
                if name not in self.CONNECTION_FIELDS:
                    fields.append((name, value.strip()))
            self.connection.send_head(self.stream, fields)
            self.head_sent = True
            self.connection.send_body(self.stream, bytes(self.head[end + 4:]))
        return len(data)

    def flush(self):
        pass


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
        if phase == "effect_stop_requested":
            plans = ("interrupt",)
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
        elif phase == "exhausted_retry_recovery_held":
            plans = ("dispatch",)
        elif phase in ("connection_request_session_stop", "connection_request_permission_decision"):
            plans = ("dispatch", "status", "list", "control_peers")
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

    def dispose_interrupt(self, collect, *, controls=()):
        """Stop the Host, then require exactly one native stop receipt per
        named control and nothing else."""
        incoming_error = sys.exc_info()[1]
        self.snapshot_failure(collect)
        try:
            stop_process(self.process)
        except BaseException as error:
            try:
                print(f"Interrupt fixture cleanup failed: {error}", file=sys.stderr)
            except Exception:
                pass
            if incoming_error is not None:
                raise incoming_error from error
            raise
        try:
            if incoming_error is None:
                assert Counter(record.get("control_key") for record in self.matching("effect_stop_requested")) == Counter(controls), self.records
                assert len(self.records) == len(controls), self.records
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
    if "--test-retry-recovery-gate-path" in args:
        observations = observations or "dispatch"
        assert observations == "dispatch", "retry recovery gate requires a selecting native plan"
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
            os.set_blocking(reader, False)
            credit = bytes(OBSERVATION_STARTUP_CREDIT)
            supplied = os.write(writer, credit)
            assert supplied == len(credit), f"incomplete observation startup credit: {supplied}/{len(credit)}"
            drained = os.read(reader, len(credit))
            assert drained == credit, "incomplete or corrupt observation startup credit drain"
            os.set_blocking(reader, True)
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
