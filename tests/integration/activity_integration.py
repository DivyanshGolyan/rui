#!/usr/bin/env python3
"""Seven-kind Session activity through real writers and the typed native Client."""
import copy
import http.server
import json
import os
import pathlib
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading

from control_integration import command, configure, inspect_execution, message, observe, start_host, stop_session, successful_sse, wait_for
from conversation_page_integration import host_resources, idle_resources, request
from dispatch_integration import sse_tool_calls
from host_process import TestHTTPServer, canonical_fixture_root, stop_process
from proposal_integration import digest

CALLER = pathlib.Path(sys.argv[2]).resolve()
SESSION = "direct/activity"
TEXT = "é中🙂\n\\\"/" * 12000
CALLS = [("bash", "exact-call", '{"cmd":"exit 0","timeout_ms":null}')]
CALLS += [("unknown", f"rejected-{i}", TEXT if i == 1 else "{}") for i in range(1, 18)]


def caller(store, mode, *args, session=SESSION, ok=True):
    argv = [str(CALLER), mode, str(store), session, *map(str, args)]
    measured = os.environ.get("RUI_ACTIVITY_MEASURE") == "1" and ok
    if measured: argv = ["/usr/bin/time", "-f", "native maxrss_kib=%M", *argv]
    result = subprocess.run(argv, capture_output=True, timeout=10)
    assert (result.returncode == 0) == ok, (mode, result.returncode, result.stderr)
    if measured: print(mode, len(result.stdout), result.stderr.decode().strip())
    return result.stdout


def page(store, end="null", position=0, ordinal="null", direction="forward"):
    return json.loads(caller(store, "page", end, position, ordinal, direction))


def history(store, end="null", position=0, direction="forward"):
    reply = page(store, end, position, direction=direction)
    rows = []
    captured = reply["page"]["end"]
    while True:
        assert reply["page"]["end"] == captured
        rows += reply["page"]["items"]
        if reply["next"] is None: return captured, rows
        c = reply["next"]
        reply = page(store, c["end"], c["position"], c["ordinal"], c["direction"])


def kind(row):
    return next(iter(row["value"]))


def mock_reply(path, store, mode, body, advertised=None, ok=False):
    path = pathlib.Path(path)
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path))
        listener.listen(1)
        def serve():
            with listener.accept()[0] as peer:
                data = b""
                while b"\r\n\r\n" not in data: data += peer.recv(4096)
                head, received = data.split(b"\r\n\r\n", 1)
                length = int(next(line.split(b": ")[1] for line in head.split(b"\r\n") if line.startswith(b"Content-Length:")))
                while len(received) < length: received += peer.recv(4096)
                size = len(body) if advertised is None else advertised
                headers = b"" if mode == "page" else f"X-Rui-Content-Bytes: {size}\r\nX-Rui-Next-Offset: {size}\r\n".encode()
                content_type = b"application/json" if mode == "page" else b"application/octet-stream"
                peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: " + content_type + f"\r\nContent-Length: {size}\r\n".encode() +
                    headers + b"X-Rui-Wire-Version: 1\r\nConnection: close\r\n\r\n" + body)
        worker = threading.Thread(target=serve)
        worker.start()
        args = ("null", 0, "null", "forward") if mode == "page" else (1, 0)
        result = caller(store, mode, *args, ok=ok)
        worker.join(timeout=5)
        assert not worker.is_alive()
    path.unlink()
    return result


def main():
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            self.server.calls = getattr(self.server, "calls", 0) + 1
            body = successful_sse(1, TEXT) if self.server.calls == 2 else sse_tool_calls("activity", CALLS)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
        def log_message(self, *_args): pass

    with tempfile.TemporaryDirectory(prefix="rui-activity-") as root:
        state = canonical_fixture_root(root)
        store = state / "store"
        store.mkdir(mode=0o700)
        endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=endpoint.serve_forever)
        worker.start()
        process = None
        provider = f"http://127.0.0.1:{endpoint.server_port}/responses"
        try:
            process, fields = start_host(store, provider)
            command("configure", "--store", store, "--record", state / "config", "--key", "config", "--session", SESSION,
                "--workspace", pathlib.Path.cwd(), "--provider", "codex", "--model", "model-a", "--tools", "bash", "--permission-mode", "ask")
            configure(state, store, "foreign-config", "direct/foreign")
            empty_end, empty = history(store)
            assert empty == []
            baseline = host_resources(process.pid)
            if baseline is not None:
                with socket.socket(socket.AF_UNIX) as held:
                    held.connect(fields["socket"])
                    wait_for(lambda: idle_resources(process.pid, fields["socket"]) is None, "held peer excluded from idle census")
                baseline = wait_for(lambda: idle_resources(process.pid, fields["socket"]), "idle reader baseline")
            message(state, store, "first", SESSION, TEXT)
            pending_end, pending = wait_for(lambda: (h := history(store)) and (h if len([r for r in h[1] if kind(r) == "call"]) == 18 else None), "complete pending proposals")
            assert [kind(r) for r in pending[:2]] == ["admission", "user"]
            assert not any(kind(r) == "tool_result" for r in pending), "partial group became visible"
            calls = [r for r in pending if kind(r) == "call"]
            assert calls[0]["value"]["call"]["action"] is not None
            assert all(r["value"]["call"]["rejection"] == "unknown_tool" for r in calls[1:])
            assert history(store, calls[1]["position"])[1][-1] == calls[1], "interior end changed immutable rejection classification"
            for i, row in enumerate(calls):
                for field, reference, expected in zip(("item_id", "name", "call_id", "arguments"), row["value"]["call"]["fields"], (f"activity-item-{i}", *CALLS[i])):
                    data = expected.encode()
                    assert reference == {"bytes": str(len(data)), "sha256": digest(data).hex()}
                    assert caller(store, "field", row["position"], field) == data
            caller(store, "content", calls[0]["position"], 0, ok=False)
            caller(store, "content", pending[0]["position"], 0, session="direct/foreign", ok=False)
            for row in pending[:2]: assert caller(store, "content", row["position"], 0) == TEXT.encode()
            message(state, store, "second", SESSION, TEXT)
            queued_end, queued = history(store)
            assert queued[-1]["value"]["admission"]["state"] == "queued" and queued[-1]["value"]["admission"]["turn"] is None
            action = calls[0]["value"]["call"]["action"]
            exact = subprocess.run([str(sys.argv[1]), "read-action-arguments", "--store", str(store), "--session", SESSION, "--action", action], capture_output=True, timeout=10)
            assert exact.returncode == 0 and exact.stdout == CALLS[0][2].encode()
            command("deny-action", "--store", store, "--record", state / "deny", "--key", "deny", "--session", SESSION, "--action", action)
            wait_for(lambda: observe(store, "first").get("result", {}).get("status") == "completed", "complete Turn")
            complete_end, complete = history(store)
            assert history(store, pending_end)[1] == pending and history(store, queued_end)[1] == queued
            results = [r for r in complete if kind(r) == "tool_result"]
            assert len(results) == 18 and len({r["position"] for r in results}) == 1
            assert [int(r["ordinal"]) for r in results] == list(range(1, 19))
            assert caller(store, "content", results[0]["position"], results[0]["ordinal"]) == b"Permission denied."
            assert history(store, complete_end, direction="backward")[1] == list(reversed(complete))
            assert history(store, position=queued_end)[1] == [r for r in complete if int(r["position"]) > int(queued_end)], "catch-up replayed old group ties"
            for row in complete:
                if kind(row) in ("assistant", "outcome"):
                    assert caller(store, "content", row["position"], row["ordinal"]) == TEXT.encode()
            message(state, store, "third", SESSION, "stopped work")
            third = wait_for(lambda: (h := history(store)) and (h if len([r for r in h[1] if kind(r) == "call"]) == 36 else None), "later proposals")
            message(state, store, "excluded", SESSION, "equal queued input")
            stop_session(state, store, "stop", SESSION)
            stopped_end, stopped = wait_for(lambda: (h := history(store)) and (h if any(kind(r) == "outcome" and r["value"]["outcome"]["code"] == "cancelled" for r in h[1]) else None), "stopped outcome")
            assert history(store, third[0])[1] == third[1]
            assert {kind(r) for r in stopped} == {"admission", "user", "assistant", "call", "tool_result", "outcome", "stop"}
            excluded = next(r["value"]["admission"] for r in stopped if kind(r) == "admission" and r["value"]["admission"]["key"] == "excluded")
            assert excluded["state"] == "excluded" and excluded["turn"] is None
            assert all(r["value"]["stop"]["completion"] == "completed" for r in stopped if kind(r) == "stop")
            stop_row = next(r for r in stopped if kind(r) == "stop")
            assert history(store, stop_row["position"])[1][-1]["value"]["stop"]["completion"] == "pending"
            assert history(store, empty_end)[1] == [] and history(store, complete_end)[1] == complete
            for args in ((stopped_end, 2**63, "null"), (str(int(stopped_end)+1), 0, "null"), (stopped_end, calls[0]["position"], 1)):
                caller(store, "page", *args, "forward", ok=False)
            before_reads = host_resources(process.pid)
            for _ in range(4): assert caller(store, "content", pending[0]["position"], 0) == TEXT.encode()
            assert history(store, stopped_end)[1] == stopped, "invalid cursors damaged healthy Store"
            wait_for(lambda: inspect_execution(store, SESSION)["custody_occupied"] == "0", "reader/effect release")
            if baseline is not None:
                wait_for(lambda: host_resources(process.pid)[1] == baseline[1], "reader FD restoration")
            print("activity repeated-reader idle Linux RSS/FDs:", before_reads, host_resources(process.pid))
            print("activity retained-idle Linux RSS/FDs:", baseline, host_resources(process.pid))
            stop_process(process)
            process = None
            saved = sqlite3.connect(":memory:")
            with sqlite3.connect(store / "rui.sqlite3") as db: db.backup(saved)
            process, fields = start_host(store, provider)
            assert history(store, stopped_end)[1] == stopped, "restart changed fixed activity"
            stop_process(process)
            process = None
            for corrupt, position, ordinal in (("UPDATE message_admission SET admission_position=NULL WHERE command_key='first'", pending[0]["position"], 0),
                    ("UPDATE core_command SET target='direct/foreign' WHERE command_key='first'", pending[0]["position"], 0),
                    ("DELETE FROM conversation_entry WHERE source_admission_id=(SELECT admission_id FROM message_admission WHERE command_key='first')", pending[0]["position"], 0),
                    ("UPDATE turn SET outcome_position=NULL WHERE outcome_code IS NOT NULL", pending[0]["position"], 0),
                    ("UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE operation_id=(SELECT min(operation_id) FROM model_tool_call)", results[0]["position"], results[0]["ordinal"])):
                for mode in ("page", "content"):
                    with sqlite3.connect(store / "rui.sqlite3") as db:
                        saved.backup(db)
                        db.execute(corrupt)
                    process, fields = start_host(store, provider)
                    args = ("null", int(position)-1, "null", "forward") if mode == "page" else (position, ordinal)
                    caller(store, mode, *args, ok=False)
                    assert process.wait(timeout=5) == 1, "damaged activity silently disappeared"
                    stop_process(process)
                    process = None
            # First read after each independent restore/restart is Conversation,
            # never proposal/activity traversal that could rescue validation.
            # Corrupt only the first call; target the healthy highest sibling.
            sibling = results[-1]
            for corrupt in (
                    "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE operation_id=(SELECT min(operation_id) FROM model_tool_call) AND call_ordinal=0",
                    "UPDATE model_tool_call SET item_id_content_id=(SELECT item_id_content_id FROM model_tool_call WHERE operation_id=(SELECT min(operation_id) FROM model_tool_call) AND call_ordinal=1) WHERE operation_id=(SELECT min(operation_id) FROM model_tool_call) AND call_ordinal=0",
                    "UPDATE content SET private=1 WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE parent_operation_id=(SELECT min(operation_id) FROM model_tool_call) AND call_ordinal=0)",
                    "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE parent_operation_id=(SELECT min(operation_id) FROM model_tool_call) AND call_ordinal=0)"):
                for mode in ("page", "cursor", "content"):
                    with sqlite3.connect(store / "rui.sqlite3") as db:
                        saved.backup(db)
                        assert db.execute(corrupt).rowcount == 1
                    process, fields = start_host(store, provider)
                    if mode == "content":
                        route, wire_kind = "/v1/conversation-content", "conversation_content"
                        identity = {"position": sibling["position"], "ordinal": sibling["ordinal"], "start": "0"}
                    else:
                        route, wire_kind = "/v1/conversation-page", "conversation_page"
                        identity = {"end": sibling["position"], "before_position": "0", "before_ordinal": "0"}
                        if mode == "cursor":
                            identity.update(before_position=sibling["position"], before_ordinal=sibling["ordinal"])
                    head, body = request(fields["socket"], store, route, wire_kind, SESSION, **identity)
                    assert head.startswith(b"HTTP/1.1 500 "), (corrupt, mode, head, body)
                    assert json.loads(body)["code"] == "canonical_store_failure", (corrupt, mode, body)
                    assert process.wait(timeout=5) == 1, "damaged Conversation did not shut down Host"
                    stop_process(process)
                    process = None
            saved.close()
            valid = {"version": "1", "type": "activity_page", "end": str(2**63-1), "direction": "forward", "more": False,
                "items": [{"position": str(i+1), "ordinal": "0", "value": {"admission": {"admission": str(i+1), "key": "\0"*128,
                    "turn": None, "state": "queued", "content": {"bytes": "0", "sha256": digest(b"").hex()}}}} for i in range(16)]}
            mock_reply(fields["socket"], store, "page", json.dumps(valid).encode(), ok=True)
            for turn, completion, ok in ((None, "completed", True), ("1", "pending", True), (None, "pending", False)):
                wire = copy.deepcopy(valid)
                wire["items"] = [{"position": "1", "ordinal": "0", "value": {"stop": {"key": "stop", "turn": turn, "cutoff": "0", "completion": completion}}}]
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode(), ok=ok)
            for fault in ("order", "union", "digest", "binding", "integer", "field"):
                wire = copy.deepcopy(valid)
                if fault == "order": wire["items"][1]["position"] = "1"
                if fault == "union": wire["items"][0]["value"]["stop"] = {}
                if fault == "digest": wire["items"][0]["value"]["admission"]["content"]["sha256"] = "z"*64
                if fault == "binding": wire["items"][0]["value"]["admission"]["turn"] = "1"
                if fault == "integer": wire["end"] = str(2**63)
                if fault == "field": del wire["items"][0]["value"]["admission"]["key"]
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode())
            encoded = json.dumps(valid).encode()
            mock_reply(fields["socket"], store, "page", encoded[:-1], len(encoded))
            mock_reply(fields["socket"], store, "page", encoded.replace(b'"version": "1"', b'"version":"1","version":"1"'))
            assert mock_reply(fields["socket"], store, "content", b"abc", 9) == b"abc"
            print("activity typed native: seven kinds/complete content/proposals/fixed-end/reverse/ties/catch-up/restart/provenance/malformed/truncation passed")
        finally:
            if process is not None: stop_process(process)
            endpoint.shutdown()
            endpoint.server_close()
            worker.join(timeout=5)
            assert not worker.is_alive()


if __name__ == "__main__": main()
