#!/usr/bin/env python3
import http.server
import hashlib
import json
import os
import pathlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

from host_process import start_ready_process, stop_process


LATIFA = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()


class FailureEndpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FailureHandler)
        self.requests = []
        self.paths = []
        self.received = threading.Event()
        self.release = threading.Event()


class FailureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        self.server.requests.append(body)
        self.server.paths.append(self.path)
        self.server.received.set()
        if self.path == "/progress":
            self.send_response(422)
            self.send_header("Content-Length", "8")
            self.send_header("Connection", "close")
            self.end_headers()
            for _ in range(8):
                self.wfile.write(b"x")
                self.wfile.flush()
                time.sleep(0.4)
            self.close_connection = True
            return
        if self.path == "/stall":
            self.send_response(422)
            self.send_header("Content-Length", "2")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"x")
            self.wfile.flush()
            time.sleep(2.5)
            try:
                self.wfile.write(b"x")
            except BrokenPipeError:
                pass
            self.close_connection = True
            return
        if not self.server.release.wait(10):
            raise RuntimeError("fixture response was never released")
        if self.path == "/disconnect":
            self.close_connection = True
            return
        payload = b'{"error":"deterministic permanent failure"}'
        status = 422
        if self.path.startswith("/large-"):
            payload = b"x" * (128 * 1024)
            status = int(self.path.rsplit("-", 1)[1])
        elif self.path in ("/429", "/503"):
            status = int(self.path[1:])
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def encode_sse(payloads, done=True):
    body = b"".join(
        b"data: " + json.dumps(payload, separators=(",", ":")).encode() + b"\n\n"
        for payload in payloads
    )
    return body + (b"data: [DONE]\n\n" if done else b"")


def sse_answer(
    response_id,
    reasoning_id,
    message_id,
    answer,
    *,
    extension=None,
    served_model="model-a-served",
):
    reasoning = {
        "type": "reasoning",
        "id": reasoning_id,
        "status": "completed",
        "summary": [],
        "encrypted_content": f"private-{response_id}",
        "created_by": "response-only",
        "extension": extension or {"preserved": response_id},
    }
    message_item = {
        "type": "message",
        "id": message_id,
        "status": "completed",
        "role": "assistant",
        "phase": "final_answer",
        "content": [
            {
                "type": "output_text",
                "text": part,
                "annotations": [],
                "extension": {"kept": True},
            } for part in (answer if isinstance(answer, list) else [answer])
        ],
    }
    completed_response = {
        "id": response_id,
        "status": "completed",
        "output": [reasoning, message_item],
        "usage": {"input_tokens": 7, "output_tokens": 11, "total_tokens": 18},
    }
    if served_model is not None:
        completed_response["model"] = served_model
    payloads = [
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {"type": "reasoning", "id": reasoning_id},
        },
        {"type": "response.output_item.done", "output_index": 0, "item": reasoning},
        {
            "type": "response.output_item.added",
            "output_index": 1,
            "item": {"type": "message", "id": message_id},
        },
        {"type": "response.output_item.done", "output_index": 1, "item": message_item},
        {
            "type": "response.completed",
            "response": completed_response,
        },
    ]
    body = encode_sse(payloads)
    return body, reasoning, message_item


def sse_many(response_id, reasoning_count, answer):
    items = []
    payloads = []
    for index in range(reasoning_count):
        item = {
            "type": "reasoning",
            "id": f"{response_id}-reasoning-{index}",
            "summary": [],
            "encrypted_content": f"private-{index}",
            "extension": {"ordinal": index},
        }
        items.append(item)
        payloads += [
            {
                "type": "response.output_item.added",
                "output_index": index,
                "item": {"type": "reasoning", "id": item["id"]},
            },
            {"type": "response.output_item.done", "output_index": index, "item": item},
        ]
    message_item = {
        "type": "message",
        "id": f"{response_id}-message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": answer, "annotations": []}],
    }
    items.append(message_item)
    payloads += [
        {
            "type": "response.output_item.added",
            "output_index": reasoning_count,
            "item": {"type": "message", "id": message_item["id"]},
        },
        {
            "type": "response.output_item.done",
            "output_index": reasoning_count,
            "item": message_item,
        },
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "status": "completed",
                "model": "model-a-served",
                "output": items,
                "usage": {"input_tokens": 7, "output_tokens": 11, "total_tokens": 18},
            },
        },
    ]
    return encode_sse(payloads)


class SuccessEndpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, responses, responses_by_input=None):
        super().__init__(("127.0.0.1", 0), SuccessHandler)
        self.responses = list(responses)
        self.responses_by_input = responses_by_input
        self.requests = []
        self.request_times = []
        self.lock = threading.Lock()


class ResponseSpec:
    def __init__(self, body, headers, status=200):
        self.body = body
        self.headers = headers
        self.status = status


class SuccessHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        with self.server.lock:
            self.server.requests.append(body)
            self.server.request_times.append(time.monotonic())
            if self.server.responses_by_input is not None:
                request = json.loads(body)
                user_text = next(
                    item["content"][0]["text"]
                    for item in reversed(request["input"])
                    if item.get("role") == "user"
                )
                payload = self.server.responses_by_input[user_text]
            else:
                if not self.server.responses:
                    raise AssertionError("unexpected extra model request")
                payload = self.server.responses.pop(0)
        if isinstance(payload, tuple):
            payload, release = payload
            if not release.wait(10):
                raise RuntimeError("success fixture response was never released")
        headers = {"X-Request-Id": f"request-{len(self.server.requests)}", "OpenAI-Model": "model-a-served"}
        status = 200
        if isinstance(payload, ResponseSpec):
            headers = payload.headers
            status = payload.status
            payload = payload.body
        self.send_response(status)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        header_items = headers.items() if hasattr(headers, "items") else headers
        for name, value in header_items:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        # Split inside SSE field names, JSON punctuation, escapes and UTF-8.
        offsets = (1, 2, 5, 3, 7, 4, 1, 6)
        cursor = 0
        index = 0
        while cursor < len(payload):
            size = offsets[index % len(offsets)]
            try:
                self.wfile.write(payload[cursor : cursor + size])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break
            cursor += size
            index += 1
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def command(*args, expect=0):
    completed = subprocess.run(
        [str(LATIFA), *map(str, args)],
        text=True,
        capture_output=True,
        timeout=15,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_host(store, endpoint, *extra, accelerated_retries=True):
    args = [
        str(LATIFA),
        "serve",
        "--store",
        str(store),
        "--active-capacity",
        "1",
    ]
    if endpoint is not None:
        args += ["--provider-endpoint", endpoint]
        if accelerated_retries:
            args += ["--test-retry-waits-ms", "50,100,150"]
    args += extra
    process, _ = start_ready_process(
        args,
        required_fields=(
            {"execution": "enabled", "curl": "8.22.0"}
            if endpoint is not None
            else {"execution": "unavailable"}
        ),
    )
    return process


def stop_host(process):
    stop_process(process)


def crash_host(process, state, label):
    assert process.poll() is None, process.returncode
    process.kill()
    stdout, stderr = process.communicate(timeout=10)
    (state / f"{label}.stdout").write_bytes(stdout)
    (state / f"{label}.stderr").write_bytes(stderr)
    return {
        "returncode": process.returncode,
        "stdout": stdout,
        "stderr": stderr,
    }


def configure(state, store, key, session, model, schema=None, instructions=None):
    record = state / f"{key}.json"
    args = [
        "configure",
        "--store",
        store,
        "--record",
        record,
        "--key",
        key,
        "--session",
        session,
        "--workspace",
        ROOT,
        "--model",
        model,
    ]
    if schema is not None:
        schema_path = state / f"{key}-schema.json"
        schema_path.write_text(json.dumps(schema, separators=(",", ":")))
        args += ["--output-schema", schema_path]
    if instructions is not None:
        instructions_path = state / f"{key}-instructions.txt"
        instructions_path.write_text(instructions)
        args += ["--instructions", instructions_path]
    result = command(*args)
    assert result["answer"]["status"] == "accepted", result


def message(state, store, key, session, text):
    text_path = state / f"{key}.txt"
    text_path.write_text(text)
    result = command(
        "message",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--text",
        text_path,
    )
    assert result["answer"]["status"] == "accepted", result


def observe(store, key):
    return command("observe-command", "--store", store, "--key", key)["observation"]


def read_result(store, key):
    completed = subprocess.run(
        [str(LATIFA), "read-result", "--store", str(store), "--key", key],
        capture_output=True,
        timeout=15,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"read-result failed for {key}: {completed.returncode}\n"
            f"stdout: {completed.stdout!r}\nstderr: {completed.stderr!r}"
        )
    return completed.stdout


def wait_for(predicate, description, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for {description}")


def completed_observation(store, key):
    value = observe(store, key)
    return value if value.get("result", {}).get("status") == "completed" else None


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="latifa-dispatch."))
    endpoint = FailureEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    processes = []
    success_endpoint = None
    success_thread = None
    completed = False
    try:
        first_answer = 'First "answer"\n🙂'.encode()
        second_answer = ("second answer " + "x" * 5000).encode()
        first_sse, first_reasoning, first_message_item = sse_answer(
            "response-1", "reasoning-1", "message-1", first_answer.decode()
        )
        second_sse, second_reasoning, second_message_item = sse_answer(
            "response-2", "reasoning-2", "message-2", second_answer.decode()
        )
        success_endpoint = SuccessEndpoint([first_sse, second_sse])
        success_thread = threading.Thread(target=success_endpoint.serve_forever, daemon=True)
        success_thread.start()
        success_url = f"http://127.0.0.1:{success_endpoint.server_port}/responses"
        success_store = state / "success-store"
        success_host = start_host(success_store, success_url, "--test-cleanup-delay-ms", "2000")
        processes.append(success_host)
        configure(state, success_store, "success-config", "direct/success", "model-a")
        command(
            "configure",
            "--store",
            success_store,
            "--record",
            state / "success-tools.json",
            "--key",
            "success-tools",
            "--session",
            "direct/success",
            "--tools",
            "none",
        )
        message(state, success_store, "success-first", "direct/success", "first question")
        first_complete = wait_for(
            lambda: completed_observation(success_store, "success-first"),
            "first complete model answer",
        )
        assert first_complete["queue"]["status"] == "completed", first_complete
        assert read_result(success_store, "success-first") == first_answer
        cleanup_state = command(
            "inspect-session", "--store", success_store, "--session", "direct/success"
        )["execution"]
        assert cleanup_state["custody_occupied"] == "1", cleanup_state
        stop_host(success_host)
        processes.remove(success_host)

        # A fresh Host and client recover the original answer, then the same
        # Session completes another Turn from the historical provider view.
        success_host = start_host(success_store, success_url)
        processes.append(success_host)
        assert read_result(success_store, "success-first") == first_answer
        before_model_change = command(
            "inspect-session", "--store", success_store, "--session", "direct/success"
        )["session"]
        incompatible_args = (
            "configure",
            "--store",
            success_store,
            "--record",
            state / "incompatible-model.json",
            "--key",
            "incompatible-model",
            "--session",
            "direct/success",
            "--model",
            "model-b",
        )
        incompatible = command(*incompatible_args)
        assert incompatible["answer"]["status"] == "rejected", incompatible
        assert incompatible["answer"]["code"] == "continuation_model_incompatible", incompatible
        replayed_incompatible = command(
            "retry",
            "--store",
            success_store,
            "--record",
            state / "incompatible-model.json",
            "--kind",
            "configure",
        )
        assert replayed_incompatible["answer"]["status"] == "rejected", replayed_incompatible
        assert replayed_incompatible["answer"]["replayed"] is True, replayed_incompatible
        after_model_change = command(
            "inspect-session", "--store", success_store, "--session", "direct/success"
        )["session"]
        assert after_model_change["model"] == "model-a", after_model_change
        assert after_model_change["revision"] == before_model_change["revision"], (
            before_model_change,
            after_model_change,
        )
        message(state, success_store, "success-second", "direct/success", "second question")
        wait_for(
            lambda: completed_observation(success_store, "success-second"),
            "second complete model answer",
        )
        assert read_result(success_store, "success-first") == first_answer
        assert read_result(success_store, "success-second") == second_answer
        wait_for(lambda: len(success_endpoint.requests) == 2, "two successful requests")
        first_request = json.loads(success_endpoint.requests[0])
        second_request = json.loads(success_endpoint.requests[1])
        assert first_request["input"] == [
            {"role": "system", "content": [{"type": "input_text", "text": ""}]},
            {"role": "user", "content": [{"type": "input_text", "text": "first question"}]},
        ]
        expected_reasoning = dict(first_reasoning)
        expected_reasoning.pop("created_by")
        assert second_request["input"] == [
            {"role": "system", "content": [{"type": "input_text", "text": ""}]},
            {"role": "user", "content": [{"type": "input_text", "text": "first question"}]},
            expected_reasoning,
            first_message_item,
            {"role": "user", "content": [{"type": "input_text", "text": "second question"}]},
        ], second_request["input"]
        database = sqlite3.connect(success_store / "latifa.sqlite3")
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
            assert json.loads(raw_reasoning)["created_by"] == "response-only"
            assert database.execute(
                "SELECT response_id,body_model,openai_model,x_openai_model,request_id,resolution_code,usage_content_id IS NOT NULL FROM model_operation ORDER BY operation_id"
            ).fetchall() == [
                (
                    "response-1",
                    "model-a-served",
                    "model-a-served",
                    None,
                    "request-1",
                    "completed",
                    1,
                ),
                (
                    "response-2",
                    "model-a-served",
                    "model-a-served",
                    None,
                    "request-2",
                    "completed",
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
        stop_host(success_host)
        processes.remove(success_host)
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
        retry_thread.start()
        retry_store = state / "retry-store"
        retry_host = start_host(
            retry_store,
            f"http://127.0.0.1:{retry_endpoint.server_port}/responses",
        )
        processes.append(retry_host)
        configure(state, retry_store, "retry-config", "direct/retry", "model-a")
        message(state, retry_store, "retry-message", "direct/retry", "retry exactly")
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
        database = sqlite3.connect(retry_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code FROM model_operation"
        ).fetchone() == (
            3,
            3,
            0,
            None,
            "provider_temporary_http_429",
            "completed",
        )
        database.close()
        stop_host(retry_host)
        processes.remove(retry_host)
        retry_endpoint.shutdown()
        retry_endpoint.server_close()
        retry_thread.join(timeout=5)

        # A permanent request/authentication-class HTTP failure is terminal
        # after one Attempt and is never blindly retried.
        permanent_endpoint = SuccessEndpoint(
            [ResponseSpec(b"authentication rejected", {}, 401)]
        )
        permanent_thread = threading.Thread(
            target=permanent_endpoint.serve_forever, daemon=True
        )
        permanent_thread.start()
        permanent_store = state / "permanent-store"
        permanent_host = start_host(
            permanent_store,
            f"http://127.0.0.1:{permanent_endpoint.server_port}/responses",
        )
        processes.append(permanent_host)
        configure(
            state, permanent_store, "permanent-config", "direct/permanent", "model-a"
        )
        message(
            state,
            permanent_store,
            "permanent-message",
            "direct/permanent",
            "do not retry",
        )
        permanent_failure = wait_for(
            lambda: (
                value := observe(permanent_store, "permanent-message")
            ).get("result", {}).get("code")
            and value,
            "permanent provider failure",
        )
        assert permanent_failure["result"]["code"] == "provider_http_401"
        time.sleep(1.2)
        assert len(permanent_endpoint.requests) == 1
        stop_host(permanent_host)
        processes.remove(permanent_host)
        permanent_endpoint.shutdown()
        permanent_endpoint.server_close()
        permanent_thread.join(timeout=5)

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
        disposition_thread.start()
        for case_index, (name, _, expected_code) in enumerate(disposition_cases, 1):
            disposition_store = state / f"{name}-store"
            disposition_host = start_host(
                disposition_store,
                f"http://127.0.0.1:{disposition_endpoint.server_port}/responses",
            )
            processes.append(disposition_host)
            configure(
                state,
                disposition_store,
                f"{name}-config",
                f"direct/{name}",
                "model-a",
            )
            message(
                state,
                disposition_store,
                f"{name}-message",
                f"direct/{name}",
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
        disposition_endpoint.shutdown()
        disposition_endpoint.server_close()
        disposition_thread.join(timeout=5)

        # A local read failure while curl owns the request is a Host fault,
        # not provider evidence. Fence dispatch, retain uncertainty and avoid
        # a same-process retry.
        local_read_endpoint = SuccessEndpoint(
            [sse_answer("local-read", "local-read-r", "local-read-m", "unused")[0]]
        )
        local_read_thread = threading.Thread(
            target=local_read_endpoint.serve_forever, daemon=True
        )
        local_read_thread.start()
        local_read_store = state / "local-read-store"
        local_read_host = start_host(
            local_read_store,
            f"http://127.0.0.1:{local_read_endpoint.server_port}/responses",
            "--fault",
            "request-read",
        )
        processes.append(local_read_host)
        configure(
            state,
            local_read_store,
            "local-read-config",
            "direct/local-read",
            "model-a",
        )
        message(
            state,
            local_read_store,
            "local-read-message",
            "direct/local-read",
            "fence local scratch failure",
        )
        wait_for(
            lambda: local_read_host.poll() is not None,
            "local request-read fenced shutdown",
        )
        assert local_read_host.returncode != 0
        processes.remove(local_read_host)
        database = sqlite3.connect(local_read_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,allowance_used,uncertain,resolution_code FROM model_operation"
        ).fetchone() == (1, 1, 1, None)
        database.close()
        assert len(local_read_endpoint.requests) <= 1
        local_read_endpoint.shutdown()
        local_read_endpoint.server_close()
        local_read_thread.join(timeout=5)

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
            configure(
                state,
                identity_store,
                f"{fault}-config",
                f"direct/{fault}",
                "model-a",
            )
            message(
                state,
                identity_store,
                f"{fault}-message",
                f"direct/{fault}",
                fault,
            )
            wait_for(
                lambda process=identity_host: process.poll() is not None,
                f"{fault} fenced shutdown",
            )
            processes.remove(identity_host)
            assert identity_host.returncode == 1, identity_host.returncode
            stderr = identity_host.stderr.read()
            assert expected_error.encode() in stderr, stderr
            assert len(identity_endpoint.requests) == index + 1
            database = sqlite3.connect(identity_store / "latifa.sqlite3")
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
                "inspect-session",
                "--store",
                identity_store,
                "--session",
                f"direct/{fault}",
            )["execution"]
            assert resources["custody_occupied"] == "0", resources
            assert resources["scratch_used_bytes"] == "0", resources
            stop_host(offline)
            processes.remove(offline)
        identity_endpoint.shutdown()
        identity_endpoint.server_close()
        identity_thread.join(timeout=5)

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
        continued_endpoint = SuccessEndpoint(
            [
                continued_first,
                ResponseSpec(b"temporary", {}, 503),
                continued_retry,
                continued_later,
            ]
        )
        continued_thread = threading.Thread(
            target=continued_endpoint.serve_forever, daemon=True
        )
        continued_thread.start()
        continued_store = state / "continued-retry-store"
        continued_host = start_host(
            continued_store,
            f"http://127.0.0.1:{continued_endpoint.server_port}/responses",
        )
        processes.append(continued_host)
        configure(
            state,
            continued_store,
            "continued-config",
            "direct/continued-retry",
            "model-a",
            instructions="original instructions",
        )
        message(
            state,
            continued_store,
            "continued-first-message",
            "direct/continued-retry",
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
            "direct/continued-retry",
            "historical retry input",
        )
        wait_for(lambda: len(continued_endpoint.requests) == 2, "first continued Attempt")
        configure(
            state,
            continued_store,
            "continued-new-instructions",
            "direct/continued-retry",
            "model-a",
            instructions="new instructions",
        )
        message(
            state,
            continued_store,
            "continued-later-message",
            "direct/continued-retry",
            "unselected later input",
        )
        wait_for(lambda: len(continued_endpoint.requests) == 3, "replacement continued Attempt")
        assert continued_endpoint.requests[1] == continued_endpoint.requests[2]
        frozen_retry = json.loads(continued_endpoint.requests[2])
        expected_private = dict(continued_reasoning)
        expected_private.pop("created_by")
        assert expected_private in frozen_retry["input"], frozen_retry["input"]
        assert continued_message in frozen_retry["input"], frozen_retry["input"]
        assert not any(
            item.get("role") == "system"
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
        continued_endpoint.shutdown()
        continued_endpoint.server_close()
        continued_thread.join(timeout=5)

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
        evidence_thread.start()
        evidence_url = f"http://127.0.0.1:{evidence_endpoint.server_port}/responses"
        for name, _, _, expected_evidence in evidence_cases:
            evidence_store = state / f"evidence-{name}-store"
            evidence_host = start_host(evidence_store, evidence_url)
            processes.append(evidence_host)
            configure(state, evidence_store, f"evidence-{name}-config", f"direct/evidence-{name}", "model-a")
            message(
                state,
                evidence_store,
                f"evidence-{name}-message",
                f"direct/evidence-{name}",
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
            database = sqlite3.connect(evidence_store / "latifa.sqlite3")
            actual_evidence = database.execute(
                "SELECT body_model,openai_model,x_openai_model,request_id FROM model_operation"
            ).fetchone()
            database.close()
            assert actual_evidence == expected_evidence, (name, actual_evidence, expected_evidence)
            stop_host(reopened)
            processes.remove(reopened)
        evidence_endpoint.shutdown()
        evidence_endpoint.server_close()
        evidence_thread.join(timeout=5)

        contradictory_sse, _, _ = sse_answer(
            "contradictory-response",
            "contradictory-reasoning",
            "contradictory-message",
            "must not publish",
            served_model="model-body",
        )
        contradictory_endpoint = SuccessEndpoint(
            [
                ResponseSpec(
                    contradictory_sse,
                    {
                        "OpenAI-Model": "model-openai-header",
                        "X-OpenAI-Model": "model-x-openai-header",
                        "X-Request-Id": "contradictory-request",
                    },
                )
            ]
        )
        contradictory_thread = threading.Thread(
            target=contradictory_endpoint.serve_forever, daemon=True
        )
        contradictory_thread.start()
        contradictory_store = state / "contradictory-evidence-store"
        contradictory_host = start_host(
            contradictory_store,
            f"http://127.0.0.1:{contradictory_endpoint.server_port}/responses",
        )
        processes.append(contradictory_host)
        configure(
            state,
            contradictory_store,
            "contradictory-config",
            "direct/contradictory-evidence",
            "model-a",
        )
        message(
            state,
            contradictory_store,
            "contradictory-message",
            "direct/contradictory-evidence",
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
        database = sqlite3.connect(contradictory_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT uncertain,resolution_code,response_id,body_model,openai_model,x_openai_model,request_id FROM model_operation"
        ).fetchone() == (0, "contradictory_provider_output", None, None, None, None, None)
        assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
        assert database.execute(
            "SELECT count(*) FROM conversation_entry WHERE entry_kind=3"
        ).fetchone()[0] == 0
        assert database.execute("SELECT outcome_content_id FROM turn").fetchone()[0] is None
        database.close()
        stop_host(contradictory_host)
        processes.remove(contradictory_host)
        contradictory_reopened = start_host(contradictory_store, None)
        processes.append(contradictory_reopened)
        restarted_failure = observe(contradictory_store, "contradictory-message")
        assert restarted_failure["queue"]["status"] == "failed", restarted_failure
        assert restarted_failure["result"] == {
            "status": "failed",
            "code": "contradictory_provider_output",
        }, restarted_failure
        unreadable_result = subprocess.run(
            [
                str(LATIFA),
                "read-result",
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
        contradictory_endpoint.shutdown()
        contradictory_endpoint.server_close()
        contradictory_thread.join(timeout=5)

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
        pending_endpoint = SuccessEndpoint(
            [(pending_first_sse, first_release), (pending_second_sse, second_release)]
        )
        pending_thread = threading.Thread(target=pending_endpoint.serve_forever, daemon=True)
        pending_thread.start()
        pending_store = state / "pending-store"
        pending_host = start_host(
            pending_store, f"http://127.0.0.1:{pending_endpoint.server_port}/responses"
        )
        processes.append(pending_host)
        configure(state, pending_store, "pending-config", "direct/pending", "model-a")
        command(
            "configure",
            "--store",
            pending_store,
            "--record",
            state / "pending-tools.json",
            "--key",
            "pending-tools",
            "--session",
            "direct/pending",
            "--tools",
            "none",
        )
        message(state, pending_store, "pending-first", "direct/pending", "before cutoff")
        wait_for(lambda: len(pending_endpoint.requests) == 1, "first frozen pending request")
        message(state, pending_store, "pending-second", "direct/pending", "after cutoff")
        assert observe(pending_store, "pending-second")["queue"]["status"] == "queued"
        first_release.set()
        wait_for(lambda: len(pending_endpoint.requests) == 2, "next input boundary request")
        assert "result" not in observe(pending_store, "pending-first")
        assert observe(pending_store, "pending-second")["queue"]["status"] == "processing"
        pending_request = json.loads(pending_endpoint.requests[1])
        expected_pending_reasoning = dict(pending_reasoning)
        expected_pending_reasoning.pop("created_by")
        assert pending_request["input"] == [
            {"role": "system", "content": [{"type": "input_text", "text": ""}]},
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
        pending_endpoint.shutdown()
        pending_endpoint.server_close()
        pending_thread.join(timeout=5)

        # Structured output remains an explicitly unavailable partial-build
        # surface. Even a complete 2xx text response cannot be published under
        # a frozen object schema without schema validation.
        schema_candidate = sse_answer(
            "schema-response", "schema-reasoning", "schema-message", "not a JSON object"
        )[0]
        schema_endpoint = SuccessEndpoint([schema_candidate])
        schema_thread = threading.Thread(target=schema_endpoint.serve_forever, daemon=True)
        schema_thread.start()
        schema_store = state / "unsupported-schema-store"
        schema_host = start_host(
            schema_store, f"http://127.0.0.1:{schema_endpoint.server_port}/responses"
        )
        processes.append(schema_host)
        configure(
            state,
            schema_store,
            "schema-config",
            "direct/unsupported-schema",
            "model-a",
            {"type": "object"},
        )
        message(
            state,
            schema_store,
            "schema-message",
            "direct/unsupported-schema",
            "return an object",
        )
        schema_failure = wait_for(
            lambda: (value := observe(schema_store, "schema-message")).get("result", {}).get("code")
            and value,
            "unsupported structured output rejection",
        )
        assert schema_failure["result"]["code"] == "unsupported_output_schema", schema_failure
        assert len(schema_endpoint.requests) == 1
        database = sqlite3.connect(schema_store / "latifa.sqlite3")
        assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
        assert database.execute(
            "SELECT count(*) FROM conversation_entry WHERE entry_kind=3"
        ).fetchone()[0] == 0
        assert database.execute(
            "SELECT outcome_content_id FROM turn"
        ).fetchone()[0] is None
        database.close()
        stop_host(schema_host)
        processes.remove(schema_host)
        schema_endpoint.shutdown()
        schema_endpoint.server_close()
        schema_thread.join(timeout=5)

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
            ],
            done=False,
        )
        unsupported_tool = encode_sse(
            [
                {
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": {"type": "function_call", "id": "tool-1"},
                }
            ],
            done=False,
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
        invalid_endpoint = SuccessEndpoint(
            [
                first_sse[:-1],
                contradictory,
                changed_terminal,
                duplicate_identity,
                late_malformed,
                unsupported_tool,
                *encrypted_cases,
            ]
        )
        invalid_thread = threading.Thread(target=invalid_endpoint.serve_forever, daemon=True)
        invalid_thread.start()
        for index, expected_code in enumerate(
            (
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "unsupported_provider_output",
                "malformed_provider_output",
                "continuation_unavailable",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "malformed_provider_output",
                "continuation_unavailable",
            )
        ):
            invalid_store = state / f"invalid-output-{index}"
            invalid_host = start_host(
                invalid_store, f"http://127.0.0.1:{invalid_endpoint.server_port}/responses"
            )
            processes.append(invalid_host)
            configure(state, invalid_store, f"invalid-config-{index}", f"direct/invalid-{index}", "model-a")
            message(
                state,
                invalid_store,
                f"invalid-message-{index}",
                f"direct/invalid-{index}",
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
            database = sqlite3.connect(invalid_store / "latifa.sqlite3")
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
            assert database.execute(
                "SELECT count(*) FROM conversation_entry WHERE entry_kind=3"
            ).fetchone()[0] == 0
            database.close()
            stop_host(invalid_host)
            processes.remove(invalid_host)
        invalid_endpoint.shutdown()
        invalid_endpoint.server_close()
        invalid_thread.join(timeout=5)

        fault_responses = []
        for index in range(7):
            fault_responses.append(
                sse_answer(f"fault-response-{index}", f"fault-r-{index}", f"fault-m-{index}", "answer")[0]
            )
        output_fault_endpoint = SuccessEndpoint(fault_responses)
        output_fault_thread = threading.Thread(
            target=output_fault_endpoint.serve_forever, daemon=True
        )
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
            configure(state, fault_store, f"{fault}-config", f"direct/{fault}", "model-a")
            message(state, fault_store, f"{fault}-message", f"direct/{fault}", "fault")
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

        for index, fault in enumerate(("response-read", "response-import", "response-commit")):
            fault_store = state / f"{fault}-store"
            fault_host = start_host(
                fault_store,
                f"http://127.0.0.1:{output_fault_endpoint.server_port}/responses",
                "--fault",
                fault,
            )
            processes.append(fault_host)
            configure(state, fault_store, f"{fault}-config", f"direct/{fault}", "model-a")
            message(state, fault_store, f"{fault}-message", f"direct/{fault}", "fault")
            wait_for(lambda: fault_host.poll() is not None, f"{fault} fenced shutdown")
            assert fault_host.returncode != 0
            processes.remove(fault_host)
            database = sqlite3.connect(fault_store / "latifa.sqlite3")
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
            assert database.execute(
                "SELECT uncertain,resolution_code FROM model_operation"
            ).fetchone() == (1, None)
            database.close()
        output_fault_endpoint.shutdown()
        output_fault_endpoint.server_close()
        output_fault_thread.join(timeout=5)

        scratch_endpoint = SuccessEndpoint(
            [sse_answer("scratch-response", "scratch-r", "scratch-m", "x" * 100_000)[0]]
        )
        scratch_thread = threading.Thread(target=scratch_endpoint.serve_forever, daemon=True)
        scratch_thread.start()
        scratch_store = state / "response-scratch-store"
        scratch_host = start_host(
            scratch_store,
            f"http://127.0.0.1:{scratch_endpoint.server_port}/responses",
            "--test-request-scratch-limit",
            str(64 * 1024),
        )
        processes.append(scratch_host)
        configure(state, scratch_store, "scratch-config", "direct/response-scratch", "model-a")
        message(state, scratch_store, "scratch-message", "direct/response-scratch", "scratch")
        rejected = wait_for(
            lambda: (value := observe(scratch_store, "scratch-message")).get("result", {}).get("code")
            and value,
            "response scratch exhaustion",
        )
        assert rejected["result"]["code"] == "response_scratch_exhausted", rejected
        assert command(
            "inspect-session",
            "--store",
            scratch_store,
            "--session",
            "direct/response-scratch",
        )["execution"]["scratch_used_bytes"] == "0"
        stop_host(scratch_host)
        processes.remove(scratch_host)
        scratch_endpoint.shutdown()
        scratch_endpoint.server_close()
        scratch_thread.join(timeout=5)

        # Item cardinality and answer bytes grow independently while execution
        # capacity remains one and metadata/capture stay in shared scratch.
        count_payload = sse_many("many-items", 32, "count answer")
        large_answer = "z" * 100_000
        byte_payload = sse_many("large-answer", 1, large_answer)
        growth_endpoint = SuccessEndpoint([count_payload, byte_payload])
        growth_thread = threading.Thread(target=growth_endpoint.serve_forever, daemon=True)
        growth_thread.start()
        growth_store = state / "growth-store"
        growth_host = start_host(
            growth_store, f"http://127.0.0.1:{growth_endpoint.server_port}/responses"
        )
        processes.append(growth_host)
        configure(state, growth_store, "growth-config-a", "direct/growth-a", "model-a")
        configure(state, growth_store, "growth-config-b", "direct/growth-b", "model-a")
        message(state, growth_store, "growth-count", "direct/growth-a", "count")
        wait_for(lambda: completed_observation(growth_store, "growth-count"), "many item output")
        message(state, growth_store, "growth-bytes", "direct/growth-b", "bytes")
        wait_for(
            lambda: completed_observation(growth_store, "growth-bytes"),
            "large output import",
            timeout=20,
        )
        assert read_result(growth_store, "growth-count") == b"count answer"
        # A failed caller destination may retain a prefix, but it cannot make
        # the read successful or consume the saved keyed answer. A fresh read
        # streams the complete bytes again without inventing a newline.
        read_fd, write_fd = os.pipe()
        failed_destination = subprocess.Popen(
            [
                str(LATIFA),
                "read-result",
                "--store",
                str(growth_store),
                "--key",
                "growth-bytes",
            ],
            stdout=write_fd,
            stderr=subprocess.PIPE,
        )
        os.close(write_fd)
        prefix = os.read(read_fd, 4096)
        os.close(read_fd)
        _, failure_stderr = failed_destination.communicate(timeout=15)
        assert failed_destination.returncode != 0, failure_stderr
        assert 0 < len(prefix) < len(large_answer), len(prefix)
        complete_path = state / "growth-answer.bin"
        with complete_path.open("wb") as complete_destination:
            completed_read = subprocess.run(
                [
                    str(LATIFA),
                    "read-result",
                    "--store",
                    str(growth_store),
                    "--key",
                    "growth-bytes",
                ],
                stdout=complete_destination,
                stderr=subprocess.PIPE,
                timeout=15,
            )
        assert completed_read.returncode == 0, completed_read.stderr
        assert complete_path.stat().st_size == len(large_answer)
        with complete_path.open("rb") as complete_source:
            actual_digest = hashlib.file_digest(complete_source, "sha256").digest()
        assert actual_digest == hashlib.sha256(large_answer.encode()).digest()
        database = sqlite3.connect(growth_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT count(*) FROM model_output_item WHERE operation_id=1"
        ).fetchone()[0] == 33
        assert database.execute("SELECT payload IS NULL,byte_length FROM content WHERE byte_length=? AND private=0", (len(large_answer),)).fetchall() == [(1, len(large_answer))]
        assert database.execute("SELECT coalesce(sum(length(payload)),0) FROM content WHERE private=0").fetchone()[0] < 1024
        database.close()
        resources = command(
            "inspect-session", "--store", growth_store, "--session", "direct/growth-b"
        )["execution"]
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(growth_host)
        processes.remove(growth_host)
        growth_endpoint.shutdown()
        growth_endpoint.server_close()
        growth_thread.join(timeout=5)

        # Public answers are projections of immutable provider items. Exercise
        # both dedup orders: answer then caller input, and caller then answer.
        parts = ["", "x" * 4093 + "\n", "🙂\t\\", ""]
        projected_answer = "".join(parts).encode()
        projection_endpoint = SuccessEndpoint([
            sse_answer("projection-1", "p-r1", "p-m1", parts)[0],
            sse_answer("projection-2", "p-r2", "p-m2", "caller-first")[0],
        ])
        projection_thread = threading.Thread(target=projection_endpoint.serve_forever, daemon=True)
        projection_thread.start()
        projection_store = state / "projection-store"
        projection_url = f"http://127.0.0.1:{projection_endpoint.server_port}/responses"
        host = start_host(projection_store, projection_url)
        processes.append(host)
        configure(state, projection_store, "projection-config", "direct/projection", "model-a", instructions="caller-first")
        message(state, projection_store, "projection-first", "direct/projection", "first")
        wait_for(lambda: completed_observation(projection_store, "projection-first"), "projected answer")
        assert read_result(projection_store, "projection-first") == projected_answer
        configure(state, projection_store, "projection-update", "direct/projection", "model-a", instructions=projected_answer.decode())
        message(state, projection_store, "projection-second", "direct/projection", projected_answer.decode())
        wait_for(lambda: completed_observation(projection_store, "projection-second"), "deduplicated answer")
        assert read_result(projection_store, "projection-second") == b"caller-first"
        replay = json.loads(projection_endpoint.requests[1])["input"]
        assert replay[-1]["content"][0]["text"] == projected_answer.decode(), replay
        assert replay[-2]["content"][0]["text"] == projected_answer.decode(), replay
        stop_host(host)
        processes.remove(host)
        with sqlite3.connect(projection_store / "latifa.sqlite3") as database:
            assert database.execute("SELECT c.payload IS NULL FROM model_operation o JOIN content c ON c.content_id=o.resolution_content_id ORDER BY o.operation_id").fetchall() == [(1,), (0,)]
            assert database.execute("SELECT count(*) FROM answer_text_projection").fetchone()[0] == len(parts)
            assert database.execute("SELECT count(*) FROM answer_text_projection p JOIN content c ON c.content_id=p.source_content_id WHERE c.private<>1 OR c.payload IS NULL").fetchone()[0] == 0
        host = start_host(projection_store, projection_url)
        processes.append(host)
        assert read_result(projection_store, "projection-first") == projected_answer
        assert read_result(projection_store, "projection-second") == b"caller-first"
        stop_host(host)
        processes.remove(host)
        projection_endpoint.shutdown()
        projection_endpoint.server_close()
        projection_thread.join(timeout=5)

        # A committed permit launches exactly one complete frozen request. The
        # endpoint holds the response so later settings and input arrive while
        # the admitted request is demonstrably in flight.
        store = state / "frozen-store"
        host = start_host(store, url, "--test-cleanup-delay-ms", "3000")
        processes.append(host)
        output_schema = {
            "type": "object",
            "properties": {"answer": {"type": "string"}},
            "required": ["answer"],
            "additionalProperties": False,
        }
        configure(state, store, "config-a", "direct/main", "model-a", output_schema, "A")
        configure(state, store, "instructions-b", "direct/main", "model-a", instructions="B")
        configure(state, store, "instructions-a", "direct/main", "model-a", instructions="A")
        configure(state, store, "instructions-a-again", "direct/main", "model-a", instructions="A")
        message(state, store, "message-a", "direct/main", 'first "message"\n')
        if not endpoint.received.wait(8):
            raise AssertionError("endpoint did not receive committed request")
        active_model_change = command(
            "configure",
            "--store",
            store,
            "--record",
            state / "config-b.json",
            "--key",
            "config-b",
            "--session",
            "direct/main",
            "--model",
            "model-b",
        )
        assert active_model_change["answer"]["status"] == "rejected", active_model_change
        assert active_model_change["answer"]["code"] == "continuation_model_incompatible"
        message(state, store, "message-b", "direct/main", "later message")
        assert len(endpoint.requests) == 1
        resources = command(
            "inspect-session", "--store", store, "--session", "direct/main"
        )["execution"]
        assert int(resources["scratch_used_bytes"]) == len(endpoint.requests[0]), resources
        endpoint.release.set()
        failed = wait_for(
            lambda: (value := observe(store, "message-a"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "provider_http_422"
            and value,
            "saved permanent failure",
        )
        assert failed["queue"]["status"] == "failed", failed
        assert failed["processing"]["attempt"] == "1", failed
        configure(state, store, "config-b-after-failure", "direct/main", "model-b")
        later = observe(store, "message-b")
        assert later["queue"]["status"] == "queued", later
        assert len(endpoint.requests) == 1, "a permit launched more than once"

        observed = json.loads(endpoint.requests[0])
        expected = {
            "model": "model-a",
            "store": False,
            "stream": True,
            "include": ["reasoning.encrypted_content"],
            "input": [
                {"role": "system", "content": [{"type": "input_text", "text": "A"}]},
                {
                    "role": "user",
                    "content": [{"type": "input_text", "text": 'first "message"\n'}],
                },
                {"role": "system", "content": [{"type": "input_text", "text": "B"}]},
                {"role": "system", "content": [{"type": "input_text", "text": "A"}]},
                {"role": "system", "content": [{"type": "input_text", "text": "A"}]},
            ],
            "tools": [
                {"type": "function", "name": "bash", "description": "Run Bash"},
                {"type": "function", "name": "edit", "description": "Edit one file"},
            ],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "latifa_output",
                    "strict": True,
                    "schema": output_schema,
                }
            },
        }
        assert observed == expected, (observed, expected)
        stop_host(host)
        processes.remove(host)

        # Killing the execution owner cannot erase the saved result or admit
        # input beyond the first Operation's cutoff.
        offline = start_host(store, None)
        processes.append(offline)
        assert observe(store, "message-a")["result"]["code"] == "provider_http_422"
        assert observe(store, "message-b")["queue"]["status"] == "queued"
        stop_host(offline)
        processes.remove(offline)

        # A successor reuses complete projected history in its original order.
        # The prior failed Turn's messages and each distinct instruction update
        # survive restart, including repeated equal text and reversals.
        host = start_host(store, url)
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 2, "successor history request")
        successor = json.loads(endpoint.requests[1])
        assert successor["input"] == expected["input"] + [
            {"role": "user", "content": [{"type": "input_text", "text": "later message"}]}
        ], successor
        assert successor["model"] == "model-b", successor
        wait_for(lambda: observe(store, "message-b").get("result", {}).get("code") == "provider_http_422", "successor failure")
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
        configure(
            state,
            preparation_store,
            "preparation-config",
            "direct/preparation",
            "model-a",
        )
        message(
            state,
            preparation_store,
            "preparation-message",
            "direct/preparation",
            "known preparation failure",
        )

        def known_preparation_settled():
            observation = observe(preparation_store, "preparation-message")
            if observation.get("processing", {}).get("attempt") != "1":
                return None
            resources = command(
                "inspect-session",
                "--store",
                preparation_store,
                "--session",
                "direct/preparation",
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
        database = sqlite3.connect(preparation_store / "latifa.sqlite3")
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
            "inspect-session",
            "--store",
            preparation_store,
            "--session",
            "direct/preparation",
        )["execution"]
        assert resources["dispatch_fenced"] is False, resources
        stop_host(preparation_host)
        processes.remove(preparation_host)
        preparation_endpoint.shutdown()
        preparation_endpoint.server_close()
        preparation_thread.join(timeout=5)

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
        prelaunch_thread.start()
        prelaunch_store = state / "crash-prelaunch-store"
        prelaunch_host = start_host(
            prelaunch_store,
            f"http://127.0.0.1:{prelaunch_endpoint.server_port}/responses",
            "--test-before-launch-delay-ms",
            "5000",
        )
        processes.append(prelaunch_host)
        configure(
            state, prelaunch_store, "prelaunch-config", "direct/prelaunch", "model-a"
        )
        message(
            state,
            prelaunch_store,
            "prelaunch-message",
            "direct/prelaunch",
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
        database = sqlite3.connect(prelaunch_store / "latifa.sqlite3")
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
            "inspect-session",
            "--store",
            prelaunch_store,
            "--session",
            "direct/prelaunch",
        )["execution"]
        assert resources["dispatch_fenced"] is False, resources
        stop_host(prelaunch_host)
        processes.remove(prelaunch_host)
        prelaunch_endpoint.shutdown()
        prelaunch_endpoint.server_close()
        prelaunch_thread.join(timeout=5)

        launched_release = threading.Event()
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
        launched_thread.start()
        launched_store = state / "crash-launched-store"
        launched_host = start_host(
            launched_store,
            f"http://127.0.0.1:{launched_endpoint.server_port}/responses",
        )
        processes.append(launched_host)
        configure(
            state, launched_store, "launched-config", "direct/launched", "model-a"
        )
        message(
            state,
            launched_store,
            "launched-message",
            "direct/launched",
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
        launched_endpoint.shutdown()
        launched_endpoint.server_close()
        launched_thread.join(timeout=5)

        sealed_lost = sse_answer(
            "sealed-lost", "sealed-lost-r", "sealed-lost-m", "lost sealed answer"
        )[0]
        sealed_recovered = sse_answer(
            "sealed-recovered", "sealed-r", "sealed-m", "sealed answer"
        )[0]
        sealed_endpoint = SuccessEndpoint([sealed_lost, sealed_recovered])
        sealed_thread = threading.Thread(target=sealed_endpoint.serve_forever, daemon=True)
        sealed_thread.start()
        sealed_store = state / "crash-sealed-store"
        sealed_host = start_host(
            sealed_store,
            f"http://127.0.0.1:{sealed_endpoint.server_port}/responses",
            "--test-before-result-delay-ms",
            "5000",
        )
        processes.append(sealed_host)
        configure(state, sealed_store, "sealed-config", "direct/sealed", "model-a")
        message(
            state,
            sealed_store,
            "sealed-message",
            "direct/sealed",
            "crash after seal",
        )
        wait_for(lambda: len(sealed_endpoint.requests) == 1, "sealed response delivery")
        time.sleep(0.5)
        database = sqlite3.connect(sealed_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,uncertain,resolution_code FROM model_operation"
        ).fetchone() == (1, 1, None)
        assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
        database.close()
        stop_host(sealed_host)
        processes.remove(sealed_host)
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
        sealed_endpoint.shutdown()
        sealed_endpoint.server_close()
        sealed_thread.join(timeout=5)

        committed_sse = sse_answer(
            "committed-response", "committed-r", "committed-m", "committed answer"
        )[0]
        committed_endpoint = SuccessEndpoint([committed_sse])
        committed_thread = threading.Thread(
            target=committed_endpoint.serve_forever, daemon=True
        )
        committed_thread.start()
        committed_store = state / "crash-committed-store"
        committed_host = start_host(
            committed_store,
            f"http://127.0.0.1:{committed_endpoint.server_port}/responses",
            "--test-cleanup-delay-ms",
            "5000",
        )
        processes.append(committed_host)
        configure(
            state, committed_store, "committed-config", "direct/committed", "model-a"
        )
        message(
            state,
            committed_store,
            "committed-message",
            "direct/committed",
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
        committed_endpoint.shutdown()
        committed_endpoint.server_close()
        committed_thread.join(timeout=5)

        # Full execution capacity leaves later work as only a durable queued
        # admission: no Attempt, request scratch, or resident waiter appears.
        # Releasing custody is sufficient to make progress without a new
        # message or notification.
        capacity_release = threading.Event()
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
        capacity_thread.start()
        durable_wait_store = state / "durable-capacity-wait-store"
        durable_wait_host = start_host(
            durable_wait_store,
            f"http://127.0.0.1:{capacity_endpoint.server_port}/responses",
            "--test-cleanup-delay-ms",
            "1500",
        )
        processes.append(durable_wait_host)
        configure(
            state,
            durable_wait_store,
            "capacity-wait-config-a",
            "direct/capacity-wait-a",
            "model-a",
        )
        configure(
            state,
            durable_wait_store,
            "capacity-wait-config-b",
            "direct/capacity-wait-b",
            "model-a",
        )
        message(
            state,
            durable_wait_store,
            "capacity-wait-message-a",
            "direct/capacity-wait-a",
            "occupy capacity",
        )
        wait_for(lambda: len(capacity_endpoint.requests) == 1, "occupied capacity")
        scratch_before = command(
            "inspect-session",
            "--store",
            durable_wait_store,
            "--session",
            "direct/capacity-wait-a",
        )["execution"]["scratch_used_bytes"]
        message(
            state,
            durable_wait_store,
            "capacity-wait-message-b",
            "direct/capacity-wait-b",
            "wait durably",
        )
        scratch_after = command(
            "inspect-session",
            "--store",
            durable_wait_store,
            "--session",
            "direct/capacity-wait-b",
        )["execution"]["scratch_used_bytes"]
        assert scratch_after == scratch_before
        database = sqlite3.connect(durable_wait_store / "latifa.sqlite3")
        assert database.execute("SELECT count(*) FROM model_operation").fetchone()[0] == 1
        assert database.execute(
            "SELECT turn_id FROM message_admission WHERE command_key='capacity-wait-message-b'"
        ).fetchone()[0] is None
        database.close()
        assert len(capacity_endpoint.requests) == 1
        capacity_release.set()
        wait_for(
            lambda: completed_observation(
                durable_wait_store, "capacity-wait-message-b"
            ),
            "capacity release progress without notification",
            timeout=8,
        )
        assert read_result(
            durable_wait_store, "capacity-wait-message-b"
        ) == b"capacity released"
        assert len(capacity_endpoint.requests) == 2
        stop_host(durable_wait_host)
        processes.remove(durable_wait_host)
        capacity_endpoint.shutdown()
        capacity_endpoint.server_close()
        capacity_thread.join(timeout=5)

        # Retry selection is taken only when execution capacity is available.
        # A candidate observed while full cannot survive until release and
        # bypass an older Operation that becomes due in the meantime.
        stale_release = threading.Event()
        stale_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"older waiting", {}, 503),
                ResponseSpec(b"newer waiting", {}, 503),
                (ResponseSpec(b"capacity owner", {}, 422), stale_release),
                ResponseSpec(b"selected after release", {}, 422),
                ResponseSpec(b"remaining retry", {}, 422),
            ]
        )
        stale_thread = threading.Thread(target=stale_endpoint.serve_forever, daemon=True)
        stale_thread.start()
        stale_store = state / "retry-release-order-store"
        stale_host = start_host(
            stale_store,
            f"http://127.0.0.1:{stale_endpoint.server_port}/responses",
            "--test-retry-waits-ms",
            "60000,60000,60000",
        )
        processes.append(stale_host)
        for name in ("older", "newer", "capacity"):
            expected_requests = len(stale_endpoint.requests) + 1
            configure(
                state,
                stale_store,
                f"stale-{name}-config",
                f"direct/stale-{name}",
                "model-a",
            )
            message(
                state,
                stale_store,
                f"stale-{name}-message",
                f"direct/stale-{name}",
                f"stale-{name}",
            )
            wait_for(
                lambda expected=expected_requests: len(stale_endpoint.requests) >= expected,
                f"{name} initial Attempt",
            )
        database = sqlite3.connect(stale_store / "latifa.sqlite3")
        try:
            now_ms = time.time_ns() // 1_000_000
            database.execute(
                "UPDATE model_operation SET retry_due_at_ms=? WHERE operation_id=1",
                (now_ms + 3000,),
            )
            database.execute(
                "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=2"
            )
            database.commit()
        finally:
            database.close()
        time.sleep(3.2)
        stale_release.set()
        wait_for(lambda: len(stale_endpoint.requests) >= 4, "retry after capacity release")
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
        stale_endpoint.shutdown()
        stale_endpoint.server_close()
        stale_thread.join(timeout=5)

        # The smallest age-indexed selector keeps no scan state. With one live
        # transport and one free slot it still finds a due Operation behind
        # 100 older future retries within the light-discovery target.
        backlog_stall_release = threading.Event()
        backlog_retry_release = threading.Event()
        backlog_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"initial temporary failure", {}, 503),
                (ResponseSpec(b"stalled live request", {}, 422), backlog_stall_release),
                (ResponseSpec(b"selected retry", {}, 422), backlog_retry_release),
            ]
        )
        backlog_thread = threading.Thread(target=backlog_endpoint.serve_forever, daemon=True)
        backlog_thread.start()
        backlog_store = state / "retry-age-backlog-store"
        backlog_host = start_host(
            backlog_store,
            f"http://127.0.0.1:{backlog_endpoint.server_port}/responses",
            "--fault",
            "attempt-before-commit",
        )
        processes.append(backlog_host)
        configure(state, backlog_store, "backlog-config", "direct/backlog", "model-a")
        message(
            state,
            backlog_store,
            "backlog-message",
            "direct/backlog",
            "due-behind-future-history",
        )
        time.sleep(0.2)
        assert backlog_endpoint.requests == []
        stop_host(backlog_host)
        processes.remove(backlog_host)
        database = sqlite3.connect(backlog_store / "latifa.sqlite3")
        try:
            database.execute("PRAGMA foreign_keys=OFF")
            database.execute(
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL "
                "SELECT value+1 FROM sequence WHERE value<100) "
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,"
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) "
                "SELECT value,value,printf('future-%d',value),1,1,1,1,1,0,9223372036854775807 FROM sequence"
            )
            database.commit()
        finally:
            database.close()
        backlog_host = start_host(
            backlog_store,
            f"http://127.0.0.1:{backlog_endpoint.server_port}/responses",
            "--active-capacity",
            "2",
            "--test-retry-waits-ms",
            "2000,60000,60000",
        )
        processes.append(backlog_host)
        wait_for(lambda: len(backlog_endpoint.requests) == 1, "future-backlog initial Attempt")
        configure(
            state,
            backlog_store,
            "backlog-stall-config",
            "direct/backlog-stall",
            "model-a",
        )
        message(
            state,
            backlog_store,
            "backlog-stall-message",
            "direct/backlog-stall",
            "occupy-one-slot",
        )
        wait_for(lambda: len(backlog_endpoint.requests) == 2, "stalled live backlog request")
        wait_for(
            lambda: len(backlog_endpoint.requests) == 3,
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
        backlog_endpoint.shutdown()
        backlog_endpoint.server_close()
        backlog_thread.join(timeout=5)

        # Exhausted recovery and admission are independent work in one Host
        # turn. A due retry and then queued new work both receive free custody
        # while a high-age exhausted sentinel proves the restart backlog is
        # still unresolved; ordinary inspection progresses and recovery
        # eventually drains.
        recovery_retry_release = threading.Event()
        recovery_new_release = threading.Event()
        recovery_endpoint = SuccessEndpoint(
            [
                ResponseSpec(b"retry later", {}, 503),
                ResponseSpec(b"sentinel retry later", {}, 503),
                (ResponseSpec(b"retried", {}, 422), recovery_retry_release),
                (ResponseSpec(b"new work", {}, 422), recovery_new_release),
            ]
        )
        recovery_thread = threading.Thread(
            target=recovery_endpoint.serve_forever, daemon=True
        )
        recovery_thread.start()
        recovery_store = state / "exhausted-control-store"
        recovery_host = start_host(
            recovery_store,
            f"http://127.0.0.1:{recovery_endpoint.server_port}/responses",
            "--fault",
            "attempt-before-commit",
        )
        processes.append(recovery_host)
        stop_host(recovery_host)
        processes.remove(recovery_host)
        database = sqlite3.connect(recovery_store / "latifa.sqlite3")
        try:
            database.execute("PRAGMA foreign_keys=OFF")
            database.execute(
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL "
                "SELECT value+1 FROM sequence WHERE value<100) "
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,"
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) "
                "SELECT value,value,printf('recovery-%d',value),1,1,1,1,1,0,9223372036854775807 "
                "FROM sequence"
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
        for name in ("due", "sentinel"):
            configure(
                state,
                recovery_store,
                f"recovery-{name}-config",
                f"direct/recovery-{name}",
                "model-a",
            )
            message(
                state,
                recovery_store,
                f"recovery-{name}-message",
                f"direct/recovery-{name}",
                f"recovery-{name}",
            )
        wait_for(lambda: len(recovery_endpoint.requests) == 2, "recovery setup Attempts")
        wait_for(
            lambda: command(
                "inspect-session",
                "--store",
                recovery_store,
                "--session",
                "direct/recovery-sentinel",
            )["execution"]["custody_occupied"]
            == "0",
            "recovery setup cleanup",
        )
        stop_host(recovery_host)
        processes.remove(recovery_host)
        recovery_host = start_host(
            recovery_store,
            f"http://127.0.0.1:{recovery_endpoint.server_port}/responses",
            "--fault",
            "attempt-before-commit",
        )
        processes.append(recovery_host)
        configure(
            state,
            recovery_store,
            "recovery-new-config",
            "direct/recovery-new",
            "model-a",
        )
        message(
            state,
            recovery_store,
            "recovery-new-message",
            "direct/recovery-new",
            "recovery-new",
        )
        time.sleep(0.2)
        assert len(recovery_endpoint.requests) == 2
        stop_host(recovery_host)
        processes.remove(recovery_host)
        database = sqlite3.connect(recovery_store / "latifa.sqlite3")
        try:
            database.execute("PRAGMA foreign_keys=OFF")
            due_operation = database.execute(
                "SELECT operation_id FROM model_operation WHERE session_ref='direct/recovery-due'"
            ).fetchone()[0]
            sentinel_operation = database.execute(
                "SELECT operation_id FROM model_operation WHERE session_ref='direct/recovery-sentinel'"
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
            database.execute(
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<100) "
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) "
                "SELECT value+10000,printf('recovery-%d',value),1,1,value FROM sequence"
            )
            database.execute(
                "UPDATE model_operation SET turn_id=operation_id+10000 WHERE operation_id<=100"
            )
            database.commit()
        finally:
            database.close()
        recovery_host = start_host(
            recovery_store,
            f"http://127.0.0.1:{recovery_endpoint.server_port}/responses",
            "--active-capacity",
            "2",
            "--test-before-launch-delay-ms",
            "100",
            "--test-retry-waits-ms",
            "60000,60000,60000",
        )
        processes.append(recovery_host)
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
            "inspect-session",
            "--store",
            recovery_store,
            "--session",
            "direct/recovery-sentinel",
        )
        assert inspection["execution"]["dispatch_fenced"] is False, inspection
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
        assert command(
            "inspect-session",
            "--store",
            recovery_store,
            "--session",
            "direct/recovery-new",
        )["execution"]["custody_occupied"] == "2"
        assert "result" not in observe(
            recovery_store, "recovery-sentinel-message"
        ), unresolved_sentinel
        wait_for(lambda: len(recovery_endpoint.requests) >= 4, "recovery new launch")
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
        assert len(recovery_latencies) >= 20, len(recovery_latencies)
        ordered_latencies = sorted(recovery_latencies)
        recovery_p95 = ordered_latencies[
            (95 * len(ordered_latencies) + 99) // 100 - 1
        ]
        recovery_max = ordered_latencies[-1]
        print(
            "exhausted recovery ordinary inspections (diagnostic only): "
            f"samples={len(recovery_latencies)} "
            f"p95_ms={recovery_p95 * 1000:.1f} "
            f"max_ms={recovery_max * 1000:.1f}"
        )
        stop_host(recovery_host)
        processes.remove(recovery_host)
        database = sqlite3.connect(recovery_store / "latifa.sqlite3")
        try:
            assert database.execute(
                "SELECT count(*) FROM model_operation WHERE uncertain=1 AND allowance_used=4 "
                "AND retry_due_at_ms=0 AND resolution_code IS NULL"
            ).fetchone()[0] == 0
        finally:
            database.close()
        recovery_endpoint.shutdown()
        recovery_endpoint.server_close()
        recovery_thread.join(timeout=5)

        # Exhaustion settles only the selected prefix. Input admitted while
        # those retries run remains unselected and receives the outcome of the
        # successor Turn that eventually takes it.
        exhaustion_release = threading.Event()
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
        exhaustion_thread.start()
        exhaustion_store = state / "retry-exhaustion-store"
        exhaustion_host = start_host(
            exhaustion_store,
            f"http://127.0.0.1:{exhaustion_endpoint.server_port}/responses",
        )
        processes.append(exhaustion_host)
        configure(
            state,
            exhaustion_store,
            "exhaustion-config",
            "direct/exhaustion",
            "model-a",
        )
        message(
            state,
            exhaustion_store,
            "exhaustion-first",
            "direct/exhaustion",
            "selected first",
        )
        wait_for(lambda: len(exhaustion_endpoint.requests) == 1, "first exhaustion Attempt")
        message(
            state,
            exhaustion_store,
            "exhaustion-later",
            "direct/exhaustion",
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
        database = sqlite3.connect(exhaustion_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT attempt_ordinal,allowance_used,resolution_code FROM model_operation ORDER BY operation_id"
        ).fetchall() == [(4, 4, "retry_exhausted"), (1, 1, "completed")]
        database.close()
        assert len(exhaustion_endpoint.requests) == 5
        stop_host(exhaustion_host)
        processes.remove(exhaustion_host)
        exhaustion_endpoint.shutdown()
        exhaustion_endpoint.server_close()
        exhaustion_thread.join(timeout=5)

        # One reactor fills two fixed custody records without allocating a
        # worker per Session. Complete beta first and verify that the opaque
        # completion identity settles beta's binding while alpha remains live.
        alpha_release = threading.Event()
        beta_release = threading.Event()
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
        capacity_thread.start()
        capacity_store = state / "capacity-store"
        host = start_host(
            capacity_store,
            f"http://127.0.0.1:{capacity_endpoint.server_port}/responses",
            "--active-capacity",
            "2",
        )
        processes.append(host)
        configure(state, capacity_store, "capacity-config-a", "direct/capacity-a", "model-a")
        configure(state, capacity_store, "capacity-config-b", "direct/capacity-b", "model-a")
        message(state, capacity_store, "capacity-message-a", "direct/capacity-a", "alpha")
        message(state, capacity_store, "capacity-message-b", "direct/capacity-b", "beta")
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
        capacity_endpoint.shutdown()
        capacity_endpoint.server_close()
        capacity_thread.join(timeout=5)

        # A failed Attempt commit rolls back all provenance and cannot produce
        # an endpoint launch.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        rollback_store = state / "rollback-store"
        host = start_host(rollback_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, rollback_store, "rollback-config", "direct/rollback", "model-a")
        message(state, rollback_store, "rollback-message", "direct/rollback", "rollback")
        time.sleep(0.35)
        assert endpoint.requests == []
        assert observe(rollback_store, "rollback-message")["queue"]["status"] == "queued"
        stop_host(host)
        processes.remove(host)

        # The first fallible post-commit step consumes Attempt 1, saves a typed
        # failure, releases custody, and never reaches HTTP.
        first_store = state / "first-step-store"
        host = start_host(first_store, url, "--fault", "request-first-step")
        processes.append(host)
        configure(state, first_store, "first-config", "direct/first", "model-a")
        message(state, first_store, "first-message", "direct/first", "first step")
        failed = wait_for(
            lambda: (value := observe(first_store, "first-message"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "request_preparation_failed"
            and value,
            "saved first-step preparation failure",
        )
        assert failed["processing"]["attempt"] == "1", failed
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)

        for fault, expected_code in (
            ("request-scratch-acquire", "request_scratch_exhausted"),
            ("request-write", "request_write_failed"),
            ("request-seal", "request_seal_failed"),
        ):
            fault_store = state / f"{fault}-store"
            host = start_host(fault_store, url, "--fault", fault)
            processes.append(host)
            configure(state, fault_store, f"{fault}-config", f"direct/{fault}", "model-a")
            message(state, fault_store, f"{fault}-message", f"direct/{fault}", fault)
            failed = wait_for(
                lambda key=f"{fault}-message", code=expected_code: (
                    value := observe(fault_store, key)
                )["status"]
                == "accepted"
                and value.get("result", {}).get("code") == code
                and value,
                f"saved {fault} failure",
            )
            assert failed["processing"]["attempt"] == "1", failed
            assert endpoint.requests == []
            resources = command(
                "inspect-session",
                "--store",
                fault_store,
                "--session",
                f"direct/{fault}",
            )["execution"]
            assert resources["scratch_used_bytes"] == "0", resources
            stop_host(host)
            processes.remove(host)

        # A canonical save fault rolls back the claimed failure, fences the
        # live dispatch owner, and leaves the admitted Attempt uncertain for
        # the following retry/restart slice rather than recreating its permit.
        endpoint.requests.clear()
        endpoint.release.set()
        save_store = state / "save-fault-store"
        host = start_host(save_store, url, "--fault", "result-before-commit")
        processes.append(host)
        configure(state, save_store, "save-config", "direct/save", "model-a")
        message(state, save_store, "save-message", "direct/save", "save fault")
        wait_for(lambda: len(endpoint.requests) == 1, "save-fault endpoint request")
        time.sleep(0.2)
        failed_observation = subprocess.run(
            [str(LATIFA), "observe-command", "--store", str(save_store), "--key", "save-message"],
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
        endpoint.requests.clear()
        endpoint.release.clear()
        framing_store = state / "framing-store"
        host = start_host(framing_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, framing_store, "framing-config", "direct/framing", "model-a")
        for index in range(40):
            message(state, framing_store, f"framing-{index}", "direct/framing", "")
        stop_host(host)
        processes.remove(host)
        host = start_host(framing_store, url)
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 1, "many-input materialization")
        actual_request_bytes = len(endpoint.requests[0])
        resources = command(
            "inspect-session", "--store", framing_store, "--session", "direct/framing"
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
        host = start_host(framing_exact_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, framing_exact_store, "exact-config", "direct/framing-exact", "model-a")
        for index in range(40):
            message(state, framing_exact_store, f"exact-{index}", "direct/framing-exact", "")
        stop_host(host)
        processes.remove(host)
        host = start_host(
            framing_exact_store,
            url,
            "--test-request-scratch-limit",
            str(actual_request_bytes),
        )
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 1, "exact request capacity")
        assert len(endpoint.requests[0]) == actual_request_bytes
        resources = command(
            "inspect-session",
            "--store",
            framing_exact_store,
            "--session",
            "direct/framing-exact",
        )["execution"]
        assert int(resources["scratch_used_bytes"]) == actual_request_bytes, resources
        endpoint.release.set()
        exact_result = wait_for(
            lambda: (value := observe(framing_exact_store, "exact-0"))
            .get("result", {})
            .get("code")
            and value,
            "exact-capacity result",
        )
        # The request itself fits exactly and reaches HTTP. Its held charge
        # intentionally leaves no shared scratch for the fixture response.
        assert exact_result["result"]["code"] == "response_scratch_exhausted", exact_result
        resources = command(
            "inspect-session",
            "--store",
            framing_exact_store,
            "--session",
            "direct/framing-exact",
        )["execution"]
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(host)
        processes.remove(host)

        endpoint.requests.clear()
        endpoint.release.clear()
        framing_limit_store = state / "framing-limit-store"
        host = start_host(framing_limit_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, framing_limit_store, "limit-config", "direct/framing-limit", "model-a")
        for index in range(40):
            message(state, framing_limit_store, f"limit-{index}", "direct/framing-limit", "")
        stop_host(host)
        processes.remove(host)
        host = start_host(
            framing_limit_store,
            url,
            "--test-request-scratch-limit",
            str(actual_request_bytes - 1),
        )
        processes.append(host)
        limited = wait_for(
            lambda: (value := observe(framing_limit_store, "limit-0")).get("result", {}).get("code")
            == "request_scratch_exhausted"
            and value,
            "pre-dispatch framing capacity failure",
        )
        assert limited["processing"]["attempt"] == "1", limited
        assert endpoint.requests == []
        resources = command(
            "inspect-session",
            "--store",
            framing_limit_store,
            "--session",
            "direct/framing-limit",
        )["execution"]
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(host)
        processes.remove(host)

        # URL authority is parsed before curl sees it. Userinfo that makes a
        # prefix look loopback is rejected at startup and reaches no server.
        endpoint.requests.clear()
        deceptive = subprocess.run(
            [
                str(LATIFA), "serve", "--store", str(state / "deceptive-store"),
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
        configure(state, progress_store, "progress-config", "direct/progress", "model-a")
        message(state, progress_store, "progress-message", "direct/progress", "progress")
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
        )
        processes.append(host)
        configure(state, stall_store, "stall-config", "direct/stall", "model-a")
        message(state, stall_store, "stall-message", "direct/stall", "stall")
        stalled = wait_for(
            lambda: (value := observe(stall_store, "stall-message")).get("result", {}).get("code")
            == "retry_exhausted"
            and value,
            "stalled response inactivity failure",
            timeout=16,
        )
        assert stalled["queue"]["status"] == "failed"
        assert stalled["processing"]["attempt"] == "4", stalled
        stop_host(host)
        processes.remove(host)

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
            configure(case_state, transient_store, "config", "direct/transient", "model-a")
            message(case_state, transient_store, "message", "direct/transient", "input")
            wait_for(lambda: len(endpoint.requests) == 1, "one endpoint request")
            wait_for(lambda: command(
                "inspect-session", "--store", transient_store, "--session", "direct/transient"
            )["execution"]["custody_occupied"] == "0", "response cleanup")
            observation = observe(transient_store, "message")
            resources = command("inspect-session", "--store", transient_store, "--session", "direct/transient")["execution"]
            assert resources["scratch_used_bytes"] == "0", resources
            if path == "/large-422":
                assert observation["result"]["code"] == "provider_http_422", observation
            else:
                assert observation["queue"]["status"] == "processing" and "result" not in observation, observation
                assert observation["processing"]["attempt"] == "1", observation
                with sqlite3.connect(transient_store / "latifa.sqlite3") as database:
                    retry = database.execute(
                        "SELECT allowance_used,uncertain,resolution_code,last_failure_code,retry_due_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER) FROM model_operation"
                    ).fetchall()
                    expected_code = (
                        "provider_transport_failure"
                        if path == "/disconnect"
                        else f"provider_temporary_http_{path.rsplit('-', 1)[-1].lstrip('/')}"
                    )
                    assert retry == [(1, 0, None, expected_code, 1)], retry
                message(case_state, transient_store, "later", "direct/transient", "later")
                assert observe(transient_store, "later")["queue"]["status"] == "queued"
            stop_host(host)
            processes.remove(host)
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
        host = start_host(race_store, url, "--test-before-launch-delay-ms", "1500")
        processes.append(host)
        configure(state, race_store, "race-config", "direct/race", "model-a")
        message(state, race_store, "race-message", "direct/race", "race")

        # Observe through the Store owner: an external SQLite reader can
        # contend with admission in DELETE-journal/zero-busy-timeout mode.
        wait_for(
            lambda: observe(race_store, "race-message")["queue"]["status"] == "processing",
            "admitted request before launch",
        )
        database = sqlite3.connect(race_store / "latifa.sqlite3", timeout=5)
        original_instructions = database.execute(
            "SELECT instructions_content_id FROM session WHERE session_ref='direct/race'"
        ).fetchone()[0]
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/race'"
        )
        database.commit()
        database.close()
        canonical_read = subprocess.run(
            [str(LATIFA), "inspect-session", "--store", str(race_store), "--session", "direct/race"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert canonical_read.returncode != 0
        wait_for(lambda: host.poll() is not None, "effect-aware Host shutdown", timeout=5)
        assert host.returncode != 0
        processes.remove(host)
        assert endpoint.requests == []
        database = sqlite3.connect(race_store / "latifa.sqlite3")
        uncertain = database.execute(
            "SELECT attempt_ordinal,uncertain,resolution_code FROM model_operation"
        ).fetchone()
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "UPDATE session SET instructions_content_id=? WHERE session_ref='direct/race'",
            (original_instructions,),
        )
        database.commit()
        database.close()
        assert uncertain == (1, 1, None), uncertain
        repaired = start_host(race_store, None)
        processes.append(repaired)
        stop_host(repaired)
        processes.remove(repaired)

        # Response and validation-metadata unlink failures retain one named
        # file under custody and fence dispatch. A second failed cleanup leaves
        # it owned for the next startup, which removes only recognized names.
        unlink_output, _, _ = sse_answer(
            "unlink-response", "unlink-reasoning", "unlink-message", "must not publish"
        )
        unlink_endpoint = SuccessEndpoint([unlink_output])
        unlink_thread = threading.Thread(target=unlink_endpoint.serve_forever, daemon=True)
        unlink_thread.start()
        unlink_url = f"http://127.0.0.1:{unlink_endpoint.server_port}/responses"
        for fault, pattern, launched in (
            ("response-unlink", "response-[0-9]*.tmp", False),
            ("response-metadata-unlink", "response-metadata-*.tmp", True),
        ):
            owned_store = state / f"{fault}-owned-store"
            owned_host = start_host(owned_store, unlink_url, "--fault", fault)
            processes.append(owned_host)
            configure(state, owned_store, f"{fault}-config", f"direct/{fault}", "model-a")
            message(state, owned_store, f"{fault}-message", f"direct/{fault}", "unlink")
            leftovers = wait_for(
                lambda store=owned_store, glob=pattern: list((store / "scratch").glob(glob)),
                f"retained named {fault} scratch",
            )
            resources = command(
                "inspect-session", "--store", owned_store, "--session", f"direct/{fault}"
            )["execution"]
            assert resources["dispatch_fenced"] is True, resources
            assert resources["custody_occupied"] == "1", resources
            assert len(unlink_endpoint.requests) == (1 if launched else 0)
            database = sqlite3.connect(owned_store / "latifa.sqlite3")
            assert database.execute(
                "SELECT uncertain,resolution_code FROM model_operation"
            ).fetchone() == (1, None)
            assert database.execute("SELECT count(*) FROM model_output_item").fetchone()[0] == 0
            database.close()
            stop_host(owned_host)
            processes.remove(owned_host)
            assert leftovers[0].exists()

            failed_cleanup = subprocess.run(
                [
                    str(LATIFA),
                    "serve",
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
                "inspect-session", "--store", owned_store, "--session", f"direct/{fault}"
            )["execution"]
            assert resources["custody_occupied"] == "0", resources
            assert resources["scratch_used_bytes"] == "0", resources
            stop_host(cleanup_host)
            processes.remove(cleanup_host)
        unlink_endpoint.shutdown()
        unlink_endpoint.server_close()
        unlink_thread.join(timeout=5)

        # If initial unlink fails, the live owner keeps both descriptors and
        # named scratch while fencing later dispatch. No bytes have yet been
        # emitted, so logical scratch charge remains zero. A fresh owner removes
        # the identifiable leftover before serving.
        unlink_store = state / "unlink-store"
        host = start_host(unlink_store, url, "--fault", "request-unlink")
        processes.append(host)
        configure(state, unlink_store, "unlink-config", "direct/unlink", "model-a")
        message(state, unlink_store, "unlink-message", "direct/unlink", "unlink")
        leftovers = wait_for(
            lambda: list(unlink_store.rglob("request-*")),
            "retained named request scratch",
        )
        resources = command(
            "inspect-session", "--store", unlink_store, "--session", "direct/unlink"
        )["execution"]
        assert resources["dispatch_fenced"] is True, resources
        assert resources["custody_occupied"] == "1", resources
        assert resources["scratch_used_bytes"] == "0", resources
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)
        assert leftovers[0].exists()

        offline = start_host(unlink_store, None)
        processes.append(offline)
        assert not list(unlink_store.rglob("request-*"))
        resources = command(
            "inspect-session", "--store", unlink_store, "--session", "direct/unlink"
        )["execution"]
        assert resources["custody_occupied"] == "0", resources
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(offline)
        processes.remove(offline)
        completed = True
    finally:
        for process in processes:
            stop_host(process)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        if success_endpoint is not None:
            success_endpoint.shutdown()
            success_endpoint.server_close()
        if success_thread is not None:
            success_thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained dispatch integration failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
