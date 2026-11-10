"""Bash Action helpers that several fixtures share: model exchanges, Session
configuration, Action and process reads, the owner case's staging and disposal,
and the recovery case's gated start and finish."""
import base64
from collections import Counter
import json
import os
import pathlib
import shlex
import sqlite3
import subprocess
import sys
import threading

from host_process import dispose_all, HostDiagnostics
import model_fixture as fixture


def assert_cleanup_population(diagnostics, *, actions, models, inspection_limit):
    # Reap/drain validates final native loss and sequence first. Endpoints cannot
    # be supplied by this census after their original waits have expired.
    def owners(phase):
        return Counter((r.get("turn"), r.get("operation"), r.get("attempt"), r.get("action"))
                       for r in diagnostics.matching(phase))

    # Only Bash delivery closure starts delayed, gated cleanup; a model
    # Attempt releases custody when it completes.
    started = owners("cleanup_started")
    assert all(count == 1 for count in started.values()), started
    assert Counter(owner[3] for owner in started) == Counter(map(str, actions)), started
    completed = owners("cleanup_completed")
    assert all(count == 1 for count in completed.values()), completed
    assert Counter({owner: count for owner, count in completed.items() if owner[3] is not None}) == started, diagnostics.records
    assert sum(1 for owner in completed if owner[3] is None) == models, completed
    assert owners("cleanup_release_observed") == started, diagnostics.records
    inspections = diagnostics.matching("inspection_captured")
    assert len(inspections) <= inspection_limit, inspections
    assert len(diagnostics.records) == sum(started.values()) * 2 + sum(completed.values()) + len(inspections), diagnostics.records


def detached_shell(command):
    encoded = base64.b64encode(command.encode()).decode()
    program = (
        "import base64,os,sys;"
        "os.setsid();"
        "os.execl('/bin/sh','sh','-c',base64.b64decode(sys.argv[1]).decode())"
    )
    return " ".join(
        (shlex.quote(sys.executable), "-c", shlex.quote(program), shlex.quote(encoded))
    )


def start_detached_shell(command, ready_path):
    ready = shlex.quote(str(ready_path))
    return f"{detached_shell(command)} & while [ ! -s {ready} ]; do :; done"


def publish_pid(path, value="$$"):
    """Publish a fixture-owned shell PID expression atomically for exists waits."""
    temporary = shlex.quote(str(path.with_suffix(".tmp")))
    return (
        f'printf "%s" "{value}" > {temporary} && '
        f"mv {temporary} {shlex.quote(str(path))}"
    )


def configure(state, store, key, permission="ask", workspace=fixture.ROOT):
    result = fixture.command(
        "session", "configure",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--workspace",
        workspace,
        "--provider",
        "codex",
        "--model",
        "gpt-6-sol",
        "--tools",
        "bash",
        "--permission-mode",
        permission,
    )
    assert result["answer"]["status"] == "accepted", result
    session = result["context"]["session"]
    assert len(session) == 6 and all(c in "0123456789abcdefghjkmnpqrstvwxyz" for c in session), result
    assert result["answer"]["created"] is True, result
    return session


def actions_for(store, session, count):
    report = fixture.command("session", "inspect", "--store", store, "--session", session)
    unresolved = report["actions"]["unresolved"]
    return unresolved if len(unresolved) == count else None


def action_for(store, session):
    actions = actions_for(store, session, 1)
    return actions[0] if actions is not None else None


def allow(state, store, key, session, action):
    result = fixture.command(
        "action", "allow",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--action",
        action,
    )
    assert result["answer"]["status"] == "accepted", result
    return result


def rows(store, sql, parameters=()):
    database = sqlite3.connect(store / "rui.sqlite3")
    try:
        return database.execute(sql, parameters).fetchall()
    finally:
        database.close()


def process_resources(process):
    process_root = pathlib.Path(f"/proc/{process.pid}")
    if not process_root.exists():
        return {"process_resources": "unavailable"}
    status = {}
    for line in (process_root / "status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmHWM:")):
            name, value, unit = line.split()
            assert unit == "kB", line
            status[name[:-1]] = int(value) * 1024
    status["descriptors"] = len(os.listdir(process_root / "fd"))
    return status


def execution_custody_idle(store, session):
    report = fixture.command("session", "inspect", "--store", store, "--session", session)
    return report if report["execution"]["custody_occupied"] == "0" else None


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def resolution(store, session):
    report = fixture.command(
        "session", "inspect", "--store", store, "--session", session, "--profile", "full"
    )
    actions = report["full"]["actions"]
    return actions[0]["resolution"] if len(actions) == 1 else None


def result_text(store, session):
    report = fixture.command(
        "session", "inspect", "--store", store, "--session", session, "--profile", "full"
    )
    actions = report["full"]["actions"]
    assert len(actions) == 1 and actions[0]["resolution"] is not None, report
    return actions[0]["result"]["text"]


def add_exchange(responses, name, command, answer="continued", timeout_ms=None, stdin=None):
    arguments = {"cmd": command, "timeout_ms": timeout_ms, "description": f"Run {name} command"}
    if stdin is not None:
        arguments["stdin"] = stdin
    responses.append(
        fixture.sse_tool_calls(
            f"{name}-calls",
            [("bash", f"{name}-call", json.dumps(arguments, separators=(",", ":")))],
        )
    )
    responses.append(fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", answer)[0])


def source_revision():
    try:
        result = subprocess.run(
            ["git", "describe", "--always", "--dirty"],
            cwd=fixture.ROOT,
            text=True,
            capture_output=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable-source-export"
    return result.stdout.strip() if result.returncode == 0 else "unavailable-source-export"


def dispose_owner_case(host, endpoint, thread):
    def shutdown():
        if thread is not None and thread.ident is not None:
            try:
                endpoint.shutdown()
            except BaseException:
                # A pre-effect refusal still owns a live serving thread.
                dispose_all(endpoint.shutdown)
                raise

    def join():
        if thread is not None and thread.ident is not None:
            thread.join(timeout=5)
            assert not thread.is_alive(), "Bash owner endpoint thread did not retire"

    dispose_all(
        lambda: fixture.stop_host(host) if host is not None else None,
        shutdown,
        lambda: endpoint.server_close() if endpoint is not None else None,
        join,
    )


def execution_idle(store, session, retained_bytes=0):
    report = fixture.command("session", "inspect", "--store", store, "--session", session)
    execution = report["execution"]
    return report if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == str(retained_bytes) else None


def stage_action(state, store, name, command, stdin=None):
    responses = []
    add_exchange(responses, name, command, stdin=stdin)
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = None
    try:
        endpoint_thread.start()
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        session = configure(state, store, f"{name}-config")
        fixture.message(state, store, f"{name}-message", session, "execute")
        action = fixture.wait_for(
            lambda: action_for(store, session),
            f"{name} Action",
        )
        fixture.wait_for(
            lambda: execution_idle(store, session),
            f"{name} Action creation cleanup",
        )
        return session, action
    finally:
        dispose_owner_case(host, endpoint, endpoint_thread)


def open_gate(path):
    os.mkfifo(path)
    return os.open(path, os.O_RDWR | os.O_NONBLOCK)


def start_case(state, name, transition, command, stdin="x"):
    store = state / f"{name}-store"
    marker = state / f"{name}-effect"
    if callable(command):
        command = command(marker)
    responses = []
    add_exchange(responses, name, command, answer=f"{name} completed", stdin=stdin)
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    gate_path = state / f"{name}-gate"
    keeper = open_gate(gate_path)
    host = fixture.start_host(
        store,
        f"http://127.0.0.1:{endpoint.server_port}/responses",
        "--test-phase-trace",
        "--test-transition",
        transition.replace("_", "-"),
        "--test-transition-gate-path",
        gate_path,
    )
    diagnostics = HostDiagnostics(host)
    session = configure(state, store, f"{name}-configure", permission="bypass")
    fixture.message(state, store, f"{name}-message", session, "run")
    return store, marker, endpoint, thread, keeper, host, diagnostics, session


def finish_case(original_host, recovered_host, keeper, endpoint, thread):
    incoming_error = sys.exc_info()[1]
    errors = []
    for dispose in (lambda: fixture.stop_host(original_host) if original_host is not None else None,
                    lambda: fixture.stop_host(recovered_host) if recovered_host is not None else None,
                    lambda: os.close(keeper), endpoint.shutdown, endpoint.server_close,
                    lambda: thread.join(timeout=5)):
        try:
            dispose()
        except BaseException as error:
            errors.append(error)
    if thread.is_alive():
        errors.append(AssertionError("Bash recovery endpoint thread did not retire"))
    if errors:
        if incoming_error is None:
            raise errors[0]
        incoming_error.add_note("Bash recovery cleanup failed: " + ", ".join(type(error).__name__ for error in errors))
