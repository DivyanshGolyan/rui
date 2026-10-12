#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import errno
import json
import fcntl
import os
import pathlib
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

from host_process import canonical_fixture_root, preserve_failure_metadata
import dispatch_integration as fixture
import codex_integration as codex_fixture


def run(home, *args, success=True, environment=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


def admit(home, *args):
    captured, admission = map(json.loads, run(home, *args, "--json").splitlines())
    assert captured == {"event": "captured", "request": admission["request"]}, (captured, admission)
    assert admission["event"] == "admission", admission
    return admission


def preference_edits(home, store):
    """Exact saved intent, independent of prospective recommendation output."""
    run(home, "setup", "--store", store, "--provider", "codex", "--model", "gpt-6-luna")
    saved = home / ".config/rui/preferences"
    pinned = f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
    cleared = f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=\n"
    assert saved.read_text() == pinned
    run(home, "setup", "--store", store)
    assert saved.read_text() == pinned, "omitted model lost its selection"
    assert "Model: not selected" in run(home, "setup", "--clear-model")
    assert saved.read_text() == cleared, "clear persisted a recommendation or retained the model"
    run(home, "setup")
    assert saved.read_text() == cleared, "inspection persisted a recommendation"
    for flags in (("--clear-model", "--model", "gpt-6-luna"),
                  ("--model", "gpt-6-luna", "--clear-model"), ("--model", "")):
        run(home, "setup", *flags, success=False)
        assert saved.read_text() == cleared, "rejected edit changed preferences"
    saved.write_text(pinned.replace("provider=codex", "provider=retired").replace("gpt-6-luna", "old-model"))
    run(home, "setup", "--clear-model")
    assert saved.read_text() == cleared.replace("provider=codex", "provider=retired")
    assert "saved provider is unsupported; no fallback" in run(home, "setup")
    run(home, "setup", "--provider", "codex", "--clear-model")
    assert saved.read_text() == cleared
    run(home, "setup", "--model", "gpt-6-luna")
    assert saved.read_text() == pinned


def read_terminal(master, marker, timeout=15, preserve_colour=False, *, composer=False):
    output = b""
    deadline = time.monotonic() + timeout
    # Foreground styling is orthogonal to text/Markdown assertions. A transcript
    # User shares the › marker, so an empty-composer wait also needs its final
    # cursor placement, not merely the first saved User encountered on opening.
    def visible():
        return re.sub(rb"\x1b\[(?:33|39|90|91|94)m", b"", output)
    def reached():
        shown = visible()
        if marker != "› ":
            if marker.encode() not in shown: return False
            if not composer: return True
            shown = shown.split(marker.encode(), 1)[1]
        return re.search("› [^\\r\\n]*(?:\\r\\n> [^\\r\\n]*)*(?:\\x1b\\[[0-9]+A)?\\r\\x1b\\[[0-9]+C".encode(), shown) is not None
    while not reached():
        remaining = deadline - time.monotonic()
        assert remaining > 0, (marker, output.decode(errors="replace"))
        assert select.select([master], [], [], remaining)[0], (marker, output.decode(errors="replace"))
        output += os.read(master, 65536)
        assert len(output) < 1024 * 1024, "unexpected unbounded terminal output"
    return ((output if preserve_colour else visible()).decode(errors="replace").replace("\r\n", "\n")
        .replace("\x1b[?2004h", "").replace("\x1b[?2004l", ""))


def assert_permission_workspace(output, workspace, columns=80):
    """Join only hanging-indent layout breaks; retain every exact path byte."""
    shown = output.split("\n  Workspace: ", 1)[1].split("\n  Time limit:", 1)[0]
    assert shown.replace("\n  ", "") == str(workspace), output
    assert all(len(line) <= columns for line in ("  Workspace: " + shown).splitlines()), output


def terminal_exit(caller, master, timeout=5):
    """Own both output streams until exit, including a late rendering prefix."""
    errors_fd = caller.stderr.fileno()
    streams = {master: bytearray(), errors_fd: bytearray()}
    pending = set(streams)
    deadline = time.monotonic() + timeout
    while True:
        exited = caller.poll() is not None
        remaining = deadline - time.monotonic()
        assert remaining > 0, ("terminal exit timeout", bytes(streams[master]), bytes(streams[errors_fd]))
        ready = select.select(list(pending), [], [], 0 if exited else min(remaining, 0.1))[0]
        if exited and not ready:
            caller.stderr.close()
            return bytes(streams[master]), bytes(streams[errors_fd])
        for fd in ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                chunk = b""
            if chunk:
                streams[fd].extend(chunk)
                assert sum(map(len, streams.values())) < 1024 * 1024, "unexpected unbounded terminal output"
            else:
                pending.remove(fd)


def terminal_gate(caller, master, reached, context, timeout=10):
    """Own startup output until the public metadata gate, not a silent wait."""
    errors_fd = caller.stderr.fileno()
    streams = {master: bytearray(), errors_fd: bytearray()}
    pending = set(streams)
    deadline = time.monotonic() + timeout
    while not reached.is_set():
        remaining = max(0, deadline - time.monotonic())
        for fd in select.select(list(pending), [], [], min(0.1, remaining))[0]:
            try:
                data = os.read(fd, 65536)
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                data = b""
            if data:
                streams[fd].extend(data)
                assert sum(map(len, streams.values())) < 1024 * 1024, "unexpected unbounded startup output"
            else:
                pending.remove(fd)
        assert reached.is_set() or (caller.poll() is None and time.monotonic() < deadline), (
            "terminal metadata gate not reached", context, caller.poll(),
            bytes(streams[master]), bytes(streams[errors_fd]))
    assert not streams[errors_fd], (context, bytes(streams[errors_fd]))
    return bytes(streams[master])


def terminal_step(master, command, marker="› ", *, composer=False):
    os.write(master, (command + "\n").encode())
    return read_terminal(master, marker, composer=composer)


def command_entry_cases():
    """Familiar entry routes use the same captured intent and conversation."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-command-entry."))
    home = state / "home"
    (home / ".config/rui").mkdir(parents=True, mode=0o700)
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    codex_fixture.credentials(home / ".config/rui/codex.json")
    prompt = "/status\nkeep //literal café"
    exec_release = threading.Event()
    permission_release = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("entry-answer", "entry-reason", "entry-message", "Initial prompt answered.")[0],
        fixture.sse_answer("older-answer", "older-reason", "older-message", "Older Session active.")[0],
        (fixture.sse_answer("exec-answer", "exec-reason", "exec-message", "# Literal **answer** café\n\x1b[31mnot a control")[0], exec_release),
        fixture.sse_answer("stdin-answer", "stdin-reason", "stdin-message", "Stdin answered.")[0],
        fixture.ResponseSpec(b'{"error":"denied"}', {}, 401),
        fixture.sse_answer("lost-answer", "lost-reason", "lost-message", "Lost reply recovered.")[0],
        (fixture.sse_tool_calls("exec-tools", [("bash", "exec-call", json.dumps({"cmd": "touch must-not-run", "timeout_ms": None}))]), permission_release),
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = executor = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "setup", "--store", store, "--provider", "codex", "--model", "gpt-6-luna")
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), prompt], cwd=workspace,
            env={**os.environ, "HOME": str(home), "TERM": "xterm-256color", "NO_COLOR": ""},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output = read_terminal(master, "Initial prompt answered.", preserve_colour=True)
        assert "\x1b[94m›\x1b[39m " in output, output
        assert "Provider:" not in output and "Assistant:" not in output, output
        assert len(endpoint.requests) == 1
        request = json.loads(endpoint.requests[0])
        user = [item for item in request["input"] if item.get("role") == "user"]
        assert user[-1]["content"][0]["text"] == prompt, user
        terminal_step(master, "/exit", "Resume: ")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0 and not errors, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original
        initial_session = json.loads(run(home, "sessions", "--all", "--json"))["sessions"][0]["reference"]
        # More than one eight-row page here; a newer foreign Workspace must not
        # win --last. Exact resume is independent of that cwd filtering.
        other = state / "other"
        other.mkdir()
        for index in range(9):
            run(home, "configure", "--session", f"last/{index}", "--workspace", workspace,
                "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
        run(home, "configure", "--session", "foreign/newer", "--workspace", other,
            "--provider", "codex", "--model", "model-b", "--permission-mode", "ask")
        older = admit(home, "message", "--session", "last/0", "older activity")
        fixture.wait_for(lambda: fixture.completed_observation(store, older["request"]), "older Session activity")
        alias = state / "workspace-alias"
        alias.symlink_to(workspace, target_is_directory=True)
        for flags, expected in ((("--last",), "last/8"), ((initial_session,), initial_session)):
            for terminal, no_colour in (("xterm-256color", ""), ("xterm-256color", "1"), ("dumb", "")):
                caller = subprocess.Popen([str(fixture.RUI), "resume", *flags], cwd=alias,
                    env={**os.environ, "HOME": str(home), "TERM": terminal, "NO_COLOR": no_colour},
                    stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                opening = read_terminal(master, "› ", preserve_colour=True)
                assert ("\x1b[94m" in opening) == (no_colour == "" and terminal != "dumb"), opening
                status = terminal_step(master, "/status")
                assert f"Session: {expected}\n" in status, status
                terminal_step(master, "/exit", "Resume: ")
                _, errors = terminal_exit(caller, master)
                assert caller.returncode == 0 and not errors, errors
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                assert actual == original
        assert len(endpoint.requests) == 2, "resume submitted or restarted work"
        env = {**os.environ, "HOME": str(home)}
        executor = subprocess.Popen([str(fixture.RUI), "exec", "held prompt"], cwd=workspace,
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: len(endpoint.requests) == 3, "exec provider request")
        assert executor.poll() is None, "exec returned on Admission instead of waiting for the answer"
        assert not select.select([executor.stdout], [], [], 0)[0], "exec leaked receipts to stdout"
        exec_release.set()
        out, errors = executor.communicate(timeout=5)
        assert executor.returncode == 0, errors
        assert out == "# Literal **answer** café\n\\x1b[31mnot a control\n".encode(), out
        assert b"Message request: " in errors and b"Configuration request: " in errors, errors
        piped = subprocess.run([str(fixture.RUI), "exec", "-"], cwd=workspace, env=env,
            input="/literal\nstdin café\n".encode(), capture_output=True, timeout=10)
        assert piped.returncode == 0 and piped.stdout == b"Stdin answered.\n", piped
        stdin_user = [item for item in json.loads(endpoint.requests[3])["input"] if item.get("role") == "user"]
        assert stdin_user[-1]["content"][0]["text"] == "/literal\nstdin café\n", stdin_user
        failed = subprocess.run([str(fixture.RUI), "exec", "failure"], cwd=workspace, env=env,
            capture_output=True, timeout=10)
        assert failed.returncode != 0 and failed.stdout == b"", failed
        assert b"provider_http_401" in failed.stderr and b"rui result " in failed.stderr, failed.stderr
        proxy = canonical.ReplyProxy(host, "/v1/message", lambda _: b"")
        lost = subprocess.run([str(fixture.RUI), "exec", "lost original"], cwd=workspace,
            env=env, capture_output=True, timeout=10)
        assert lost.returncode != 0 and lost.stdout == b"", lost
        handle = re.search(rb"Message request: ([a-z0-9-]+)", lost.stderr).group(1).decode()
        assert f"rui recover {handle}".encode() in lost.stderr, lost.stderr
        record = home / ".config/rui/requests" / (handle + ".json")
        original_record = record.read_bytes()
        proxy.close()
        proxy = None
        fixture.wait_for(lambda: fixture.completed_observation(store, handle), "lost exec original answer")
        assert json.loads(run(home, "recover", handle, "--json"))["answer"]["replayed"] is True
        assert record.read_bytes() == original_record and len(endpoint.requests) == 6, "exec replaced uncertain input"
        executor = subprocess.Popen([str(fixture.RUI), "exec", "needs approval"], cwd=workspace,
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: len(endpoint.requests) == 7, "exec held tool request")
        pages = [json.loads(line) for line in run(home, "sessions", "--all", "--json").splitlines()]
        selected = pages[-1]["sessions"][-1]["reference"]
        # Permission mode is selected at proposal admission, not dispatch.
        run(home, "configure", "--session", selected, "--permission-mode", "ask")
        permission_release.set()
        out, errors = executor.communicate(timeout=5)
        assert executor.returncode != 0 and out == b"" and b"approval required" in errors, (out, errors)
        assert b"rui resume --store " in errors and selected.encode() in errors, errors
        current = fixture.command("inspect-session", "--store", store, "--session", selected)
        assert current["actionable_permissions"] and not (workspace / "must-not-run").exists(), current
        assert len(endpoint.requests) == 7, "blocked exec authorized or continued work"
        missing_home = state / "missing-home"
        missing_home.mkdir(mode=0o700)
        missing = subprocess.run([str(fixture.RUI), "exec", "no login"], cwd=workspace,
            env={**env, "HOME": str(missing_home), "RUI_CODEX_CREDENTIAL_FILE": str(missing_home / "codex.json")},
            capture_output=True, timeout=10)
        assert missing.returncode != 0 and missing.stdout == b"" and b"rui login codex" in missing.stderr, missing
        assert not (missing_home / ".config").exists() and not (missing_home / ".local").exists(), "exec prompted or mutated before login"
        completed = True
        print("CLI entry/resume/exec: literal prompt, canonical scoped paginated last vs older activity, exact resume, colour/NO_COLOR, waited escaped answer, stdin, failure, exact lost-reply recovery, permission block and missing-login controls passed", flush=True)
    finally:
        exec_release.set()
        permission_release.set()
        if proxy is not None:
            proxy.close()
        if executor is not None and executor.poll() is None:
            executor.kill()
            executor.communicate(timeout=5)
        if caller is not None and caller.poll() is None:
            caller.kill()
            caller.wait(timeout=5)
        if master is not None:
            os.close(master)
            os.close(slave)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained command-entry failure state: {state}", file=sys.stderr)


def persistent_opening_case():
    """Frozen replay uses real content once and assistant-only formatting."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-opening."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store'$(false)"
    large_answer = "# Saved heading\n**saved bold** é\n# " + "x" * 8192 + "\nOPENING-COMPLETE"
    history_release = threading.Event()
    opening_release = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("opening-a", "opening-ar", "opening-am", large_answer)[0],
        *[fixture.sse_answer(f"older-{i}", f"older-r-{i}", f"older-m-{i}", f"saved answer {i:02d}")[0] for i in range(1, 10)],
        fixture.sse_answer("late", "late-r", "late-m", "late beyond captured end")[0],
        fixture.sse_answer("independent", "independent-r", "independent-m", "independent history admission")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "configure", "--store", store, "--session", "persistent/opening",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        message = admit(home, "message", "--store", store, "--session", "persistent/opening", "literal **user** é")
        fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "opening saved answer")
        rendered = run(home, "result", message["request"])
        assert "\x1b[1mSaved heading\x1b[0m" in rendered and "OPENING-COMPLETE" in rendered, "keyed result bypassed assistant renderer"
        assert run(home, "read-result", "--store", store, "--key", message["request"]) == large_answer
        assert json.loads(run(home, "result", message["request"], "--json"))["answer"] == large_answer
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", "persistent/opening"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output = read_terminal(master, "› ")
        assert output.count("literal **user** é") == 1, ("opening lost or duplicated User", output)
        assert "\n› literal **user** é" in output, output
        assert "\n  \x1b[1mSaved heading" in output, output
        assert all(noise not in output for noise in ("You:", "Assistant:", "Rui:", "item_id:", "call_id:", "Capturing original", "Original reserved request")), output
        assert output.count("\x1b[1mSaved heading\x1b[0m") == 1, ("opening bypassed assistant renderer", output)
        assert output.count("\x1b[1msaved bold\x1b[0m é") == 1, output
        assert "Provider:" not in output and "Workspace (Bash cwd):" not in output, ("opening is not compact", output)
        assert "OPENING-COMPLETE" in output, "opening applied the historical omission limit"
        assert len(endpoint.requests) == 1, "opening restarted saved work"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "opening terminal configuration was not restored"
        os.close(master)
        os.close(slave)
        master = slave = None

        # A late opening read error is fatal after a visible prefix, not a
        # recoverable page preparation error or a reason to replay provider work.
        proxy = canonical.ReplyProxy(host, "/v1/activity-content",
            lambda response: response[:-1] if b"OPENING-COMPLETE" in response else response)
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", "persistent/opening"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        prefix = read_terminal(master, "Saved heading")
        tail, errors = terminal_exit(caller, master)
        assert caller.returncode != 0 and b"TruncatedResponse" in errors, errors
        assert "OPENING-COMPLETE" not in prefix and b"OPENING-COMPLETE" not in tail, "truncated opening exposed unverified completion"
        styled = prefix.encode() + tail
        assert styled.rfind(b"\x1b[0m") > styled.rfind(b"\x1b[1m"), "failed opening left renderer styling active"
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "late opening error left terminal configuration changed"
        assert len(endpoint.requests) == 1 and len(proxy.exchanges) == 2, "opening error retried or caused work"
        proxy.close()
        proxy = None
        os.close(master)
        os.close(slave)
        master = slave = None
        for buffered_reset in (False, True):
            def truncate_result(response):
                if not buffered_reset:
                    return response[:-1]
                # The renderer has returned to normal style, but its reset and
                # incomplete span remain buffered after a visible bold prefix.
                body = b"# " + b"x" * 5000 + b"\n*UNVERIFIED"
                return (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
                    b"X-Rui-Wire-Version: 1\r\nContent-Length: " + str(len(body) + 1).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body)

            proxy = canonical.ReplyProxy(host, "/v1/read-result", truncate_result)
            failed_result = subprocess.run([str(fixture.RUI), "result", message["request"]],
                env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=5)
            assert failed_result.returncode != 0 and b"TruncatedResponse" in failed_result.stderr, failed_result
            assert failed_result.stdout.rfind(b"\x1b[0m") > failed_result.stdout.rfind(b"\x1b[1m"), "failed keyed result left renderer styling active"
            assert b"OPENING-COMPLETE" not in failed_result.stdout and b"UNVERIFIED" not in failed_result.stdout, "failed keyed result flushed unverified text"
            assert len(endpoint.requests) == 1 and len(proxy.exchanges) == 1, "failed keyed result restarted work"
            proxy.close()
            proxy = None
        for i in range(1, 10):
            message = admit(home, "message", "--store", store, "--session", "persistent/opening", f"saved user {i:02d}")
            fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "history saved answer")
        # A queued local traversal is not eligible until opening establishes its
        # cursor. Both command and inspection cancellation must retain it.
        for handoff in (b"/status\n", b"/inspect-action\n"):
            opening_release.clear()
            opening_held = threading.Event()

            def hold_first_opening(response):
                if len(proxy.exchanges) == 1:
                    opening_held.set()
                    assert opening_release.wait(15), "cancelled opening gate was not released"
                return response

            proxy = canonical.ReplyProxy(host, "/v1/activity-page", hold_first_opening)
            master, slave = pty.openpty()
            caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", "persistent/opening"], env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            startup = terminal_gate(caller, master, opening_held, ("queued opening", handoff, proxy.exchanges))
            os.write(master, b"/history\n" + handoff)
            output = startup
            deadline = time.monotonic() + 15
            while b"No older Conversation rows" not in output and b"History page complete" not in output:
                remaining = deadline - time.monotonic()
                assert remaining > 0 and select.select([master], [], [], remaining)[0], output
                output += os.read(master, 65536)
                assert len(output) < 1024 * 1024
            assert b"No older Conversation rows" not in output, ("queued history consumed an unestablished opening cursor", handoff, output)
            assert b"literal **user**" in output and b"saved user 01" in output, output
            assert len(endpoint.requests) == 10, "opening/history handoff restarted work"
            opening_release.set()
            os.write(master, b"\x03")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0, errors
            proxy.close()
            proxy = None
            os.close(master)
            os.close(slave)
            master = slave = None
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", "persistent/opening"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output = read_terminal(master, "› ")
        assert "saved user 09" in output and "literal **user** é" not in output, output
        assert output.index("saved user 08") < output.index("saved answer 08") < output.index("saved user 09"), output
        message = admit(home, "message", "--store", store, "--session", "persistent/opening", "late input")
        fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "late saved answer")
        read_terminal(master, "late beyond captured end")
        # Explicit latest details cannot move the frozen older-history cursor.
        os.write(master, b"/details\n")
        details = read_terminal(master, "Details complete")
        assert "late beyond captured end" in details and "literal **user** é" not in details, details

        history_held = threading.Event()

        def truncate_second(response):
            if len(proxy.exchanges) == 2:
                history_held.set()
                assert history_release.wait(15), "history preparation gate was not released"
                return response[:-1]
            return response

        proxy = canonical.ReplyProxy(host, "/v1/conversation-content", truncate_second)
        os.write(master, b"/history\n")
        assert history_held.wait(10), "history did not reach its held content read"
        records = home / ".config/rui/requests"
        before = set(records.glob("*.json"))
        os.write(master, "during history é\nnext café!\x1b[D\x1b[DX".encode())
        fixture.wait_for(lambda: len(set(records.glob("*.json")) - before) == 1, "independent history Admission capture")
        record = (set(records.glob("*.json")) - before).pop()
        fixture.wait_for(lambda: fixture.completed_observation(store, record.stem), "Admission while history preparation is held")
        assert json.loads(record.read_text())["text"]["value"] == "during history é"
        composing = read_terminal(master, "› next cafXé!", timeout=5)
        assert not history_release.is_set() and "saved answer" not in composing and "saved user" not in composing
        history_release.set()
        failed = read_terminal(master, "History unavailable; older cursor and draft retained")
        assert "saved answer" not in failed and "saved user" not in failed, "failed history exposed a staged prefix"
        if "› next cafXé!" not in failed:
            read_terminal(master, "› next cafXé!")
        os.write(master, b"\x1b[CZ")
        read_terminal(master, "› next cafXéZ!")
        os.write(master, b"\x05\x15/history\n")
        recovered = read_terminal(master, "History page complete")
        assert recovered.count("literal **user** é") == 1 and "Historical item omitted" in recovered, recovered
        assert "Saved heading" not in recovered and "OPENING-COMPLETE" not in recovered, "oversized historical content leaked"
        assert recovered.index("literal **user** é") < recovered.index("Historical item omitted") < recovered.index("saved user 01"), recovered
        export = next(line.removeprefix("Raw export: ") for line in recovered.splitlines() if line.startswith("Raw export: "))
        command = shlex.split(export)
        assert command[0:3] == ["rui", "read-conversation", "--store-hex"] and bytes.fromhex(command[3]) == str(store).encode(), export
        assert all(32 <= ord(char) < 127 for char in export), "raw export printed terminal controls"
        executables = state / "bin"
        executables.mkdir()
        (executables / "rui").symlink_to(fixture.RUI.resolve())
        exported = subprocess.run(export, shell=True, env={**os.environ, "HOME": str(home),
            "PATH": str(executables) + os.pathsep + os.environ["PATH"]}, capture_output=True, timeout=10)
        assert exported.returncode == 0 and exported.stdout == large_answer.encode(), (export, exported.stderr, exported.stdout)
        for flags in (("--session-hex", "0"), ("--session-hex", "zz"),
                ("--session-hex", "61" * 129), ("--store-hex", "61" * 493),
                ("--session", "persistent/opening", "--session-hex", "61"),
                ("--store", store, "--store-hex", "61")):
            rejected = subprocess.run([str(fixture.RUI), "read-conversation", *map(str, flags),
                "--position", "1", "--ordinal", "0"], capture_output=True, timeout=10)
            assert rejected.returncode != 0 and not rejected.stdout, (flags, rejected)
            assert b"InvalidHexIdentity" in rejected.stderr or b"DuplicateArgument" in rejected.stderr, rejected.stderr
        assert "late beyond captured end" not in recovered and "saved user 09" not in recovered, "history recaptured or replayed opening"
        assert proxy.exchanges[0][0] == proxy.exchanges[2][0], "history failure advanced its actual cursor"
        os.write(master, b"/history\n")
        read_terminal(master, "No older Conversation rows")
        assert len(endpoint.requests) == 12, "history caused provider work"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("persistent opening/history: exact chronological frozen replay, assistant-only Markdown, whole-page failure/retry, no cursor loss/late append/repeated work passed", flush=True)
    finally:
        history_release.set()
        opening_release.set()
        if caller is not None and caller.poll() is None:
            caller.kill()
            caller.wait(timeout=5)
        if master is not None:
            os.close(master)
            os.close(slave)
        if proxy is not None:
            proxy.close()
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent opening failure state: {state}", file=sys.stderr)


def persistent_pending_case():
    """Opening counts the frozen queue beyond its newest Activity page."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-pending."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store"
    release, captured, opening_release = threading.Event(), threading.Event(), threading.Event()
    endpoint = fixture.SuccessEndpoint([(fixture.sse_answer("pending-a", "pending-r", "pending-m", "held answer")[0], release)])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "configure", "--store", store, "--session", "persistent/pending", "--workspace", state,
            "--provider", "codex", "--model", "model-a")
        admit(home, "message", "--store", store, "--session", "persistent/pending", "active original")
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "held first provider request")
        for i in range(1, 25):
            admit(home, "message", "--store", store, "--session", "persistent/pending", f"queued-{i:02d} é")

        def hold_opening(response):
            if len(proxy.exchanges) == 1:
                captured.set()
                assert opening_release.wait(15), "opening metadata gate was not released"
            return response

        proxy = canonical.ReplyProxy(host, "/v1/activity-page", hold_opening)
        master, slave = pty.openpty()
        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", "persistent/pending"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        startup = terminal_gate(caller, master, captured, ("pending opening", proxy.exchanges, endpoint.requests))
        admit(home, "message", "--store", store, "--session", "persistent/pending", "late queued beyond snapshot")
        opening_release.set()
        output = startup.decode(errors="replace").replace("\r\n", "\n") + read_terminal(master, "› ")
        assert "24 queued messages" in output, ("opening counted only its newest page or fresh Current", output)
        previews = [line for line in output.splitlines() if "Queued: " in line]
        assert len(previews) == 4, previews
        for i, preview in enumerate(previews, 1):
            assert preview.endswith(f"queued-{i:02d} é"), previews
        assert len(endpoint.requests) == 1, "opening dispatched queued work"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("persistent pending: exact frozen 24 beyond newest 16, oldest four previews, late admission excluded passed", flush=True)
    finally:
        opening_release.set()
        if caller is not None and caller.poll() is None:
            caller.kill()
            caller.wait(timeout=5)
        if master is not None:
            os.close(master)
            os.close(slave)
        if proxy is not None:
            proxy.close()
        if host is not None:
            fixture.stop_host(host)
        release.set()
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent pending failure state: {state}", file=sys.stderr)


def persistent_input_cases():
    """Real captured Admission, a next draft, original replay and input recovery."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-input."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store"
    first_release = threading.Event()
    next_received, next_admission_release = threading.Event(), threading.Event()
    endpoint = fixture.SuccessEndpoint([
        (fixture.sse_answer("persistent-a", "persistent-ar", "persistent-am", "first exact answer")[0], first_release),
        fixture.sse_answer("persistent-b", "persistent-br", "persistent-bm", "second exact answer")[0],
        fixture.sse_answer("persistent-c", "persistent-cr", "persistent-cm", "valid after malformed")[0],
        fixture.sse_answer("persistent-d", "persistent-dr", "persistent-dm", "capture retry answer")[0],
        fixture.sse_answer("persistent-e", "persistent-er", "persistent-em", "next after capture retry")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "configure", "--store", store, "--session", "persistent/input",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        received, admission_release = threading.Event(), threading.Event()

        def lost_once(response):
            received.set()
            assert admission_release.wait(15), "Admission gate was not released"
            if len(proxy.exchanges) == 3:
                next_received.set()
                assert next_admission_release.wait(15), "next Admission gate was not released"
            return b"" if len(proxy.exchanges) in (1, 4) else response

        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", "persistent/input"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        read_terminal(master, "› ")
        proxy = canonical.ReplyProxy(host, "/v1/message", lost_once)
        # An idle recovery key cannot authorize retry of a future submission.
        os.write(master, "\x12original éZ\n".encode())
        assert received.wait(10), "original Message did not reach Host"
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        composed = read_terminal(master, "› next cafXé!")
        assert "Sending" in composed and "Original reserved request" not in composed, composed
        records = home / ".config/rui/requests"
        before = set(records.glob("*.json"))
        os.write(master, b"\n")
        assert "Input still pending" in read_terminal(master, "Input still pending")
        assert set(records.glob("*.json")) == before, "busy Enter created replacement intent"
        admission_release.set()
        uncertain = read_terminal(master, "Not confirmed")
        assert "! Not confirmed" in uncertain and "Rui:" not in uncertain, uncertain
        assert "Original reserved request" not in uncertain, ("normal recovery exposed a UUID", uncertain)
        assert len(proxy.exchanges) == 1
        saved = proxy.exchanges[0][0]
        assert json.loads(saved)["text"]["value"] == "original éZ"
        first_release.set()
        read_terminal(master, "first exact answer")
        assert len(proxy.exchanges) == 1, "idle Ctrl-R retried unrelated uncertain intent"
        os.write(master, b"\x12")
        read_terminal(master, "Original confirmed")
        assert len(proxy.exchanges) == 2 and proxy.exchanges[1][0] == saved, "Ctrl-R changed original capture"
        assert len(endpoint.requests) == 1, "recovery repeated provider work"
        # Cursor still sits before é; insert at that exact logical position.
        os.write(master, b"Y\n")
        assert next_received.wait(10), "next Message did not reach Host"
        # A retry requested during this Admission belongs only to its ticket.
        os.write(master, b"\x12pending scope")
        read_terminal(master, "› pending scope")
        next_admission_release.set()
        read_terminal(master, "second exact answer")
        assert json.loads(proxy.exchanges[-1][0])["text"]["value"] == "next cafXYé!"
        assert len(endpoint.requests) == 2
        os.write(master, b"\x15bad\xc3(\n")
        rejected = read_terminal(master, "Input rejected; nothing sent.")
        assert "InvalidTerminalInput" not in rejected, ("internal error name leaked", rejected)
        os.write(master, b"valid after rejection\n")
        uncertain = read_terminal(master, "Not confirmed")
        if "valid after malformed" not in uncertain:
            read_terminal(master, "valid after malformed")
        assert json.loads(proxy.exchanges[-1][0])["text"]["value"] == "valid after rejection"
        assert len(proxy.exchanges) == 4, "accepted ticket's Ctrl-R retried a later submission"
        os.write(master, b"\x12")
        read_terminal(master, "Original confirmed")
        assert len(proxy.exchanges) == 5 and proxy.exchanges[4][0] == proxy.exchanges[3][0], "fresh Ctrl-R did not recover the current original"
        # Actual prepublication access failure, followed by repair. Recovery
        # must capture the original under its reserved key, not wedge forever.
        before_failure = set(records.glob("*.json"))
        records.chmod(0o500)
        os.write(master, b"original before capture failure\n")
        failed = read_terminal(master, "Not confirmed")
        assert "Original reserved request" not in failed, failed
        # Diagnostics run with canonical input restored. Their final line is
        # not readiness: the next raw-entry flush follows it. Await the resumed
        # composer under the same response budget before typing the next draft.
        diagnostic_deadline = time.monotonic() + 15
        os.write(master, b"/status\n")
        diagnostic = read_terminal(master, "Ctrl-R retries this exact original.",
            timeout=diagnostic_deadline - time.monotonic())
        if "› " not in diagnostic.split("Ctrl-R retries this exact original.", 1)[1]:
            diagnostic += read_terminal(master, "› ", timeout=diagnostic_deadline - time.monotonic())
        reserved = diagnostic.split("Original reserved request: ", 1)[1].splitlines()[0]
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        failed += read_terminal(master, "› next cafXé!")
        assert set(records.glob("*.json")) == before_failure
        assert len(proxy.exchanges) == 5, "capture failure transmitted input"
        records.chmod(0o700)
        os.write(master, b"\x12")
        read_terminal(master, "capture retry answer")
        recovered = json.loads(proxy.exchanges[-1][0])
        assert recovered["key"] == reserved and recovered["text"]["value"] == "original before capture failure", recovered
        assert len(set(records.glob("*.json")) - before_failure) == 1
        os.write(master, b"Y\n")
        # Visible answer bytes are not joined-reader readiness for a command.
        read_terminal(master, "next after capture retry", composer=True)
        assert json.loads(proxy.exchanges[-1][0])["text"]["value"] == "next cafXYé!"
        assert len(endpoint.requests) == 5 and len(proxy.exchanges) == 7
        # A command selects a handoff, not another input/submission window.
        before_command = set(records.glob("*.json"))
        os.write(master, b"/configure --permission-mode ask\nUNREAD suffix\n")
        read_terminal(master, "Configured.")
        added = [json.loads(path.read_text()) for path in set(records.glob("*.json")) - before_command]
        assert len(added) == 1 and "configuration" in added[0], "command suffix became captured Message intent"
        assert fixture.command("inspect-session", "--store", store,
            "--session", "persistent/input")["session"]["permission_mode"] == "ask"
        assert len(endpoint.requests) == 5 and len(proxy.exchanges) == 7, "command suffix reached Host"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = caller.communicate(timeout=5)
        assert caller.returncode == 0, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            # NOW restores user configuration, not kernel-owned history flags.
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "persistent terminal configuration was not restored"
        completed = True
        print("persistent public Session: exact original replay, joined acceptance, next Unicode cursor, malformed→valid, prepublication repair, restoration passed", flush=True)
    finally:
        first_release.set()
        next_admission_release.set()
        records = home / ".config/rui/requests"
        if records.exists():
            records.chmod(0o700)
        if not completed and caller is not None and caller.poll() is not None:
            print(f"persistent caller exited {caller.returncode}: {caller.stderr.read().decode(errors='replace')}", file=sys.stderr)
        if caller is not None and caller.poll() is None:
            caller.kill()
            caller.wait(timeout=5)
        if proxy is not None:
            proxy.close()
        if master is not None:
            os.close(master)
            os.close(slave)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent input failure state: {state}", file=sys.stderr)


def persistent_permission_case(decision="deny-action", exit_code=0, signal_failure=False,
                               lost_reply=False, fragmented_paste=False, stale_target=False):
    """Fresh inline choices retain draft custody and exact canonical targets."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-permission."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store'$(false)"
    reference = "persistent/permission'$(false) é\n"
    answer = "after explicit denial" if decision == "deny-action" else "after explicit approval"
    arguments = json.dumps({"cmd": f"printf inspection-only-output; printf unsafe >> effect-count; exit {exit_code}", "timeout_ms": 30000})
    calls = [("bash", "persistent-call-id", arguments)]
    second_command = "printf distinct >> second-effect"
    if stale_target:
        calls.append(("bash", "persistent-second-id", json.dumps({"cmd": second_command, "timeout_ms": None})))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("persistent-call", calls),
        fixture.sse_answer("persistent-answer", "persistent-reason", "persistent-message", answer)[0],
        fixture.sse_answer("retained-answer", "retained-reason", "retained-message", "retained draft complete")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    arguments_release = threading.Event()
    arguments_held = threading.Event()
    ready_read, ready_write = os.pipe()
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
            *(("--fault", "bash-signal") if signal_failure else ()))
        run(home, "configure", "--store", store, "--session", reference,
            "--workspace", state, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", reference], env={**os.environ, "HOME": str(home),
                "TERM": "xterm-256color", "NO_COLOR": "",
                "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,),
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        opening = read_terminal(master, "› ")
        assert all(noise not in opening for noise in ("model-a", "Workspace:", "Session:", "Store:", "/help commands")), opening
        def hold_arguments(response):
            if not arguments_held.is_set():
                arguments_held.set()
                assert arguments_release.wait(15), "Action arguments gate was not released"
            return response

        proxy = canonical.ReplyProxy(host, "/v1/read-action-arguments", hold_arguments)
        os.write(master, b"requires permission\n")
        terminal_gate(caller, master, arguments_held, "automatic Action arguments")
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        read_terminal(master, "› next cafXé!")
        records = home / ".config/rui/requests"
        before_choice = set(records.glob("*.json"))
        os.write(master, b"a\n\x1b[200~" if fragmented_paste else b"a\n")
        arguments_release.set()
        styled_transcript = read_terminal(master, json.loads(arguments)["cmd"], preserve_colour=True)
        assert "\x1b[33m\n? Run Bash:\x1b[39m" in styled_transcript, styled_transcript
        transcript = re.sub(r"\x1b\[(?:33|39|90|91|94)m", "", styled_transcript)
        if fragmented_paste:
            assert not select.select([ready_read], [], [], 1)[0], "unfinished chat paste opened consent scope"
            os.write(master, b"\x1b[201~\n")
        transcript += action_ready(ready_read, master)
        if "a: Allow once / d: Deny (Enter)" not in transcript:
            transcript += read_terminal(master, "a: Allow once / d: Deny (Enter)")
        assert "Capturing original" not in transcript and "Original reserved request" not in transcript, transcript
        assert "item_id:" not in transcript and "call_id:" not in transcript and "arguments:" not in transcript, transcript
        assert transcript.count("Workspace:") == 1 and transcript.count("Run Bash:") == 1, transcript
        assert f"\n? Run Bash:\n  {json.loads(arguments)['cmd']}\n" in transcript, transcript
        assert_permission_workspace(transcript, state, 100)
        assert transcript.count("Time limit: 30000 ms") == 1, transcript
        assert transcript.count(json.loads(arguments)["cmd"]) == 1, transcript
        assert all(noise not in transcript for noise in ("You:", "Assistant:", "Rui:", "persistent-call-id")), transcript
        assert set(records.glob("*.json")) == before_choice, "queued chat created a record"
        assert not (state / "effect-count").exists(), "queued chat authorized an effect"
        for invalid in (b"Y\n", b"\x1b[200~a\x1b[201~\n"):
            os.write(master, invalid)
            rejected = read_terminal(master, "a: Allow once / d: Deny (Enter)")
            rejected += action_ready(ready_read, master)
            assert "Run Bash:" not in rejected, "invalid choice repeated command"
            assert set(records.glob("*.json")) == before_choice, "invalid choice captured authority"
            assert not (state / "effect-count").exists()
        for command, notice in (("/wait", "Work continues while you compose."),
                                ("/login", "Login uses rui login codex in your shell.")):
            os.write(master, (command + "\n").encode())
            restricted = read_terminal(master, notice)
            restricted += action_ready(ready_read, master)
            assert "Run Bash:" not in restricted, restricted
            assert set(records.glob("*.json")) == before_choice, "nested prompt created intent"
        current = fixture.command("inspect-session", "--store", store, "--session", reference)
        action = current["actionable_permissions"][0]["action"]
        proxy.exchanges.clear()
        proxy.route = "/v1/control/permission-decision"
        proxy.rewrite = lambda response: b"" if lost_reply and len(proxy.exchanges) == 1 else response
        if stale_target:
            run(home, "deny-action", "--store", store, "--session", reference, "--action", action)
            proxy.exchanges.clear()
        os.write(master, b"d\n" if decision == "deny-action" and not stale_target else b"a\n")
        settled = ""
        if lost_reply:
            settled = read_terminal(master, "Decision not confirmed")
            assert "! Decision not confirmed" in settled and "Rui:" not in settled, settled
            os.write(master, b"\x12")
            settled += read_terminal(master, "Decision confirmed.")
        if stale_target:
            read_terminal(master, "action_not_pending")
            assert len(proxy.exchanges) == 1
            assert json.loads(proxy.exchanges[0][0])["action"] == action
            assert not (state / "effect-count").exists() and not (state / "second-effect").exists()
            assert len(endpoint.requests) == 1
            os.write(master, b"\x01\x0b/discard\n")
            shown = read_terminal(master, second_command)
            shown += action_ready(ready_read, master)
            if "a: Allow once / d: Deny (Enter)" not in shown:
                shown += read_terminal(master, "a: Allow once / d: Deny (Enter)")
            assert f"\n? Run Bash:\n  {second_command}\n" in shown, shown
            os.write(master, b"/details\n")
            details = read_terminal(master, "Details complete")
            assert "\n› requires permission" in details, details
            details += action_ready(ready_read, master)
            assert fixture.command("inspect-session", "--store", store, "--session", reference)["actionable_permissions"][0]["action"] == current["actionable_permissions"][1]["action"]
            os.write(master, b"/exit\n")
            assert caller.wait(timeout=5) == 0, caller.stderr.read()
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            assert len(endpoint.requests) == 1
            assert not (state / "effect-count").exists() and not (state / "second-effect").exists()
            completed = True
            return
        if answer not in settled:
            settled += read_terminal(master, answer)
        assert len(proxy.exchanges) == (2 if lost_reply else 1), proxy.exchanges
        if lost_reply:
            assert proxy.exchanges[0][0] == proxy.exchanges[1][0], "decision retry changed intent"
        submitted = json.loads(proxy.exchanges[0][0])
        assert submitted["action"] == action and submitted["session"] == reference
        assert submitted["decision"] == ("deny" if decision == "deny-action" else "allow_once")
        for _, response in proxy.exchanges:
            assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
        saved = [json.loads(path.read_text()) for path in records.glob("*.json")]
        assert sum(row["kind"] == "permission_decision" for row in saved) == 1, saved
        assert len(endpoint.requests) == 2
        if exit_code:
            assert f"! Bash failed. Exit code: {exit_code}." in settled, ("quiet view hid tool failure", settled)
            assert "/details for output." in settled, settled
        elif decision == "allow-action":
            assert "  • Bash succeeded." in settled, ("quiet view hid tool outcome", settled)
            assert "Exit code: 0." not in settled, ("routine zero exit code leaked", settled)
        else:
            assert "  • Permission denied." in settled, ("intentional denial was not a settled outcome", settled)
            assert "! Permission denied." not in settled and "/details for output." not in settled, settled
        if signal_failure:
            assert "Process-group signaling reported a failure." in settled, ("quiet view hid cleanup warning", settled)
        assert f"\n  {answer}" in settled, settled
        assert all(noise not in settled for noise in ("You:", "Assistant:", "Rui:", "item_id:", "call_id:", "Capturing original", "Original reserved request")), settled
        assert "inspection-only-output" not in settled, ("routine tool output leaked", settled)
        effect = state / "effect-count"
        assert effect.read_text() == "unsafe" if decision == "allow-action" else not effect.exists()
        if "› next cafXaé!" not in settled:
            read_terminal(master, "› next cafXaé!")
        proxy.route = "/v1/message"
        proxy.exchanges.clear()
        proxy.rewrite = lambda response: response
        os.write(master, b"Y\n")
        submitted_draft = read_terminal(master, "\n› next cafXaYé!")
        fixture.wait_for(lambda: proxy.exchanges, "retained draft queued Message")
        assert json.loads(proxy.exchanges[0][0])["text"]["value"] == "next cafXaYé!"
        if "retained draft complete" not in submitted_draft:
            read_terminal(master, "retained draft complete")
        os.write(master, b"/details\n")
        details = read_terminal(master, "Details complete")
        assert "Recent conversation — tool details" in details and "  Tool result:\n" in details, details
        assert "\n› requires permission" in details and f"\n  {answer}" in details, details
        assert all(noise not in details for noise in ("You:", "Assistant:", "Rui:", "Tool Result:")), details
        if decision == "allow-action":
            assert "inspection-only-output" in details, ("saved tool output unavailable on inspection", details)
            assert f"Exit code: {exit_code}." in details, ("exact exit code unavailable on inspection", details)
        # A resize must retain the exact non-tail Unicode cursor without prose.
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        read_terminal(master, "› next cafXé!")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 32, 0, 0))
        resized = read_terminal(master, "› next cafXé!")
        assert "terminal resized" not in resized, resized
        os.write(master, b"Y")
        read_terminal(master, "› next cafXYé!")
        caller.send_signal(signal.SIGTERM)
        assert caller.wait(timeout=5) == 0, caller.stderr.read()
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "signal after inspection handoff did not restore terminal"
        # Quiet proposal fields must still be consumed and validated on opening.
        proxy.route = "/v1/proposal-field"
        proxy.rewrite = lambda response: response[:-1] if b"effect-count" in response else response
        caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", reference], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        _, errors = terminal_exit(caller, master)
        assert caller.returncode != 0 and b"TruncatedResponse" in errors, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
        assert actual == original, "hidden proposal failure left terminal configuration changed"
        completed = True
        print(f"persistent permission: inline {decision}, lost={lost_reply}, fragmented={fragmented_paste}, quiet outcome, retained cursor, hidden-field validation and TERM cleanup passed", flush=True)
    finally:
        if sys.exc_info()[0] is not None:
            preserve_failure_metadata(state / "pty-failure.json", lambda: {
                "case": "persistent_permission", "decision": decision,
                "lost_reply": lost_reply, "fragmented_paste": fragmented_paste,
                "error": sys.exc_info()[0].__name__,
                "caller_returncode": caller.poll() if caller is not None else None,
                "ready_pending": bool(select.select([ready_read], [], [], 0)[0]),
                "terminal_pending": bool(select.select([master], [], [], 0)[0]) if master is not None else None,
            })
        arguments_release.set()
        if caller is not None and caller.poll() is None:
            caller.kill()
            caller.wait(timeout=5)
        if proxy is not None:
            proxy.close()
        if master is not None:
            os.close(master)
            os.close(slave)
        os.close(ready_read)
        os.close(ready_write)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent permission failure state: {state}", file=sys.stderr)


def store_selection_cases(state, workspace, valid_store):
    for case in ("saved-initial", "saved-after", "explicit-override", "explicit-create", "home-create"):
        home = state / case
        home.mkdir(mode=0o700)
        destination = home / ".local/share/rui/store" if case == "home-create" else home / "store"
        saved = case.startswith("saved") or case == "explicit-override"
        if saved:
            destination.mkdir(mode=0o700)
            run(home, "setup", "--store", destination, "--provider", "codex", "--model", "gpt-6-luna")
            if case != "saved-after":
                destination.rmdir()
                assert run(home, "host", "status", success=False) == ""
        if not case.startswith("saved"):
            (home / ".config/rui").mkdir(mode=0o700, parents=True, exist_ok=True)
            codex_fixture.credentials(home / ".config/rui/codex.json")
        explicit = valid_store if case == "explicit-override" else destination
        if case == "explicit-override":
            assert "Host: ready" in run(home, "host", "status", "--store", explicit)
        args = ["--store", str(explicit)] if case.startswith("explicit") else []
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        caller = subprocess.Popen([str(fixture.RUI), *args], cwd=workspace,
            env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write)},
            pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        os.close(slave)
        os.close(ready_write)
        try:
            settlement_timeout = 5
            if case == "saved-after":
                assert "No locally ready provider" in provider_prompt(master, ready_read)
                destination.rmdir()
                assert run(home, "host", "status", success=False) == ""
                response_deadline = time.monotonic() + settlement_timeout
                os.write(master, b"d\n")
                # Darwin prompt cleanup can wait for this PTY consumer. Drain
                # the actual deferral response within the original exit budget.
                read_terminal(master, "Rui: Login deferred.", timeout=response_deadline - time.monotonic())
                settlement_timeout = response_deadline - time.monotonic()
                assert settlement_timeout > 0, "saved-Store deferral did not settle within 5 seconds"
            if not case.startswith("saved"):
                greeting = read_terminal(master, "› ")
                assert "Session:" not in greeting and "request:" not in greeting, greeting
                terminal_step(master, "/exit", "Detached.")
            _, errors = caller.communicate(timeout=settlement_timeout)
            if case.startswith("saved"):
                assert caller.returncode != 0 and b"FileNotFound" in errors, (case, errors)
                assert not destination.exists() and not (home / ".config/rui/requests").exists()
            else:
                assert caller.returncode == 0, (case, errors)
                record, = (home / ".config/rui/requests").glob("*.json")
                binding = json.loads(record.read_bytes())
                assert binding["store"] == str(explicit.resolve()) and binding["require_model"] is True
            print("Store provenance:", case, "passed", flush=True)
        finally:
            if caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
            if case in ("explicit-create", "home-create") and destination.exists():
                run(home, "host", "stop", "--store", destination)
                fixture.wait_for(lambda: "Host: unavailable" in run(home, "host", "status", "--store", destination), "created Host stopped")


def action_ready(descriptor, master, timeout=15):
    """Supply normal terminal credit until the actual fresh-input boundary.

    Read exactly one notification, never a future choice's byte. Keep every
    intervening output byte under the existing terminal transcript bound.
    Deliberately withheld-credit controls must select the pipe directly.
    """
    deadline = time.monotonic() + timeout
    output = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0, ("Action input flush did not finish", bytes(output))
        ready = select.select([descriptor, master], [], [], remaining)[0]
        assert ready, ("Action input flush did not finish", bytes(output))
        if master in ready:
            output.extend(os.read(master, 65536))
            assert len(output) < 1024 * 1024, "unexpected unbounded terminal output"
        if descriptor in ready:
            assert os.read(descriptor, 1) == b"x", "Action caller exited before readiness"
            # The notification follows the final write/flush. Collect its
            # remaining queued bytes too, without waiting for another prompt.
            while select.select([master], [], [], 0)[0]:
                assert time.monotonic() < deadline, "Action transcript exceeded readiness deadline"
                chunk = os.read(master, 65536)
                assert chunk, "Action terminal closed at readiness"
                output.extend(chunk)
                assert len(output) < 1024 * 1024, "unexpected unbounded terminal output"
            return re.sub(rb"\x1b\[(?:33|39|90|91|94)m", b"", output).decode(errors="replace").replace("\r\n", "\n")


def provider_prompt(master, ready, command=None):
    # Initial prompts use a fresh pipe. Later prompts must not consume an
    # unread notification from an earlier choice as readiness for this one.
    if command is not None:
        assert not select.select([ready], [], [], 0)[0], "stale provider readiness"
        os.write(master, (command + "\n").encode())
    deadline = time.monotonic() + 15
    output = read_terminal(master, "Provider: [c]", timeout=deadline - time.monotonic())
    output += action_ready(ready, master, timeout=deadline - time.monotonic())
    assert not select.select([ready], [], [], 0)[0], "extra provider readiness"
    return output


def terminal_bulk(master, command, marker="› ", *, submit=True):
    fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
        "noncanonical terminal input")
    def send():
        payload = (command + ("\n" if submit else "")).encode()
        for offset in range(0, len(payload), 1024):
            os.write(master, payload[offset:offset + 1024])

    writer = threading.Thread(target=send, daemon=True)
    writer.start()
    output = read_terminal(master, marker)
    writer.join(timeout=5)
    assert not writer.is_alive(), "bulk terminal writer stalled"
    return output


def saved_capture_cases(state, store, workspace):
    home = state / "capture-home"
    home.mkdir()
    records = home / ".config/rui/requests"
    args = ["configure", "--store", store, "--session", "capture/original",
        "--workspace", workspace, "--provider", "codex", "--model", "model-a"]
    gate = state / "capture-original-reader"
    caller = subprocess.Popen([str(fixture.RUI), *map(str, args), "--json"],
        env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    original = None
    record = None
    try:
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "capture reader publication")
        handles = json.loads(run(home, "requests", "--json"))
        assert len(handles) == 1, handles
        handle = handles[0]
        record = records / f"{handle}.json"
        original = record.read_bytes()
        assert fixture.command("observe-command", "--store", store,
            "--key", handle)["observation"]["status"] == "absent"
        # A pathname replacement after publication must not swap the bytes
        # selected by the captured owner before its announcement.
        replaced = json.loads(original)
        replaced["session"] = "capture/replacement"
        replacement = records / "replacement"
        replacement.write_text(json.dumps(replaced, separators=(",", ":")))
        replacement.replace(record)
        pathlib.Path(f"{gate}.release").touch()
        output, errors = caller.communicate(timeout=20)
        assert caller.returncode == 0, (output, errors)
        captured, admission = map(json.loads, output.splitlines())
        assert captured["request"] == handle and admission["admission"]["answer"]["status"] == "accepted"
        observed = fixture.command("observe-command", "--store", store, "--key", handle)["observation"]
        assert observed["target"] == "capture/original", ("captured owner transmitted a replaced pathname", observed)
    finally:
        if caller.poll() is None:
            caller.kill()
            caller.communicate(timeout=5)
        if original is not None:
            record.write_bytes(original)

    # Recovery must ignore a newly selected, nonexistent preference Store.
    run(home, "setup", "--store", store)
    preferences = home / ".config/rui/preferences"
    preferences.write_text(f"version=1\nstore={state / 'missing-capture-store'}\n")
    assert json.loads(run(home, "recover", handle, "--json"))["answer"]["replayed"] is True

    # Failure to announce happens after publication but before any send.
    before = set(run(home, "requests").splitlines())
    output = run(home, *args, success=False,
        environment={"RUI_TEST_CAPTURE_GATE": str(state / "missing-parent/gate")})
    assert output == "", output
    failed_notice, = set(run(home, "requests").splitlines()) - before
    assert fixture.command("observe-command", "--store", store,
        "--key", failed_notice)["observation"]["status"] == "absent"
    assert json.loads(run(home, "recover", failed_notice, "--json"))["answer"]["replayed"] is False

    # Linux libc fault injection reaches the actual post-rename directory sync,
    # not a fixture-only success path. No automatic send may follow uncertainty.
    if sys.platform == "linux":
        source, library = state / "capture-sync.c", state / "capture-sync.so"
        source.write_text(r"""
#include <dlfcn.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
int fsync(int fd) {
    struct stat value;
    if (!fstat(fd, &value) && S_ISDIR(value.st_mode)) { errno = EIO; return -1; }
    int (*real_sync)(int) = dlsym(RTLD_NEXT, "fsync");
    return real_sync(fd);
}
""")
        subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl", "-o", str(library)], check=True)
        before = set(run(home, "requests").splitlines())
        failed = subprocess.run([str(fixture.RUI), *map(str, args)],
            env={**os.environ, "HOME": str(home), "LD_PRELOAD": str(library)},
            capture_output=True, text=True, timeout=20)
        assert failed.returncode != 0 and "RecordDirectorySyncFailed" in failed.stderr, failed
        assert failed.stdout == "", failed.stdout
        uncertain, = set(run(home, "requests").splitlines()) - before
        assert fixture.command("observe-command", "--store", store,
            "--key", uncertain)["observation"]["status"] == "absent"
        assert json.loads(run(home, "recover", uncertain, "--json"))["answer"]["replayed"] is False
    else:
        print("capture directory-sync injection: unavailable outside Linux", flush=True)

    invalid = "01234567-89ab-4cde-8012-3456789abcde"
    unsupported = "01234567-89ab-4cde-8012-3456789abcdf"
    (records / f"{invalid}.json").write_text("not a readable record")
    stop = {"version": "1", "kind": "session_stop", "store": str(store.resolve()),
        "key": unsupported, "session": "capture/original"}
    (records / f"{unsupported}.json").write_text(json.dumps(stop, separators=(",", ":")))
    (records / "not-a-handle.json").write_text("not a record")
    listed = json.loads(run(home, "requests", "--json"))
    assert invalid in listed and unsupported in listed and "not-a-handle" not in listed, listed
    assert run(home, "recover", invalid, success=False) == ""
    assert run(home, "recover", unsupported, success=False) == ""
    master, slave = pty.openpty()
    entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
        "--session", "capture/original"], env={**os.environ, "HOME": str(home)},
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        read_terminal(master, "› ")
        listing = terminal_step(master, "/requests")
        assert handle in listing and failed_notice in listing, listing
        assert invalid not in listing and unsupported not in listing, listing
        terminal_step(master, "/exit", "Detached.")
        assert entered.wait(timeout=5) == 0
    finally:
        if entered.poll() is None:
            entered.kill()
            entered.wait(timeout=5)
        os.close(master)
    print("saved capture owner: pinned original bytes, preference-independent recovery, failed announcement, "
        "sync uncertainty, listing asymmetry", flush=True)


def silent_read_edit_cases():
    """Silent observation must not hide accepted draft edits with ECHO off."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-silent-edit."))
    home, store = state / "home", state / "store"
    home.mkdir(mode=0o700)
    host = caller = proxy = None
    completed = False
    try:
        host = fixture.start_host(store, None)
        for index, route in enumerate(("/v1/inspect-session", "/v1/activity-page")):
            reference = f"silent/{index}"
            run(home, "configure", "--store", store, "--session", reference,
                "--workspace", state, "--provider", "codex", "--model", "model-a")
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            held, release = threading.Event(), threading.Event()
            try:
                caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), reference],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                read_terminal(master, "› ")
                def hold(response):
                    held.set()
                    assert release.wait(15), "silent read was not released"
                    return response
                proxy = canonical.ReplyProxy(host, route, hold)
                terminal_gate(caller, master, held, ("silent observation", route))
                os.write(master, "visible café!\x1b[D\x1b[DX".encode())
                output = read_terminal(master, "› visible cafXé!", timeout=5)
                assert not release.is_set() and "Run Bash:" not in output
                release.set()
                before = set((home / ".config/rui/requests").glob("*.json"))
                os.write(master, b"\n")
                fixture.wait_for(lambda: len(set((home / ".config/rui/requests").glob("*.json")) - before) == 1,
                    "visible draft capture")
                record, = set((home / ".config/rui/requests").glob("*.json")) - before
                assert json.loads(record.read_bytes())["text"]["value"] == "visible cafXé!"
                os.write(master, b"\x03")
                _, errors = terminal_exit(caller, master)
                assert caller.returncode == 0, errors
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original
                print(f"silent observation: {route} visible Unicode edit and exact capture passed", flush=True)
            finally:
                release.set()
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                if proxy is not None:
                    proxy.close()
                    proxy = None
                os.close(master)
                os.close(slave)
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained silent-edit failure state: {state}", file=sys.stderr)


def opaque_session_commands_case():
    """Execute generated commands without losing opaque Session bytes in argv."""
    from control_integration import raw_request
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-opaque-session."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    reference = "human/nul\x00' é\n--last"
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("opaque-actions", [("bash", "opaque-deny", json.dumps({"cmd": "touch must-not-run", "timeout_ms": None})),
                                                   ("bash", "opaque-allow", json.dumps({"cmd": "touch allowed-once", "timeout_ms": None}))]),
        fixture.sse_answer("opaque-answer", "opaque-r", "opaque-m", "Opaque decisions complete.")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    ready_read, ready_write = os.pipe()
    host = entered = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for key, session in (("prefix", "human/nul"), ("opaque", reference)):
            body = {"version": "1", "kind": "configure", "store": str(store), "key": key,
                    "session": session, "configuration": {
                        **{name: {"state": "value", "value": value} for name, value in
                           (("workspace", str(state)), ("provider", "codex"), ("model", "model-a"))},
                        **{name: {"state": "omitted"} for name in
                           ("instructions", "tools", "permission_mode", "output_schema")}}}
            body["configuration"]["permission_mode"] = {"state": "value", "value": "ask"}
            head, answer = raw_request(host.rui_ready_fields["socket"], "/v1/configure", json.dumps(body).encode())
            assert b" 200 " in head and json.loads(answer)["answer"]["status"] == "accepted", (head, answer)
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "--last"],
            cwd=state, env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=slave)
        read_terminal(master, "› ")
        assert "Session: human/nul\\x00" in terminal_step(master, "/status")
        farewell = terminal_step(master, "/exit", "Resume: ")
        assert entered.wait(timeout=5) == 0
        command = farewell.split("Resume: ", 1)[1].split("\n", 1)[0]
        bin_dir = state / "bin"
        bin_dir.mkdir()
        (bin_dir / "rui").symlink_to(fixture.RUI)
        entered = subprocess.Popen(["bash", "-c", "exec " + command], cwd=state,
            env={**os.environ, "HOME": str(home), "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                 "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        read_terminal(master, "› ")
        actual = terminal_step(master, "/status")
        assert "Session: human/nul\\x00" in actual, (command, actual)
        os.write(master, b"propose two distinct Actions\n")
        proposal = action_ready(ready_read, master)
        for label, decision in (("Deny: ", "deny"), ("Allow once: ", "allow_once")):
            inspection = terminal_step(master, "/inspect-action", "Deny: ")
            inspection += action_ready(ready_read, master)
            while select.select([master], [], [], 0.05)[0]:
                inspection += os.read(master, 65536).decode().replace("\r\n", "\n")
            printed = inspection.split(label, 1)[1].split("\n", 1)[0]
            reply = subprocess.run(["bash", "-c", "exec " + printed + " --json"], cwd=state,
                env={**os.environ, "HOME": str(home), "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True, timeout=10)
            assert reply.returncode == 0, (printed, reply.stdout, reply.stderr)
            captured, admission = map(json.loads, reply.stdout.splitlines())
            saved = json.loads((home / ".config/rui/requests" / (captured["request"] + ".json")).read_bytes())
            assert admission["admission"]["answer"]["status"] == "accepted", admission
            assert saved["session"] == reference and saved["decision"] == decision
            assert saved["action"] == printed.rsplit(" --action ", 1)[1], (saved, printed)
            print(json.dumps({"printed": printed, "decision": decision, "exact_session": True}), flush=True)
        fixture.wait_for(lambda: (state / "allowed-once").exists(), "printed Allow executed its exact Action")
        assert (state / "allowed-once").exists() and not (state / "must-not-run").exists()
        terminal_step(master, "/exit", "Resume: ")
        assert entered.wait(timeout=5) == 0
        before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
        invalid_hex = ("", "0", "zz", "ff", "61" * 129)
        for route in ("resume", "allow-action", "deny-action"):
            extra = [] if route == "resume" else ["--action", "1"]
            negatives = [["--session-hex", value] for value in invalid_hex]
            negatives += [["--session-hex", "61", "--session-hex", "62"]]
            negatives += ([["--last", "--session-hex", "61"], ["--session-hex", "61", "other"],
                           ["other", "--session-hex", "61"]] if route == "resume" else
                          [["--session", "plain", "--session-hex", "61"],
                           ["--session-hex", "61", "--session", "plain"],
                           ["--session", "plain", "--session", "other"],
                           ["--session-hex", reference.encode().hex(), "--action", "1"],
                           ["--session-hex", reference.encode().hex(), "--action", "2"]])
            for flags in negatives:
                rejected = subprocess.run([str(fixture.RUI), route, "--store", str(store), *flags, *extra],
                    env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=10)
                assert rejected.returncode != 0 and b"InteractiveTerminalRequired" not in rejected.stderr, (route, flags, rejected)
        assert {path: path.read_bytes() for path in before} == before
        assert set((home / ".config/rui/requests").glob("*.json")) == set(before)
        completed = True
        print("opaque Session: actual printed resume preserves NUL and rejects a configured prefix lookalike", flush=True)
    finally:
        if sys.exc_info()[0] is not None:
            preserve_failure_metadata(state / "pty-failure.json", lambda: {
                "case": "opaque_session_commands", "error": sys.exc_info()[0].__name__,
                "caller_returncode": entered.poll() if entered is not None else None,
                "ready_pending": bool(select.select([ready_read], [], [], 0)[0]) if ready_read is not None else None,
                "terminal_pending": bool(select.select([master], [], [], 0)[0]) if master is not None else None,
            })
        if entered is not None and entered.poll() is None:
            entered.kill()
            entered.wait(timeout=5)
        for fd in (master, slave, ready_read, ready_write):
            if fd is not None:
                os.close(fd)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained opaque-Session failure state: {state}", file=sys.stderr)


def main():
    import canonical_failure_integration
    import terminal_restoration_integration
    opaque_session_commands_case()
    silent_read_edit_cases()
    command_entry_cases()
    persistent_opening_case()
    persistent_pending_case()
    persistent_input_cases()
    persistent_permission_case()
    persistent_permission_case("allow-action")
    persistent_permission_case("allow-action", exit_code=7)
    persistent_permission_case("allow-action", signal_failure=True)
    persistent_permission_case("allow-action", lost_reply=True)
    persistent_permission_case(fragmented_paste=True)
    persistent_permission_case(stale_target=True)
    terminal_restoration_integration.main()
    canonical_failure_integration.main()
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-human-cli."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    session = "human/bash"
    counter = workspace / "effect-count"
    arguments = json.dumps({"cmd": "printf x >> effect-count", "timeout_ms": None}, separators=(",", ":"))
    control_call = "human-call\x1b[1Ghidden\u202e"
    control_arguments = arguments + "\r  "
    sibling_started = state / "sibling-started"
    sibling_release = state / "sibling-release"
    sibling_effect = workspace / "sibling-effect"
    sibling_arguments = json.dumps({"cmd": f"touch {shlex.quote(str(sibling_started))}; "
        f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.05; done; "
        "printf y >> sibling-effect", "timeout_ms": None}, separators=(",", ":"))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("human-calls", [("bash", control_call, control_arguments)]),
        fixture.sse_answer("human-answer", "human-reason", "human-message", "first answer")[0],
        fixture.sse_answer("second-answer", "second-reason", "second-message", "second answer")[0],
        fixture.sse_tool_calls("sibling-calls", [("bash", "pending-call", arguments),
            ("bash", "running-call", sibling_arguments)]),
        fixture.sse_answer("sibling-answer", "sibling-reason", "sibling-message", "siblings done")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    failure_release = None
    stop_release = None
    observation_release = None
    race_predecessor_release = threading.Event()
    race_message_release = threading.Event()
    race_follower = None
    race_waiter = None
    terminal_waiter = None
    race_gate = state / "follow-queued-before-current"
    wait_gate = state / "wait-active-before-current"
    completed = False
    try:
        host = fixture.start_host(store, url)
        store_selection_cases(state, workspace, store)
        saved_capture_cases(state, store, workspace)
        preferences_home = state / "preferences-home"
        preferences_home.mkdir()
        fallback = preferences_home / ".local/share/rui/store"
        fresh_setup = run(preferences_home, "setup")
        assert f"Store: {fallback} (HOME fallback)" in fresh_setup
        assert "choose a supported provider" in fresh_setup and "Host: unavailable" in fresh_setup
        assert not (preferences_home / ".config").exists(), "inspection created private state"
        # The shorter preferences path fits while the unsaved Store fallback
        # does not. Independent provider publication still succeeds.
        max_path = os.pathconf(preferences_home, "PC_PATH_MAX")
        long_home = str(preferences_home) + "/." * ((max_path - 16 - len(str(preferences_home))) // 2)
        oversized_setup = run(long_home, "setup", "--provider", "codex")
        assert "Saved defaults" in oversized_setup and "Store unavailable" in oversized_setup
        assert "no alternate Store selected" in oversized_setup and "Host: unavailable" in oversized_setup
        assert (preferences_home / ".config/rui/preferences").read_text().endswith("provider=codex\nmodel=\n")
        invalid_home = os.fsencode(state) + b"/home-\xff"
        try:
            os.mkdir(invalid_home, mode=0o700)
        except OSError as err:
            if err.errno != errno.EILSEQ:
                raise
            # macOS filesystems may reject this name before Rui sees HOME.
        invalid = subprocess.run([os.fsencode(fixture.RUI), b"setup", b"--provider", b"codex"],
            env={**os.environb, b"HOME": invalid_home}, capture_output=True, timeout=20)
        assert invalid.returncode != 0 and b"InvalidHome" in invalid.stderr, invalid
        assert not os.path.exists(invalid_home + b"/.config"), invalid
        bidi_store = state / "store-\u202ehidden"
        bidi_store.mkdir(mode=0o700)
        bidi_home = state / "bidi-home"
        bidi_home.mkdir()
        canonical_bidi_store = bidi_store.resolve()
        assert "Store: " + str(canonical_bidi_store).replace("\u202e", "\\u202e") + " (saved)" in run(
            bidi_home, "setup", "--store", bidi_store)
        assert f"store={canonical_bidi_store}\n" in (bidi_home / ".config/rui/preferences").read_text()
        assert "HomeUnavailable" in subprocess.run([str(fixture.RUI), "setup"],
            env={key: value for key, value in os.environ.items() if key != "HOME"},
            capture_output=True, text=True).stderr
        alias = state / "store-alias"
        alias.symlink_to(store, target_is_directory=True)
        assert "Saved defaults" in run(preferences_home, "setup", "--store", alias,
            "--provider", "codex", "--model", "gpt-6-luna")
        saved = preferences_home / ".config/rui/preferences"
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        preference_edits(preferences_home, store)
        original_preferences = saved.read_text()
        saved.write_text(original_preferences.replace("model=gpt-6-luna", "model=family=variant"))
        assert saved.read_text().endswith("provider=codex\nmodel=family=variant\n")
        assert "Model: family=variant" in run(preferences_home, "setup")
        saved.write_text(original_preferences)
        assert saved.stat().st_mode & 0o777 == 0o600
        assert saved.parent.stat().st_mode & 0o777 == 0o700
        missing_setup = run(preferences_home, "setup")
        assert str(store.resolve()) in missing_setup
        assert "credential: missing" in missing_setup and "No fallback" in missing_setup
        assert "Host: ready without managed Codex" in missing_setup
        linked_home = state / "linked-home"
        (linked_home / ".config").mkdir(parents=True)
        (linked_home / ".config/rui").symlink_to(saved.parent, target_is_directory=True)
        assert run(linked_home, "setup", "--store", store,
            "--provider", "codex", "--model", "gpt-6-luna", success=False) == ""
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        backup = saved.parent / "saved-preferences"
        saved.rename(backup)
        os.mkfifo(saved, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
        finally:
            saved.unlink()
            backup.rename(saved)
        retired_store = state / "retired-store"
        retired_store.mkdir(mode=0o700)
        assert "Saved defaults" in run(preferences_home, "setup", "--store", retired_store)
        retired_store.rmdir()
        unavailable_setup = run(preferences_home, "setup")
        assert str(retired_store) in unavailable_setup and "Store unavailable" in unavailable_setup
        assert "no alternate Store selected" in unavailable_setup and "Host: unavailable" in unavailable_setup
        assert "Saved defaults" in run(preferences_home, "setup", "--clear-model")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        assert f"store={retired_store}\n" in saved.read_text()
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        assert "Saved defaults" in run(preferences_home, "setup", "--store", store)
        assert f"store={store.resolve()}\n" in saved.read_text()
        credential = saved.parent / "codex.json"
        lock = saved.parent / ".codex.json.lock"
        assert not credential.exists() and not lock.exists()
        codex_fixture.credentials(credential)
        configured_setup = run(preferences_home, "setup")
        assert "credential: configured locally" in configured_setup and "remote acceptance not checked" in configured_setup
        assert not lock.exists(), "status must not create a credential lock"
        fresh_provider_home = state / "fresh-provider-home"
        (fresh_provider_home / ".config/rui").mkdir(parents=True, mode=0o700)
        codex_fixture.credentials(fresh_provider_home / ".config/rui/codex.json")
        assert "Saved defaults" in run(fresh_provider_home, "setup", "--model", "gpt-6-luna")
        assert (fresh_provider_home / ".config/rui/preferences").read_text().endswith(
            "store=\nprovider=codex\nmodel=gpt-6-luna\n")
        credential.unlink()
        os.mkfifo(credential, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode == 0 and "credential: error" in blocked.stdout, blocked
        finally:
            credential.unlink()
        codex_fixture.credentials(credential, state="refresh_pending")
        assert "credential: refresh required" in run(preferences_home, "setup")
        assert "state=refresh_pending" in credential.read_text(), "status must not refresh"
        credential.chmod(0o644)
        assert "credential: error" in run(preferences_home, "setup")
        credential.unlink()
        assert run(preferences_home, "setup", "--provider", "other", success=False) == ""
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "other-model")
        assert saved.read_text().endswith("model=other-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        assert run(preferences_home, "setup", "--store", state / "missing", success=False) == ""
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        # A directory in the temporary-file slot is an honest save failure;
        # no partial replacement may appear as a saved preference.
        temp = saved.parent / "preferences.tmp"
        temp.mkdir()
        blocked = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
            env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=2)
        assert blocked.returncode != 0 and "save failed: InsecurePreferenceFile" in blocked.stderr, blocked
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        temp.rmdir()
        os.mkfifo(temp, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
            assert saved.read_text().endswith("model=gpt-6-luna\n")
        finally:
            temp.unlink()
        codex_fixture.credentials(credential)
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        stale = run(preferences_home, "setup")
        assert "credential: configured locally" in stale and "saved provider is unsupported; no fallback" in stale
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--store", store)
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex", "--model", "gpt-6-luna")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=old-model\n")
        assert "Next Session: codex / old-model" in run(preferences_home, "setup")
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        saved.rename(saved.parent / "preferences.backup")
        sole = run(preferences_home, "setup")
        assert "Provider: not selected" in sole and "Next Session: codex / gpt-6-luna" in sole
        (saved.parent / "preferences.backup").rename(saved)
        credential.unlink()
        saved.write_text("version=9\n")
        assert run(preferences_home, "setup", success=False) == ""
        assert run(preferences_home, "setup", "--model", "another-model", success=False) == ""
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o644)
        assert run(preferences_home, "setup", success=False) == ""
        saved.chmod(0o600)
        saved.rename(saved.parent / "real-preferences")
        saved.symlink_to("real-preferences")
        assert run(preferences_home, "setup", success=False) == ""
        saved.unlink()
        (saved.parent / "real-preferences").rename(saved)
        assert run(preferences_home, "setup", "--model", "bad\nmodel", success=False) == ""
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        config = admit(home, "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        # A one-shot read selects the saved Store; explicit targeting bypasses
        # even corrupt preferences, and an invalid saved destination never falls back.
        assert json.loads(run(preferences_home, "wait-session", "--session", session,
            "--json")) == {"return": "idle"}
        saved.write_text("version=9\n")
        assert run(preferences_home, "wait-session", "--session", session,
            "--json", success=False) == ""
        assert json.loads(run(preferences_home, "wait-session", "--store", store,
            "--session", session, "--json")) == {"return": "idle"}
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", session], env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Session:" not in read_terminal(master, "› ")
            assert f"Session: {session}" in terminal_step(master, "/status")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        saved.unlink()
        fallback.parent.mkdir(parents=True)
        fallback.symlink_to(store, target_is_directory=True)
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--session", session],
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Session:" not in read_terminal(master, "› ")
            assert f"Session: {session}" in terminal_step(master, "/status")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        fallback.unlink()
        saved.write_text(f"version=1\nstore={state / 'missing'}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o600)
        assert run(preferences_home, "wait-session", "--session", session,
            "--json", success=False) == ""
        master, slave = pty.openpty()
        entered = subprocess.run([str(fixture.RUI), "session", "--session", session],
            env={**os.environ, "HOME": str(preferences_home)}, stdin=slave,
            stdout=slave, stderr=subprocess.PIPE, timeout=5)
        os.close(slave)
        os.close(master)
        assert entered.returncode != 0 and b"FileNotFound" in entered.stderr, entered.stderr
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        before = run(preferences_home, "requests", "--json")
        invalid_store = subprocess.run([str(fixture.RUI), "message", "--store", "",
            "--session", session, "not sent"], env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=5)
        assert invalid_store.returncode != 0 and "InvalidStore" in invalid_store.stderr, invalid_store
        assert invalid_store.stdout == "" and run(preferences_home, "requests", "--json") == before
        no_tty_home = state / "no-tty-home"
        no_tty_home.mkdir()
        for flags in ([], ["--persistent"]):
            no_terminal = subprocess.run([str(fixture.RUI), *flags], cwd=workspace,
                env={**os.environ, "HOME": str(no_tty_home)}, capture_output=True, text=True, timeout=5)
            assert no_terminal.returncode != 0 and "InteractiveTerminalRequired" in no_terminal.stderr
        assert not (no_tty_home / ".config").exists(), "non-TTY invocation created preferences or a request"
        assert not (no_tty_home / ".local/share/rui/store").exists(), "non-TTY invocation changed the Store"
        before_missing = set(run(preferences_home, "requests").splitlines())
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            deferred = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            offered = provider_prompt(master, ready_read)
            assert "No locally ready provider" in offered and "Codex login" in offered, offered
            assert "No new Session created" in terminal_step(master, "d", "No new Session created")
            assert deferred.wait(timeout=5) == 0
            assert set(run(preferences_home, "requests").splitlines()) == before_missing
        finally:
            if deferred.poll() is None:
                deferred.kill()
                deferred.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        explicit_home = state / "explicit-home"
        explicit_config = explicit_home / ".config/rui"
        explicit_config.mkdir(parents=True, mode=0o700)
        malformed = explicit_config / "preferences"
        malformed.write_text("version=9\n")
        malformed.chmod(0o600)
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            explicit = subprocess.Popen([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "No locally ready provider" in provider_prompt(master, ready_read)
            # Another client installs a fixture credential while this caller
            # waits for a choice. Its explicit selectors must still bypass the
            # malformed prospective defaults when it rechecks readiness.
            codex_fixture.credentials(explicit_config / "codex.json")
            os.write(master, b"d\n")
            welcome = b""
            deadline = time.monotonic() + 10
            while "› ".encode("utf-8") not in welcome and time.monotonic() < deadline:
                if not select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                    break
                try:
                    welcome += os.read(master, 65536)
                except OSError as err:
                    if err.errno != errno.EIO:
                        raise
                    break
            welcome = welcome.decode(errors="replace")
            assert all(noise not in welcome for noise in ("Session:", "Provider:", "Model:", "request:")), welcome
            record, = (explicit_config / "requests").glob("*.json")
            saved = json.loads(record.read_bytes())
            assert saved["session"] == f"rui/{record.stem}" and saved["configuration"]["model"] == {"state": "value", "value": "gpt-6-luna"}, saved
            binding = terminal_step(master, "/status")
            assert f"Session: {saved['session']}" in binding and "Provider: codex" in binding and "Model: gpt-6-luna" in binding and "Permission: bypass" in binding, binding
            assert malformed.read_text() == "version=9\n"
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert explicit.wait(timeout=5) == 0
        finally:
            if explicit.poll() is None:
                explicit.kill()
                explicit.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        # A valid opaque credential arrives while the prompt is open, then
        # becomes renewal-due before the choice. It remains usable for creation.
        (explicit_config / "codex.json").unlink()
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            expiring = subprocess.Popen([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "No locally ready provider" in provider_prompt(master, ready_read)
            expiry = int(time.time()) + 2
            credential_file = explicit_config / "codex.json"
            codex_fixture.credentials(credential_file)
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", f"expires_at={expiry}"))
            assert "credential: error" in run(preferences_home, "setup", environment={"RUI_CODEX_CREDENTIAL_FILE": str(credential_file)}), "JWT/record expiry mismatch was accepted"
            codex_fixture.credentials(credential_file, access="synthetic-opaque-access")
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", "expires_at=0").replace("refreshed_at=1750000000", f"refreshed_at={expiry - 8 * 24 * 60 * 60}"))
            while time.time() < expiry:
                time.sleep(0.01)
            assert "usable locally; renewal due at dispatch" in run(preferences_home, "setup", environment={"RUI_CODEX_CREDENTIAL_FILE": str(credential_file)})
            welcome = terminal_step(master, "d", "› ")
            assert "Session:" not in welcome and "Permission:" not in welcome, welcome
            binding = terminal_step(master, "/status")
            assert "Session: rui/" in binding and "Permission: bypass" in binding, binding
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert expiring.wait(timeout=5) == 0
            assert malformed.read_text() == "version=9\n"
        finally:
            if expiring.poll() is None:
                expiring.kill()
                expiring.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        longer_store = state / "another-longer-store-selector"
        other_host = fixture.start_host(longer_store, url)
        try:
            for index, (before, after) in enumerate(((store, longer_store), (longer_store, store))):
                changing_home = state / f"changing-home-{index}"
                changing_home.mkdir()
                assert "Saved defaults" in run(changing_home, "setup", "--store", before,
                    "--provider", "codex", "--model", "gpt-6-luna")
                master, slave = pty.openpty()
                ready_read, ready_write = os.pipe()
                try:
                    changing = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                        env={**os.environ, "HOME": str(changing_home),
                            "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                        pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    os.close(master)
                    os.close(ready_read)
                    raise
                finally:
                    os.close(slave)
                    os.close(ready_write)
                try:
                    assert "No locally ready provider" in provider_prompt(master, ready_read)
                    assert "Saved defaults" in run(changing_home, "setup", "--store", after)
                    codex_fixture.credentials(changing_home / ".config/rui/codex.json")
                    welcome = terminal_step(master, "d")
                    assert all(noise not in welcome for noise in ("Diagnostics:", "request:", "Session:")), welcome
                    record, = (changing_home / ".config/rui/requests").glob("*.json")
                    handle = record.stem
                    selected = json.loads(record.read_bytes())
                    assert selected["store"] == str(after.resolve()), selected
                    current = fixture.command("inspect-session", "--store", after,
                        "--session", f"rui/{handle}")
                    assert current["session"]["model"] == "gpt-6-luna", current
                    assert "Detached." in terminal_step(master, "/exit", "Detached.")
                    assert changing.wait(timeout=5) == 0
                finally:
                    if changing.poll() is None:
                        changing.kill()
                        changing.wait(timeout=5)
                    os.close(ready_read)
                    os.close(master)
        finally:
            fixture.stop_host(other_host)
        codex_fixture.credentials(credential)
        for tools, mode, warning in (("none", "bypass", False), ("edit", "bypass", False),
                                     ("bash,edit", "bypass", True), ("bash", "ask", False)):
            warning_ref = f"warnings/{tools}/{mode}"
            admit(preferences_home, "configure", "--store", store, "--session", warning_ref,
                  "--workspace", workspace, "--provider", "codex", "--model", "model-a",
                  "--tools", tools, "--permission-mode", mode)
            listing = run(preferences_home, "sessions", "--store", store, "--all")
            selected = listing.split(f"Session: {warning_ref}\n", 1)[1].split("Session: ", 1)[0]
            assert "Bash runs without approval" not in selected, selected
            assert f"Permission: {mode}\n" in selected, selected
            master, slave = pty.openpty()
            caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store), "--session", warning_ref],
                env={**os.environ, "HOME": str(preferences_home)}, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                welcome = read_terminal(master, "› ")
                assert "Permission:" not in welcome, welcome
                assert ("Bash runs without approval" in welcome) == warning, welcome
                assert "Bash commands can run without asking you" not in welcome, welcome
                status = terminal_step(master, "/status")
                assert f"Permission: {mode}\n" in status, status
                assert fixture.command("inspect-session", "--store", store, "--session", warning_ref)["session"]["permission_mode"] == mode
                assert "Bash runs without approval" not in status, status
                terminal_step(master, "/exit", "Detached.")
                assert caller.wait(timeout=5) == 0
            finally:
                if caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                os.close(master)
        created = []
        records = preferences_home / ".config/rui/requests"
        for persistent in (False, False, True, True):
            before_records = set(records.glob("*.json"))
            master, slave = pty.openpty()
            caller = subprocess.Popen([str(fixture.RUI), *(["--persistent"] if persistent else [])], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                welcome = read_terminal(master, "› ")
                assert "Attached to the ready Host" not in welcome and "Diagnostics:" not in welcome, welcome
                new_records = set(records.glob("*.json")) - before_records
                assert len(new_records) == 1, new_records
                handle = new_records.pop().stem
                reference = f"rui/{handle}"
                saved = json.loads((records / f"{handle}.json").read_bytes())
                assert saved["require_model"] is True and saved["store"] == str(store.resolve())
                assert saved["session"] == reference and saved["configuration"]["workspace"] == {"state": "value", "value": str(workspace.resolve())}
                mode = "bypass"
                assert saved["configuration"]["tools"] == {"state": "value", "value": ["bash"]} and saved["configuration"]["permission_mode"] == {"state": "value", "value": mode}
                assert all(noise not in welcome for noise in ("request:", "New Session intent:", reference, "Workspace:", "Provider:", "Permission:")), welcome
                status = terminal_step(master, "/status")
                assert f"Session: {reference}" in status and "Permission: bypass" in status, status
                assert "Bash runs without approval" in welcome, welcome
                assert "Bash commands can run without asking you" not in welcome, welcome
                current = fixture.command("inspect-session", "--store", store, "--session", reference)
                assert current["session"]["permission_mode"] == mode, current
                assert current["session"]["workspace"] == str(workspace.resolve()), current
                assert current["session"]["provider"] == "codex" and current["session"]["model"] == "gpt-6-luna", current
                assert json.loads(run(preferences_home, "recover", handle, "--json"))["answer"]["replayed"] is True
                created.append(reference)
                assert "Detached." in terminal_step(master, "/exit", "Detached.")
                assert caller.wait(timeout=5) == 0
            finally:
                if caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                os.close(master)
        assert len(set(created)) == 4, "independent new intent reused a reference"
        blocked_home = state / "blocked-capture-home"
        blocked_config = blocked_home / ".config/rui"
        blocked_config.mkdir(parents=True, mode=0o700)
        (blocked_config / "preferences").write_text(
            f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        (blocked_config / "preferences").chmod(0o600)
        (blocked_config / "requests").write_text("not a directory")
        codex_fixture.credentials(blocked_config / "codex.json")
        sessions_before = run(preferences_home, "sessions", "--store", store, "--all", "--json")
        master, slave = pty.openpty()
        original_mode = termios.tcgetattr(master)
        blocked = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(blocked_home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            # Capture fails before the send/uncertain-admission diagnostic.
            output = read_terminal(master, "error: NotDir")
            assert blocked.wait(timeout=5) == 1
            # The reaped caller has closed its PTY. Include any final output
            # before checking that no intent, handle or prompt escaped.
            while True:
                assert select.select([master], [], [], 0)[0], "failed caller retained its terminal"
                try:
                    tail = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not tail:
                    break
                output += tail.decode(errors="replace")
                assert len(output.encode()) < 1024 * 1024
            assert "New Session intent" not in output and "request: " not in output and "› " not in output, output
            assert termios.tcgetattr(master) == original_mode
            assert (blocked_config / "requests").read_text() == "not a directory"
            assert run(preferences_home, "sessions", "--store", store, "--all", "--json") == sessions_before
        finally:
            if blocked.poll() is None:
                blocked.kill()
                blocked.wait(timeout=5)
            os.close(master)
        before = set(run(preferences_home, "requests").splitlines())
        gate = state / "new-session-capture"
        master, slave = pty.openpty()
        interrupted = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "fresh configuration captured")
            early = os.read(master, 65536) if select.select([master], [], [], 0)[0] else b""
            assert b"New Session intent" not in early, "announced before the capture callback"
            after = set(run(preferences_home, "requests").splitlines())
            assert len(after - before) == 1, (before, after)
            handle = (after - before).pop()
            captured = json.loads((preferences_home / ".config/rui/requests" / f"{handle}.json").read_text())
            assert captured["require_model"] is True, captured
            interrupted.kill()
            interrupted.wait(timeout=5)
            recovered = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered["answer"]["status"] == "accepted" and not recovered["answer"]["replayed"], recovered
            recovered_again = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered_again["answer"]["replayed"], recovered_again
            assert fixture.command("inspect-session", "--store", store,
                "--session", f"rui/{handle}")["session"]["permission_mode"] == "bypass"
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.wait(timeout=5)
            os.close(master)
        credential.unlink()
        initial = fixture.command("inspect-session", "--store", store, "--session", session)
        assert initial["selected_message"] is None and initial["recent_messages"] == [], initial
        assert "InteractiveTerminalRequired" in subprocess.run(
            [str(fixture.RUI), "session", "--store", str(store), "--session", session],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5).stderr
        assert config["request"] in json.loads(run(home, "requests", "--json"))
        assert json.loads(run(home, "recover", config["request"], "--json"))["answer"]["replayed"] is True
        assert run(home, "recover", config["request"]) == (
            f"Store: {store}\nSession: {session}\nkey: {config['request']}\n"
            "admitted: accepted\nreplayed: true\nrevision: 1; created: true\n")

        text = state / "input"
        text.write_text("first input")
        dropped = run(home, "message", "--store", store, "--session", session,
            "--text", text, "--test-drop-reply", "after-commit", success=False)
        first = dropped.split("request: ", 1)[1].splitlines()[0]
        record = home / ".config/rui/requests" / f"{first}.json"
        captured = record.read_bytes()
        assert json.loads(captured)["text"]["value"] == "first input"
        text.write_text("changed after capture")
        assert first in run(home, "requests").splitlines()
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "first provider request")
        recovered = json.loads(run(home, "recover", first, "--json"))
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True
        assert record.read_bytes() == captured
        assert len(endpoint.requests) == 1, endpoint.requests

        attention = run(home, "follow", first)
        assert "return: attention" in attention and "status: waiting_for_permission" in attention, attention
        action = attention.split("action: ", 1)[1].splitlines()[0]
        selected, blocked = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", session, "--json").splitlines())
        assert selected == {"event": "selection", "session": session, "message": first}, selected
        assert blocked == {"return": "attention", "status": "waiting_for_permission", "action": action}, blocked
        terminal_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", session, "--terminal", "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert json.loads(terminal_waiter.stdout.readline()) == selected
        time.sleep(0.1)
        assert terminal_waiter.poll() is None, "terminal-only wait returned on permission"
        queued = admit(home, "message", "--store", store, "--session", session,
            "queued behind permission")["request"]
        assert run(home, "result", queued) == "admitted: accepted\nresult: queued\n"
        queued_fact = fixture.command("observe-command", "--store", store, "--key", queued)["observation"]
        assert queued_fact["queue"]["status"] == "queued" and queued_fact["progress"] == {
            "status": "waiting_for_permission", "action": action}, queued_fact
        scratch = state / "render-scratch"
        scratch.mkdir()
        render_environment = {"TMPDIR": str(scratch)}
        queued_attention = json.loads(run(home, "follow", queued, "--json", environment=render_environment))
        assert queued_attention == {"return": "attention", "status": "waiting_for_permission", "action": action}, queued_attention
        presentation = run(home, "inspect-action", "--store", store, "--session", session, "--action", action)
        assert f"Action {action}\n" in presentation, presentation
        assert json.loads(presentation.split("call ID: ", 1)[1].splitlines()[0]) == control_call, presentation
        assert json.loads(presentation.split("Bash arguments: ", 1)[1].splitlines()[0]) == control_arguments, presentation
        assert "\\u001b" in presentation and "\\u202e" in presentation and "\\r  " in presentation, presentation
        assert "\x1b" not in presentation and "\u202e" not in presentation and "\r" not in presentation, presentation
        fresh_home = state / "fresh-home"
        fresh_home.mkdir()
        assert not (fresh_home / ".config").exists()
        assert json.loads(run(fresh_home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json", environment=render_environment)) == {"action": action, "call_id": control_call, "arguments": control_arguments}
        assert not (fresh_home / ".config").exists()
        assert list(scratch.iterdir()) == []
        unavailable = subprocess.run([str(fixture.RUI), "inspect-action", "--store", str(store),
            "--session", session, "--action", action, "--json"],
            env={**os.environ, "HOME": str(fresh_home), "TMPDIR": str(state / "missing-scratch")},
            capture_output=True, text=True, timeout=20)
        assert unavailable.returncode != 0 and unavailable.stdout == "", unavailable
        exact = json.loads(run(home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json"))
        assert exact == {"action": action, "call_id": control_call, "arguments": control_arguments}, exact
        assert run(home, "result", first) == "admitted: accepted\nresult: processing\n"
        assert not counter.exists()

        lost_decision = run(home, "allow-action", "--store", store, "--session", session,
            "--action", action, "--test-drop-reply", "after-commit", success=False)
        decision_key = lost_decision.split("request: ", 1)[1].splitlines()[0]
        assert decision_key in run(home, "requests").splitlines()
        recovered_decision = json.loads(run(home, "recover", decision_key, "--json"))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, queued), "queued answer after permission")
        terminal_output, terminal_error = terminal_waiter.communicate(timeout=10)
        assert terminal_waiter.returncode == 0 and json.loads(terminal_output)["observation"]["result"]["status"] == "completed", terminal_error
        terminal_waiter = None
        stale = admit(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert run(home, "result", queued) == "admitted: accepted\nresult: completed\nfirst answer\n"
        current = fixture.command("inspect-session", "--store", store, "--session", session)
        assert current["selected_message"] is None and [r["message"] for r in current["recent_messages"]] == [queued, first], current
        assert [r["outcome"] for r in current["recent_messages"]] == ["completed", "completed"], current
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "session", "--session", session],
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            greeting = read_terminal(master, "› ")
            assert all(noise not in greeting for noise in ("Session:", "Workspace:", "Provider:", "Model:", "Permission:", "Store:", queued)), greeting
            assert "\n› first input" in greeting and "\n  first answer" in greeting, greeting
            binding = terminal_step(master, "/status")
            assert f"Session: {session}" in binding and f"Workspace (Bash cwd): {workspace.resolve()}" in binding, binding
            assert "Provider: codex" in binding and "Model: model-a" in binding and "Permission: ask" in binding, binding
            help_text = terminal_step(master, "/help")
            for command in ("/status", "/inspect-action", "/details", "/history", "/requests", "/result KEY", "/setup", "/configure", "/exit", "Ctrl-R"):
                assert command in help_text, help_text
            assert "/wait" not in help_text and "/login" not in help_text and "rui login codex" in help_text, help_text
            assert "result: completed\nfirst answer" in terminal_step(master, f"/result {queued}")
            assert "Local recovery handles" in terminal_step(master, "/requests")
            assert not (fresh_home / ".config/rui/requests").exists(), "re-entry should not require saved records"
            before_unsupported = set(run(preferences_home, "requests").splitlines())
            for command, notice in (("/wait", "Work continues while you compose."),
                                    ("/login", "Login uses rui login codex in your shell.")):
                assert notice in terminal_step(master, command)
                assert set(run(preferences_home, "requests").splitlines()) == before_unsupported
            assert "gpt-6-luna" in terminal_step(master, "/setup")
            assert "Permission: ask" in terminal_step(master, "/status")
            assert not credential.exists(), "unsupported in-session login created credentials"
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model gpt-6-luna")
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model other-model")
            interactive_saved = preferences_home / ".config/rui/preferences"
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --clear-model")
            assert interactive_saved.read_text().endswith("provider=codex\nmodel=\n")
            cleared_preferences = interactive_saved.read_bytes()
            for command, error in (("/setup --clear-model --model gpt-6-luna", "ConflictingPreferenceModelEdit"),
                                   ("/setup --model gpt-6-luna --clear-model", "ConflictingPreferenceModelEdit"),
                                   ('/setup --model ""', "InvalidPreferenceModel")):
                assert error in terminal_step(master, command)
                assert interactive_saved.read_bytes() == cleared_preferences
            assert "Permission: ask" in terminal_step(master, "/status")
            active = fixture.command("inspect-session", "--store", store, "--session", session)["session"]
            assert active["model"] == "model-a" and active["permission_mode"] == "ask", active
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model gpt-6-luna")
            spaced_store = state / "spaced store"
            spaced_store.mkdir(mode=0o700)
            assert "Saved defaults for future Sessions" in terminal_step(master, f'/setup --store "{spaced_store}"')
            assert str(spaced_store.resolve()) in run(preferences_home, "setup")
            quoted_store = state / 'quoted "store"'
            quoted_store.mkdir(mode=0o700)
            escaped_store = str(quoted_store).replace('"', r'\"')
            assert "Saved defaults for future Sessions" in terminal_step(
                master, f'/setup --store "{escaped_store}"')
            assert str(quoted_store.resolve()).replace('"', r'\"') in run(preferences_home, "setup")
            assert "Usage: /setup" in terminal_step(master, '/setup --store "unfinished')
            assert str(quoted_store.resolve()).replace('"', r'\"') in run(preferences_home, "setup")
            assert "Saved defaults for future Sessions" in terminal_step(master, f'/setup --store "{store}"')
            assert "Permission: ask" in terminal_step(master, "/status")
            assert fixture.command("inspect-session", "--store", store,
                "--session", session)["session"]["model"] == "model-a"
            assert "Usage: /configure" in terminal_step(master, "/configure --session human/other")
            assert "Use a file for" in terminal_step(master, "/configure --instructions -")
            assert "Use a file for" in terminal_step(master, "/configure --output-schema -")
            assert f"Session: {session}" in terminal_step(master, "/status")
            configured = terminal_step(master, '/configure --model "model-a"')
            assert "Configured." in configured and "request:" not in configured, configured
            assert f"Session: {session}" in terminal_step(master, "/status")
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        assert run(home, "follow", queued) == "return: outcome\nadmitted: accepted\nstatus: completed\n"
        assert run(home, "recover", stale["request"]) == (
            f"Store: {store}\nSession: {session}\nkey: {stale['request']}\n"
            f"target Action: {action}; decision: deny\n"
            "admitted: rejected\nreplayed: true\ncode: action_not_pending\n")
        stale_default = run(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        stale_key = stale_default.splitlines()[0].removeprefix("request: ")
        assert stale_default == (
            f"request: {stale_key}\nStore: {store}\nSession: {session}\nkey: {stale_key}\n"
            f"target Action: {action}; decision: deny\n"
            "admitted: rejected\nreplayed: false\ncode: action_not_pending\n"), stale_default
        assert run(home, "result", first) == "admitted: accepted\nresult: completed\nfirst answer\n"
        completed_result = json.loads(run(home, "result", first, "--json", environment=render_environment))
        assert completed_result["answer"] == "first answer"
        assert completed_result["observation"]["result"]["status"] == "completed"
        assert list(scratch.iterdir()) == []
        completed_follow = json.loads(run(home, "follow", first, "--json"))
        assert completed_follow["return"] == "outcome"
        assert completed_follow["observation"]["result"]["status"] == "completed"
        assert counter.read_text() == "x"

        before = set(run(home, "requests").splitlines())
        gate = state / "captured-before-handle"
        caller = subprocess.Popen(
            [str(fixture.RUI), "message", "--store", str(store), "--session", session,
             "--text", str(text), "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "durable capture before handle output")
        after = set(run(home, "requests").splitlines())
        assert len(after - before) == 1, (before, after)
        second = (after - before).pop()
        assert caller.poll() is None
        assert fixture.command("observe-command", "--store", store,
            "--key", second)["observation"]["status"] == "absent"
        caller.kill()
        output, _ = caller.communicate(timeout=5)
        assert caller.returncode == -signal.SIGKILL and output == b"", output
        assert second != first
        text.unlink()
        initial_recovery = json.loads(run(home, "recover", second, "--json"))["answer"]
        assert initial_recovery["status"] == "accepted" and initial_recovery["replayed"] is False
        fixture.wait_for(lambda: fixture.completed_observation(store, second), "second saved answer")
        assert run(home, "result", first) == "admitted: accepted\nresult: completed\nfirst answer\n"
        assert run(home, "result", second) == "admitted: accepted\nresult: completed\nsecond answer\n"
        assert counter.read_text() == "x" and len(endpoint.requests) == 3

        fixture.stop_host(host)
        host = fixture.start_host(store, url, active_capacity=2)
        sibling_session = "human/siblings"
        sibling_config = run(home, "configure", "--store", store, "--session", sibling_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert f"configuration: {sibling_session} in {store}" in sibling_config
        assert "next: rui session (same Store and Session)" in sibling_config
        sibling_key = admit(home, "message", "--store", store, "--session", sibling_session,
            "two independent Actions")["request"]
        def two_actions():
            candidate = fixture.command("inspect-session", "--store", store, "--session", sibling_session)
            return candidate if len(candidate["actionable_permissions"]) == 2 else None

        report = fixture.wait_for(two_actions, "two actionable siblings")
        pending, running = [row["action"] for row in report["actionable_permissions"]]
        selection, permissions, attention = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", sibling_session, "--json").splitlines())
        assert selection["message"] == sibling_key, selection
        assert permissions == {"event": "actionable_permissions", "actions": [pending, running]}, permissions
        assert attention["return"] == "attention" and attention["action"] == pending, attention
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", sibling_session], env={**os.environ, "HOME": str(fresh_home),
                "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,),
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            deadline = time.monotonic() + 15
            opening = read_terminal(master, "a: Allow once / d: Deny (Enter)", timeout=deadline - time.monotonic())
            opening += action_ready(ready_read, master, timeout=deadline - time.monotonic())
            deadline = time.monotonic() + 15
            os.write(master, b"/status\n")
            status = read_terminal(master, "a: Allow once / d: Deny (Enter)", timeout=deadline - time.monotonic())
            status += action_ready(ready_read, master, timeout=deadline - time.monotonic())
            assert status.count("Action requiring attention: ") == 2, status
            assert f"Action requiring attention: {pending}" in status and f"Action requiring attention: {running}" in status, status
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
            os.close(ready_read)
            os.close(ready_write)
        run(home, "allow-action", "--store", store, "--session", sibling_session,
            "--action", running)
        fixture.wait_for(lambda: sibling_started.exists(), "approved sibling in flight")
        attention = run(home, "follow", sibling_key, "--json")
        assert json.loads(attention) == {"return": "attention", "status": "in_flight", "action": pending}, attention
        assert run(home, "result", sibling_key) == "admitted: accepted\nresult: processing\n"
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", sibling_session], env={**os.environ, "HOME": str(home),
                "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,),
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            waiting = read_terminal(master, "a: Allow once / d: Deny (Enter)")
            waiting += action_ready(ready_read, master)
            assert "Run Bash:\n  printf x >> effect-count" in waiting, waiting
            assert counter.read_text() == "x" and not sibling_effect.exists(), "opening authorized pending sibling"
            run(home, "deny-action", "--store", store, "--session", sibling_session,
                "--action", pending)
            sibling_release.touch()
            rejected = terminal_step(master, "a", "action_not_pending")
            assert "Decision rejected" in rejected and counter.read_text() == "x", rejected
            if "› " not in rejected.split("action_not_pending", 1)[1]:
                rejected += read_terminal(master, "› ")
            caught_up = rejected + terminal_step(master, "/discard",
                "› " if "siblings done" in rejected else "siblings done", composer=True)
            assert "siblings done" in caught_up and counter.read_text() == "x", caught_up
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            sibling_release.touch()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
            os.close(ready_read)
            os.close(ready_write)
        fixture.wait_for(lambda: fixture.completed_observation(store, sibling_key), "sibling outcome")
        assert run(home, "result", sibling_key) == "admitted: accepted\nresult: completed\nsiblings done\n"
        assert sibling_effect.read_text() == "y" and counter.read_text() == "x"

        failure_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(b"permanent failure", {}, 422), failure_release),
            fixture.sse_answer("successor-answer", "successor-reason", "successor-message", "successor done")[0],
        ])
        failure_session = "human/failure"
        run(home, "configure", "--store", store, "--session", failure_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        failed_key = admit(home, "message", "--store", store, "--session", failure_session,
            "first failing Turn")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "held first failed Turn")
        queued_key = admit(home, "message", "--store", store, "--session", failure_session,
            "queued successor")["request"]
        assert run(home, "result", queued_key) == "admitted: accepted\nresult: queued\n"
        follower = subprocess.Popen([str(fixture.RUI), "follow", failed_key],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.15)
        assert follower.poll() is None, follower.communicate(timeout=5)
        follower.kill()
        follower.communicate(timeout=5)
        failure_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", failed_key)["observation"].get("result"), "failed first Turn")
        assert run(home, "result", failed_key) == "admitted: accepted\nresult: failed\ncode: provider_http_422\n"
        fixture.wait_for(lambda: fixture.completed_observation(store, queued_key), "queued successor")
        assert run(home, "result", queued_key) == "admitted: accepted\nresult: completed\nsuccessor done\n"
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", failure_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "› ")
            failed = terminal_step(master, f"/result {failed_key}")
            assert "result: failed" in failed, failed
            assert "code: provider_http_422" in failed and "successor done" not in failed, failed
            assert "result: completed\nsuccessor done" in terminal_step(master, f"/result {queued_key}")
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)

        stop_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("stopped-answer", "stopped-reason",
            "stopped-message", "must not appear")[0], stop_release))
        stop_session = "human/stopped"
        run(home, "configure", "--store", store, "--session", stop_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        stopped_key = admit(home, "message", "--store", store, "--session", stop_session,
            "running when stopped")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 8, "held stopped Turn")
        excluded_key = admit(home, "message", "--store", store, "--session", stop_session,
            "queued when stopped")["request"]
        assert run(home, "result", excluded_key) == "admitted: accepted\nresult: queued\n"
        stopped = fixture.command("stop-session", "--store", store, "--session", stop_session,
            "--record", state / "stop.json", "--key", "human-stop")
        assert stopped["answer"]["status"] == "accepted", stopped
        stop_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", stopped_key)["observation"].get("result"), "stopped Turn")
        assert run(home, "result", stopped_key).startswith("admitted: accepted\nresult: cancelled\n")
        assert run(home, "result", excluded_key) == "admitted: accepted\nresult: cancelled\ncode: session_stopped\n"

        rejected = admit(home, "message", "--store", store, "--session", "human/absent",
            "unknown session")
        assert rejected["admission"]["answer"]["status"] == "rejected", rejected
        assert run(home, "result", rejected["request"]) == "admitted: rejected\nresult: rejected\ncode: unknown_session\n"
        assert run(home, "recover", rejected["request"]) == (
            f"Store: {store}\nSession: human/absent\nkey: {rejected['request']}\n"
            "admitted: rejected\nreplayed: true\ncode: unknown_session\n")

        large_answer = "x" * 4095 + "🍰" + "y" * (128 * 1024)
        endpoint.responses.append(fixture.sse_answer("large-answer", "large-reason",
            "large-message", large_answer)[0])
        large_session = "human/large"
        run(home, "configure", "--store", store, "--session", large_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        large_key = admit(home, "message", "--store", store, "--session", large_session,
            "large output")["request"]
        fixture.wait_for(lambda: fixture.completed_observation(store, large_key), "large saved answer")
        reader = subprocess.Popen([str(fixture.RUI), "result", large_key, "--json"],
            env={**os.environ, "HOME": str(home), **render_environment},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert reader.stdout.read(256).startswith(b'{"observation":')
            assert reader.poll() is None, "large result should block on unread stdout"
            assert list(scratch.iterdir()) == [], "rendering must not leave a named payload"
        finally:
            if reader.poll() is None:
                reader.kill()
            reader.communicate(timeout=5)
        assert reader.returncode == -signal.SIGKILL and list(scratch.iterdir()) == []
        assert json.loads(run(home, "result", large_key, "--json", environment=render_environment))["answer"] == large_answer

        fixture.crash_host(host, state, "human-cli-crash")
        failed_observation = run(home, "result", first, success=False)
        assert failed_observation == "", failed_observation
        host = fixture.start_host(store, url)
        assert json.loads(run(home, "recover", first, "--json"))["answer"]["replayed"] is True
        assert run(home, "result", first) == "admitted: accepted\nresult: completed\nfirst answer\n"
        recovered_session = fixture.command("inspect-session", "--store", store, "--session", session)
        assert recovered_session["selected_message"] is None
        assert [row["message"] for row in recovered_session["recent_messages"]] == [second, queued, first]
        assert counter.read_text() == "x" and sibling_effect.read_text() == "y" and len(endpoint.requests) == 9

        endpoint.responses.extend([
            (fixture.sse_answer("race-prior", "race-prior-reason", "race-prior-message", "prior done")[0], race_predecessor_release),
            (fixture.sse_answer("race-a", "race-a-reason", "race-a-message", "A done")[0], race_message_release),
            fixture.sse_tool_calls("race-b", [("bash", "race-b-call", arguments)]),
            fixture.sse_answer("race-b-done", "race-b-done-reason", "race-b-done-message", "B done")[0],
        ])
        race_session = "human/follow-race"
        run(home, "configure", "--store", store, "--session", race_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        prior_receipt = run(home, "message", "--store", store, "--session", race_session, "prior")
        prior = prior_receipt.split("request: ", 1)[1].splitlines()[0]
        assert f"message: {race_session} in {store}" in prior_receipt
        assert "next: rui session (same Store and Session)" in prior_receipt
        assert "next: rui follow" not in prior_receipt
        fixture.wait_for(lambda: len(endpoint.requests) == 10, "held predecessor request")
        message_a = admit(home, "message", "--store", store, "--session", race_session, "A")["request"]
        assert run(home, "result", message_a) == "admitted: accepted\nresult: queued\n"
        race_follower = subprocess.Popen([str(fixture.RUI), "follow", message_a, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(race_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{race_gate}.ready").exists(), "queued A observed by follower")
        assert race_follower.poll() is None
        assert run(home, "result", message_a) == "admitted: accepted\nresult: queued\n"
        race_predecessor_release.set()
        fixture.wait_for(lambda: len(endpoint.requests) == 11, "A processing request")
        race_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", race_session, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(wait_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{wait_gate}.ready").exists(), "Session wait selected A")
        race_message_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, message_a), "A outcome before Current")
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "predecessor completion")
        message_b = admit(home, "message", "--store", store, "--session", race_session, "B")["request"]
        def b_action():
            report = fixture.command("inspect-session", "--store", store, "--session", race_session)
            return report["actionable_permissions"][0]["action"] if report["actionable_permissions"] else None

        action_b = fixture.wait_for(b_action, "B permission before Current")
        assert fixture.command("observe-command", "--store", store, "--key", message_a)["observation"]["result"]["status"] == "completed"
        pathlib.Path(f"{race_gate}.release").touch()
        pathlib.Path(f"{wait_gate}.release").touch()
        output, error = race_follower.communicate(timeout=10)
        assert race_follower.returncode == 0, (output, error)
        followed = json.loads(output)
        assert followed["return"] == "outcome" and followed["observation"]["result"]["status"] == "completed", followed
        assert followed["observation"]["target"] == race_session, followed
        race_follower = None
        wait_output, wait_error = race_waiter.communicate(timeout=10)
        assert race_waiter.returncode == 0, wait_error
        selection, observed = map(json.loads, wait_output.splitlines())
        assert selection["message"] == prior and observed["return"] == "outcome", wait_output
        assert observed["observation"]["result"]["status"] == "completed", wait_output
        race_waiter = None
        assert b_action() == action_b
        assert json.loads(run(home, "inspect-action", "--store", store, "--session", race_session,
            "--action", action_b, "--json"))["call_id"] == "race-b-call"
        denied = admit(home, "deny-action", "--store", store, "--session", race_session,
            "--action", action_b)
        assert denied["admission"]["answer"]["status"] == "accepted", denied
        fixture.wait_for(lambda: fixture.completed_observation(store, message_b), "B outcome after decision")
        control_call = "interactive-bash\x1b[1Ghidden\u202e"
        argument_prefix = '{"cmd":"printf x >> effect-count # '
        padded_arguments = json.dumps({"cmd": "printf x >> effect-count # " +
            "A" * (4095 - len(argument_prefix)) + "é", "timeout_ms": None},
            ensure_ascii=False, separators=(",", ":")) + "\r  "
        assert padded_arguments.encode()[4095:4097] == "é".encode()
        endpoint.responses.extend([
            fixture.sse_tool_calls("interactive-call", [("bash", control_call, padded_arguments)]),
            fixture.sse_answer("interactive-answer", "interactive-reason", "interactive-message",
                "interactive complete")[0],
        ])
        interactive = "human/interactive"
        run(home, "configure", "--store", store, "--session", interactive,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", interactive], env={**os.environ, "HOME": str(home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "Permission:" not in read_terminal(master, "› ")
            os.write(master, b"interactive request\na\n")
            proposal = read_terminal(master, "a: Allow once / d: Deny (Enter)")
            proposal += action_ready(ready_read, master)
            assert counter.read_text() == "x", "pasted typeahead approved an unseen Action"
            assert "\n› interactive request" in proposal, proposal
            shown_command = proposal.split("\n? Run Bash:\n", 1)[1].split("\n  Workspace:", 1)[0]
            assert "".join(line.removeprefix("  ") for line in shown_command.splitlines()) == json.loads(padded_arguments)["cmd"], proposal
            assert_permission_workspace(proposal, workspace.resolve())
            assert "call ID:" not in proposal and "request:" not in proposal and "return:" not in proposal, proposal
            assert "é" in proposal and "\u202e" not in proposal and "hidden" not in proposal, proposal
            interactive_key = fixture.command("inspect-session", "--store", store, "--session", interactive)["selected_message"]
            assert interactive_key is not None, proposal
            assert interactive_key in run(home, "requests").splitlines(), "hidden receipt must remain recoverable"
            current_action = fixture.command("inspect-session", "--store", store, "--session", interactive)
            action_id = current_action["actionable_permissions"][0]["action"]
            assert [item["action"] for item in current_action["actionable_permissions"]] == [action_id], current_action
            inspection = terminal_step(master, "/inspect-action", "a: Allow once / d: Deny (Enter)")
            inspection += action_ready(ready_read, master)
            assert json.loads(inspection.split("Bash arguments: ", 1)[1].splitlines()[0]) == padded_arguments, inspection
            assert "\\r  " in inspection and "\u202e" not in inspection, inspection
            exact = json.loads(run(home, "inspect-action", "--store", store, "--session", interactive,
                "--action", action_id, "--json"))
            assert exact == {"action": action_id, "call_id": control_call, "arguments": padded_arguments}, exact
            mismatch = admit(home, "allow-action", "--store", store, "--session", session,
                "--action", action_id)
            assert mismatch["admission"]["answer"]["status"] == "rejected", mismatch
            assert mismatch["admission"]["answer"]["code"] == "target_mismatch", mismatch
            records = home / ".config/rui/requests"
            before_choice = set(records.glob("*.json"))
            for invalid in ("l", " a ", "\x1b[200~a\x1b[201~", ""):
                rejected_choice = terminal_step(master, invalid, "a: Allow once / d: Deny (Enter)")
                rejected_choice += action_ready(ready_read, master)
                # The fresh explicit choice is the next action; a no-op need
                # not add another notice to it. Durable effects are the oracle.
                assert "a: Allow once / d: Deny (Enter)" in rejected_choice, (invalid, rejected_choice)
                assert counter.read_text() == "x", "non-exact choice approved an Action"
                assert set(records.glob("*.json")) == before_choice, "no-op choice captured authorization"
                assert "Run Bash:" not in rejected_choice, "no-op repeated the command"
            completed_turn = terminal_step(master, "a", "interactive complete", composer=True)
            assert "\n  interactive complete" in completed_turn and "result:" not in completed_turn and "request:" not in completed_turn, completed_turn
            decision_record, = set(records.glob("*.json")) - before_choice
            saved_decision = json.loads(decision_record.read_bytes())
            assert saved_decision["action"] == action_id and saved_decision["decision"] == "allow_once" and saved_decision["session"] == interactive, saved_decision
            assert json.loads(run(home, "recover", decision_record.stem, "--json"))["answer"]["replayed"] is True
            # The pasted chat suffix remains a draft, not approval or another
            # submission. Clear only that unsent draft before diagnostics.
            assert "result: completed\ninteractive complete" in terminal_step(master, "\x15/result " + interactive_key)
            assert "Recent messages" in terminal_step(master, "/status")
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON, "terminal mode not restored"
            assert counter.read_text() == "xx", counter.read_text()
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        control_session = "human/name\n\x1b[2J\u202e"
        run(home, "configure", "--store", store, "--session", control_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", control_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "› ")
            assert "Session:" not in greeting, greeting
            assert "\x1b[2J" not in greeting and "\u202e" not in greeting, greeting
            status = terminal_step(master, "/status")
            assert "Session: human/name\\n\\x1b[2J\\u202e" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            farewell = terminal_step(master, "/exit", "Resume: ")
            assert entered.wait(timeout=5) == 0
            resume = farewell.split("Resume: ", 1)[1].split("\n", 1)[0]
            assert "\x1b" not in resume and "\u202e" not in resume, resume
            # Execute the printed command, not a reconstructed equivalent. Both
            # exact selectors must survive shell quoting and changed defaults.
            other_store = workspace / "unused-store"
            other_store.mkdir(mode=0o700)
            run(home, "setup", "--store", other_store)
            resume_bin = state / "resume-bin"
            resume_bin.mkdir()
            (resume_bin / "rui").symlink_to(fixture.RUI)
            os.close(master)
            master, slave = pty.openpty()
            entered = subprocess.Popen(["bash", "-c", "exec " + resume],
                env={**os.environ, "HOME": str(home),
                     "PATH": str(resume_bin) + os.pathsep + os.environ["PATH"]},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            read_terminal(master, "› ")
            resumed = terminal_step(master, "/status")
            assert "Session: human/name\\n\\x1b[2J\\u202e" in resumed, resumed
            assert f"Store: {store}\n" in resumed, resumed
            terminal_step(master, "/exit", "Resume: ")
            assert entered.wait(timeout=5) == 0
            run(home, "setup", "--store", store)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        unsafe_session = "human/unsafe-key"
        unsafe_key = "message\n\x1b[2J\u202e"
        unsafe_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("unsafe-answer", "unsafe-reason",
            "unsafe-message", "safe result")[0], unsafe_release))
        run(home, "configure", "--store", store, "--session", unsafe_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        unsafe_text = state / "unsafe-input"
        unsafe_text.write_text("report status")
        run(home, "message", "--store", store, "--session", unsafe_session,
            "--record", state / "unsafe-record.json", "--key", unsafe_key, "--text", unsafe_text)
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", unsafe_session)["selected_message"] == unsafe_key, "unsafe key selected")
        waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert waiter.stdout.readline() == "selected message: message\\n\\x1b[2J\\u202e\n"
            master, slave = pty.openpty()
            entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                read_terminal(master, "› ")
                status = terminal_step(master, "/status")
                assert "Current message: message\\n\\x1b[2J\\u202e" in status, status
                assert "\x1b[2J" not in status and "\u202e" not in status, status
                assert "Detached." in terminal_step(master, "/exit", "Detached.")
                assert entered.wait(timeout=5) == 0
            finally:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                os.close(master)
        finally:
            unsafe_release.set()
            waiter.communicate(timeout=10)
        fixture.wait_for(lambda: fixture.completed_observation(store, unsafe_key), "unsafe key result")
        assert fixture.command("inspect-session", "--store", store,
            "--session", unsafe_session)["recent_messages"][0]["message"] == unsafe_key
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "› ")
            assert "Session:" not in greeting and "\n  safe result" in greeting, greeting
            status = terminal_step(master, "/status")
            assert "Session: human/unsafe-key" in status, status
            assert "message\\n\\x1b[2J\\u202e: completed" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        empty_session = "human/empty-key"
        run(home, "configure", "--store", store, "--session", empty_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        empty_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("empty-answer", "empty-reason", "empty-message",
            "empty key answer")[0], empty_release))
        empty_input = state / "empty-input"
        empty_input.write_text("empty key input")
        admission = json.loads(run(home, "message", "--store", store, "--session", empty_session,
            "--record", state / "empty-record.json", "--key", "", "--text", empty_input))
        assert admission["answer"]["status"] == "accepted", admission
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", empty_session)["work"]["status"] == "in_flight", "empty key active")
        current = fixture.command("inspect-session", "--store", store, "--session", empty_session)
        assert current["selected_message"] == "", current
        empty_wait = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", empty_session, "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert json.loads(empty_wait.stdout.readline()) == {"event": "selection", "session": empty_session, "message": ""}
            empty_release.set()
            assert json.loads(empty_wait.stdout.readline())["observation"]["result"]["status"] == "completed"
            assert empty_wait.wait(timeout=10) == 0
        finally:
            empty_release.set()
            if empty_wait.poll() is None:
                empty_wait.kill()
                empty_wait.communicate(timeout=5)
        current = fixture.command("inspect-session", "--store", store, "--session", empty_session)
        assert current["selected_message"] is None and current["recent_messages"][0]["message"] == "", current
        endpoint.responses.append(fixture.sse_answer("long-answer", "long-reason", "long-message", "long input intact")[0])
        long_session = "human/long-input"
        run(home, "configure", "--store", store, "--session", long_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 40, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", long_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "› ")
            assert "Permission:" not in greeting, greeting
            assert "Bash runs without approval" in greeting, greeting
            assert "Bash commands can run without asking you" not in greeting, greeting
            binding = terminal_step(master, "/status")
            assert "Permission: bypass\n" in binding and "Provider: codex" in binding and "Model: model-a" in binding, binding
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
            before = len(endpoint.requests)
            long_text = "X" * 5000
            answer = terminal_bulk(master, long_text, "long input intact")
            assert "long input intact" in answer, answer
            assert len(endpoint.requests) == before + 1
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == long_text
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            long_cluster = "a" + "\u0301" * 2048
            for index, draft in enumerate((long_cluster, ("e" + "\u0301" * 1024) * 3,
                                           "ab" + "\u0301" * 32767)):
                marker = f"encoded row accepted {index}"
                endpoint.responses.append(fixture.sse_answer(f"encoded-answer-{index}",
                    f"encoded-reason-{index}", f"encoded-message-{index}", marker)[0])
                before_draft = len(endpoint.requests)
                # Do not race Enter against redraw: the complete unsent draft
                # must remain renderable before any capture/transmission.
                terminal_bulk(master, "\x1b[200~" + draft + "\x1b[201~", draft, submit=False)
                assert entered.poll() is None and len(endpoint.requests) == before_draft
                terminal_step(master, "", marker, composer=True)
                body = json.loads(endpoint.requests[-1])
                assert next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user") == draft
            for index, (columns, draft, drawn) in enumerate((
                    (80, "A中e\u0301\tB", "A中e\u0301    B\r\x1b[11C"),
                    (8, "abcd\tQ", "› abcd\n>      \n> Q\r\x1b[3C"))):
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
                marker = f"tab row accepted {index}"
                endpoint.responses.append(fixture.sse_answer(f"tab-answer-{index}",
                    f"tab-reason-{index}", f"tab-message-{index}", marker)[0])
                before_draft = len(endpoint.requests)
                output = terminal_bulk(master, "\x1b[200~" + draft + "\x1b[201~",
                    drawn.split("\n")[-1], submit=False)
                assert drawn in output.replace("\r\n", "\n"), output
                assert entered.poll() is None and len(endpoint.requests) == before_draft
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                terminal_step(master, "", marker, composer=True)
                body = json.loads(endpoint.requests[-1])
                assert next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user") == draft
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            endpoint.responses.append(fixture.sse_answer("encoded-delete-answer", "encoded-delete-reason",
                "encoded-delete-message", "encoded deletion intact")[0])
            terminal_bulk(master, "\x1b[200~" + long_cluster + "\x1b[201~", long_cluster, submit=False)
            terminal_step(master, "\x7fZ", "encoded deletion intact", composer=True)
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "Z", body
            accepted_count = len(endpoint.requests)
            rejected = terminal_bulk(master, "Y" * (64 * 1024 + 1) + "\x7f", "input too long")
            assert "input too long" in rejected and "nothing sent" in rejected, rejected[-1000:]
            assert len(endpoint.requests) == accepted_count, "oversized input reached Host"
            rejected = terminal_step(master, "invalid\x00x", "Input rejected; nothing sent.")
            assert "Input rejected; nothing sent." in rejected and "--text FILE" not in rejected, rejected
            assert len(endpoint.requests) == accepted_count, "unsupported control reached Host"
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        editor_session = "human/editor"
        run(home, "configure", "--store", store, "--session", editor_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        cases = [
            ("first second\x1b\x7fZ", "first Z"),
            ("A中e\u0301🧑‍🌾\x7f", "A中e\u0301"),
            ("\x1b[200~line1\nline2\x1b[201~", "line1\nline2"),
            ("\x1b[200~a\n\u0301\x1b[201~\x01\x7f\x7fZ", "Z"),
            ("ab\x01\x04\x05\x04", "b"),
            ("ask src/foo-bar\x17", "ask "),
            ("\x1b[123;4~Z", "Z"),
            ("\x1bZ", "Z"),
            ("abc\x1b[D\x1b[DZ", "aZbc"),
            ("\x1b[200~line1\nline2\x1b[201~\x1b[A\x01X", "Xline1\nline2"),
        ]
        endpoint.responses.extend(fixture.sse_answer(f"editor-answer-{i}", f"editor-reason-{i}",
            f"editor-message-{i}", f"edited {i}")[0] for i in range(len(cases)))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", editor_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "› ")
            for index, (typed, expected) in enumerate(cases):
                if index == 0:
                    os.write(master, b"first second\x1b\x7f")
                    read_terminal(master, "› first ")
                    observed = terminal_step(master, "Z", f"edited {index}")
                elif index == 1:
                    os.write(master, typed.encode())
                    read_terminal(master, "› A中e\u0301")
                    observed = terminal_step(master, "", f"edited {index}")
                elif typed == "abc\x1b[D\x1b[DZ":
                    os.write(master, b"abc\x1b[")
                    time.sleep(0.2)  # A recognized CSI must outlive the bare-ESC ambiguity timeout.
                    observed = terminal_step(master, "D\x1b[DZ", f"edited {index}")
                else:
                    observed = terminal_step(master, typed, f"edited {index}")
                assert f"edited {index}" in observed, observed
                if index == 2:
                    assert "\n› line1\n  line2" in observed, observed
                    assert "\n  edited 2" in observed, observed
                if "› " not in observed.split(f"edited {index}", 1)[1]:
                    read_terminal(master, "› ")
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == expected, (typed, expected, actual)
            for index, (cluster, count) in enumerate((("a", 1000), ("e\u0301", 500))):
                marker = f"burst edited {index}"
                endpoint.responses.append(fixture.sse_answer(f"burst-answer-{index}",
                    f"burst-reason-{index}", f"burst-message-{index}", marker)[0])
                observed = terminal_bulk(master, cluster * count + "\x7f" * count + "Z", marker)
                assert len(observed.encode()) < 100_000, "tail deletion repainted the whole draft per key"
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == "Z", actual
                if "› " not in observed.split(marker, 1)[1]:
                    read_terminal(master, "› ")
            endpoint.responses.append(fixture.sse_answer("paced-answer", "paced-reason",
                "paced-message", "paced edited")[0])
            os.write(master, b"a" * 100)
            read_terminal(master, "a" * 100)
            for _ in range(100):
                os.write(master, b"\x7f")
                time.sleep(0.025)  # Longer than the editor's repaint window.
            observed = terminal_step(master, "Z", "paced edited")
            assert "\n› Z" in observed, observed
            body = json.loads(endpoint.requests[-1])
            actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user")
            assert actual == "Z", actual
            if "› " not in observed.split("paced edited", 1)[1]:
                read_terminal(master, "› ")
            endpoint.responses.append(fixture.sse_answer("wrapped-answer", "wrapped-reason",
                "wrapped-message", "wrapped edit intact")[0])
            accepted = terminal_bulk(master, "a" * 2050 + "\x7f" * 2048, "wrapped edit intact")
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "aa", body
            before = len(endpoint.requests)
            for invalid in (b"\xc3(\n", b"\xc3\n"):
                os.write(master, invalid)
                rejected = read_terminal(master, "Input rejected; nothing sent.")
                assert "Input rejected; nothing sent." in rejected, rejected
            assert len(endpoint.requests) == before, "malformed UTF-8 reached Host"
            endpoint.responses.append(fixture.sse_answer("editor-limit-answer", "editor-limit-reason",
                "editor-limit-message", "limit accepted")[0])
            at_limit = "a" * (64 * 1024 - 2) + "é"
            accepted = terminal_bulk(master, at_limit, "limit accepted")
            assert "limit accepted" in accepted, accepted[-1000:]
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == at_limit
            if "› " not in accepted.split("limit accepted", 1)[1]:
                read_terminal(master, "› ")
            before = len(endpoint.requests)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 12, 0, 0))
            endpoint.responses.append(fixture.sse_answer("narrow-answer", "narrow-reason",
                "narrow-message", "intact")[0])
            terminal_step(master, "A中e\u0301\x1b[DX", "intact")
            assert len(endpoint.requests) == before + 1
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "A中Xe\u0301", body
            os.write(master, b"\x04")
            assert "Detached. Host work continues." in read_terminal(master, "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", empty_session], env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Recent messages" not in read_terminal(master, "› ")
            fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
                "terminal ready for Ctrl+C")
            os.write(master, b"\x03")
            assert "Detached. Host work continues." in read_terminal(master, "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        for columns in (7, 8):
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
            original_terminal = termios.tcgetattr(slave)
            before = set((fresh_home / ".config/rui/requests").glob("*.json"))
            entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", empty_session], env={**os.environ, "HOME": str(fresh_home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            try:
                if columns == 8:
                    read_terminal(master, "› ")
                    os.write(master, b"\x03")
                output, errors = terminal_exit(entered, master)
                assert entered.returncode == (1 if columns == 7 else 0), errors
                assert (b"UncertainTerminalCursor" in errors) == (columns == 7), errors
                assert (b"Detached." in output) == (columns == 8), output
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original_terminal[3] &= ~mask
                assert actual == original_terminal
                assert set((fresh_home / ".config/rui/requests").glob("*.json")) == before
            finally:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                entered.stderr.close()
                os.close(master)
                os.close(slave)
        # Independent read-only callers can wait for the same production
        # deadline together; keep every input class and restoration assertion.
        incomplete_callers = []
        before = len(endpoint.requests)
        try:
            for incomplete in (b"\xc3", b"\x1b[200~unfinished", b"\x1b[", b"\x1bO"):
                master, slave = pty.openpty()
                try:
                    entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                        "--session", empty_session], env={**os.environ, "HOME": str(fresh_home)},
                        stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    os.close(master)
                    raise
                finally:
                    os.close(slave)
                incomplete_callers.append((master, entered))
                read_terminal(master, "› ")
                os.write(master, incomplete)
            for master, entered in incomplete_callers:
                assert "IncompleteTerminalInput" in read_terminal(master, "IncompleteTerminalInput", timeout=7)
                assert entered.wait(timeout=5) != 0
                assert termios.tcgetattr(master)[3] & termios.ICANON
            assert len(endpoint.requests) == before, "incomplete terminal input reached Host"
        finally:
            for master, entered in incomplete_callers:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                os.close(master)
        observation_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("observed-later", "observed-later-reason",
            "observed-later-message", "observed later")[0], observation_release))
        observation_held, observation_continue = threading.Event(), threading.Event()
        master, slave = pty.openpty()
        original_terminal = termios.tcgetattr(slave)
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", empty_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        proxy = None
        try:
            read_terminal(master, "› ")
            before = set(run(home, "requests").splitlines())
            def hold_observation(response):
                observation_held.set()
                assert observation_continue.wait(15), "accepted observation gate was not released"
                return b""  # Lost read framing must be fatal, not partial success.

            def after_admission(response):
                assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
                proxy.route = "/v1/activity-page"
                proxy.rewrite = hold_observation
                return response

            proxy = canonical_failure_integration.ReplyProxy(host, "/v1/message", after_admission)
            os.write(master, b"observe after Host loss\n")
            terminal_gate(entered, master, observation_held, "accepted Message before activity loss", timeout=8)
            after = set(run(home, "requests").splitlines())
            assert len(after - before) == 1, (before, after)
            saved_key = (after - before).pop()
            record = home / ".config/rui/requests" / f"{saved_key}.json"
            original = record.read_bytes()
            assert json.loads(original)["text"]["value"] == "observe after Host loss"
            assert fixture.command("observe-command", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
            fixture.crash_host(host, state, "accepted-before-observation-loss")
            observation_continue.set()
            lost, errors = terminal_exit(entered, master)
            assert entered.returncode != 0 and b"TruncatedResponse" in errors, errors
            assert b"Message accepted; do not resubmit it" in errors, errors
            assert f"rui result {saved_key}".encode() in errors, errors
            assert b"Detached." not in lost and b"Not confirmed" not in lost, lost
            assert proxy.mutations == [("/v1/message", original)], "fatal observation retransmitted Message"
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original_terminal[3] &= ~mask
            assert actual == original_terminal
            assert set(run(home, "requests").splitlines()) == after and record.read_bytes() == original
            proxy.close()
            proxy = None
            endpoint.responses.append(fixture.sse_answer("observed-recovery", "observed-recovery-reason",
                "observed-recovery-message", "observed after recovery")[0])
            host = fixture.start_host(store, url)
            assert fixture.command("observe-command", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
            assert json.loads(run(home, "recover", saved_key, "--json"))["answer"]["replayed"] is True
            assert record.read_bytes() == original, "activity failure replaced accepted original"
        finally:
            observation_continue.set()
            observation_release.set()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            if proxy is not None:
                proxy.close()
            entered.stderr.close()
            os.close(master)
            os.close(slave)
        completed = True
        print("human CLI: saved recovery, Session wait/re-entry, exact PTY approval, bounded input and Host restart passed")
    finally:
        sibling_release.touch()
        if failure_release is not None:
            failure_release.set()
        if stop_release is not None:
            stop_release.set()
        if observation_release is not None:
            observation_release.set()
        race_predecessor_release.set()
        race_message_release.set()
        if terminal_waiter is not None and terminal_waiter.poll() is None:
            terminal_waiter.kill()
            terminal_waiter.communicate(timeout=5)
        if race_follower is not None and race_follower.poll() is None:
            race_follower.kill()
            race_follower.communicate(timeout=5)
        if race_waiter is not None and race_waiter.poll() is None:
            race_waiter.kill()
            race_waiter.communicate(timeout=5)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained human CLI failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
