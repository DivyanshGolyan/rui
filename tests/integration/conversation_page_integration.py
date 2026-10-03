#!/usr/bin/env python3
"""Public Conversation wire reads against a real Host and canonical Store."""

import fcntl
import hashlib
import json
import os
import pathlib
import pty
import select
import shutil
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time

from control_integration import (
    RUI,
    StreamingEndpoint,
    configure,
    inspect_execution,
    message,
    read_http_response,
    start_host,
    stop_session,
    wait_for,
)
from dispatch_integration import SuccessEndpoint, encode_sse, sse_answer, sse_tool_calls, completed_observation
from host_process import start_ready_process, stop_process


def request(socket_path, store, route, kind, session, **fields):
    body = json.dumps(
        {"version": "1", "kind": kind, "store": str(store), "session": session, **fields},
        separators=(",", ":"),
    ).encode()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(socket_path)
        connection.sendall(f"POST {route} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
        response = read_http_response(connection)
        # Content-Length completion precedes handler cleanup. EOF observes the
        # production connection close, after its ContentReader has released.
        assert connection.recv(1) == b"", "unexpected trailing response bytes"
        return response


def host_resources(pid):
    if not pathlib.Path(f"/proc/{pid}/status").exists():
        return None  # Linux process diagnostics; not a macOS footprint verdict.
    status = pathlib.Path(f"/proc/{pid}/status").read_text()
    rss = int(next(line.split()[1] for line in status.splitlines() if line.startswith("VmRSS:"))) * 1024
    return rss, len(os.listdir(f"/proc/{pid}/fd"))


def prefix_rejection_pages():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-conversation-prefix-")).resolve()
    store = state / "store"
    store.mkdir(mode=0o700)
    session = "direct/prefix"
    prefix = "first, the answer"
    user_text = "ask for unavailable tools"
    message_item = sse_answer("prefix", "prefix-reason", "prefix-message", prefix)[2]
    calls = [{"type": "function_call", "id": f"prefix-item-{number}", "status": "completed",
              "name": f"missing-{number:02d}", "call_id": f"prefix-call-{number}", "arguments": "{}"}
             for number in range(1, 18)]
    items = [message_item, *calls]
    events = []
    for index, item in enumerate(items):
        events.extend((
            {"type": "response.output_item.added", "output_index": index,
             "item": {"type": item["type"], "id": item["id"]}},
            {"type": "response.output_item.done", "output_index": index, "item": item},
        ))
    events.append({"type": "response.completed", "response": {
        "id": "prefix", "status": "completed", "model": "model-a-served", "output": items}})
    successor_release = threading.Event()
    endpoint = SuccessEndpoint([encode_sse(events), (sse_answer("successor", "next-reason", "next-message", "later")[0], successor_release)])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    process = None
    try:
        process, fields = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        socket_path = fields["socket"]
        configure(state, store, "prefix-config", session)
        message(state, store, "prefix-input", session, user_text)

        def page(end, before_position, before_ordinal):
            head, body = request(socket_path, store, "/v1/conversation-page", "conversation_page", session,
                end=end, before_position=before_position, before_ordinal=before_ordinal)
            assert head.startswith(b"HTTP/1.1 200 "), (head, body)
            return json.loads(body)

        wait_for(lambda: len(page("0", "0", "0")["items"]) == 16, "settled rejected calls", timeout=15)
        newest = page("0", "0", "0")
        assert newest["version"] == "1" and newest["type"] == "conversation_page"
        assert newest["direction"] == "newest_first" and newest["more"] is True, newest
        assert [(item["kind"], item["ordinal"]) for item in newest["items"]] == [
            ("tool_result", str(number)) for number in range(17, 1, -1)], newest
        assert newest["before_position"] == newest["items"][-1]["position"]
        assert newest["before_ordinal"] == "2", newest
        older = page(newest["end"], newest["before_position"], newest["before_ordinal"])
        assert older["end"] == newest["end"] and older["more"] is False, older
        assert "before_position" not in older and "before_ordinal" not in older, older
        assert [(item["kind"], item["ordinal"]) for item in older["items"]] == [
            ("tool_result", "1"), ("assistant", "0"), ("user", "0")], older
        assert len({item["position"] for item in [*newest["items"], older["items"][0]]}) == 1
        assert int(older["items"][0]["position"]) > int(older["items"][1]["position"]) > int(older["items"][2]["position"])

        expected = [f"Unknown tool: missing-{number:02d}.".encode() for number in range(17, 0, -1)]
        expected += [prefix.encode(), user_text.encode()]
        domain = b"rui/content/v1"
        assert len(newest["items"]) + len(older["items"]) == len(expected)
        for item, content in zip([*newest["items"], *older["items"]], expected):
            assert item["content"] == {
                "bytes": str(len(content)), "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + content).hexdigest(),
                "display": "omitted",
            }, item
            head, data = request(socket_path, store, "/v1/conversation-content", "conversation_content", session,
                position=item["position"], ordinal=item["ordinal"], start="0")
            assert head.startswith(b"HTTP/1.1 200 ") and data == content, (item, head, data)
    finally:
        successor_release.set()
        if process is not None:
            stop_process(process)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=3)
        shutil.rmtree(state)


def saved_call_content():
    """Real settlement, proposal-only reads, byte ranges and reader release."""
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-call-content-")).resolve()
    store = state / "store"
    store.mkdir(mode=0o700)
    session = "direct/content"
    arguments = json.dumps({"cmd": "true # " + "x" * 4080 + "😀" + "y" * 32768,
        "timeout_ms": None}, ensure_ascii=False, separators=(",", ":"))
    rejected_name = "n" * 4095 + "😀" + "z" * 32768
    rejected_arguments = "a" * 4094 + "中" + "b" * 32768
    calls = [("bash", "accepted", arguments), (rejected_name, "rejected", rejected_arguments)]
    reasoning = sse_answer("content-private", "private-item", "unused", "unused")[1]
    events = [json.loads(line[6:]) for line in sse_tool_calls("content-calls", calls).splitlines()
        if line.startswith(b"data: {")]
    for event in events:
        if "output_index" in event:
            event["output_index"] += 1
    events[-1]["response"]["output"].insert(0, reasoning)
    events = [{"type": "response.output_item.added", "output_index": 0,
        "item": {"type": "reasoning", "id": reasoning["id"]}},
        {"type": "response.output_item.done", "output_index": 0, "item": reasoning}, *events]
    endpoint = SuccessEndpoint([encode_sse(events)])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    process = None
    try:
        process, fields = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        socket_path = fields["socket"]
        configure(state, store, "content-config", session)
        configure(state, store, "content-foreign", "direct/foreign")
        subprocess.run([str(RUI), "configure", "--store", str(store), "--session", session,
            "--record", str(state / "content-ask.json"), "--key", "content-ask", "--permission-mode", "ask"],
            check=True, capture_output=True, timeout=10)
        message(state, store, "content-message", session, "propose")
        wait_for(lambda: json.loads(request(socket_path, store, "/v1/session-calls", "session_calls", session,
            after_position="0")[1])["call"] is not None, "proposal settlement")
        shapes = ((1, 128), (1, 65536), (64, 128), (64, 65536))
        for population, length in shapes:
            growth = f"direct/growth-{population}-{length}"
            configure(state, store, growth + "-config", growth)
            values = [(f"missing-{n}", f"grow-{n}", "q" * length) for n in range(population)]
            endpoint.responses.extend([sse_tool_calls(growth, values), sse_answer(growth + "-answer", "reason", "message", "grown")[0]])
            key = f"grow-{population}-{length}"
            message(state, store, key, growth, "x" * length)
            wait_for(lambda: completed_observation(store, key), "growth original-key result", timeout=30)

        # Canonical settlement and CLI acknowledgement precede their owners'
        # cleanup. Reap the generating Host, then isolate complete read churn
        # on the same saved Store without provider or earlier client owners.
        stop_process(process)
        process = None
        process, fields = start_ready_process(
            [RUI, "serve", "--store", store, "--active-capacity", "1"],
            required_fields={"execution": "unavailable"},
        )
        socket_path = fields["socket"]
        head, body = request(socket_path, store, "/v1/session-calls", "session_calls", session, after_position="0")
        assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["call"] is not None, (head, body)
        baseline = host_resources(process.pid)
        snapshots = []
        cursor = "0"
        domain = b"rui/content/v1"
        for index, (name, _, args) in enumerate(calls):
            head, body = request(socket_path, store, "/v1/session-calls", "session_calls", session, after_position=cursor)
            assert head.startswith(b"HTTP/1.1 200 "), (head, body)
            page = json.loads(body)
            cursor = page["position"]
            call = page["call"]
            if index == 0:
                # This real settled response positions its private reasoning
                # item immediately before the first call; it is not public.
                head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", session,
                    position=str(int(cursor) - 1), field="arguments", start="0")
                assert head.startswith(b"HTTP/1.1 409 ") and reasoning["encrypted_content"].encode() not in data, (head, data)
            assert call["classification"] == ("ask" if index == 0 else "rejected"), call
            assert set(call) == {"turn", "operation", "ordinal", "classification", "rejection", "name", "arguments"}, call
            for field, value in (("name", name), ("arguments", args)):
                expected = value.encode()
                assert call[field] == {"type": "text", "bytes": str(len(expected)),
                    "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + expected).hexdigest()}, call[field]
                for limit in (128, 256):
                    head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", session,
                        position=cursor, field=field, start="0", length=str(limit))
                    assert head.startswith(b"HTTP/1.1 200 ") and data == expected[:limit], (head, len(data))
                    assert f"X-Rui-Next-Offset: {min(limit, len(expected))}\r\n".encode() in head, head
                chunks = []
                for start in range(0, len(expected), 4096):
                    head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", session,
                        position=cursor, field=field, start=str(start))
                    assert head.startswith(b"HTTP/1.1 200 ") and data == expected[start:start + 4096], (head, start, len(data))
                    chunks.append(data)
                assert b"".join(chunks) == expected
                head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", session,
                    position=cursor, field=field, start="0", stream=True)
                assert head.startswith(b"HTTP/1.1 200 ") and data == expected, (head, len(data))
                snapshots.append(host_resources(process.pid))
            # Foreign, input/private/non-call and invented identities never
            # resolve via arbitrary digest/ordinal or leak another Session.
            for target, position in (("direct/foreign", cursor), (session, "1"), (session, "999999")):
                head, _ = request(socket_path, store, "/v1/session-call-content", "session_call_content", target,
                    position=position, field="arguments", start="0")
                assert head.startswith(b"HTTP/1.1 409 "), head
            for extra in ({"field": "reasoning"}, {"sha256": call["arguments"]["sha256"]},
                {"ordinal": "0"}, {"position": str(2**64 - 1)}, {"length": "4097"}, {"start": "1", "stream": True}):
                identity = {"position": cursor, "field": "arguments", "start": "0", **extra}
                head, _ = request(socket_path, store, "/v1/session-call-content", "session_call_content", session, **identity)
                assert head.startswith(b"HTTP/1.1 400 "), (extra, head)
        # Repeated partial readers cannot retain FDs.
        for _ in range(20):
            head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", session,
                position=cursor, field="arguments", start="0", length="256")
            assert len(data) == 256 and head.startswith(b"HTTP/1.1 200 ")
        drained = host_resources(process.pid)
        if baseline is not None:
            assert drained[1] == baseline[1], (baseline, snapshots, drained)
        print(f"saved-call offline complete-read snapshots baseline={baseline} field_reads={snapshots} repeated_prefix={drained}; prefix transfers=128/256 bytes, window=4096 (Linux RSS/FD, not peak attribution)")
        # All resource samples precede every intentional disconnect. A fresh
        # request's EOF cannot prove another handler's socket was released.
        disconnects = []
        for population, length in shapes:
            growth = f"direct/growth-{population}-{length}"
            head, data = request(socket_path, store, "/v1/session-calls", "session_calls", growth, after_position="0")
            position = json.loads(data)["position"]
            for _ in range(4):
                head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", growth,
                    position=position, field="arguments", start="0", length="128")
                assert head.startswith(b"HTTP/1.1 200 ") and data == b"q" * 128
            snapshot = host_resources(process.pid)
            if baseline is not None:
                assert snapshot[1] == baseline[1], (population, length, baseline, snapshot)
            print(f"saved-call persisted shape population={population} field_bytes={length} complete-read Host={snapshot} (RSS bytes, FDs; reader churn, not provider growth or quiescent RSS)")
            disconnects.append((growth, position))
        for growth, position in disconnects:
            # Disconnect a real complete delivery, then exercise a fresh reader.
            body = json.dumps({"version": "1", "kind": "session_call_content", "store": str(store),
                "session": growth, "position": position, "field": "arguments", "start": "0", "stream": True}, separators=(",", ":")).encode()
            with socket.socket(socket.AF_UNIX) as connection:
                connection.connect(socket_path)
                connection.sendall(b"POST /v1/session-call-content HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                assert connection.recv(256).startswith(b"HTTP/1.1 200 ")
            head, data = request(socket_path, store, "/v1/session-call-content", "session_call_content", growth,
                position=position, field="arguments", start="0", length="128")
            assert head.startswith(b"HTTP/1.1 200 ") and data == b"q" * 128
    finally:
        if process is not None:
            stop_process(process)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=3)
        shutil.rmtree(state)


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-conversation-page-")).resolve()
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
        saved = state / "saved-content"
        result = subprocess.run([RUI, "conversation-content", "--store", store,
            "--session", "direct/page", "--position", item["position"],
            "--ordinal", "0", "--output", saved], capture_output=True, timeout=15)
        assert result.returncode == 0 and saved.read_bytes() == payload.encode(), (result.stderr, saved.stat())
        env = {**os.environ, "HOME": str(state)}
        preference = subprocess.run([RUI, "setup", "--store", store], env=env,
            capture_output=True, timeout=15)
        assert preference.returncode == 0, preference.stderr
        selected = state / "saved-default-content"
        result = subprocess.run([RUI, "conversation-content", "--session", "direct/page",
            "--position", item["position"], "--ordinal", "0", "--output", selected],
            env=env, capture_output=True, timeout=15)
        assert result.returncode == 0 and selected.read_bytes() == payload.encode(), result.stderr
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        resumed = subprocess.Popen([RUI, "--resume", "direct/page", "--store", store],
            cwd=state, env={**os.environ, "HOME": str(state)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            output = b""
            deadline = time.monotonic() + 15
            while b"\r> \r\x1b[2C" not in output:
                assert select.select([master], [], [], deadline - time.monotonic())[0], output[-2000:]
                output += os.read(master, 65536)
            assert b"You: " in output and b"[content omitted: 10005 bytes;" in output, output
            assert b"No work selected" not in output, output
        finally:
            resumed.kill()
            resumed.wait(timeout=5)
            os.close(master)
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
    prefix_rejection_pages()
    saved_call_content()
