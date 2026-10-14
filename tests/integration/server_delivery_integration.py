#!/usr/bin/env python3
"""Real 60-second reply inactivity, release, control headroom and Host drain.

Run directly with a ReleaseSafe Rui binary; no Client/schema/test-hook changes.
"""

import fcntl
import hashlib
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

import control_integration as control
import model_fixture as model
from host_process import HostDiagnostics, PeerCensus, canonical_fixture_root, dispose_all, stop_process


def exchange(sock, store, route, kind, **fields):
    body = json.dumps({"version": "1", "kind": kind, "store": str(store), **fields}).encode()
    return control.raw_request(sock, route, body)


def hold_reply(sock, store, route, kind, **fields):
    body = json.dumps({"version": "1", "kind": kind, "store": str(store), **fields}).encode()
    peer = socket.socket(socket.AF_UNIX)
    try:
        peer.settimeout(5)
        peer.connect(sock)
        peer.sendall(f"POST {route} HTTP/1.1\r\nContent-Type: application/json\r\n"
                     f"X-Rui-Wire-Version: 1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            byte = peer.recv(1)  # Do not drain any body or unblock its writer.
            assert byte, header
            header.extend(byte)
            assert len(header) <= 512
        assert header.startswith(b"HTTP/1.1 200 "), header
        length = int(next(line.split(b":", 1)[1] for line in header.split(b"\r\n")
                          if line.lower().startswith(b"content-length:")))
        assert length > 100_000, length
        return peer, length
    except BaseException:
        peer.close()
        raise


def resources(pid):
    root = pathlib.Path(f"/proc/{pid}")
    if not root.exists():
        return None  # Not native Mac footprint evidence.
    status = (root / "status").read_text()
    rss = int(next(line.split()[1] for line in status.splitlines() if line.startswith("VmRSS:")))
    return {"rss_kib": rss, "fds": len(os.listdir(root / "fd"))}


def main():
    with tempfile.TemporaryDirectory(prefix="rui-reply-") as root:
        state = canonical_fixture_root(root)
        store = state / "store"
        store.mkdir(mode=0o700)
        text = "é中\n" + "asymmetric-0123456789\n" * 12_000
        expected = text.encode()
        endpoint = model.SuccessEndpoint([model.sse_answer("reply", "private", "answer", text)[0]])
        worker = threading.Thread(target=endpoint.serve_forever)
        worker.start()
        host = None
        held = []
        held_requests = []
        try:
            host, ready = control.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                             "--test-client-send-buffer-bytes", "1024", observations="control_peers")
            diagnostics = HostDiagnostics(host)
            peers = PeerCensus(diagnostics)
            sock = ready["socket"]
            peers.call("configure", lambda: control.configure(state, store, "reply-config", "direct/reply"))
            peers.call("message", lambda: control.message(state, store, "reply-message", "direct/reply", "answer"))
            deadline = time.monotonic() + 8
            control.wait_for(lambda: peers.call("observe", lambda: control.observe(store, "reply-message", deadline=deadline),
                                               deadline=deadline).get("result", {}).get("status")
                             == "completed", "saved answer", deadline=deadline)
            baseline = resources(host.pid)

            def read(route, kind, **fields):
                native_route = {"inspect_session": "inspect", "observe_command": "observe"}.get(kind, kind)
                return peers.call(native_route, lambda: exchange(sock, store, route, kind, **fields), timeout=5)

            head, body = read("/v1/read-result", "read_result", key="reply-message")
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected
            head, body = read("/v1/conversation-page", "conversation_page",
                                  session="direct/reply", end="0", before_position="0", before_ordinal="0")
            assert head.startswith(b"HTTP/1.1 200 "), head
            item = json.loads(body)["items"][0]
            assert item["kind"] == "assistant", item
            for index in range(10):
                deadline = time.monotonic() + 5
                held_requests.append(peers.expect("conversation_content" if index in (0, 2) else
                                                  "inspect" if index % 2 else "read_result"))
                if index in (0, 2):
                    peer, length = hold_reply(sock, store, "/v1/conversation-content", "conversation_content",
                                              session="direct/reply", position=item["position"], ordinal="0", start="0", stream=True)
                elif index % 2:
                    peer, length = hold_reply(sock, store, "/v1/inspect-session", "inspect_session",
                                              session="direct/reply", profile="full")
                else:
                    peer, length = hold_reply(sock, store, "/v1/read-result", "read_result", key="reply-message")
                held.append((peer, length))
                peers.started(held_requests[-1], deadline)
            peers.held(held_requests)
            full = resources(host.pid)
            head, _ = peers.release_place("classification", lambda: exchange(
                sock, store, "/v1/observe-command", "observe_command", key="reply-message"), timeout=5)
            assert b" 503 " in head, head
            discovery_head, discovery_body = read("/v1/host-info", "host_info")
            assert discovery_head.startswith(b"HTTP/1.1 200 "), discovery_head
            assert json.loads(discovery_body)["store"] == str(store), discovery_body
            # A committed idle stop fits protected capacity while all ten
            # ordinary writers remain held; it cannot revoke the saved answer.
            assert peers.call("session_stop", lambda: control.stop_session(
                state, store, "reply-stop", "direct/reply"))["answer"]["status"] == "accepted"
            # Disconnect releases one exchange, not the committed result.
            deadline = time.monotonic() + 8
            held.pop(0)[0].close()  # Whole-stream Conversation reader.
            peers.release(held_requests.pop(0), deadline)
            head, body = read("/v1/read-result", "read_result", key="reply-message")
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected
            assert int(peers.call("inspect", lambda: control.inspect_execution(
                store, "direct/reply"))["scratch_used_bytes"]) > 0
            deadline = time.monotonic() + 5
            held_requests.append(peers.expect("read_result"))
            held.append(hold_reply(sock, store, "/v1/read-result", "read_result", key="reply-message"))
            peers.started(held_requests[-1], deadline)
            peers.held(held_requests)
            print(json.dumps({"phase": "held", "baseline": baseline, "held": full}), flush=True)
            # No reader rescue: ten unread peers remain open for the real
            # production inactivity interval. Shutdown must drain them itself.
            started = time.monotonic()
            stop_deadline = started + 5
            stop_requests = [peers.expect("host_info"), peers.expect("host_stop")]
            stopped = subprocess.run([control.RUI, "host", "stop", "--store", store],
                                     capture_output=True, text=True, timeout=5)
            assert stopped.returncode == 0, stopped
            identity = json.loads(discovery_body)["instance"]
            assert f"Host instance: {identity} (retry with --instance {identity})" in stopped.stdout, stopped
            assert "Stop acknowledged; completion and lease release are not confirmed" in stopped.stdout, stopped
            for request in stop_requests:
                peers.release(request, stop_deadline)
            control.wait_for(lambda: not pathlib.Path(sock).exists(), "listener closure with ten readers held")
            with (store / "host.lock").open("rb") as lease:
                try:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("lease released before unread borrowers drained")
            assert host.poll() is None, "acknowledgement is not completed drain"
            assert host.wait(timeout=75) == 1
            elapsed = time.monotonic() - started
            assert 55 <= elapsed < 75, elapsed
            peers.finish(started + 75)
            for peer, length in held:
                partial = bytearray()
                while chunk := peer.recv(4096):
                    partial.extend(chunk)
                    assert len(partial) < length, "stalled reply unexpectedly complete"
                assert b"HTTP/1.1" not in partial, "second HTTP reply appended"
            stop_process(host)
            assert b"EffectAwareShutdown" in diagnostics.tail(), "not the normal Host drain"
            peers.finish(time.monotonic())
            host = None
            # Restart and public reads prove the timed-out delivery did not
            # reject/cancel/alter committed work. Fresh accounting is checked
            # separately; it is not proof of the old process's exact refund.
            host, ready = control.start_host(store, observations="control_peers")
            diagnostics = HostDiagnostics(host)
            peers = PeerCensus(diagnostics)
            sock = ready["socket"]
            head, body = read("/v1/read-result", "read_result", key="reply-message")
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected
            assert int(peers.call("inspect", lambda: control.inspect_execution(
                store, "direct/reply"))["scratch_used_bytes"]) == 0
            print(json.dumps({"delivery": "passed", "bytes": len(expected), "sha256": hashlib.sha256(expected).hexdigest(),
                              "drain_seconds": elapsed, "baseline": baseline, "held": full,
                              "restart": resources(host.pid)}))
            stop_process(host)
            peers.finish(time.monotonic())
            host = None
        finally:
            def join():
                worker.join(timeout=5)
                assert not worker.is_alive()
            dispose_all(*(peer.close for peer, _ in held), lambda: stop_process(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, join)


if __name__ == "__main__":
    main()
