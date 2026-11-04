#!/usr/bin/env python3
"""A Host started with a launch frame on stdin: readiness on the socket in
runtimeDir, refusals as one `rui_start_error` line, and a clean exit when
stdin closes (D5, D112, D118, D130, D136)."""

import json
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
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
    body = json.dumps({"version": WIRE, "kind": "host_info", "store": store}).encode()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        connection.sendall(b"POST /v1/host-info HTTP/1.1\r\nContent-Type: application/json\r\n"
                           b"X-Rui-Wire-Version: " + WIRE.encode() + b"\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        reply = b""
        while chunk := connection.recv(65536):
            reply += chunk
    head, _, payload = reply.partition(b"\r\n\r\n")
    assert head.startswith(b"HTTP/1.1 200"), reply
    return json.loads(payload)


def wait_for_socket(path, process):
    def ready():
        assert process.poll() is None, process.communicate()
        return path.exists()
    host_process.wait_for(ready, "the socket in runtimeDir", timeout=20)


def refusal(process):
    out, err = process.communicate(timeout=20)
    assert process.returncode != 0, (out, err)
    lines = out.decode().splitlines()
    assert len(lines) == 1, (out, err)
    return json.loads(lines[0])["rui_start_error"]


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

    # Closing stdin stops the Host; its socket goes with it.
    started = time.monotonic()
    host.stdin.close()
    assert host.wait(timeout=30) == 0, host.communicate()
    elapsed = time.monotonic() - started
    assert elapsed < 10, elapsed
    assert not sock.exists()

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
    print(f"launch frame: ready, store_locked, stdin close stopped the Host in {elapsed:.2f} s, four refusals")


if __name__ == "__main__":
    host_process.enter()
    main()
