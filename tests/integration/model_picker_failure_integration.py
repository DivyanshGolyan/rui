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
from human_cli_fixture import overview_frame, overview_title, read_terminal, terminal_exit
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
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        filtered = overview_frame(master, lambda screen: "gpt-5.6-luna" in screen and "gpt-6-luna" in screen,
                                  b"/model luna")
        assert "/model luna" in filtered, filtered
        moved = overview_frame(master, lambda screen: any(
            "gpt-6-luna" in row and "‹" in row for row in screen.splitlines()), b"\x1b[B")
        assert "/model luna" in moved, moved
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        caller = None
        close_pty(master)
        close_pty(slave)
        master = slave = None

        master, slave = open_pty(columns=120, rows=24)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        overview_frame(master, lambda screen: "gpt-6-luna" in screen, b"/model luna")
        preferences = config / "preferences"
        original = preferences.read_bytes()
        preferences.write_bytes(b"version=1\n")
        overview_frame(master, lambda screen: any(
            "gpt-6-luna" in row and "‹" in row for row in screen.splitlines()), b"\x1b[B")
        overview_frame(master, lambda screen: any(
            "gpt-6-luna" in row and "‹ medium ›" in row for row in screen.splitlines()), b"\x1b[C")
        failed = overview_frame(master, lambda screen: "Default not saved" in screen, b"\r")
        assert "new Sessions here still use gpt-6-luna · medium · ChatGPT" in failed, failed
        assert "new Session · gpt-6-luna · medium" in failed, failed
        assert preferences.read_bytes() == b"version=1\n"
        preferences.write_bytes(original)

        os.write(master, b"hello\r")
        read_terminal(master, "› ")

        def created_session():
            rows = json.loads(cli("session", "list", "--store", store, "--all"))["sessions"]
            return rows[0]["reference"] if len(rows) == 1 else None

        session = host_process.wait_for(created_session, "Session after failed save")
        settings = json.loads(cli("session", "inspect", "--store", store, "--session", session))["session"]
        assert settings["model"] == "gpt-6-luna" and settings["reasoning_effort"] == "medium", settings
        saved = json.loads(cli("defaults", "inspect"))
        assert saved["model"] == "gpt-5.5", saved
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("model picker: narrow navigation and failed-save Session recovery passed", flush=True)
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
            host_process.retain_failure_state("model picker failure state", state)


if __name__ == "__main__":
    host_process.enter()
    main()
