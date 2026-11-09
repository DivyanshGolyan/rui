#!/usr/bin/env python3
"""Public Conversation wire reads against a real Host and canonical Store."""

import hashlib
import http.server
import json
import shutil
import sqlite3
import tempfile
import threading
import time

from control_fixture import StreamingEndpoint, configure, inspect_execution, message, start_host, stop_session, successful_sse
from control_fixture import encode_sse
from host_process import wait_for
import host_process
from host_process import TestHTTPServer, canonical_fixture_root, dispose_all
from conversation_page_fixture import dispose_page, host_resources
from conversation_page_fixture import request, whole_stream_shape


ACTIVITY_KINDS = ["admission", "user", "assistant", "call", "tool_result", "hosted_call", "turn_ended", "stop", "sent", "send_failed", "received", "approval_requested", "session_changed", "compacted"]


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-conversation-page-"))
    store = state / "store"
    store.mkdir(mode=0o700)
    endpoint = StreamingEndpoint()
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    process = None
    try:
        thread.start()
        process, fields = start_host(store, f"http://127.0.0.1:{endpoint.server_address[1]}/responses")
        socket_path = fields["socket"]
        page_session = configure(state, store, "page-config")
        foreign_session = configure(state, store, "foreign-config")
        # Raw wire identities are exact, even when an alias selects this Store
        # through the production Client. Keep this deliberate alias unnormalized.
        alias = state / "store-alias"
        alias.symlink_to(store, target_is_directory=True)
        head, body = request(socket_path, alias, "/v1/conversation-page", "conversation_page", page_session,
            end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 409 "), (head, body)
        assert json.loads(body) == {"version": host_process.WIRE_VERSION, "type": "invocation_error", "code": "wrong_store_identity"}, body
        head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", page_session,
            end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        assert json.loads(body)["items"] == []

        baseline = host_resources(process.pid)
        payload = "é中" + "x" * 10000
        admitted_after = int(time.time())
        message(state, store, "page-message", page_session, payload)
        wait_for(lambda: endpoint.counts()[0] == 1, "held provider request")
        head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", page_session,
            end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        page = json.loads(body)
        assert page["direction"] == "newest_first" and not page["more"], page
        assert len(page["items"]) == 1, page
        item = page["items"][0]
        assert item["kind"] == "user" and item["ordinal"] == "0", item
        # The Host stamps its own wall-clock second when it admits the row.
        assert admitted_after <= int(item["admitted_at"]) <= int(time.time()), item
        # Invalid public identities must not turn a SQL bind error into a
        # canonical Store fence. A subsequent ordinary read still succeeds.
        for field in ("end", "before_position", "before_ordinal"):
            cursor = {"end": page["end"], "before_position": item["position"], "before_ordinal": "0"}
            cursor[field] = str(2**64 - 1)
            head, _ = request(socket_path, store, "/v1/conversation-page", "conversation_page", page_session, **cursor)
            assert head.startswith(b"HTTP/1.1 400 "), head
        head, _ = request(socket_path, store, "/v1/conversation-page", "conversation_page", page_session,
            end=page["end"], before_position=item["position"], before_ordinal="1")
        assert head.startswith(b"HTTP/1.1 409 "), head
        for field in ("position", "ordinal"):
            identity = {"position": item["position"], "ordinal": "0", "start": "0"}
            identity[field] = str(2**64 - 1)
            head, _ = request(socket_path, store, "/v1/conversation-content", "conversation_content", page_session, **identity)
            assert head.startswith(b"HTTP/1.1 400 "), head
        head, _ = request(socket_path, store, "/v1/conversation-page", "conversation_page", page_session,
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
            head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", page_session,
                position=item["position"], ordinal="0", start=str(start))
            assert head.startswith(b"HTTP/1.1 200 "), (head, data)
            assert b"X-Rui-Content-Bytes: 10005\r\n" in head, head
            next_offset = int(next(line.split(b": ", 1)[1] for line in head.split(b"\r\n") if line.startswith(b"X-Rui-Next-Offset:")))
            assert len(data) <= 4096 and next_offset == start + len(data), (head, len(data))
            chunks.append(data)
            start = next_offset
        assert b"".join(chunks) == payload.encode() and len(chunks) == 3
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", page_session,
            position=item["position"], ordinal="0", start="0", stream=True)
        assert head.startswith(b"HTTP/1.1 200 ") and data == payload.encode(), (head, len(data))
        assert b"Content-Length: 10005\r\n" in head and b"X-Rui-Next-Offset: 10005\r\n" in head, head
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", page_session,
            position=item["position"], ordinal="0", start=str(len(payload.encode())))
        assert head.startswith(b"HTTP/1.1 200 ") and data == b"", (head, data)
        assert b"X-Rui-Next-Offset: 10005\r\n" in head, head
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", page_session,
            position=item["position"], ordinal="0", start="1")
        assert head.startswith(b"HTTP/1.1 200 ") and data == payload.encode()[1:4097]
        for session, position, ordinal, start in (
            (foreign_session, item["position"], "0", "0"),
            (page_session, page["end"], "0", "0"),
            (page_session, item["position"], "1", "0"),
            (page_session, item["position"], "0", "10006"),
        ):
            head, _ = request(socket_path, store, "/v1/conversation-content", "conversation_content", session,
                position=position, ordinal=ordinal, start=start)
            assert head.startswith(b"HTTP/1.1 409 "), head
        # Keep the provider held. These large admissions remain unapplied and
        # cannot inflate the public page or add per-message resident buffers.
        for index in range(8):
            message(state, store, f"queued-{index}", page_session, "q" * (256 * 1024))
        after = host_resources(process.pid)
        head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", page_session,
            end=page["end"], before_position=item["position"], before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["items"] == [], (head, body)
        assert stop_session(state, store, "page-stop", page_session)["answer"]["status"] == "accepted"
        endpoint.release.set()
        wait_for(lambda: inspect_execution(store, page_session)["custody_occupied"] == "0", "physical cleanup")
        head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", page_session,
            position=item["position"], ordinal="0", start="10000")
        assert head.startswith(b"HTTP/1.1 200 ") and data == payload.encode()[10000:]
        drained = host_resources(process.pid)
        print(f"conversation Host resource snapshots baseline={baseline} queued_2MiB={after} drained={drained} (RSS bytes, FDs; Linux only)")
    finally:
        dispose_all(endpoint.release.set,
                    lambda: dispose_page(process, endpoint, thread, 3),
                    lambda: shutil.rmtree(state))


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

    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-projected-ranges-"))
    store = state / "store"
    store.mkdir(mode=0o700)
    endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    process = None
    expected = ("x" * 4094 + "é中🙂\n\\\"/tail").encode()
    try:
        thread.start()
        provider = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, fields = start_host(store, provider)
        session = configure(state, store, "projection-config")
        message(state, store, "projection-key", session, "input")

        def completed_page():
            head, body = request(fields["socket"], store, "/v1/conversation-page", "conversation_page", session,
                end="0", before_position="0", before_ordinal="0")
            assert head.startswith(b"HTTP/1.1 200 "), (head, body)
            page = json.loads(body)
            return page if page["items"] and page["items"][0]["kind"] == "assistant" else None

        page = wait_for(completed_page, "public assistant projection")
        item = page["items"][0]
        domain = b"rui/content/v1"
        assert item["content"]["sha256"] == hashlib.sha256(len(domain).to_bytes(8, "big") + domain + expected).hexdigest(), item
        for start in (0, 4095, 4096, len(expected) - 1, len(expected), len(expected), 1):
            head, data = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", session,
                position=item["position"], ordinal="0", start=str(start))
            assert head.startswith(b"HTTP/1.1 200 "), (head, data)
            assert data == expected[start:start + 4096], (start, len(data))
            assert f"X-Rui-Content-Bytes: {len(expected)}\r\n".encode() in head, head
            assert f"X-Rui-Next-Offset: {start + len(data)}\r\n".encode() in head, head
        wait_for(lambda: inspect_execution(store, session)["custody_occupied"] == "0", "projected result cleanup")
        print("multi-part Conversation ranges: exact escaped/multibyte bytes, healthy trailing empties and repeated EOF passed")
    finally:
        dispose_all(lambda: dispose_page(process, endpoint, thread, 3),
                    lambda: shutil.rmtree(state))


def missing_assistant_entries():
    """Stopped synthetic Store damage must not look like absent public text."""
    import model_fixture as f
    from host_process import HostDiagnostics

    items = [{"type": "message", "id": f"message-{index}", "role": "assistant", "phase": phase,
              "content": [{"type": "output_text", "text": text}]}
             for index, (phase, text) in enumerate((("commentary", "Shared commentary"),
                 ("commentary", "Second commentary"), ("final_answer", "Selected answer")))]
    stream = f.encode_sse([
        *({"type": "response.output_item.done", "output_index": index, "item": item}
          for index, item in enumerate(items)),
        {"type": "response.completed", "response": {"id": "synthetic-certificates", "model": "gpt-6-luna",
         "status": "completed", "output": items}}])
    failures = []
    for fault in ("commentary", "final", "cross-operation"):
        for route in ("page", "exact", "activity", "full"):
            with tempfile.TemporaryDirectory(prefix="rui-message-certificates-") as root:
                state = canonical_fixture_root(root)
                store = state / "store"
                endpoint = f.SuccessEndpoint([f.ResponseSpec(stream, {})] * 2)
                worker = threading.Thread(target=endpoint.serve_forever, daemon=True)
                process = None
                try:
                    worker.start()
                    process = f.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
                    session = f.configure(state, store, "configure", None, "gpt-6-luna")
                    for key in ("first", "second"):
                        f.message(state, store, key, session, "Synthetic certificate input")
                        f.wait_for(lambda: (value := f.observe(store, key)).get("result") and value, key + " completion")
                        assert f.read_result(store, key) == b"Selected answer"
                    f.wait_for_execution_release(lambda remaining: f.command("session", "inspect", "--store", store,
                        "--session", session, timeout=remaining)["execution"], time.monotonic() + 10)
                    f.stop_host(process)
                    process = None
                    # No concurrent SQLite owner, FK bypass or live Store writes.
                    with sqlite3.connect(store / "rui.sqlite3") as database:
                        rows = database.execute("SELECT session_position,source_operation_id,source_item_ordinal,turn_id,content_id "
                            "FROM conversation_entry WHERE entry_kind=3 ORDER BY session_position").fetchall()
                        assert len(rows) == 6 and rows[0][4] == rows[3][4], rows
                        target = rows[2] if fault == "final" else rows[0]
                        if fault == "cross-operation":
                            database.execute("UPDATE conversation_entry SET source_operation_id=?,turn_id=? WHERE session_position=?",
                                (rows[3][1], rows[3][3], target[0]))
                        else:
                            database.execute("DELETE FROM conversation_entry WHERE session_position=?", (target[0],))
                        assert database.execute("PRAGMA foreign_key_check").fetchall() == []
                        assert database.execute("PRAGMA integrity_check").fetchone() == ("ok",)
                    process = f.start_host(store, None)
                    HostDiagnostics(process)
                    # A damaged Conversation projection does not replace the
                    # original admitted Request result, even after reopen.
                    assert f.read_result(store, "first") == b"Selected answer"
                    paths = {
                        "page": ("conversation-page", "conversation_page", dict(end="0", before_position="0", before_ordinal="0")),
                        "exact": ("conversation-content", "conversation_content", dict(position=str(target[0]), ordinal="0", start="0")),
                        "activity": ("activity-page", "activity_page", dict(end=None, position="0", ordinal=None, direction="forward", kinds=ACTIVITY_KINDS, limit="16")),
                        "full": ("inspect-session", "inspect_session", dict(profile="full")),
                    }
                    path, kind, fields = paths[route]
                    head, body = request(process.rui_ready_fields["socket"], store, "/v1/" + path, kind, session, **fields)
                    fenced = head.startswith(b"HTTP/1.1 500 ") and json.loads(body).get("code") == "canonical_store_failure"
                    print(f"message certificate {fault}/{route}: {head.splitlines()[0].decode()}", flush=True)
                    if not fenced:
                        failures.append((fault, route, head, body))
                    else:
                        assert process.wait(timeout=5) == 1, "canonical corruption did not shut down Host"
                except BaseException:
                    if process is not None:
                        print(f"message certificate {fault}/{route}: Host exit={process.poll()} "
                              f"diagnostics={process.rui_diagnostics.tail()!r}", flush=True)
                    raise
                finally:
                    dispose_page(process, endpoint, worker, 5)
    assert not failures, failures


if __name__ == "__main__":
    host_process.enter()
    main()
    projected_ranges()
    missing_assistant_entries()
    for size in (0, 1, 4095, 4096, 8192, 8193, 131073):
        whole_stream_shape(size)
