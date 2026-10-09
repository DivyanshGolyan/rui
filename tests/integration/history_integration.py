#!/usr/bin/env python3
"""Independent native History owner: whole-page preparation and retry faults.

Run serially: history_integration.py RUI HISTORY_CLIENT. No CLI opening imports.
"""
import copy
import hashlib
import http.server
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

RUI, CALLER = map(lambda p: str(pathlib.Path(p).resolve()), sys.argv[1:3])
SESSION = "history/exact"


def digest(data):
    domain = b"rui/content/v1"
    return hashlib.sha256(len(domain).to_bytes(8, "big") + domain + data).hexdigest()


def socket_path(store):
    return pathlib.Path(f"/tmp/rui-{os.geteuid()}/{hashlib.sha256(str(store.resolve()).encode()).hexdigest()[:32]}.sock")


def invoke(store, cursor=(0, 0, 0)):
    return subprocess.run([CALLER, "history", str(store), SESSION, *map(str, cursor), str(store.parent / "history-scratch")], capture_output=True, timeout=15)


def row(position, data, kind="user", ordinal=0):
    return {"position": str(position), "ordinal": str(ordinal), "kind": kind,
            "content": {"bytes": str(len(data)), "sha256": digest(data), "display": "omitted"}}


def page(rows, end=40, more=False):
    result = {"version": "1", "type": "conversation_page", "direction": "newest_first", "end": str(end), "items": rows, "more": more}
    if more:
        result.update(before_position=rows[-1]["position"], before_ordinal=rows[-1]["ordinal"])
    return result


def wire(body, content=False, total=None, next_offset=None, advertised=None):
    length = len(body) if advertised is None else advertised
    head = f"HTTP/1.1 200 OK\r\nContent-Type: {'application/octet-stream' if content else 'application/json'}\r\nContent-Length: {length}\r\nX-Rui-Wire-Version: 1\r\nConnection: close\r\n"
    if content:
        head += f"X-Rui-Content-Bytes: {length if total is None else total}\r\nX-Rui-Next-Offset: {length if next_offset is None else next_offset}\r\n"
    return head.encode() + b"\r\n" + body


def exchange(peer):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = peer.recv(4096)
        assert chunk
        data += chunk
    head, body = data.split(b"\r\n\r\n", 1)
    length = int(next(line.split(b": ")[1] for line in head.split(b"\r\n") if line.startswith(b"Content-Length:")))
    while len(body) < length:
        body += peer.recv(4096)
    return json.loads(body)


def mock(store, metadata, responses, cursor=(40, 0, 0), failure=None, staged_bytes=None):
    path = socket_path(store)
    path.parent.mkdir(mode=0o700, exist_ok=True)
    path.unlink(missing_ok=True)
    errors = []
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path))
        listener.listen(1)
        listener.settimeout(15)
        def serve():
            try:
                with listener.accept()[0] as peer:
                    request = exchange(peer)
                    assert request["kind"] == "conversation_page"
                    assert [request[k] for k in ("end", "before_position", "before_ordinal")] == list(map(str, cursor))
                    peer.sendall(wire(json.dumps(metadata).encode()))
                for index, (identity, response) in enumerate(responses):
                    with listener.accept()[0] as peer:
                        request = exchange(peer)
                        assert request["kind"] == "conversation_content"
                        assert (int(request["position"]), int(request["ordinal"])) == identity
                        assert request["stream"] is True and request["start"] == "0"
                        if index == 1 and staged_bytes is not None:
                            # The second request proves the first staging write
                            # completed. Fault scratch before prepare returns;
                            # leave both complete network bodies unchanged.
                            scratch = store.parent / "history-scratch"
                            original = scratch.read_bytes()
                            assert len(original) == int(metadata["items"][0]["content"]["bytes"])
                            assert digest(original) == metadata["items"][0]["content"]["sha256"]
                            scratch.write_bytes(staged_bytes)
                        peer.sendall(response)
            except BaseException as err:
                errors.append(err)
        worker = threading.Thread(target=serve)
        worker.start()
        result = invoke(store, cursor)
        worker.join(20)
        assert not worker.is_alive() and not errors, errors
    path.unlink()
    if failure:
        assert result.returncode != 0 and result.stdout == b"", (failure, result)
        assert f"prepare failed at {'/'.join(map(str, cursor))}: {failure}".encode() in result.stderr, result.stderr
        assert b"next " not in result.stderr, result.stderr
    else:
        assert result.returncode == 0, result.stderr
    return result


def negatives(store):
    older, newer = b"older verified", b"newer\x1b\xe2\x80\xae"
    metadata = page([row(30, newer, "assistant"), row(20, older)])
    good = [((30, 0), wire(newer, True)), ((20, 0), wire(older, True))]
    result = mock(store, metadata, good)
    assert result.stdout.index(older) < result.stdout.index(b"newer\\x1b\\u202e")
    assert b"Conversation position 20, ordinal 0" in result.stdout
    # Hash all completed staged ranges, not just received bytes or the last
    # fetched item. The first item spans the verification window boundary.
    staged = b"newer staged " + b"q" * 4096
    staged_page = page([row(30, staged), row(20, older)])
    staged_wire = [((30, 0), wire(staged, True)), ((20, 0), wire(older, True))]
    expected = mock(store, staged_page, staged_wire).stdout
    assert staged in expected and expected.index(older) < expected.index(staged)
    for altered in (b"!" + staged[1:], staged[:-1] + b"!"):
        mock(store, staged_page, staged_wire, staged_bytes=altered, failure="ContentBindingMismatch")
    # An empty second body cannot extend a truncated first range with a hole.
    mock(store, page([row(30, staged), row(20, b"")]),
         [staged_wire[0], ((20, 0), wire(b"", True))],
         staged_bytes=b"", failure="TruncatedHistoryScratch")
    assert mock(store, staged_page, staged_wire).stdout == expected  # unchanged-cursor retry
    # Second-item failure proves no first-item display escapes preparation.
    mock(store, metadata, [good[0], ((20, 0), wire(b"X" * len(older), True))], failure="ContentBindingMismatch")
    assert (store.parent / "history-scratch").read_bytes() == newer
    assert mock(store, metadata, good).stdout == result.stdout  # retry same cursor
    for headers in ({"total": len(older) + 1}, {"next_offset": len(older) - 1}, {"advertised": len(older) + 1}):
        mock(store, metadata, [good[0], ((20, 0), wire(older, True, **headers))], failure="ContentBindingMismatch")
        assert (store.parent / "history-scratch").read_bytes() == newer  # no mismatched frame reaches sink
    mock(store, metadata, [good[0], ((20, 0), wire(older[:-1], True, advertised=len(older)))], failure="TruncatedResponse")
    mock(store, metadata, [good[0], ((20, 0), wire(older + b"!", True, advertised=len(older)))], failure="InvalidResponse")
    empty = page([row(30, b"")])
    assert mock(store, empty, [((30, 0), wire(b"", True))]).returncode == 0
    empty["items"][0]["content"]["sha256"] = digest(b"not empty")
    mock(store, empty, [((30, 0), wire(b"", True))], failure="ContentBindingMismatch")
    # A late failure after more than one transport window still displays none.
    large = b"q" * 8192
    mock(store, page([row(30, large)]), [((30, 0), wire(large[:-1] + b"X", True))], failure="ContentBindingMismatch")
    assert (store.parent / "history-scratch").read_bytes() == large[:4096]  # final whole window withheld
    rendered = mock(store, page([row(30, large)]), [((30, 0), wire(large, True))])
    assert large in rendered.stdout
    omitted = mock(store, page([row(30, b"q" * 8193)]), [])
    assert b"omitted: 8193 raw bytes; Conversation position 30, ordinal 0" in omitted.stdout
    assert (f"rui export-conversation --store $'{store.resolve()}' --session $'history/exact'"
            " --position 30 --ordinal 0 > NEW_FILE").encode() in omitted.stdout
    for change in ("fixed_end", "order", "ordinal", "digest", "direction", "kind"):
        bad = copy.deepcopy(metadata)
        if change == "fixed_end": bad["end"] = "41"
        elif change == "order": bad["items"].reverse()
        elif change == "ordinal": bad["items"][0]["ordinal"] = "1"
        elif change == "digest": bad["items"][0]["content"]["sha256"] = "zz" * 32
        elif change == "direction": bad["direction"] = "forward"
        elif change == "kind": bad["items"][0]["kind"] = "admission"
        mock(store, bad, [], failure="InvalidConversationPage")
    full = page([row(40, b"", "tool_result", 16 - i) for i in range(16)], more=True)
    result = mock(store, full, [((40, 16 - i), wire(b"", True)) for i in range(16)])
    assert b"next 40/40/1" in result.stderr
    full["before_ordinal"] = "2"
    mock(store, full, [], failure="InvalidConversationPage")
    print("History native fault witnesses: metadata, framing, wire/staged hash, scratch truncation, empty, tail, late failure, 8192/8193, retry, continuation")


def real_host(state, store):
    class Provider(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            item = {"type": "message", "id": "m", "status": "completed", "role": "assistant", "phase": "final_answer", "content": [{"type": "output_text", "text": "history answer", "annotations": []}]}
            events = [{"type": "response.output_item.added", "output_index": 0, "item": {"type": "message", "id": "m"}}, {"type": "response.output_item.done", "output_index": 0, "item": item}, {"type": "response.completed", "response": {"id": "r", "status": "completed", "model": "model-a", "output": [item], "usage": {"input_tokens": 7, "output_tokens": 11, "total_tokens": 18}}}]
            body = b"".join(b"event: response\ndata: " + json.dumps(e).encode() + b"\n\n" for e in events)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_): pass
    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever)
    thread.start()
    host = subprocess.Popen([RUI, "serve", "--store", str(store), "--active-capacity", "2", "--provider-endpoint", f"http://127.0.0.1:{provider.server_port}/responses"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def command(*args):
        result = subprocess.run([RUI, *map(str, args)], capture_output=True, timeout=15)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    try:
        deadline = time.monotonic() + 15
        while not socket_path(store).exists():
            assert host.poll() is None and time.monotonic() < deadline
            time.sleep(.01)
        command("configure", "--store", store, "--record", state / "configure.json", "--key", "configure", "--session", SESSION, "--workspace", state, "--provider", "codex", "--model", "model-a")
        text = state / "input"
        text.write_text("history input")
        command("message", "--store", store, "--record", state / "message.json", "--key", "message", "--session", SESSION, "--text", text)
        deadline = time.monotonic() + 15
        while True:
            facts = command("observe-command", "--store", store, "--key", "message")
            if facts.get("observation", {}).get("result", {}).get("status") == "completed": break
            assert time.monotonic() < deadline, facts
            time.sleep(.01)
        result = invoke(store)
        assert result.returncode == 0, result.stderr
        assert result.stdout.index(b"history input") < result.stdout.index(b"history answer")
        assert b"You (Conversation position" in result.stdout and b"Assistant (Conversation position" in result.stdout
        assert b"next none" in result.stderr
        print("History real Host: typed Conversation prepare/render, chronological user/assistant identities")
    finally:
        host.terminate()
        try: host.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            host.kill()
            host.communicate()
        provider.shutdown()
        provider.server_close()
        thread.join()


def main():
    print(subprocess.check_output([CALLER, "layout"], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="rui-history-") as directory:
        state = pathlib.Path(directory).resolve()
        store = state / "store"
        store.mkdir(mode=0o700)
        real_host(state, store)
        negatives(store)


if __name__ == "__main__": main()
