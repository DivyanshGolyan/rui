#!/usr/bin/env python3
"""CM-40: native Message images retain their bytes through provider delivery."""
import base64
import json
import shutil
import subprocess
import tempfile
import threading
import time

import host_process
from host_process import canonical_fixture_root, dispose_all, retain_failure_state
import model_fixture as fixture
import terminal_process


def user_parts(request):
    users = [item for item in request["input"] if item.get("role") == "user"]
    return users[-1]["content"]


def wait_message(store, key):
    deadline = time.monotonic() + 30
    observation = fixture.wait_for(
        lambda: (value if (value := fixture.observe(store, key, deadline=deadline)).get("state")
                 in fixture.TERMINAL_MESSAGE_STATES else None),
        f"{key} terminal result", deadline=deadline,
    )
    answer = fixture.read_result(store, key, deadline=deadline) if observation["state"] == "completed" else None
    return observation, answer


def cli_observation(store, receipt, observation, expected_parts):
    # CLI-19: inspect and wait retain the admitted multipart identity and its readable owner.
    admitted_input = receipt["input"]
    admission = receipt["answer"]["admission"]
    session = receipt["context"]["session"]
    assert admitted_input["type"] == "parts" and admitted_input["owner"] == {"message": admission}, receipt
    waited = fixture.command("request", "wait", "--store", store, "--key", receipt["context"]["key"],
                             "--timeout-seconds", "15")["observation"]
    for observed in (observation, waited):
        assert (observed["kind"], observed["status"], observed["state"], observed["target"]) == (
            "message", "accepted", "completed", session), observed
        assert observed["queue"]["admission"] == admission, observed
        assert observed["input"] == admitted_input, (observed, receipt)

    selectors = ["--store", str(store), "--session", waited["target"],
                 "--admission", waited["input"]["owner"]["message"]]
    listed = fixture.command("session", "list-parts", *selectors)
    assert listed["value"] == admitted_input, (listed, receipt)
    assert [(part["ordinal"], part["type"], part.get("mime")) for part in listed["parts"]] == [
        (str(ordinal), kind, mime) for ordinal, (kind, mime, _) in enumerate(expected_parts)
    ], listed
    for ordinal, (_, _, content) in enumerate(expected_parts):
        read = subprocess.run([str(fixture.RUI), "session", "read-part", *selectors, "--part", str(ordinal)],
                              capture_output=True, timeout=15)
        assert read.returncode == 0, (ordinal, read.stderr)
        assert read.stdout == content, (ordinal, len(read.stdout), len(content))


def rejected_image(store, record, part_args, accepted):
    # CLI-19: a rejected multipart receipt identifies the request, but has no admitted owner.
    target = "zzzzzz" if accepted["context"]["session"] != "zzzzzz" else "zzzzzy"
    key = "rejected-image"
    result = fixture.command("session", "send", "--store", store, "--session", target,
                             "--record", record, "--key", key, *part_args, input="", expect=3)
    assert result["answer"] == {
        "status": "rejected", "replayed": False, "session": target, "code": "unknown_session",
    }, result
    assert result["input"] == {field: accepted["input"][field] for field in ("type", "bytes", "sha256")}, result
    replay = fixture.command("request", "recover", "--store", store, "--record", record,
                             "--kind", "message", expect=3)
    assert replay["answer"] == {**result["answer"], "replayed": True}, replay
    assert replay["input"] == result["input"], (replay, result)
    inspected = fixture.observe(store, key)
    waited = fixture.command("request", "wait", "--store", store, "--key", key,
                             "--timeout-seconds", "15")["observation"]
    for observed in (inspected, waited):
        assert (observed["kind"], observed["status"], observed["state"], observed["target"], observed["code"]) == (
            "message", "rejected", "rejected", target, "unknown_session"), observed
        assert "input" not in observed, observed


def run_case(root, provider, operation):
    state = root / (provider + "-" + operation)
    state.mkdir(mode=0o700)
    workspace = state / "workspace"
    workspace.mkdir()
    png = (fixture.ROOT / "src/codecs/fixtures/image-input/pixel.png").read_bytes()
    jpeg = (fixture.ROOT / "src/testing/fixtures/input-baseline.jpg").read_bytes()
    first = state / "first.png"
    second = state / "second.jpg"
    first.write_bytes(png)
    second.write_bytes(jpeg)
    text_file = state / "middle.txt"
    text_file.write_text("middle", encoding="utf-8")
    answer = fixture.sse_answer("image-answer", "reason", "message", "received")[0]
    endpoint = fixture.SuccessEndpoint([
        fixture.ResponseSpec(b"retry", {"Retry-After": "0"}, 503), answer,
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    processes = []
    try:
        store = state / "store"
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        processes.append(fixture.start_host(store, url,
            "--set", f"providers.{provider}.endpoint={url}",
            "--set", f"providers.{provider}.unauthenticated=true"))
        common = ["--store", store, "--record", state / "message.json", "--key", "message"]
        if operation == "start":
            args = ["session", "start", *common, "--workspace", workspace,
                    "--connection", provider, "--model", "gpt-6-sol", "--tools", "none"]
        else:
            configured = fixture.command("session", "configure", "--store", store,
                "--record", state / "configure.json", "--key", "configure",
                "--workspace", workspace, "--connection", provider, "--model", "gpt-6-sol", "--tools", "none")
            args = ["session", "send", *common, "--session", configured["context"]["session"]]
        part_args = ["--text", "before", "--image", first, "--text-file", text_file,
                     "--image", second, "--text", "after"]
        args += part_args
        record = state / "message.json"
        receipt = None
        if provider == "codex" and operation == "send":
            lost = subprocess.run([str(fixture.RUI), *map(str, args), "--test-drop-reply", "after-commit"],
                                  text=True, input="", capture_output=True, timeout=15)
            assert lost.returncode == 4, lost
        else:
            receipt = fixture.command(*args, input="")
            assert receipt["answer"]["status"] == "accepted" and receipt["answer"]["replayed"] is False, receipt
            if provider == "codex" and operation == "start":
                rejected_image(store, state / "rejected.json", part_args, receipt)

        frozen = record.read_bytes()
        first.unlink()
        second.unlink()
        text_file.unlink()
        replay = fixture.command("request", "recover", "--store", store, "--record", record, "--kind", "message")
        assert replay["answer"]["status"] == "accepted" and replay["answer"]["replayed"] is True, replay
        assert replay["context"]["key"] == "message" and record.read_bytes() == frozen, replay
        if receipt is not None:
            assert replay["context"] == receipt["context"], (replay, receipt)
            assert replay["answer"] == {**receipt["answer"], "replayed": True}, (replay, receipt)
            assert replay["input"] == receipt["input"], (replay, receipt)

        observation, answer_bytes = wait_message(store, "message")
        assert observation["state"] == "completed" and answer_bytes == b"received", observation
        cli_observation(store, replay, observation, [
            ("text", None, b"before"), ("image", "image/png", png), ("text", None, b"middle"),
            ("image", "image/jpeg", jpeg), ("text", None, b"after"),
        ])
        assert len(endpoint.requests) == 2, endpoint.requests
        assert endpoint.requests[0] == endpoint.requests[1], endpoint.requests
        right = json.loads(endpoint.requests[1])
        parts = user_parts(right)
        assert [part["type"] for part in parts] == ["input_text", "input_image", "input_text", "input_image", "input_text"], parts
        assert [parts[i]["text"] for i in (0, 2, 4)] == ["before", "middle", "after"], parts
        for part, mime, expected in ((parts[1], "image/png", png), (parts[3], "image/jpeg", jpeg)):
            prefix = "data:" + mime + ";base64,"
            assert part["image_url"].startswith(prefix), part
            assert base64.b64decode(part["image_url"][len(prefix):], validate=True) == expected, part
        assert str(first) not in json.dumps(right) and str(second) not in json.dumps(right)
    finally:
        fixture.dispose_dispatch(processes, {endpoint: thread}, [])


def cli_rules(root):
    # CLI-21: syntax and stdin selection are local and preserve scalar text bytes.
    state = root / "cli-rules"
    state.mkdir(mode=0o700)
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("scalar-answer", "reason", "message", "received")[0],
        fixture.sse_answer("stdin-answer", "reason2", "message2", "received")[0],
        fixture.sse_answer("terminal-answer", "reason3", "message3", "received")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    processes = []
    try:
        store = state / "store"
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        processes.append(fixture.start_host(store, url))
        config = fixture.command("session", "configure", "--store", store,
            "--record", state / "configure.json", "--key", "configure", "--workspace", state,
            "--connection", "codex", "--model", "gpt-6-sol", "--tools", "none")
        session = config["context"]["session"]
        legacy = state / "legacy.json"
        explicit = state / "explicit.json"
        common = ["session", "send", "--store", store, "--session", session, "--key", "scalar"]
        first = fixture.command(*common, "--record", legacy, input="α\n\n")
        replay = fixture.command(*common, "--record", explicit, "--text", "α\n\n", input="")
        assert first["answer"]["status"] == "accepted" and replay["answer"]["replayed"] is True
        assert legacy.read_bytes() == explicit.read_bytes()
        for label, args, stdin in (
            ("unselected", ["--text", "value"], "unselected"),
            ("empty", ["--text", ""], ""),
            ("unknown", ["--unknown-option"], ""),
            ("duplicate-stdin", ["--text-file", "-", "--text-file", "-"], "text"),
        ):
            record = state / (label + ".json")
            cmd = [str(fixture.RUI), "session", "send", "--store", str(store), "--session", session,
                   "--record", str(record), "--key", label, *args]
            failed = subprocess.run(cmd, input=stdin, text=True, capture_output=True, timeout=15)
            assert failed.returncode != 0 and not record.exists(), (label, failed)
        image = state / "image.png"
        png = (fixture.ROOT / "src/codecs/fixtures/image-input/pixel.png").read_bytes()
        image.write_bytes(png)
        result = fixture.command("session", "send", "--store", store, "--session", session,
            "--record", state / "implicit.json", "--key", "implicit", "--image", image, input="piped first")
        assert result["answer"]["status"] == "accepted", result
        observation, _ = wait_message(store, "implicit")
        assert observation["state"] == "completed", observation
        parts = user_parts(json.loads(endpoint.requests[-1]))
        assert parts[0] == {"type": "input_text", "text": "piped first"}, parts
        assert base64.b64decode(parts[1]["image_url"].split(",", 1)[1], validate=True) == png, parts
        master, slave = terminal_process.open_pty()
        try:
            cmd = [str(fixture.RUI), "session", "send", "--store", str(store), "--session", session,
                   "--record", str(state / "terminal.json"), "--key", "terminal", "--image", str(image)]
            completed = subprocess.run(cmd, stdin=slave, text=True, capture_output=True, timeout=15)
            assert completed.returncode == 0, completed
            assert json.loads(completed.stdout)["answer"]["status"] == "accepted", completed
        finally:
            terminal_process.close_pty(master, slave)
        observation, _ = wait_message(store, "terminal")
        assert observation["state"] == "completed", observation
        parts = user_parts(json.loads(endpoint.requests[-1]))
        assert len(parts) == 1 and parts[0]["type"] == "input_image", parts
        assert base64.b64decode(parts[0]["image_url"].split(",", 1)[1], validate=True) == png, parts
    finally:
        fixture.dispose_dispatch(processes, {endpoint: thread}, [])


def unsupported_model(root):
    # CM-41: the existing model policy refuses before provider I/O.
    state = root / "unsupported"
    state.mkdir(mode=0o700)
    image = state / "image.png"
    image.write_bytes((fixture.ROOT / "src/codecs/fixtures/image-input/pixel.png").read_bytes())
    endpoint = fixture.SuccessEndpoint([])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    processes = []
    try:
        store = state / "store"
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        processes.append(fixture.start_host(store, url))
        result = fixture.command("session", "start", "--store", store,
            "--record", state / "message.json", "--key", "message", "--workspace", state,
            "--connection", "codex", "--model", "gpt-3.5-turbo", "--tools", "none",
            "--text", "image", "--image", image)
        assert result["answer"]["status"] == "accepted", result
        observed, _ = wait_message(store, "message")
        assert observed["state"] == "failed" and observed["result"]["code"] == "model_image_input_unsupported", observed
        assert endpoint.requests == [], endpoint.requests
    finally:
        fixture.dispose_dispatch(processes, {endpoint: thread}, [])


def main():
    root = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-cli-image."))
    completed = False
    try:
        for provider in ("codex", "openai", "chatgpt"):
            for operation in ("start", "send"):
                run_case(root, provider, operation)
        cli_rules(root)
        unsupported_model(root)
        completed = True
        print("CLI start/send: ordered PNG and JPEG reached each provider and retry unchanged")
    finally:
        dispose_all(lambda: shutil.rmtree(root) if completed else retain_failure_state("CLI image failure state", root))


if __name__ == "__main__":
    host_process.enter()
    main()
