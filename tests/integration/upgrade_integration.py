#!/usr/bin/env python3
"""Native, offline Upgrade evidence: python3 upgrade_integration.py REAL_RUI.

Release metadata, target version and archives may be synthetic. Only the
*selected old version* fixture is a --version-only script; every started Host
and every install target is the supplied real native executable. Retained-build paths, not invented
Host versions, exercise replacement of an already-running native Host.
"""
import contextlib
import hashlib
import http.server
import io
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
from terminal_process import COLUMNS, ROWS, terminal_process
from terminal_screen import ScreenCapture, shown


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
        self.metadata_change = None
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                # Capture the exact requested pinned path before releasing it.
                owner.requests.append(self.path)
                try:
                    if self.path in owner.gates:
                        owner.gates[self.path].hold()
                    status = owner.status.get(self.path, 200)
                    if self.path == "/latest":
                        body = json.dumps(owner.metadata()).encode()
                    elif self.path == owner.sums_path:
                        body = f"{owner.digest}  {owner.name}\n".encode()
                    elif self.path == owner.archive_path:
                        body = owner.archive
                    else:
                        status, body = 404, b"unexpected fixture endpoint"
                    self.send_response(status)
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

    def metadata(self):
        value = {"tag_name": f"v{self.version}", "draft": False, "prerelease": False,
                 "assets": [{"name": self.name, "browser_download_url": self.origin + self.archive_path},
                            {"name": "SHA256SUMS", "browser_download_url": self.origin + self.sums_path}]}
        if self.metadata_change:
            self.metadata_change(value)
        return value

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
                    "RUI_TEST_UPGRADE_API_URL": releases.origin + "/latest",
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

    def json(self, *args):
        result = subprocess.run([str(self.binary), *map(str, args)], env=self.env,
                                capture_output=True, text=True, timeout=25)
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
        process, ready = start_ready_process(
            [build / "bin/rui", "host", "serve", *destination,
             "--active-capacity", "2", "--provider", "codex", *extra], env=self.env)
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
            releases.metadata_change = None
        dispose_all(value.close, reset_publication)


def peer_pid(path):
    """Independent OS receipt of the exact listening native process."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
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
        assert "No Host was running" in output
        assert releases.requests[start:] == ["/latest", releases.sums_path]
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

    variants = {
        "draft": lambda m: m.update(draft=True),
        "prerelease": lambda m: m.update(prerelease=True),
        "malformed-version": lambda m: m.update(tag_name="v0.056.4"),
        "missing-assets": lambda m: m.update(assets=[]),
        "unpinned-assets": lambda m: m["assets"][0].update(browser_download_url=releases.origin + "/latest/archive"),
    }
    for name, change in variants.items():
        with case(root, binary, releases, name) as c:
            c.old_selection()
            releases.metadata_change = change
            result = subprocess.run([str(binary), "upgrade", "--check", "--store", str(c.store)],
                                    env=c.env, capture_output=True, text=True, timeout=15)
            assert result.returncode != 0, (name, result.stdout, result.stderr)
            c.assert_unchanged()
            c.assert_no_host()

    with case(root, binary, releases, "offline-discovery") as c:
        c.old_selection()
        # Bound local connection refusal; no DNS, external host or provider.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            c.env["RUI_TEST_UPGRADE_API_URL"] = f"http://127.0.0.1:{reserved.getsockname()[1]}/latest"
            child = c.spawn_upgrade()
            c.finish_upgrade(child, success=False)
        c.assert_unchanged()
        c.assert_no_host()


def install_cases(root, binary, releases):
    with case(root, binary, releases, "install-no-host") as c:
        c.old_selection()
        output = c.upgrade()
        assert "Installed Rui" in output and "no Host was initially running and none was started" in output, output
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
        wait_for(gate.entered.is_set, "pinned archive after metadata resolution")
        releases.metadata_change = lambda m: m.update(tag_name="v0.999.0")
        gate.release.set()
        output = c.finish_upgrade(child)
        assert "Installed Rui" in output, output
        assert releases.requests[start:] == ["/latest", releases.sums_path, releases.archive_path]
        assert subprocess.check_output([str(c.link), "--version"], env=c.env, text=True).startswith("rui " + releases.version)
        c.assert_no_host()

    with case(root, binary, releases, "newer-selected-no-downgrade") as c:
        c.select(c.build("synthetic-future-selected", "0.999.0"))
        output = c.upgrade()
        assert "Installation unchanged" in output and "No downgrade or restart occurred" in output, output
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
        # A second Store remains outside this Upgrade's lifecycle authority.
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
            assert "Installed Rui" in output and "Activation: ready;" in output, output
            proof_ready(c, previous, old_host)
            assert other_host.poll() is None and other.status()["instance"] == other_previous["instance"]
        finally:
            other.close()

    with case(root, binary, releases, "store-hex-host-restart") as c:
        c.old_selection()
        old_host, previous = c.start_host(store_hex=True)
        output = c.upgrade()
        assert "Installed Rui" in output and "Activation: ready;" in output, output
        proof_ready(c, previous, old_host)

    with case(root, binary, releases, "relative-launch-path-not-restarted") as c:
        c.old_selection()
        relative_bash = os.path.relpath("/bin/bash", pathlib.Path.cwd())
        old_host, previous = c.start_host(extra=("--bash-path", relative_bash))
        output = c.finish_upgrade(c.spawn_upgrade(), success=False)
        assert "Installed Rui" in output and "existing Host was left running" in output, output
        assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
        assert os_semantics.process_executable(old_host.pid) != c.link.resolve()

    with case(root, binary, releases, "same-release-older-retained-host") as c:
        c.select(c.build("selected-real-current"))
        old_host, previous = c.start_host()
        start = len(releases.requests)
        output = c.upgrade()
        assert "Installation unchanged" in output and "Activation: ready;" in output, output
        assert releases.archive_path not in releases.requests[start:]
        proof_ready(c, previous, old_host)
        ready = c.status()
        output = c.upgrade()
        assert "already running the selected pinned build" in output, output
        assert c.status()["instance"] == ready["instance"]

    with case(root, binary, releases, "retained-tagged-source-host") as c:
        c.old_selection()
        host, previous = c.start_host(source=True)
        output = c.finish_upgrade(c.spawn_upgrade(), success=False)
        assert "Installed Rui" in output and "existing Host was left running" in output, output
        assert host.poll() is None and c.status()["instance"] == previous["instance"]
        assert os_semantics.process_executable(host.pid) != c.link.resolve()

    with case(root, binary, releases, "application-owned-host") as c:
        c.old_selection()
        host, previous = c.start_host(managed=False)
        output = c.finish_upgrade(c.spawn_upgrade(), success=False)
        assert "Installed Rui" in output and "existing Host was left running" in output, output
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
        output = c.finish_upgrade(child, success=False)
        assert "Installed Rui" in output and "another Host instance owns this Store" in output, output
        assert replacement.poll() is None and c.status()["instance"] == current["instance"]
        assert os_semantics.process_executable(replacement.pid) != c.link.resolve()


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
        assert "Installed Rui" in output and "Activation: unconfirmed" in output, output
        assert "release remains installed" in output and "failed before publication" not in output, output
        assert c.link.is_symlink() and os.readlink(c.link) == str(installed)
        assert host.poll() is None and c.status()["instance"] == previous["instance"]


class TerminalScreen:
    """Borrow the repository's committed screen observer, not text scraping."""

    def __init__(self, master, process):
        self.master, self.process = master, process
        self.capture = ScreenCapture(COLUMNS, ROWS)
        self.tail = bytearray()
        os.set_blocking(master, False)

    def read_output(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            data = b""
        if data:
            self.capture.feed(data)
            self.tail.extend(data)
            del self.tail[:-16384]

    def observe(self):
        self.read_output()
        assert self.process.poll() is None, (self.process.returncode, self.capture.completed)
        return self.capture.completed

    def contains(self, marker):
        return wait_for(self.observe, f"terminal screen: {marker}", timeout=15,
                        ready=lambda screen: shown(marker, screen))

    def until(self, predicate, description):
        # Keep draining the real PTY while waiting for a nonterminal effect;
        # Darwin's small PTY output queue is not a background log sink.
        return wait_for(self.observe, description, timeout=15, ready=lambda _: predicate())

    def send(self, text):
        os.write(self.master, text.encode())

    def save(self, destination, name):
        if destination is not None:
            (destination / f"{name}.txt").write_text(self.capture.completed + "\n")


def terminal_setup(c):
    # Reuse the existing synthetic credential authority; never inspect the
    # caller's HOME, real credentials or a live provider endpoint.
    from codex_integration import credentials
    directory = c.home / ".config/rui"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    credential = directory / "codex.json"
    credentials(credential)
    c.run("defaults", "configure", "--provider", "codex", "--model", "gpt-6-luna")
    configured = c.json("session", "configure", "--store", c.store,
        "--workspace", c.root, "--provider", "codex", "--model", "gpt-6-luna")
    return configured["answer"]["session"], credential.read_bytes()


def terminal_cases(root, binary, releases, artifacts):
    for entry in ("overview", "conversation"):
        prompt = " › " if entry == "overview" else "› "
        with case(root, binary, releases, f"terminal-{entry}") as c:
            c.old_selection()
            old_host, previous = c.start_host()
            session, credential = terminal_setup(c)
            before = c.json("session", "inspect", "--store", c.store, "--session", session)
            request_directory = c.home / ".config/rui/requests"
            captures = {p.name: p.read_bytes() for p in request_directory.glob("*.json")}
            args = ([str(binary), "--store", str(c.store), "--provider", "codex", "--model", "gpt-6-luna"]
                    if entry == "overview" else [str(binary), "session", "resume", "--store", str(c.store), "--", session])
            gate = releases.gate_archive()
            with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
                screen = TerminalScreen(master, process)
                screen.contains("›")
                screen.send("/upgrade\r")
                screen.contains("enter Install")
                screen.save(artifacts, f"{entry}-offer")
                assert c.link.resolve() == c.original and c.status()["instance"] == previous["instance"]
                screen.send("\r")
                screen.until(gate.entered.is_set, "terminal installation archive gate")
                screen.contains("preparing")
                # Escape must interrupt the running task, not send a Message or
                # wait for the server to finish downloading the archive.
                screen.send("\x1b")
                wait_for(screen.observe, "cancelled terminal preparation", timeout=15,
                         ready=lambda text: "enter Install" in text or "Upgrade closed" in text or "Cancelled" in text)
                gate.release.set()
                c.assert_unchanged()
                assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
                # Reopen explicitly; no automatic retry or uncertain replay.
                screen.send("\x1b")
                screen.contains("›")
                wait_for(screen.observe, "retained /upgrade draft after cancellation",
                         ready=lambda _: screen.capture.draft("/upgrade", len(prompt) + 8, prompt=prompt))
                screen.send("\x15/upgrade\r")
                screen.contains("enter Install")
                screen.send("\r")
                screen.contains("Activation: ready;")
                screen.save(artifacts, f"{entry}-installed")
                proof_ready(c, previous, old_host)
                screen.send("\x1b")
                screen.contains("›")
                wait_for(screen.observe, "retained /upgrade draft after installation",
                         ready=lambda _: screen.capture.draft("/upgrade", len(prompt) + 8, prompt=prompt))
                screen.send("\x15unsent fixture draft")
                screen.contains("unsent fixture draft")
                screen.save(artifacts, f"{entry}-returned")
            after = c.json("session", "inspect", "--store", c.store, "--session", session)
            assert after["session"] == before["session"], "Upgrade submitted work or changed selected Session"
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            assert {p.name: p.read_bytes() for p in request_directory.glob("*.json")} == captures, "local Upgrade captured a Host command"


def cancel_after_publication(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-cancel-after-publication") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        session, credential = terminal_setup(c)
        gate = c.root / "after-publication.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(gate)
        args = [str(binary), "session", "resume", "--store", str(c.store), "--", session]
        with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
            screen = TerminalScreen(master, process)
            screen.contains("›")
            screen.send("/upgrade\r")
            screen.contains("enter Install")
            screen.send("\r")
            screen.until(lambda: c.link.resolve() != c.original, "publication before terminal cancellation")
            installed = c.link.resolve()
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            screen.send("\x1b")
            screen.contains("cancelled after installation; publication was not rolled back")
            screen.save(artifacts, "cancel-after-publication")
            assert c.link.resolve() == installed and installed.exists()
            assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            gate.unlink()


def signal_during_check(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-signal-during-check") as c:
        c.old_selection()
        host, previous = c.start_host()
        session, credential = terminal_setup(c)
        gate = releases.gates["/latest"] = Gate()
        args = [str(binary), "session", "resume", "--store", str(c.store), "--", session]
        with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
            screen = TerminalScreen(master, process)
            screen.contains("›")
            screen.send("/upgrade\r")
            screen.until(gate.entered.is_set, "metadata check held before terminal signal")
            screen.contains("Read-only check")
            screen.save(artifacts, "signal-during-check")
            process.send_signal(signal.SIGINT)

            def exited():
                screen.read_output()
                return process.poll() is not None

            wait_for(exited, "terminal restoration and exit during held upgrade check")
            assert not gate.release.is_set(), "terminal required metadata peer release before exiting"
            assert b"\x1b[?1049l" in screen.tail, "alternate screen not restored on signal"
            assert b"\x1b[?25h" in screen.tail, "cursor not restored on signal"
            c.assert_unchanged()
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential



def signal_after_publication(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-signal-after-publication") as c:
        c.old_selection()
        host, previous = c.start_host()
        session, credential = terminal_setup(c)
        gate = c.root / "after-publication.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(gate)
        args = [str(binary), "session", "resume", "--store", str(c.store), "--", session]
        with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
            screen = TerminalScreen(master, process)
            screen.contains("›")
            screen.send("/upgrade\r")
            screen.contains("enter Install")
            screen.send("\r")
            screen.until(lambda: c.link.resolve() != c.original, "publication before SIGINT")
            installed = c.link.resolve()
            assert installed.exists() and gate.exists()
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            process.send_signal(signal.SIGINT)

            def exited():
                screen.read_output()
                return process.poll() is not None

            wait_for(exited, "joined publication receipt and terminal exit after SIGINT")
            output = bytes(screen.tail)
            restored = output.rfind(b"\x1b[?1049l")
            receipt = output.find(b"Installed Rui. Complete build:")
            assert restored >= 0, "SIGINT after publication did not restore the terminal"
            assert receipt > restored, ("joined installation receipt was lost after interruption", output.decode())
            assert b"cancelled after installation; publication was not rolled back" in output, output.decode()
            assert os.fsencode(installed.parent.parent) in output, "receipt lost the published build identity"
            assert gate.exists(), "signal exit required releasing the post-publication gate"
            assert c.link.resolve() == installed and installed.exists(), "signal rolled back publication"
            assert host.poll() is None and c.status()["instance"] == previous["instance"]
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            if artifacts is not None:
                (artifacts / "signal-after-publication.txt").write_text(screen.capture.plain)



def cancel_selected_version_check(root, binary, releases, artifacts):
    """Cancel the selected build probe itself, before release discovery starts."""
    for action in ("escape", "sigint"):
        with case(root, binary, releases, f"selected-version-cancel-{action}") as c:
            c.old_selection()
            host, previous = c.start_host()
            session, credential = terminal_setup(c)
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
            args = [str(binary), "session", "resume", "--store", str(c.store), "--", session]

            def release_version():
                descriptor = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
                try:
                    os.write(descriptor, b"continue\n")
                finally:
                    os.close(descriptor)

            with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
                try:
                    screen = TerminalScreen(master, process)
                    screen.contains("›")
                    screen.send("/upgrade\r")

                    def child_started():
                        if not receipt.exists():
                            return False
                        return receipt.read_text().strip().isdigit()

                    screen.until(child_started, "selected --version child receipt before discovery")
                    child_pid = int(receipt.read_text().strip())
                    running = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                             env=c.env, capture_output=True, text=True, timeout=5)
                    assert running.returncode == 0 and not running.stdout.strip().startswith("Z"), running
                    assert releases.requests[start:] == [], "latest discovery ran before selected probe completed"
                    if action == "escape":
                        screen.send("\x1b")
                        screen.contains("Upgrade check failed: Cancelled")
                        screen.save(artifacts, "selected-version-escape")
                    else:
                        process.send_signal(signal.SIGINT)

                        def exited():
                            screen.read_output()
                            return process.poll() is not None

                        wait_for(exited, "SIGINT exit while selected version child is gated")
                        assert b"\x1b[?1049l" in screen.tail, "selected-probe signal did not restore terminal"
                        if artifacts is not None:
                            (artifacts / "selected-version-sigint.txt").write_text(screen.capture.plain)

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
    with case(root, binary, releases, "terminal-dual-failure") as c:
        c.old_selection()
        host, previous = c.start_host()
        session, credential = terminal_setup(c)
        parent = c.home / ".local/lib/rui"
        original_mode = stat.S_IMODE(parent.stat().st_mode)
        original_digest = releases.digest
        releases.digest = "0" * 64
        gate = releases.gate_archive()
        args = [str(binary), "session", "resume", "--store", str(c.store), "--", session]
        try:
            with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
                screen = TerminalScreen(master, process)
                screen.contains("›")
                screen.send("/upgrade\r")
                screen.contains("enter Install")
                screen.send("\r")
                screen.until(gate.entered.is_set, "real archive request after stage creation")
                stages = list(parent.glob("install.*"))
                assert len(stages) == 1 and stages[0].is_dir(), stages
                retained = stages[0]
                # The stage remains writable for curl, but its parent cannot
                # remove that directory after checksum validation rejects it.
                parent.chmod(0o500)
                gate.release.set()
                screen.contains("Upgrade result")
                # Check details can occupy the initial viewport; the retained
                # receipt must remain reachable through the panel's real scroll.
                screen.send("\x1b[6~")
                panel = screen.contains("cleanup also failed (AccessDenied)")
                assert shown("installation failed (ReleaseChecksumMismatch)", panel), panel
                assert shown(str(retained), panel), ("panel lost retained cleanup custody", panel)
                assert retained.is_dir(), "cleanup receipt did not identify an existing retained stage"
                assert c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                screen.save(artifacts, "dual-failure-panel")
                process.send_signal(signal.SIGINT)

                def exited():
                    screen.read_output()
                    return process.poll() is not None

                wait_for(exited, "restored primary and retained cleanup receipt after SIGINT")
                output = bytes(screen.tail)
                restored = output.rfind(b"\x1b[?1049l")
                assert restored >= 0, "dual-failure SIGINT did not restore the terminal"
                receipt = output[restored:]
                assert b"installation failed (ReleaseChecksumMismatch)" in receipt, receipt.decode()
                assert b"cleanup also failed (AccessDenied)" in receipt, receipt.decode()
                assert os.fsencode(retained) in receipt, ("restored output lost retained cleanup custody", receipt.decode())
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



def stop_tmux(base, env, server_pid):
    """Retire this fixture's observed server; unsuccessful kills are not success."""
    result = subprocess.run([*base, "kill-server"], env=env, capture_output=True,
                            text=True, timeout=5)
    assert server_pid is not None, ("tmux server identity was not observed; disposal unconfirmed", result)

    def retired():
        observed = subprocess.run(["ps", "-p", str(server_pid), "-o", "stat="],
                                  env=env, capture_output=True, text=True, timeout=5)
        if observed.returncode == 1 and not observed.stdout and not observed.stderr:
            return True  # The independently observed server PID is absent.
        assert observed.returncode == 0 and observed.stdout.strip(), ("tmux server census failed", observed)
        # An exited orphan may await its OS reaper but owns no live resources.
        return observed.stdout.strip().startswith("Z")

    if result.returncode != 0:
        assert retired(), ("tmux kill-server failed with a live server", result)
    else:
        wait_for(retired, "exact tmux server retirement")


def tmux_cases(root, binary, releases, artifacts):
    """Real tmux cells supplement, rather than replace, PTY process evidence."""
    tmux = shutil.which("tmux")
    assert tmux is not None, "native terminal evidence requires real tmux"
    for entry in ("overview", "conversation"):
        with case(root, binary, releases, f"tmux-{entry}") as c:
            c.old_selection()
            old_host, previous = c.start_host()
            session, credential = terminal_setup(c)
            before = c.json("session", "inspect", "--store", c.store, "--session", session)
            request_directory = c.home / ".config/rui/requests"
            captures = {p.name: p.read_bytes() for p in request_directory.glob("*.json")}
            socket_path = root / "tmux.sock"
            base = [tmux, "-S", str(socket_path), "-f", "/dev/null"]

            def command(*args):
                result = subprocess.run([*base, *args], env=c.env, capture_output=True,
                                        text=True, timeout=5)
                assert result.returncode == 0, (args, result.stdout, result.stderr)
                return result.stdout

            def capture():
                return command("capture-pane", "-p", "-t", "upgrade:0.0")

            def reached(marker):
                return wait_for(capture, f"real tmux screen: {marker}", timeout=15,
                                ready=lambda text: shown(marker, text))

            def save(name, text):
                if artifacts is not None:
                    (artifacts / f"tmux-{entry}-{name}.txt").write_text(text)

            args = ([str(binary), "--store", str(c.store), "--provider", "codex", "--model", "gpt-6-luna"]
                    if entry == "overview" else [str(binary), "session", "resume", "--store", str(c.store), "--", session])
            server_pid = None
            try:
                command("new-session", "-d", "-x", str(COLUMNS), "-y", str(ROWS),
                        "-s", "upgrade", "-c", str(c.root), "exec " + shlex.join(args))
                server_pid = int(command("display-message", "-p", "#{pid}").strip())
                assert server_pid > 0
                reached("›")
                command("send-keys", "-t", "upgrade:0.0", "-l", "/upgrade")
                command("send-keys", "-t", "upgrade:0.0", "Enter")
                offer = reached("enter Install")
                save("offer", offer)
                assert c.link.resolve() == c.original
                command("send-keys", "-t", "upgrade:0.0", "Enter")
                installed = reached("Activation: ready;")
                save("installed", installed)
                proof_ready(c, previous, old_host)
                command("send-keys", "-t", "upgrade:0.0", "Escape")
                reached("›")
                assert "/upgrade" in reached("› /upgrade")
                command("send-keys", "-t", "upgrade:0.0", "C-u")
                command("send-keys", "-t", "upgrade:0.0", "-l", "unsent tmux draft")
                save("returned", reached("unsent tmux draft"))
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            finally:
                dispose_all(lambda: stop_tmux(base, c.env, server_pid))
            assert c.json("session", "inspect", "--store", c.store, "--session", session)["session"] == before["session"]
            assert {p.name: p.read_bytes() for p in request_directory.glob("*.json")} == captures



def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 tests/integration/upgrade_integration.py PATH_TO_REAL_RUI")
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
        for suite in (discovery_cases, install_cases, lifecycle_cases):
            suite(root, binary, releases)
            print(f"upgrade native: {suite.__name__} passed", flush=True)
        cancel_selected_version_check(root, binary, releases, artifacts)
        print("upgrade native: Escape and SIGINT reaped selected version probes before discovery", flush=True)
        terminal_cases(root, binary, releases, artifacts)
        print("upgrade native: both terminal /upgrade entry points passed", flush=True)
        cancel_after_publication(root, binary, releases, artifacts)
        print("upgrade native: cancellation after publication preserved installation and Host", flush=True)
        terminal_cleanup_dual_failure(root, binary, releases, artifacts)
        print("upgrade native: real checksum/cleanup dual failure retained panel and restored custody", flush=True)
        signal_after_publication(root, binary, releases, artifacts)
        print("upgrade native: SIGINT after publication preserved and reported the installed receipt", flush=True)
        signal_during_check(root, binary, releases, artifacts)
        print("upgrade native: terminal signal restored during held release check", flush=True)
        tmux_cases(root, binary, releases, artifacts)
        print("upgrade native: both real tmux /upgrade captures passed", flush=True)
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
