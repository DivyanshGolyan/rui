import json
import os
import pathlib

import model_fixture as fixture
from host_process import wait_for
from human_cli_fixture import keyed_frame, read_terminal
from tool_profile_fixture import profile_worlds
from product_defaults import DEFAULTS, compaction_trigger, start_effort
from terminal_process import terminal_process


PEER_PREFIX = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}")[0]


def answer(name):
    return fixture.sse_answer(name, name + "-reason", name + "-message", name + " answered")[0]


def profile(w, session, allowed, loaded, permission=None):
    saved = w.inspect(session)["session"]
    assert saved["tools"] == sorted(allowed), saved
    assert saved["loaded_tools"] == sorted(loaded), saved
    if permission is not None:
        assert saved["permission_mode"] == permission, saved
    return saved


def declarations(request):
    tools = list(request.get("tools", []))
    for item in request["input"]:
        if item.get("type") == "additional_tools":
            tools.extend(item["tools"])
    names = []
    for tool in tools:
        if tool["type"] == "function":
            names.append(tool["name"])
        else:
            assert tool["type"] == "web_search", tool
            names.append("web_search")
    assert len(names) == len(set(names)), ("duplicate declarations", names)
    return set(names)


def requests_for(w, session):
    with w.endpoint.lock:
        bodies = [json.loads(body) for body in w.endpoint.requests]
    return [body for body in bodies if fixture.instructions_session(fixture.request_system_prompt(body)) == session]


def finished(w, session):
    report = wait_for(lambda: w.inspect(session), "tool-profile Message completes",
                      ready=lambda report: report["work"]["state"]["kind"] == "finished")
    assert report["recent_messages"][-1]["outcome"] == "completed", report
    return report


def first_request(w, session, loaded):
    finished(w, session)
    request, = requests_for(w, session)
    assert declarations(request) == set(loaded), request
    return request


def references(w):
    return {row["reference"] for row in json.loads(w.run("session", "list", "--all"))["sessions"]}


def fresh_callers(world, engine):
    allowed = DEFAULTS.tools.split(",")
    loaded = DEFAULTS.loaded_tools.split(",")
    replies = {name: answer(name) for name in ("configured", "started", "tui-new", "tui-wide")}
    with world("fresh-tool-profile", replies) as w:
        configured = w.session()
        profile(w, configured, allowed, loaded)
        assert requests_for(w, configured) == []
        w.run("session", "send", "--to", configured, input="configured")
        first_request(w, configured, loaded)

        started = json.loads(w.run("session", "start", "--workspace", w.workspace, input="started"))
        session = started["context"]["session"]
        profile(w, session, allowed, loaded)
        first_request(w, session, loaded)

        for columns, name in ((80, "tui-new"), (140, "tui-wide")):
            known = references(w)
            with w.overview(columns=columns, keep_launch=True) as screen:
                if columns < 100:
                    screen.wait(lambda frame: "+ New Session" in frame and "Settings" in frame
                                and "Type a task" not in frame, "narrow overview ready")
                    screen.keys(b"\x1b[H\r")
                screen.wait(lambda frame: "Type a task" in frame and screen.capture.draft("", 2),
                            "fresh chat composer")
                session, = references(w) - known
                profile(w, session, allowed, loaded)
                report = w.inspect(session)
                assert report["recent_messages"] == [] and report["selected_message"] is None, report
                assert requests_for(w, session) == []
                screen.keys(name)
                screen.wait(lambda frame: screen.capture.draft(name, len(name) + 2), "first task draft")
                screen.keys(b"\r")
                screen.contains(name + " answered")
                first_request(w, session, loaded)
    print(f"tool profiles ({engine}): fresh CLI configure/start and narrow/wide TUI creation save allowed/loaded sets and offer only loaded tools", flush=True)


def restrictions_and_resume(world, engine):
    cases = (
        ("none", None, [], []),
        ("bash", None, ["bash"], ["bash"]),
        ("bash,web_search", None, ["bash", "web_search"], ["bash", "web_search"]),
        ("bash,find_tools", "find_tools", ["bash", "find_tools"], ["find_tools"]),
        ("none", "none", [], []),
    )
    replies = {f"restricted-{index}": answer(f"restricted-{index}") for index in range(len(cases))}
    replies["narrowed-fresh"] = answer("narrowed-fresh")
    with world("restricted-tool-profile", replies) as w:
        # This tools-only update previously refused because the intersection of
        # the fresh loaded set with these tools lacks find_tools.
        narrowed = w.session()
        original = profile(w, narrowed, DEFAULTS.tools.split(","), DEFAULTS.loaded_tools.split(","))
        w.run("session", "configure", "--session", narrowed, "--tools", "bash,skill,start_agent")
        next_tools = ["bash", "skill", "start_agent"]
        current = profile(w, narrowed, next_tools, next_tools)
        assert int(current["revision"]) == int(original["revision"]) + 1, current
        rejected = json.loads(w.run("session", "configure", "--session", narrowed,
                                    "--loaded-tools", "bash,skill", expect=3))
        assert rejected["answer"]["code"] == "loaded_tools_unreachable", rejected
        assert profile(w, narrowed, next_tools, next_tools)["revision"] == current["revision"]
        w.run("session", "send", "--to", narrowed, input="narrowed-fresh")
        first_request(w, narrowed, next_tools)
        for index, (tools, initial, allowed, loaded) in enumerate(cases):
            args = ["--tools", tools, "--permission-mode", "ask"]
            if initial is not None:
                args += ["--loaded-tools", initial]
            session = w.session(*args)
            original = profile(w, session, allowed, loaded, "ask")
            w.run("session", "configure", "--session", session, "--label", "kept restriction")
            revised = profile(w, session, allowed, loaded, "ask")
            assert int(revised["revision"]) == int(original["revision"]) + 1, revised
            with terminal_process([str(fixture.RUI), "session", "resume", "--", session],
                                  env=w.env, cwd=w.workspace) as (caller, master):
                keyed_frame(master, b"", lambda screen, x, y: "› " in screen)
                profile(w, session, allowed, loaded, "ask")
                os.write(master, b"\x03")
                read_terminal(master, "Detached.")
                assert caller.wait(timeout=5) == 0
            resumed = profile(w, session, allowed, loaded, "ask")
            assert resumed["revision"] == revised["revision"], resumed
            w.run("session", "send", "--to", session, input=f"restricted-{index}")
            first_request(w, session, loaded)
            profile(w, session, allowed, loaded, "ask")
    print(f"tool profiles ({engine}): explicit empty/restricted selections, explicit loaded subsets, label updates and resume preserve authority and first wire", flush=True)


def discovery(world, engine):
    allowed = DEFAULTS.tools.split(",")
    loaded = DEFAULTS.loaded_tools.split(",")
    with world("tool-profile-discovery") as w:
        w.endpoint.responses_by_input = None
        for name, args, words, initial, final, offered, tools in (
            ("fresh", [], "read_action", loaded, sorted(set(loaded) | {"read_action"}), set(loaded) | {"read_action", "stop_action"}, allowed),
            ("restricted", ["--tools", "find_tools"], "bash", ["find_tools"], ["find_tools"], {"find_tools"}, ["find_tools"]),
        ):
            session = w.session(*args)
            profile(w, session, tools, initial)
            w.endpoint.responses.extend([
                fixture.sse_tool_calls(name + "-search", [("find_tools", name + "-find", json.dumps({"words": words}))]),
                answer(name + "-found"),
            ])
            w.run("session", "send", "--to", session, input="discover " + name)
            finished(w, session)
            first, second = requests_for(w, session)
            assert declarations(first) == set(initial), first
            assert declarations(second) == offered, second
            output, = [item for item in second["input"] if item.get("call_id") == name + "-find"
                       and item.get("type") == "function_call_output"]
            assert output["output"], output
            profile(w, session, tools, final)
    print(f"tool profiles ({engine}): discovery loads deferred read_action, projects stop_action, and preserves a restricted Session", flush=True)


class ChildReplies(dict):
    def __init__(self):
        super().__init__()
        self.parent_requests = 0
        self.model = None

    def __bool__(self):
        return True

    def __getitem__(self, text):
        if text == "restricted parent":
            self.parent_requests += 1
            if self.parent_requests == 1:
                model = self.model
                spec = {"model": model, "effort": start_effort(model),
                        "compactAt": compaction_trigger("codex", model), "permissionMode": "ask"}
                calls = []
                for name, tools in (("narrowed child", ["skill"]), ("forbidden child", ["bash"])):
                    arguments = {"task": name, "attached": True, "spec": {**spec, "tools": tools}}
                    calls.append(("start_agent", name, json.dumps(arguments)))
                return fixture.sse_tool_calls("restricted-parent-calls", calls)
            return answer("parent")
        if text.startswith(PEER_PREFIX):
            return answer("child-ending-received")
        assert text == "narrowed child", text
        return answer("child")


def attached_child(world, engine):
    replies = ChildReplies()
    with world("attached-tool-profile", replies, active_capacity=2) as w:
        parent = w.session("--tools", "skill,start_agent", "--permission-mode", "ask")
        replies.model = profile(w, parent, ["skill", "start_agent"], ["skill", "start_agent"], "ask")["model"]
        w.run("session", "send", "--to", parent, input="restricted parent")
        finished(w, parent)
        children = [session for session in references(w) if w.inspect(session)["session"]["parent"] == parent]
        child, = children
        saved = profile(w, child, ["skill"], ["skill"], "ask")
        parent_saved = w.inspect(parent)["session"]
        assert saved["workspace"] == parent_saved["workspace"] and saved["provider"] == parent_saved["provider"], saved
        first_request(w, child, ["skill"])
        requests = requests_for(w, parent)
        assert all(declarations(request) == {"skill", "start_agent"} for request in requests), requests
        outputs = {item["call_id"]: item["output"] for request in requests for item in request["input"]
                   if item.get("type") == "function_call_output"}
        assert "narrowed child" in outputs and "forbidden child" in outputs, outputs
        assert "bash" in outputs["forbidden child"] and "Nothing was started" in outputs["forbidden child"], outputs
        profile(w, parent, ["skill", "start_agent"], ["skill", "start_agent"], "ask")
    print(f"tool profiles ({engine}): attached children keep narrowed tools and reject widening beyond their parent", flush=True)


def main():
    with profile_worlds() as worlds:
        for engine, world in worlds:
            fresh_callers(world, engine)
            restrictions_and_resume(world, engine)
            discovery(world, engine)
            attached_child(world, engine)
