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

from host_process import start_ready_process, stop_process


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
        response = bytearray()
        while True:
            chunk = stream.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
            assert len(response) < 8192
    return bytes(response)


def main():
    with tempfile.TemporaryDirectory(prefix="rui-host-info-") as root:
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
                            connection.recv(4096)
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
                            connection.recv(4096)
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
            if sys.platform == "linux":
                # Linux enforces mode bits on the Unix socket itself.
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
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\nX-Rui-Wire-Version: 1\r\n\r\n",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 2\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
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
                                connection.recv(4096)
                                connection.sendall(response)

                    peer = threading.Thread(target=malformed_peer, daemon=True)
                    peer.start()
                    assert status(store) == "incompatible"
                    assert cli_status(home, "--store", store).startswith("Host: incompatible")
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
        # start_ready_process inherits this test's environment.
        old = os.environ.get("RUI_CODEX_CREDENTIAL_FILE")
        os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential)
        try:
            first, fields = start(store, 3, "--codex")
            assert fields["execution"] == "enabled"
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
            before_fd = len(os.listdir(f"/proc/{first.pid}/fd")) if sys.platform == "linux" else None
            for _ in range(40):
                assert status(alias) == first_status
            after_fd = len(os.listdir(f"/proc/{first.pid}/fd")) if sys.platform == "linux" else None
            if before_fd is not None:
                assert after_fd == before_fd, (before_fd, after_fd)
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
