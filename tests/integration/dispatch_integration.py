#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import resource
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time

from host_process import HostDiagnostics, PeerCensus, ReleaseGate, canonical_fixture_root, dispose_all, preserve_failure_metadata, retain_failure_state, stop_process, wait_for_execution_release
from model_fixture import (
    ROOT, RUI, FailureEndpoint, ResponseSpec, SuccessEndpoint,
    assert_model_cleanup_census, classification_population, command,
    completed_observation, configure, configure_lost_reply, crash_host,
    encode_sse, finish_command, message, message_lost_reply,
    model_instructions, observe, read_action, read_result, retry_message,
    sse_answer, sse_many, sse_tool_calls, start_command, start_host, stop_host,
    wait_for, wait_for_result_release, wait_model_cleanup,
)


def failed_response_records(store):
    """Read back failed-response records in retention order, checking each
    private body against its metadata's length and digest."""
    root = pathlib.Path(store) / "diagnostics" / "failed-responses"
    if not root.exists():
        return []
    assert stat.S_IMODE(root.lstat().st_mode) == 0o700, oct(root.lstat().st_mode)
    records = []
    for path in sorted(root.glob("response-*.json"), key=lambda path: int(path.name.split("-")[1])):
        assert stat.S_IMODE(path.lstat().st_mode) == 0o600, path
        metadata = json.loads(path.read_bytes())
        sequence, operation, attempt = path.name.removesuffix(".json").split("-")[1:]
        assert (metadata["operation"], metadata["attempt"]) == (operation, attempt), (path, metadata)
        body = None
        if metadata["body"] is not None:
            body_path = root / metadata["body"]
            assert body_path.name == f"response-{sequence}-{operation}-{attempt}.body", metadata
            assert stat.S_IMODE(body_path.lstat().st_mode) == 0o600, body_path
            body = body_path.read_bytes()
            assert str(len(body)) == metadata["retained_bytes"], metadata
            assert hashlib.sha256(body).hexdigest() == metadata["retained_sha256"], metadata
        records.append((metadata, body))
    assert not list(root.glob("*.tmp")), list(root.iterdir())
    return records


def assert_complete_failed_response(store, body, *, operation, code, http_status, request_id, diagnostic=None):
    """One complete record of exactly the bytes the provider sent."""
    records = failed_response_records(store)
    assert len(records) == 1, records
    metadata, retained = records[0]
    assert retained == body, (len(retained or b""), len(body))
    assert metadata["status"] == "complete" and metadata["transfer"] == "complete", metadata
    assert metadata["truncated"] is False and metadata["captured_bytes"] == str(len(body)), metadata
    assert (metadata["operation"], metadata["attempt"]) == (operation, "1"), metadata
    assert (metadata["code"], metadata["http_status"], metadata["request_id"]) == (code, http_status, request_id), metadata
    assert metadata["diagnostic"] == diagnostic, metadata
    return metadata


def failed_response_export_case(state, processes, endpoints):
    """Production incomplete output and binary HTTP failure, public raw reads."""
    incomplete = encode_sse([{"type": "response.incomplete", "response": {"status": "incomplete"}}], done=False)
    binary = bytes(range(256)) * 1025 + b"\x00\xfftail\r\n"
    endpoint = SuccessEndpoint([incomplete, ResponseSpec(binary, {}, status=400)], chunk_sizes=(65536,))
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoints[endpoint] = thread
    thread.start()
    store = state / "failed-response-export"
    host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
    processes.append(host)
    session = configure(state, store, "export-config", None, "gpt-6-sol")
    other_session = configure(state, store, "export-other-config", None, "gpt-6-sol")
    for label, code in (("incomplete", "malformed_provider_output"), ("binary", "provider_http_400")):
        message(state, store, f"export-{label}", session, label)
        result = wait_for(lambda: (value := observe(store, f"export-{label}")).get("result") and value, label)
        assert result["result"]["code"] == code, result
    stop_host(host)
    processes.remove(host)
    records = failed_response_records(store)
    assert len(records) == 2 and [body for _, body in records] == [incomplete, binary], records
    assert json.loads(records[0][0]["diagnostic"])["reason"] == "IncompleteProviderOutput", records[0]
    root = store / "diagnostics" / "failed-responses"

    def fd256():
        resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))

    def export(operation, part, *, target=session, attempt="1", extra=(), error=None):
        result = subprocess.run([str(RUI), "session", "inspect", "--store", str(store),
                                 "--session", target, "--operation", str(operation), "--attempt", attempt,
                                 "--failed-response", part, *extra], capture_output=True, timeout=15,
                                preexec_fn=fd256)
        if error is not None:
            assert result.returncode != 0 and result.stdout == b"" and error.encode() in result.stderr, result
        else:
            assert result.returncode == 0 and result.stderr == b"", result
        return result.stdout

    def snapshot():
        # Canonical values, not WAL/checkpoint housekeeping or filesystem atime.
        # The Host's exclusive SQLite lease must be released for this audit.
        with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as database:
            canonical = tuple(database.iterdump())
        retained = {path.name: (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ctime_ns)
                    for path in root.iterdir()}
        return canonical, retained

    before = snapshot()
    # Restart with execution unavailable: inspection cannot fetch another body.
    host = start_host(store, None)
    processes.append(host)
    for metadata, expected in records:
        operation = metadata["operation"]
        metadata_path = root / metadata["body"].replace(".body", ".json")
        assert export(operation, "body") == expected, "body bytes changed in public export"
        assert export(operation, "metadata") == metadata_path.read_bytes(), "metadata bytes changed in public export"
        export(operation, "body", target=other_session, error="ContentNotFound")
        export(operation, "body", attempt="2", error="ContentNotFound")
    export("999999", "metadata", error="ContentNotFound")
    export(records[0][0]["operation"], "body", extra=("--profile", "full"), error="conflicting")
    export(records[0][0]["operation"], "unknown", error="InvalidArguments")
    export("0", "body", error="InvalidTarget")
    stop_host(host)
    processes.remove(host)
    assert snapshot() == before, "export mutated canonical data, retained bytes or write timestamps"
    host = start_host(store, None)
    processes.append(host)

    # Perturb one real retained record, never a file-only replacement Store.
    # Partial/omitted metadata is exported verbatim; a partial body is its
    # exact retained prefix, while absent/corrupt/substituted bodies fail empty.
    metadata, expected = records[1]
    operation = metadata["operation"]
    body_path = root / metadata["body"]
    metadata_path = body_path.with_suffix(".json")
    original_metadata = metadata_path.read_bytes()
    prefix = expected[:65539]
    partial = dict(metadata, status="partial", transfer="interrupted", retained_bytes=str(len(prefix)),
                   retained_sha256=hashlib.sha256(prefix).hexdigest())
    body_path.write_bytes(prefix)
    partial_bytes = json.dumps(partial, indent=2).encode() + b"\n \n"
    metadata_path.write_bytes(partial_bytes)
    assert export(operation, "body") == prefix
    assert export(operation, "metadata") == partial_bytes
    omitted = dict(metadata, status="omitted", body=None, retained_bytes="0", retained_sha256=None,
                   omitted_reason="ShortResponseCaptureRead")
    omitted_bytes = json.dumps(omitted).encode()
    metadata_path.write_bytes(omitted_bytes)
    body_path.unlink()
    assert export(operation, "metadata") == omitted_bytes
    export(operation, "body", error="FailedResponseBodyOmitted")
    metadata_path.write_bytes(original_metadata)
    export(operation, "body", error="FailedResponseNotFound")
    body_path.symlink_to(state / "must-not-read")
    export(operation, "body", error="SymLinkLoop")
    body_path.unlink()
    body_path.write_bytes(expected)
    body_path.chmod(0)
    try:
        export(operation, "body", error="AccessDenied")
    finally:
        body_path.chmod(0o600)
    body_path.write_bytes(bytes([expected[0] ^ 1]) + expected[1:])
    export(operation, "body", error="InvalidFailedResponseRecord")
    body_path.write_bytes(expected)
    wrong = dict(metadata, turn=str(int(metadata["turn"]) + 1))
    metadata_path.write_bytes(json.dumps(wrong).encode())
    export(operation, "metadata", error="InvalidFailedResponseRecord")
    metadata_path.write_bytes(original_metadata)
    duplicate = root / f"response-999-{operation}-1.json"
    duplicate.write_bytes(original_metadata)
    export(operation, "metadata", error="AmbiguousFailedResponse")
    duplicate.unlink()
    metadata_path.unlink()
    export(operation, "body", error="FailedResponseNotFound")
    metadata_path.write_bytes(original_metadata)
    assert export(operation, "body") == expected
    assert len(endpoint.requests) == 2, "inspection contacted the provider"
    report = command("session", "inspect", "--store", store, "--session", session)
    assert report["execution"]["scratch_used_bytes"] == "0", report
    stop_host(host)
    processes.remove(host)
    assert snapshot()[0] == before[0], "diagnostic error paths mutated canonical data"
    # Export uses the same mandatory report-scratch disposal as inspection.
    # An unlinked-name failure must stop dispatch, not accumulate uncharged
    # files behind an ordinary diagnostic-unavailable reply.
    host = start_host(store, None, "--fault", "report-unlink")
    processes.append(host)
    export(records[0][0]["operation"], "body", error="report_scratch_cleanup_failed")
    wait_for(lambda: host.poll() is not None, "export unlink effect-aware Host shutdown", timeout=5)
    assert host.returncode != 0, host.returncode
    stop_host(host)
    processes.remove(host)
    leftovers = list((store / "scratch").glob("report-*.tmp"))
    assert len(leftovers) == 1 and leftovers[0].stat().st_size == 0, leftovers
    assert snapshot()[0] == before[0], "export disposal changed the original saved failure"
    host = start_host(store, None)
    processes.append(host)
    assert not leftovers[0].exists(), "startup did not reclaim the failed export capture"
    assert export(records[0][0]["operation"], "body") == incomplete
    assert json.loads(export(records[0][0]["operation"], "metadata"))["diagnostic"] == records[0][0]["diagnostic"]
    assert observe(store, "export-incomplete")["result"]["code"] == "malformed_provider_output"
    stop_host(host)
    processes.remove(host)
    export(operation, "body", error="ConnectionRefused")
    stop_endpoint(endpoint, endpoints)
    print(f"failed-response export: IncompleteProviderOutput {len(incomplete)} bytes and binary {len(binary)} bytes exact; "
          "metadata exact; fd256; read-only; partial/omitted/missing/identity/symlink/corruption errors empty stdout; "
          "scratch unlink fences and recovers without changing saved failure; no provider calls")


def empty_response_retention_case(state, processes, endpoints, status):
    """Empty failures leave fresh diagnostics and a full retention FIFO untouched."""
    label = f"empty-http-{status}"
    store = state / label
    body = b'{"error":"nonempty retention control"}'
    empty = ResponseSpec(b"", {"X-Request-Id": label}, status=status)
    nonempty = ResponseSpec(body, {"X-Request-Id": "nonempty-control"}, status=400)
    # A clean HTTP 200 close retries through the four-Attempt allowance;
    # every empty capture must still leave the retention FIFO unchanged.
    empty_attempts = 1 if status == 400 else 4
    endpoint = SuccessEndpoint([*[empty] * empty_attempts, nonempty, *[empty] * empty_attempts, nonempty])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoints[endpoint] = thread
    thread.start()
    host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
    processes.append(host)
    session = configure(state, store, label + "-config", None, "gpt-6-sol")

    def fail(key, code):
        message(state, store, key, session, "input")
        result = wait_for(lambda: (value := observe(store, key)).get("result") and value, key)
        assert result["result"]["code"] == code, result

    code = "provider_http_400" if status == 400 else "retry_exhausted"
    root = store / "diagnostics" / "failed-responses"
    fail(label + "-fresh", code)
    assert not root.exists(), f"{label} created diagnostics without response bytes"
    fail(label + "-seed", "provider_http_400")
    (seed, retained), = failed_response_records(store)
    assert retained == body and seed["status"] == "complete", seed
    assert seed["body"].startswith("response-1-"), seed

    # Fill the production 256-record bound with private copies of this real
    # record. Empty admission must return before prune could evict its oldest.
    for sequence in range(2, 257):
        stem = f"response-{sequence}-{seed['operation']}-{seed['attempt']}"
        metadata = dict(seed, body=stem + ".body")
        for name, data in ((stem + ".body", body), (stem + ".json", json.dumps(metadata).encode())):
            path = root / name
            path.write_bytes(data)
            path.chmod(0o600)
    before = {path.name: path.read_bytes() for path in root.iterdir()}
    assert len(failed_response_records(store)) == 256
    fail(label + "-full", code)
    after = {path.name: path.read_bytes() for path in root.iterdir()}
    assert after == before, f"{label} changed the full retention FIFO"
    assert len(endpoint.requests) == 2 * empty_attempts + 1, len(endpoint.requests)

    # A later nonempty failure still evicts exactly the oldest record and
    # takes sequence 257, with no sequence or FIFO cost for either empty body.
    fail(label + "-after", "provider_http_400")
    records = failed_response_records(store)
    assert [int(record["body"].split("-")[1]) for record, _ in records] == list(range(2, 258))
    assert records[-1][1] == body and records[-1][0]["status"] == "complete"
    oldest = {seed["body"], seed["body"].removesuffix(".body") + ".json"}
    for name, data in before.items():
        if name in oldest:
            assert not (root / name).exists(), name
        else:
            assert (root / name).read_bytes() == data, name
    assert len(endpoint.requests) == 2 * empty_attempts + 2, len(endpoint.requests)
    stop_host(host)
    processes.remove(host)
    stop_endpoint(endpoint, endpoints)
    print(f"{label}: no empty record/directory; full FIFO and next sequence unchanged; nonempty eviction preserved")


def decode_model_evidence(value):
    """Independent oracle for the adapter's opaque v1 source certificate."""
    assert isinstance(value, bytes) and 7 <= len(value) <= 775, value
    assert value[0] == 1, value
    fields = []
    offset = 1
    for _ in range(3):
        assert offset + 2 <= len(value), value
        length = int.from_bytes(value[offset:offset + 2], "little")
        offset += 2
        assert length <= 256 and offset + length <= len(value), value
        fields.append(value[offset:offset + length].decode("utf-8") if length else None)
        offset += length
    assert offset == len(value), value
    return tuple(fields)


def stop_endpoint(endpoint, endpoints):
    thread = endpoints[endpoint]

    def shutdown():
        if thread.ident is not None:
            try:
                endpoint.shutdown()
            except BaseException:
                # A pre-effect refusal leaves serve_forever alive. Retry once,
                # retaining the first failure even if retirement then succeeds.
                dispose_all(endpoint.shutdown)
                raise

    def join():
        if thread.ident is not None:
            thread.join(timeout=5)
            assert not thread.is_alive(), "Dispatch endpoint thread did not retire"

    # shutdown/server_close may block; the join timeout is not a shutdown bound.
    dispose_all(
        shutdown,
        endpoint.server_close,
        join,
    )
    # dispose_all retains an active body error; inspect retirement rather than
    # treating its return as proof that every disposal succeeded.
    if endpoint.fileno() == -1 and not thread.is_alive():
        del endpoints[endpoint]


def dispose_dispatch(processes, endpoints, releases, *after):
    dispose_all(
        *(lambda process=process: stop_host(process) for process in processes),
        *releases,
        *(lambda endpoint=endpoint: stop_endpoint(endpoint, endpoints) for endpoint in tuple(endpoints)),
        *after,
    )


def compaction_cases(state, processes, endpoints, releases):
    """Exercise compaction through ordinary intake, transport and recovery."""
    def compact_response(label, *, extra=None):
        items = [
            {"type": "reasoning", "id": f"{label}-before", "summary": [], "encrypted_content": "discard-before-anchor"},
            {"type": "compaction", "id": f"{label}-anchor", "encrypted_content": "opaque-" + "é" * 5000, "created_by": "response-only"},
            {"type": "message", "id": f"{label}-tail", "role": "assistant", "content": [{"type": "output_text", "text": "private compaction tail"}]},
        ]
        if extra is not None:
            items.append(extra)
        payloads = []
        for index, item in enumerate(items):
            payloads.append({"type": "response.output_item.done", "output_index": index, "item": item})
        payloads.append({"type": "response.completed", "response": {
            "id": label, "status": "completed", "model": "model-a-served", "output": items,
            "usage": {"total_tokens": 999999},
        }})
        return encode_sse(payloads), items

    def endpoint_for(responses):
        endpoint = SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        return endpoint, f"http://127.0.0.1:{endpoint.server_port}/responses"

    def patch(store, session, key, *flags):
        result = command("session", "configure", "--store", store, "--record", state / f"{key}.json",
                         "--session", session, "--key", key, *flags)
        assert result["answer"]["status"] == "accepted", result

    def user_texts(request):
        return [item["content"][0]["text"] for item in request["input"] if item.get("role") == "user"]

    overflow_request_id = 'overflow-"quoted"\\request'
    overflow_http = ResponseSpec(
        b'{"error":{"code":"context_length_exceeded"}}', {"X-Request-Id": overflow_request_id}, status=400
    )
    overflow_sse = encode_sse([{"type": "response.failed", "response": {
        "status": "failed", "error": {"code": "context_length_exceeded"},
    }}], done=False)
    for route, overflow in (("http", overflow_http), ("sse", overflow_sse)):
        compact, items = compact_response(route)
        gate = threading.Event()
        releases.append(gate.set)
        answer, _, _ = sse_answer(f"{route}-answer", f"{route}-reason", f"{route}-message", "recovered answer")
        endpoint, url = endpoint_for([overflow, (compact, gate), answer])
        store = state / f"compaction-{route}"
        host = start_host(store, url)
        processes.append(host)
        session = configure(state, store, f"{route}-config", None, "gpt-6-sol", instructions="baseline")
        settings = command("session", "inspect", "--store", store, "--session", session)["session"]
        assert settings["compaction_trigger"] is None and settings["output_reservation"] == "0", settings
        message(state, store, f"{route}-first", session, "covered user input")
        wait_for(lambda: len(endpoint.requests) == 2, "overflow followed by explicit compaction")
        compaction = json.loads(endpoint.requests[1])
        assert compaction["input"][-1] == {"type": "compaction_trigger"}, compaction
        # The originating Operation's address and baseline survive overflow
        # into its compaction Operation.
        address = model_instructions(ROOT, "baseline", store=store, session=session)
        assert [json.loads(request)["instructions"] for request in endpoint.requests[:2]] == [address, address], endpoint.requests[:2]
        assert compaction["store"] is False and compaction["stream"] is True, compaction
        assert compaction["include"] == ["reasoning.encrypted_content"], compaction
        assert user_texts(compaction) == ["covered user input"], compaction
        # Admission fixes coverage. Later settings and messages cannot enter it.
        patch(store, session, f"{route}-policy", "--compaction-trigger", "1", "--output-reservation", "0")
        configure(state, store, f"{route}-instructions", session, "gpt-6-sol", instructions="arrived during compaction")
        message(state, store, f"{route}-late", session, "pending input")
        gate.set()
        wait_for(lambda: completed_observation(store, f"{route}-late"), "compaction successor answer")
        assert read_result(store, f"{route}-first") == b"recovered answer"
        assert read_result(store, f"{route}-late") == b"recovered answer"
        assert len(endpoint.requests) == 3, endpoint.requests
        successor = json.loads(endpoint.requests[2])
        assert user_texts(successor) == ["covered user input", "pending input"], successor
        assert successor["instructions"] == address, successor
        assert [item["content"][0]["text"] for item in successor["input"] if item.get("role") == "developer"] == ["arrived during compaction"], successor
        assert not any(item.get("id") == items[0]["id"] for item in successor["input"]), successor
        replay_anchor = dict(items[1])
        replay_anchor.pop("created_by")
        assert successor["input"][1:3] == [replay_anchor, items[2]], successor
        report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
        assert report["actions"]["count"] == "0", report
        assert b"private compaction tail" not in json.dumps(report).encode(), report
        # The full canonical output is saved once, with no Conversation projection.
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute("SELECT purpose,resolution_code FROM model_operation ORDER BY operation_id").fetchall() == [
                (0, "context_overflow"), (1, "compacted"), (0, "answer")]
            # Each overflow keeps the correlation its provider answer carried.
            assert database.execute("SELECT request_id FROM model_operation WHERE operation_id=1").fetchone()[0] == (
                overflow_request_id if route == "http" else "request-1")
            assert database.execute("SELECT count(*) FROM model_output_item WHERE operation_id=2").fetchone()[0] == 3
            assert database.execute("SELECT count(*) FROM conversation_entry WHERE source_operation_id=2").fetchone()[0] == 0
        # Reset recovers default selection, then restart reconstructs the same base.
        followup, _, _ = sse_answer(f"{route}-followup", f"{route}-r2", f"{route}-m2", "after restart")
        endpoint.responses.append(followup)
        host = start_host(store, url)
        processes.append(host)
        patch(store, session, f"{route}-reset", "--compaction-trigger", "default", "--output-reservation", "default")
        current = command("session", "inspect", "--store", store, "--session", session)["session"]
        assert current["compaction_trigger"] is None and current["compaction_trigger_override"] is None, current
        assert current["output_reservation"] == "0" and current["output_reservation_override"] is None, current
        overflowed = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")["full"]["model_operations"][0]
        assert overflowed["request_id"] == (overflow_request_id if route == "http" else "request-1"), overflowed
        message(state, store, f"{route}-followup-input", session, "followup input")
        wait_for(lambda: completed_observation(store, f"{route}-followup-input"), "reconstructed base after restart")
        assert read_result(store, f"{route}-followup-input") == b"after restart"
        restarted = json.loads(endpoint.requests[3])
        assert replay_anchor in restarted["input"] and items[2] in restarted["input"], restarted
        assert user_texts(restarted) == ["covered user input", "pending input", "followup input"], restarted
        assert restarted["instructions"] == address, restarted
        execution = wait_for(lambda: (value := command("session", "inspect", "--store", store, "--session", session)["execution"])["custody_occupied"] == "0" and value, "compaction custody release")
        assert execution["scratch_used_bytes"] == "0" and not execution["dispatch_fenced"], execution
        stop_host(host)
        processes.remove(host)
        # Corruption after the base must not silently shorten the suffix.
        with sqlite3.connect(store / "rui.sqlite3") as database:
            database.execute("DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_operation) AND item_ordinal=0")
        host = start_host(store, url)
        processes.append(host)
        message(state, store, f"{route}-corrupt-input", session, "do not dispatch incomplete history")
        wait_for(lambda: host.poll() is not None, "missing suffix fences Host")
        assert host.returncode == 1, host.returncode
        failure = host.stderr.read()
        assert b"dispatch fenced" in failure and b"CorruptStore" in failure, failure
        assert len(endpoint.requests) == 4, endpoint.requests
        stop_host(host)
        processes.remove(host)
        stop_endpoint(endpoint, endpoints)

    # Proactive compaction holds the new input outside its frozen view. The
    # multibyte, quote- and backslash-bearing Store does not leak into the
    # allocated Session's self-address. The Store path stays space-free
    # because Host readiness is space-delimited.
    first, _, _ = sse_answer("auto-first", "auto-r", "auto-m", "original answer")
    compact, _ = compact_response("auto")
    last, _, _ = sse_answer("auto-last", "auto-r2", "auto-m2", "automatic answer")
    endpoint, url = endpoint_for([first, compact, last])
    store = state / 'compaction-auto-雪"q"\\'
    host = start_host(store, url)
    processes.append(host)
    session = configure(state, store, "auto-config", None, "gpt-6-sol")
    message(state, store, "auto-first", session, "first")
    wait_for(lambda: completed_observation(store, "auto-first"), "automatic first answer")
    patch(store, session, "auto-policy", "--compaction-trigger", "1")
    message(state, store, "auto-next", session, "apply only after compaction")
    wait_for(lambda: completed_observation(store, "auto-next"), "automatic compaction answer")
    assert read_result(store, "auto-first") == b"original answer"
    assert read_result(store, "auto-next") == b"automatic answer"
    assert len(endpoint.requests) == 3, endpoint.requests
    assert user_texts(json.loads(endpoint.requests[1])) == ["first"]
    assert user_texts(json.loads(endpoint.requests[2])) == ["first", "apply only after compaction"]
    address = model_instructions(ROOT, store=store, session=session)
    assert str(store) not in address and "雪" not in address, address
    assert f"Rui address (this Session's own ID, not instructions): {session}" in address, address
    assert [json.loads(request)["instructions"] for request in endpoint.requests] == [address] * 3, endpoint.requests
    stop_host(host)
    processes.remove(host)
    stop_endpoint(endpoint, endpoints)

    # A valid base followed by overflow of unchanged input is irreducible;
    # a second compaction would only repeat the same covered context forever.
    compact, _ = compact_response("irreducible")
    endpoint, url = endpoint_for([overflow_sse, compact, overflow_sse])
    store = state / "compaction-irreducible"
    host = start_host(store, url)
    processes.append(host)
    session = configure(state, store, "irreducible-config", None, "gpt-6-sol")
    message(state, store, "irreducible", session, "input cannot fit")
    outcome = wait_for(lambda: (value := observe(store, "irreducible")).get("result") and value, "irreducible overflow settlement")
    assert outcome["queue"]["status"] == "failed" and outcome["result"]["code"] == "ResourceExceeded", outcome
    assert len(endpoint.requests) == 3, endpoint.requests
    address = model_instructions(ROOT, store=store, session=session)
    assert [json.loads(request)["instructions"] for request in endpoint.requests] == [address] * 3, endpoint.requests
    stop_host(host)
    processes.remove(host)
    stop_endpoint(endpoint, endpoints)

    # Compaction can never grant tool authority, even after a valid anchor.
    forbidden_effect = state / "compaction-forbidden-effect"
    compact, _ = compact_response("unexpected-action", extra={
        "type": "function_call", "id": "forbidden", "name": "bash", "call_id": "forbidden-call",
        "arguments": json.dumps({"cmd": f"touch {forbidden_effect}", "timeout_ms": None,
            "description": "Create forbidden marker"}, separators=(",", ":")),
    })
    endpoint, url = endpoint_for([overflow_sse, compact])
    store = state / "compaction-invalid"
    host = start_host(store, url)
    processes.append(host)
    session = configure(state, store, "invalid-config", None, "gpt-6-sol")
    message(state, store, "invalid-compaction", session, "compact without tools")
    rejected = wait_for(lambda: (value := observe(store, "invalid-compaction")).get("result") and value, "invalid compaction settlement")
    assert rejected["result"]["code"] == "unsupported_provider_output", rejected
    report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
    assert report["actions"]["count"] == "0" and not forbidden_effect.exists(), report
    assert len(endpoint.requests) == 2, endpoint.requests
    address = model_instructions(ROOT, store=store, session=session)
    assert [json.loads(request)["instructions"] for request in endpoint.requests] == [address] * 2, endpoint.requests
    stop_host(host)
    processes.remove(host)
    stop_endpoint(endpoint, endpoints)


def http_quota_cases(state, processes, endpoints):
    """A quota refusal settles once and keeps its code/reset through reopen."""
    for index, provider_code in enumerate(("usage_limit_reached", "insufficient_quota", "usage_not_included")):
        reset = 1_800_000_123 + index
        body = json.dumps({"error": {"code": provider_code, "resets_at": reset,
                                    "message": "private provider prose must not be copied"}}).encode()
        request_id = f"quota-request-{index}"
        endpoint = SuccessEndpoint([
            ResponseSpec(body, {"X-Request-Id": request_id, "Retry-After": "0"}, 429)
            for _ in range(4)
        ])
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        store = state / provider_code
        host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                          "--test-retry-waits-ms", "1,1,1")
        processes.append(host)
        session = configure(state, store, provider_code + "-config", None, "gpt-6-sol")
        key = provider_code + "-message"
        message(state, store, key, session, "do not retry quota failures")
        result = wait_for(lambda: (value := observe(store, key)).get("result") and value,
                          "permanent HTTP quota failure")
        code = "provider_" + provider_code
        assert result["result"]["code"] == code, result
        assert result["processing"]["attempt"] == "1", result
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT allowance_used,retry_due_at_ms,resolution_code FROM model_operation"
            ).fetchone() == (1, None, code)
        reopened = start_host(store, None)
        processes.append(reopened)
        report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
        operation = report["full"]["model_operations"][0]
        assert operation["request_id"] == request_id, operation
        assert operation["resolution"]["code"] == code, operation
        diagnostic = operation["resolution"]["content"]["text"]
        assert json.loads(diagnostic) == {"provider_code": provider_code, "resets_at": reset}, diagnostic
        assert observe(store, key)["result"] == result["result"]
        stop_host(reopened)
        processes.remove(reopened)
        assert len(endpoint.requests) == 1, endpoint.requests
        assert_complete_failed_response(store, body, operation=operation["operation"], code=code,
                                        http_status=429, request_id=request_id, diagnostic=diagnostic)
        stop_endpoint(endpoint, endpoints)
    answer = sse_answer("rate-response", "rate-reasoning", "rate-message", "rate limit recovered")[0]
    endpoint = SuccessEndpoint([
        ResponseSpec(b'{"error":{"code":"rate_limit_exceeded","resets_at":1800000123}}', {}, 429),
        answer,
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoints[endpoint] = thread
    thread.start()
    store = state / "rate-limit-control"
    host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                      "--test-retry-waits-ms", "1,1,1")
    processes.append(host)
    session = configure(state, store, "rate-config", None, "gpt-6-sol")
    message(state, store, "rate-message", session, "retry a temporary rate limit")
    result = wait_for(lambda: completed_observation(store, "rate-message"), "rate limit recovery")
    assert result["processing"]["attempt"] == "2", result
    assert read_result(store, "rate-message") == b"rate limit recovered"
    stop_host(host)
    processes.remove(host)
    assert len(endpoint.requests) == 2, endpoint.requests
    stop_endpoint(endpoint, endpoints)
    print("HTTP 429 quota: distinct permanent codes, one Attempt and exact resets_at through reopen")


def failure_correlation_cases(state, processes, endpoints, selected="all"):
    """Bounded Debug coverage for inline failure provenance through SQLite."""
    for label, status, schema, code, request_id in (
        (*variant, request_id)
        for variant in (
            ("rejected", 200, {"type": "object"}, "unsupported_output_schema"),
            ("correlated", 401, None, "provider_http_401"),
            ("exhausted", 503, None, "retry_exhausted"),
        )
        for request_id in ('correlated-"request"\\path', "")
    ):
        if selected not in ("all", label):
            continue
        identity = label + ("-present" if request_id else "-absent")
        body = sse_answer("response", "reasoning", "message", "private answer")[0] if schema else b'{"error":"synthetic"}'
        request_ids = ["attempt-1", "", "attempt-3", request_id] if status == 503 else [request_id]
        endpoint = SuccessEndpoint([
            ResponseSpec(body, {"X-Request-Id": value} if value else {}, status)
            for value in request_ids
        ])
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        store = state / identity
        flags = ["--test-phase-trace", "--test-retry-waits-ms", "1,1,1"]
        if schema:
            flags += ["--fault", "response-metadata-unlink"]
        host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", *flags, observations="control")
        processes.append(host)
        diagnostics = HostDiagnostics(host)
        session = configure(state, store, identity + "-config", None, "gpt-6-sol", schema)
        message(state, store, identity + "-message", session, "input")
        deadline = time.monotonic() + 15

        def settled():
            value = observe(store, identity + "-message", deadline=deadline)
            return value if value.get("result") else None

        result = wait_for(settled, label + " failure settlement", deadline=deadline)
        assert result["result"]["code"] == code, result
        resources = wait_model_cleanup(diagnostics, store, session, result, deadline)
        assert not resources["dispatch_fenced"], resources
        assert result["processing"]["attempt"] == str(len(request_ids)), result
        attempts = [
            {"processing": dict(result["processing"], attempt=str(ordinal))}
            for ordinal in range(1, len(request_ids) + 1)
        ]
        for attempt in attempts:
            diagnostics.wait_model_cleanup(attempt["processing"], deadline)
        stop_host(host)
        assert_model_cleanup_census(diagnostics, *attempts)
        processes.remove(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            saved = database.execute(
                "SELECT CAST(request_id AS BLOB),resolution_code,attempt_ordinal FROM model_operation"
            ).fetchone()
        expected_id = request_id.encode() if request_id else None
        assert saved == (expected_id, code, len(request_ids)), ("failure correlation must preserve exact provider bytes", identity, saved)
        reopened = start_host(store, None)
        processes.append(reopened)
        report = command(
            "session", "inspect", "--store", store,
            "--session", session, "--profile", "full",
        )
        operation = report["full"]["model_operations"][0]
        assert operation["request_id"] == (request_id or None), operation
        assert operation["resolution"]["code"] == code, operation
        assert observe(store, identity + "-message")["result"] == result["result"]
        stop_host(reopened)
        processes.remove(reopened)
        assert len(endpoint.requests) == len(request_ids), endpoint.requests
        stop_endpoint(endpoint, endpoints)
    print(f"Failure correlation ({selected}): exact provider bytes and absence preserved through reopen")


def empty_answer_cases(state, processes, endpoints):
    """Completed empty results preserve exact messages and replay after restart."""
    for phased in (True, False):
        label = "empty-phased" if phased else "empty-unphased"
        texts = ["", [" ", "\t\r\n\u00a0\u2003"], [" \té", "\n "]]
        bodies, items = [], []
        for index, text in enumerate(texts):
            body, reasoning, item = sse_answer(f"{label}-{index}", f"r-{index}", f"m-{index}", text)
            if not phased:
                del item["phase"]
                body = encode_sse([
                    {"type": "response.output_item.done", "output_index": 0, "item": reasoning},
                    {"type": "response.output_item.done", "output_index": 1, "item": item},
                    {"type": "response.completed", "response": {"id": f"{label}-{index}",
                     "status": "completed", "output": [reasoning, item]}},
                ])
            bodies.append(body)
            # created_by is response-only metadata, never a request field.
            reasoning.pop("created_by")
            items.extend((reasoning, item))
        endpoint = SuccessEndpoint(bodies)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        store = state / label
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        host = start_host(store, url)
        processes.append(host)
        session = configure(state, store, f"{label}-config", None, "gpt-6-sol")
        for index, expected in enumerate((b"", b"", " \té\n ".encode())):
            key = f"{label}-{index}"
            message(state, store, key, session, f"input-{index}")
            deadline = time.monotonic() + 10
            result = wait_for(lambda: (value := observe(store, key, deadline=deadline)).get("result") and value,
                              key, deadline=deadline)
            assert result["result"]["status"] == "completed", result
            assert read_result(store, key, deadline=deadline) == expected
            report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
            resolution = report["full"]["model_operations"][-1]["resolution"]
            assert resolution["code"] == "answer" and resolution["content"]["text"] == expected.decode(), resolution
            assert report["full"]["turns"][-1]["outcome"]["code"] == "completed", report
            wait_for_execution_release(lambda remaining: command("session", "inspect", "--store", store,
                                       "--session", session, timeout=remaining)["execution"], deadline)
            crash_host(host, state, key)
            processes.remove(host)
            host = start_host(store, url)
            processes.append(host)
            assert read_result(store, key) == expected
        replay = json.loads(endpoint.requests[2])["input"]
        assert replay[1:3] == items[:2] and replay[4:6] == items[2:4], replay
        assert len(endpoint.requests) == 3, "empty answers continued without new input"
        assert failed_response_records(store) == [], "completed empty answers became failed responses"
        stop_host(host)
        processes.remove(host)
        stop_endpoint(endpoint, endpoints)
    print("empty answers: phased/unphased empty and Unicode whitespace complete; exact nonblank bytes; inspect/read-result and restart replay passed")


def stream_failure_cases(state, processes, endpoints):
    """Sealed SSE failures retry only when their parsed meaning permits it."""
    answer = sse_answer("retry-answer", "reasoning", "answer", "recovered")[0]
    partial = encode_sse([{"type": "response.output_item.done", "output_index": 0,
                           "item": {"type": "message", "id": "partial", "role": "assistant",
                                    "content": [{"type": "output_text", "text": "not accepted"}]}}], done=False)
    cases = []
    for event_type in ("error", "response.failed"):
        for code, temporary in (("server_is_overloaded", True), ("rate_limit_exceeded", True),
                                ("future_error", True), ("insufficient_quota", False), ("bio_policy", False)):
            event = {"type": event_type, "code": code} if event_type == "error" else {
                "type": event_type, "response": {"status": "failed", "error": {"code": code}}}
            body = partial + encode_sse([event])
            cases.append((event_type + "-" + code, [body, answer] if temporary else [body],
                          "completed" if temporary else "provider_permanent_error", 2 if temporary else 1))
    overloaded = encode_sse([{"type": "response.failed", "response": {
        "status": "failed", "error": {"code": "server_is_overloaded"}}}])
    nullable = answer.replace(b'"model":"model-a-served"', b'"model":null').replace(
        b'"usage":{"input_tokens":7,"output_tokens":11,"total_tokens":18}', b'"usage":null')
    assert b'"usage":null' in nullable and b'"model":null' in nullable
    cases += [
        ("clean-close", [partial, answer], "completed", 2),
        ("exhausted", [overloaded] * 4, "retry_exhausted", 4),
        ("incomplete", [encode_sse([{"type": "response.incomplete", "response": {
            "status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}}}])], "malformed_provider_output", 1),
        ("malformed-code", [encode_sse([{"type": "error", "code": 17}])], "malformed_provider_output", 1),
        ("malformed-framing", [b'data: {"type":"response.created"}\n'], "malformed_provider_output", 1),
        ("nullable-evidence", [nullable], "completed", 1),
    ]
    for label, bodies, code, attempts in cases:
        endpoint = SuccessEndpoint(bodies)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        store = state / ("stream-" + label)
        host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        processes.append(host)
        session = configure(state, store, "stream-" + label + "-config", None, "gpt-6-sol")
        key = "stream-" + label
        message(state, store, key, session, "input")
        result = wait_for(lambda: (value := observe(store, key)).get("result") and value, label)
        assert result["processing"]["attempt"] == str(attempts), (label, result)
        if code == "completed":
            assert result["result"]["status"] == "completed", (label, result)
            assert read_result(store, key) == b"recovered", (label, result)
        else:
            assert result["result"] == {"status": "failed", "code": code}, (label, result)
        operation = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")["full"]["model_operations"][0]
        assert operation["request_id"] == f"request-{attempts}", (label, operation)
        if label == "exhausted":
            detail = json.loads(operation["resolution"]["content"]["text"])
            assert detail == {"reason": "TemporaryProviderFailure", "stage": "event", "byte_offset": "6", "output_index": None}, detail
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute("SELECT count(*) FROM action_operation").fetchone() == (0,)
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone() == (2 if code == "completed" else 0,)
        reopened = start_host(store, None)
        processes.append(reopened)
        assert command("session", "inspect", "--store", store, "--session", session, "--profile", "full")["full"]["model_operations"][0] == operation
        assert observe(store, key)["result"] == result["result"]
        stop_host(reopened)
        processes.remove(reopened)
        assert len(endpoint.requests) == attempts, (label, endpoint.requests)
        stop_endpoint(endpoint, endpoints)
    print("Stream failures: retry, permanent controls, exhaustion provenance, nullable evidence and reopen passed")


def refusal_cases(state, processes, endpoints):
    """Refusal text is observable; canonical and replay content stays a refusal."""
    for phased in (False, True):
        label = "refusal-phased" if phased else "refusal-unphased"
        refusal = "I cannot help with that. é\n\x00End.\n"
        blocks = [{"type": "refusal", "refusal": refusal, "future": {"retained": True}}]
        if phased:
            blocks = [{"type": "output_text", "text": "Before. "}, *blocks,
                      {"type": "output_text", "text": "After."}]
        expected = ("Before. " + refusal + "After." if phased else refusal).encode()
        item = {"type": "message", "id": label, "role": "assistant", "status": "completed",
                "content": blocks, "created_by": "provider"}
        if phased:
            item["phase"] = "final_answer"
        events = [
            {"type": "response.refusal.delta", "output_index": 0, "content_index": int(phased),
             "delta": "Untrusted delta must not become the answer"},
            {"type": "response.refusal.done", "output_index": 0, "content_index": int(phased),
             "refusal": refusal},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {"id": label, "status": "completed",
             "output": [item] if phased else []}},
        ]
        body = encode_sse(events)
        endpoint = SuccessEndpoint([body, sse_answer(label + "-next", "reason", "next", "Next answer")[0]])
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        store = state / label
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        host = start_host(store, url)
        processes.append(host)
        session = configure(state, store, label + "-config", None, "gpt-6-luna")
        message(state, store, label, session, "Refuse this request")
        result, answer, _ = wait_for_result_release(store, label, session, time.monotonic() + 10)
        assert result["result"]["status"] == "completed", result
        assert answer == expected, "refusal text lost in original result"

        def assert_public_refusal():
            assert read_result(store, label) == expected, "refusal text lost in original result"
            report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
            positions = [entry["position"] for entry in report["full"]["conversation"]
                         if entry["kind"] == "assistant"]
            assert len(positions) == 1, report
            public = subprocess.run([str(RUI), "session", "read-conversation", "--store", str(store),
                "--session", session, "--position", str(positions[0]), "--ordinal", "0"],
                capture_output=True, timeout=10)
            assert public.returncode == 0 and public.stdout == expected, public

        assert_public_refusal()
        crash_host(host, state, label)
        processes.remove(host)
        host = start_host(store, url)
        processes.append(host)
        assert_public_refusal()
        message(state, store, label + "-next", session, "Continue after refusal")
        later, answer, _ = wait_for_result_release(store, label + "-next", session, time.monotonic() + 10)
        assert later["result"]["status"] == "completed" and answer == b"Next answer", later
        assert read_result(store, label) == expected
        replay = json.loads(endpoint.requests[1])["input"]
        assert replay[1] == {key: value for key, value in item.items() if key != "created_by"}, replay
        stop_host(host)
        processes.remove(host)
        # Public reads are projections; canonical raw bytes retain refusal kind,
        # unknown metadata and created_by independently of replay filtering.
        with sqlite3.connect(store / "rui.sqlite3") as database:
            raw = database.execute("SELECT c.payload FROM model_output_item i JOIN content c "
                "ON c.content_id=i.content_id WHERE i.item_kind=2 ORDER BY i.operation_id LIMIT 1").fetchone()
            assert raw is not None and bytes(raw[0]) == json.dumps(item, separators=(",", ":")).encode(), raw
        assert not failed_response_records(store), "accepted refusal became failed-response diagnostics"
        stop_endpoint(endpoint, endpoints)
    print("Refusal: public result/conversation, crash recovery and exact typed replay passed")


def phased_message_cases(state, processes, endpoints):
    """Synthetic gpt-6-luna-shaped streams, not recovered live captures."""
    def text_item(identity, text, phase):
        item = {"type": "message", "id": identity, "role": "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}]}
        if phase is not None:
            item["phase"] = phase
        return item

    def response(identity, items):
        return ResponseSpec(encode_sse([
            *({"type": "response.output_item.done", "output_index": index, "item": item}
              for index, item in enumerate(items)),
            {"type": "response.completed", "response": {"id": identity,
             "model": "gpt-6-luna", "status": "completed", "output": items}},
        ]), headers={"OpenAI-Model": "gpt-6-luna"})

    for phased in (True, False):
        label = "phased" if phased else "unphased"
        store = state / f"{label}-store"
        commentary = "commentary" if phased else None
        final = "final_answer" if phased else None
        forbidden = state / f"{label}-must-not-launch"
        calls = [
            {"type": "function_call", "id": f"{label}-bash", "call_id": "first-call", "name": "bash",
             "arguments": json.dumps({"cmd": f"touch {forbidden}", "timeout_ms": None,
                                      "description": "Create forbidden marker"}, separators=(",", ":"))},
            {"type": "function_call", "id": f"{label}-unknown", "call_id": "second-call",
             "name": "missing-tool", "arguments": "{}"},
        ]
        first_items = [text_item("before", "Inspecting files", commentary), calls[0],
                       text_item("between", "Checking sibling calls", commentary), calls[1],
                       text_item("after", "Waiting for tool results", commentary)]
        # Identical visible text in distinct messages deliberately exercises
        # content dedup without losing exact item provenance.
        final_items = [text_item("repeated", "Inspecting files", commentary),
                       text_item("summary", "Tools settled", commentary),
                       text_item("final", "Canonical answer é", final)]
        later_items = [text_item("later", "Newer answer", final)]
        if phased:
            # An explicit final wins even when later text remains visible.
            later_items.append(text_item("tail", "After final commentary", commentary))
        endpoint = SuccessEndpoint([response("tools", first_items), response("answer", final_items),
                                    response("later", later_items)])
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        endpoints[endpoint] = thread
        thread.start()
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        host = start_host(store, url)
        processes.append(host)
        session = configure(state, store, f"{label}-config", None, "gpt-6-luna")
        key = f"{label}-request"
        message(state, store, key, session, "Inspect the workspace")
        report = wait_for(lambda: (value := command("session", "inspect", "--store", store,
                          "--session", session, "--profile", "full"))["actions"]["unresolved"] and value,
                          "interleaved Bash permission")
        action = report["full"]["actions"][0]["action"]
        command("action", "deny", "--store", store, "--session", session, "--action", action,
                "--record", state / f"{label}-deny.json", "--key", f"{label}-deny")
        deadline = time.monotonic() + 10
        wait_for(lambda: completed_observation(store, key, deadline=deadline),
                 "phase-selected answer", deadline=deadline)
        assert read_result(store, key, deadline=deadline) == "Canonical answer é".encode()
        wait_for_execution_release(lambda remaining: command("session", "inspect", "--store", store,
                                   "--session", session, timeout=remaining)["execution"], deadline)
        assert not forbidden.exists(), "denied Bash was launched"
        replay = json.loads(endpoint.requests[1])["input"]
        assert replay[1:6] == first_items, replay
        assert replay[6:] == [
            {"type": "function_call_output", "call_id": "first-call", "output": "Permission denied."},
            {"type": "function_call_output", "call_id": "second-call", "output": "Unknown tool: missing-tool."},
        ], replay

        def public_messages():
            report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
            positions = [int(entry["position"]) for entry in report["full"]["conversation"]
                         if entry["kind"] == "assistant"]
            actual = []
            for position in positions:
                result = subprocess.run([str(RUI), "session", "read-conversation", "--store", str(store),
                    "--session", session, "--position", str(position), "--ordinal", "0"],
                    capture_output=True, timeout=10)
                assert result.returncode == 0, result.stderr
                actual.append(result.stdout.decode())
            assert actual == ["Inspecting files", "Checking sibling calls", "Waiting for tool results",
                              "Inspecting files", "Tools settled", "Canonical answer é"], actual
            return positions

        positions = public_messages()
        crash_host(host, state, f"{label}-saved")
        processes.remove(host)
        # The Host owns SQLite exclusively; inspect provenance only after reap.
        with sqlite3.connect(store / "rui.sqlite3") as database:
            rows = database.execute("SELECT e.session_position,e.source_item_ordinal,i.item_ordinal "
                "FROM conversation_entry e JOIN model_output_item i ON i.operation_id=e.source_operation_id "
                "AND i.item_ordinal=e.source_item_ordinal WHERE e.entry_kind=3 ORDER BY e.session_position").fetchall()
            call_positions = [row[0] for row in database.execute(
                "SELECT session_position FROM model_output_item WHERE item_kind=3 ORDER BY session_position")]
            assert rows[0][0] < call_positions[0] < rows[1][0] < call_positions[1] < rows[2][0], rows
            assert [row[1:] for row in rows] == [(0, 0), (2, 2), (4, 4), (0, 0), (1, 1), (2, 2)], rows
            assert [row[0] for row in rows] == positions, rows
        host = start_host(store, url)
        processes.append(host)
        assert read_result(store, key) == "Canonical answer é".encode()
        assert public_messages() == positions
        message(state, store, f"{label}-newer", session, "Continue after restart")
        wait_for(lambda: completed_observation(store, f"{label}-newer"), "newer answer")
        assert read_result(store, f"{label}-newer") == b"Newer answer"
        assert read_result(store, key) == "Canonical answer é".encode()
        restarted = json.loads(endpoint.requests[2])["input"]
        assert restarted[1:6] == first_items, restarted
        assert restarted[6:8] == replay[6:], restarted
        assert restarted[8:11] == final_items, restarted
        assert restarted[11] == {"role": "user", "content": [
            {"type": "input_text", "text": "Continue after restart"}]}, restarted
        stop_host(host)
        processes.remove(host)
        stop_endpoint(endpoint, endpoints)
    bad_items = [text_item("bad-prefix", "Never publish this prefix", "commentary"), calls[0],
                 text_item("bad-final-one", "First final", "final_answer"),
                 text_item("bad-final-two", "Second final", "final_answer")]
    endpoint = SuccessEndpoint([response("duplicate-finals", bad_items)])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoints[endpoint] = thread
    thread.start()
    store = state / "duplicate-finals-store"
    host = start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
    processes.append(host)
    session = configure(state, store, "duplicate-finals-config", None, "gpt-6-luna")
    message(state, store, "duplicate-finals", session, "Reject the complete candidate")
    failure = wait_for(lambda: (value := observe(store, "duplicate-finals")).get("result") and value,
                       "duplicate final rejection")
    assert failure["result"]["code"] == "malformed_provider_output", failure
    report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
    detail = json.loads(report["full"]["model_operations"][0]["resolution"]["content"]["text"])
    assert detail["reason"] == "MultipleFinalAnswers" and detail["stage"] == "response", detail
    stop_host(host)
    processes.remove(host)
    with sqlite3.connect(store / "rui.sqlite3") as database:
        for table in ("model_output_item", "model_tool_call", "action_operation"):
            assert database.execute(f"SELECT count(*) FROM {table}").fetchone() == (0,), table
        assert database.execute("SELECT count(*) FROM conversation_entry WHERE entry_kind=3").fetchone() == (0,)
    assert not forbidden.exists(), "malformed candidate launched Bash"
    stop_endpoint(endpoint, endpoints)
    print("Synthetic gpt-6-luna phase and unphased streams: exact replay, visible order, final result and crash recovery passed")


def main(mode="all", correlation_case="all"):
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-dispatch."))
    endpoint = FailureEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    processes = []
    endpoints = {endpoint: endpoint_thread}
    releases = [endpoint.release.set]
    success_endpoint = None
    success_thread = None
    proposal_endpoint = None
    proposal_thread = None
    continuation_endpoint = None
    continuation_thread = None
    proposal_milestones = None
    proposal_gate_keeper = None
    continuation_diagnostics = None
    completed = False
    try:
        if mode in ("all", "http-quota"):
            http_quota_cases(state, processes, endpoints)
            if mode == "http-quota":
                completed = True
                return
        if mode == "failure-correlation":
            failure_correlation_cases(state, processes, endpoints, correlation_case)
            completed = True
            return
        if mode in ("all", "stream-failures"):
            stream_failure_cases(state, processes, endpoints)
            if mode == "stream-failures":
                completed = True
                return
        if mode in ("all", "empty-answers"):
            empty_answer_cases(state, processes, endpoints)
            if mode == "empty-answers":
                completed = True
                return
        if mode in ("all", "refusals"):
            refusal_cases(state, processes, endpoints)
            if mode == "refusals":
                completed = True
                return
        if mode in ("all", "failed-response-export"):
            failed_response_export_case(state, processes, endpoints)
            if mode == "failed-response-export":
                completed = True
                return
        phased_message_cases(state, processes, endpoints)
        if mode == "phased-messages":
            completed = True
            return
        for status in (400, 200):
            empty_response_retention_case(state, processes, endpoints, status)
        endpoint_thread.start()
        compaction_cases(state, processes, endpoints, releases)
        forbidden_effect = state / "proposal-must-not-launch"
        calls = [
            ("bash", "call\nA", json.dumps({"cmd": f"touch {forbidden_effect}", "timeout_ms": None, "description": "Create forbidden effect marker"}, separators=(",", ":"))),
            ("other", "call-unknown", "{}"),
            ("bash", "call-invalid", "{"),
            ("bash", "call-B", json.dumps({"cmd": "printf second", "timeout_ms": None, "description": "Print second output"}, separators=(",", ":"))),
        ]
        race_calls = []
        race_responses = []
        for order in ("denial-first", "stop-first"):
            first_effect = state / f"{order}-first-must-not-launch"
            second_effect = state / f"{order}-second-must-not-launch"
            order_calls = [
                ("bash", f"{order}-call-0", json.dumps({"cmd": f"touch {first_effect}", "timeout_ms": None, "description": "Create first effect marker"}, separators=(",", ":"))),
                ("bash", f"{order}-call-1", json.dumps({"cmd": f"touch {second_effect}", "timeout_ms": None, "description": "Create second effect marker"}, separators=(",", ":"))),
            ]
            race_calls.append((order_calls, first_effect, second_effect))
            race_responses.append(sse_tool_calls(f"{order}-response", order_calls))
        proposal_endpoint = SuccessEndpoint([
            sse_tool_calls("proposal-response", calls),
            *race_responses,
        ])
        proposal_thread = threading.Thread(target=proposal_endpoint.serve_forever, daemon=True)
        endpoints[proposal_endpoint] = proposal_thread
        proposal_thread.start()
        proposal_url = f"http://127.0.0.1:{proposal_endpoint.server_port}/responses"
        proposal_store = state / "proposal-store"
        proposal_host = start_host(proposal_store, proposal_url)
        processes.append(proposal_host)
        proposal_session = configure(state, proposal_store, "proposal-config", None, "gpt-6-sol")
        message(state, proposal_store, "proposal-message", proposal_session, "propose mixed calls")
        proposal = wait_for(
            lambda: (value := command("session", "inspect", "--store", proposal_store, "--session", proposal_session, "--profile", "full"))["actions"]["unresolved"] and value,
            "complete exact Action collection",
        )
        assert proposal["actions"]["count"] == "2", proposal
        assert len(proposal["actions"]["unresolved"]) == 2, proposal
        rejected_calls = [
            call for call in proposal["full"]["tool_calls"] if call["rejection"] is not None
        ]
        assert len(rejected_calls) == 2, proposal
        assert rejected_calls[0]["call_ordinal"] == "1", proposal
        assert rejected_calls[0]["rejection"] == "unknown_tool", proposal
        first_request = proposal["actions"]["unresolved"][0]
        assert first_request["call_ordinal"] == "0", first_request
        assert read_action(proposal_store, proposal_session, first_request["action"], "call-id") == calls[0][1].encode()
        assert read_action(proposal_store, proposal_session, first_request["action"], "arguments") == calls[0][2].encode()
        second_before_denial = proposal["actions"]["unresolved"][1]
        assert second_before_denial["call_ordinal"] == "3", second_before_denial
        denied = subprocess.run(
            [
                str(RUI), "action", "deny", "--store", str(proposal_store),
                "--record", str(state / "proposal-denial.json"), "--key", "proposal-denial",
                "--session", proposal_session, "--action", first_request["action"],
                "--test-drop-reply", "after-commit",
            ],
            capture_output=True,
            timeout=15,
        )
        assert denied.returncode != 0, denied
        stop_host(proposal_host)
        processes.remove(proposal_host)
        control_gate = state / "proposal-control-gate"
        os.mkfifo(control_gate)
        # Keep both FIFO ends present so neither the Host reader nor fixture
        # writer can hang during open if its peer fails between milestones.
        proposal_gate_keeper = os.open(control_gate, os.O_RDWR | os.O_NONBLOCK)
        proposal_host = start_host(
            proposal_store,
            proposal_url,
            "--test-phase-trace",
            "--test-control-gate-keys",
            "denial-first-deny,stop-first-stop",
            "--test-control-gate-path",
            control_gate,
            observations="dispatch",
        )
        processes.append(proposal_host)
        proposal_milestones = HostDiagnostics(proposal_host)
        replay = command(
            "request", "recover", "--store", proposal_store, "--record", state / "proposal-denial.json",
            "--kind", "permission-decision",
        )
        assert replay["answer"]["status"] == "accepted" and replay["answer"]["replayed"] is True, replay
        recovered = command("session", "inspect", "--store", proposal_store, "--session", proposal_session, "--profile", "full")
        assert len([
            call for call in recovered["full"]["tool_calls"] if call["rejection"] is not None
        ]) == 2, recovered
        assert len(recovered["actions"]["unresolved"]) == 1, recovered
        assert read_action(proposal_store, proposal_session, first_request["action"], "call-id") == calls[0][1].encode()
        assert read_action(proposal_store, proposal_session, first_request["action"], "arguments") == calls[0][2].encode()
        # The Host holds its Store exclusively: canonical rows are checked
        # after it stops; later controls never touch these resolved rows.
        expected_action_rows = {}
        # Replay preserves canonical work; a live inspection may sample a
        # temporary no-work admission reservation before its owner releases it.
        assert recovered["work"]["status"] == "waiting_for_permission", recovered
        assert len(recovered["full"]["model_operations"]) == 1, recovered
        assert recovered["full"]["model_operations"][0]["resolution"]["code"] == "tool_proposals", recovered
        second = recovered["actions"]["unresolved"][0]
        assert second["call_ordinal"] == "3", second
        assert read_action(proposal_store, proposal_session, second["action"], "call-id") == calls[3][1].encode()
        assert read_action(proposal_store, proposal_session, second["action"], "arguments") == calls[3][2].encode()
        stopped = command(
            "session", "stop", "--store", proposal_store, "--record", state / "proposal-stop.json",
            "--key", "proposal-stop", "--session", proposal_session,
        )
        assert stopped["answer"]["status"] == "accepted", stopped
        stale = command(
            "action", "deny", "--store", proposal_store, "--record", state / "proposal-stale.json",
            "--key", "proposal-stale", "--session", proposal_session, "--action", second["action"],
            expect=1,
        )
        assert stale["answer"]["status"] == "rejected" and stale["answer"]["code"] == "action_not_pending", stale
        assert not forbidden_effect.exists()

        for index, order in enumerate(("denial-first", "stop-first")):
            order_calls, first_effect, second_effect = race_calls[index]
            session = configure(state, proposal_store, f"{order}-config", None, "gpt-6-sol")
            message(state, proposal_store, f"{order}-message", session, f"race {order}")
            before = wait_for(
                lambda: (lambda value: value if len(value["actions"]["unresolved"]) == 2 else None)(
                    command("session", "inspect", "--store", proposal_store, "--session", session)
                ),
                f"{order} Actions",
            )
            actions = before["actions"]["unresolved"]
            first_key = f"{order}-deny" if order == "denial-first" else f"{order}-stop"
            second_key = f"{order}-stop" if order == "denial-first" else f"{order}-deny"
            deny_args = (
                "action", "deny", "--store", proposal_store,
                "--record", state / f"{order}-deny.json", "--key", f"{order}-deny",
                "--session", session, "--action", actions[0]["action"],
            )
            stop_args = (
                "session", "stop", "--store", proposal_store,
                "--record", state / f"{order}-stop.json", "--key", f"{order}-stop",
                "--session", session,
            )
            first_process = start_command(*(deny_args if order == "denial-first" else stop_args))
            second_process = None
            try:
                first_lock = proposal_milestones.wait("control_lock_acquired", subject=first_key)[0]
                assert first_process.poll() is None, "first control did not remain held at the Store owner"
                second_phase = "connection_request_" + ("session_stop" if order == "denial-first" else "permission_decision")
                preceding = len(proposal_milestones.matching(second_phase))
                second_process = start_command(*(stop_args if order == "denial-first" else deny_args))
                routed = proposal_milestones.wait(second_phase, count=preceding + 1)
                assert len(routed) == preceding + 1, routed
                second_request = routed[-1]
                assert second_request["subject_kind"] == "request_number", second_request
                assert second_request["process"] == first_lock["process"] and second_request["run"] == first_lock["run"], second_request
                assert int(second_request["sequence"]) > int(first_lock["sequence"]), second_request
                assert second_process.poll() is None, "second control did not remain awaiting control service"
                with control_gate.open("wb", buffering=0) as release:
                    release.write(b"x")
                gate_release = proposal_milestones.wait("control_gate_released", subject=first_key)[0]
                first_result = finish_command(first_process)
                second_lock = proposal_milestones.wait("control_lock_acquired", subject=second_key)[0]
                second_result = finish_command(second_process, expect=1 if order == "stop-first" else 0)
                assert int(first_lock["at_ns"]) < int(second_request["at_ns"])
                assert int(second_request["at_ns"]) < int(gate_release["at_ns"])
                assert int(gate_release["at_ns"]) < int(second_lock["at_ns"])
            finally:
                dispose_all(
                    lambda: stop_process(first_process, timeout=5),
                    lambda: stop_process(second_process, timeout=5) if second_process is not None else None,
                )

            denial = first_result if order == "denial-first" else second_result
            stop = second_result if order == "denial-first" else first_result
            assert stop["answer"]["status"] == "accepted", stop
            if order == "denial-first":
                assert denial["answer"]["status"] == "accepted", denial
                expected_rows = [(0, 2, "denied"), (1, 0, "cancelled")]
            else:
                assert denial["answer"]["status"] == "rejected", denial
                assert denial["answer"]["code"] == "action_not_pending", denial
                expected_rows = [(0, 0, "cancelled"), (1, 0, "cancelled")]
            release_deadline = time.monotonic() + 8
            after = command("session", "inspect", "--store", proposal_store, "--session", session,
                            timeout=release_deadline - time.monotonic())
            assert after["actions"]["count"] == "0", after
            assert after["actions"]["unresolved"] == [], after
            assert after["actions"]["resolved"] == [], after
            assert after["rejected_calls"] == {"count": "0", "items": []}, after
            assert "bash_execution" not in after["execution"]["unavailable"], after
            wait_for_execution_release(
                lambda remaining: command(
                    "session", "inspect", "--store", proposal_store, "--session", session,
                    timeout=remaining,
                )["execution"],
                release_deadline,
            )
            expected_action_rows[session] = expected_rows
            for action, expected in zip(actions, order_calls):
                assert read_action(proposal_store, session, action["action"], "call-id") == expected[1].encode()
                assert read_action(proposal_store, session, action["action"], "arguments") == expected[2].encode()
            assert not first_effect.exists()
            assert not second_effect.exists()

        stop_host(proposal_host)
        processes.remove(proposal_host)
        with sqlite3.connect(proposal_store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT permission_state,resolution_code FROM action_operation WHERE action_id=?",
                (int(first_request["action"]),),
            ).fetchone() == (2, "denied")
            for session, expected_rows in expected_action_rows.items():
                rows = database.execute(
                    "SELECT call_ordinal,permission_state,resolution_code FROM action_operation "
                    "WHERE session_ref=? ORDER BY call_ordinal",
                    (session,),
                ).fetchall()
                assert rows == expected_rows, (session, rows)
                assert database.execute(
                    "SELECT outcome_code FROM turn WHERE session_ref=?", (session,)
                ).fetchone() == ("cancelled",)
        starts = [record for record in proposal_milestones.records
                  if record["rui_test_phase"].startswith("connection_request_")]
        assert [record["rui_test_phase"] for record in starts] == [
            "connection_request_permission_decision", "connection_request_session_stop",
            "connection_request_permission_decision", "connection_request_permission_decision",
            "connection_request_session_stop", "connection_request_session_stop",
            "connection_request_permission_decision"], starts
        assert all(record["subject_kind"] == "request_number" for record in starts), starts
        assert len({record["subject"] for record in starts}) == 7, starts
        proposal_milestones = None
        os.close(proposal_gate_keeper)
        proposal_gate_keeper = None

        continuation_calls = [
            ("bash", "continuation-call-0", json.dumps({"cmd": "printf zero", "timeout_ms": None, "description": "Print zero output"}, separators=(",", ":"))),
            ("missing-tool", "continuation-call-1", "{}"),
            ("bash", "continuation-call-2", "{"),
            ("bash", "continuation-call-3", json.dumps({"cmd": "printf three", "timeout_ms": None, "description": "Print three output"}, separators=(",", ":"))),
        ]
        continuation_answer = b"continued after complete tool results"
        continuation_sse, _, _ = sse_answer(
            "continuation-answer", "continuation-reasoning", "continuation-message", continuation_answer.decode()
        )
        queued_calls = [
            ("bash", "queued-call-0", json.dumps({"cmd": "printf queued", "timeout_ms": None, "description": "Print queued output"}, separators=(",", ":"))),
            ("missing-tool", "queued-call-1", "{}"),
        ]
        queued_answer = b"continued with queued input"
        queued_sse, _, _ = sse_answer(
            "queued-answer", "queued-reasoning", "queued-message", queued_answer.decode()
        )
        continuation_endpoint = SuccessEndpoint([
            sse_tool_calls("continuation-calls", continuation_calls),
            continuation_sse,
            sse_tool_calls("queued-calls", queued_calls),
            queued_sse,
        ])
        continuation_thread = threading.Thread(target=continuation_endpoint.serve_forever, daemon=True)
        endpoints[continuation_endpoint] = continuation_thread
        continuation_thread.start()
        continuation_store = state / "continuation-store"
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
        )
        processes.append(continuation_host)
        continuation_session = configure(state, continuation_store, "continuation-config", None, "gpt-6-sol")
        message(state, continuation_store, "continuation-first", continuation_session, "make calls")
        continuation_report = wait_for(
            lambda: (lambda value: value if len(value["actions"]["unresolved"]) == 2 else None)(
                command("session", "inspect", "--store", continuation_store, "--session", continuation_session)
            ),
            "continuation Actions",
        )
        continuation_actions = continuation_report["actions"]["unresolved"]
        stop_host(continuation_host)
        processes.remove(continuation_host)
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
            active_capacity=0,
        )
        processes.append(continuation_host)
        command(
            "action", "deny", "--store", continuation_store,
            "--record", state / "continuation-deny-3.json", "--key", "continuation-deny-3",
            "--session", continuation_session, "--action", continuation_actions[1]["action"],
        )
        partial_results = command(
            "session", "inspect", "--store", continuation_store, "--session", continuation_session
        )
        assert len(partial_results["actions"]["unresolved"]) == 1, partial_results
        assert len(partial_results["actions"]["resolved"]) == 1, partial_results
        assert partial_results["actions"]["resolved"][0]["call_ordinal"] == "3", partial_results
        assert partial_results["actions"]["resolved"][0]["code"] == "denied", partial_results
        assert int(partial_results["actions"]["resolved"][0]["acceptance_position"]) > 0
        assert all(int(call["acceptance_position"]) > 0 for call in partial_results["rejected_calls"]["items"])
        assert len(continuation_endpoint.requests) == 1, continuation_endpoint.requests
        stop_host(continuation_host)
        processes.remove(continuation_host)
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
            active_capacity=0,
        )
        processes.append(continuation_host)
        command(
            "action", "deny", "--store", continuation_store,
            "--record", state / "continuation-deny-0.json", "--key", "continuation-deny-0",
            "--session", continuation_session, "--action", continuation_actions[0]["action"],
        )
        complete_results = command(
            "session", "inspect", "--store", continuation_store, "--session", continuation_session
        )
        assert complete_results["actions"]["unresolved"] == [], complete_results
        assert [item["call_ordinal"] for item in complete_results["actions"]["resolved"]] == ["0", "3"]
        assert len(continuation_endpoint.requests) == 1, continuation_endpoint.requests
        continuation_first_processing = observe(continuation_store, "continuation-first")["processing"]
        continuation_before_admission_crash = crash_host(
            continuation_host, state, "continuation-before-admission-crash"
        )
        processes.remove(continuation_host)
        assert continuation_before_admission_crash["returncode"] == -signal.SIGKILL
        with sqlite3.connect(continuation_store / "rui.sqlite3") as database:
            assert database.execute("SELECT count(*) FROM model_operation").fetchone() == (1,)
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
            "--test-before-launch-delay-ms",
            "5000",
        )
        processes.append(continuation_host)
        continuation_diagnostics = HostDiagnostics(continuation_host)
        continuation_deadline = time.monotonic() + 8

        def continuation_successor_admitted():
            # Observe through the Store owner. An external SQLite reader can
            # prevent admission COMMIT in DELETE-journal/zero-busy-timeout mode.
            value = observe(continuation_store, "continuation-first", deadline=continuation_deadline)
            return (
                value
                if value.get("queue", {}).get("status") == "processing"
                and value.get("processing") == {
                    "turn": continuation_first_processing["turn"], "operation": "2", "attempt": "1",
                }
                else None
            )

        wait_for(continuation_successor_admitted, "tool-result successor admission", deadline=continuation_deadline)
        assert len(continuation_endpoint.requests) == 1, continuation_endpoint.requests
        continuation_after_admission_crash = crash_host(
            continuation_host, state, "continuation-after-admission-crash", diagnostics=continuation_diagnostics
        )
        continuation_diagnostics = None
        processes.remove(continuation_host)
        assert continuation_after_admission_crash["returncode"] == -signal.SIGKILL
        with sqlite3.connect(continuation_store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT operation_id,attempt_ordinal,uncertain,resolution_code "
                "FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(1, 1, 0, "tool_proposals"), (2, 1, 1, None)]

        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
        )
        processes.append(continuation_host)
        wait_for(lambda: len(continuation_endpoint.requests) == 2, "recovered tool-result continuation request")
        wait_for(
            lambda: completed_observation(continuation_store, "continuation-first"),
            "tool-result continuation answer",
        )
        assert read_result(continuation_store, "continuation-first") == continuation_answer
        continuation_request = json.loads(continuation_endpoint.requests[1])
        continuation_input = continuation_request["input"]
        output_items = [item for item in continuation_input if item.get("type") == "function_call_output"]
        assert [item["call_id"] for item in output_items] == [call[1] for call in continuation_calls], output_items
        assert [item["output"] for item in output_items] == [
            "Permission denied.",
            "Unknown tool: missing-tool.",
            "Invalid arguments for tool 'bash'.",
            "Permission denied.",
        ], output_items
        assert [
            item.get("content", [{}])[0].get("text")
            for item in continuation_input
            if item.get("role") == "user"
        ] == ["make calls"], continuation_input
        replayed_denial = command(
            "request", "recover", "--store", continuation_store,
            "--record", state / "continuation-deny-0.json",
            "--kind", "permission-decision",
        )
        assert replayed_denial["answer"]["status"] == "accepted", replayed_denial
        assert replayed_denial["answer"]["replayed"] is True, replayed_denial
        stale_denial = command(
            "action", "deny", "--store", continuation_store,
            "--record", state / "continuation-stale-denial.json",
            "--key", "continuation-stale-denial", "--session", continuation_session,
            "--action", continuation_actions[0]["action"],
            expect=1,
        )
        assert stale_denial["answer"]["status"] == "rejected", stale_denial
        assert stale_denial["answer"]["code"] == "action_not_pending", stale_denial
        # The Host holds its Store exclusively; inspect rows between Hosts.
        stop_host(continuation_host)
        processes.remove(continuation_host)
        with sqlite3.connect(continuation_store / "rui.sqlite3") as database:
            assert database.execute("SELECT count(*) FROM model_operation").fetchone() == (2,)
            assert database.execute(
                "SELECT attempt_ordinal FROM model_operation WHERE operation_id=2"
            ).fetchone() == (2,)
            assert database.execute(
                "SELECT count(*),count(DISTINCT acceptance_position) FROM model_tool_call "
                "WHERE rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL "
                "AND acceptance_position IS NOT NULL"
            ).fetchone() == (2, 2)
            assert database.execute(
                "SELECT count(*),count(DISTINCT acceptance_position) FROM action_operation "
                "WHERE resolution_code='denied' AND resolution_content_id IS NOT NULL "
                "AND acceptance_position IS NOT NULL"
            ).fetchone() == (2, 2)
            assert database.execute(
                "SELECT count(*) FROM sqlite_schema WHERE name LIKE '%tool_result%'"
            ).fetchone() == (0,)
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
        )
        processes.append(continuation_host)

        queued_continuation_session = configure(state, continuation_store, "queued-config", None, "gpt-6-sol")
        message(
            state,
            continuation_store,
            "queued-first",
            queued_continuation_session,
            "make queued calls",
        )
        queued_report = wait_for(
            lambda: (lambda value: value if len(value["actions"]["unresolved"]) == 1 else None)(
                command(
                    "session", "inspect",
                    "--store",
                    continuation_store,
                    "--session",
                    queued_continuation_session,
                )
            ),
            "queued-input continuation Action",
        )
        queued_action = queued_report["actions"]["unresolved"][0]
        stop_host(continuation_host)
        processes.remove(continuation_host)
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
            active_capacity=0,
        )
        processes.append(continuation_host)
        message(
            state,
            continuation_store,
            "queued-second",
            queued_continuation_session,
            "input queued during tool wait",
        )
        command(
            "action", "deny",
            "--store",
            continuation_store,
            "--record",
            state / "queued-denial.json",
            "--key",
            "queued-denial",
            "--session",
            queued_continuation_session,
            "--action",
            queued_action["action"],
        )
        assert len(continuation_endpoint.requests) == 3, continuation_endpoint.requests
        stop_host(continuation_host)
        processes.remove(continuation_host)
        continuation_host = start_host(
            continuation_store,
            f"http://127.0.0.1:{continuation_endpoint.server_port}/responses",
        )
        processes.append(continuation_host)
        wait_for(lambda: len(continuation_endpoint.requests) == 4, "queued-input continuation request")
        wait_for(
            lambda: completed_observation(continuation_store, "queued-second"),
            "queued-input continuation answer",
        )
        assert read_result(continuation_store, "queued-first") == queued_answer
        assert read_result(continuation_store, "queued-second") == queued_answer
        queued_input = json.loads(continuation_endpoint.requests[3])["input"]
        queued_outputs = [item for item in queued_input if item.get("type") == "function_call_output"]
        assert [item["call_id"] for item in queued_outputs] == [call[1] for call in queued_calls], queued_outputs
        assert [item["output"] for item in queued_outputs] == [
            "Permission denied.",
            "Unknown tool: missing-tool.",
        ], queued_outputs
        relevant_input = [
            ("output", item["call_id"])
            if item.get("type") == "function_call_output"
            else ("user", item.get("content", [{}])[0].get("text"))
            for item in queued_input
            if item.get("type") == "function_call_output" or item.get("role") == "user"
        ]
        assert relevant_input == [
            ("user", "make queued calls"),
            ("output", "queued-call-0"),
            ("output", "queued-call-1"),
            ("user", "input queued during tool wait"),
        ], relevant_input
        stop_host(continuation_host)
        processes.remove(continuation_host)

        first_answer = 'First "answer"\n🙂'.encode()
        second_answer = ("second answer " + "x" * 5000).encode()
        first_sse, first_reasoning, first_message_item = sse_answer(
            "response-1",
            "reasoning-1",
            "message-1",
            first_answer.decode(),
            # Small retained/discarded fields keep the native replay witness
            # (response-only `created_by` omission in the follow-up request).
            # Large-field boundaries now live in the portable cursor corpus.
            encrypted_content="r" * 64,
            created_by="d" * 64,
        )
        second_sse, second_reasoning, second_message_item = sse_answer(
            "response-2", "reasoning-2", "message-2", second_answer.decode()
        )
        success_endpoint = SuccessEndpoint([first_sse, second_sse])
        success_thread = threading.Thread(target=success_endpoint.serve_forever, daemon=True)
        endpoints[success_endpoint] = success_thread
        success_thread.start()
        success_url = f"http://127.0.0.1:{success_endpoint.server_port}/responses"
        success_store = state / "success-store"
        success_host = start_host(success_store, success_url)
        processes.append(success_host)
        configure_lost_reply(
            state, success_store, "success-config", None, "gpt-6-sol"
        )
        stop_host(success_host)
        processes.remove(success_host)

        success_host = start_host(success_store, success_url)
        processes.append(success_host)
        recovered_configuration = command(
            "request", "recover",
            "--store",
            success_store,
            "--record",
            state / "success-config.json",
            "--kind",
            "configure",
        )
        assert recovered_configuration["answer"]["status"] == "accepted", recovered_configuration
        assert recovered_configuration["answer"]["replayed"] is True, recovered_configuration
        success_session = recovered_configuration["answer"]["session"]
        command(
            "session", "configure",
            "--store",
            success_store,
            "--record",
            state / "success-tools.json",
            "--key",
            "success-tools",
            "--session",
            success_session,
            "--tools",
            "none",
        )
        message_lost_reply(
            state, success_store, "success-first", success_session, "first question"
        )
        first_complete = wait_for(
            lambda: completed_observation(success_store, "success-first"),
            "first complete model answer",
        )
        assert first_complete["queue"]["status"] == "completed", first_complete
        assert read_result(success_store, "success-first") == first_answer
        assert hashlib.sha256(read_result(success_store, "success-first")).digest() == hashlib.sha256(
            first_answer
        ).digest()
        stop_host(success_host)
        processes.remove(success_host)

        # A fresh Host and client recover the original admission and answer,
        # then the same Session completes another Turn from the historical
        # provider view. One-byte encoding and replay progress are covered by
        # the portable cursor corpus and real-Store preparation cases, so this
        # restart uses production allowances and witnesses recovery/handoff.
        success_host = start_host(
            success_store,
            success_url,
        )
        processes.append(success_host)
        recovered_first = command(
            "request", "recover",
            "--store",
            success_store,
            "--record",
            state / "success-first.json",
            "--kind",
            "message",
        )
        assert recovered_first["answer"]["status"] == "accepted", recovered_first
        assert recovered_first["answer"]["replayed"] is True, recovered_first
        assert read_result(success_store, "success-first") == first_answer
        before_model_change = command(
            "session", "inspect", "--store", success_store, "--session", success_session
        )["session"]
        incompatible_args = (
            "session", "configure",
            "--store",
            success_store,
            "--record",
            state / "incompatible-model.json",
            "--key",
            "incompatible-model",
            "--session",
            success_session,
            "--model",
            "gpt-6.1-sol",
            "--tools",
            "bash",
        )
        incompatible = command(*incompatible_args, expect=1)
        assert incompatible["answer"]["status"] == "rejected", incompatible
        assert incompatible["answer"]["code"] == "model_is_immutable", incompatible
        replayed_incompatible = command(
            "request", "recover",
            "--store",
            success_store,
            "--record",
            state / "incompatible-model.json",
            "--kind",
            "configure",
            expect=1,
        )
        assert replayed_incompatible["answer"]["status"] == "rejected", replayed_incompatible
        assert replayed_incompatible["answer"]["replayed"] is True, replayed_incompatible
        after_model_change = command(
            "session", "inspect", "--store", success_store, "--session", success_session
        )["session"]
        assert after_model_change["model"] == "gpt-6-sol", after_model_change
        assert after_model_change["revision"] == before_model_change["revision"], (
            before_model_change,
            after_model_change,
        )
        message_lost_reply(
            state, success_store, "success-second", success_session, "second question"
        )
        wait_for(
            lambda: completed_observation(success_store, "success-second"),
            "second complete model answer",
        )
        assert read_result(success_store, "success-first") == first_answer
        assert read_result(success_store, "success-second") == second_answer
        wait_for(lambda: len(success_endpoint.requests) == 2, "two successful requests")
        first_request = json.loads(success_endpoint.requests[0])
        second_request = json.loads(success_endpoint.requests[1])
        assert first_request["instructions"] == second_request["instructions"] == model_instructions(ROOT, store=success_store, session=success_session)
        assert first_request["input"] == [
            {"role": "user", "content": [{"type": "input_text", "text": "first question"}]},
        ]
        expected_reasoning = dict(first_reasoning)
        expected_reasoning.pop("created_by")
        assert second_request["input"] == [
            {"role": "user", "content": [{"type": "input_text", "text": "first question"}]},
            expected_reasoning,
            first_message_item,
            {"role": "user", "content": [{"type": "input_text", "text": "second question"}]},
        ], second_request["input"]
        stop_host(success_host)
        processes.remove(success_host)

        success_host = start_host(success_store, success_url)
        processes.append(success_host)
        recovered_second = command(
            "request", "recover",
            "--store",
            success_store,
            "--record",
            state / "success-second.json",
            "--kind",
            "message",
        )
        assert recovered_second["answer"]["status"] == "accepted", recovered_second
        assert recovered_second["answer"]["replayed"] is True, recovered_second
        assert read_result(success_store, "success-first") == first_answer
        assert read_result(success_store, "success-second") == second_answer
        assert hashlib.sha256(read_result(success_store, "success-second")).digest() == hashlib.sha256(
            second_answer
        ).digest()
        assert len(success_endpoint.requests) == 2
        stop_host(success_host)
        processes.remove(success_host)

        database = sqlite3.connect(success_store / "rui.sqlite3")
        try:
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 4
            assert database.execute(
                "SELECT count(*) FROM model_output_item item JOIN content c ON c.content_id=item.content_id WHERE c.private=1"
            ).fetchone()[0] == 4
            assert database.execute(
                "SELECT attempt_ordinal,count(*) FROM model_output_item GROUP BY attempt_ordinal"
            ).fetchall() == [(1, 4)]
            raw_reasoning = database.execute(
                "SELECT CAST(c.payload AS TEXT) FROM model_output_item item JOIN content c ON c.content_id=item.content_id ORDER BY item.operation_id,item.item_ordinal LIMIT 1"
            ).fetchone()[0]
            assert json.loads(raw_reasoning)["created_by"] == "d" * 64
            observations = database.execute(
                "SELECT response_id,model_evidence,request_id,resolution_code,usage_content_id IS NOT NULL FROM model_operation ORDER BY operation_id"
            ).fetchall()
            assert [(row[0], *decode_model_evidence(row[1]), *row[2:]) for row in observations] == [
                (
                    "response-1",
                    "model-a-served",
                    "model-a-served",
                    None,
                    "request-1",
                    "answer",
                    1,
                ),
                (
                    "response-2",
                    "model-a-served",
                    "model-a-served",
                    None,
                    "request-2",
                    "answer",
                    1,
                ),
            ]
            saved_usage = database.execute(
                "SELECT CAST(c.payload AS TEXT) FROM model_operation o JOIN content c ON c.content_id=o.usage_content_id ORDER BY o.operation_id"
            ).fetchall()
            assert [json.loads(row[0]) for row in saved_usage] == [
                {"input_tokens": 7, "output_tokens": 11, "total_tokens": 18},
                {"input_tokens": 7, "output_tokens": 11, "total_tokens": 18},
            ]
        finally:
            database.close()
        offline_success = start_host(success_store, None)
        processes.append(offline_success)
        assert read_result(success_store, "success-first") == first_answer
        assert read_result(success_store, "success-second") == second_answer
        stop_host(offline_success)
        processes.remove(offline_success)

        # Temporary transport classes consume one shared per-Operation
        # allowance. Retry-After may lengthen, never shorten, the frozen
        # 2/4/8 policy (shortened here only to keep the fixture deterministic).
        retry_sse, retry_reasoning, retry_message_item = sse_answer(
            "retry-response", "retry-reasoning", "retry-message-item", "recovered answer"
        )
        retry_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"temporary server failure", {"Retry-After": "0"}, 503),
                ResponseSpec(b"rate limited", {"Retry-After": "1"}, 429),
                retry_sse,
            ]
        )
        retry_thread = threading.Thread(target=retry_endpoint.serve_forever, daemon=True)
        endpoints[retry_endpoint] = retry_thread
        retry_thread.start()
        retry_store = state / "retry-store"
        retry_host = start_host(
            retry_store,
            f"http://127.0.0.1:{retry_endpoint.server_port}/responses",
        )
        processes.append(retry_host)
        retry_session = configure(state, retry_store, "retry-config", None, "gpt-6-sol")
        message(state, retry_store, "retry-message", retry_session, "retry exactly")
        retry_complete = wait_for(
            lambda: completed_observation(retry_store, "retry-message"),
            "temporary failures followed by saved answer",
            timeout=8,
        )
        assert retry_complete["processing"]["attempt"] == "3", retry_complete
        assert read_result(retry_store, "retry-message") == b"recovered answer"
        assert len(retry_endpoint.requests) == 3
        assert retry_endpoint.request_times[1] - retry_endpoint.request_times[0] >= 0.04
        assert retry_endpoint.request_times[2] - retry_endpoint.request_times[1] >= 0.90
        assert retry_endpoint.requests[0] == retry_endpoint.requests[1]
        assert retry_endpoint.requests[1] == retry_endpoint.requests[2]
        assert json.loads(retry_endpoint.requests[0])["instructions"] == model_instructions(ROOT, store=retry_store, session=retry_session)
        stop_host(retry_host)
        processes.remove(retry_host)
        database = sqlite3.connect(retry_store / "rui.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code FROM model_operation"
        ).fetchone() == (
            3,
            3,
            0,
            None,
            "provider_temporary_http_429",
            "answer",
        )
        database.close()
        stop_endpoint(retry_endpoint, endpoints)

        # A date four seconds ahead expires during five seconds of progressing
        # error-body transfer. It must not add the original delay again.
        dated_failure = ResponseSpec(
            b"123456789012345678", {}, 503,
            retry_date_seconds=4, chunk_delay=1,
        )
        dated_endpoint = SuccessEndpoint([dated_failure, retry_sse])
        dated_thread = threading.Thread(target=dated_endpoint.serve_forever, daemon=True)
        endpoints[dated_endpoint] = dated_thread
        dated_thread.start()
        dated_store = state / "dated-retry-store"
        dated_host = start_host(dated_store, f"http://127.0.0.1:{dated_endpoint.server_port}/responses")
        processes.append(dated_host)
        dated_session = configure(state, dated_store, "dated-config", None, "gpt-6-sol")
        message(state, dated_store, "dated-message", dated_session, "retry date")
        dated_complete = wait_for(
            lambda: completed_observation(dated_store, "dated-message"),
            "expired Retry-After date after progressing body", timeout=12,
        )
        assert dated_complete["processing"]["attempt"] == "2", dated_complete
        assert read_result(dated_store, "dated-message") == b"recovered answer"
        assert len(dated_endpoint.requests) == 2
        assert dated_endpoint.requests[0] == dated_endpoint.requests[1]
        # Allows the one-second discovery tick; the old conversion adds at
        # least three seconds after the body and cannot pass this bound.
        assert dated_failure.body_finished_at is not None
        after_body = dated_endpoint.request_times[1] - dated_failure.body_finished_at
        assert 0.04 <= after_body < 2.5, after_body
        stop_host(dated_host)
        processes.remove(dated_host)
        stop_endpoint(dated_endpoint, endpoints)

        # A permanent request/authentication-class HTTP failure is terminal
        # after one Attempt and is never blindly retried. It keeps the
        # provider's own request correlation, or none, through restart.
        permanent_request_ids = ('permanent-"quoted"\\request', None)
        permanent_endpoint = SuccessEndpoint([
            ResponseSpec(b"authentication rejected", {"X-Request-Id": request_id} if request_id else {}, 401)
            for request_id in permanent_request_ids
        ])
        permanent_thread = threading.Thread(
            target=permanent_endpoint.serve_forever, daemon=True
        )
        endpoints[permanent_endpoint] = permanent_thread
        permanent_thread.start()
        for index, request_id in enumerate(permanent_request_ids):
            permanent_store = state / f"permanent-store-{index}"
            permanent_host = start_host(
                permanent_store,
                f"http://127.0.0.1:{permanent_endpoint.server_port}/responses",
            )
            processes.append(permanent_host)
            permanent_session = configure(
                state, permanent_store, f"permanent-config-{index}", None, "gpt-6-sol"
            )
            message(
                state,
                permanent_store,
                f"permanent-message-{index}",
                permanent_session,
                "do not retry",
            )
            permanent_failure = wait_for(
                lambda: (
                    value := observe(permanent_store, f"permanent-message-{index}")
                ).get("result", {}).get("code")
                and value,
                "permanent provider failure",
            )
            assert permanent_failure["result"]["code"] == "provider_http_401"
            time.sleep(1.2)
            assert len(permanent_endpoint.requests) == index + 1
            stop_host(permanent_host)
            processes.remove(permanent_host)
            with sqlite3.connect(permanent_store / "rui.sqlite3") as database:
                assert database.execute(
                    "SELECT resolution_code,resolution_content_id,request_id FROM model_operation"
                ).fetchone() == ("provider_http_401", None, request_id)
            reopened = start_host(permanent_store, None)
            processes.append(reopened)
            report = command(
                "session", "inspect", "--store", permanent_store,
                "--session", permanent_session, "--profile", "full",
            )
            operation = report["full"]["model_operations"][0]
            assert operation["request_id"] == request_id, operation
            assert operation["resolution"]["code"] == "provider_http_401", operation
            assert operation["resolution"]["content"] is None, operation
            assert observe(permanent_store, f"permanent-message-{index}")["result"] == permanent_failure["result"]
            assert len(permanent_endpoint.requests) == index + 1
            stop_host(reopened)
            processes.remove(reopened)
        stop_endpoint(permanent_endpoint, endpoints)

        # Redirects are disabled and contradictory provider headers are
        # deterministic response failures. Neither is a connection retry.
        invalid_header_sse = sse_answer(
            "invalid-header-response",
            "invalid-header-reasoning",
            "invalid-header-message",
            "must not publish",
        )[0]
        disposition_cases = (
            ("redirect", ResponseSpec(b"", {}, 302), "provider_http_302"),
            (
                "invalid-headers",
                ResponseSpec(
                    invalid_header_sse,
                    [("OpenAI-Model", "served-a"), ("OpenAI-Model", "served-b")],
                ),
                "invalid_provider_headers",
            ),
        )
        disposition_endpoint = SuccessEndpoint([case[1] for case in disposition_cases])
        disposition_thread = threading.Thread(
            target=disposition_endpoint.serve_forever, daemon=True
        )
        endpoints[disposition_endpoint] = disposition_thread
        disposition_thread.start()
        for case_index, (name, _, expected_code) in enumerate(disposition_cases, 1):
            disposition_store = state / f"{name}-store"
            disposition_host = start_host(
                disposition_store,
                f"http://127.0.0.1:{disposition_endpoint.server_port}/responses",
            )
            processes.append(disposition_host)
            session = configure(
                state,
                disposition_store,
                f"{name}-config",
                None,
                "gpt-6-sol",
            )
            message(
                state,
                disposition_store,
                f"{name}-message",
                session,
                "do not retry deterministic transport evidence",
            )
            failure = wait_for(
                lambda store=disposition_store, key=f"{name}-message": (
                    value := observe(store, key)
                ).get("result", {}).get("code")
                and value,
                f"{name} permanent disposition",
            )
            assert failure["result"]["code"] == expected_code, failure
            assert failure["processing"]["attempt"] == "1", failure
            time.sleep(0.3)
            assert len(disposition_endpoint.requests) == case_index
            stop_host(disposition_host)
            processes.remove(disposition_host)
        stop_endpoint(disposition_endpoint, endpoints)

        # A local read failure while curl owns the request is a Host fault,
        # not provider evidence. Fence dispatch, retain uncertainty and avoid
        # a same-process retry.
        local_read_endpoint = SuccessEndpoint(
            [sse_answer("local-read", "local-read-r", "local-read-m", "unused")[0]]
        )
        local_read_thread = threading.Thread(
            target=local_read_endpoint.serve_forever, daemon=True
        )
        endpoints[local_read_endpoint] = local_read_thread
        local_read_thread.start()
        local_read_store = state / "local-read-store"
        local_read_host = start_host(
            local_read_store,
            f"http://127.0.0.1:{local_read_endpoint.server_port}/responses",
            "--fault",
            "request-read",
        )
        processes.append(local_read_host)
        local_read_session = configure(
            state,
            local_read_store,
            "local-read-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            local_read_store,
            "local-read-message",
            local_read_session,
            "fence local scratch failure",
        )
        wait_for(
            lambda: local_read_host.poll() is not None,
            "local request-read fenced shutdown",
        )
        assert local_read_host.returncode != 0
        stop_host(local_read_host)
        processes.remove(local_read_host)
        database = sqlite3.connect(local_read_store / "rui.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,allowance_used,uncertain,resolution_code FROM model_operation"
        ).fetchone() == (1, 1, 1, None)
        database.close()
        assert len(local_read_endpoint.requests) <= 1
        stop_endpoint(local_read_endpoint, endpoints)

        # Completion identity is recovered only after the fixed slot owner
        # matches curl's native handle. Missing, foreign and mismatched private
        # pointers fence safely; the reactor removes the owned handle once, and
        # shutdown still closes its transfer scratch and releases custody.
        identity_endpoint = SuccessEndpoint(
            [
                sse_answer(
                    f"identity-{index}",
                    f"identity-r-{index}",
                    f"identity-m-{index}",
                    "must not publish",
                )[0]
                for index in range(3)
            ]
        )
        identity_thread = threading.Thread(
            target=identity_endpoint.serve_forever, daemon=True
        )
        endpoints[identity_endpoint] = identity_thread
        identity_thread.start()
        for index, (fault, expected_error) in enumerate(
            (
                ("completion-private-missing", "MissingTransportCompletionIdentity"),
                ("completion-private-foreign", "MismatchedTransportCompletionIdentity"),
                ("completion-private-mismatch", "MismatchedTransportCompletionIdentity"),
            )
        ):
            identity_store = state / f"{fault}-store"
            identity_host = start_host(
                identity_store,
                f"http://127.0.0.1:{identity_endpoint.server_port}/responses",
                "--fault",
                fault,
            )
            processes.append(identity_host)
            session = configure(
                state,
                identity_store,
                f"{fault}-config",
                None,
                "gpt-6-sol",
            )
            message(
                state,
                identity_store,
                f"{fault}-message",
                session,
                fault,
            )
            wait_for(
                lambda process=identity_host: process.poll() is not None,
                f"{fault} fenced shutdown",
            )
            assert identity_host.returncode == 1, identity_host.returncode
            stderr = identity_host.stderr.read()
            assert expected_error.encode() in stderr, stderr
            stop_host(identity_host)
            processes.remove(identity_host)
            assert len(identity_endpoint.requests) == index + 1
            database = sqlite3.connect(identity_store / "rui.sqlite3")
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used,uncertain,resolution_code FROM model_operation"
            ).fetchone() == (1, 1, 1, None)
            database.close()

            offline = start_host(identity_store, None)
            processes.append(offline)
            observation = observe(identity_store, f"{fault}-message")
            assert observation["queue"]["status"] == "processing", observation
            assert observation["processing"]["attempt"] == "1", observation
            assert "result" not in observation, observation
            resources = command(
                "session", "inspect",
                "--store",
                identity_store,
                "--session",
                session,
            )["execution"]
            assert resources["scratch_used_bytes"] == "0", resources
            stop_host(offline)
            processes.remove(offline)
        stop_endpoint(identity_endpoint, endpoints)

        # A replacement Attempt reuses the exact historical view, including
        # private continuation, even after newer settings and input commit.
        continued_first, continued_reasoning, continued_message = sse_answer(
            "continued-first", "continued-r-1", "continued-m-1", "first answer"
        )
        continued_retry, _, _ = sse_answer(
            "continued-retry", "continued-r-2", "continued-m-2", "second answer"
        )
        continued_later, _, _ = sse_answer(
            "continued-later", "continued-r-3", "continued-m-3", "later answer"
        )
        continued_retry_release = threading.Event()
        releases.append(continued_retry_release.set)
        continued_endpoint = SuccessEndpoint(
            [
                continued_first,
                (ResponseSpec(b"temporary", {}, 503), continued_retry_release),
                continued_retry,
                continued_later,
            ]
        )
        continued_thread = threading.Thread(
            target=continued_endpoint.serve_forever, daemon=True
        )
        endpoints[continued_endpoint] = continued_thread
        continued_thread.start()
        continued_store = state / "continued-retry-store"
        continued_host = start_host(
            continued_store,
            f"http://127.0.0.1:{continued_endpoint.server_port}/responses",
        )
        processes.append(continued_host)
        continued_retry_session = configure(
            state,
            continued_store,
            "continued-config",
            None,
            "gpt-6-sol",
            instructions="original instructions",
        )
        message(
            state,
            continued_store,
            "continued-first-message",
            continued_retry_session,
            "first input",
        )
        wait_for(
            lambda: completed_observation(continued_store, "continued-first-message"),
            "first continuation source",
        )
        message(
            state,
            continued_store,
            "continued-second-message",
            continued_retry_session,
            "historical retry input",
        )
        wait_for(lambda: len(continued_endpoint.requests) >= 2, "first continued Attempt")
        configure(
            state,
            continued_store,
            "continued-new-instructions",
            continued_retry_session,
            "gpt-6-sol",
            instructions="new instructions",
        )
        message(
            state,
            continued_store,
            "continued-later-message",
            continued_retry_session,
            "unselected later input",
        )
        continued_retry_release.set()
        wait_for(lambda: len(continued_endpoint.requests) >= 3, "replacement continued Attempt")
        assert continued_endpoint.requests[1] == continued_endpoint.requests[2]
        frozen_retry = json.loads(continued_endpoint.requests[2])
        # Later settings cannot re-address or re-baseline the replacement Attempt.
        assert frozen_retry["instructions"] == model_instructions(
            ROOT, "original instructions", store=continued_store, session=continued_retry_session
        ), frozen_retry
        expected_private = dict(continued_reasoning)
        expected_private.pop("created_by")
        assert expected_private in frozen_retry["input"], frozen_retry["input"]
        assert continued_message in frozen_retry["input"], frozen_retry["input"]
        assert not any(
            item.get("role") == "developer"
            and item.get("content", [{}])[0].get("text") == "new instructions"
            for item in frozen_retry["input"]
        )
        wait_for(
            lambda: completed_observation(continued_store, "continued-later-message"),
            "later input successor Turn boundary",
        )
        assert read_result(continued_store, "continued-second-message") == b"later answer"
        assert read_result(continued_store, "continued-later-message") == b"later answer"
        assert len(continued_endpoint.requests) == 4
        stop_host(continued_host)
        processes.remove(continued_host)
        stop_endpoint(continued_endpoint, endpoints)

        evidence_cases = (
            ("body-only", "model-a-served", {}, ("model-a-served", None, None, None)),
            (
                "openai-only",
                None,
                {"OpenAI-Model": "model-a-served"},
                (None, "model-a-served", None, None),
            ),
            (
                "x-openai-only",
                None,
                {"X-OpenAI-Model": "model-a-served"},
                (None, None, "model-a-served", None),
            ),
            (
                "all-sources",
                "model-a-served",
                {
                    "OpenAI-Model": "model-a-served",
                    "X-OpenAI-Model": "model-a-served",
                    "X-Request-Id": "all-sources-request",
                },
                (
                    "model-a-served",
                    "model-a-served",
                    "model-a-served",
                    "all-sources-request",
                ),
            ),
            ("absent", None, {}, (None, None, None, None)),
        )
        evidence_endpoint = SuccessEndpoint(
            [
                ResponseSpec(
                    sse_answer(
                        f"evidence-{name}",
                        f"evidence-{name}-reasoning",
                        f"evidence-{name}-message",
                        f"answer-{name}",
                        served_model=body_model,
                    )[0],
                    headers,
                )
                for name, body_model, headers, _ in evidence_cases
            ]
        )
        evidence_thread = threading.Thread(target=evidence_endpoint.serve_forever, daemon=True)
        endpoints[evidence_endpoint] = evidence_thread
        evidence_thread.start()
        evidence_url = f"http://127.0.0.1:{evidence_endpoint.server_port}/responses"
        for name, _, _, expected_evidence in evidence_cases:
            evidence_store = state / f"evidence-{name}-store"
            evidence_host = start_host(evidence_store, evidence_url)
            processes.append(evidence_host)
            session = configure(state, evidence_store, f"evidence-{name}-config", None, "gpt-6-sol")
            message(
                state,
                evidence_store,
                f"evidence-{name}-message",
                session,
                "evidence",
            )
            wait_for(
                lambda key=f"evidence-{name}-message", store=evidence_store: completed_observation(store, key),
                f"{name} evidence completion",
            )
            stop_host(evidence_host)
            processes.remove(evidence_host)
            reopened = start_host(evidence_store, None)
            processes.append(reopened)
            assert read_result(evidence_store, f"evidence-{name}-message") == f"answer-{name}".encode()
            stop_host(reopened)
            processes.remove(reopened)
            database = sqlite3.connect(evidence_store / "rui.sqlite3")
            actual_evidence = database.execute(
                "SELECT model_evidence,request_id FROM model_operation"
            ).fetchone()
            database.close()
            actual_evidence = (*decode_model_evidence(actual_evidence[0]), actual_evidence[1])
            assert actual_evidence == expected_evidence, (name, actual_evidence, expected_evidence)
        stop_endpoint(evidence_endpoint, endpoints)

        contradictory_sse, _, _ = sse_answer(
            "contradictory-response",
            "contradictory-reasoning",
            "contradictory-message",
            "must not publish",
            served_model="model-body",
        )
        contradictory_request_id = 'contradictory-"quoted"\\path'
        contradictory_endpoint = SuccessEndpoint(
            [
                ResponseSpec(
                    contradictory_sse,
                    {
                        "OpenAI-Model": "model-openai-header",
                        "X-OpenAI-Model": "model-x-openai-header",
                        "X-Request-Id": contradictory_request_id,
                    },
                )
            ]
        )
        contradictory_thread = threading.Thread(
            target=contradictory_endpoint.serve_forever, daemon=True
        )
        endpoints[contradictory_endpoint] = contradictory_thread
        contradictory_thread.start()
        contradictory_store = state / "contradictory-evidence-store"
        contradictory_host = start_host(
            contradictory_store,
            f"http://127.0.0.1:{contradictory_endpoint.server_port}/responses",
        )
        processes.append(contradictory_host)
        contradictory_evidence_session = configure(
            state,
            contradictory_store,
            "contradictory-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            contradictory_store,
            "contradictory-message",
            contradictory_evidence_session,
            "contradictory evidence",
        )
        contradictory_failure = wait_for(
            lambda: (
                value := observe(contradictory_store, "contradictory-message")
            ).get("result", {}).get("code")
            and value,
            "contradictory model evidence failure",
        )
        assert contradictory_failure["queue"]["status"] == "failed", contradictory_failure
        assert (
            contradictory_failure["result"]["code"] == "contradictory_provider_output"
        ), contradictory_failure
        assert len(contradictory_endpoint.requests) == 1
        stop_host(contradictory_host)
        processes.remove(contradictory_host)
        database = sqlite3.connect(contradictory_store / "rui.sqlite3")
        assert database.execute(
            "SELECT uncertain,resolution_code,response_id,model_evidence,request_id FROM model_operation"
        ).fetchone() == (0, "contradictory_provider_output", None, None, contradictory_request_id)
        assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
        assert database.execute(
            "SELECT count(*) FROM conversation_entry WHERE entry_kind=3"
        ).fetchone()[0] == 0
        assert database.execute("SELECT outcome_content_id FROM turn").fetchone()[0] is None
        database.close()
        contradictory_reopened = start_host(contradictory_store, None)
        processes.append(contradictory_reopened)
        restarted_failure = observe(contradictory_store, "contradictory-message")
        assert restarted_failure["queue"]["status"] == "failed", restarted_failure
        assert restarted_failure["result"] == {
            "status": "failed",
            "code": "contradictory_provider_output",
        }, restarted_failure
        report = command(
            "session", "inspect", "--store", contradictory_store,
            "--session", contradictory_evidence_session, "--profile", "full",
        )
        operation = report["full"]["model_operations"][0]
        assert operation["request_id"] == contradictory_request_id, operation
        resolution = operation["resolution"]
        assert resolution["content"] is not None, resolution
        assert json.loads(resolution["content"]["text"]) == {
            "reason": "ContradictoryProviderOutput", "stage": "response",
            "byte_offset": str(len(contradictory_sse)), "output_index": None,
        }, resolution
        assert len(resolution["content"]["text"].encode()) <= 512
        assert "must not publish" not in json.dumps(report), report
        assert report["full"]["turns"][0]["outcome"]["content"] is None, report
        unreadable_result = subprocess.run(
            [
                str(RUI),
                "request", "read-result",
                "--store",
                str(contradictory_store),
                "--key",
                "contradictory-message",
            ],
            capture_output=True,
            timeout=15,
        )
        assert unreadable_result.returncode != 0, unreadable_result.stdout
        stop_host(contradictory_reopened)
        processes.remove(contradictory_reopened)
        stop_endpoint(contradictory_endpoint, endpoints)

        # Input committed after the first request's cutoff is selected at the
        # next boundary. The first complete candidate is durable history but
        # cannot become the Turn's Final Answer while applicable input waits.
        pending_first_sse, pending_reasoning, pending_message_item = sse_answer(
            "pending-response-1", "pending-reasoning-1", "pending-message-1", "intermediate"
        )
        pending_second_sse, _, _ = sse_answer(
            "pending-response-2", "pending-reasoning-2", "pending-message-2", "actual final"
        )
        first_release = threading.Event()
        second_release = threading.Event()
        releases.extend((first_release.set, second_release.set))
        pending_endpoint = SuccessEndpoint(
            [(pending_first_sse, first_release), (pending_second_sse, second_release)]
        )
        pending_thread = threading.Thread(target=pending_endpoint.serve_forever, daemon=True)
        endpoints[pending_endpoint] = pending_thread
        pending_thread.start()
        pending_store = state / "pending-store"
        pending_host = start_host(
            pending_store, f"http://127.0.0.1:{pending_endpoint.server_port}/responses"
        )
        processes.append(pending_host)
        pending_session = configure(state, pending_store, "pending-config", None, "gpt-6-sol")
        command(
            "session", "configure",
            "--store",
            pending_store,
            "--record",
            state / "pending-tools.json",
            "--key",
            "pending-tools",
            "--session",
            pending_session,
            "--tools",
            "none",
        )
        message(state, pending_store, "pending-first", pending_session, "before cutoff")
        wait_for(lambda: len(pending_endpoint.requests) == 1, "first frozen pending request")
        message(state, pending_store, "pending-second", pending_session, "after cutoff")
        assert observe(pending_store, "pending-second")["queue"]["status"] == "queued"
        first_release.set()
        wait_for(lambda: len(pending_endpoint.requests) == 2, "next input boundary request")
        assert "result" not in observe(pending_store, "pending-first")
        assert observe(pending_store, "pending-second")["queue"]["status"] == "processing"
        pending_request = json.loads(pending_endpoint.requests[1])
        expected_pending_reasoning = dict(pending_reasoning)
        expected_pending_reasoning.pop("created_by")
        assert pending_request["instructions"] == model_instructions(ROOT, store=pending_store, session=pending_session)
        assert pending_request["input"] == [
            {"role": "user", "content": [{"type": "input_text", "text": "before cutoff"}]},
            expected_pending_reasoning,
            pending_message_item,
            {"role": "user", "content": [{"type": "input_text", "text": "after cutoff"}]},
        ]
        second_release.set()
        wait_for(lambda: completed_observation(pending_store, "pending-first"), "pending Turn final")
        assert read_result(pending_store, "pending-first") == b"actual final"
        assert read_result(pending_store, "pending-second") == b"actual final"
        stop_host(pending_host)
        processes.remove(pending_host)
        stop_endpoint(pending_endpoint, endpoints)

        # Structured output remains an explicitly unavailable partial-build
        # surface. Even a complete 2xx text response cannot be published under
        # a frozen object schema without schema validation.
        schema_candidate = sse_answer(
            "schema-response", "schema-reasoning", "schema-message", "private schema answer"
        )[0]
        schema_request_ids = ('schema-"quoted\\request', None)
        schema_endpoint = SuccessEndpoint([
            ResponseSpec(schema_candidate, {"X-Request-Id": request_id} if request_id else {})
            for request_id in schema_request_ids
        ])
        schema_thread = threading.Thread(target=schema_endpoint.serve_forever, daemon=True)
        endpoints[schema_endpoint] = schema_thread
        schema_thread.start()
        for index, request_id in enumerate(schema_request_ids):
            schema_store = state / f"unsupported-schema-store-{index}"
            schema_host = start_host(
                schema_store, f"http://127.0.0.1:{schema_endpoint.server_port}/responses",
                "--fault", "response-metadata-unlink",
                "--test-phase-trace", observations="control",
            )
            processes.append(schema_host)
            schema_diagnostics = HostDiagnostics(schema_host)
            unsupported_schema_session = configure(
                state,
                schema_store,
                f"schema-config-{index}",
                None,
                "gpt-6-sol",
                {"type": "object"},
            )
            message(
                state,
                schema_store,
                f"schema-message-{index}",
                unsupported_schema_session,
                "return an object",
            )
            schema_deadline = time.monotonic() + 8

            def schema_result():
                value = observe(schema_store, f"schema-message-{index}", deadline=schema_deadline)
                remaining = schema_deadline - time.monotonic()
                assert remaining > 0, "schema result exceeded its original deadline"
                execution = command(
                    "session", "inspect", "--store", schema_store,
                    "--session", unsupported_schema_session,
                    timeout=remaining,
                )["execution"]
                assert not execution["dispatch_fenced"], ("schema rejection must precede metadata acquisition", execution)
                return value if value.get("result", {}).get("code") else None

            schema_failure = wait_for(
                schema_result,
                "unsupported structured output rejection",
                deadline=schema_deadline,
            )
            assert schema_failure["result"]["code"] == "unsupported_output_schema", schema_failure
            resources = wait_model_cleanup(schema_diagnostics, schema_store, unsupported_schema_session, schema_failure, schema_deadline)
            assert not resources["dispatch_fenced"], resources
            assert not list((schema_store / "scratch").glob("response-metadata-*.tmp"))
            before_operation = command(
                "session", "inspect", "--store", schema_store,
                "--session", unsupported_schema_session, "--profile", "full",
            )["full"]["model_operations"][0]
            stop_host(schema_host)
            assert_model_cleanup_census(schema_diagnostics, schema_failure)
            processes.remove(schema_host)
            with sqlite3.connect(schema_store / "rui.sqlite3") as database:
                assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
                assert database.execute("SELECT count(*) FROM model_tool_call").fetchone()[0] == 0
                assert database.execute("SELECT count(*) FROM action_operation").fetchone()[0] == 0
                assert database.execute(
                    "SELECT count(*) FROM conversation_entry WHERE entry_kind=3"
                ).fetchone()[0] == 0
                assert database.execute("SELECT outcome_content_id FROM turn").fetchone()[0] is None
            reopened = start_host(schema_store, None)
            processes.append(reopened)
            report = command(
                "session", "inspect", "--store", schema_store,
                "--session", unsupported_schema_session, "--profile", "full",
            )
            operation = report["full"]["model_operations"][0]
            assert operation == before_operation, operation
            resolution = operation["resolution"]
            assert resolution["code"] == "unsupported_output_schema", resolution
            assert resolution["content"] is not None, resolution
            assert json.loads(resolution["content"]["text"]) == {
                "reason": "UnsupportedOutputSchema", "stage": "response",
                "byte_offset": str(len(schema_candidate)), "output_index": None,
            }, resolution
            assert len(resolution["content"]["text"].encode()) <= 512
            assert operation["request_id"] == request_id, operation
            assert "private schema answer" not in json.dumps(report), report
            assert report["full"]["turns"][0]["outcome"]["content"] is None, report
            assert observe(schema_store, f"schema-message-{index}")["result"] == schema_failure["result"]
            assert len(schema_endpoint.requests) == index + 1
            stop_host(reopened)
            processes.remove(reopened)
        stop_endpoint(schema_endpoint, endpoints)

        # Completed transport is not success: the whole SSE candidate must be
        # complete, consistent and limited to the supported text subset.
        invalid_reasoning = {
            "type": "reasoning",
            "id": "invalid-reasoning",
            "summary": [],
            "encrypted_content": "private-invalid",
        }
        invalid_message = {
            "type": "message",
            "id": "invalid-message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "must not escape", "annotations": []}],
        }
        contradictory = encode_sse(
            [
                {"type": "response.output_item.done", "output_index": 0, "item": invalid_reasoning},
                {"type": "response.output_item.done", "output_index": 1, "item": invalid_message},
                {
                    "type": "response.completed",
                    "response": {
                        "id": "contradictory",
                        "status": "completed",
                        "model": "model-a-served",
                        "output": [invalid_message, invalid_reasoning],
                    },
                },
            ]
        )
        changed_message = dict(invalid_message)
        changed_message["content"] = [
            {"type": "output_text", "text": "changed terminal text", "annotations": []}
        ]
        changed_terminal = encode_sse(
            [
                {"type": "response.output_item.done", "output_index": 0, "item": invalid_reasoning},
                {"type": "response.output_item.done", "output_index": 1, "item": invalid_message},
                {
                    "type": "response.completed",
                    "response": {
                        "id": "changed-terminal",
                        "status": "completed",
                        "model": "model-a-served",
                        "output": [invalid_reasoning, changed_message],
                    },
                },
            ]
        )
        duplicate_message = dict(invalid_message)
        duplicate_message["id"] = invalid_reasoning["id"]
        duplicate_identity = encode_sse(
            [
                {"type": "response.output_item.done", "output_index": 0, "item": invalid_reasoning},
                {"type": "response.output_item.done", "output_index": 1, "item": duplicate_message},
                {"type": "response.completed", "response": {
                    "id": "duplicate-identity", "status": "completed",
                    "output": [invalid_reasoning, duplicate_message],
                }},
            ],
        )
        incomplete_tool = encode_sse(
            [
                {
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": {"type": "function_call", "id": "tool-1"},
                },
                {"type": "response.completed", "response": {
                    "id": "unfinished-tool", "status": "completed", "output": [],
                }},
            ],
        )
        late_malformed = first_sse.replace(
            b"data: [DONE]\n\n", b"data: {malformed\n\ndata: [DONE]\n\n"
        )
        encrypted_cases = []
        for encrypted in (None, "", 42, [], {}, True):
            item = dict(invalid_reasoning)
            item["encrypted_content"] = encrypted
            encrypted_cases.append(encode_sse([
                {"type": "response.output_item.done", "output_index": 0, "item": item}
            ], done=False))
        missing = dict(invalid_reasoning)
        del missing["encrypted_content"]
        encrypted_cases.append(encode_sse([
            {"type": "response.output_item.done", "output_index": 0, "item": missing}
        ], done=False))
        private_sentinel = "PRIVATE-CONTINUATION-MUST-NOT-APPEAR"
        unsupported_message = dict(invalid_message)
        unsupported_message["phase"] = "future_phase"
        unsupported_message["content"] = [{"type": "output_text", "text": private_sentinel}]
        unsupported_cases = [
            encode_sse([{"type": "response.output_item.done", "output_index": 0,
                         "item": unsupported_message}], done=False),
            encode_sse([{"type": "response.future_event", "private": private_sentinel}], done=False),
        ]
        # Distinct output item identities pass parsing, but the decoded call
        # identity must remain unique when Store imports the complete envelope.
        duplicate_calls = sse_tool_calls("duplicate-calls", [
            ("bash", "same-call", json.dumps({
                "description": f"Print duplicate marker {index}",
                "cmd": "true", "timeout_ms": None,
            })) for index in range(2)
        ])
        invalid_bodies = [
            first_sse[:-1],
            contradictory,
            changed_terminal,
            duplicate_identity,
            late_malformed,
            incomplete_tool,
            *encrypted_cases,
            *unsupported_cases,
            duplicate_calls,
        ]
        invalid_endpoint = SuccessEndpoint([ResponseSpec(invalid_bodies[0], {}), *invalid_bodies[1:]])
        invalid_thread = threading.Thread(target=invalid_endpoint.serve_forever, daemon=True)
        endpoints[invalid_endpoint] = invalid_thread
        invalid_thread.start()
        for index, expected_code in enumerate(
            (
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "contradictory_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "continuation_unavailable",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "continuation_unavailable",
                "unsupported_provider_output",
                "unsupported_provider_output",
                "contradictory_provider_output",
            )
        ):
            invalid_store = state / f"invalid-output-{index}"
            invalid_host = start_host(
                invalid_store, f"http://127.0.0.1:{invalid_endpoint.server_port}/responses"
            )
            processes.append(invalid_host)
            session = configure(state, invalid_store, f"invalid-config-{index}", None, "gpt-6-sol")
            message(
                state,
                invalid_store,
                f"invalid-message-{index}",
                session,
                "candidate",
            )
            rejected = wait_for(
                lambda key=f"invalid-message-{index}": (
                    value := observe(invalid_store, key)
                ).get("result", {}).get("code")
                and value,
                f"invalid output {index}",
            )
            assert rejected["result"]["code"] == expected_code, rejected
            assert rejected["processing"]["attempt"] == "1", rejected
            expected_request_id = None if index == 0 else f"request-{index + 1}"
            before_operation = command(
                "session", "inspect", "--store", invalid_store,
                "--session", session, "--profile", "full",
            )["full"]["model_operations"][0]
            assert before_operation["request_id"] == expected_request_id, before_operation
            stop_host(invalid_host)
            processes.remove(invalid_host)
            database = sqlite3.connect(invalid_store / "rui.sqlite3")
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
            assert database.execute(
                "SELECT count(*) FROM conversation_entry WHERE entry_kind=3"
            ).fetchone()[0] == 0
            assert database.execute("SELECT count(*) FROM action_operation").fetchone()[0] == 0
            assert database.execute("SELECT count(*) FROM model_tool_call").fetchone()[0] == 0
            assert database.execute("SELECT request_id FROM model_operation").fetchone()[0] == expected_request_id
            database.close()
            # Rejection evidence must survive scratch disposal and Host restart,
            # without turning a diagnostic into an answer or continuation.
            reopened = start_host(invalid_store, None)
            processes.append(reopened)
            report = command(
                "session", "inspect", "--store", invalid_store,
                "--session", session, "--profile", "full",
            )
            operation = report["full"]["model_operations"][0]
            assert operation["operation"] == before_operation["operation"], operation
            assert operation["request_id"] == expected_request_id, operation
            resolution = operation["resolution"]
            assert resolution["code"] == expected_code, resolution
            assert resolution["content"] is not None, resolution
            detail = json.loads(resolution["content"]["text"])
            assert detail["reason"] and detail["stage"], detail
            assert len(resolution["content"]["text"].encode()) <= 512
            assert private_sentinel not in json.dumps(report), report
            # The same rejected bytes stay privately on disk, bound to the
            # saved Operation, Attempt, code and typed reason/offset.
            assert_complete_failed_response(
                invalid_store, invalid_bodies[index], operation=operation["operation"],
                code=expected_code, http_status=200, request_id=expected_request_id,
                diagnostic=resolution["content"]["text"],
            )
            if index == 3:
                assert detail["reason"] == "InvalidProviderEnvelope", detail
            if index == 5:
                assert detail["reason"] == "UnfinishedProviderOutputItem", detail
            if index == 13:
                assert detail["reason"] == "UnsupportedMessagePhase", detail
                assert detail["stage"] == "item" and detail["output_index"] == 0, detail
            if index == 14:
                assert detail["reason"] == "UnsupportedEventType", detail
                assert detail["stage"] == "event" and detail["output_index"] is None, detail
            if index == 15:
                assert detail == {
                    "reason": "InvalidProviderEnvelope", "stage": "response",
                    "byte_offset": str(len(duplicate_calls)), "output_index": None,
                }, detail
            assert report["full"]["turns"][0]["outcome"]["content"] is None, report
            stop_host(reopened)
            processes.remove(reopened)
        assert len(invalid_endpoint.requests) == 16
        stop_endpoint(invalid_endpoint, endpoints)

        # Concurrent failures keep separate exact captures, a success adds
        # none, and a retention fault leaves the saved failure unchanged.
        def unfinished_tool(label, padding):
            return encode_sse([{
                "type": "response.output_item.added", "output_index": 0,
                "item": {"type": "function_call", "id": f"{label}-{'z' * padding}"},
            }, {"type": "response.completed", "response": {
                "id": label, "status": "completed", "output": [],
            }}])

        concurrent_release = threading.Event()
        # One body crosses the 64 KiB copy window; lengths all differ.
        concurrent_bodies = {
            f"concurrent-{index}": unfinished_tool(f"concurrent-{index}", (70_000, 1, 977, 4_096)[index])
            for index in range(4)
        }
        later_bodies = {text: unfinished_tool(text, 3) for text in ("blocked", "after-fault")}
        metadata_release = threading.Event()
        metadata_body = sse_answer("metadata-response", "metadata-reasoning", "metadata-message", "private answer")[0]
        concurrent_endpoint = SuccessEndpoint([], responses_by_input={
            **{
                text: (ResponseSpec(body, {"X-Request-Id": text, "OpenAI-Model": "model-a-served"}), concurrent_release)
                for text, body in concurrent_bodies.items()
            },
            **{
                text: ResponseSpec(body, {"X-Request-Id": text, "OpenAI-Model": "model-a-served"})
                for text, body in later_bodies.items()
            },
            "metadata-blocked": (ResponseSpec(metadata_body, {"X-Request-Id": "metadata-blocked"}), metadata_release),
            "succeed": sse_answer("concurrent-success", "concurrent-reasoning", "concurrent-message", "fine")[0],
        })
        concurrent_thread = threading.Thread(target=concurrent_endpoint.serve_forever, daemon=True)
        endpoints[concurrent_endpoint] = concurrent_thread
        concurrent_thread.start()
        concurrent_store = state / "concurrent-failed-responses"
        concurrent_host = start_host(
            # HTTP/1.1 opens one connection per 100 capacity: five in flight at once.
            concurrent_store, f"http://127.0.0.1:{concurrent_endpoint.server_port}/responses", active_capacity=500,
        )
        processes.append(concurrent_host)
        concurrent_sessions = {}
        for text in (*concurrent_bodies, "succeed"):
            concurrent_sessions[text] = configure(state, concurrent_store, f"{text}-config", None, "gpt-6-sol")
            message(state, concurrent_store, f"{text}-message", concurrent_sessions[text], text)
        wait_for(lambda: len(concurrent_endpoint.requests) == 5, "concurrent requests in flight")
        wait_for(lambda: completed_observation(concurrent_store, "succeed-message"), "concurrent success")
        assert failed_response_records(concurrent_store) == []
        concurrent_release.set()

        def failed_result(key):
            return wait_for(
                lambda: (value := observe(concurrent_store, key)).get("result", {}).get("code") and value,
                f"{key} failure",
            )["result"]["code"]

        def saved_failures(text):
            operation, = command(
                "session", "inspect", "--store", concurrent_store,
                "--session", concurrent_sessions[text], "--profile", "full",
            )["full"]["model_operations"][-1:]
            return operation

        concurrent_codes = {text: failed_result(f"{text}-message") for text in concurrent_bodies}
        records = failed_response_records(concurrent_store)
        assert len(records) == 4, records
        for record, body in records:
            text = record["request_id"]
            saved = saved_failures(text)
            assert body == concurrent_bodies[text], (text, len(body))
            assert (record["operation"], record["attempt"]) == (saved["operation"], "1"), (record, saved)
            assert record["code"] == concurrent_codes[text] == saved["resolution"]["code"], (record, saved)
            assert record["diagnostic"] == saved["resolution"]["content"]["text"], (record, saved)
            assert record["status"] == "complete", record
        assert sorted(record["request_id"] for record, _ in records) == sorted(concurrent_bodies)

        # A record-namespace entry that cannot be reclaimed blocks retention.
        # The Attempt still saves the same failure, and later work recovers.
        record_root = concurrent_store / "diagnostics" / "failed-responses"
        blocker = record_root / "response-99-1-1.json.tmp"
        blocker.mkdir(mode=0o700)
        before_fault = sorted(path.name for path in record_root.iterdir())
        message(state, concurrent_store, "blocked-message", concurrent_sessions["concurrent-0"], "blocked")
        assert failed_result("blocked-message") == concurrent_codes["concurrent-0"]
        blocked = saved_failures("concurrent-0")
        assert blocked["resolution"]["code"] == concurrent_codes["concurrent-0"], blocked
        assert json.loads(blocked["resolution"]["content"]["text"])["reason"], blocked
        assert sorted(path.name for path in record_root.iterdir()) == before_fault
        blocker.rmdir()
        message(state, concurrent_store, "after-fault-message", concurrent_sessions["concurrent-1"], "after-fault")
        assert failed_result("after-fault-message") == concurrent_codes["concurrent-1"]
        records = failed_response_records(concurrent_store)
        assert len(records) == 5, records
        recovered, recovered_body = records[-1]
        assert (recovered["request_id"], recovered_body) == ("after-fault", later_bodies["after-fault"]), recovered
        assert recovered["operation"] == saved_failures("concurrent-1")["operation"], recovered

        # Local metadata acquisition can fail after a complete provider
        # response; it must not discard that failed request's captured bytes.
        message(state, concurrent_store, "metadata-blocked-message", concurrent_sessions["concurrent-1"], "metadata-blocked")
        wait_for(lambda: len(concurrent_endpoint.requests) == 8, "metadata request awaiting response")
        metadata_operation = saved_failures("concurrent-1")["operation"]
        metadata_blocker = concurrent_store / "scratch" / f"response-metadata-{metadata_operation}-1.tmp"
        metadata_blocker.write_bytes(b"fixture-owned metadata acquisition blocker")
        metadata_release.set()
        assert failed_result("metadata-blocked-message") == "response_metadata_exhausted"
        metadata_blocker.unlink()
        records = failed_response_records(concurrent_store)
        assert len(records) == 6, records
        retained_metadata, retained_body = records[-1]
        assert retained_body == metadata_body
        assert (retained_metadata["operation"], retained_metadata["attempt"], retained_metadata["request_id"]) == (metadata_operation, "1", "metadata-blocked"), retained_metadata
        assert (retained_metadata["code"], retained_metadata["http_status"], retained_metadata["diagnostic"], retained_metadata["status"]) == ("response_metadata_exhausted", 200, None, "complete"), retained_metadata
        assert len(concurrent_endpoint.requests) == 8, concurrent_endpoint.requests
        stop_host(concurrent_host)
        processes.remove(concurrent_host)
        stop_endpoint(concurrent_endpoint, endpoints)

        fault_effect = state / "output-fault-must-not-launch"
        fault_calls = classification_population("fault", fault_effect)
        fault_responses = []
        for index in range(7):
            fault_responses.append(
                sse_tool_calls(
                    f"fault-response-{index}",
                    fault_calls,
                )
            )
        output_fault_endpoint = SuccessEndpoint(fault_responses)
        output_fault_thread = threading.Thread(
            target=output_fault_endpoint.serve_forever, daemon=True
        )
        endpoints[output_fault_endpoint] = output_fault_thread
        output_fault_thread.start()
        for index, (fault, expected_code) in enumerate(
            (
                ("response-acquire", "response_capture_failed"),
                ("response-write", "response_write_failed"),
                ("response-seal", "response_seal_failed"),
                ("response-metadata", "response_metadata_failed"),
            )
        ):
            fault_store = state / f"{fault}-store"
            fault_host = start_host(
                fault_store,
                f"http://127.0.0.1:{output_fault_endpoint.server_port}/responses",
                "--fault",
                fault,
            )
            processes.append(fault_host)
            session = configure(state, fault_store, f"{fault}-config", None, "gpt-6-sol")
            message(state, fault_store, f"{fault}-message", session, "fault")
            rejected = wait_for(
                lambda key=f"{fault}-message": (
                    value := observe(fault_store, key)
                ).get("result", {}).get("code")
                and value,
                f"{fault} rejection",
            )
            assert rejected["result"]["code"] == expected_code, rejected
            stop_host(fault_host)
            processes.remove(fault_host)
            with sqlite3.connect(fault_store / "rui.sqlite3") as database:
                assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
                assert database.execute("SELECT count(*) FROM model_tool_call").fetchone()[0] == 0
                assert database.execute("SELECT count(*) FROM action_operation").fetchone()[0] == 0

        for index, fault in enumerate(("response-read", "response-import", "response-commit")):
            fault_store = state / f"{fault}-store"
            fault_host = start_host(
                fault_store,
                f"http://127.0.0.1:{output_fault_endpoint.server_port}/responses",
                "--fault",
                fault,
            )
            processes.append(fault_host)
            session = configure(state, fault_store, f"{fault}-config", None, "gpt-6-sol")
            message(state, fault_store, f"{fault}-message", session, "fault")
            wait_for(lambda: fault_host.poll() is not None, f"{fault} fenced shutdown")
            assert fault_host.returncode != 0
            stop_host(fault_host)
            processes.remove(fault_host)
            database = sqlite3.connect(fault_store / "rui.sqlite3")
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
            assert database.execute(
                "SELECT uncertain,resolution_code FROM model_operation"
            ).fetchone() == (1, None)
            assert database.execute("SELECT count(*) FROM model_tool_call").fetchone()[0] == 0
            assert database.execute("SELECT count(*) FROM action_operation").fetchone()[0] == 0
            database.close()
        assert not fault_effect.exists()
        stop_endpoint(output_fault_endpoint, endpoints)

        scratch_endpoint = SuccessEndpoint(
            [sse_answer("scratch-response", "scratch-r", "scratch-m", "x" * 100_000)[0]]
        )
        scratch_thread = threading.Thread(target=scratch_endpoint.serve_forever, daemon=True)
        endpoints[scratch_endpoint] = scratch_thread
        scratch_thread.start()
        scratch_store = state / "response-scratch-store"
        scratch_host = start_host(
            scratch_store,
            f"http://127.0.0.1:{scratch_endpoint.server_port}/responses",
            "--test-request-scratch-limit",
            str(64 * 1024),
            "--test-phase-trace",
            observations="control",
        )
        processes.append(scratch_host)
        scratch_diagnostics = HostDiagnostics(scratch_host)
        response_scratch_session = configure(state, scratch_store, "scratch-config", None, "gpt-6-sol")
        message(state, scratch_store, "scratch-message", response_scratch_session, "scratch")
        scratch_deadline = time.monotonic() + 8
        rejected = wait_for(
            lambda: (value := observe(
                scratch_store, "scratch-message", deadline=scratch_deadline,
            )).get("result", {}).get("code")
            and value,
            "response scratch exhaustion",
            deadline=scratch_deadline,
        )
        assert rejected["result"]["code"] == "response_scratch_exhausted", rejected
        wait_model_cleanup(
            scratch_diagnostics, scratch_store, response_scratch_session,
            rejected, scratch_deadline,
        )
        stop_host(scratch_host)
        assert_model_cleanup_census(scratch_diagnostics, rejected)
        processes.remove(scratch_host)
        stop_endpoint(scratch_endpoint, endpoints)

        # Item cardinality and answer bytes grow independently while execution
        # capacity remains one and metadata/capture stay in shared scratch.
        count_payload = sse_many("many-items", 32, "count answer")
        large_answer = "z" * 100_000
        byte_payload = sse_many("large-answer", 1, large_answer)
        growth_endpoint = SuccessEndpoint([count_payload, byte_payload])
        growth_thread = threading.Thread(target=growth_endpoint.serve_forever, daemon=True)
        endpoints[growth_endpoint] = growth_thread
        growth_thread.start()
        growth_store = state / "growth-store"
        growth_host = start_host(
            growth_store, f"http://127.0.0.1:{growth_endpoint.server_port}/responses",
            "--test-phase-trace", observations="control_peers",
        )
        processes.append(growth_host)
        growth_diagnostics = HostDiagnostics(growth_host)
        growth_peers = PeerCensus(growth_diagnostics)
        growth_a_session = growth_peers.call("configure", lambda: configure(state, growth_store, "growth-config-a", None, "gpt-6-sol"))
        growth_b_session = growth_peers.call("configure", lambda: configure(state, growth_store, "growth-config-b", None, "gpt-6-sol"))
        growth_peers.call("message", lambda: message(state, growth_store, "growth-count", growth_a_session, "count"))
        count_deadline = time.monotonic() + 8
        counted = wait_for(
            lambda: growth_peers.call("observe", lambda: completed_observation(
                growth_store, "growth-count", deadline=count_deadline,
            ), deadline=count_deadline),
            "many item output", deadline=count_deadline,
        )
        assert growth_peers.call("read_result", lambda: read_result(
            growth_store, "growth-count", deadline=count_deadline,
        ), deadline=count_deadline) == b"count answer"
        wait_model_cleanup(
            growth_diagnostics, growth_store, growth_a_session, counted, count_deadline,
            peers=growth_peers,
        )
        growth_peers.call("message", lambda: message(state, growth_store, "growth-bytes", growth_b_session, "bytes"))
        bytes_deadline = time.monotonic() + 20
        imported = wait_for(
            lambda: growth_peers.call("observe", lambda: completed_observation(
                growth_store, "growth-bytes", deadline=bytes_deadline,
            ), deadline=bytes_deadline),
            "large output import",
            deadline=bytes_deadline,
        )
        assert growth_peers.call("read_result", lambda: read_result(
            growth_store, "growth-bytes", deadline=bytes_deadline,
        ), deadline=bytes_deadline) == large_answer.encode()
        wait_model_cleanup(
            growth_diagnostics, growth_store, growth_b_session, imported, bytes_deadline,
            peers=growth_peers,
        )
        # A failed caller destination may retain a prefix, but it cannot make
        # the read successful or consume the saved keyed answer. A fresh read
        # streams the complete bytes again without inventing a newline.
        read_fd, write_fd = os.pipe()
        failed_destination = None
        failed_read_deadline = time.monotonic() + 15
        failed_read_request = growth_peers.expect("read_result")
        try:
            failed_destination = subprocess.Popen(
                [str(RUI), "request", "read-result", "--store", str(growth_store), "--key", "growth-bytes"],
                stdout=write_fd,
                stderr=subprocess.PIPE,
            )
            os.close(write_fd)
            write_fd = None
            prefix = os.read(read_fd, 4096)
            os.close(read_fd)
            read_fd = None
            _, failure_stderr = failed_destination.communicate(timeout=max(0, failed_read_deadline - time.monotonic()))
            growth_peers.release(failed_read_request, failed_read_deadline)
        finally:
            dispose_all(
                lambda: os.close(write_fd) if write_fd is not None else None,
                lambda: os.close(read_fd) if read_fd is not None else None,
                lambda: stop_process(failed_destination) if failed_destination is not None else None,
            )
        assert failed_destination.returncode != 0, failure_stderr
        assert 0 < len(prefix) < len(large_answer), len(prefix)
        complete_path = state / "growth-answer.bin"
        complete_read_deadline = time.monotonic() + 15
        complete_read_request = growth_peers.expect("read_result")
        with complete_path.open("wb") as complete_destination:
            completed_read = subprocess.run(
                [
                    str(RUI),
                    "request", "read-result",
                    "--store",
                    str(growth_store),
                    "--key",
                    "growth-bytes",
                ],
                stdout=complete_destination,
                stderr=subprocess.PIPE,
                timeout=max(0, complete_read_deadline - time.monotonic()),
            )
        growth_peers.release(complete_read_request, complete_read_deadline)
        assert completed_read.returncode == 0, completed_read.stderr
        assert complete_path.stat().st_size == len(large_answer)
        with complete_path.open("rb") as complete_source:
            actual_digest = hashlib.file_digest(complete_source, "sha256").digest()
        assert actual_digest == hashlib.sha256(large_answer.encode()).digest()
        resources = growth_peers.call("inspect", lambda: command(
            "session", "inspect", "--store", growth_store, "--session", growth_b_session
        ))["execution"]
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(growth_host)
        growth_peers.finish(time.monotonic() + 5)
        assert_model_cleanup_census(growth_diagnostics, counted, imported)
        processes.remove(growth_host)
        database = sqlite3.connect(growth_store / "rui.sqlite3")
        assert database.execute(
            "SELECT count(*) FROM model_output_item WHERE operation_id=1"
        ).fetchone()[0] == 33
        assert database.execute("SELECT payload IS NULL,byte_length FROM content WHERE byte_length=? AND private=0", (len(large_answer),)).fetchall() == [(1, len(large_answer))]
        assert database.execute("SELECT coalesce(sum(length(payload)),0) FROM content WHERE private=0").fetchone()[0] < 1024
        database.close()
        stop_endpoint(growth_endpoint, endpoints)

        # Public answers are projections of immutable provider items. Exercise
        # both dedup orders: answer then caller input, and caller then answer.
        parts = ["", "x" * 4093 + "\n", "🙂\t\\", ""]
        projected_answer = "".join(parts).encode()
        projection_endpoint = SuccessEndpoint([
            sse_answer("projection-1", "p-r1", "p-m1", parts)[0],
            sse_answer("projection-2", "p-r2", "p-m2", "caller-first")[0],
        ])
        projection_thread = threading.Thread(target=projection_endpoint.serve_forever, daemon=True)
        endpoints[projection_endpoint] = projection_thread
        projection_thread.start()
        projection_store = state / "projection-store"
        projection_url = f"http://127.0.0.1:{projection_endpoint.server_port}/responses"
        host = start_host(projection_store, projection_url)
        processes.append(host)
        projection_session = configure(state, projection_store, "projection-config", None, "gpt-6-sol", instructions="caller-first")
        message(state, projection_store, "projection-first", projection_session, "first")
        wait_for(lambda: completed_observation(projection_store, "projection-first"), "projected answer")
        assert read_result(projection_store, "projection-first") == projected_answer
        configure(state, projection_store, "projection-update", projection_session, "gpt-6-sol", instructions=projected_answer.decode())
        message(state, projection_store, "projection-second", projection_session, projected_answer.decode())
        wait_for(lambda: completed_observation(projection_store, "projection-second"), "deduplicated answer")
        assert read_result(projection_store, "projection-second") == b"caller-first"
        replay = json.loads(projection_endpoint.requests[1])["input"]
        assert replay[-1]["content"][0]["text"] == projected_answer.decode(), replay
        assert replay[-2]["content"][0]["text"] == projected_answer.decode(), replay
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(projection_store / "rui.sqlite3") as database:
            assert database.execute("SELECT c.payload IS NULL FROM model_operation o JOIN content c ON c.content_id=o.resolution_content_id ORDER BY o.operation_id").fetchall() == [(1,), (0,)]
            assert database.execute("SELECT count(*) FROM answer_text_projection").fetchone()[0] == len(parts)
            assert database.execute("SELECT count(*) FROM answer_text_projection p JOIN content c ON c.content_id=p.source_content_id WHERE c.private<>1 OR c.payload IS NULL").fetchone()[0] == 0
        host = start_host(projection_store, projection_url)
        processes.append(host)
        assert read_result(projection_store, "projection-first") == projected_answer
        assert read_result(projection_store, "projection-second") == b"caller-first"
        stop_host(host)
        processes.remove(host)
        stop_endpoint(projection_endpoint, endpoints)

        # A committed permit launches exactly one complete frozen request. The
        # endpoint holds the response so later settings and input arrive while
        # the admitted request is demonstrably in flight. Byte/item
        # scheduling stress lives in the portable cursor corpus; this journey
        # keeps production allowances and witnesses the frozen composition.
        store = state / "frozen-store"
        host = start_host(
            store,
            url,
            "--test-phase-trace", observations="control_peers",
        )
        processes.append(host)
        frozen_peers = PeerCensus(HostDiagnostics(host))
        output_schema = {
            "type": "object",
            "properties": {"answer": {"type": "string"}},
            "required": ["answer"],
            "additionalProperties": False,
        }
        main_session = frozen_peers.call("configure", lambda: configure(state, store, "config-a", None, "gpt-6-sol", output_schema, "A"))
        frozen_peers.call("configure", lambda: configure(state, store, "instructions-b", main_session, "gpt-6-sol", instructions="B"))
        frozen_peers.call("configure", lambda: configure(state, store, "instructions-a", main_session, "gpt-6-sol", instructions="A"))
        frozen_peers.call("configure", lambda: configure(state, store, "instructions-a-again", main_session, "gpt-6-sol", instructions="A"))
        frozen_peers.call("message", lambda: message(state, store, "message-a", main_session, 'first "message"\n'))
        if not endpoint.received.wait(8):
            raise AssertionError("endpoint did not receive committed request")
        active_model_change = frozen_peers.call("configure", lambda: command(
            "session", "configure",
            "--store",
            store,
            "--record",
            state / "config-b.json",
            "--key",
            "config-b",
            "--session",
            main_session,
            "--model",
            "gpt-6.1-sol",
            "--tools",
            "none",
            expect=1,
        ))
        assert active_model_change["answer"]["status"] == "rejected", active_model_change
        assert active_model_change["answer"]["code"] == "model_is_immutable"
        active_settings = frozen_peers.call("inspect", lambda: command(
            "session", "inspect", "--store", store, "--session", main_session
        ))["session"]
        assert active_settings["model"] == "gpt-6-sol", active_settings
        assert active_settings["tools"] == ["bash"], active_settings
        frozen_peers.call("message", lambda: message(state, store, "message-b", main_session, "later message"))
        assert len(endpoint.requests) == 1
        resources = frozen_peers.call("inspect", lambda: command(
            "session", "inspect", "--store", store, "--session", main_session
        ))["execution"]
        assert int(resources["scratch_used_bytes"]) == len(endpoint.requests[0]), resources
        # Mutable settings accepted while the request is in flight apply only
        # to the successor, never to the frozen request.
        mutable_update = frozen_peers.call("configure", lambda: command(
            "session", "configure",
            "--store",
            store,
            "--record",
            state / "mutable-during-flight.json",
            "--key",
            "mutable-during-flight",
            "--session",
            main_session,
            "--tools",
            "none",
            "--text-output",
        ))
        assert mutable_update["answer"]["status"] == "accepted", mutable_update
        assert len(endpoint.requests) == 1
        endpoint.release.set()
        frozen_deadline = time.monotonic() + 8
        failed = wait_for(
            lambda: (value := frozen_peers.call("observe", lambda: observe(
                store, "message-a", deadline=frozen_deadline,
            ), deadline=frozen_deadline))["status"] == "accepted"
            and value.get("result", {}).get("code") == "provider_http_422"
            and value,
            "saved permanent failure", deadline=frozen_deadline,
        )
        assert failed["queue"]["status"] == "failed", failed
        assert failed["processing"]["attempt"] == "1", failed
        post_failure_model_change = frozen_peers.call("configure", lambda: command(
            "session", "configure",
            "--store",
            store,
            "--record",
            state / "post-failure-model.json",
            "--key",
            "post-failure-model",
            "--session",
            main_session,
            "--model",
            "gpt-6.1-sol",
            "--permission-mode",
            "bypass",
            expect=1,
        ))
        assert post_failure_model_change["answer"]["status"] == "rejected"
        assert post_failure_model_change["answer"]["code"] == "model_is_immutable"
        # The queued Message starts its own Turn once the first one fails.
        successor_deadline = time.monotonic() + 8
        wait_for(
            lambda: frozen_peers.call("observe", lambda: observe(
                store, "message-b", deadline=successor_deadline,
            ), deadline=successor_deadline).get("result", {}).get("code") == "provider_http_422",
            "successor failure", deadline=successor_deadline,
        )
        assert len(endpoint.requests) == 2, "a permit launched more than once"

        observed = json.loads(endpoint.requests[0])
        expected = {
            "model": "gpt-6-sol",
            "store": False,
            "stream": True,
            "include": ["reasoning.encrypted_content"],
            "instructions": model_instructions(ROOT, "A", store=store, session=main_session),
            "input": [
                {
                    "role": "user",
                    "content": [{"type": "input_text", "text": 'first "message"\n'}],
                },
                {"role": "developer", "content": [{"type": "input_text", "text": "B"}]},
                {"role": "developer", "content": [{"type": "input_text", "text": "A"}]},
                {"role": "developer", "content": [{"type": "input_text", "text": "A"}]},
            ],
            "tools": [
                {
                    "type": "function",
                    "name": "bash",
                    "description": "Run Bash on the local machine. Each call starts in the Session Workspace; relative paths resolve there, while absolute paths can access outside it. Start filesystem exploration there and broaden searches only as needed. Put text payloads in stdin, never inside cmd.",
                    "strict": True,
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "cmd": {"type": "string"},
                            "stdin": {
                                "type": ["string", "null"],
                                "description": "Stdin is empty unless set. Supply literal UTF-8 text, at most 122880 decoded bytes, read exactly then EOF. Missing or null uses /dev/null.",
                            },
                            "description": {
                                "type": "string",
                                "description": "A short human-facing activity label: base verb + concrete target + useful scope, in sentence case with no trailing punctuation. Describe the intended work, not its status, success or safety. Required, nonblank, single-line valid UTF-8, at most 100 decoded UTF-8 bytes. Aim for 40–60 characters; use more only for useful scope. Example: Run parser regression tests",
                            },
                            "timeout_ms": {
                                "type": ["integer", "null"],
                                "description": "Use null for the Host default unless the work needs a different budget. A positive integer replaces it with a total elapsed execution budget in milliseconds from process start; output does not reset it. Allow enough time for searches, builds and tests. Expiry ends the call through process-group termination, not a background handle; partial effects may remain.",
                                "minimum": 1,
                                "maximum": 9223372036854775807,
                            },
                        },
                        "required": ["cmd", "stdin", "description", "timeout_ms"],
                        "additionalProperties": False,
                    },
                },
            ],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "rui_output",
                    "strict": True,
                    "schema": output_schema,
                }
            },
        }
        assert observed == expected, (observed, expected)
        stop_host(host)
        frozen_peers.finish(time.monotonic() + 5)
        processes.remove(host)

        # Killing the execution owner cannot erase either saved result. Input
        # accepted without execution stays queued for the restarted Host.
        offline = start_host(store, None)
        processes.append(offline)
        assert observe(store, "message-a")["result"]["code"] == "provider_http_422"
        assert observe(store, "message-b")["result"]["code"] == "provider_http_422"
        message(state, store, "message-c", main_session, "after restart")
        assert observe(store, "message-c")["queue"]["status"] == "queued"
        stop_host(offline)
        processes.remove(offline)

        # A successor reuses complete projected history in its original order:
        # the prior failed Turn's messages and each distinct instruction
        # update, including repeated equal text and reversals.
        successor = json.loads(endpoint.requests[1])
        later_input = expected["input"] + [
            {"role": "user", "content": [{"type": "input_text", "text": "later message"}]}
        ]
        assert successor["input"] == later_input, successor
        assert successor["instructions"] == model_instructions(ROOT, "A", store=store, session=main_session), successor
        assert successor["model"] == "gpt-6-sol", successor
        assert successor["tools"] == [], successor
        assert "text" not in successor, successor

        # A restarted Host reconstructs the same projection from the Store
        # alone and dispatches the queued Message after it.
        host = start_host(store, url)
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 3, "post-restart successor request")
        restarted = json.loads(endpoint.requests[2])
        assert restarted["input"] == later_input + [
            {"role": "user", "content": [{"type": "input_text", "text": "after restart"}]}
        ], restarted
        assert restarted["instructions"] == successor["instructions"], restarted
        assert restarted["model"] == "gpt-6-sol", restarted
        assert restarted["tools"] == [], restarted
        assert "text" not in restarted, restarted
        wait_for(lambda: observe(store, "message-c").get("result", {}).get("code") == "provider_http_422", "post-restart successor failure")
        assert len(endpoint.requests) == 3, "a permit launched more than once"
        stop_host(host)
        processes.remove(host)

        # A known live preparation failure saves future eligibility. Killing
        # the process before such a failure can settle leaves conservative
        # uncertainty instead. Neither path refunds Attempt 1; both recover
        # through a freshly admitted Attempt 2.
        preparation_sse = sse_answer(
            "preparation-recovered",
            "preparation-r",
            "preparation-m",
            "prepared after restart",
        )[0]
        preparation_endpoint = SuccessEndpoint([preparation_sse])
        preparation_thread = threading.Thread(
            target=preparation_endpoint.serve_forever, daemon=True
        )
        endpoints[preparation_endpoint] = preparation_thread
        preparation_thread.start()
        preparation_store = state / "known-preparation-store"
        preparation_host = start_host(
            preparation_store,
            f"http://127.0.0.1:{preparation_endpoint.server_port}/responses",
            "--fault",
            "provider-prepare",
            accelerated_retries=False,
        )
        processes.append(preparation_host)
        preparation_session = configure(
            state,
            preparation_store,
            "preparation-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            preparation_store,
            "preparation-message",
            preparation_session,
            "known preparation failure",
        )

        def known_preparation_settled():
            observation = observe(preparation_store, "preparation-message")
            if observation.get("processing", {}).get("attempt") != "1":
                return None
            resources = command(
                "session", "inspect",
                "--store",
                preparation_store,
                "--session",
                preparation_session,
            )["execution"]
            if resources["custody_occupied"] != "0" or resources["dispatch_fenced"]:
                return None
            return observation, resources

        preparation_observation, preparation_resources = wait_for(
            known_preparation_settled,
            "publicly observed saved preparation failure",
            timeout=15,
        )
        assert preparation_observation["queue"]["status"] == "processing"
        assert preparation_resources["dispatch_fenced"] is False
        assert preparation_endpoint.requests == []
        preparation_crash = crash_host(
            preparation_host, state, "known-preparation-crash"
        )
        processes.remove(preparation_host)
        assert preparation_crash["returncode"] == -signal.SIGKILL, {
            "crash": preparation_crash,
            "endpoint_requests": preparation_endpoint.requests,
            "state": str(state),
        }
        database = sqlite3.connect(preparation_store / "rui.sqlite3")
        try:
            preparation_fact = database.execute(
                "SELECT attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code FROM model_operation"
            ).fetchone()
        finally:
            database.close()
        (state / "known-preparation-crash.json").write_text(
            json.dumps(
                {
                    "returncode": preparation_crash["returncode"],
                    "endpoint_request_count": len(preparation_endpoint.requests),
                    "offline_row": preparation_fact,
                },
                indent=2,
            )
            + "\n"
        )
        assert preparation_fact[:3] == (1, 1, 0), {
            "row": preparation_fact,
            "crash": preparation_crash,
            "state": str(state),
        }
        assert preparation_fact[3] > 0, preparation_fact
        assert preparation_fact[4:] == ("provider_transport_failure", None), preparation_fact
        preparation_host = start_host(
            preparation_store,
            f"http://127.0.0.1:{preparation_endpoint.server_port}/responses",
            accelerated_retries=False,
        )
        processes.append(preparation_host)
        wait_for(
            lambda: completed_observation(preparation_store, "preparation-message"),
            "known preparation retry",
        )
        assert observe(preparation_store, "preparation-message")["processing"]["attempt"] == "2"
        assert len(preparation_endpoint.requests) == 1
        resources = command(
            "session", "inspect",
            "--store",
            preparation_store,
            "--session",
            preparation_session,
        )["execution"]
        assert resources["dispatch_fenced"] is False, resources
        stop_host(preparation_host)
        processes.remove(preparation_host)
        stop_endpoint(preparation_endpoint, endpoints)

        # Fresh processes are terminated after committed Attempt admission,
        # launch, sealed validation input, and final result commit. Only the
        # committed boundary is recovered; old permits and scratch never are.
        prelaunch_sse = sse_answer(
            "prelaunch-recovered", "prelaunch-r", "prelaunch-m", "prelaunch answer"
        )[0]
        prelaunch_endpoint = SuccessEndpoint([prelaunch_sse])
        prelaunch_thread = threading.Thread(
            target=prelaunch_endpoint.serve_forever, daemon=True
        )
        endpoints[prelaunch_endpoint] = prelaunch_thread
        prelaunch_thread.start()
        prelaunch_store = state / "crash-prelaunch-store"
        prelaunch_host = start_host(
            prelaunch_store,
            f"http://127.0.0.1:{prelaunch_endpoint.server_port}/responses",
            "--test-before-launch-delay-ms",
            "5000",
        )
        processes.append(prelaunch_host)
        prelaunch_session = configure(
            state, prelaunch_store, "prelaunch-config", None, "gpt-6-sol"
        )
        message(
            state,
            prelaunch_store,
            "prelaunch-message",
            prelaunch_session,
            "crash before launch",
        )

        def prelaunch_attempt_one():
            observation = observe(prelaunch_store, "prelaunch-message")
            return (
                observation
                if observation.get("processing", {}).get("attempt") == "1"
                else None
            )

        prelaunch_observation = wait_for(
            prelaunch_attempt_one,
            "publicly observed prelaunch Attempt 1",
        )
        assert prelaunch_observation["queue"]["status"] == "processing"
        assert prelaunch_endpoint.requests == []
        prelaunch_crash = crash_host(prelaunch_host, state, "prelaunch-crash")
        processes.remove(prelaunch_host)
        assert prelaunch_crash["returncode"] == -signal.SIGKILL, {
            "crash": prelaunch_crash,
            "endpoint_requests": prelaunch_endpoint.requests,
            "state": str(state),
        }
        database = sqlite3.connect(prelaunch_store / "rui.sqlite3")
        try:
            prelaunch_fact = database.execute(
                "SELECT attempt_ordinal,allowance_used,uncertain,resolution_code FROM model_operation"
            ).fetchone()
        finally:
            database.close()
        (state / "prelaunch-crash.json").write_text(
            json.dumps(
                {
                    "returncode": prelaunch_crash["returncode"],
                    "endpoint_request_count": len(prelaunch_endpoint.requests),
                    "offline_row": prelaunch_fact,
                },
                indent=2,
            )
            + "\n"
        )
        assert prelaunch_fact == (1, 1, 1, None), {
            "row": prelaunch_fact,
            "crash": prelaunch_crash,
            "state": str(state),
        }
        prelaunch_host = start_host(
            prelaunch_store,
            f"http://127.0.0.1:{prelaunch_endpoint.server_port}/responses",
        )
        processes.append(prelaunch_host)
        wait_for(
            lambda: completed_observation(prelaunch_store, "prelaunch-message"),
            "prelaunch replacement",
        )
        assert observe(prelaunch_store, "prelaunch-message")["processing"]["attempt"] == "2"
        assert len(prelaunch_endpoint.requests) == 1
        resources = command(
            "session", "inspect",
            "--store",
            prelaunch_store,
            "--session",
            prelaunch_session,
        )["execution"]
        assert resources["dispatch_fenced"] is False, resources
        stop_host(prelaunch_host)
        processes.remove(prelaunch_host)
        stop_endpoint(prelaunch_endpoint, endpoints)

        launched_release = threading.Event()
        releases.append(launched_release.set)
        launched_lost = sse_answer(
            "launched-lost", "launched-lost-r", "launched-lost-m", "lost answer"
        )[0]
        launched_recovered = sse_answer(
            "launched-recovered",
            "launched-recovered-r",
            "launched-recovered-m",
            "launched answer",
        )[0]
        launched_endpoint = SuccessEndpoint(
            [(launched_lost, launched_release), launched_recovered]
        )
        launched_thread = threading.Thread(
            target=launched_endpoint.serve_forever, daemon=True
        )
        endpoints[launched_endpoint] = launched_thread
        launched_thread.start()
        launched_store = state / "crash-launched-store"
        launched_host = start_host(
            launched_store,
            f"http://127.0.0.1:{launched_endpoint.server_port}/responses",
        )
        processes.append(launched_host)
        launched_session = configure(
            state, launched_store, "launched-config", None, "gpt-6-sol"
        )
        message(
            state,
            launched_store,
            "launched-message",
            launched_session,
            "crash after launch",
        )
        wait_for(lambda: len(launched_endpoint.requests) == 1, "launched Attempt")
        stop_host(launched_host)
        processes.remove(launched_host)
        launched_release.set()
        launched_host = start_host(
            launched_store,
            f"http://127.0.0.1:{launched_endpoint.server_port}/responses",
        )
        processes.append(launched_host)
        wait_for(
            lambda: completed_observation(launched_store, "launched-message"),
            "launched replacement",
        )
        assert read_result(launched_store, "launched-message") == b"launched answer"
        assert len(launched_endpoint.requests) == 2
        stop_host(launched_host)
        processes.remove(launched_host)
        stop_endpoint(launched_endpoint, endpoints)

        sealed_lost = sse_answer(
            "sealed-lost", "sealed-lost-r", "sealed-lost-m", "lost sealed answer"
        )[0]
        sealed_recovered = sse_answer(
            "sealed-recovered", "sealed-r", "sealed-m", "sealed answer"
        )[0]
        sealed_endpoint = SuccessEndpoint([sealed_lost, sealed_recovered])
        sealed_thread = threading.Thread(target=sealed_endpoint.serve_forever, daemon=True)
        endpoints[sealed_endpoint] = sealed_thread
        sealed_thread.start()
        sealed_store = state / "crash-sealed-store"
        sealed_host = start_host(
            sealed_store,
            f"http://127.0.0.1:{sealed_endpoint.server_port}/responses",
            "--test-before-result-delay-ms",
            "5000",
        )
        processes.append(sealed_host)
        sealed_session = configure(state, sealed_store, "sealed-config", None, "gpt-6-sol")
        message(
            state,
            sealed_store,
            "sealed-message",
            sealed_session,
            "crash after seal",
        )
        wait_for(lambda: len(sealed_endpoint.requests) == 1, "sealed response delivery")
        time.sleep(0.5)
        sealed_observation = observe(sealed_store, "sealed-message")
        assert sealed_observation["processing"]["attempt"] == "1" and "result" not in sealed_observation, sealed_observation
        stop_host(sealed_host)
        processes.remove(sealed_host)
        database = sqlite3.connect(sealed_store / "rui.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,uncertain,resolution_code FROM model_operation"
        ).fetchone() == (1, 1, None)
        assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
        database.close()
        sealed_host = start_host(
            sealed_store,
            f"http://127.0.0.1:{sealed_endpoint.server_port}/responses",
        )
        processes.append(sealed_host)
        wait_for(
            lambda: completed_observation(sealed_store, "sealed-message"),
            "sealed replacement",
        )
        assert read_result(sealed_store, "sealed-message") == b"sealed answer"
        assert len(sealed_endpoint.requests) == 2
        stop_host(sealed_host)
        processes.remove(sealed_host)
        stop_endpoint(sealed_endpoint, endpoints)

        committed_sse = sse_answer(
            "committed-response", "committed-r", "committed-m", "committed answer"
        )[0]
        committed_endpoint = SuccessEndpoint([committed_sse])
        committed_thread = threading.Thread(
            target=committed_endpoint.serve_forever, daemon=True
        )
        endpoints[committed_endpoint] = committed_thread
        committed_thread.start()
        committed_store = state / "crash-committed-store"
        committed_host = start_host(
            committed_store,
            f"http://127.0.0.1:{committed_endpoint.server_port}/responses",
        )
        processes.append(committed_host)
        committed_session = configure(
            state, committed_store, "committed-config", None, "gpt-6-sol"
        )
        message(
            state,
            committed_store,
            "committed-message",
            committed_session,
            "crash after result commit",
        )
        wait_for(
            lambda: completed_observation(committed_store, "committed-message"),
            "committed result",
        )
        stop_host(committed_host)
        processes.remove(committed_host)
        committed_host = start_host(
            committed_store,
            f"http://127.0.0.1:{committed_endpoint.server_port}/responses",
        )
        processes.append(committed_host)
        assert read_result(committed_store, "committed-message") == b"committed answer"
        time.sleep(1.2)
        assert len(committed_endpoint.requests) == 1
        stop_host(committed_host)
        processes.remove(committed_host)
        stop_endpoint(committed_endpoint, endpoints)

        # Full execution capacity leaves later work as only a durable queued
        # admission: no Attempt, request scratch, or resident waiter appears.
        # Releasing custody is sufficient to make progress without a new
        # message or notification.
        capacity_release = threading.Event()
        releases.append(capacity_release.set)
        capacity_answer = sse_answer(
            "capacity-release-response",
            "capacity-release-r",
            "capacity-release-m",
            "capacity released",
        )[0]
        capacity_endpoint = SuccessEndpoint(
            [
                (ResponseSpec(b"permanent", {}, 422), capacity_release),
                capacity_answer,
            ]
        )
        capacity_thread = threading.Thread(
            target=capacity_endpoint.serve_forever, daemon=True
        )
        endpoints[capacity_endpoint] = capacity_thread
        capacity_thread.start()
        durable_wait_store = state / "durable-capacity-wait-store"
        durable_wait_host = start_host(
            durable_wait_store,
            f"http://127.0.0.1:{capacity_endpoint.server_port}/responses",
            "--test-phase-trace", observations="control_peers",
        )
        processes.append(durable_wait_host)
        capacity_peers = PeerCensus(HostDiagnostics(durable_wait_host))
        capacity_wait_a_session = capacity_peers.call("configure", lambda: configure(
            state,
            durable_wait_store,
            "capacity-wait-config-a",
            None,
            "gpt-6-sol",
        ))
        capacity_wait_b_session = capacity_peers.call("configure", lambda: configure(
            state,
            durable_wait_store,
            "capacity-wait-config-b",
            None,
            "gpt-6-sol",
        ))
        capacity_peers.call("message", lambda: message(
            state,
            durable_wait_store,
            "capacity-wait-message-a",
            capacity_wait_a_session,
            "occupy capacity",
        ))
        wait_for(lambda: len(capacity_endpoint.requests) == 1, "occupied capacity")
        # The provider gate holds model scratch, not preceding ingress/report
        # owners. Retire each exchange before either accounting snapshot.
        scratch_before = capacity_peers.call("inspect", lambda: command(
            "session", "inspect",
            "--store",
            durable_wait_store,
            "--session",
            capacity_wait_a_session,
        ))["execution"]["scratch_used_bytes"]
        capacity_peers.call("message", lambda: message(
            state,
            durable_wait_store,
            "capacity-wait-message-b",
            capacity_wait_b_session,
            "wait durably",
        ))
        scratch_after = capacity_peers.call("inspect", lambda: command(
            "session", "inspect",
            "--store",
            durable_wait_store,
            "--session",
            capacity_wait_b_session,
        ))["execution"]["scratch_used_bytes"]
        assert scratch_after == scratch_before, (scratch_before, scratch_after)
        queued_observation = capacity_peers.call("observe", lambda: observe(durable_wait_store, "capacity-wait-message-b"))
        assert queued_observation["queue"]["status"] == "queued" and "processing" not in queued_observation, queued_observation
        assert len(capacity_endpoint.requests) == 1
        capacity_release_started = time.monotonic()
        capacity_release.set()
        wait_for(
            lambda: len(capacity_endpoint.requests) == 2,
            "capacity release discovery without notification",
            timeout=8,
        )
        capacity_release_discovery_ms = (
            time.monotonic() - capacity_release_started
        ) * 1000
        capacity_deadline = time.monotonic() + 8
        wait_for(
            lambda: capacity_peers.call("observe", lambda: completed_observation(
                durable_wait_store, "capacity-wait-message-b", deadline=capacity_deadline,
            ), deadline=capacity_deadline),
            "capacity release progress without notification",
            deadline=capacity_deadline,
        )
        assert capacity_peers.call("read_result", lambda: read_result(
            durable_wait_store, "capacity-wait-message-b"
        )) == b"capacity released"
        assert len(capacity_endpoint.requests) == 2
        print(
            "queued capacity-release discovery (diagnostic): "
            f"{capacity_release_discovery_ms:.1f} ms"
        )
        stop_host(durable_wait_host)
        capacity_peers.finish(time.monotonic() + 5)
        processes.remove(durable_wait_host)
        stop_endpoint(capacity_endpoint, endpoints)

        # Retry selection is taken only when execution capacity is available.
        # A candidate observed while full cannot survive until release and
        # bypass an older Operation that becomes due in the meantime.
        stale_release = threading.Event()
        newer_initial_release = threading.Event()
        releases.extend((newer_initial_release.set, stale_release.set))
        stale_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"older waiting", {"Retry-After": "3"}, 503),
                (
                    ResponseSpec(b"newer waiting", {"Retry-After": "1"}, 503),
                    newer_initial_release,
                ),
                (ResponseSpec(b"capacity owner", {}, 422), stale_release),
                ResponseSpec(b"selected after release", {}, 422),
                ResponseSpec(b"remaining retry", {}, 422),
            ]
        )
        stale_thread = threading.Thread(target=stale_endpoint.serve_forever, daemon=True)
        endpoints[stale_endpoint] = stale_thread
        stale_thread.start()
        stale_store = state / "retry-release-order-store"
        stale_host = start_host(
            stale_store,
            f"http://127.0.0.1:{stale_endpoint.server_port}/responses",
            "--test-retry-waits-ms",
            "50,100,150",
        )
        processes.append(stale_host)
        for name in ("older", "newer"):
            expected_requests = len(stale_endpoint.requests) + 1
            session = configure(
                state,
                stale_store,
                f"stale-{name}-config",
                None,
                "gpt-6-sol",
            )
            message(
                state,
                stale_store,
                f"stale-{name}-message",
                session,
                f"stale-{name}",
            )
            wait_for(
                lambda expected=expected_requests: len(stale_endpoint.requests) >= expected,
                f"{name} initial Attempt",
            )
        stale_capacity_session = configure(
            state,
            stale_store,
            "stale-capacity-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            stale_store,
            "stale-capacity-message",
            stale_capacity_session,
            "stale-capacity",
        )
        time.sleep(0.2)
        assert len(stale_endpoint.requests) == 2
        newer_initial_release.set()
        wait_for(lambda: len(stale_endpoint.requests) == 3, "capacity owner initial Attempt")
        time.sleep(3.2)
        stale_release.set()
        wait_for(
            lambda: len(stale_endpoint.requests) >= 4,
            "retry after capacity release",
            timeout=8,
        )
        released_request = json.loads(stale_endpoint.requests[3])
        released_user_text = next(
            content["text"]
            for item in released_request["input"]
            if item.get("role") == "user"
            for content in item["content"]
            if content.get("type") == "input_text"
        )
        assert released_user_text == "stale-older", released_user_text
        stop_host(stale_host)
        processes.remove(stale_host)
        stop_endpoint(stale_endpoint, endpoints)

        # The smallest age-indexed selector keeps no scan state. With one live
        # transport and a second permitted H1 connection it still finds a due
        # Operation behind 100 older future retries within the light-discovery target.
        backlog_stall_release = threading.Event()
        backlog_retry_release = threading.Event()
        releases.extend((backlog_retry_release.set, backlog_stall_release.set))
        backlog_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"initial temporary failure", {}, 503),
                (ResponseSpec(b"stalled live request", {}, 422), backlog_stall_release),
                (ResponseSpec(b"selected retry", {}, 422), backlog_retry_release),
            ]
        )
        backlog_thread = threading.Thread(target=backlog_endpoint.serve_forever, daemon=True)
        endpoints[backlog_endpoint] = backlog_thread
        backlog_thread.start()
        backlog_store = state / "retry-age-backlog-store"
        # An offline Host queues the admission without dispatching it.
        backlog_host = start_host(backlog_store, None)
        processes.append(backlog_host)
        backlog_session = configure(state, backlog_store, "backlog-config", None, "gpt-6-sol")
        message(
            state,
            backlog_store,
            "backlog-message",
            backlog_session,
            "due-behind-future-history",
        )
        time.sleep(0.2)
        assert backlog_endpoint.requests == []
        backlog_history = [configure(state, backlog_store, f"backlog-history-{index}", None, "gpt-6-sol")
                           for index in range(1, 101)]
        stop_host(backlog_host)
        processes.remove(backlog_host)
        database = sqlite3.connect(backlog_store / "rui.sqlite3")
        try:
            database.execute("PRAGMA foreign_keys=OFF")
            database.executemany(
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,"
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) "
                "VALUES(?,?,?,1,1,1,1,1,0,9223372036854775807,0)",
                [(index, index, session) for index, session in enumerate(backlog_history, 1)],
            )
            database.commit()
        finally:
            database.close()
        backlog_host = start_host(
            backlog_store,
            f"http://127.0.0.1:{backlog_endpoint.server_port}/responses",
            "--active-capacity",
            "101",
            "--test-retry-waits-ms",
            "2000,60000,60000",
        )
        processes.append(backlog_host)
        wait_for(lambda: len(backlog_endpoint.requests) == 1, "future-backlog initial Attempt")
        backlog_stall_session = configure(
            state,
            backlog_store,
            "backlog-stall-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            backlog_store,
            "backlog-stall-message",
            backlog_stall_session,
            "occupy-one-slot",
        )
        wait_for(lambda: len(backlog_endpoint.requests) >= 2, "stalled live backlog request")
        wait_for(
            lambda: len(backlog_endpoint.requests) >= 3,
            "due retry behind future history",
            timeout=5,
        )
        discovery_upper_bound = (
            backlog_endpoint.request_times[2] - backlog_endpoint.request_times[0] - 2.0
        )
        assert discovery_upper_bound < 2.0, discovery_upper_bound
        selected_request = json.loads(backlog_endpoint.requests[2])
        selected_user_text = next(
            content["text"]
            for item in selected_request["input"]
            if item.get("role") == "user"
            for content in item["content"]
            if content.get("type") == "input_text"
        )
        assert selected_user_text == "due-behind-future-history", selected_user_text
        backlog_retry_release.set()
        backlog_stall_release.set()
        stop_host(backlog_host)
        processes.remove(backlog_host)
        stop_endpoint(backlog_endpoint, endpoints)

        # Exhausted recovery and admission are independent work in one Host
        # turn. A due retry and then queued new work both receive free custody
        # while a high-age exhausted sentinel proves the restart backlog is
        # still unresolved; ordinary inspection progresses and recovery
        # eventually drains.
        recovery_retry_release = threading.Event()
        recovery_new_release = threading.Event()
        releases.extend((recovery_retry_release.set, recovery_new_release.set))
        recovery_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"retry later", {}, 503),
                ResponseSpec(b"sentinel retry later", {}, 503),
                (ResponseSpec(b"retried", {}, 422, gate_timeout=30), recovery_retry_release),
                (ResponseSpec(b"new work", {}, 422, gate_timeout=30), recovery_new_release),
            ]
        )
        recovery_thread = threading.Thread(
            target=recovery_endpoint.serve_forever, daemon=True
        )
        endpoints[recovery_endpoint] = recovery_thread
        recovery_thread.start()
        recovery_store = state / "exhausted-control-store"
        recovery_host = start_host(recovery_store, None)
        processes.append(recovery_host)
        recovery_history = [configure(state, recovery_store, f"recovery-history-{index}", None, "gpt-6-sol")
                            for index in range(1, 101)]
        stop_host(recovery_host)
        processes.remove(recovery_host)
        database = sqlite3.connect(recovery_store / "rui.sqlite3")
        try:
            database.execute("PRAGMA foreign_keys=OFF")
            database.executemany(
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,"
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) "
                "VALUES(?,?,?,1,1,1,1,1,0,9223372036854775807,0)",
                [(index, index, session) for index, session in enumerate(recovery_history, 1)],
            )
            database.commit()
        finally:
            database.close()
        recovery_host = start_host(
            recovery_store,
            f"http://127.0.0.1:{recovery_endpoint.server_port}/responses",
            "--active-capacity",
            "2",
            "--test-retry-waits-ms",
            "60000,60000,60000",
        )
        processes.append(recovery_host)
        recovery_sessions = {}
        for name in ("due", "sentinel"):
            recovery_sessions[name] = configure(
                state,
                recovery_store,
                f"recovery-{name}-config",
                None,
                "gpt-6-sol",
            )
            message(
                state,
                recovery_store,
                f"recovery-{name}-message",
                recovery_sessions[name],
                f"recovery-{name}",
            )
        wait_for(lambda: len(recovery_endpoint.requests) == 2, "recovery setup Attempts")
        wait_for(
            lambda: command(
                "session", "inspect",
                "--store",
                recovery_store,
                "--session",
                recovery_sessions["sentinel"],
            )["execution"]["custody_occupied"]
            == "0",
            "recovery setup cleanup",
        )
        stop_host(recovery_host)
        processes.remove(recovery_host)
        recovery_host = start_host(recovery_store, None)
        processes.append(recovery_host)
        recovery_new_session = configure(
            state,
            recovery_store,
            "recovery-new-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            recovery_store,
            "recovery-new-message",
            recovery_new_session,
            "recovery-new",
        )
        time.sleep(0.2)
        assert len(recovery_endpoint.requests) == 2
        stop_host(recovery_host)
        processes.remove(recovery_host)
        database = sqlite3.connect(recovery_store / "rui.sqlite3")
        try:
            database.execute("PRAGMA foreign_keys=OFF")
            due_operation = database.execute(
                "SELECT operation_id FROM model_operation WHERE session_ref=?", (recovery_sessions["due"],)
            ).fetchone()[0]
            sentinel_operation = database.execute(
                "SELECT operation_id FROM model_operation WHERE session_ref=?", (recovery_sessions["sentinel"],)
            ).fetchone()[0]
            database.execute(
                "UPDATE model_operation SET attempt_ordinal=4,allowance_used=4,uncertain=1,retry_due_at_ms=0 "
                "WHERE operation_id<=100 OR operation_id=?",
                (sentinel_operation,),
            )
            database.execute(
                "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?",
                (due_operation,),
            )
            database.executemany(
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) "
                "VALUES(?,?,1,1,?)",
                [(index + 10000, session, index) for index, session in enumerate(recovery_history, 1)],
            )
            database.execute(
                "UPDATE model_operation SET turn_id=operation_id+10000 WHERE operation_id<=100"
            )
            database.commit()
        finally:
            database.close()
        recovery_gate = ReleaseGate(state / "exhausted-recovery-gate")
        releases.append(recovery_gate.release)
        recovery_host = start_host(
            recovery_store,
            f"http://127.0.0.1:{recovery_endpoint.server_port}/responses",
            "--active-capacity",
            "101",
            "--test-retry-recovery-gate-path",
            str(recovery_gate.path),
            "--test-before-launch-delay-ms",
            "100",
            "--test-retry-waits-ms",
            "60000,60000,60000",
        )
        processes.append(recovery_host)
        recovery_diagnostics = HostDiagnostics(recovery_host)
        recovery_diagnostics.wait("exhausted_retry_recovery_held", timeout=10,
                                  subject_kind="path", subject=str(recovery_gate.path))
        recovery_gate.assert_held()
        due_admitted = wait_for(
            lambda: (
                value
                if (value := observe(recovery_store, "recovery-due-message"))
                .get("processing", {})
                .get("attempt")
                == "2"
                else None
            ),
            "due retry admitted during exhausted recovery",
        )
        assert "result" not in due_admitted, due_admitted
        unresolved_sentinel = observe(recovery_store, "recovery-sentinel-message")
        assert unresolved_sentinel["processing"]["attempt"] == "4", unresolved_sentinel
        assert "result" not in unresolved_sentinel, unresolved_sentinel
        inspection = command(
            "session", "inspect",
            "--store",
            recovery_store,
            "--session",
            recovery_sessions["sentinel"],
        )
        assert inspection["execution"]["dispatch_fenced"] is False, inspection
        try:
            wait_for(lambda: len(recovery_endpoint.requests) >= 3, "recovery retry launch")
            new_admitted = wait_for(
                lambda: (
                    value
                    if (value := observe(recovery_store, "recovery-new-message"))[
                        "queue"
                    ]["status"]
                    == "processing"
                    else None
                ),
                "new admission during exhausted recovery",
            )
            assert new_admitted["processing"]["attempt"] == "1", new_admitted
            wait_for(lambda: len(recovery_endpoint.requests) >= 4, "recovery new launch")
            # Both attempts must remain in flight while their responses are
            # held. Global custody may also contain a transient reservation
            # while the Host probes the Store for more work.
            for key, attempt in (("recovery-due-message", "2"), ("recovery-new-message", "1")):
                held = observe(recovery_store, key)
                assert held["processing"]["attempt"] == attempt, held
                assert "result" not in held, held
            assert "result" not in observe(
                recovery_store, "recovery-sentinel-message"
            ), unresolved_sentinel
            recovery_gate.assert_held()
        finally:
            recovery_gate.release()
            recovery_retry_release.set()
            recovery_new_release.set()
        recovery_latencies = []
        recovery_deadline = time.monotonic() + 30
        sentinel_terminal = None
        while time.monotonic() < recovery_deadline:
            recovery_observation_started = time.monotonic()
            sentinel_observation = observe(
                recovery_store, "recovery-sentinel-message"
            )
            recovery_latency = time.monotonic() - recovery_observation_started
            if (
                sentinel_observation.get("result", {}).get("code")
                == "retry_exhausted"
            ):
                sentinel_terminal = sentinel_observation
                break
            assert (
                sentinel_observation["processing"]["attempt"] == "4"
            ), sentinel_observation
            recovery_latencies.append(recovery_latency)
        assert sentinel_terminal is not None
        if recovery_latencies:
            ordered_latencies = sorted(recovery_latencies)
            recovery_p95 = ordered_latencies[
                (95 * len(ordered_latencies) + 99) // 100 - 1
            ]
            print(
                "exhausted recovery ordinary inspections (diagnostic only): "
                f"samples={len(recovery_latencies)} "
                f"p95_ms={recovery_p95 * 1000:.1f} "
                f"max_ms={ordered_latencies[-1] * 1000:.1f}"
            )
        else:
            print("exhausted recovery ordinary inspections: latency unavailable; "
                  "recovery settled before the first nonterminal observation")
        for key in ("recovery-due-message", "recovery-new-message"):
            wait_for(
                lambda: observe(recovery_store, key).get("result", {}).get("code")
                == "provider_http_422",
                f"released {key} settlement",
            )
        wait_for(
            lambda: command(
                "session", "inspect", "--store", recovery_store,
                "--session", recovery_new_session,
            )["execution"]["custody_occupied"] == "0",
            "recovery custody drainage",
        )
        stop_host(recovery_host)
        processes.remove(recovery_host)
        database = sqlite3.connect(recovery_store / "rui.sqlite3")
        try:
            assert database.execute(
                "SELECT count(*) FROM model_operation WHERE uncertain=1 AND allowance_used=4 "
                "AND retry_due_at_ms=0 AND resolution_code IS NULL"
            ).fetchone()[0] == 0
        finally:
            database.close()
        stop_endpoint(recovery_endpoint, endpoints)

        # Exhaustion settles only the selected prefix. Input admitted while
        # those retries run remains unselected and receives the outcome of the
        # successor Turn that eventually takes it.
        exhaustion_release = threading.Event()
        releases.append(exhaustion_release.set)
        exhaustion_answer = sse_answer(
            "exhaustion-success",
            "exhaustion-success-r",
            "exhaustion-success-m",
            "later input answer",
        )[0]
        exhaustion_endpoint = SuccessEndpoint(
            [
                (ResponseSpec(b"temporary-1", {}, 503), exhaustion_release),
                ResponseSpec(b"temporary-2", {}, 503),
                ResponseSpec(b"temporary-3", {}, 503),
                ResponseSpec(b"temporary-4", {}, 503),
                exhaustion_answer,
            ]
        )
        exhaustion_thread = threading.Thread(
            target=exhaustion_endpoint.serve_forever, daemon=True
        )
        endpoints[exhaustion_endpoint] = exhaustion_thread
        exhaustion_thread.start()
        exhaustion_store = state / "retry-exhaustion-store"
        exhaustion_host = start_host(
            exhaustion_store,
            f"http://127.0.0.1:{exhaustion_endpoint.server_port}/responses",
        )
        processes.append(exhaustion_host)
        exhaustion_session = configure(
            state,
            exhaustion_store,
            "exhaustion-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            exhaustion_store,
            "exhaustion-first",
            exhaustion_session,
            "selected first",
        )
        wait_for(lambda: len(exhaustion_endpoint.requests) == 1, "first exhaustion Attempt")
        message(
            state,
            exhaustion_store,
            "exhaustion-later",
            exhaustion_session,
            "unselected later",
        )
        assert observe(exhaustion_store, "exhaustion-later")["queue"]["status"] == "queued"
        exhaustion_release.set()
        exhausted = wait_for(
            lambda: (
                value := observe(exhaustion_store, "exhaustion-first")
            ).get("result", {}).get("code")
            == "retry_exhausted"
            and value,
            "retry exhaustion",
            timeout=10,
        )
        assert exhausted["processing"]["attempt"] == "4", exhausted
        wait_for(
            lambda: completed_observation(exhaustion_store, "exhaustion-later"),
            "unselected input successor",
            timeout=8,
        )
        assert observe(exhaustion_store, "exhaustion-first")["result"]["code"] == "retry_exhausted"
        assert read_result(exhaustion_store, "exhaustion-later") == b"later input answer"
        assert len(exhaustion_endpoint.requests) == 5
        stop_host(exhaustion_host)
        processes.remove(exhaustion_host)
        database = sqlite3.connect(exhaustion_store / "rui.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,allowance_used,resolution_code FROM model_operation ORDER BY operation_id"
        ).fetchall() == [(4, 4, "retry_exhausted"), (1, 1, "answer")]
        database.close()
        stop_endpoint(exhaustion_endpoint, endpoints)

        # One reactor fills two fixed custody records without allocating a
        # worker per Session. Complete beta first and verify that the opaque
        # completion identity settles beta's binding while alpha remains live.
        alpha_release = threading.Event()
        beta_release = threading.Event()
        releases.extend((beta_release.set, alpha_release.set))
        capacity_endpoint = SuccessEndpoint(
            [],
            responses_by_input={
                "alpha": (
                    sse_answer("capacity-alpha", "capacity-alpha-r", "capacity-alpha-m", "alpha answer")[0],
                    alpha_release,
                ),
                "beta": (
                    sse_answer("capacity-beta", "capacity-beta-r", "capacity-beta-m", "beta answer")[0],
                    beta_release,
                ),
            },
        )
        capacity_thread = threading.Thread(target=capacity_endpoint.serve_forever, daemon=True)
        endpoints[capacity_endpoint] = capacity_thread
        capacity_thread.start()
        capacity_store = state / "capacity-store"
        host = start_host(
            capacity_store,
            f"http://127.0.0.1:{capacity_endpoint.server_port}/responses",
            "--active-capacity",
            "101",
        )
        processes.append(host)
        capacity_a_session = configure(state, capacity_store, "capacity-config-a", None, "gpt-6-sol")
        capacity_b_session = configure(state, capacity_store, "capacity-config-b", None, "gpt-6-sol")
        message(state, capacity_store, "capacity-message-a", capacity_a_session, "alpha")
        message(state, capacity_store, "capacity-message-b", capacity_b_session, "beta")
        wait_for(lambda: len(capacity_endpoint.requests) == 2, "two concurrent reactor requests")
        beta_release.set()
        wait_for(
            lambda: completed_observation(capacity_store, "capacity-message-b"),
            "second concurrent request completing first",
        )
        alpha_pending = observe(capacity_store, "capacity-message-a")
        assert alpha_pending["queue"]["status"] == "processing", alpha_pending
        assert "result" not in alpha_pending, alpha_pending
        assert read_result(capacity_store, "capacity-message-b") == b"beta answer"
        alpha_release.set()
        wait_for(
            lambda: completed_observation(capacity_store, "capacity-message-a"),
            "first concurrent request completing second",
        )
        assert read_result(capacity_store, "capacity-message-a") == b"alpha answer"
        assert len(capacity_endpoint.requests) == 2
        stop_host(host)
        processes.remove(host)
        stop_endpoint(capacity_endpoint, endpoints)

        # H1 loopback is still supported, but a capacity-two Host now has
        # only one provider connection. The second admitted Attempt waits in
        # curl, then drains after the first releases it rather than spinning
        # or opening a second socket.
        h1_release = threading.Event()
        releases.append(h1_release.set)
        h1_endpoint = SuccessEndpoint(
            [],
            responses_by_input={
                "first": (sse_answer("h1-first", "h1-first-r", "gpt-6-sol", "first answer")[0], h1_release),
                "second": sse_answer("h1-second", "h1-second-r", "gpt-6-sol", "second answer")[0],
            },
        )
        h1_thread = threading.Thread(target=h1_endpoint.serve_forever, daemon=True)
        endpoints[h1_endpoint] = h1_thread
        h1_thread.start()
        h1_store = state / "h1-queued-store"
        h1_host = start_host(
            h1_store,
            f"http://127.0.0.1:{h1_endpoint.server_port}/responses",
            "--active-capacity",
            "2",
        )
        processes.append(h1_host)
        h1_first_session = configure(state, h1_store, "h1-config-first", None, "gpt-6-sol")
        h1_second_session = configure(state, h1_store, "h1-config-second", None, "gpt-6-sol")
        message(state, h1_store, "h1-message-first", h1_first_session, "first")
        wait_for(lambda: len(h1_endpoint.requests) == 1, "first H1 request")
        message(state, h1_store, "h1-message-second", h1_second_session, "second")
        wait_for(
            lambda: command("session", "inspect", "--store", h1_store, "--session", h1_second_session)["execution"]["custody_occupied"] == "2",
            "second H1 Attempt queued under the connection bound",
        )
        assert len(h1_endpoint.requests) == 1, h1_endpoint.requests
        h1_release.set()
        wait_for(lambda: completed_observation(h1_store, "h1-message-second"), "queued H1 completion")
        assert read_result(h1_store, "h1-message-first") == b"first answer"
        assert read_result(h1_store, "h1-message-second") == b"second answer"
        assert len(h1_endpoint.requests) == 2
        stop_host(h1_host)
        processes.remove(h1_host)
        stop_endpoint(h1_endpoint, endpoints)

        # A capacity-waiting easy has no curl progress callback. Its Attempt
        # must still expire while the first H1 response makes steady progress.
        pacing_end = threading.Event()
        releases.append(pacing_end.set)
        slow_response = ResponseSpec(
            b"x" * 2048, {}, 422, chunk_delay=0.015, pacing_end=pacing_end
        )
        slow_endpoint = SuccessEndpoint([slow_response])
        slow_thread = threading.Thread(target=slow_endpoint.serve_forever, daemon=True)
        endpoints[slow_endpoint] = slow_thread
        slow_thread.start()
        slow_store = state / "h1-queue-deadline-store"
        slow_host = start_host(
            slow_store,
            f"http://127.0.0.1:{slow_endpoint.server_port}/responses",
            "--test-provider-inactivity-seconds", "1",
            "--test-retry-waits-ms", "60000,60000,60000",
            active_capacity=2,
        )
        processes.append(slow_host)
        slow_first_session = configure(state, slow_store, "slow-config-first", None, "gpt-6-sol")
        slow_second_session = configure(state, slow_store, "slow-config-second", None, "gpt-6-sol")
        message(state, slow_store, "slow-message-first", slow_first_session, "first")
        wait_for(lambda: len(slow_endpoint.requests) == 1, "progressing first H1 response")
        message(state, slow_store, "slow-message-second", slow_second_session, "second")
        wait_for(
            lambda: command("session", "inspect", "--store", slow_store, "--session", slow_second_session)["execution"]["custody_occupied"] == "2",
            "both H1 Attempts in custody",
        )
        wait_for(
            lambda: command("session", "inspect", "--store", slow_store, "--session", slow_second_session)["execution"]["custody_occupied"] == "1",
            "queued H1 Attempt releases custody on expiry",
        )
        assert len(slow_endpoint.requests) == 1, slow_endpoint.requests
        assert slow_response.body_finished_at is None
        assert slow_host.poll() is None, "Host exited during queued H1 expiry"
        pacing_end.set()
        slow_failure = wait_for(
            lambda: (value := observe(slow_store, "slow-message-first")).get("result", {}).get("code")
            == "provider_http_422"
            and value,
            "progressing H1 completion",
        )
        assert slow_failure["queue"]["status"] == "failed", slow_failure
        stop_host(slow_host)
        processes.remove(slow_host)
        with sqlite3.connect(slow_store / "rui.sqlite3") as database:
            retry = database.execute(
                "SELECT attempt_ordinal,uncertain,retry_due_at_ms FROM model_operation "
                "WHERE session_ref=?", (slow_second_session,)
            ).fetchone()
        assert retry[0] == 1 and retry[1] == 0 and retry[2] is not None, retry
        stop_endpoint(slow_endpoint, endpoints)

        # A failed Attempt commit rolls back all provenance, fences the Store
        # like any canonical save fault, and cannot produce an endpoint launch.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        rollback_store = state / "rollback-store"
        host = start_host(rollback_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        rollback_diagnostics = HostDiagnostics(host)
        rollback_session = configure(state, rollback_store, "rollback-config", None, "gpt-6-sol")
        message(state, rollback_store, "rollback-message", rollback_session, "rollback")
        host.wait(timeout=10)
        assert host.returncode != 0, rollback_diagnostics.tail()
        assert b"dispatch fenced after Attempt admission failure: InjectedAttemptCommitFailure" in rollback_diagnostics.tail()
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(rollback_store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT count(*),count(turn_id) FROM message_admission "
                "WHERE command_key='rollback-message'"
            ).fetchone() == (1, 0)
            assert database.execute(
                "SELECT count(*) FROM turn WHERE session_ref=?", (rollback_session,)
            ).fetchone() == (0,)
            assert database.execute(
                "SELECT count(*) FROM model_operation WHERE session_ref=?", (rollback_session,)
            ).fetchone() == (0,)
            assert database.execute(
                "SELECT count(*) FROM conversation_entry WHERE session_ref=?", (rollback_session,)
            ).fetchone() == (0,)

        # Retrying the original caller record after rollback recovers the one
        # queued admission. Only its later successful admission may dispatch.
        endpoint.release.set()
        host = start_host(rollback_store, url)
        processes.append(host)
        rollback_replay = retry_message(state, rollback_store, "rollback-message")
        assert rollback_replay["answer"]["status"] == "accepted", rollback_replay
        assert rollback_replay["answer"]["replayed"] is True, rollback_replay
        wait_for(lambda: len(endpoint.requests) == 1, "rollback retry dispatch")
        rollback_failed = wait_for(
            lambda: (value := observe(rollback_store, "rollback-message")).get("result")
            and value,
            "rollback retry result",
        )
        assert rollback_failed["processing"]["attempt"] == "1", rollback_failed
        assert rollback_failed["result"]["code"] == "provider_http_422", rollback_failed
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(rollback_store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT count(*),count(turn_id) FROM message_admission "
                "WHERE command_key='rollback-message'"
            ).fetchone() == (1, 1)
            assert database.execute(
                "SELECT count(*) FROM turn WHERE session_ref=?", (rollback_session,)
            ).fetchone() == (1,)
            assert database.execute(
                "SELECT count(*) FROM model_operation WHERE session_ref=?", (rollback_session,)
            ).fetchone() == (1,)
            assert database.execute(
                "SELECT count(*) FROM conversation_entry WHERE session_ref=? "
                "AND entry_kind=1", (rollback_session,)
            ).fetchone() == (1,)
        endpoint.requests.clear()
        endpoint.received.clear()
        endpoint.release.clear()

        # The first fallible post-commit step consumes Attempt 1, saves a typed
        # failure, releases custody, and never reaches HTTP. Original request
        # retries stay bound to that result after the Session advances.
        first_store = state / "first-step-store"
        host = start_host(first_store, url, "--fault", "request-first-step")
        processes.append(host)
        first_session = configure(state, first_store, "first-config", None, "gpt-6-sol")
        message(state, first_store, "first-message", first_session, "first step")
        failed = wait_for(
            lambda: (value := observe(first_store, "first-message"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "request_preparation_failed"
            and value,
            "saved first-step preparation failure",
        )
        assert failed["processing"]["attempt"] == "1", failed
        assert endpoint.requests == []
        first_processing = failed["processing"]
        first_replay = retry_message(state, first_store, "first-message")
        assert first_replay["answer"]["status"] == "accepted", first_replay
        assert first_replay["answer"]["replayed"] is True, first_replay
        assert observe(first_store, "first-message") == failed

        message(
            state,
            first_store,
            "first-later-message",
            first_session,
            "later input",
        )
        later_failed = wait_for(
            lambda: (value := observe(first_store, "first-later-message")).get("result", {}).get("code")
            == "request_preparation_failed"
            and value,
            "later saved first-step preparation failure",
        )
        assert later_failed["processing"]["attempt"] == "1", later_failed
        assert later_failed["processing"]["operation"] != first_processing["operation"], later_failed
        original_after_later = retry_message(state, first_store, "first-message")
        assert original_after_later["answer"]["status"] == "accepted", original_after_later
        assert original_after_later["answer"]["replayed"] is True, original_after_later
        assert observe(first_store, "first-message") == failed
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(first_store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT count(*),count(DISTINCT turn_id) FROM message_admission "
                "WHERE command_key IN ('first-message','first-later-message')"
            ).fetchone() == (2, 2)
            assert database.execute(
                "SELECT resolution_code FROM model_operation "
                "WHERE session_ref=? ORDER BY operation_id", (first_session,)
            ).fetchall() == [
                ("request_preparation_failed",),
                ("request_preparation_failed",),
            ]

        for fault, expected_code in (
            ("request-scratch-acquire", "request_scratch_exhausted"),
            ("request-write", "request_write_failed"),
            ("request-seal", "request_seal_failed"),
        ):
            fault_store = state / f"{fault}-store"
            host = start_host(
                fault_store, url, "--fault", fault,
                "--test-phase-trace", observations="control",
            )
            processes.append(host)
            fault_diagnostics = HostDiagnostics(host)
            session = configure(state, fault_store, f"{fault}-config", None, "gpt-6-sol")
            message(state, fault_store, f"{fault}-message", session, fault)
            fault_deadline = time.monotonic() + 8
            failed = wait_for(
                lambda key=f"{fault}-message", code=expected_code: (
                    value := observe(fault_store, key, deadline=fault_deadline)
                )["status"]
                == "accepted"
                and value.get("result", {}).get("code") == code
                and value,
                f"saved {fault} failure",
                deadline=fault_deadline,
            )
            assert failed["processing"]["attempt"] == "1", failed
            assert endpoint.requests == []
            wait_model_cleanup(
                fault_diagnostics, fault_store, session, failed, fault_deadline,
            )
            stop_host(host)
            assert_model_cleanup_census(fault_diagnostics, failed)
            processes.remove(host)

        # A canonical stop committed between resumable preparation advances
        # cancels that exact live owner before transport sees partial scratch.
        preparation_stop_endpoint = SuccessEndpoint(
            [sse_answer("preparation-stop-response", "preparation-stop-r", "preparation-stop-m", "must not launch")[0]]
        )
        preparation_stop_thread = threading.Thread(
            target=preparation_stop_endpoint.serve_forever, daemon=True
        )
        endpoints[preparation_stop_endpoint] = preparation_stop_thread
        preparation_stop_thread.start()
        preparation_stop_store = state / "preparation-stop-store"
        preparation_stop_host = start_host(
            preparation_stop_store,
            f"http://127.0.0.1:{preparation_stop_endpoint.server_port}/responses",
            "--test-phase-trace",
            "--test-request-preparation-advance-delay-ms",
            "1500",
            observations="dispatch",
        )
        processes.append(preparation_stop_host)
        preparation_stop_trace = HostDiagnostics(preparation_stop_host)
        preparation_stop_session = configure(
            state,
            preparation_stop_store,
            "preparation-stop-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            preparation_stop_store,
            "preparation-stop-message",
            preparation_stop_session,
            "p" * (64 * 1024),
        )
        preparation_stop_trace.wait("preparation_advance_completed")
        stopped_preparation = command(
            "session", "stop",
            "--store",
            preparation_stop_store,
            "--record",
            state / "preparation-stop.json",
            "--key",
            "preparation-stop",
            "--session",
            preparation_stop_session,
        )
        assert stopped_preparation["answer"]["status"] == "accepted", stopped_preparation
        stopped_resources = wait_for(
            lambda: (lambda value: value if value["execution"]["custody_occupied"] == "0"
                    and value["execution"]["scratch_used_bytes"] == "0" else None)(
                command(
                    "session", "inspect",
                    "--store",
                    preparation_stop_store,
                    "--session",
                    preparation_stop_session,
                )
            ),
            "preparation stop cleanup",
        )
        assert stopped_resources["execution"]["dispatch_fenced"] is False, stopped_resources
        assert preparation_stop_endpoint.requests == []
        stop_process(preparation_stop_host)
        processes.remove(preparation_stop_host)
        with sqlite3.connect(preparation_stop_store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,resolution_code FROM model_operation"
            ).fetchall() == [(1, "interrupted")]
            assert database.execute("SELECT outcome_code FROM turn").fetchall() == [("cancelled",)]
        stop_endpoint(preparation_stop_endpoint, endpoints)

        # Infrastructure shutdown owns the same cancellation path. Populate
        # durable work while execution is unavailable, then make the listener
        # fail after preparation has yielded. Restart admits Attempt 2 from
        # canonical uncertainty; the discarded cursor and scratch never launch.
        preparation_shutdown_sse = sse_answer(
            "preparation-shutdown-response",
            "preparation-shutdown-r",
            "preparation-shutdown-m",
            "prepared after shutdown",
        )[0]
        preparation_shutdown_endpoint = SuccessEndpoint([preparation_shutdown_sse])
        preparation_shutdown_thread = threading.Thread(
            target=preparation_shutdown_endpoint.serve_forever, daemon=True
        )
        endpoints[preparation_shutdown_endpoint] = preparation_shutdown_thread
        preparation_shutdown_thread.start()
        preparation_shutdown_store = state / "preparation-shutdown-store"
        offline_shutdown_host = start_host(preparation_shutdown_store, None)
        processes.append(offline_shutdown_host)
        preparation_shutdown_session = configure(
            state,
            preparation_shutdown_store,
            "preparation-shutdown-config",
            None,
            "gpt-6-sol",
        )
        message(
            state,
            preparation_shutdown_store,
            "preparation-shutdown-message",
            preparation_shutdown_session,
            "s" * (64 * 1024),
        )
        stop_host(offline_shutdown_host)
        processes.remove(offline_shutdown_host)
        preparation_shutdown_host = start_host(
            preparation_shutdown_store,
            f"http://127.0.0.1:{preparation_shutdown_endpoint.server_port}/responses",
            "--fault",
            "shutdown-after-accept",
            "--test-phase-trace",
            "--test-request-preparation-advance-delay-ms",
            "1500",
            accelerated_retries=False,
            observations="dispatch",
        )
        processes.append(preparation_shutdown_host)
        preparation_shutdown_trace = HostDiagnostics(preparation_shutdown_host)
        preparation_shutdown_trace.wait("preparation_advance_completed")
        shutdown_trigger = subprocess.run(
            [
                str(RUI),
                "session", "inspect",
                "--store",
                str(preparation_shutdown_store),
                "--session",
                preparation_shutdown_session,
            ],
            capture_output=True,
            timeout=10,
        )
        # The already-spawned client may finish while the listener owner is
        # beginning shutdown; its reply does not determine Host lifecycle.
        assert shutdown_trigger.returncode in (0, 1), shutdown_trigger
        assert preparation_shutdown_host.wait(timeout=10) != 0
        stop_process(preparation_shutdown_host)
        processes.remove(preparation_shutdown_host)
        assert preparation_shutdown_endpoint.requests == []
        assert not list((preparation_shutdown_store / "scratch").glob("provider-request-*.tmp"))
        preparation_shutdown_host = start_host(
            preparation_shutdown_store,
            f"http://127.0.0.1:{preparation_shutdown_endpoint.server_port}/responses",
            accelerated_retries=False,
        )
        processes.append(preparation_shutdown_host)
        recovered_shutdown = wait_for(
            lambda: completed_observation(
                preparation_shutdown_store, "preparation-shutdown-message"
            ),
            "preparation shutdown recovery",
        )
        assert recovered_shutdown["processing"]["attempt"] == "2", recovered_shutdown
        assert len(preparation_shutdown_endpoint.requests) == 1
        assert read_result(
            preparation_shutdown_store, "preparation-shutdown-message"
        ) == b"prepared after shutdown"
        stop_host(preparation_shutdown_host)
        processes.remove(preparation_shutdown_host)
        stop_endpoint(preparation_shutdown_endpoint, endpoints)

        # A canonical save fault rolls back the claimed failure, fences the
        # live dispatch owner, and leaves the admitted Attempt uncertain for
        # the following retry/restart slice rather than recreating its permit.
        endpoint.requests.clear()
        endpoint.release.set()
        save_store = state / "save-fault-store"
        host = start_host(save_store, url, "--fault", "result-before-commit")
        processes.append(host)
        save_session = configure(state, save_store, "save-config", None, "gpt-6-sol")
        message(state, save_store, "save-message", save_session, "save fault")
        wait_for(lambda: len(endpoint.requests) == 1, "save-fault endpoint request")
        time.sleep(0.2)
        failed_observation = subprocess.run(
            [str(RUI), "request", "inspect", "--store", str(save_store), "--key", "save-message"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert failed_observation.returncode != 0, failed_observation.stdout
        assert len(endpoint.requests) == 1
        stop_host(host)
        processes.remove(host)

        offline = start_host(save_store, None)
        processes.append(offline)
        uncertain = observe(save_store, "save-message")
        assert uncertain["queue"]["status"] == "processing", uncertain
        assert uncertain["processing"]["attempt"] == "1", uncertain
        assert "result" not in uncertain, uncertain
        stop_host(offline)
        processes.remove(offline)

        # Exact emitted request bytes, including the framing around many empty
        # inputs, are the complete reservation. The exact observed limit passes
        # while one byte below it fails before HTTP.
        def empty_messages(host, store, session, prefix):
            # Empty CLI stdin sends nothing. Seed these zero-byte framing
            # cases through the Message protocol without changing their input.
            from control_integration import raw_request
            for index in range(40):
                wire = {"version": "1", "kind": "message", "store": str(store),
                    "key": f"{prefix}-{index}", "session": session, "sender": None, "sender_handle": None,
                    "text": {"state": "value", "value": ""}}
                head, body = raw_request(host.rui_ready_fields["socket"], "/v1/message", json.dumps(wire, separators=(",", ":")).encode())
                assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["answer"]["status"] == "accepted", (head, body)

        endpoint.requests.clear()
        endpoint.release.clear()
        # Each request carries only its six-byte Session ID, so all three
        # cases have identical address framing regardless of their Store paths.
        framing_store = state / "framing-meter-store"
        host = start_host(framing_store, None)
        processes.append(host)
        framing_meter_session = configure(state, framing_store, "framing-config", None, "gpt-6-sol")
        empty_messages(host, framing_store, framing_meter_session, "framing")
        stop_host(host)
        processes.remove(host)
        host = start_host(framing_store, url)
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 1, "many-input materialization")
        actual_request_bytes = len(endpoint.requests[0])
        resources = command(
            "session", "inspect", "--store", framing_store, "--session", framing_meter_session
        )["execution"]
        assert int(resources["scratch_used_bytes"]) == actual_request_bytes, resources
        endpoint.release.set()
        wait_for(
            lambda: observe(framing_store, "framing-0").get("result", {}).get("code")
            == "provider_http_422",
            "many-input permanent failure",
        )
        stop_host(host)
        processes.remove(host)

        endpoint.requests.clear()
        endpoint.release.clear()
        framing_exact_store = state / "framing-exact-store"
        host = start_host(framing_exact_store, None)
        processes.append(host)
        framing_exact_session = configure(state, framing_exact_store, "exact-config", None, "gpt-6-sol")
        empty_messages(host, framing_exact_store, framing_exact_session, "exact")
        stop_host(host)
        processes.remove(host)
        host = start_host(
            framing_exact_store,
            url,
            "--test-request-scratch-limit",
            str(actual_request_bytes),
            "--test-phase-trace", observations="control",
        )
        processes.append(host)
        exact_diagnostics = HostDiagnostics(host)
        wait_for(lambda: len(endpoint.requests) == 1, "exact request capacity")
        assert len(endpoint.requests[0]) == actual_request_bytes
        resources = command(
            "session", "inspect",
            "--store",
            framing_exact_store,
            "--session",
            framing_exact_session,
        )["execution"]
        assert int(resources["scratch_used_bytes"]) == actual_request_bytes, resources
        exact_deadline = time.monotonic() + 8
        endpoint.release.set()
        exact_result = wait_for(
            lambda: (value := observe(framing_exact_store, "exact-0", deadline=exact_deadline))
            .get("result", {})
            .get("code")
            and value,
            "exact-capacity result",
            deadline=exact_deadline,
        )
        # The request itself fits exactly and reaches HTTP. Its held charge
        # intentionally leaves no shared scratch for the fixture response.
        assert exact_result["result"]["code"] == "response_scratch_exhausted", exact_result
        wait_model_cleanup(
            exact_diagnostics, framing_exact_store, framing_exact_session,
            exact_result, exact_deadline,
        )
        stop_host(host)
        assert_model_cleanup_census(exact_diagnostics, exact_result)
        processes.remove(host)

        endpoint.requests.clear()
        endpoint.release.clear()
        framing_limit_store = state / "framing-limit-store"
        host = start_host(framing_limit_store, None)
        processes.append(host)
        framing_limit_session = configure(state, framing_limit_store, "limit-config", None, "gpt-6-sol")
        empty_messages(host, framing_limit_store, framing_limit_session, "limit")
        stop_host(host)
        processes.remove(host)
        host = start_host(
            framing_limit_store,
            url,
            "--test-request-scratch-limit",
            str(actual_request_bytes - 1),
            "--test-phase-trace", observations="control",
        )
        processes.append(host)
        limit_diagnostics = HostDiagnostics(host)
        limit_deadline = time.monotonic() + 8
        limited = wait_for(
            lambda: (value := observe(
                framing_limit_store, "limit-0", deadline=limit_deadline,
            )).get("result", {}).get("code")
            == "request_scratch_exhausted"
            and value,
            "pre-dispatch framing capacity failure",
            deadline=limit_deadline,
        )
        assert limited["processing"]["attempt"] == "1", limited
        assert endpoint.requests == []
        wait_model_cleanup(
            limit_diagnostics, framing_limit_store, framing_limit_session,
            limited, limit_deadline,
        )
        stop_host(host)
        assert_model_cleanup_census(limit_diagnostics, limited)
        processes.remove(host)

        # URL authority is parsed before curl sees it. Userinfo that makes a
        # prefix look loopback is rejected at startup and reaches no server.
        endpoint.requests.clear()
        deceptive = subprocess.run(
            [
                str(RUI), "host", "serve", "--store", str(state / "deceptive-store"),
                "--provider-endpoint", f"http://127.0.0.1:80@127.0.0.1:{endpoint.server_port}/responses",
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert deceptive.returncode != 0
        assert endpoint.requests == []

        # The production timeout is inactivity-based, not a total request
        # deadline. A reduced one-second interval stays alive while bytes make
        # progress for over three intervals, while a body stall fails.
        progress_store = state / "progress-store"
        host = start_host(
            progress_store,
            f"http://127.0.0.1:{endpoint.server_port}/progress",
            "--test-provider-inactivity-seconds",
            "1",
        )
        processes.append(host)
        progress_session = configure(state, progress_store, "progress-config", None, "gpt-6-sol")
        message(state, progress_store, "progress-message", progress_session, "progress")
        progress_failure = wait_for(
            lambda: (value := observe(progress_store, "progress-message")).get("result", {}).get("code")
            == "provider_http_422"
            and value,
            "progressing response beyond inactivity interval",
            timeout=8,
        )
        assert progress_failure["queue"]["status"] == "failed"
        stop_host(host)
        processes.remove(host)

        stall_store = state / "stall-store"
        host = start_host(
            stall_store,
            f"http://127.0.0.1:{endpoint.server_port}/stall",
            "--test-provider-inactivity-seconds",
            "1",
            "--test-retry-waits-ms",
            "60000,60000,60000",
            accelerated_retries=False,
        )
        processes.append(host)
        stall_session = configure(state, stall_store, "stall-config", None, "gpt-6-sol")
        message(state, stall_store, "stall-message", stall_session, "stall")
        wait_for(
            lambda: command(
                "session", "inspect", "--store", stall_store, "--session", stall_session
            )["execution"]["custody_occupied"] == "1",
            "stalled response takes custody",
        )
        stalled_resources = wait_for_execution_release(
            lambda remaining: command(
                "session", "inspect", "--store", stall_store, "--session", stall_session, timeout=remaining,
            )["execution"],
            time.monotonic() + 8,
        )
        assert stalled_resources["scratch_used_bytes"] == "0", stalled_resources
        stalled = observe(stall_store, "stall-message")
        assert stalled["queue"]["status"] == "processing" and "result" not in stalled, stalled
        assert stalled["processing"]["attempt"] == "1", stalled
        stop_host(host)
        processes.remove(host)
        # The interrupted body keeps its one received byte, never called complete.
        (stalled_record, stalled_body), = failed_response_records(stall_store)
        assert stalled_body == b"x", stalled_body
        assert (stalled_record["status"], stalled_record["transfer"], stalled_record["truncated"]) == ("partial", "interrupted", False), stalled_record
        assert (stalled_record["operation"], stalled_record["attempt"]) == (stalled["processing"]["operation"], "1"), stalled_record
        assert (stalled_record["code"], stalled_record["http_status"]) == ("provider_transport_failure", None), stalled_record
        with sqlite3.connect(stall_store / "rui.sqlite3") as database:
            retry = database.execute(
                "SELECT attempt_ordinal,allowance_used,uncertain,resolution_code,last_failure_code,retry_due_at_ms>? "
                "FROM model_operation",
                (int(time.time() * 1000),),
            ).fetchall()
        assert retry == [(1, 1, 0, None, "provider_transport_failure", 1)], retry

        # Discarding large bodies must preserve HTTP classification. Retryable
        # evidence releases physical custody and saves the next eligible retry.
        for path in ("/large-422", "/large-429", "/429", "/503", "/disconnect"):
            case_state = state / (path[1:] + "-records")
            case_state.mkdir(mode=0o700)
            endpoint.requests.clear()
            endpoint.release.set()
            transient_store = state / (path[1:] + "-store")
            host = start_host(
                transient_store,
                f"http://127.0.0.1:{endpoint.server_port}{path}",
                accelerated_retries=False,
            )
            processes.append(host)
            transient_session = configure(case_state, transient_store, "config", None, "gpt-6-sol")
            message(case_state, transient_store, "message", transient_session, "input")
            wait_for(lambda: len(endpoint.requests) == 1, "one endpoint request")
            resources = wait_for_execution_release(
                lambda remaining: command(
                    "session", "inspect", "--store", transient_store, "--session", transient_session, timeout=remaining,
                )["execution"],
                time.monotonic() + 8,
            )
            observation = observe(transient_store, "message")
            assert resources["scratch_used_bytes"] == "0", resources
            if path == "/large-422":
                assert observation["result"]["code"] == "provider_http_422", observation
            else:
                assert observation["queue"]["status"] == "processing" and "result" not in observation, observation
                assert observation["processing"]["attempt"] == "1", observation
                message(case_state, transient_store, "later", transient_session, "later")
                assert observe(transient_store, "later")["queue"]["status"] == "queued"
            retry_observed_at_ms = int(time.time() * 1000)
            stop_host(host)
            processes.remove(host)
            with sqlite3.connect(transient_store / "rui.sqlite3") as database:
                (operation_id,), = database.execute("SELECT operation_id FROM model_operation").fetchall()
            if path == "/disconnect":
                # No response byte arrived, so nothing is retained.
                assert failed_response_records(transient_store) == []
            else:
                status = int(path.rsplit("-", 1)[-1].lstrip("/"))
                assert_complete_failed_response(
                    transient_store,
                    b"x" * (128 * 1024) if path.startswith("/large-") else b'{"error":"deterministic permanent failure"}',
                    operation=str(operation_id),
                    code="provider_http_422" if status == 422 else f"provider_temporary_http_{status}",
                    http_status=status, request_id=None,
                )
            if path != "/large-422":
                with sqlite3.connect(transient_store / "rui.sqlite3") as database:
                    retry = database.execute(
                        "SELECT allowance_used,uncertain,resolution_code,last_failure_code,retry_due_at_ms>? FROM model_operation",
                        (retry_observed_at_ms,),
                    ).fetchall()
                    expected_code = (
                        "provider_transport_failure"
                        if path == "/disconnect"
                        else f"provider_temporary_http_{path.rsplit('-', 1)[-1].lstrip('/')}"
                    )
                    assert retry == [(1, 0, None, expected_code, 1)], retry
            host = start_host(
                transient_store,
                f"http://127.0.0.1:{endpoint.server_port}{path}",
                accelerated_retries=False,
            )
            processes.append(host)
            assert observe(transient_store, "message") == observation
            assert len(endpoint.requests) == 1, "restart recreated a consumed permit"
            stop_host(host)
            processes.remove(host)

        # A canonical read fault published before launch fences the Store
        # and prevents the synchronized dispatch handoff.
        endpoint.requests.clear()
        endpoint.release.clear()
        race_store = state / "fence-race-store"
        host = start_host(race_store, url)
        processes.append(host)
        race_session = configure(state, race_store, "race-config", None, "gpt-6-sol")
        other_session = configure(state, race_store, "race-other-config", None, "gpt-6-sol")
        stop_host(host)
        processes.remove(host)
        # The Host holds its Store exclusively, so damage another Session
        # while it is stopped: admitting and preparing the race Session never read
        # it, and the inspection below reads it inside the launch delay.
        database = sqlite3.connect(race_store / "rui.sqlite3")
        original_instructions = database.execute(
            "SELECT instructions_content_id FROM session WHERE session_ref=?", (other_session,)
        ).fetchone()[0]
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?", (other_session,)
        )
        database.commit()
        database.close()
        host = start_host(race_store, url, "--test-before-launch-delay-ms", "1500")
        processes.append(host)
        message(state, race_store, "race-message", race_session, "race")
        wait_for(
            lambda: observe(race_store, "race-message")["queue"]["status"] == "processing",
            "admitted request before launch",
        )
        canonical_read = subprocess.run(
            [str(RUI), "session", "inspect", "--store", str(race_store), "--session", other_session],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert canonical_read.returncode != 0
        wait_for(lambda: host.poll() is not None, "effect-aware Host shutdown", timeout=5)
        assert host.returncode != 0
        stop_host(host)
        processes.remove(host)
        assert endpoint.requests == []
        database = sqlite3.connect(race_store / "rui.sqlite3")
        uncertain = database.execute(
            "SELECT attempt_ordinal,uncertain,resolution_code FROM model_operation"
        ).fetchone()
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "UPDATE session SET instructions_content_id=? WHERE session_ref=?",
            (original_instructions, other_session),
        )
        database.commit()
        database.close()
        assert uncertain == (1, 1, None), uncertain
        repaired = start_host(race_store, None)
        processes.append(repaired)
        stop_host(repaired)
        processes.remove(repaired)

        # The first report uses request number zero. If immediate unlink fails,
        # the Host stops instead of accumulating ownerless names; startup owns
        # the recognizable empty file and either removes it or refuses service.
        report_unlink_store = state / "report-unlink-store"
        report_setup_host = start_host(report_unlink_store, None)
        processes.append(report_setup_host)
        report_unlink_session = configure(state, report_unlink_store, "report-unlink-config", None, "gpt-6-sol")
        stop_host(report_setup_host)
        processes.remove(report_setup_host)
        report_unlink_host = start_host(
            report_unlink_store, None, "--fault", "report-unlink"
        )
        processes.append(report_unlink_host)
        report_failure = subprocess.run(
            [
                str(RUI),
                "session", "inspect",
                "--store",
                str(report_unlink_store),
                "--session",
                report_unlink_session,
                "--profile",
                "full",
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert report_failure.returncode != 0, report_failure
        wait_for(
            lambda: report_unlink_host.poll() is not None,
            "report unlink effect-aware Host shutdown",
            timeout=5,
        )
        assert report_unlink_host.returncode != 0
        stop_host(report_unlink_host)
        processes.remove(report_unlink_host)
        report_leftover = report_unlink_store / "scratch" / "report-0-1.tmp"
        assert report_leftover.exists(), report_leftover

        failed_report_cleanup = subprocess.run(
            [
                str(RUI),
                "host", "serve",
                "--store",
                str(report_unlink_store),
                "--active-capacity",
                "1",
                "--fault",
                "startup-cleanup",
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert failed_report_cleanup.returncode != 0, failed_report_cleanup
        assert report_leftover.exists()
        report_cleanup_host = start_host(report_unlink_store, None)
        processes.append(report_cleanup_host)
        assert not report_leftover.exists()
        stop_host(report_cleanup_host)
        processes.remove(report_cleanup_host)

        # Response and validation-metadata unlink failures retain one named
        # file under custody and fence dispatch. A second failed cleanup leaves
        # it owned for the next startup, which removes only recognized names.
        unlink_effect = state / "unlink-fault-must-not-launch"
        unlink_calls = classification_population("unlink", unlink_effect)
        unlink_output = sse_tool_calls(
            "unlink-response",
            unlink_calls,
        )
        unlink_endpoint = SuccessEndpoint([unlink_output])
        unlink_thread = threading.Thread(target=unlink_endpoint.serve_forever, daemon=True)
        endpoints[unlink_endpoint] = unlink_thread
        unlink_thread.start()
        unlink_url = f"http://127.0.0.1:{unlink_endpoint.server_port}/responses"
        for fault, pattern, launched in (
            ("response-unlink", "response-[0-9]*.tmp", False),
            ("response-metadata-unlink", "response-metadata-*.tmp", True),
        ):
            owned_store = state / f"{fault}-owned-store"
            owned_host = start_host(owned_store, unlink_url, "--fault", fault)
            processes.append(owned_host)
            session = configure(state, owned_store, f"{fault}-config", None, "gpt-6-sol")
            message(state, owned_store, f"{fault}-message", session, "unlink")
            resources = wait_for(
                lambda store=owned_store, session=session: (
                    report["execution"]
                    if (report := command(
                        "session", "inspect", "--store", store, "--session", session
                    ))["execution"]["dispatch_fenced"]
                    else None
                ),
                f"{fault} cleanup ownership",
                timeout=20,
            )
            assert resources["custody_occupied"] == "1", resources
            assert len(unlink_endpoint.requests) == (1 if launched else 0)
            stop_host(owned_host)
            processes.remove(owned_host)
            leftovers = list((owned_store / "scratch").glob(pattern))
            assert len(leftovers) == 1, leftovers
            database = sqlite3.connect(owned_store / "rui.sqlite3")
            assert database.execute(
                "SELECT uncertain,resolution_code FROM model_operation"
            ).fetchone() == (1, None)
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
            database.close()
            assert leftovers[0].exists()

            failed_cleanup = subprocess.run(
                [
                    str(RUI),
                    "host", "serve",
                    "--store",
                    str(owned_store),
                    "--active-capacity",
                    "1",
                    "--fault",
                    "startup-cleanup",
                ],
                text=True,
                capture_output=True,
                timeout=10,
            )
            assert failed_cleanup.returncode != 0, failed_cleanup
            assert leftovers[0].exists()

            cleanup_host = start_host(owned_store, None)
            processes.append(cleanup_host)
            assert not list((owned_store / "scratch").glob(pattern))
            resources = command(
                "session", "inspect", "--store", owned_store, "--session", session
            )["execution"]
            assert resources["scratch_used_bytes"] == "0", resources
            stop_host(cleanup_host)
            processes.remove(cleanup_host)
        assert not unlink_effect.exists()
        stop_endpoint(unlink_endpoint, endpoints)

        # If initial unlink fails, the live owner keeps both descriptors and
        # named scratch while fencing later dispatch. No bytes have yet been
        # emitted, so logical scratch charge remains zero. A fresh owner removes
        # the identifiable leftover before serving.
        unlink_store = state / "unlink-store"
        host = start_host(unlink_store, url, "--fault", "request-unlink")
        processes.append(host)
        unlink_session = configure(state, unlink_store, "unlink-config", None, "gpt-6-sol")
        message(state, unlink_store, "unlink-message", unlink_session, "unlink")
        unlink_deadline = time.monotonic() + 20
        resources = wait_for(
            lambda: (
                execution
                if (execution := command(
                    "session", "inspect", "--store", unlink_store, "--session", unlink_session,
                    timeout=min(15, max(0, unlink_deadline - time.monotonic())),
                )["execution"])["dispatch_fenced"]
                and execution["custody_occupied"] == "1"
                and execution["scratch_used_bytes"] == "0"
                else None
            ),
            "request-unlink cleanup ownership",
            deadline=unlink_deadline,
        )
        assert resources["custody_occupied"] == "1", resources
        assert resources["scratch_used_bytes"] == "0", resources
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)
        leftovers = list(unlink_store.rglob("provider-request-*"))
        assert len(leftovers) == 1, leftovers
        assert leftovers[0].exists()

        offline = start_host(unlink_store, None)
        processes.append(offline)
        assert not list(unlink_store.rglob("provider-request-*"))
        resources = command(
            "session", "inspect", "--store", unlink_store, "--session", unlink_session
        )["execution"]
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(offline)
        processes.remove(offline)
        completed = True
    finally:
        incoming_error = sys.exc_info()[1]

        def collect_successor():
            if continuation_diagnostics is None:
                return
            try:
                preserve_failure_metadata(state / "successor-pre-kill.json", lambda: {
                    "process": continuation_host.pid, "returncode": continuation_host.poll(),
                    "atomic_census": False, "stderr_tail": continuation_diagnostics.tail().decode(errors="replace")})
                if continuation_host.poll() is None:
                    crash_host(continuation_host, state, "successor-failure", diagnostics=continuation_diagnostics)
                else:
                    continuation_diagnostics.close()
                    (state / "successor-failure.stderr").write_bytes(continuation_diagnostics.tail())
            except BaseException as error:
                preserve_failure_metadata(state / "successor-collector-failure.json", lambda error=error: {
                    "original_error": type(incoming_error).__name__ if incoming_error else None,
                    "collector_error": type(error).__name__})
                raise

        try:
            dispose_all(
                collect_successor,
                lambda: dispose_dispatch(
                    processes, endpoints, releases,
                    lambda: os.close(proposal_gate_keeper) if proposal_gate_keeper is not None else None,
                ),
            )
        except BaseException:
            completed = False
            raise
        finally:
            dispose_all(lambda: shutil.rmtree(state) if completed and incoming_error is None else
                        retain_failure_state("dispatch integration failure state", state))


if __name__ == "__main__":
    mode = sys.argv[2] if len(sys.argv) >= 3 else "all"
    correlation_case = sys.argv[3] if len(sys.argv) == 4 else "all"
    if (len(sys.argv) not in (2, 3, 4) or mode not in ("all", "http-quota", "failure-correlation", "phased-messages", "failed-response-export", "empty-answers", "stream-failures", "refusals")
            or correlation_case not in ("all", "rejected", "correlated", "exhausted")
            or (len(sys.argv) == 4 and mode != "failure-correlation")):
        raise SystemExit("usage: dispatch_integration.py RUI [all|http-quota|stream-failures|empty-answers|refusals|failed-response-export|phased-messages|failure-correlation [all|rejected|correlated|exhausted]]")
    main(mode, correlation_case)
