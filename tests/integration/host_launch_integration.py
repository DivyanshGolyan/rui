#!/usr/bin/env python3
"""Public-CLI evidence for detached Host launch and convergence."""

import errno
import json
import fcntl
import os
import pathlib
import pty
import re
import resource
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

from host_process import start_ready_process, stop_process, assert_persistent_terminal_restored
import codex_integration as codex_fixture


RUI = pathlib.Path(sys.argv[1]).resolve()
COMMAND_TIMEOUT = 16
PTY_OUTPUT_LIMIT = 1024 * 1024


LAUNCH_PROBE = r"""
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int rui_launch_detached(const char *, const char *const *, size_t);

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "launch") == 0) {
        int pipe_fds[2];
        if (pipe(pipe_fds) != 0) return 90;
        int high = fcntl(pipe_fds[1], F_DUPFD, 200);
        if (high != 200) return 91;
        if (fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) < 0) return 92;
        if (fcntl(pipe_fds[0], F_SETFD, FD_CLOEXEC) < 0) return 93;
        struct sigaction ignored = {0}, previous, observed;
        ignored.sa_handler = SIG_IGN;
        sigemptyset(&ignored.sa_mask);
        if (sigaction(SIGCHLD, &ignored, &previous) != 0) return 94;
        const char *child_argv[] = {argv[0], "witness", "", "two words",
            "--not-a-launch-option", "final", NULL};
        int result = rui_launch_detached(argv[0], child_argv, 6);
        if (sigaction(SIGCHLD, NULL, &observed) != 0) return 95;
        if (sigaction(SIGCHLD, &previous, NULL) != 0) return 96;
        if (result != 0) return 97;
        if (observed.sa_handler != SIG_IGN) return 98;
        if (fcntl(pipe_fds[0], F_GETFD) != FD_CLOEXEC ||
            !(fcntl(pipe_fds[0], F_GETFL) & O_NONBLOCK) ||
            fcntl(high, F_GETFD) != 0) return 99;
        close(high);
        close(pipe_fds[1]);
        close(pipe_fds[0]);
        return 0;
    }
    FILE *output = fopen(getenv("RUI_LAUNCH_PROBE_OUTPUT"), "wb");
    if (!output) return 100;
    for (int i = 0; i < argc; i++)
        if (fwrite(argv[i], 1, strlen(argv[i]) + 1, output) != strlen(argv[i]) + 1) return 101;
    const char *keys[] = {"RUI_LAUNCH_PROBE_VALUE", "RUI_LAUNCH_PROBE_EMPTY", "HOME"};
    for (size_t i = 0; i < 3; i++) {
        const char *value = getenv(keys[i]);
        if (!value) value = "missing";
        if (fwrite(value, 1, strlen(value) + 1, output) != strlen(value) + 1) return 102;
    }
    char cwd[4096];
    if (!getcwd(cwd, sizeof(cwd))) return 103;
    if (fwrite(cwd, 1, strlen(cwd) + 1, output) != strlen(cwd) + 1) return 104;
    errno = 0;
    int closed = fcntl(200, F_GETFD) == -1 && errno == EBADF;
    if (fputs(closed ? "closed" : "inherited", output) < 0) return 105;
    if (fclose(output) != 0) return 106;
    return 0;
}
"""


def assert_launch_adapter(root, env):
    # Link the production adapter, including Darwin's early same-executable
    # helper, without adding application policy or a production test hook.
    source, actor = root / "launch-probe.c", root / "launch-probe"
    source.write_text(LAUNCH_PROBE)
    adapter = pathlib.Path(__file__).resolve().parents[2] / "src/host_launch.c"
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(source), str(adapter),
                    "-pthread", "-o", str(actor)], check=True)
    output = root / "launch-probe-output"
    probe_env = {**env, "RUI_LAUNCH_PROBE_OUTPUT": str(output),
                 "RUI_LAUNCH_PROBE_VALUE": "inherited = value / λ",
                 "RUI_LAUNCH_PROBE_EMPTY": ""}
    result = subprocess.run([actor, "launch"], cwd=root, env=probe_env,
                            capture_output=True, timeout=5)
    assert result.returncode == 0, result
    expected = [str(actor), "witness", "", "two words", "--not-a-launch-option", "final",
                probe_env["RUI_LAUNCH_PROBE_VALUE"], "", env["HOME"], "/", "closed"]
    deadline = time.monotonic() + 5
    while True:
        observed = output.read_bytes() if output.exists() else b""
        if observed.endswith(b"closed") or observed.endswith(b"inherited"):
            break
        assert time.monotonic() < deadline, observed
        time.sleep(0.01)
    assert observed.split(b"\0") == [part.encode() for part in expected], observed


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


def wait_for_terminal_exit(caller, master, output, deadline):
    """Sole reader retains output through PTY EOF and reap, without renewed time."""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(caller.args, 5)
        if not select.select([master], [], [], min(remaining, 0.05))[0]:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError as error:
            # Linux PTYs report EOF as EIO; Darwin returns an empty read.
            if error.errno != errno.EIO:
                raise
            chunk = b""
        if not chunk:
            return caller.wait(timeout=max(0, deadline - time.monotonic()))
        assert len(output) + len(chunk) < PTY_OUTPUT_LIMIT, "unexpected unbounded terminal output"
        output.extend(chunk)


def main():
    assert len(sys.argv) == 2, "usage: host_launch_integration.py /absolute/path/to/rui"
    from host_launch_exit_test import check_exit_reader
    check_exit_reader(wait_for_terminal_exit)
    with tempfile.TemporaryDirectory(prefix="rui-host-launch-") as root_text:
        root = pathlib.Path(root_text)
        home = root / "home"
        home.mkdir(mode=0o700)
        credential = root / "credentials" / "missing.json"
        env = environment(home, credential)
        assert_launch_adapter(root, env)

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
        # Reach the readiness write even under the orb's finite FD limit;
        # production default-capacity admission has its own dedicated gate.
        disconnected = subprocess.Popen([RUI, "serve", "--store", disconnected_store, "--active-capacity", "8"],
            env=clean_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            disconnected.stdout.close()
            assert disconnected.wait(timeout=COMMAND_TIMEOUT) == 1
            errors = disconnected.stderr.read(4096).decode()
            assert "HostReadinessOutputUnavailable" in errors, errors
            records = [json.loads(line) for file in (disconnected_store / "diagnostics").glob("host-*.jsonl")
                for line in file.read_text().splitlines()]
            assert any(record.get("phase") == "failed" for record in records), records
            assert not any(record.get("phase") == "ready" for record in records), records
            replacement = run_start(disconnected_store, env)
            assert replacement.returncode == 0, replacement.stderr
            assert instance(status(disconnected_store, env), 8)
        finally:
            if disconnected.poll() is None:
                disconnected.kill()
                disconnected.wait(timeout=3)
            disconnected.stderr.close()
            forced_crash_cleanup(disconnected_store)

        # Bare terminal entry starts the same managed Host and configures one
        # recoverable Session without any separate serve terminal.
        bare_home = root / "bare-home"
        bare_home.mkdir(mode=0o700)
        # macOS's temporary root may have symlink ancestors. Supply canonical
        # fixture HOME without relaxing the credential owner's no-symlink rule.
        bare_home = bare_home.resolve(strict=True)
        bare_store = bare_home / ".local/share/rui/store"
        bare_credential_dir = bare_home / ".config/rui"
        bare_credential_dir.mkdir(parents=True, mode=0o700)
        bare_credential = bare_credential_dir / "codex.json"
        codex_fixture.credentials(bare_credential)
        bare_env = {**os.environ, "HOME": str(bare_home)}
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        caller = None
        try:
            original_terminal = termios.tcgetattr(master)
            caller = subprocess.Popen([RUI], cwd=root, env=bare_env,
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            slave = None
            output = bytearray()
            until = time.monotonic() + COMMAND_TIMEOUT
            while b"rui> " not in output:
                remaining = until - time.monotonic()
                assert remaining > 0 and select.select([master], [], [], remaining)[0], output
                chunk = os.read(master, 65536)
                assert len(output) + len(chunk) < PTY_OUTPUT_LIMIT, "unexpected unbounded terminal output"
                output.extend(chunk)
            assert b"Host ready" not in output, "auto-start polluted quiet opening"
            assert b"Provider/model: codex/gpt-6-luna" in output and b"Permission Mode: bypass" in output, output
            assert b"Bash bypasses approval" in output, output
            assert b"request: " in output and b"Rui Session: rui/" in output, output
            captures = list((bare_home / ".config/rui/requests").glob("*.json"))
            assert len(captures) == 1, captures
            captured = json.loads(captures[0].read_text())
            assert captured["key"] == captures[0].stem
            assert captured["session"] == "rui/" + captured["key"]
            assert captured["store"] == str(bare_store.resolve())
            configuration = captured["configuration"]
            assert configuration["workspace"] == {"state": "value", "value": str(root.resolve())}
            assert configuration["provider"] == {"state": "value", "value": "codex"}
            assert configuration["model"] == {"state": "value", "value": "gpt-6-luna"}
            assert configuration["tools"] == {"state": "value", "value": ["bash"]}
            assert configuration["permission_mode"] == {"state": "value", "value": "bypass"}
            assert captured["require_model"] is True
            assert ("Rui Session: " + captured["session"]).encode() in output
            assert len(wait_for_processes(bare_store, 1)) == 1
            # Transfer this thread's reader from prompt to exit without
            # withholding output credit or discarding any transcript bytes.
            os.set_blocking(master, False)
            deadline = time.monotonic() + 5
            assert os.write(master, b"/exit\n") == 6, "incomplete /exit submission"
            assert wait_for_terminal_exit(caller, master, output, deadline) == 0, output
            assert_persistent_terminal_restored(master, original_terminal)
            assert instance(status(bare_store, bare_env), 8)
            stopped = subprocess.run([RUI, "host", "stop", "--store", bare_store],
                env=bare_env, capture_output=True, text=True, timeout=5)
            assert stopped.returncode == 0 and "Stop acknowledged" in stopped.stdout, stopped
        finally:
            try:
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
            finally:
                try:
                    os.close(master)
                finally:
                    try:
                        if slave is not None:
                            os.close(slave)
                    finally:
                        forced_crash_cleanup(bare_store)

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
