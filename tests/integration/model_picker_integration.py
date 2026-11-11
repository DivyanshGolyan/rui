#!/usr/bin/env python3
"""The model picker through a real PTY and committed terminal frames."""
import json
import os
import shutil
import subprocess
import threading

import codex_fixture
import host_process
import model_fixture as fixture
from human_cli_fixture import command_frame, overview_frame, overview_title, read_terminal, terminal_exit
from terminal_process import close_pty, open_pty, spawn


def main():
    state = host_process.screen_fixture_root("rui-model-picker.")
    home = state / "home"
    config = home / ".config/rui"
    config.mkdir(parents=True, mode=0o700)
    codex_fixture.credentials(config / "codex.json")
    store = state / "store"
    endpoint = fixture.SuccessEndpoint([])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        env = {**os.environ, "HOME": str(home)}
        configured = subprocess.run(
            [str(fixture.RUI), "defaults", "configure", "--store", str(store),
             "--provider", "codex", "--model", "gpt-5.5"],
            env=env, capture_output=True, text=True, timeout=20,
        )
        assert configured.returncode == 0, configured.stderr
        master, slave = open_pty(columns=80, rows=24)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        overview_frame(master, lambda screen: "/model" in screen, b"/m")
        overview_frame(master, lambda screen: "/model" in screen and any(
            "gpt-5.5" in row and "‹" in row for row in screen.splitlines()), b"\r")
        filtered = overview_frame(master, lambda screen: "gpt-6-luna" in screen,
                                  b"luna")
        assert "/model luna" in filtered, filtered
        rows = filtered.splitlines()
        first = next(row for row in rows if "gpt-5.6-luna" in row)
        second = next(row for row in rows if "gpt-6-luna" in row)
        assert rows.index(first) < rows.index(second) and "‹" in first and "‹" not in second, filtered
        moved = overview_frame(master, lambda screen: any(
            "gpt-6-luna" in row and "‹" in row for row in screen.splitlines()), b"\x1b[B")
        assert "/model luna" in moved, moved
        changed = overview_frame(master, lambda screen: any(
            "gpt-6-luna" in row and "‹ medium ›" in row for row in screen.splitlines()), b"\x1b[C")
        assert "/model luna" in changed, changed
        selected = overview_frame(master, lambda screen: "gpt-6-luna · medium" in screen and "/model" not in screen,
                                  b"\r")
        assert "gpt-6-luna · medium" in selected, selected
        def saved_model():
            saved = subprocess.run([str(fixture.RUI), "defaults", "inspect"], env=env,
                                   capture_output=True, text=True, timeout=20)
            assert saved.returncode == 0, saved.stderr
            value = json.loads(saved.stdout)
            return value["model"] == "gpt-6-luna" and value["reasoning_effort"] == "medium"

        host_process.wait_for(saved_model, "model default saved")
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        caller = None
        close_pty(master)
        close_pty(slave)
        master = slave = None

        master, slave = open_pty(columns=80, rows=24)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env={**env, "LC_ALL": "C"}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        ascii_frame = overview_frame(master, lambda screen: any(
            "+  gpt-6-luna" in row and "< medium >" in row for row in screen.splitlines()), b"/model luna")
        assert ascii_frame.isascii(), ascii_frame
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        caller = None
        close_pty(master)
        close_pty(slave)
        master = slave = None

        created = subprocess.run(
            [str(fixture.RUI), "session", "configure", "--store", str(store),
             "--workspace", str(state), "--provider", "codex", "--model", "gpt-5.5"],
            env=env, capture_output=True, text=True, timeout=20,
        )
        assert created.returncode == 0, created.stderr
        session = json.loads(created.stdout)["answer"]["session"]
        master, slave = open_pty(columns=80, rows=24)
        caller = spawn([str(fixture.RUI), "session", "resume", "--store", str(store), session],
                       cwd=state, env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        read_terminal(master, "› ")
        session_model = command_frame(master, "/model", lambda screen: "new Session: /model in overview" in screen)
        assert "gpt-5.5" in session_model and "ChatGPT" in session_model, session_model
        assert "Known to Rui" not in session_model, session_model
        host_process.wait_for(saved_model, "overview default remains unchanged")
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("model picker: filtering, navigation, effort, one-Enter save, facts and read-only Session passed", flush=True)
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
