#!/usr/bin/env python3
"""Gate stopped-Store compatibility and installer activation of a running release."""
import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import re
import resource
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

import model_fixture as fixture
import host_process
import os_semantics
from host_serve_dialect import HostServeDialect, help_text
from host_process import canonical_fixture_root, dispose_all, start_ready_process, stop_process, wait_for, wait_for_execution_release


def install(checkout, publisher=None, *, released=False):
    if publisher is None:
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
        print(f"Installing current {revision} through ./install.sh", flush=True)
        subprocess.run(["bash", "./install.sh"], cwd=checkout, check=True, timeout=1200)
    else:
        prefix = pathlib.Path(os.environ["HOME"], ".local/lib/rui")
        prefix.mkdir(parents=True, exist_ok=True)
        stage = pathlib.Path(tempfile.mkdtemp(prefix="install.", dir=prefix))
        if released:
            (stage / "bin").mkdir()
            shutil.copy2(checkout / "bin/rui", stage / "bin/rui")
            shutil.copy2(checkout / "THIRD_PARTY_NOTICES.md", stage / "THIRD_PARTY_NOTICES.md")
        else:
            subprocess.run(["zig", "build", "-Doptimize=ReleaseSafe", "--prefix", str(stage)],
                           cwd=checkout, check=True, timeout=1200)
        subprocess.run([publisher, "--publish-install", os.environ["HOME"], str(stage),
                        "released-install" if released else "intentional-source"],
                       check=True, timeout=30)
    binary = pathlib.Path(os.environ["HOME"], ".local/bin/rui")
    print(f"Installed artifact sha256={hashlib.sha256(binary.read_bytes()).hexdigest()}", flush=True)
    return binary


def release_version(binary):
    reported = subprocess.check_output([binary, "--version"], text=True, timeout=5)
    match = re.fullmatch(r"rui (0\.[0-9]+\.[0-9]+) \(.*\)\n", reported)
    assert match, reported
    return match[1]


def build_candidate_release(candidate, root):
    # Source installs normally report "unreleased", which cannot be used for
    # verified release activation. Reuse upgrade-integration's production actor:
    # only its release identity is synthetic, not its Host or installer behavior.
    prefix = root / "candidate"
    subprocess.run(["zig", "build", "upgrade-fixture", "--prefix", prefix, "-j2"],
                   cwd=candidate, check=True, timeout=1200)
    return prefix / "bin/rui-upgrade-release-fixture"


def install_candidate_release(candidate, publisher, root):
    # Exercise the rendered curl-installer path, including extraction, digest
    # verification, publication and restart. Only archive transport is local.
    sys.path.insert(0, str(candidate / "tests/ci"))
    import release

    version = release_version(publisher)
    platform = os_semantics.native_release_target()
    assert platform is not None, "unsupported release platform"
    name = f"rui-{version}-{platform}"
    archive = root / f"{name}.tar.gz"
    with tarfile.open(archive, "w:gz") as packed:
        packed.add(publisher, arcname=f"{name}/bin/rui")
        packed.add(candidate / "THIRD_PARTY_NOTICES.md", arcname=f"{name}/THIRD_PARTY_NOTICES.md")
    with archive.open("rb") as packed:
        digest = hashlib.file_digest(packed, "sha256").hexdigest()
    script = root / "install.sh"
    script.write_text(release.installer(
        (candidate / "release/install.sh").read_text(), version,
        {target: digest for target in release.PLATFORMS},
        (candidate / "release/publish.sh").read_text()))
    tools = root / "tools"
    tools.mkdir()
    curl = tools / "curl"
    curl.write_text("""#!/usr/bin/env python3
import os
import sys
args = sys.argv[1:]
url = os.environ["RUI_UPGRADE_ARCHIVE_URL"]
assert args.count(url) == 1, args
args[args.index(url)] = os.environ["RUI_UPGRADE_LOCAL_ARCHIVE"]
os.execv(os.environ["RUI_UPGRADE_REAL_CURL"], ["curl", *args])
""")
    curl.chmod(0o700)
    real_curl = shutil.which("curl")
    assert real_curl is not None, "release installer requires curl"
    print("Installing candidate through rendered release/install.sh (local native archive)", flush=True)
    result = subprocess.run(["sh", script], capture_output=True, text=True, timeout=60,
        env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
             "RUI_NO_MODIFY_PATH": "1", "RUI_UPGRADE_REAL_CURL": real_curl,
             "RUI_UPGRADE_ARCHIVE_URL": f"https://github.com/DivyanshGolyan/rui/releases/download/v{version}/{name}.tar.gz",
             "RUI_UPGRADE_LOCAL_ARCHIVE": archive.as_uri()})
    output = result.stdout + result.stderr
    print(output, flush=True)
    assert result.returncode == 0, (result.returncode, output)
    return pathlib.Path(os.environ["HOME"], ".local/bin/rui"), output


def assert_running_upgrade(dialect, binary, store, seed, ready, previous, version, output):
    state, shown = dialect.host_status(binary, store, 5)
    assert state == "ready", shown
    current = json.loads(shown)
    assert current["store"] == previous["store"] == str(store), shown
    assert current["instance"] != previous["instance"], "installer left the old Host running"
    # Status's version is a wire version, not a release version. Bind its socket
    # to the kernel's exact server image before asking that image for its version.
    with os_semantics.unix_stream() as connection:
        connection.settimeout(5)
        connection.connect(ready["socket"])
        pid = os_semantics.socket_peer_pid(connection)
    assert pid != seed.pid, "installer kept the previous-release process"
    executable = os_semantics.process_executable(pid)
    assert executable == binary.resolve(), (executable, binary.resolve())
    assert release_version(binary) == version, "installer did not select the candidate version"
    assert release_version(executable) == version, "serving Host is not the candidate version"
    assert f"{store}: restarted on {version}" in output, output
    wait_for(lambda: seed.poll() is not None, "previous-release Host retirement", timeout=10)
    print(f"Running Host upgraded to {version}, instance {previous['instance']} → {current['instance']}", flush=True)


def supported_format(checkout):
    # Releases before the Store's split declare the format in src/store.zig.
    path = checkout / "src/store/schema.zig"
    source = (path if path.exists() else checkout / "src/store.zig").read_text()
    return int(re.search(r"pub const schema_version: u32 = (\d+);", source)[1])


def supported_range(checkout):
    path = checkout / "src/store/schema.zig"
    source = (path if path.exists() else checkout / "src/store.zig").read_text()
    current = supported_format(checkout)
    baseline = re.search(r"pub const migration_baseline: u32 = (\d+);", source)
    return (int(baseline[1]) if baseline else current), current




class Dialect(HostServeDialect):
    """One installed build's command grammar; the previous build keeps its own."""

    def __init__(self, binary):
        super().__init__(binary)
        send_help = (help_text(binary, "session", "send") if self.resource_first
                     else help_text(binary))
        assert send_help, f"No command help from {binary}"
        self.address_send = "--to ADDRESS" in send_help
        self.short_ids = "--to ID" in send_help
        self.stdin_message = bool(help_text(binary, "session", "start"))
        self.pause = ("host", "pause") if help_text(binary, "host", "pause") else ("host", "stop")

    def host_status(self, binary, store, timeout):
        status = subprocess.run([binary, "host", "status", "--store", store],
                                capture_output=True, text=True, check=True, timeout=timeout)
        if self.resource_first:
            return json.loads(status.stdout)["status"], status.stdout
        for state in ("ready", "unavailable"):
            if f"Host: {state}" in status.stdout:
                return state, status.stdout
        return None, status.stdout

    def configure(self, state, store, key, session, model):
        reply = fixture.command(*(("session", "configure") if self.resource_first else ("configure",)),
            "--store", store, "--record", state / f"{key}.json", "--key", key,
            *(("--session", session) if not self.short_ids else ()),
            "--workspace", fixture.ROOT, "--provider", "codex", "--model", model,
            "--tools", "bash", "--permission-mode", "ask")
        assert reply["answer"]["status"] == "accepted", reply
        return reply["answer"]["session"] if self.short_ids else session

    def message(self, state, store, key, session, text):
        text_path = state / f"{key}.txt"
        text_path.write_text(text)
        destination = (("--store", store, "--to", session) if self.short_ids else
            ("--to", json.dumps({"store": str(store), "session": session})) if self.address_send else
            ("--store", store, "--session", session))
        reply = fixture.command(*(("session", "send") if self.resource_first else ("message",)),
            *destination, "--record", state / f"{key}.json", "--key", key,
            *(("--text", text_path) if not self.stdin_message else ()),
            input=text if self.stdin_message else None)
        assert reply["answer"]["status"] == "accepted", reply

    def observe(self, store, key, timeout=15):
        return fixture.command(*(("request", "inspect") if self.resource_first else ("observe-command",)),
                               "--store", store, "--key", key, timeout=timeout)["observation"]

    def terminal(self, observation):
        # The previous installed binary keeps its own observation contract.
        return (observation.get("state") in fixture.TERMINAL_MESSAGE_STATES
                if "state" in observation else bool(observation.get("result")))

    def binding(self, observation):
        return observation["binding" if "state" in observation else "processing"]

    def read_result(self, store, key, timeout=15):
        command = ("request", "read-result") if self.resource_first else ("read-result",)
        completed = subprocess.run([str(fixture.RUI), *command, "--store", str(store), "--key", key],
                                   capture_output=True, timeout=timeout)
        assert completed.returncode == 0, (key, completed)
        return completed.stdout

    def inspect_session(self, store, session, timeout=15):
        return fixture.command(*(("session", "inspect") if self.resource_first else ("inspect-session",)),
                               "--store", store, "--session", session, timeout=timeout)

    def wait_for_result_release(self, store, key, session, deadline):
        def remaining():
            left = min(deadline, time.monotonic() + 15) - time.monotonic()
            assert left > 0, f"{key} exhausted its original deadline"
            return left
        observation = fixture.wait_for(
            lambda: (value if self.terminal(value := self.observe(store, key, remaining())) else None),
            f"{key} terminal result", deadline=deadline)
        answer = (self.read_result(store, key, remaining())
                  if observation["result"]["status"] == "completed" else None)
        assert time.monotonic() < deadline, f"{key} result read exceeded its original deadline"
        execution = wait_for_execution_release(
            lambda left: self.inspect_session(store, session, left)["execution"], deadline)
        return observation, answer, execution


def database_hashes(store):
    return {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in store.glob("rui.sqlite3*")}


def stop_detached(dialect, binary, store):
    deadline = time.monotonic() + 10

    def status():
        remaining = deadline - time.monotonic()
        assert remaining > 0, "Store ownership release unconfirmed"
        return dialect.host_status(binary, store, min(5, remaining))
    state, shown = wait_for(status, "a ready or released Host", deadline=deadline,
                            ready=lambda observed: observed[0] in ("ready", "unavailable"))
    if state == "ready":
        remaining = deadline - time.monotonic()
        assert remaining > 0, shown
        subprocess.run([binary, *dialect.pause, "--store", store], check=True, timeout=min(5, remaining))
        wait_for(status, "Store ownership release", deadline=deadline, ready=lambda observed: observed[0] == "unavailable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--running-host", action="store_true",
                        help="previous is an unpacked release; leave its Host running during release/install.sh")
    parser.add_argument("previous", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    args = parser.parse_args()
    previous, candidate = args.previous.resolve(), args.candidate.resolve()
    if not args.running_host:
        previous_format = supported_format(previous)
        candidate_minimum, candidate_format = supported_range(candidate)
        supported = candidate_minimum <= previous_format <= candidate_format
    # Do not use the runner's HOME, default Store or credentials. Keep the
    # compiler cache outside HOME so both normal installs can reuse compilation.
    os.environ.setdefault("ZIG_GLOBAL_CACHE_DIR", str(pathlib.Path.home() / ".cache/zig"))
    directory = tempfile.mkdtemp(prefix="rui-upgrade-", dir=os.environ.get("RUI_UPGRADE_FAILURES"))
    host_released = True
    try:
        root = canonical_fixture_root(directory)
        home, workspace, store = root / "home", root / "workspace", root / "store"
        home.mkdir()
        workspace.mkdir()
        os.environ["HOME"] = str(home)
        os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(root / "absent-credentials.json")
        fixture.ROOT = workspace
        publisher = (build_candidate_release(candidate, root) if args.running_host
                     else install(candidate).resolve())
        candidate_cli = Dialect(publisher)
        binary = install(previous, publisher, released=args.running_host)
        previous_artifact = binary.resolve()
        previous_hash = hashlib.sha256(previous_artifact.read_bytes()).digest()
        fixture.RUI = binary
        dialect = previous_cli = Dialect(binary)
        expected = "Saved before reinstall: café\nsecond line remains intact".encode()
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_answer("upgrade-response", "upgrade-reasoning", "upgrade-message",
                               expected.decode())[0],
        ])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        seed = None
        attempted_restart = False

        def stop_installed_host():
            nonlocal host_released
            # The old child is reaped first; a failed install may have left
            # either it or a detached candidate serving this Store.
            if args.running_host:
                stop_detached(candidate_cli, publisher, store)
                host_released = True
            elif attempted_restart:
                stop_detached(dialect, binary, store)

        try:
            host_released = False
            seed, ready = start_ready_process(
                dialect.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                       retry_waits=not args.running_host),
                required_fields={"execution": "enabled"}, isolate_providers=False,
            )
            session = dialect.configure(root, store, "upgrade-configure", "upgrade/session", "gpt-6-sol")
            dialect.message(root, store, "upgrade-message", session, "Save this real work.")
            observation, answer, _ = dialect.wait_for_result_release(
                store, "upgrade-message", session, time.monotonic() + 15)
            assert observation["result"]["status"] == "completed" and answer == expected, observation
            original_binding = dialect.binding(observation)
            assert len(endpoint.requests) == 1, "seed work did not use the provider exactly once"
            configuration = {
                "workspace": str(workspace), "provider": "codex", "model": "gpt-6-sol",
                "tools": ["bash"], "permission_mode": "ask",
            }
            before = dialect.inspect_session(store, session)["session"]
            for field, value in configuration.items():
                assert before[field] == value, (field, value, before)
            if args.running_host:
                state, shown = dialect.host_status(previous_artifact, store, 5)
                assert state == "ready" and seed.poll() is None, shown
                previous_status = json.loads(shown)
                print(f"Leaving previous release {release_version(previous_artifact)} running: {shown}", flush=True)
                binary, installer_output = install_candidate_release(candidate, publisher, root)
            else:
                subprocess.run([binary, *dialect.pause, "--store", store], check=True, timeout=10)
                # Effect-aware shutdown is a nonzero serving exit, not a crash.
                assert seed.wait(timeout=10) != 0
                stop_detached(dialect, binary, store)  # Confirm lease release, not just acknowledgement.
                stop_process(seed)
                seed = None
                # The Host has closed and checkpointed. A normal read-only WAL
                # connection creates sidecars, contaminating the refusal snapshot.
                with contextlib.closing(sqlite3.connect((store / "rui.sqlite3").as_uri() + "?mode=ro&immutable=1", uri=True)) as database:
                    assert database.execute("PRAGMA user_version").fetchone()[0] == previous_format
                before_hashes = database_hashes(store)
                assert "rui.sqlite3" in before_hashes
                print("Previous build saved the exact answer and released the Store", flush=True)

                binary = install(candidate)
            assert binary.resolve() != previous_artifact, "installation did not publish a new build"
            assert hashlib.sha256(previous_artifact.read_bytes()).digest() == previous_hash, "old build changed"
            fixture.RUI = binary
            dialect = candidate_cli = Dialect(binary)
            if args.running_host:
                assert_running_upgrade(dialect, binary, store, seed, ready, previous_status,
                                       release_version(publisher), installer_output)
                commands = ()  # No explicit start/restart may repair the installer.
            else:
                commands = ((("host", "start"),) if supported
                            else (("host", "start"), candidate_cli.serve()))
            for command in commands:
                attempted_restart = True
                started_at = time.monotonic()
                original_limits = resource.getrlimit(resource.RLIMIT_NOFILE)
                try:
                    resource.setrlimit(resource.RLIMIT_NOFILE, (256, original_limits[1]))
                    restarted = subprocess.run([binary, *command, "--store", store],
                                               capture_output=True, text=True, timeout=16)
                finally:
                    resource.setrlimit(resource.RLIMIT_NOFILE, original_limits)
                elapsed = time.monotonic() - started_at
                print(restarted.stdout + restarted.stderr, flush=True)
                if supported:
                    assert restarted.returncode == 0, "supported upgrade must start without a fresh Store"
                    state, shown = dialect.host_status(binary, store, 5)
                    assert state == "ready", shown
                    # Restarted from soft 256, the candidate uses its own default.
                    assert json.loads(shown)["active_capacity"] == "100", shown
                    print(shown, flush=True)
                    if previous_format != candidate_format:
                        backup = store / "rui.backup"
                        assert backup.exists(), "startup migration omitted its pre-migration backup"
                        with contextlib.closing(sqlite3.connect(backup.as_uri() + "?mode=ro&immutable=1", uri=True)) as database:
                            assert database.execute("PRAGMA user_version").fetchone()[0] == previous_format
                        with contextlib.closing(sqlite3.connect((store / "rui.sqlite3").as_uri() + "?mode=ro", uri=True)) as database:
                            assert database.execute("PRAGMA user_version").fetchone()[0] == candidate_format
                else:
                    assert restarted.returncode != 0 and elapsed < 5, (elapsed, restarted)
                    for text in (str(store), f"found schema {previous_format}",
                                 f"supports schema {candidate_format}", "compatible Rui build",
                                 "original path", "back up", "fresh Store", "No migration was performed",
                                 "https://github.com/DivyanshGolyan/rui#start-fresh-after-a-store-format-change"):
                        assert text in restarted.stderr, (text, restarted.stderr)
                    assert "HostReadinessUnconfirmed" not in restarted.stderr
                    assert database_hashes(store) == before_hashes, "refusal changed SQLite data or file membership"
                    stop_detached(dialect, binary, store)
                    attempted_restart = False
                    print(f"Breaking format {previous_format}→{candidate_format} {' '.join(command)} refused in {elapsed:.3f}s; SQLite hashes unchanged", flush=True)
            if not args.running_host and not supported:
                # The previous installed artifact must still recover the exact
                # work at its original Store path. This is not a migration.
                fixture.RUI = previous_artifact
                dialect = previous_cli
                seed, _ = start_ready_process(
                    dialect.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses"),
                    required_fields={"execution": "enabled"}, isolate_providers=False,
                )
            recovered = dialect.observe(store, "upgrade-message")
            assert recovered["result"]["status"] == "completed", recovered
            assert dialect.binding(recovered) == original_binding, "upgrade replayed completed work"
            assert dialect.read_result(store, "upgrade-message") == expected, "saved answer changed"
            after = dialect.inspect_session(store, session)["session"]
            for field, value in configuration.items():
                assert after[field] == value, (field, value, after)
            assert len(endpoint.requests) == 1, "upgrade replayed completed work"
        finally:
            dispose_all(
                lambda: stop_process(seed) if args.running_host and seed is not None else None,
                stop_installed_host,
                lambda: stop_process(seed) if not args.running_host and seed is not None else None,
                endpoint.shutdown,
                endpoint.server_close,
                lambda: thread.join(timeout=5),
            )
    except BaseException:
        # A failed/unknown start may still own this Store. Never delete beneath
        # it, even when cleanup also failed. Retain the original failure first.
        if args.running_host and host_released and not os.environ.get("RUI_UPGRADE_FAILURES"):
            dispose_all(lambda: shutil.rmtree(directory))
        else:
            print(f"Upgrade failure state retained at {directory}; confirm Host release before removal", flush=True)
        raise
    else:
        shutil.rmtree(directory)
        print(("Running-release install passed: installer exited 0 and named the restart; candidate Host version/new instance; "
               if args.running_host else
               "Compatibility passed: supported startup readiness/migration backup or unsupported-format refusal; ") +
              "exact saved work/configuration and no replay", flush=True)


if __name__ == "__main__":
    host_process.enter()
    main()
