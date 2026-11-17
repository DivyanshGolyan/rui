"""Creation preferences across real clients against a changed Host catalog."""
import json
import os
import pathlib
import ssl
import subprocess
import threading

import h2_fixture
import host_process
from human_cli_fixture import open_new_chat, overview_frame, overview_title, terminal_exit
import settings_fixture
from terminal_process import close_pty, open_pty, spawn


def preferences_bridge(binary, root, store_settings, env):
    root = pathlib.Path(root)
    root.mkdir(mode=0o700)
    home, workspace = root / "home", root / "workspace"
    home.mkdir(mode=0o700)
    workspace.mkdir(mode=0o700)
    config = home / ".config/rui"
    config.mkdir(parents=True, mode=0o700)
    preferences = config / "preferences"
    preferences.write_text("version=4\nstore=\nprovider=openai\nmodel=\nnotifications=on\n"
                           "reasoning_effort=max\npermission_mode=bypass\n")
    preferences.chmod(0o600)
    key_file = config / "openai.key"
    key_file.write_text("sk-preferences-fixture\n")
    key_file.chmod(0o600)
    clean = dict(env, HOME=str(home))
    for name in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE", "RUI_RUNTIME_DIR"):
        clean.pop(name, None)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
                    "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    endpoint = h2_fixture.Endpoint(tls, 1, sse=True, eager_sse=True)
    endpoint.catalog = json.dumps({"openai": {"models": {
        "gpt-5.5": {"reasoning_options": [{"type": "effort", "values": ["high", "max"]}]},
        "gpt-6.1-sol": {"reasoning_options": [{"type": "effort", "values": ["low"]}]},
    }}}).encode()
    endpoint.models = b'{"error":"unavailable"}'
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    try:
        with host_process.short_interface_directory() as runtime:
            clean["RUI_RUNTIME_DIR"] = str(runtime)
            if "sqlite" in store_settings:
                placement = subprocess.run([str(binary), "host", "set", "--store", store_settings["sqlite"]["dir"],
                                            "interface.dir", str(runtime)], env=clean, cwd=workspace,
                                           text=True, capture_output=True, timeout=20)
                assert placement.returncode == 0, placement
            document = {"store": store_settings, "interface": {"dir": str(runtime), "lifetime": "stdin"},
                        "execution": {"paused": True}, "network": {"caFile": str(root / "cert.pem")},
                        "providers": {"openai": {"endpoint": "https://api.openai.com/v1/responses",
                                                   "key": {"value": "sk-preferences-fixture"}}}}
            sock = runtime / "rui.sock"

            def launch(*args):
                host = subprocess.Popen([str(binary), "host", "serve", "--settings", "-", *args], env=clean,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                host.stdin.write(settings_fixture.frame(document))
                host.stdin.flush()
                settings_fixture.wait_for_host(sock, "", host)
                return host

            def close(host):
                try:
                    host_process.close_stdin(host)
                    assert host.wait(timeout=30) == 0, settings_fixture.output(host)
                finally:
                    host_process.stop_process(host)

            seed = launch("--test-models-dev-url", f"https://localhost:{endpoint.server_address[1]}/api.json")
            try:
                store = settings_fixture.host_info(sock, "")["store"]
                def catalog_ready():
                    reply = settings_fixture.post(sock, "model-list", {"version": settings_fixture.WIRE,
                                                   "kind": "model_list", "store": store})
                    return any({row["id"] for row in provider["models"]} == {"gpt-5.5", "gpt-6.1-sol"}
                               for provider in reply["providers"] if provider["provider"] == "openai")
                host_process.wait_for(catalog_ready, "changed Host catalog", timeout=30)
            finally:
                close(seed)

            helper = pathlib.Path(__file__).resolve().parents[2] / "clients/ts/test/fixtures/preferences-bridge.ts"
            typed = subprocess.run(["node", "--experimental-strip-types", str(helper)], env=clean, cwd=workspace,
                                   input=json.dumps({"binary": str(binary), "settings": document, "workspace": str(workspace)}),
                                   capture_output=True, text=True, timeout=60)
            assert typed.returncode == 0, typed
            reports = json.loads(typed.stdout)
            assert [(r["session"]["model"], r["session"]["reasoning_effort"], r["session"]["permission_mode"])
                    for r in reports] == [("gpt-5.5", "max", "bypass"), ("gpt-6.1-sol", "low", "bypass"),
                                           ("gpt-5.5", "high", "ask")], reports

            host = launch()
            try:
                store = settings_fixture.host_info(sock, "")["store"]
                def invoke(*args):
                    done = subprocess.run([str(binary), *map(str, args)], env=clean, cwd=workspace,
                                          capture_output=True, text=True, timeout=30)
                    assert done.returncode == 0, (args, done)
                    return json.loads(done.stdout)
                def inspect(session):
                    return invoke("session", "inspect", "--store", store, "--session", session)["session"]
                def check(saved, model, effort, mode):
                    assert (saved["model"], saved["reasoning_effort"], saved["permission_mode"]) == (model, effort, mode), saved
                for index, (model, effort, flags, mode) in enumerate([
                    ("gpt-5.5", "max", (), "bypass"),
                    ("gpt-6.1-sol", "low", (), "bypass"),
                    ("gpt-5.5", "high", ("--reasoning-effort", "high", "--permission-mode", "ask"), "ask"),
                ]):
                    record = root / f"cli-{index}.json"
                    receipt = invoke("session", "configure", "--store", store, "--record", record, "--key", f"preferences:cli:{index}",
                                     "--model", model, "--workspace", workspace, *flags)
                    if index == 0:
                        parent = receipt["context"]["session"]
                    request = json.loads(record.read_text())
                    assert request["configuration"]["provider"] == "openai", request
                    assert request["configuration"]["model"] == model, request
                    captured_preferences = {"permission_mode": "bypass"}
                    if not flags:
                        captured_preferences["reasoning_effort"] = "max"
                    assert request["configuration"]["preferences"] == captured_preferences, request
                    check(inspect(receipt["context"]["session"]), model, effort, mode)
                    original = preferences.read_bytes()
                    preferences.write_text(original.decode().replace("reasoning_effort=max", "reasoning_effort=low")
                                           .replace("permission_mode=bypass", "permission_mode=ask"))
                    replay = invoke("request", "recover", "--store", store, "--record", record, "--kind", "configure")
                    preferences.write_bytes(original)
                    assert replay["answer"]["replayed"] is True and replay["context"]["session"] == receipt["context"]["session"], replay

                # A saved provider must not replace an attached parent's provider.
                # The selected model still uses the Host catalog for preferences.
                original = preferences.read_bytes()
                preferences.write_text(original.decode().replace("provider=openai", "provider=codex"))
                try:
                    for index, (model, effort, flags, field) in enumerate([
                        ("gpt-5.5", "max", (), "omitted"),
                        ("gpt-6.1-sol", "low", (), "omitted"),
                        ("gpt-5.5", "high", ("--reasoning-effort", "high"), "high"),
                        ("gpt-5.5", "high", ("--reasoning-effort", "default"), None),
                    ]):
                        record = root / f"attached-{index}.json"
                        receipt = invoke("session", "configure", "--store", store, "--record", record,
                                         "--key", f"preferences:attached:{index}", "--parent", parent,
                                         "--model", model, *flags)
                        captured = json.loads(record.read_text())["configuration"]
                        assert captured["parent"] == parent and captured["model"] == model, captured
                        assert "provider" not in captured and "workspace" not in captured, captured
                        expected_preferences = {"permission_mode": "bypass"}
                        if not flags:
                            expected_preferences["reasoning_effort"] = "max"
                        assert captured["preferences"] == expected_preferences, captured
                        if field == "omitted":
                            assert "effort" not in captured, captured
                        else:
                            assert "effort" in captured and captured["effort"] == field, captured
                        child = receipt["context"]["session"]
                        saved = inspect(child)
                        assert (saved["parent"], saved["provider"], saved["workspace"]) == (parent, "openai", str(workspace)), saved
                        check(saved, model, effort, "bypass")
                        changed = preferences.read_bytes()
                        preferences.write_text(changed.decode().replace("reasoning_effort=max", "reasoning_effort=low")
                                               .replace("permission_mode=bypass", "permission_mode=ask"))
                        replay = invoke("request", "recover", "--store", store, "--record", record, "--kind", "configure")
                        preferences.write_bytes(changed)
                        assert replay["answer"]["replayed"] is True and replay["context"]["session"] == child, replay
                        assert inspect(child) == saved
                finally:
                    preferences.write_bytes(original)

                records = config / "requests"
                for model, effort in (("gpt-5.5", "max"), ("gpt-6.1-sol", "low")):
                    before = set(records.glob("*.json"))
                    master, slave = open_pty()
                    caller = None
                    try:
                        caller = spawn([str(binary), "--store", store, "--provider", "openai", "--model", model],
                                       cwd=workspace, env=clean, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                        overview_frame(master, overview_title)
                        open_new_chat(master)
                        captured = set(records.glob("*.json")) - before
                        assert len(captured) == 1, captured
                        request = json.loads(captured.pop().read_text())
                        assert request["configuration"]["provider"] == "openai", request
                        assert request["configuration"]["model"] == model, request
                        assert request["configuration"]["preferences"] == {"reasoning_effort": "max", "permission_mode": "bypass"}, request
                        receipt = invoke("request", "recover", request["key"])
                        assert receipt["answer"]["replayed"] is True, receipt
                        check(inspect(receipt["context"]["session"]), model, effort, "bypass")
                        os.write(master, b"\x04")
                        _, errors = terminal_exit(caller, master)
                        assert caller.wait(timeout=5) == 0, errors
                    finally:
                        host_process.dispose_all(lambda: host_process.stop_process(caller, timeout=5) if caller else None,
                                                 lambda: close_pty(master), lambda: close_pty(slave))
            finally:
                close(host)
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=10)
    print("preferences bridge: CLI, terminal and TypeScript follow changed Host catalog and explicit settings")
