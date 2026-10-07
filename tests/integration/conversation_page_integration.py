#!/usr/bin/env python3
"""Public Conversation wire reads against a real Host and canonical Store."""

import hashlib
import http.server
import json
import os
import pathlib
import shutil
import sqlite3
import tempfile
import threading

from control_integration import (
    StreamingEndpoint,
    configure,
    encode_sse,
    inspect_execution,
    message,
    raw_request,
    start_host,
    stop_session,
    successful_sse,
    wait_for,
)
from host_process import TestHTTPServer, stop_process


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


def projected_ranges():
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            body = successful_sse(1, "x" * 4094 + "é中🙂\n\\\"/tail")
            events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith(b"data: ")]
            for item in (events[1]["item"], events[2]["response"]["output"][0]):
                item["content"].extend({"type": "output_text", "text": "", "annotations": []} for _ in range(2))
            body = encode_sse(events)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True

        def log_message(self, _format, *_args):
            pass

    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-projected-ranges-"))
    store = state / "store"
    store.mkdir(mode=0o700)
    endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    process = None
    expected = ("x" * 4094 + "é中🙂\n\\\"/tail").encode()
    try:
        provider = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, fields = start_host(store, provider)
        configure(state, store, "projection-config", "direct/projection")
        message(state, store, "projection-key", "direct/projection", "input")

        def completed_page():
            head, body = request(fields["socket"], store, "/v1/conversation-page", "conversation_page", "direct/projection",
                end="0", before_position="0", before_ordinal="0")
            assert head.startswith(b"HTTP/1.1 200 "), (head, body)
            page = json.loads(body)
            return page if page["items"] and page["items"][0]["kind"] == "assistant" else None

        page = wait_for(completed_page, "public assistant projection")
        item = page["items"][0]
        domain = b"rui/content/v1"
        assert item["content"]["sha256"] == hashlib.sha256(len(domain).to_bytes(8, "big") + domain + expected).hexdigest(), item
        for start in (0, 4095, 4096, len(expected) - 1, len(expected), len(expected), 1):
            head, data = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", "direct/projection",
                position=item["position"], ordinal="0", start=str(start))
            assert head.startswith(b"HTTP/1.1 200 "), (head, data)
            assert data == expected[start:start + 4096], (start, len(data))
            assert f"X-Rui-Content-Bytes: {len(expected)}\r\n".encode() in head, head
            assert f"X-Rui-Next-Offset: {start + len(data)}\r\n".encode() in head, head
        wait_for(lambda: inspect_execution(store, "direct/projection")["custody_occupied"] == "0", "projected result cleanup")
        # Production preserves empty text records at the tail. Add a nonempty
        # part beyond those rows and an ordinal gap, leaving prefix/digest intact.
        stop_process(process)
        process = None
        with sqlite3.connect(store / "rui.sqlite3") as database:
            answer, source, start, payload = database.execute(
                "SELECT p.answer_content_id,p.source_content_id,p.encoded_start,c.payload FROM answer_text_projection p "
                "JOIN content c ON c.content_id=p.source_content_id WHERE p.part_ordinal=0"
            ).fetchone()
            assert database.execute(
                "SELECT part_ordinal,encoded_length,decoded_length FROM answer_text_projection "
                "WHERE answer_content_id=? AND part_ordinal>0 ORDER BY part_ordinal", (answer,)
            ).fetchall() == [(1, 0, 0), (2, 0, 0)]
            database.execute("INSERT INTO answer_text_projection VALUES(?,?,?,?,?,?)", (answer, 4, source, start, 1, 1))
        # Restart separately: the first canonical failure fences the running
        # Store and may not substitute for the second offset's EOF-tail witness.
        for offset in (len(expected) - 1, len(expected)):
            process, fields = start_host(store, provider)
            head, body = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", "direct/projection",
                position=item["position"], ordinal="0", start=str(offset))
            assert head.startswith(b"HTTP/1.1 500 "), (offset, head, body)
            assert json.loads(body)["code"] == "canonical_store_failure", body
            print(f"projected nonempty-tail offset {offset}: canonical corruption HTTP 500")
            stop_process(process)
            process = None
        # Retain the distinct original digest-substitution witness, without
        # allowing the extra-tail rejection to mask it.
        with sqlite3.connect(store / "rui.sqlite3") as database:
            database.execute("DELETE FROM answer_text_projection WHERE answer_content_id=? AND part_ordinal=4", (answer,))
            assert payload[start:start + 1] == b"x"
            database.execute("UPDATE content SET payload=? WHERE content_id=?", (payload[:start] + b"y" + payload[start + 1:], source))
        process, fields = start_host(store, provider)
        # Complete projected identity must fail before publishing the final
        # range or successful EOF. This is not earlier-range authentication.
        head, body = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", "direct/projection",
            position=item["position"], ordinal="0", start=str(len(expected) - 1))
        assert head.startswith(b"HTTP/1.1 500 "), (head, body)
        assert json.loads(body)["code"] == "canonical_store_failure", body
        print("projected Conversation ranges: exact escaped/multibyte bytes, healthy trailing empties, repeated EOF, tail and digest corruption fences passed")
    finally:
        if process is not None:
            stop_process(process)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=3)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
    projected_ranges()
