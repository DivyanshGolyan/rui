"""Overview pointer behavior: Session rows and New Session open chats,
and panels never open rows.
The flat list exposes every Session without group headings or folds.
"""
import json
import pathlib
import re
import shlex

import model_fixture as fixture
from host_process import wait_for
from overview_fixture import world

MODEL = "gpt-6-luna"
WIDTH = 99  # Whole-list hit targets; split-shell routing has its own owner tests.
# A peer Message's first content part, up to its sender: the fixture keys
# replies by that part, so every peer Message shares one reply.
PEER_PREFIX = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}")[0]


def answer(name, text):
    return fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", text)[0]


class FanOutReplies(dict):
    """The lead's first request gets one Bash call that sends each peer a
    Message from the lead's own Bash, so their first Message is no person's
    and they finish without changing their sender; its second gets a plain answer.
    Peer Messages get a plain answer. Truthy while empty, so World keeps it."""

    def __init__(self):
        super().__init__()
        self.command = None
        self.lead_requests = 0

    def __bool__(self):
        return True

    def __getitem__(self, text):
        if text == "fan out":
            self.lead_requests += 1
            if self.lead_requests == 1:
                arguments = {"cmd": self.command, "stdin": None, "timeout_ms": 20000, "description": "Message the peers"}
                return fixture.sse_tool_calls("lead-calls", [("bash", "lead-call", json.dumps(arguments))])
            return answer("lead", "lead done")
        assert text.startswith(PEER_PREFIX), text
        return answer("peer", "peer done")


def wait_for_host(w, sessions, predicate, description, timeout=60):
    wait_for(lambda: [w.inspect(session) for session in sessions], description, timeout,
             ready=lambda reports: all(predicate(report) for report in reports))


def finished(report):
    return report["work"]["state"]["kind"] == "finished"


def row_of(frame, label):
    """The 1-based screen row of the Session row titled `label`."""
    found = [n + 1 for n, line in enumerate(frame.split("\n")) if re.match(rf" \S {re.escape(label)}( |$)", line)]
    assert len(found) == 1, (label, found, frame)
    return found[0]


def line_of(frame, predicate, description):
    """The 1-based screen row of the only line `predicate` accepts."""
    found = [n + 1 for n, line in enumerate(frame.split("\n")) if predicate(line)]
    assert len(found) == 1, (description, found, frame)
    return found[0]


def click_label(screen, frame, label):
    row = row_of(frame, label)
    screen.click(frame.split("\n")[row - 1].index(label) + 1, row)


def is_overview(frame):
    """Pinned actions and the list footer, never a chat editor or facts."""
    return "+ New Session" in frame and "Settings" in frame and "enter open" in frame and "Type a task" not in frame and not any(line.startswith(" ‹ ") for line in frame.split("\n"))


def conversation_of(label):
    """A frame showing `label`'s conversation: the facts row under its
    composer leads with `‹` and names it."""
    return lambda frame: any(line.startswith(f" ‹ {label} · {MODEL}") for line in frame.split("\n")) and not is_overview(frame)


def back_to_overview(screen, *markers):
    screen.keys(b"\x1b")
    return screen.wait(lambda frame: is_overview(frame) and all(marker in frame for marker in markers),
                       ("Esc returns to the overview", markers))


def opening_and_views():
    replies = {f"ask {name}": answer(name, f"answer from {name}") for name in ("alpha", "bravo")}
    with world("clicks-open", replies) as w:
        sessions = {name: w.session("--label", name) for name in ("alpha", "bravo")}
        for name, session in sessions.items():
            w.run("session", "send", "--store", w.store, "--to", session, input=f"ask {name}")
        wait_for_host(w, sessions.values(), finished, "both Sessions answer")
        charlie = w.session("--label", "charlie")
        w.run("session", "archive", "--store", w.store, "--session", charlie)
        wait_for_host(w, [charlie], lambda report: report["archive_state"] == "archived", "charlie archived")

        with w.overview(columns=WIDTH, rows=30) as screen:
            screen.wait(lambda frame: " ✓ alpha" in frame and " ✓ bravo" in frame, "both answered rows")
            # Enter opens the selected Session: that names it.
            screen.keys(b"\r")
            opened = screen.wait(lambda frame: conversation_of("alpha")(frame) or conversation_of("bravo")(frame),
                                 "Enter opens the selected Session")
            selected = "alpha" if conversation_of("alpha")(opened) else "bravo"
            other = "bravo" if selected == "alpha" else "alpha"
            assert f"answer from {selected}" in opened and f"answer from {other}" not in opened, opened
            listed = back_to_overview(screen, " ✓ alpha", " ✓ bravo")

            click_label(screen, listed, other)
            screen.wait(conversation_of(other), f"a click opens {other}")
            screen.wait(lambda frame: f"answer from {other}" in frame, f"{other}'s answer")
            assert f"answer from {selected}" not in screen.text, screen.text
            assert f"ask {other}" in screen.text, screen.text
            listed = back_to_overview(screen, " ✓ alpha", " ✓ bravo")

            # And a click on the row now selected opens it too.
            click_label(screen, listed, other)
            screen.wait(lambda frame: conversation_of(other)(frame) and f"answer from {other}" in frame,
                        f"a click on selected {other} opens it")
            back_to_overview(screen, " ✓ alpha", " ✓ bravo")
        print("overview clicks: a click on a Session row other than the selected one opens the clicked Session's "
              "conversation, a click on the selected row opens it, and Esc returns to the overview", flush=True)

        with w.overview(columns=WIDTH, rows=30) as screen:
            screen.wait(lambda frame: " ✓ alpha" in frame, "the default view")
            listed = screen.text
            alpha_row = row_of(listed, "alpha")
            screen.keys(b"\x1b[F\r")
            screen.wait(lambda frame: "Notifications" in frame and "Version" in frame, "app settings")
            screen.keys(b"\x1b[B" * 6 + b"\r")
            panel = screen.wait(lambda frame: "earlier message" in frame and "tool output" in frame, "the keys panel")
            assert all(stale not in panel for stale in ("/help", "Commands", "Marks", "Esc returns", "Ctrl-X twice")), panel
            under = panel.split("\n")[alpha_row - 1]
            assert under.strip() and "alpha" not in under, (under, panel)
            screen.click(under.index(under.strip()[0]) + 1, alpha_row)
            screen.keys(b"\x1b")
            settings = screen.wait(lambda frame: "Notifications" in frame and "Version" in frame, "Esc closes only Keys after an inert click")
            assert "earlier message" not in settings, settings
            screen.keys(b"\x1b")
            screen.wait(lambda frame: is_overview(frame) and "✓ alpha" in frame, "Esc returns from Settings to the overview")
        print("overview clicks: a line of an open panel over a Session's row opens nothing", flush=True)


def flat_list():
    replies = FanOutReplies()
    peers_by_label = {}
    with world("clicks-flat", replies) as w:
        for n in range(7):
            peers_by_label[f"peer-{n}"] = w.session("--label", f"peer-{n}")
        lead = w.session("--label", "lead", "--tools", "bash", "--permission-mode", "bypass")
        replies.command = "; ".join(f"printf %s hi | {shlex.quote(str(fixture.RUI))} session send --to {peer}"
                                    for peer in peers_by_label.values())
        w.run("session", "send", "--store", w.store, "--to", lead, input="fan out")
        wait_for_host(w, [lead, *peers_by_label.values()], finished, "the lead and every peer finish")
        assert replies.lead_requests == 2, replies.lead_requests

        with w.overview(columns=WIDTH, rows=30) as screen:
            listed = screen.wait(lambda frame: all(f" ✓ {label}" in frame for label in peers_by_label),
                                 "every finished peer without folding")
            lines = listed.split("\n")
            assert lines[0] == "  + New Session" and lines[1] == "", listed
            assert not any(re.fullmatch(r" \S.* · \d+", line) for line in lines), listed
            assert " more" not in listed, listed
            # New Session opens an empty chat, then returns to this flat list.
            screen.click(4, 1)
            screen.wait(lambda frame: "Type a task" in frame and not is_overview(frame), "New Session opens chat")
            listed = back_to_overview(screen, *peers_by_label)
            # Every formerly hidden row is directly clickable.
            lines = listed.split("\n")
            label = lines[max(row_of(listed, peer) for peer in peers_by_label) - 1].split()[1]
            click_label(screen, listed, label)
            screen.wait(lambda frame: conversation_of(label)(frame) and "peer done" in frame,
                        f"a click opens the last peer {label}")
            back_to_overview(screen, f" ✓ {label}")
        print("overview clicks: all finished rows remain visible without headings or folds, and the last opens directly", flush=True)


def empty_list():
    with world("clicks-empty", {"first task": answer("new", "first task answered")}) as w, w.overview(columns=WIDTH, rows=30) as screen:
        frame = screen.contains("+ New Session")
        assert "No unarchived Sessions" not in frame and "Type a task" not in frame, frame
        known = set()
        for gesture in ("click", "Enter"):
            before = set((w.home / ".config/rui/requests").glob("*.json"))
            if gesture == "click":
                screen.click(4, line_of(frame, lambda line: "+ New Session" in line, "New Session"))
            else:
                screen.keys(b"\x1b[H\r")
            chat = screen.wait(lambda frame: "Type a task" in frame and not is_overview(frame), f"{gesture} opens an empty chat")
            sessions = json.loads(w.run("session", "list", "--store", w.store, "--all"))["sessions"]
            current = {row["reference"] for row in sessions}
            created, = current - known
            assert len(current) == len(known) + 1, sessions
            known = current
            report = w.inspect(created)
            assert report["selected_message"] is None and report["recent_messages"] == [], report
            assert report["session"]["model"] == MODEL, report
            assert MODEL in chat and w.endpoint.requests == [], chat
            captured, = set((w.home / ".config/rui/requests").glob("*.json")) - before
            assert json.loads(captured.read_bytes())["kind"] == "configure", captured.read_text()
            if gesture == "Enter":
                screen.keys(b"first task")
                screen.contains("› first task")
                screen.keys(b"\r")
                screen.contains("first task answered")
                assert len(w.endpoint.requests) == 1, w.endpoint.requests
                assert w.inspect(created)["selected_message"] is not None, created
            frame = back_to_overview(screen)
    print("overview clicks: click and Enter each Configure one empty Session; only chat typing sends a Message", flush=True)


def cases():
    opening_and_views()
    flat_list()
    empty_list()
