#!/usr/bin/env python3
"""Model picker narrow-screen and failed-save behavior on a real PTY."""
import json
import os
import shutil
import subprocess
import threading

import codex_fixture
import host_process
import model_fixture as fixture
from human_cli_fixture import AppModelCatalog, app_model_open, model_choice_frame, model_choice_shown, panel_frame, overview_frame, overview_title, read_terminal, terminal_exit
from terminal_process import close_pty, open_pty, spawn


def main():
    state = host_process.screen_fixture_root("rui-model-picker-failure.")
    home = state / "home"
    config = home / ".config/rui"
    config.mkdir(parents=True, mode=0o700)
    codex_fixture.credentials(config / "codex.json")
    store = state / "store"
    endpoint = fixture.SuccessEndpoint([fixture.sse_answer("picker", "response", "message", "Hello")[0]])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = None
    catalog = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        env = {**os.environ, "HOME": str(home)}

        def cli(*args):
            result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env,
                                    cwd=state, capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, (args, result.stdout, result.stderr)
            return result.stdout

        cli("defaults", "configure", "--store", store, "--provider", "codex", "--model", "gpt-5.5")
        master, slave = open_pty(columns=50, rows=12)
        catalog = AppModelCatalog(host)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        filtered = app_model_open(master, b"luna", catalog=catalog)
        assert "gpt-5.6-luna" in filtered and "gpt-6-luna" in filtered, filtered
        moved = model_choice_frame(master, b"\x1b[B", query="luna", more=False)
        assert len(moved.splitlines()) == 12, moved
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        caller = None
        close_pty(master)
        close_pty(slave)
        master = slave = None

        # Keep 120 columns for the compose pane; the notice fits before its keys.
        master, slave = open_pty(columns=161, rows=24)
        catalog = AppModelCatalog(host)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        app_model_open(master, b"luna", catalog=catalog)
        preferences = config / "preferences"
        original = preferences.read_bytes()
        preferences.write_bytes(b"version=1\n")
        model_choice_frame(master, b"\x1b[B", query="luna", more=False)
        failed = panel_frame(master, lambda screen: "couldn't save" in screen, b"\r")
        assert "Model" in failed, failed
        assert preferences.read_bytes() == b"version=1\n"
        preferences.write_bytes(original)
        # A failed panel save must not change the next Session's defaults.
        panel_frame(master, lambda screen: "Rui · settings" not in screen, b"\x1b")
        os.write(master, b"hello\r")
        read_terminal(master, "› ")

        def created_session():
            rows = json.loads(cli("session", "list", "--store", store, "--all"))["sessions"]
            return rows[0]["reference"] if len(rows) == 1 else None

        session = host_process.wait_for(created_session, "Session after failed save")
        settings = json.loads(cli("session", "inspect", "--store", store, "--session", session))["session"]
        assert settings["model"] == "gpt-5.5", settings
        saved = json.loads(cli("defaults", "inspect"))
        assert saved["model"] == "gpt-5.5", saved
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("model picker: narrow navigation and failed-save default isolation passed", flush=True)
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
            host_process.retain_failure_state("model picker failure state", state)


if __name__ == "__main__":
    host_process.enter()
    main()
