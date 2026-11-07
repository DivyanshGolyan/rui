#!/usr/bin/env python3
"""Skills across the real Host wire, durable creation, reload and recovery.

The loopback provider records the actual incoming bytes before replying. No
provider credentials, caller-side skill expansion or live provider is needed.
"""
import hashlib
import http.server
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import threading

import host_process
import model_fixture as fixture
from control_integration import raw_request
from host_process import canonical_fixture_root, dispose_all, retain_failure_state, start_ready_process, stop_process, wait_for


PARENT_INSTRUCTIONS = "Authored parent instructions; never replace with skill metadata."
CHILD_INSTRUCTIONS = "Unique child instructions for the six-content creation transaction."
CHILD_TASK = "Unique child task for the six-content creation transaction."
CHILD_SCHEMA = {"type": "object", "properties": {"child": {"type": "string"}},
                "required": ["child"], "additionalProperties": False}


def user_text(request):
    return next(item["content"][-1]["text"] for item in reversed(request["input"])
                if item.get("role") == "user")


def messages(request, role):
    return [part["text"] for item in request["input"] if item.get("role") == role
            for part in item.get("content", []) if "text" in part]


def declarations(request):
    tools = list(request.get("tools", []))
    for item in request["input"]:
        if item.get("type") == "additional_tools":
            tools.extend(item["tools"])
    return {tool["name"] for tool in tools if tool.get("type") == "function"}


def metadata(request, prefix):
    return [json.loads(text.rsplit("\n", 1)[-1]) for text in messages(request, "developer")
            if text.startswith(prefix + "\n")]


class SkillsEndpoint(host_process.TestHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), SkillsHandler)
        self.requests = []
        self.lock = threading.Lock()
        self.errors = []

    def respond(self, request, number):
        text = user_text(request)
        outputs = [item for item in request["input"] if item.get("type") == "function_call_output"]
        if text == "invoke with the skill tool" and not any(item.get("call_id") == "skill-call" for item in outputs):
            return fixture.sse_tool_calls("skill-tool", [("skill", "skill-call", '{"operation":"invoke","name":"demo"}')])
        if text == "invoke a FIFO with the skill tool" and not any(item.get("call_id") == "skill-fifo-call" for item in outputs):
            return fixture.sse_tool_calls("skill-fifo-tool", [("skill", "skill-fifo-call", '{"operation":"invoke","name":"demo"}')])
        if text == "start the unique child" and not any(item.get("call_id") == "child-call" for item in outputs):
            arguments = {"task": CHILD_TASK, "attached": False, "spec": {
                "model": "gpt-6-sol", "effort": "low", "compactAt": 100000, "permissionMode": "bypass",
                "tools": ["skill"], "instructions": CHILD_INSTRUCTIONS, "outputSchema": CHILD_SCHEMA}}
            return fixture.sse_tool_calls("spawn-child", [("start_agent", "child-call", json.dumps(arguments))])
        allowed = {"initial probe", "restricted initial message", "invoke with the skill tool", "invoke a FIFO with the skill tool",
                   "after metadata reload", "start the unique child", CHILD_TASK}
        assert text in allowed or text.startswith("Skill file: "), text
        answer = '{"child":"ok"}' if text == CHILD_TASK else "skills checked"
        return fixture.sse_answer(f"answer-{number}", f"reason-{number}", f"message-{number}", answer)[0]

    def decoded(self):
        with self.lock:
            assert not self.errors, self.errors
            return [json.loads(body) for body in self.requests]


class SkillsHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        # Capture before responding: fixture disposal cannot manufacture evidence.
        with self.server.lock:
            self.server.requests.append(body)
            number = len(self.server.requests)
        try:
            payload = self.server.respond(json.loads(body), number)
            status = 200
        except BaseException as error:
            with self.server.lock:
                self.server.errors.append(repr(error))
            payload, status = b'{"error":{"message":"unexpected fixture request"}}', 422
        self.send_response(status)
        self.send_header("Content-Type", "text/event-stream" if status == 200 else "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, *_args):
        pass


def skill(root, name, description, body="BODY_NOT_METADATA\n"):
    path = root / name / "SKILL.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = f"---\nname: {name}\ndescription: {description}\n---\n{body}".encode()
    path.write_bytes(raw)
    return {"name": name, "description": description, "path": str(path.resolve())}


def catalog(*entries):
    return {"entries": sorted(entries, key=lambda entry: entry["name"])}


def content_reference(raw):
    domain = b"rui/content/v1"
    return {"bytes": str(len(raw)), "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + raw).hexdigest()}


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-skills."))
    host = endpoint = None
    try:
        home = state / "home"
        home.mkdir()
        repo = state / "repo"
        (repo / ".git").mkdir(parents=True)
        workspace = repo / "nested" / "workspace"
        workspace.mkdir(parents=True)
        project = repo / ".agents" / "skills"
        personal = home / ".agents" / "skills"
        demo = skill(project, "demo", "Demo metadata")
        shared = skill(project, "shared", "Project wins")
        removed = skill(project, "removed", "Remove this metadata")
        home_only = skill(personal, "home-only", "Host HOME metadata")
        switching = skill(personal, "switching", "Same description, different winning path")
        skill(personal, "shared", "HOME must lose")
        # Neither legacy roots, a workspace below the repository, an ancestor,
        # nor a nested candidate directory is an additional discovery root.
        skill(repo / ".claude" / "skills", "legacy", "Not advertised")
        skill(repo / ".codex" / "skills", "codex", "Not advertised")
        skill(workspace / ".agents" / "skills", "workspace-only", "Not advertised")
        skill(state / ".agents" / "skills", "ancestor", "Not advertised")
        skill(project / "container", "nested", "Not advertised")
        initial_catalog = catalog(demo, shared, removed, home_only, switching)
        store = state / "store"
        environment = {"PATH": os.environ["PATH"], "HOME": str(home), "OPENAI_API_KEY": "sk-fixture-only",
                       "RUI_TEST_MODELS_DEV_URL": ""}
        endpoint = SkillsEndpoint()
        threading.Thread(target=endpoint.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"

        def start():
            process, fields = start_ready_process(fixture.host_arguments(store, url), env=environment,
                                                  required_fields={"execution": "enabled", "socket": None, "store": None})
            host_process.HostDiagnostics(process)
            assert pathlib.Path(fields["store"]) == store, fields
            return process

        def invoke(*args, text=None):
            result = subprocess.run([str(fixture.RUI), *map(str, args)], input=text, text=True,
                                    capture_output=True, timeout=15, env=environment)
            assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
            return json.loads(result.stdout)

        def post(request):
            body = request if isinstance(request, bytes) else json.dumps(request, separators=(",", ":")).encode()
            route = "/v1/" + json.loads(body)["kind"]
            head, payload = raw_request(host.rui_ready_fields["socket"], route, body)
            if not head.startswith(b"HTTP/1.1 200 "):
                status = host.poll()
                if status is not None:
                    host.rui_diagnostics.close()
                raise AssertionError((head, payload, status, host.rui_diagnostics.tail()))
            return json.loads(payload)

        def reload(key):
            return {"version": host_process.WIRE_VERSION, "kind": "configure", "store": str(store),
                    "key": key, "session": parent, "configuration": {}, "reload_skills": True}

        def complete(key):
            observed = wait_for(lambda: fixture.completed_observation(store, key), f"skills Message {key}")
            assert observed["state"] == "completed", observed
            endpoint.decoded()

        def send(key, text, session=None):
            result = invoke("session", "send", "--store", store, "--to", session or parent,
                            "--record", state / f"{key}.json", "--key", key, text=text)
            assert result["answer"]["status"] == "accepted", result
            complete(key)

        def conversation(session):
            cursor = {"end": "0", "before_position": "0", "before_ordinal": "0"}
            rows = []
            for _ in range(16):
                request = {"version": host_process.WIRE_VERSION, "kind": "conversation_page",
                           "store": str(store), "session": session, **cursor}
                body = json.dumps(request).encode()
                head, payload = raw_request(host.rui_ready_fields["socket"], "/v1/conversation-page", body)
                assert head.startswith(b"HTTP/1.1 200 "), (head, payload)
                page = json.loads(payload)
                for item in page["items"]:
                    content = subprocess.run([str(fixture.RUI), "session", "read-conversation", "--store", str(store),
                        "--session", session, "--position", item["position"], "--ordinal", item["ordinal"]],
                        capture_output=True, timeout=15, env=environment)
                    assert content.returncode == 0, content.stderr
                    rows.append((item, content.stdout))
                if not page["more"]:
                    return list(reversed(rows))
                cursor = {name: page[name] for name in ("end", "before_position", "before_ordinal")}
            raise AssertionError("unexpectedly large skills Conversation")

        host = start()

        def creation_refusal_case(label, rejected_workspace, code, repair):
            sessions_before = invoke("session", "list", "--store", store, "--all")["sessions"]
            request_count = len(endpoint.decoded())
            refused = []
            for operation, kind in (("configure", "configure"), ("start", "message")):
                key = f"{label}-{operation}"
                record = state / f"{key}.json"
                result = subprocess.run([str(fixture.RUI), "session", operation, "--store", str(store),
                    "--workspace", str(rejected_workspace), "--provider", "codex", "--model", "gpt-6-sol",
                    "--record", str(record), "--key", key], input="refused initial Message" if operation == "start" else None,
                    text=True, capture_output=True, timeout=15, env=environment)
                assert result.returncode == 3, (label, operation, result.returncode, result.stdout, result.stderr)
                reply = json.loads(result.stdout)
                expected = {"status": "rejected", "replayed": False, "session": "", "code": code}
                assert reply["answer"] == expected, (label, operation, reply)
                refused.append((key, record, record.read_bytes(), kind, expected))
            repair()
            for key, record, captured, kind, expected in refused:
                result = subprocess.run([str(fixture.RUI), "request", "recover", "--store", str(store),
                    "--record", str(record), "--kind", kind], text=True, capture_output=True,
                    timeout=15, env=environment)
                assert result.returncode == 3, (label, kind, result.returncode, result.stdout, result.stderr)
                assert json.loads(result.stdout)["answer"] == {**expected, "replayed": True}, result.stdout
                observation = invoke("request", "inspect", "--store", store, "--key", key)["observation"]
                assert observation["code"] == code and observation["target"] == "", observation
                assert record.read_bytes() == captured
            assert invoke("session", "list", "--store", store, "--all")["sessions"] == sessions_before
            assert len(endpoint.decoded()) == request_count, "refused creation admitted model work"

        # Ordinary Workspace validation remains authoritative even when the
        # outer discovery capture also failed. Repair cannot alter keyed refusal.
        missing_workspace = state / "missing-workspace"
        creation_refusal_case("missing-workspace", missing_workspace, "invalid_workspace", missing_workspace.mkdir)
        if os.geteuid() != 0:
            inaccessible_workspace = state / "inaccessible-workspace"
            inaccessible_root = inaccessible_workspace / ".agents" / "skills"
            inaccessible_root.mkdir(parents=True)
            inaccessible_root.chmod(0)
            try:
                # A valid Workspace with a genuinely inaccessible skills root
                # must still fail closed, never become an empty catalog.
                creation_refusal_case("inaccessible-root", inaccessible_workspace, "skills_unavailable",
                                      lambda: inaccessible_root.chmod(0o700))
            finally:
                inaccessible_root.chmod(0o700)
        else:
            print("skills inaccessible-root permission fixture skipped for privileged root")

        created = invoke("session", "configure", "--store", store, "--workspace", workspace,
                         "--provider", "codex", "--model", "gpt-6-sol", "--instructions", "-",
                         "--record", state / "create.json", "--key", "create", text=PARENT_INSTRUCTIONS)
        assert created["answer"]["created"] is True, created
        parent = created["context"]["session"]
        create_capture = (state / "create.json").read_bytes()
        saved = invoke("session", "inspect", "--store", store, "--session", parent)["session"]
        assert "skill" in saved["tools"], saved
        assert endpoint.decoded() == [], "Configure must not schedule a model turn"
        # Public parsing accepts bounded UTF-8 strings, so target syntax belongs
        # to the shared mutation owner, after keyed replay classification.
        targets = ("bad", "abcdefg", "ABCDEF", "iiiiii", "ab/cde", "ab\0cde", "éabcd", "absent", "")
        target_refusals = []
        before_targets = conversation(parent)
        for index, target in enumerate(targets):
            request = dict(reload(f"reload-target-{index}"), session=target)
            if target == "":
                # Creating syntax still needs the ordinary complete spec. A
                # reload must reject it, never turn that spec into creation.
                request["configuration"] = json.loads(create_capture)["configuration"]
            expected = {"status": "rejected", "replayed": False, "session": target,
                        "code": "invalid_session_reference" if index < len(targets) - 2 else "unknown_session"}
            answer = post(request)["answer"]
            assert answer == expected, (request, answer, expected)
            assert post(request)["answer"] == {**expected, "replayed": True}
            target_refusals.append((request, expected))
        existing_reload = post(reload("target-existing"))["answer"]
        assert existing_reload["status"] == "accepted" and existing_reload["skills"] == "unchanged", existing_reload
        assert invoke("session", "inspect", "--store", store, "--session", parent)["session"] == saved
        assert conversation(parent) == before_targets
        assert endpoint.decoded() == [], "target validation or reload admitted model work"
        send("probe", "initial probe")
        first = endpoint.decoded()[-1]
        assert metadata(first, "Available skills") == [initial_catalog], first
        assert not metadata(first, "Skill catalog changes"), first
        assert "BODY_NOT_METADATA" not in json.dumps(first), first
        assert PARENT_INSTRUCTIONS in json.dumps(first), first
        assert "skill" in declarations(first), first

        restricted = invoke("session", "start", "--store", store, "--workspace", workspace,
                            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash",
                            "--record", state / "initial.json", "--key", "initial", text="restricted initial message")
        restricted_session = restricted["context"]["session"]
        initial_capture = (state / "initial.json").read_bytes()
        complete("initial")
        limited = endpoint.decoded()[-1]
        assert metadata(limited, "Available skills") == [initial_catalog], limited
        assert "skill" not in declarations(limited) and "bash" in declarations(limited), limited
        limited_saved = invoke("session", "inspect", "--store", store, "--session", restricted_session)["session"]
        assert limited_saved["tools"] == ["bash"], limited_saved

        # Body-only edits are deliberately NOT a catalog delta. Invocation must
        # nevertheless read the full current raw bytes, including frontmatter.
        raw = b'---\r\nname: demo\r\ndescription: Demo metadata\r\n---\r\n# Current body\r\n' + '雪 "quoted" \\ end\r\n\r\n'.encode()
        pathlib.Path(demo["path"]).write_bytes(raw)
        count = len(endpoint.decoded())
        unchanged = post(reload("body-only"))["answer"]
        assert unchanged["status"] == "accepted" and unchanged["skills"] == "unchanged", unchanged
        assert len(endpoint.decoded()) == count, "idle reload scheduled a model turn"
        native = {"version": host_process.WIRE_VERSION, "kind": "message", "store": str(store),
                  "key": "native-invoke", "session": parent, "sender": None, "sender_handle": None, "skill": "demo"}
        expected_invocation = f'Skill file: {json.dumps(demo["path"], ensure_ascii=False, separators=(",", ":"))}\n\n' + raw.decode()
        admitted = post(native)["answer"]
        assert admitted["status"] == "accepted" and not admitted["replayed"], admitted
        complete("native-invoke")
        invoked = endpoint.decoded()[-1]
        assert user_text(invoked) == expected_invocation, invoked
        assert raw.decode() not in "\n".join(messages(invoked, "developer")), invoked
        pathlib.Path(demo["path"]).unlink()
        before_replay = conversation(parent)
        assert expected_invocation.encode() in [content for item, content in before_replay if item["kind"] == "user"], before_replay
        restricted_before = conversation(restricted_session)
        stop_process(host)
        host = None

        # The same requests replay their committed capture, not today's missing
        # file/catalog, including both independently allocated creation routes.
        host = start()
        count = len(endpoint.decoded())
        for request, expected in target_refusals:
            assert post(request)["answer"] == {**expected, "replayed": True}
        for original in (native, create_capture, initial_capture, reload("body-only")):
            replayed = post(original)["answer"]
            assert replayed["status"] == "accepted" and replayed["replayed"] is True, replayed
        missing = post(dict(native, key="missing-file"))["answer"]
        assert missing["status"] == "rejected" and missing["code"] == "skill_file_unavailable", missing
        missing_result = fixture.read_result(store, "missing-file")
        assert b"demo" in missing_result and b"could not read" in missing_result, missing_result
        replayed_missing = post(dict(native, key="missing-file"))["answer"]
        assert replayed_missing["replayed"] is True and replayed_missing["code"] == "skill_file_unavailable", replayed_missing
        assert fixture.read_result(store, "missing-file") == missing_result
        assert len(endpoint.decoded()) == count, "replay or missing file scheduled a model turn"
        assert conversation(parent) == before_replay
        assert conversation(restricted_session) == restricted_before

        pathlib.Path(demo["path"]).write_bytes(raw)
        send("tool-invoke", "invoke with the skill tool")
        tool_request = endpoint.decoded()[-1]
        output = next(item["output"] for item in tool_request["input"]
                      if item.get("type") == "function_call_output" and item.get("call_id") == "skill-call")
        assert output == expected_invocation, output
        assert raw.decode() not in "\n".join(messages(tool_request, "developer")), tool_request

        # An advertised regular file can become a writerless FIFO. Both public
        # invocation paths must refuse it without pinning a worker/engine in
        # blocking open; raw_request's existing five-second deadline bounds the
        # negative, and the ordinary Host disposer kills/reaps on assertion.
        source = pathlib.Path(demo["path"])
        source.unlink()
        os.mkfifo(source, 0o600)
        fifo_request = dict(native, key="fifo-file")
        fifo_before = conversation(parent)
        fifo_settings = invoke("session", "inspect", "--store", store, "--session", parent)["session"]
        fifo_count = len(endpoint.decoded())
        try:
            try:
                fifo_answer = post(fifo_request)["answer"]
            except TimeoutError as error:
                raise AssertionError("writerless FIFO invocation did not reach typed refusal within the socket deadline") from error
            assert fifo_answer == {"status": "rejected", "replayed": False, "session": parent,
                                   "code": "skill_file_unavailable"}, fifo_answer
            fifo_result = fixture.read_result(store, "fifo-file")
            assert b"InvalidSkillFile" in fifo_result, fifo_result
            assert conversation(parent) == fifo_before
            assert len(endpoint.decoded()) == fifo_count, "refused FIFO admitted model work"
            assert invoke("session", "inspect", "--store", store, "--session", parent)["session"] == fifo_settings
            send("fifo-tool", "invoke a FIFO with the skill tool")
            fifo_tool_request = endpoint.decoded()[-1]
            fifo_output = next(item["output"] for item in fifo_tool_request["input"]
                               if item.get("type") == "function_call_output" and item.get("call_id") == "skill-fifo-call")
            assert fifo_output.encode() == fifo_result, fifo_output
            assert metadata(fifo_tool_request, "Available skills") == [initial_catalog]
            assert not metadata(fifo_tool_request, "Skill catalog changes")
            assert invoke("session", "inspect", "--store", store, "--session", parent)["session"] == fifo_settings
        finally:
            source.unlink()
            source.write_bytes(raw)
        assert post(fifo_request)["answer"] == {**fifo_answer, "replayed": True}
        assert fixture.read_result(store, "fifo-file") == fifo_result
        assert post(reload("fifo-repair"))["answer"]["skills"] == "unchanged"

        # An addition, a removal, a description change and a path-only winner
        # change produce one append-only system fact, never a full new listing.
        pathlib.Path(removed["path"]).unlink()
        added = skill(project, "added", "Added metadata")
        changed_shared = skill(project, "shared", "Changed project description")
        changed_switching = skill(project, "switching", switching["description"])
        updated_catalog = catalog(demo, changed_shared, home_only, changed_switching, added)
        delta = {"added": [added], "removed": [removed], "changed": [changed_shared, changed_switching]}
        count = len(endpoint.decoded())
        reloaded = post(reload("metadata"))["answer"]
        assert reloaded["status"] == "accepted" and reloaded["skills"] == "reloaded", reloaded
        assert len(endpoint.decoded()) == count, "metadata reload scheduled a model turn"
        pathlib.Path(added["path"]).unlink()
        after_reload = conversation(parent)
        assert after_reload[:len(before_replay)] == before_replay, "Conversation content changed"
        assert invoke("session", "inspect", "--store", store, "--session", parent)["session"]["instructions"] == saved["instructions"]
        stop_process(host)
        host = None
        host = start()
        assert post(fifo_request)["answer"] == {**fifo_answer, "replayed": True}
        assert fixture.read_result(store, "fifo-file") == fifo_result
        replayed = post(reload("metadata"))["answer"]
        assert replayed["replayed"] is True and replayed["skills"] == "reloaded", replayed
        # This refusal also survives restart and a now-readable skill file.
        replayed_missing = post(dict(native, key="missing-file"))["answer"]
        assert replayed_missing["replayed"] is True and replayed_missing["code"] == "skill_file_unavailable", replayed_missing
        assert fixture.read_result(store, "missing-file") == missing_result
        assert len(endpoint.decoded()) == count, "replayed reload or refusal scheduled a model turn"
        send("after-reload", "after metadata reload")
        updated = endpoint.decoded()[-1]
        assert metadata(updated, "Available skills") == [initial_catalog], updated
        assert metadata(updated, "Skill catalog changes") == [delta], updated

        # Add a disk skill only now: the child's catalog and instruction cannot
        # deduplicate against its parent's. Instructions/schema/task are also
        # unique, exercising the entire six-content start_agent import path.
        skill(project, "added", "Added metadata")
        child_only = skill(project, "child-only", "Unique child discovery after parent creation")
        configured = invoke("session", "configure", "--store", store, "--session", parent,
                            "--tools", "bash,skill,start_agent", "--key", "parent-tools",
                            "--record", state / "parent-tools.json")
        assert configured["answer"]["status"] == "accepted", configured
        send("spawn", "start the unique child")
        wait_for(lambda: any(user_text(request) == CHILD_TASK for request in endpoint.decoded()), "child provider request")
        child_request = next(request for request in endpoint.decoded() if user_text(request) == CHILD_TASK)
        child = fixture.instructions_session(child_request["instructions"])
        assert child not in (parent, restricted_session), child
        assert metadata(child_request, "Available skills") == [catalog(*updated_catalog["entries"], child_only)], child_request
        assert CHILD_INSTRUCTIONS in json.dumps(child_request), child_request
        assert child_request["text"]["format"]["schema"] == CHILD_SCHEMA, child_request

        child_observation = {}

        def child_complete():
            report = invoke("session", "inspect", "--store", store, "--session", child)
            child_observation["report"] = report
            return report if report["pending_messages"] == "0" and report["work"]["state"]["kind"] in ("finished", "failed", "stopped", "out_of_context") else None

        try:
            child_saved = wait_for(child_complete, "child completion")
        except host_process.WaitTimeout as error:
            with endpoint.lock:
                errors = list(endpoint.errors)
            raise AssertionError(("child completion", child_observation, errors, host.poll(), host.rui_diagnostics.tail())) from error
        assert child_saved["session"]["tools"] == ["skill"], child_saved
        assert child_saved["session"]["instructions"] == content_reference(CHILD_INSTRUCTIONS.encode()), child_saved
        schema_bytes = json.dumps(CHILD_SCHEMA, separators=(",", ":")).encode()
        assert child_saved["session"]["output_schema"] == content_reference(schema_bytes), child_saved
        child_conversation = conversation(child)
        assert CHILD_TASK.encode() in [content for item, content in child_conversation if item["kind"] == "user"], child_conversation
        if "structured_output" in child_saved["execution"].get("unavailable", []):
            # The current Host explicitly lacks schema validation. Creation and
            # all six imports still succeed; the later model response must be
            # refused with its real capability cause, not mistaken for a hang.
            assert child_saved["work"]["state"]["kind"] == "failed", child_saved
            assert child_saved["recent_messages"][0]["outcome"] == "unsupported_output_schema", child_saved
            assert child_saved["work"]["latest_outcome"]["code"] == "unsupported_output_schema", child_saved
            assert not any(item["kind"] == "assistant" for item, _ in child_conversation), child_conversation
        else:
            assert child_saved["recent_messages"][0]["outcome"] == "completed", child_saved
            assert b'{"child":"ok"}' in [content for item, content in child_conversation if item["kind"] == "assistant"], child_conversation
        # Exercise the real slash adapter, not a caller-side expansion or a
        # constructed native Message. Its announced handle must use the same
        # HOME-owned capture directory as ordinary inspect/list/recover.
        import human_cli_integration as human
        before_handles = set(invoke("request", "list"))
        count = len(endpoint.decoded())
        with human.terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store), parent],
                cwd=workspace, env={**environment, "TERM": "xterm-256color", "LANG": "C.UTF-8"}) as (_, master):
            human.read_terminal(master, "› ")
            os.write(master, b"/skill demo\r")
            page = human.read_terminal(master, "request: ")
            (state / "slash-skill-screen.txt").write_text(page)
            announced = re.search(r"request: (\S+)", page)
            assert announced, page
            handle = announced.group(1)
            # This plain HANDLE route is the independent regression oracle:
            # passing --store/--key here would conceal a misplaced capture.
            inspected = invoke("request", "inspect", handle)
            assert inspected["observation"]["target"] == parent, inspected
            assert set(invoke("request", "list")) - before_handles == {handle}
            record = home / ".config" / "rui" / "requests" / f"{handle}.json"
            captured = record.read_bytes()
            operation = json.loads(captured)
            assert (operation["store"], operation["session"], operation["key"], operation["skill"]) == (
                str(store), parent, handle, "demo"), operation
            assert not (store / f"{handle}.json").exists(), "slash capture leaked into the Store"
            complete(handle)
            assert len(endpoint.decoded()) == count + 1, endpoint.decoded()
            assert user_text(endpoint.decoded()[-1]) == expected_invocation
        # Lose the terminal's receipt and the source file. Normal handle-only
        # recovery must replay the captured operation, not admit current bytes.
        pathlib.Path(demo["path"]).unlink()
        before_recovery = conversation(parent)
        recovered = invoke("request", "recover", handle)
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True, recovered
        assert recovered["context"]["session"] == parent and recovered["context"]["key"] == handle, recovered
        assert recovered["input"] == {"type": "text", **content_reference(expected_invocation.encode())}, recovered
        assert invoke("request", "inspect", handle)["observation"]["target"] == parent
        assert record.read_bytes() == captured
        assert conversation(parent) == before_recovery, "slash recovery duplicated Conversation input"
        assert len(endpoint.decoded()) == count + 1, "slash recovery duplicated provider work"
        endpoint.decoded()
        print("skills Host wire passed: creation, default/restricted tools, raw invocation, idle metadata-only reload, restart replay and slash handle recovery")
    except BaseException:
        retain_failure_state("skills integration failure state", state)
        state = None
        raise
    finally:
        disposals = []
        if host is not None:
            disposals.append(lambda: stop_process(host))
        if endpoint is not None:
            disposals.extend((endpoint.shutdown, endpoint.server_close))
        if state is not None:
            disposals.append(lambda: shutil.rmtree(state))
        dispose_all(*disposals)


if __name__ == "__main__":
    host_process.enter()
    main()
