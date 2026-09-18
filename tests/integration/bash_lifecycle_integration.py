#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

import bash_integration as bash_fixture
import dispatch_integration as fixture


def endpoint_for(name, command):
    responses = []
    bash_fixture.add_exchange(responses, name, command)
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    return endpoint, thread, f"http://127.0.0.1:{endpoint.server_port}/responses"


def admit(state, store, endpoint_url, name, fault=None, gated=False):
    session = f"direct/{name}"
    arguments = ["--fault", fault] if fault is not None else []
    if gated:
        arguments += ["--fault", "bash-fault-gated"]
    host = fixture.start_host(store, endpoint_url, *arguments)
    if gated:
        (store / "scratch" / "bash-fault-gate").write_text("blocked")
    bash_fixture.configure(state, store, f"{name}-config", session)
    fixture.message(state, store, f"{name}-message", session, "execute")
    action = fixture.wait_for(
        lambda: bash_fixture.action_for(store, session), f"{name} Action"
    )
    bash_fixture.allow(state, store, f"{name}-allow", session, action["action"])
    return host, session


def control_closed_while_host_alive(host, store, session):
    assert host.poll() is None, host.returncode
    try:
        fixture.command("inspect-session", "--store", store, "--session", session)
    except AssertionError as error:
        return "FileNotFound" in str(error)
    return False


def competing_host_is_rejected(store):
    completed = subprocess.run(
        [str(fixture.RUI), "serve", "--store", str(store), "--active-capacity", "1"],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert completed.returncode != 0, completed.stdout
    assert "StoreAlreadyOwned" in completed.stderr, completed.stderr


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-bash-lifecycle."))
    completed = False
    try:
        name = "lifecycle-observe"
        state = root / name
        state.mkdir(mode=0o700)
        store = state / "store"
        bash_pid_path = state / "bash-pid"
        endpoint, thread, endpoint_url = endpoint_for(
            name,
            f"printf $$ > {bash_pid_path}; trap '' TERM; sleep 30",
        )
        host = None
        try:
            host, session = admit(state, store, endpoint_url, name, "bash-observe")
            fixture.wait_for(bash_pid_path.exists, "observe-fault Bash identity")
            bash_pid = int(bash_pid_path.read_text())
            fixture.wait_for(
                lambda: host.poll() is not None,
                "observe fault forced retirement shutdown",
                timeout=12,
            )
            host.communicate(timeout=5)
            host = None
            assert not bash_fixture.process_exists(bash_pid)
            assert bash_fixture.rows(
                store,
                "SELECT resolution_code FROM action_operation WHERE session_ref=?",
                (session,),
            ) == [(None,)]
            assert not list((store / "scratch").glob("bash-*.tmp"))
            host = fixture.start_host(store, endpoint_url)
            fixture.wait_for(
                lambda: bash_fixture.resolution(store, session) == "indeterminate",
                "observe fault indeterminate recovery",
                interval=0.5,
            )
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                "observe fault recovery continuation",
            )
        finally:
            if host is not None:
                fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)

        for fault in (
            "reap",
            "reap-watchdog",
            "group-probe",
            "cleanup-watchdog",
        ):
            name = f"lifecycle-{fault}"
            state = root / name
            state.mkdir(mode=0o700)
            store = state / "store"
            launch_counter = state / "launch-counter"
            endpoint, thread, endpoint_url = endpoint_for(name, f"printf x >> {launch_counter}")
            host = None
            try:
                host, session = admit(state, store, endpoint_url, name, f"bash-{fault}", gated=True)
                fixture.wait_for(
                    lambda: control_closed_while_host_alive(host, store, session),
                    f"{fault} fault entered blocked shutdown",
                    timeout=12,
                )
                assert host.poll() is None
                competing_host_is_rejected(store)
                (store / "scratch" / "bash-fault-gate").unlink()
                fixture.wait_for(
                    lambda: host.poll() is not None,
                    f"{fault} original owner retirement after fault cleared",
                    timeout=12,
                )
                host.communicate(timeout=5)
                host = None
                assert launch_counter.read_text() == "x"
                assert bash_fixture.rows(
                    store,
                    "SELECT resolution_code FROM action_operation WHERE session_ref=?",
                    (session,),
                ) == [(None,)]
                assert not list((store / "scratch").glob("bash-*.tmp"))
                host = fixture.start_host(store, endpoint_url)
                fixture.wait_for(
                    lambda: bash_fixture.resolution(store, session) == "indeterminate",
                    f"{fault} indeterminate recovery",
                    interval=0.5,
                )
                fixture.wait_for(
                    lambda: fixture.completed_observation(store, f"{name}-message"),
                    f"{fault} recovery continuation",
                )
                assert not list((store / "scratch").glob("bash-*.tmp"))
            finally:
                if host is not None:
                    fixture.stop_host(host)
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)

        name = "lifecycle-forced-reap"
        state = root / name
        state.mkdir(mode=0o700)
        store = state / "store"
        endpoint, thread, endpoint_url = endpoint_for(name, "true")
        host = None
        try:
            host, session = admit(state, store, endpoint_url, name, "bash-reap")
            fixture.wait_for(
                lambda: control_closed_while_host_alive(host, store, session),
                "forced termination fault entered blocked shutdown",
                timeout=12,
            )
            competing_host_is_rejected(store)
            fixture.stop_host(host)
            host = None
            assert bash_fixture.rows(
                store,
                "SELECT resolution_code FROM action_operation WHERE session_ref=?",
                (session,),
            ) == [(None,)]
            assert list((store / "scratch").glob("bash-*.tmp"))
            host = fixture.start_host(store, endpoint_url)
            fixture.wait_for(
                lambda: bash_fixture.resolution(store, session) == "indeterminate",
                "forced termination indeterminate recovery",
                interval=0.5,
            )
        finally:
            if host is not None:
                fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)

        name = "lifecycle-idle-detached-writer"
        state = root / name
        state.mkdir(mode=0o700)
        store = state / "store"
        detached_pid_path = state / "detached-pid"
        endpoint, thread, endpoint_url = endpoint_for(
            name,
            bash_fixture.detached_shell(f"echo $$ > {detached_pid_path}; sleep 30") + " &",
        )
        host = None
        detached_pid = None
        try:
            host, session = admit(state, store, endpoint_url, name)
            fixture.wait_for(
                detached_pid_path.exists,
                "idle detached writer identity",
            )
            detached_pid = int(detached_pid_path.read_text())
            fixture.wait_for(
                lambda: bash_fixture.resolution(store, session) == "succeeded",
                "idle detached writer finite-tail settlement",
                interval=0.5,
            )
            result = bash_fixture.result_text(store, session)
            assert "Capture may be incomplete" in result, result
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                "idle detached writer continuation",
            )
            assert bash_fixture.process_exists(detached_pid)
        finally:
            if host is not None:
                fixture.stop_host(host)
            if detached_pid is not None and bash_fixture.process_exists(detached_pid):
                os.kill(detached_pid, signal.SIGKILL)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)

        name = "lifecycle-tail-snapshot"
        state = root / name
        state.mkdir(mode=0o700)
        store = state / "store"
        endpoint, thread, endpoint_url = endpoint_for(
            name, bash_fixture.detached_shell("sleep 2") + " &"
        )
        host = None
        try:
            host, session = admit(state, store, endpoint_url, name, "bash-tail-snapshot")
            fixture.wait_for(
                lambda: bash_fixture.resolution(store, session) == "storage_failed",
                "tail-snapshot capture failure",
                interval=0.5,
            )
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                "tail-snapshot continuation",
            )
        finally:
            if host is not None:
                fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)

        name = "lifecycle-signal"
        state = root / name
        state.mkdir(mode=0o700)
        store = state / "store"
        endpoint, thread, endpoint_url = endpoint_for(name, "true")
        host = None
        try:
            host, session = admit(state, store, endpoint_url, name, "bash-signal")
            fixture.wait_for(
                lambda: bash_fixture.resolution(store, session) == "succeeded",
                "signal failure with independently confirmed cleanup",
                interval=0.5,
            )
            result = bash_fixture.result_text(store, session)
            assert "signaling reported a failure" in result, result
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                "signal-failure continuation",
            )
        finally:
            if host is not None:
                fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)

        print(json.dumps({"bash_lifecycle_faults": "passed"}, sort_keys=True))
        completed = True
    finally:
        if completed:
            shutil.rmtree(root)
        else:
            print(f"retained Bash lifecycle failure state: {root}", file=sys.stderr)


if __name__ == "__main__":
    main()
