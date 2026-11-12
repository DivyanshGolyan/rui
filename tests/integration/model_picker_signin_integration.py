#!/usr/bin/env python3
"""Save a model for each sign-in through the app settings Model field."""
import json
import os
import shutil
import subprocess
import threading

import codex_fixture
import host_process
import model_fixture as fixture
from human_cli_fixture import AppModelCatalog, app_model_open, model_choice_frame, model_choice_shown, panel_frame, overview_frame, overview_title, terminal_exit
from terminal_process import close_pty, open_pty, spawn


def main():
    state = host_process.screen_fixture_root("rui-model-signin.")
    home = state / "home"
    config = home / ".config/rui"
    config.mkdir(parents=True, mode=0o700)
    codex_fixture.credentials(config / "codex.json")
    key = config / "openai.key"
    key.write_text("fixture-provider-choice-key\n")
    key.chmod(0o600)
    store = state / "store"
    env = {**os.environ, "HOME": str(home)}
    endpoint = fixture.SuccessEndpoint([])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = None
    catalog = None
    master = slave = None
    completed = False
    try:
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        host, _ = host_process.start_ready_process(
            [fixture.RUI, "host", "serve", "--store", store,
             "--test-codex-fixture-endpoint", url, "--test-openai-fixture-endpoint", url],
            env={**env, "RUI_OPENAI_KEY_FILE": str(key),
                 "RUI_CODEX_CREDENTIAL_FILE": str(config / "codex.json")},
            required_fields={"execution": "enabled", "nghttp2": "1.70.0"})
        configured = subprocess.run(
            [str(fixture.RUI), "defaults", "configure", "--store", str(store),
             "--provider", "codex", "--model", "gpt-5.5"],
            env=env, capture_output=True, text=True, timeout=20, check=False)
        assert configured.returncode == 0, configured.stderr

        def saved(provider):
            result = subprocess.run([str(fixture.RUI), "defaults", "inspect"], env=env,
                                    capture_output=True, text=True, timeout=20, check=False)
            assert result.returncode == 0, result.stderr
            value = json.loads(result.stdout)
            return value["provider"] == provider and value["model"] == "gpt-6-luna"

        # Sign-in's screen is not implemented yet. Keep both providers' native
        # Model-field persistence coverage with the retained CLI configure path.
        for sign_in, provider in (("API key", "openai"), ("ChatGPT", "codex")):
            changed = subprocess.run(
                [str(fixture.RUI), "defaults", "configure", "--store", str(store),
                 "--provider", provider, "--model", "gpt-5.5"],
                env=env, capture_output=True, text=True, timeout=20, check=False)
            assert changed.returncode == 0, changed.stderr
            master, slave = open_pty(columns=80, rows=24)
            catalog = AppModelCatalog(host)
            caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                           env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            overview_frame(master, overview_title)
            app_model_open(master, b"gpt-6-luna", catalog=catalog)
            selected = panel_frame(master, lambda screen: not model_choice_shown(screen) and "saving" not in screen
                                   and any("Model" in row and "gpt-6-luna" in row for row in screen.splitlines()), b"\r")
            assert any("Sign-in" in row and sign_in in row for row in selected.splitlines()), selected
            host_process.wait_for(lambda provider=provider: saved(provider), f"{sign_in} model default saved")
            os.write(master, b"\x03")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0, errors
            caller = None
            close_pty(master)
            close_pty(slave)
            master = slave = None
        assert endpoint.requests == [], endpoint.requests
        completed = True
        print("model picker: Model field saves each configured sign-in without switching provider", flush=True)
    finally:
        host_process.dispose_all(
            lambda: host_process.stop_process(caller, timeout=5) if caller else None,
            lambda: close_pty(master) if master is not None else None,
            lambda: close_pty(slave) if slave is not None else None,
            lambda: catalog.close() if catalog else None,
            lambda: fixture.stop_host(host) if host else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            host_process.retain_failure_state("model sign-in failure state", state)


if __name__ == "__main__":
    host_process.enter()
    main()
