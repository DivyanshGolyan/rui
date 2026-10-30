#!/usr/bin/env python3
"""Verify same-format upgrades and prompt, preserving breaking-format refusal."""
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
import tempfile
import threading
import time

import model_fixture as fixture
from host_process import canonical_fixture_root, dispose_all, start_ready_process, stop_process, wait_for, wait_for_execution_release


def install(checkout):
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    print(f"Installing {revision} through ./install.sh", flush=True)
    subprocess.run(["bash", "./install.sh"], cwd=checkout, check=True, timeout=1200)
    binary = pathlib.Path(os.environ["HOME"], ".local/bin/rui")
    print(f"Installed artifact sha256={hashlib.sha256(binary.read_bytes()).hexdigest()}", flush=True)
    return binary


def supported_format(checkout):
    source = (checkout / "src/store.zig").read_text()
    return int(re.search(r"pub const schema_version: u32 = (\d+);", source)[1])


class Dialect:
    """One installed build's command grammar; the previous build keeps its own."""

    def __init__(self, checkout):
        arguments = checkout / "src/cli_args.zig"
        self.resource_first = arguments.exists() and ".request_inspect" in arguments.read_text()
        self.address_send = arguments.exists() and 'value("to", "ADDRESS")' in arguments.read_text()
        self.short_ids = "pub const session_id_bytes = 6;" in (checkout / "src/protocol.zig").read_text()
        self.stdin_message = arguments.exists() and ".session_start" in arguments.read_text()

    def serve(self):
        return ("host", "serve") if self.resource_first else ("serve",)

    def host_arguments(self, store, endpoint):
        return [str(fixture.RUI), *self.serve(), "--store", str(store), "--active-capacity", "1",
                "--provider-endpoint", endpoint, "--test-retry-waits-ms", "50,100,150"]

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
            lambda: (value if (value := self.observe(store, key, remaining())).get("result") else None),
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
        subprocess.run([binary, "host", "stop", "--store", store], check=True, timeout=min(5, remaining))
        wait_for(status, "Store ownership release", deadline=deadline, ready=lambda observed: observed[0] == "unavailable")


def main():
    previous, candidate = (pathlib.Path(value).resolve() for value in sys.argv[1:])
    previous_format, candidate_format = supported_format(previous), supported_format(candidate)
    previous_cli, candidate_cli = Dialect(previous), Dialect(candidate)
    # Do not use the runner's HOME, default Store or credentials. Keep the
    # compiler cache outside HOME so both normal installs can reuse compilation.
    os.environ.setdefault("ZIG_GLOBAL_CACHE_DIR", str(pathlib.Path.home() / ".cache/zig"))
    directory = tempfile.mkdtemp(prefix="rui-upgrade-", dir=os.environ.get("RUI_UPGRADE_FAILURES"))
    try:
        root = canonical_fixture_root(directory)
        home, workspace, store = root / "home", root / "workspace", root / "store"
        home.mkdir()
        workspace.mkdir()
        os.environ["HOME"] = str(home)
        os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(root / "absent-credentials.json")
        fixture.ROOT = workspace
        binary = install(previous)
        previous_artifact = binary.resolve()
        previous_hash = hashlib.sha256(previous_artifact.read_bytes()).digest()
        fixture.RUI = binary
        dialect = previous_cli
        expected = "Saved before reinstall: café\nsecond line remains intact".encode()
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_answer("upgrade-response", "upgrade-reasoning", "upgrade-message",
                               expected.decode())[0],
        ])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        seed = None
        attempted_restart = False
        try:
            seed, _ = start_ready_process(
                dialect.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses"),
                required_fields={"execution": "enabled"},
            )
            session = dialect.configure(root, store, "upgrade-configure", "upgrade/session", "gpt-6-sol")
            dialect.message(root, store, "upgrade-message", session, "Save this real work.")
            observation, answer, _ = dialect.wait_for_result_release(
                store, "upgrade-message", session, time.monotonic() + 15)
            assert observation["result"]["status"] == "completed" and answer == expected, observation
            assert len(endpoint.requests) == 1, "seed work did not use the provider exactly once"
            configuration = {
                "workspace": str(workspace), "provider": "codex", "model": "gpt-6-sol",
                "tools": ["bash"], "permission_mode": "ask",
            }
            before = dialect.inspect_session(store, session)["session"]
            for field, value in configuration.items():
                assert before[field] == value, (field, value, before)
            subprocess.run([binary, "host", "stop", "--store", store], check=True, timeout=10)
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
            dialect = candidate_cli
            commands = ((("host", "start"),) if previous_format == candidate_format
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
                if previous_format == candidate_format:
                    assert restarted.returncode == 0, "same-format upgrade must start without a fresh Store"
                    state, shown = dialect.host_status(binary, store, 5)
                    assert state == "ready", shown
                    # Restarted from soft 256, the candidate uses its own default.
                    assert json.loads(shown)["active_capacity"] == "100", shown
                    print(shown, flush=True)
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
            if previous_format != candidate_format:
                # The previous installed artifact must still recover the exact
                # work at its original Store path. This is not a migration.
                fixture.RUI = previous_artifact
                dialect = previous_cli
                seed, _ = start_ready_process(
                    dialect.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses"),
                    required_fields={"execution": "enabled"},
                )
            recovered = dialect.observe(store, "upgrade-message")
            assert recovered["result"]["status"] == "completed", recovered
            assert recovered["processing"] == observation["processing"], "upgrade replayed completed work"
            assert dialect.read_result(store, "upgrade-message") == expected, "saved answer changed"
            after = dialect.inspect_session(store, session)["session"]
            for field, value in configuration.items():
                assert after[field] == value, (field, value, after)
            assert len(endpoint.requests) == 1, "upgrade replayed completed work"
        finally:
            dispose_all(
                lambda: stop_detached(dialect, binary, store) if attempted_restart else None,
                lambda: stop_process(seed) if seed is not None else None,
                endpoint.shutdown,
                endpoint.server_close,
                lambda: thread.join(timeout=5),
            )
    except BaseException:
        # A failed/unknown start may still own this Store. Never delete beneath
        # it, even when cleanup also failed. Retain the original failure first.
        print(f"Upgrade failure state retained at {directory}; confirm Host release before removal", flush=True)
        raise
    else:
        shutil.rmtree(directory)
        print("Compatibility passed: same-format readiness or explicit breaking-format refusal; exact saved work/configuration and no replay", flush=True)


if __name__ == "__main__":
    main()
