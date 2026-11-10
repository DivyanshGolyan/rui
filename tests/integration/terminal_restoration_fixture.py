"""Terminal restoration helpers that the human CLI fixture, terminal input replay
and host_process_test.py share: file-flag assertions, the stop receipt case and
renderer comparison retention."""
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

from host_process import cleanup_failure, copy_failure_diagnostics, HostDiagnostics, preserve_failure_metadata, start_ready_process
import model_fixture as fixture
import os_semantics


def assert_file_flags(actual, expected):
    # Keep every bit but kernel write history exact, including access mode
    # and O_NONBLOCK.
    assert os_semantics.user_file_flags(actual) == os_semantics.user_file_flags(expected), (
        f"file flags actual={actual:#x} expected={expected:#x} excluded={os_semantics.FILE_FLAG_HISTORY:#x}")


def stop_receipt_case(state, library):
    """While real, unrelated optional stderr custody is held, one response
    is captured exactly and a required stop receipt is delivered."""
    root = state / "stop-receipt"
    root.mkdir(mode=0o700)
    store = root / "store"
    arm, release, log = (root / name for name in ("arm", "release", "probe.log"))
    answer = b"exact capture answer"
    provider_release = threading.Event()
    stop_release = threading.Event()
    # The second peer response is never released: that Transfer is stopped.
    endpoint = fixture.SuccessEndpoint([], responses_by_input={
        "hello": (fixture.sse_answer("capture", "reason", "message", answer.decode())[0], provider_release),
        "stop": (fixture.ResponseSpec(b"unused", {}), stop_release)})
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    host = diagnostics = inspector = None
    try:
        host, _ = start_ready_process(fixture.host_arguments(store,
            f"http://127.0.0.1:{endpoint.server_port}/responses", "--test-phase-trace",
            active_capacity=2), observations="interrupt", env={**os.environ,
            os_semantics.PRELOAD: str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "diagnostic-contention",
            "RUI_DIAGNOSTIC_DROP_FIRST_INSPECTION": "1",
            "RUI_DIAGNOSTIC_ARM": str(arm), "RUI_DIAGNOSTIC_RELEASE": str(release)})
        diagnostics = HostDiagnostics(host)
        session = fixture.configure(root, store, "capture-config", None, "gpt-6-sol")
        stop_session = fixture.configure(root, store, "stop-config", None, "gpt-6-sol")
        # Admission uses the ordinary worker; complete it before that worker
        # holds optional stderr. Only provider work must progress under hold.
        fixture.message(root, store, "capture-message", session, "hello")
        fixture.message(root, store, "stop-message", stop_session, "stop")
        fixture.wait_for(lambda: len(endpoint.requests) == 2, "held provider requests", timeout=3)
        processing = fixture.observe(store, "stop-message")["binding"]
        arm.write_text(session)
        # A specific optional write may lose custody or output credit. Seek an
        # actual hold without requiring delivery of any one inspection trace.
        # The first eligible write deliberately fails to exercise that case.
        acquisition_deadline = time.monotonic() + 3
        while True:
            remaining = acquisition_deadline - time.monotonic()
            assert remaining > 0, "actual optional inspection custody exhausted original deadline"
            inspector = fixture.start_command("session", "inspect", "--store", store, "--session", session)
            fixture.wait_for(lambda: (log.exists() and "diagnostic-held-inspection\n" in log.read_text())
                or inspector.poll() is not None, "optional inspection hold or completed caller", timeout=remaining)
            assert time.monotonic() < acquisition_deadline, "actual optional inspection custody exceeded original deadline"
            if log.exists() and "diagnostic-held-inspection\n" in log.read_text():
                break
            out, err = inspector.communicate(timeout=max(0, acquisition_deadline - time.monotonic()))
            assert inspector.returncode == 0, (out, err)
            assert json.loads(out)["session"]["reference"] == session, out
        assert log.read_text().count("diagnostic-dropped-inspection\n") == 1
        held = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
        assert len(held) == 1 and held[0]["process"] == str(host.pid) and held[0]["subject"] == session, held
        # The answer streams in and is captured while stderr is held.
        provider_release.set()
        reply = fixture.command(
            "session", "interrupt-model", "--store", store, "--record", root / "stop-interrupt.json",
            "--key", "stop-interrupt", "--session", stop_session,
            "--turn", processing["turn"], "--operation", processing["operation"],
        )
        assert reply["answer"]["status"] == "accepted", reply
        event = diagnostics.wait("effect_stop_requested", control_key="stop-interrupt", timeout=15)[0]
        assert event["process"] == held[0]["process"] and event["run"] == held[0]["run"], (event, held)
        assert not release.exists(), event
        assert b"effect_stop_requested" not in diagnostics.tail(), "optional output supplied required receipt"
        release.touch()
        out, err = inspector.communicate(timeout=3)
        assert inspector.returncode == 0, (out, err)
        deadline = time.monotonic() + 10
        observation, saved_answer, _ = fixture.wait_for_result_release(
            store, "capture-message", session, deadline)
        assert observation["result"]["status"] == "completed", observation
        assert saved_answer == answer
        stopped, stopped_answer, _ = fixture.wait_for_result_release(
            store, "stop-message", stop_session, deadline)
        assert stopped["result"]["status"] == "cancelled", stopped
        assert stopped_answer is None
        print("native stop receipt: optional inspection drop tolerated within original deadline; exact answer captured and stop receipt delivered under actual stderr contention; peer-held stream cancelled; simultaneous zero custody/scratch", flush=True)
    finally:
        incoming_error = sys.exc_info()[1]
        if diagnostics is not None:
            diagnostics.snapshot_failure(lambda: {"case": "stop-receipt", "optional_released": release.exists()})

        def retire_inspector():
            if inspector is not None and inspector.poll() is None:
                try:
                    inspector.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    inspector.kill()
                    inspector.communicate(timeout=3)
                    raise  # Mandatory reap does not accept the timed-out caller.

        errors = []
        for dispose in (release.touch, retire_inspector,
                        lambda: diagnostics.dispose_interrupt(
                            lambda: {"case": "stop-receipt", "optional_released": release.exists()},
                            controls=("stop-interrupt",))
                            if diagnostics is not None else None,
                        provider_release.set, stop_release.set,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        if thread.is_alive():
            errors.append(AssertionError("Stop endpoint thread did not retire"))
        if errors:
            if incoming_error is None:
                raise errors[0]
            try:
                incoming_error.add_note("Stop cleanup failed: " + ", ".join(cleanup_failure(error) for error in errors))
            except BaseException:
                pass  # Secondary reporting cannot replace the primary failure.


def preserve_renderer_comparison(state, before, after, screen_start, events, omitted_events):
    """Keep exact synthetic-fixture operands outside disposal's temporary root.

    Hex is lossless encoding, not redaction. This case has only fixture-owned
    configuration text, no model request/response or user-provided content.
    Never generalize this capture to other terminal journeys. Existing whole-
    file/job caps refuse oversized evidence rather than truncating operands.
    """
    try:
        root = state / "renderer-comparison"
        root.mkdir(mode=0o700)
        difference = next((index for index, (left, right) in enumerate(zip(before, after))
                           if left != right), min(len(before), len(after)))
        path = root / "pty-failure.json"
        if not preserve_failure_metadata(path, lambda: {
            "case": "renderer-backpressure", "phase": "idle-after-configure",
            "retained_at_ns": time.monotonic_ns(), "screen_start": screen_start,
            "equal": before == after, "before_hex": before.hex(), "after_hex": after.hex(),
            "first_difference": difference,
            "before_delta_hex": before[difference:].hex(),
            "after_delta_hex": after[difference:].hex(),
            "events": events, "omitted_events": omitted_events,
        }):
            return
        destination = pathlib.Path(os.environ.get("RUI_FAILURE_ARTIFACTS", ".amp/failure-artifacts"))
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        copy_failure_diagnostics(root, destination)
        print(f"renderer comparison destination: {destination}", file=sys.stderr, flush=True)
    except Exception as error:
        # Optional evidence cannot replace the assertion or prevent disposal.
        try:
            print(f"Renderer comparison unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
        except Exception:
            pass
