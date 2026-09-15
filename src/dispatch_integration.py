#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time


LATIFA = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()


class FailureEndpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FailureHandler)
        self.requests = []
        self.paths = []
        self.received = threading.Event()
        self.release = threading.Event()


class FailureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        self.server.requests.append(body)
        self.server.paths.append(self.path)
        self.server.received.set()
        if self.path == "/progress":
            self.send_response(422)
            self.send_header("Content-Length", "8")
            self.send_header("Connection", "close")
            self.end_headers()
            for _ in range(8):
                self.wfile.write(b"x")
                self.wfile.flush()
                time.sleep(0.4)
            self.close_connection = True
            return
        if self.path == "/stall":
            self.send_response(422)
            self.send_header("Content-Length", "2")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"x")
            self.wfile.flush()
            time.sleep(2.5)
            try:
                self.wfile.write(b"x")
            except BrokenPipeError:
                pass
            self.close_connection = True
            return
        if not self.server.release.wait(10):
            raise RuntimeError("fixture response was never released")
        if self.path == "/disconnect":
            self.close_connection = True
            return
        payload = b'{"error":"deterministic permanent failure"}'
        status = 422
        if self.path.startswith("/large-"):
            payload = b"x" * (128 * 1024)
            status = int(self.path.rsplit("-", 1)[1])
        elif self.path in ("/429", "/503"):
            status = int(self.path[1:])
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def command(*args, expect=0):
    completed = subprocess.run(
        [str(LATIFA), *map(str, args)],
        text=True,
        capture_output=True,
        timeout=15,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_host(store, endpoint, *extra):
    process = subprocess.Popen(
        [
            str(LATIFA),
            "serve",
            "--store",
            str(store),
            "--active-capacity",
            "1",
            "--provider-endpoint",
            endpoint,
            *extra,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if line.startswith("ready "):
            if "execution=enabled" not in line or "curl=8.22.0" not in line:
                raise AssertionError(f"missing transport readiness evidence: {line}")
            return process
        if process.poll() is not None:
            raise AssertionError(f"Host exited before ready: {process.stderr.read()}")
    raise AssertionError("Host did not become ready")


def stop_host(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


def configure(state, store, key, session, model, schema=None, instructions=None):
    record = state / f"{key}.json"
    args = [
        "configure",
        "--store",
        store,
        "--record",
        record,
        "--key",
        key,
        "--session",
        session,
        "--workspace",
        ROOT,
        "--model",
        model,
    ]
    if schema is not None:
        schema_path = state / f"{key}-schema.json"
        schema_path.write_text(json.dumps(schema, separators=(",", ":")))
        args += ["--output-schema", schema_path]
    if instructions is not None:
        instructions_path = state / f"{key}-instructions.txt"
        instructions_path.write_text(instructions)
        args += ["--instructions", instructions_path]
    result = command(*args)
    assert result["answer"]["status"] == "accepted", result


def message(state, store, key, session, text):
    text_path = state / f"{key}.txt"
    text_path.write_text(text)
    result = command(
        "message",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--text",
        text_path,
    )
    assert result["answer"]["status"] == "accepted", result


def observe(store, key):
    return command("observe-command", "--store", store, "--key", key)["observation"]


def wait_for(predicate, description, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for {description}")


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="latifa-dispatch."))
    endpoint = FailureEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    processes = []
    try:
        # A committed permit launches exactly one complete frozen request. The
        # endpoint holds the response so later settings and input arrive while
        # the admitted request is demonstrably in flight.
        store = state / "frozen-store"
        host = start_host(store, url, "--test-cleanup-delay-ms", "3000")
        processes.append(host)
        output_schema = {
            "type": "object",
            "properties": {"answer": {"type": "string"}},
            "required": ["answer"],
            "additionalProperties": False,
        }
        configure(state, store, "config-a", "direct/main", "model-a", output_schema, "A")
        configure(state, store, "instructions-b", "direct/main", "model-a", instructions="B")
        configure(state, store, "instructions-a", "direct/main", "model-a", instructions="A")
        configure(state, store, "instructions-a-again", "direct/main", "model-a", instructions="A")
        message(state, store, "message-a", "direct/main", 'first "message"\n')
        if not endpoint.received.wait(8):
            raise AssertionError("endpoint did not receive committed request")
        configure(state, store, "config-b", "direct/main", "model-b")
        message(state, store, "message-b", "direct/main", "later message")
        assert len(endpoint.requests) == 1
        endpoint.release.set()
        failed = wait_for(
            lambda: (value := observe(store, "message-a"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "provider_http_422"
            and value,
            "saved permanent failure",
        )
        assert failed["queue"]["status"] == "failed", failed
        assert failed["processing"]["attempt"] == "1", failed
        later = observe(store, "message-b")
        assert later["queue"]["status"] == "queued", later
        assert len(endpoint.requests) == 1, "a permit launched more than once"

        observed = json.loads(endpoint.requests[0])
        expected = {
            "model": "model-a",
            "store": False,
            "stream": True,
            "include": ["reasoning.encrypted_content"],
            "input": [
                {"role": "system", "content": [{"type": "input_text", "text": "A"}]},
                {
                    "role": "user",
                    "content": [{"type": "input_text", "text": 'first "message"\n'}],
                },
                {"role": "system", "content": [{"type": "input_text", "text": "B"}]},
                {"role": "system", "content": [{"type": "input_text", "text": "A"}]},
                {"role": "system", "content": [{"type": "input_text", "text": "A"}]},
            ],
            "tools": [
                {"type": "function", "name": "bash", "description": "Run Bash"},
                {"type": "function", "name": "edit", "description": "Edit one file"},
            ],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "latifa_output",
                    "strict": True,
                    "schema": output_schema,
                }
            },
        }
        assert observed == expected, (observed, expected)
        stop_host(host)
        processes.remove(host)

        # Killing the execution owner cannot erase the saved result or admit
        # input beyond the first Operation's cutoff.
        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
        assert observe(store, "message-a")["result"]["code"] == "provider_http_422"
        assert observe(store, "message-b")["queue"]["status"] == "queued"
        stop_host(offline)
        processes.remove(offline)

        # A successor reuses complete projected history in its original order.
        # The prior failed Turn's messages and each distinct instruction update
        # survive restart, including repeated equal text and reversals.
        host = start_host(store, url)
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 2, "successor history request")
        successor = json.loads(endpoint.requests[1])
        assert successor["input"] == expected["input"] + [
            {"role": "user", "content": [{"type": "input_text", "text": "later message"}]}
        ], successor
        assert successor["model"] == "model-b", successor
        wait_for(lambda: observe(store, "message-b").get("result", {}).get("code") == "provider_http_422", "successor failure")
        stop_host(host)
        processes.remove(host)

        # One reactor fills two fixed custody records without allocating a
        # worker per Session. Both requests reach the endpoint before either
        # response is released.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        capacity_store = state / "capacity-store"
        host = start_host(capacity_store, url, "--active-capacity", "2")
        processes.append(host)
        configure(state, capacity_store, "capacity-config-a", "direct/capacity-a", "model-a")
        configure(state, capacity_store, "capacity-config-b", "direct/capacity-b", "model-a")
        message(state, capacity_store, "capacity-message-a", "direct/capacity-a", "alpha")
        message(state, capacity_store, "capacity-message-b", "direct/capacity-b", "beta")
        wait_for(lambda: len(endpoint.requests) == 2, "two concurrent reactor requests")
        endpoint.release.set()
        wait_for(
            lambda: observe(capacity_store, "capacity-message-a").get("result", {}).get("code")
            == "provider_http_422",
            "first concurrent failure",
        )
        wait_for(
            lambda: observe(capacity_store, "capacity-message-b").get("result", {}).get("code")
            == "provider_http_422",
            "second concurrent failure",
        )
        stop_host(host)
        processes.remove(host)

        # A failed Attempt commit rolls back all provenance and cannot produce
        # an endpoint launch.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        rollback_store = state / "rollback-store"
        host = start_host(rollback_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, rollback_store, "rollback-config", "direct/rollback", "model-a")
        message(state, rollback_store, "rollback-message", "direct/rollback", "rollback")
        time.sleep(0.35)
        assert endpoint.requests == []
        assert observe(rollback_store, "rollback-message")["queue"]["status"] == "queued"
        stop_host(host)
        processes.remove(host)

        # The first fallible post-commit step consumes Attempt 1, saves a typed
        # failure, releases custody, and never reaches HTTP.
        first_store = state / "first-step-store"
        host = start_host(first_store, url, "--fault", "request-first-step")
        processes.append(host)
        configure(state, first_store, "first-config", "direct/first", "model-a")
        message(state, first_store, "first-message", "direct/first", "first step")
        failed = wait_for(
            lambda: (value := observe(first_store, "first-message"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "request_preparation_failed"
            and value,
            "saved first-step preparation failure",
        )
        assert failed["processing"]["attempt"] == "1", failed
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)

        for fault, expected_code in (
            ("request-scratch-acquire", "request_scratch_exhausted"),
            ("request-write", "request_write_failed"),
            ("request-seal", "request_seal_failed"),
        ):
            fault_store = state / f"{fault}-store"
            host = start_host(fault_store, url, "--fault", fault)
            processes.append(host)
            configure(state, fault_store, f"{fault}-config", f"direct/{fault}", "model-a")
            message(state, fault_store, f"{fault}-message", f"direct/{fault}", fault)
            failed = wait_for(
                lambda key=f"{fault}-message", code=expected_code: (
                    value := observe(fault_store, key)
                )["status"]
                == "accepted"
                and value.get("result", {}).get("code") == code
                and value,
                f"saved {fault} failure",
            )
            assert failed["processing"]["attempt"] == "1", failed
            assert endpoint.requests == []
            stop_host(host)
            processes.remove(host)

        # A canonical save fault rolls back the claimed failure, fences the
        # live dispatch owner, and leaves the admitted Attempt uncertain for
        # the following retry/restart slice rather than recreating its permit.
        endpoint.requests.clear()
        endpoint.release.set()
        save_store = state / "save-fault-store"
        host = start_host(save_store, url, "--fault", "result-before-commit")
        processes.append(host)
        configure(state, save_store, "save-config", "direct/save", "model-a")
        message(state, save_store, "save-message", "direct/save", "save fault")
        wait_for(lambda: len(endpoint.requests) == 1, "save-fault endpoint request")
        time.sleep(0.2)
        failed_observation = subprocess.run(
            [str(LATIFA), "observe-command", "--store", str(save_store), "--key", "save-message"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert failed_observation.returncode != 0, failed_observation.stdout
        assert len(endpoint.requests) == 1
        stop_host(host)
        processes.remove(host)

        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(save_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
        uncertain = observe(save_store, "save-message")
        assert uncertain["queue"]["status"] == "processing", uncertain
        assert uncertain["processing"]["attempt"] == "1", uncertain
        assert "result" not in uncertain, uncertain
        stop_host(offline)
        processes.remove(offline)

        # Per-input framing participates in scratch reservation. Forty empty
        # messages exceed the old fixed allowance: the successful run remains
        # fully charged, and one byte below the observed complete request is
        # rejected before HTTP rather than oversubscribing the shared budget.
        endpoint.requests.clear()
        endpoint.release.clear()
        framing_store = state / "framing-store"
        host = start_host(framing_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, framing_store, "framing-config", "direct/framing", "model-a")
        for index in range(40):
            message(state, framing_store, f"framing-{index}", "direct/framing", "")
        stop_host(host)
        processes.remove(host)
        host = start_host(framing_store, url)
        processes.append(host)
        wait_for(lambda: len(endpoint.requests) == 1, "many-input materialization")
        actual_request_bytes = len(endpoint.requests[0])
        resources = command(
            "inspect-session", "--store", framing_store, "--session", "direct/framing"
        )["execution"]
        assert int(resources["scratch_used_bytes"]) >= actual_request_bytes, resources
        endpoint.release.set()
        wait_for(
            lambda: observe(framing_store, "framing-0").get("result", {}).get("code")
            == "provider_http_422",
            "many-input permanent failure",
        )
        stop_host(host)
        processes.remove(host)

        endpoint.requests.clear()
        endpoint.release.clear()
        framing_limit_store = state / "framing-limit-store"
        host = start_host(framing_limit_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, framing_limit_store, "limit-config", "direct/framing-limit", "model-a")
        for index in range(40):
            message(state, framing_limit_store, f"limit-{index}", "direct/framing-limit", "")
        stop_host(host)
        processes.remove(host)
        host = start_host(
            framing_limit_store,
            url,
            "--test-request-scratch-limit",
            str(actual_request_bytes - 1),
        )
        processes.append(host)
        limited = wait_for(
            lambda: (value := observe(framing_limit_store, "limit-0")).get("result", {}).get("code")
            == "request_scratch_exhausted"
            and value,
            "pre-dispatch framing capacity failure",
        )
        assert limited["processing"]["attempt"] == "1", limited
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)

        # URL authority is parsed before curl sees it. Userinfo that makes a
        # prefix look loopback is rejected at startup and reaches no server.
        endpoint.requests.clear()
        deceptive = subprocess.run(
            [
                str(LATIFA), "serve", "--store", str(state / "deceptive-store"),
                "--provider-endpoint", f"http://127.0.0.1:80@127.0.0.1:{endpoint.server_port}/responses",
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert deceptive.returncode != 0
        assert endpoint.requests == []

        # The production timeout is inactivity-based, not a total request
        # deadline. A reduced one-second interval stays alive while bytes make
        # progress for over three intervals, while a body stall fails.
        progress_store = state / "progress-store"
        host = start_host(
            progress_store,
            f"http://127.0.0.1:{endpoint.server_port}/progress",
            "--test-provider-inactivity-seconds",
            "1",
        )
        processes.append(host)
        configure(state, progress_store, "progress-config", "direct/progress", "model-a")
        message(state, progress_store, "progress-message", "direct/progress", "progress")
        progress_failure = wait_for(
            lambda: (value := observe(progress_store, "progress-message")).get("result", {}).get("code")
            == "provider_http_422"
            and value,
            "progressing response beyond inactivity interval",
            timeout=8,
        )
        assert progress_failure["queue"]["status"] == "failed"
        stop_host(host)
        processes.remove(host)

        stall_store = state / "stall-store"
        host = start_host(
            stall_store,
            f"http://127.0.0.1:{endpoint.server_port}/stall",
            "--test-provider-inactivity-seconds",
            "1",
        )
        processes.append(host)
        configure(state, stall_store, "stall-config", "direct/stall", "model-a")
        message(state, stall_store, "stall-message", "direct/stall", "stall")
        wait_for(
            lambda: observe(stall_store, "stall-message")["queue"]["status"] == "processing" and command(
                "inspect-session", "--store", stall_store, "--session", "direct/stall"
            )["execution"]["custody_occupied"] == "0",
            "stalled response cleanup",
        )
        stalled = observe(stall_store, "stall-message")
        assert stalled["queue"]["status"] == "processing" and "result" not in stalled, stalled
        stop_host(host)
        processes.remove(host)

        # Discarding large bodies must preserve HTTP classification. Retryable
        # evidence releases physical custody without inventing a final result.
        for path in ("/large-422", "/large-429", "/429", "/503", "/disconnect"):
            case_state = state / (path[1:] + "-records")
            case_state.mkdir(mode=0o700)
            endpoint.requests.clear()
            endpoint.release.set()
            transient_store = state / (path[1:] + "-store")
            host = start_host(transient_store, f"http://127.0.0.1:{endpoint.server_port}{path}")
            processes.append(host)
            configure(case_state, transient_store, "config", "direct/transient", "model-a")
            message(case_state, transient_store, "message", "direct/transient", "input")
            wait_for(lambda: len(endpoint.requests) == 1, "one endpoint request")
            wait_for(lambda: command(
                "inspect-session", "--store", transient_store, "--session", "direct/transient"
            )["execution"]["custody_occupied"] == "0", "response cleanup")
            observation = observe(transient_store, "message")
            resources = command("inspect-session", "--store", transient_store, "--session", "direct/transient")["execution"]
            assert resources["scratch_used_bytes"] == "0", resources
            if path == "/large-422":
                assert observation["result"]["code"] == "provider_http_422", observation
            else:
                assert observation["queue"]["status"] == "processing" and "result" not in observation, observation
                assert observation["processing"]["attempt"] == "1", observation
                with sqlite3.connect(transient_store / "latifa.sqlite3") as database:
                    assert database.execute("SELECT allowance_used,uncertain,resolution_code FROM model_operation").fetchall() == [(1, 1, None)]
                message(case_state, transient_store, "later", "direct/transient", "later")
                assert observe(transient_store, "later")["queue"]["status"] == "queued"
            stop_host(host)
            processes.remove(host)
            host = start_host(transient_store, f"http://127.0.0.1:{endpoint.server_port}{path}")
            processes.append(host)
            assert observe(transient_store, "message") == observation
            assert len(endpoint.requests) == 1, "restart recreated a consumed permit"
            stop_host(host)
            processes.remove(host)

        # A canonical read fault published before launch fences the Store
        # and prevents the synchronized dispatch handoff.
        endpoint.requests.clear()
        endpoint.release.clear()
        race_store = state / "fence-race-store"
        host = start_host(race_store, url, "--test-before-launch-delay-ms", "1500")
        processes.append(host)
        configure(state, race_store, "race-config", "direct/race", "model-a")
        message(state, race_store, "race-message", "direct/race", "race")

        # Observe through the Store owner: an external SQLite reader can
        # contend with admission in DELETE-journal/zero-busy-timeout mode.
        wait_for(
            lambda: observe(race_store, "race-message")["queue"]["status"] == "processing",
            "admitted request before launch",
        )
        database = sqlite3.connect(race_store / "latifa.sqlite3", timeout=5)
        original_instructions = database.execute(
            "SELECT instructions_content_id FROM session WHERE session_ref='direct/race'"
        ).fetchone()[0]
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/race'"
        )
        database.commit()
        database.close()
        canonical_read = subprocess.run(
            [str(LATIFA), "inspect-session", "--store", str(race_store), "--session", "direct/race"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert canonical_read.returncode != 0
        wait_for(lambda: host.poll() is not None, "effect-aware Host shutdown", timeout=5)
        assert host.returncode != 0
        processes.remove(host)
        assert endpoint.requests == []
        database = sqlite3.connect(race_store / "latifa.sqlite3")
        uncertain = database.execute(
            "SELECT attempt_ordinal,uncertain,resolution_code FROM model_operation"
        ).fetchone()
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "UPDATE session SET instructions_content_id=? WHERE session_ref='direct/race'",
            (original_instructions,),
        )
        database.commit()
        database.close()
        assert uncertain == (1, 1, None), uncertain
        repaired = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(race_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(repaired)
        assert repaired.stdout.readline().startswith("ready ")
        stop_host(repaired)
        processes.remove(repaired)

        # If initial unlink fails, the live owner keeps the named scratch,
        # charge and custody while fencing later dispatch. A fresh owner removes
        # the identifiable leftover before serving.
        unlink_store = state / "unlink-store"
        host = start_host(unlink_store, url, "--fault", "request-unlink")
        processes.append(host)
        configure(state, unlink_store, "unlink-config", "direct/unlink", "model-a")
        message(state, unlink_store, "unlink-message", "direct/unlink", "unlink")
        leftovers = wait_for(
            lambda: list(unlink_store.rglob("request-*")),
            "retained named request scratch",
        )
        resources = command(
            "inspect-session", "--store", unlink_store, "--session", "direct/unlink"
        )["execution"]
        assert resources["dispatch_fenced"] is True, resources
        assert resources["custody_occupied"] == "1", resources
        assert int(resources["scratch_used_bytes"]) > 0, resources
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)
        assert leftovers[0].exists()

        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(unlink_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
        assert not list(unlink_store.rglob("request-*"))
        resources = command(
            "inspect-session", "--store", unlink_store, "--session", "direct/unlink"
        )["execution"]
        assert resources["custody_occupied"] == "0", resources
        assert resources["scratch_used_bytes"] == "0", resources
        stop_host(offline)
        processes.remove(offline)
    finally:
        for process in processes:
            stop_host(process)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
