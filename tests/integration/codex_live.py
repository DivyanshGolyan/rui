#!/usr/bin/env python3
"""Opt-in native public-caller qualification; never part of ordinary build gates."""

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time

import bash_integration as bash
import dispatch_integration as caller
from host_process import start_ready_process


def observations(host):
    records = []

    def drain():
        for line in host.stderr:
            match = re.search(rb"rui: codex transfer (operation=\d+ http_version=\d+ connection_id=-?\d+ new_connections=\d+ correlation_present=(?:true|false) correlation_sha256=[0-9a-f]+ alpn=unavailable)", line)
            if match and len(records) < 8:
                records.append(dict(part.split("=", 1) for part in match.group(1).decode().split()))
            rejection = re.search(rb"rui: provider output rejected for operation (\d+): ([A-Za-z][A-Za-z0-9_]*)", line)
            if rejection:
                print(f"Provider validation rejected operation {rejection[1].decode()}: {rejection[2].decode()}", flush=True)

    thread = threading.Thread(target=drain, daemon=True)
    thread.start()
    return records, thread


def wait_for(store, key, predicate, label):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        value = caller.observe(store, key)
        if predicate(value):
            return value
        result = value.get("result", {})
        if result.get("code") or result.get("status") in ("failed", "stopped"):
            raise AssertionError(f"{label}: saved failure {result.get('code', result.get('status'))}")
        time.sleep(0.5)
    raise AssertionError(f"timed out waiting for {label}")


def evidence(store):
    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as db:
        return db.execute(
            "SELECT response_id,body_model,openai_model,x_openai_model,request_id "
            "FROM model_operation WHERE response_id IS NOT NULL ORDER BY operation_id"
        ).fetchall()


def private_reasoning_count(store, operation):
    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as db:
        return db.execute(
            "SELECT count(*) FROM model_output_item item JOIN content c ON c.content_id=item.content_id "
            "WHERE item.operation_id=? AND item.item_kind=1 AND c.private=1",
            (operation,),
        ).fetchone()[0]


def reasoning_token_count(store, operation):
    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as db:
        row = db.execute(
            "SELECT usage.payload FROM model_operation op LEFT JOIN content usage "
            "ON usage.content_id=op.usage_content_id WHERE op.operation_id=?",
            (operation,),
        ).fetchone()
        if row is None or row[0] is None:
            return None
        return (json.loads(row[0]).get("output_tokens_details") or {}).get("reasoning_tokens")


def run(model, external_credential=None):
    if external_credential is not None and not external_credential.is_absolute():
        raise ValueError("credential path must be absolute")
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex-live."))
    private = state / "credentials"
    private.mkdir(mode=0o700)
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    credential = external_credential or private / "codex.json"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential)
    session = "qualification/codex"
    command = "printf 'once\\n' >> effect-count; shasum -a 256 effect-count"
    prompt = (
        "Call Bash once with exactly this cmd and timeout_ms null: " + command +
        ". After its result, answer with the hex SHA-256 value printed by Bash. "
        "Do not run another tool or guess the value."
    )
    host = None
    reader = None
    first_observations = []
    later_observations = []
    try:
        # The device code is shown directly to the operator, never captured in
        # an artifact or included in the payload-free qualification report.
        if not credential.exists():
            print("Rui-owned device login (requires an enabled account):", flush=True)
            subprocess.run([str(caller.RUI), "login", "codex"], check=True, timeout=1000)

        def start():
            process, ready = start_ready_process(
                [caller.RUI, "serve", "--store", store, "--active-capacity", "2", "--codex"],
                required_fields={"execution": "enabled"}, timeout=20,
            )
            records, thread = observations(process)
            return process, records, thread, {"curl": ready["curl"], "openssl": ready["openssl"]}

        def stop():
            nonlocal host, reader
            if host.poll() is None:
                host.kill()
            host.wait(timeout=10)
            reader.join(timeout=5)
            assert not reader.is_alive(), "Host diagnostics did not drain"
            host.stdout.close()
            host.stderr.close()
            host = None
            reader = None

        host, first_observations, reader, dependencies = start()
        configured = caller.command(
            "configure", "--store", store, "--record", state / "configure.json",
            "--key", "configure", "--session", session, "--workspace", workspace,
            "--provider", "codex", "--model", model, "--tools", "none",
            "--permission-mode", "ask",
        )
        assert configured["answer"]["status"] == "accepted", "configuration rejected"
        # The simple Bash proposal may use no reasoning tokens. Establish real
        # private reasoning first, then require the same Session to replay it
        # through Bash continuation and a fresh Host.
        caller.message(
            state, store, "reasoning", session,
            "Count monotone lattice paths from (0,0) to (15,15) that avoid both forbidden "
            "vertices (4,7) and (10,9). Show a careful inclusion-exclusion derivation "
            "with binomial coefficients; do not use tools or write code.",
        )
        reasoning = wait_for(store, "reasoning", lambda value: value.get("result", {}).get("status") == "completed", "reasoning answer")
        assert not (workspace / "effect-count").exists(), "reasoning request caused a Bash effect"
        enabled = caller.command(
            "configure", "--store", store, "--record", state / "enable-bash.json",
            "--key", "enable-bash", "--session", session, "--tools", "bash",
        )
        assert enabled["answer"]["status"] == "accepted", "Bash configuration rejected"
        caller.message(state, store, "first", session, prompt)
        deadline = time.monotonic() + 180
        action = None
        while time.monotonic() < deadline:
            action = bash.action_for(store, session)
            if action:
                break
            result = caller.observe(store, "first").get("result", {})
            if result.get("code"):
                raise AssertionError(f"proposal failed: {result['code']}")
            time.sleep(0.5)
        assert action is not None, "no inspectable Bash proposal"
        args = json.loads(caller.read_action(store, session, action["action"], "arguments"))
        assert args == {"cmd": command, "timeout_ms": None}, "proposal differed from the safe command; nothing approved"
        assert action["authorization"] == "pending" and not (workspace / "effect-count").exists()
        bash.allow(state, store, "approve", session, action["action"])
        first = wait_for(store, "first", lambda value: value.get("result", {}).get("status") == "completed", "first answer")
        bash_report = caller.command("inspect-session", "--store", store, "--session", session, "--profile", "full")
        actions = bash_report["full"]["actions"]
        assert len(actions) == 1 and actions[0]["resolution"] == "succeeded", "Bash did not settle once"
        expected = hashlib.sha256(b"once\n").hexdigest()
        assert expected.encode() in actions[0]["result"]["text"].encode(), "tool did not print the independently computed digest"
        original_answer = caller.read_result(store, "first")
        assert expected.encode() in original_answer, "final answer omitted the tool-produced digest"
        caller.wait_for(lambda: bash.execution_custody_idle(store, session), "committed cleanup", timeout=30)
        assert (workspace / "effect-count").read_bytes() == b"once\n"
        caller.wait_for(lambda: len(first_observations) >= 3, "first Host transport observations", timeout=10)
        assert len(first_observations) == 3, "expected reasoning, Bash proposal and tool-continuation managed transfers"
        assert all(int(record["http_version"]) == 3 for record in first_observations), "HTTP/2 not observed"
        assert len({record["connection_id"] for record in first_observations}) == 1, "connection reuse not observed"
        assert [int(record["new_connections"]) for record in first_observations] == [1, 0, 0], "sequential reuse not observed"
        resources = bash.process_resources(host)

        stop()  # committed result, not an interrupted Bash effect; SQLite reads only after exit
        reasoning_counts = [private_reasoning_count(store, record["operation"]) for record in first_observations]
        reasoning_tokens = [reasoning_token_count(store, record["operation"]) for record in first_observations]
        print(f"Pre-restart reasoning: private item counts={reasoning_counts}, token usage={reasoning_tokens}", flush=True)
        assert reasoning_counts[0] > 0, "no accepted private reasoning to replay; live qualification incomplete"
        assert first_observations[0]["operation"] == reasoning["processing"]["operation"]
        before = evidence(store)
        assert len(before) == 3 and all(row[0] for row in before), "missing response identities"
        host, later_observations, reader, restarted_dependencies = start()
        assert restarted_dependencies == dependencies
        recovered = caller.retry_message(state, store, "first")
        assert recovered["answer"]["replayed"] is True
        assert caller.read_result(store, "first") == original_answer
        assert caller.observe(store, "first")["result"] == first["result"]
        assert not later_observations
        assert (workspace / "effect-count").read_bytes() == b"once\n"

        caller.message(state, store, "later", session, "What SHA-256 digest did the approved tool return earlier? Answer without Bash.")
        later = wait_for(store, "later", lambda value: value.get("result", {}).get("status") == "completed", "post-restart answer")
        assert expected.encode() in caller.read_result(store, "later"), "continued answer lost the tool witness"
        caller.wait_for(lambda: bash.execution_custody_idle(store, session), "post-restart cleanup", timeout=30)
        assert (workspace / "effect-count").read_bytes() == b"once\n"
        caller.wait_for(lambda: len(later_observations) >= 1, "fresh Host transport observation", timeout=10)
        assert len(later_observations) == 1 and int(later_observations[0]["http_version"]) == 3
        stop()  # release the Store owner before inspecting private response shape
        after = evidence(store)
        assert len(after) == 4 and after[:3] == before and after[3][0]
        print(json.dumps({
            "revision": bash.source_revision(), "system": platform.system(),
            "architecture": platform.machine(), "requested_model": model,
            "route": "/backend-api/codex/responses", "authentication": "Rui device code",
            "native_dependencies": dependencies,
            "public_result_identity": {"reasoning": reasoning["processing"], "first": first["processing"], "later": later["processing"]},
            "served_model_evidence": [
                {"body": row[1] or None, "openai_model": row[2] or None, "x_openai_model": row[3] or None,
                 "correlation_present": bool(row[4])} for row in after
            ],
            "transport": first_observations + later_observations,
            "host_resources_before_restart": resources,
            "bash_effect_count": 1, "committed_recovery_model_requests": 0,
            "post_restart_model_requests": 1, "private_reasoning_counts": reasoning_counts,
            "reasoning_token_usage": reasoning_tokens,
            "private_replay": "request bytes fixture-verified; live subsequent requests accepted",
        }, sort_keys=True))
    finally:
        try:
            if host is not None:
                stop()
        finally:
            shutil.rmtree(state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rui", type=pathlib.Path, help="built Rui binary")
    parser.add_argument("--live", action="store_true", help="explicitly authorize a live authenticated journey")
    parser.add_argument("--model", required=True, help="exact requested subscription model")
    parser.add_argument("--credential-file", type=pathlib.Path, help="reuse an isolated Rui credential file across diagnostic runs; operator must remove it")
    args = parser.parse_args()
    if not args.live:
        parser.error("live account calls require --live; ordinary build gates never run this runner")
    caller.RUI = args.rui.resolve()
    run(args.model, args.credential_file)
