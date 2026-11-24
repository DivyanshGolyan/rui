#!/usr/bin/env python3
import contextlib
import errno
import functools
import hashlib
import http.server
import itertools
import json
import os
import pathlib
import re
import secrets
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote

import live_engines
import settings_fixture
from terminal_screen import split_pane_row

import host_process
import os_semantics
from host_process import canonical_fixture_root, dispose_all, start_ready_process, stop_process, wait_for
from terminal_process import COLUMNS, ROWS, answers_to, terminal_process
from terminal_screen import ScreenCapture, shown
from upgrade_fixture import Gate, Releases


terminal_process = functools.partial(terminal_process, eof=True)
TERMINAL_COLUMNS = max(COLUMNS, 140)


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
# Each redirect hop is its own attempt: one redirect_url probe with no --location.
redirect_hop = "%{redirect_url}" in args
assert ("--location" in args) != redirect_hop, args
assert args[args.index("--proto-redir") + 1] == ("=http" if redirect_hop else "=https"), args
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
        self.root.mkdir(mode=0o700)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
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

    def build(self, name, version=None, *, managed=True, native=None):
        # Cases can share HOME to exercise a whole-Host batch. Retained
        # artifacts still belong to each Case, not to that shared installation
        # selector. Keep one managed leaf (the production ownership shape).
        owner = hashlib.sha256(os.fsencode(self.root)).hexdigest()[:16]
        build = self.home / ".local/lib/rui" / f"{owner}-{name}" if managed else self.root / name
        # Never reuse an installation or overwrite an executable of a live Host.
        (build / "bin").mkdir(parents=True)
        executable = build / "bin/rui"
        if version is None:
            shutil.copy2(self.binary if native is None else native, executable)
        else:
            executable.write_text(f"#!/bin/sh\n[ \"$1\" = --version ] || exit 91\nprintf '%s\\n' 'rui {version} (synthetic metadata fixture)'\n")
            executable.chmod(0o755)
        (build / "THIRD_PARTY_NOTICES.md").write_text("Synthetic fixture build\n")
        return build

    def select(self, build, *, source=False):
        self.run("--publish-install", self.home, build, "intentional-source" if source else "released-install")
        assert self.link.resolve() == build / "bin/rui"
        self.original = self.link.resolve()

    def old_selection(self):
        self.select(self.build("synthetic-selected-old", "0.1.0"))

    def start_host(self, name="retained-real-host", *, managed=True, store_hex=False, extra=(), sources_only=False, source=False, native=None):
        build = self.build(name, managed=managed, native=native)
        if source:
            (build / "revision").write_text("synthetic-source-revision-marker\n")
        destination = ["--store-hex", os.fsencode(self.store).hex()] if store_hex else ["--store", self.store]
        provider = [] if any(str(value).startswith("providers.") or str(value).startswith("providers=") for value in extra) else ["--set", 'providers={"codex":{}}']
        defaults = [] if sources_only else ["--set", 'execution.activeCapacity=2', *provider]
        process, ready = start_ready_process(
            [build / "bin/rui", "host", "serve", *destination, *defaults, *extra], env=self.env, isolate_settings=not sources_only)
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
    complete = False
    try:
        yield value
        complete = True
    finally:
        for gate in releases.gates.values():
            gate.release.set()
        def reset_publication():
            releases.gates.clear()
            releases.status.clear()
            releases.latest_location = None
            releases.sums_name = None
        dispose_all(value.close, reset_publication)
        # Bound disk lifetime to the case, like process lifetime. Keep the
        # failed case (including cleanup failures) for diagnosis, not every
        # successfully retired installation from the preceding matrices.
        if complete:
            shutil.rmtree(value.root)


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
        assert releases.requests[start:] == ["/releases/latest", "/releases/redirect", releases.sums_path]
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

    with case(root, binary, releases, "malformed-version") as c:
        c.old_selection()
        releases.latest_location = releases.origin + "/releases/tag/v0.056.4"
        releases.status["/releases/tag/v0.056.4"] = 200
        result = c.upgrade("--check", expect=6)
        assert "upgrade_release_invalid" in result, result
        c.assert_unchanged()
        c.assert_no_host()

    with case(root, binary, releases, "download-403-latest") as c:
        c.old_selection()
        releases.status["/releases/latest"] = 403
        output = c.upgrade("--check", expect=6)
        assert "upgrade_download_failed" in output, output
        assert "curl: (22)" in output and "403" in output, output
        assert "upgrade_preparation_failed" not in output, output
        c.assert_unchanged()
        c.assert_no_host()


def read_until(stream, text, what, timeout=10):
    """Read a live child's pipe until `text` arrives; return what was read.

    Reads the raw descriptor, so a later communicate() continues after it."""
    deadline = time.monotonic() + timeout
    seen = b""
    while text.encode() not in seen:
        remaining = deadline - time.monotonic()
        assert remaining > 0, (f"timed out waiting for {what}", seen.decode(errors="replace"))
        ready, _, _ = select.select([stream.fileno()], [], [], remaining)
        if ready:
            chunk = os.read(stream.fileno(), 65536)
            assert chunk, (f"output ended before {what}", seen.decode(errors="replace"))
            seen += chunk
    return seen.decode()


def install_cases(root, binary, releases):
    with case(root, binary, releases, "install-pinned-no-host") as c:
        # The release is resolved once: a later change of latest cannot
        # change what is installed. A second run downloads nothing.
        c.old_selection()
        gate = releases.gate_archive()
        start = len(releases.requests)
        child = c.spawn_upgrade()
        wait_for(gate.entered.is_set, "pinned archive after release resolution")
        # #1854: the installing line reaches the reader while the download is still held.
        early = read_until(child.stdout, f"Installing Rui {releases.version}...", "installing line during the download")
        releases.latest_location = releases.origin + "/releases/tag/v0.999.0"
        gate.release.set()
        output = early + c.finish_upgrade(child)
        releases.latest_location = None
        assert "Upgraded to Rui" in output and "No running Hosts." in output, output
        # #1854: the check report, then what is happening, then the verdict.
        check_end = output.index("The running client and bundled/custom application binaries are not replaced.")
        installing = output.index(f"Installing Rui {releases.version}...")
        verdict = output.index(f"Upgraded to Rui {releases.version}. Complete build: ")
        assert check_end < installing < verdict, output
        assert releases.requests[start:] == ["/releases/latest", "/releases/redirect", releases.sums_path, releases.archive_path]
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

    with case(root, binary, releases, "download-failure") as c:
        c.old_selection()
        host, previous = c.start_host()
        releases.status[releases.archive_path] = 503
        child = c.spawn_upgrade()
        output = c.finish_upgrade(child, success=False)
        assert "Upgraded to Rui" not in output, output
        c.assert_unchanged()
        assert host.poll() is None and c.status()["instance"] == previous["instance"]


def frozen_upgrade_cases(root, binary, releases):
    """Later admission reads B; after retirement only checked B reaches start.

    The restart is `host restart --all` onto a selected real build: the same
    coordinator and activation path Upgrade takes after publication, without
    installing a release."""
    none = {"codex": "unserved", "openai": "unserved", "chatgpt": "unserved"}
    exact = {"openai": {"endpoint": "http://127.0.0.1:9/v1/responses", "unauthenticated": True}}

    def save(path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    for source_kind, mutation in (("saved", "changed"), ("file", "malformed"), ("assignment-file", "removed")):
        with contextlib.ExitStack() as interfaces, case(root, binary, releases, f"frozen-upgrade-{source_kind}") as c:
            runtime = interfaces.enter_context(host_process.short_interface_directory())
            c.store.mkdir(mode=0o700)
            saved = c.store / "host.json"
            placement = {"interface": {"dir": str(runtime)}, "providers": {}}
            save(saved, placement)
            retained = c.build("retained-frozen-source")
            c.binary = retained / "bin/rui"
            c.ready = {"socket": str(runtime / "rui.sock")}
            arguments = []
            if source_kind == "saved":
                source = saved
                admitted_a = {**placement, "execution": {"paused": False, "activeCapacity": 2}}
            elif source_kind == "file":
                source = c.root / "settings.json"
                admitted_a = {"providers": {}, "execution": {"paused": False, "activeCapacity": 2}}
                arguments = ["--settings", source]
            else:
                source = c.root / "execution.json"
                admitted_a = {"paused": False, "activeCapacity": 2}
                arguments = ["--set", f"execution=@{source}"]
            save(source, admitted_a)
            # Exercise the existing public detached starter, not foreground
            # serve: the observed child carries consumed private-fd provenance.
            started = c.json("host", "start", "--store", c.store, *arguments)
            previous = c.status()
            old_pid = peer_pid(c.ready["socket"])
            assert started["instance"] == previous["instance"] and previous["paused"] is False, previous
            assert previous["active_capacity"] == "2" and previous["capabilities"]["providers"] == none, previous
            assert os_semantics.process_executable(old_pid) == retained / "bin/rui"

            admitted_b = json.loads(json.dumps(admitted_a))
            execution_b = admitted_b if source_kind == "assignment-file" else admitted_b["execution"]
            execution_b.update(paused=True, activeCapacity=7)
            if source_kind != "assignment-file":
                admitted_b["providers"] = exact
            save(source, admitted_b)
            # Editing a source changes next admission, never the live A Host.
            assert c.status()["instance"] == previous["instance"] and c.status()["paused"] is False
            expected_providers = none if source_kind == "assignment-file" else {**none, "openai": "endpoint"}
            c.select(c.build("frozen-restart-target"))
            gate = c.root / "checked-before-start.gate"
            gate.touch(mode=0o600)
            c.env["RUI_TEST_UPGRADE_BEFORE_START_GATE"] = str(gate)
            restart = subprocess.Popen([str(c.binary), "host", "restart", "--all"], env=c.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            c.children.append(restart)
            try:
                def checked_and_retired():
                    if restart.poll() is not None:
                        output, diagnostic = restart.communicate(timeout=3)
                        raise AssertionError(("restart exited before checked-frame retirement gate", restart.returncode,
                                              output, diagnostic))
                    return gate.with_name(gate.name + ".entered").exists()

                wait_for(checked_and_retired, "target admitted B and old frozen-source Host retired", timeout=30)
                assert gate.exists() and restart.poll() is None
                assert old_pid not in os_semantics.processes_executing(retained / "bin/rui")
                assert c.status()["status"] == "unavailable"
                if mutation == "changed":
                    admitted_c = json.loads(json.dumps(admitted_a))
                    admitted_c["execution"]["activeCapacity"] = 11
                    save(source, admitted_c)
                elif mutation == "malformed":
                    source.write_text("{malformed-after-check")
                else:
                    source.unlink()
                assert gate.exists() and restart.poll() is None
            finally:
                gate.unlink(missing_ok=True)
            output = c.finish_upgrade(restart)
            assert f"{c.store}: restarted on " in output and "1 restarted" in output, output
            # C remains in place through full verification. Malformed/deleted
            # C is an explicit source, not the saved DIR locator; no locator
            # restoration or alternate verification route hides a failure.
            direct = settings_fixture.host_info(runtime / "rui.sock", str(c.store))
            current = c.status()
            for facts in (direct, current):
                assert facts["instance"] != previous["instance"] and facts["paused"] is True, (source_kind, facts)
                assert facts["active_capacity"] == "2", "observed active capacity is projected last"
                assert facts["capabilities"]["providers"] == expected_providers, facts
                assert facts["store"] == previous["store"], facts
            assert direct["instance"] == current["instance"]
            assert os_semantics.process_executable(peer_pid(c.ready["socket"])) == c.link.resolve()
            if mutation == "malformed":
                assert source.read_text() == "{malformed-after-check"
            elif mutation == "removed":
                assert not source.exists()
            else:
                assert json.loads(source.read_text()) == admitted_c
                # A subsequent deliberate restart rereads C as NEW intent;
                # neither the original A nor consumed checked B is a registry.
                next_target = c.build("next-intent-target")
                (next_target / "revision").write_text("frozen-next-admission-source\n")
                c.select(next_target, source=True)
                next_output = c.run("host", "restart", "--all", timeout=60)
                assert "1 restarted" in next_output, next_output
                next_status = c.status()
                assert next_status["instance"] != current["instance"] and next_status["paused"] is False, next_status
                assert next_status["active_capacity"] == "2" and next_status["capabilities"]["providers"] == none, next_status
            print(f"upgrade native: frozen {source_kind} A -> new checked B -> {mutation} C consumed B; full verification passed", flush=True)


def frozen_credential_refusal_case(root, binary, releases):
    """Reference selection freezes; later credential contents still resolve."""
    with contextlib.ExitStack() as interfaces, case(root, binary, releases, "frozen-child-credential-refusal") as c:
        runtime = interfaces.enter_context(host_process.short_interface_directory())
        c.store.mkdir(mode=0o700)
        key_file = c.root / "private-openai.key"
        test_key = "sk-native-frozen-reference-test-key"
        key_file.write_text(test_key + "\n")
        key_file.chmod(0o600)
        saved = c.store / "host.json"
        # HTTPS loopback satisfies normal credential endpoint admission; no
        # unauthenticated/fixture bypass can skip resolving this selected file.
        saved.write_text(json.dumps({"interface": {"dir": str(runtime)},
                                     "execution": {"activeCapacity": 2},
                                     "providers": {"openai": {"endpoint": "https://127.0.0.1:9/v1/responses",
                                                               "key": {"file": str(key_file)}}}}))
        saved.chmod(0o600)
        old, previous = c.start_host(sources_only=True)
        assert previous["capabilities"]["providers"]["openai"] == "key_file", previous
        assert test_key not in os_semantics.process_environment(old.pid, env=c.env)
        c.select(c.build("checked-credential-target"))
        gate = c.root / "credential-after-check.gate"
        gate.touch(mode=0o600)
        c.env["RUI_TEST_UPGRADE_BEFORE_START_GATE"] = str(gate)
        restart = subprocess.Popen([str(c.binary), "host", "restart", "--all"], env=c.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        c.children.append(restart)
        try:
            def checked_and_retired():
                if restart.poll() is not None:
                    output, diagnostic = restart.communicate(timeout=3)
                    raise AssertionError(("credential target failed before successful check/retirement", restart.returncode,
                                          output, diagnostic))
                return gate.with_name(gate.name + ".entered").exists()

            wait_for(checked_and_retired, "valid key source checked before old Host retirement", timeout=20)
            assert gate.exists() and restart.poll() is None
            assert key_file.read_text() == test_key + "\n", "referenced key changed before the post-check interposition"
            assert old.poll() is not None and c.status()["status"] == "unavailable"
            # Only reference contents change. The checked source document and
            # its immutable private frame never contain the resolved test key.
            key_file.unlink()
            assert test_key not in saved.read_text()
        finally:
            gate.unlink(missing_ok=True)
        output, diagnostic = restart.communicate(timeout=30)
        combined = output + diagnostic
        assert restart.returncode == 6, (restart.returncode, output, diagnostic)
        assert f"{c.store}: refused at starting" in output, combined
        assert "failed at starting" not in output and "0 restarted" in output and "1 failed" in output, combined
        failures = [json.loads(line)["rui_start_error"] for line in output.splitlines()
                    if line.startswith('{"rui_start_error":')]
        assert failures == [{"code": "settings_invalid",
                             "message": f"providers.openai.key: file {key_file} does not exist"}], combined
        assert test_key not in combined, "a child-only refusal exposed resolved credential bytes"
        assert not key_file.exists() and c.status()["status"] == "unavailable"
        print("upgrade native: checked credential reference survives stop, missing child file preserves exact typed starting refusal", flush=True)


def pre_freeze_target_case(root, binary, releases, pre_freeze_binary):
    """An actual earlier native target's public check is not frame capability."""
    with contextlib.ExitStack() as interfaces, case(root, binary, releases, "actual-pre-freeze-target") as c:
        runtime = interfaces.enter_context(host_process.short_interface_directory())
        c.store.mkdir(mode=0o700)
        saved = c.store / "host.json"
        saved.write_text(json.dumps({"interface": {"dir": str(runtime)}, "providers": {},
                                     "execution": {"activeCapacity": 2}}))
        saved.chmod(0o600)
        # Both running Host and selected target use the actual old artifact.
        # Otherwise a newer coordinator version can trigger no-downgrade before
        # the capability precondition this witness is intended to exercise.
        old, previous = c.start_host(sources_only=True, native=pre_freeze_binary)
        target = c.build("actual-pre-freeze-build")
        shutil.copy2(pre_freeze_binary, target / "bin/rui")
        public_check = subprocess.run([target / "bin/rui", "host", "settings", "--check", "--store", c.store],
                                      env=c.env, capture_output=True, text=True, timeout=30)
        assert public_check.returncode == 0, (public_check.returncode, public_check.stdout, public_check.stderr)
        c.select(target)
        # Keep the CURRENT coordinator; the selected target is deliberately old.
        gate = c.root / "must-not-stop.gate"
        gate.touch(mode=0o600)
        c.env["RUI_TEST_UPGRADE_BEFORE_START_GATE"] = str(gate)
        try:
            output = c.run("host", "restart", "--all", timeout=60)
            assert "left running" in output and "target build cannot safely check" in output, output
            assert not gate.with_name(gate.name + ".entered").exists(), "unsupported target reached the post-stop boundary"
            assert old.poll() is None and peer_pid(c.ready["socket"]) == old.pid
            assert c.status()["instance"] == previous["instance"], output
        finally:
            gate.unlink(missing_ok=True)
        print("upgrade native: actual pre-1480 public-check-capable target refused before stop; old PID/instance unchanged", flush=True)


class BusyEndpoint:
    """A derived interface directory a live Host holds: its flock on D, and a listener at rui.sock that never accepts."""

    def __init__(self, directory):
        self.directory = directory
        self.socket = directory / "rui.sock"
        self._lock = None
        self._listener = None

    def hold(self):
        self._lock = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        assert os_semantics.try_lock(self._lock), "a fresh interface directory is already locked"
        self._listener = os_semantics.unix_stream()
        self._listener.bind(str(self.socket))
        # Connections queue behind a listener nothing accepts, so the holder never answers.
        self._listener.listen(16)

    def release(self):
        """The holder exits: its lock and listener go, and the socket node it leaves is for the next census."""
        if self._lock is not None:
            os.close(self._lock)
            self._lock = None
        if self._listener is not None:
            self._listener.close()
            self._listener = None


@contextlib.contextmanager
def busy_endpoint(runtime_socket, label):
    """Plant a live-looking endpoint in a derived interface directory and yield its BusyEndpoint.

    While it is held, a census finds D busy and restart cannot prove the socket dead, so it fails
    with the socket's path. After `release()`, D is free and the next census reclaims it. The
    directory is removed on exit if nothing reclaimed it first.
    """
    directory = pathlib.Path(runtime_socket).parent.parent / hashlib.sha256(label.encode()).hexdigest()[:32]
    directory.mkdir(mode=0o700)
    endpoint = BusyEndpoint(directory)
    try:
        endpoint.hold()
        yield endpoint
    finally:
        endpoint.release()
        endpoint.socket.unlink(missing_ok=True)
        with contextlib.suppress(OSError):
            directory.rmdir()


@contextlib.contextmanager
def unprovable_socket(runtime_socket, label):
    """Plant a regular file at `rui.sock` in a derived interface directory.

    A node Rui did not make is the unprovable case: restart fails with its path and never removes
    it, whether or not anything holds D. `runtime_socket` is any Host socket of the same runtime.
    Yields (path, handle); the path and its directory are removed on exit.
    """
    directory = pathlib.Path(runtime_socket).parent.parent / hashlib.sha256(label.encode()).hexdigest()[:32]
    unreadable = directory / "rui.sock"
    directory.mkdir(mode=0o700)
    try:
        with unreadable.open("x") as handle:
            yield unreadable, handle
    finally:
        unreadable.unlink(missing_ok=True)
        directory.rmdir()


def upgrade_journey(root, binary, releases):
    """One install proves SH-23: every eligible Host, found afresh after
    publication, restarts on the selected build; others are left with a
    reason; every Host is counted; a failed one exits 6 without undoing the
    install; and a second run finds them current."""
    with case(root, binary, releases, "journey-a") as a, \
            case(root, binary, releases, "journey-b") as b, \
            case(root, binary, releases, "journey-foreign") as foreign:
        for shared in (b, foreign):
            shared.home, shared.env, shared.link = a.home, a.env, a.link
        a.old_selection()
        old_a, previous_a = a.start_host("journey-a")
        old_foreign, previous_foreign = foreign.start_host("journey-foreign", managed=False)
        warning = a.upgrade("--check")
        assert "Discovered 2 Hosts" in warning, warning
        assert "every running Host" in warning and "ALL Sessions" in warning, warning
        for previous in (previous_a, previous_foreign):
            assert previous["store"] in warning, warning
        assert "left running: application-owned Host" in warning, warning

        with busy_endpoint(a.ready["socket"], "journey-busy") as busy:
            gate = releases.gate_archive()
            start = len(releases.requests)
            child = a.spawn_upgrade()
            wait_for(gate.entered.is_set, "download while the old Host still serves")
            assert old_a.poll() is None and a.status()["instance"] == previous_a["instance"], "Host touched before publication"
            assert a.link.resolve() == a.original, "selection changed before the archive was verified"
            # A Host started after the census is found afresh after publication.
            old_b, previous_b = b.start_host("journey-b", store_hex=True)
            gate.release.set()
            output = a.finish_upgrade(child, success=False)
            assert child.returncode == 6, (child.returncode, output)
            assert "Upgraded to Rui" in output and "[host_restart_failed]" in output, output
            for previous in (previous_a, previous_b):
                assert f"{previous['store']}: restarted on {releases.version}" in output, output
            assert f"{previous_foreign['store']}: left running: application-owned Host" in output, output
            assert str(busy.socket) in output and "failed at discovery" in output, output
            assert "4 Hosts: 2 restarted, 0 already current, 1 left unchanged, 1 failed." in output, output
            assert releases.requests[start:].count(releases.archive_path) == 1, releases.requests[start:]
            assert a.link.resolve() != a.original, "restart failure rolled the installation back"
            proof_ready(a, previous_a, old_a)
            proof_ready(b, previous_b, old_b)
            assert old_foreign.poll() is None and foreign.status()["instance"] == previous_foreign["instance"]
            assert os_semantics.process_executable(old_foreign.pid) != a.link.resolve()

        ready_a, ready_b = a.status(), b.status()
        start = len(releases.requests)
        output = a.upgrade()
        assert "Installation unchanged" in output, output
        for ready in (ready_a, ready_b):
            assert f"{ready['store']}: already on {releases.version}" in output, output
        assert "3 Hosts: 0 restarted, 2 already current, 1 left unchanged, 0 failed." in output, output
        assert releases.archive_path not in releases.requests[start:], "equal release re-downloaded"
        assert a.status()["instance"] == ready_a["instance"] and b.status()["instance"] == ready_b["instance"]


def lifecycle_cases(root, binary, releases):
    frozen_upgrade_cases(root, binary, releases)
    frozen_credential_refusal_case(root, binary, releases)

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
        # A saved setting changed since the Host started restarts it even on the same build.
        c.run("host", "set", "--store", c.store, "execution.backgroundAfterMs", "45000")
        output = c.upgrade()
        assert "restarted on " in output, output
        restarted = c.status()
        assert restarted["instance"] != ready["instance"], (ready, restarted)
        output = c.upgrade()
        assert "already on " in output, output
        assert c.status()["instance"] == restarted["instance"]

    upgrade_journey(root, binary, releases)


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
            return None
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if data:
            transitions = self.transition_tail + data
            self.entries += transitions.count(b"\x1b[?1049h")
            self.restorations += transitions.count(b"\x1b[?1049l")
            self.transition_tail = transitions[-7:]
            self.capture.feed(data)
            self.tail.extend(data)
            del self.tail[:-16384]
        return bool(data)

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
                         ready=lambda screen: "+ New chat" in screen and any(split_pane_row(row)[1] for row in screen.splitlines())
                         and "What shall we work on?" in screen and self.capture.draft("", 2))
        assert "Settings" in frame, frame
        self.send("\x1b")
        return self.overview()

    def overview(self, *, ready=True):
        frame = wait_for(self.observe, "terminal overview list and footer", timeout=15,
                         ready=lambda screen: all(shown(marker, screen) for marker in
                                                  ("+ New chat", "Settings"))
                         and "Notifications" not in screen
                         and "What shall we work on?" not in screen
                         and not any(re.match(r"\s*[›>](?: |$)", split_pane_row(row)[2]) for row in screen.splitlines()))
        assert "What shall we work on?" not in frame, ("overview has an editor", frame)
        assert not any(re.match(r"\s*[›>](?: |$)", split_pane_row(row)[2]) for row in frame.splitlines()), ("overview has a composer", frame)
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

    def empty_chat(self, case, session):
        facts = self.empty_session(case, session)
        frame = wait_for(self.observe, "empty chat model facts and chat-only footer", timeout=15,
                         ready=lambda screen: any(shown(f" {facts['model']} · ", split_pane_row(row)[2]) for row in screen.splitlines())
                         and "alt+i info" not in screen
                         and "Upgraded to " not in screen and " · upgraded to " not in screen)
        return frame

    def sidebar(self, *, failed=False):
        right = "Update failed" if failed else r"\d+(?:\.\d+)? (?:MB|GB)"
        pattern = re.compile(r"\s*Settings\s+" + right + r"\s*")

        def ready(frame):
            if "Upgraded to " in frame or " · upgraded to " in frame:
                return False
            parts = [split_pane_row(row) for row in frame.splitlines()]
            rows = [left if divider else pane for left, divider, pane in parts]
            if any(re.search(r"\b(?:0\.\d+\.\d+|unreleased)\b", row) for row in rows):
                return False
            return any(pattern.fullmatch(row) for row in rows)

        state = "short Update failed" if failed else "quiet memory"
        return wait_for(self.observe, f"Settings with {state} on one row and hidden version", timeout=15, ready=ready)

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
        # Settings is a card over the overview, so its Version row is found by its label, not by a screen column.
        for row, line in enumerate(frame.splitlines()):
            if "Version" in line:
                column = line.index("Version")
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

    for placement in ("default", "external", "contended", "frozen"):
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
                if placement == "frozen":
                    # A real baseline owns DB A. Freeze another admission of
                    # A, then change the selected URL SOURCE (not its contents)
                    # at the same interface. Reopening B would fail because its
                    # credential variable is absent; positive readyA is proof.
                    stop_process(old)
                    starter = c.build("frozen-mysql-starter") / "bin/rui"
                    gate = c.root / "mysql-after-freeze.gate"
                    gate.touch(mode=0o600)
                    c.env["RUI_TEST_HOST_AFTER_FREEZE_GATE"] = str(gate)
                    launcher = subprocess.Popen([starter, "host", "start", "--store", c.store],
                                                env=c.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    c.children.append(launcher)
                    try:
                        def frozen():
                            if launcher.poll() is not None:
                                output, diagnostic = launcher.communicate(timeout=3)
                                raise AssertionError(("MySQL starter exited before freeze", launcher.returncode,
                                                      output, diagnostic))
                            return gate.with_name(gate.name + ".entered").exists()
                        wait_for(frozen, "real MySQL A source frozen before child launch", timeout=30)
                        # A missing MySQL endpoint is deliberately not proof
                        # that its DB lock is free. The known old child is gone;
                        # only the new child's readyA below proves acquisition.
                        assert old.poll() is not None, "old MySQL Host is still living"
                        stopped = c.status()
                        assert stopped["status"] == "owned_unavailable", stopped
                        missing = "RUI_FROZEN_SOURCE_MUST_STAY_UNUSED"
                        assert missing not in c.env
                        changed = json.loads(json.dumps(document))
                        changed["store"]["mysql"]["url"] = {"env": missing}
                        changed["execution"] = {"paused": True}
                        saved.write_text(json.dumps(changed))
                        assert gate.exists() and launcher.poll() is None
                    finally:
                        gate.unlink(missing_ok=True)
                    output, diagnostic = launcher.communicate(timeout=30)
                    assert launcher.returncode == 0, (launcher.returncode, output, diagnostic)
                    ready = json.loads(output)
                    current = c.status()
                    assert current["instance"] == ready["instance"] != previous["instance"], (previous, ready, current)
                    assert current["store"] == previous["store"] != str(c.store) and current["paused"] is False, current
                    assert current["active_capacity"] == previous["active_capacity"], current
                    assert json.loads(saved.read_text()) == changed, "B must remain installed through A readiness"
                    print("MySQL detached freeze passed: admitted source A, changed saved source B at same private interface, consumed A", flush=True)
                    continue
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
    """Retire, hold our starter, install an external owner, then adopt it."""
    with case(root, binary, releases, "adopted-replacement") as c:
        old, previous = c.start_host()
        alternate = c.build("concurrent-same-version")
        c.select(c.build("selected-target"))
        c.binary = c.link
        gate = c.root / "before-start.gate"
        gate.touch()
        c.env["RUI_TEST_UPGRADE_BEFORE_START_GATE"] = str(gate)
        restart = subprocess.Popen([str(c.binary), "host", "restart", "--all"], env=c.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        c.children.append(restart)
        try:
            wait_for(lambda: gate.with_name(gate.name + ".entered").exists(),
                     "coordinator held after retirement and before its starter", timeout=20)
            assert gate.exists() and restart.poll() is None
            assert old.poll() is not None and c.status()["status"] == "unavailable"
            child, ready = start_ready_process(
                [alternate / "bin/rui", "host", "serve", "--store", c.store,
                 "--set", "providers={}", "--set", "execution.activeCapacity=" + previous["active_capacity"]],
                env=c.env, isolate_settings=False)
            c.hosts.append(child)
            assert c.status()["instance"] == ready["instance"] != previous["instance"]
            assert gate.exists() and restart.poll() is None, "our starter was not held until the external Host was ready"
        finally:
            gate.unlink(missing_ok=True)
        output = c.finish_upgrade(restart)
        assert "1 restarted" in output, output
        current = c.status()
        assert current["instance"] == ready["instance"] != previous["instance"], (current, previous)
        assert peer_pid(c.ready["socket"]) == child.pid
        assert os_semantics.process_executable(child.pid) == alternate / "bin/rui"
        assert os_semantics.process_executable(child.pid) != c.link.resolve()
        print("upgrade native: deterministic adopted same-target-version owner verified (different managed executable)", flush=True)


def unchecked_target_case(root, binary, releases, baseline):
    """Downloaded real releases, verified by the caller, never stand-in Hosts."""
    with case(root, binary, releases, "old-target-precondition") as c:
        retained = c.build("running-baseline")
        shutil.copy2(baseline, retained / "bin/rui")
        old_binary = retained / "bin/rui"
        old, ready = start_ready_process([old_binary, "host", "serve", "--store", c.store, "--set", "execution.activeCapacity=2"],
                                         env=c.env, isolate_settings=False)
        c.hosts.append(old)
        c.ready = ready

        def old_status():
            return json.loads(subprocess.check_output([old_binary, "host", "status", "--store", c.store], env=c.env, text=True, timeout=15))

        previous = old_status()
        try:
            build = c.build("no-settings-check")
            shutil.copy2(baseline, build / "bin/rui")
            c.select(build)
            output = c.run("host", "restart", "--all", timeout=60)
            assert "left running" in output and "target build cannot safely check" in output, output
            assert old.poll() is None and old_status()["instance"] == previous["instance"], output
            print("upgrade native: a pre-check release target is refused before stop; old PID/instance unchanged", flush=True)
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
    # SH-11: a SIGKILLed Host whose Store is gone leaves an endpoint that one
    # census proves dead and removes, socket and interface directory alike.
    with case(root, binary, releases, "restart-all-crashed") as c:
        from model_fixture import crash_host
        process, _ = c.start_host("restart-all-crashed")
        socket_path = pathlib.Path(c.ready["socket"])
        crash_host(process, c.root, "restart-all-crashed")
        assert socket_path.exists(), socket_path
        shutil.rmtree(c.store)
        assert c.run("host", "restart", "--all").strip() == "No running Hosts."
        assert not socket_path.exists(), "a census removes the endpoint of a killed Host"
        assert not socket_path.parent.exists(), "and the interface directory derived for it"

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

        # A held D whose listener never answers is busy, not dead: restart fails with its socket's path.
        # Once the holder exits, the next restart reclaims the endpoint silently.
        with busy_endpoint(first.ready["socket"], "restart-busy") as busy:
            output = first.run("host", "restart", "--all", expect=6)
            assert str(busy.socket) in output and "failed at discovery:" in output, output
            assert "3 Hosts: 0 restarted, 2 already current, 0 left unchanged, 1 failed." in output, output
            busy.release()
            output = first.run("host", "restart", "--all")
            assert "2 Hosts: 0 restarted, 2 already current" in output, output
            assert str(busy.socket) not in output and "failed at discovery" not in output, output
        # A regular file at rui.sock in a derived interface directory is unprovable: it fails, and
        # discovery never removes it. The probe is the rui.sock of another derived directory.
        with unprovable_socket(first.ready["socket"], "restart-unreadable") as (unreadable, _):
            output = first.run("host", "restart", "--all", expect=6)
            assert "Store unknown (socket " in output and "failed at discovery:" in output, output
            assert re.search(r"Host state is unconfirmed \([A-Za-z]+\);", output), output
            assert "[host_restart_failed]" in output, output
            assert "3 Hosts: 0 restarted, 2 already current, 0 left unchanged, 1 failed." in output, output
        output = first.run("host", "restart", "--all")
        assert "2 Hosts: 0 restarted, 2 already current" in output, output
        assert str(unreadable) not in output and "failed at discovery" not in output, output

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


def tool_custody_cases(root, binary, releases, operation):
    import codex_fixture
    import model_fixture as fixture

    # The coordinator is one owner for both operations: restart crosses both
    # Bash process shapes, Upgrade keeps the ordinary retained installer shell.
    rows = itertools.product((False, True), (False, True)) if operation == "restart" else ((False, False),)
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
                origin.json("session", "send", "--store", origin.store, "--session", session, input="upgrade now")

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
    screen.sidebar()
    assert screen.capture.alternate


def exit_on_sigint(screen, process, description):
    process.send_signal(signal.SIGINT)

    def exited_and_drained():
        status = process.poll()
        return status, screen.read_output()

    wait_for(exited_and_drained, description,
             ready=lambda observation: observation[0] is not None and observation[1] is not True)
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
            assert b"Upgrade cancelled; nothing changed." in receipt and b"Upgrade installation failed" not in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "cancelled Upgrade relaunched"
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.start_upgrade()
            screen.contains(" · publishing")
            screen.close_settings()
            screen.contains("Publishing; cancelling no longer rolls back")
            screen.send("\x1b")
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
            screen.sidebar()
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
            assert b"Upgrade cancelled; nothing changed." in receipt and b"Upgrade installation failed" not in receipt, receipt.decode()
            assert screen.entries == screen.restorations == 1, "cancelled Upgrade relaunched"
        with terminal_process([str(binary), "session", "resume", "--store", str(c.store), session], env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.empty_chat(c, session)
            screen.start_upgrade()
            screen.contains(" · publishing")
            screen.close_settings()
            frame = screen.contains("Updating…")
            assert "Publishing; cancelling" not in frame, frame
            screen.send("\x01\x0bconversation β draft\x01\x1b[C\x1b[C\x1b[C")
            screen.draft("conversation β draft", 5)
            published.unlink()
            proof_relaunched(c, screen, process)
            screen.empty_chat(c, session)
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


def terminal_handoffs(root, binary, releases, artifacts):
    terminal_cases(root, binary, releases, artifacts)
    conversation_case(root, binary, releases, artifacts)


def terminal_download_recovery(root, binary, releases, artifacts):
    """Settings > Version reads the release itself and recovers DNS failure through its own download owner."""
    with case(root, binary, releases, "terminal-download-recovery") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        # Retain the report rather than exec so this journey is independent
        # of any other application-owned Hosts discovered for the fixture uid.
        shadow = c.build("recovery-shadowing-path", "0.1.0", managed=False) / "bin/rui"
        c.env["PATH"] = f"{shadow.parent}:{c.env['PATH']}"
        # Background discovery's lookup succeeds; the request's own lookup then fails once.
        curl = CurlAttempts(c, {"/releases/latest": [0, 6]})
        gate = releases.gate_archive()
        with terminal_process(overview_args(binary, c), env=c.env, cwd=c.root, columns=TERMINAL_COLUMNS) as (process, master):
            screen = TerminalScreen(master, process)
            screen.launch_overview()
            screen.until(lambda: curl.log.exists() and any(row["path"] == releases.sums_path for row in curl.observed()),
                         "background discovery read the release before the request")
            screen.start_upgrade()
            screen.until(gate.entered.is_set, "Settings download recovered and reached archive")
            screen.contains("preparing Upgrade")
            screen.save(artifacts, "download-recovering-settings")
            assert c.link.resolve() == c.original
            gate.release.set()
            screen.contains(f" · upgraded to {releases.version}")
            screen.save(artifacts, "download-recovered-settings")
            screen.close_settings()
            screen.sidebar()
            proof_ready(c, previous, old_host)
            screen.save(artifacts, "download-recovered")
            curl.assert_attempts([("/releases/latest", "normal", 0),
                                 ("/releases/redirect", "normal", 0),
                                 (releases.sums_path, "normal", 0),
                                 ("/releases/latest", "normal", 6),
                                 ("/releases/latest", "ipv4", 0),
                                 ("/releases/redirect", "ipv4", 0),
                                 (releases.sums_path, "ipv4", 0),
                                 (releases.archive_path, "ipv4", 0)])
            receipt = exit_on_sigint(screen, process, "recovered download report after terminal restoration")
            assert b"Upgraded to Rui" in receipt and b"restarted on " in receipt, receipt.decode()
            assert b"curl fixture final" not in receipt, receipt.decode()
            assert os.fsencode(shadow) in receipt, "recovery lost the retained PATH guidance"
            assert screen.entries == screen.restorations == 1, "retained guidance relaunched the TUI"
            assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            if artifacts is not None:
                (artifacts / "download-recovered.pty-tail.ansi").write_bytes(screen.tail)
                (artifacts / "download-recovered.receipt.txt").write_bytes(receipt)
                shutil.copy2(curl.log, artifacts / "download-recovered.curl.jsonl")


def startup_cases(root, binary, releases, artifacts):
    for screen_kind in ("overview", "resume"):
        name = f"startup-{screen_kind}-unreadable-no-credentials-implicit"
        with case(root, binary, releases, name) as c:
            c.old_selection()
            old_host, previous = c.start_host()
            session, _ = terminal_setup(c)
            c.run("defaults", "configure", "--store", c.store)
            before = c.json("session", "inspect", "--store", c.store, "--session", session)
            preferences = c.home / ".config/rui/preferences"
            credential = c.home / ".config/rui/codex.json"
            preference_mode = stat.S_IMODE(preferences.stat().st_mode)
            other_store = c.root / "other-store"
            other_store.mkdir(mode=0o700)
            published = c.root / "after-publication.gate"
            published.touch()
            c.env["RUI_TEST_UPGRADE_AFTER_PUBLICATION_GATE"] = str(published)
            arguments = ([str(binary), "session", "resume", session]
                         if screen_kind == "resume" else [str(binary)])

            def retire_misdirected_host():
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
                    frame = screen.contains("Updating…" if screen_kind == "resume" else "Publishing; cancelling no longer rolls back")
                    if screen_kind == "resume":
                        assert "Publishing; cancelling" not in frame, frame
                        screen.send("\x01\x0bstartup α draft\x01\x1b[C\x1b[C\x1b[C")
                        screen.draft("startup α draft", 5)
                    else:
                        screen.ignored_overview_input("/xstartup α ignored\x1b[200~startup β paste\x1b[201~",
                                                      "startup α ignored", "startup β paste")
                    assert c.link.resolve() != c.original and published.exists()
                    assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
                    c.run("defaults", "configure", "--store", other_store)
                    expected_preferences = preferences.read_bytes()
                    preferences.chmod(0o000)
                    credential.unlink()
                    published.unlink()
                    proof_relaunched(c, screen, process)
                    proof_ready(c, previous, old_host)
                    if screen_kind == "resume":
                        screen.empty_chat(c, session)
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
                    assert stat.S_IMODE(preferences.stat().st_mode) == 0
                    assert not credential.exists(), "relaunch recreated provider credentials"
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
            assert b"Upgraded to Rui " in receipt, ("joined installation receipt was lost after interruption", receipt.decode())
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
                    state = os_semantics.process_state(child_pid, env=c.env)
                    return state is not None and not state.startswith("Z")

                assert alive()
                screen.contains("checking for updates")
                assert releases.requests[start:] == [], "latest discovery ran before selected probe completed"
                screen.send("\x1b")
                screen.contains(" · cancelled")
                screen.save(artifacts, "selected-version-escape")

                def reaped():
                    return os_semantics.process_state(child_pid, env=c.env) is None

                wait_for(reaped, "cancelled exact selected --version child reap")
                assert releases.requests[start:] == [], "cancelled check reached latest discovery"
                assert c.link.resolve() == c.original
                assert host.poll() is None and c.status()["instance"] == previous["instance"]
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            finally:
                dispose_all(release_version)


def main():
    modes = ("restart-all", "lifecycle", "custody", "download", "terminal", "startup", "future-target", "unchecked-target", "frozen-settings", "pre-freeze-target")
    if len(sys.argv) not in (2, 3, 4, 5) or (len(sys.argv) >= 3 and sys.argv[2] not in modes):
        sys.exit("usage: python3 tests/integration/upgrade_integration.py REAL_RUI [restart-all|lifecycle|custody|terminal|startup|future-target FUTURE_REAL_RUI|unchecked-target BASELINE_RUI|frozen-settings|pre-freeze-target PRE_FREEZE_REAL_RUI]")
    selection = sys.argv[2] if len(sys.argv) >= 3 else "all"
    assert len(sys.argv) == (4 if selection in ("future-target", "pre-freeze-target") else 4 if selection == "unchecked-target" else 2 if selection == "all" else 3), "supply the native binaries required by this mode"
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
        if selection == "frozen-settings":
            frozen_upgrade_cases(root, binary, releases)
            frozen_credential_refusal_case(root, binary, releases)
        if selection == "pre-freeze-target":
            pre_freeze_target_case(root, binary, releases, pathlib.Path(sys.argv[3]).resolve(strict=True))
        if selection == "future-target":
            future_target_case(root, binary, releases)
        if selection == "unchecked-target":
            unchecked_target_case(root, binary, releases, pathlib.Path(sys.argv[3]).resolve(strict=True))
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
            terminal_download_recovery(root, binary, releases, artifacts)
            print("upgrade native: terminal_download_recovery passed", flush=True)
        if selection == "all":
            for suite in (discovery_cases, install_cases, lifecycle_cases, restart_all_cases):
                suite(root, binary, releases)
                print(f"upgrade native: {suite.__name__} passed", flush=True)
            for operation in ("restart", "upgrade"):
                tool_custody_cases(root, binary, releases, operation)
                print(f"upgrade native: tool {operation} custody passed", flush=True)
        if selection in ("all", "terminal"):
            for suite in (terminal_download_recovery, terminal_handoffs):
                suite(root, binary, releases, artifacts)
                print(f"upgrade native: {suite.__name__} passed", flush=True)
        if selection in ("all", "startup"):
            startup_cases(root, binary, releases, artifacts)
        if selection == "all":
            for suite in (cancel_selected_version_check, signal_after_publication, signal_during_check):
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
