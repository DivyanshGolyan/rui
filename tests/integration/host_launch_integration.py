#!/usr/bin/env python3

import errno
from contextlib import closing, contextmanager, ExitStack
import json
import fcntl
import hashlib
import os
import pathlib
import pty
from terminal_process import close_pty, COLUMNS, ROWS, answers_to, open_pty, spawn, terminal_process
from terminal_screen import ScreenCapture
import re
import resource
import select
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import termios
import time

import host_process
from host_process import (canonical_fixture_root, start_ready_process, stop_process,
                          dispose_all, preserve_failure_metadata, _failure_destination,
                          copy_failure_diagnostics, wait_for, STORE_SCHEMA)
import codex_fixture
from model_fixture import stop_endpoint
from product_defaults import DEFAULTS
import os_semantics
from host_launch_fixture import COMMAND_TIMEOUT, RUI, dispose_provider_case, forced_crash_cleanup, matching_processes, run_start


SCHEMA = STORE_SCHEMA
DEFAULT_ACTIVE_CAPACITY = DEFAULTS.active_capacity
INTAKE = DEFAULTS.intake_capacity
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
extern int rui_launch_detached_reported(const char *, const char *const *, size_t, int, int *, int *, int *, unsigned long long *);
extern int rui_launch_input_pipe(int *, int *);

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "settings-descendant") == 0) {
        errno = 0;
        if (fcntl(5, F_GETFD) != -1 || errno != EBADF) return 112;
        return write(1, "isolated", 8) == 8 ? 0 : 113;
    }
    if (argc == 2 && strcmp(argv[1], "settings-child") == 0) {
        char bytes[6];
        if (fcntl(5, F_GETFD) != 0 || read(5, bytes, sizeof(bytes)) != 5 || memcmp(bytes, "frame", 5)) return 114;
        if (read(5, bytes, sizeof(bytes)) != 0 || fcntl(5, F_SETFD, FD_CLOEXEC) != 0) return 115;
        const char *next[] = {argv[0], "settings-descendant", NULL};
        execv(argv[0], (char *const *)next);
        return 116;
    }
    if (argc == 3 && strcmp(argv[1], "input-launch") == 0) {
        int mask = atoi(argv[2]);
        for (int fd = 0; fd < 3; fd++) if (mask & (1 << fd)) close(fd);
        int reader = -1, writer = -1;
        if (rui_launch_input_pipe(&reader, &writer) || write(writer, "frame", 5) != 5) return 117;
        close(writer);
        const char *next[] = {argv[0], "settings-child", NULL};
        int startup = -1, output = -1, pid = 0;
        unsigned long long started = 0;
        if (rui_launch_detached_reported(argv[0], next, 2, reader, &startup, &output, &pid, &started)) return 118;
        if (pid <= 0 || started == 0 || fcntl(reader, F_GETFD) != FD_CLOEXEC) return 119;
        close(reader);
        struct pollfd ready = {.fd = output, .events = POLLIN};
        if (poll(&ready, 1, 3000) <= 0) return 120;
        char reply[9];
        ssize_t count = read(output, reply, sizeof(reply));
        close(output);
        close(startup);
        return count == 8 && !memcmp(reply, "isolated", 8) ? 0 : 121;
    }
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
    source, actor = root / "launch-probe.c", root / "launch-probe"
    source.write_text(LAUNCH_PROBE)
    adapter = pathlib.Path(__file__).resolve().parents[2] / "src/host_launch.c"
    identity = adapter.with_name("host_identity.c")
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(source), str(adapter), str(identity),
                    "-pthread", "-o", str(actor)], check=True)
    output = root / "launch-probe-output"
    probe_env = {**env, "RUI_LAUNCH_PROBE_OUTPUT": str(output),
                 "RUI_LAUNCH_PROBE_VALUE": "inherited = value / λ",
                 "RUI_LAUNCH_PROBE_EMPTY": ""}
    result = subprocess.run([actor, "launch"], cwd=root, env=probe_env,
                            capture_output=True, timeout=5)
    assert result.returncode == 0, result
    for mask in range(8):
        result = subprocess.run([actor, "input-launch", str(mask)], env=probe_env,
                                capture_output=True, timeout=5)
        assert result.returncode == 0, ("private input inheritance and descendant isolation", mask, result)
    for mask in range(1, 8):
        result = subprocess.run([actor, "closed-startup", str(mask)], env=probe_env,
                                capture_output=True, timeout=5)
        assert result.returncode == 0, (mask, result)
    expected = [str(actor), "witness", "", "two words", "--not-a-launch-option", "final",
                probe_env["RUI_LAUNCH_PROBE_VALUE"], "", env["HOME"], "/", "closed"]
    observed = wait_for(lambda: output.read_bytes() if output.exists() else b"", f"the launch witness in {output} to finish",
                        timeout=5, interval=0.01, ready=lambda observed: observed.endswith((b"closed", b"inherited")))
    assert observed.split(b"\0") == [part.encode() for part in expected], observed


def environment(home, credential):
    return {
        **os.environ,
        "HOME": str(home),
        "RUI_CODEX_CREDENTIAL_FILE": str(credential),
    }


def status(store, env):
    result = subprocess.run(
        [RUI, "host", "status", "--store", store],
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
    )
    observation = json.dumps(dict(store=str(store), returncode=result.returncode,
                                  stdout=result.stdout, stderr=result.stderr)) + "\n"
    assert len(observation.encode()) <= 1024 * 1024, "status observation exceeds artifact bound"
    root = next((parent for parent in store.parents if parent.name.startswith("rui-host-launch-")), store.parent)
    (root / "probe.log").write_text(observation)
    assert result.returncode == 0, result.stderr
    value = json.loads(result.stdout)
    assert value["version"] == host_process.WIRE_VERSION and value["type"] == "host_status", result
    return value


def instance(output, capacity):
    assert output["status"] == "ready" and output["active_capacity"] == str(capacity), output
    assert re.fullmatch(r"[0-9a-f]{32}", output["instance"]), output
    return output["instance"]


def wait_for_processes(store, count, timeout=5):
    return wait_for(lambda: matching_processes(store), f"{count} Host processes", timeout=timeout, interval=0.02,
                    ready=lambda found: len(found) == count)


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


def assert_configure_defaults(root, store, env):
    home = root / "configure-defaults-home"
    home.mkdir(mode=0o700)
    home = home.resolve(strict=True)
    env = {**env, "HOME": str(home)}

    def configure(*arguments):
        result = subprocess.run([RUI, "session", "configure", "--store", store, *arguments],
            cwd=root, env=env, capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
        assert result.returncode == 0, result.stderr
        answer = json.loads(result.stdout)["answer"]
        assert answer["status"] == "accepted", answer
        return answer["session"]

    def settings(session):
        result = subprocess.run([RUI, "session", "inspect", "--store", store, "--session", session],
            env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        current = json.loads(result.stdout)["session"]
        return current["model"], current["tools"], current["permission_mode"]

    module = (DEFAULTS.recommended_model, DEFAULTS.tools.split(","), DEFAULTS.permission_mode)
    assert settings(configure()) == module
    addressed = configure("--workspace", root, "--provider", "codex", "--model", "gpt-6-sol")
    assert settings(addressed) == ("gpt-6-sol", *module[1:])
    configure("--session", addressed, "--tools", "none", "--permission-mode", "ask")
    configure("--session", addressed, "--compaction-trigger", "12345")
    assert settings(addressed) == ("gpt-6-sol", [], "ask")


def managed_descriptor_rejection(store, env, limit):
    def limits():
        resource.setrlimit(resource.RLIMIT_NOFILE, (limit, limit))
    before = time.monotonic()
    failed = run_start(store, env, preexec_fn=limits)
    assert failed.returncode == 1 and time.monotonic() - before < 5, failed
    for text in ("[internal_unexpected]", "RLIMIT_NOFILE",
                 "minimum intake", "ulimit -Hn", "rui host start"):
        assert text in failed.stderr, (text, failed.stderr)
    line = next(line for line in failed.stderr.splitlines() if "descriptor capacity insufficient:" in line)
    fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}
    inherited = fields["inherited"]
    assert inherited in os_semantics.INHERITED_DESCRIPTORS, fields
    fixed_host = os_semantics.HOST_FIXED_DESCRIPTORS
    authentication = os_semantics.AUTHENTICATION_DESCRIPTORS
    execution, clients = (DEFAULT_ACTIVE_CAPACITY - 1) * 5 + 10, INTAKE * 5 + 3
    expected = dict(active_capacity=DEFAULT_ACTIVE_CAPACITY, soft_limit=limit, inherited=inherited,
                    fixed_host=fixed_host, clients=clients, execution=execution,
                    authentication=authentication, self_wake=2,
                    required=inherited + fixed_host + clients + execution + authentication + 2)
    assert fields == expected, (fields, expected)
    assert not (store / "host.lock").exists() and not (store / "diagnostics").exists(), store
    assert status(store, env)["status"] != "ready"
    assert not matching_processes(store)
    return fields["required"]


def startup_limits(root, env):
    required = managed_descriptor_rejection(root / "hard-256", env, 256)
    minimum = required - 5 * (INTAKE - 10)
    observed = managed_descriptor_rejection(root / "hard-below-minimum", env, minimum - 1)
    if observed != required:
        required, minimum = observed, observed - 5 * (INTAKE - 10)
        assert managed_descriptor_rejection(root / "hard-below-minimum-again", env, minimum - 1) == required
    print(f"default capacity refused below {minimum} descriptors (default intake needs {required})", flush=True)
    for name, hard in (("soft-256", None), ("linux-1024", 1024), ("hard-minimum", minimum)):
        store = root / name
        def limits():
            _, inherited_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
            resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard) if hard else (256, inherited_hard))
        try:
            started = run_start(store, env, preexec_fn=limits)
            assert started.returncode == 0, started.stderr
            reported = status(store, env)
            assert reported["status"] == "ready", reported
            assert reported["active_capacity"] == str(DEFAULT_ACTIVE_CAPACITY), reported
            assert json.loads(started.stdout) == reported, (started, reported)
            capacity = int(reported["intake_capacity"])
            if hard == 1024:
                expected_capacity = INTAKE - max(0, (required - 1024 + 4) // 5)
                assert capacity == expected_capacity and reported["descriptor_limit"] == "1024", reported
            elif hard:
                assert capacity == 10 and reported["descriptor_limit"] == str(hard), reported
            else:
                assert capacity == INTAKE and int(reported["descriptor_limit"]) >= required, reported
            if hard == minimum:
                socket_path = f"/tmp/rui-{os.getuid()}/{hashlib.sha256(str(store).encode()).hexdigest()[:32]}.sock"
                borrowers = []
                try:
                    for _ in range(capacity):
                        peer = os_semantics.unix_stream()
                        borrowers.append(peer)
                        peer.settimeout(3)
                        peer.connect(socket_path)
                        peer.sendall(b"POST /v1/configure HTTP/1.1\r\n")
                    assert status(store, env)["status"] == "ready"
                    with os_semantics.unix_stream() as peer:
                        peer.settimeout(3)
                        peer.connect(socket_path)
                        peer.sendall(b"POST /v1/configure HTTP/1.1\r\n")
                        response = bytearray()
                        while chunk := peer.recv(4096):
                            response.extend(chunk)
                        header, body = bytes(response).split(b"\r\n\r\n", 1)
                        assert header.startswith(b"HTTP/1.1 503 "), response
                        assert json.loads(body) == {
                            "version": host_process.WIRE_VERSION, "type": "busy", "code": "ordinary_capacity_exhausted",
                        }, response
                    assert status(store, env)["status"] == "ready"
                    for _ in range(3):
                        peer = os_semantics.unix_stream()
                        borrowers.append(peer)
                        peer.settimeout(3)
                        peer.connect(socket_path)
                    assert status(store, env)["status"] == "ready", "unknown routes blocked discovery"
                    for _ in range(3):
                        borrowers.pop().close()
                    for _ in range(2):
                        peer = os_semantics.unix_stream()
                        borrowers.append(peer)
                        peer.settimeout(3)
                        peer.connect(socket_path)
                        peer.sendall(b"POST /v1/control/session-stop HTTP/1.1\r\n")
                        assert status(store, env)["status"] == "ready"
                        peer.setblocking(False)
                        try:
                            assert peer.recv(1, socket.MSG_PEEK) != b"", "classified control was evicted"
                        except BlockingIOError:
                            pass
                        peer.settimeout(3)
                    for route in (b"/v1/control/session-stop", b"/v1/control/unknown"):
                        with os_semantics.unix_stream() as excess:
                            excess.settimeout(3)
                            excess.connect(socket_path)
                            excess.sendall(b"POST " + route + b" HTTP/1.1\r\n")
                            response = bytearray()
                            while chunk := excess.recv(4096):
                                response.extend(chunk)
                            header, body = bytes(response).split(b"\r\n\r\n", 1)
                            assert header.startswith(b"HTTP/1.1 503 "), response
                            assert json.loads(body) == {
                                "version": host_process.WIRE_VERSION, "type": "busy", "code": "control_capacity_exhausted",
                            }, response
                    peer = os_semantics.unix_stream()
                    borrowers.append(peer)
                    peer.connect(socket_path)
                    assert status(store, env)["status"] == "ready", "unknown route blocked reserved discovery"
                    for _ in range(3):
                        borrowers.pop().close()
                    fields = b"Content-Type: application/json\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\nContent-Length: 2\r\n\r\n"
                    for tail in (b"", fields + b"{"):
                        discovery = os_semantics.unix_stream()
                        borrowers.append(discovery)
                        discovery.settimeout(3)
                        discovery.connect(socket_path)
                        discovery.sendall(b"POST /v1/host-info HTTP/1.1\r\n" + tail)
                        with os_semantics.unix_stream() as excess:
                            excess.settimeout(3)
                            excess.connect(socket_path)
                            excess.sendall(b"POST /v1/host-info HTTP/1.1\r\n")
                            response = bytearray()
                            while chunk := excess.recv(4096):
                                response.extend(chunk)
                            header, body = bytes(response).split(b"\r\n\r\n", 1)
                            assert header.startswith(b"HTTP/1.1 503 "), response
                            assert json.loads(body) == {
                                "version": host_process.WIRE_VERSION, "type": "busy", "code": "discovery_capacity_exhausted",
                            }, response
                        for _ in range(2):
                            control = os_semantics.unix_stream()
                            borrowers.append(control)
                            control.settimeout(3)
                            control.connect(socket_path)
                            control.sendall(b"POST /v1/control/session-stop HTTP/1.1\r\n" + tail)
                        for control in borrowers[-2:]:
                            control.sendall(fields + b"{}" if not tail else b"}")
                            response = bytearray()
                            while chunk := control.recv(4096):
                                response.extend(chunk)
                            assert bytes(response).startswith(b"HTTP/1.1 400 "), response
                            assert json.loads(bytes(response).split(b"\r\n\r\n", 1)[1])["type"] == "invocation_error"
                        for _ in range(3):
                            borrowers.pop().close()
                        assert status(store, env)["status"] == "ready"
                    stopped = subprocess.run(
                        [RUI, "host", "pause", "--store", store, "--instance", instance(reported, DEFAULT_ACTIVE_CAPACITY)],
                        env=env, text=True, capture_output=True, timeout=5,
                    )
                    assert stopped.returncode == 0 and json.loads(stopped.stdout)["status"] == "acknowledged", stopped
                finally:
                    for peer in borrowers:
                        peer.close()
            records = list((store / "diagnostics").glob("*.jsonl"))
            assert records and any(f"ordinary_intake={capacity}" in path.read_text() for path in records)
            print(f"detached startup {name}: {reported}", flush=True)
        finally:
            dispose_all(
                lambda: subprocess.run([RUI, "host", "pause", "--store", store], env=env, capture_output=True, timeout=5),
                lambda: wait_for_processes(store, 0),
            )

    store = root / "below-minimum"
    before = time.monotonic()
    failed = run_start(store, env, preexec_fn=lower_descriptor_limit)
    assert failed.returncode == 1 and time.monotonic() - before < 5, failed
    assert "[internal_unexpected]" in failed.stderr, failed.stderr
    assert "RLIMIT_NOFILE" in failed.stderr and "minimum intake" in failed.stderr, failed.stderr
    assert not (store / "host.lock").exists()

    store = root / "soft-256"
    database = next(store.glob("*.sqlite*"))
    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA user_version=21")
    before = time.monotonic()
    failed = run_start(store, env)
    assert failed.returncode == 1 and time.monotonic() - before < 5, failed
    assert str(store.resolve()) in failed.stderr, failed.stderr
    assert "found schema 21" in failed.stderr and f"supports schema {SCHEMA}" in failed.stderr, failed.stderr
    assert "back up" in failed.stderr and "[internal_unexpected]" in failed.stderr, failed.stderr
    with sqlite3.connect(database) as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 21
    for saved_format in (None, "future"):
        with sqlite3.connect(database) as connection:
            connection.execute(f"PRAGMA user_version={SCHEMA}")
            connection.execute("DELETE FROM store_meta WHERE meta_key='format'")
            if saved_format is not None:
                connection.execute("INSERT INTO store_meta(meta_key,meta_value) VALUES('format',?)", (saved_format,))
        original = hashlib.sha256(database.read_bytes()).digest()
        before = time.monotonic()
        failed = run_start(store, env)
        assert failed.returncode == 1 and time.monotonic() - before < 5, failed
        assert "format metadata" in failed.stderr and "wire metadata" not in failed.stderr, failed.stderr
        assert f"wire {host_process.WIRE_VERSION}" in failed.stderr, failed.stderr
        assert "unsupported Store format" not in failed.stderr, failed.stderr
        assert str(store) in failed.stderr and "back up" in failed.stderr and "No migration" in failed.stderr, failed.stderr
        assert hashlib.sha256(database.read_bytes()).digest() == original

    parent = root / ("\x01" * 150)
    parent.mkdir(mode=0o700)
    hostile = parent / ("\x01" * 150 + "\nforged\x1b[2J\r\u202e\\\"")
    hostile.mkdir(mode=0o700)
    failed = run_start(hostile, env, preexec_fn=lower_descriptor_limit)
    assert failed.returncode == 2 and "[store_path_malformed]" in failed.stderr, failed
    assert "\\x01" in failed.stderr and "detached Host startup failed" not in failed.stderr, failed.stderr
    assert str(hostile) not in failed.stderr and "\x1b" not in failed.stderr, failed.stderr
    parent = root / ("\u0080" * 100)
    parent.mkdir(mode=0o700)
    hostile = parent / ("\u0080" * 100 + "\u202e\\\"")
    hostile.mkdir(mode=0o700)
    escaped = (str(hostile).replace("\\", "\\\\").replace('"', '\\"')
               .replace("\u0080", "\\u0080").replace("\u202e", "\\u202e"))
    failed = run_start(hostile, env, preexec_fn=lower_descriptor_limit)
    assert failed.returncode == 1 and "[internal_unexpected]" in failed.stderr, failed
    assert f"startup failed for Store {escaped}:\n" in failed.stderr, failed.stderr
    assert str(hostile) not in failed.stderr and "\x1b" not in failed.stderr, failed.stderr
    hostile_database = hostile / database.name
    with sqlite3.connect(database) as source, sqlite3.connect(hostile_database) as destination:
        source.backup(destination)
    hostile_database.chmod(0o600)
    for schema, saved_format in ((21, "21"), (SCHEMA, None), (SCHEMA, "future")):
        with sqlite3.connect(hostile_database) as connection:
            connection.execute(f"PRAGMA user_version={schema}")
            connection.execute("DELETE FROM store_meta WHERE meta_key='format'")
            if saved_format is not None:
                connection.execute("INSERT INTO store_meta(meta_key,meta_value) VALUES('format',?)", (saved_format,))
        original = hashlib.sha256(hostile_database.read_bytes()).digest()
        before = time.monotonic()
        failed = run_start(hostile, env)
        assert failed.returncode == 1 and time.monotonic() - before < 5, failed
        assert f" at {escaped}: found schema {schema}" in failed.stderr, failed.stderr
        assert "back up" in failed.stderr and "No migration" in failed.stderr and "[internal_unexpected]" in failed.stderr
        assert str(hostile) not in failed.stderr and "\x1b" not in failed.stderr, failed.stderr
        assert hashlib.sha256(hostile_database.read_bytes()).digest() == original
    print("startup limits passed: soft raise, hard-limit minimum boundary, below-minimum and unsupported-version fast failure", flush=True)


def moved_store_identity(root, env, *, terminal=False):
    original = root / ("a" if terminal else 'saved-' + '\u0080' * 80 + '-\u202e-"-\\-store')
    moved = root / ("b" if terminal else 'moved-' + '\u0080' * 80 + '-\u202e-"-\\-store')
    child, _ = start_ready_process([RUI, "host", "serve", "--store", original], env=env)
    stop_process(child)
    database = original / "rui.sqlite3"
    assert database.is_file(), list(original.iterdir())
    with closing(sqlite3.connect(database)) as connection:
        metadata = connection.execute("SELECT meta_key,meta_value FROM store_meta ORDER BY meta_key").fetchall()
    original.rename(moved)
    database = moved / database.name
    digest = hashlib.sha256(database.read_bytes()).digest()
    escaped = lambda path: str(path).replace("\\", "\\\\").replace('"', '\\"').replace("\u0080", "\\u0080").replace("\u202e", "\\u202e")
    credential = root / "identity-credentials"
    codex_fixture.credentials(credential)
    interactive_env = {**env, "RUI_CODEX_CREDENTIAL_FILE": str(credential)}
    try:
        for alias in (False, True):
            if alias:
                original.symlink_to(moved, target_is_directory=True)
            selected = original if alias else moved
            for command in (("interactive",) if terminal else ("serve", "start")):
                if command == "interactive":
                    with terminal_process([RUI, "--store", selected, "--provider", "codex"], env=interactive_env, cwd=root) as (caller, master):
                        output = bytearray()
                        code = wait_for_terminal_exit(caller, master, output, time.monotonic() + COMMAND_TIMEOUT)
                        diagnostic = output.decode().replace("\r\n", "\n")
                else:
                    failed = subprocess.run([RUI, "host", command, "--store", selected],
                        env=env, capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
                    code, diagnostic = failed.returncode, failed.stderr
                assert code == 6, (command, alias, code, diagnostic)
                assert f"Saved original canonical folder: {escaped(original)}\n" in diagnostic, diagnostic
                assert f"Actual canonical folder: {escaped(moved)}\n" in diagnostic, diagnostic
                assert "[store_identity_mismatch]" in diagnostic and "internal_unexpected" not in diagnostic, diagnostic
                assert "Stop Hosts" in diagnostic and "preserve the complete Store" in diagnostic, diagnostic
                assert "symlink" in diagnostic and "back up" in diagnostic and "--store" in diagnostic, diagnostic
                assert all(control not in diagnostic for control in ("\x1b", "\u0080", "\u202e")), diagnostic
                assert hashlib.sha256(database.read_bytes()).digest() == digest
                with closing(sqlite3.connect(database)) as connection:
                    assert connection.execute("SELECT meta_key,meta_value FROM store_meta ORDER BY meta_key").fetchall() == metadata
        failures = [json.loads(line) for path in (moved / "diagnostics").glob("host-*.jsonl")
                    for line in path.read_text().splitlines() if json.loads(line).get("phase") == "failed"]
        assert len(failures) == (2 if terminal else 4) and all(row["detail"] == "store_identity_mismatch" for row in failures), failures
        original.unlink()
        moved.rename(original)
        restored, _ = start_ready_process([RUI, "host", "serve", "--store", original], env=env)
        stop_process(restored)
    finally:
        forced_crash_cleanup(moved)
        forced_crash_cleanup(original)
    surface = "all-streams PTY interactive" if terminal else "foreground and detached escaped paths"
    print(f"moved Store identity passed: {surface}, old-path symlink, unchanged identity, restored readiness", flush=True)


def host_command(env, *arguments):
    return subprocess.run([RUI, "host", *map(str, arguments)], env=env, capture_output=True,
                          text=True, timeout=COMMAND_TIMEOUT)


def host_ok(env, *arguments):
    completed = host_command(env, *arguments)
    assert completed.returncode == 0, (arguments, completed.returncode, completed.stderr)
    return completed


def new_host_provider_policy(root, env):
    import http.client
    import http.server
    import threading
    from settings_fixture import frame

    class RejectProxy(http.server.BaseHTTPRequestHandler):
        def do_CONNECT(self):
            with self.server.receipt_lock:
                self.server.targets.add(self.path)
                self.server.authorized |= any(name in self.headers for name in ("Authorization", "Proxy-Authorization"))
                self.server.requests += 1
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True

        def log_message(self, *args):
            pass

    proxy = host_process.TestHTTPServer(("127.0.0.1", 0), RejectProxy)
    proxy.receipt_lock = threading.Lock()
    proxy.targets = set()
    proxy.requests = 0
    proxy.authorized = False
    proxy_thread = threading.Thread(target=proxy.serve_forever)
    proxy_threads = {proxy: proxy_thread}
    proxy_url = f"http://127.0.0.1:{proxy.server_port}"

    private = root / "provider-policy"
    private.mkdir(mode=0o700)
    browser = private / "chatgpt.json"
    key = private / "openai.key"
    missing = private / "missing.json"
    policy_env = {**env, "RUI_CODEX_CREDENTIAL_FILE": str(missing),
                  "RUI_CHATGPT_CREDENTIAL_FILE": str(browser), "RUI_OPENAI_KEY_FILE": str(key),
                  "https_proxy": proxy_url, "HTTPS_PROXY": proxy_url, "no_proxy": "", "NO_PROXY": ""}
    none = {"codex": "unserved", "chatgpt": "unserved", "openai": "unserved"}
    exact = {"codex": "unserved", "chatgpt": "chatgpt_plan", "openai": "unserved"}
    checked = 0
    intercepted_cases = 0
    proxy_thread.start()
    try:
        with closing(http.client.HTTPConnection("127.0.0.1", proxy.server_port, timeout=5)) as probe:
            probe.request("CONNECT", "api.openai.com:443")
            assert probe.getresponse().status == 403
        for state, automatic in (
                ("missing", {"codex": "chatgpt_device", "chatgpt": "unserved", "openai": "unserved"}),
                ("invalid", {"codex": "chatgpt_device", "chatgpt": "unserved", "openai": "unserved"}),
                ("browser", {"codex": "chatgpt_device", "chatgpt": "chatgpt_plan", "openai": "unserved"}),
                ("key", {"codex": "chatgpt_device", "chatgpt": "unserved", "openai": "key_file"}),
                ("both", {"codex": "chatgpt_device", "chatgpt": "chatgpt_plan", "openai": "key_file"})):
            browser.unlink(missing_ok=True)
            key.unlink(missing_ok=True)
            if state == "invalid":
                browser.write_text("not a credential record\n")
                key.write_text("two words\n")
            if state in ("browser", "both"):
                browser.write_text(
                    "version=3\ngeneration=1\naccount_id=policy-subject\nclient_id=policy-client\n"
                    "fedramp=0\nid_token=e30.eyJzdWIiOiJwb2xpY3ktc3ViamVjdCJ9.c2ln\n"
                    "access_token=" + codex_fixture.ACCESS + "\nrefresh_token=synthetic-not-real\n"
                    "expires_at=4102444800\nrefreshed_at=1750000000\nstate=ready\n")
            if state in ("key", "both"):
                key.write_text("sk-synthetic-provider-policy\n")
            for credential in (browser, key):
                if credential.exists():
                    credential.chmod(0o600)
            for selection, providers, expected in (("omitted", None, automatic),
                                                    ("empty", {}, none),
                                                    ("exact", {"chatgpt": {}}, exact)):
                if selection == "exact" and state not in ("browser", "both"):
                    continue
                for door in ("serve", "start", "file", "stdin", "saved"):
                    store = private / f"{state}-{selection}-{door}"
                    document = {"store": {"sqlite": {"dir": str(store)}},
                                "interface": {"lifetime": "stdin"}}
                    if providers is not None:
                        document["providers"] = providers
                    process = None
                    with proxy.receipt_lock:
                        previous_requests = proxy.requests
                    try:
                        if door in ("start", "saved"):
                            if door == "saved":
                                store.mkdir(mode=0o700)
                                saved = store / "host.json"
                                saved.write_text(json.dumps({} if providers is None else {"providers": providers}))
                                saved.chmod(0o600)
                                shown = host_ok(policy_env, "settings", "--store", store)
                                assert set(json.loads(shown.stdout)["providers"]) == {
                                    name for name, route in expected.items() if route != "unserved"}, (state, selection, shown)
                                arguments = ()
                            else:
                                arguments = () if providers is None else ("--set", "providers=" + json.dumps(providers))
                            started = run_start(store, policy_env, *arguments)
                            assert started.returncode == 0, (state, selection, door, started)
                        else:
                            arguments = [RUI, "host", "serve", "--store", store]
                            if door == "file":
                                source = private / "input.json"
                                source.write_text(json.dumps(document))
                                source.chmod(0o600)
                                arguments += ["--settings", source]
                            elif door == "stdin":
                                arguments += ["--settings", "-"]
                            else:
                                arguments += ["--set", "interface.lifetime=stdin"]
                                if providers is not None:
                                    arguments += ["--set", "providers=" + json.dumps(providers)]
                            process = subprocess.Popen(arguments, env=policy_env, stdin=subprocess.PIPE,
                                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                            if door == "stdin":
                                process.stdin.write(frame(document))
                                process.stdin.flush()
                        def ready():
                            if process is not None:
                                assert process.poll() is None, (state, selection, door, process.communicate())
                            observed = host_command(policy_env, "status", "--store", store)
                            if observed.returncode != 0:
                                return None
                            info = json.loads(observed.stdout)
                            return info if info["status"] == "ready" else None
                        info = wait_for(ready, f"{state} {selection} {door} Host readiness", timeout=20)
                        assert info["capabilities"]["providers"] == expected, (state, selection, door, info)
                        assert not missing.exists(), "signed-out startup created credentials"
                        if expected["chatgpt"] != "unserved" or expected["openai"] != "unserved":
                            def intercepted():
                                with proxy.receipt_lock:
                                    return proxy.requests > previous_requests
                            wait_for(intercepted, f"{state} {selection} {door} loopback CONNECT refusal", timeout=10)
                            intercepted_cases += 1
                        checked += 1
                    finally:
                        dispose_provider_case(process, store)
        assert checked == 60 and intercepted_cases == 25, (checked, intercepted_cases)
        with proxy.receipt_lock:
            assert "api.openai.com:443" in proxy.targets, proxy.targets
            assert proxy.targets <= {"api.openai.com:443", "models.dev:443"}, proxy.targets
            assert not proxy.authorized, "provider authorization escaped a refused CONNECT"
    finally:
        stop_endpoint(proxy, proxy_threads)
    print(f"new Host provider policy: {checked} Host cases passed across serve/start/file/framed stdin/saved settings; "
          f"{intercepted_cases} usable-credential cases observed loopback CONNECT refusal to api.openai.com:443; "
          "no authorization headers or forwarding", flush=True)


def detached_settings_checks(root, env):
    """--check uses detached admission, resolves/seals, and never starts/stops a Host."""
    directory = root / "detached-checks"
    host_ok(env, "set", "--store", directory, "providers", "{}")
    sources = directory / "document.json"
    sources.write_text("{}")
    sources.chmod(0o600)
    original_files = {path.name for path in directory.iterdir()}
    cases = (
        ("bare", {}, (), None),
        ("nonplacement", {"execution": {"activeCapacity": 3}}, (), None),
        ("stdin-lifetime", {"interface": {"lifetime": "stdin"}}, (), "no stdin"),
        ("relative-path", {"tools": {"bash": {"path": "relative/bash"}}}, (), "absolute path"),
        ("relative-secret", {"providers": {"openai": {"key": {"file": "relative/key"}}}}, (), "absolute path"),
        ("unsaved-placement", {"interface": {"dir": str(root / "elsewhere")}}, (), "unsaved Store or interface"),
        ("unknown-leaf", {"unknown": True}, (), "unknown"),
        ("zero-capacity", {"execution": {"activeCapacity": 0}}, (), None),
        ("invalid-count", {"execution": {"activeCapacity": -1}}, (), "execution.activeCapacity"),
        ("seal", {"providers": {"codex": {"endpoint": "https://example.com/responses",
                   "credentialFile": str(root / "unread-credential")}}}, (), "providers.codex.endpoint"),
        ("resolve", {"providers": {"openai": {"key": {"env": "DETACHED_CHECK_ABSENT_KEY"}}}}, (), "providers.openai.key"),
    )
    for name, document, assignments, reason in cases:
        sources.write_text(json.dumps(document))
        sources.chmod(0o600)
        checked = host_command(env, "settings", "--check", "--store", directory,
                               "--settings", sources, *assignments)
        if reason is None:
            assert checked.returncode == 0 and not checked.stdout, (name, checked)
        else:
            assert checked.returncode == 2, (name, checked)
            failure = json.loads(checked.stdout)["rui_start_error"]
            assert failure["code"] == "settings_invalid" and reason in failure["message"], (name, checked)
            assert "[settings_invalid]" in checked.stderr and reason in checked.stderr, (name, checked)
        assert not matching_processes(directory), (name, checked)
    for arguments, reason in (
            (("--settings", "-"), "no stdin"),
            (("--settings", "relative.json"), "absolute path"),
            (("--set", "tools.bash=@relative.json"), "@FILE"),
            (("--set", "interface.lifetime=stdin"), "no stdin")):
        checked = host_command(env, "settings", "--check", "--store", directory, *arguments)
        assert checked.returncode == 2, (arguments, checked)
        failure = json.loads(checked.stdout)["rui_start_error"]
        assert failure["code"] == "settings_invalid" and reason in failure["message"], checked
        assert "[settings_invalid]" in checked.stderr and reason in checked.stderr, checked
    # No database, diagnostics or lease was created by a check.
    assert {path.name for path in directory.iterdir()} == original_files
    assert json.loads((directory / "host.json").read_text()) == {"providers": {}}
    absent = root / "check-does-not-create"
    checked = host_command(env, "settings", "--check", "--store", absent, "--set", "providers={}")
    assert checked.returncode == 0 and not absent.exists(), checked
    started = run_start(directory, env)
    assert started.returncode == 0, started
    try:
        before = status(directory, env)
        checked = host_command(env, "settings", "--check", "--store", directory,
                               "--set", "interface.lifetime=stdin")
        assert checked.returncode == 2, checked
        after = status(directory, env)
        assert before["instance"] == after["instance"] and after["status"] == "ready", (before, after)
    finally:
        forced_crash_cleanup(directory)
    print("detached settings check passed: sources, detached refusal, placement, resolution/seal, no Store effects, live Host unchanged", flush=True)


def frozen_settings_launches(root, env):
    """Admitted A survives deterministic public-source mutation before launch."""
    private = root / "frozen-settings"
    private.mkdir(mode=0o700)
    missing = private / "absent-credential"
    selected_env = {**env, "RUI_CODEX_CREDENTIAL_FILE": str(missing),
                    "RUI_CHATGPT_CREDENTIAL_FILE": str(missing), "RUI_OPENAI_KEY_FILE": str(missing)}
    none = {"codex": "unserved", "chatgpt": "unserved", "openai": "unserved"}
    automatic = {**none, "codex": "chatgpt_device"}
    exact = {"openai": {"endpoint": "http://127.0.0.1:9/v1/responses", "unauthenticated": True}}
    expected_exact = {**none, "openai": "endpoint"}

    def write_source(path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def held_start(directory, arguments, mutate, *, expected_refusal=None):
        gate = directory.parent / (directory.name + ".after-freeze.gate")
        gate.touch(mode=0o600)
        entered = gate.with_name(gate.name + ".entered")
        child = None
        try:
            child = subprocess.Popen([str(RUI), "host", "start", "--store", str(directory),
                                      *map(str, arguments)],
                                     env={**selected_env, "RUI_TEST_HOST_AFTER_FREEZE_GATE": str(gate)},
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

            def reached():
                if child.poll() is not None:
                    output, diagnostic = child.communicate(timeout=3)
                    raise AssertionError(("starter exited before freeze acknowledgement", child.returncode,
                                          output, diagnostic))
                return entered.exists()

            wait_for(reached, "parent admitted and counted frozen settings before launch", timeout=10)
            assert gate.exists() and child.poll() is None
            assert not matching_processes(directory), "Host launched before the freeze interposition"
            assert not (directory / "rui.sqlite3").exists()
            assert not (directory / "diagnostics").exists()
            mutate()
            assert gate.exists() and child.poll() is None
            gate.unlink()
            output, diagnostic = child.communicate(timeout=COMMAND_TIMEOUT)
            if expected_refusal is not None:
                assert child.returncode == 1, (child.returncode, output, diagnostic)
                report = json.loads(output)["rui_start_error"]
                assert report["code"] == "settings_invalid" and expected_refusal in report["message"], report
                assert not matching_processes(directory) and not (directory / "rui.sqlite3").exists()
                return report
            assert child.returncode == 0, (child.returncode, output, diagnostic)
            ready = json.loads(output)
            assert instance(ready, 2)
            return ready
        finally:
            dispose_all(lambda: gate.unlink(missing_ok=True),
                        lambda: stop_process(child) if child is not None else None)

    # A frozen source reference is not a frozen credential value. A child-only
    # resolution failure still crosses both startup channels as the ORIGINAL
    # typed refusal, rather than a generic child-closed outcome.
    failure_root = private / "referenced-file-refusal"
    failure_root.mkdir(mode=0o700)
    key = failure_root / "private-key"
    key.write_text("frozen-source-test-key")
    key.chmod(0o600)
    source = failure_root / "settings.json"
    write_source(source, {"providers": {"openai": {"endpoint": "https://127.0.0.1:9/v1/responses", "key": {"file": str(key)}}}})
    report = held_start(failure_root / "host", ["--settings", source], key.unlink,
                        expected_refusal="providers.openai.key")
    assert "frozen-source-test-key" not in json.dumps(report), report

    for label, payload in (("missing", b""), ("future", b"rui-host-settings-v99\n")):
        directory = private / ("refused-private-" + label)
        failed = subprocess.run([str(RUI), "host", "start", "--store", directory,
                                 "--settings-handoff-input-v1", "0"], input=payload,
                                env=selected_env, capture_output=True, timeout=COMMAND_TIMEOUT)
        assert failed.returncode == 2, (label, failed.returncode, failed.stdout, failed.stderr)
        assert json.loads(failed.stdout)["rui_start_error"]["code"] == "settings_invalid", failed.stdout
        assert not directory.exists() and not matching_processes(directory), "private refusal fell back to public sources"

    checked = 0
    # Every source door sees a valid changed B, malformed B, and removed B.
    # Rotate provider intent through omission, explicit none, and exact one.
    for door_index, door in enumerate(("saved", "file", "assignment-file")):
        for mutation_index, mutation in enumerate(("changed", "malformed", "removed")):
            case_root = private / f"{door}-{mutation}"
            case_root.mkdir(mode=0o700)
            directory = case_root / "host"
            policy = ("empty", "exact", "omitted")[(door_index + mutation_index) % 3]
            document = {"execution": {"activeCapacity": 2}}
            if policy != "omitted":
                document["providers"] = {} if policy == "empty" else exact
            expected = none if policy == "empty" else expected_exact if policy == "exact" else automatic
            arguments = []
            if door == "saved":
                directory.mkdir(mode=0o700)
                source = directory / "host.json"
                source_value = document
            elif door == "file":
                source = case_root / "settings.json"
                source_value = document
                arguments = ["--settings", source]
            else:
                source = case_root / "execution.json"
                source_value = document["execution"]
                arguments = ["--set", f"execution=@{source}"]
                if policy != "omitted":
                    arguments += ["--set", "providers=" + json.dumps(document["providers"])]
            write_source(source, source_value)
            admitted = source.read_bytes()

            def mutate():
                if door != "saved":
                    assert not directory.exists(), "source admission created the Host directory"
                if mutation == "changed":
                    replacement = json.loads(admitted)
                    if door == "assignment-file":
                        replacement["activeCapacity"] = 7
                    else:
                        replacement["execution"]["activeCapacity"] = 7
                    write_source(source, replacement)
                elif mutation == "malformed":
                    source.write_text("{not-json")
                else:
                    source.unlink()

            try:
                ready = held_start(directory, arguments, mutate)
                assert ready["capabilities"]["providers"] == expected, (door, mutation, policy, ready)
                # Saved document bytes also locate a later DIR client. Restore
                # them only AFTER launch returned positive A readiness with B
                # still installed; explicit and assignment sources stay B.
                if door == "saved":
                    source.write_bytes(admitted)
                observed = status(directory, selected_env)
                assert instance(observed, 2) == ready["instance"]
                assert observed["capabilities"]["providers"] == expected, observed
                assert (directory / "rui.sqlite3").is_file()
                checked += 1
            finally:
                forced_crash_cleanup(directory)

    # A private interface independent of long CI TMPDIR proves both the parent
    # route and child Store came from A, not just that some child was launched.
    with host_process.short_interface_directory() as interface:
        directory = private / "saved-placement"
        directory.mkdir(mode=0o700)
        source = directory / "host.json"
        data_a, data_b = directory / "data-a", directory / "data-b"
        document = {"providers": {}, "execution": {"activeCapacity": 2},
                    "store": {"sqlite": {"dir": str(data_a)}}, "interface": {"dir": str(interface)}}
        write_source(source, document)
        admitted = source.read_bytes()

        def move_source():
            assert not data_a.exists() and not data_b.exists()
            replacement = json.loads(admitted)
            replacement["execution"]["activeCapacity"] = 7
            replacement["store"]["sqlite"]["dir"] = str(data_b)
            write_source(source, replacement)

        try:
            ready = held_start(directory, [], move_source)
            assert ready["store"] == str(data_a.resolve()) and ready["capabilities"]["providers"] == none, ready
            assert (data_a / "rui.sqlite3").is_file() and not data_b.exists()
            assert (interface / "rui.sock").is_socket()
            source.write_bytes(admitted)
            observed = status(directory, selected_env)
            assert instance(observed, 2) == ready["instance"] and observed["store"] == str(data_a.resolve()), observed
            assert not data_b.exists(), "unadmitted B created a Store"
            checked += 1
        finally:
            forced_crash_cleanup(directory)

    # Each complete preset is a valid independent public input below 1 MiB.
    # Their composed frame exceeds 1 MiB, not merely a usual 64 KiB pipe, and
    # deleting both inputs proves the child did not reopen assignment files.
    directory = private / "large-frame-host"
    preset = {"model": "gpt-6-sol", "effort": "low", "compactAt": 100000,
              "tools": [], "permissionMode": "ask", "label": "Frozen preset",
              "instructions": "f" * (600 * 1024)}
    sources = [private / "first-preset.json", private / "second-preset.json"]
    arguments = ["--set", "execution.activeCapacity=2", "--set", "providers={}"]
    for name, source in zip(("first", "second"), sources):
        write_source(source, preset)
        assert source.stat().st_size < 1024 * 1024
        arguments += ["--set", f"presets.{name}=@{source}"]
    assert sum(source.stat().st_size for source in sources) > 1024 * 1024

    def remove_presets():
        assert not directory.exists()
        for source in sources:
            source.unlink()

    try:
        ready = held_start(directory, arguments, remove_presets)
        observed = status(directory, selected_env)
        assert instance(observed, 2) == ready["instance"]
        assert observed["capabilities"]["providers"] == none, observed
        assert all(not source.exists() for source in sources)
        checked += 1
    finally:
        forced_crash_cleanup(directory)

    # Literal credentials in a file are rejected before snapshot creation,
    # gate acknowledgement, directory creation, diagnostics, or a Host child.
    directory = private / "literal-refused-host"
    source = private / "literal-settings.json"
    secret = "native-freeze-never-print-this"
    write_source(source, {"providers": {"openai": {"key": {"value": secret}}}})
    gate = private / "literal-refused.gate"
    gate.touch(mode=0o600)
    try:
        refused = run_start(directory, {**selected_env, "RUI_TEST_HOST_AFTER_FREEZE_GATE": str(gate)},
                            "--settings", str(source))
        assert refused.returncode != 0 and "settings_invalid" in refused.stdout, refused
        assert secret not in refused.stdout + refused.stderr
        assert not directory.exists() and not matching_processes(directory)
        assert not gate.with_name(gate.name + ".entered").exists(), "unsafe sources reached the frozen boundary"
    finally:
        dispose_all(lambda: gate.unlink(missing_ok=True), lambda: forced_crash_cleanup(directory))
    print(f"frozen detached settings passed: {checked} positive A launches after source mutation, "
          "saved SQLite placement, provider omission/empty/exact, composed frame >1 MiB, literal refusal before effects", flush=True)


def resume_saved_host(root, env, directory, reference):
    with terminal_process([RUI, "session", "resume", "--store", directory, "--", reference], env=env, cwd=root) as (caller, master):
        output = bytearray()
        screen = ScreenCapture(COLUMNS, ROWS, reply=answers_to(master))
        until = time.monotonic() + COMMAND_TIMEOUT
        while "What shall we work on?" not in screen.completed or "Opening…" in screen.completed:
            remaining = until - time.monotonic()
            assert remaining > 0 and select.select([master], [], [], remaining)[0], (caller.poll(), screen.completed, output)
            chunk = os.read(master, 65536)
            assert chunk and len(output) + len(chunk) < PTY_OUTPUT_LIMIT, output
            output.extend(chunk)
            screen.feed(chunk)
        assert status(directory, env)["status"] == "ready"
        os.write(master, b"\x03")
        assert wait_for_terminal_exit(caller, master, output, time.monotonic() + 5) == 0, output


def saved_settings(root, env):
    store = root / "saved-settings"
    for path, value in (("execution.activeCapacity", "3"), ("execution.paused", "true"),
                        ("tools.bash.timeoutMs", "1234")):
        saved = host_command(env, "set", "--store", store, path, value)
        assert saved.returncode == 0 and not saved.stdout, saved
    document = store / "host.json"
    assert document.stat().st_mode & 0o777 == 0o600, oct(document.stat().st_mode)
    assert json.loads(document.read_text()) == {
        "execution": {"activeCapacity": 3, "paused": True}, "tools": {"bash": {"timeoutMs": 1234}}}, document.read_text()
    shown = host_command(env, "settings", "--store", store)
    assert shown.returncode == 0, shown
    effective = json.loads(shown.stdout)
    assert effective["tools"]["bash"]["timeoutMs"] == 1234 and effective["execution"]["paused"] is True, effective
    assert "codex" in effective["providers"], effective
    check = host_command(env, "settings", "--store", store, "--check")
    assert check.returncode == 0 and not check.stdout, check
    try:
        started = run_start(store, env)
        assert started.returncode == 0, started.stderr
        observed = status(store, env)
        assert instance(observed, 3) and observed["paused"] is True, observed
    finally:
        forced_crash_cleanup(store)
    unset = host_command(env, "unset", "--store", store, "execution.paused")
    assert unset.returncode == 0, unset
    assert "paused" not in json.loads(document.read_text())["execution"], document.read_text()

    literal = host_command(env, "set", "--store", store, "providers.openai.key", '{"value":"never-print-this"}')
    assert literal.returncode != 0 and "never-print-this" not in literal.stdout + literal.stderr, literal
    assert '"code":"settings_invalid"' in literal.stdout and "providers.openai.key" in literal.stdout, literal
    unknown = host_command(env, "set", "--store", store, "tools.bash.timeoutMS", "5")
    assert unknown.returncode != 0 and "nearest leaf: tools.bash.timeoutMs" in unknown.stdout, unknown

    private = root / "saved-settings-files"
    private.mkdir(mode=0o700)
    override = private / "settings.json"
    override.write_text('{"execution":{"activeCapacity":4}}')
    override.chmod(0o600)
    for arguments, capacity in ((("--settings", override), 4),
                                (("--settings", override, "--set", "execution.activeCapacity=6",
                                  "--set", "execution.activeCapacity=5"), 5)):
        ordered = root / f"saved-order-{capacity}"
        host_ok(env, "set", "--store", ordered, "execution.activeCapacity", "2")
        try:
            started = run_start(ordered, env, *map(str, arguments))
            assert started.returncode == 0, started.stderr
            assert instance(status(ordered, env), capacity)
        finally:
            forced_crash_cleanup(ordered)
    piped = run_start(root / "saved-pipe", env, "--settings", "-")
    assert piped.returncode != 0 and "rui host serve --settings -" in piped.stderr, piped

    # Saved placement is shared by foreground intake, the starter and clients.
    # A short interface remains necessary even under CI's long TMPDIR.
    for relocate_store, explicit in ((data, interface) for data in (False, True) for interface in (False, True)):
        with ExitStack() as interfaces:
            name = f"saved-placement-{int(relocate_store)}-{int(explicit)}"
            moved = root / name
            elsewhere = interfaces.enter_context(host_process.short_interface_directory()) if explicit else None
            home = root / f"{name}-home"
            home.mkdir(mode=0o700)
            selected_env = dict(env, HOME=str(home))
            try:
                host_ok(selected_env, "set", "--store", moved, "execution.paused", "true")
                if explicit:
                    host_ok(selected_env, "set", "--store", moved, "interface.dir", elsewhere)
                if relocate_store:
                    host_ok(selected_env, "set", "--store", moved, "store.sqlite.dir", moved / "data")
                too_long = host_command(selected_env, "set", "--store", moved, "interface.dir", "/" + "d" * 94)
                assert too_long.returncode == 2 and "interface.dir: path is longer than 94 bytes" in too_long.stderr, too_long
                defaults = subprocess.run([RUI, "defaults", "configure", "--store", moved], env=selected_env,
                                          text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
                assert defaults.returncode == 0, defaults
                chosen = json.loads(defaults.stdout)
                assert chosen["store"] == str(moved.resolve()) and chosen["store_available"], chosen
                assert chosen["host"]["status"] == "unavailable", chosen
                started = run_start(moved, selected_env)
                assert started.returncode == 0, started
                info = status(moved, selected_env)
                assert instance(info, DEFAULT_ACTIVE_CAPACITY)
                if explicit:
                    assert (elsewhere / "rui.sock").is_socket()
                defaults = subprocess.run([RUI, "defaults", "inspect"], env=selected_env,
                                          text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
                assert defaults.returncode == 0 and json.loads(defaults.stdout)["host"]["status"] == "ready", defaults
                retained = run_start(moved, selected_env, "--set", "execution.activeCapacity=3")
                assert retained.returncode == 0 and instance(json.loads(retained.stdout), DEFAULT_ACTIVE_CAPACITY) == info["instance"], retained
                assert f"rui host pause --store $'{moved.resolve()}'\n" in retained.stderr, retained
                record = root / f"{name}-request.json"
                command = subprocess.run([RUI, "session", "start",
                                          "--record", str(record), "--key", "placement-start",
                                          "--provider", "codex", "--model", "gpt-5.5", "--workspace", str(root)],
                                         env=selected_env, input="Saved placement evidence", text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
                assert command.returncode == 0, command
                receipt = json.loads(command.stdout)
                expected_store = (moved / "data" if relocate_store else moved).resolve()
                assert receipt["context"]["store"] == str(expected_store), receipt
                observed = subprocess.run([RUI, "request", "inspect", "--store", str(moved), "--key", "placement-start"],
                                          env=selected_env, text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
                assert observed.returncode == 0, observed
                replay = subprocess.run([RUI, "request", "recover", "--store", str(moved), "--record", str(record), "--kind", "message"],
                                        env=selected_env, text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
                assert replay.returncode == 0, replay
                configured = subprocess.run([RUI, "session", "configure", "--store", moved, "--workspace", root,
                                             "--provider", "codex", "--model", "gpt-5.5", "--tools", "none"],
                                            env=selected_env, text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
                assert configured.returncode == 0, configured
                reference = json.loads(configured.stdout)["answer"]["session"]
                resume_saved_host(root, selected_env, moved, reference)
                paused = host_command(selected_env, "pause", "--store", moved)
                assert paused.returncode == 0 and json.loads(paused.stdout)["retirement"] == "confirmed", paused
                resume_saved_host(root, selected_env, moved, reference)
                assert status(moved, selected_env)["instance"] != info["instance"]
                paused = host_command(selected_env, "pause", "--store", moved)
                assert paused.returncode == 0 and json.loads(paused.stdout)["retirement"] == "confirmed", paused
            finally:
                forced_crash_cleanup(moved)

    # Placement overrides cannot leave later directory clients guessing.
    with host_process.short_interface_directory() as unsaved_interface:
        unsaved = run_start(root / "unsaved-placement", env, "--set", f"interface.dir={unsaved_interface}")
        assert unsaved.returncode != 0 and "rui host set" in unsaved.stderr, unsaved

    typed = root / "saved-typed-relative"
    try:
        started = run_start(typed, env, "--set", f"store.sqlite.dir={typed.name}", cwd=root)
        assert started.returncode == 0, started.stderr
        assert (typed / "rui.sqlite3").is_file() and not pathlib.Path("/" + typed.name).exists(), started
    finally:
        forced_crash_cleanup(typed)
    def deleted_cwd(name):
        gone = root / name
        gone.mkdir()
        return lambda: (os.chdir(gone), os.rmdir(gone))
    orphaned = root / "saved-deleted-cwd"
    try:
        started = run_start(orphaned, env, "--set", "tools.bash.path=/bin/bash", preexec_fn=deleted_cwd("gone-absolute"))
        assert started.returncode == 0, started.stderr
    finally:
        forced_crash_cleanup(orphaned)
    refused = run_start(root / "saved-deleted-cwd-relative", env, "--set", "tools.bash.path=relative/bash",
                        preexec_fn=deleted_cwd("gone-relative"))
    assert refused.returncode == 2 and "tools.bash.path: the current directory no longer exists" in refused.stderr, refused
    assert not (root / "saved-deleted-cwd-relative").exists(), refused
    for path, value, leaf in (("tools.bash.path", "relative/bash", "tools.bash.path: a Host started in / has no base"),
                              ("interface.lifetime", "stdin", "interface.lifetime: a Host started by bare rui")):
        unrooted = root / f"saved-unrooted-{path}"
        if path == "tools.bash.path":
            # Existing files from before detached-safe edits must still refuse at start.
            unrooted.mkdir(mode=0o700)
            saved = unrooted / "host.json"
            saved.write_text(json.dumps({"tools": {"bash": {"path": value}}}))
            saved.chmod(0o600)
        else:
            host_ok(env, "set", "--store", unrooted, path, value)
        refused = run_start(unrooted, env)
        assert refused.returncode == 2 and leaf in refused.stderr and '"settings_invalid"' in refused.stdout, refused
        assert not matching_processes(unrooted), refused

    proxy_dir = root / "saved-proxy"
    for path, value in (("providers.openai.endpoint", "http://127.0.0.1:9/responses"),
                        ("providers.openai.unauthenticated", "true")):
        host_ok(env, "set", "--store", proxy_dir, path, value)
    keyless = root / "saved-keyless"
    host_ok(env, "set", "--store", keyless, "providers", '{"openai":{}}')
    for directory, changes, report in (
            (proxy_dir, {"HTTPS_PROXY": "https://proxy.example:1", "https_proxy": "https://proxy.example:1"},
             "Rui tunnels only through an http:// proxy. The Host did not start."),
            (keyless, {"RUI_OPENAI_KEY_FILE": str(root / "saved-absent-key")}, "[sign_in_required]")):
        failed = run_start(directory, dict(env, **changes))
        assert failed.returncode != 0 and not failed.stdout and report in failed.stderr, failed
        assert "settings_invalid" not in failed.stderr and not matching_processes(directory), failed

    for flag, value, replacement in (("--bash-timeout-ms", "1000", "--set tools.bash.timeoutMs=1000"),
                                     ("--active-capacity", "4", "--set execution.activeCapacity=4")):
        retired = host_command(env, "serve", "--store", root / "retired", flag, value)
        assert retired.returncode != 0 and replacement in retired.stderr, retired
    print("saved settings passed: sparse private host.json, settings/check, starter, unset, literal and unknown"
          " refusals, ordered sources, unreachable refusal, relative paths, child start failures, retired flags", flush=True)


def saved_settings_served(root, env):
    import bash_fixture
    import h2_fixture
    import model_fixture
    import ssl
    import threading
    from settings_fixture import WIRE, post
    from settings_fixture import mcp_server

    state = root / "saved-served-state"
    state.mkdir(mode=0o700)

    def save(store, path, value):
        saved = host_command(env, "set", "--store", store, path, value)
        assert saved.returncode == 0, saved

    docs, clash = mcp_server(["search"]), mcp_server(["bash"])
    mcp_store = root / "saved-mcp"
    try:
        token_env = {**env, "RUI_TEST_MCP_TOKEN": "t"}
        for name, server in (("docs", docs), ("clash", clash)):
            save(mcp_store, f"tools.mcp.{name}.url", f"http://127.0.0.1:{server.server_port}/mcp")
            save(mcp_store, f"tools.mcp.{name}.bearerToken", "env:RUI_TEST_MCP_TOKEN")
        refused = run_start(mcp_store, token_env)
        assert refused.returncode != 0 and "[tool_name_collision]" in refused.stderr, refused
        assert "clash" in refused.stderr and "bash" in refused.stderr, refused.stderr
        host_ok(env, "unset", "--store", mcp_store, "tools.mcp.clash")
        started = run_start(mcp_store, token_env)
        assert started.returncode == 0, started.stderr
    finally:
        forced_crash_cleanup(mcp_store)
        for server in (docs, clash):
            server.shutdown()
            server.server_close()

    responses = []
    bash_fixture.add_exchange(responses, "timeout", "printf before; sleep 30")
    endpoint = model_fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "saved-served"
    preset = {"model": "gpt-6-sol", "effort": "low", "compactAt": 100000,
              "tools": [], "permissionMode": "ask", "label": "Review"}
    preset_file = state / "preset.json"
    preset_file.write_text(json.dumps(preset))
    try:
        save(store, "providers.codex.endpoint", f"http://127.0.0.1:{endpoint.server_port}/responses")
        save(store, "providers.codex.unauthenticated", "true")
        save(store, "tools.bash.timeoutMs", "500")
        save(store, "presets.review", f"@{preset_file}")
        started = run_start(store, env)
        assert started.returncode == 0, started.stderr
        sock = f"/tmp/rui-{os.getuid()}/{hashlib.sha256(str(store.resolve()).encode()).hexdigest()[:32]}.sock"
        create = {"version": WIRE, "kind": "configure", "store": str(store.resolve()), "key": "preset:create",
                  "session": "", "preset": "review", "configuration": {"label": None}}
        created = post(sock, "configure", create)
        assert created["answer"]["status"] == "accepted", created
        inspected = post(sock, "inspect-session", {"version": WIRE, "kind": "inspect_session",
                                                   "store": str(store.resolve()), "session": created["answer"]["session"]})
        assert inspected["session"]["model"] == "gpt-6-sol" and inspected["session"]["reasoning_effort"] == "low", inspected
        session = bash_fixture.configure(state, store, "timeout-config")
        model_fixture.message(state, store, "timeout-message", session, "execute")
        action = model_fixture.wait_for(lambda: bash_fixture.action_for(store, session), "timeout Action")
        bash_fixture.allow(state, store, "timeout-allow", session, action["action"])
        model_fixture.wait_for(lambda: model_fixture.completed_observation(store, "timeout-message"), "timeout continuation")
        result = bash_fixture.result_text(store, session)
        assert result.startswith("Bash timed_out.") and "after a 500 ms total budget" in result, result
    finally:
        forced_crash_cleanup(store)
        endpoint.shutdown()
        endpoint.server_close()

    tls_root = root / "saved-tls"
    tls_root.mkdir(mode=0o700)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(tls_root / "key.pem"), "-out", str(tls_root / "cert.pem"),
                    "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(tls_root / "cert.pem", tls_root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    secure = h2_fixture.Endpoint(tls, 1, sse=True, eager_sse=True)
    threading.Thread(target=secure.serve_forever, daemon=True).start()
    tls_store = root / "saved-tls-store"
    try:
        save(tls_store, "providers.codex.endpoint", f"https://localhost:{secure.server_address[1]}/responses")
        save(tls_store, "providers.codex.unauthenticated", "true")
        save(tls_store, "network.caFile", tls_root / "cert.pem")
        started = run_start(tls_store, env)
        assert started.returncode == 0, started.stderr
        configured = model_fixture.command(
            "session", "configure", "--store", tls_store, "--record", state / "tls-config.json", "--key", "tls-config",
            "--workspace", model_fixture.ROOT, "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none")
        assert configured["answer"]["status"] == "accepted", configured
        tls_session = configured["answer"]["session"]
        model_fixture.message(state, tls_store, "tls-message", tls_session, "over-tls")
        observation, answer, _ = model_fixture.wait_for_result_release(
            tls_store, "tls-message", tls_session, time.monotonic() + 20)
        assert observation["result"]["status"] == "completed" and answer == b"answer-over-tls", (observation, answer)
        assert len(secure.streams) == 1, secure.streams
    finally:
        forced_crash_cleanup(tls_store)
        secure.shutdown()
        secure.server_close()
    print("saved settings served: MCP tools listed and a collision refused, preset Session created,"
          " Bash timed out at the saved 500 ms, provider reached over TLS with the saved CA file", flush=True)


def wait_for_terminal_exit(caller, master, output, deadline):
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
            copy_failure_diagnostics(root, destination)
            print(f"bounded fixture failure destination: {destination}", file=sys.stderr, flush=True)

        dispose_all(lambda: forced_crash_cleanup(root, descendants=True), retain,
                    lambda: print(f"retained native observation failure state: {root}", file=sys.stderr, flush=True))
        raise
    else:
        shutil.rmtree(root)


def contended_starters(root, env):
    # A fixture-held real lease makes the child lose without any scheduler race.
    # The existing acknowledged gate pins its parent's first unavailable probe
    # AFTER that child's store_locked report and startup EOF.
    for outcome in ("ready", "absent", "dies"):
        store = root / f"contended-{outcome}"
        store.mkdir(mode=0o700)
        gate = root / f"contended-{outcome}.gate"
        gate.touch(mode=0o600)
        loser = winner = None
        lock = os.fdopen(os.open(store / "host.lock", os.O_RDWR | os.O_CREAT, 0o600), "r+b")
        try:
            assert os_semantics.try_lock(lock), "a fresh Store's lease was already held"
            loser = subprocess.Popen(
                [RUI, "host", "start", "--store", store, "--set", "providers={}"],
                env={**env, "RUI_TEST_HOST_STORE_LOCKED_GATE": str(gate)},
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=True)
            wait_for(lambda: gate.with_suffix(gate.suffix + ".entered").exists(),
                     "the losing child's closed startup channel and unavailable owner", timeout=5)
            assert loser.poll() is None, "loser settled before its readiness budget"
            lock.close()
            lock = None
            if outcome != "absent":
                winner, ready = start_ready_process(
                    [RUI, "host", "serve", "--store", store, "--set", "providers={}"],
                    env=env, required_fields={"active_capacity": str(DEFAULT_ACTIVE_CAPACITY)})
                winning_instance = instance(status(store, env), DEFAULT_ACTIVE_CAPACITY)
                if outcome == "dies":
                    stop_process(winner)
                    winner = None
                    assert status(store, env)["status"] == "unavailable"
            gate.unlink()
            stdout, stderr = loser.communicate(timeout=COMMAND_TIMEOUT)
            if outcome == "ready":
                assert loser.returncode == 0, (loser.returncode, stdout, stderr)
                assert instance(json.loads(stdout), DEFAULT_ACTIVE_CAPACITY) == winning_instance
                assert instance(status(store, env), DEFAULT_ACTIVE_CAPACITY) == winning_instance
                assert wait_for_processes(store, 1) == [winner.pid]
                assert "store_locked" not in stdout + stderr, (stdout, stderr)
            else:
                assert loser.returncode == 1, (loser.returncode, stdout, stderr)
                assert json.loads(stdout) == {"rui_start_error": {
                    "code": "store_locked", "message": "another Host owns this Store"}}, stdout
                assert status(store, env)["status"] == "unavailable"
                assert not matching_processes(store), "refused starter left a Host"
        finally:
            gate.unlink(missing_ok=True)
            dispose_all(lambda: lock.close() if lock is not None else None,
                        lambda: stop_process(loser) if loser is not None else None,
                        lambda: stop_process(winner) if winner is not None else None,
                        lambda: forced_crash_cleanup(store))
    print("contended starters: delayed ready owner adopted; absent and retired winners preserve typed refusal", flush=True)


def host_refusal_receipts(root, env):
    # CLI-18
    directory = root / "saved-path-refusal"
    directory.mkdir(mode=0o700)
    saved = directory / "host.json"
    saved.write_text(json.dumps({"providers": {"openai": {"key": {"env": "PR7C_ABSENT_KEY"}}},
                                 "tools": {"bash": {"path": "relative/bash"}}}))
    saved.chmod(0o600)
    start = run_start(directory, env)
    assert start.returncode == 2, start
    failure = json.loads(start.stdout)["rui_start_error"]
    assert failure["code"] == "settings_invalid" and "tools.bash.path" in failure["message"], failure
    saved.write_text(json.dumps({"providers": {"openai": {"key": {"env": "PR7C_ABSENT_KEY"}}}}))
    before = saved.read_bytes()
    edit = host_command(env, "set", "--store", directory, "tools.bash.path", "relative/bash")
    assert edit.returncode == 2 and json.loads(edit.stdout)["rui_start_error"] == failure and saved.read_bytes() == before, edit
    assert edit.stderr.split(": ", 2)[2] == start.stderr.split(": ", 2)[2], (edit, start)
    after = run_start(directory, env)
    assert after.returncode == 1 and "tools.bash.path" not in after.stderr, after

    directory = root / "typed-child-refusal"
    directory.mkdir(mode=0o700)
    saved = directory / "host.json"
    saved.write_text(json.dumps({"providers": {"openai": {"key": {"env": "PR7C_ABSENT_KEY"}}}}))
    saved.chmod(0o600)
    selected_env = {**env, "RUI_STORE": str(directory)}
    selected_env.pop("PR7C_ABSENT_KEY", None)
    child = subprocess.run([RUI, "host", "serve", "--store", directory], env=selected_env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
    assert child.returncode == 2 and json.loads(child.stdout)["rui_start_error"]["code"] == "settings_invalid", child
    result = run_start(directory, selected_env)
    assert result.returncode == 1 and result.stdout == child.stdout, result
    assert result.stderr == child.stderr and "internal_unexpected" not in result.stderr, (child, result)
    credential = root / "typed-child-codex.json"
    codex_fixture.credentials(credential)
    selected_env["RUI_CODEX_CREDENTIAL_FILE"] = str(credential)
    master, slave = open_pty()
    bare = None
    try:
        bare = spawn([RUI, "--store", directory, "--provider", "codex"], env=selected_env, cwd=root, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        _, diagnostic = bare.communicate(timeout=COMMAND_TIMEOUT)
        assert bare.returncode == 1 and diagnostic.decode() == child.stderr, (bare.returncode, diagnostic, child)
    finally:
        if bare is not None and bare.poll() is None:
            bare.kill()
            bare.wait(timeout=5)
        close_pty(master, slave)
    managed_descriptor_rejection(root / "unexpected-parent", selected_env, 64)


def main():
    assert len(sys.argv) in (2, 3), "usage: host_launch_integration.py /absolute/path/to/rui [startup-limits|store-identity|provider-policy|detached-checks|frozen-settings|contention]"
    from host_launch_exit_test import check_exit_reader, check_process_discovery, check_failure_retention, check_provider_disposal
    with launch_fixture_root() as root_text:
        root = canonical_fixture_root(pathlib.Path(root_text))
        home = root / "home"
        home.mkdir(mode=0o700)
        credential = root / "credentials" / "missing.json"
        env = environment(home, credential)
        if len(sys.argv) == 3 and sys.argv[2] == "typed-refusal":
            host_refusal_receipts(root, env)
            return
        host_refusal_receipts(root, env)
        check_provider_disposal(dispose_provider_case, stop_endpoint)
        if len(sys.argv) == 3 and sys.argv[2] == "frozen-settings":
            frozen_settings_launches(root, env)
            return
        if len(sys.argv) == 3 and sys.argv[2] == "contention":
            contended_starters(root, env)
            return
        if len(sys.argv) == 3 and sys.argv[2] == "detached-checks":
            detached_settings_checks(root, env)
            return
        if len(sys.argv) == 3 and sys.argv[2] == "selection":
            saved_settings(root, env)
            return
        if len(sys.argv) == 3 and sys.argv[2] == "provider-policy":
            new_host_provider_policy(root, env)
            return
        check_process_discovery(forced_crash_cleanup)
        check_exit_reader(wait_for_terminal_exit)
        check_failure_retention(launch_fixture_root, status)
        if len(sys.argv) == 3 and sys.argv[2] == "store-identity":
            moved_store_identity(root, env)
            moved_store_identity(root, env, terminal=True)
            return
        moved_store_identity(root, env)
        moved_store_identity(root, env, terminal=True)
        startup_limits(root, env)
        if len(sys.argv) == 3:
            assert sys.argv[2] == "startup-limits"
            return
        assert_launch_adapter(root, env)
        contended_starters(root, env)

        held_store = root / "held-store"
        held, _ = start_ready_process(
            [RUI, "host", "serve", "--store", held_store, "--set", 'execution.activeCapacity=3'],
            required_fields={"active_capacity": "3"},
        )
        try:
            first = status(held_store, env)
            before = instance(first, 3)
            attached = run_start(held_store, env)
            assert attached.returncode == 0, attached.stderr
            reported = json.loads(attached.stdout)
            assert instance(reported, 3) == before, reported
            assert reported["diagnostics"] == f"{held_store.resolve()}/diagnostics", reported
            later = status(held_store, env)
            assert instance(later, 3) == before
            assert reported["started_at"] == later["started_at"] == first["started_at"], (first, later)
            assert later["custody_occupied"] == "0", later
            same = run_start(held_store, env, "--set", 'execution.activeCapacity=3')
            assert same.returncode == 0 and "--set assignments apply only to a new Host" in same.stderr, same
            assert instance(json.loads(same.stdout), 3) == before, same
            differing = run_start(held_store, env, "--set", 'execution.activeCapacity=7')
            assert differing.returncode == 0, differing.stderr
            assert instance(json.loads(differing.stdout), 3) == before, differing
            assert ("rui: the running Host keeps its settings; --set assignments apply only to a new Host. "
                    f"Changing settings means pausing this Host and all its work: rui host pause --store $'{held_store.resolve()}'\n"
                    ) in differing.stderr, differing.stderr
            assert instance(status(held_store, env), 3) == before
            assert wait_for_processes(held_store, 1) == [held.pid]
        finally:
            stop_process(held)

        new_host_provider_policy(root, env)
        detached_settings_checks(root, env)
        frozen_settings_launches(root, env)
        saved_settings(root, env)
        saved_settings_served(root, env)

        unparsed_store = root / "unparsed-capacity"
        unparsed = run_start(unparsed_store, env, "--set", 'execution.activeCapacity=-1')
        assert unparsed.returncode == 2 and '"code":"settings_invalid"' in unparsed.stdout, unparsed
        assert not unparsed_store.exists(), "unparsed capacity created a candidate Store"
        sized_store = root / "sized-store"
        try:
            sized = run_start(sized_store, env, "--set", 'execution.activeCapacity=5')
            assert sized.returncode == 0, sized.stderr
            assert instance(json.loads(sized.stdout), 5) == instance(status(sized_store, env), 5)
            assert len(wait_for_processes(sized_store, 1)) == 1
        finally:
            forced_crash_cleanup(sized_store)

        key_dir = root / "openai-private"
        key_dir.mkdir(mode=0o700)
        key_file = key_dir / "openai.key"
        key_file.write_text("two words\n")
        key_file.chmod(0o600)
        invalid_store = root / "openai-invalid-key"
        invalid_env = {**env, "RUI_OPENAI_KEY_FILE": str(key_file)}
        try:
            started = run_start(invalid_store, invalid_env)
            assert started.returncode == 0, started.stderr
            providers = status(invalid_store, invalid_env)["capabilities"]["providers"]
            assert providers == {"codex": "chatgpt_device", "openai": "unserved", "chatgpt": "unserved"}, providers
        finally:
            forced_crash_cleanup(invalid_store)
        key_file.write_text("sk-host-launch\n")
        openai_store = root / "openai-explicit-endpoint"
        openai_env = {**env, "RUI_OPENAI_KEY_FILE": str(key_file)}
        try:
            started = run_start(openai_store, openai_env, "--set", "providers.openai.endpoint=https://proxy.example/v1/responses")
            assert started.returncode == 0, started.stderr
            providers = status(openai_store, openai_env)["capabilities"]["providers"]
            assert providers["openai"] == "key_file", providers
        finally:
            forced_crash_cleanup(openai_store)

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
            identity = instance(ready, DEFAULT_ACTIVE_CAPACITY)
            assert instance(status(store, env), DEFAULT_ACTIVE_CAPACITY) == identity
            pids = wait_for_processes(store, 1)
            assert pids[0] not in launcher_pids, "Host remained the CLI launcher process"
            if os_semantics.PROC_FS:
                assert os.readlink(os_semantics.descriptor_link(pids[0], 0)) == "/dev/null"
                for descriptor in (1, 2):
                    assert os.readlink(os_semantics.descriptor_link(pids[0], descriptor)).startswith("pipe:[")
                assert os.readlink(os_semantics.working_directory_link(pids[0])) == "/", "detached Host retained launcher cwd"
                assert os.getsid(pids[0]) not in launcher_pids
            assert not credential.exists(), "Host startup opened or created credentials"
            started = [json.loads(stdout) for _, stdout, _ in results]
            assert all(instance(value, DEFAULT_ACTIVE_CAPACITY) == identity for value in started), results
            diagnostic_lines = [value["diagnostics"] for value in started]
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
            assert instance(status(ignored_child_store, env), DEFAULT_ACTIVE_CAPACITY)
        finally:
            forced_crash_cleanup(ignored_child_store)

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

        clean_env = {key: value for key, value in env.items()
            if key not in ("MallocMaxMagazines", "MallocSpaceEfficient", "RUI_HOST_MALLOC_DEFAULTS")}
        rejected_store = root / "default-capacity-rejected"
        rejected = subprocess.run([RUI, "host", "serve", "--store", rejected_store, "--set", "providers={}"],
            env=clean_env, preexec_fn=lower_descriptor_limit,
            capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
        assert rejected.returncode == 1, rejected
        assert "[internal_unexpected]" in rejected.stderr, rejected.stderr
        fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", rejected.stderr)}
        assert fields["active_capacity"] == DEFAULT_ACTIVE_CAPACITY and fields["soft_limit"] == 64, fields
        assert fields["required"] > fields["soft_limit"], fields
        assert not rejected.stdout and not rejected_store.exists(), rejected
        default_store = root / "default-capacity-serve"
        served, _ = start_ready_process(
            ["sh", "-c", 'ulimit -Sn 256; exec "$@"', "rui-soft-256", RUI, "host", "serve", "--store", default_store],
            env=clean_env, required_fields={"active_capacity": str(DEFAULT_ACTIVE_CAPACITY), "intake_capacity": str(INTAKE)},
        )
        stop_process(served)

        disconnected_store = root / "disconnected-stdout"
        disconnected = subprocess.Popen([RUI, "host", "serve", "--store", disconnected_store, "--set", 'execution.activeCapacity=8', "--set", "providers={}"],
            env=clean_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            disconnected.stdout.close()
            assert disconnected.wait(timeout=COMMAND_TIMEOUT) == 1
            stderr = disconnected.stderr.read().decode()
            assert "[internal_unexpected]" in stderr, stderr
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

        bare_home = root / "bare-home"
        bare_home.mkdir(mode=0o700)
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
            caller = spawn([RUI], cwd=root, env=bare_env,
                stdin=slave, stdout=slave, stderr=slave)
            output = bytearray()
            screen = ScreenCapture(COLUMNS, ROWS, reply=answers_to(master))
            until = time.monotonic() + COMMAND_TIMEOUT
            while not all(marker in screen.completed for marker in ("+ New chat", "Settings")):
                remaining = until - time.monotonic()
                assert remaining > 0 and select.select([master], [], [], remaining)[0], (screen.completed, output)
                chunk = os.read(master, 65536)
                assert chunk, ("terminal closed before prompt", output)
                assert len(output) + len(chunk) < PTY_OUTPUT_LIMIT, "unexpected unbounded terminal output"
                output.extend(chunk)
                screen.feed(chunk)
            assert all(noise not in screen.completed for noise in ("Provider:", "Model:", "Permission:", "request:", "Session:", "Workspace:")), screen.completed
            assert "What shall we work on?" not in screen.completed and "enter open" not in screen.completed, screen.completed
            assert not screen.plain, ("bypass notice left the frame", screen.plain)
            assert "Bash commands can run without asking you" not in screen.completed, screen.completed
            assert not list((bare_home / ".config/rui/requests").glob("*.json")), "the overview captured a request"
            assert len(wait_for_processes(bare_store, 1)) == 1
            assert status(bare_store, bare_env)["capabilities"]["providers"] == {
                "codex": "chatgpt_device", "chatgpt": "unserved", "openai": "unserved"}
            os.set_blocking(master, False)
            deadline = time.monotonic() + 5
            assert os.write(master, b"\x03") == 1, "incomplete Ctrl-C input"
            assert wait_for_terminal_exit(caller, master, output, deadline) == 0, output
            actual_terminal = termios.tcgetattr(slave)
            assert os_semantics.user_termios(actual_terminal) == os_semantics.user_termios(original_terminal), (actual_terminal, original_terminal, output)
            assert b"host_status" not in output and b'"diagnostics"' not in output, output
            assert instance(status(bare_store, bare_env), DEFAULT_ACTIVE_CAPACITY)
            listed = subprocess.run([RUI, "session", "list", "--store", bare_store, "--all"],
                env=bare_env, capture_output=True, text=True, timeout=5)
            assert listed.returncode == 0 and json.loads(listed.stdout)["sessions"] == [], listed
            assert_configure_defaults(root, bare_store, bare_env)
            stopped = subprocess.run([RUI, "host", "pause", "--store", bare_store],
                env=bare_env, capture_output=True, text=True, timeout=5)
            assert stopped.returncode == 0 and json.loads(stopped.stdout)["status"] == "acknowledged", stopped
        finally:
            try:
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
            finally:
                try:
                    close_pty(master)
                finally:
                    try:
                        if slave is not None:
                            close_pty(slave)
                    finally:
                        forced_crash_cleanup(bare_store)

        failure_store = root / "capacity-failure"
        started = time.monotonic()
        failed = run_start(failure_store, env, preexec_fn=lower_descriptor_limit)
        elapsed = time.monotonic() - started
        try:
            assert failed.returncode == 1
            assert elapsed < 5, elapsed
            assert "[internal_unexpected]" in failed.stderr, failed.stderr
            assert status(failure_store, env)["status"] == "unavailable"
            assert not credential.exists()
        finally:
            forced_crash_cleanup(failure_store)

        print(f"host-launch passed: held lease, 6 aliases -> 1 capacity-{DEFAULT_ACTIVE_CAPACITY} Host, detached stdio, bounded failure")


if __name__ == "__main__":
    host_process.enter()
    main()
