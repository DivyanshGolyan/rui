import json

import model_fixture as fixture
from host_process import wait_for
from overview_fixture import world
from overview_groups_cases import Replies, answer, send, wait_state
from overview_keyboard_cases import ALT_LEFT, ALT_RIGHT, FIRST_ROW
from product_defaults import compaction_trigger, start_effort


def row(frame, label):
    return next((line for line in frame.splitlines() if label in line), "")


def cases():
    """SUI-121 Active creator badges use the Active roster's ancestry across deltas."""
    model = "gpt-6-luna"
    middle_task, leaf_task, sibling_task = "Middle branch", "Leaf behind middle", "Visible sibling"

    def start(task, call):
        spec = {"model": model, "effort": start_effort(model), "compactAt": compaction_trigger("codex", model),
                "permissionMode": "bypass", "tools": ["start_agent"]}
        return "start_agent", call, json.dumps({"task": task, "attached": False, "spec": spec})

    replies = Replies({
        "create middle": [fixture.sse_tool_calls("middle", [start(middle_task, "middle")]), answer("Middle started")],
        "create sibling": [fixture.sse_tool_calls("sibling", [start(sibling_task, "sibling")]), answer("Sibling started")],
        middle_task: [answer("Middle ready")],
        "grow middle": [fixture.sse_tool_calls("leaf", [start(leaf_task, "leaf")]), answer("Leaf started")],
        leaf_task: [answer("Leaf complete")],
        sibling_task: [answer("Sibling complete")],
        "peer": [answer("Completion received")],
        "restore middle": [answer("Middle restored")],
    })
    with world("tree-counts", replies, active_capacity=4) as w:
        root = w.session("--label", "Rollup parent", "--permission-mode", "bypass", "--tools", "start_agent")
        send(w, root, "create middle")
        wait_state(w, root, "finished")

        def listing(*args):
            return json.loads(w.run("session", "list", "--store", w.store, "--all", *args))

        def tree():
            rows = listing()["sessions"]
            return rows

        first_tree = wait_for(tree, "the middle child", ready=lambda rows: len(rows) == 2)
        middle, = [entry["reference"] for entry in first_tree if entry["creator"] == root]
        wait_state(w, middle, "finished")
        send(w, middle, "grow middle")
        wait_for(tree, "the grandchild", ready=lambda rows: any(entry["creator"] == middle for entry in rows))
        send(w, root, "create sibling")
        rows = wait_for(tree, "the root, two children and grandchild", ready=lambda rows: len(rows) == 4)
        for entry in rows:
            wait_state(w, entry["reference"], "finished")

        with w.overview(columns=46, rows=30) as screen:
            screen.wait(lambda frame: all(row(frame, name) for name in (middle_task, leaf_task, sibling_task)), "entire tree is expanded")
            screen.keys(FIRST_ROW)
            screen.wait(lambda _: screen.style("Rollup parent").bold, "parent selected")
            screen.keys(ALT_LEFT)
            screen.wait(lambda frame: "▸ 3" in row(frame, "Rollup parent"), "three active descendants")
            before = listing()["since"]
            w.run("session", "archive", "--store", w.store, "--session", middle)
            wait_for(lambda: w.inspect(middle)["archive_state"] == "archived", "middle archived")

            for options, count in (((), "1"), (("--include-archived",), "3")):
                delta = listing("--since", before, *options)
                assert delta["delta"] == "changed", delta
                rerendered, = [entry for entry in delta["sessions"] if entry["reference"] == root]
                removed, = [entry for entry in delta["sessions"] if entry["reference"] == middle]
                assert rerendered["descendant_count"] == count and removed["archive_state"] == "archived", delta

            screen.contains(leaf_task)
            screen.wait(lambda frame: "▸ 1" in row(frame, "Rollup parent") and not row(frame, middle_task) and
                        not row(frame, sibling_task), "one hidden descendant and a separate live root after archive")
            screen.keys(ALT_RIGHT)
            screen.contains(sibling_task)
            screen.keys(ALT_LEFT)
            screen.wait(lambda frame: "▸ 1" in row(frame, "Rollup parent"), "badge agrees with the one row expansion shows")
            send(w, middle, "restore middle")
            screen.wait(lambda frame: "▸ 3" in row(frame, "Rollup parent") and not row(frame, leaf_task),
                        "restore rejoins the tree and its badge")
