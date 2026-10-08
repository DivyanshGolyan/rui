#!/usr/bin/env python3
"""Real 60-second reply inactivity, release, control headroom and Host drain.

Run directly with a ReleaseSafe Rui binary; no Client/schema/test-hook changes.
"""

import hashlib
import json
import os
import pathlib
import socket
import sys
import tempfile
import threading
import time

import control_integration as control
import dispatch_integration as model
from host_process import stop_process
from host_process import canonical_fixture_root


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
        try:
            host, ready = control.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                             "--test-client-send-buffer-bytes", "1024")
            sock = ready["socket"]
            control.configure(state, store, "reply-config", "direct/reply")
            control.message(state, store, "reply-message", "direct/reply", "answer")
            control.wait_for(lambda: control.observe(store, "reply-message").get("result", {}).get("status")
                             == "completed", "saved answer")
            baseline = resources(host.pid)
            head, body = exchange(sock, store, "/v1/read-result", "read_result", key="reply-message")
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected
            head, body = exchange(sock, store, "/v1/conversation-page", "conversation_page",
                                  session="direct/reply", end="0", before_position="0", before_ordinal="0")
            assert head.startswith(b"HTTP/1.1 200 "), head
            item = json.loads(body)["items"][0]
            assert item["kind"] == "assistant", item
            for index in range(10):
                if index in (0, 2):
                    peer, length = hold_reply(sock, store, "/v1/conversation-content", "conversation_content",
                                              session="direct/reply", position=item["position"], ordinal="0", start="0", stream=True)
                elif index % 2:
                    peer, length = hold_reply(sock, store, "/v1/inspect-session", "inspect_session",
                                              session="direct/reply", profile="full")
                else:
                    peer, length = hold_reply(sock, store, "/v1/read-result", "read_result", key="reply-message")
                held.append((peer, length))
            full = resources(host.pid)
            head, _ = exchange(sock, store, "/v1/observe-command", "observe_command", key="reply-message")
            assert b" 503 " in head, head
            discovery_head, discovery_body = exchange(sock, store, "/v1/host-info", "host_info")
            assert discovery_head.startswith(b"HTTP/1.1 200 "), discovery_head
            assert json.loads(discovery_body)["store"] == str(store), discovery_body
            # A committed idle stop fits protected capacity while all ten
            # ordinary writers remain held; it cannot revoke the saved answer.
            assert control.stop_session(state, store, "reply-stop", "direct/reply")["answer"]["status"] == "accepted"
            # Disconnect releases one exchange, not the committed result.
            held.pop(0)[0].close()  # Whole-stream Conversation reader.

            def reclaimed():
                head, body = exchange(sock, store, "/v1/read-result", "read_result", key="reply-message")
                return body if head.startswith(b"HTTP/1.1 200 ") else None

            assert control.wait_for(reclaimed, "disconnected place release") == expected
            assert int(control.inspect_execution(store, "direct/reply")["scratch_used_bytes"]) > 0
            held.append(hold_reply(sock, store, "/v1/read-result", "read_result", key="reply-message"))
            print(json.dumps({"phase": "held", "baseline": baseline, "held": full}), flush=True)
            # No reader rescue: ten unread peers remain open for the real
            # production inactivity interval. Shutdown must drain them itself.
            started = time.monotonic()
            host_head, host_body = exchange(sock, store, "/v1/host-info", "host_info")
            assert host_head.startswith(b"HTTP/1.1 200 "), host_head
            identity = json.loads(host_body)["instance"]
            stop_body = json.dumps({"version": "1", "kind": "host_stop", "store": str(store)}).encode()
            with socket.socket(socket.AF_UNIX) as stop:
                stop.settimeout(5)
                stop.connect(sock)
                stop.sendall(f"POST /v1/control/host-stop HTTP/1.1\r\nContent-Type: application/json\r\n"
                             f"X-Rui-Wire-Version: 1\r\nX-Rui-Host-Instance: {identity}\r\n"
                             f"Content-Length: {len(stop_body)}\r\n\r\n".encode() + stop_body)
                head, body = control.read_http_response(stop)
                assert b" 200 " in head and json.loads(body)["status"] == "acknowledged", (head, body)
            assert host.poll() is None, "acknowledgement is not completed drain"
            assert host.wait(timeout=75) == 1
            assert b"EffectAwareShutdown" in host.stderr.read(), "not the normal Host drain"
            elapsed = time.monotonic() - started
            assert 55 <= elapsed < 75, elapsed
            for peer, length in held:
                partial = bytearray()
                while chunk := peer.recv(4096):
                    partial.extend(chunk)
                    assert len(partial) < length, "stalled reply unexpectedly complete"
                assert b"HTTP/1.1" not in partial, "second HTTP reply appended"
            stop_process(host)
            host = None
            # Restart and public reads prove the timed-out delivery did not
            # reject/cancel/alter committed work. Fresh accounting is checked
            # separately; it is not proof of the old process's exact refund.
            host, ready = control.start_host(store)
            head, body = exchange(ready["socket"], store, "/v1/read-result", "read_result", key="reply-message")
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected
            assert int(control.inspect_execution(store, "direct/reply")["scratch_used_bytes"]) == 0
            print(json.dumps({"delivery": "passed", "bytes": len(expected), "sha256": hashlib.sha256(expected).hexdigest(),
                              "drain_seconds": elapsed, "baseline": baseline, "held": full,
                              "restart": resources(host.pid)}))
        finally:
            for peer, _ in held:
                peer.close()
            stop_process(host)
            endpoint.shutdown()
            endpoint.server_close()
            worker.join(timeout=5)
            assert not worker.is_alive()


if __name__ == "__main__":
    main()
