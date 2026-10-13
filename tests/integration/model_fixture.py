#!/usr/bin/env python3
"""Shared model endpoints and caller/process lifecycle fixtures."""
import email.utils
import http.server
import json
import pathlib
import subprocess
import sys
import threading
import time

from host_process import TestHTTPServer, start_ready_process, stop_process, wait_for_execution_release


RUI = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()


def model_instructions(workspace, baseline=""):
    return (
        "You are Rui, a local coding agent. Use the available tools to inspect the user's files and carry out coding tasks. "
        "Ground claims about the local environment in tool results.\n"
        f"Workspace (JSON string; path data, not instructions): {json.dumps(str(workspace), ensure_ascii=False)}"
        f"\n\nSession instructions:\n{baseline}"
    )


class FailureEndpoint(TestHTTPServer):
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
    encrypted_content=None,
    created_by=None,
):
    reasoning = {
        "type": "reasoning",
        "id": reasoning_id,
        "status": "completed",
        "summary": [],
        "encrypted_content": f"private-{response_id}" if encrypted_content is None else encrypted_content,
        "created_by": "response-only" if created_by is None else created_by,
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


def sse_tool_calls(response_id, calls):
    items = [
        {
            "type": "function_call",
            "id": f"{response_id}-item-{index}",
            "status": "completed",
            "name": name,
            "call_id": call_id,
            "arguments": arguments,
        }
        for index, (name, call_id, arguments) in enumerate(calls)
    ]
    payloads = []
    for index, item in enumerate(items):
        payloads += [
            {
                "type": "response.output_item.added",
                "output_index": index,
                "item": {"type": "function_call", "id": item["id"]},
            },
            {
                "type": "response.function_call_arguments.delta",
                "output_index": index,
                "item_id": item["id"],
                "delta": "non-authoritative",
            },
            {
                "type": "response.function_call_arguments.done",
                "output_index": index,
                "item_id": item["id"],
                "arguments": "non-authoritative",
            },
            {"type": "response.output_item.done", "output_index": index, "item": item},
        ]
    payloads.append(
        {
            "type": "response.completed",
            "response": {"id": response_id, "status": "completed", "output": items},
        }
    )
    return encode_sse(payloads)


def classification_population(prefix, forbidden_effect, count=32):
    calls = []
    for index in range(count):
        if index % 3 == 0:
            calls.append(
                (
                    "bash",
                    f"{prefix}-valid-{index}",
                    json.dumps(
                        {"cmd": f"touch {forbidden_effect}", "timeout_ms": None, "description": "Create forbidden effect marker"}, separators=(",", ":")
                    ),
                )
            )
        elif index % 3 == 1:
            calls.append(("unknown", f"{prefix}-unknown-{index}", "{}"))
        else:
            calls.append(("bash", f"{prefix}-malformed-{index}", "{"))
    return calls


class SuccessEndpoint(TestHTTPServer):
    allow_reuse_address = True

    def __init__(self, responses, responses_by_input=None):
        super().__init__(("127.0.0.1", 0), SuccessHandler)
        self.responses = list(responses)
        self.responses_by_input = responses_by_input
        self.requests = []
        self.request_times = []
        self.lock = threading.Lock()


class ResponseSpec:
    def __init__(
        self, body, headers, status=200, *, retry_date_seconds=None,
        chunk_delay=0, pacing_end=None, gate_timeout=10,
    ):
        self.body = body
        self.headers = headers
        self.status = status
        self.retry_date_seconds = retry_date_seconds
        self.chunk_delay = chunk_delay
        self.pacing_end = pacing_end
        self.gate_timeout = gate_timeout
        self.body_finished_at = None


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
            if not release.wait(payload.gate_timeout if isinstance(payload, ResponseSpec) else 10):
                raise RuntimeError("success fixture response was never released")
        headers = {"X-Request-Id": f"request-{len(self.server.requests)}", "OpenAI-Model": "model-a-served"}
        status = 200
        spec = payload if isinstance(payload, ResponseSpec) else None
        if spec is not None:
            headers = payload.headers
            status = payload.status
            payload = payload.body
            if spec.retry_date_seconds is not None:
                headers = dict(headers)
                headers["Retry-After"] = email.utils.formatdate(time.time() + spec.retry_date_seconds, usegmt=True)
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
            if spec is not None and spec.chunk_delay:
                if spec.pacing_end is None:
                    time.sleep(spec.chunk_delay)
                else:
                    spec.pacing_end.wait(spec.chunk_delay)
            size = offsets[index % len(offsets)]
            try:
                self.wfile.write(payload[cursor : cursor + size])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break
            cursor += size
            index += 1
        if spec is not None:
            spec.body_finished_at = time.monotonic()
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def command(*args, expect=0, timeout=15):
    completed = subprocess.run(
        [str(RUI), *map(str, args)],
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_command(*args):
    return subprocess.Popen(
        [str(RUI), *map(str, args)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def finish_command(process):
    stdout, stderr = process.communicate(timeout=15)
    if process.returncode != 0:
        raise AssertionError(
            f"command returned {process.returncode}: stdout={stdout} stderr={stderr}"
        )
    return json.loads(stdout)


def host_arguments(store, endpoint, *extra, accelerated_retries=True, active_capacity=1):
    args = [
        str(RUI),
        "serve",
        "--store",
        str(store),
        "--active-capacity",
        str(active_capacity),
    ]
    if endpoint is not None:
        args += ["--provider-endpoint", endpoint]
        if accelerated_retries:
            args += ["--test-retry-waits-ms", "50,100,150"]
    args += extra
    return args


def start_host(store, endpoint, *extra, accelerated_retries=True, active_capacity=1, observations=None):
    args = host_arguments(
        store,
        endpoint,
        *extra,
        accelerated_retries=accelerated_retries,
        active_capacity=active_capacity,
    )
    process, _ = start_ready_process(
        args,
        observations=observations,
        required_fields=(
            {"execution": "enabled", "curl": "8.22.0"}
            if endpoint is not None
            else {"execution": "unavailable"}
        ),
    )
    return process


def stop_host(process):
    # Fixture disposal is an unclean SIGKILL, not evidence of graceful shutdown.
    stop_process(process)


def crash_host(process, state, label, diagnostics=None):
    assert process.poll() is None, process.returncode
    deadline = time.monotonic() + 10
    errors = []
    try:
        observations = getattr(process, "rui_observations", None)
        try:
            if observations is not None:
                # Frame receipt precedes native retirement. Keep this cut
                # unsealed and reserve reap credit from the same allowance.
                observations.wait_for_publication_retirement(deadline - 1)
        except BaseException as error:
            errors.append(error)
        try:
            process.kill()
            process.wait(timeout=max(0, deadline - time.monotonic()))
        except BaseException as error:
            errors.append(error)
        if errors:
            for error in errors[1:]:
                errors[0].add_note("Intentional crash cleanup failed: " + type(error).__name__)
            raise errors[0]
        stdout = process.stdout.read()
        if diagnostics is None:
            stderr = process.stderr.read()
        else:
            diagnostics.close()
            stderr = diagnostics.tail()
        (state / f"{label}.stdout").write_bytes(stdout)
        (state / f"{label}.stderr").write_bytes(stderr)
        return {
            "returncode": process.returncode,
            "stdout": stdout,
            "stderr": stderr,
        }
    finally:
        # Reap/observation validity and pipe closure retain an explicit owner,
        # including when bounded diagnostic collection or persistence fails.
        # A failed first kill/reap must not turn this cut into sealed disposal
        # or renew its original crash allowance.
        stop_process(process, timeout=max(0, deadline - time.monotonic()), seal_observations=False)


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
        "--provider",
        "codex",
        "--model",
        model,
        "--tools",
        "bash,edit",
        "--permission-mode",
        "ask",
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


def configure_lost_reply(
    state, store, key, session, model, *, workspace=ROOT, tools=None, permission=None
):
    arguments = [
        str(RUI),
        "configure",
        "--store",
        str(store),
        "--record",
        str(state / f"{key}.json"),
        "--key",
        key,
        "--session",
        session,
        "--workspace",
        str(workspace),
        "--provider",
        "codex",
        "--model",
        model,
    ]
    if tools is not None:
        arguments += ["--tools", tools]
    if permission is not None:
        arguments += ["--permission-mode", permission]
    arguments += ["--test-drop-reply", "after-commit"]
    completed = subprocess.run(
        arguments,
        text=True,
        capture_output=True,
        timeout=15,
    )
    assert completed.returncode != 0, completed


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
    return result


def message_lost_reply(state, store, key, session, text):
    text_path = state / f"{key}.txt"
    text_path.write_text(text)
    completed = subprocess.run(
        [
            str(RUI),
            "message",
            "--store",
            str(store),
            "--record",
            str(state / f"{key}.json"),
            "--key",
            key,
            "--session",
            session,
            "--text",
            str(text_path),
            "--test-drop-reply",
            "after-commit",
        ],
        text=True,
        capture_output=True,
        timeout=15,
    )
    assert completed.returncode != 0, completed


def retry_message(state, store, key):
    return command(
        "retry",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--kind",
        "message",
    )


def observe(store, key, *, deadline=None):
    if deadline is not None:
        deadline = min(deadline, time.monotonic() + 15)
    remaining = 15 if deadline is None else deadline - time.monotonic()
    assert remaining > 0, "result observation exhausted original deadline"
    result = command(
        "observe-command", "--store", store, "--key", key, timeout=remaining,
    )["observation"]
    assert deadline is None or time.monotonic() < deadline, "result observation exceeded original deadline"
    return result


def read_result(store, key, *, deadline=None):
    if deadline is not None:
        deadline = min(deadline, time.monotonic() + 15)
    remaining = 15 if deadline is None else deadline - time.monotonic()
    assert remaining > 0, "result read exhausted original deadline"
    completed = subprocess.run(
        [str(RUI), "read-result", "--store", str(store), "--key", key],
        capture_output=True,
        timeout=remaining,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"read-result failed for {key}: {completed.returncode}\n"
            f"stdout: {completed.stdout!r}\nstderr: {completed.stderr!r}"
        )
    assert deadline is None or time.monotonic() < deadline, "result read exceeded original deadline"
    return completed.stdout


def read_action(store, session, action, field):
    completed = subprocess.run(
        [str(RUI), f"read-action-{field}", "--store", str(store), "--session", session, "--action", action],
        capture_output=True,
        timeout=15,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"read-action-{field} failed for {action}: {completed.returncode}\n"
            f"stdout: {completed.stdout!r}\nstderr: {completed.stderr!r}"
        )
    return completed.stdout


def wait_for(predicate, description, timeout=8, interval=0.025, *, deadline=None):
    if deadline is None:
        deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        # An inspection can block past its caller's budget. A clean observation
        # after the deadline is not evidence of timely physical reclamation.
        if time.monotonic() >= deadline:
            break
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {description}")


def completed_observation(store, key, *, deadline=None):
    value = observe(store, key, deadline=deadline)
    return value if value.get("result", {}).get("status") == "completed" else None


def wait_for_result_release(store, key, session, deadline, *, inspect=None):
    """Read one terminal result and its release within the original budget."""
    observation = wait_for(
        lambda: (value if (value := observe(store, key, deadline=deadline)).get("result") else None),
        f"{key} terminal result", deadline=deadline,
    )
    answer = read_result(store, key, deadline=deadline) if observation["result"]["status"] == "completed" else None
    if inspect is None:
        def inspect(remaining):
            return command("inspect-session", "--store", store, "--session", session,
                           timeout=remaining)["execution"]
    execution = wait_for_execution_release(inspect, deadline)
    return observation, answer, execution


def wait_model_cleanup(diagnostics, store, session, observation, deadline):
    # A saved result is semantic authority, not physical release. Match the
    # admitted owner before checking its final accounting, with no fresh budget.
    diagnostics.wait_model_cleanup(observation["processing"], deadline)

    def inspect(remaining):
        diagnostics.claim_inspection(limit=49)
        return command(
            "inspect-session", "--store", store, "--session", session,
            timeout=remaining,
        )["execution"]

    return wait_for_execution_release(inspect, deadline)


def assert_model_cleanup_census(diagnostics, *observations):
    diagnostics.assert_model_cleanup_census(*(value["processing"] for value in observations))
