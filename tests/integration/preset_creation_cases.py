"""CLI preset capture and the shared native resolver on either real Store engine."""
import json
import pathlib
import subprocess

from canonical_fixture import announced
import host_process
import settings_fixture
from product_defaults import compaction_trigger, start_effort


def preset_creation(binary, root, store_settings, env):
    # Exercise the socket limit even when the fixture runner has a short TMPDIR.
    long_root = pathlib.Path(root) / ("long-root-" + "x" * 80)
    with host_process.short_interface_directory() as runtime:
        _preset_creation(binary, long_root, store_settings, env, runtime)


def _preset_creation(binary, root, store_settings, env, runtime):
    root = pathlib.Path(root)
    root.mkdir(mode=0o700, parents=True)
    home, workspace, elsewhere = (root / name for name in ("home", "workspace", "cwd"))
    for path in (home, workspace, elsewhere):
        path.mkdir(mode=0o700)
    clean = dict(env, HOME=str(home), RUI_RUNTIME_DIR=str(runtime))
    for name in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE"):
        clean.pop(name, None)
    socket = runtime / "rui.sock"
    preset = {"provider": "openai", "workspace": str(workspace), "model": "gpt-6.1-sol",
              "effort": "low", "compactAt": 100000, "outputReservation": 1234,
              "tools": ["bash", "find_tools"], "loadedTools": ["find_tools"],
              "permissionMode": "ask", "instructions": "Preset instructions", "label": "Restricted",
              "outputSchema": {"type": "object", "properties": {"answer": {"type": "string"}}}}
    document = {"store": store_settings, "interface": {"dir": str(runtime), "lifetime": "stdin"},
                "execution": {"paused": True},
                "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses",
                                           "key": {"value": "sk-preset-creation-fixture"}}}}
    host = None
    store = None
    captures = []

    def invoke(*args, input=None, expect=0):
        result = subprocess.run([str(binary), *map(str, args)], cwd=elsewhere, env=clean,
                                input=input, text=True, capture_output=True, timeout=40)
        assert result.returncode == expect, (args, result)
        return result

    def value(*args, **kwargs):
        return json.loads(invoke(*args, **kwargs).stdout)

    def close():
        nonlocal host
        if host is not None:
            current, host = host, None
            try:
                host_process.close_stdin(current)
                assert current.wait(timeout=30) == 0, settings_fixture.output(current)
            finally:
                host_process.stop_process(current)

    def launch(presets):
        nonlocal host, store
        close()
        host = subprocess.Popen([str(binary), "host", "serve", "--settings", "-"], env=clean,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        host.stdin.write(settings_fixture.frame(dict(document, presets=presets)))
        host.stdin.flush()
        settings_fixture.wait_for_host(socket, "", host)
        identity = settings_fixture.host_info(socket, "")["store"]
        assert store is None or identity == store, (identity, store)
        store = identity

    def inspect(session):
        cli = value("session", "inspect", "--store", store, "--session", session)
        native = settings_fixture.post(socket, "inspect-session", {
            "version": settings_fixture.WIRE, "kind": "inspect_session", "store": store, "session": session})
        assert cli["session"] == native["session"], (cli, native)
        return cli

    def sessions():
        return {row["reference"] for row in value("session", "list", "--store", store, "--all")["sessions"]}

    def capture(*args, input=None, expect=4, unlisted=None):
        result = invoke("session", "configure", "--store", store, *args, input=input, expect=expect)
        if unlisted is not None:
            warning = f"rui: this client's catalog does not list {unlisted}; client defaults use estimated limits.\n"
            assert result.stderr.startswith(warning), result
            result = subprocess.CompletedProcess(result.args, result.returncode, result.stdout, result.stderr[len(warning):])
        handle = announced(result)
        record = home / ".config/rui/requests" / (handle + ".json")
        routing = record.with_name(record.name + ".routing")
        original, route = record.read_bytes(), routing.read_bytes()
        request = json.loads(original)
        assert request["kind"] == "configure" and request["store"] == store, request
        captures.append((record, original, routing, route))
        return handle, request

    def recover(handle, expect=0):
        return value("request", "recover", handle, expect=expect)

    def admission(handle, session):
        observed = value("request", "inspect", handle)
        assert observed["observation"] == {"status": "accepted", "kind": "configure", "target": session,
                                           "revision": "1", "created": True}, observed
        return observed["observation"]

    def restricted(saved, loaded=("find_tools",)):
        assert saved["provider"] == preset["provider"] and saved["workspace"] == str(workspace), saved
        assert saved["model"] == preset["model"] and saved["reasoning_effort_override"] == "low", saved
        assert saved["compaction_trigger_override"] == "100000", saved
        assert saved["output_reservation_override"] == "1234", saved
        assert saved["tools"] == ["bash", "find_tools"] and saved["loaded_tools"] == list(loaded), saved
        assert saved["permission_mode"] == "ask" and saved["label"] == "Restricted", saved
        assert saved["instructions"]["bytes"] == str(len(preset["instructions"].encode())), saved
        assert saved["output_schema"] is not None, saved
        full = value("session", "inspect", "--store", store, "--session", saved["reference"], "--profile", "full")
        revision = full["full"]["session_revisions"][0]
        assert revision["instructions"]["text"] == preset["instructions"], revision
        assert json.loads(revision["output_schema"]["text"]) == preset["outputSchema"], revision

    try:
        if "sqlite" in store_settings:
            invoke("host", "set", "--store", store_settings["sqlite"]["dir"], "interface.dir", runtime)
        launch({"restricted": preset})
        # Poison ordinary fresh preferences and cwd: none may replace the preset seed.
        invoke("defaults", "configure", "--provider", "codex", "--model", "gpt-6-sol",
               "--permission-mode", "bypass", "--reasoning-effort", "high")
        before = sessions()
        base, captured = capture("--preset", "restricted", "--test-drop-reply", "after-commit")
        assert captured["session"] == "" and captured["preset"] == "restricted", captured
        assert captured["configuration"] == {}, captured
        reply = recover(base)
        session = reply["context"]["session"]
        assert reply["answer"]["replayed"] is True and reply["answer"]["created"] is True, reply
        base_report = inspect(session)
        restricted(base_report["session"])
        assert base_report["first_message"] is None and base_report["pending_messages"] == "0", base_report
        original_admission = admission(base, session)
        result = invoke("request", "read-result", base, expect=1)
        assert result.stdout == "", result
        assert any(line.startswith("{") and json.loads(line).get("error", {}).get("code") == "result_not_found"
                   for line in result.stderr.splitlines()), result

        # The public native Configure door resolves the same complete settings spec.
        native = settings_fixture.post(socket, "configure", {
            "version": settings_fixture.WIRE, "kind": "configure", "store": store, "session": "",
            "key": "preset-native-parity", "preset": "restricted", "configuration": {}})
        assert native["answer"]["status"] == "accepted", native
        native_session = native["answer"]["session"]
        restricted(inspect(native_session)["session"])

        loaded_only, loaded_capture = capture("--preset", "restricted", "--loaded-tools", "find_tools",
                                              "--test-drop-reply", "after-commit")
        assert loaded_capture["configuration"] == {"loadedTools": ["find_tools"]}, loaded_capture
        loaded_session = recover(loaded_only)["context"]["session"]
        restricted(inspect(loaded_session)["session"], loaded=("find_tools",))

        loaded_refusals = []
        for argument, members, code in (
            ("none", [], "loaded_tools_unreachable"),
            ("web_search", ["web_search"], "loaded_tools_not_in_tools"),
        ):
            handle, rejected_capture = capture("--preset", "restricted", "--loaded-tools", argument, expect=3)
            assert rejected_capture["configuration"] == {"loadedTools": members}, rejected_capture
            refusal = recover(handle, expect=3)["answer"]
            assert refusal["replayed"] is True and refusal["code"] == code, refusal
            observed = value("request", "inspect", handle)["observation"]
            assert observed == {"status": "rejected", "kind": "configure", "target": "", "code": code}, observed
            loaded_refusals.append((handle, code))

        override, changed_capture = capture("--preset", "restricted", "--model", "gpt-4.1",
            "--tools", "none", "--loaded-tools", "none", "--permission-mode", "bypass",
            "--reasoning-effort", "default", "--compaction-trigger", "2000", "--output-reservation", "default",
            "--instructions", "-", "--label", "", "--text-output", "--test-drop-reply", "after-commit", input="")
        configuration = changed_capture["configuration"]
        assert "provider" not in configuration and "workspace" not in configuration, configuration
        assert configuration["tools"] == [] and configuration["loadedTools"] == [], configuration
        assert configuration["instructions"] == "" and configuration["compactAt"] == 2000, configuration
        for name in ("effort", "outputReservation", "label", "outputSchema"):
            assert name in configuration and configuration[name] is None, configuration
        changed_reply = recover(override)
        changed_session = changed_reply["context"]["session"]
        changed = inspect(changed_session)["session"]
        assert changed["provider"] == "openai" and changed["workspace"] == str(workspace), changed
        assert changed["model"] == "gpt-4.1" and changed["reasoning_effort_override"] is None, changed
        assert changed["tools"] == [] and changed["loaded_tools"] == [] and changed["permission_mode"] == "bypass", changed
        assert changed["compaction_trigger_override"] == "2000" and changed["output_reservation_override"] is None, changed
        assert changed["label"] is None and changed["output_schema"] is None and changed["instructions"]["bytes"] == "0", changed

        # Explicit policy nulls now ask the Host for the selected model's
        # defaults, including when they override a preset's explicit policies.
        unknown_model = "unlisted-preset-model"
        unknown_effort, unknown_effort_capture = capture("--preset", "restricted", "--model", unknown_model,
            "--reasoning-effort", "default", "--test-drop-reply", "after-commit", unlisted=unknown_model)
        assert unknown_effort_capture["configuration"] == {"model": unknown_model, "effort": None}, unknown_effort_capture
        unknown_effort_session = recover(unknown_effort)["context"]["session"]
        unknown_saved = inspect(unknown_effort_session)["session"]
        assert unknown_saved["model"] == unknown_model, unknown_saved
        assert unknown_saved["reasoning_effort_override"] == start_effort(unknown_model), unknown_saved
        reset_effort, reset_effort_capture = capture("--preset", "restricted", "--model", "gpt-6-luna",
            "--reasoning-effort", "default", "--test-drop-reply", "after-commit")
        assert reset_effort_capture["configuration"] == {"model": "gpt-6-luna", "effort": None}, reset_effort_capture
        reset_effort_reply = recover(reset_effort)
        assert reset_effort_reply["answer"]["replayed"] is True, reset_effort_reply
        reset_effort_session = reset_effort_reply["context"]["session"]
        reset_saved = inspect(reset_effort_session)["session"]
        assert reset_saved["model"] == "gpt-6-luna", reset_saved
        assert reset_saved["reasoning_effort_override"] == start_effort("gpt-6-luna"), reset_saved

        reset_compact, reset_compact_capture = capture("--preset", "restricted", "--compaction-trigger", "default",
                                                       "--test-drop-reply", "after-commit")
        assert reset_compact_capture["configuration"] == {"compactAt": None}, reset_compact_capture
        reset_compact_reply = recover(reset_compact)
        assert reset_compact_reply["answer"]["replayed"] is True, reset_compact_reply
        reset_compact_session = reset_compact_reply["context"]["session"]
        compact_saved = inspect(reset_compact_session)["session"]
        assert compact_saved["compaction_trigger_override"] == str(compaction_trigger("openai", preset["model"])), compact_saved

        missing, _ = capture("--preset", "missing", expect=3)
        assert recover(missing, expect=3)["answer"]["code"] == "unknown_preset"
        update, _ = capture("--session", session, "--preset", "restricted", expect=3)
        assert recover(update, expect=3)["answer"]["code"] == "preset_on_update"
        # The preset refusal belongs to the Host even when an addressed Session
        # does not exist and effort default would normally trigger a client read.
        known = sessions()
        unknown = next(f"{number:06d}" for number in range(len(known) + 1) if f"{number:06d}" not in known)
        unknown_update, unknown_capture = capture("--session", unknown, "--preset", "restricted",
                                                  "--reasoning-effort", "default", expect=3)
        assert unknown_capture["session"] == unknown and unknown_capture["preset"] == "restricted", unknown_capture
        assert unknown_capture["configuration"] == {"effort": None}, unknown_capture
        unknown_refusal = {"status": "rejected", "kind": "configure", "target": unknown, "code": "preset_on_update"}
        assert value("request", "inspect", unknown_update)["observation"] == unknown_refusal
        replayed_unknown = recover(unknown_update, expect=3)["answer"]
        assert replayed_unknown["code"] == "preset_on_update" and replayed_unknown["replayed"] is True, replayed_unknown

        start_record = root / "start-refused.json"
        refused = invoke("session", "start", "--store", store, "--preset", "restricted", "--record", start_record,
                         input="must not start a task", expect=2)
        assert "[option_unknown]" in refused.stderr and "rui session start:" in refused.stderr and "preset" in refused.stderr, refused
        assert not start_record.exists(), refused
        assert sessions() - before == {session, native_session, loaded_session, changed_session, unknown_effort_session,
                                                reset_effort_session, reset_compact_session}

        # A later configuration must not rewrite the original Configure admission answer.
        invoke("session", "configure", "--store", store, "--session", session, "--label", "Later label")
        assert inspect(session)["session"]["revision"] == "2"
        assert value("request", "inspect", base)["observation"] == original_admission
        launch({"restricted": preset})
        assert recover(base)["answer"]["session"] == session
        assert recover(override)["answer"]["session"] == changed_session
        assert recover(loaded_only)["answer"]["session"] == loaded_session
        assert recover(reset_effort)["answer"]["session"] == reset_effort_session
        assert recover(reset_compact)["answer"]["session"] == reset_compact_session
        for handle, code in loaded_refusals:
            refusal = recover(handle, expect=3)["answer"]
            assert refusal["replayed"] is True and refusal["code"] == code, refusal
        assert value("request", "inspect", base)["observation"] == original_admission

        # Changing a field hidden by an explicit override preserves the effective resolution.
        launch({"restricted": dict(preset, model="gpt-6-sol"), "missing": preset})
        assert recover(base, expect=3)["answer"]["status"] == "conflict"
        assert recover(loaded_only, expect=3)["answer"]["status"] == "conflict"
        assert recover(override)["answer"]["replayed"] is True
        assert recover(reset_effort)["answer"]["replayed"] is True
        assert recover(reset_compact, expect=3)["answer"]["status"] == "conflict"
        for handle, code in ((missing, "unknown_preset"), (update, "preset_on_update"), (unknown_update, "preset_on_update")):
            refusal = recover(handle, expect=3)["answer"]
            assert refusal["replayed"] is True and refusal["code"] == code, refusal
        assert value("request", "inspect", unknown_update)["observation"] == unknown_refusal
        assert value("request", "inspect", base)["observation"] == original_admission
        assert inspect(session)["session"]["model"] == preset["model"]

        launch({})
        for handle in (base, loaded_only, override, reset_effort, reset_compact):
            assert recover(handle, expect=3)["answer"]["status"] == "conflict"
        for handle, code in ((missing, "unknown_preset"), (update, "preset_on_update"), (unknown_update, "preset_on_update")):
            refusal = recover(handle, expect=3)["answer"]
            assert refusal["replayed"] is True and refusal["code"] == code, refusal
        assert value("request", "inspect", unknown_update)["observation"] == unknown_refusal
        assert sessions() - before == {session, native_session, loaded_session, changed_session, unknown_effort_session,
                                                reset_effort_session, reset_compact_session}
        assert value("request", "inspect", base)["observation"] == original_admission
        for record, original, routing, route in captures:
            assert record.read_bytes() == original and routing.read_bytes() == route
        print("CLI presets: sparse capture, restricted seed, native parity, explicit clears, durable replay and refusals passed")
    finally:
        host_process.dispose_all(close)
