"""Actual CLI attached creation, shared by real SQLite and MySQL fixtures."""
import http.server
import json
import pathlib
import re
import sqlite3
import subprocess
import threading

from canonical_fixture import announced
import host_process
import model_fixture
from product_defaults import compaction_trigger


TASK = "attached CLI environment\n雪\n"
SHOW = 'printf "ATTACHED_ENV[%s|%s]" "${ATTACHED_MARK-unset}" "$(pwd -P)"'
ENVIRONMENT = re.compile(r"ATTACHED_ENV\[([^|\]]*)\|([^\]]*)\]")


class AttachedModel(host_process.TestHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), AttachedHandler)
        self.release = threading.Event()
        self.requested = threading.Event()
        self.requests = []
        self.outputs = {}
        self.lock = threading.Lock()

    def respond(self, request):
        session = model_fixture.instructions_session(model_fixture.request_system_prompt(request))
        inputs = request["input"]
        last_user = max(index for index, item in enumerate(inputs) if item.get("role") == "user")
        text = inputs[last_user]["content"][-1]["text"]
        outputs = [item["output"] for item in inputs[last_user:] if item.get("type") == "function_call_output"]
        with self.lock:
            self.requests.append((session, request))
            name = f"attached-{len(self.requests)}"
            if outputs:
                self.outputs.setdefault(session, []).extend(outputs)
        if text == TASK and not outputs:
            self.requested.set()
            assert self.release.wait(30), "the attached CLI caller did not release its first model reply"
            arguments = json.dumps({"cmd": SHOW, "timeout_ms": 10000,
                                    "description": "Report the inherited environment and Workspace"})
            return model_fixture.sse_tool_calls(name, [("bash", name + "-call", arguments)])
        return model_fixture.sse_answer(name, name + "-reason", name + "-message", "attached CLI done")[0]


class AttachedHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        payload = self.server.respond(request)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, *_args):
        pass


def attached_creation(binary, directory, root, env, *, scalar=None):
    """Run against a fresh Host directory, optionally configured for MySQL.

    scalar reads one integer from the same real database the Host owns. SQLite
    audits through a read-only connection only after each Host stops; MySQL's
    caller supplies its existing SQL actor and also audits while the Host lives.
    """
    root, directory = pathlib.Path(root), pathlib.Path(directory)
    home, workspace, elsewhere = (root / name for name in ("attached-home", "attached-workspace", "attached-cwd"))
    for path in (home, workspace, elsewhere):
        path.mkdir(mode=0o700)
    clean = dict(env, HOME=str(home), ATTACHED_MARK="caller")
    for name in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE", "RUI_RUNTIME_DIR"):
        clean.pop(name, None)

    def invoke(*args, input=None, mark="caller", expect=0, without_home=False):
        environment = dict(clean, ATTACHED_MARK=mark)
        if without_home:
            environment.pop("HOME", None)
        result = subprocess.run([str(binary), *map(str, args)], cwd=elsewhere,
                                env=environment, input=input,
                                text=True, capture_output=True, timeout=40)
        assert result.returncode == expect, (args, result)
        return result

    def value(*args, **kwargs):
        return json.loads(invoke(*args, **kwargs).stdout)

    def inspect(session):
        return value("session", "inspect", "--store", directory, "--session", session)

    def configuration(session):
        settings = inspect(session)["session"]
        return {name: settings[name] for name in ("parent", "workspace", "connection", "model", "revision",
                                                 "tools", "loaded_tools", "permission_mode")}

    def wait(handle):
        result = value("request", "wait", handle, "--timeout-seconds", "25")
        assert result["observation"]["state"] == "completed", result
        return result

    def sqlite_scalar(statement):
        with sqlite3.connect((directory / "rui.sqlite3").as_uri() + "?mode=ro", uri=True) as database:
            return database.execute(statement).fetchone()[0]

    sql_expectations = {}

    def expect_count(statement, expected):
        # SQLite owns an exclusive connection while its Host lives. Keep exact
        # independent row expectations for each stopped-Host boundary instead
        # of asking SQLite to violate that ownership for a fixture read.
        sql_expectations[statement] = expected
        if scalar is not None:
            assert scalar(statement) == expected, (statement, expected)

    def audit():
        read = scalar or sqlite_scalar
        for statement, expected in sql_expectations.items():
            actual = read(statement)
            assert actual == expected, (statement, expected, actual)

    def session_refs():
        return {row["reference"] for row in value("session", "list", "--store", directory, "--all")["sessions"]}
    spec = ["--model", "gpt-6-sol", "--tools", "bash", "--loaded-tools", "bash",
            "--permission-mode", "bypass", "--reasoning-effort", "low", "--compaction-trigger", "100000"]
    endpoint = AttachedModel()
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = None
    args = [str(binary), "host", "serve", "--store", str(directory), "--set", "providers={}",
            "--set", f"providers.codex.endpoint=http://127.0.0.1:{endpoint.server_port}/responses",
            "--set", "providers.codex.unauthenticated=true", "--set", "execution.activeCapacity=2"]
    try:
        host, _ = host_process.start_ready_process(args, env=dict(clean, ATTACHED_MARK="host"),
                                                  required_fields={"execution": "enabled"})
        # These ordinary defaults and cwd would violate the attached contract if
        # the CLI inserted them before forwarding the parent-bearing spec.
        invoke("defaults", "configure", "--store", directory, "--connection", "openai", "--model", "gpt-6.1-sol")
        parent = value("session", "configure", "--store", directory, "--workspace", workspace,
                       "--connection", "codex", *spec)["context"]["session"]
        seed = invoke("session", "send", "--store", directory, "--session", parent,
                      input="seed the parent environment", mark="parent-original")
        wait(announced(seed))
        invoke("session", "configure", "--store", directory, "--session", parent,
               "--tools", "bash,find_tools", "--loaded-tools", "find_tools")
        saved_parent = configuration(parent)
        assert saved_parent["tools"] == ["bash", "find_tools"], saved_parent
        assert saved_parent["loaded_tools"] == ["find_tools"], saved_parent
        # Saved client bindings must not choose an attached child's compaction
        # policy. Both creating routes resolve against the inherited provider.
        for saved_provider in ("openai", "codex"):
            invoke("defaults", "configure", "--connection", saved_provider, "--model", "gpt-6.1-sol")
            for door in ("configure", "start"):
                for explicit in (False, True):
                    key = f"parent-compaction-{saved_provider}-{door}-{explicit}"
                    record = root / (key + ".json")
                    options = ["--compaction-trigger", "2000"] if explicit else []
                    created = value("session", door, "--store", directory, "--parent", parent,
                                    "--model", "gpt-6.1-sol", "--tools", "bash", "--loaded-tools", "bash",
                                    "--permission-mode", "bypass", "--record", record, "--key", key, *options,
                                    input="attached compaction evidence" if door == "start" else None)
                    captured = json.loads(record.read_bytes())["configuration"]
                    assert "connection" not in captured and "workspace" not in captured, captured
                    if explicit:
                        assert captured["compactAt"] == 2000, captured
                    else:
                        assert "compactAt" not in captured, captured
                    child = created["context"]["session"]
                    saved = inspect(child)["session"]
                    assert saved["parent"] == parent and saved["connection"] == "codex", saved
                    assert saved["workspace"] == str(workspace) and saved["model"] == "gpt-6.1-sol", saved
                    expected = "2000" if explicit else str(compaction_trigger("codex", "gpt-6.1-sol"))
                    assert saved["compaction_trigger"] == expected, saved
                    assert saved["compaction_trigger_override"] == expected, saved
                    if door == "start":
                        ended = value("request", "wait", "--store", directory, "--key", created["context"]["key"],
                                      "--timeout-seconds", "25")
                        assert ended["observation"]["state"] == "completed", ended
                    replay = value("request", "recover", "--store", directory, "--record", record,
                                   "--kind", "message" if door == "start" else "configure")
                    assert replay["answer"]["replayed"] is True and replay["context"]["session"] == child, replay
        invoke("defaults", "configure", "--connection", "openai", "--model", "gpt-6.1-sol")
        assert configuration(parent) == saved_parent
        print("attached CLI: OpenAI/Codex saved bindings preserve inherited compaction and explicit overrides", flush=True)
        records = []
        for door in ("configure", "start"):
            dropped = invoke("session", door, "--store", directory, "--parent", parent, *spec,
                             "--test-drop-reply", "after-commit", input=TASK if door == "start" else None, expect=4)
            assert "[reply_unconfirmed]" in dropped.stderr, dropped
            handle = announced(dropped)
            record = home / ".config/rui/requests" / (handle + ".json")
            routing = record.with_name(record.name + ".routing")
            original, route = record.read_bytes(), routing.read_bytes()
            captured = json.loads(original)
            assert captured["session"] == "" and captured["configuration"]["parent"] == parent, captured
            assert captured["kind"] == ("message" if door == "start" else "configure"), captured
            assert "connection" not in captured["configuration"] and "workspace" not in captured["configuration"], captured
            assert captured["configuration"]["tools"] == ["bash"], captured
            if door == "start":
                assert captured["text"] == {"state": "value", "value": TASK}, captured
                assert endpoint.requested.wait(15), "the atomic child did not reach the provider"
                newer = invoke("session", "send", "--store", directory, "--session", parent,
                               input="replace the parent environment after child creation", mark="parent-newer")
                wait(announced(newer))
            replay = value("request", "recover", handle, mark="recover-caller")
            child = replay["context"]["session"]
            assert replay["answer"]["replayed"] is True, replay
            assert replay["context"]["key"] == handle, replay
            current = inspect(child)
            settings = current["session"]
            assert settings["parent"] == parent and settings["connection"] == "codex", settings
            assert settings["workspace"] == str(workspace) and settings["tools"] == ["bash"], settings
            assert settings["loaded_tools"] == ["bash"] and settings["permission_mode"] == "bypass", settings
            expect_count(f"SELECT count(*) FROM session WHERE session_ref='{child}' AND parent_ref='{parent}'", 1)
            expected_messages = int(door == "start")
            expect_count(f"SELECT count(*) FROM message_admission WHERE session_ref='{child}'", expected_messages)
            expect_count(f"SELECT count(*) FROM core_command WHERE target='{child}'", 1)
            if door == "configure":
                assert current["first_message"] is None and current["pending_messages"] == "0", current
            else:
                endpoint.release.set()
                wait(handle)
                assert invoke("request", "read-result", handle).stdout == "attached CLI done"
                output = "".join(endpoint.outputs.get(child, []))
                found = ENVIRONMENT.search(output)
                assert found and found.groups() == ("parent-original", str(workspace)), output
                child_requests = [request for session, request in endpoint.requests if session == child]
                assert len(child_requests) == 2, child_requests
                offered = {tool["name"] for item in child_requests[0]["input"]
                           if item.get("type") == "additional_tools" for tool in item["tools"]}
                assert offered == {"bash"}, child_requests[0]
                expect_count(f"SELECT count(*) FROM message_admission WHERE session_ref='{child}'", 1)
            assert record.read_bytes() == original and routing.read_bytes() == route
            records.append((handle, child, original, route, record, routing, expected_messages))

        for handle, child, _original, _route, _record, _routing, messages in records:
            door = "start" if messages else "configure"
            before = session_refs()
            changed = value("session", door, "--store", directory, "--parent", child, *spec,
                            "--record", home / (handle + "-changed-parent.json"), "--key", handle,
                            input=TASK if messages else None, expect=3)
            assert changed["answer"]["status"] == "conflict", changed
            if messages:
                changed = value("session", "start", "--store", directory, "--parent", parent, *spec,
                                "--record", home / (handle + "-changed-task.json"), "--key", handle,
                                input=TASK + "changed", expect=3)
                assert changed["answer"]["status"] == "conflict", changed
            assert session_refs() == before
            expect_count(f"SELECT count(*) FROM message_admission WHERE session_ref='{child}'", messages)

        # Narrowing permission and allowing a configured but unloaded parent tool
        # are separate facts. Neither may widen the parent's saved restrictions.
        direct = value("session", "start", "--store", directory, "--parent", parent,
                       *spec, input="attached start receipt evidence")
        assert direct["configuration"]["connection"] is None and direct["configuration"]["parent"] == parent, direct
        direct_child = direct["context"]["session"]
        wait(direct["context"]["key"])
        assert configuration(direct_child)["parent"] == parent
        expect_count(f"SELECT count(*) FROM message_admission WHERE session_ref='{direct_child}'", 1)
        asking_spec = list(spec)
        asking_spec[asking_spec.index("bypass")] = "ask"
        narrow = value("session", "configure", "--store", directory, "--parent", parent, *asking_spec)
        assert inspect(narrow["context"]["session"])["session"]["permission_mode"] == "ask"
        assert configuration(parent) == saved_parent
        invoke("session", "configure", "--store", directory, "--session", parent, "--permission-mode", "ask")
        archived = value("session", "configure", "--store", directory, "--workspace", workspace,
                         "--connection", "codex", *spec)["context"]["session"]
        invoke("session", "archive", "--store", directory, "--session", archived)
        known = session_refs()
        unknown = next(f"{number:06d}" for number in range(len(known) + 1) if f"{number:06d}" not in known)
        rejected_records = []
        cases = [
            ("connection", parent, ["--connection", "codex"], "parent_provider_forbidden"),
            ("workspace", parent, ["--workspace", workspace], "parent_workspace_forbidden"),
            ("tools", parent, ["--tools", "bash,web_search"], "tools_not_in_parent"),
            ("permission", parent, ["--permission-mode", "bypass"], "permission_mode_wider_than_parent"),
            ("unknown", unknown, [], "unknown_session"),
            ("archived", archived, [], "unknown_session"),
        ]
        for door in ("configure", "start"):
            for name, selected, extra, code in cases:
                # Replace values in the base spec rather than repeating a CLI
                # option: the shared parent owner must make each refusal.
                options = list(asking_spec)
                for index in range(0, len(extra), 2):
                    flag, argument = extra[index:index + 2]
                    if flag in options:
                        options[options.index(flag) + 1] = argument
                    else:
                        options.extend((flag, argument))
                before = session_refs()
                rejected = invoke("session", door, "--store", directory, "--parent", selected, *options,
                                  input=TASK if door == "start" else None, expect=3)
                handle = announced(rejected)
                answer = json.loads(rejected.stdout)["answer"]
                assert answer["status"] == "rejected" and answer["code"] == code and not answer["replayed"], (name, rejected)
                replay = value("request", "recover", handle, expect=3)["answer"]
                assert replay["status"] == "rejected" and replay["code"] == code and replay["replayed"], replay
                assert session_refs() == before
                expect_count(f"SELECT count(*) FROM message_admission WHERE command_key='{handle}'", 0)
                rejected_records.append((handle, code))
        refused_update = invoke("session", "configure", "--store", directory, "--session", parent,
                                "--parent", parent, "--permission-mode", "ask", expect=3)
        update_handle = announced(refused_update)
        assert json.loads(refused_update.stdout)["answer"]["code"] == "parent_on_update", refused_update
        rejected_records.append((update_handle, "parent_on_update"))
        parent_after_refusals = configuration(parent)
        assert parent_after_refusals["tools"] == saved_parent["tools"]
        assert parent_after_refusals["loaded_tools"] == saved_parent["loaded_tools"]

        # A complete attached spec has no ordinary binding/default dependency.
        # Use explicit captures so HOME is not needed to choose a record path.
        preferences = home / ".config/rui/preferences"
        saved_preferences = preferences.read_bytes()
        assert b"provider=openai\n" in saved_preferences, saved_preferences
        try:
            for mode in ("no-home", "stale-provider"):
                if mode == "stale-provider":
                    preferences.write_bytes(saved_preferences.replace(b"provider=openai\n", b"provider=retired-provider\n"))
                for door in ("configure", "start"):
                    for name, selected, extra, code in (cases[0], cases[1], cases[4], cases[5]):
                        key = f"attached-{mode}-{door}-{name}"
                        record = home / (key + ".json")
                        before = session_refs()
                        rejected = value("session", door, "--store", directory, "--parent", selected,
                                         *asking_spec, *extra, "--record", record, "--key", key,
                                         input=TASK if door == "start" else None,
                                         without_home=mode == "no-home", expect=3)
                        assert rejected["answer"]["code"] == code, rejected
                        captured = json.loads(record.read_bytes())
                        assert captured["configuration"]["parent"] == selected, captured
                        if name in ("connection", "workspace"):
                            assert captured["configuration"][name] == str(extra[1]), captured
                        replay = value("request", "recover", "--store", directory, "--record", record,
                                       "--kind", "message" if door == "start" else "configure",
                                       without_home=mode == "no-home", expect=3)["answer"]
                        assert replay["code"] == code and replay["replayed"], replay
                        assert session_refs() == before
                        expect_count(f"SELECT count(*) FROM message_admission WHERE command_key='{key}'", 0)
        finally:
            preferences.write_bytes(saved_preferences)

        # Reopening in a new Host proves committed identity and request replay.
        # Environment assertions above intentionally belong to the same Host.
        host_process.stop_process(host)
        host = None
        audit()
        host, _ = host_process.start_ready_process(args, env=clean, required_fields={"execution": "enabled"})
        for handle, child, original, route, record, routing, messages in records:
            replay = value("request", "recover", handle)
            assert replay["context"]["session"] == child and replay["answer"]["replayed"], replay
            settings = inspect(child)["session"]
            assert settings["parent"] == parent and settings["tools"] == ["bash"], settings
            expect_count(f"SELECT count(*) FROM message_admission WHERE session_ref='{child}'", messages)
            assert record.read_bytes() == original and routing.read_bytes() == route
        for handle, code in rejected_records:
            replay = value("request", "recover", handle, expect=3)["answer"]
            assert replay["code"] == code and replay["replayed"], replay
        assert configuration(parent) == parent_after_refusals
        host_process.stop_process(host)
        host = None
        audit()
        print("attached CLI: shared parent capture, atomic start, Bash environment, refusal and reopen replay passed", flush=True)
    finally:
        host_process.dispose_all(endpoint.release.set,
                                 lambda: host_process.stop_process(host) if host is not None else None,
                                 endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5))
        assert not thread.is_alive(), "the attached CLI provider did not retire"
