"""The canonical failure reply proxy and invocation helpers that the canonical
failure, human CLI, Current, request-wait, session-list and terminal-restoration
fixtures share."""
import json
import os
import pathlib
import re
import os_semantics
import socketserver
import subprocess
import threading

import host_process
import model_fixture as fixture


ERROR = {"version": host_process.WIRE_VERSION, "type": "invocation_error", "code": "canonical_store_failure"}


ERROR_BYTES = json.dumps(ERROR, separators=(",", ":")).encode()


def invoke(home, *args, input=None):
    return subprocess.run([str(fixture.RUI), *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=20, input=input)


def announced(result):
    """Generated capture identity: the first stderr line, before transmission."""
    first = result.stderr.splitlines()[0] if result.stderr else ""
    match = re.fullmatch(r"request: (\S+) \(wait: rui request wait \1; if unconfirmed: rui request recover \1\)", first)
    assert match, result
    assert result.stderr.count("request: ") == 1, result
    return match[1]


class ReplyProxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Forward the real request, drain its reply, replace only the selected route."""
    def __init__(self, host, route, rewrite=None, *, before_forward=None):
        self.path = pathlib.Path(host.rui_ready_fields["socket"])
        # Exchanges connect to the backend name and the proxy binds its
        # staging name, so both are exactly as long as the Host's: wherever
        # the Host could bind (macOS allows 103 path bytes), they fit too.
        self.backend = self.path.with_name("=" + self.path.name[1:])
        self.route = route
        self.rewrite = rewrite
        self.before_forward = before_forward
        self.exchanges = []
        self.mutations = []
        # A running client may connect at any moment, so the public path
        # always names a listening socket: the Host's until the proxy is
        # renamed over it, and the Host's again once it is renamed back.
        staging = self.path.with_name("~" + self.path.name[1:])
        os.link(self.path, self.backend)
        bound = False
        try:
            super().__init__(str(staging), Exchange)
            bound = True
            os.chmod(staging, 0o600)
            os.rename(staging, self.path)
        except BaseException:
            # Before the rename the Host still owns the public path: remove
            # only what this proxy added, keeping the original error primary.
            for cleanup in ((self.server_close,) if bound else ()) + (
                    lambda: staging.unlink(missing_ok=True), self.backend.unlink):
                try:
                    cleanup()
                except OSError:
                    pass
            raise
        self.thread = threading.Thread(target=self.serve_forever)
        self.thread.start()

    def close(self, *, after_restore=None):
        # New connections reach the Host first; accepted ones still forward
        # through the backend name until their handlers join. A test may release
        # an already-drained reply only after the direct socket is restored.
        restored = self.path.with_suffix(".canonical-restore")
        os.link(self.backend, restored)
        os.rename(restored, self.path)
        try:
            if after_restore is not None:
                after_restore()
        finally:
            host_process.dispose_all(self.shutdown, self.server_close,
                                     lambda: self.thread.join(timeout=5), self.backend.unlink)
            assert not self.thread.is_alive(), "reply proxy did not join"


class Exchange(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        data = b""
        while b"\r\n\r\n" not in data:
            part = self.request.recv(4096)
            assert part, "truncated request head"
            data += part
        head, body = data.split(b"\r\n\r\n", 1)
        fields = dict(line.split(b": ", 1) for line in head.split(b"\r\n")[1:])
        length = int(fields[b"Content-Length"])
        while len(body) < length:
            part = self.request.recv(length - len(body))
            assert part, "truncated request body"
            body += part
        route = head.split(b" ")[1].decode()
        # A Message's client environment precedes its saved record bytes;
        # the record is what callers compare.
        record = body[int(fields.get(b"X-Rui-Environment-Bytes", b"0")):]
        if route in ("/v1/message", "/v1/control/permission-decision"):
            self.server.mutations.append((route, record))
        if route == self.server.route and self.server.before_forward is not None:
            if not self.server.before_forward(record):
                return  # Held full request was cancelled before Host admission.
        with os_semantics.unix_stream() as backend:
            backend.settimeout(15)
            backend.connect(str(self.server.backend))
            backend.sendall(head + b"\r\n\r\n" + body)
            response = b""
            while True:
                part = backend.recv(65536)
                if not part:
                    break
                response += part
        if route == self.server.route:
            self.server.exchanges.append((record, response))
            if self.server.rewrite is not None:
                response = self.server.rewrite(response)
            else:
                response = (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                    b"X-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\nConnection: close\r\nContent-Length: "
                    + str(len(ERROR_BYTES)).encode() + b"\r\n\r\n" + ERROR_BYTES)
        if response is not None:  # An explicitly held cancellation peer sends nothing.
            self.request.sendall(response)
