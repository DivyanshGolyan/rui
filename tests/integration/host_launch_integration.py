#!/usr/bin/env python3
"""Public-CLI evidence for detached Host launch and convergence."""

import errno
from contextlib import contextmanager
import json
import fcntl
import hashlib
import os
import pathlib
import pty
from terminal_process import open_pty
import re
import resource
import select
import shlex
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import termios
import time

from host_process import (canonical_fixture_root, start_ready_process, stop_process,
                          dispose_all, preserve_failure_metadata, _failure_destination)
import codex_integration as codex_fixture


RUI = pathlib.Path(sys.argv[1]).resolve()
COMMAND_TIMEOUT = 16
PTY_OUTPUT_LIMIT = 1024 * 1024


LAUNCH_PROBE = r"""
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int rui_launch_detached(const char *, const char *const *, size_t);
extern int rui_launch_detached_observed(const char *, const char *const *, size_t, int *);

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "startup-failure") == 0) {
        const char failure[] = "error: StartupProbeFailed (exit status 1)\n";
        if (write(2, failure, sizeof(failure) - 1) != sizeof(failure) - 1) return 108;
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "closed-startup") == 0) {
        int mask = atoi(argv[2]);
        for (int fd = 0; fd < 3; fd++) if (mask & (1 << fd)) close(fd);
        const char *child_argv[] = {argv[0], "startup-failure", NULL};
        int reader = -1;
        if (rui_launch_detached_observed(argv[0], child_argv, 2, &reader)) return 109;
        struct pollfd ready = {.fd = reader, .events = POLLIN};
        if (poll(&ready, 1, 3000) <= 0) return 110;
        char data[128];
        ssize_t count = read(reader, data, sizeof(data));
        close(reader);
        const char expected[] = "error: StartupProbeFailed (exit status 1)\n";
        return count == sizeof(expected) - 1 && !memcmp(data, expected, sizeof(expected) - 1) ? 0 : 111;
    }
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
    for mask in range(1, 8):
        result = subprocess.run([actor, "closed-startup", str(mask)], env=probe_env,
                                capture_output=True, timeout=5)
        assert result.returncode == 0, (mask, result)
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
    # Save the actual observation before the caller tests readiness. A later
    # probe cannot reconstruct the status that failed under intake pressure.
    observation = json.dumps(dict(store=str(store), returncode=result.returncode,
                                  stdout=result.stdout, stderr=result.stderr)) + "\n"
    assert len(observation.encode()) <= 1024 * 1024, "status observation exceeds artifact bound"
    root = next((parent for parent in store.parents if parent.name.startswith("rui-host-launch-")), store.parent)
    (root / "probe.log").write_text(observation)
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


def matching_processes(store, *, descendants=False):
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
            except (FileNotFoundError, ProcessLookupError, PermissionError, UnicodeDecodeError):
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
            if selected == expected or (descendants and pathlib.Path(selected).is_relative_to(expected)):
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


def forced_crash_cleanup(store, *, descendants=False):
    # #329 is intentionally not part of this fixture. SIGKILL is a forced
    # crash used only to avoid leaking detached test processes.
    for pid in matching_processes(store, descendants=descendants):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while matching_processes(store, descendants=descendants) and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not matching_processes(store, descendants=descendants), "forced-crash cleanup did not reap detached Host"


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


def startup_limits(root, env):
    for name, hard in (("soft-256", False), ("hard-256", True)):
        store = root / name
        def limits():
            _, inherited_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
            resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256 if hard else inherited_hard))
        try:
            started = run_start(store, env, preexec_fn=limits)
            assert started.returncode == 0, started.stderr
            reported = status(store, env)
            assert "Host: ready" in reported and "Active capacity: 8" in reported, reported
            match = re.search(r"Concurrent intake: (\d+) ordinary", reported)
            assert match, reported
            capacity = int(match[1])
            assert (10 <= capacity < 100) if hard else capacity == 100, reported
            if hard:
                assert "reduced by descriptor limit" in reported, reported
                socket_path = f"/tmp/rui-{os.getuid()}/{hashlib.sha256(str(store).encode()).hexdigest()[:32]}.sock"
                borrowers = []
                try:
                    for _ in range(capacity):
                        peer = socket.socket(socket.AF_UNIX)
                        borrowers.append(peer)
                        peer.settimeout(3)
                        peer.connect(socket_path)
                        peer.sendall(b"POST /v1/configure HTTP/1.1\r\n")
                    # Discovery is prepared by intake after reading preceding
                    # borrowers, so its reply establishes their classification.
                    assert "Host: ready" in status(store, env)
                    with socket.socket(socket.AF_UNIX) as peer:
                        peer.settimeout(3)
                        peer.connect(socket_path)
                        peer.sendall(b"POST /v1/configure HTTP/1.1\r\n")
                        response = bytearray()
                        while chunk := peer.recv(4096):
                            response.extend(chunk)
                        header, body = bytes(response).split(b"\r\n\r\n", 1)
                        assert header.startswith(b"HTTP/1.1 503 "), response
                        assert json.loads(body) == {
                            "version": "1", "type": "busy", "code": "ordinary_capacity_exhausted",
                        }, response
                    assert "Host: ready" in status(store, env)
                    for _ in range(3):
                        peer = socket.socket(socket.AF_UNIX)
                        borrowers.append(peer)
                        peer.settimeout(3)
                        peer.connect(socket_path)
                    assert "Host: ready" in status(store, env), "unknown routes blocked discovery"
                    for _ in range(3):
                        borrowers.pop().close()
                    for _ in range(2):
                        peer = socket.socket(socket.AF_UNIX)
                        borrowers.append(peer)
                        peer.settimeout(3)
                        peer.connect(socket_path)
                        peer.sendall(b"POST /v1/control/session-stop HTTP/1.1\r\n")
                        assert "Host: ready" in status(store, env)
                        peer.setblocking(False)
                        try:
                            assert peer.recv(1, socket.MSG_PEEK) != b"", "classified control was evicted"
                        except BlockingIOError:
                            pass
                        peer.settimeout(3)
                    for route in (b"/v1/control/session-stop", b"/v1/control/unknown"):
                        with socket.socket(socket.AF_UNIX) as excess:
                            excess.settimeout(3)
                            excess.connect(socket_path)
                            excess.sendall(b"POST " + route + b" HTTP/1.1\r\n")
                            response = bytearray()
                            while chunk := excess.recv(4096):
                                response.extend(chunk)
                            header, body = bytes(response).split(b"\r\n\r\n", 1)
                            assert header.startswith(b"HTTP/1.1 503 "), response
                            assert json.loads(body) == {
                                "version": "1", "type": "busy", "code": "control_capacity_exhausted",
                            }, response
                    peer = socket.socket(socket.AF_UNIX)
                    borrowers.append(peer)
                    peer.connect(socket_path)
                    assert "Host: ready" in status(store, env), "unknown route blocked reserved discovery"
                    for _ in range(3):
                        borrowers.pop().close()
                    # One stalled discovery must not borrow either control
                    # place. Exercise both request-line and body stalls.
                    fields = b"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: 2\r\n\r\n"
                    for tail in (b"", fields + b"{"):
                        discovery = socket.socket(socket.AF_UNIX)
                        borrowers.append(discovery)
                        discovery.settimeout(3)
                        discovery.connect(socket_path)
                        discovery.sendall(b"POST /v1/host-info HTTP/1.1\r\n" + tail)
                        with socket.socket(socket.AF_UNIX) as excess:
                            excess.settimeout(3)
                            excess.connect(socket_path)
                            excess.sendall(b"POST /v1/host-info HTTP/1.1\r\n")
                            response = bytearray()
                            while chunk := excess.recv(4096):
                                response.extend(chunk)
                            header, body = bytes(response).split(b"\r\n\r\n", 1)
                            assert header.startswith(b"HTTP/1.1 503 "), response
                            assert json.loads(body) == {
                                "version": "1", "type": "busy", "code": "discovery_capacity_exhausted",
                            }, response
                        for _ in range(2):
                            control = socket.socket(socket.AF_UNIX)
                            borrowers.append(control)
                            control.settimeout(3)
                            control.connect(socket_path)
                            control.sendall(b"POST /v1/control/session-stop HTTP/1.1\r\n" + tail)
                        # Finish both controls independently while the discovery
                        # body is still held. Their invalid envelopes must be
                        # decoded, not rejected as capacity or left unaccepted.
                        for control in borrowers[-2:]:
                            control.sendall(fields + b"{}" if not tail else b"}")
                            response = bytearray()
                            while chunk := control.recv(4096):
                                response.extend(chunk)
                            assert bytes(response).startswith(b"HTTP/1.1 400 "), response
                            assert json.loads(bytes(response).split(b"\r\n\r\n", 1)[1])["type"] == "invocation_error"
                        for _ in range(3):
                            borrowers.pop().close()
                        assert "Host: ready" in status(store, env)
                    stopped = subprocess.run(
                        [RUI, "host", "stop", "--store", store, "--instance", instance(reported, 8)],
                        env=env, text=True, capture_output=True, timeout=5,
                    )
                    assert stopped.returncode == 0 and "Stop acknowledged" in stopped.stdout, stopped
                finally:
                    for peer in borrowers:
                        peer.close()
            records = list((store / "diagnostics").glob("*.jsonl"))
            assert records and any(f"ordinary_intake={capacity}" in path.read_text() for path in records)
            print(f"detached startup {name}: {reported}", flush=True)
        finally:
            dispose_all(
                lambda: subprocess.run([RUI, "host", "stop", "--store", store], env=env, capture_output=True, timeout=5),
                lambda: wait_for_processes(store, 0),
            )

    store = root / "below-minimum"
    before = time.monotonic()
    failed = run_start(store, env, preexec_fn=lower_descriptor_limit)
    assert failed.returncode != 0 and time.monotonic() - before < 5, failed
    assert "DescriptorCapacityInsufficient" in failed.stderr and "exit status 1" in failed.stderr, failed.stderr
    assert "RLIMIT_NOFILE" in failed.stderr and "minimum intake" in failed.stderr, failed.stderr
    assert not (store / "host.lock").exists()

    # A genuine prior-format Store is covered by upgrade CI. This counterexample
    # independently drives refusal before schema reads on the real artifact.
    store = root / "soft-256"
    database = next(store.glob("*.sqlite*"))
    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA user_version=21")
    before = time.monotonic()
    failed = run_start(store, env)
    assert failed.returncode != 0 and time.monotonic() - before < 5, failed
    assert str(store.resolve()) in failed.stderr, failed.stderr
    assert "found schema 21" in failed.stderr and "supports schema 24" in failed.stderr, failed.stderr
    assert "back up" in failed.stderr and "exit status 1" in failed.stderr, failed.stderr
    with sqlite3.connect(database) as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 21
    for wire in (None, "future"):
        with sqlite3.connect(database) as connection:
            connection.execute("PRAGMA user_version=24")
            connection.execute("DELETE FROM store_meta WHERE key='wire_version'")
            if wire is not None:
                connection.execute("INSERT INTO store_meta(key,value) VALUES('wire_version',?)", (wire,))
        original = hashlib.sha256(database.read_bytes()).digest()
        before = time.monotonic()
        failed = run_start(store, env)
        assert failed.returncode != 0 and time.monotonic() - before < 5, failed
        assert "wire metadata" in failed.stderr and "wire 1" in failed.stderr, failed.stderr
        assert "unsupported Store format" not in failed.stderr, failed.stderr
        assert str(store) in failed.stderr and "back up" in failed.stderr and "No migration" in failed.stderr, failed.stderr
        assert hashlib.sha256(database.read_bytes()).digest() == original

    # Existing paths may contain controls. Their human presentation must be
    # safe, complete even beyond stderr.print's 1-KiB buffer, and remain data.
    parent = root / ("\x01" * 150)
    parent.mkdir(mode=0o700)
    hostile = parent / ("\x01" * 150 + "\nforged\x1b[2J\r\u202e\\\"")
    hostile.mkdir(mode=0o700)
    escaped = (str(hostile).replace("\\", "\\\\").replace('"', '\\"')
               .replace("\x01", "\\x01").replace("\n", "\\n").replace("\r", "\\r")
               .replace("\x1b", "\\x1b").replace("\u202e", "\\u202e"))
    failed = run_start(hostile, env, preexec_fn=lower_descriptor_limit)
    assert failed.returncode != 0 and "DescriptorCapacityInsufficient" in failed.stderr, failed
    assert f"startup failed for Store {escaped}:\n" in failed.stderr, failed.stderr
    assert str(hostile) not in failed.stderr and "\x1b" not in failed.stderr, failed.stderr
    # Clone only the stopped fixture DB. Version validation precedes selector
    # identity, so no relocation or metadata rebinding is needed for refusal.
    hostile_database = hostile / database.name
    with sqlite3.connect(database) as source, sqlite3.connect(hostile_database) as destination:
        source.backup(destination)
    hostile_database.chmod(0o600)
    for schema, wire in ((21, "1"), (24, None), (24, "future")):
        with sqlite3.connect(hostile_database) as connection:
            connection.execute(f"PRAGMA user_version={schema}")
            connection.execute("DELETE FROM store_meta WHERE key='wire_version'")
            if wire is not None:
                connection.execute("INSERT INTO store_meta(key,value) VALUES('wire_version',?)", (wire,))
        original = hashlib.sha256(hostile_database.read_bytes()).digest()
        before = time.monotonic()
        failed = run_start(hostile, env)
        assert failed.returncode != 0 and time.monotonic() - before < 5, failed
        assert f" at {escaped}: found schema {schema}" in failed.stderr, failed.stderr
        assert "back up" in failed.stderr and "No migration" in failed.stderr and "exit status 1" in failed.stderr
        assert str(hostile) not in failed.stderr and "\x1b" not in failed.stderr, failed.stderr
        assert hashlib.sha256(hostile_database.read_bytes()).digest() == original
    print("startup limits passed: soft raise, hard-limit fallback, below-minimum and unsupported-version fast failure", flush=True)


def wait_for_terminal_exit(caller, master, output, deadline):
    """Drain output through reap, including a retained slave without EOF."""
    while True:
        exited = caller.poll() is not None
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(caller.args, 5)
        if not select.select([master], [], [], 0 if exited else min(remaining, 0.05))[0]:
            if exited:
                return caller.wait(timeout=max(0, deadline - time.monotonic()))
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


@contextmanager
def launch_fixture_root():
    root = canonical_fixture_root(pathlib.Path(tempfile.mkdtemp(prefix="rui-host-launch-")))
    try:
        yield root
    except BaseException:
        failure_name = type(sys.exception()).__name__

        def retain():
            def metadata():
                diagnostics = {}
                remaining = 128 * 1024
                for path in sorted(root.glob("**/diagnostics/host-*.jsonl")):
                    if path.is_symlink():
                        continue
                    with path.open("rb") as stream:
                        data = stream.read(remaining + 1)
                    if len(data) > remaining:
                        diagnostics[str(path.relative_to(root))] = {"unavailable": "exceeds remaining diagnostic bound"}
                        break
                    diagnostics[str(path.relative_to(root))] = data.decode(errors="replace")
                    remaining -= len(data)
                return dict(failure=failure_name, host_diagnostics=diagnostics)
            preserve_failure_metadata(root / f"observation-failure-{os.getpid()}.json", metadata)
            destination = _failure_destination(os.environ.get("RUI_FAILURE_ARTIFACTS"))
            ci = str(pathlib.Path(__file__).resolve().parents[1] / "ci")
            sys.path.insert(0, ci)
            try:
                from run_selected import retain_failure_logs
                retain_failure_logs([root], destination)
            finally:
                sys.path.remove(ci)
            print(f"bounded fixture failure destination: {destination}", file=sys.stderr, flush=True)

        # Select only this executable's Hosts beneath the private root, even
        # before a nested default Store or its ownership lock exists.
        dispose_all(lambda: forced_crash_cleanup(root, descendants=True), retain,
                    lambda: print(f"retained native observation failure state: {root}", file=sys.stderr, flush=True))
        raise
    else:
        shutil.rmtree(root)


def main():
    assert len(sys.argv) in (2, 3), "usage: host_launch_integration.py /absolute/path/to/rui [startup-limits]"
    from host_launch_exit_test import check_exit_reader, check_process_discovery, check_failure_retention
    check_process_discovery(forced_crash_cleanup)
    check_exit_reader(wait_for_terminal_exit)
    check_failure_retention(launch_fixture_root, status)
    with launch_fixture_root() as root_text:
        root = canonical_fixture_root(pathlib.Path(root_text))
        home = root / "home"
        home.mkdir(mode=0o700)
        credential = root / "credentials" / "missing.json"
        env = environment(home, credential)
        startup_limits(root, env)
        if len(sys.argv) == 3:
            assert sys.argv[2] == "startup-limits"
            return
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
                for descriptor in range(2):
                    assert os.readlink(f"/proc/{pids[0]}/fd/{descriptor}") == "/dev/null"
                # The private startup error channel is not a retained caller
                # pipe: all launchers already drained their own stderr to EOF.
                assert os.readlink(f"/proc/{pids[0]}/fd/2").startswith("pipe:[")
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
        # The admitted eight-credit Host needs 460 descriptors for its
        # supported intake burst. Keep the inherited fd above that soft limit.
        inherited_store = root / "inherited-fd"
        read_fd, write_fd = os.pipe()
        inherited_fd = fcntl.fcntl(write_fd, fcntl.F_DUPFD, 768)
        try:
            def inherited_above_limit():
                soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (512, hard))

            inherited = run_start(inherited_store, env, pass_fds=(inherited_fd,),
                preexec_fn=inherited_above_limit)
            assert inherited.returncode == 0, inherited.stderr
        finally:
            os.close(inherited_fd)
            os.close(write_fd)
            try:
                ready, _, _ = select.select([read_fd], [], [], 1)
                assert ready and os.read(read_fd, 1) == b"", "detached Host inherited fd 768"
            finally:
                os.close(read_fd)
                forced_crash_cleanup(inherited_store)

        # An initially open readiness pipe whose reader disconnects during
        # startup must fail the handshake rather than claim ready.
        clean_env = {key: value for key, value in env.items()
            if key not in ("MallocMaxMagazines", "MallocSpaceEfficient", "RUI_HOST_MALLOC_DEFAULTS")}
        # The production default remains 1000. Its descriptor admission runs
        # before the lease/diagnostic writer, so rejection creates no Store.
        rejected_store = root / "default-capacity-rejected"
        rejected = subprocess.run([RUI, "serve", "--store", rejected_store],
            env=clean_env, preexec_fn=lower_descriptor_limit,
            capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
        assert rejected.returncode != 0, rejected
        assert "DescriptorCapacityInsufficient" in rejected.stderr, rejected.stderr
        fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", rejected.stderr)}
        assert fields["active_capacity"] == 1000 and fields["soft_limit"] == 64, fields
        assert fields["required"] > fields["soft_limit"], fields
        assert not rejected.stdout and not rejected_store.exists(), rejected

        # Capacity 8 is the existing desktop profile. Admit this child so the
        # disconnected pipe exercises readiness output, not pre-lease refusal.
        disconnected_store = root / "disconnected-stdout"
        disconnected = subprocess.Popen([RUI, "serve", "--store", disconnected_store, "--active-capacity", "8"],
            env=clean_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            disconnected.stdout.close()
            assert disconnected.wait(timeout=COMMAND_TIMEOUT) != 0
            stderr = disconnected.stderr.read().decode()
            assert "HostReadinessOutputUnavailable" in stderr, stderr
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
        master, slave = open_pty()
        caller = None
        try:
            original_terminal = termios.tcgetattr(master)
            caller = subprocess.Popen([RUI], cwd=root, env=bare_env,
                stdin=slave, stdout=slave, stderr=slave)
            output = bytearray()
            until = time.monotonic() + COMMAND_TIMEOUT
            while "› ".encode("utf-8") not in output:
                remaining = until - time.monotonic()
                assert remaining > 0 and select.select([master], [], [], remaining)[0], output
                chunk = os.read(master, 65536)
                assert chunk, ("terminal closed before prompt", output)
                assert len(output) + len(chunk) < PTY_OUTPUT_LIMIT, "unexpected unbounded terminal output"
                output.extend(chunk)
            # Automatic success is quiet; readiness is established separately
            # through protected status and the accepted Session below.
            assert all(noise not in output for noise in (b"Provider:", b"Model:", b"Permission:", b"request:", b"Session:", b"Workspace:")), output
            assert b"Bash runs without approval" in output, output
            assert b"Bash commands can run without asking you" not in output, output
            captures = list((bare_home / ".config/rui/requests").glob("*.json"))
            assert len(captures) == 1, captures
            captured = json.loads(captures[0].read_text())
            key = captures[0].stem
            reference = "rui/" + key
            assert captured["key"] == key and captured["kind"] == "configure", captured
            assert captured["session"] == reference and captured["store"] == str(bare_store.resolve()), captured
            configuration = captured["configuration"]
            assert configuration["workspace"] == {"state": "value", "value": str(root.resolve())}, captured
            assert configuration["provider"] == {"state": "value", "value": "codex"}, captured
            assert configuration["model"] == {"state": "value", "value": "gpt-6-luna"}, captured
            assert configuration["tools"] == {"state": "value", "value": ["bash"]}, captured
            assert configuration["permission_mode"] == {"state": "value", "value": "bypass"}, captured
            assert captured["require_model"] is True, captured
            assert key.encode() not in output and reference.encode() not in output, output
            assert len(wait_for_processes(bare_store, 1)) == 1
            # Transfer this thread's reader from prompt to exit without
            # withholding output credit or discarding any transcript bytes.
            os.set_blocking(master, False)
            deadline = time.monotonic() + 5
            assert os.write(master, b"/exit\n") == 6, "incomplete /exit submission"
            assert wait_for_terminal_exit(caller, master, output, deadline) == 0, output
            actual_terminal = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual_terminal[3] &= ~mask
                original_terminal[3] &= ~mask
            assert actual_terminal == original_terminal, (actual_terminal, original_terminal, output)
            assert b"Host ready" not in output and b"Attached to the ready Host" not in output and b"Diagnostics:" not in output, output
            assert instance(status(bare_store, bare_env), 8)
            inspected = subprocess.run([RUI, "inspect-session", "--store", bare_store, "--session", reference],
                env=bare_env, capture_output=True, text=True, timeout=5)
            assert inspected.returncode == 0, inspected.stderr
            current = json.loads(inspected.stdout)["session"]
            assert {name: current[name] for name in ("reference", "workspace", "provider", "model", "tools", "permission_mode")} == {
                "reference": reference, "workspace": str(root.resolve()), "provider": "codex",
                "model": "gpt-6-luna", "tools": ["bash"], "permission_mode": "bypass",
            }, current
            recovered = subprocess.run([RUI, "recover", key, "--json"],
                env=bare_env, capture_output=True, text=True, timeout=5)
            assert recovered.returncode == 0, recovered.stderr
            answer = json.loads(recovered.stdout)["answer"]
            assert answer["status"] == "accepted" and answer["replayed"] is True, answer
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
            assert elapsed < 5, elapsed
            assert "DescriptorCapacityInsufficient" in failed.stderr, failed.stderr
            assert "exit status 1" in failed.stderr, failed.stderr
            assert status(failure_store, env).startswith("Host: unavailable")
            assert not credential.exists()
        finally:
            forced_crash_cleanup(failure_store)

        print("host-launch passed: held lease, 6 aliases -> 1 capacity-8 Host, detached stdio, bounded failure")


if __name__ == "__main__":
    main()
