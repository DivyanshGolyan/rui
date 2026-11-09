"""Host status helpers that the Host status and stop fixtures and
host_process_test.py share."""
import hashlib
import os
import pathlib
import subprocess
import sys

from host_process import is_peer_disconnect


RUI, ACTOR = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])


def status(store):
    result = subprocess.run([ACTOR, store], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def socket_path(store):
    digest = hashlib.sha256(str(store.resolve()).encode()).hexdigest()[:32]
    return pathlib.Path(f"/tmp/rui-{os.geteuid()}/{digest}.sock")


def complete_response(stream):
    response = bytearray()
    while True:
        try:
            chunk = stream.recv(4096)
        except OSError as error:
            if not is_peer_disconnect(error):
                raise
            # Early route/kind rejection leaves hostile bytes unread. Reset
            # can terminate a complete reply, but never certify a prefix.
            break
        if not chunk:
            break
        response.extend(chunk)
        assert len(response) < 8192, response
    head, body = response.split(b"\r\n\r\n", 1)
    lengths = [line.split(b":", 1)[1].strip() for line in head.split(b"\r\n")[1:]
               if line.lower().startswith(b"content-length:")]
    assert len(lengths) == 1 and int(lengths[0]) == len(body), (head, body)
    return bytes(response)


def finish(stream, body):
    response = bytearray()
    with stream:
        try:
            stream.sendall(body)
            while chunk := stream.recv(4096):
                response.extend(chunk)
                assert len(response) < 8192
        except OSError as error:
            if not is_peer_disconnect(error):
                raise
            # A late reset must not erase a captured acceptance prefix.
    return bytes(response)
