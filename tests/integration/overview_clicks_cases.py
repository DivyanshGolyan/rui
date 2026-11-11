"""Overview pointer behavior: Session rows open, New Session composes,
/sessions reaches archive views, and panels never open rows.
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
    """Pinned Settings and the overview composer, never chat facts."""
    return "Settings" in frame and not any(line.startswith(" ‹ ") for line in frame.split("\n"))


def conversation_of(label):
    """A frame showing `label`'s conversation: the facts row under its
    composer leads with `‹` and names it."""
    return lambda frame: any(line.startswith(f" ‹ {label} · {MODEL}") for line in frame.split("\n")) and not is_overview(frame)


def back_to_overview(screen, *markers):
    screen.keys(b"\x1b")
    return screen.wait(lambda frame: is_overview(frame) and all(marker in frame for marker in markers),
                       ("Esc returns to the overview", markers))


def assert_still_overview(screen, what, *markers):
    """The click before this one opened nothing: a draft typed after it
    shows in the overview's composer, beside `markers`. Esc closes any
    panel, then clears the draft."""
    screen.keys("zz")
    frame = screen.wait(lambda frame: "› zz" in frame, (what, "the draft typed after the click"))
    assert is_overview(frame), (what, "a click opened something", frame)
    for marker in markers:
        assert marker in frame, (what, marker, frame)
    if "Esc returns" in frame:
        screen.keys(b"\x1b")
        screen.wait(lambda frame: "Esc returns" not in frame and "› zz" in frame, (what, "Esc closes the panel"))
    screen.keys(b"\x1b")
    screen.wait(lambda frame: "› Type a task" in frame and is_overview(frame), (what, "Esc clears the draft"))
    return frame


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
            # Enter on a blank draft opens the selected Session: that names it.
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
            assert not screen.rows()[0].rstrip().endswith(("Archived", "All")), screen.text
            for command, name in (("archived", "Archived"), ("all", "All")):
                screen.keys(f"/sessions {command}\r")
                screen.wait(lambda frame: "[Archived] charlie" in frame and "/sessions" not in frame,
                            f"the {name} view")
                screen.keys(b"/sessions unarchived\r")
                back = screen.wait(lambda frame: "✓ alpha" in frame and "charlie" not in frame and "/sessions" not in frame,
                                   f"{name} returns to default by command")
                assert is_overview(back), back
            print("overview clicks: /sessions reaches every archive view without a counts-line click", flush=True)

            listed = screen.text
            alpha_row = row_of(listed, "alpha")
            screen.keys("/help\r")
            panel = screen.wait(lambda frame: "Esc returns" in frame and "/sessions [VIEW]" in frame, "the help panel")
            under = panel.split("\n")[alpha_row - 1]
            assert under.strip() and "alpha" not in under, (under, panel)
            screen.click(under.index(under.strip()[0]) + 1, alpha_row)
            assert_still_overview(screen, "a panel line over alpha's row", "Esc returns", "/sessions [VIEW]")
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
            # New Session selects the composer, not a conversation.
            screen.click(4, 1)
            assert_still_overview(screen, "New Session", *peers_by_label)
            # Every formerly hidden row is directly clickable.
            label = lines[max(row_of(listed, peer) for peer in peers_by_label) - 1].split()[1]
            click_label(screen, listed, label)
            screen.wait(lambda frame: conversation_of(label)(frame) and "peer done" in frame,
                        f"a click opens the last peer {label}")
            back_to_overview(screen, f" ✓ {label}")
        print("overview clicks: all finished rows remain visible without headings or folds, and the last opens directly", flush=True)


def empty_list():
    with world("clicks-empty") as w, w.overview(columns=WIDTH, rows=30) as screen:
        frame = screen.contains("+ New Session")
        assert "No unarchived Sessions" not in frame, frame
        screen.click(4, line_of(frame, lambda line: "+ New Session" in line, "New Session"))
        assert_still_overview(screen, "New Session in an empty Store", "+ New Session")
        screen.keys(b"\r")
        assert_still_overview(screen, "Enter on New Session", "+ New Session")
    print("overview clicks: New Session in an empty Store keeps the composer focused", flush=True)


def cases():
    opening_and_views()
    flat_list()
    empty_list()
