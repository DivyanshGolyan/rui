import json

import model_fixture as fixture
from overview_fixture import world
from overview_groups_cases import Replies, answer, send, wait_state
from product_defaults import compaction_trigger, start_effort


RIGHT = b"\x1b[C"
LEFT = b"\x1b[D"
DOWN = b"\x1b[B"
ALT_LEFT = b"\x1b[1;3D"
ALT_RIGHT = b"\x1b[1;3C"
FIRST_ROW = b"\x1b[H\x1b[1;2B\x1b[1;2B"


def row_of(frame, label):
    return next(index for index, line in enumerate(frame.splitlines(), 1) if label in line)


def draft(screen, text):
    screen.wait(lambda _: screen.capture.draft(text, len(text) + 2), f"composer draft {text!r}")


def cases():
    """SUI-116 Right Arrow transfers keyboard input to the selected Session."""
    keyboard_activation()
    creator_gestures()


def keyboard_activation():
    with world("keyboard", {"first input": answer("First answer"), "second input": answer("Second answer")}) as w:
        first = w.session("--label", "First chat")
        second = w.session("--label", "Second chat")
        for session, text in ((first, "first input"), (second, "second input")):
            send(w, session, text)
            wait_state(w, session, "finished")

        for columns in (46, 140):
            with w.overview(columns=columns, rows=30) as screen:
                frame = screen.wait(lambda frame: "First chat" in frame and "Second chat" in frame, "both Sessions")
                first_shown = frame.index("First chat") < frame.index("Second chat")
                screen.keys(FIRST_ROW)
                screen.wait(lambda _: screen.style("First chat" if first_shown else "Second chat").bold, "first Session selected")
                screen.keys(RIGHT)
                screen.contains("First answer" if first_shown else "Second answer")
                draft(screen, "")
                screen.keys(b"first draft")
                draft(screen, "first draft")
                screen.keys(ALT_LEFT + b"_")
                screen.wait(lambda _: screen.capture.draft("first _draft", 9), "Option+Left edits by word")
                screen.keys(ALT_RIGHT + b"!")
                draft(screen, "first _draft!")

        starting = first if first_shown else second
        starting_answer, destination_answer = (("First answer", "Second answer") if first_shown
                                              else ("Second answer", "First answer"))
        sibling = "Second chat" if first_shown else "First chat"
        for settle in (True, False):
            with w.overview("session", "resume", "--", starting, columns=140, rows=30, keep_launch=True) as screen:
                screen.wait(lambda frame: starting_answer in frame and sibling in frame, "split Session and its sibling")
                draft(screen, "")
                screen.keys(LEFT + RIGHT + b"same")
                draft(screen, "same")
                screen.keys(b"\x7f" * 4)
                draft(screen, "")
                screen.keys(LEFT)
                if settle:
                    screen.keys(DOWN)
                    screen.contains(destination_answer)
                    screen.keys(RIGHT)
                else:
                    screen.keys(DOWN + RIGHT)
                    screen.contains(destination_answer)
                draft(screen, "")
                screen.keys(b"seconddraft")
                draft(screen, "seconddraft")


def creator_gestures():
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
    with world("tree-gestures", replies, active_capacity=2) as w:
        parent = w.session("--label", "Tree parent", "--permission-mode", "bypass", "--tools", "start_agent")
        send(w, parent, "create tree")
        wait_state(w, parent, "finished")
        for columns in (46, 140):
            with w.overview(columns=columns, rows=30) as screen:
                screen.contains(task)
                screen.keys(FIRST_ROW)
                screen.wait(lambda _: screen.style("Tree parent").bold, "parent selected")
                screen.keys(ALT_LEFT)
                screen.wait(lambda frame: task not in frame and "▸ 1" in frame, "Option+Left collapses the parent")
                screen.keys(ALT_RIGHT)
                frame = screen.contains(task)
                row = row_of(frame, "Tree parent")
                screen.click(8, row)
                screen.click(8, row)
                screen.wait(lambda frame: task not in frame and "▸ 1" in frame, "double-click collapses the parent")
                screen.click(8, row)
                screen.click(8, row)
                screen.contains(task)
                screen.keys(ALT_LEFT + RIGHT)
                screen.contains("Parent answer")
                draft(screen, "")
                screen.keys(b"parentdraft")
                draft(screen, "parentdraft")

        for columns in (46, 140):
            with w.overview(columns=columns, rows=30) as screen:
                frame = screen.contains(task)
                row = row_of(frame, "Tree parent")
                screen.click(8, row)
                screen.keys(b"beforefocus")
                screen.contains("Parent answer")
                draft(screen, "")

        with w.overview("session", "resume", "--", parent, columns=140, rows=30, keep_launch=True) as screen:
            frame = screen.wait(lambda frame: "Parent answer" in frame and task in frame, "parent with its split list")
            draft(screen, "")
            row = row_of(frame, "Tree parent")
            screen.click(8, row)
            screen.click(8, row)
            screen.wait(lambda frame: task not in frame and "▸ 1" in frame and "Parent answer" in frame,
                        "double-click folds the active chat without replacing its transcript")
            screen.keys(RIGHT + b"sameparent")
            draft(screen, "sameparent")
