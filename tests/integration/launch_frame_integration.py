#!/usr/bin/env python3
"""A Host started with a launch frame on stdin: readiness on the socket in
runtimeDir, refusals as one `rui_start_error` line, and a clean exit when
stdin closes (D5, D112, D118, D130, D136)."""

import http.server
import json
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

import host_process
import os_semantics


RUI = pathlib.Path(sys.argv[1]).resolve()
WIRE = host_process.WIRE_VERSION


def frame(value):
    body = json.dumps(value).encode()
    return struct.pack(">I", len(body)) + body


def launch(raw):
    process = subprocess.Popen([RUI, "host", "serve", "--launch-frame"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(raw)
    process.stdin.flush()
    return process


def host_info(path, store):
    return post(path, "host-info", {"version": WIRE, "kind": "host_info", "store": store})


def host_stop(path, store, instance):
    return post(path, "control/host-stop", {"version": WIRE, "kind": "host_stop", "store": store},
                b"X-Rui-Host-Instance: " + instance.encode() + b"\r\n")


def post(path, route, request, extra=b""):
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
    assert head.startswith(b"HTTP/1.1 200"), reply
    return json.loads(payload)


def output(process, timeout=20):
    """What the Host wrote, within `timeout`. communicate() flushes stdin, so a closed stdin is dropped first."""
    if process.stdin is not None:
        process.stdin.close()
        process.stdin = None
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


def mcp_server(names):
    """A loopback MCP server whose tools/list names `names`."""
    tools = [{"name": name, "inputSchema": {"type": "object"}} for name in names]

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            body = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"tools": tools}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def mcp_entry(name, server):
    return {"name": name, "url": f"http://127.0.0.1:{server.server_port}/mcp", "bearerToken": "t", "callTimeoutMs": 1000}


def main():
    root = host_process.canonical_fixture_root(tempfile.mkdtemp(prefix="rui-launch-"))
    store = root / "store"
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    good = {"v": 1, "store": str(store), "runtimeDir": str(runtime), "activeCapacity": 2,
            "provider": {"kind": "openai_key", "baseUrl": "https://api.openai.com/v1", "key": "sk-launch-test"}}

    host = launch(frame(good))
    sock = runtime / "rui.sock"
    wait_for_socket(sock, host)
    info = host_info(sock, str(store))
    assert info["active_capacity"] == "2", info
    assert info["capabilities"]["providers"]["openai"] == "key_file", info
    # The key never reaches argv or the environment.
    if os_semantics.PROC_FS:
        for name in ("cmdline", "environ"):
            assert b"sk-launch-test" not in pathlib.Path(f"/proc/{host.pid}/{name}").read_bytes(), name

    # A second Host on the same Store is refused while the first holds it.
    other = root / "other"
    other.mkdir(mode=0o700)
    second = launch(frame(dict(good, runtimeDir=str(other))))
    assert refusal(second)["code"] == "store_locked"

    # Another Store may not share the runtime directory: the first Host keeps
    # its socket.
    shared = launch(frame(dict(good, store=str(root / "store2"))))
    refused = refusal(shared)
    assert refused["code"] == "runtime_dir_unusable", refused
    assert info == host_info(sock, str(store))

    # A runtime directory others can write to is refused before any bind.
    open_dir = root / "open"
    open_dir.mkdir()
    open_dir.chmod(0o777)
    insecure = launch(frame(dict(good, store=str(root / "store3"), runtimeDir=str(open_dir))))
    refused = refusal(insecure)
    assert refused["code"] == "runtime_dir_unusable", refused
    assert not (open_dir / "rui.sock").exists()

    # A runtimeDir that is a file is a structured refusal too.
    not_a_dir = root / "file"
    not_a_dir.write_text("x")
    refused = refusal(launch(frame(dict(good, store=str(root / "store4"), runtimeDir=str(not_a_dir)))))
    assert refused["code"] == "runtime_dir_unusable", refused

    # Closing stdin stops the Host; its socket goes with it.
    started = time.monotonic()
    host.stdin.close()
    assert host.wait(timeout=30) == 0, output(host)
    elapsed = time.monotonic() - started
    assert elapsed < 10, elapsed
    assert not sock.exists()

    # host-stop before stdin closes stops a launched Host too.
    host = launch(frame(good))
    wait_for_socket(sock, host)
    host_stop(sock, str(store), host_info(sock, str(store))["instance"])
    assert host.wait(timeout=30) == 0, output(host)
    assert not sock.exists()

    # A Host launched paused reports it, and host_pause can lift it.
    host = launch(frame(dict(good, paused=True)))
    wait_for_socket(sock, host)
    info = host_info(sock, str(store))
    assert info["paused"] is True, info
    lifted = post(sock, "control/host-pause", {"version": WIRE, "kind": "host_pause", "store": str(store), "paused": False},
                  b"X-Rui-Host-Instance: " + info["instance"].encode() + b"\r\n")
    assert lifted["paused"] is False, lifted
    assert host_info(sock, str(store))["paused"] is False
    host.stdin.close()
    assert host.wait(timeout=30) == 0, output(host)

    for raw, message in [
        (frame(dict(good, v=2)), "v must be 1"),
        (frame(dict(good, runtimeDir="relative")), "runtimeDir must be an absolute path"),
        (frame(dict(good, provider=dict(good["provider"], baseUrl="http://plain.example"))), "provider.baseUrl"),
        (b"\x00\x00", "4-byte frame length"),
    ]:
        process = launch(raw)
        process.stdin.close()
        refused = refusal(process)
        assert refused["code"] == "launch_frame_invalid", refused
        assert message in refused["message"], refused

    # MCP servers: the Host lists their tools before it serves; a name a
    # server shares with a built-in refuses the start naming both; a server
    # that is down does not stop it.
    docs = mcp_server(["search"])
    clash = mcp_server(["bash"])
    mcp_root = root / "mcp"
    mcp_root.mkdir(mode=0o700)
    base = dict(good, store=str(root / "store5"), runtimeDir=str(mcp_root))
    host = launch(frame(dict(base, mcpServers=[mcp_entry("docs", docs)])))
    wait_for_socket(mcp_root / "rui.sock", host)
    host.stdin.close()
    assert host.wait(timeout=30) == 0, output(host)
    refused = refusal(launch(frame(dict(base, mcpServers=[mcp_entry("docs", docs), mcp_entry("clash", clash)]))))
    assert refused["code"] == "tool_name_collision", refused
    assert "bash" in refused["message"] and "clash" in refused["message"], refused
    docs.shutdown()
    docs.server_close()
    host = launch(frame(dict(base, mcpServers=[mcp_entry("docs", docs)])))
    wait_for_socket(mcp_root / "rui.sock", host)
    host.stdin.close()
    assert host.wait(timeout=30) == 0, output(host)
    print(f"launch frame: ready, store_locked, runtime_dir_unusable, stdin close stopped the Host in {elapsed:.2f} s, opened paused, four refusals, MCP tools listed, a collision refused, a server down tolerated")


if __name__ == "__main__":
    host_process.enter()
    main()
