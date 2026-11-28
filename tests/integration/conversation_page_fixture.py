import http.server
import json
import sqlite3
import tempfile
import threading

from control_fixture import configure, inspect_execution, message, observe, start_host, successful_sse, raw_request
import host_process
from host_fixture import conversation_rows, dispose_endpoint, request, row_kind
from host_process import canonical_fixture_root, stop_process, TestHTTPServer, wait_for


def whole_stream_shape(length):
    unit = "\x00\n\\\"é中🙂/"
    text = "" if length == 0 else "x" + unit * ((length - 1) // len(unit.encode()))
    text += "z" * (length - len(text.encode()))
    expected = text.encode()
    assert len(expected) == length

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            body = successful_sse(1, text)
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

    with tempfile.TemporaryDirectory(prefix="rui-whole-stream-") as root:
        state = canonical_fixture_root(root)
        store = state / "store"
        store.mkdir(mode=0o700)
        endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=endpoint.serve_forever, daemon=True)
        process = None
        try:
            worker.start()
            provider = f"http://127.0.0.1:{endpoint.server_port}/responses"
            process, fields = start_host(store, provider)
            session = configure(state, store, "stream-config")
            if length == 0:
                wire = {"version": host_process.WIRE_VERSION, "kind": "message", "store": str(store),
                    "key": "stream-message", "session": session,
                    "text": {"state": "value", "value": ""}}
                head, body = raw_request(fields["socket"], "/v1/message", json.dumps(wire, separators=(",", ":")).encode())
                assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["answer"]["status"] == "accepted", (head, body)
                settled = wait_for(lambda: observe(store, "stream-message").get("result"), "empty answer settlement")
                assert settled["status"] == "completed" and settled["text"]["bytes"] == "0", settled
            else:
                message(state, store, "stream-message", session, "input")

            def completed_row():
                kind = "assistant" if length else "user"
                return next((row for row in conversation_rows(fields["socket"], store, session) if row_kind(row) == kind), None)

            item = wait_for(completed_row, "stream public identity")
            identity = dict(position=item["position"], ordinal="0")
            head, body = request(fields["socket"], store, "/v1/activity-content", "activity_content", session, **identity)
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected, (head, len(body), length)
            for name in ("Content-Length", "X-Rui-Content-Bytes", "X-Rui-Next-Offset"):
                assert f"{name}: {length}\r\n".encode() in head + b"\r\n", head
            for changes, status in (({"ordinal": "1"}, 409), ({"position": str(2**64 - 1)}, 400)):
                head, _ = request(fields["socket"], store, "/v1/activity-content", "activity_content", session, **(identity | changes))
                assert head.startswith(f"HTTP/1.1 {status} ".encode()), head
            wait_for(lambda: inspect_execution(store, session)["custody_occupied"] == "0", "stream producer cleanup")
            stop_process(process)
            process = None
            with sqlite3.connect(store / "rui.sqlite3") as database:
                if length:
                    answer, payload = database.execute(
                        "SELECT c.content_id,c.payload FROM conversation_entry e JOIN content c ON c.content_id=e.content_id WHERE e.entry_kind=3"
                    ).fetchone()
                    assert payload[:1] == b"x"
                    database.execute("UPDATE content SET payload=? WHERE content_id=?", (b"y" + payload[1:], answer))
                else:
                    answer = database.execute("SELECT content_id FROM conversation_entry WHERE entry_kind=1").fetchone()[0]
                    database.execute("UPDATE content SET digest=? WHERE content_id=?", (b"\xff" * 32, answer))
            process, fields = start_host(store, provider)
            head, body = request(fields["socket"], store, "/v1/activity-content", "activity_content", session, **identity)
            if length <= 4096:
                assert head.startswith(b"HTTP/1.1 500 "), (length, head, len(body))
                assert json.loads(body)["code"] == "canonical_store_failure", body
            else:
                assert head.startswith(b"HTTP/1.1 200 "), head
                assert f"Content-Length: {length}\r\n".encode() in head, head
                sent = ((length - 1) // 4096) * 4096
                assert body == (b"y" + expected[1:])[:sent] and len(body) < length, (length, len(body))
                assert b"HTTP/1.1" not in body and b"canonical_store_failure" not in body
            assert process.wait(timeout=5) == 1, "canonical corruption did not shut down Host"
            stop_process(process)
            process = None
            print(f"whole stream {length} bytes: exact escape-heavy framing and digest no-false-success witness passed")
        finally:
            dispose_endpoint(process, endpoint, worker, 5)
