#!/usr/bin/env python3
"""Native, offline Upgrade evidence: python3 upgrade_integration.py REAL_RUI [terminal|startup].

Release redirects, target version and archives may be synthetic. Only the
*selected old version* fixture is a --version-only script; every started Host
and every install target is the supplied real native executable. Retained-build paths, not invented
Host versions, exercise replacement of an already-running native Host.
"""
import contextlib
import hashlib
import http.server
import io
import itertools
import json
import os
import pathlib
import re
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

import host_process
import os_semantics
from host_process import canonical_fixture_root, dispose_all, start_ready_process, stop_process, wait_for
from terminal_process import COLUMNS, ROWS, answers_to, terminal_process
from terminal_screen import ScreenCapture, shown


# Spawn at the same split-pane size the observer measures. A post-spawn
# resize can leave the first committed Settings coordinates stale for a click.
TERMINAL_COLUMNS = max(COLUMNS, 140)


class Gate:
    """A request records arrival before the owner chooses its release."""

    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()

    def hold(self):
        self.entered.set()
        wait_for(self.release.is_set, "fixture release gate", timeout=45)


class Releases:
    """One pinned GitHub-shaped publication; never resolves a real release."""

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
                # Capture the exact requested pinned path before releasing it.
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
                    # A cancelled curl relinquishes its request; no success is
                    # inferred from the HTTP writer's eventual completion.
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
            # Metadata/publisher eligibility only. NEVER used for host serve.
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

    def start_host(self, name="retained-real-host", *, managed=True, store_hex=False, extra=(), source=False):
        build = self.build(name, managed=managed)
        if source:
            (build / "revision").write_text("synthetic-source-revision-marker\n")
        destination = ["--store-hex", os.fsencode(self.store).hex()] if store_hex else ["--store", self.store]
        provider = [] if "--provider-endpoint" in extra else ["--provider", "codex"]
        process, ready = start_ready_process(
            [build / "bin/rui", "host", "serve", *destination,
             "--active-capacity", "2", *provider, *extra], env=self.env)
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
        # Release blocked fixture HTTP writers before waiting for clients.
        for gate in releases.gates.values():
            gate.release.set()
        def reset_publication():
            releases.gates.clear()
            releases.status.clear()
            releases.latest_location = None
            releases.sums_name = None
        dispose_all(value.close, reset_publication)


def peer_pid(path):
    """Independent OS receipt of the exact listening native process."""
    with os_semantics.unix_stream() as connection:
        connection.connect(path)
        return os_semantics.socket_peer_pid(connection)


def proof_ready(c, previous, old_host):
    status = c.status()
    assert status["status"] == "ready", status
    assert status["instance"] != previous["instance"], "old Host was not replaced"
    assert status["store"] == previous["store"]
    assert status["active_capacity"] == previous["active_capacity"] == "2"
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
        # The explicit release installer, unlike automatic Upgrade, can make
        # the person's intentional source-to-release conversion.
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
        # Bound local connection failure; no DNS, external host or provider.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            c.env["RUI_TEST_UPGRADE_RELEASES_URL"] = f"http://127.0.0.1:{reserved.getsockname()[1]}/releases"
            child = c.spawn_upgrade()
            output = c.finish_upgrade(child, success=False)
            assert "upgrade_download_failed" in output and "curl: (" in output, output
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
        # A retained executable under another synthetic HOME is foreign to
        # this installation. Discovery must still report its explained skip.
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
        old_host, previous = c.start_host(extra=("--bash-path", relative_bash))
        output = c.finish_upgrade(c.spawn_upgrade())
        assert "Installed Rui" in output and "left running: launch configuration cannot be safely reconstructed" in output, output
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
        # The pre-install census is warning-only. Fresh post-publication
        # discovery must include and authorize the replacement, not an old plan.
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
        # Publication succeeded. Losing that executable must not be called a
        # preparation failure or cause the known-good old Host to be stopped.
        installed.unlink()
        gate.unlink()
        output = c.finish_upgrade(child, success=False)
        assert "Installed Rui" in output and "Host restart could not finish" in output, output
        assert "Installation was not rolled back" in output and "failed before publication" not in output, output
        assert c.link.is_symlink() and os.readlink(c.link) == str(installed)
        assert host.poll() is None and c.status()["instance"] == previous["instance"]


class TerminalScreen:
    """Borrow the repository's committed screen observer, not text scraping."""

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
            # Count real terminal leave/re-entry, including controls split
            # across PTY reads. A frame from the old image is not a relaunch.
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
            # A crash writes its message after the last frame: show it.
            self.read_output()
            raise AssertionError(self.process.returncode, self.capture.completed, bytes(self.tail[-4096:]).decode(errors="replace"))
        return self.capture.completed

    def contains(self, marker):
        return wait_for(self.observe, f"terminal screen: {marker}", timeout=15,
                        ready=lambda screen: shown(marker, screen))

    def until(self, predicate, description):
        # Keep draining the real PTY while waiting for a nonterminal effect;
        # Darwin's small PTY output queue is not a background log sink.
        return wait_for(self.observe, description, timeout=15, ready=lambda _: predicate())

    def draft(self, text, caret):
        return self.until(lambda: self.capture.draft(text, caret),
                          f"terminal draft and caret: {text!r}, {caret}")

    def send(self, text):
        os.write(self.master, text.encode())

    def overview(self, *, ready=True):
        frame = wait_for(self.observe, "terminal overview list and footer", timeout=15,
                         ready=lambda screen: all(shown(marker, screen) for marker in
                                                  ("+ New Session", "Settings"))
                         and (not ready or shown("enter open", screen))
                         and "Notifications" not in screen)
        assert "Type a task" not in frame, ("overview has an editor", frame)
        assert not re.search(r"(?m)(?:^|│)\s*[›>](?: |$)", frame), ("overview has a composer", frame)
        return frame

    def empty_session(self, case, session):
        """Exactly this accepted empty Session still exists; projection is separate."""
        report = case.json("session", "inspect", "--store", case.store, "--session", session)
        facts = report["session"]
        assert facts["reference"] == session, report
        assert report["selected_message"] is None and report["recent_messages"] == [], report
        listing = case.json("session", "list", "--store", case.store, "--all")
        assert {row["reference"] for row in listing["sessions"]} == {session}, listing
        return facts

    def empty_overview(self, case, session, *, ready=False):
        """An accepted no-Message Session is stored, not an overview row."""
        frame = self.overview(ready=ready)
        assert not shown(session, frame), ("empty Session leaked into overview", frame)
        assert "alt+i info" not in frame, ("overview reopened as a conversation", frame)
        self.empty_session(case, session)
        return frame

    def empty_chat(self, case, session, *, expected_notice=None):
        """The sole accepted Session is open with its empty-chat facts.

        Empty-chat footers show model/effort/folder, not the reference. Bind
        identity through the public report and list instead; a mistaken New
        Session would add a second reference. Unsent drafts remain editor
        state and do not change this no-Message contract after relaunch.
        A proven relaunch can retain a reply instead of the info action; its
        caller must name that exact outcome rather than skip footer readiness.
        """
        facts = self.empty_session(case, session)
        footer = "alt+i info" if expected_notice is None else expected_notice
        assert footer, "empty chat requires an info action or an exact retained notice"
        frame = wait_for(self.observe, "empty chat model facts and expected footer", timeout=15,
                         ready=lambda screen: shown(f"│ {facts['model']} · ", screen)
                         and shown(footer, screen))
        return frame

    def ignored_overview_input(self, text, *markers):
        self.overview(ready=False)
        # End and Enter open Settings after every ignored byte. Observing that
        # panel and returning orders the check after input consumption, even
        # when ignored input itself causes no repaint.
        self.send(text + "\x1b[F\r")
        self.contains("Notifications")
        self.close_settings()
        # The roundtrip acknowledges input; a held Host need not advertise
        # Enter on the returned list.
        frame = self.overview(ready=False)
        for marker in markers:
            assert marker not in frame, ("overview retained ignored input", marker, frame)
        assert "Unknown command" not in frame, ("overview interpreted a slash command", frame)

    def start_upgrade(self):
        # Settings stays reachable in the split list while a conversation is open.
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


def restart_all_cases(root, binary, releases):
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

    with case(root, binary, releases, "restart-all-first") as first, \
            case(root, binary, releases, "restart-all-second") as second:
        # Both retained managed builds belong to the one installing user/home.
        # They are real native Hosts, just as the other lifecycle cases above;
        # a different retained path establishes older launch identity without
        # inventing a Host version or replacing its wire implementation.
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

        # Derive the runtime location from native readiness, not a second owner
        # of the uid/hash naming rule. A live non-Host socket must be reported;
        # after its listener closes, even this stale socket stays unconfirmed:
        # discovery cannot prove the Store lease is free from a refused connect.
        unreadable = pathlib.Path(first.ready["socket"]).parent / "restart-unreadable.sock"
        try:
            with os_semantics.unix_stream() as listener:
                listener.bind(str(unreadable))
                listener.listen(1)
                output = first.run("host", "restart", "--all", expect=6)
                assert "Store unknown (socket " in output and "failed at discovery:" in output, output
                assert "[host_restart_failed]" in output, output
                assert "3 Hosts: 0 restarted, 2 already current, 0 left unchanged, 1 failed." in output, output
            output = first.run("host", "restart", "--all", expect=6)
            assert str(unreadable) in output and "Host state is unconfirmed" in output, output
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
        # As with the retained release builds above, these are different real
        # build identities at the same numeric version. Source revisions can
        # advance without a version bump; both builds have source markers.
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
        # Observation of a source Host grants no right to replace a selected
        # source installation through Upgrade: that still requires .released.
        start = len(releases.requests)
        output = c.upgrade(expect=6)
        assert "intentional source build" in output, output
        assert c.link.resolve() == target / "bin/rui"
        assert c.status()["instance"] == current["instance"]
        assert releases.archive_path not in releases.requests[start:]

    with case(root, binary, releases, "restart-all-application-owned") as c:
        process, previous = c.start_host("application-owned", managed=False)
        # There is no selected installation: unsupported ownership is a skip,
        # not an attempt to select a target, stop the process or start a Host.
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
    """A real Host Bash tool may kill its caller, but not restart custody.

    The exact same restart CLI is used by both installers. Cross exec'd group
    leader vs a retained installer shell with open vs already-broken stdout.
    The originating Host is deliberately the first socket in discovery order.
    Upgrade also uses this owner, including its inline UpgradeJob caller.
    """
    import codex_fixture
    import model_fixture as fixture

    # Restart receipts are optional even before handoff. Upgrade warnings are
    # required before publication; its report pipe closes when the first Host
    # kills the caller, not before the warning has been presented.
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
                extra = ("--provider-endpoint", f"http://127.0.0.1:{endpoint.server_port}/responses")
                old_first, previous_first = first.start_host("retained-a", extra=extra)
                old_second, previous_second = second.start_host("retained-b", extra=extra)
                # Take ordering from readiness socket paths, never duplicate the
                # runtime's Store hash or assume creation order is discovery order.
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
                    # Host child environments intentionally omit test routing.
                    # Bind this nested CLI explicitly to the offline authority;
                    # never let a tool-side check reach published releases.
                    invocation = shlex.join(["env", "RUI_TEST_UPGRADE_RELEASES_URL=" + releases.origin + "/releases", *argv])
                if closed_stdout:
                    # Leave a real fd 1 pipe with no readers, not a missing fd
                    # that initialization could reuse. The break precedes exec.
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
    # Reuse the existing synthetic credential authority; never inspect the
    # caller's HOME, real credentials or a live provider endpoint.
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
    """The overview, where every terminal case starts; a conversation opens from it."""
    return [str(binary), "--store", str(c.store), "--provider", "codex", "--model", "gpt-6-luna"]


def proof_relaunched(c, screen, process):
    """The original TUI PID now executes the published image on this PTY."""
    installed = c.link.resolve(strict=True)
    assert installed != c.binary
    def observed():
        frame = screen.observe()
        return (os_semantics.process_executable(process.pid), screen.entries,
                screen.restorations, frame)

    wait_for(observed, "selected release replaced the original TUI PID after terminal restoration",
             timeout=15, ready=lambda value: value[:3] == (installed, 2, 1))
    # Re-entry clears the observer's old completed frame. This is the new
    # TUI's ending line, not the old TUI's last frame or departure output.
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
    """Settings > Version on the overview reports progress; Esc cancels
    while preparing; a fresh TUI's Upgrade replaces both Host and TUI,
    retaining the editor-free overview. An up-to-date run does not relaunch again."""
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
            screen.overview()
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "terminal installation archive gate")
            screen.contains("preparing Upgrade")
            screen.contains("Version")
            screen.save(artifacts, "overview-preparing")
            assert c.link.resolve() == c.original and c.status()["instance"] == previous["instance"]
            # Escape interrupts the running download; nothing waits on the
            # fixture server.
            screen.send("\x1b")
            screen.contains(" · cancelled")
            gate.release.set()
            c.assert_unchanged()
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            receipt = exit_on_sigint(screen, process, "overview cancellation report after restoration")
            assert b"Upgrade installation failed:" in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "cancelled Upgrade relaunched"
        # A cancellation's report belongs to its old TUI until departure. A
        # fresh launch has no retained guidance to suppress this installation.
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.overview()
            screen.start_upgrade()
            screen.contains(" · publishing")
            screen.close_settings()
            screen.contains("Publishing; cancelling no longer rolls back")
            # Printable, slash and pasted bytes cannot seed an overview draft,
            # including while publication holds the Host.
            screen.ignored_overview_input("overview α ignored/x\x1b[200~overview β paste\x1b[201~",
                                          "overview α ignored", "overview β paste")
            published.unlink()
            proof_relaunched(c, screen, process)
            proof_ready(c, previous, old_host)
            assert "alt+i info" not in screen.observe(), "overview reopened as a conversation"
            # The proven relaunch retains its Upgrade reply in Footer.
            screen.overview(ready=False)
            screen.save(artifacts, "overview-installed")
            screen.ignored_overview_input("/x\x1b[200~returned γ paste\x1b[201~", "returned γ paste")
            screen.save(artifacts, "overview-returned")
            # The selected build is now current: the second run installs
            # nothing. Its terminal retirement below is a completed witness
            # that no second exec/re-entry occurred, even of the same image.
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
    """Settings > Version over a conversation runs the overview's Upgrade:
    Esc cancels while preparing; a fresh TUI's Upgrade installs and
    restarts Host and TUI, reopening that conversation with its unsent draft."""
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
            # The empty chat footer carries model facts; the public Session
            # boundaries retain its exact accepted identity.
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
            # The selected image restored the actual conversation and caret,
            # not just an overview row. Its info panel reads from the new Host
            # without replacing or submitting the restored unsent draft.
            screen.send("\x1bi")
            screen.until(lambda: "unavailable" not in screen.capture.completed
                         and all(value in screen.capture.completed for value in
                                 ("Copy last answer", "Model", "Folder", "gpt-6-luna")),
                         "ready chat info reads the relaunched Host")
            screen.contains("› conXversation β draft")
            screen.save(artifacts, "conversation-returned")
            # The draft/caret survived above. Clear it deliberately only now,
            # so Esc can leave; stored empty identity must outlive its row.
            screen.send("\x1b\x01\x0b\x1b")
            screen.empty_overview(c, session)
            screen.save(artifacts, "conversation-left-empty-hidden")
        after = c.json("session", "inspect", "--store", c.store, "--session", session)
        assert after["session"] == before["session"], "Upgrade submitted work or changed the open Session"
        assert (c.home / ".config/rui/codex.json").read_bytes() == credential


def escape_after_publication(root, binary, releases, artifacts):
    """Once publishing starts, Esc no longer cancels: it cannot roll back."""
    with case(root, binary, releases, "terminal-escape-after-publication") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = c.root / "after-publication.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(gate)
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.overview()
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


def terminal_download_failure(root, binary, releases, artifacts):
    """The visible settings field, status line and restored report share the cause."""
    with case(root, binary, releases, "terminal-download-failure") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        releases.status["/releases/latest"] = 403
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.overview()
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
    """A previous run's retained cancellation report prevents even a later
    successful installation from replacing this TUI or relaunching on quit."""
    with case(root, binary, releases, "terminal-cancellation-guidance") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        terminal_setup(c)
        gate = releases.gate_archive()
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.overview()
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
    """An installed release cannot swallow PATH advice by replacing the TUI."""
    with case(root, binary, releases, "terminal-path-guidance") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        shadow = c.build("shadowing-path", "0.1.0", managed=False) / "bin/rui"
        c.env["PATH"] = f"{shadow.parent}:{c.env['PATH']}"
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.overview()
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
    """Relaunch resumes existing work before fresh-Session admission, even
    after local setup or the saved Store changes underneath the old TUI."""
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
            # The resume entry is intentionally not a conversation opened by
            # Enter from a freshly admitted overview. Its startup tolerances
            # must survive the new process's bare relaunch entry.
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
                    # Mutate only after the old TUI has entered successfully.
                    # These are startup preconditions, not upgrade failures.
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
                        # proof_relaunched already observed the retained Footer reply.
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
            screen.overview()
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
            screen.overview()
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
    """Esc during the check cancels it, and its --version probe is reaped
    before release discovery starts."""
    with case(root, binary, releases, "selected-version-cancel-escape") as c:
        c.old_selection()
        host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = c.root / "selected-version.fifo"
        os.mkfifo(gate, mode=0o600)
        receipt = c.root / "selected-version.pid"
        # This is only the selected release's metadata/version fixture.
        # Its real runtime Host remains the separately copied native actor.
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
                screen.overview()
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
                    return False  # A zombie is not a reaped version child.

                wait_for(reaped, "cancelled exact selected --version child reap")
                assert releases.requests[start:] == [], "cancelled check reached latest discovery"
                assert c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            finally:
                # Failure disposal can unblock the child, but never supplies
                # credit before the cancellation/reap assertions above.
                dispose_all(release_version)


def terminal_cleanup_dual_failure(root, binary, releases, artifacts):
    """The status bar says the run failed; the retained cleanup path and both
    failures print once the terminal is restored."""
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
                screen.overview()
                screen.start_upgrade()
                screen.until(gate.entered.is_set, "real archive request after stage creation")
                stages = list(parent.glob("install.*"))
                assert len(stages) == 1 and stages[0].is_dir(), stages
                retained = stages[0]
                # The stage remains writable for curl, but its parent cannot
                # remove that directory after checksum validation rejects it.
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
                # Rui names the stage by its real path: macOS's temporary
                # directory sits under the /var -> /private/var link.
                assert os.fsencode(retained.resolve()) in receipt, ("restored output lost retained cleanup custody", receipt.decode())
                assert retained.is_dir() and c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
                if artifacts is not None:
                    (artifacts / "dual-failure-restored.txt").write_text(screen.capture.plain)
        finally:
            # Restore the real permission cut even when the body fails; neither
            # cleanup nor the next fixture may inherit the intended denial.
            dispose_all(lambda: parent.chmod(original_mode),
                        gate.release.set,
                        lambda: setattr(releases, "digest", original_digest))


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ("restart-all", "lifecycle", "custody", "terminal", "startup")):
        sys.exit("usage: python3 tests/integration/upgrade_integration.py PATH_TO_REAL_RUI [restart-all|lifecycle|custody|terminal|startup]")
    selection = sys.argv[2] if len(sys.argv) == 3 else "all"
    binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
    root = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-upgrade-"))
    version_home = root / "version-home"
    version_home.mkdir()
    version_output = subprocess.check_output([str(binary), "--version"],
        env={**os.environ, "HOME": str(version_home)}, text=True, timeout=5)
    match = re.match(r"rui (0\.[0-9]+\.[0-9]+) \(", version_output)
    assert match, "supply a native release-identity actor (production owners), not an unreleased build"
    version = match[1]
    configured_artifacts = os.environ.get("RUI_UPGRADE_FAILURES") or os.environ.get("RUI_FAILURE_ARTIFACTS")
    artifacts = pathlib.Path(configured_artifacts).resolve() if configured_artifacts else None
    if artifacts is not None:
        artifacts.mkdir(parents=True, exist_ok=True)
        assert not artifacts.is_relative_to(root), "artifacts must outlive fixture root"
    releases = Releases(binary, version)
    complete = False
    try:
        if selection in ("restart-all", "lifecycle"):
            suite = {"restart-all": restart_all_cases, "lifecycle": lifecycle_cases}[selection]
            suite(root, binary, releases)
            print(f"upgrade native: {suite.__name__} passed", flush=True)
            tool_custody_cases(root, binary, releases, "restart" if selection == "restart-all" else "upgrade")
        if selection == "custody":
            for operation in ("restart", "upgrade"):
                tool_custody_cases(root, binary, releases, operation)
                print(f"upgrade native: tool {operation} custody passed", flush=True)
        if selection == "all":
            for suite in (discovery_cases, install_cases, lifecycle_cases, restart_all_cases):
                suite(root, binary, releases)
                print(f"upgrade native: {suite.__name__} passed", flush=True)
            for operation in ("restart", "upgrade"):
                tool_custody_cases(root, binary, releases, operation)
                print(f"upgrade native: tool {operation} custody passed", flush=True)
        if selection in ("all", "terminal"):
            for suite in (terminal_download_failure, terminal_cases, conversation_case, escape_after_publication,
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
