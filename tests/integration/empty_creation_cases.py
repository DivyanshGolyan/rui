"""Equivalent omitted creation settings through three real clients and either Store."""
import json
import os
import pathlib
import subprocess

import host_process
from human_cli_fixture import open_new_chat, overview_frame, overview_title, terminal_exit
from product_defaults import DEFAULTS, compaction_trigger, start_effort
import settings_fixture
from terminal_process import close_pty, open_pty, spawn


def empty_creation(binary, root, store_settings, env):
    root = pathlib.Path(root)
    root.mkdir(mode=0o700)
    home, workspace = root / "home", root / "workspace"
    home.mkdir(mode=0o700)
    workspace.mkdir(mode=0o700)
    config = home / ".config/rui"
    config.mkdir(parents=True, mode=0o700)
    fixture_key = "sk-empty-creation-fixture"
    key_file = config / "openai.key"
    key_file.write_text(fixture_key + "\n")
    key_file.chmod(0o600)
    clean = dict(env, HOME=str(home))
    for name in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE", "RUI_RUNTIME_DIR"):
        clean.pop(name, None)
    binding = {"provider": "openai", "model": DEFAULTS.recommended_model, "workspace": str(workspace)}
    expected = {
        "tools": sorted(DEFAULTS.tools.split(",")),
        "loaded_tools": sorted(DEFAULTS.tools.split(",")),
        "permission_mode": DEFAULTS.permission_mode,
        "reasoning_effort": start_effort(binding["model"]),
        "compaction_trigger": str(compaction_trigger(binding["provider"], binding["model"])),
    }

    def check(report):
        saved = report["session"]
        assert {name: saved[name] for name in binding} == binding, saved
        assert {name: saved[name] for name in expected} == expected, saved
        assert report["first_message"] is None and report["pending_messages"] == "0", report
        # Identity and creation time differ; every persisted setting must agree.
        return {name: value for name, value in saved.items() if name not in ("reference", "created_at")}

    with host_process.short_interface_directory() as runtime:
        clean["RUI_RUNTIME_DIR"] = str(runtime)
        if "sqlite" in store_settings:
            placement = subprocess.run([str(binary), "host", "set", "--store", store_settings["sqlite"]["dir"],
                                        "interface.dir", str(runtime)], env=clean, cwd=workspace,
                                       text=True, capture_output=True, timeout=20)
            assert placement.returncode == 0, placement
        document = {
            "store": store_settings,
            "interface": {"dir": str(runtime), "lifetime": "stdin"},
            "execution": {"paused": True},
            "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses",
                                      "key": {"value": fixture_key}}},
        }
        helper = pathlib.Path(__file__).resolve().parents[2] / "clients/ts/test/fixtures/empty-creation.ts"
        typed = subprocess.run(["node", "--experimental-strip-types", str(helper)], env=clean, cwd=workspace,
                               input=json.dumps({"binary": str(binary), "settings": document, "binding": binding}),
                               capture_output=True, text=True, timeout=40)
        assert typed.returncode == 0, typed
        typescript = json.loads(typed.stdout)
        assert len(typescript) == 1, typescript
        resolved = check(typescript[0]["report"])
        assert typescript[0]["request"]["configuration"] == binding, typescript[0]["request"]

        host = subprocess.Popen([str(binary), "host", "serve", "--settings", "-"], env=clean,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def close_host():
            try:
                host_process.close_stdin(host)
                assert host.wait(timeout=30) == 0, settings_fixture.output(host)
            finally:
                host_process.stop_process(host)

        try:
            host.stdin.write(settings_fixture.frame(document))
            host.stdin.flush()
            sock = runtime / "rui.sock"
            settings_fixture.wait_for_host(sock, "", host)
            store = settings_fixture.host_info(sock, "")["store"]

            def invoke(*args):
                result = subprocess.run([str(binary), *map(str, args)], env=clean, cwd=workspace,
                                        text=True, capture_output=True, timeout=20)
                assert result.returncode == 0, (args, result)
                return json.loads(result.stdout)

            def inspect(session):
                return invoke("session", "inspect", "--store", store, "--session", session)

            record = root / "cli.json"
            cli = invoke("session", "configure", "--store", store, "--record", record, "--key", "empty-creation:cli",
                         "--connection", binding["provider"], "--model", binding["model"], "--workspace", workspace)
            assert json.loads(record.read_text())["configuration"] == binding
            assert check(inspect(cli["context"]["session"])) == resolved

            records = home / ".config/rui/requests"
            before = set(records.glob("*.json"))
            master, slave = open_pty()
            caller = None
            try:
                caller = spawn([str(binary), "--store", store, "--connection", binding["provider"],
                                "--model", binding["model"]], cwd=workspace, env=clean,
                               stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                overview_frame(master, overview_title)
                open_new_chat(master)
                captured = set(records.glob("*.json")) - before
                assert len(captured) == 1, captured
                tui = json.loads(captured.pop().read_text())
                assert tui["kind"] == "configure" and tui["configuration"] == binding, tui
                admission = invoke("request", "recover", tui["key"])
                assert admission["answer"]["replayed"] is True, admission
                assert check(inspect(admission["context"]["session"])) == resolved
                os.write(master, b"\x04")
                _, errors = terminal_exit(caller, master)
                assert caller.wait(timeout=5) == 0, errors
            finally:
                host_process.dispose_all(
                    lambda: host_process.stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: close_pty(master), lambda: close_pty(slave))
        finally:
            host_process.dispose_all(close_host)
    print("empty creation: CLI, TUI and TypeScript persist identical Host defaults for an explicit model")
