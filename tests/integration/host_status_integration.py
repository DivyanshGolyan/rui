#!/usr/bin/env python3
"""Native client/Host observation without a CLI status command or SQLite access."""

import fcntl
import hashlib
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

import host_process
from host_process import HostDiagnostics, canonical_fixture_root, is_peer_disconnect, start_ready_process, stop_process, wait_for
import os_semantics


RUI, ACTOR = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])
PUBLISH = pathlib.Path(__file__).resolve().parents[2] / "release/publish.sh"


def installer_view(home):
    """What the installer's report reads from this build: the selected Store and its Host status."""
    result = subprocess.run(["sh", "-c", '. "$1"; _rui_selected "$2"', "sh", PUBLISH, RUI],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and result.stderr == "", result
    return result.stdout.splitlines()


def status(store):
    result = subprocess.run([ACTOR, store], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def cli_status(home, *args):
    # Metadata is exactly one JSON value on stdout; incompatible and access
    # failures still report their status there and exit nonzero.
    result = subprocess.run([RUI, "host", "status", *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
    value = json.loads(result.stdout)
    assert value["version"] == "3" and value["type"] == "host_status", result
    failed = value["status"] in ("incompatible", "access_failure")
    assert (result.returncode != 0) == failed, result
    if value["status"] != "ready":
        assert value == {"version": "3", "type": "host_status", "status": value["status"]}, result
    return value


def read_request(connection):
    # Closing with an unread request can reset the connection, replacing the
    # response classification under test with a transport failure.
    connection.settimeout(5)
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = connection.recv(4096)
        assert chunk, "truncated fixture request headers"
        request += chunk
        assert len(request) <= 16 * 1024, "fixture request headers exceeded bound"
    head, body = request.split(b"\r\n\r\n", 1)
    lengths = [line.split(b":", 1)[1].strip() for line in head.split(b"\r\n")[1:]
        if line.lower().startswith(b"content-length:")]
    assert len(lengths) == 1 and lengths[0].isdigit(), head
    length = int(lengths[0])
    assert len(body) <= length <= 8192, "fixture request body exceeded bound"
    while len(body) < length:
        chunk = connection.recv(length - len(body))
        assert chunk, "truncated fixture request body"
        body += chunk
    return body


def prove_fragmented_request():
    class FragmentedRequest:
        chunks = iter((
            b"POST /v1/host-info HTTP/1.1\r\nContent-Length: 8\r\n\r\n",
            b'{"x":',
            b'17}',
        ))

        def settimeout(self, timeout):
            assert timeout > 0

        def recv(self, limit):
            chunk = next(self.chunks)
            assert len(chunk) <= limit
            return chunk

    assert read_request(FragmentedRequest()) == b'{"x":17}'


def start(store, capacity, *options):
    return start_ready_process(
        [RUI, "host", "serve", "--store", store, "--active-capacity", str(capacity), *options],
        required_fields={"active_capacity": str(capacity)},
        observations="status" if "--test-phase-trace" in options else None,
    )


def socket_path(store):
    digest = hashlib.sha256(str(store.resolve()).encode()).hexdigest()[:32]
    return pathlib.Path(f"/tmp/rui-{os.geteuid()}/{digest}.sock")


def raw_info(sock, store, instance=None, *, kind="host_info", route="host-info", extra=None):
    payload = json.dumps({"version": "3", "kind": kind, "store": str(store), **(extra or {})}).encode()
    header = b"X-Rui-Wire-Version: 3\r\n"
    if instance is not None:
        header += f"X-Rui-Host-Instance: {instance}\r\n".encode()
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(5)
        stream.connect(str(sock))
        stream.sendall(
            f"POST /v1/{route} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\n".encode()
            + f"Content-Length: {len(payload)}\r\n".encode()
            + header + b"\r\n" + payload
        )
        return complete_response(stream)


def wait_for_descriptors(pid, expected=None, timeout=5):
    directory = pathlib.Path(f"/proc/{pid}/fd")

    def snapshot():
        try:
            return {entry.name: os.readlink(entry) for entry in directory.iterdir()}
        except FileNotFoundError:
            # Retry the whole snapshot if a connection closes during enumeration.
            return None
    return wait_for(snapshot, f"descriptors {expected}", timeout=timeout, interval=.01,
                    ready=lambda observed: observed is not None and (expected is None or observed == expected))


def complete_response(stream):
    response = bytearray()
    while True:
        try:
            chunk = stream.recv(4096)
        except OSError as error:
            if not is_peer_disconnect(error):
                raise
            # Early route/kind rejection leaves hostile bytes unread. Reset
            # can terminate a complete reply, but never certify a prefix.
            break
        if not chunk:
            break
        response.extend(chunk)
        assert len(response) < 8192, response
    head, body = response.split(b"\r\n\r\n", 1)
    lengths = [line.split(b":", 1)[1].strip() for line in head.split(b"\r\n")[1:]
               if line.lower().startswith(b"content-length:")]
    assert len(lengths) == 1 and int(lengths[0]) == len(body), (head, body)
    return bytes(response)


def held_request(store, route, length=512, *, complete_headers=True):
    stream = socket.socket(socket.AF_UNIX)
    stream.settimeout(2)
    stream.connect(str(socket_path(store)))
    stream.sendall(f"POST /v1/{route} HTTP/1.1\r\n".encode())
    if complete_headers:
        stream.sendall((f"Host: local\r\nContent-Type: application/json\r\n"
                       f"X-Rui-Wire-Version: 3\r\nContent-Length: {length}\r\n\r\n").encode())
    return stream


def correlated_phase(diagnostics, phase, began_ns, **fields):
    deadline = time.monotonic() + 2
    with diagnostics.condition:
        while True:
            records = diagnostics.matching(phase, **fields)
            current = [record for record in records if int(record["at_ns"]) >= began_ns]
            if current:
                break
            remaining = deadline - time.monotonic()
            assert remaining > 0, (phase, diagnostics.tail())
            diagnostics.condition.wait(remaining)
    assert len(current) == 1, (phase, current)
    record = current[0]
    assert record["process"] == str(diagnostics.process.pid), record
    assert record["clock"] == "awake_ns" and isinstance(record["trace_lost"], bool), record
    assert record["run"] == records[0]["run"], record
    return record


def discovery_released(diagnostics, began_ns):
    started = correlated_phase(diagnostics, "connection_request_host_info", began_ns)
    released = correlated_phase(diagnostics, "connection_resources_released", began_ns,
                                subject_kind="request_number", subject=started["subject"])
    assert int(released["sequence"]) > int(started["sequence"]), (started, released)
    assert int(released["at_ns"]) >= int(started["at_ns"]), (started, released)
    assert released["run"] == started["run"], (started, released)
    assert not started["trace_lost"] or released["trace_lost"], (started, released)


def protected_saturation(root):
    store = root / "saturated"
    host, _ = start(store, 1, "--test-phase-trace")
    diagnostics = HostDiagnostics(host)
    held = []
    try:
        diagnostics.wait("lifecycle_boundary")
        began_ns = time.monotonic_ns()
        initial = status(store)
        identity = initial.split()[1]
        assert initial.startswith("ready "), initial
        discovery_released(diagnostics, began_ns)
        began_ns = time.monotonic_ns()
        assert b'"type":"host_info"' in raw_info(socket_path(store), store)
        discovery_released(diagnostics, began_ns)
        baseline = wait_for_descriptors(host.pid) if os_semantics.PROC_FS else None
        began = time.monotonic()
        for index in range(10):
            began_ns = time.monotonic_ns()
            held.append(held_request(store, "message", complete_headers=False))
            # A full request line, not accept/backlog population, establishes
            # each ordinary borrower. Each milestone belongs to this issuer.
            records = diagnostics.wait("ordinary_classification_released", count=index + 1,
                                       timeout=2, subject_kind="route", subject="message")
            record = records[index]
            assert int(record["at_ns"]) >= began_ns and isinstance(record["trace_lost"], bool), record
            assert record["process"] == str(host.pid) and record["clock"] == "awake_ns", record
            assert record["run"] == records[0]["run"], records
            assert index == 0 or int(record["sequence"]) > int(records[index - 1]["sequence"]), records
            assert index == 0 or not records[index - 1]["trace_lost"] or record["trace_lost"], records
        began_ns = time.monotonic_ns()
        observed = status(store)
        assert observed == initial, ("status lost ordinary headroom", observed)
        discovery_released(diagnostics, began_ns)
        began_ns = time.monotonic_ns()
        held.append(held_request(store, "host-info"))
        pending = correlated_phase(diagnostics, "connection_request_host_info", began_ns)
        assert not diagnostics.matching("connection_resources_released", subject=pending["subject"])
        competing_started = time.monotonic()
        began_ns = time.monotonic_ns()
        competing = raw_info(socket_path(store), store)
        assert competing.startswith(b"HTTP/1.1 200") and b'"type":"host_info"' in competing, competing
        assert time.monotonic() - competing_started < 2, "competing discovery exceeded bound"
        discovery_released(diagnostics, began_ns)
        began_ns = time.monotonic_ns()
        assert status(store) == initial, "incomplete discovery blocked complete discovery"
        discovery_released(diagnostics, began_ns)
        assert time.monotonic() - began < 5, "fixture consumed ordinary borrowers' acceptance budget"
        if baseline is not None:
            snapshot = wait_for_descriptors(host.pid)
            assert len(snapshot) <= len(baseline) + 11, (baseline, snapshot)
        ack = raw_info(socket_path(store), store, identity,
                       kind="host_stop", route="control/host-stop")
        assert ack.startswith(b"HTTP/1.1 200") and json.loads(ack.split(b"\r\n\r\n", 1)[1]) == {
            "version": "3", "type": "host_stop_reply", "status": "acknowledged"}, ack
        deadline = time.monotonic() + 2
        wait_for(lambda: not socket_path(store).exists(), "stop to close the listener", interval=.01, deadline=deadline)
        # These peers never handed a complete request to a worker. They must
        # retire without requiring peer close, unlike an already-owned reply.
        for stream in held:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "unhanded intake did not retire after stop"
            stream.settimeout(remaining)
            try:
                assert stream.recv(1) == b"", "unhanded intake produced a reply"
            except OSError as error:
                if not is_peer_disconnect(error):
                    raise
        host.wait(timeout=5)
        stop_process(host)
        assert host.returncode != 0, diagnostics.tail()  # EffectAwareShutdown, not a forced kill.
        # The per-exchange receipt is after physical close; process reap also
        # establishes that both shared workers have retired before lease reuse.
        release = diagnostics.matching("connection_resources_released", subject=pending["subject"])
        assert len(release) == 1 and release[0]["scratch_used_bytes"] == "0", release
        assert release[0]["run"] == pending["run"] and int(release[0]["sequence"]) > int(pending["sequence"]), release
        assert status(store) == "unavailable"
        with (store / "host.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("protected discovery passed: ten ordinary + incomplete discovery, competing ready, exact stop, unhanded peer retirement, correlated release and lease reuse")
    finally:
        for stream in held:
            stream.close()
        stop_process(host)


def hostile_discovery(root):
    store = root / "hostile"
    host, _ = start(store, 1, "--test-phase-trace", "--fault", "content-acquire")
    diagnostics = HostDiagnostics(host)
    try:
        diagnostics.wait("lifecycle_boundary")
        began_ns = time.monotonic_ns()
        assert b'"type":"host_info"' in raw_info(socket_path(store), store)
        discovery_released(diagnostics, began_ns)
        baseline = wait_for_descriptors(host.pid) if os_semantics.PROC_FS else None
        for kind, extra in (("message", {"key": "hostile", "session": "hostile/session", "sender": None, "sender_handle": None, "text": {"state": "value", "value": "x" * 128}}),
                            ("configure", {"key": "hostile", "session": "hostile/session", "configuration": {
                                "workspace": {"state": "omitted"}, "provider": {"state": "omitted"},
                                "model": {"state": "omitted"}, "instructions": {"state": "value", "value": "x" * 128}}})):
            for route in ("host-info", "control/host-stop"):
                began_ns = time.monotonic_ns()
                response = raw_info(socket_path(store), store, route=route, kind=kind, extra=extra)
                assert b"RouteKindMismatch" in response and b"InjectedContentAcquireFailure" not in response, response
                if route == "host-info":
                    discovery_released(diagnostics, began_ns)
            assert list((store / "scratch").iterdir()) == [], "hostile discovery created scratch"
            observed = raw_info(socket_path(store), store, kind="observe_command", route="observe-command", extra={"key": "hostile"})
            assert b'"status":"absent"' in observed, observed
            began_ns = time.monotonic_ns()
            assert status(store).startswith("ready ")
            discovery_released(diagnostics, began_ns)
        began_ns = time.monotonic_ns()
        with held_request(store, "host-info", length=1000000) as stream:
            response = complete_response(stream)
        assert response.startswith(b"HTTP/1.1 400") and b"DiscoveryRequestTooLarge" in response, response
        discovery_released(diagnostics, began_ns)
        assert list((store / "scratch").iterdir()) == []
        began_ns = time.monotonic_ns()
        assert b'"type":"host_info"' in raw_info(socket_path(store), store)
        discovery_released(diagnostics, began_ns)
        if baseline is not None:
            wait_for_descriptors(host.pid, baseline)
        print("hostile discovery passed: oversized before body, message/configure before scratch, no saved command, healthy reuse")
    finally:
        stop_process(host)


def discovery_body_deadline(root):
    store = root / "deadline"
    host, _ = start(store, 1, "--test-phase-trace")
    diagnostics = HostDiagnostics(host)
    response = bytearray()
    try:
        accepted = time.monotonic()
        began_ns = time.monotonic_ns()
        with held_request(store, "host-info", complete_headers=False) as stream:
            # Header time is charged to the same original acceptance budget.
            time.sleep(2)
            stream.sendall(b"Host: local\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 3\r\nContent-Length: 512\r\n\r\n")
            diagnostics.wait("connection_request_host_info", timeout=2)
            prefix = json.dumps({"version": "3", "kind": "host_info", "store": str(store)}).encode()[:-1]
            stream.sendall(prefix)
            stream.settimeout(.5)
            closed = False
            while time.monotonic() - accepted < 11.5:
                try:
                    stream.sendall(b" ")
                    chunk = stream.recv(4096)
                    if not chunk:
                        closed = True
                        break
                    response.extend(chunk)
                    assert len(response) < 8192, response
                except socket.timeout:
                    continue
                except OSError as error:
                    if not is_peer_disconnect(error):
                        raise
                    closed = True
                    break
            elapsed = time.monotonic() - accepted
            assert closed and 9 <= elapsed < 11.5, ("body deadline not acceptance-derived 10s", elapsed, bytes(response), diagnostics.tail())
        # Peer EOF precedes admission retirement; require the owned endpoint
        # before probing the single discovery place again.
        discovery_released(diagnostics, began_ns)
        began_ns = time.monotonic_ns()
        observed = status(store)
        assert observed.startswith("ready "), (observed, diagnostics.tail())
        discovery_released(diagnostics, began_ns)
        assert list((store / "scratch").iterdir()) == []
        print(f"discovery absolute deadline passed: header + trickling body closed in {elapsed:.3f}s, scratch=0")
    finally:
        stop_process(host)


def main():
    prove_fragmented_request()
    with tempfile.TemporaryDirectory(prefix="rui-host-info-") as root:
        root = canonical_fixture_root(root)
        protected_saturation(root)
        hostile_discovery(root)
        discovery_body_deadline(root)
        store = pathlib.Path(root) / "store"
        home = pathlib.Path(root) / "home"
        home.mkdir(mode=0o700)
        assert installer_view(home) == [f"{home}/.local/share/rui/store", "store_unavailable"]
        assert status(store) == "unavailable"
        assert cli_status(home, "--store", store)["status"] == "unavailable"
        assert not store.exists(), "observation created a Store"
        store.mkdir(mode=0o700)
        assert status(store) == "unavailable"
        fifo_lock = store / "host.lock"
        os.mkfifo(fifo_lock, mode=0o600)
        try:
            probe = subprocess.run([ACTOR, store], capture_output=True, text=True, timeout=2)
            assert probe.returncode == 0 and probe.stdout.strip() == "access_failure", probe
            assert cli_status(home, "--store", store)["status"] == "access_failure"
        finally:
            fifo_lock.unlink()
        stale = socket_path(store)
        stale.parent.mkdir(mode=0o700, exist_ok=True)
        with socket.socket(socket.AF_UNIX) as endpoint:
            endpoint.bind(str(stale))
        assert status(store) == "unavailable", "stale socket claimed readiness"
        stale.unlink()

        with (store / "host.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert status(store) == "owned_unavailable"
            assert cli_status(home, "--store", store)["status"] == "owned_unavailable"
            for partial in (b"", b"HTTP/1.1 200 OK\r\n", b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 3\r\n\r\n{"):
                with socket.socket(socket.AF_UNIX) as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(1)
                    release = threading.Event()

                    def stalled_peer():
                        connection, _ = endpoint.accept()
                        with connection:
                            read_request(connection)
                            if partial:
                                connection.sendall(partial)
                            release.wait(timeout=4)

                    stalled = threading.Thread(target=stalled_peer)
                    stalled.start()
                    try:
                        started = time.monotonic()
                        assert status(store) == "owned_unavailable"
                        assert time.monotonic() - started < 2.5, "stalled Host-info peer exceeded deadline"
                    finally:
                        release.set()
                        stalled.join(timeout=3)
                    assert not stalled.is_alive()
                stale.unlink()
            with socket.socket(socket.AF_UNIX) as endpoint:
                endpoint.bind(str(stale))
                endpoint.listen(1)
                def incompatible_peer():
                    for _ in range(3):
                        connection, _ = endpoint.accept()
                        with connection:
                            read_request(connection)
                            connection.sendall(
                                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                b"Content-Length: 2\r\nX-Rui-Wire-Version: 4\r\n\r\n{}"
                            )

                peer = threading.Thread(target=incompatible_peer)
                peer.start()
                assert status(store) == "incompatible"
                assert cli_status(home, "--store", store)["status"] == "incompatible"
                # A client of another wire version names the mismatch and the
                # way out instead of failing on its first read.
                started = subprocess.run([RUI, "host", "start", "--store", str(store)],
                    env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
                assert started.returncode != 0 and "does not speak this rui's protocol" in started.stderr, started
                peer.join(timeout=3)
                assert not peer.is_alive()
            stale.unlink()
            if os_semantics.SOCKET_MODE_ENFORCED:
                with socket.socket(socket.AF_UNIX) as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(1)
                    stale.chmod(0)
                    try:
                        assert status(store) == "access_failure"
                        assert cli_status(home, "--store", store)["status"] == "access_failure"
                    finally:
                        stale.chmod(0o600)
                stale.unlink()
            noncanonical = json.dumps({
                "version": "3", "type": "host_info", "store": str(store.resolve()),
                "instance": "0" * 32, "active_capacity": "01", "started_at": "1792918800", "custody_occupied": "1",
                "capabilities": {"bash": True, "providers": {"codex": "unserved", "openai": "unserved"}},
            }).encode()
            valid_body = noncanonical.replace(b'"active_capacity": "01"', b'"active_capacity": "1"')
            ambiguous_bodies = (
                valid_body.replace(b'"store": ', b'"store": "/wrong", "store": ', 1),
                valid_body.replace(b'"bash": true', b'"bash": false, "bash": true'),
                *(valid_body.replace(b'"capabilities":', f'"{field}": "{value}", "capabilities":'.encode())
                  for field in ("intake_capacity", "descriptor_limit") for value in ("010", "+10", "1_0")),
                # The start time is a positive canonical second; slots in use
                # never exceed Active Capacity; both are required.
                *(valid_body.replace(b'"started_at": "1792918800"', f'"started_at": "{value}"'.encode())
                  for value in ("0", "01792918800", "+1792918800")),
                valid_body.replace(b'"custody_occupied": "1"', b'"custody_occupied": "2"'),
                valid_body.replace(b'"started_at": "1792918800", ', b''),
                valid_body.replace(b'"custody_occupied": "1", ', b''),
            )
            for response in (
                b"HTTP/1.1 bogus OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 3\r\n\r\n{}",
                (f"HTTP/1.1 200\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version: 3\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 0200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version: 3\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version : 3\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version: 3\r\nTransfer-Encoding: chunked\r\n\r\n").encode() + valid_body,
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 3\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\nX-Rui-Wire-Version: 3\r\n\r\n",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 4\r\nX-Rui-Wire-Version: 3\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 3\r\nX-Rui-Wire-Version: 3\r\n\r\n{}",
                b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 3\r\n\r\n{}",
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(noncanonical)}\r\n"
                 "X-Rui-Wire-Version: 3\r\n\r\n").encode() + noncanonical,
                *((f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n"
                   "X-Rui-Wire-Version: 3\r\n\r\n").encode() + body for body in ambiguous_bodies),
            ):
                with socket.socket(socket.AF_UNIX) as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(2)

                    def malformed_peer():
                        for _ in range(2):
                            connection, _ = endpoint.accept()
                            with connection:
                                read_request(connection)
                                connection.sendall(response)

                    peer = threading.Thread(target=malformed_peer, daemon=True)
                    peer.start()
                    observed = status(store)
                    assert observed == "incompatible", (response, observed)
                    observed = cli_status(home, "--store", store)
                    assert observed["status"] == "incompatible", (response, observed)
                    peer.join(timeout=3)
                    assert not peer.is_alive()
                stale.unlink()
            for kind, code in (("busy", "ordinary_capacity_exhausted"),
                               ("host_unavailable", "dispatch_fenced")):
                body = json.dumps({"version": "3", "type": kind, "code": code}).encode()
                response = (f"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                            f"Content-Length: {len(body)}\r\nX-Rui-Wire-Version: 3\r\n\r\n").encode() + body
                with socket.socket(socket.AF_UNIX) as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(2)

                    def unavailable_peer():
                        for _ in range(2):
                            connection, _ = endpoint.accept()
                            with connection:
                                read_request(connection)
                                connection.sendall(response)

                    peer = threading.Thread(target=unavailable_peer, daemon=True)
                    peer.start()
                    assert status(store) == "owned_unavailable"
                    assert cli_status(home, "--store", store)["status"] == "owned_unavailable"
                    peer.join(timeout=3)
                    assert not peer.is_alive()
                stale.unlink()
            fcntl.flock(lock, fcntl.LOCK_UN)
        assert status(store) == "unavailable"

        store.chmod(0o755)
        assert status(store) == "access_failure"
        assert cli_status(home, "--store", store)["status"] == "access_failure"
        store.chmod(0o700)

        # A selected managed route is enabled before login; readiness does not
        # open or refresh its deliberately absent credential file.
        credential = pathlib.Path(root) / "missing-credential.json"
        first = None
        diagnostics = None
        before_fd = after_fd = None
        expected_routes = []
        completed = False

        def exchange(route, invoke, timeout=10):
            expected_routes.append(route)
            began_ns = time.monotonic_ns()
            deadline = time.monotonic() + timeout
            value = invoke()
            released = diagnostics.borrower_census(deadline, expected_routes)
            current = next(record for record in released if int(record["subject"]) == len(expected_routes) - 1)
            assert began_ns <= int(current["at_ns"]) <= began_ns + int(timeout * 1e9), current
            return value

        # start_ready_process inherits this test's environment.
        old = os.environ.get("RUI_CODEX_CREDENTIAL_FILE")
        os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential)
        try:
            first, fields = start(store, 3, "--provider", "codex", "--test-phase-trace")
            assert fields["execution"] == "enabled"
            diagnostics = HostDiagnostics(first)
            if os_semantics.PROC_FS:
                # Readiness precedes execution-thread initialization. Its first
                # boundary proves reactor wake descriptors have been created.
                diagnostics.wait("lifecycle_boundary")
                assert b'"type":"host_info"' in exchange("host_info", lambda: raw_info(stale, store.resolve()), 5)
                before = wait_for_descriptors(first.pid)
                before_fd = len(before)
            first_status = exchange("host_info", lambda: status(store))
            match = re.fullmatch(r"ready ([0-9a-f]{32}) 3 true chatgpt_device ([1-9][0-9]*) 0", first_status)
            assert match, first_status
            # The Host's start, not the call's: fixed for this Host's life.
            started_at = match.group(2)
            assert int(started_at) <= time.time(), first_status
            alias = store.parent / "alias"
            alias.symlink_to(store, target_is_directory=True)
            assert exchange("host_info", lambda: status(alias)) == first_status
            setup = exchange("host_info", lambda: subprocess.run([RUI, "defaults", "configure", "--store", str(alias)],
                env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10))
            assert setup.returncode == 0, setup.stderr
            # Configure saves the canonical path, which the installer then shows.
            view = exchange("host_info", lambda: installer_view(home))
            assert view == [str(store.resolve()), "ready"], view
            selected = exchange("host_info", lambda: cli_status(home))
            assert selected == {
                "version": "3", "type": "host_status", "status": "ready", "store": str(store.resolve()),
                "instance": match.group(1), "active_capacity": "3", "intake_capacity": "100",
                "descriptor_limit": fields["descriptor_limit"], "started_at": started_at, "custody_occupied": "0",
                "capabilities": {"bash": True, "providers": {"codex": "chatgpt_device", "openai": "unserved"}},
                "diagnostics": f"{store.resolve()}/diagnostics",
            }, selected
            assert exchange("host_info", lambda: cli_status(home, "--store", alias)) == selected
            assert not credential.exists()
            for _ in range(40):
                assert exchange("host_info", lambda: status(alias)) == first_status
            if before_fd is not None:
                # Independent FD readback is not admission-retirement authority.
                after_fd = len(wait_for_descriptors(first.pid, before))
            assert list((store / "scratch").iterdir()) == []
            head, body = exchange("host_info", lambda: raw_info(stale, store.resolve()), 5).split(b"\r\n\r\n", 1)
            assert head.startswith(b"HTTP/1.1 200 OK\r\n")
            assert f"Content-Length: {len(body)}".encode() in head.split(b"\r\n")
            assert json.loads(body) == {
                "version": "3", "type": "host_info", "store": str(store.resolve()),
                "instance": match.group(1), "active_capacity": "3",
                "intake_capacity": "100", "descriptor_limit": fields["descriptor_limit"],
                "started_at": started_at, "custody_occupied": "0",
                "capabilities": {"bash": True, "providers": {"codex": "chatgpt_device", "openai": "unserved"}},
            }
            assert b'"type":"host_info"' in exchange("host_info", lambda: raw_info(stale, store.resolve(), match.group(1)), 5)
            changed = exchange("host_info", lambda: raw_info(stale, store.resolve(), "0" * 32), 5)
            assert b"host_instance_changed" in changed and changed.startswith(b"HTTP/1.1 409")
            guarded = exchange("session_stop", lambda: raw_info(stale, store.resolve(), "0" * 32, kind="session_stop", route="control/session-stop", extra={"key": "guarded-stop", "session": "none"}), 5)
            assert b"host_instance_changed" in guarded and guarded.startswith(b"HTTP/1.1 409")
            observation = exchange("observe", lambda: raw_info(stale, store.resolve(), kind="observe_command", route="observe-command", extra={"key": "guarded-stop"}), 5)
            assert b'"status":"absent"' in observation, observation
            wrong = exchange("host_info", lambda: raw_info(stale, store.parent), 5)
            assert b"wrong_store_identity" in wrong and wrong.startswith(b"HTTP/1.1 409")
            completed = True
        finally:
            try:
                if first is not None:
                    stop_process(first)
            finally:
                try:
                    if diagnostics is not None:
                        if completed:
                            diagnostics.borrower_census(time.monotonic(), expected_routes)
                finally:
                    if old is None:
                        os.environ.pop("RUI_CODEX_CREDENTIAL_FILE", None)
                    else:
                        os.environ["RUI_CODEX_CREDENTIAL_FILE"] = old
        assert status(store) == "unavailable"
        second, _ = start(store, 7, "--test-phase-trace")
        diagnostics = HostDiagnostics(second)
        expected_routes = []
        completed = False
        try:
            second_status = exchange("host_info", lambda: status(store))
            match_second = re.fullmatch(r"ready ([0-9a-f]{32}) 7 true unserved ([1-9][0-9]*) 0", second_status)
            assert match_second, second_status
            # A replacement Host starts no earlier than the one it replaced.
            assert int(match_second.group(2)) >= int(started_at), (first_status, second_status)
            selected = exchange("host_info", lambda: cli_status(home))
            assert selected["status"] == "ready" and selected["store"] == str(store.resolve()), selected
            assert selected["active_capacity"] == "7", selected
            assert selected["capabilities"] == {"bash": True, "providers": {"codex": "unserved", "openai": "unserved"}}, selected
            assert selected["instance"] == match_second.group(1), selected
            assert match_second.group(1) != match.group(1), "replacement reused instance identity"
            old_instance = exchange("host_info", lambda: raw_info(stale, store.resolve(), match.group(1)), 5)
            assert b"host_instance_changed" in old_instance and old_instance.startswith(b"HTTP/1.1 409")
            completed = True
        finally:
            try:
                stop_process(second)
            finally:
                if completed:
                    diagnostics.borrower_census(time.monotonic(), expected_routes)
        assert status(store) == "unavailable"
        print(f"host-status passed: capacity=3/7 replacement identity, 40 reads, fd={before_fd}->{after_fd}, scratch=0")


if __name__ == "__main__":
    host_process.enter()
    main()
