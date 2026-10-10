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

from host_process import HostDiagnostics, canonical_fixture_root, start_ready_process, stop_process


RUI, ACTOR = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])


def status(store):
    result = subprocess.run([ACTOR, store], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def cli_status(home, *args):
    result = subprocess.run([RUI, "host", "status", *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout


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
        [RUI, "serve", "--store", store, "--active-capacity", str(capacity), *options],
        required_fields={"active_capacity": str(capacity)},
    )


def socket_path(store):
    digest = hashlib.sha256(str(store.resolve()).encode()).hexdigest()[:32]
    return pathlib.Path(f"/tmp/rui-{os.geteuid()}/{digest}.sock")


def raw_info(sock, store, instance=None, *, kind="host_info", route="host-info", extra=None):
    payload = json.dumps({"version": "1", "kind": kind, "store": str(store), **(extra or {})}).encode()
    header = b"X-Rui-Wire-Version: 1\r\n"
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
    deadline = time.monotonic() + timeout
    while True:
        try:
            observed = {entry.name: os.readlink(entry) for entry in directory.iterdir()}
        except FileNotFoundError:
            # Retry the whole snapshot if a connection closes during enumeration.
            observed = None
        if observed is not None and (expected is None or observed == expected):
            return observed
        assert time.monotonic() < deadline, (expected, observed)
        time.sleep(.01)


def complete_response(stream):
    response = bytearray()
    while True:
        try:
            chunk = stream.recv(4096)
        except ConnectionResetError:
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
                       f"X-Rui-Wire-Version: 1\r\nContent-Length: {length}\r\n\r\n").encode())
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
    assert record["clock"] == "awake_ns" and record["trace_lost"] is False, record
    assert record["run"] == records[0]["run"], record
    return record


def discovery_released(diagnostics, began_ns):
    started = correlated_phase(diagnostics, "connection_request_host_info", began_ns)
    released = correlated_phase(diagnostics, "connection_resources_released", began_ns,
                                subject_kind="request_number", subject=started["subject"])
    assert int(released["sequence"]) > int(started["sequence"]), (started, released)


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
        baseline = wait_for_descriptors(host.pid) if sys.platform == "linux" else None
        began = time.monotonic()
        for index in range(10):
            began_ns = time.monotonic_ns()
            held.append(held_request(store, "message", complete_headers=False))
            # A full request line, not accept/backlog population, establishes
            # each ordinary borrower. Each milestone belongs to this issuer.
            records = diagnostics.wait("ordinary_classification_released", count=index + 1,
                                       timeout=2, subject_kind="route", subject="message")
            record = records[index]
            assert int(record["at_ns"]) >= began_ns and record["trace_lost"] is False, record
            assert record["process"] == str(host.pid) and record["clock"] == "awake_ns", record
            assert record["run"] == records[0]["run"], records
            assert index == 0 or int(record["sequence"]) > int(records[index - 1]["sequence"]), records
        began_ns = time.monotonic_ns()
        observed = status(store)
        assert observed == initial, ("status lost ordinary headroom", observed)
        discovery_released(diagnostics, began_ns)
        began_ns = time.monotonic_ns()
        held.append(held_request(store, "host-info"))
        pending = correlated_phase(diagnostics, "connection_request_host_info", began_ns)
        assert not diagnostics.matching("connection_resources_released", subject=pending["subject"])
        busy_started = time.monotonic()
        began_ns = time.monotonic_ns()
        busy = raw_info(socket_path(store), store)
        assert busy.startswith(b"HTTP/1.1 503") and b"discovery_capacity_exhausted" in busy, busy
        assert time.monotonic() - busy_started < 2, "discovery busy reply exceeded bound"
        busy_release = correlated_phase(diagnostics, "connection_place_released", began_ns,
                                        subject_kind="place", subject="classification")
        began_ns = time.monotonic_ns()
        assert status(store) == "owned_unavailable", "discovery saturation is not wire incompatibility"
        status_release = correlated_phase(diagnostics, "connection_place_released", began_ns,
                                          subject_kind="place", subject="classification")
        print("discovery rejection cleanup:", json.dumps([busy_release, status_release]), flush=True)
        assert time.monotonic() - began < 5, "fixture consumed ordinary borrowers' acceptance budget"
        ack = raw_info(socket_path(store), store, identity,
                       kind="host_stop", route="control/host-stop")
        assert ack.startswith(b"HTTP/1.1 200") and json.loads(ack.split(b"\r\n\r\n", 1)[1]) == {
            "version": "1", "type": "host_stop_reply", "status": "acknowledged"}, ack
        deadline = time.monotonic() + 2
        while socket_path(store).exists():
            assert time.monotonic() < deadline, "stop did not close listener"
            time.sleep(.01)
        assert host.poll() is None, "Host exited with borrowers held"
        with (store / "host.lock").open("rb") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("lease released with borrowers held")
        if baseline is not None:
            snapshot = wait_for_descriptors(host.pid)
            assert len(snapshot) <= len(baseline) + 11, (baseline, snapshot)
        for stream in held:
            stream.close()
        held.clear()
        host.wait(timeout=5)
        diagnostics.close()
        assert host.returncode != 0, diagnostics.tail()  # EffectAwareShutdown, not a forced kill.
        # Resource release is before the final drain unlock, not thread retirement.
        release = diagnostics.matching("connection_resources_released", subject=pending["subject"])
        assert len(release) == 1 and release[0]["scratch_used_bytes"] == "0", release
        assert release[0]["run"] == pending["run"] and int(release[0]["sequence"]) > int(pending["sequence"]), release
        assert status(store) == "unavailable"
        with (store / "host.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("protected discovery passed: ten ordinary + one discovery, competing busy, exact stop, listener closure, held lease, correlated release")
    finally:
        for stream in held:
            stream.close()
        stop_process(host)
        diagnostics.close()


def hostile_discovery(root):
    store = root / "hostile"
    host, _ = start(store, 1, "--test-phase-trace", "--fault", "content-acquire")
    diagnostics = HostDiagnostics(host)
    try:
        diagnostics.wait("lifecycle_boundary")
        assert b'"type":"host_info"' in raw_info(socket_path(store), store)
        baseline = wait_for_descriptors(host.pid) if sys.platform == "linux" else None
        for kind, extra in (("message", {"key": "hostile", "session": "hostile/session", "text": {"state": "value", "value": "x" * 128}}),
                            ("configure", {"key": "hostile", "session": "hostile/session", "configuration": {
                                "workspace": {"state": "omitted"}, "provider": {"state": "omitted"},
                                "model": {"state": "omitted"}, "instructions": {"state": "value", "value": "x" * 128}}})):
            for route in ("host-info", "control/host-stop"):
                response = raw_info(socket_path(store), store, route=route, kind=kind, extra=extra)
                assert b"RouteKindMismatch" in response and b"InjectedContentAcquireFailure" not in response, response
            assert list((store / "scratch").iterdir()) == [], "hostile discovery created scratch"
            observed = raw_info(socket_path(store), store, kind="observe_command", route="observe-command", extra={"key": "hostile"})
            assert b'"status":"absent"' in observed, observed
            assert status(store).startswith("ready ")
        with held_request(store, "host-info", length=1000000) as stream:
            response = complete_response(stream)
        assert response.startswith(b"HTTP/1.1 400") and b"DiscoveryRequestTooLarge" in response, response
        assert list((store / "scratch").iterdir()) == []
        assert b'"type":"host_info"' in raw_info(socket_path(store), store)
        if baseline is not None:
            wait_for_descriptors(host.pid, baseline)
        print("hostile discovery passed: oversized before body, message/configure before scratch, no saved command, healthy reuse")
    finally:
        stop_process(host)
        diagnostics.close()


def discovery_body_deadline(root):
    store = root / "deadline"
    host, _ = start(store, 1, "--test-phase-trace")
    diagnostics = HostDiagnostics(host)
    response = bytearray()
    try:
        accepted = time.monotonic()
        with held_request(store, "host-info", complete_headers=False) as stream:
            # Header time is charged to the same original acceptance budget.
            time.sleep(2)
            stream.sendall(b"Host: local\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: 512\r\n\r\n")
            diagnostics.wait("connection_request_host_info", timeout=2)
            prefix = json.dumps({"version": "1", "kind": "host_info", "store": str(store)}).encode()[:-1]
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
                except (BrokenPipeError, ConnectionResetError):
                    closed = True
                    break
            elapsed = time.monotonic() - accepted
            assert closed and 9 <= elapsed < 11.5, ("body deadline not acceptance-derived 10s", elapsed, bytes(response), diagnostics.tail())
        assert status(store).startswith("ready ")
        assert list((store / "scratch").iterdir()) == []
        print(f"discovery absolute deadline passed: header + trickling body closed in {elapsed:.3f}s, scratch=0")
    finally:
        stop_process(host)
        diagnostics.close()


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
        assert status(store) == "unavailable"
        assert cli_status(home, "--store", store) == "Host: unavailable (no current Store owner established)\n"
        assert not store.exists(), "observation created a Store"
        store.mkdir(mode=0o700)
        assert status(store) == "unavailable"
        fifo_lock = store / "host.lock"
        os.mkfifo(fifo_lock, mode=0o600)
        try:
            probe = subprocess.run([ACTOR, store], capture_output=True, text=True, timeout=2)
            assert probe.returncode == 0 and probe.stdout.strip() == "access_failure", probe
            assert cli_status(home, "--store", store).startswith("Host: access failure")
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
            assert cli_status(home, "--store", store).startswith("Host: owned but unavailable")
            for partial in (b"", b"HTTP/1.1 200 OK\r\n", b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{"):
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
                    for _ in range(2):
                        connection, _ = endpoint.accept()
                        with connection:
                            read_request(connection)
                            connection.sendall(
                                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                b"Content-Length: 2\r\nX-Rui-Wire-Version: 2\r\n\r\n{}"
                            )

                peer = threading.Thread(target=incompatible_peer)
                peer.start()
                assert status(store) == "incompatible"
                assert cli_status(home, "--store", store).startswith("Host: incompatible")
                peer.join(timeout=3)
                assert not peer.is_alive()
            stale.unlink()
            if sys.platform == "linux" and os.geteuid() != 0:
                # Linux enforces socket mode bits for unprivileged callers;
                # root may bypass this denial with CAP_DAC_OVERRIDE.
                with socket.socket(socket.AF_UNIX) as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(1)
                    stale.chmod(0)
                    try:
                        assert status(store) == "access_failure"
                        assert cli_status(home, "--store", store).startswith("Host: access failure")
                    finally:
                        stale.chmod(0o600)
                stale.unlink()
            noncanonical = json.dumps({
                "version": "1", "type": "host_info", "store": str(store.resolve()),
                "instance": "0" * 32, "active_capacity": "01",
                "capabilities": {"bash": True, "model": False, "managed_authentication": False},
            }).encode()
            valid_body = noncanonical.replace(b'"active_capacity": "01"', b'"active_capacity": "1"')
            ambiguous_bodies = (
                valid_body.replace(b'"store": ', b'"store": "/wrong", "store": ', 1),
                valid_body.replace(b'"bash": true', b'"bash": false, "bash": true'),
            )
            for response in (
                b"HTTP/1.1 bogus OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                (f"HTTP/1.1 200\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version: 1\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 0200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version: 1\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version : 1\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 "X-Rui-Wire-Version: 1\r\nTransfer-Encoding: chunked\r\n\r\n").encode() + valid_body,
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\nX-Rui-Wire-Version: 1\r\n\r\n",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(noncanonical)}\r\n"
                 "X-Rui-Wire-Version: 1\r\n\r\n").encode() + noncanonical,
                *((f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n"
                   "X-Rui-Wire-Version: 1\r\n\r\n").encode() + body for body in ambiguous_bodies),
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
                    assert observed.startswith("Host: incompatible"), (response, observed)
                    peer.join(timeout=3)
                    assert not peer.is_alive()
                stale.unlink()
            for kind, code in (("busy", "ordinary_capacity_exhausted"),
                               ("host_unavailable", "dispatch_fenced")):
                body = json.dumps({"version": "1", "type": kind, "code": code}).encode()
                response = (f"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                            f"Content-Length: {len(body)}\r\nX-Rui-Wire-Version: 1\r\n\r\n").encode() + body
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
                    assert cli_status(home, "--store", store).startswith("Host: owned but unavailable")
                    peer.join(timeout=3)
                    assert not peer.is_alive()
                stale.unlink()
            fcntl.flock(lock, fcntl.LOCK_UN)
        assert status(store) == "unavailable"

        store.chmod(0o755)
        assert status(store) == "access_failure"
        assert cli_status(home, "--store", store).startswith("Host: access failure")
        store.chmod(0o700)

        # A selected managed route is enabled before login; readiness does not
        # open or refresh its deliberately absent credential file.
        credential = pathlib.Path(root) / "missing-credential.json"
        first = None
        diagnostics = None
        before_fd = after_fd = None
        # start_ready_process inherits this test's environment.
        old = os.environ.get("RUI_CODEX_CREDENTIAL_FILE")
        os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential)
        try:
            trace_options = ("--test-phase-trace",) if sys.platform == "linux" else ()
            first, fields = start(store, 3, "--codex", *trace_options)
            assert fields["execution"] == "enabled"
            if sys.platform == "linux":
                # Readiness precedes execution-thread initialization. Its first
                # boundary proves reactor wake descriptors have been created.
                diagnostics = HostDiagnostics(first)
                diagnostics.wait("lifecycle_boundary")
                # No other client has connected. EOF proves this warm-up socket
                # closed, unlike framed response completion in hostStatus.
                assert b'"type":"host_info"' in raw_info(stale, store.resolve())
                before = wait_for_descriptors(first.pid)
                before_fd = len(before)
            first_status = status(store)
            match = re.fullmatch(r"ready ([0-9a-f]{32}) 3 true true true", first_status)
            assert match, first_status
            alias = store.parent / "alias"
            alias.symlink_to(store, target_is_directory=True)
            assert status(alias) == first_status
            setup = subprocess.run([RUI, "setup", "--store", str(alias)],
                env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
            assert setup.returncode == 0, setup.stderr
            selected = cli_status(home)
            assert selected.startswith(f"Host: ready\nStore: {store.resolve()}\nWire: 1\nActive capacity: 3\n"), selected
            assert "Bash: enabled\nModel: enabled\nManaged authentication: enabled\n" in selected, selected
            assert f"Instance: {match.group(1)}\n" in selected, selected
            assert cli_status(home, "--store", alias) == selected
            assert not credential.exists()
            for _ in range(40):
                assert status(alias) == first_status
            if before_fd is not None:
                # The last framed reply may precede its owner's close. Require
                # exact descriptor identities after drain, not an extra allowance.
                after_fd = len(wait_for_descriptors(first.pid, before))
            assert list((store / "scratch").iterdir()) == []
            head, body = raw_info(stale, store.resolve()).split(b"\r\n\r\n", 1)
            assert head.startswith(b"HTTP/1.1 200 OK\r\n")
            assert f"Content-Length: {len(body)}".encode() in head.split(b"\r\n")
            assert json.loads(body) == {
                "version": "1", "type": "host_info", "store": str(store.resolve()),
                "instance": match.group(1), "active_capacity": "3",
                "capabilities": {"bash": True, "model": True, "managed_authentication": True},
            }
            assert b'"type":"host_info"' in raw_info(stale, store.resolve(), match.group(1))
            changed = raw_info(stale, store.resolve(), "0" * 32)
            assert b"host_instance_changed" in changed and changed.startswith(b"HTTP/1.1 409")
            guarded = raw_info(stale, store.resolve(), "0" * 32, kind="session_stop", route="control/session-stop", extra={"key": "guarded-stop", "session": "none"})
            assert b"host_instance_changed" in guarded and guarded.startswith(b"HTTP/1.1 409")
            observation = raw_info(stale, store.resolve(), kind="observe_command", route="observe-command", extra={"key": "guarded-stop"})
            assert b'"status":"absent"' in observation, observation
            wrong = raw_info(stale, store.parent)
            assert b"wrong_store_identity" in wrong and wrong.startswith(b"HTTP/1.1 409")
        finally:
            if first is not None:
                stop_process(first)
            if diagnostics is not None:
                diagnostics.close()
            if old is None:
                os.environ.pop("RUI_CODEX_CREDENTIAL_FILE", None)
            else:
                os.environ["RUI_CODEX_CREDENTIAL_FILE"] = old
        assert status(store) == "unavailable"
        second, _ = start(store, 7)
        try:
            second_status = status(store)
            match_second = re.fullmatch(r"ready ([0-9a-f]{32}) 7 true false false", second_status)
            assert match_second, second_status
            selected = cli_status(home)
            assert "Active capacity: 7\nBash: enabled\nModel: disabled\nManaged authentication: disabled\n" in selected, selected
            assert f"Instance: {match_second.group(1)}\n" in selected, selected
            assert match_second.group(1) != match.group(1), "replacement reused instance identity"
            old_instance = raw_info(stale, store.resolve(), match.group(1))
            assert b"host_instance_changed" in old_instance and old_instance.startswith(b"HTTP/1.1 409")
        finally:
            stop_process(second)
        assert status(store) == "unavailable"
        print(f"host-status passed: capacity=3/7 replacement identity, 40 reads, fd={before_fd}->{after_fd}, scratch=0")


if __name__ == "__main__":
    main()
