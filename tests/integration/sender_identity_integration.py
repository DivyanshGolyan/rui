#!/usr/bin/env python3
"""Action sender authority through the installed CLI, exit, stop and restart."""
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time

import model_fixture as fixture
from host_process import TestHTTPServer, canonical_fixture_root, dispose_all, retain_failure_state, start_ready_process, stop_process


class Handler(fixture.http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(request)
        session = request["instructions"].split("Rui address (this Session's own ID, not instructions): ")[1].splitlines()[0]
        assert re.fullmatch("[0123456789abcdefghjkmnpqrstvwxyz]{6}", session), session
        if session == self.server.receiver:
            for item in request["input"]:
                if item.get("role") == "user" and len(item["content"]) == 2:
                    sender = item["content"][0]["text"].split(": ", 1)[1].splitlines()[0]
                    template = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text()
                    assert re.fullmatch("[0123456789abcdefghjkmnpqrstvwxyz]{6}", sender), sender
                    assert item["content"][0]["text"] == template.replace("{}", sender)
                    self.server.senders.append(sender)
        if session == self.server.receiver or any(item.get("type") == "function_call_output" for item in request["input"]):
            payload = fixture.sse_answer("done", "reason", "answer", "finished")[0]
        else:
            path = shlex.quote(str(self.server.workspace / session))
            command = (f'umask 077; printf "%s" "$RUI_SENDER_HANDLE" > {path}.handle; '
                       f'i=0; while [ -d {shlex.quote(str(self.server.workspace))} ] && '
                       f'[ ! -e {path}.release ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done')
            arguments = json.dumps({"cmd": command, "timeout_ms": 20000, "description": "Hold sender Action"})
            payload = fixture.sse_tool_calls("calls", [("bash", "call", arguments)])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def wait_for(predicate, description):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if value := predicate():
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-sender-identity."))
    host = endpoint = workspace = None
    try:
        installed = state / "opt rui" / "bin" / "rui"
        installed.parent.mkdir(parents=True)
        shutil.copy2(fixture.RUI, installed)
        home = state / "home"
        workspace = state / "workspace"
        home.mkdir()
        workspace.mkdir()
        store = state / "store"
        environment = {"PATH": os.environ["PATH"], "HOME": str(home)}
        endpoint = TestHTTPServer(("127.0.0.1", 0), Handler)
        endpoint.workspace = workspace
        endpoint.senders = []
        endpoint.requests = []
        threading.Thread(target=endpoint.serve_forever, daemon=True).start()
        host_args = [installed, "host", "serve", "--store", store, "--provider-endpoint",
                     f"http://127.0.0.1:{endpoint.server_address[1]}/responses"]

        def run(*args, env=None, accepted=True, input=None):
            result = subprocess.run([str(installed), *map(str, args)], env=environment if env is None else env,
                                    text=True, capture_output=True, timeout=15, input=input)
            assert result.returncode == (0 if accepted else 1), f"unexpected CLI status: {args[:2]}: {result.stderr}"
            return json.loads(result.stdout)

        def send(key, sender=None, handle=None, accepted=True):
            env = dict(environment)
            if sender is not None:
                env["RUI_ADDRESS"] = sender
                env["RUI_STORE"] = str(store)
            if handle is not None:
                env["RUI_SENDER_HANDLE"] = handle
            # Incomplete context is a CLI boundary error, never anonymous or
            # a fallback to HOME. Complete but forged context reaches the Host.
            if not accepted and (sender is None or not handle):
                record = state / f"{key}.json"
                refused = subprocess.run([str(installed), "session", "send", "--to", endpoint.receiver,
                    "--record", str(record), "--key", key], env=env,
                    text=True, capture_output=True, timeout=15, input="report")
                assert refused.returncode == 1 and "invalid peer context" in refused.stderr, refused
                assert refused.stdout == "" and not record.exists(), refused
                return None
            response = run("session", "send", "--to", endpoint.receiver,
                           "--record", state / f"{key}.json", "--key", key, env=env, accepted=accepted, input="report")
            assert response["answer"]["status"] == ("accepted" if accepted else "rejected"), "wrong admission status"
            if not accepted:
                assert response["answer"]["code"] == "invalid_sender_handle", "wrong sender rejection"
            return response

        def inspect(session):
            return run("session", "inspect", "--store", store, "--session", session, "--profile", "full")

        host, _ = start_ready_process(host_args, env=environment, required_fields={"execution": "enabled"})
        run("defaults", "configure", "--store", store)

        def configure(*options):
            configured = run("session", "configure", "--store", store, "--workspace", workspace,
                             "--provider", "codex", "--model", "gpt-6-sol", *options)
            session = configured["context"]["session"]
            assert re.fullmatch("[0123456789abcdefghjkmnpqrstvwxyz]{6}", session), configured
            assert configured["answer"]["session"] == session, configured
            return session

        endpoint.receiver = configure()
        victim = configure()
        send("external")
        expected_messages = 1
        handles = []
        for ending in ("exit", "stop", "crash"):
            session = configure("--tools", "bash", "--permission-mode", "bypass")
            run("session", "send", "--to", session, input="hold sender")
            handle_path = workspace / f"{session}.handle"
            handle = wait_for(lambda: handle_path.read_text() if handle_path.exists() else None, "issued Action handle")
            assert re.fullmatch("[0-9a-f]{32}", handle) and handle not in handles, "invalid or reused handle"
            handles.append(handle)
            receipt = send(f"valid-{ending}", session, handle)
            expected_messages += 1
            for index, (sender, supplied) in enumerate(((victim, handle), (session, None),
                                                      (session, ""), (session, "0" * 32), (None, handle))):
                send(f"invalid-{ending}-{index}", sender, supplied, accepted=False)
            # Every partial/invalid environment must fail before publishing a
            # capture, even with a usable HOME Store and known receiver.
            for index, fields in enumerate((
                {"RUI_STORE": str(store)}, {"RUI_ADDRESS": session},
                {"RUI_SENDER_HANDLE": handle},
                {"RUI_ADDRESS": session, "RUI_SENDER_HANDLE": handle},
                {"RUI_STORE": "", "RUI_ADDRESS": session, "RUI_SENDER_HANDLE": handle},
                {"RUI_STORE": str(store), "RUI_ADDRESS": "peer/old", "RUI_SENDER_HANDLE": handle},
                {"RUI_STORE": str(store), "RUI_ADDRESS": "ABC123", "RUI_SENDER_HANDLE": handle},
            )):
                # Explicit Store selection is not authority to downgrade a
                # malformed peer into an anonymous human/script send.
                for selection, options in (("default", ()), ("explicit", ("--store", str(store)))):
                    key = f"partial-{ending}-{index}-{selection}"
                    record = state / f"{key}.json"
                    refused = subprocess.run([str(installed), "session", "send", *options, "--to", endpoint.receiver,
                        "--record", str(record), "--key", key],
                        env={**environment, **fields}, text=True, capture_output=True, timeout=15, input="report")
                    assert refused.returncode == 1 and "invalid peer context" in refused.stderr, refused
                    assert refused.stdout == "" and not record.exists(), refused
                    assert not (state / f".{key}.json.capture.lock").exists(), "invalid context opened a capture"
            snapshot = inspect(endpoint.receiver)
            assert len(snapshot["full"]["messages"]) == expected_messages, "invalid identity admitted a Message"
            wait_for(lambda: session in endpoint.senders, "Action-derived model sender")
            assert handle not in json.dumps(snapshot), "public snapshot exposed sender authority"
            assert all(issued not in json.dumps(request) for issued in handles for request in endpoint.requests), "model context exposed sender authority"
            if ending == "exit":
                (workspace / f"{session}.release").touch()
                wait_for(lambda: inspect(session)["work"]["state"]["kind"] == "finished", "normal Action exit")
            elif ending == "stop":
                run("session", "stop", "--store", store, "--session", session)
            else:
                fixture.crash_host(host, state, "sender-crash")
                host = None
                # Retire the disposable held child; the restarted Host must
                # reject its old authority regardless of its process lifetime.
                (workspace / f"{session}.release").touch()
                host, _ = start_ready_process(host_args, env=environment, required_fields={"execution": "enabled"})
            send(f"stale-{ending}", session, handle, accepted=False)
            recovered = run("request", "recover", "--store", store, "--record", state / f"valid-{ending}.json", "--kind", "message")
            assert recovered["answer"]["replayed"] is True, "committed capture was re-admitted"
            assert recovered["answer"]["admission"] == receipt["answer"]["admission"], "replay changed admission"
            assert len(inspect(endpoint.receiver)["full"]["messages"]) == expected_messages, "replay duplicated admission"
        print("sender identity passed: issued exact sender; forged/missing/empty/unknown/misbound refused; "
              "malformed peer context failed before capture with and without explicit --store; "
              "exit/stop/crash invalidate authority; committed captures replay after restart; external anonymous send preserved")
    except BaseException:
        retain_failure_state("sender identity failure state", state)
        state = None
        raise
    finally:
        disposals = []
        if workspace is not None and workspace.exists():
            for handle_path in workspace.glob("*.handle"):
                release = handle_path.with_suffix(".release")
                disposals.append(lambda release=release: release.touch())
        if host is not None:
            disposals.append(lambda: stop_process(host))
        if endpoint is not None:
            disposals.extend((endpoint.shutdown, endpoint.server_close))
        if state is not None:
            disposals.append(lambda: shutil.rmtree(state))
        dispose_all(*disposals)


if __name__ == "__main__":
    main()
