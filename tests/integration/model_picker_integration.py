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
from product_defaults import CATALOG
from human_cli_fixture import (AppModelCatalog, app_model_open, assert_chat_info_layout, assert_model_choice, chat_info_open, model_choice_frame, model_choice_shown, panel_frame, overview_frame,
                               overview_title, read_terminal, terminal_exit)
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
    catalog = None
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
        catalog = AppModelCatalog(host)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        opened = app_model_open(master, catalog=catalog)
        assert any("Sign-in" in row and "Codex" in row for row in opened.splitlines()), opened
        full = assert_model_choice(opened, query="", more=True)
        filtered = model_choice_frame(master, b"luna", query="luna", more=False)
        narrow = assert_model_choice(filtered, query="luna", more=False)
        assert len(narrow["matches"]) == 2 < len(full["matches"]), filtered
        effort_row = next(index for index, row in enumerate(narrow["rows"]) if row.startswith("   Effort"))
        assert effort_row == narrow["matches"][-1][0] + 1, ("list shrinks without blank placeholders", filtered)
        rows = filtered.splitlines()
        first = next(row for row in rows if "gpt-5.6-luna" in row)
        second = next(row for row in rows if "gpt-6-luna" in row)
        assert rows.index(first) < rows.index(second), filtered
        model_choice_frame(master, b"\x1b[B", query="luna", more=False)
        selected = panel_frame(master, lambda screen: not model_choice_shown(screen) and
                               "gpt-6-luna" in screen and "saving" not in screen, b"\r")
        assert "Model" in selected, selected
        # Effort is a separate setting, not a model-row keyboard submode.
        panel_frame(master, lambda screen: "model default" in screen, b"\x1b[B\r")
        panel_frame(master, lambda screen: not model_choice_shown(screen) and "saving" not in screen
                    and any("Effort" in row and "medium" in row for row in screen.splitlines()),
                    b"\x1b[B" * (1 + CATALOG["gpt-6-luna"].efforts.index("medium")) + b"\r")
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
        catalog = AppModelCatalog(host)
        caller = spawn([str(fixture.RUI), "--store", str(store)], cwd=state,
                       env={**env, "LC_ALL": "C"}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        overview_frame(master, overview_title)
        ascii_frame = app_model_open(master, b"luna", catalog=catalog)
        assert "gpt-6-luna" in ascii_frame, ascii_frame
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
        session_model = chat_info_open(master)
        assert "gpt-5.5" in session_model and "Folder" in session_model, session_model
        assert_chat_info_layout(session_model, context=False)
        choice = model_choice_frame(master, b"\x1b[B\x1b[B\x1b[B\r", query="")
        assert "gpt-5.5" in choice and "Known to Rui" not in choice, choice
        assert_chat_info_layout(choice, context=False)
        model_choice_frame(master, b"luna", query="luna", more=False)
        panel_frame(master, lambda screen: not model_choice_shown(screen) and "gpt-6-luna" in screen
                    and "saving" not in screen, b"\x1b[B\r")
        inspected = subprocess.run([str(fixture.RUI), "session", "inspect", "--store", str(store),
                                    "--session", session], env=env, capture_output=True, text=True, timeout=20)
        assert inspected.returncode == 0, inspected.stderr
        saved_session = json.loads(inspected.stdout)["session"]
        assert saved_session["model"] == "gpt-6-luna" and saved_session["provider"] == "codex", inspected.stdout
        host_process.wait_for(saved_model, "chat model change leaves overview default unchanged")
        panel_frame(master, lambda screen: "Copy last answer" not in screen, b"\x1b")
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("model picker: filtering, navigation, effort, one-Enter save, separate effort and chat model save passed", flush=True)
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
