#!/usr/bin/env python3
"""Seven-kind Session activity through real writers and the typed native Client."""
import copy
import http.server
import json
import os
import pathlib
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

from control_integration import command, configure, inspect_execution, message, observe, start_host, stop_session, successful_sse, wait_for
from conversation_page_integration import host_resources, idle_resources
from model_fixture import sse_tool_calls
from host_process import TestHTTPServer, canonical_fixture_root, retain_failure_state, stop_process
from proposal_integration import digest
from one_reply import one_reply

CALLER = pathlib.Path(sys.argv[2]).resolve()
SESSION = "direct/activity"
TEXT = "é中🙂\n\\\"/" * 12000
CALLS = [("bash", "exact-call", '{"cmd":"exit 0","timeout_ms":null,"description":"Exit with success"}')]
CALLS += [("unknown", f"rejected-{i}", TEXT if i == 1 else "{}") for i in range(1, 18)]


def caller(store, mode, *args, session=SESSION, ok=True, timeout=10):
    argv = [str(CALLER), mode, str(store), session, *map(str, args)]
    measured = os.environ.get("RUI_ACTIVITY_MEASURE") == "1" and ok
    if measured: argv = ["/usr/bin/time", "-f", "native maxrss_kib=%M", *argv]
    result = subprocess.run(argv, capture_output=True, timeout=timeout)
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
    size = len(body) if advertised is None else advertised
    headers = b"" if mode == "page" else f"X-Rui-Content-Bytes: {size}\r\nX-Rui-Next-Offset: {size}\r\n".encode()
    content_type = b"application/json" if mode == "page" else b"application/octet-stream"
    response = (b"HTTP/1.1 200 OK\r\nContent-Type: " + content_type + f"\r\nContent-Length: {size}\r\n".encode() +
        headers + b"X-Rui-Wire-Version: 1\r\nConnection: close\r\n\r\n" + body)
    with one_reply(path, response) as deadline:
        args = ("null", 0, "null", "forward") if mode == "page" else (1, 0)
        return caller(store, mode, *args, ok=ok, timeout=max(0, deadline - time.monotonic()))


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

    root = tempfile.mkdtemp(prefix="rui-activity-")
    completed = False
    try:
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
            command("session", "configure", "--store", store, "--record", state / "config", "--key", "config", "--session", SESSION,
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
            stamps = {r["value"][kind(r)]["admitted_at"] for r in pending[:2]}
            assert len(stamps) == 1 and int(next(iter(stamps))) > 0, pending[:2]
            assert not any(kind(r) == "tool_result" for r in pending), "partial group became visible"
            calls = [r for r in pending if kind(r) == "call"]
            assert calls[0]["value"]["call"]["action"] is not None
            assert all(r["value"]["call"]["rejection"] == "unknown_tool" for r in calls[1:])
            live = page(store)["page"]["call_activity"]
            assert live["total"] == "18" and [int(e["ordinal"]) for e in live["entries"]] == [0, 1, 2], live
            assert live["entries"][0]["presentation"]["code"] == "pending_permission", live
            assert live["entries"][0]["presentation"]["description"] == "Exit with success", live
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
            exact = subprocess.run([str(sys.argv[1]), "action", "read-arguments", "--store", str(store), "--session", SESSION, "--action", action], capture_output=True, timeout=10)
            assert exact.returncode == 0 and exact.stdout == CALLS[0][2].encode()
            command("action", "deny", "--store", store, "--record", state / "deny", "--key", "deny", "--session", SESSION, "--action", action)
            wait_for(lambda: observe(store, "first").get("result", {}).get("status") == "completed", "complete Turn")
            complete_end, complete = history(store)
            assert history(store, pending_end)[1] == pending and history(store, queued_end)[1] == queued
            results = [r for r in complete if kind(r) == "tool_result"]
            assert len(results) == 18 and len({r["position"] for r in results}) == 1
            assert [int(r["ordinal"]) for r in results] == list(range(1, 19))
            projected = page(store)
            assert projected["page"]["call_activity"]["total"] == "18", projected
            while True:
                facts = projected["page"]
                boundary = (int(facts["items"][-1]["position"]), int(facts["items"][-1]["ordinal"])) if facts["more"] else (int(facts["end"]), 2**63-1)
                remaining = [r for r in results if (int(r["position"]), int(r["ordinal"])) > boundary]
                live = facts["call_activity"]
                assert int(live["total"]) == len(remaining), (boundary, live)
                assert [int(e["ordinal"]) for e in live["entries"]] == [int(r["ordinal"])-1 for r in remaining[:3]], live
                if projected["next"] is None: break
                cursor = projected["next"]
                projected = page(store, cursor["end"], cursor["position"], cursor["ordinal"], cursor["direction"])
            assert page(store, direction="backward")["page"]["call_activity"]["total"] == "0"
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
            # Keep representative Host fencing for sequence and group faults;
            # admission and first-read Conversation matrices live with Store.
            for corrupt, position, ordinal in (("UPDATE turn SET outcome_position=NULL WHERE outcome_code IS NOT NULL", pending[0]["position"], 0),
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
            saved.close()
            valid = {"version": "1", "type": "activity_page", "end": str(2**63-1), "direction": "forward", "more": False,
                "call_activity": {"total": "0", "entries": []},
                "items": [{"position": str(i+1), "ordinal": "0", "value": {"admission": {"admission": str(i+1), "key": "\0"*128,
                    "turn": None, "state": "queued", "admitted_at": str(2**63-1), "sender": None, "content": {"bytes": "0", "sha256": digest(b"").hex()}}}} for i in range(16)]}
            mock_reply(fields["socket"], store, "page", json.dumps(valid).encode(), ok=True)
            for fault in ("missing", "count", "duplicate", "order", "retired", "overflow"):
                wire = copy.deepcopy(valid)
                if fault == "missing": del wire["call_activity"]
                else:
                    entry = {"operation": "1", "ordinal": "0", "presentation": {"description": "Inspect local files", "code": "unresolved", "publication_position": None}}
                    entries = [entry]
                    if fault == "count": wire["call_activity"]["total"] = "2"
                    else:
                        if fault in ("duplicate", "order", "overflow"):
                            entries += [copy.deepcopy(entry)]
                            if fault == "order": entries[0]["ordinal"] = "1"
                            if fault == "overflow": entries += [copy.deepcopy(entry), copy.deepcopy(entry)]
                        wire["call_activity"]["total"] = str(len(entries))
                        if fault == "retired": entry["presentation"].update(code="succeeded", publication_position="1")
                    wire["call_activity"]["entries"] = entries
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode())
            for turn, completion, ok in ((None, "completed", True), ("1", "pending", True), (None, "pending", False)):
                wire = copy.deepcopy(valid)
                wire["items"] = [{"position": "1", "ordinal": "0", "value": {"stop": {"key": "stop", "turn": turn, "cutoff": "0", "completion": completion}}}]
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode(), ok=ok)
            # A peer prefix exists only for a generated reference, from six characters.
            generated = "rui/1a2b3c4d-0000-4000-8000-000000000001"
            for session, prefix, ok in ((generated, "6", True), (generated, "5", False), ("rui/" + "a" * 36, "6", False), ("reviewer", "0", True), ("reviewer", "6", False)):
                wire = copy.deepcopy(valid)
                wire["items"][0]["value"]["admission"]["sender"] = {"session": session, "prefix": prefix}
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode(), ok=ok)
            for fault in ("order", "union", "digest", "binding", "integer", "field", "stamp", "sender"):
                wire = copy.deepcopy(valid)
                if fault == "order": wire["items"][1]["position"] = "1"
                if fault == "union": wire["items"][0]["value"]["stop"] = {}
                if fault == "digest": wire["items"][0]["value"]["admission"]["content"]["sha256"] = "z"*64
                if fault == "binding": wire["items"][0]["value"]["admission"]["turn"] = "1"
                if fault == "integer": wire["end"] = str(2**63)
                if fault == "field": del wire["items"][0]["value"]["admission"]["key"]
                if fault == "stamp": wire["items"][0]["value"]["admission"]["admitted_at"] = "0"
                if fault == "sender": del wire["items"][0]["value"]["admission"]["sender"]
                mock_reply(fields["socket"], store, "page", json.dumps(wire).encode())
            encoded = json.dumps(valid).encode()
            mock_reply(fields["socket"], store, "page", encoded[:-1], len(encoded))
            mock_reply(fields["socket"], store, "page", encoded.replace(b'"version": "1"', b'"version":"1","version":"1"'))
            assert mock_reply(fields["socket"], store, "content", b"abc", 9) == b""
            assert mock_reply(fields["socket"], store, "content", b"p" * 4096 + b"abc", 4105) == b"p" * 4096
            print("activity typed native: seven kinds/complete content/proposals/fixed-end/reverse/ties/catch-up/restart/provenance/malformed/truncation passed")
        finally:
            if process is not None: stop_process(process)
            endpoint.shutdown()
            endpoint.server_close()
            worker.join(timeout=5)
            assert not worker.is_alive()
        completed = True
    finally:
        if completed:
            shutil.rmtree(root)
        else:
            retain_failure_state("activity failure state", root)


def performance_case(item_bytes):
    """Opt-in real admission witness; stream both copies of the provider item."""
    from model_fixture import read_result
    root = tempfile.mkdtemp(prefix="rui-activity-performance-")
    completed = False
    process = None
    endpoint = None
    worker = None
    polling = None
    done = threading.Event()
    try:
        state = canonical_fixture_root(root)
        store = state / "store"
        store.mkdir(mode=0o700)
        marker = state / "must-not-execute"
        label = "Create forbidden effect marker"
        command_prefix = f"touch {marker};#"
        arguments = json.dumps({"cmd": command_prefix + "PADDING", "timeout_ms": None,
            "description": label}, separators=(",", ":"))
        item = json.dumps({"type": "function_call", "id": "performance-item-0", "status": "completed",
            "name": "bash", "call_id": "performance-call", "arguments": arguments}, separators=(",", ":")).encode()
        prefix, suffix = item.split(b"PADDING")
        padding = item_bytes - len(prefix) - len(suffix)
        assert padding >= 0
        argument_bytes = len(arguments.encode()) - len("PADDING") + padding
        command_bytes = len(command_prefix.encode()) + padding
        fixture = state / "provider.sse"
        generation_start = time.monotonic()
        with fixture.open("wb") as out:
            for envelope, tail in (
                    (b'data: {"type":"response.output_item.done","output_index":0,"item":', b'}\n\n'),
                    (b'data: {"type":"response.completed","response":{"id":"performance","status":"completed","output":[', b']}}\n\n')):
                out.write(envelope)
                out.write(prefix)
                remaining = padding
                chunk = b" " * (1024 * 1024)
                while remaining:
                    count = min(remaining, len(chunk))
                    out.write(chunk[:count])
                    remaining -= count
                out.write(suffix)
                out.write(tail)
        print(json.dumps({"item_bytes": item_bytes, "arguments_bytes": argument_bytes,
            "command_bytes": command_bytes, "provider_bytes": fixture.stat().st_size,
            "generation_seconds": time.monotonic() - generation_start}), flush=True)
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                is_second = b"independent question" in json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.send_header("Content-Length", str(len(successful_sse(2, "independent answer 42"))) if is_second else str(fixture.stat().st_size))
                self.end_headers()
                if is_second:
                    self.wfile.write(successful_sse(2, "independent answer 42"))
                else:
                    with fixture.open("rb") as source:
                        shutil.copyfileobj(source, self.wfile, 1024 * 1024)
                self.close_connection = True
            def log_message(self, *_args): pass
        endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=endpoint.serve_forever)
        worker.start()
        process, fields = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        command("session", "configure", "--store", store, "--record", state / "config", "--key", "config", "--session", SESSION,
            "--workspace", pathlib.Path.cwd(), "--provider", "codex", "--model", "model-a", "--tools", "bash", "--permission-mode", "ask")
        configure(state, store, "second-config", "direct/independent")
        admitted_start = time.monotonic()
        message(state, store, "large", SESSION, "propose command")
        # A live, read-only commit observer avoids sending a bounded Client
        # exchange into the nonpreemptible import. This is not admission proof:
        # the native page below must independently report the admitted Action.
        def committed():
            try:
                with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True, timeout=0) as db:
                    return db.execute("SELECT count(*) FROM model_tool_call").fetchone()[0] == 1
            except sqlite3.OperationalError as error:
                if error.sqlite_errorcode == sqlite3.SQLITE_BUSY: return False
                raise
        wait_for(committed, "live provider import commit", timeout=300)
        first = page(store)
        calls = [r for r in first["page"]["items"] if kind(r) == "call"]
        assert len(calls) == 1 and calls[0]["value"]["call"]["action"] is not None, first
        assert calls[0]["value"]["call"]["rejection"] is None, first
        assert calls[0]["value"]["call"]["fields"][3]["bytes"] == str(argument_bytes), first
        for reference, identity in zip(calls[0]["value"]["call"]["fields"][:3],
                (b"performance-item-0", b"bash", b"performance-call")):
            assert reference == {"bytes": str(len(identity)), "sha256": digest(identity).hex()}, reference
        expected = first["page"]["call_activity"]
        assert expected["total"] == "1" and expected["entries"][0]["presentation"]["description"] == label, expected
        assert expected["entries"][0]["presentation"]["code"] == "pending_permission", expected
        print(json.dumps({"admission_seconds": time.monotonic() - admitted_start, "call": calls[0], "activity": expected}), flush=True)
        errors = []
        timings = []
        def poll():
            try:
                for index in range(30):
                    if done.is_set(): return
                    tick = time.monotonic()
                    current = command("session", "inspect", "--store", store, "--session", SESSION)
                    current_end = time.monotonic()
                    if done.is_set(): return
                    observed = page(store)["page"]["call_activity"]
                    end = time.monotonic()
                    assert observed == expected, observed
                    unresolved = current["actions"]["unresolved"]
                    assert current["profile"] == "current" and len(unresolved) == 1, current
                    assert unresolved[0]["action"] == calls[0]["value"]["call"]["action"], current
                    assert unresolved[0]["presentation"] == expected["entries"][0]["presentation"], current
                    assert unresolved[0]["parent_operation"] == expected["entries"][0]["operation"], current
                    assert unresolved[0]["call_ordinal"] == expected["entries"][0]["ordinal"], current
                    assert not marker.exists()
                    timings.append({"index": index, "current_seconds": current_end - tick,
                        "activity_seconds": end - current_end, "current": current,
                        "start_seconds": tick - admitted_start, "end_seconds": end - admitted_start})
                    # Pace the workload, never a correctness/acceptance delay.
                    done.wait(max(0, 0.25 - (time.monotonic() - tick)))
            except BaseException as error:
                errors.append(error)
        polling = threading.Thread(target=poll)
        polling.start()
        second_start = time.monotonic()
        try:
            message(state, store, "independent", "direct/independent", "independent question")
            second_admitted = time.monotonic()
            deadline = second_start + 15
            result = wait_for(lambda: observe(store, "independent").get("result", {}).get("status") == "completed",
                "independent result while polling", deadline=deadline)
            answer = read_result(store, "independent", deadline=deadline)
            assert answer == b"independent answer 42", answer
            second_end = time.monotonic()
            print(json.dumps({"second_admission_seconds": second_admitted - second_start,
                "second_result_seconds": second_end - second_start, "answer": answer.decode(), "completed": result,
                "second_start_seconds": second_start - admitted_start, "second_end_seconds": second_end - admitted_start}), flush=True)
        finally:
            incoming_error = sys.exc_info()[1]
            if incoming_error is not None: done.set()
            polling.join(timeout=15)
            if polling.is_alive():
                error = AssertionError("performance polling thread did not retire")
                if incoming_error is None: raise error
                incoming_error.add_note(str(error))
            print(json.dumps({"polls": timings}), flush=True)
        if errors: raise errors[0]
        assert len(timings) == 30 and not marker.exists()
        assert any(sample["start_seconds"] < second_end - admitted_start and
            sample["end_seconds"] > second_start - admitted_start for sample in timings), "no polling exchange overlapped independent Session progress"
        stop_session(state, store, "stop-large", SESSION)
        wait_for(lambda: observe(store, "large").get("result", {}).get("status") == "cancelled", "large cancellation")
        wait_for(lambda: inspect_execution(store, SESSION)["custody_occupied"] == "0", "all disposal")
        assert not marker.exists()
        completed = True
    finally:
        incoming_error = sys.exc_info()[1]
        done.set()
        disposal_errors = []
        for dispose in (lambda: stop_process(process) if process is not None else None,
                        lambda: polling.join(timeout=15) if polling is not None else None,
                        endpoint.shutdown if endpoint is not None else None,
                        endpoint.server_close if endpoint is not None else None,
                        lambda: worker.join(timeout=5) if worker is not None else None):
            if dispose is None: continue
            try:
                dispose()
            except BaseException as error:
                disposal_errors.append(error)
        if polling is not None and polling.is_alive():
            disposal_errors.append(AssertionError("performance polling thread did not retire after Host disposal"))
        if worker is not None and worker.is_alive():
            disposal_errors.append(AssertionError("performance provider thread did not retire"))
        if completed and not disposal_errors:
            shutil.rmtree(root)
            print("performance native receipts, cancellation, disposal and fixture removal complete", flush=True)
        else:
            retain_failure_state("performance failure state", root)
        if disposal_errors:
            primary = incoming_error if incoming_error is not None else disposal_errors[0]
            primary.add_note("Performance fixture disposal failed: " + ", ".join(str(error) for error in disposal_errors))
            if incoming_error is None: raise primary


if __name__ == "__main__":
    if "RUI_ACTIVITY_ITEM_BYTES" in os.environ:
        performance_case(int(os.environ["RUI_ACTIVITY_ITEM_BYTES"]))
    else:
        main()
