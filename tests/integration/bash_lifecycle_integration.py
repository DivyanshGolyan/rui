#!/usr/bin/env python3
import json
import pathlib
import shutil
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


def admit(state, store, endpoint_url, name, fault):
    session = f"direct/{name}"
    host = fixture.start_host(store, endpoint_url, "--fault", fault)
    bash_fixture.configure(state, store, f"{name}-config", session)
    fixture.message(state, store, f"{name}-message", session, "execute")
    action = fixture.wait_for(
        lambda: bash_fixture.action_for(store, session), f"{name} Action"
    )
    bash_fixture.allow(state, store, f"{name}-allow", session, action["action"])
    return host, session


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-bash-lifecycle."))
    completed = False
    try:
        for fault in ("observe", "reap", "group-probe", "cleanup-watchdog"):
            name = f"lifecycle-{fault}"
            state = root / name
            state.mkdir(mode=0o700)
            store = state / "store"
            endpoint, thread, endpoint_url = endpoint_for(name, "true")
            host = None
            try:
                host, session = admit(state, store, endpoint_url, name, f"bash-{fault}")
                fixture.wait_for(
                    lambda: host.poll() is not None,
                    f"{fault} fault fenced shutdown",
                    timeout=12,
                )
                host.communicate(timeout=5)
                host = None
                assert bash_fixture.resolution(store, session) is None
                assert list((store / "scratch").glob("bash-*.tmp"))
                host = fixture.start_host(store, endpoint_url)
                fixture.wait_for(
                    lambda: bash_fixture.resolution(store, session) == "indeterminate",
                    f"{fault} indeterminate recovery",
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

        name = "lifecycle-tail-snapshot"
        state = root / name
        state.mkdir(mode=0o700)
        store = state / "store"
        endpoint, thread, endpoint_url = endpoint_for(name, "setsid sh -c 'sleep 2' &")
        host = None
        try:
            host, session = admit(state, store, endpoint_url, name, "bash-tail-snapshot")
            fixture.wait_for(
                lambda: bash_fixture.resolution(store, session) == "storage_failed",
                "tail-snapshot capture failure",
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
            )
            result = bash_fixture.rows(
                store,
                "SELECT content.payload FROM action_operation action "
                "JOIN content ON content.content_id=action.resolution_content_id "
                "WHERE action.session_ref=?",
                (session,),
            )[0][0]
            assert b"signaling reported a failure" in result, result
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
