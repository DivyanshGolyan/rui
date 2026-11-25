import http.server
import json
import os
import sqlite3
import tempfile
import threading

from control_fixture import configure, inspect_execution, message, observe, raw_request, start_host, successful_sse
import host_process
import os_semantics
from host_process import canonical_fixture_root, dispose_all, stop_process, TestHTTPServer, wait_for


def dispose_page(process, endpoint, thread, timeout):
    def shutdown():
        if thread.ident is not None:
            try:
                endpoint.shutdown()
            except BaseException:
                dispose_all(endpoint.shutdown)
                raise

    def join():
        if thread.ident is not None:
            thread.join(timeout=timeout)
            assert not thread.is_alive(), "Conversation endpoint thread did not retire"

    dispose_all(
        lambda: stop_process(process) if process is not None else None,
        shutdown,
        endpoint.server_close,
        join,
    )


def host_resources(pid):
    memory = os_semantics.process_memory(pid)
    if memory is None:
        return None
    return memory["rss_kib"] * 1024, len(os_semantics.descriptor_links(pid))


def provider_connections(pid, port):
    inodes = {row[9] for rows in (os_semantics.socket_table("tcp"), os_semantics.socket_table("tcp6")) if rows is not None
              for row in rows if int(row[2].rsplit(":", 1)[1], 16) == port}
    count = 0
    for fd in os_semantics.descriptor_links(pid):
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        count += target.startswith("socket:[") and target[8:-1] in inodes
    return count


def idle_resources(pid, path):
    try:
        descriptors = {fd.name: os.readlink(fd) for fd in os_semantics.descriptor_links(pid)}
        unix = os_semantics.socket_table("unix")
        if unix is None: return None
        peers = {f"socket:[{r[6]}]" for r in unix if len(r) == 8 and r[7] == path and int(r[3], 16) == 0}
        if any(target in peers for target in descriptors.values()): return None
        if descriptors != {fd.name: os.readlink(fd) for fd in os_semantics.descriptor_links(pid)}: return None
    except FileNotFoundError: return None
    return host_resources(pid)[0], len(descriptors)


def request(socket_path, store, route, kind, session, **fields):
    body = json.dumps(
        {"version": host_process.WIRE_VERSION, "kind": kind, "store": str(store), "session": session, **fields},
        separators=(",", ":"),
    ).encode()
    return raw_request(socket_path, route, body)


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

            def completed_page():
                head, body = request(fields["socket"], store, "/v1/conversation-page", "conversation_page", session,
                    end="0", before_position="0", before_ordinal="0")
                assert head.startswith(b"HTTP/1.1 200 "), (head, body)
                items = json.loads(body)["items"]
                kind = "assistant" if length else "user"
                return next((item for item in items if item["kind"] == kind), None)

            item = wait_for(completed_page, "stream public identity")
            identity = dict(position=item["position"], ordinal="0", start="0", stream=True)
            head, body = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", session, **identity)
            assert head.startswith(b"HTTP/1.1 200 ") and body == expected, (head, len(body), length)
            for name in ("Content-Length", "X-Rui-Content-Bytes", "X-Rui-Next-Offset"):
                assert f"{name}: {length}\r\n".encode() in head + b"\r\n", head
            for changes, status in (({"start": "1"}, 400), ({"ordinal": "1"}, 409), ({"position": str(2**64 - 1)}, 400)):
                head, _ = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", session, **(identity | changes))
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
            head, body = request(fields["socket"], store, "/v1/conversation-content", "conversation_content", session, **identity)
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
            dispose_page(process, endpoint, worker, 5)
