import json

import model_fixture as fixture
from overview_fixture import world
from overview_groups_cases import Replies, answer, send, wait_state
from product_defaults import compaction_trigger, start_effort


LEFT = b"\x1b[D"
RIGHT = b"\x1b[C"
HOME = b"\x1b[H"
DOWN = b"\x1b[B"
FIRST_ROW = HOME + b"\x1b[1;2B" * 2
ENCODINGS = ((b"\x1b[1;3D", b"\x1b[1;3C"), (b"\x1bb", b"\x1bf"))


def tree_key_custody():
    """SUI-141: tree keys use list focus while other input owners keep custody."""
    model = "gpt-6-luna"
    task = "Tree child task"
    arguments = {"task": task, "attached": False, "spec": {
        "model": model, "effort": start_effort(model), "compactAt": compaction_trigger("codex", model),
        "permissionMode": "bypass", "tools": ["start_agent"],
    }}
    replies = Replies({
        "create tree": [fixture.sse_tool_calls("create-tree", [("start_agent", "tree-call", json.dumps(arguments))]),
                        answer("Parent answer")],
        task: [answer("Child answer")],
        "peer": [answer("Child completion received")],
    })
    with world("tree-key-custody", replies, active_capacity=2) as w:
        parent = w.session("--label", "Tree parent", "--permission-mode", "bypass", "--tools", "start_agent")
        send(w, parent, "create tree")
        wait_state(w, parent, "finished")
        for columns in (46, 140):
            with w.overview(columns=columns, rows=30) as screen:
                screen.contains(task)
                screen.keys(FIRST_ROW)
                screen.wait(lambda _: screen.style("Tree parent").bold, "parent selected")
                for left, right in ENCODINGS:
                    screen.keys(left)
                    screen.wait(lambda frame: task not in frame and "▸ 1" in frame and
                                screen.style("Tree parent").bold, "selected parent folds with one descendant")
                    screen.keys(right)
                    screen.wait(lambda frame: task in frame and screen.style("Tree parent").bold,
                                "selected parent expands")

                def tree_state(folded, description):
                    screen.wait(lambda frame: "Notifications" not in frame and
                                ((task not in frame and "▸ 1" in frame) if folded else
                                 (task in frame and "▸ 1" not in frame)), description)

                for left, right in ENCODINGS:
                    for key, folded in ((left, False), (right, True)):
                        for owner in ("paste", "Settings", "Keys"):
                            screen.keys(FIRST_ROW + (left if folded else right))
                            tree_state(folded, "prepare tree state for " + owner)
                            if owner == "paste":
                                screen.keys(b"\x1b[200~" + key + b"\x1b[201~\x1b[F\r")
                            else:
                                screen.keys(b"\x1b[F\r")
                            screen.wait(lambda frame: "Notifications" in frame and "Version" in frame,
                                        "Settings owns input")
                            if owner == "Keys":
                                screen.keys(DOWN * 6 + b"\r")
                                screen.wait(lambda frame: "earlier message" in frame and "tool output" in frame,
                                            "Settings Keys panel owns input")
                            if owner != "paste":
                                screen.keys(key)
                            screen.keys(b"\x1b")
                            if owner == "Keys":
                                screen.wait(lambda frame: "Notifications" in frame and "Version" in frame and
                                            "earlier message" not in frame, "Keys panel closes to Settings")
                                screen.keys(b"\x1b")
                            tree_state(folded, owner + " retains custody of one tree key")

                screen.keys(FIRST_ROW)
                screen.wait(lambda _: screen.style("Tree parent").bold, "parent selected after Settings")
                for left, right in ENCODINGS:
                    screen.keys(left)
                    screen.wait(lambda frame: task not in frame and "▸ 1" in frame,
                                "parent folds after returning from Settings")
                    screen.keys(right)
                    screen.contains(task)
                screen.keys(RIGHT)
                screen.contains("Parent answer")
                for left, right in ENCODINGS:
                    screen.keys(b"first draft")
                    screen.wait(lambda _: screen.capture.draft("first draft", 13), "composer draft")
                    screen.keys(left + b"_")
                    screen.wait(lambda _: screen.capture.draft("first _draft", 9), "composer word left")
                    screen.keys(right + b"!")
                    screen.wait(lambda _: screen.capture.draft("first _draft!", 15), "composer word right")
                    screen.keys(b"\x15")
                    screen.wait(lambda _: screen.capture.draft("", 2), "composer cleared")
                if columns == 140:
                    screen.keys(LEFT)
                    screen.wait(lambda _: screen.style("Tree parent").bold, "split list focused")
                    for left, right in ENCODINGS:
                        screen.keys(left)
                        screen.wait(lambda frame: task not in frame and "▸ 1" in frame and "Parent answer" in frame,
                                    "split list folds without replacing the chat")
                        screen.keys(right)
                        screen.wait(lambda frame: task in frame and "Parent answer" in frame,
                                    "split list expands without replacing the chat")
                    screen.keys(RIGHT + b"retained")
                    screen.wait(lambda _: screen.capture.draft("retained", 10), "Right returns to composer")

        rows = json.loads(w.run("session", "list", "--store", w.store, "--all"))["sessions"]
        child, = (entry["reference"] for entry in rows if entry["creator"] == parent)
        w.run("session", "pin", "--store", w.store, "--session", child)
        with w.overview(columns=140, rows=30) as screen:
            screen.wait(lambda frame: task in frame and "Tree parent" in frame, "pinned child and parent")
            screen.keys(FIRST_ROW + DOWN)
            screen.wait(lambda _: screen.style("Tree parent").bold, "unpinned parent selected")
            screen.keys(b"\x1bb" + RIGHT)
            screen.wait(lambda frame: "Parent answer" in frame and task in frame and "▸ 1" not in frame,
                        "pinned child stays visible outside the parent count")
