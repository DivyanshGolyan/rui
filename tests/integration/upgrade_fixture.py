import hashlib
import http.server
import io
import tarfile
import threading

import os_semantics
from host_process import wait_for


class Gate:

    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()

    def hold(self):
        self.entered.set()
        wait_for(self.release.is_set, "fixture release gate", timeout=45)


class Releases:

    def __init__(self, binary, version):
        target = os_semantics.native_release_target()
        assert target is not None, "Upgrade supports darwin-arm64 and linux-x86_64"
        self.version = version
        self.name = f"rui-{version}-{target}.tar.gz"
        self.archive = self.make_archive(binary)
        self.digest = hashlib.sha256(self.archive).hexdigest()
        self.requests = []
        self.gates = {}
        self.status = {}
        self.errors = []
        self.latest_location = None
        self.sums_name = None
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(self.path)
                try:
                    if self.path in owner.gates:
                        owner.gates[self.path].hold()
                    status = owner.status.get(self.path, 200)
                    location = None
                    if self.path == "/releases/latest":
                        status = owner.status.get(self.path, 302)
                        location = owner.latest_location if owner.latest_location is not None else owner.origin + "/releases/redirect"
                        body = b""
                    elif self.path == "/releases/redirect":
                        status = owner.status.get(self.path, 302)
                        location = owner.origin + f"/releases/tag/v{owner.version}"
                        body = b""
                    elif self.path == f"/releases/tag/v{owner.version}":
                        body = b"fixture release page; HTML is not release metadata"
                    elif self.path == owner.sums_path:
                        body = f"{owner.digest}  {owner.sums_name or owner.name}\n".encode()
                    elif self.path == owner.archive_path:
                        body = owner.archive
                    else:
                        status, body = owner.status.get(self.path, 404), b"unexpected fixture endpoint"
                    self.send_response(status)
                    if location:
                        self.send_header("Location", location)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except BaseException as error:
                    owner.errors.append(error)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = False
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.archive_path = f"/releases/download/v{version}/{self.name}"
        self.sums_path = f"/releases/download/v{version}/SHA256SUMS"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def make_archive(self, binary, *, invalid=False):
        output = io.BytesIO()
        root = self.name.removesuffix(".tar.gz")
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            if invalid:
                data = b"not an executable\n"
                entry = tarfile.TarInfo(f"{root}/bin/rui")
                entry.mode, entry.size = 0o755, len(data)
                archive.addfile(entry, io.BytesIO(data))
            else:
                archive.add(binary, arcname=f"{root}/bin/rui", recursive=False)
            notices = b"Synthetic Upgrade fixture notices; native executable supplied by caller.\n"
            entry = tarfile.TarInfo(f"{root}/THIRD_PARTY_NOTICES.md")
            entry.mode, entry.size = 0o644, len(notices)
            archive.addfile(entry, io.BytesIO(notices))
        return output.getvalue()

    def gate_archive(self):
        gate = self.gates[self.archive_path] = Gate()
        return gate

    def close(self):
        for gate in self.gates.values():
            gate.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        assert not self.thread.is_alive(), "release server did not retire"
        assert not self.errors, self.errors
