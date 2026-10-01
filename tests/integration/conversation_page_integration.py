#!/usr/bin/env python3
"""Public Conversation wire reads against a real Host and canonical Store."""

import hashlib
import json
import os
import pathlib
import shutil
import tempfile
import threading

from control_integration import (
    StreamingEndpoint,
    configure,
    inspect_execution,
    message,
    raw_request,
    start_host,
    stop_session,
    wait_for,
)
from host_process import stop_process


def request(socket_path, store, route, kind, session, **fields):
    body = json.dumps(
        {"version": "1", "kind": kind, "store": str(store), "session": session, **fields},
        separators=(",", ":"),
    ).encode()
    return raw_request(socket_path, route, body)


def host_resources(pid):
    if not pathlib.Path(f"/proc/{pid}/status").exists():
        return None  # Linux process diagnostics; not a macOS footprint verdict.
    status = pathlib.Path(f"/proc/{pid}/status").read_text()
    rss = int(next(line.split()[1] for line in status.splitlines() if line.startswith("VmRSS:"))) * 1024
    return rss, len(os.listdir(f"/proc/{pid}/fd"))


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-conversation-page-"))
    store = state / "store"
    store.mkdir(mode=0o700)
    endpoint = StreamingEndpoint()
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    process = None
    try:
        process, fields = start_host(store, f"http://127.0.0.1:{endpoint.server_address[1]}/responses")
        socket_path = fields["socket"]
        configure(state, store, "page-config", "direct/page")
        head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", "direct/page",
            end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        assert json.loads(body)["items"] == []

        baseline = host_resources(process.pid)
        payload = "é中" + "x" * 10000
        message(state, store, "page-message", "direct/page", payload)
        wait_for(lambda: endpoint.counts()[0] == 1, "held provider request")
        head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", "direct/page",
            end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        page = json.loads(body)
        assert page["direction"] == "newest_first" and not page["more"], page
        assert len(page["items"]) == 1, page
        item = page["items"][0]
        assert item["kind"] == "user" and item["ordinal"] == "0", item
        # Invalid public identities must not turn a SQL bind error into a
        # canonical Store fence. A subsequent ordinary read still succeeds.
        for field in ("end", "before_position", "before_ordinal"):
            cursor = {"end": page["end"], "before_position": item["position"], "before_ordinal": "0"}
            cursor[field] = str(2**64 - 1)
            head, _ = request(socket_path, store, "/v1/conversation-page", "conversation_page", "direct/page", **cursor)
            assert head.startswith(b"HTTP/1.1 400 "), head
        head, _ = request(socket_path, store, "/v1/conversation-page", "conversation_page", "direct/page",
            end=page["end"], before_position=item["position"], before_ordinal="1")
        assert head.startswith(b"HTTP/1.1 409 "), head
        for field in ("position", "ordinal"):
            identity = {"position": item["position"], "ordinal": "0", "start": "0"}
            identity[field] = str(2**64 - 1)
            head, _ = request(socket_path, store, "/v1/conversation-content", "conversation_content", "direct/page", **identity)
            assert head.startswith(b"HTTP/1.1 400 "), head
        head, _ = request(socket_path, store, "/v1/conversation-page", "conversation_page", "direct/page",
            end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 "), head
        domain = b"rui/content/v1"
        assert item["content"] == {
            "bytes": "10005", "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + payload.encode()).hexdigest(),
            "display": "omitted",
        }, item
        # Range offsets are bytes, not UTF-8 character indices. The first
        # transfer can end inside a scalar; joining transfers is lossless.
        chunks = []
        start = 0
        while start < len(payload.encode()):
            head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", "direct/page",
                position=item["position"], ordinal="0", start=str(start))
            assert head.startswith(b"HTTP/1.1 200 "), (head, data)
            assert b"X-Rui-Content-Bytes: 10005\r\n" in head, head
            next_offset = int(next(line.split(b": ", 1)[1] for line in head.split(b"\r\n") if line.startswith(b"X-Rui-Next-Offset:")))
            assert len(data) <= 4096 and next_offset == start + len(data), (head, len(data))
            chunks.append(data)
            start = next_offset
        assert b"".join(chunks) == payload.encode() and len(chunks) == 3
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", "direct/page",
            position=item["position"], ordinal="0", start=str(len(payload.encode())))
        assert head.startswith(b"HTTP/1.1 200 ") and data == b"", (head, data)
        assert b"X-Rui-Next-Offset: 10005\r\n" in head, head
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", "direct/page",
            position=item["position"], ordinal="0", start="1")
        assert head.startswith(b"HTTP/1.1 200 ") and data == payload.encode()[1:4097]
        for session, position, ordinal, start in (
            ("direct/foreign", item["position"], "0", "0"),
            ("direct/page", page["end"], "0", "0"),
            ("direct/page", item["position"], "1", "0"),
            ("direct/page", item["position"], "0", "10006"),
        ):
            head, _ = request(socket_path, store, "/v1/conversation-content", "conversation_content", session,
                position=position, ordinal=ordinal, start=start)
            assert head.startswith(b"HTTP/1.1 409 "), head
        # Keep the provider held. These large admissions remain unapplied and
        # cannot inflate the public page or add per-message resident buffers.
        for index in range(8):
            message(state, store, f"queued-{index}", "direct/page", "q" * (256 * 1024))
        after = host_resources(process.pid)
        head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", "direct/page",
            end=page["end"], before_position=item["position"], before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["items"] == [], (head, body)
        assert stop_session(state, store, "page-stop", "direct/page")["answer"]["status"] == "accepted"
        endpoint.release.set()
        wait_for(lambda: inspect_execution(store, "direct/page")["custody_occupied"] == "0", "physical cleanup")
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", "direct/page",
            position=item["position"], ordinal="0", start="10000")
        assert head.startswith(b"HTTP/1.1 200 ") and data == payload.encode()[10000:]
        drained = host_resources(process.pid)
        print(f"conversation Host resource snapshots baseline={baseline} queued_2MiB={after} drained={drained} (RSS bytes, FDs; Linux only)")
    finally:
        endpoint.release.set()
        if process is not None:
            stop_process(process)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=3)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
