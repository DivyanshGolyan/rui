#!/usr/bin/env python3
"""Public-CLI evidence for detached Host launch and convergence."""

import json
import fcntl
import os
import pathlib
import re
import resource
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from host_process import start_ready_process, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
COMMAND_TIMEOUT = 16


def environment(home, credential):
    return {
        **os.environ,
        "HOME": str(home),
        "RUI_CODEX_CREDENTIAL_FILE": str(credential),
    }


def run_start(store, env, **options):
    return subprocess.run(
        [RUI, "host", "start", "--store", store],
        env=env,
        capture_output=True,
        text=True,
        timeout=COMMAND_TIMEOUT,
        **options,
    )


def status(store, env):
    result = subprocess.run(
        [RUI, "host", "status", "--store", store],
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout


def instance(output, capacity):
    match = re.search(
        rf"^Active capacity: {capacity}$.*^Instance: ([0-9a-f]{{32}})$",
        output,
        re.MULTILINE | re.DOTALL,
    )
    assert match, output
    return match.group(1)


def matching_processes(store):
    """Test-cleanup discovery only; PIDs are never treated as Host authority."""
    expected = str(pathlib.Path(store).resolve())
    matches = []
    candidates = []
    if pathlib.Path("/proc").is_dir():
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                argv = (entry / "cmdline").read_bytes().split(b"\0")
                candidates.append((int(entry.name), [part.decode() for part in argv if part]))
            except (FileNotFoundError, PermissionError, UnicodeDecodeError):
                continue
    else:
        listing = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=5, check=True
        )
        for line in listing.stdout.splitlines():
            try:
                pid_text, command = line.strip().split(maxsplit=1)
                candidates.append((int(pid_text), shlex.split(command)))
            except (ValueError, IndexError):
                continue
    for pid, text in candidates:
        if len(text) >= 4 and pathlib.Path(text[0]).resolve() == RUI and text[1:3] == ["serve", "--store"]:
            try:
                selected = str(pathlib.Path(text[3]).resolve())
            except OSError:
                continue
            if selected == expected:
                matches.append(pid)
    return matches


def wait_for_processes(store, count, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        found = matching_processes(store)
        if len(found) == count:
            return found
        if time.monotonic() >= deadline:
            raise AssertionError(f"expected {count} Host processes, found {found}")
        time.sleep(0.02)


def forced_crash_cleanup(store):
    # #329 is intentionally not part of this fixture. SIGKILL is a forced
    # crash used only to avoid leaking detached test processes.
    for pid in matching_processes(store):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while matching_processes(store) and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not matching_processes(store), "forced-crash cleanup did not reap detached Host"


def assert_diagnostics(store, credential, reported):
    directory = pathlib.Path(store).resolve() / "diagnostics"
    assert reported == directory
    assert directory.is_dir()
    files = list(directory.glob("host-*.jsonl"))
    assert 1 <= len(files) <= 16
    records = []
    for path in files:
        assert path.stat().st_size <= 8 * 1024 * 1024
        for line in path.read_text().splitlines():
            record = json.loads(line)
            assert record["classification"] == "startup"
            records.append(record)
    assert any(record.get("phase") == "ready" for record in records), records
    assert str(credential) not in "".join(path.read_text() for path in files)


def lower_descriptor_limit():
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))


def main():
    assert len(sys.argv) == 2, "usage: host_launch_integration.py /absolute/path/to/rui"
    with tempfile.TemporaryDirectory(prefix="rui-host-launch-") as root_text:
        root = pathlib.Path(root_text)
        home = root / "home"
        home.mkdir(mode=0o700)
        credential = root / "credentials" / "missing.json"
        env = environment(home, credential)

        # A held lease is attached, not replaced or reconfigured.
        held_store = root / "held-store"
        held, _ = start_ready_process(
            [RUI, "serve", "--store", held_store, "--active-capacity", "3"],
            required_fields={"active_capacity": "3"},
        )
        try:
            before = instance(status(held_store, env), 3)
            attached = run_start(held_store, env)
            assert attached.returncode == 0, attached.stderr
            assert "Attached to the ready Host" in attached.stdout, attached.stdout
            assert f"Diagnostics: {held_store.resolve()}/diagnostics\n" in attached.stdout
            assert instance(status(held_store, env), 3) == before
            assert wait_for_processes(held_store, 1) == [held.pid]
        finally:
            stop_process(held)

        # Concurrent spelling aliases may launch candidates, but exactly one
        # capacity-8 owner becomes ready and all callers converge on it.
        store = root / "detached-store"
        store.mkdir(mode=0o700)
        alias = root / "detached-alias"
        alias.symlink_to(store, target_is_directory=True)
        launchers = []
        try:
            for selected in [store, alias, store, alias, store, alias]:
                launchers.append(subprocess.Popen(
                    [RUI, "host", "start", "--store", selected],
                    cwd=root,
                    env=env,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    start_new_session=True,
                ))
            launcher_pids = {process.pid for process in launchers}
            results = []
            for process in launchers:
                stdout, stderr = process.communicate(timeout=COMMAND_TIMEOUT)
                results.append((process.returncode, stdout, stderr))
            assert all(code == 0 for code, _, _ in results), results
            ready = status(alias, env)
            identity = instance(ready, 8)
            assert instance(status(store, env), 8) == identity
            pids = wait_for_processes(store, 1)
            assert pids[0] not in launcher_pids, "Host remained the CLI launcher process"
            if sys.platform == "linux":
                for descriptor in range(3):
                    assert os.readlink(f"/proc/{pids[0]}/fd/{descriptor}") == "/dev/null"
                assert os.readlink(f"/proc/{pids[0]}/cwd") == "/", "detached Host retained launcher cwd"
                assert os.getsid(pids[0]) not in launcher_pids
            assert not credential.exists(), "Host startup opened or created credentials"
            diagnostic_lines = [
                line.removeprefix("Diagnostics: ")
                for _, stdout, _ in results
                for line in stdout.splitlines()
                if line.startswith("Diagnostics: ")
            ]
            assert diagnostic_lines, results
            for location in diagnostic_lines:
                assert_diagnostics(store, credential, pathlib.Path(location))
        finally:
            for process in launchers:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=3)
            forced_crash_cleanup(store)

        ignored_child_store = root / "ignored-sigchld"
        try:
            inherited = run_start(ignored_child_store, env,
                preexec_fn=lambda: signal.signal(signal.SIGCHLD, signal.SIG_IGN))
            assert inherited.returncode == 0, inherited.stderr
            assert instance(status(ignored_child_store, env), 8)
        finally:
            forced_crash_cleanup(ignored_child_store)

        # A descriptor opened before lowering the soft limit is still owned
        # by the launcher; the detached Host must not hold its pipe open.
        inherited_store = root / "inherited-fd"
        read_fd, write_fd = os.pipe()
        inherited_fd = fcntl.fcntl(write_fd, fcntl.F_DUPFD, 200)
        try:
            def inherited_above_limit():
                soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (128, hard))

            inherited = run_start(inherited_store, env, pass_fds=(inherited_fd,),
                preexec_fn=inherited_above_limit)
            assert inherited.returncode == 0, inherited.stderr
        finally:
            os.close(inherited_fd)
            os.close(write_fd)
            try:
                ready, _, _ = select.select([read_fd], [], [], 1)
                assert ready and os.read(read_fd, 1) == b"", "detached Host inherited fd 200"
            finally:
                os.close(read_fd)
                forced_crash_cleanup(inherited_store)

        # An initially open readiness pipe whose reader disconnects during
        # startup must fail the handshake rather than claim ready.
        clean_env = {key: value for key, value in env.items()
            if key not in ("MallocMaxMagazines", "MallocSpaceEfficient", "RUI_HOST_MALLOC_DEFAULTS")}
        disconnected_store = root / "disconnected-stdout"
        disconnected = subprocess.Popen([RUI, "serve", "--store", disconnected_store],
            env=clean_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            disconnected.stdout.close()
            assert disconnected.wait(timeout=COMMAND_TIMEOUT) != 0
            records = [json.loads(line) for file in (disconnected_store / "diagnostics").glob("host-*.jsonl")
                for line in file.read_text().splitlines()]
            assert any(record.get("phase") == "failed" for record in records), records
            assert not any(record.get("phase") == "ready" for record in records), records
        finally:
            if disconnected.poll() is None:
                disconnected.kill()
                disconnected.wait(timeout=3)
            disconnected.stderr.close()
            forced_crash_cleanup(disconnected_store)

        # A detached Host that cannot satisfy its inherited descriptor budget
        # exits; the CLI bounds uncertainty and points at owner diagnostics.
        failure_store = root / "capacity-failure"
        started = time.monotonic()
        failed = run_start(failure_store, env, preexec_fn=lower_descriptor_limit)
        elapsed = time.monotonic() - started
        try:
            assert failed.returncode != 0
            assert 9 <= elapsed < COMMAND_TIMEOUT, elapsed
            assert "readiness unconfirmed after 10 seconds" in failed.stderr, failed.stderr
            assert "diagnostics/ startup records" in failed.stderr, failed.stderr
            assert status(failure_store, env).startswith("Host: unavailable")
            assert not credential.exists()
        finally:
            forced_crash_cleanup(failure_store)

        print("host-launch passed: held lease, 6 aliases -> 1 capacity-8 Host, detached stdio, bounded failure")


if __name__ == "__main__":
    main()
