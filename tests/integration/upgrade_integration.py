#!/usr/bin/env python3
import contextlib
import hashlib
import http.server
import io
import itertools
import json
import os
import pathlib
import re
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
from urllib.parse import quote

import live_engines
import settings_fixture

import host_process
import os_semantics
from host_process import canonical_fixture_root, dispose_all, start_ready_process, stop_process, wait_for
from terminal_process import COLUMNS, ROWS, answers_to, terminal_process
from terminal_screen import ScreenCapture, shown


TERMINAL_COLUMNS = max(COLUMNS, 140)


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


class CurlAttempts:
    """Inject transport failures; real curl still owns every successful HTTP transfer."""

    def __init__(self, c, failures):
        actual = shutil.which("curl")
        assert actual, "Upgrade integration requires curl"
        self.root = c.root / "curl-fixture"
        self.root.mkdir()
        self.log = self.root / "attempts.jsonl"
        (self.root / "plan.json").write_text(json.dumps({
            "curl": actual, "origin": c.releases.origin, "failures": failures,
        }))
        wrapper = self.root / "curl"
        wrapper.write_text(f"#!{sys.executable}\n" + r'''
import json
import os
import pathlib
import signal
import sys
import urllib.parse

root = pathlib.Path(__file__).parent
plan = json.loads((root / "plan.json").read_text())
log = root / "attempts.jsonl"
args = sys.argv[1:]
url = args[-1]
assert url.startswith(plan["origin"] + "/"), ("non-fixture download", url)
path = urllib.parse.urlsplit(url).path
# Configuration and protocol confinement remain mandatory on every attempt.
assert args[0] == "--disable", args
assert args[args.index("--proto") + 1] == "=http", args
assert args[args.index("--proto-redir") + 1] == ("=http" if path == "/releases/latest" else "=https"), args
previous = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
number = sum(row["path"] == path for row in previous)
failures = plan["failures"].get(path, [])
code = failures[number] if number < len(failures) else 0
family = "ipv4" if "--ipv4" in args or "-4" in args else "normal"
with log.open("a") as output:
    output.write(json.dumps({"url": url, "path": path, "family": family, "code": code, "args": args}) + "\n")
if code:
    if "--output" in args:
        destination = args[args.index("--output") + 1]
        if destination != "/dev/null":
            pathlib.Path(destination).write_bytes(b"partial failed archive must not survive retry\n")
    else:
        sys.stdout.write("partial failed response must not survive retry\n")
    sys.stdout.flush()
    sys.stderr.write("curl fixture: discarded earlier diagnostic\n")
    sys.stderr.write(f"curl fixture final: {path} attempt {number + 1} exit {code}\n")
    sys.stderr.flush()
    if code == "signal":
        os.kill(os.getpid(), signal.SIGTERM)
    sys.exit(code)
os.execv(plan["curl"], [plan["curl"], *args])
''')
        wrapper.chmod(0o755)
        c.env["PATH"] = f"{self.root}:{c.env['PATH']}"

    def observed(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_attempts(self, expected):
        observed = [(row["path"], row["family"], row["code"]) for row in self.observed()]
        assert observed == expected, ("curl attempts", observed, expected)


class Case:
    def __init__(self, root, binary, releases, name):
        self.root = root / name
        self.root.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.store = self.root / "store"
        self.binary = binary
        self.releases = releases
        self.env = {**os.environ, "HOME": str(self.home),
                    "PATH": f"{self.home}/.local/bin:{os.environ['PATH']}",
                    "RUI_TEST_UPGRADE_RELEASES_URL": releases.origin + "/releases",
                    "RUI_UPGRADE_FIXTURE_PRIVATE": "isolated-private-launch-value"}
        self.link = self.home / ".local/bin/rui"
        self.hosts = []
        self.ready = None
        self.children = []
        self.original = None

    def run(self, *args, expect=0, timeout=25):
        result = subprocess.run([str(self.binary), *map(str, args)], env=self.env,
                                capture_output=True, text=True, timeout=timeout)
        assert result.returncode == expect, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout + result.stderr

    def json(self, *args, input=None):
        result = subprocess.run([str(self.binary), *map(str, args)], env=self.env,
                                capture_output=True, text=True, timeout=25, input=input)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)

    def upgrade(self, *args, expect=0):
        return self.run("upgrade", "--store", self.store, *args, expect=expect)

    def build(self, name, version=None, *, managed=True):
        build = (self.home / ".local/lib/rui" if managed else self.root) / name
        (build / "bin").mkdir(parents=True)
        executable = build / "bin/rui"
        if version is None:
            shutil.copy2(self.binary, executable)
        else:
            executable.write_text(f"#!/bin/sh\n[ \"$1\" = --version ] || exit 91\nprintf '%s\\n' 'rui {version} (synthetic metadata fixture)'\n")
            executable.chmod(0o755)
        (build / "THIRD_PARTY_NOTICES.md").write_text("Synthetic fixture build\n")
        return build

    def select(self, build):
        self.run("--publish-install", self.home, build, "released-install")
        assert self.link.resolve() == build / "bin/rui"
        self.original = self.link.resolve()

    def old_selection(self):
        self.select(self.build("synthetic-selected-old", "0.1.0"))

    def start_host(self, name="retained-real-host", *, managed=True, store_hex=False, extra=(), sources_only=False, source=False):
        build = self.build(name, managed=managed)
        if source:
            (build / "revision").write_text("synthetic-source-revision-marker\n")
        destination = ["--store-hex", os.fsencode(self.store).hex()] if store_hex else ["--store", self.store]
        provider = [] if any(str(value).startswith("providers.") or str(value).startswith("providers=") for value in extra) else ["--set", 'providers={"codex":{}}']
        defaults = [] if sources_only else ["--set", 'execution.activeCapacity=2', *provider]
        process, ready = start_ready_process(
            [build / "bin/rui", "host", "serve", *destination, *defaults, *extra], env=self.env, isolate_providers=not sources_only)
        self.hosts.append(process)
        self.ready = ready
        status = self.status()
        assert status["status"] == "ready", status
        assert peer_pid(ready["socket"]) == process.pid
        return process, status

    def status(self):
        return self.json("host", "status", "--store", self.store)

    def assert_no_host(self):
        assert self.status()["status"] == "unavailable"
        assert not self.store.exists(), "checking/installing created a Store"

    def assert_unchanged(self):
        assert self.link.resolve() == self.original
        assert not list((self.home / ".local/lib/rui").glob("install.*")), "incomplete staging leaked"

    def spawn_upgrade(self):
        child = subprocess.Popen([str(self.binary), "upgrade", "--store", str(self.store)],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def finish_upgrade(self, child, *, success=True):
        out, err = child.communicate(timeout=30)
        assert (child.returncode == 0) == success, (child.returncode, out, err)
        return out + err

    def close(self):
        def pause_current():
            if self.ready is not None:
                current = self.status()
                if current["status"] == "ready":
                    self.run("host", "pause", "--store", self.store, "--instance", current["instance"])
        dispose_all(pause_current,
                    *(lambda child=child: stop_process(child) for child in self.children),
                    *(lambda process=process: stop_process(process) for process in self.hosts))


@contextlib.contextmanager
def case(root, binary, releases, name):
    value = Case(root, binary, releases, name)
    try:
        yield value
    finally:
        for gate in releases.gates.values():
            gate.release.set()
        def reset_publication():
            releases.gates.clear()
            releases.status.clear()
            releases.latest_location = None
            releases.sums_name = None
        dispose_all(value.close, reset_publication)


def peer_pid(path):
    with os_semantics.unix_stream() as connection:
        connection.connect(path)
        return os_semantics.socket_peer_pid(connection)


def proof_ready(c, previous, old_host):
    status = c.status()
    assert status["status"] == "ready", status
    assert status["instance"] != previous["instance"], "old Host was not replaced"
    assert status["store"] == previous["store"]
    assert status["active_capacity"] == previous["active_capacity"]
    pid = peer_pid(c.ready["socket"])
    assert pid != old_host.pid
    assert os_semantics.process_executable(pid) == c.link.resolve(), "ready process is not selected pinned build"
    environment = os_semantics.process_environment(pid, env=c.env)
    assert "RUI_UPGRADE_FIXTURE_PRIVATE=isolated-private-launch-value" in environment, "private launch environment lost"
    wait_for(lambda: old_host.poll() is not None, "old exact Host process retirement")
    return status


def discovery_cases(root, binary, releases):
    with case(root, binary, releases, "check-no-host") as c:
        c.old_selection()
        facts = c.json("--installation-facts")
        assert set(facts) == {"schema_version", "minimum_schema_version"}, facts
        assert 0 < facts["minimum_schema_version"] <= facts["schema_version"]
        c.assert_no_host()
        start = len(releases.requests)
        output = c.upgrade("--check")
        assert f"Latest published stable: {releases.version}" in output, output
        assert "Selected managed release: 0.1.0" in output, output
        assert "No running Hosts discovered now" in output
        assert releases.requests[start:] == ["/releases/latest", "/releases/redirect", f"/releases/tag/v{releases.version}", releases.sums_path]
        c.assert_unchanged()
        c.assert_no_host()
        for args in (("--bogus",), ("unexpected-message",), ("--check", "--check")):
            failed = subprocess.run([str(binary), "upgrade", *args], env=c.env,
                                    capture_output=True, text=True, timeout=10)
            assert failed.returncode != 0, (args, failed)
            c.assert_no_host()

    with case(root, binary, releases, "check-ignores-curlrc") as c:
        c.old_selection()
        unexpected = c.root / "unexpected-cookie-write"
        (c.home / ".curlrc").write_text(f'cookie-jar = "{unexpected}"\n')
        output = c.upgrade("--check")
        assert f"Latest published stable: {releases.version}" in output, output
        assert not unexpected.exists(), "read-only Upgrade check loaded .curlrc and wrote a cookie jar"
        c.assert_unchanged()
        c.assert_no_host()

    with case(root, binary, releases, "unmanaged-destination") as c:
        custom = c.build("custom", managed=False) / "bin/rui"
        c.link.parent.mkdir(parents=True)
        c.link.symlink_to(custom)
        output = c.upgrade("--check")
        assert "Upgrade cannot replace this destination" in output, output
        c.finish_upgrade(c.spawn_upgrade(), success=False)
        assert c.link.resolve() == custom
        c.assert_no_host()

    with case(root, binary, releases, "selected-tagged-source-ineligible") as c:
        build = c.build("tagged-source")
        (build / "revision").write_text("synthetic-source-revision-marker\n")
        c.run("--publish-install", c.home, build, "intentional-source")
        c.original = c.link.resolve()
        output = c.upgrade("--check")
        assert "Upgrade cannot replace this destination" in output, output
        c.finish_upgrade(c.spawn_upgrade(), success=False)
        c.assert_unchanged()
        c.assert_no_host()
        released = c.build("intentional-release-conversion")
        c.run("--publish-install", c.home, released, "released-install")
        assert c.link.resolve() == released / "bin/rui"
        c.assert_no_host()

    variants = ("malformed-version", "missing-redirect", "missing-archive-checksum", "unpinned-final-origin")
    for name in variants:
        with case(root, binary, releases, name) as c:
            c.old_selection()
            if name == "malformed-version":
                releases.latest_location = releases.origin + "/releases/tag/v0.056.4"
                releases.status["/releases/tag/v0.056.4"] = 200
            elif name == "missing-redirect":
                releases.status["/releases/latest"] = 200
            elif name == "missing-archive-checksum":
                releases.sums_name = "another-archive.tar.gz"
            else:
                releases.latest_location = releases.origin + "/not-the-repository/releases/tag/v0.56.4"
                releases.status["/not-the-repository/releases/tag/v0.56.4"] = 200
            result = c.upgrade("--check", expect=6)
            assert "upgrade_release_invalid" in result, (name, result)
            c.assert_unchanged()
            c.assert_no_host()

    for path, checking in (("/releases/latest", True), (releases.sums_path, True), (releases.archive_path, False)):
        with case(root, binary, releases, "download-403-" + ("latest" if path.endswith("latest") else "sums" if checking else "archive")) as c:
            c.old_selection()
            releases.status[path] = 403
            output = c.upgrade(*(["--check"] if checking else []), expect=6)
            assert "upgrade_download_failed" in output, output
            assert "curl: (22)" in output and "403" in output, output
            assert "upgrade_preparation_failed" not in output, output
            c.assert_unchanged()
            c.assert_no_host()

    with case(root, binary, releases, "offline-discovery") as c:
        c.old_selection()
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            c.env["RUI_TEST_UPGRADE_RELEASES_URL"] = f"http://127.0.0.1:{reserved.getsockname()[1]}/releases"
            child = c.spawn_upgrade()
            output = c.finish_upgrade(child, success=False)
            assert "upgrade_download_failed" in output and "curl: (" in output, output
        c.assert_unchanged()
        c.assert_no_host()


def download_cases(root, binary, releases):
    latest, sums, archive = "/releases/latest", releases.sums_path, releases.archive_path
    paths = (latest, sums, archive)
    for failed_path in paths:
        stage = paths.index(failed_path)
        for code in (6, 28):
            with case(root, binary, releases, f"download-recover-{stage}-{code}") as c:
                c.old_selection()
                curl = CurlAttempts(c, {failed_path: [code]})
                # A failed archive attempt writes junk to the real output file.
                # Installation and its checksum prove the retry replaced it.
                output = c.upgrade()
                assert "Installed Rui" in output, output
                selected = c.link.resolve()
                assert selected != c.original and c.original.exists()
                assert subprocess.check_output([str(c.link), "--version"], env=c.env,
                                               text=True, timeout=5).startswith("rui " + releases.version)
                expected = [(path, "normal", 0) for path in paths[:stage]]
                expected += [(failed_path, "normal", code), (failed_path, "ipv4", 0)]
                expected += [(path, "ipv4", 0) for path in paths[stage + 1:]]
                curl.assert_attempts(expected)
                c.assert_no_host()
                # A separate invocation starts with ordinary address selection.
                output = c.upgrade("--check")
                assert f"Latest published stable: {releases.version}" in output, output
                curl.assert_attempts(expected + [(latest, "normal", 0), (sums, "normal", 0)])
                assert c.link.resolve() == selected
                c.assert_no_host()

    for stage, failed_path in enumerate(paths):
        for first, final in ((6, 28), (28, 6)):
            with case(root, binary, releases, f"download-both-fail-{stage}-{first}") as c:
                c.old_selection()
                curl = CurlAttempts(c, {failed_path: [first, final]})
                output = c.upgrade(expect=6)
                assert "upgrade_download_failed" in output, output
                assert f"curl fixture final: {failed_path} attempt 2 exit {final}" in output, output
                assert f"curl fixture final: {failed_path} attempt 1" not in output, output
                assert "discarded earlier diagnostic" not in output, output
                curl.assert_attempts([(path, "normal", 0) for path in paths[:stage]] +
                                     [(failed_path, "normal", first), (failed_path, "ipv4", final)])
                c.assert_unchanged()
                c.assert_no_host()

        for code in (22, 60, 7, 23, "signal"):
            with case(root, binary, releases, f"download-no-retry-{stage}-{code}") as c:
                c.old_selection()
                curl = CurlAttempts(c, {failed_path: [code]})
                output = c.finish_upgrade(c.spawn_upgrade(), success=False)
                assert "upgrade_download_failed" in output, output
                curl.assert_attempts([(path, "normal", 0) for path in paths[:stage]] +
                                     [(failed_path, "normal", code)])
                c.assert_unchanged()
                c.assert_no_host()

    for stage, failed_path in enumerate((sums, archive), 1):
        with case(root, binary, releases, f"download-sticky-no-extra-retry-{stage}") as c:
            c.old_selection()
            curl = CurlAttempts(c, {latest: [6], failed_path: [6]})
            output = c.upgrade(expect=6)
            assert "upgrade_download_failed" in output, output
            curl.assert_attempts([(latest, "normal", 6), (latest, "ipv4", 0)] +
                                 [(path, "ipv4", 0) for path in paths[1:stage]] +
                                 [(failed_path, "ipv4", 6)])
            c.assert_unchanged()
            c.assert_no_host()


def install_cases(root, binary, releases):
    with case(root, binary, releases, "install-no-host") as c:
        c.old_selection()
        output = c.upgrade()
        assert "Installed Rui" in output and "No running Hosts." in output, output
        assert c.link.resolve() != c.original
        assert c.original.exists(), "retained old complete build removed"
        assert c.run("--version").startswith("rui " + releases.version)
        assert subprocess.check_output([str(c.link), "--version"], env=c.env, text=True).startswith("rui " + releases.version)
        c.assert_no_host()
        selected = c.link.resolve()
        start = len(releases.requests)
        output = c.upgrade()
        assert "Installation unchanged" in output, output
        assert c.link.resolve() == selected
        assert releases.archive_path not in releases.requests[start:], "equal release re-downloaded"
        c.assert_no_host()

    with case(root, binary, releases, "release-promotion-pinned") as c:
        c.old_selection()
        gate = releases.gate_archive()
        start = len(releases.requests)
        child = c.spawn_upgrade()
        wait_for(gate.entered.is_set, "pinned archive after release resolution")
        releases.latest_location = releases.origin + "/releases/tag/v0.999.0"
        gate.release.set()
        output = c.finish_upgrade(child)
        assert "Installed Rui" in output, output
        assert releases.requests[start:] == ["/releases/latest", "/releases/redirect", f"/releases/tag/v{releases.version}", releases.sums_path, releases.archive_path]
        assert subprocess.check_output([str(c.link), "--version"], env=c.env, text=True).startswith("rui " + releases.version)
        c.assert_no_host()

    with case(root, binary, releases, "newer-selected-no-downgrade") as c:
        c.select(c.build("synthetic-future-selected", "0.999.0"))
        output = c.upgrade()
        assert "Installation unchanged" in output and "No running Hosts." in output, output
        c.assert_unchanged()
        c.assert_no_host()

    for name in ("download-failure", "checksum-failure", "bad-executable"):
        with case(root, binary, releases, name) as c:
            c.old_selection()
            host, previous = c.start_host()
            original_archive, original_digest = releases.archive, releases.digest
            try:
                if name == "download-failure":
                    releases.status[releases.archive_path] = 503
                elif name == "checksum-failure":
                    releases.digest = "0" * 64
                else:
                    releases.archive = releases.make_archive(binary, invalid=True)
                    releases.digest = hashlib.sha256(releases.archive).hexdigest()
                child = c.spawn_upgrade()
                output = c.finish_upgrade(child, success=False)
                assert "Installed Rui" not in output, output
                c.assert_unchanged()
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
            finally:
                releases.archive, releases.digest = original_archive, original_digest

    with case(root, binary, releases, "destination-revalidated") as c:
        c.old_selection()
        host, previous = c.start_host()
        gate = releases.gate_archive()
        child = c.spawn_upgrade()
        wait_for(gate.entered.is_set, "archive preparation before destination replacement")
        custom = c.build("application-owned", managed=False) / "bin/rui"
        c.link.unlink()
        c.link.symlink_to(custom)
        gate.release.set()
        c.finish_upgrade(child, success=False)
        assert c.link.resolve() == custom, "commit overwrote newly ineligible destination"
        assert host.poll() is None and c.status()["instance"] == previous["instance"]


def lifecycle_cases(root, binary, releases):
    with case(root, binary, releases, "managed-host-restart") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        other = Case(root, binary, releases, "unrelated-store")
        try:
            other_host, other_previous = other.start_host()
            gate = releases.gate_archive()
            child = c.spawn_upgrade()
            wait_for(gate.entered.is_set, "download while old Host still serves")
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            assert c.link.resolve() == c.original
            gate.release.set()
            output = c.finish_upgrade(child)
            assert "Installed Rui" in output and "restarted on " in output, output
            proof_ready(c, previous, old_host)
            assert other_host.poll() is None and other.status()["instance"] == other_previous["instance"]
        finally:
            other.close()

    with case(root, binary, releases, "store-hex-host-restart") as c:
        c.old_selection()
        old_host, previous = c.start_host(store_hex=True)
        output = c.upgrade()
        assert "Installed Rui" in output and "restarted on " in output, output
        proof_ready(c, previous, old_host)

    with case(root, binary, releases, "relative-launch-path-not-restarted") as c:
        c.old_selection()
        relative_bash = os.path.relpath("/bin/bash", pathlib.Path.cwd())
        old_host, previous = c.start_host(extra=("--set", "tools.bash.path=" + str(relative_bash)))
        output = c.finish_upgrade(c.spawn_upgrade(), success=False)
        assert "Installed Rui" in output and "refused at checking" in output and '"code":"settings_invalid"' in output, output
        assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
        assert os_semantics.process_executable(old_host.pid) != c.link.resolve()

    with case(root, binary, releases, "same-release-older-retained-host") as c:
        c.select(c.build("selected-real-current"))
        old_host, previous = c.start_host()
        start = len(releases.requests)
        output = c.upgrade()
        assert "Installation unchanged" in output and "restarted on " in output, output
        assert releases.archive_path not in releases.requests[start:]
        proof_ready(c, previous, old_host)
        ready = c.status()
        output = c.upgrade()
        assert "already on " in output, output
        assert c.status()["instance"] == ready["instance"]

    with case(root, binary, releases, "retained-tagged-source-host") as c:
        c.old_selection()
        host, previous = c.start_host(source=True)
        output = c.finish_upgrade(c.spawn_upgrade())
        assert "Installed Rui" in output and "restarted on " in output, output
        proof_ready(c, previous, host)

    with case(root, binary, releases, "upgrade-all-first") as first, \
            case(root, binary, releases, "upgrade-all-second") as second, \
            case(root, binary, releases, "upgrade-all-unsupported") as unsupported:
        second.home, second.env, second.link = first.home, first.env, first.link
        unsupported.home, unsupported.env, unsupported.link = first.home, first.env, first.link
        first.old_selection()
        old_first, previous_first = first.start_host("all-first")
        old_second, previous_second = second.start_host("all-second", store_hex=True)
        foreign, previous_foreign = unsupported.start_host("all-foreign", managed=False)
        warning = first.upgrade("--check")
        assert "Discovered 3 Hosts" in warning, warning
        assert "every running Host" in warning and "ALL Sessions" in warning, warning
        for previous in (previous_first, previous_second, previous_foreign):
            assert previous["store"] in warning, warning
        assert "left running: application-owned Host" in warning, warning
        output = first.upgrade()
        for previous in (previous_first, previous_second):
            assert f"{previous['store']}: restarted on {releases.version}" in output, output
        assert f"{previous_foreign['store']}: left running: application-owned Host" in output, output
        assert "3 Hosts: 2 restarted, 0 already current, 1 left unchanged, 0 failed." in output, output
        proof_ready(first, previous_first, old_first)
        proof_ready(second, previous_second, old_second)
        assert foreign.poll() is None and unsupported.status()["instance"] == previous_foreign["instance"]

    with case(root, binary, releases, "upgrade-all-discovery-failure") as c:
        c.old_selection()
        old, previous = c.start_host()
        unreadable = pathlib.Path(c.ready["socket"]).parent / "upgrade-unreadable.sock"
        try:
            with os_semantics.unix_stream() as listener:
                listener.bind(str(unreadable))
                listener.listen(1)
                output = c.upgrade(expect=6)
                assert "Installed Rui" in output and "[host_restart_failed]" in output, output
                assert str(unreadable) in output and "failed at discovery" in output, output
                assert "2 Hosts: 1 restarted, 0 already current, 0 left unchanged, 1 failed." in output, output
                assert c.link.resolve() != c.original
                proof_ready(c, previous, old)
        finally:
            unreadable.unlink(missing_ok=True)

    with case(root, binary, releases, "upgrade-all-late-host") as c:
        c.old_selection()
        gate = releases.gate_archive()
        child = c.spawn_upgrade()
        wait_for(gate.entered.is_set, "initial empty census before late Host")
        late, previous = c.start_host("late-after-check")
        gate.release.set()
        output = c.finish_upgrade(child)
        assert "No running Hosts discovered now" in output, output
        assert f"{previous['store']}: restarted on {releases.version}" in output, output
        proof_ready(c, previous, late)

    with case(root, binary, releases, "application-owned-host") as c:
        c.old_selection()
        host, previous = c.start_host(managed=False)
        output = c.finish_upgrade(c.spawn_upgrade())
        assert "Installed Rui" in output and "left running: application-owned Host" in output, output
        assert host.poll() is None and c.status()["instance"] == previous["instance"]
        assert os_semantics.process_executable(host.pid) != c.link.resolve()

    with case(root, binary, releases, "replacement-race") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        gate = releases.gate_archive()
        child = c.spawn_upgrade()
        wait_for(gate.entered.is_set, "captured old Host before replacement")
        c.run("host", "pause", "--store", c.store, "--instance", previous["instance"])
        wait_for(lambda: old_host.poll() is not None, "original Host retirement before replacement")
        replacement, current = c.start_host("replacement-real-host")
        assert current["instance"] != previous["instance"]
        gate.release.set()
        output = c.finish_upgrade(child)
        assert "Installed Rui" in output and "restarted on " in output, output
        proof_ready(c, current, replacement)


    with case(root, binary, releases, "activation-target-disappeared") as c:
        c.old_selection()
        host, previous = c.start_host()
        gate = c.root / "after-publication.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(gate)
        child = c.spawn_upgrade()
        wait_for(lambda: c.link.resolve() != c.original, "native publication receipt before activation")
        installed = c.link.resolve()
        assert host.poll() is None and c.status()["instance"] == previous["instance"]
        installed.unlink()
        gate.unlink()
        output = c.finish_upgrade(child, success=False)
        assert "Installed Rui" in output and "Host restart could not finish" in output, output
        assert "Installation was not rolled back" in output and "failed before publication" not in output, output
        assert c.link.is_symlink() and os.readlink(c.link) == str(installed)
        assert host.poll() is None and c.status()["instance"] == previous["instance"]


class TerminalScreen:

    def __init__(self, master, process):
        self.master, self.process = master, process
        self.columns = TERMINAL_COLUMNS
        self.capture = ScreenCapture(self.columns, ROWS, reply=answers_to(master))
        self.tail = bytearray()
        self.entries = self.restorations = 0
        self.transition_tail = b""
        os.set_blocking(master, False)

    def read_output(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            data = b""
        if data:
            transitions = self.transition_tail + data
            self.entries += transitions.count(b"\x1b[?1049h")
            self.restorations += transitions.count(b"\x1b[?1049l")
            self.transition_tail = transitions[-7:]
            self.capture.feed(data)
            self.tail.extend(data)
            del self.tail[:-16384]

    def observe(self):
        self.read_output()
        if self.process.poll() is not None:
            self.read_output()
            raise AssertionError(self.process.returncode, self.capture.completed, bytes(self.tail[-4096:]).decode(errors="replace"))
        return self.capture.completed

    def contains(self, marker):
        return wait_for(self.observe, f"terminal screen: {marker}", timeout=15,
                        ready=lambda screen: shown(marker, screen))

    def until(self, predicate, description):
        return wait_for(self.observe, description, timeout=15, ready=lambda _: predicate())

    def draft(self, text, caret):
        return self.until(lambda: self.capture.draft(text, caret),
                          f"terminal draft and caret: {text!r}, {caret}")

    def send(self, text):
        os.write(self.master, text.encode())

    def launch_overview(self):
        frame = wait_for(self.observe, "wide launch chat beside the overview", timeout=15,
                         ready=lambda screen: "+ New Session" in screen and "│" in screen
                         and "Type a task" in screen and self.capture.draft("", 2))
        assert "Settings" in frame, frame
        self.send("\x1b")
        return self.overview()

    def overview(self, *, ready=True):
        frame = wait_for(self.observe, "terminal overview list and footer", timeout=15,
                         ready=lambda screen: all(shown(marker, screen) for marker in
                                                  ("+ New Session", "Settings"))
                         and "Notifications" not in screen
                         and "Type a task" not in screen
                         and not re.search(r"(?m)(?:^|│)\s*[›>](?: |$)", screen))
        assert "Type a task" not in frame, ("overview has an editor", frame)
        assert not re.search(r"(?m)(?:^|│)\s*[›>](?: |$)", frame), ("overview has a composer", frame)
        return frame

    def empty_session(self, case, session):
        report = case.json("session", "inspect", "--store", case.store, "--session", session)
        facts = report["session"]
        assert facts["reference"] == session, report
        assert report["selected_message"] is None and report["recent_messages"] == [], report
        listing = case.json("session", "list", "--store", case.store, "--all")
        assert {row["reference"] for row in listing["sessions"]} == {session}, listing
        return facts

    def empty_overview(self, case, session, *, ready=False):
        frame = self.overview(ready=ready)
        assert not shown(session, frame), ("empty Session leaked into overview", frame)
        assert "alt+i info" not in frame, ("overview reopened as a conversation", frame)
        self.empty_session(case, session)
        return frame

    def empty_chat(self, case, session, *, expected_notice=None):
        facts = self.empty_session(case, session)
        footer = "alt+i info" if expected_notice is None else expected_notice
        assert footer, "empty chat requires an info action or an exact retained notice"
        frame = wait_for(self.observe, "empty chat model facts and expected footer", timeout=15,
                         ready=lambda screen: shown(f"│ {facts['model']} · ", screen)
                         and shown(footer, screen))
        return frame

    def leave_empty_chat(self, case, session):
        self.send("\x1b")
        self.until(lambda: "Copy last answer" not in self.capture.completed,
                   "chat info closed before clearing the proven unsent draft")
        self.send("\x05\x15")
        self.draft("", 2)
        self.send("\x1b")
        return self.empty_overview(case, session)

    def ignored_overview_input(self, text, *markers):
        self.overview(ready=False)
        self.send(text + "\x1b[F\r")
        self.contains("Notifications")
        self.close_settings()
        frame = self.overview(ready=False)
        for marker in markers:
            assert marker not in frame, ("overview retained ignored input", marker, frame)
        assert "Unknown command" not in frame, ("overview interpreted a slash command", frame)

    def start_upgrade(self):
        frame = self.contains("Settings")
        for row, line in enumerate(frame.splitlines()):
            if "Settings" in line[:40]:
                column = line.index("Settings")
                self.send(f"\x1b[<0;{column + 1};{row + 1}M\x1b[<0;{column + 1};{row + 1}m")
                break
        else:
            raise AssertionError(frame)
        self.contains("Notifications")
        frame = self.contains("Version")
        for row, line in enumerate(frame.splitlines()):
            if "Version" in line[40:]:
                column = line.index("Version", 40)
                self.send(f"\x1b[<0;{column + 1};{row + 1}M\x1b[<0;{column + 1};{row + 1}m")
                break
        else:
            raise AssertionError(frame)

    def close_settings(self):
        self.send("\x1b")
        self.until(lambda: "Notifications" not in self.capture.completed,
                   "Settings closed without requiring an overview editor")

    def save(self, destination, name):
        if destination is not None:
            (destination / f"{name}.txt").write_text(self.capture.completed + "\n")


def refused_source_cases(root, binary, releases):
    for source in ("saved-relative", "file-relative", "relative-file-name", "invalid-document", "stdin-file", "stdin-lifetime"):
        with contextlib.ExitStack() as interfaces, case(root, binary, releases, f"refused-source-{source}") as c:
            c.root.chmod(0o700)
            c.store.mkdir(mode=0o700)
            runtime = interfaces.enter_context(host_process.short_interface_directory())
            document = {"interface": {"dir": str(runtime)}, "providers": {}}
            saved = c.store / "host.json"
            saved.write_text(json.dumps(document))
            saved.chmod(0o600)
            extra = ()
            if source in ("saved-relative", "file-relative", "relative-file-name", "invalid-document"):
                path = saved if source == "saved-relative" else c.root / "settings.json"
                relative = os.path.relpath("/bin/bash", pathlib.Path.cwd())
                settings = dict(document)
                if source not in ("invalid-document", "relative-file-name"):
                    settings["tools"] = {"bash": {"path": relative}}
                path.write_text(json.dumps(settings))
                path.chmod(0o600)
                if path != saved:
                    extra = ("--settings", os.path.relpath(path, pathlib.Path.cwd()) if source == "relative-file-name" else path)
                old, previous = c.start_host(extra=extra)
                if source == "invalid-document":
                    path.write_text('{"unknownFutureGroup":{}}')
            else:
                build = c.build("retained-stdin-source")
                extra = ("--settings", "-") if source == "stdin-file" else ("--set", "interface.lifetime=stdin", "--set", "providers={}")
                old = subprocess.Popen([str(build / "bin/rui"), "host", "serve", "--store", str(c.store), *extra],
                                       env=c.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                c.hosts.append(old)
                if source == "stdin-file":
                    old.stdin.write(settings_fixture.frame(document))
                    old.stdin.flush()
                settings_fixture.wait_for_host(runtime / "rui.sock", c.store, old)
                # Framed foreground serve owns a text startup line, not a
                # public-status JSON envelope. Control already proved ready.
                c.ready = {"socket": str(runtime / "rui.sock")}
                previous = c.status()
            c.select(c.build("selected-target"))
            c.binary = c.link
            output = c.run("host", "restart", "--all", expect=6, timeout=60)
            assert "refused at checking" in output and '"code":"settings_invalid"' in output, (source, output)
            assert old.poll() is None and c.status()["instance"] == previous["instance"], (source, output)
    print("upgrade native: stdin, relative layers and invalid document refused before stop", flush=True)


def mysql_restart_cases(root, binary, releases):
    socket_path = os.environ.get(live_engines.MYSQL_SOCKET)
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    if not socket_path or not password:
        assert "mysql" not in os.environ.get(live_engines.REQUIRE, "").split(","), "required MySQL restart fixture has no server"
        print("MySQL upgrade restart: skipped (no RUI_TEST_MYSQL_* server)", flush=True)
        return
    admin = pathlib.Path(os.environ["RUI_TEST_MYSQL_ADMIN"]).resolve()

    def sql(text):
        return subprocess.run([admin], input=text, text=True, capture_output=True, check=True, timeout=40).stdout.strip()

    for placement in ("default", "external", "contended"):
        database = "rui_upgrade_" + secrets.token_hex(6)
        runtime = None
        waiter = None
        try:
            sql(f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin")
            ddl = subprocess.check_output([binary, "store", "schema", "--engine", "mysql"], text=True, timeout=20)
            sql(f"USE {database};" + ddl)
            with contextlib.ExitStack() as interfaces, case(root, binary, releases, "mysql-" + placement) as c, case(root, binary, releases, "mysql-later-" + placement) as later:
                c.store.mkdir(mode=0o700)
                c.env["PR6_PRIVATE_DATABASE_URL"] = f"mysql://root:{quote(password, safe='')}@{quote(socket_path, safe='')}/{database}"
                document = {"store": {"mysql": {"url": {"env": "PR6_PRIVATE_DATABASE_URL"}}}, "providers": {}}
                if placement != "default":
                    runtime = interfaces.enter_context(host_process.short_interface_directory())
                    document["interface"] = {"dir": str(runtime)}
                saved = c.store / "host.json"
                saved.write_text(json.dumps(document))
                saved.chmod(0o600)
                old, previous = c.start_host(sources_only=True)
                runtime = pathlib.Path(c.ready["socket"]).parent
                # Only the captured Host has this credential variable. Both
                # target check and start must use its environment, not caller's.
                c.env = dict(c.env)
                del c.env["PR6_PRIVATE_DATABASE_URL"]
                if placement == "contended":
                    later.home, later.env, later.link = c.home, c.env, c.link
                    later.store.mkdir(mode=0o700)
                    later_runtime = interfaces.enter_context(host_process.short_interface_directory())
                    later_saved = later.store / "host.json"
                    later_saved.write_text(json.dumps({"interface": {"dir": str(later_runtime)}, "providers": {}}))
                    later_saved.chmod(0o600)
                    later_old, later_previous = later.start_host(sources_only=True)
                    waiter = subprocess.Popen([admin], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    waiter.stdin.write(f"SELECT GET_LOCK('{database}',30); SELECT SLEEP(15)")
                    host_process.close_stdin(waiter)
                    # Queue before old stop. MySQL grants the waiting session
                    # the lock when old retires; the new Host must NOT bypass it.
                    wait_for(lambda: sql(f"SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE STATE='User lock' AND INFO LIKE '%{database}%' AND ID<>CONNECTION_ID()") != "0", "queued competing Store lock", timeout=10)
                c.select(c.build("selected-target"))
                c.binary = c.link
                output = c.run("host", "restart", "--all", expect=6 if placement == "contended" else 0, timeout=60)
                if placement == "contended":
                    assert "refused at starting" in output and '"code":"store_locked"' in output, output
                    assert "1 restarted" in output and "1 failed" in output, output
                    proof_ready(later, later_previous, later_old)
                    assert old.poll() is not None and c.status()["status"] != "ready", output
                else:
                    assert "1 restarted" in output, output
                    current = proof_ready(c, previous, old)
                    assert current["store"] == previous["store"] and current["store"] != str(c.store), current
        finally:
            if waiter is not None:
                # Let its bounded SQL finish and close its OWN connection;
                # coordinator never polls or manipulates the database lock.
                waiter.communicate(timeout=40)
            sql(f"DROP DATABASE IF EXISTS {database}")
            if runtime is not None and runtime.exists():
                shutil.rmtree(runtime)
    print("MySQL upgrade restart passed: default/moved interface, captured environment, typed DB-lock contention and later Host", flush=True)


def adopted_replacement_case(root, binary, releases):
    """A different retained installation of the target VERSION may win start."""
    for attempt in range(6):
        with case(root, binary, releases, f"adopted-replacement-{attempt}") as c:
            old, previous = c.start_host()
            alternate = c.build("concurrent-same-version")
            c.select(c.build("selected-target"))
            c.binary = c.link
            external, failures = [], []

            def compete():
                try:
                    old.wait(timeout=20)
                    child, ready = start_ready_process(
                        [alternate / "bin/rui", "host", "serve", "--store", c.store,
                         "--set", "providers={}", "--set", "execution.activeCapacity=" + previous["active_capacity"]],
                        env=c.env, isolate_providers=False)
                    c.hosts.append(child)
                    external.append((child, ready))
                except host_process.HostStartError as err:
                    # Losing this real Store-lock race is expected. Other
                    # startup failures are not evidence that adoption worked.
                    if '"code":"store_locked"' not in str(err):
                        failures.append(err)
                except Exception as err:
                    failures.append(err)

            competitor = threading.Thread(target=compete)
            competitor.start()
            try:
                output = c.run("host", "restart", "--all", timeout=60)
            finally:
                competitor.join(timeout=25)
            assert not competitor.is_alive() and not failures, failures
            assert "1 restarted" in output, output
            if external:
                child, ready = external[0]
                current = c.status()
                assert current["instance"] == ready["instance"] != previous["instance"], (current, previous)
                assert peer_pid(c.ready["socket"]) == child.pid
                assert os_semantics.process_executable(child.pid) == alternate / "bin/rui"
                assert os_semantics.process_executable(child.pid) != c.link.resolve()
                print("upgrade native: adopted same-target-version owner verified (different managed executable)", flush=True)
                return
    raise AssertionError("no external starter won the Store-lock race; adoption witness was not reached")


def known_target_case(root, binary, releases, baseline, known_bad):
    """Downloaded real releases, verified by the caller, never stand-in Hosts."""
    with case(root, binary, releases, "old-target-precondition") as c:
        retained = c.build("running-baseline")
        shutil.copy2(baseline, retained / "bin/rui")
        old_binary = retained / "bin/rui"
        old, ready = start_ready_process([old_binary, "host", "serve", "--store", c.store, "--active-capacity", "2"],
                                         env=c.env, isolate_providers=False)
        c.hosts.append(old)
        c.ready = ready

        def old_status():
            return json.loads(subprocess.check_output([old_binary, "host", "status", "--store", c.store], env=c.env, text=True, timeout=15))

        previous = old_status()
        try:
            for name, target, reason in (("no-settings-check", baseline, "launch configuration cannot be safely reconstructed"),
                                         ("known-bad-check", known_bad, "target build cannot safely check")):
                build = c.build(name)
                shutil.copy2(target, build / "bin/rui")
                c.select(build)
                output = c.run("host", "restart", "--all", timeout=60)
                assert "left running" in output and reason in output, output
                assert old.poll() is None and old_status()["instance"] == previous["instance"], output
            print("upgrade native: actual known-bad check and pre-check release targets refused before stop; old PID/instance unchanged", flush=True)
        finally:
            # Its owning historical client retains cleanup authority.
            c.binary = old_binary


def future_target_case(root, binary, releases):
    """Two real native builds: target has a deliberately different wire owner."""
    with case(root, binary, releases, "future-wire-target") as c:
        c.old_selection()
        old, previous = c.start_host()
        output = c.upgrade()
        assert "different Host protocol; inspect with the selected Rui client" in output, output
        c.binary = c.link
        current = proof_ready(c, previous, old)
        assert current["version"] != previous["version"], (current, previous)
        print("upgrade native: target-public status proved future-wire new instance and actual installed release", flush=True)


def alias_restart_cases(root, binary, releases):
    for spelling in ("symlink", "dot"):
        for saved in (False, True):
            with case(root, binary, releases, f"restart-alias-{spelling}-{saved}") as c:
                canonical_store = c.store
                canonical_store.mkdir(mode=0o700)
                if saved:
                    document = canonical_store / "host.json"
                    document.write_text(json.dumps({"providers": {}, "execution": {"activeCapacity": 3}}))
                    document.chmod(0o600)
                if spelling == "symlink":
                    alias = c.root / "host-alias"
                    alias.symlink_to(canonical_store, target_is_directory=True)
                else:
                    alias = canonical_store / ".." / canonical_store.name
                c.store = alias
                old, previous = c.start_host(sources_only=True)
                c.store = canonical_store
                c.select(c.build("selected-alias"))
                c.binary = c.link
                output = c.run("host", "restart", "--all", timeout=60)
                assert "1 restarted" in output, output
                current = proof_ready(c, previous, old)
                assert current["store"] == str(canonical_store), current
                assert str(canonical_store) in output, output
    print("upgrade native: absolute symlink/dot Host selectors restart with bare and saved sources", flush=True)


def restart_all_cases(root, binary, releases):
    alias_restart_cases(root, binary, releases)
    adopted_replacement_case(root, binary, releases)
    refused_source_cases(root, binary, releases)
    mysql_restart_cases(root, binary, releases)
    for source in ("bare", "saved", "file", "set"):
        with case(root, binary, releases, f"restart-sources-{source}") as c:
            extra = ()
            if source in ("saved", "file"):
                document = {"providers": {}, "execution": {"paused": True, "activeCapacity": 3},
                            "tools": {"bash": {"path": "/bin/bash", "timeoutMs": 1500}}}
                path = c.store / "host.json" if source == "saved" else c.root / "settings.json"
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.parent.chmod(0o700)
                path.write_text(json.dumps(document))
                path.chmod(0o600)
                if source == "file":
                    extra = ("--settings", path)
            elif source == "set":
                extra = ("--set", "providers={}", "--set", "execution.paused=true", "--set", "execution.activeCapacity=3")
            old, previous = c.start_host(f"retained-{source}", sources_only=True, extra=extra)
            c.select(c.build(f"selected-{source}"))
            c.binary = c.link
            output = c.run("host", "restart", "--all", timeout=60)
            assert "1 restarted" in output, output
            current = proof_ready(c, previous, old)
            for field in ("active_capacity", "paused", "capabilities"):
                assert current[field] == previous[field], (source, field, previous, current)

    # This suite runs under an isolated non-root fixture user: --all intentionally
    # discovers every Host of that uid, not just the defaults-selected Store.
    # Earlier lifecycle cases intentionally crash Hosts. Leave one explicitly
    # here too: discovery must prove its lease free without deleting its socket.
    with case(root, binary, releases, "restart-all-crashed") as c:
        from model_fixture import crash_host
        process, _ = c.start_host("restart-all-crashed")
        socket_path = pathlib.Path(c.ready["socket"])
        crash_host(process, c.root, "restart-all-crashed")
        assert socket_path.exists(), socket_path
        assert c.run("host", "restart", "--all").strip() == "No running Hosts."
        assert socket_path.exists(), "Discovery must not reclaim sockets"

    with case(root, binary, releases, "restart-all-empty") as c:
        assert c.run("host", "restart", "--all").strip() == "No running Hosts."
        c.assert_no_host()
        missing = c.run("host", "restart", expect=2)
        assert "[option_required]" in missing, missing
        rejected = c.run("host", "restart", "--all", "--store", c.store, expect=2)
        assert "[option_unknown]" in rejected, rejected

    # The selector is DIR, not the moved SQLite wire Store. Public starter
    # admission reloads its saved document; census also finds saved interfaces
    # outside the shallow uid socket directory, without a registry.
    for explicit in ("default", "uid", "external"):
        with contextlib.ExitStack() as interfaces, case(root, binary, releases, f"restart-all-moved-storage-{explicit}") as c:
            c.store.mkdir(mode=0o700)
            document = {"store": {"sqlite": {"dir": str(c.root / "data")}},
                        "execution": {"paused": True}, "providers": {}}
            if explicit != "default":
                runtime = (pathlib.Path(f"/tmp/rui-{os.geteuid()}") if explicit == "uid" else
                           interfaces.enter_context(host_process.short_interface_directory()) / "nested" / "private-interface")
                runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
                document["interface"] = {"dir": str(runtime)}
            saved = c.store / "host.json"
            saved.write_text(json.dumps(document))
            saved.chmod(0o600)
            original = saved.read_bytes()
            old, previous = c.start_host("moved-storage-retained", extra=("--set", "providers={}"))
            c.select(c.build("moved-storage-selected"))
            c.binary = c.link
            output = c.run("host", "restart", "--all", timeout=60)
            assert f"{c.store}: restarted on {releases.version}" in output, output
            assert "1 restarted" in output, output
            current = proof_ready(c, previous, old)
            assert current["paused"] is True and current["store"] == previous["store"], current
            assert saved.read_bytes() == original, output

    with case(root, binary, releases, "restart-all-first") as first, \
            case(root, binary, releases, "restart-all-second") as second:
        second.home, second.env, second.link = first.home, first.env, first.link
        old_first, previous_first = first.start_host("restart-all-retained-first")
        old_second, previous_second = second.start_host("restart-all-retained-second", store_hex=True)
        first.select(first.build("restart-all-selected"))
        first.binary = first.link
        output = first.run("host", "restart", "--all", timeout=60)
        for previous in (previous_first, previous_second):
            assert f"{previous['store']}: restarted on {releases.version}" in output, output
        assert "2 Hosts: 2 restarted" in output, output
        current_first = proof_ready(first, previous_first, old_first)
        current_second = proof_ready(second, previous_second, old_second)
        output = first.run("host", "restart", "--all", timeout=60)
        for previous in (previous_first, previous_second):
            assert f"{previous['store']}: already on {releases.version}" in output, output
        assert "2 Hosts: 0 restarted, 2 already current" in output, output
        assert first.status()["instance"] == current_first["instance"]
        assert second.status()["instance"] == current_second["instance"]

        unreadable = pathlib.Path(first.ready["socket"]).parent / "restart-unreadable.sock"
        try:
            with os_semantics.unix_stream() as listener:
                listener.bind(str(unreadable))
                listener.listen(1)
                output = first.run("host", "restart", "--all", expect=6)
                assert "Store unknown (socket " in output and "failed at discovery:" in output, output
                assert re.search(r"Host state is unconfirmed \([A-Za-z]+\);", output), output
                assert "[host_restart_failed]" in output, output
                assert "3 Hosts: 0 restarted, 2 already current, 0 left unchanged, 1 failed." in output, output
            output = first.run("host", "restart", "--all", expect=6)
            assert str(unreadable) in output and "Host state is unconfirmed" in output, output
            assert re.search(r"Host state is unconfirmed \([A-Za-z]+\);", output), output
            assert "3 Hosts: 0 restarted, 2 already current, 0 left unchanged, 1 failed." in output, output
            assert "[host_restart_failed]" in output, output
        finally:
            unreadable.unlink(missing_ok=True)
        output = first.run("host", "restart", "--all")
        assert "2 Hosts: 0 restarted, 2 already current" in output, output
        assert str(unreadable) not in output, output

    with case(root, binary, releases, "restart-all-managed-source") as c:
        old_host, previous = c.start_host("retained-older-source", source=True)
        target = c.build("selected-newer-source")
        (target / "revision").write_text("synthetic-newer-source-revision\n")
        c.run("--publish-install", c.home, target, "intentional-source")
        assert c.link.resolve() == target / "bin/rui"
        c.binary = c.link
        output = c.run("host", "restart", "--all", timeout=60)
        assert f"{previous['store']}: restarted on {releases.version}" in output, output
        current = proof_ready(c, previous, old_host)
        output = c.run("host", "restart", "--all")
        assert f"{previous['store']}: already on {releases.version}" in output, output
        assert c.status()["instance"] == current["instance"]
        start = len(releases.requests)
        output = c.upgrade(expect=6)
        assert "intentional source build" in output, output
        assert c.link.resolve() == target / "bin/rui"
        assert c.status()["instance"] == current["instance"]
        assert releases.archive_path not in releases.requests[start:]

    with case(root, binary, releases, "restart-all-application-owned") as c:
        process, previous = c.start_host("application-owned", managed=False)
        output = c.run("host", "restart", "--all")
        assert f"{previous['store']}: left running: application-owned Host" in output, output
        assert "1 Hosts: 0 restarted, 0 already current, 1 left unchanged, 0 failed." in output, output
        assert process.poll() is None and c.status()["instance"] == previous["instance"]

    with case(root, binary, releases, "restart-all-unknown-managed") as c:
        process, previous = c.start_host("unknown-managed")
        executable = os_semantics.process_executable(process.pid)
        (executable.parent.parent / "THIRD_PARTY_NOTICES.md").unlink()
        output = c.run("host", "restart", "--all")
        assert f"{previous['store']}: left running: application-owned Host" in output, output
        assert process.poll() is None and c.status()["instance"] == previous["instance"]


def tool_custody_cases(root, binary, releases, operation):
    import codex_fixture
    import model_fixture as fixture

    rows = itertools.product((False, True), (False, True) if operation == "restart" else (False,))
    for leader, closed_stdout in rows:
        name = f"tool-{operation}-leader-{leader}-closed-{closed_stdout}"
        with case(root, binary, releases, name + "-a") as first, \
                case(root, binary, releases, name + "-b") as second:
            second.home, second.env, second.link = first.home, first.env, first.link
            credentials = first.home / ".config/rui/codex.json"
            credentials.parent.mkdir(mode=0o700, parents=True)
            codex_fixture.credentials(credentials)
            endpoint = fixture.SuccessEndpoint([])
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            endpoints = {endpoint: thread}
            try:
                extra = ("--set", "providers={}",
                    "--set", "providers.codex.endpoint=" + str(f"http://127.0.0.1:{endpoint.server_port}/responses"),
                    "--set", "providers.codex.unauthenticated=true")
                old_first, previous_first = first.start_host("retained-a", extra=extra)
                old_second, previous_second = second.start_host("retained-b", extra=extra)
                origin = min((first, second), key=lambda c: c.ready["socket"])
                later = second if origin is first else first
                assert origin.ready["socket"] < later.ready["socket"]
                diagnostic = first.root / "coordinator-receipts.txt"
                if operation == "restart":
                    first.select(first.build("selected"))
                    argv = [str(first.link), "host", "restart", "--all"]
                else:
                    first.old_selection()
                    argv = [str(binary), "upgrade", "--store", str(origin.store)]
                invocation = shlex.join(argv)
                if operation == "upgrade":
                    invocation = shlex.join(["env", "RUI_TEST_UPGRADE_RELEASES_URL=" + releases.origin + "/releases", *argv])
                if closed_stdout:
                    script = ("import os; r,w=os.pipe(); os.close(r); "
                              "os.dup2(w,1); os.close(w); "
                              f"os.execv({argv[0]!r}, {argv!r})")
                    invocation = shlex.join([sys.executable, "-c", script])
                    if operation == "upgrade":
                        invocation = shlex.join(["env", "RUI_TEST_UPGRADE_RELEASES_URL=" + releases.origin + "/releases"]) + " " + invocation
                command = ("exec " if leader else "") + invocation
                command += " 2>" + shlex.quote(str(diagnostic))
                if not leader:
                    command += "; printf installer-shell-retained"
                arguments = json.dumps({"cmd": command, "description": "Upgrade from a Host Bash tool", "timeout_ms": 90000})
                endpoint.responses.append(fixture.sse_tool_calls(name, [("bash", name, arguments)]))
                endpoint.responses.append(fixture.sse_answer(name + "-after", "reason", "message", "done")[0])
                session = origin.json("session", "configure", "--store", origin.store,
                    "--workspace", origin.root, "--provider", "codex", "--model", "gpt-6-luna",
                    "--tools", "bash", "--permission-mode", "bypass")["answer"]["session"]
                origin.json("session", "send", "--store", origin.store, "--to", session, input="upgrade now")

                if operation == "restart":
                    wait_for(lambda: (old_first.poll(), old_second.poll(), first.status(), second.status()),
                             "origin-first tool restart returns every Host on the selected build", timeout=45,
                             ready=lambda state: all(status["status"] == "ready" and status["instance"] != previous["instance"]
                                                     for status, previous in zip(state[2:], (previous_first, previous_second))))
                    current_first = proof_ready(first, previous_first, old_first)
                    current_second = proof_ready(second, previous_second, old_second)
                    assert current_first["instance"] != current_second["instance"]
                    wait_for(lambda: diagnostic.exists() and "2 Hosts: 2 restarted" in diagnostic.read_text(),
                             "closed caller output retains complete restart diagnostics")
                    receipt = diagnostic.read_text()
                    assert receipt.index(str(origin.store) + ": restarted") < receipt.index(str(later.store) + ": restarted"), receipt
                else:
                    wait_for(lambda: (old_first.poll(), old_second.poll(), first.status(), second.status()),
                             "tool Upgrade finishes the entire batch after its caller is killed", timeout=45,
                             ready=lambda state: all(status["status"] == "ready" and status["instance"] != previous["instance"]
                                                     for status, previous in zip(state[2:], (previous_first, previous_second))))
                    current_first = proof_ready(first, previous_first, old_first)
                    current_second = proof_ready(second, previous_second, old_second)

                    def batch_receipt():
                        if not diagnostic.exists():
                            return None
                        events = [json.loads(line) for line in diagnostic.read_text().splitlines() if line.startswith("{")]
                        return events if any("done" in event for event in events) else None

                    events = wait_for(batch_receipt, "departed Upgrade caller retains the complete batch receipt")
                    entries = [event["entry"] for event in events if "entry" in event]
                    assert [entry["store"] for entry in entries] == [str(origin.store), str(later.store)], entries
                    for c, current in ((first, current_first), (second, current_second)):
                        outcome = next(entry["state"]["outcome"] for entry in entries if entry["store"] == str(c.store))
                        assert set(outcome) == {"ready"}, outcome
                        assert outcome["ready"]["pid"] == peer_pid(c.ready["socket"]), outcome
                        assert bytes(outcome["ready"]["instance"]).hex() == current["instance"], outcome
            finally:
                fixture.stop_endpoint(endpoint, endpoints)


def terminal_setup(c):
    from codex_fixture import credentials
    directory = c.home / ".config/rui"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    credential = directory / "codex.json"
    credentials(credential)
    c.run("defaults", "configure", "--provider", "codex", "--model", "gpt-6-luna")
    configured = c.json("session", "configure", "--store", c.store,
        "--workspace", c.root, "--provider", "codex", "--model", "gpt-6-luna")
    return configured["answer"]["session"], credential.read_bytes()


def overview_args(binary, c):
    return [str(binary), "--store", str(c.store), "--provider", "codex", "--model", "gpt-6-luna"]


def proof_relaunched(c, screen, process):
    installed = c.link.resolve(strict=True)
    assert installed != c.binary
    def observed():
        frame = screen.observe()
        return (os_semantics.process_executable(process.pid), screen.entries,
                screen.restorations, frame)

    wait_for(observed, "selected release replaced the original TUI PID after terminal restoration",
             timeout=15, ready=lambda value: value[:3] == (installed, 2, 1))
    screen.contains(f"Upgraded to {c.releases.version} · Host restarted")
    assert screen.capture.alternate


def exit_on_sigint(screen, process, description):
    process.send_signal(signal.SIGINT)

    def exited():
        screen.read_output()
        return process.poll() is not None

    wait_for(exited, description)
    output = bytes(screen.tail)
    restored = output.rfind(b"\x1b[?1049l")
    assert restored >= 0, f"{description}: terminal not restored"
    assert b"\x1b[?25h" in output, f"{description}: cursor not restored"
    return output[restored:]


def terminal_cases(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-overview") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        session, credential = terminal_setup(c)
        before = c.json("session", "inspect", "--store", c.store, "--session", session)
        request_directory = c.home / ".config/rui/requests"
        captures = {p.name: p.read_bytes() for p in request_directory.glob("*.json")}
        gate = releases.gate_archive()
        published = c.root / "after-publication.gate"
        published.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(published)
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "terminal installation archive gate")
            screen.contains("preparing Upgrade")
            screen.contains("Version")
            screen.save(artifacts, "overview-preparing")
            assert c.link.resolve() == c.original and c.status()["instance"] == previous["instance"]
            screen.send("\x1b")
            screen.contains(" · cancelled")
            gate.release.set()
            c.assert_unchanged()
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            receipt = exit_on_sigint(screen, process, "overview cancellation report after restoration")
            assert b"Upgrade installation failed:" in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "cancelled Upgrade relaunched"
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.contains(" · publishing")
            screen.close_settings()
            screen.contains("Publishing; cancelling no longer rolls back")
            screen.ignored_overview_input("overview α ignored/x\x1b[200~overview β paste\x1b[201~",
                                          "overview α ignored", "overview β paste")
            published.unlink()
            proof_relaunched(c, screen, process)
            proof_ready(c, previous, old_host)
            assert "alt+i info" not in screen.observe(), "overview reopened as a conversation"
            screen.overview(ready=False)
            screen.save(artifacts, "overview-installed")
            screen.ignored_overview_input("/x\x1b[200~returned γ paste\x1b[201~", "returned γ paste")
            screen.save(artifacts, "overview-returned")
            screen.start_upgrade()
            screen.contains(" · up to date")
            screen.close_settings()
            screen.contains(f"Rui is up to date ({releases.version})")
            assert os_semantics.process_executable(process.pid) == c.link.resolve()
            screen.ignored_overview_input("unchanged δ ignored", "unchanged δ ignored")
            screen.save(artifacts, "overview-unchanged")
            exit_on_sigint(screen, process, "overview exit after unchanged Upgrade")
            assert screen.entries == screen.restorations == 2, "unchanged Upgrade relaunched the TUI"
        after = c.json("session", "inspect", "--store", c.store, "--session", session)
        assert after["session"] == before["session"], "Upgrade submitted work or changed selected Session"
        assert (c.home / ".config/rui/codex.json").read_bytes() == credential
        assert {p.name: p.read_bytes() for p in request_directory.glob("*.json")} == captures, "local Upgrade captured a Host command"


def conversation_case(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-conversation") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        session, credential = terminal_setup(c)
        before = c.json("session", "inspect", "--store", c.store, "--session", session)
        gate = releases.gate_archive()
        published = c.root / "after-publication.gate"
        published.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(published)
        with terminal_process([str(binary), "session", "resume", "--store", str(c.store), session], env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.empty_chat(c, session)
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "conversation installation archive gate")
            screen.contains("preparing Upgrade")
            screen.contains("Version")
            screen.save(artifacts, "conversation-preparing")
            assert c.link.resolve() == c.original and c.status()["instance"] == previous["instance"]
            screen.send("\x1b")
            screen.contains(" · cancelled")
            gate.release.set()
            c.assert_unchanged()
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            receipt = exit_on_sigint(screen, process, "conversation cancellation report after restoration")
            assert b"Upgrade installation failed:" in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "cancelled Upgrade relaunched"
        with terminal_process([str(binary), "session", "resume", "--store", str(c.store), session], env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.empty_chat(c, session)
            screen.start_upgrade()
            screen.contains(" · publishing")
            screen.close_settings()
            screen.contains("Publishing; cancelling no longer rolls back")
            screen.send("\x01\x0bconversation β draft\x01\x1b[C\x1b[C\x1b[C")
            screen.draft("conversation β draft", 5)
            published.unlink()
            proof_relaunched(c, screen, process)
            screen.empty_chat(c, session,
                              expected_notice=f"Upgraded to {c.releases.version} · Host restarted")
            screen.draft("conversation β draft", 5)
            screen.save(artifacts, "conversation-installed")
            proof_ready(c, previous, old_host)
            screen.send("X")
            screen.draft("conXversation β draft", 6)
            screen.send("\x1bi")
            screen.until(lambda: "unavailable" not in screen.capture.completed
                         and all(value in screen.capture.completed for value in
                                 ("Copy last answer", "Model", "Folder", "gpt-6-luna")),
                         "ready chat info reads the relaunched Host")
            screen.contains("› conXversation β draft")
            screen.save(artifacts, "conversation-returned")
            screen.leave_empty_chat(c, session)
            screen.save(artifacts, "conversation-left-empty-hidden")
        after = c.json("session", "inspect", "--store", c.store, "--session", session)
        assert after["session"] == before["session"], "Upgrade submitted work or changed the open Session"
        assert (c.home / ".config/rui/codex.json").read_bytes() == credential


def escape_after_publication(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-escape-after-publication") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = c.root / "after-publication.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(gate)
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.until(lambda: c.link.resolve() != c.original, "publication before terminal Escape")
            installed = c.link.resolve()
            screen.contains(" · publishing")
            screen.close_settings()
            screen.contains("Publishing; cancelling no longer rolls back")
            screen.save(artifacts, "escape-after-publication")
            assert c.link.resolve() == installed and installed.exists()
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            gate.unlink()
            proof_relaunched(c, screen, process)
            proof_ready(c, previous, old_host)
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential


def terminal_download_recovery(root, binary, releases, artifacts):
    """Settings > Version recovers DNS failure through the same download owner."""
    with case(root, binary, releases, "terminal-download-recovery") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        # Retain the report rather than exec so this journey is independent
        # of any other application-owned Hosts discovered for the fixture uid.
        shadow = c.build("recovery-shadowing-path", "0.1.0", managed=False) / "bin/rui"
        c.env["PATH"] = f"{shadow.parent}:{c.env['PATH']}"
        curl = CurlAttempts(c, {"/releases/latest": [6]})
        gate = releases.gate_archive()
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "Settings download recovered and reached archive")
            screen.contains("preparing Upgrade")
            screen.save(artifacts, "download-recovering-settings")
            assert c.link.resolve() == c.original
            gate.release.set()
            screen.contains(f" · upgraded to {releases.version}")
            screen.save(artifacts, "download-recovered-settings")
            screen.close_settings()
            screen.contains(f"Upgraded to {releases.version}")
            proof_ready(c, previous, old_host)
            screen.save(artifacts, "download-recovered")
            curl.assert_attempts([("/releases/latest", "normal", 6),
                                 ("/releases/latest", "ipv4", 0),
                                 (releases.sums_path, "ipv4", 0),
                                 (releases.archive_path, "ipv4", 0)])
            receipt = exit_on_sigint(screen, process, "recovered download report after terminal restoration")
            assert b"Installed Rui" in receipt and b"restarted on " in receipt, receipt.decode()
            assert b"curl fixture final" not in receipt, receipt.decode()
            assert os.fsencode(shadow) in receipt, "recovery lost the retained PATH guidance"
            assert screen.entries == screen.restorations == 1, "retained guidance relaunched the TUI"
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            if artifacts is not None:
                (artifacts / "download-recovered.pty-tail.ansi").write_bytes(screen.tail)
                (artifacts / "download-recovered.receipt.txt").write_bytes(receipt)
                shutil.copy2(curl.log, artifacts / "download-recovered.curl.jsonl")


def terminal_download_failure(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-download-failure") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        releases.status["/releases/latest"] = 403
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.contains(" · couldn't reach GitHub")
            assert os_semantics.process_executable(process.pid) == binary, "failed check replaced the client"
            assert screen.entries == 1 and screen.restorations == 0, "failed check relaunched"
            screen.save(artifacts, "download-failure-settings")
            screen.close_settings()
            screen.contains("Couldn't reach GitHub; nothing changed")
            receipt = exit_on_sigint(screen, process, "restored curl download failure report")
            assert b"curl: (22)" in receipt and b"403" in receipt, receipt.decode()
            assert b"could not download release information" in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "failed check relaunched on departure"
            c.assert_unchanged()
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential


def terminal_cancellation_guidance(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-cancellation-guidance") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        terminal_setup(c)
        gate = releases.gate_archive()
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "archive held before cancellation guidance")
            screen.send("\x1b")
            screen.contains(" · cancelled")
            gate.release.set()
            c.assert_unchanged()
            screen.start_upgrade()
            screen.contains(f" · upgraded to {releases.version}")
            screen.close_settings()
            screen.contains(f"Upgraded to {releases.version}")
            proof_ready(c, previous, old_host)
            assert os_semantics.process_executable(process.pid) == binary
            screen.save(artifacts, "cancellation-guidance-installed")
            receipt = exit_on_sigint(screen, process, "retained cancellation report after successful install")
            assert b"Upgrade installation failed:" in receipt, receipt.decode()
            assert b"No completed installation receipt" in receipt, receipt.decode()
            assert b"Installed Rui. Complete build:" in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "prior report triggered delayed relaunch"


def terminal_path_guidance(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-path-guidance") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        shadow = c.build("shadowing-path", "0.1.0", managed=False) / "bin/rui"
        c.env["PATH"] = f"{shadow.parent}:{c.env['PATH']}"
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.contains(f" · upgraded to {releases.version}")
            screen.close_settings()
            screen.contains(f"Upgraded to {releases.version}")
            proof_ready(c, previous, old_host)
            screen.ignored_overview_input("guidance ε ignored", "guidance ε ignored")
            assert os_semantics.process_executable(process.pid) == binary
            assert screen.entries == 1 and screen.restorations == 0
            screen.save(artifacts, "path-guidance-installed")
            receipt = exit_on_sigint(screen, process, "PATH guidance after terminal restoration")
            assert b"Your PATH finds another rui first, at " in receipt, receipt.decode()
            assert os.fsencode(shadow) in receipt, "departure lost the shadowing executable's path"
            assert b"hash -r" in receipt and b"rehash" in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "PATH guidance did not prevent relaunch"
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential


def startup_cases(root, binary, releases, artifacts):
    for screen_kind, condition, store_kind in itertools.product(
            ("overview", "resume"), ("readable", "unreadable", "no-credentials"),
            ("explicit", "implicit")):
        name = f"startup-{screen_kind}-{condition}-{store_kind}"
        with case(root, binary, releases, name) as c:
            c.old_selection()
            old_host, previous = c.start_host()
            session, credential_bytes = terminal_setup(c)
            c.run("defaults", "configure", "--store", c.store)
            before = c.json("session", "inspect", "--store", c.store, "--session", session)
            preferences = c.home / ".config/rui/preferences"
            credential = c.home / ".config/rui/codex.json"
            preference_mode = stat.S_IMODE(preferences.stat().st_mode)
            other_store = c.root / "other-store" if store_kind == "implicit" else None
            if other_store is not None:
                other_store.mkdir(mode=0o700)
            published = c.root / "after-publication.gate"
            published.touch()
            c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(published)
            destination = ["--store", str(c.store)] if store_kind == "explicit" else []
            arguments = ([str(binary), "session", "resume", *destination, session]
                         if screen_kind == "resume" else [str(binary), *destination])

            def retire_misdirected_host():
                if other_store is not None:
                    status = c.json("host", "status", "--store", other_store)
                    if status["status"] == "ready":
                        c.run("host", "pause", "--store", other_store, "--instance", status["instance"])

            try:
                with terminal_process(arguments, env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
                    screen = TerminalScreen(master, process)
                    if screen_kind == "resume":
                        screen.empty_chat(c, session)
                    else:
                        screen.launch_overview()
                        screen.empty_overview(c, session, ready=True)
                    screen.start_upgrade()
                    screen.contains(" · publishing")
                    screen.close_settings()
                    screen.contains("Publishing; cancelling no longer rolls back")
                    if screen_kind == "resume":
                        screen.send("\x01\x0bstartup α draft\x01\x1b[C\x1b[C\x1b[C")
                        screen.draft("startup α draft", 5)
                    else:
                        screen.ignored_overview_input("/xstartup α ignored\x1b[200~startup β paste\x1b[201~",
                                                      "startup α ignored", "startup β paste")
                    assert c.link.resolve() != c.original and published.exists()
                    assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
                    if other_store is not None:
                        c.run("defaults", "configure", "--store", other_store)
                    expected_preferences = preferences.read_bytes()
                    if condition == "unreadable":
                        preferences.chmod(0o000)
                    elif condition == "no-credentials":
                        credential.unlink()
                    published.unlink()
                    proof_relaunched(c, screen, process)
                    proof_ready(c, previous, old_host)
                    if screen_kind == "resume":
                        screen.empty_chat(c, session,
                                          expected_notice=f"Upgraded to {c.releases.version} · Host restarted")
                        screen.draft("startup α draft", 5)
                        screen.send("X")
                        screen.draft("staXrtup α draft", 6)
                    else:
                        screen.empty_overview(c, session)
                        screen.ignored_overview_input("/xreturned γ ignored\x1b[200~returned δ paste\x1b[201~",
                                                      "returned γ ignored", "returned δ paste")
                    screen.save(artifacts, name)
                    assert "No locally ready provider for a new Session" not in screen.capture.plain
                    assert "private setup defaults unreadable" not in screen.capture.plain
                    if condition == "unreadable":
                        assert stat.S_IMODE(preferences.stat().st_mode) == 0
                    if condition == "no-credentials":
                        assert not credential.exists(), "relaunch recreated provider credentials"
                    else:
                        assert credential.read_bytes() == credential_bytes
                    if other_store is not None:
                        assert c.json("host", "status", "--store", other_store)["status"] == "unavailable"
                        assert not list(other_store.iterdir()), "relaunch opened the newly saved default Store"
                    exit_on_sigint(screen, process, f"{name} terminal exit")
                    assert screen.entries == screen.restorations == 2, "startup replaced the TUI more than once"
                after = c.json("session", "inspect", "--store", c.store, "--session", session)
                assert after["session"] == before["session"], "relaunch submitted a draft or changed the Session"
                preferences.chmod(preference_mode)
                assert preferences.read_bytes() == expected_preferences, "relaunch rewrote saved defaults"
            finally:
                dispose_all(lambda: preferences.chmod(preference_mode), retire_misdirected_host)
        print(f"upgrade native: {name} passed", flush=True)


def signal_during_check(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-signal-during-check") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = releases.gates["/releases/latest"] = Gate()
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "release check held before terminal signal")
            screen.contains("checking for updates")
            screen.save(artifacts, "signal-during-check")
            exit_on_sigint(screen, process, "terminal exit during held upgrade check")
            assert not gate.release.is_set(), "terminal required release peer release before exiting"
            c.assert_unchanged()
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential


def signal_after_publication(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-signal-after-publication") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = c.root / "after-publication.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(gate)
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.until(lambda: c.link.resolve() != c.original, "publication before SIGINT")
            installed = c.link.resolve()
            assert installed.exists() and gate.exists()
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            receipt = exit_on_sigint(screen, process, "joined publication receipt and terminal exit after SIGINT")
            assert b"Installed Rui. Complete build:" in receipt, ("joined installation receipt was lost after interruption", receipt.decode())
            assert b"Host restart could not finish (Cancelled)" in receipt, receipt.decode()
            assert b"Installation was not rolled back" in receipt, receipt.decode()
            assert os.fsencode(installed.parent.parent) in receipt, "receipt lost the published build identity"
            assert gate.exists(), "signal exit required releasing the post-publication gate"
            assert c.link.resolve() == installed and installed.exists(), "signal rolled back publication"
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            if artifacts is not None:
                (artifacts / "signal-after-publication.txt").write_text(screen.capture.plain)


def cancel_selected_version_check(root, binary, releases, artifacts):
    with case(root, binary, releases, "selected-version-cancel-escape") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = c.root / "selected-version.fifo"
        os.mkfifo(gate, mode=0o600)
        receipt = c.root / "selected-version.pid"
        c.original.write_text(
            '#!/bin/sh\n[ "$1" = --version ] || exit 91\n'
            f'printf "%s\\n" "$$" > {shlex.quote(str(receipt))}\n'
            f'IFS= read -r released < {shlex.quote(str(gate))}\n'
            "printf '%s\\n' 'rui 0.1.0 (synthetic gated metadata fixture)'\n")
        start = len(releases.requests)

        def release_version():
            descriptor = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
            try:
                os.write(descriptor, b"continue\n")
            finally:
                os.close(descriptor)

        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            try:
                screen = TerminalScreen(master, process)
                screen.launch_overview()
                screen.start_upgrade()

                def child_started():
                    return receipt.exists() and receipt.read_text().strip().isdigit()

                screen.until(child_started, "selected --version child receipt before discovery")
                child_pid = int(receipt.read_text().strip())

                def alive():
                    running = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                             env=c.env, capture_output=True, text=True, timeout=5)
                    return running.returncode == 0 and not running.stdout.strip().startswith("Z")

                assert alive()
                screen.contains("checking for updates")
                assert releases.requests[start:] == [], "latest discovery ran before selected probe completed"
                screen.send("\x1b")
                screen.contains(" · cancelled")
                screen.save(artifacts, "selected-version-escape")

                def reaped():
                    observed = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                              env=c.env, capture_output=True, text=True, timeout=5)
                    if observed.returncode == 1 and not observed.stdout and not observed.stderr:
                        return True
                    assert observed.returncode == 0 and observed.stdout.strip(), observed
                    return False

                wait_for(reaped, "cancelled exact selected --version child reap")
                assert releases.requests[start:] == [], "cancelled check reached latest discovery"
                assert c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            finally:
                dispose_all(release_version)


def terminal_cleanup_dual_failure(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-dual-failure") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        parent = c.home / ".local/lib/rui"
        original_mode = stat.S_IMODE(parent.stat().st_mode)
        original_digest = releases.digest
        releases.digest = "0" * 64
        gate = releases.gate_archive()
        try:
            with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
                screen = TerminalScreen(master, process)
                screen.launch_overview()
                screen.start_upgrade()
                screen.until(gate.entered.is_set, "real archive request after stage creation")
                stages = list(parent.glob("install.*"))
                assert len(stages) == 1 and stages[0].is_dir(), stages
                retained = stages[0]
                parent.chmod(0o500)
                gate.release.set()
                screen.contains(" · upgrade failed")
                screen.close_settings()
                screen.contains("Upgrade failed; nothing changed")
                screen.save(artifacts, "dual-failure-status")
                assert retained.is_dir(), "cleanup receipt did not identify an existing retained stage"
                assert c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                receipt = exit_on_sigint(screen, process, "restored primary and retained cleanup receipt after SIGINT")
                assert b"ReleaseChecksumMismatch" in receipt, receipt.decode()
                assert b"cleanup also failed (AccessDenied)" in receipt, receipt.decode()
                assert os.fsencode(retained.resolve()) in receipt, ("restored output lost retained cleanup custody", receipt.decode())
                assert retained.is_dir() and c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
                if artifacts is not None:
                    (artifacts / "dual-failure-restored.txt").write_text(screen.capture.plain)
        finally:
            dispose_all(lambda: parent.chmod(original_mode),
                        gate.release.set,
                        lambda: setattr(releases, "digest", original_digest))


def main():
    modes = ("restart-all", "lifecycle", "custody", "download", "terminal", "startup", "future-target", "known-target")
    if len(sys.argv) not in (2, 3, 4, 5) or (len(sys.argv) >= 3 and sys.argv[2] not in modes):
        sys.exit("usage: python3 tests/integration/upgrade_integration.py REAL_RUI [restart-all|lifecycle|custody|terminal|startup|future-target FUTURE_REAL_RUI|known-target BASELINE_RUI KNOWN_BAD_RUI]")
    selection = sys.argv[2] if len(sys.argv) >= 3 else "all"
    assert len(sys.argv) == (4 if selection == "future-target" else 5 if selection == "known-target" else 2 if selection == "all" else 3), "supply the native binaries required by this mode"
    binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
    target_binary = pathlib.Path(sys.argv[3]).resolve(strict=True) if selection == "future-target" else binary
    root = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-upgrade-"))
    version_home = root / "version-home"
    version_home.mkdir()
    version_output = subprocess.check_output([str(target_binary), "--version"],
        env={**os.environ, "HOME": str(version_home)}, text=True, timeout=5)
    match = re.match(r"rui (0\.[0-9]+\.[0-9]+) \(", version_output)
    assert match, "supply a native release-identity actor (production owners), not an unreleased build"
    version = match[1]
    configured_artifacts = os.environ.get("RUI_UPGRADE_FAILURES") or os.environ.get("RUI_FAILURE_ARTIFACTS")
    artifacts = pathlib.Path(configured_artifacts).resolve() if configured_artifacts else None
    if artifacts is not None:
        artifacts.mkdir(parents=True, exist_ok=True)
        assert not artifacts.is_relative_to(root), "artifacts must outlive fixture root"
    releases = Releases(target_binary, version)
    complete = False
    try:
        if selection == "future-target":
            future_target_case(root, binary, releases)
        if selection == "known-target":
            known_target_case(root, binary, releases, pathlib.Path(sys.argv[3]).resolve(strict=True), pathlib.Path(sys.argv[4]).resolve(strict=True))
        if selection in ("restart-all", "lifecycle"):
            suite = {"restart-all": restart_all_cases, "lifecycle": lifecycle_cases}[selection]
            suite(root, binary, releases)
            print(f"upgrade native: {suite.__name__} passed", flush=True)
            tool_custody_cases(root, binary, releases, "restart" if selection == "restart-all" else "upgrade")
        if selection == "custody":
            for operation in ("restart", "upgrade"):
                tool_custody_cases(root, binary, releases, operation)
                print(f"upgrade native: tool {operation} custody passed", flush=True)
        if selection == "download":
            download_cases(root, binary, releases)
            print("upgrade native: download_cases passed", flush=True)
            terminal_download_recovery(root, binary, releases, artifacts)
            print("upgrade native: terminal_download_recovery passed", flush=True)
        if selection == "all":
            for suite in (discovery_cases, download_cases, install_cases, lifecycle_cases, restart_all_cases):
                suite(root, binary, releases)
                print(f"upgrade native: {suite.__name__} passed", flush=True)
            for operation in ("restart", "upgrade"):
                tool_custody_cases(root, binary, releases, operation)
                print(f"upgrade native: tool {operation} custody passed", flush=True)
        if selection in ("all", "terminal"):
            for suite in (terminal_download_recovery, terminal_download_failure, terminal_cases, conversation_case, escape_after_publication,
                          terminal_cancellation_guidance, terminal_path_guidance):
                suite(root, binary, releases, artifacts)
                print(f"upgrade native: {suite.__name__} passed", flush=True)
        if selection in ("all", "startup"):
            startup_cases(root, binary, releases, artifacts)
        if selection == "all":
            for suite in (cancel_selected_version_check, terminal_cleanup_dual_failure,
                          signal_after_publication, signal_during_check):
                suite(root, binary, releases, artifacts)
                print(f"upgrade native: {suite.__name__} passed", flush=True)
        complete = True
    finally:
        retired = False

        def retire_server():
            nonlocal retired
            releases.close()
            retired = True

        def retain_or_remove():
            if complete and retired:
                shutil.rmtree(root)
            else:
                print(f"Upgrade failure state retained: {root}", file=sys.stderr)

        dispose_all(retire_server, retain_or_remove)


if __name__ == "__main__":
    host_process.enter()
    main()
