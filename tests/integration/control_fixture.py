"""Control helpers that several fixtures share: the Host launch, Session commands
and observation, raw socket requests and the streaming model endpoint."""
import http.server
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time

import host_process
from host_process import is_peer_disconnect, start_ready_process, TestHTTPServer


RUI = pathlib.Path(sys.argv[1]).resolve()


ROOT = pathlib.Path.cwd()


class StreamingEndpoint(TestHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), StreamingHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.disconnects = 0
        self.release = threading.Event()

    def counts(self):
        with self.condition:
            return self.requests, self.disconnects


class StreamingHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            self.server.condition.notify_all()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        while not self.server.release.wait(0.025):
            try:
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
            except OSError as error:
                if not is_peer_disconnect(error):
                    raise
                with self.server.condition:
                    self.server.disconnects += 1
                    self.server.condition.notify_all()
                return

    def log_message(self, _format, *_args):
        pass


def encode_sse(payloads):
    return b"".join(
        b"event: response\ndata: "
        + json.dumps(payload, separators=(",", ":")).encode()
        + b"\n\n"
        for payload in payloads
    )


def successful_sse(index, answer=None):
    if answer is None:
        answer = f"answer-{index}"
    message_item = {
        "type": "message",
        "id": f"message-{index}",
        "status": "completed",
        "role": "assistant",
        "phase": "final_answer",
        "content": [
            {"type": "output_text", "text": answer, "annotations": []}
        ],
    }
    return encode_sse(
        [
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {"type": "message", "id": message_item["id"]},
            },
            {
                "type": "response.output_item.done",
                "output_index": 0,
                "item": message_item,
            },
            {
                "type": "response.completed",
                "response": {
                    "id": f"response-{index}",
                    "status": "completed",
                    "model": "gpt-6-sol",
                    "output": [message_item],
                    "usage": {
                        "input_tokens": 7,
                        "output_tokens": 11,
                        "total_tokens": 18,
                    },
                },
            },
        ]
    )


def command(*args, expect=0, timeout=15, input=None):
    completed = subprocess.run(
        [str(RUI), *map(str, args)],
        text=True,
        input=input,
        capture_output=True,
        timeout=timeout,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_host(store, endpoint=None, *extra, active_capacity=2, observations=None):
    args = [
        str(RUI),
        "host", "serve",
        "--store",
        str(store),
        "--active-capacity",
        str(active_capacity),
    ]
    required = {"execution": "unavailable"}
    if endpoint is not None:
        args += ["--provider-endpoint", endpoint]
        required = {"execution": "enabled", "nghttp2": "1.70.0"}
    args += extra
    if observations is not None and "--test-phase-trace" not in args:
        args.append("--test-phase-trace")
    return start_ready_process(args, required_fields=required,
                               observations=observations or ("control" if "--test-phase-trace" in extra else None))


def configure(state, store, key, session=None):
    args = [
        "session", "configure",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--workspace",
        ROOT,
        "--provider",
        "codex",
        "--model",
        "gpt-6-sol",
    ]
    if session is not None:
        args += ["--session", session]
    result = command(*args)
    assert result["answer"]["status"] == "accepted", result
    return result["answer"]["session"]


def message(state, store, key, session, text):
    result = command(
        "session", "send",
        "--store",
        store,
        "--to",
        session,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        input=text,
    )
    assert result["answer"]["status"] == "accepted", result


def stop_session(state, store, key, session):
    return command(
        "session", "stop",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
    )


def observe(store, key, *, deadline=None):
    remaining = 15 if deadline is None else min(15, deadline - time.monotonic())
    assert remaining > 0, "result observation exhausted original deadline"
    return command("request", "inspect", "--store", store, "--key", key,
                   timeout=remaining)["observation"]


def read_http_response(connection, timeout=3, *, deadline=None):
    connection.settimeout(timeout)

    def receive():
        if deadline is not None:
            remaining = min(timeout, deadline - time.monotonic())
            assert remaining > 0, "Host response exhausted original deadline"
            connection.settimeout(remaining)
        chunk = connection.recv(4096)
        assert deadline is None or time.monotonic() < deadline, "Host response exceeded original deadline"
        return chunk

    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = receive()
        if not chunk:
            break
        response.extend(chunk)
    head, _, body = bytes(response).partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    while len(body) < length:
        chunk = receive()
        if not chunk:
            break
        body += chunk
    return head, body


def open_partial(socket_path, route, *, complete_headers=True):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(3)
        connection.connect(socket_path)
        connection.sendall(f"POST {route} HTTP/1.1\r\n".encode())
        if complete_headers:
            connection.sendall(
                b"Content-Type: application/json\r\n"
                b"Content-Length: 1024\r\n"
                b"X-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n{"
            )
    except BaseException:
        connection.close()
        raise
    return connection


def environment_header(route):
    """A Message carries a client environment; these raw ones carry none."""
    return b"X-Rui-Environment-Bytes: 0\r\n" if route == "/v1/message" else b""


def raw_request(socket_path, route, body, declared_length=None):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(5)
        connection.connect(socket_path)
        length = len(body) if declared_length is None else declared_length
        connection.sendall(
            f"POST {route} HTTP/1.1\r\n".encode()
            + b"Content-Type: application/json\r\n"
            + f"Content-Length: {length}\r\n".encode()
            + environment_header(route)
            + b"X-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n\r\n"
            + body
        )
        return read_http_response(connection)
    finally:
        connection.close()


def inspect_execution(store, session, *, timeout=15):
    return command(
        "session", "inspect",
        "--store",
        store,
        "--session",
        session,
        timeout=timeout,
    )["execution"]


def assert_intake_progress(socket_path, store, peers=None):
    """Both Store observation and protected discovery progress beside borrowers."""
    for kind, route in (("observe_command", "/v1/observe-command"),
                        ("host_info", "/v1/host-info")):
        request = {"version": host_process.WIRE_VERSION, "kind": kind, "store": str(store)}
        if kind == "observe_command":
            request["key"] = "intake-progress-absent"
        def invoke():
            return raw_request(socket_path, route, json.dumps(request).encode())
        head, body = invoke() if peers is None else peers.call(
            "observe" if kind == "observe_command" else kind, invoke)
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        value = json.loads(body)
        if kind == "observe_command":
            assert value["observation"]["status"] == "absent", value
        else:
            assert value["store"] == str(store) and len(value["instance"]) == 32, value
