"""Fresh-process consumers of a client's immutable capture and routing pair."""
import json
import pathlib
import subprocess

from canonical_fixture import announced


def capture_routing(binary, directory, root, env, *, message=None):
    clean = dict(env)
    for name in ("RUI_STORE", "RUI_RUNTIME_DIR", "RUI_SETTINGS_MYSQL_URL"):
        clean.pop(name, None)

    def invoke(*args, input=None):
        return subprocess.run([str(binary), *map(str, args)], cwd=root, env=clean,
                              input=input, text=True, capture_output=True, timeout=40)

    command = ["session", "start" if message is not None else "configure", "--store", directory,
               "--workspace", root, "--provider", "codex", "--model", "gpt-6-sol",
               "--test-drop-reply", "after-commit"]
    dropped = invoke(*command, input=message)
    assert dropped.returncode == 4 and "[reply_unconfirmed]" in dropped.stderr, dropped
    handle = announced(dropped)
    record = pathlib.Path(clean["HOME"]) / ".config/rui/requests" / (handle + ".json")
    route = record.with_name(record.name + ".routing")
    original, routing = record.read_bytes(), route.read_bytes()
    metadata = json.loads(routing)
    assert metadata["host_directory"] == str(directory.resolve()) and not metadata["runtime_hint"], metadata
    saved = json.loads(original)
    different = root / "different-default"
    different.mkdir(mode=0o700, exist_ok=True)
    changed = invoke("defaults", "configure", "--store", different)
    assert changed.returncode == 0, changed
    recovered = invoke("request", "recover", handle)
    assert recovered.returncode == 0, recovered
    replay = json.loads(recovered.stdout)
    assert replay["context"]["key"] == handle and replay["context"]["store"] == saved["store"], replay
    assert replay["answer"]["replayed"] is True, replay
    observed = invoke("request", "inspect", handle)
    assert observed.returncode == 0, observed
    facts = json.loads(observed.stdout)
    assert facts["key"] == handle and facts["observation"]["status"] == "accepted", facts
    waited = invoke("request", "wait", handle, "--timeout-seconds", "20")
    assert waited.returncode == 0, waited
    waiting = json.loads(waited.stdout)
    assert waiting["key"] == handle and waiting["observation"]["status"] == "accepted", waiting
    result = invoke("request", "read-result", handle)
    if message is not None:
        assert result.returncode == 0 and result.stdout == "capture route answer", result
        assert waiting["observation"]["state"] == "completed", waiting
    else:
        # Configure is not a Message. This must be the Host's typed answer,
        # not a failure to discover the captured endpoint.
        assert result.returncode != 0 and any(
            line.startswith("{") and json.loads(line).get("code") == "result_not_found"
            for line in result.stderr.splitlines()), result
    assert record.read_bytes() == original and route.read_bytes() == routing
    return handle
