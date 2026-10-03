#!/usr/bin/env python3
"""Native protected stop, exact-instance retry, and Host-owned drain."""

import json
import os
import pathlib
import re
import select
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time

import bash_integration as bash_fixture
import bash_lifecycle_integration as lifecycle_fixture
import control_integration as control_fixture
import dispatch_integration as fixture
from host_process import HostDiagnostics, ReleaseGate, stop_process
from host_status_integration import raw_info, socket_path, status, wait_for_descriptors


RUI, ACTOR = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:3])
fixture.RUI = RUI


def actor(*args):
    result = subprocess.run([ACTOR, *map(str, args)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


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
    with stream:
        stream.sendall(body)
        # Busy rejection can close with unread ingress, yielding reset after
        # its complete framed reply. Match the real client's framing boundary.
        head, response = control_fixture.read_http_response(stream, timeout=5)
        lengths = [line.split(b":", 1)[1].strip() for line in head.split(b"\r\n")
                   if line.lower().startswith(b"content-length:")]
        assert len(lengths) == 1 and len(response) == int(lengths[0]) < 8192, (head, response)
    return head + b"\r\n\r\n" + response


def discovery(sock, store, *, length=None):
    body = json.dumps({"version": "1", "kind": "host_info", "store": str(store.resolve())}).encode()
    stream = socket.socket(socket.AF_UNIX)
    try:
        stream.settimeout(13)
        stream.connect(str(sock))
        stream.sendall(
            b"POST /v1/host-info HTTP/1.1\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body) if length is None else length}\r\n".encode()
            + b"X-Rui-Wire-Version: 1\r\n\r\n"
        )
    except BaseException:
        stream.close()
        raise
    return stream, body


def info_reply(sock, store, *, kind="host_info"):
    stream, body = discovery(sock, store)
    if kind != "host_info":
        body = body.replace(b'"host_info"', json.dumps(kind).encode())
        # Use a same-length kind so the originally framed body stays complete.
        assert kind == "configure"
    return finish(stream, body)


def after_discovery_release(exchange):
    # A complete response does not establish handler close/release. Retry only
    # the recognized busy observation; any other response reaches its assertion.
    return fixture.wait_for(
        lambda: (reply if b"discovery_capacity_exhausted" not in (reply := exchange()) else None),
        "discovery admission reusable after prior exchange",
    )


def retain_discovery(sock, store, *, header=None):
    # Opening a socket does not prove admission: a preceding exchange may
    # still own discovery. Require a second discovery's semantic rejection
    # while the first has neither a rejection nor EOF, all within one second.
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        began = time.monotonic()
        if header is None:
            held, _ = discovery(sock, store)
        else:
            held = socket.socket(socket.AF_UNIX)
            held.settimeout(5)
            held.connect(str(sock))
            held.sendall(header)
        retained = False
        try:
            reply = info_reply(sock, store)
            held.setblocking(False)
            try:
                held.recv(1, socket.MSG_PEEK)
            except BlockingIOError:
                retained = reply.startswith(b"HTTP/1.1 503") and b"discovery_capacity_exhausted" in reply
            except ConnectionResetError:
                pass
        finally:
            if not retained:
                held.close()
        if retained:
            assert time.monotonic() < deadline, "second discovery did not reject promptly"
            held.settimeout(.1)
            return held, began
        time.sleep(.025)
    raise AssertionError("second discovery must be rejected while one is retained")


def resource_sample(pid):
    if sys.platform != "linux":
        return None
    fields = dict(line.split(":", 1) for line in pathlib.Path(f"/proc/{pid}/status").read_text().splitlines() if ":" in line)
    return {name: fields[name].strip() for name in ("VmRSS", "VmSize", "Threads")}


def saturated_stop(state, *, competing):
    store = state / ("competition" if competing else "fresh")
    gate = ReleaseGate(state / ("competition-readers" if competing else "fresh-readers"))
    # Persist setup before the measured Host starts. Reply completion from a
    # configure/status probe is not a witness of its final admission release.
    setup = fixture.start_host(store, None)
    try:
        bash_fixture.configure(state, store, "competition-config" if competing else "fresh-config", "direct/readers")
    finally:
        stop_process(setup)
    host = fixture.start_host(store, None, "--test-phase-trace", "--test-inspection-reply-gate-path", gate.path)
    diagnostics = HostDiagnostics(host)
    readers = []
    held = None
    try:
        # The fresh case does not pre-discover an instance. CLI must perform
        # the whole discovery + protected-stop flow at ten ordinary occupants.
        sock = socket_path(store)
        readers = control_fixture.fill_complete_inspections(str(sock), str(store.resolve()), "direct/readers")
        diagnostics.wait("inspection_captured", count=10, subject="direct/readers")
        diagnostics.wait("test_gate_waiting", count=10, subject=str(gate.path))
        baseline = wait_for_descriptors(host.pid) if sys.platform == "linux" else None
        before = resource_sample(host.pid)
        if competing:
            # No earlier discovery owns this fresh Host. Two incomplete
            # requests establish the cap without assuming connect order is
            # classification order. Keep the winner, whichever it is.
            pair = []
            try:
                for _ in range(2):
                    stream, _ = discovery(sock, store)
                    pair.append(stream)
                ready, _, _ = select.select(pair, [], [], 1)
                assert len(ready) == 1, "one competing discovery must reject promptly"
                rejected = ready[0]
                head, body = control_fixture.read_http_response(rejected, timeout=1)
                assert head.startswith(b"HTTP/1.1 503") and b"discovery_capacity_exhausted" in body, (head, body)
                held = next(stream for stream in pair if stream is not rejected)
                held.setblocking(False)
                try:
                    observed = held.recv(1, socket.MSG_PEEK)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError(("retained discovery replied or closed", observed))
                held.settimeout(.1)
            finally:
                for stream in pair:
                    if stream is not held:
                        stream.close()
            assert status(store) == "owned_unavailable", "busy discovery lost owned-unavailable semantics"
            held.close()
            held = None
            fixture.wait_for(lambda: info_reply(sock, store).startswith(b"HTTP/1.1 200"), "discovery reuse after disconnect")
            control_fixture.assert_ordinary_capacity_busy(str(sock))

            # Both content length and route kind are checked before any
            # content-bearing parser can consume headroom or create scratch.
            def oversized_body():
                stream, _ = discovery(sock, store, length=3001)  # derived maximum is 2,997 bytes
                return finish(stream, b"")

            def malformed_body():
                stream, _ = discovery(sock, store)
                return finish(stream, b"not-json")

            assert b"DiscoveryRequestTooLarge" in after_discovery_release(oversized_body)
            assert b"invocation_error" in after_discovery_release(malformed_body)
            mismatched = after_discovery_release(lambda: info_reply(sock, store, kind="configure"))
            assert b"RouteKindMismatch" in mismatched, mismatched

            def oversized_header():
                with socket.socket(socket.AF_UNIX) as header:
                    header.settimeout(3)
                    header.connect(str(sock))
                    header.sendall(b"POST /v1/host-info HTTP/1.1\r\n" + b"X: " + b"a" * 16384)
                    return finish(header, b"")

            assert b"HeaderTooLarge" in after_discovery_release(oversized_header)

            # Six seconds of header trickle followed by body trickle cannot
            # renew the ten-second budget from acceptance. Poll until EOF,
            # rather than releasing this retained discovery ourselves.
            held, began = retain_discovery(sock, store, header=b"POST /v1/host-info HTTP/1.1\r\nX-Slow: ")
            while time.monotonic() - began < 6:
                held.sendall(b"a")
                time.sleep(.2)
            held.sendall(b"\r\nContent-Type: application/json\r\nContent-Length: 2997\r\nX-Rui-Wire-Version: 1\r\n\r\n{")
            while True:
                try:
                    chunk = held.recv(4096)
                    if not chunk:
                        break
                except TimeoutError:
                    held.sendall(b" ")
                except (BrokenPipeError, ConnectionResetError):
                    break
                assert time.monotonic() - began < 12, "discovery trickle renewed its budget"
            elapsed = time.monotonic() - began
            assert 9 <= elapsed < 12, elapsed
            held.close()
            held = None
            fixture.wait_for(lambda: info_reply(sock, store).startswith(b"HTTP/1.1 200"), "discovery reuse after deadline/errors")
            if baseline is not None:
                wait_for_descriptors(host.pid, baseline)
            after = resource_sample(host.pid)
            assert list((store / "scratch").iterdir()) == []
            print(f"host discovery fixed-population resources (10 ordinary): {before} -> {after}; fd={len(baseline) if baseline else None}")
            # These replies/EOF do not join their handlers. Exact release and
            # subsequent control reuse are proved at the native owner boundary.
            gate.release()
            for reader in readers:
                head, body = control_fixture.read_http_response(reader, timeout=5)
                assert head.startswith(b"HTTP/1.1 200") and json.loads(body)["type"] == "session_report", (head, body)
                reader.close()
            readers.clear()
            print("host discovery passed: bounded competition, hostile ingress, disconnect and deadline; no admission-release claim from EOF")
            return
        else:
            stopped = subprocess.run([RUI, "host", "stop", "--store", store], capture_output=True, text=True, timeout=5)
            assert stopped.returncode == 0 and "Stop acknowledged" in stopped.stdout, stopped
            assert re.search(r"Host instance: ([0-9a-f]{32}) \(retry with --instance \1\)", stopped.stdout), stopped.stdout
        assert gate.fd is not None and host.poll() is None, "stop required releasing ordinary readers"
        assert status(store) == "owned_unavailable", "acknowledgement claimed lease release"
        if held is not None:
            held.close()
            held = None
        gate.release()
        for reader in readers:
            head, body = control_fixture.read_http_response(reader, timeout=5)
            assert head.startswith(b"HTTP/1.1 200") and json.loads(body)["type"] == "session_report", (head, body)
            reader.close()
        readers.clear()
        assert host.wait(timeout=5) != 0
        assert status(store) == "unavailable"
        print("host-stop saturation passed: ten captured ordinary readers; fresh CLI discovery + stop before release")
    finally:
        gate.release()
        if held is not None:
            held.close()
        for reader in readers:
            reader.close()
        stop_process(host)
        diagnostics.close()


def mixed_effect_drain(provider_first):
    """A held provider capture cannot postpone another owner's retirement."""
    order = "provider-before-Bash" if provider_first else "Bash-before-provider"
    with tempfile.TemporaryDirectory(prefix="rui-mixed-stop-") as root:
        state = pathlib.Path(root)
        store = state / "store"
        ready = state / "bash-ready"
        events = state / "events"
        quoted_events = shlex.quote(str(events))
        command = (
            f"trap 'printf \"TERM\\n\" >> {quoted_events}; exit 0' TERM; "
            f"printf ready > {shlex.quote(str(ready))}; "
            f"for ((i=0; i<600; i++)); do printf 'alive\\n' >> {quoted_events}; sleep 0.05; done"
        )
        proposal = fixture.sse_tool_calls("bash-proposal", [
            ("bash", "bash-call", json.dumps({"cmd": command, "timeout_ms": None}))
        ])
        large = fixture.sse_answer("held-provider", "private-reason", "answer", "x" * 128000)[0]
        endpoint = fixture.SuccessEndpoint([], responses_by_input={"bash": proposal, "provider": large})
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        gate = ReleaseGate(state / "capture-gate")
        cleanup_gate = state / "model-cleanup-gate"
        cleanup_gate.write_text("held")
        host = None
        diagnostics = None
        try:
            host = fixture.start_host(
                store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                "--test-response-capture-gate-path", gate.path,
                "--test-response-capture-gate-min-written-bytes", "4096",
                "--test-model-cleanup-gate-path", cleanup_gate,
                "--test-phase-trace", active_capacity=3,
            )
            diagnostics = HostDiagnostics(host)
            bash_fixture.configure(state, store, "configure-bash", "bash/session")
            fixture.message(state, store, "message-bash", "bash/session", "bash")
            action = fixture.wait_for(lambda: bash_fixture.action_for(store, "bash/session"), "Bash proposal")
            proposal_cleanup = diagnostics.wait("cleanup_started")[0]["operation"]
            fixture.configure(state, store, "configure-provider", "provider/session", "model-a")

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

            occupied = fixture.command("inspect-session", "--store", store, "--session", "bash/session")["execution"]
            assert int(occupied["custody_occupied"]) == 3, occupied
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
            contender = subprocess.run([RUI, "serve", "--store", store, "--active-capacity", "1"],
                                       capture_output=True, timeout=10)
            assert contender.returncode != 0 and b"ready store=" not in contender.stdout, contender
            gate.release()
            diagnostics.wait("cleanup_started", count=3)  # proposal, Bash, discarded provider
            assert not [record for record in diagnostics.matching("cleanup_completed", operation=proposal_cleanup)
                        if "action" not in record]
            assert host.poll() is None and status(store) == "owned_unavailable"
            cleanup_gate.unlink()
            assert host.wait(timeout=10) != 0 and b"EffectAwareShutdown" in diagnostics.tail()
            diagnostics.close()
            assert len(diagnostics.matching("cleanup_completed", action=action["action"])) == 1
            model_cleanups = [record for record in diagnostics.matching("cleanup_completed") if "action" not in record]
            assert len(model_cleanups) == 2 and len({record["operation"] for record in model_cleanups}) == 2
            assert status(store) == "unavailable"
            assert list((store / "scratch").iterdir()) == [], "mixed shutdown retained scratch"
            # Stopped-Store audit: infrastructure cleanup must not become a
            # user cancellation, a provider failure or a new continuation.
            assert bash_fixture.rows(store, "SELECT attempt_ordinal,resolution_code FROM action_operation") == [(1, "infrastructure_shutdown")]
            assert bash_fixture.rows(store, "SELECT session_ref,attempt_ordinal,resolution_code FROM model_operation ORDER BY session_ref") == [
                ("bash/session", 1, "tool_calls"), ("provider/session", 1, None),
            ]
            print(f"mixed Host stop passed: {order}, TERM and exactly-once Bash cleanup before capture release; retained model cleanup, lease held, scratch=0")
        finally:
            gate.release()
            cleanup_gate.unlink(missing_ok=True)
            if host is not None:
                if host.poll() is None:
                    # On the red path, let the original owner drain once the
                    # fixture's capture gate opens; kill only if it cannot.
                    try:
                        host.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        host.kill()
                        host.wait(timeout=10)
                if diagnostics is not None:
                    diagnostics.close()
                stop_process(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


def main():
    with tempfile.TemporaryDirectory(prefix="rui-host-stop-") as root:
        state = pathlib.Path(root)
        saturated_stop(state, competing=False)
        saturated_stop(state, competing=True)
        store = state / "store"
        gate = state / "bash-cleanup-gate"
        gate.write_text("held")
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
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                      "--test-bash-cleanup-gate-path", gate, "--test-phase-trace")
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
            occupied = fixture.command("inspect-session", "--store", store, "--session", "direct/stop")["execution"]
            assert int(occupied["custody_occupied"]) > 0, occupied
            held_fds = len(os.listdir(f"/proc/{host.pid}/fd")) if sys.platform == "linux" else None

            # Owned upload content proves ordinary classification before the
            # stop needs headroom. Sending a request line alone cannot do that.
            pending, pending_body = request(sock, store, target)
            transferred = lifecycle_fixture.hold_incomplete_connection(host, store)
            first = actor("stop", store, target, "after-commit")
            assert first == "TruncatedResponse", first
            # A drop before admission also truncates the reply. Prove the
            # first stop committed before the pending body could stop the Host.
            fixture.wait_for(lambda: not sock.exists(), "listener closure before retry")
            retry = finish(pending, pending_body)
            assert retry.startswith(b"HTTP/1.1 200") and b'"status":"acknowledged"' in retry, retry
            pending = None
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
                [RUI, "serve", "--store", store, "--active-capacity", "1"],
                capture_output=True, timeout=10,
            )
            assert contender.returncode != 0 and b"ready store=" not in contender.stdout, contender
            assert not diagnostics.matching("cleanup_completed", action=str(action["action"]))
            gate.unlink()
            diagnostics.wait("cleanup_completed", action=str(action["action"]))
            assert host.poll() is None, "transferred connection must retain lease"
            assert status(store) == "owned_unavailable"
            drained_fds = len(os.listdir(f"/proc/{host.pid}/fd")) if held_fds is not None else None
            if held_fds is not None:
                assert drained_fds < held_fds, (held_fds, drained_fds)
            transferred.close()
            transferred = None
            assert host.wait(timeout=10) != 0  # existing graceful owner reports EffectAwareShutdown
            diagnostics.close()
            diagnostics = None
            host.stdout.close()
            host.stderr.close()
            host = None
            assert status(store) == "unavailable"
            assert list((store / "scratch").iterdir()) == [], "shutdown retained scratch"
            replacement = fixture.start_host(store, None)
            newer = instance(store)
            assert newer != target
            # The first reply was lost. Retrying A's retained input must not
            # rediscover or stop live replacement B.
            assert actor("stop", store, target) == "instance_changed"
            assert instance(store) == newer
            stale_cli = subprocess.run([RUI, "host", "stop", "--store", store, "--instance", target],
                                       capture_output=True, text=True, timeout=10)
            assert stale_cli.returncode != 0 and "Host instance changed" in stale_cli.stderr, stale_cli
            assert instance(store) == newer
            current_cli = subprocess.run([RUI, "host", "stop", "--store", store],
                                         capture_output=True, text=True, timeout=10)
            assert current_cli.returncode == 0 and "Stop acknowledged; completion and lease release are not confirmed" in current_cli.stdout, current_cli
            assert f"Host instance: {newer} (retry with --instance {newer})" in current_cli.stdout
            assert replacement.wait(timeout=10) != 0
            replacement.stdout.close()
            replacement.stderr.close()
            replacement = None
            assert actor("stop", store, newer) == "unavailable", "retry may not select a replacement"
            print(f"host-stop passed: guarded rejection, acknowledged retry, held cleanup/connection lease, replacement; Linux fd={held_fds}->{drained_fds}, scratch=0")
        finally:
            gate.unlink(missing_ok=True)
            if pending is not None:
                pending.close()
            if transferred is not None:
                transferred.close()
            if diagnostics is not None and host is not None:
                stop_process(host)
                diagnostics.close()
            elif host is not None:
                stop_process(host)
            if replacement is not None:
                stop_process(replacement)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    mixed_effect_drain(True)
    mixed_effect_drain(False)
    main()
