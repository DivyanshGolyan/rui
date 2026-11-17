"""Public CLI creation receipts retain revision one across edits and report failures."""
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

        def before_report(record):
            request = json.loads(record)
            if request.get("profile") == "full" and not held.is_set():
                requested.update(request)
                held.set()
                assert release.wait(15), "the concurrent configuration did not release the receipt report"
            return True

        try:
            host = fixture.start_host(store, None)
            proxy = canonical_fixture.ReplyProxy(host, "/v1/inspect-session", lambda response: response,
                                                 before_forward=before_report)
            record = root / "original.json"
            args = ["session", "start", "--store", store, "--provider", "codex",
                    "--model", DEFAULTS.recommended_model, "--workspace", workspace,
                    "--record", record, "--key", "receipt-original"]
            task = "retain the original creation receipt"
            caller = subprocess.Popen([str(fixture.RUI), *map(str, args)], env=environment,
                                      cwd=workspace, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            caller.stdin.write(task)
            host_process.close_stdin(caller)
            host_process.wait_for(held.is_set, "the start receipt read after accepted Message admission", timeout=15)
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
            assert canonical_fixture.announced(subprocess.CompletedProcess(args, 0, stdout, stderr)) == "receipt-original"
            expected = {"provider": "codex", "model": DEFAULTS.recommended_model,
                        "reasoning_effort": start_effort(DEFAULTS.recommended_model), "effort_source": "model_default"}
            assert admitted["configuration"] == expected, admitted
            assert admitted["context"]["session"] == session and not admitted["answer"]["replayed"], admitted
            original = record.read_bytes()
            saved = json.loads(original)
            assert set(saved["configuration"]) == {"provider", "model", "workspace"}, saved
            replayed = json.loads(invoke(*args, input=task).stdout)
            assert replayed["configuration"] == expected and replayed["context"] == admitted["context"], replayed
            assert replayed["answer"]["replayed"] and replayed["answer"]["admission"] == admitted["answer"]["admission"], replayed
            assert record.read_bytes() == original
            messages = [body for route, body in proxy.mutations if route == "/v1/message"]
            assert messages == [original, original], messages
            proxy.close()
            proxy = canonical_fixture.ReplyProxy(host, "/v1/inspect-session")
            failure_record = root / "report-failure.json"
            failure_args = args[:-4] + ["--record", failure_record, "--key", "receipt-report-failure"]
            for replay in (False, True):
                failed = subprocess.run([str(fixture.RUI), *map(str, failure_args)], env=environment,
                                        cwd=workspace, input=task, text=True, capture_output=True, timeout=20)
                assert failed.returncode != 0, failed
                known = json.loads(failed.stdout)
                assert known["answer"]["status"] == "accepted" and known["answer"]["replayed"] is replay, known
                assert known["context"]["key"] == "receipt-report-failure" and known["context"]["session"], known
                assert "configuration" not in known and "canonical_store_failure" in failed.stderr, failed
                assert canonical_fixture.announced(failed) == "receipt-report-failure"
            recovered = value("request", "recover", "--store", store, "--record", failure_record,
                              "--key", "receipt-report-failure")
            assert recovered["answer"]["replayed"] and recovered["context"] == known["context"], recovered
            print("session start receipt: concurrent edit, immutable replay and accepted identity after report failure passed", flush=True)
        finally:
            host_process.dispose_all(release.set,
                lambda: host_process.stop_process(caller, timeout=5) if caller is not None else None,
                lambda: proxy.close() if proxy is not None else None,
                lambda: fixture.stop_host(host) if host is not None else None)

