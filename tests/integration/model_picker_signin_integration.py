#!/usr/bin/env python3
"""Switch a model's sign-in and save it through the plain terminal."""
import json
import os
import shutil
import subprocess
import threading

import codex_fixture
import host_process
import model_fixture as fixture
from human_cli_fixture import keyed_frame, overview_frame, overview_title, terminal_exit
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

        master, slave = open_pty(columns=80, rows=24)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        for initial, target, provider in (("ChatGPT", "API key", "openai"),
                                          ("API key", "ChatGPT", "codex")):
            def row_has(screen, sign_in):
                return any("gpt-6-luna" in row and "‹" in row and f"[{sign_in}]" in row
                           for row in screen.splitlines())

            shown = overview_frame(master, lambda screen, initial=initial: row_has(screen, initial), b"/model gpt-6-luna")
            assert "/model gpt-6-luna" in shown, shown
            switched = overview_frame(master, lambda screen, target=target: row_has(screen, target), b"\t")
            assert "/model gpt-6-luna" in switched, switched
            selected = keyed_frame(master, b"\r", lambda screen, x, y, target=target:
                                   "gpt-6-luna" in screen and target in screen and "/model" not in screen)
            assert target in selected, selected
            host_process.wait_for(lambda provider=provider: saved(provider), f"{target} model default saved")

        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        assert endpoint.requests == [], endpoint.requests
        completed = True
        print("model picker: Tab switches both sign-ins and one Enter saves each default", flush=True)
    finally:
        host_process.dispose_all(
            lambda: host_process.stop_process(caller, timeout=5) if caller else None,
            lambda: close_pty(master) if master is not None else None,
            lambda: close_pty(slave) if slave is not None else None,
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
