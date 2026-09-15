#!/usr/bin/env python3
import http.server
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
                "text": answer,
                "annotations": [],
                "extension": {"kept": True},
            }
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

    def __init__(self, responses):
        super().__init__(("127.0.0.1", 0), SuccessHandler)
        self.responses = list(responses)
        self.requests = []
        self.lock = threading.Lock()


class ResponseSpec:
    def __init__(self, body, headers):
        self.body = body
        self.headers = headers


class SuccessHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        with self.server.lock:
            self.server.requests.append(body)
            if not self.server.responses:
                raise AssertionError("unexpected extra model request")
            payload = self.server.responses.pop(0)
        if isinstance(payload, tuple):
            payload, release = payload
            if not release.wait(10):
                raise RuntimeError("success fixture response was never released")
        headers = {"X-Request-Id": f"request-{len(self.server.requests)}", "OpenAI-Model": "model-a-served"}
        if isinstance(payload, ResponseSpec):
            headers = payload.headers
            payload = payload.body
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        for name, value in headers.items():
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


def start_host(store, endpoint, *extra):
    process = subprocess.Popen(
        [
            str(LATIFA),
            "serve",
            "--store",
            str(store),
            "--active-capacity",
            "1",
            "--provider-endpoint",
            endpoint,
            *extra,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if line.startswith("ready "):
            if "execution=enabled" not in line or "curl=8.22.0" not in line:
                raise AssertionError(f"missing transport readiness evidence: {line}")
            return process
        if process.poll() is not None:
            raise AssertionError(f"Host exited before ready: {process.stderr.read()}")
    raise AssertionError("Host did not become ready")


def stop_host(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


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
        offline_success = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(success_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline_success)
        assert offline_success.stdout.readline().startswith("ready ")
        assert read_result(success_store, "success-first") == first_answer
        assert read_result(success_store, "success-second") == second_answer
        stop_host(offline_success)
        processes.remove(offline_success)

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
            reopened = subprocess.Popen(
                [str(LATIFA), "serve", "--store", str(evidence_store), "--active-capacity", "1"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            processes.append(reopened)
            assert reopened.stdout.readline().startswith("ready ")
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
        contradictory_reopened = subprocess.Popen(
            [
                str(LATIFA),
                "serve",
                "--store",
                str(contradictory_store),
                "--active-capacity",
                "1",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(contradictory_reopened)
        assert contradictory_reopened.stdout.readline().startswith("ready ")
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
            [sse_answer("scratch-response", "scratch-r", "scratch-m", "x" * (1024 * 1024))[0]]
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
        count_payload = sse_many("many-items", 128, "count answer")
        large_answer = "z" * (5 * 1024 * 1024)
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
        assert read_result(growth_store, "growth-bytes") == large_answer.encode()
        database = sqlite3.connect(growth_store / "latifa.sqlite3")
        assert database.execute(
            "SELECT count(*) FROM model_output_item WHERE operation_id=1"
        ).fetchone()[0] == 129
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
        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
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

        # One reactor fills two fixed custody records without allocating a
        # worker per Session. Both requests reach the endpoint before either
        # response is released.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        capacity_store = state / "capacity-store"
        host = start_host(capacity_store, url, "--active-capacity", "2")
        processes.append(host)
        configure(state, capacity_store, "capacity-config-a", "direct/capacity-a", "model-a")
        configure(state, capacity_store, "capacity-config-b", "direct/capacity-b", "model-a")
        message(state, capacity_store, "capacity-message-a", "direct/capacity-a", "alpha")
        message(state, capacity_store, "capacity-message-b", "direct/capacity-b", "beta")
        wait_for(lambda: len(endpoint.requests) == 2, "two concurrent reactor requests")
        endpoint.release.set()
        wait_for(
            lambda: observe(capacity_store, "capacity-message-a").get("result", {}).get("code")
            == "provider_http_422",
            "first concurrent failure",
        )
        wait_for(
            lambda: observe(capacity_store, "capacity-message-b").get("result", {}).get("code")
            == "provider_http_422",
            "second concurrent failure",
        )
        stop_host(host)
        processes.remove(host)

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

        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(save_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
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
        wait_for(
            lambda: observe(stall_store, "stall-message")["queue"]["status"] == "processing" and command(
                "inspect-session", "--store", stall_store, "--session", "direct/stall"
            )["execution"]["custody_occupied"] == "0",
            "stalled response cleanup",
        )
        stalled = observe(stall_store, "stall-message")
        assert stalled["queue"]["status"] == "processing" and "result" not in stalled, stalled
        stop_host(host)
        processes.remove(host)

        # Discarding large bodies must preserve HTTP classification. Retryable
        # evidence releases physical custody without inventing a final result.
        for path in ("/large-422", "/large-429", "/429", "/503", "/disconnect"):
            case_state = state / (path[1:] + "-records")
            case_state.mkdir(mode=0o700)
            endpoint.requests.clear()
            endpoint.release.set()
            transient_store = state / (path[1:] + "-store")
            host = start_host(transient_store, f"http://127.0.0.1:{endpoint.server_port}{path}")
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
                    assert database.execute("SELECT allowance_used,uncertain,resolution_code FROM model_operation").fetchall() == [(1, 1, None)]
                message(case_state, transient_store, "later", "direct/transient", "later")
                assert observe(transient_store, "later")["queue"]["status"] == "queued"
            stop_host(host)
            processes.remove(host)
            host = start_host(transient_store, f"http://127.0.0.1:{endpoint.server_port}{path}")
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
        repaired = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(race_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(repaired)
        assert repaired.stdout.readline().startswith("ready ")
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

            cleanup_host = subprocess.Popen(
                [str(LATIFA), "serve", "--store", str(owned_store), "--active-capacity", "1"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            processes.append(cleanup_host)
            assert cleanup_host.stdout.readline().startswith("ready ")
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

        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(unlink_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
        assert not list(unlink_store.rglob("request-*"))
        resources = command(
            "inspect-session", "--store", unlink_store, "--session", "direct/unlink"
        )["execution"]
        assert resources["custody_occupied"] == "0", resources
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(offline)
        processes.remove(offline)
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
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
