#!/usr/bin/env python3
"""Native client/Host observation without a CLI status command or SQLite access."""

import fcntl
import http.server
import json
import os
import pathlib
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote

import host_process
from host_process import HeldReplies, HostDiagnostics, TestHTTPServer, canonical_fixture_root, dispose_all, is_peer_disconnect, start_ready_process, stop_process, wait_for
import os_semantics
import live_engines
import settings_fixture as frame_host
from host_status_fixture import ACTOR, RUI, complete_response, socket_path, status


PUBLISH = pathlib.Path(__file__).resolve().parents[2] / "release/publish.sh"


def installer_view(home):
    """What the installer's report reads from this build: the selected Store and its Host status."""
    result = subprocess.run(["sh", "-c", '. "$1"; _rui_selected "$2"', "sh", PUBLISH, RUI],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and result.stderr == "", result
    return result.stdout.splitlines()


def cli_status(home, *args):
    # Metadata is exactly one JSON value on stdout; incompatible and access
    # failures still report their status there and exit nonzero.
    result = subprocess.run([RUI, "host", "status", *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
    value = json.loads(result.stdout)
    assert value["version"] == host_process.WIRE_VERSION and value["type"] == "host_status", result
    failed = value["status"] in ("incompatible", "access_failure")
    assert (result.returncode != 0) == failed, result
    if value["status"] != "ready":
        assert value == {"version": host_process.WIRE_VERSION, "type": "host_status", "status": value["status"]}, result
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
        required_fields={"activeCapacity": str(capacity)},
        observations="status" if "--test-phase-trace" in options else None,
    )

def raw_info(sock, store, instance=None, *, kind="host_info", route="host-info", extra=None):
    payload = json.dumps({"version": host_process.WIRE_VERSION, "kind": kind, "store": str(store), **(extra or {})}).encode()
    header = b"X-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n"
    if instance is not None:
        header += f"X-Rui-Host-Instance: {instance}\r\n".encode()
    with os_semantics.unix_stream() as stream:
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


def held_request(store, route, length=512, *, complete_headers=True):
    stream = os_semantics.unix_stream()
    stream.settimeout(2)
    stream.connect(str(socket_path(store)))
    stream.sendall(f"POST /v1/{route} HTTP/1.1\r\n".encode())
    if complete_headers:
        stream.sendall((f"Host: local\r\nContent-Type: application/json\r\n"
                       f"X-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\nContent-Length: {length}\r\n\r\n").encode())
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
            "version": host_process.WIRE_VERSION, "type": "host_stop_reply", "status": "acknowledged"}, ack
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
                            ("configure", {"key": "hostile", "session": "hostile/session", "configuration": {"instructions": "x" * 128}})):
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
            stream.sendall(b"Host: local\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\nContent-Length: 512\r\n\r\n")
            diagnostics.wait("connection_request_host_info", timeout=2)
            prefix = json.dumps({"version": host_process.WIRE_VERSION, "kind": "host_info", "store": str(store)}).encode()[:-1]
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


def mysql_host_info():
    socket = os.environ.get(live_engines.MYSQL_SOCKET)
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    if not socket or not password:
        assert "mysql" not in os.environ.get(live_engines.REQUIRE, "").split(","), "required MySQL host-info fixture has no server"
        print("MySQL host-info: skipped (no RUI_TEST_MYSQL_* server)")
        return
    admin = pathlib.Path(os.environ["RUI_TEST_MYSQL_ADMIN"]).resolve()
    database = "rui_host_info_" + secrets.token_hex(6)

    def sql(text):
        return subprocess.run([admin], input=text, text=True, capture_output=True, check=True, timeout=20).stdout.strip()

    with tempfile.TemporaryDirectory(prefix="rui-host-info-mysql-") as root:
        root = canonical_fixture_root(root)
        runtime = root / "run"
        runtime.mkdir(mode=0o700)
        child = None
        try:
            sql(f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin")
            ddl = subprocess.run([RUI, "store", "schema", "--engine", "mysql"], check=True, capture_output=True, text=True, timeout=20).stdout
            sql(f"USE {database};" + ddl)
            url = f"mysql://root:{quote(password, safe='')}@{quote(socket, safe='')}/{database}"
            # Credentials travel only through the settings document, never argv or
            # the child's environment. The Host answers with its opaque id.
            child = subprocess.Popen([RUI, "host", "serve", "--settings", "-"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env={key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ})
            child.stdin.write(frame_host.frame({
                "store": {"mysql": {"url": {"value": url}}},
                "interface": {"dir": str(runtime), "lifetime": "stdin"},
                "execution": {"activeCapacity": 2},
                "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses", "key": {"value": "sk-host-info-test"}}},
            }))
            child.stdin.flush()
            sock = runtime / "rui.sock"
            try:
                frame_host.wait_for_host(sock, "", child)
            except AssertionError:
                if child.poll() is None:
                    raise
                out, err = frame_host.output(child)
                raise AssertionError(f"MySQL Host exited {child.returncode} before readiness: stdout={out!r} stderr={err!r}") from None
            discovered = frame_host.host_info(sock, "")
            selector = discovered["store"]
            assert re.fullmatch(r"[0-9a-f]{32}", selector), discovered
            info = frame_host.host_info(sock, selector)
            diagnostic = info["innodb_doublewrite"]
            assert isinstance(diagnostic, str) and len(diagnostic.encode()) <= 32, info
            assert diagnostic == sql("SELECT @@global.innodb_doublewrite"), info
            # The same neutral common fields as SQLite; only this optional
            # member differs. No engine-specific reply variant is introduced.
            assert set(info) == {"version", "type", "store", "instance", "active_capacity", "intake_capacity",
                                 "descriptor_limit", "started_at", "custody_occupied", "paused", "capabilities", "innodb_doublewrite"}, info
            assert info["type"] == "host_info" and info["version"] == host_process.WIRE_VERSION, info
            print(f"MySQL host-info passed: opaque selector, bounded non-null diagnostic={diagnostic}")
        finally:
            dispose_all(
                lambda: host_process.close_stdin(child) if child is not None else None,
                lambda: stop_process(child) if child is not None else None,
                lambda: sql(f"DROP DATABASE IF EXISTS {database}"),
            )


def resolved_sqlite_routing(root):
    """A hex directory is SQLite without a hint; launch routing stays separate."""
    home = pathlib.Path(root) / "routing-home"
    home.mkdir(mode=0o700)
    name = "0123456789abcdef0123456789abcdef"
    store = pathlib.Path(root) / name
    env = dict(os.environ, HOME=str(home))
    env.pop("RUI_RUNTIME_DIR", None)
    host, fields = start_ready_process([RUI, "host", "serve", "--store", store], env=env)
    try:
        result = subprocess.run([RUI, "host", "status", "--store", name], cwd=root, env=env,
                                text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result
        value = json.loads(result.stdout)
        assert value["status"] == "ready" and value["store"] == fields["store"], value
        assert value["diagnostics"] == str(store / "diagnostics"), value
        assert "innodb_doublewrite" not in value, value
    finally:
        stop_process(host)

    runtime = pathlib.Path(root) / "sqlite-runtime"
    runtime.mkdir(mode=0o700)
    launched_store = pathlib.Path(root) / "launched-store"
    document = {"store": {"sqlite": {"dir": str(launched_store)}},
                "interface": {"dir": str(runtime), "lifetime": "stdin"},
                "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses", "key": {"value": "sk-routing-test"}}}}
    launched = subprocess.Popen([RUI, "host", "serve", "--settings", "-"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        launched.stdin.write(frame_host.frame(document))
        launched.stdin.flush()
        frame_host.wait_for_host(runtime / "rui.sock", launched_store, launched)
        value = frame_host.host_info(runtime / "rui.sock", str(launched_store))
        assert value["store"] == str(launched_store.resolve()), value
        assert "innodb_doublewrite" not in value and "kind" not in value and "engine" not in value, value
        # Read-only discovery supplies the canonical identity; a nonempty
        # wrong identity still cannot address this Host.
        discovered = frame_host.host_info(runtime / "rui.sock", "")
        assert discovered["store"] == str(launched_store.resolve()), discovered
        wrong = frame_host.post(runtime / "rui.sock", "host-info",
                                {"version": frame_host.WIRE, "kind": "host_info", "store": str(pathlib.Path(root) / "foreign-store")}, expected_status=409)
        assert wrong["code"] == "wrong_store_identity", wrong
        host_process.close_stdin(launched)
        assert launched.wait(timeout=20) == 0, frame_host.output(launched)
        assert (launched_store / "diagnostics").is_dir() and not (runtime / "diagnostics").exists()
    finally:
        if launched.poll() is None:
            launched.kill()
        frame_host.output(launched)


def main():
    prove_fragmented_request()
    mysql_host_info()
    with tempfile.TemporaryDirectory(prefix="rui-host-info-") as root:
        root = canonical_fixture_root(root)
        resolved_sqlite_routing(root)
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
        with os_semantics.unix_stream() as endpoint:
            endpoint.bind(str(stale))
        assert status(store) == "unavailable", "stale socket claimed readiness"
        stale.unlink()

        with (store / "host.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert status(store) == "owned_unavailable"
            assert cli_status(home, "--store", store)["status"] == "owned_unavailable"
            for partial in (b"", b"HTTP/1.1 200 OK\r\n", b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{"):
                with os_semantics.unix_stream() as endpoint:
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
                        assert status(store, timed=True) == "owned_unavailable"
                        assert time.monotonic() - started < 2.5, "stalled Host-info peer exceeded deadline"
                    finally:
                        release.set()
                        stalled.join(timeout=3)
                    assert not stalled.is_alive()
                stale.unlink()
            with os_semantics.unix_stream() as endpoint:
                endpoint.bind(str(stale))
                endpoint.listen(1)
                def incompatible_peer():
                    connection, _ = endpoint.accept()
                    with connection:
                        read_request(connection)
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                            b"Content-Length: 2\r\nX-Rui-Wire-Version: " + str(int(host_process.WIRE_VERSION) + 1).encode() + b"\r\n\r\n{}"
                        )

                peer = threading.Thread(target=incompatible_peer)
                peer.start()
                # The CLI's status, exit and `host start` refusal for this peer
                # are cli.zig's "host status and start classify a Host's reply
                # however late it comes": the CLI runs on the real 1 s
                # Host-info deadline, which a loaded runner can miss (#967).
                assert status(store) == "incompatible"
                peer.join(timeout=3)
                assert not peer.is_alive()
            stale.unlink()
            if os_semantics.SOCKET_MODE_ENFORCED:
                with os_semantics.unix_stream() as endpoint:
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
                "version": host_process.WIRE_VERSION, "type": "host_info", "store": str(store.resolve()),
                "instance": "0" * 32, "activeCapacity": "01", "started_at": "1792918800", "custody_occupied": "1",
                "paused": False, "capabilities": {"bash": True, "providers": {"codex": "unserved", "openai": "unserved", "chatgpt": "unserved"}},
            }).encode()
            valid_body = noncanonical.replace(b'"activeCapacity": "01"', b'"activeCapacity": "1"')
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
                valid_body.replace(b'"paused": false, ', b''),
            )
            for response in (
                b"HTTP/1.1 bogus OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{}",
                (f"HTTP/1.1 200\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 f"X-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 0200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 f"X-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 f"X-Rui-Wire-Version : {host_process.WIRE_VERSION}\r\n\r\n").encode() + valid_body,
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(valid_body)}\r\n"
                 f"X-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\nTransfer-Encoding: chunked\r\n\r\n").encode() + valid_body,
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " + str(int(host_process.WIRE_VERSION) + 1).encode() + b"\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{}",
                b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{}",
                (f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(noncanonical)}\r\n"
                 f"X-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\n\r\n").encode() + noncanonical,
                *((f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n"
                   f"X-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\n\r\n").encode() + body for body in ambiguous_bodies),
            ):
                with os_semantics.unix_stream() as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(2)

                    def malformed_peer():
                        connection, _ = endpoint.accept()
                        with connection:
                            read_request(connection)
                            connection.sendall(response)

                    peer = threading.Thread(target=malformed_peer, daemon=True)
                    peer.start()
                    # The CLI prints this same classification; cli.zig checks
                    # its incompatible status and exit against a newer wire.
                    observed = status(store)
                    assert observed == "incompatible", (response, observed)
                    peer.join(timeout=3)
                    assert not peer.is_alive()
                stale.unlink()
            for kind, code in (("busy", "ordinary_capacity_exhausted"),
                               ("host_unavailable", "dispatch_fenced")):
                body = json.dumps({"version": host_process.WIRE_VERSION, "type": kind, "code": code}).encode()
                response = (f"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                            f"Content-Length: {len(body)}\r\nX-Rui-Wire-Version: {host_process.WIRE_VERSION}\r\n\r\n").encode() + body
                with os_semantics.unix_stream() as endpoint:
                    endpoint.bind(str(stale))
                    endpoint.listen(2)

                    def unavailable_peer():
                        connection, _ = endpoint.accept()
                        with connection:
                            read_request(connection)
                            connection.sendall(response)

                    peer = threading.Thread(target=unavailable_peer, daemon=True)
                    peer.start()
                    # The untimed actor proves the reply was classified, not
                    # timed out; cli.zig checks the CLI renders a fenced Host.
                    assert status(store) == "owned_unavailable"
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
                "version": host_process.WIRE_VERSION, "type": "host_status", "status": "ready", "store": str(store.resolve()),
                "instance": match.group(1), "activeCapacity": "3", "intake_capacity": "100",
                "descriptor_limit": fields["descriptor_limit"], "started_at": started_at, "custody_occupied": "0",
                "paused": False, "capabilities": {"bash": True, "providers": {"codex": "chatgpt_device", "openai": "unserved", "chatgpt": "unserved"}},
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
            assert "innodb_doublewrite" not in json.loads(body), body
            assert json.loads(body) == {
                "version": host_process.WIRE_VERSION, "type": "host_info", "store": str(store.resolve()),
                "instance": match.group(1), "activeCapacity": "3",
                "intake_capacity": "100", "descriptor_limit": fields["descriptor_limit"],
                "started_at": started_at, "custody_occupied": "0", "paused": False,
                "capabilities": {"bash": True, "providers": {"codex": "chatgpt_device", "openai": "unserved", "chatgpt": "unserved"}},
            }
            assert b'"type":"host_info"' in exchange("host_info", lambda: raw_info(stale, store.resolve(), match.group(1)), 5)
            # Holding new Turns is Host memory: the reply and Host status say it.
            for paused in (True, False):
                head, body = exchange("host_pause", lambda: raw_info(stale, store.resolve(), kind="host_pause", route="control/host-pause", extra={"paused": paused}), 5).split(b"\r\n\r\n", 1)
                assert head.startswith(b"HTTP/1.1 200 OK\r\n"), head
                assert json.loads(body) == {"version": host_process.WIRE_VERSION, "type": "host_pause_reply", "paused": paused}, body
                info = exchange("host_info", lambda: raw_info(stale, store.resolve()), 5).split(b"\r\n\r\n", 1)[1]
                assert json.loads(info)["paused"] is paused, info
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
            assert selected["capabilities"] == {"bash": True, "providers": {"codex": "unserved", "openai": "unserved", "chatgpt": "unserved"}}, selected
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
