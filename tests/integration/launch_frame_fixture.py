"""Launch frame helpers shared by the SQLite and MySQL launch-frame fixtures."""
import json
import socket
import struct

import host_process


WIRE = host_process.WIRE_VERSION


def frame(value):
    body = json.dumps(value).encode()
    return struct.pack(">I", len(body)) + body


def host_info(path, store):
    return post(path, "host-info", {"version": WIRE, "kind": "host_info", "store": store})


def post(path, route, request, extra=b"", expected_status=200):
    body = json.dumps(request).encode()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        connection.sendall(b"POST /v1/" + route.encode() + b" HTTP/1.1\r\nContent-Type: application/json\r\n" + extra +
                           b"X-Rui-Wire-Version: " + WIRE.encode() + b"\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        reply = b""
        while chunk := connection.recv(65536):
            reply += chunk
    head, _, payload = reply.partition(b"\r\n\r\n")
    assert head.startswith(b"HTTP/1.1 " + str(expected_status).encode() + b" "), reply
    return json.loads(payload)


def output(process, timeout=20):
    """What the Host wrote, within `timeout`, after its stdin closes."""
    host_process.close_stdin(process)
    return process.communicate(timeout=timeout)


def wait_for_socket(path, process):
    def ready():
        assert process.poll() is None, "the Host exited before its socket appeared"
        return path.exists()
    host_process.wait_for(ready, "the socket in runtimeDir", timeout=20)


def refusal(process):
    out, err = output(process)
    assert process.returncode != 0, (out, err)
    lines = out.decode().splitlines()
    assert len(lines) == 1, (out, err)
    return json.loads(lines[0])["rui_start_error"]
