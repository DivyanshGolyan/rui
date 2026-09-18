#!/usr/bin/env python3
import pathlib
import shutil
import sqlite3
import tempfile
import threading

import bash_integration as bash_fixture
import dispatch_integration as fixture


def execution_idle(store, session):
    report = fixture.command("inspect-session", "--store", store, "--session", session)
    execution = report["execution"]
    return report if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0" else None


def continuation_endpoint(names):
    specs = [
        fixture.ResponseSpec(
            fixture.sse_answer(
                f"{name}-continuation",
                f"{name}-continuation-reasoning",
                f"{name}-continuation-message",
                "continued",
            )[0],
            {},
        )
        for name in names
    ]
    endpoint = fixture.SuccessEndpoint(specs)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    return endpoint, thread, specs


def resolution_after_stop(store, session):
    database = sqlite3.connect(store / "rui.sqlite3")
    try:
        row = database.execute(
            "SELECT resolution_code FROM action_operation WHERE session_ref=?",
            (session,),
        ).fetchone()
        return None if row is None else row[0]
    finally:
        database.close()


def stage_action(state, store, name, command):
    responses = []
    bash_fixture.add_exchange(responses, name, command)
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
    try:
        session = f"direct/{name}"
        bash_fixture.configure(state, store, f"{name}-config", session)
        fixture.message(state, store, f"{name}-message", session, "execute")
        action = fixture.wait_for(
            lambda: bash_fixture.action_for(store, session),
            f"{name} Action",
        )
        fixture.wait_for(
            lambda: execution_idle(store, session),
            f"{name} Action creation cleanup",
        )
        return action
    finally:
        fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-bash-owner."))
    state = root / "state"
    state.mkdir(mode=0o700)
    store = root / "store"
    host = None
    completed = False
    try:
        actions = {
            "preparation-failure": stage_action(
                state, store, "preparation-failure", "printf %05d 0"
            ),
            "slot-reuse": stage_action(state, store, "slot-reuse", "true"),
        }
        endpoint, endpoint_thread, continuations = continuation_endpoint(
            ("preparation-failure", "slot-reuse")
        )
        host = fixture.start_host(
            store,
            f"http://127.0.0.1:{endpoint.server_port}/responses",
            "--test-bash-scratch-limit-bytes",
            "12",
        )
        bash_fixture.allow(
            state,
            store,
            "preparation-failure-allow",
            "direct/preparation-failure",
            actions["preparation-failure"]["action"],
        )
        fixture.wait_for(
            lambda: continuations[0].body_finished_at,
            "incremental preparation failure continuation",
        )
        bash_fixture.allow(
            state,
            store,
            "slot-reuse-allow",
            "direct/slot-reuse",
            actions["slot-reuse"]["action"],
        )
        fixture.wait_for(
            lambda: continuations[1].body_finished_at,
            "slot reuse after incremental preparation failure",
        )
        fixture.stop_host(host)
        host = None
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        assert resolution_after_stop(store, "direct/preparation-failure") == "storage_failed"
        assert resolution_after_stop(store, "direct/slot-reuse") == "succeeded"

        for name, command, expected in (
            ("exact-budget", "printf %05d 0", "succeeded"),
            ("crossing-budget", "printf %06d 0", "storage_failed"),
        ):
            isolated_store = root / f"{name}-store"
            action = stage_action(state, isolated_store, name, command)
            endpoint, endpoint_thread, continuations = continuation_endpoint((name,))
            host = fixture.start_host(
                isolated_store,
                f"http://127.0.0.1:{endpoint.server_port}/responses",
                "--test-bash-scratch-limit-bytes",
                "18",
            )
            bash_fixture.allow(
                state,
                isolated_store,
                f"{name}-allow",
                f"direct/{name}",
                action["action"],
            )
            fixture.wait_for(
                lambda: continuations[0].body_finished_at,
                f"{name} continuation",
            )
            fixture.stop_host(host)
            host = None
            endpoint.shutdown()
            endpoint.server_close()
            endpoint_thread.join(timeout=5)
            assert resolution_after_stop(isolated_store, f"direct/{name}") == expected

        name = "self-unlink"
        isolated_store = root / f"{name}-store"
        action = stage_action(state, isolated_store, name, 'rm -- "$0"; printf unlinked')
        endpoint, endpoint_thread, continuations = continuation_endpoint((name,))
        host = fixture.start_host(
            isolated_store,
            f"http://127.0.0.1:{endpoint.server_port}/responses",
        )
        bash_fixture.allow(
            state,
            isolated_store,
            f"{name}-allow",
            f"direct/{name}",
            action["action"],
        )
        fixture.wait_for(
            lambda: continuations[0].body_finished_at,
            "self-unlink continuation",
        )
        resources = fixture.command(
            "inspect-session",
            "--store",
            isolated_store,
            "--session",
            f"direct/{name}",
        )["execution"]
        assert resources["dispatch_fenced"] is False, resources
        assert resources["custody_occupied"] == "0", resources
        fixture.stop_host(host)
        host = None
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        assert resolution_after_stop(isolated_store, f"direct/{name}") == "succeeded"
        assert not list((isolated_store / "scratch").glob("bash-script-*.tmp"))
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed:
            shutil.rmtree(root)
        else:
            print(f"retained Bash owner failure state: {root}")


if __name__ == "__main__":
    main()
