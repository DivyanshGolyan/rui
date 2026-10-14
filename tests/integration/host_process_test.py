#!/usr/bin/env python3
"""Failure-sensitive checks for bounded Host process startup."""

import json
import io
import contextlib
import mmap
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from host_process import (
    READINESS_LIMIT,
    STDERR_TAIL_LIMIT,
    HostDiagnostics,
    HostStartError,
    ReleaseGate,
    _Observations,
    dispose_all,
    start_ready_process,
    stop_process,
)


def child(source):
    return [
        sys.executable,
        "-u",
        "-c",
        "import sys, time; " + source,
    ]


def assert_reaped(source, description, *, timeout=0.2, required_fields=None, observations=None):
    started = time.monotonic()
    try:
        start_ready_process(
            child(source),
            timeout=timeout,
            required_fields=required_fields,
            observations=observations,
        )
    except HostStartError as error:
        elapsed = time.monotonic() - started
        assert elapsed < timeout + 2, description
        assert error.pid > 0, description
        try:
            os.kill(error.pid, 0)
        except ProcessLookupError:
            return error, elapsed
        raise AssertionError(f"{description} child was not reaped")
    raise AssertionError(f"{description} unexpectedly became ready")


def main():
    prove_dispose_all()
    prove_caller_disposal()
    prove_terminal_capture_budget()
    prove_execution_release_oracles()
    prove_bash_cleanup_population()
    prove_required_capture_receipts()
    assert_reaped("time.sleep(10)", "silent alive")
    assert_reaped("sys.stdout.write('rea'); sys.stdout.flush(); time.sleep(10)", "partial line")
    assert_reaped("print('not-ready'); time.sleep(10)", "malformed readiness")
    assert_reaped("sys.exit(7)", "early exit")
    assert_reaped(
        "print('ready execution=unavailable'); time.sleep(10)",
        "mismatched readiness",
        required_fields={"execution": "enabled"},
    )
    flood_error, _ = assert_reaped(
        "sys.stderr.write('x' * (1024 * 1024)); sys.stderr.flush(); time.sleep(10)",
        "stderr flood",
    )
    assert "stderr_tail=" in str(flood_error)
    assert STDERR_TAIL_LIMIT <= len(str(flood_error))
    error_text_limit = 4 * (READINESS_LIMIT + STDERR_TAIL_LIMIT) + 512
    assert len(str(flood_error)) <= error_text_limit
    stdout_error, stdout_elapsed = assert_reaped(
        "sys.stdout.write('x' * (1024 * 1024)); sys.stdout.flush(); time.sleep(10)",
        "stdout flood",
        timeout=5,
    )
    assert stdout_elapsed < 1
    assert "readiness exceeded 16 KiB" in str(stdout_error)
    assert len(str(stdout_error)) <= error_text_limit
    process, fields = start_ready_process(
        child("print('ready execution=enabled curl=8.22.0'); time.sleep(10)"),
        timeout=1,
        required_fields={"execution": "enabled", "curl": "8.22.0"},
    )
    try:
        assert fields == {"execution": "enabled", "curl": "8.22.0"}
        assert process.poll() is None
    finally:
        stop_process(process)
    prove_private_environment()
    prove_coalesced_phase_records()
    prove_observation_channel()
    prove_observation_disposal()
    prove_intentional_crash_retirement()
    prove_short_optional_receipt()
    prove_gate_broadcast()


def prove_private_environment():
    with tempfile.TemporaryDirectory(prefix="rui-host-environment-") as directory:
        inherited = "RUI_TEST_PARENT_ENV"
        previous = os.environ.get(inherited)
        os.environ[inherited] = "parent-only"
        try:
            process, fields = start_ready_process(
                child("import os; print('ready home=' + os.environ['HOME'].encode().hex() "
                      "+ ' inherited=' + os.environ.get('RUI_TEST_PARENT_ENV', 'absent')); time.sleep(10)"),
                env={"HOME": directory},
                timeout=1,
            )
            try:
                assert fields == {"home": directory.encode().hex(), "inherited": "absent"}, fields
                assert os.environ[inherited] == "parent-only"
            finally:
                stop_process(process)
        finally:
            if previous is None:
                del os.environ[inherited]
            else:
                os.environ[inherited] = previous


def prove_gate_broadcast():
    with tempfile.TemporaryDirectory(prefix="rui-release-gate-") as directory:
        gate = ReleaseGate(pathlib.Path(directory) / "gate")
        readers = []
        try:
            gate.assert_held()
            for _ in range(2):
                reader = os.open(gate.path, os.O_RDONLY | os.O_NONBLOCK)
                readers.append(reader)
                try:
                    os.read(reader, 1)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("gate did not hold reader")
            gate.release()
            for reader in readers:
                assert os.read(reader, 1) == b"", "release did not broadcast EOF"
            assert not gate.path.exists(), "later native arrivals would block"
            gate.release()
        finally:
            gate.release()
            for reader in readers:
                os.close(reader)

    for case in ("released", "credited", "replaced", "unlink-failure"):
        with tempfile.TemporaryDirectory(prefix="rui-gate-refusal-") as directory:
            gate = ReleaseGate(pathlib.Path(directory) / "gate")
            descriptor = gate.fd
            try:
                if case == "released":
                    gate.release()
                elif case == "credited":
                    os.write(gate.fd, b"x")
                elif case == "replaced":
                    gate.path.unlink()
                    gate.path.write_bytes(b"not the native gate")
                else:
                    failure = OSError("gate unlink refused")
                    with patch.object(pathlib.Path, "unlink", side_effect=failure):
                        try:
                            gate.release()
                        except OSError as error:
                            assert error is failure
                        else:
                            raise AssertionError("unlink refusal was hidden")
                    assert gate.fd is None
                    try:
                        os.fstat(descriptor)
                    except OSError:
                        pass
                    else:
                        raise AssertionError("unlink refusal leaked owned FIFO descriptor")
                try:
                    gate.assert_held()
                except AssertionError:
                    pass
                else:
                    raise AssertionError(f"accepted unheld {case} transition gate")
            finally:
                gate.release()


def prove_coalesced_phase_records():
    first = {
        "rui_test_phase": "control_durable_acceptance",
        "subject_kind": "command_key",
        "subject": "stopped-pipes-stop",
    }
    second = {
        "rui_test_phase": "control_lock_acquired",
        "subject_kind": "command_key",
        "subject": "stopped-pipes-stop",
    }
    payload = json.dumps(first) + "\n" + json.dumps(second) + "\n"
    process = subprocess.Popen(
        [
            sys.executable,
            "-u",
            "-c",
            "import sys, time; sys.stderr.write(sys.argv[1]); sys.stderr.flush(); time.sleep(10)",
            payload,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    diagnostics = HostDiagnostics(process)
    try:
        matches = diagnostics.wait(
            "control_lock_acquired",
            timeout=2,
            subject_kind="command_key",
            subject="stopped-pipes-stop",
        )
        assert matches == [second], matches
        assert diagnostics.matching(
            "control_durable_acceptance",
            subject_kind="command_key",
            subject="stopped-pipes-stop",
        ) == [first]
    finally:
        stop_process(process)
        diagnostics.close()


def prove_short_optional_receipt():
    reader, writer = os.pipe()
    process = subprocess.Popen(child("sys.stderr.write('short fixture receipt\\n'); sys.stderr.flush(); sys.stdin.read(1)"),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.rui_observations = _Observations(process, reader, "list", observation_state(process.pid, 0))
    diagnostics = HostDiagnostics(process)
    try:
        deadline = time.monotonic() + 1
        while diagnostics.tail() != b"short fixture receipt\n":
            assert diagnostics.read_error is None, diagnostics.read_error
            assert time.monotonic() < deadline, "short receipt withheld until filler output or EOF"
            time.sleep(.01)
        assert process.poll() is None, "receipt required writer exit"
        assert not diagnostics.records, "optional receipt became native owner evidence"
        process.stdin.write(b"r")
        process.stdin.flush()
        assert process.wait(timeout=1) == 0
    finally:
        os.close(writer)
        stop_process(process)
        diagnostics.close()
        process.stdin.close()
    print("Host optional receipt: short write visible with writer open and no filler, no native evidence")


def observation_frame(sequence, *, phase="ordinary_classification_released", subject="message", action=None, process=None, lost=0):
    # Independent native codec golden: phase=0, timestamp=1, subject kind=2,
    # subject=3, action=7. Keep the asymmetric route/subject distinct.
    fields = ((0, phase), (1, "1234567"), (2, "route"), (3, subject))
    if action is not None:
        fields += ((7, action),)
    body = b"".join(struct.pack("<BH", index, len(value.encode())) + value.encode()
                    for index, value in fields)
    return struct.pack("<HBBQQQ", 28 + len(body), 1, lost, sequence, 37,
                       os.getpid() if process is None else process) + body


def observation_state(process, state, *, run=37, active=0, version=1):
    mapping = mmap.mmap(-1, 40)
    mapping[:] = struct.pack("<QQQQQ", version, process, run, state, active)
    return mapping


def prove_required_capture_receipts():
    import host_process
    # Optional output cannot manufacture native authority, even when complete.
    receipt = b'{"rui_test_phase":"capture_write_gate_entered","written_bytes":12345}\n'
    process = SimpleNamespace(pid=os.getpid(), stderr=io.BytesIO(receipt), poll=lambda: 0)
    diagnostics = HostDiagnostics(process)
    diagnostics.thread.join(timeout=1)
    for phase in ("capture_write_gate_entered", "transport_resume_capture_failure", "effect_stop_requested",
                  "action_attempt_admitted", "action_result_ready", "action_result_committed",
                  "preparation_completed", "prepared_before_handoff", "codex_transfer",
                  "cleanup_started", "cleanup_completed", "cleanup_release_observed",
                  "inspection_captured",
                  "bash_leader_observed_with_open_pipes", "control_store_complete"):
        for invoke in (lambda: diagnostics.wait(phase, timeout=.01), lambda: diagnostics.matching(phase)):
            try:
                invoke()
            except AssertionError as error:
                assert "native observation authority" in str(error), error
            else:
                raise AssertionError("optional stderr supplied required capture evidence")
    diagnostics.close()
    # Complete optional records and wrong native plans must both fail at the
    # authority boundary, for positive waits and negative/exact censuses.
    required = {
        "cleanup_started": ("control", "stop", "bash_cleanup"),
        "cleanup_completed": ("control", "stop", "bash_cleanup"),
        "cleanup_release_observed": ("bash_cleanup",),
        "inspection_captured": ("control", "bash_cleanup"),
        "bash_leader_observed_with_open_pipes": ("bash_pipes",),
        "control_store_complete": ("bash_pipes",),
    }
    for phase, plans in required.items():
        record = {"rui_test_phase": phase}
        for plan in (None, *host_process.OBSERVATION_LIMITS):
            observations = SimpleNamespace(plan=plan, records=[record], condition=threading.Condition(), error=None)
            process = SimpleNamespace(stderr=io.BytesIO(json.dumps(record).encode() + b"\n"), poll=lambda: 0)
            if plan is not None:
                process.rui_observations = observations
            diagnostics = HostDiagnostics(process)
            diagnostics.close()
            for invoke in (lambda: diagnostics.wait(phase, timeout=.001), lambda: diagnostics.matching(phase)):
                if plan in plans:
                    assert invoke() == [record]
                else:
                    try:
                        invoke()
                    except AssertionError as error:
                        assert "native observation authority" in str(error), error
                    else:
                        raise AssertionError((phase, plan, "wrong authority accepted"))
    assert_reaped("print('not-ready'); time.sleep(30)", "native startup retains readiness error",
                  observations="managed")
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        args = child("raise AssertionError('invalid setup launched a child')") + [
            '--store', str(root / 'store'), '--test-response-capture-gate-path', str(root / 'gate')]
        for options, expected in (({'observations': 'list'}, 'selecting native plan'),
                                  ({'env': {'RUI_FAILURE_ARTIFACTS': str(root / 'retained')}}, 'survive fixture-root deletion')):
            try:
                start_ready_process(args, **options)
            except AssertionError as error:
                assert expected in str(error), error
            else:
                raise AssertionError('invalid required-evidence setup accepted')
    source = r'''
import os, mmap, struct
def arg(name): return sys.argv[sys.argv.index(name) + 1]
state = mmap.mmap(int(arg('--test-observation-state-fd')), 40)
case = arg('--case')
count = 2 if case == 'duplicate' else 1
state[:] = struct.pack('<QQQQQ', 1, os.getpid(), 37, count * 2 + int(case == 'lost'), 0)
phase = 'cleanup_started' if case == 'missing' else 'capture_write_gate_entered'
fields = ((0, phase), (1, '1234567'), (24, '12345'))
body = b''.join(struct.pack('<BH', index, len(value)) + value.encode() for index, value in fields)
for sequence in range(1, count + 1):
    os.write(int(arg('--test-observation-fd')), struct.pack('<HBBQQQ', 28 + len(body), 1, int(case == 'lost'), sequence, 37, os.getpid()) + body)
print('ready execution=enabled curl=8.22.0', flush=True)
time.sleep(30)
'''
    for case in ('received', 'missing', 'duplicate', 'lost'):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            gate = ReleaseGate(root / 'gate')
            arguments = child(source) + ['--store', str(root / 'store'),
                '--test-response-capture-gate-path', str(gate.path), '--case', case]
            process, _ = start_ready_process(arguments, timeout=1)
            assert process.rui_observations.plan == 'capture', "gate forgot its native collector"
            destination = process.rui_failure_destination
            assert destination.is_dir() and not destination.is_relative_to(root), destination
            diagnostics = HostDiagnostics(process)
            primary = None
            try:
                try:
                    records = diagnostics.wait('capture_write_gate_entered', timeout=.02)
                    assert records[0]['written_bytes'] == '12345', records
                    if case == 'duplicate':
                        diagnostics.wait('capture_write_gate_entered', count=2, timeout=.02)
                finally:
                    diagnostics.dispose_capture(gate, lambda: {'case': case, 'capture_released': gate.fd is None})
            except AssertionError as error:
                assert case != 'received', error
                if case == 'missing':
                    assert 'timed out waiting for 1 capture_write_gate_entered' in str(error), error
                if case == 'lost':
                    assert 'native observation loss' in str(error), error
                primary = error
            assert (primary is not None) == (case != 'received')
            assert gate.fd is None and not gate.path.exists()
            assert process.returncode is not None and process.stdout.closed and process.stderr.closed
            assert not diagnostics.thread.is_alive() and not process.rui_observations.thread.is_alive()
            pid = process.pid
        assert not root.exists()
        if case != 'received':
            retained = list(destination.rglob(f'observation-failure-{pid}.json'))
            assert len(retained) == 1, retained
            facts = json.loads(retained[0].read_bytes())
            assert facts['fixture'] == {'case': case, 'capture_released': case == 'duplicate'}, facts
            assert facts['final_error'] == 'AssertionError', facts
            assert (facts['returncode'] is None) == (case != 'duplicate'), facts
            assert facts['post_reap_state'][0:3] == [1, pid, 37], facts
            assert not list(destination.rglob('rui.sqlite3'))
    class NoteFailure(AssertionError):
        def add_note(self, note):
            raise RuntimeError('secondary reporting unavailable')

    for nested, primary in ((True, AssertionError('original managed result assertion')),
                            (False, NoteFailure('original managed result assertion'))):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            process, _ = start_ready_process(child(source) + ['--store', str(root / 'store'), '--case', 'lost'],
                                             observations='managed', timeout=1)
            diagnostics = HostDiagnostics(process)
            disposed = threading.Event()
            try:
                try:
                    raise primary
                finally:
                    if nested:
                        dispose_all(lambda: stop_process(process), disposed.set)
                    else:
                        stop_process(process)
            except AssertionError as error:
                assert error is primary, error
                if nested:
                    assert any('Host cleanup failed' in note for note in error.__notes__), error
                    assert any('native observation loss invalidates evidence' in note for note in error.__notes__), error.__notes__
            if nested:
                assert disposed.is_set(), 'nested cleanup failure skipped later disposal'
            assert process.returncode is not None and process.stdout.closed and process.stderr.closed
            assert not diagnostics.thread.is_alive() and not process.rui_observations.thread.is_alive()
    print('Required receipts: optional authority/wrong plan/disposable retention refused; missing/duplicate/lost native gate fails; original failure survives release/reap/root teardown')


def prove_observation_channel():
    for case in ("reordered", "missing", "wrong-process", "loss", "duplicate", "overflow", "wrong-subject", "missing-final", "wrong-action", "missing-handoff"):
        reader, writer = os.pipe()
        process = SimpleNamespace(pid=os.getpid(), poll=lambda: 0, stderr=io.BytesIO())
        count = 2 if case == "reordered" else (0 if case == "missing-handoff" else 1)
        process.rui_observations = _Observations(process, reader, "stop", observation_state(process.pid, count * 2))
        observations = process.rui_observations
        diagnostics = HostDiagnostics(process)
        try:
            if case == "reordered":
                os.write(writer, observation_frame(2, subject="observe"))
                deadline = time.monotonic() + 1
                with observations.condition:
                    while not observations.pending_records and observations.error is None:
                        remaining = deadline - time.monotonic()
                        assert remaining > 0, "withheld-prefix controller did not reach reader"
                        observations.condition.wait(remaining)
                    assert not observations.records, "later arrival exposed an incomplete prefix"
                os.write(writer, observation_frame(1))
                assert diagnostics.wait("ordinary_classification_released", count=2, timeout=1) == [
                    dict(rui_test_phase="ordinary_classification_released", at_ns="1234567",
                         subject_kind="route", subject=subject, process=str(os.getpid()), run="37",
                         sequence=str(sequence), clock="awake_ns", trace_lost=False)
                    for sequence, subject in ((1, "message"), (2, "observe"))]
            elif case == "missing":
                os.write(writer, observation_frame(2))
            elif case == "wrong-process":
                os.write(writer, observation_frame(1, process=os.getpid() + 1))
            elif case == "loss":
                os.write(writer, observation_frame(1, lost=1))
            elif case == "duplicate":
                os.write(writer, observation_frame(1) * 2)
            elif case == "overflow":
                observations.limit = 1
                os.write(writer, observation_frame(1) + observation_frame(2))
            elif case in ("wrong-action", "missing-handoff"):
                if case == "wrong-action":
                    os.write(writer, observation_frame(1, phase="bash_handoff_committed", action="19"))
                try:
                    diagnostics.wait("bash_handoff_committed", action="17", timeout=.05)
                except AssertionError as error:
                    assert "timed out waiting" in str(error), error
                else:
                    raise AssertionError("another Action or missing handoff accepted")
            else:
                os.write(writer, observation_frame(1, subject="other" if case == "wrong-subject" else "message"))
                try:
                    diagnostics.wait("ordinary_classification_released", count=2 if case == "missing-final" else 1,
                                     subject="message", timeout=.05)
                except AssertionError as error:
                    assert "timed out waiting" in str(error), error
                else:
                    raise AssertionError("missing/wrong-subject evidence accepted")
            os.close(writer)
            writer = None
            if case in ("reordered", "wrong-subject", "missing-final", "wrong-action", "missing-handoff"):
                observations.close()
            else:
                try:
                    observations.close()
                except AssertionError as error:
                    expected = {"missing": "missing observation sequence", "wrong-process": "foreign observation",
                                "loss": "observation loss", "duplicate": "duplicate observation sequence",
                                "overflow": "population exceeded"}[case]
                    assert expected in str(error), error
                else:
                    raise AssertionError("invalid observation accepted")
        finally:
            if writer is not None:
                os.close(writer)
            observations.thread.join(1)
            assert not observations.thread.is_alive(), "observation custody leaked"
    print("Host observation channel: withheld prefix, reordered arrival, missing middle/final/handoff, wrong Action, foreign subject/process, loss, duplicate and bounded overflow controls passed")
    prove_final_observation_state()


def prove_final_observation_state():
    from host_process import OBSERVATION_LIMITS
    for plan in OBSERVATION_LIMITS:
        for case in ("normal", "tail-loss", "encoding-loss", "missing-tail", "in-flight", "missing-state", "foreign-process", "foreign-run"):
            reader, writer = os.pipe()
            process = SimpleNamespace(pid=os.getpid(), poll=lambda: -9)
            state = observation_state(process.pid, {"tail-loss": 5, "encoding-loss": 3, "missing-tail": 4}.get(case, 2),
                                      active=int(case == "in-flight"), version=0 if case == "missing-state" else 1,
                                      run=38 if case == "foreign-run" else 37)
            if case == "foreign-process":
                state = observation_state(process.pid + 1, 2)
            observations = _Observations(process, reader, plan, state)
            os.write(writer, observation_frame(1))
            os.close(writer)  # A complete received prefix and EOF, never a later loss-bearing frame.
            try:
                observations.close()
            except AssertionError as error:
                expected = {"tail-loss": "final native observation loss", "encoding-loss": "final native observation loss",
                            "missing-tail": "missing final observation sequence", "in-flight": "during observation publication",
                            "missing-state": "missing/foreign final observation state", "foreign-process": "missing/foreign final observation state",
                            "foreign-run": "mixed final observation run"}.get(case)
                assert expected and expected in str(error), (plan, case, error)
            else:
                assert case == "normal", (plan, case, "terminal channel loss accepted")
                observations.close()  # Idempotent readback after mapping custody ends.
    print("Host final observation helper: every plan rejects final loss, encoding loss, missing tail, interrupted publication and missing/foreign state with kill status; normal prefix accepted")


def prove_observation_disposal():
    import ctypes
    from host_process import OBSERVATION_LIMITS, OBSERVATION_SEALED, _observation_atomics
    native = _observation_atomics()
    for plan in OBSERVATION_LIMITS:
        for case in ("held-final", "late-loss", "missing-tail", "missing-endpoint"):
            reader, writer = os.pipe()
            process = SimpleNamespace(pid=os.getpid(), poll=lambda: None, stderr=io.BytesIO())
            state = observation_state(process.pid, 4 if case == "missing-tail" else 2,
                                      active=int(case == "held-final"))
            observations = _Observations(process, reader, plan, state)
            process.rui_observations = observations
            diagnostics = HostDiagnostics(process)
            os.write(writer, observation_frame(1))
            diagnostics.wait("ordinary_classification_released", timeout=1)
            address = ctypes.addressof(ctypes.c_char.from_buffer(state))
            result = []
            def dispose():
                try:
                    observations.dispose(time.monotonic() + .2)
                except BaseException as error:
                    result.append(error)
                else:
                    result.append(None)
            if case == "late-loss":
                # Synthetic post-seal loss stays sticky; the real native
                # late-attempt/SIGKILL ordering is separately exercised in Zig.
                state[24] = 3
            worker = threading.Thread(target=dispose)
            worker.start()
            deadline = time.monotonic() + 1
            while not native.observation_load(address + 32) & OBSERVATION_SEALED:
                assert time.monotonic() < deadline, "fixture failed to seal native admission"
                time.sleep(.001)
            if case == "held-final":
                assert worker.is_alive() and not result, "received final frame falsely proved retirement"
                # Synthetic retirement shadow: only the count byte changes.
                # The native regression holds the actual record call here.
                state[32] = 0
            worker.join(1)
            assert not worker.is_alive(), "bounded disposal worker leaked"
            if case in ("held-final", "missing-endpoint"):
                assert result == [None], result
                assert native.observation_load(address + 32) == OBSERVATION_SEALED
                if case == "missing-endpoint":
                    try:
                        diagnostics.wait("cleanup_completed", operation="7", timeout=.02)
                    except AssertionError as error:
                        expected = "timed out waiting" if plan in ("control", "stop", "bash_cleanup") else "native observation authority"
                        assert expected in str(error), error
                    else:
                        raise AssertionError("sealed zero-active channel invented a required endpoint")
            else:
                assert len(result) == 1 and isinstance(result[0], AssertionError), result
                assert ("native loss" if case == "late-loss" else "disposal budget") in str(result[0]), result
            os.close(writer)
            process.poll = lambda: -9
            try:
                observations.close()
            except AssertionError as error:
                assert case in ("late-loss", "missing-tail"), error
            else:
                assert case in ("held-final", "missing-endpoint")
    # Actual pre-teardown helper copy survives deletion of its private root,
    # without Store/HOME reads or a new retention service.
    with tempfile.TemporaryDirectory() as destination:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "store").mkdir()
            (root / "store/private").write_bytes(b"private Store bytes")
            process = SimpleNamespace(pid=os.getpid(), poll=lambda: None,
                                      args=["rui", "serve", "--store", root / "store"])
            reader, writer = os.pipe()
            observations = _Observations(process, reader, "status", observation_state(process.pid, 0))
            snapshot = observations.snapshot()
            os.close(writer)
            process.poll = lambda: -9
            observations.close()
            with patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=destination):
                observations.preserve_failure(snapshot)
        paths = list(pathlib.Path(destination).rglob("observation-failure-*.json"))
        assert len(paths) == 1 and not list(pathlib.Path(destination).rglob("private"))
        snapshot = json.loads(paths[0].read_bytes())
        assert snapshot["returncode"] is None and not snapshot["atomic_census"]
        assert snapshot["records"] == [] and snapshot["shared_state"] == [1, os.getpid(), 37, 0, 0]
    print("Host disposal: every plan drains held final custody, seals admission, refuses late loss/missing tail and missing endpoint; pre-teardown retention survives root removal")
    prove_retention_does_not_own_teardown()


def prove_intentional_crash_retirement():
    import host_process
    with patch.object(sys, "argv", [sys.argv[0], "unused-rui"]):
        import model_fixture as dispatch

    # Drive the real crash owner and native accessor. Synthetic state changes
    # discriminate receipt from retirement; actual native holds remain in Zig.
    for case in ("kill-refusal", "wait-timeout", "expired-wait", "kill-future-writer",
                 "retired", "held-final", "held-expired", "missing-tail", "loss", "sealed", "future-writer"):
        clock = [100.0]
        waits = []
        kills = []
        diagnostics_closed = []
        primary = (subprocess.TimeoutExpired("rui", 10) if case in ("wait-timeout", "expired-wait")
                   else RuntimeError("first crash kill refused") if case.startswith("kill-") else None)
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as destination:
            root = pathlib.Path(directory)
            reader, writer = os.pipe()
            process = SimpleNamespace(pid=os.getpid(), returncode=None, stdout=io.BytesIO(b"out"),
                stderr=io.BytesIO(b"err"), args=["rui", "serve", "--store", root / "store"])
            process.poll = lambda: process.returncode
            process.rui_diagnostics = SimpleNamespace(close=lambda: diagnostics_closed.append(True))
            state = observation_state(process.pid, 4 if case == "missing-tail" else 3 if case == "loss" else 2,
                                      active=int(case.startswith("held")))
            if case == "sealed":
                struct.pack_into("<Q", state, 32, host_process.OBSERVATION_SEALED)
            observations = _Observations(process, reader, "recovery", state)
            observations._accept(observation_frame(1, phase="action_result_ready", action="1"))
            process.rui_observations = observations

            def sleep(_):
                clock[0] += 4.5 if case in ("held-expired", "missing-tail") else .25
                if case == "held-final":
                    struct.pack_into("<Q", state, 32, 0)

            def kill():
                kills.append(clock[0])
                if len(kills) == 1 and primary is not None:
                    if case.startswith("kill-"):
                        clock[0] += .25
                        raise primary
                    return  # Sent termination has not yet produced an exit.
                if case in ("future-writer", "kill-future-writer"):
                    active = struct.unpack_from("<Q", state, 32)[0]
                    struct.pack_into("<Q", state, 32, active + 1)
                process.returncode = -9
                os.close(writer)

            def wait(*, timeout):
                waits.append((clock[0], timeout))
                if len(waits) == 1 and case in ("wait-timeout", "expired-wait"):
                    clock[0] += 10 if case == "expired-wait" else 2
                    raise primary
                return process.returncode

            process.kill, process.wait = kill, wait
            virtual_time = SimpleNamespace(monotonic=lambda: clock[0], sleep=sleep)
            expected = {"held-expired": "crash budget", "missing-tail": "crash budget",
                        "loss": "native loss", "sealed": "admission was sealed",
                        "future-writer": "during observation publication"}.get(case)
            with patch.object(host_process, "time", virtual_time), patch.object(dispatch, "time", virtual_time), \
                    patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=destination), contextlib.redirect_stderr(io.StringIO()):
                try:
                    result = dispatch.crash_host(process, root, case)
                except BaseException as error:
                    if primary is not None:
                        assert error is primary, (case, error)
                    else:
                        assert expected and expected in str(error), (case, error)
                else:
                    assert primary is None and expected is None and result == {"returncode": -9, "stdout": b"out", "stderr": b"err"}, case
            assert process.returncode == -9 and process.stdout.closed and process.stderr.closed
            assert not observations.thread.is_alive() and state.closed and diagnostics_closed
            assert bool(observations.final_state[4] & host_process.OBSERVATION_SEALED) == (case == "sealed"), f"{case}: intentional crash cleanup sealed admission"
            assert all(timeout == max(0, 110 - at) for at, timeout in waits), f"{case}: crash reap renewed its original allowance"
            if case == "held-final":
                assert clock[0] == 100.25 and waits[0][1] == 9.75, "receipt bypassed publication retirement"
            if case == "kill-future-writer":
                assert observations.final_state[4] == 1, "future publication custody was hidden"
                assert any("Host cleanup failed" in note for note in primary.__notes__), primary
            if expected or primary is not None:
                assert len(list(pathlib.Path(destination).rglob("observation-failure-*.json"))) == 1
    print("Intentional crash: receipt custody retires unsealed inside original budget; withheld/lost evidence and future writers fail with teardown/retention")


def prove_retention_does_not_own_teardown():
    import host_process
    import run_selected  # Loaded by the preceding real retention helper call.
    # Sampling itself is optional, including failures before write_text/open.
    with tempfile.TemporaryDirectory() as directory:
        try:
            raise AssertionError("original fixture failure")
        except AssertionError as original:
            assert not host_process.preserve_failure_metadata(pathlib.Path(directory) / "pty-failure.json",
                lambda: os.read(-1, 1))
            assert sys.exc_info()[1] is original, "metadata sampling replaced original failure"
    for case in ("write-failure", "copy-failure", "late-loss"):
        with tempfile.TemporaryDirectory() as destination, tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            reader, writer = os.pipe()
            process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                "--store", str(root / "store")], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                pass_fds=(writer,))
            os.close(writer)  # Only child custody now; kill must produce EOF.
            state = observation_state(process.pid, 0)
            observations = _Observations(process, reader, "status", state)
            process.rui_observations = observations
            copied = []
            def copy(*args):
                assert process.returncode == -9 and process.stdout.closed and process.stderr.closed
                copied.append(True)
                if case == "copy-failure":
                    raise OSError("unavailable hosted destination")
            original_kill = process.kill
            def kill():
                if case == "late-loss":
                    state[24] = 1  # Synthetic native loss after successful seal.
                original_kill()
            original_open = pathlib.Path.open
            def open_path(path, *args, **kwargs):
                if case == "write-failure" and path.name.startswith("observation-failure-"):
                    raise OSError("unavailable fixture destination")
                return original_open(path, *args, **kwargs)
            try:
                with patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=destination), \
                        patch.object(run_selected, "retain_failure_logs", copy), \
                        patch.object(pathlib.Path, "open", open_path), patch.object(process, "kill", kill):
                    if case == "late-loss":
                        try:
                            stop_process(process, timeout=1)
                        except AssertionError as error:
                            assert "final native observation loss" in str(error), error
                        else:
                            raise AssertionError("post-seal loss became acceptance")
                    else:
                        try:
                            raise AssertionError("original fixture failure")
                        except AssertionError as original:
                            stop_process(process, timeout=1)
                            assert sys.exc_info()[1] is original, "optional retention replaced original failure"
                assert process.returncode == -9 and process.stdout.closed and process.stderr.closed
                assert not observations.thread.is_alive() and observations.final_state is not None
                assert copied == ([] if case == "write-failure" else [True]), copied
                if case == "late-loss":
                    snapshot = json.loads(next(root.glob("observation-failure-*.json")).read_bytes())
                    assert snapshot["stage"] == "pre_kill" and snapshot["shared_state"][3] == 0
                    assert snapshot["post_reap_state"][3] == 1 and snapshot["final_error"] == "AssertionError"
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
    print("Host retention: sampling/write/copy refusal preserves original failure and actual SIGKILL/reap/closed custody; post-seal loss retains distinct pre/post states")


def prove_execution_release_oracles():
    import host_process

    def refused(invoke, description):
        try:
            invoke()
        except AssertionError as error:
            assert description in str(error), error
        else:
            raise AssertionError(f"accepted {description}")

    clean = dict(dispatch_fenced=False, custody_occupied="0", scratch_used_bytes="0")
    # Independently authored accounting snapshots: separate zeros do not add
    # up to a release, and a clean reply at the deadline is already too late.
    for sequence, accepted, finished_at in (
        ([dict(clean, custody_occupied="1"), clean], True, 0.1),
        ([dict(clean, custody_occupied="1")], False, 0.1),
        ([dict(clean, scratch_used_bytes="4096")], False, 0.1),
        ([dict(clean, custody_occupied="1"), dict(clean, scratch_used_bytes="4096")], False, 0.1),
        ([clean], False, 0.5),
        ([clean], False, 0.6),
    ):
        now = [0.0]
        replies = iter(sequence)
        def inspect(remaining):
            assert 0 < remaining <= 0.5 - now[0], remaining
            now[0] += finished_at
            return next(replies, sequence[-1])
        clock = SimpleNamespace(monotonic=lambda: now[0], sleep=lambda delay: None)
        with patch.object(host_process, "time", clock):
            invoke = lambda: host_process.wait_for_execution_release(inspect, 0.5)
            if accepted:
                assert invoke() == clean
            else:
                refused(invoke, "custody drainage")
    with patch.object(host_process.time, "monotonic", return_value=100):
        for deadline, expected in ((145, 15), (101, 1)):
            def inspect(remaining):
                assert remaining == expected, remaining
                return clean
            assert host_process.wait_for_execution_release(inspect, deadline) == clean
        refused(lambda: host_process.wait_for_execution_release(lambda _: dict(clean, dispatch_fenced=True), 101), "dispatch_fenced")

    for limit in (49, 50):
        diagnostics = HostDiagnostics(SimpleNamespace(stderr=io.BytesIO(), poll=lambda: 0))
        diagnostics.close()
        for _ in range(limit):
            diagnostics.claim_inspection(limit)
        assert diagnostics.records == [], "missing receipts must not refund issued inspections"
        refused(lambda: diagnostics.claim_inspection(limit), "inspection population")

    processing = dict(turn="7", operation="11", attempt="2")
    endpoint = dict(processing, rui_test_phase="cleanup_completed", action=None)
    # Drive the actual diagnostics reader and identity selector. Synthetic
    # frames test the oracle; they do not qualify a native Host's reclamation.
    for records, accepted in (
        ([endpoint], True), ([], False), ([dict(endpoint, turn="8")], False),
        ([dict(endpoint, operation="12")], False), ([dict(endpoint, attempt="3")], False),
        ([dict(endpoint, action="19")], False), ([endpoint, endpoint], False),
    ):
        observations = SimpleNamespace(plan="control", records=list(records), condition=threading.Condition(), error=None)
        diagnostics = HostDiagnostics(SimpleNamespace(stderr=io.BytesIO(), poll=lambda: 0, rui_observations=observations))
        diagnostics.close()
        invoke = lambda: diagnostics.wait_model_cleanup(processing, time.monotonic() + 0.001)
        if accepted:
            assert invoke() == endpoint
            diagnostics.assert_model_cleanup_census(processing)
            with patch.object(host_process.time, "monotonic", return_value=10):
                refused(lambda: diagnostics.wait_model_cleanup(processing, 10), "physical cleanup deadline")
            original_wait = diagnostics.wait
            for completed_at in (9.999, 10.0, 10.5):
                now = [9.0]
                def wait(*args, **kwargs):
                    records = original_wait(*args, **kwargs)
                    now[0] = completed_at
                    return records
                clock = SimpleNamespace(monotonic=lambda: now[0])
                with patch.object(host_process, "time", clock), patch.object(diagnostics, "wait", wait):
                    if completed_at < 10:
                        assert diagnostics.wait_model_cleanup(processing, 10) == endpoint
                    else:
                        refused(lambda: diagnostics.wait_model_cleanup(processing, 10), "cleanup endpoint arrived")
            # A duplicate or unrelated owner discovered after first success
            # must still fail the complete post-reap population.
            for late in (endpoint, dict(endpoint, operation="12")):
                diagnostics.records.append(late)
                refused(lambda: diagnostics.assert_model_cleanup_census(processing), "Counter")
                diagnostics.records.pop()
        elif records == [endpoint, endpoint]:
            refused(invoke, "cleanup_completed")
        else:
            refused(invoke, "timed out")
    print("Execution release oracle: simultaneous accounting, exact cleanup owners/final population, withheld custody/scratch, late replies, caller and inspection bounds")


def prove_bash_cleanup_population():
    from bash_integration import assert_cleanup_population

    records = []
    for action in (None, "19"):
        for phase in ("cleanup_started", "cleanup_release_observed", "cleanup_completed"):
            records.append(dict(rui_test_phase=phase, turn="7", operation="11", attempt="1", action=action))
    records.append(dict(rui_test_phase="inspection_captured"))
    for case in ("normal", "missing", "duplicate", "wrong-owner", "extra-phase", "inspection-overflow"):
        values = [dict(r) for r in records]
        if case == "missing":
            values.pop(2)
        elif case == "duplicate":
            values.append(dict(values[1]))  # Retry must not duplicate release authority.
        elif case == "wrong-owner":
            values[2]["operation"] = "12"
        elif case == "extra-phase":
            values.append(dict(rui_test_phase="lifecycle_boundary"))
        elif case == "inspection-overflow":
            values.append(dict(values[-1]))
        observations = SimpleNamespace(plan="bash_cleanup", records=values, condition=threading.Condition(), error=None)
        diagnostics = HostDiagnostics(SimpleNamespace(stderr=io.BytesIO(), poll=lambda: 0, rui_observations=observations))
        diagnostics.close()
        try:
            assert_cleanup_population(diagnostics, actions=[19], models=1, model_releases=True, inspection_limit=1)
        except AssertionError:
            assert case != "normal", case
        else:
            assert case == "normal", case
    print("Bash cleanup census: exact unique owner endpoints, single release, inspection bound and no extra phases")


def prove_capacity_refusal_oracle(probe):
    module = sys.modules[probe.__module__]
    class ConnectedSocket(socket.socket):
        def connect(self, _path):
            pass  # The socketpair is already connected; send/receive/close are real.

    connection_body = b'{"version":"1","type":"busy","code":"connection_capacity_exhausted"}'
    ordinary_body = b'{"version":"1","type":"busy","code":"ordinary_capacity_exhausted"}'
    for case in ("early-complete", "ordinary-complete", "empty", "truncated", "wrong-code",
                 "wrong-status", "code-suffix", "missing-length", "duplicate-length"):
        body = connection_body
        if case == "wrong-code":
            body = ordinary_body
        elif case == "code-suffix":
            body = connection_body.replace(b'"connection_capacity_exhausted"', b'"connection_capacity_exhausted_extra"')
        elif case == "ordinary-complete":
            body = ordinary_body
        status = b"200 OK" if case == "wrong-status" else b"503 Service Unavailable"
        length = b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        if case == "missing-length":
            length = b""
        elif case == "duplicate-length":
            length *= 2
        response = b"HTTP/1.1 " + status + b"\r\n" + length + b"\r\n" + body
        if case == "truncated":
            response = response[:-1]
        elif case == "empty":
            response = b""
        client, peer = socket.socketpair()
        client = ConnectedSocket(fileno=client.detach())
        peer.settimeout(3)
        errors = []

        def respond():
            try:
                if case == "ordinary-complete":
                    request = bytearray()
                    while b"\r\n" not in request:
                        chunk = peer.recv(4096)
                        assert chunk, "ordinary probe closed before classification"
                        request.extend(chunk)
                peer.sendall(response)
            except BaseException as error:
                errors.append(error)
            finally:
                peer.close()

        thread = None
        if case == "ordinary-complete":
            thread = threading.Thread(target=respond)
            thread.start()
        else:
            respond()  # A complete refusal can precede the client's first write.
        try:
            with patch.object(module.socket, "socket", return_value=client):
                probe("unused", b"ordinary_capacity_exhausted" if case == "ordinary-complete"
                      else b"connection_capacity_exhausted")
        except (AssertionError, ValueError):
            assert case not in ("early-complete", "ordinary-complete"), case
        else:
            assert case in ("early-complete", "ordinary-complete"), ("invalid refusal accepted", case)
        finally:
            client.close()
            if thread is not None:
                thread.join(3)
                assert not thread.is_alive(), case
            assert not errors, errors
    print("Capacity refusal oracle: pre-write close and classified replies; empty, truncated, wrong status/code/framing refused")


def prove_control_disposal_oracle(dispose):
    module = sys.modules[dispose.__module__]
    for broken in ((), ("connection",), ("stop",), ("gate",), ("diagnostics",),
                   ("shutdown",), ("server",), ("join",), ("stop", "gate", "shutdown")):
        for failing_body in (False, True):
            closed = set()
            failures = {name: RuntimeError(name) for name in broken}
            primary = AssertionError("original Control assertion")

            def close(name):
                closed.add(name)
                if name in failures:
                    raise failures[name]

            endpoint = SimpleNamespace(release=SimpleNamespace(set=lambda: close("release")),
                                       shutdown=lambda: close("shutdown"), server_close=lambda: close("server"))
            thread = SimpleNamespace(join=lambda timeout: close("join"), is_alive=lambda: "join" not in closed)
            diagnostics = SimpleNamespace(close=lambda: close("diagnostics"))
            connection = SimpleNamespace(close=lambda: close("connection"))
            with patch.object(module, "stop_process", lambda process: close("stop")), \
                    contextlib.redirect_stderr(io.StringIO()):
                try:
                    try:
                        if failing_body:
                            raise primary
                    finally:
                        dispose(object(), diagnostics, endpoint, thread, lambda: close("gate"),
                                connections=[connection])
                except BaseException as error:
                    assert error is (primary if failing_body else failures[broken[0]]), error
                else:
                    assert not failing_body and not broken
            assert closed == {"connection", "stop", "gate", "diagnostics", "release", "shutdown", "server", "join"}, closed
    print("Control disposal oracle: original assertion survives every cleanup failure; every owned resource still receives disposal")


def prove_terminal_capture_budget():
    """Drive the actual capture caller; only external work uses a virtual clock."""
    with patch.object(sys, "argv", [sys.argv[0], "unused-rui"]):
        import terminal_restoration_integration as terminal

    for late_stage in (None, "read", "release"):
        clock = [100.0]
        reached = []
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as patches:
            root = pathlib.Path(directory)
            held = {"process": "123", "run": "1", "subject": "diagnostic/session"}
            inspector = MagicMock(returncode=0)
            inspector.communicate.return_value = (b"", b"")
            inspector.poll.return_value = 0
            diagnostics = MagicMock()
            diagnostics.wait.return_value = [{**held, "written_bytes": "0"}]
            diagnostics.tail.return_value = b""
            gate = MagicMock()
            gate.path = root / "gate"
            gate.path.touch()

            def start_inspector(*args):
                (root / "capture-receipt" / "probe.log").write_text(
                    "diagnostic-held-inspection\n" + json.dumps(held) + "\n")
                return inspector

            def observe(*args, **kwargs):
                clock[0] += 6
                return {"result": {"status": "completed"}}

            def read(*args, **kwargs):
                reached.append("read")
                clock[0] += 5 if late_stage == "read" else 1
                return SimpleNamespace(returncode=0, stdout=b"exact capture answer", stderr=b"")

            def inspect(*args, **kwargs):
                reached.append("release")
                clock[0] += 4 if late_stage == "release" else 1
                return {"execution": {"dispatch_fenced": False,
                    "custody_occupied": "0", "scratch_used_bytes": "0"}}

            replacements = {
                "start_ready_process": lambda *args, **kwargs: (SimpleNamespace(pid=123), None),
                "HostDiagnostics": lambda *args: diagnostics,
                "ReleaseGate": lambda *args: gate,
            }
            for name, replacement in replacements.items():
                patches.enter_context(patch.object(terminal, name, replacement))
            for name, replacement in {
                "SuccessEndpoint": MagicMock(), "configure": MagicMock(), "message": MagicMock(),
                "start_command": start_inspector, "observe": observe, "command": inspect,
            }.items():
                patches.enter_context(patch.object(terminal.fixture, name, replacement))
            patches.enter_context(patch.object(terminal.threading, "Thread", MagicMock()))
            terminal.threading.Thread.return_value.is_alive.return_value = False
            patches.enter_context(patch.object(time, "monotonic", lambda: clock[0]))
            patches.enter_context(patch.object(terminal.fixture.subprocess, "run", read))
            patches.enter_context(contextlib.redirect_stdout(io.StringIO()))
            try:
                terminal.capture_receipt_case(root, root / "unused.so")
            except AssertionError as error:
                assert late_stage is not None, error
                assert "exceeded original deadline" in str(error), error
                assert reached[-1] == late_stage, reached
            else:
                assert late_stage is None, f"accepted late {late_stage} at {clock[0]}"
                assert reached == ["read", "release"], reached
    print("Terminal capture caller clock: timely exact read/release accepted; late exact read and release rejected")


def prove_dispose_all():
    for body_failed in (True, False):
        body_error = AssertionError("original body failure")
        cleanup_error = RuntimeError("first cleanup failure")
        later_error = OSError("later cleanup failure; release gate manually: " + "x" * 2000)
        reader, writer = os.pipe()
        process = subprocess.Popen(child("time.sleep(10)"))
        attempted = []

        def fail(error):
            attempted.append(error)
            raise error

        try:
            try:
                if body_failed:
                    raise body_error
            finally:
                dispose_all(lambda: fail(cleanup_error),
                            lambda: os.close(reader),
                            lambda: fail(later_error),
                            lambda: stop_process(process, timeout=5),
                            lambda: os.close(writer))
        except BaseException as error:
            assert error is (body_error if body_failed else cleanup_error), error
            assert attempted == [cleanup_error, later_error], attempted
            assert len(error.__notes__) == 2, error.__notes__
            assert "disposal 1" in error.__notes__[0] and "first cleanup failure" in error.__notes__[0], error.__notes__
            assert "disposal 3" in error.__notes__[1] and "release gate manually" in error.__notes__[1], error.__notes__
            assert "[truncated]" not in error.__notes__[0], error.__notes__
            assert error.__notes__[1].endswith("[truncated]"), "cleanup detail was silently truncated"
            assert all(len(note) < 1024 for note in error.__notes__), "unbounded cleanup diagnostic"
            assert process.poll() is not None, "later child disposal skipped"
            for fd in (reader, writer):
                try:
                    os.fstat(fd)
                except OSError:
                    pass
                else:
                    raise AssertionError("later descriptor disposal skipped")
        else:
            raise AssertionError("cleanup failure suppressed on successful body")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for fd in (reader, writer):
                try:
                    os.close(fd)
                except OSError:
                    pass
    print("Fixture disposal: primary failure retained, all resources attempted")


def prove_caller_disposal():
    with patch.object(sys, "argv", [sys.argv[0], "unused-rui"]):
        import dispatch_integration as dispatch
        import conversation_page_integration as page
        import bash_owner_integration as bash

    for owner in (dispatch, page, bash):
        for body_failed in (False, True):
            for fault in (None, "stop", "shutdown", "close"):
                primary = AssertionError("original caller assertion")
                cleanup = RuntimeError(f"injected {fault}")
                processes = [subprocess.Popen(child("time.sleep(30)"), stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE)
                             for _ in range(2 if owner is dispatch else 1)]
                endpoints = [dispatch.SuccessEndpoint([]) for _ in processes]
                threads = [threading.Thread(target=endpoint.serve_forever) for endpoint in endpoints]
                for thread in threads:
                    thread.start()
                release = threading.Event()
                retained = []
                original_shutdown = endpoints[0].shutdown
                original_close = endpoints[0].server_close

                def stop(process):
                    stop_process(process)
                    if process is processes[0] and fault == "stop":
                        raise cleanup

                def shutdown():
                    original_shutdown()
                    if fault == "shutdown":
                        raise cleanup

                def close():
                    original_close()
                    if fault == "close":
                        raise cleanup

                stop_module, stop_name = (bash.fixture, "stop_host") if owner is bash else (
                    owner, "stop_host" if owner is dispatch else "stop_process")
                try:
                    with patch.object(stop_module, stop_name, stop), \
                            patch.object(endpoints[0], "shutdown", shutdown), \
                            patch.object(endpoints[0], "server_close", close):
                        caught = None
                        try:
                            try:
                                if body_failed:
                                    raise primary
                            finally:
                                if owner is dispatch:
                                    dispatch.dispose_dispatch(processes, dict(zip(endpoints, threads)),
                                                              [release.set], lambda: retained.append(True))
                                else:
                                    dispose = (lambda: page.dispose_page(processes[0], endpoints[0], threads[0], 3)
                                               if owner is page else
                                               bash.dispose_owner_case(processes[0], endpoints[0], threads[0]))
                                    dispose_all(release.set, dispose, lambda: retained.append(True))
                        except BaseException as error:
                            caught = error
                        # Check retirement before exception identity so a grouped
                        # process loop mutation fails at the skipped second child.
                        assert all(process.poll() is not None for process in processes), "later child disposal skipped"
                        assert all(process.stdout.closed and process.stderr.closed for process in processes)
                        assert all(endpoint.fileno() == -1 for endpoint in endpoints), "endpoint close skipped"
                        assert all(not thread.is_alive() for thread in threads), "endpoint retirement skipped"
                        assert release.is_set() and retained == [True], "release or retention skipped"
                        assert caught is (primary if body_failed else cleanup if fault else None), caught
                        if fault:
                            assert any(f"injected {fault}" in note for note in caught.__notes__), caught
                finally:
                    # Keep a deliberately broken candidate from leaking test resources.
                    dispose_all(*(lambda process=process: stop_process(process) for process in processes),
                                original_shutdown, original_close,
                                *(endpoint.shutdown for endpoint in endpoints[1:]),
                                *(endpoint.server_close for endpoint in endpoints[1:]),
                                *(lambda thread=thread: thread.join(timeout=5) for thread in threads))

    # Execute stage_action's actual startup boundary, not just its disposer.
    endpoint = dispatch.SuccessEndpoint([])
    startup = RuntimeError("Host startup refused")
    with patch.object(bash.fixture, "SuccessEndpoint", return_value=endpoint), \
            patch.object(bash.fixture, "start_host", side_effect=startup):
        try:
            bash.stage_action(pathlib.Path("unused"), pathlib.Path("unused"), "startup", "true")
        except RuntimeError as error:
            assert error is startup
        finally:
            closed = endpoint.fileno() == -1
            endpoint.shutdown()
            endpoint.server_close()
        assert closed, "stage_action startup leaked endpoint"

    # A timed join returning is not retirement, even with successful shutdown.
    endpoint = MagicMock()
    thread = SimpleNamespace(ident=1, join=lambda timeout: None, is_alive=lambda: True)
    for dispose in (lambda: dispatch.stop_endpoint(endpoint, {endpoint: thread}),
                    lambda: page.dispose_page(None, endpoint, thread, 3),
                    lambda: bash.dispose_owner_case(None, endpoint, thread)):
        try:
            dispose()
        except AssertionError as error:
            assert "thread did not retire" in str(error), error
        else:
            raise AssertionError("live endpoint thread accepted as retired")
    print("Caller disposal: dispatch/page/Bash body and cleanup faults, multiple children/endpoints, startup refusal and live-thread rejection passed")


if __name__ == "__main__":
    main()
