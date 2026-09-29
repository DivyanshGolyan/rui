#!/usr/bin/env python3
"""Native protected stop, exact-instance retry, and Host-owned drain."""

import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading

import bash_integration as bash_fixture
import dispatch_integration as fixture
from host_process import HostDiagnostics, stop_process
from host_status_integration import socket_path, status


RUI, ACTOR = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])
fixture.RUI = RUI


def actor(*args):
    result = subprocess.run([ACTOR, *map(str, args)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def instance(store):
    match = re.fullmatch(r"ready ([0-9a-f]{32}) \d+ true (?:true|false) (?:true|false)", status(store))
    assert match, status(store)
    return match.group(1)


def request(sock, store, identity=None, *, extra=b""):
    body = json.dumps({"version": "1", "kind": "host_stop", "store": str(store.resolve())}).encode()
    header = (
        b"POST /v1/control/host-stop HTTP/1.1\r\nHost: local\r\n"
        + b"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
    )
    if identity is not None:
        header += f"X-Rui-Host-Instance: {identity}\r\n".encode()
    stream = socket.socket(socket.AF_UNIX)
    stream.settimeout(5)
    stream.connect(str(sock))
    stream.sendall(header + extra + b"\r\n")
    return stream, body


def finish(stream, body):
    with stream:
        stream.sendall(body)
        response = bytearray()
        while chunk := stream.recv(4096):
            response.extend(chunk)
            assert len(response) < 8192
    return bytes(response)


def main():
    with tempfile.TemporaryDirectory(prefix="rui-host-stop-") as root:
        state = pathlib.Path(root)
        store = state / "store"
        gate = state / "bash-cleanup-gate"
        gate.write_text("held")
        responses = []
        bash_fixture.add_exchange(responses, "host-stop", "printf stopped")
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        host = None
        replacement = None
        diagnostics = None
        pending = None
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                      "--test-bash-cleanup-gate-path", gate, "--test-phase-trace")
            diagnostics = HostDiagnostics(host)
            target = instance(store)
            sock = socket_path(store)
            wrong = actor("stop", store, "0" * 32)
            assert wrong == "instance_changed", wrong
            missing, body = request(sock, store)
            assert b"host_instance_required" in finish(missing, body)
            assert instance(store) == target
            detached, _ = request(sock, store, target)
            detached.close()  # Incomplete request / terminal detach is not a stop.
            assert instance(store) == target

            bash_fixture.configure(state, store, "stop-config", "direct/stop")
            fixture.message(state, store, "stop-message", "direct/stop", "run Bash")
            action = fixture.wait_for(lambda: bash_fixture.action_for(store, "direct/stop"), "Bash Action")
            bash_fixture.allow(state, store, "stop-allow", "direct/stop", action["action"])
            diagnostics.wait("cleanup_started", action=str(action["action"]))
            assert not diagnostics.matching("cleanup_completed", action=str(action["action"]))
            occupied = fixture.command("inspect-session", "--store", store, "--session", "direct/stop")["execution"]
            assert int(occupied["custody_occupied"]) > 0, occupied
            held_fds = len(os.listdir(f"/proc/{host.pid}/fd")) if sys.platform == "linux" else None

            # Both connections were accepted before shutdown. The second can
            # retry its original instance after the listener has closed.
            pending, pending_body = request(sock, store, target)
            transferred = socket.socket(socket.AF_UNIX)
            transferred.settimeout(5)
            transferred.connect(str(sock))
            transferred.sendall(b"POST /v1/host-info HTTP/1.1\r\n")
            first = actor("stop", store, target, "after-commit")
            assert first == "TruncatedResponse", first
            retry = finish(pending, pending_body)
            assert retry.startswith(b"HTTP/1.1 200") and b'"status":"acknowledged"' in retry, retry
            pending = None
            fixture.wait_for(lambda: not sock.exists(), "listener closure before cleanup")
            with socket.socket(socket.AF_UNIX) as newcomer:
                try:
                    newcomer.connect(str(sock))
                except (FileNotFoundError, ConnectionRefusedError):
                    pass
                else:
                    raise AssertionError("new client connected after listener closure")
            assert status(store) == "owned_unavailable"
            assert host.poll() is None, "acknowledgement was mistaken for completion"
            contender = subprocess.run(
                [RUI, "serve", "--store", store, "--active-capacity", "1"],
                capture_output=True, timeout=10,
            )
            assert contender.returncode != 0 and b"ready store=" not in contender.stdout, contender
            assert not diagnostics.matching("cleanup_completed", action=str(action["action"]))
            gate.unlink()
            diagnostics.wait("cleanup_completed", action=str(action["action"]))
            assert host.poll() is None, "transferred connection must retain lease"
            assert status(store) == "owned_unavailable"
            drained_fds = len(os.listdir(f"/proc/{host.pid}/fd")) if held_fds is not None else None
            if held_fds is not None:
                assert drained_fds < held_fds, (held_fds, drained_fds)
            transferred.close()
            assert host.wait(timeout=10) != 0  # existing graceful owner reports EffectAwareShutdown
            diagnostics.close()
            diagnostics = None
            host.stdout.close()
            host.stderr.close()
            host = None
            assert status(store) == "unavailable"
            assert list((store / "scratch").iterdir()) == [], "shutdown retained scratch"
            replacement = fixture.start_host(store, None)
            newer = instance(store)
            assert newer != target
            # The first reply was lost. Retrying A's retained input must not
            # rediscover or stop live replacement B.
            assert actor("stop", store, target) == "instance_changed"
            assert instance(store) == newer
            stale_cli = subprocess.run([RUI, "host", "stop", "--store", store, "--instance", target],
                                       capture_output=True, text=True, timeout=10)
            assert stale_cli.returncode != 0 and "Host instance changed" in stale_cli.stderr, stale_cli
            assert instance(store) == newer
            current_cli = subprocess.run([RUI, "host", "stop", "--store", store],
                                         capture_output=True, text=True, timeout=10)
            assert current_cli.returncode == 0 and "Stop acknowledged; completion and lease release are not confirmed" in current_cli.stdout, current_cli
            assert f"Host instance: {newer} (retry with --instance {newer})" in current_cli.stdout
            assert replacement.wait(timeout=10) != 0
            replacement.stdout.close()
            replacement.stderr.close()
            replacement = None
            assert actor("stop", store, newer) == "unavailable", "retry may not select a replacement"
            print(f"host-stop passed: guarded rejection, acknowledged retry, held cleanup/connection lease, replacement; Linux fd={held_fds}->{drained_fds}, scratch=0")
        finally:
            gate.unlink(missing_ok=True)
            if pending is not None:
                pending.close()
            if diagnostics is not None and host is not None:
                stop_process(host)
                diagnostics.close()
            elif host is not None:
                stop_process(host)
            if replacement is not None:
                stop_process(replacement)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    main()
