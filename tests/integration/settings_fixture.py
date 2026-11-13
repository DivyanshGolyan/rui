"""Settings document helpers shared by the SQLite and MySQL fixtures."""
import codecs
import json
import os_semantics
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
    with os_semantics.unix_stream() as connection:
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


def wait_for_host(path, store, process):
    """A launched Host is ready once it answers Host info, as managed launch
    observes it. Its socket file appears at bind, before the Host listens, so
    a connect in between is refused."""
    def ready():
        assert process.poll() is None, "the Host exited before it answered Host info"
        try:
            return host_info(path, str(store))
        except (FileNotFoundError, ConnectionRefusedError):
            return None
    host_process.wait_for(ready, "the Host in interface.dir to answer Host info", timeout=20)


def refusal(process, forbidden=()):
    out, err = output(process)
    assert process.returncode == 1, (out, err)
    assert err.strip(), (out, err)
    assert err.endswith(b"\n") and err.count(b"\n") == 1, (out, err)
    assert len(err.decode().splitlines()) == 1, (out, err)
    assert out.endswith(b"\n") and out.count(b"\n") == 1, (out, err)
    failure = json.loads(out[:-1])["rui_start_error"]
    prefix = b"rui: the Host did not start: "
    suffix = b" [" + failure["code"].encode() + b"]\n"
    assert err.startswith(prefix) and err.endswith(suffix), (out, err)
    escaped = err[len(prefix):-len(suffix)]
    decoded, consumed = codecs.escape_decode(escaped)
    assert consumed == len(escaped) and decoded == failure["message"].encode(), (out, err)
    for secret in forbidden:
        assert secret.encode() not in out + err, "a refusal exposed secret bytes"
    return failure
