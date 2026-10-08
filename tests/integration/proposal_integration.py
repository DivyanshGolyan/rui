#!/usr/bin/env python3
"""Historical proposals through the real Host and typed native Client."""
import copy
import hashlib
import http.server
import json
import pathlib
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading

from control_integration import RUI, command, configure, inspect_execution, message, observe, start_host, successful_sse, wait_for
from conversation_page_integration import host_resources, request
from dispatch_integration import sse_tool_calls
from host_process import TestHTTPServer, stop_process

CALLER = pathlib.Path(sys.argv[2]).resolve()
SESSION = "direct/proposals"
FIELDS = ("item_id", "name", "call_id", "arguments")
LARGE = "é中🙂\n\\\"/" * 12000
CALLS = [("bash", "exact-call", '{"cmd":"exit 0","timeout_ms":null}')]
CALLS += [("unknown" + str(i), f"call-{i}é\n", LARGE if i == 1 else "{}") for i in range(1, 18)]
CALLS[2] = ("bash", "invalid-call", "{")
CALLS[3] = ("edit", "edit-call", "{}")
CALLS[4] = ("x" * 300, "long-name", "")


def caller(store, mode, first, second, session=SESSION, ok=True):
    result = subprocess.run([str(CALLER), mode, str(store), session, str(first), str(second)],
                            capture_output=True, timeout=10)
    assert (result.returncode == 0) == ok, (mode, result.returncode, result.stderr)
    return result.stdout


def page(store, end="null", after=0):
    return json.loads(caller(store, "page", end, after))


def digest(data):
    domain = b"rui/content/v1"
    return hashlib.sha256(len(domain).to_bytes(8, "big") + domain + data).digest()


def mock_reply(socket_path, store, mode, body, advertised=None, extra_headers=b""):
    # Replace only the stopped fixture Host's endpoint, not its saved work.
    path = pathlib.Path(socket_path)
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path))
        listener.listen(1)
        def serve():
            with listener.accept()[0] as peer:
                data = b""
                while b"\r\n\r\n" not in data:
                    data += peer.recv(4096)
                head, received = data.split(b"\r\n\r\n", 1)
                length = int(next(line.split(b": ")[1] for line in head.split(b"\r\n") if line.startswith(b"Content-Length:")))
                while len(received) < length:
                    received += peer.recv(4096)
                kind = b"application/json" if mode == "page" else b"application/octet-stream"
                peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: " + kind +
                    f"\r\nContent-Length: {len(body) if advertised is None else advertised}\r\n".encode() +
                    extra_headers + b"X-Rui-Wire-Version: 1\r\nConnection: close\r\n\r\n" + body)
        worker = threading.Thread(target=serve)
        worker.start()
        result = caller(store, mode, "null" if mode == "page" else 1, 0 if mode == "page" else "arguments", ok=False)
        worker.join(timeout=5)
        assert not worker.is_alive()
    path.unlink()
    return result


def main():
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            supplied = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            is_continuation = supplied["input"][-1].get("type") == "function_call_output"
            # Each new Message produces the same complete group. Continuations
            # finish the Turn, so historical discovery is not active-only.
            body = successful_sse(1, "finished") if is_continuation else sse_tool_calls("proposal", CALLS)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
        def log_message(self, *_args):
            pass

    with tempfile.TemporaryDirectory(prefix="rui-proposals-") as root:
        state = pathlib.Path(root)
        store = state / "store"
        store.mkdir(mode=0o700)
        endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=endpoint.serve_forever)
        worker.start()
        process = None
        provider = f"http://127.0.0.1:{endpoint.server_port}/responses"
        try:
            process, fields = start_host(store, provider)
            configured = command("configure", "--store", store, "--record", state / "config.json", "--key", "config",
                "--session", SESSION, "--workspace", pathlib.Path.cwd(), "--provider", "codex", "--model", "model-a",
                "--tools", "bash,edit", "--permission-mode", "ask")
            assert configured["answer"]["status"] == "accepted", configured
            configure(state, store, "foreign-config", "direct/foreign")
            empty = page(store)
            assert empty["items"] == [] and not empty["more"]
            baseline = host_resources(process.pid)
            message(state, store, "first", SESSION, "first group")
            first = wait_for(lambda: (p if len((p := page(store))["items"]) == 16 else None), "proposal page")
            assert first["more"] and [i["call_ordinal"] for i in first["items"]] == list(range(16))
            last = page(store, first["next"]["end"], first["next"]["after"])
            assert not last["more"] and len(last["items"]) == 2
            items = first["items"] + last["items"]
            assert items[0]["action"] is not None and items[0]["rejection"] is None
            assert [i["rejection"] for i in items[1:4]] == ["unknown_tool", "invalid_arguments", "tool_unavailable"]
            assert all(i["action"] is None for i in items[1:])
            for index, item in enumerate(items):
                expected = (f"proposal-item-{index}", *CALLS[index])
                for field, reference, value in zip(FIELDS, item["fields"], expected):
                    data = value.encode()
                    assert reference == {"length": len(data), "digest": list(digest(data))}, (index, field, reference)
                    assert caller(store, "field", item["position"], field) == data, (index, field)
            # Proposal metadata conveys no decision authority. Exact Action
            # inspection is still the authority offered to a fresh decision.
            action = items[0]["action"]
            result = subprocess.run([str(RUI), "read-action-arguments", "--store", str(store), "--session", SESSION, "--action", str(action)], capture_output=True, timeout=10)
            assert result.returncode == 0 and result.stdout == CALLS[0][2].encode(), result
            denied = command("deny-action", "--store", store, "--record", state / "deny.json", "--key", "deny", "--session", SESSION, "--action", action)
            assert denied["answer"]["status"] == "accepted", denied
            wait_for(lambda: observe(store, "first").get("result", {}).get("status") == "completed", "terminal Turn")
            assert page(store, first["end"]) == first, "settlement changed historical metadata"
            wait_for(lambda: inspect_execution(store, SESSION)["custody_occupied"] == "0", "retained idle")
            for _ in range(3):
                for index in (0, 1):
                    assert caller(store, "field", items[index]["position"], "arguments") == CALLS[index][2].encode()
            idle = host_resources(process.pid)
            if baseline is not None:
                wait_for(lambda: host_resources(process.pid)[1] == baseline[1], "proposal reader descriptor recovery")
                idle = host_resources(process.pid)
            print(f"proposal retained idle after repeated small/large reads={idle} (Linux RSS bytes/FDs)")
            message(state, store, "second", SESSION, "later group")
            wait_for(lambda: page(store)["end"] > first["end"], "later accepted proposals")
            assert page(store, first["end"]) == first, "fixed end admitted later calls"
            assert page(store, empty["end"])["items"] == [], "empty fixed end reopened"
            assert page(store, first["end"], last["items"][-1]["position"])["items"] == []
            for kwargs in ({"end": None, "after": "1"}, {"end": str(first["end"]), "after": "1"},
                           {"end": str(2**64 - 1), "after": "0"}):
                head, _ = request(fields["socket"], store, "/v1/proposal-page", "proposal_page", SESSION, **kwargs)
                assert not head.startswith(b"HTTP/1.1 200 "), head
            caller(store, "field", items[1]["position"], "arguments", session="direct/foreign", ok=False)
            head, _ = request(fields["socket"], store, "/v1/proposal-field", "proposal_field", SESSION,
                              position=str(items[1]["position"]), field="provider_source")
            assert head.startswith(b"HTTP/1.1 400 "), head
            assert page(store, first["end"]) == first, "bad request fenced healthy Store"
            print(f"proposal resources baseline={baseline} large_fields={host_resources(process.pid)} (Linux RSS bytes/FDs, not aggregate qualification)")
            print(subprocess.check_output([str(CALLER), "layout"], text=True).strip())
            if sys.platform.startswith("linux") and pathlib.Path("/usr/bin/time").exists():
                for label, mode, first_arg, second_arg in (("small-field", "field", items[0]["position"], "arguments"),
                        ("large-field", "field", items[1]["position"], "arguments"), ("page", "page", first["end"], 0)):
                    rss = state / "caller-rss"
                    subprocess.run(["/usr/bin/time", "-f", "%M", "-o", str(rss), str(CALLER), mode,
                        str(store), SESSION, str(first_arg), str(second_arg)], stdout=subprocess.DEVNULL, check=True, timeout=10)
                    print(f"native Client {label} max RSS KiB={rss.read_text().strip()} (fresh process; not aggregate verdict)")
            stop_process(process)
            process = None
            process, fields = start_host(store, provider)
            assert page(store, first["end"]) == first, "restart lost history"
            stop_process(process)
            process = None
            # Snapshot only for stopped-Store corruption fixtures, never an API.
            saved = sqlite3.connect(":memory:")
            with sqlite3.connect(store / "rui.sqlite3") as db:
                db.backup(saved)
            faults = [
                "UPDATE content SET private=1,payload=zeroblob(byte_length) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1 LIMIT 1)",
                "DELETE FROM model_tool_call WHERE call_ordinal=1 AND operation_id=(SELECT min(operation_id) FROM model_tool_call)",
                "UPDATE turn SET session_ref='foreign' WHERE turn_id=(SELECT min(turn_id) FROM turn)",
                "UPDATE content SET digest=zeroblob(32) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1 LIMIT 1)",
                "UPDATE content SET payload=CAST(replace(CAST(payload AS TEXT),'\\u00e9','\\q00e9') AS BLOB) WHERE content_id IN "
                "(SELECT source_content_id FROM answer_text_projection WHERE answer_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1 LIMIT 1))",
            ]
            for index, fault in enumerate(faults):
                for mode in (("page", "cursor", "field") if index < 3 else ("field",)):
                    with sqlite3.connect(store / "rui.sqlite3") as db:
                        saved.backup(db)
                        db.execute("PRAGMA foreign_keys=OFF")
                        db.execute(fault)
                    process, fields = start_host(store, provider)
                    if mode == "field":
                        data = caller(store, "field", items[1]["position"], "arguments", ok=False)
                        assert len(data) < len(LARGE.encode()), (index, len(data))
                        if index == 3:
                            assert data == LARGE.encode()[:((len(LARGE.encode()) - 1) // 4096) * 4096]
                    else:
                        caller(store, "page", first["end"], items[1]["position"] if mode == "cursor" else 0, ok=False)
                    assert process.wait(timeout=5) == 1, "canonical corruption did not fence Host"
                    stop_process(process)
                    process = None
            with sqlite3.connect(store / "rui.sqlite3") as db:
                saved.backup(db)
            saved.close()
            # The native consumer must reject truncated bodies and malformed
            # metadata, rather than accepting a parsed prefix or partial fields.
            wire_items = []
            for item in first["items"]:
                row = {key: str(item[key]) for key in ("position", "operation", "turn", "call_ordinal")}
                row.update(action=str(item["action"]) if item["action"] else None, rejection=item["rejection"])
                row["fields"] = {name: {"bytes": str(ref["length"]), "sha256": bytes(ref["digest"]).hex()} for name, ref in zip(FIELDS, item["fields"])}
                wire_items.append(row)
            valid = dict(version="1", type="proposal_page", end=str(first["end"]), items=wire_items, more=True)
            for change in ("order", "digest", "missing", "authority", "type"):
                wire = copy.deepcopy(valid)
                if change == "order": wire["items"][1]["position"] = wire["items"][0]["position"]
                if change == "digest": wire["items"][0]["fields"]["arguments"]["sha256"] = "z" * 64
                if change == "missing": del wire["items"][0]["fields"]["call_id"]
                if change == "authority": wire["items"][1]["action"] = "1"
                if change == "type": wire["end"] = int(wire["end"])
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode())
            encoded = json.dumps(valid).encode()
            mock_reply(fields["socket"], store, "page", encoded[:-1], len(encoded))
            mock_reply(fields["socket"], store, "page", encoded.replace(b'"version": "1"', b'"version":"1","version":"1"'))
            assert mock_reply(fields["socket"], store, "field", b"abc", 9,
                b"X-Rui-Content-Bytes: 9\r\nX-Rui-Next-Offset: 9\r\n") == b"abc"
            print("proposal native caller: historical rejection/complete fields/frozen traversal/restart/authority/corruption/malformed/truncation passed")
        finally:
            if process is not None: stop_process(process)
            endpoint.shutdown()
            endpoint.server_close()
            worker.join(timeout=5)
            assert not worker.is_alive()


if __name__ == "__main__":
    main()
