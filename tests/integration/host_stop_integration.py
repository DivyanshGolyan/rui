#!/usr/bin/env python3
"""Native protected stop, exact-instance retry, and Host-owned drain."""

import contextlib
import json
import os
import pathlib
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time

import bash_integration as bash_fixture
import model_fixture as fixture
from host_process import HostDiagnostics, ReleaseGate, canonical_fixture_root, dispose_all, is_peer_disconnect, stop_process
from host_status_integration import socket_path, status


RUI, ACTOR = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])
fixture.RUI = RUI


def actor(*args, timeout=10):
    result = subprocess.run([ACTOR, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def exchange_phase(diagnostics, phase, began_ns, deadline, **fields):
    # This isolated Host has one fixture issuer. Earlier buffered milestones
    # cannot satisfy this invocation; ambiguous or missing evidence is failure.
    with diagnostics.condition:
        while True:
            assert diagnostics.read_error is None, diagnostics.read_error
            matches = [record for record in diagnostics.records
                       if record["rui_test_phase"] == phase
                       and int(record["at_ns"]) >= began_ns
                       and all(record.get(name) == value for name, value in fields.items())]
            assert len(matches) <= 1, ("ambiguous exchange phase", matches)
            if matches:
                record = matches[0]
                assert record.get("process") == str(diagnostics.process.pid), record
                assert record.get("clock") == "awake_ns" and isinstance(record.get("trace_lost"), bool), record
                for field in ("run", "sequence", "at_ns"):
                    value = record.get(field, "")
                    assert isinstance(value, str) and value.isascii() and value.isdecimal(), record
                    assert str(int(value)) == value and 0 < int(value) < 2**64, record
                assert record["run"] == diagnostics.records[0]["run"], record
                assert int(record["at_ns"]) <= time.monotonic_ns(), record
                assert time.monotonic() <= deadline, "exchange phase exceeded original stop budget"
                return record
            remaining = deadline - time.monotonic()
            assert remaining > 0, ("missing exchange phase within original stop budget", phase)
            diagnostics.condition.wait(remaining)


def actor_after_classification(diagnostics, began_ns, deadline, pending_phase, store, target, *, invoke=actor):
    transferred_phase = exchange_phase(diagnostics, "ordinary_classification_released", began_ns, deadline,
                                       subject_kind="route", subject="observe")
    assert transferred_phase["run"] == pending_phase["run"]
    assert int(transferred_phase["sequence"]) > int(pending_phase["sequence"])
    assert int(transferred_phase["at_ns"]) >= int(pending_phase["at_ns"])
    assert not pending_phase["trace_lost"] or transferred_phase["trace_lost"]
    assert time.monotonic() < deadline, "classification exceeded original stop budget"
    return invoke("stop", store, target, "after-commit", timeout=deadline - time.monotonic())


def instance(store):
    match = re.fullmatch(r"ready ([0-9a-f]{32}) \d+ true (?:true|false) (?:true|false)", status(store))
    assert match, status(store)
    return match.group(1)


def request(sock, store, identity=None, *, extra=b""):
    body = json.dumps({"version": "1", "kind": "host_stop", "store": str(store.resolve())}).encode()
    header = (
        b"POST /v1/control/host-stop HTTP/1.1\r\nHost: local\r\n"
        + b"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
    )
    if identity is not None:
        header += f"X-Rui-Host-Instance: {identity}\r\n".encode()
    stream = socket.socket(socket.AF_UNIX)
    stream.settimeout(5)
    stream.connect(str(sock))
    stream.sendall(header + extra + b"\r\n")
    return stream, body


def finish(stream, body):
    response = bytearray()
    with stream:
        try:
            stream.sendall(body)
            while chunk := stream.recv(4096):
                response.extend(chunk)
                assert len(response) < 8192
        except OSError as error:
            if not is_peer_disconnect(error):
                raise
            # A late reset must not erase a captured acceptance prefix.
    return bytes(response)


def mixed_effect_drain(provider_first):
    """A held provider capture cannot postpone another owner's retirement."""
    order = "provider-before-Bash" if provider_first else "Bash-before-provider"
    with tempfile.TemporaryDirectory(prefix="rui-mixed-stop-") as root, contextlib.ExitStack() as handles:
        state = canonical_fixture_root(root)
        store = state / "store"
        # These real shutdown journeys must survive absent optional stderr.
        # The existing startup adapter owns an EOF reader while fd 2 goes to
        # /dev/null; required readiness and native receipts remain unchanged.
        reader, writer = os.pipe()
        os.close(writer)
        stderr_pipe = (handles.enter_context(os.fdopen(reader, "rb")),
                       handles.enter_context(open(os.devnull, "wb")))
        ready = state / "bash-ready"
        events = state / "events"
        quoted_events = shlex.quote(str(events))
        command = (
            f"trap 'printf \"TERM\\n\" >> {quoted_events}; exit 0' TERM; "
            f"printf ready > {shlex.quote(str(ready))}; "
            f"for ((i=0; i<600; i++)); do printf 'alive\\n' >> {quoted_events}; sleep 0.05; done"
        )
        proposal = fixture.sse_tool_calls("bash-proposal", [
            ("bash", "bash-call", json.dumps({"cmd": command, "timeout_ms": None, "description": "Write Host stop lifecycle events"}))
        ])
        large = fixture.sse_answer("held-provider", "private-reason", "answer", "x" * 128000)[0]
        endpoint = fixture.SuccessEndpoint([], responses_by_input={"bash": proposal, "provider": large})
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        gate = ReleaseGate(state / "capture-gate")
        host = None
        diagnostics = None
        try:
            host = fixture.start_host(
                store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                "--test-response-capture-gate-path", gate.path,
                "--test-response-capture-gate-min-written-bytes", "4096",
                "--test-phase-trace", active_capacity=3, observations="stop", stderr_pipe=stderr_pipe,
            )
            diagnostics = HostDiagnostics(host)
            bash_fixture.configure(state, store, "configure-bash", "bash/session")
            fixture.message(state, store, "message-bash", "bash/session", "bash")
            action = fixture.wait_for(lambda: bash_fixture.action_for(store, "bash/session"), "Bash proposal")
            proposal_cleanup = diagnostics.wait("cleanup_completed")[0]["operation"]
            fixture.configure(state, store, "configure-provider", "provider/session", "gpt-6-sol")

            def launch_bash():
                bash_fixture.allow(state, store, "allow-bash", "bash/session", action["action"])
                fixture.wait_for(ready.exists, "native Bash ready file")
                diagnostics.wait("bash_handoff_committed", action=action["action"])

            def hold_provider():
                fixture.message(state, store, "message-provider", "provider/session", "provider")
                diagnostics.wait("capture_write_gate_entered")
                assert gate.fd is not None

            if provider_first:
                hold_provider()
                launch_bash()
            else:
                launch_bash()
                hold_provider()

            occupied = fixture.command("session", "inspect", "--store", store, "--session", "bash/session")["execution"]
            assert int(occupied["custody_occupied"]) == 2, occupied
            assert actor("stop", store, instance(store)) == "acknowledged"
            fixture.wait_for(lambda: not socket_path(store).exists(), "listener closure with held capture")
            assert status(store) == "owned_unavailable"
            assert host.poll() is None, "held capture must retain the Host and Store lease"

            # This is the regression assertion, before the capture gate opens.
            # Both admission orders must retire and release Bash independently.
            fixture.wait_for(lambda: "TERM\n" in events.read_text(),
                             f"{order}: Bash TERM before provider capture release", timeout=2)
            diagnostics.wait("cleanup_completed", action=action["action"], timeout=3)
            assert gate.fd is not None and host.poll() is None
            assert status(store) == "owned_unavailable"
            contender = subprocess.run([RUI, "host", "serve", "--store", store, "--active-capacity", "1"],
                                       capture_output=True, timeout=10)
            assert contender.returncode != 0 and b"ready store=" not in contender.stdout, contender
            gate.release()
            assert host.wait(timeout=10) == 1, host.returncode
            stop_process(host)
            assert len(diagnostics.matching("cleanup_completed", action=action["action"])) == 1
            model_cleanups = [record for record in diagnostics.matching("cleanup_completed") if "action" not in record]
            # The proposal and the discarded provider each release once.
            assert len(model_cleanups) == 2 and len({record["operation"] for record in model_cleanups}) == 2
            assert proposal_cleanup in {record["operation"] for record in model_cleanups}
            assert status(store) == "unavailable"
            assert list((store / "scratch").iterdir()) == [], "mixed shutdown retained scratch"
            # Stopped-Store audit: infrastructure cleanup must not become a
            # user cancellation, a provider failure or a new continuation.
            assert bash_fixture.rows(store, "SELECT attempt_ordinal,resolution_code FROM action_operation") == [(1, "infrastructure_shutdown")]
            assert bash_fixture.rows(store, "SELECT session_ref,attempt_ordinal,resolution_code FROM model_operation ORDER BY session_ref") == [
                ("bash/session", 1, "tool_proposals"), ("provider/session", 1, None),
            ]
            print(f"mixed Host stop passed: {order}, TERM and exactly-once Bash cleanup before capture release; lease held, scratch=0")
        finally:
            incoming_error = sys.exc_info()[1]
            if diagnostics is not None:
                diagnostics.snapshot_failure(lambda: {"case": "mixed_effect_drain", "order": order,
                    "capture_gate_exists": gate.path.exists(), "capture_held": gate.fd is not None})
            errors = []
            for release in (gate.release,):
                try:
                    release()
                except BaseException as error:
                    errors.append(error)
            if host is not None:
                if host.poll() is None:
                    # On the red path, let the original owner drain once the
                    # fixture's capture gate opens; kill only if it cannot.
                    try:
                        host.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass  # Shared disposal still owns mandatory kill/reap.
            for dispose in (lambda: stop_process(host) if host is not None else None,
                            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
                try:
                    dispose()
                except BaseException as error:
                    errors.append(error)
            if thread.is_alive():
                errors.append(AssertionError("Host-stop endpoint thread did not retire"))
            if errors:
                if incoming_error is None:
                    raise errors[0]
                incoming_error.add_note("Host-stop cleanup failed: " + ", ".join(type(error).__name__ for error in errors))


def main():
    with tempfile.TemporaryDirectory(prefix="rui-host-stop-") as root:
        state = canonical_fixture_root(root)
        store = state / "store"
        gate = state / "bash-cleanup-gate"
        gate.write_text("held")
        reply_gate = state / "reply-gate"
        responses = []
        bash_fixture.add_exchange(responses, "host-stop", "printf stopped")
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        host = None
        replacement = None
        diagnostics = None
        pending = None
        transferred = None
        inspector = None
        report_release = None
        uploads = []
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                      "--test-bash-cleanup-gate-path", gate,
                                      "--test-inspection-reply-gate-path", reply_gate,
                                      "--test-phase-trace", observations="stop")
            diagnostics = HostDiagnostics(host)
            target = instance(store)
            sock = socket_path(store)
            wrong = actor("stop", store, "0" * 32)
            assert wrong == "instance_changed", wrong
            missing, body = request(sock, store)
            assert b"host_instance_required" in finish(missing, body)
            assert instance(store) == target
            detached, _ = request(sock, store, target)
            detached.close()  # Incomplete request / terminal detach is not a stop.
            assert instance(store) == target

            bash_fixture.configure(state, store, "stop-config", "direct/stop")
            fixture.message(state, store, "stop-message", "direct/stop", "run Bash")
            action = fixture.wait_for(lambda: bash_fixture.action_for(store, "direct/stop"), "Bash Action")
            bash_fixture.allow(state, store, "stop-allow", "direct/stop", action["action"])
            diagnostics.wait("cleanup_started", action=str(action["action"]))
            assert not diagnostics.matching("cleanup_completed", action=str(action["action"]))
            occupied = fixture.command("session", "inspect", "--store", store, "--session", "direct/stop")["execution"]
            assert int(occupied["custody_occupied"]) > 0, occupied
            report_release = ReleaseGate(reply_gate)
            began = time.monotonic_ns()
            inspector = fixture.start_command("session", "inspect", "--store", store, "--session", "direct/stop")
            exchange_phase(diagnostics, "test_gate_waiting", began, time.monotonic() + 5,
                           subject=str(reply_gate))
            held_fds = len(os.listdir(f"/proc/{host.pid}/fd")) if sys.platform == "linux" else None

            # Both classified headers and captured bodies still belong to
            # intake, not admission. Completing either after stop must not save
            # work that an explicit restart would later execute.
            for kind in ("message", "configure"):
                for phase in ("header", "body"):
                    fields = {"sender": None, "text": {"state": "value", "value": "x" * 8192}} if kind == "message" else {
                        "configuration": {name: {"state": "omitted"} for name in
                            ("workspace", "provider", "model", "tools", "permission_mode", "output_schema")}}
                    if kind == "configure":
                        fields["configuration"]["instructions"] = {"state": "value", "value": "x" * 8192}
                    body = json.dumps({"version": "1", "kind": kind, "store": str(store),
                        "key": f"late-{kind}-{phase}", "session": "direct/stop", **fields}).encode()
                    header = (f"POST /v1/{kind} HTTP/1.1\r\nHost: local\r\n".encode()
                        + b"Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\n"
                        + f"Content-Length: {len(body)}\r\n\r\n".encode())
                    upload = socket.socket(socket.AF_UNIX)
                    uploads.append((upload, b"\r\n" + body if phase == "header" else body[-3:]))
                    upload.settimeout(5)
                    upload.connect(str(sock))
                    began = time.monotonic_ns()
                    upload.sendall(header[:-2] if phase == "header" else header + body[:-3])
                    exchange_phase(diagnostics,
                        "ordinary_classification_released" if phase == "header" else f"connection_request_{kind}",
                        began, time.monotonic() + 5,
                        **({"subject": kind} if phase == "header" else {}))

            # Share the original ten-second actor budget with synchronization;
            # connects and header writes alone do not establish classification.
            deadline = time.monotonic() + 10
            began_ns = time.monotonic_ns()
            pending, _ = request(sock, store, target)
            pending_phase = exchange_phase(diagnostics, "connection_request_host_stop", began_ns, deadline,
                                           subject_kind="request_number")
            assert not diagnostics.matching("connection_resources_released", subject=pending_phase["subject"])
            began_ns = time.monotonic_ns()
            transferred = socket.socket(socket.AF_UNIX)
            transferred.settimeout(5)
            transferred.connect(str(sock))
            transferred.sendall(b"POST /v1/observe-command HTTP/1.1\r\n")
            first = actor_after_classification(diagnostics, began_ns, deadline, pending_phase, store, target)
            assert first == "TruncatedResponse", first
            # Routed headers are still incomplete input, not a guarded retry.
            # The complete-retry owner test separately requires acknowledgment.
            assert pending.recv(1) == b"", "incomplete Host stop survived shutdown"
            pending.close()
            pending = None
            for upload, remainder in uploads:
                response = finish(upload, remainder)
                assert b'"status":"accepted"' not in response, ("admitted after Host stop", response)
            fixture.wait_for(lambda: not sock.exists(), "listener closure before cleanup")
            with socket.socket(socket.AF_UNIX) as newcomer:
                try:
                    newcomer.connect(str(sock))
                except (FileNotFoundError, ConnectionRefusedError):
                    pass
                else:
                    raise AssertionError("new client connected after listener closure")
            assert status(store) == "owned_unavailable"
            assert host.poll() is None, "acknowledgement was mistaken for completion"
            contender = subprocess.run(
                [RUI, "host", "serve", "--store", store, "--active-capacity", "1"],
                capture_output=True, timeout=10,
            )
            assert contender.returncode != 0 and b"ready store=" not in contender.stdout, contender
            assert not diagnostics.matching("cleanup_completed", action=str(action["action"]))
            gate.unlink()
            diagnostics.wait("cleanup_completed", action=str(action["action"]))
            assert host.poll() is None, "owned report must retain lease"
            assert status(store) == "owned_unavailable"
            drained_fds = len(os.listdir(f"/proc/{host.pid}/fd")) if held_fds is not None else None
            if held_fds is not None:
                assert drained_fds < held_fds, (held_fds, drained_fds)
            assert transferred.recv(1) == b"", "unhanded read survived the intake fence"
            transferred.close()
            transferred = None
            report_release.release()
            output, errors = inspector.communicate(timeout=5)
            assert inspector.returncode == 0 and json.loads(output)["session"]["reference"] == "direct/stop", (output, errors)
            inspector = None
            assert host.wait(timeout=10) != 0  # existing graceful owner reports EffectAwareShutdown
            stop_process(host)
            diagnostics = None
            host = None
            assert status(store) == "unavailable"
            assert list((store / "scratch").iterdir()) == [], "shutdown retained scratch"
            replacement = fixture.start_host(store, None)
            newer = instance(store)
            assert newer != target
            for kind in ("message", "configure"):
                for phase in ("header", "body"):
                    assert fixture.observe(store, f"late-{kind}-{phase}") == {"status": "absent"}
            # The first reply was lost. Retrying A's retained input must not
            # rediscover or stop live replacement B.
            assert actor("stop", store, target) == "instance_changed"
            assert instance(store) == newer
            stale_cli = subprocess.run([RUI, "host", "stop", "--store", store, "--instance", target],
                                       capture_output=True, text=True, timeout=10)
            assert stale_cli.returncode != 0 and "Host instance changed" in stale_cli.stderr and stale_cli.stdout == "", stale_cli
            assert instance(store) == newer
            current_cli = subprocess.run([RUI, "host", "stop", "--store", store],
                                         capture_output=True, text=True, timeout=10)
            assert current_cli.returncode == 0 and json.loads(current_cli.stdout) == {
                "version": "1", "type": "host_stop", "status": "acknowledged", "store": str(store.resolve()),
                "instance": newer, "retirement": "unconfirmed",
            }, current_cli
            notice = current_cli.stderr
            assert notice.startswith("rui: stop affects all work in this Store. Retry only this exact target: rui host stop --store "), current_cli
            assert notice.endswith(f" --instance {newer}\n") and notice.count("\n") == 1, current_cli
            assert replacement.wait(timeout=10) != 0
            replacement.stdout.close()
            replacement.stderr.close()
            replacement = None
            assert actor("stop", store, newer) == "unavailable", "retry may not select a replacement"
            print(f"host-stop passed: guarded rejection, incomplete-stop retirement, held cleanup/connection lease, replacement; Linux fd={held_fds}->{drained_fds}, scratch=0")
        finally:
            dispose_all(
                lambda: gate.unlink(missing_ok=True),
                lambda: report_release.release() if report_release is not None else None,
                lambda: pending.close() if pending is not None else None,
                lambda: transferred.close() if transferred is not None else None,
                *(upload.close for upload, _ in uploads),
                lambda: stop_process(inspector) if inspector is not None else None,
                lambda: stop_process(host) if host is not None else None,
                lambda: stop_process(replacement) if replacement is not None else None,
                endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
            )


if __name__ == "__main__":
    from host_stop_integration_test import check_classification_oracle, check_missing_classification
    check_classification_oracle(actor_after_classification)
    check_missing_classification(actor_after_classification)
    mixed_effect_drain(True)
    mixed_effect_drain(False)
    main()
