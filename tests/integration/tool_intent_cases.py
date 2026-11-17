"""Configured and loaded tool intent through Chat info and public inspection."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote

import live_engines
import model_fixture as fixture
from host_process import dispose_all, stop_process, wait_for
from human_cli_fixture import admit, terminal_exit
from overview_fixture import Screen, world
from settings_fixture import mcp_server
from terminal_process import close_pty, open_pty, register_capture, spawn


@contextmanager
def tool_store(engine, temporary):
    if engine == "sqlite":
        yield None
        return
    assert engine == "mysql", engine
    socket = os.environ.get(live_engines.MYSQL_SOCKET)
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    admin = os.environ.get("RUI_TEST_MYSQL_ADMIN")
    assert socket and password and admin, "MySQL tool intent requires the server and native SQL fixture"
    database = "rui_tool_intent_" + secrets.token_hex(6)

    def sql(text):
        return subprocess.run([admin], input=text, text=True, capture_output=True, check=True, timeout=30)

    sql(f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin")
    try:
        schema = subprocess.run([str(fixture.RUI), "store", "schema", "--engine", "mysql"],
                                text=True, capture_output=True, check=True, timeout=30).stdout
        sql(f"USE {database};" + schema)
        login = Path(temporary) / "mysql-login"
        login.write_text(f"mysql://root:{quote(password, safe='')}@{quote(socket, safe='')}/{database}")
        login.chmod(0o600)

        def configure(w):
            w.run("host", "set", "--store", w.store, "store.mysql.url", f"file:{login}")

        yield configure
    finally:
        dispose_all(lambda: sql(f"DROP DATABASE {database}"))


@contextmanager
def tool_world(prefix, engine="sqlite"):
    server = mcp_server(["lookup", "none"])
    try:
        with tempfile.TemporaryDirectory(prefix="rui-tool-token.") as temporary:
            token = Path(temporary) / "token"
            token.write_text("t")
            token.chmod(0o600)
            options = ("--set", f"tools.mcp.docs.url=http://127.0.0.1:{server.server_port}/mcp",
                       "--set", f"tools.mcp.docs.bearerToken=file:{token}")
            with tool_store(engine, temporary) as store_setup:
                with world(prefix + "-" + engine, host_options=options, store_setup=store_setup) as w:
                    if engine == "mysql":
                        status = json.loads(w.run("host", "status", "--store", w.store))
                        assert status["innodb_doublewrite"] is not None, ("MySQL Host observation", status)
                    yield w
    finally:
        dispose_all(server.shutdown, server.server_close)


@contextmanager
def resume(w, session, columns, rows):
    master, slave = open_pty(columns, rows)
    process = None
    try:
        process = spawn([str(fixture.RUI), "session", "resume", "--store", str(w.store), "--", session],
                        env=w.env, cwd=w.workspace, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        screen = Screen(process, master, columns, rows)
        register_capture(master, screen.capture)
        screen.wait(lambda frame: ("Type a task" in frame or "alt+i info" in frame) and "Opening…" not in frame,
                    "resumed Session composer with Chat info available")
        yield screen
        screen.keys(b"\x03")
        _, errors = terminal_exit(process, master)
        assert process.returncode == 0, errors
    finally:
        dispose_all(lambda: stop_process(process, timeout=5) if process is not None else None,
                    lambda: close_pty(master), lambda: close_pty(slave))


def retain_frame(name, frame):
    artifacts = os.environ.get("RUI_FAILURE_ARTIFACTS")
    if artifacts:
        directory = Path(artifacts) / "tool-intent-screens"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / (name + ".txt")).write_text(frame + "\n")


def picker_open(screen, *, capture_prefix=None, tools_focused=False):
    screen.keys(b"\x1bi")
    info = screen.wait(lambda frame: "Copy last answer" in frame and "unavailable" not in frame,
                       "Chat info loaded")
    if capture_prefix:
        retain_frame(capture_prefix + "-chat-info", info)
    screen.keys(b"\r" if tools_focused else b"\x1b[B\x1b[B\r")
    picker = screen.wait(lambda frame: "web search" in frame and "read_transcript" in frame,
                         "built-in tool choices")
    if capture_prefix:
        retain_frame(capture_prefix + "-picker", picker)
    return picker


def picker_close(screen, *, cancel=False):
    screen.keys(b"\x1b" if cancel else b"\r")
    return screen.wait(lambda frame: "Copy last answer" in frame and "read_transcript" not in frame
                       and "saving" not in frame, "tool choices settled")


def inspect_intent(w, session, allowed, loaded, *, revision=None):
    current = w.inspect(session)["session"]
    assert current["tools"] == sorted(allowed), ("configured allowed tools", allowed, current)
    assert current["loaded_tools"] == sorted(loaded), ("configured loaded tools", loaded, current)
    if revision is not None:
        assert current["revision"] == revision, ("unchanged revision", revision, current)
    full = json.loads(w.run("session", "inspect", "--store", w.store, "--session", session,
                            "--profile", "full"))
    assert full["session"] == current, ("Current/Full inspection agreement", current, full)
    latest = full["full"]["session_revisions"][-1]
    assert latest["tools"] == current["tools"] and latest["loaded_tools"] == current["loaded_tools"], full
    return current


def assert_reachability_refusal(w, screen, session, allowed, loaded, revision, previous_handles, capture_name):
    handles = set(json.loads(w.run("request", "list"))) - previous_handles
    assert len(handles) == 1, ("one saved UI Configure", handles)
    handle, = handles
    def settled():
        observed = json.loads(w.run("request", "inspect", handle))["observation"]
        return observed if observed["status"] in ("accepted", "rejected", "conflict") else None
    observed = wait_for(settled, "the saved UI Configure admission")
    assert observed["status"] == "rejected" and observed["kind"] == "configure", observed
    assert observed["code"] == "loaded_tools_unreachable", observed
    screen.contains("couldn't save")
    screen.keys(b"\x1b")
    repair_words = ("reachable", "find_tools", "--loaded-tools", "--tools")
    diagnostic = screen.wait(lambda frame: "Copy last answer" not in frame
                             and "[loaded_tools_unreachable]" in frame
                             and all(word in " ".join(frame.split()) for word in repair_words),
                             "reachability cause and repair in the actual TUI inspection page")
    retain_frame(capture_name + "-reachability-inspection", diagnostic)
    inspect_intent(w, session, allowed, loaded, revision=revision)
    replay = subprocess.run([str(fixture.RUI), "request", "recover", handle], env=w.env, cwd=w.workspace,
                            text=True, capture_output=True, timeout=20)
    assert replay.returncode == 3, replay
    answer = json.loads(replay.stdout)["answer"]
    assert answer["status"] == "rejected" and answer["replayed"] is True, answer
    assert answer["code"] == observed["code"], (answer, observed)
    assert "[loaded_tools_unreachable]" in replay.stderr, replay.stderr
    assert all(word in replay.stderr for word in repair_words), replay.stderr
    inspect_intent(w, session, allowed, loaded, revision=revision)


def edit_cases(columns, rows, *, engine="sqlite", cases=("noop", "cancel", "toggle", "add", "none", "specifications", "refusal", "add-refusal", "empty-enable-refusal")):
    with tool_world(f"tool-intent-{columns}", engine) as w:
        allowed, loaded = ["bash", "find_tools", "lookup"], ["find_tools", "lookup"]
        for action in ("noop", "cancel", "toggle", "add"):
            if action not in cases:
                continue
            session = w.session("--tools", ",".join(allowed), "--loaded-tools", ",".join(loaded))
            before = inspect_intent(w, session, allowed, loaded)
            with resume(w, session, columns, rows) as screen:
                picker_open(screen, capture_prefix=f"{engine}-{columns}" if action == "noop" else None)
                if action == "add":
                    screen.keys(b"\x1b[B\x1b[B ")
                    screen.wait(lambda frame: "read_transcript" in frame and "✓ message_agent" in frame,
                                "message_agent added to the allowed draft")
                elif action != "noop":
                    screen.keys(b" ")
                    screen.wait(lambda frame: "read_transcript" in frame and "✓ bash" not in frame,
                                "bash unchecked in the draft")
                picker_close(screen, cancel=action == "cancel")
                if action != "cancel":
                    wait_for(lambda: w.inspect(session)["session"]["revision"] != before["revision"],
                             "tool edit admission")
                expected = (["find_tools", "lookup"] if action == "toggle" else
                            allowed + ["message_agent"] if action == "add" else allowed)
                inspect_intent(w, session, expected, loaded,
                               revision=before["revision"] if action == "cancel" else None)
            print(f"tool intent {engine} {columns}: {action} preserves arbitrary allowed and loaded tools", flush=True)

        if "none" in cases:
            session = w.session("--tools", "bash,none", "--loaded-tools", "bash,none")
            before = inspect_intent(w, session, ["bash", "none"], ["bash", "none"])
            with resume(w, session, columns, rows) as screen:
                picker_open(screen)
                screen.keys(b" ")
                screen.wait(lambda frame: "read_transcript" in frame and "✓ bash" not in frame,
                            "bash unchecked leaving MCP none")
                picker_close(screen)
                wait_for(lambda: w.inspect(session)["session"]["revision"] != before["revision"],
                         "singleton MCP tool admission")
                inspect_intent(w, session, ["none"], ["none"])
            print(f"tool intent {engine} {columns}: a singleton MCP named none survives save", flush=True)

        if "specifications" in cases:
            for specification, names in (("none", []), ("bash", ["bash"])):
                session = w.session("--tools", specification, "--loaded-tools", specification)
                before = inspect_intent(w, session, names, names)
                with resume(w, session, columns, rows) as screen:
                    picker_open(screen)
                    picker_close(screen)
                    wait_for(lambda: w.inspect(session)["session"]["revision"] != before["revision"],
                             "explicit tool specification admission")
                    inspect_intent(w, session, names, names)
            print(f"tool intent {engine} {columns}: explicit empty and restricted CLI specifications survive resume", flush=True)

        if "refusal" in cases:
            allowed, loaded = ["bash", "find_tools", "lookup"], ["bash", "find_tools"]
            session = w.session("--tools", ",".join(allowed), "--loaded-tools", ",".join(loaded))
            before = inspect_intent(w, session, allowed, loaded)
            with resume(w, session, columns, rows) as screen:
                picker_open(screen)
                screen.keys(b"\x1b[B ")
                screen.wait(lambda frame: "read_transcript" in frame and "✓ find_tools" not in frame,
                            "find_tools unchecked with an unloaded MCP tool")
                handles = set(json.loads(w.run("request", "list")))
                picker_close(screen)
                assert_reachability_refusal(w, screen, session, allowed, loaded, before["revision"], handles,
                                            f"{engine}-{columns}-remove-find-tools")
                # Chat info retains the Allowed tools focus after a rejected save.
                picker_open(screen, tools_focused=True)
                screen.wait(lambda frame: "✓ find_tools" in frame and "read_transcript" in frame,
                            "rejected edit reopened from saved intent")
                picker_close(screen)
                wait_for(lambda: w.inspect(session)["session"]["revision"] != before["revision"],
                         "valid retry admission after refusal")
                inspect_intent(w, session, allowed, loaded)
                assert "couldn't save" not in screen.text, screen.text
            print(f"tool intent {engine} {columns}: unreachable MCP intent is refused and a valid retry recovers", flush=True)


        for action, specification, names, keys, marker in (
            ("add-refusal", "bash", ["bash"], b"\x1b[B\x1b[B ", "✓ message_agent"),
            ("empty-enable-refusal", "none", [], b" ", "✓ bash"),
        ):
            if action not in cases:
                continue
            session = w.session("--tools", specification, "--loaded-tools", specification)
            before = inspect_intent(w, session, names, names)
            with resume(w, session, columns, rows) as screen:
                picker_open(screen)
                screen.keys(keys)
                screen.wait(lambda frame: "read_transcript" in frame and marker in frame,
                            "builtin enabled without a loaded find_tools")
                handles = set(json.loads(w.run("request", "list")))
                picker_close(screen)
                assert_reachability_refusal(w, screen, session, names, names, before["revision"], handles,
                                            f"{engine}-{columns}-{action}")
            print(f"tool intent {engine} {columns}: {action} explains reachability without widening loaded tools", flush=True)



def model_operations(w, session):
    report = json.loads(w.run("session", "inspect", "--store", w.store, "--session", session,
                              "--profile", "full"))
    return report["full"]["model_operations"]


def offered_names(request):
    return sorted(tool["name"] for item in request["input"] if item.get("type") == "additional_tools"
                  for tool in item["tools"])


def frozen_offer_case(engine="sqlite"):
    release = threading.Event()
    with tool_world("tool-intent-frozen", engine) as w:
        try:
            w.endpoint.responses_by_input = None
            arguments = json.dumps({"cmd": "printf frozen-offer > frozen-offer", "description": "Record frozen offer",
                                    "timeout_ms": None})
            removed_arguments = json.dumps({"cmd": "printf widened > widened-offer", "description": "Try removed Bash",
                                            "timeout_ms": None})
            w.endpoint.responses = [
                (fixture.sse_tool_calls("frozen", [("bash", "frozen-call", arguments)]), release),
                fixture.sse_tool_calls("removed", [("bash", "removed-call", removed_arguments)]),
                fixture.sse_answer("next", "reason-next", "message-next", "NEXT-ANSWER")[0],
            ]
            session = w.session("--tools", "bash,lookup", "--loaded-tools", "bash,lookup",
                                "--permission-mode", "bypass")
            first = admit(w.home, "session", "send", "--store", w.store, "--to", session, input="first")
            wait_for(lambda: len(w.endpoint.requests) == 1, "the held operation's provider request")
            original = w.endpoint.requests[0]
            assert offered_names(json.loads(original)) == ["bash", "lookup"], original
            before = w.inspect(session)["session"]
            operations = model_operations(w, session)
            assert len(operations) == 1, operations
            frozen = operations[0]
            assert "offered_tools" in frozen, ("Full must expose the operation-frozen effective offer", frozen)
            assert frozen["offered_tools"] == ["bash", "lookup"], frozen
            assert frozen["settings_revision"] == before["revision"], (frozen, before)
            with resume(w, session, 140, 40) as screen:
                picker_open(screen)
                screen.keys(b" ")
                screen.wait(lambda frame: "read_transcript" in frame and "✓ bash" not in frame,
                            "bash unchecked during the operation")
                picker_close(screen)
                wait_for(lambda: w.inspect(session)["session"]["revision"] != before["revision"],
                         "configuration changed during the operation")
                edited = inspect_intent(w, session, ["lookup"], ["lookup"])
                held = model_operations(w, session)
                assert len(held) == 1 and held[0]["offered_tools"] == frozen["offered_tools"], held
                assert held[0]["settings_revision"] == frozen["settings_revision"], held
                assert w.endpoint.requests == [original], "editing retransmitted or rewrote the held request"
                release.set()
                _, answer, _ = fixture.wait_for_result_release(w.store, first["request"], session, time.monotonic() + 15)
                assert answer == b"NEXT-ANSWER", answer
                assert (w.workspace / "frozen-offer").read_text() == "frozen-offer", "the original offered Bash call was rejected"
                assert len(w.endpoint.requests) == 3, w.endpoint.requests
                continuation = json.loads(w.endpoint.requests[1])
                # Historical additional_tools declarations retain the immutable provider prefix.
                outputs = [item for item in continuation["input"] if item.get("type") == "function_call_output"]
                assert len(outputs) == 1 and outputs[0]["call_id"] == "frozen-call", outputs
                final_request = json.loads(w.endpoint.requests[2])
                removed = [item for item in final_request["input"] if item.get("type") == "function_call_output"
                           and item["call_id"] == "removed-call"]
                assert len(removed) == 1 and removed[0]["output"] == "This tool was removed.", removed
                assert not (w.workspace / "widened-offer").exists(), "the new operation executed removed Bash"
                assert w.endpoint.requests[0] == original, "configuration changed the original operation offer"
                resolved = model_operations(w, session)
                assert len(resolved) == 3, resolved
                assert [operation["offered_tools"] for operation in resolved] == [["bash", "lookup"], ["lookup"], ["lookup"]], resolved
                assert [operation["settings_revision"] for operation in resolved] == [before["revision"], edited["revision"], edited["revision"]], resolved
            print(f"tool intent {engine}: a held operation keeps its offer; the next operation uses the edited intent", flush=True)
        finally:
            release.set()


def main():
    engines = ["sqlite"]
    required = os.environ.get(live_engines.REQUIRE, "").split(",")
    mysql = os.environ.get(live_engines.MYSQL_SOCKET)
    if mysql or "mysql" in required:
        engines.append("mysql")
    for engine in engines:
        for columns, rows in ((140, 40), (46, 30)):
            edit_cases(columns, rows, engine=engine)
        frozen_offer_case(engine)
