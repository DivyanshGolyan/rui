"""Public CLI creation receipts retain initial settings across edits and lost replies."""
import json
import os
import pathlib
import subprocess
import tempfile
import threading

import canonical_fixture
import host_process
import model_fixture as fixture
from product_defaults import DEFAULTS, start_effort


def main():
    with tempfile.TemporaryDirectory(prefix="rui-start-receipt.") as temporary:
        root = pathlib.Path(temporary)
        home, workspace, store = (root / name for name in ("home", "workspace", "store"))
        home.mkdir(mode=0o700)
        workspace.mkdir(mode=0o700)
        environment = dict(os.environ, HOME=str(home))
        for name in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE", "RUI_RUNTIME_DIR"):
            environment.pop(name, None)
        host = proxy = caller = None
        held, release = threading.Event(), threading.Event()
        requested = {}

        def invoke(*args, input=None, expect=0):
            result = subprocess.run([str(fixture.RUI), *map(str, args)], env=environment,
                                    cwd=workspace, input=input, text=True, capture_output=True, timeout=20)
            assert result.returncode == expect, (args, result)
            return result

        def value(*args):
            return json.loads(invoke(*args).stdout)

        def hold_create_response(response):
            head, body = response.split(b"\r\n\r\n", 1)
            answer = json.loads(body)["answer"]
            if answer["status"] == "accepted" and not held.is_set():
                requested.update(answer)
                held.set()
                assert release.wait(15), "the concurrent configuration did not release the create answer"
            return response

        try:
            host = fixture.start_host(store, None)
            proxy = canonical_fixture.ReplyProxy(host, "/v1/message", hold_create_response)
            record = root / "original.json"
            args = ["session", "start", "--store", store, "--connection", "codex",
                    "--model", DEFAULTS.recommended_model, "--workspace", workspace,
                    "--record", record, "--key", "receipt-original"]
            task = "retain the original creation receipt"
            caller = subprocess.Popen([str(fixture.RUI), *map(str, args)], env=environment,
                                      cwd=workspace, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            caller.stdin.write(task)
            host_process.close_stdin(caller)
            host_process.wait_for(held.is_set, "the accepted Message reply", timeout=15)
            session = requested["session"]
            changed = value("session", "configure", "--store", store, "--session", session,
                            "--model", "gpt-5.5", "--reasoning-effort", "high")
            assert changed["answer"]["revision"] == "2", changed
            current = value("session", "inspect", "--store", store, "--session", session)["session"]
            assert current["model"] == "gpt-5.5" and current["reasoning_effort"] == "high", current
            release.set()
            stdout, stderr = caller.communicate(timeout=20)
            assert caller.returncode == 0, (stdout, stderr)
            admitted = json.loads(stdout)
            assert not stderr, stderr
            expected = {"connection": "codex", "model": DEFAULTS.recommended_model,
                        "reasoning_effort": start_effort(DEFAULTS.recommended_model), "effort_source": "model_default"}
            assert admitted["configuration"] == expected, admitted
            assert admitted["context"]["session"] == session and not admitted["answer"]["replayed"], admitted
            original = record.read_bytes()
            saved = json.loads(original)
            assert set(saved["configuration"]) == {"connection", "model", "workspace"}, saved
            replay_args = args[:-4] + ["--record", root / "replay.json", "--key", "receipt-original"]
            replayed = json.loads(invoke(*replay_args, input=task).stdout)
            assert replayed["configuration"] == expected and replayed["context"] == admitted["context"], replayed
            assert replayed["answer"]["replayed"] and replayed["answer"]["admission"] == admitted["answer"]["admission"], replayed
            assert record.read_bytes() == original
            messages = [body for route, body in proxy.mutations if route == "/v1/message"]
            assert messages == [original, original], messages
            proxy.close()
            proxy = canonical_fixture.ReplyProxy(host, "/v1/inspect-session")
            failure_record = root / "lost-reply.json"
            lost = subprocess.run([str(fixture.RUI), *map(str, args[:-4]), "--record", str(failure_record),
                                   "--key", "receipt-lost", "--test-drop-reply", "after-commit"],
                                  env=environment, cwd=workspace, input=task, text=True,
                                  capture_output=True, timeout=20)
            assert lost.returncode != 0, lost
            recovered = value("request", "recover", "--store", store, "--record", failure_record,
                              "--kind", "message")
            assert recovered["answer"]["replayed"] and recovered["context"]["session"], recovered
            assert recovered["answer"]["configuration"]["model"] == DEFAULTS.recommended_model, recovered
            assert not proxy.exchanges, proxy.exchanges

            configure_record = root / "lost-configure.json"
            lost_configure = subprocess.run(
                [str(fixture.RUI), "session", "configure", "--store", str(store),
                 "--connection", "codex", "--model", DEFAULTS.recommended_model,
                 "--workspace", str(workspace), "--record", str(configure_record),
                 "--key", "receipt-configure-lost", "--test-drop-reply", "after-commit"],
                env=environment, cwd=workspace, text=True, capture_output=True, timeout=20)
            assert lost_configure.returncode != 0, lost_configure
            observation = value("request", "inspect", "--store", store, "--key", "receipt-configure-lost")
            configured_session = observation["observation"]["target"]
            value("session", "configure", "--store", store, "--session", configured_session,
                  "--model", "gpt-5.5", "--reasoning-effort", "high")
            recovered_configure = value("request", "recover", "--store", store, "--record", configure_record,
                                        "--kind", "configure")
            assert recovered_configure["context"]["session"] == configured_session, recovered_configure
            assert recovered_configure["answer"]["replayed"], recovered_configure
            assert recovered_configure["answer"]["configuration"]["model"] == DEFAULTS.recommended_model, recovered_configure
            assert not proxy.exchanges, proxy.exchanges
            print("session creation receipts: immutable replay and lost-reply recovery passed", flush=True)
        finally:
            host_process.dispose_all(release.set,
                lambda: host_process.stop_process(caller, timeout=5) if caller is not None else None,
                lambda: proxy.close() if proxy is not None else None,
                lambda: fixture.stop_host(host) if host is not None else None)
