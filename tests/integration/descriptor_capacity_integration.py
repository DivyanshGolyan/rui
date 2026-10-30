#!/usr/bin/env python3
import errno
import http.server
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

import bash_integration as bash
import control_integration as control
import model_fixture as fixture
from host_process import HostDiagnostics, TestHTTPServer, canonical_fixture_root, dispose_all, retain_failure_state, start_ready_process, stop_process, wait_for
import os_semantics


RUI = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()
fixture.RUI = RUI
control.RUI = RUI


# Observe actual EMFILE as well as inject system-wide resource errors without
# exhausting the runner. This descriptor belongs to the fixture from startup.
ACCEPT_PROBE = r"""
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
static int log_fd;
__attribute__((constructor)) static void setup(void) {
    log_fd = open(getenv("RUI_ACCEPT_LOG"), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (log_fd < 0) _exit(90);
}
static int probe_accept(int fd, struct sockaddr *address, socklen_t *length) {
#ifdef __APPLE__
    int (*original)(int, struct sockaddr *, socklen_t *) = accept;
#else
    int (*original)(int, struct sockaddr *, socklen_t *) = dlsym(RTLD_NEXT, "accept");
#endif
    if (!original || original == probe_accept) _exit(91);
    int result;
    if (!access(getenv("RUI_ACCEPT_ARM"), F_OK)) {
        errno = atoi(getenv("RUI_ACCEPT_ERRNO"));
        result = -1;
    } else result = original(fd, address, length);
    int saved = errno;
    if (result >= 0 || (saved != EAGAIN && saved != EINTR && saved != ECONNABORTED)) {
        static unsigned failures;
        if (result < 0 && ++failures > 128) _exit(92); // Fail closed on a retry spin.
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now)) _exit(93);
        char record[96];
        int count = snprintf(record, sizeof(record), "%d %lld\n", result >= 0 ? 0 : saved,
            (long long)now.tv_sec * 1000000000LL + now.tv_nsec);
        if (count <= 0 || count >= sizeof(record) || write(log_fd, record, count) != count) _exit(94);
    }
    const char *hold = getenv("RUI_ACCEPT_HOLD");
    if (result >= 0 && hold && !access(hold, F_OK)) {
        if (unlink(hold)) _exit(95); // One selected acquisition, before caller flagging.
        struct stat identity;
        if (fstat(result, &identity)) _exit(96);
        int ready = open(getenv("RUI_ACCEPT_READY"), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (ready < 0) _exit(97);
        char record[128];
        int count = snprintf(record, sizeof(record), "%d %llu %llu\n", result,
            (unsigned long long)identity.st_dev, (unsigned long long)identity.st_ino);
        if (count <= 0 || count >= sizeof(record) || write(ready, record, count) != count || close(ready)) _exit(98);
        struct timespec pause = { .tv_nsec = 1000000 };
        unsigned waits = 0;
        while (access(getenv("RUI_ACCEPT_RELEASE"), F_OK)) {
            if (++waits > 10000) _exit(99);
            nanosleep(&pause, NULL);
        }
    }
    errno = saved;
    return result;
}
#ifdef __APPLE__
__attribute__((used, section("__DATA,__interpose"))) static struct {
    const void *replacement; const void *original;
} interpose_accept = { (const void *)probe_accept, (const void *)accept };
#else
int accept(int fd, struct sockaddr *address, socklen_t *length) { return probe_accept(fd, address, length); }
#endif
"""


class HeldEndpoint(TestHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), HeldHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.completed = 0
        self.release = threading.Event()

    def wait_for(self, field, count, timeout=10):
        deadline = time.monotonic() + timeout
        with self.condition:
            while getattr(self, field) < count:
                remaining = deadline - time.monotonic()
                assert remaining > 0, f"timed out waiting for {field}={count}"
                self.condition.wait(remaining)


class HeldHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            self.server.condition.notify_all()
        assert self.server.release.wait(10), "provider fixture was never released"
        body = b'{"error":"descriptor capacity fixture"}'
        self.send_response(422)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
        with self.server.condition:
            self.server.completed += 1
            self.server.condition.notify_all()

    def log_message(self, _format, *_args):
        pass


def limited_host(limit, *arguments):
    return [
        "sh",
        "-c",
        'ulimit -n "$1"; shift; exec "$@"',
        "rui-descriptor-limit",
        str(limit),
        str(RUI),
        *map(str, arguments),
    ]


def command(state, *arguments, input=None):
    completed = subprocess.run(
        [str(RUI), *map(str, arguments)],
        text=True,
        input=input,
        capture_output=True,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


def configure(state, store, ordinal):
    result = command(
        state,
        "session", "configure",
        "--store",
        store,
        "--record",
        state / f"configure-{ordinal}.json",
        "--key",
        f"configure-{ordinal}",
        "--workspace",
        ROOT,
        "--provider",
        "codex",
        "--model",
        "gpt-6-sol",
    )
    assert result["answer"]["status"] == "accepted", result
    return result["answer"]["session"]


def message(state, store, session, ordinal):
    result = command(
        state,
        "session", "send",
        "--store",
        store,
        "--to",
        session,
        "--record",
        state / f"message-{ordinal}.json",
        "--key",
        f"message-{ordinal}",
        input=f"descriptor fill {ordinal}",
    )
    assert result["answer"]["status"] == "accepted", result


def observe(state, store, ordinal):
    return command(
        state,
        "request", "inspect",
        "--store",
        store,
        "--key",
        f"message-{ordinal}",
    )["observation"]


def failed_result(state, store, ordinal):
    observation = observe(state, store, ordinal)
    return observation if observation.get("result", {}).get("code") == "provider_http_422" else None


def execution_idle(state, store, session):
    report = command(state, "session", "inspect", "--store", store, "--session", session)
    execution = report["execution"]
    return report if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0" else None


def open_gate(path):
    os.mkfifo(path)
    return os.open(path, os.O_RDWR | os.O_NONBLOCK)


def assert_connections_live(connections):
    for ordinal, connection in enumerate(connections):
        original_timeout = connection.gettimeout()
        connection.settimeout(0.001)
        try:
            unexpected = connection.recv(1, socket.MSG_PEEK)
        except TimeoutError:
            continue
        finally:
            connection.settimeout(original_timeout)
        raise AssertionError(
            f"held connection {ordinal} responded or closed before Bash spawn: {unexpected!r}"
        )


def admitted_at_gate(diagnostics, ordinal):
    records = diagnostics.wait("action_attempt_admitted", action=str(ordinal + 1))
    assert len(records) == 1, records
    return records[0]


def prove_borrower_oracle():
    # Independent golden endpoints for two fixture-issued exchanges. Channel
    # validity is not authority for a missing last start/release before begin.
    golden = [dict(rui_test_phase=phase, subject_kind="request_number", subject=str(subject),
                   process="123", run="37", clock="awake_ns", sequence=str(sequence), at_ns=str(at))
              for phase, subject, sequence, at in (
                  ("connection_request_configure", 0, 1, 5), ("connection_resources_released", 0, 2, 7),
                  ("connection_request_inspect", 1, 3, 11), ("connection_resources_released", 1, 4, 13))]
    for case in ("normal", "missing-final-both", "missing-final-release", "wrong-route", "wrong-number", "wrong-run", "reversed", "duplicate"):
        records = [dict(record) for record in golden]
        if case == "missing-final-both":
            records = records[:2]
        elif case == "missing-final-release":
            records = records[:3]
        elif case == "wrong-route":
            records[2]["rui_test_phase"] = "connection_request_message"
        elif case == "wrong-number":
            records[2]["subject"] = "2"
        elif case == "wrong-run":
            records[3]["run"] = "38"
        elif case == "reversed":
            records[3].update(sequence="1", at_ns="9")
        elif case == "duplicate":
            records.append(dict(records[3]))
        process = SimpleNamespace(pid=123, poll=lambda: 0,
            stderr=io.BytesIO(b"".join((json.dumps(record) + "\n").encode() for record in records)))
        diagnostics = HostDiagnostics(process)
        diagnostics.thread.join(1)
        try:
            diagnostics.borrower_census(time.monotonic() + .02, ["configure", "inspect"])
        except AssertionError:
            assert case != "normal", "complete asymmetric golden population was refused"
        else:
            assert case == "normal", ("invalid endpoint population accepted", case)
        finally:
            diagnostics.close()
    print("descriptor oracle: independent final population, missing start/release, wrong route/number/run, reversed and duplicate controls passed", flush=True)


def prove_bash_spawn_with_full_client_population(state, required):
    store = state / "bash-client-overlap-store"
    gate_path = state / "bash-client-overlap-gate"
    keeper = open_gate(gate_path)
    releases = [state / f"bash-release-{ordinal}" for ordinal in range(2)]
    markers = [state / f"bash-marker-{ordinal}" for ordinal in range(2)]
    commands = [
        f"printf x > {shlex.quote(str(marker))}; "
        f"i=0; while [ ! -e {shlex.quote(str(release))} ] && [ \"$i\" -lt 3000 ]; "
        "do sleep 0.01; i=$((i+1)); done"
        for marker, release in zip(markers, releases)
    ]
    responses = [
        fixture.sse_tool_calls(
            f"descriptor-bash-{ordinal}-calls",
            [
                (
                    "bash",
                    f"descriptor-bash-{ordinal}-call",
                    json.dumps({"cmd": commands[ordinal], "timeout_ms": None, "description": f"Write descriptor marker {ordinal}"}, separators=(",", ":")),
                )
            ],
        )
        for ordinal in range(2)
    ]
    responses += [
        fixture.sse_answer(
            f"descriptor-bash-{ordinal}-answer",
            f"descriptor-bash-{ordinal}-reasoning",
            f"descriptor-bash-{ordinal}-message",
            "done",
        )[0]
        for ordinal in range(2)
    ]
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    host = None
    diagnostics = None
    held = []
    completed = False
    expected_routes = []
    try:
        # Two inherited observation descriptors are counted by startup: writer
        # and publication-state file (closed after mapping). The FIFO adds one
        # live descriptor at spawn. Thus requirement = production + 2, and
        # limit = production + 2 + 1; the unobserved main witness stays exact.
        witness_limit = required + 2 + 1
        host, ready = start_ready_process(
            limited_host(
                witness_limit,
                "host", "serve",
                "--store",
                store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
                "--test-phase-trace",
                "--test-transition",
                "action-attempt-admitted",
                "--test-transition-gate-path",
                gate_path,
            ),
            required_fields={"descriptor_requirement": str(required + 2), "descriptor_limit": str(witness_limit)},
            observations="status",
        )
        diagnostics = HostDiagnostics(host)
        sessions = []
        for ordinal in range(2):
            expected_routes.append("configure")
            session = bash.configure(state, store, f"bash-configure-{ordinal}", permission="bypass")
            sessions.append(session)
            expected_routes.append("message")
            fixture.message(state, store, f"bash-message-{ordinal}", session, f"run bash {ordinal}")
            admitted_at_gate(diagnostics, ordinal)
            if ordinal == 0:
                os.write(keeper, b"x")
                wait_for(markers[0].exists, "first Bash process", timeout=10)

        socket_path = ready["socket"]
        diagnostics.borrower_census(time.monotonic() + 10, expected_routes)
        starts = []
        population_deadline = time.monotonic() + 10
        # Ten numbered body borrowers, then exactly two incomplete request
        # lines. No saturation retries can supply or hide retirement evidence.
        for ordinal in range(10):
            expected_routes.append("inspect")
            held.append(control.open_partial(socket_path, "/v1/inspect-session"))
            records = diagnostics.wait("connection_request_inspect", count=ordinal + 1,
                                       timeout=max(0, population_deadline - time.monotonic()))
            assert len(records) == ordinal + 1, records
            starts.append(records[-1])
        for _ in range(2):
            connection = socket.socket(socket.AF_UNIX)
            connection.settimeout(3)
            connection.connect(socket_path)
            connection.sendall(b"POST /v1/")
            held.append(connection)
        assert len(held) == 12
        expected_routes.extend(("observe", "host_info"))
        control.assert_intake_progress(socket_path, store)
        assert_connections_live(held)
        for started in starts:
            assert not diagnostics.matching("connection_resources_released", subject=started["subject"]), started

        os.write(keeper, b"x")
        wait_for(markers[1].exists, "second Bash spawn with full clients", timeout=10)
        assert_connections_live(held)
        deadline = time.monotonic() + 10
        for connection, started in zip(held[:10], starts):
            assert not diagnostics.matching("connection_resources_released", subject=started["subject"]), started
            began_ns = time.monotonic_ns()
            connection.close()
            released = diagnostics.borrower_release(started, deadline)
            assert int(released["at_ns"]) >= began_ns, (started, released)
        # These borrowers have no request number. Retire them serially to
        # correlate each native admission decrement with its own local close.
        classification_releases = []
        for ordinal, connection in enumerate(held[10:]):
            assert len(diagnostics.matching("connection_place_released")) == ordinal
            began_ns = time.monotonic_ns()
            connection.close()
            records = diagnostics.wait("connection_place_released", count=ordinal + 1,
                                       timeout=max(0, deadline - time.monotonic()))
            assert len(records) == ordinal + 1, records
            record = records[-1]
            assert record["subject_kind"] == "place" and record["subject"] == "classification", record
            assert record["process"] == str(host.pid) and record["run"] == starts[0]["run"], record
            assert record["clock"] == "awake_ns" and int(record["at_ns"]) >= began_ns, record
            assert int(record["sequence"]) > int(starts[-1]["sequence"]), record
            if classification_releases:
                previous = classification_releases[-1]
                assert int(record["sequence"]) > int(previous["sequence"]), records
                assert int(record["at_ns"]) >= int(previous["at_ns"]), records
            classification_releases.append(record)
        held = []
        diagnostics.borrower_census(deadline, expected_routes)
        print("descriptor borrower retirement:", json.dumps(
            [diagnostics.borrower_release(started, deadline) for started in starts]
            + classification_releases), flush=True)
        for release in releases:
            release.touch()
        probes = 0

        def bounded_probe(predicate):
            nonlocal probes
            probes += 1
            assert probes <= 40, "descriptor fixture exceeded status-plan probe population"
            expected_routes.append("inspect")  # Both resolution and idle predicates issue one inspection.
            result = predicate()
            diagnostics.borrower_census(deadline, expected_routes)
            return result
        for ordinal, session in enumerate(sessions):
            deadline = time.monotonic() + 10
            wait_for(lambda session=session: bounded_probe(lambda: bash.resolution(store, session) == "succeeded"), f"Bash {ordinal} result", timeout=10)
        deadline = time.monotonic() + 10
        wait_for(lambda: bounded_probe(lambda: execution_idle(state, store, sessions[0])), "Bash overlap execution drain", timeout=10)
        assert host.poll() is None, diagnostics.tail()
        completed = True
    except BaseException:
        if diagnostics is not None:
            with diagnostics.condition:
                print("descriptor failure endpoints:", json.dumps(diagnostics.records[-12:]), flush=True)
            print("descriptor failure stderr:", repr(diagnostics.tail()), flush=True)
        raise
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for connection in held:
            connection.close()
        for release in releases:
            release.touch(exist_ok=True)
        for dispose in (lambda: stop_process(host) if host is not None else None,
                        lambda: os.close(keeper), endpoint.shutdown, endpoint.server_close,
                        lambda: endpoint_thread.join(timeout=3)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        try:
            if completed and diagnostics is not None:
                diagnostics.borrower_census(time.monotonic(), expected_routes)
                assert len(diagnostics.matching("connection_place_released")) == 2
                assert len(diagnostics.matching("action_attempt_admitted")) == 2
        except BaseException as error:
            diagnostics.snapshot_failure(lambda: {"case": "descriptor_final_population"})
            diagnostics.observations.preserve_failure(getattr(host, "rui_failure_snapshot", None))
            errors.append(error)
        if endpoint_thread.is_alive():
            errors.append(AssertionError("Descriptor endpoint thread did not retire"))
        if errors:
            if incoming_error is None:
                raise errors[0]
            incoming_error.add_note("Descriptor cleanup failed: " + ", ".join(type(error).__name__ for error in errors))


def accept_records(log, *, final=False):
    contents = log.read_bytes()
    end = contents.rfind(b"\n") + 1
    if final:
        assert end == len(contents), ("incomplete final accept record", contents[end:])
    records = []
    for line in contents[:end].split(b"\n")[:-1]:
        code, at = map(int, line.split())
        records.append((code, at))
    return records


def finish_accept_records(host, log):
    if host is not None:
        assert host.poll() is not None, "accept log writer has not retired"
        accept_records(log, final=True)


def prove_accept_record_oracle(state):
    log = state / "accept-record-oracle"
    golden = b"0 123456789\n24 987654321\n"
    expected = [(0, 123456789), (24, 987654321)]
    try:
        for cut in range(len(golden) + 1):
            prefix = golden[:cut]
            log.write_bytes(prefix)
            # Expected framing is derived from the producer's literal LF,
            # independently of the reader and integer-token availability.
            count = prefix.count(b"\n")
            assert accept_records(log) == expected[:count], (cut, prefix)
            if not prefix or prefix.endswith(b"\n"):
                assert accept_records(log, final=True) == expected[:count]
            else:
                try:
                    accept_records(log, final=True)
                except AssertionError:
                    pass
                else:
                    raise AssertionError(("final incomplete record accepted", prefix))
        for malformed in (b"\n", b"24\n", b"24 1 2\n", b"no 1\n"):
            log.write_bytes(golden + malformed + b"0")
            try:
                accept_records(log)
            except (AssertionError, ValueError):
                pass
            else:
                raise AssertionError(("complete malformed record accepted", malformed))
    finally:
        log.unlink()
    print("accept log oracle: every publication cut, complete corruption and final incomplete refusal passed", flush=True)


def prove_accept_pressure(state):
    prove_accept_record_oracle(state)
    source, library = state / "accept.c", state / "accept.so"
    source.write_text(ACCEPT_PROBE)
    subprocess.run(os_semantics.shared_library_command(source, library), check=True)
    prove_accept_inheritance(state, library)
    for label, injected in (("mfile", errno.EMFILE), ("nfile", errno.ENFILE),
                            ("nobufs", errno.ENOBUFS), ("nomem", errno.ENOMEM),
                            ("real-mfile", None), ("shutdown-mfile", errno.EMFILE)):
        root = state / label
        root.mkdir(mode=0o700)
        store, arm, log = root / "store", root / "arm", root / "accept.log"
        backlog_hold, backlog_ready, backlog_release = (root / name for name in ("hold", "ready", "release"))
        endpoint = HeldEndpoint()
        worker = threading.Thread(target=endpoint.serve_forever)
        worker.start()
        host = None
        connections = []

        def connect(path):
            peer = socket.socket(socket.AF_UNIX)
            connections.append(peer)
            peer.settimeout(1)
            peer.connect(path)
            return peer

        try:
            env = {**os.environ, os_semantics.PRELOAD: str(library),
                   "RUI_ACCEPT_LOG": str(log), "RUI_ACCEPT_ARM": str(arm), "RUI_ACCEPT_ERRNO": str(injected or 0),
                   "RUI_ACCEPT_HOLD": str(backlog_hold), "RUI_ACCEPT_READY": str(backlog_ready),
                   "RUI_ACCEPT_RELEASE": str(backlog_release)}
            # A system shell on macOS can strip DYLD_INSERT_LIBRARIES. Use
            # the selected fixture Python to set this child's limit and exec.
            host, ready = start_ready_process([sys.executable, "-c",
                "import os, resource, sys; resource.setrlimit(resource.RLIMIT_NOFILE, (512, 512)); os.execv(sys.argv[1], sys.argv[1:])",
                str(RUI), "host", "serve", "--store", str(store), "--active-capacity", "2",
                "--provider-endpoint", f"http://127.0.0.1:{endpoint.server_port}/responses"], env=env)
            diagnostics = HostDiagnostics(host)
            session = configure(root, store, 0)
            if label != "shutdown-mfile":
                message(root, store, session, 0)
                endpoint.wait_for("requests", 1)
            baseline = sum(code == 0 for code, _ in accept_records(log))
            held = connect(ready["socket"])
            held.sendall(b"POST /v1/host-info HTTP/1.1\r\n")
            wait_for(lambda: sum(code == 0 for code, _ in accept_records(log)) > baseline, "preexisting accepted peer", timeout=10)
            if label == "shutdown-mfile":
                baseline = sum(code == 0 for code, _ in accept_records(log))
                stopping = connect(ready["socket"])
                stopping.sendall(b"POST /v1/control/host-stop HTTP/1.1\r\n")
                wait_for(lambda: sum(code == 0 for code, _ in accept_records(log)) > baseline, "preexisting stop peer", timeout=10)
            if injected is not None:
                arm.touch()
                pending = connect(ready["socket"])
            else:
                # Real per-process exhaustion, isolated to this 512-FD Host.
                # Incomplete headers require sockets but no content handles.
                # Hold one real accept so backlog pressure occurs before FD
                # exhaustion, independently of scheduler load. A failed connect
                # alone must not be mistaken for the required EMFILE receipt.
                backlog_hold.touch()
                pending = connect(ready["socket"])
                wait_for(backlog_ready.exists, "held accept before backlog fill", timeout=10)
                attempts, deadline = 0, time.monotonic() + 10
                while attempts < 600 and time.monotonic() < deadline:
                    try:
                        pending = connect(ready["socket"])
                        attempts += 1
                    except (TimeoutError, BlockingIOError, ConnectionRefusedError):
                        # Linux may report EAGAIN/timeout and Darwin refuses a
                        # full queue. Neither means Host descriptors ran out.
                        connections.pop().close()
                        backlog_release.touch()
                        time.sleep(0.01)
                    if any(code == errno.EMFILE for code, _ in accept_records(log)):
                        break
                assert backlog_release.exists(), "real listener backlog was not exercised"
            expected = injected or errno.EMFILE
            wait_for(lambda: any(code == expected for code, _ in accept_records(log)), "accept resource exhaustion", timeout=10)
            # Existing accepted peers still progress during pressure.
            body = json.dumps({"version": "1", "kind": "host_info", "store": str(store)}).encode()
            held.sendall(f"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
            head, response = control.read_http_response(held)
            assert head.startswith(b"HTTP/1.1 200 "), (label, head, diagnostics.tail())
            identity = json.loads(response)["instance"]
            if injected is not None:
                wait_for(lambda: len([at for code, at in accept_records(log) if code == expected]) >= 4, "bounded retry samples", timeout=10)
                attempts = [at for code, at in accept_records(log) if code == expected]
                assert all(b - a >= 50_000_000 for a, b in zip(attempts, attempts[1:])), (label, attempts)
                if label == "shutdown-mfile":
                    stop_body = json.dumps({"version": "1", "kind": "host_stop", "store": str(store)}).encode()
                    stopping.sendall(f"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nX-Rui-Host-Instance: {identity}\r\nContent-Length: {len(stop_body)}\r\n\r\n".encode() + stop_body)
                    head, response = control.read_http_response(stopping)
                    assert head.startswith(b"HTTP/1.1 200 "), head
                    assert json.loads(response) == {"version": "1", "type": "host_stop_reply", "status": "acknowledged"}, response
                    # Keep acquisition pressure armed through physical shutdown.
                    for peer in connections:
                        peer.close()
                    host.wait(timeout=8)
                    assert not pathlib.Path(ready["socket"]).exists(), diagnostics.tail()
                    print("accept pressure: guarded shutdown during cooldown passed", flush=True)
                    continue
                arm.unlink()
            else:
                # Releasing sockets restores the actual descriptor supply.
                for peer in connections:
                    peer.close()
            if injected is not None:
                pending.sendall(b"POST /v1/host-info HTTP/1.1\r\n" +
                    f"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
                head, response = control.read_http_response(pending)
                assert head.startswith(b"HTTP/1.1 200 ") and json.loads(response)["instance"] == identity
            endpoint.release.set()
            endpoint.wait_for("completed", 1)
            wait_for(lambda: failed_result(root, store, 0), "original admitted work without interruption", timeout=10)
            wait_for(lambda: execution_idle(root, store, session), "recovered execution drainage", timeout=10)
            head, response = control.raw_request(ready["socket"], "/v1/host-info", body)
            assert head.startswith(b"HTTP/1.1 200 ") and json.loads(response)["instance"] == identity
            assert host.poll() is None, diagnostics.tail()
            print(f"accept pressure: {label}, existing peer, admitted work, same-Host recovery and bounded retry passed", flush=True)
        finally:
            backlog_release.touch()
            endpoint.release.set()
            dispose_all(*(peer.close for peer in connections),
                        lambda: stop_process(host) if host is not None else None,
                        lambda: finish_accept_records(host, log),
                        endpoint.shutdown, endpoint.server_close, lambda: worker.join(timeout=3))


def prove_accept_inheritance(state, library):
    root = state / "accept-inheritance"
    root.mkdir(mode=0o700)
    store, hold, ready, release = (root / name for name in ("store", "hold", "ready", "release"))
    report, child_release = root / "child-report", root / "child-release"
    gate = root / "launch-gate"
    keeper = open_gate(gate)
    wrapper = root / "bash"
    wrapper.write_text(f"#!{sys.executable}\n" + f"""
import json, os, pathlib, sys, time
fd, device, inode = map(int, pathlib.Path({str(ready)!r}).read_text().split())
evidence = {{"fd": fd, "expected": [device, inode], "raw": None, "normalized": None, "stat_error": None, "inherited": False}}
try:
    actual = os.fstat(fd)
    evidence["raw"] = [actual.st_dev, actual.st_ino]
    # Match the probe's unsigned long long casts, including Darwin dev_t -1.
    evidence["normalized"] = [value & ((1 << 64) - 1) for value in evidence["raw"]]
    evidence["inherited"] = evidence["normalized"] == evidence["expected"]
except OSError as error:
    evidence["stat_error"] = error.errno
pathlib.Path({str(report)!r}).write_text(json.dumps(evidence) + '\\n')
deadline = time.monotonic() + 10
while not pathlib.Path({str(child_release)!r}).exists():
    if time.monotonic() >= deadline: sys.exit(91)
    time.sleep(0.001)
os.execv('/bin/bash', ['/bin/bash', *sys.argv[1:]])
""")
    wrapper.chmod(0o700)
    response = fixture.sse_tool_calls("inheritance", [("bash", "inheritance-call", json.dumps(
        {"cmd": "printf done", "timeout_ms": None, "description": "Check child descriptor isolation"}))])
    endpoint = fixture.SuccessEndpoint([response, fixture.sse_answer("inheritance-answer", "reason", "message", "done")[0]])
    worker = threading.Thread(target=endpoint.serve_forever)
    worker.start()
    host = peer = timer = None
    try:
        env = {**os.environ, os_semantics.PRELOAD: str(library),
               "RUI_ACCEPT_LOG": str(root / "accept.log"), "RUI_ACCEPT_ARM": str(root / "unused"),
               "RUI_ACCEPT_HOLD": str(hold), "RUI_ACCEPT_READY": str(ready), "RUI_ACCEPT_RELEASE": str(release)}
        host, fields = start_ready_process([str(RUI), "host", "serve", "--store", str(store), "--active-capacity", "2",
            "--provider-endpoint", f"http://127.0.0.1:{endpoint.server_port}/responses", "--bash-path", str(wrapper),
            "--test-transition", "prepared-before-handoff", "--test-transition-gate-path", str(gate)], env=env)
        diagnostics = HostDiagnostics(host)
        session = bash.configure(root, store, "configure", permission="bypass")
        fixture.message(root, store, "message", session, "check inheritance")
        diagnostics.wait("prepared_before_handoff", timeout=10)
        hold.touch()
        peer = socket.socket(socket.AF_UNIX)
        peer.connect(fields["socket"])
        wait_for(lambda: ready.exists() and ready.read_bytes().endswith(b"\n"), "accepted socket before flags", timeout=10)
        # Open a competing launch window, not a timing acceptance assertion.
        # The child reports exact socket identity whether it spawns during or
        # after acquisition. The unfixed-path control must witness inheritance.
        timer = threading.Timer(2, release.touch)
        timer.start()
        os.write(keeper, b"x")
        wait_for(lambda: report.exists() and report.read_bytes().endswith(b"\n"), "real Bash launch descriptor report", timeout=10)
        evidence = json.loads(report.read_text())
        print("accept inheritance child:", json.dumps(evidence), flush=True)
        assert evidence["stat_error"] in (None, errno.EBADF), json.dumps(evidence)
        assert evidence["inherited"] is False, json.dumps(evidence)
        print("accept inheritance: real Bash child did not retain the selected exchange socket", flush=True)
    finally:
        release.touch(exist_ok=True)
        child_release.touch(exist_ok=True)
        dispose_all(lambda: timer.join() if timer is not None else None,
                    lambda: peer.close() if peer is not None else None,
                    lambda: stop_process(host) if host is not None else None,
                    lambda: finish_accept_records(host, root / "accept.log"),
                    lambda: os.close(keeper), endpoint.shutdown, endpoint.server_close, lambda: worker.join(timeout=3))


def main():
    prove_borrower_oracle()
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-descriptor-capacity-"))
    endpoint = HeldEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    host = None
    documented = None
    diagnostics = None
    try:
        # Keep allocator defaults enabled. macOS libmalloc may itself open a
        # socket before Host ownership begins; it belongs in inherited, not
        # in the independently calculated Host population below.
        if os_semantics.HOST_MALLOC_REEXEC:
            assert os.environ.get("RUI_HOST_MALLOC_DEFAULTS") != "0"
            for name in ("MallocMaxMagazines", "MallocSpaceEfficient"):
                assert os.environ.get(name, "1") == "1", (name, os.environ.get(name))
        prove_accept_pressure(state)
        # Two execution slots need one steady population(5) plus the
        # serial Bash spawn peak(10).
        fixed_host = os_semantics.HOST_FIXED_DESCRIPTORS
        execution = 5 + 10
        # The supported burst is 100 ordinary exchanges (socket + up to
        # three content aliases each), two controls and one discovery.
        # This preflight is a resource estimate, not a runtime admission cap.
        clients = 100 * 4 + 3
        fixed = fixed_host + clients + execution + 0 + 2
        minimum_required = fixed - clients + 10 * 4 + 3 + 3
        rejected_store = state / "rejected-store"
        rejected = subprocess.run(
            limited_host(
                minimum_required - 1,
                "host", "serve",
                "--store",
                rejected_store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
            ),
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert rejected.returncode != 0, rejected.stdout
        assert not rejected.stdout.startswith("ready "), rejected.stdout
        assert "descriptor capacity insufficient" in rejected.stderr, rejected.stderr
        assert "active_capacity=2" in rejected.stderr, rejected.stderr
        fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", rejected.stderr)}
        assert fields["inherited"] in os_semantics.INHERITED_DESCRIPTORS, fields
        required = fixed + fields["inherited"]
        expected = dict(active_capacity=2, required=required, soft_limit=minimum_required - 1,
            inherited=fields["inherited"], fixed_host=fixed_host, clients=clients, execution=execution,
            authentication=0, self_wake=2)
        assert fields == expected, (fields, expected)
        assert not rejected_store.exists(), "descriptor rejection followed startup side effects"
        if fields["inherited"] != 3:
            rejected = subprocess.run(
                limited_host(required - clients + 10 * 4 + 3 - 1, "host", "serve", "--store", rejected_store,
                    "--active-capacity", "2", "--provider-endpoint",
                    f"http://127.0.0.1:{endpoint.server_port}/responses"),
                text=True, capture_output=True, timeout=10)
            assert rejected.returncode != 0 and "descriptor capacity insufficient" in rejected.stderr, rejected
            assert not rejected.stdout.startswith("ready "), rejected.stdout
            fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", rejected.stderr)}
            assert fields == {**expected, "soft_limit": required - clients + 10 * 4 + 3 - 1}, fields
            assert not rejected_store.exists(), "descriptor rejection followed startup side effects"

        store = state / "adequate-store"
        host, ready = start_ready_process(
            limited_host(
                required,
                "host", "serve",
                "--store",
                store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
            ),
            required_fields={
                "descriptor_requirement": str(required),
                "descriptor_limit": str(required),
            },
        )
        diagnostics = HostDiagnostics(host)
        sessions = [configure(state, store, ordinal) for ordinal in range(4)]
        message(state, store, sessions[0], 0)
        message(state, store, sessions[1], 1)
        # At capacity two both streams share one connection and are held by
        # the peer at once, each Attempt with its own custody.
        endpoint.wait_for("requests", 2)
        assert endpoint.requests == 2, endpoint.requests
        assert host.poll() is None, diagnostics.tail()

        endpoint.release.set()
        endpoint.wait_for("completed", 2)
        for ordinal in range(2):
            wait_for(lambda ordinal=ordinal: failed_result(state, store, ordinal), f"message {ordinal} result", timeout=10)
        wait_for(lambda: execution_idle(state, store, sessions[0]), "first complete execution drain", timeout=10)

        endpoint.release.clear()
        message(state, store, sessions[2], 2)
        message(state, store, sessions[3], 3)
        endpoint.wait_for("requests", 4)
        assert endpoint.requests == 4, endpoint.requests
        assert endpoint.completed == 2, endpoint.completed
        endpoint.release.set()
        endpoint.wait_for("completed", 4)
        for ordinal in range(2, 4):
            wait_for(lambda ordinal=ordinal: failed_result(state, store, ordinal), f"message {ordinal} result", timeout=10)
        wait_for(lambda: execution_idle(state, store, sessions[2]), "second complete execution drain", timeout=10)
        assert host.poll() is None, diagnostics.tail()

        documented_store = state / "documented-store"
        documented, _ = start_ready_process(
            limited_host(
                1024,
                "host", "serve",
                "--store",
                documented_store,
                "--active-capacity",
                "8",
            ),
            required_fields={"active_capacity": "8", "descriptor_limit": "1024"},
        )
        stop_process(documented)
        documented = None
        prove_bash_spawn_with_full_client_population(state, required)
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: stop_process(documented) if documented is not None else None,
                        lambda: stop_process(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: endpoint_thread.join(timeout=3)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        if endpoint_thread.is_alive():
            errors.append(AssertionError("Descriptor endpoint thread did not retire"))
        if incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("descriptor fixture failure state", state)
        if errors:
            if incoming_error is None:
                raise errors[0]
            incoming_error.add_note("Descriptor cleanup failed: " + ", ".join(type(error).__name__ for error in errors))


if __name__ == "__main__":
    main()
