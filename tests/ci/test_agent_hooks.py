import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from pr_shape import ready_refusal

HOOK = Path(__file__).resolve().parents[2] / ".claude/hooks/block_full_runs.py"
MERGE_HOOK = HOOK.with_name("review_before_merge.py")
WAITING_HOOK = HOOK.with_name("person_messages.py")


def run(command):
    return subprocess.run([sys.executable, "-B", str(HOOK)], input=json.dumps(
        {"tool_name": "Bash", "tool_input": {"command": command}}), text=True, capture_output=True)


class BlockFullRunsTest(unittest.TestCase):
    def test_full_suites_and_ci_mirrors_are_refused(self):
        for command in ("zig build test", "cd rui && zig build check --summary all",
                        "/opt/zig/zig build test test-logic -j4", "zig build check-full -Dcheck-part=callers",
                        "bash /mnt/project-files/frontend/pr-gates.sh HEAD",
                        "sh /mnt/project-files/rui-dev/nonroot-check.sh", "time zig build test 2>&1 | tail",
                        "bash -c 'zig build test'", "(zig build check)", "timeout 600 zig build -j4 check",
                        "echo RUI_CI_RED=1 zig build test", "zig build test --foo RUI_CI_RED=x",
                        "RUI_CI_RED=#1 true; zig build check", "zig build \\\ncheck --summary all"):
            with self.subTest(command=command):
                result = run(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn("RUI_CI_RED=", result.stderr)

    def test_focused_runs_and_a_named_ci_red_pass(self):
        for command in ("zig build test -Dtest-filter=api_key", "zig build test-logic --summary all",
                        "zig build typecheck-macos", "zig fmt --check src", "zig build",
                        "python3 tests/ci/prepush.py", "RUI_CI_RED=#755 zig build check",
                        "cd rui && RUI_CI_RED=https://x/runs/1 timeout 900 zig build test",
                        "RUI_CI_RED=#755 bash pr-gates.sh HEAD", "zig build test --summary all -Dtest-filter=x", "zig build test \\\n  -Dtest-filter=Store",
                        "git log --grep 'build check'", "echo test"):
            with self.subTest(command=command):
                self.assertEqual(run(command).returncode, 0, command)


def load_merge_hook():
    spec = importlib.util.spec_from_file_location("review_before_merge", MERGE_HOOK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def merge_call(tool, **args):
    return {"tool_name": tool, "tool_input": args}


class ReviewBeforeMergeTest(unittest.TestCase):
    def setUp(self):
        self.hook = load_merge_hook()

    def test_every_way_to_merge_a_rui_pr_is_recognised(self):
        rui = {"owner": "DivyanshGolyan", "repo": "rui"}
        for payload, numbers in (
                (merge_call("mcp__github__merge_pull_request", pullNumber=2302, **rui), [2302]),
                (merge_call("mcp__github__enable_pr_auto_merge", pullNumber=2289, **rui), [2289]),
                (merge_call("mcp__github__merge_pull_request", owner="divyanshgolyan", repo="Rui", pullNumber=7), [7]),
                (merge_call("Bash", command="gh pr merge 2302 --squash"), [2302]),
                (merge_call("Bash", command="cd rui && gh pr merge --squash --auto 2289"), [2289]),
                (merge_call("Bash", command="gh pr merge https://github.com/DivyanshGolyan/rui/pull/2305"), [2305]),
                (merge_call("Bash", command="gh pr merge -R DivyanshGolyan/rui --body 'fixes 9' 11"), [11]),
                (merge_call("Bash", command="gh pr merge 2310; gh pr merge 5 && echo done"), [2310, 5]),
                (merge_call("Bash", command="gh api -X PUT repos/DivyanshGolyan/rui/pulls/2288/merge"), [2288])):
            with self.subTest(payload=payload):
                self.assertEqual(self.hook.merged_prs(payload), numbers)

    def test_a_merge_without_a_number_resolves_the_branch_pr(self):
        for command in ("gh pr merge --squash --auto", "gh pr merge", "gh pr merge --squash --delete-branch", "gh pr merge fix/x"):
            with self.subTest(command=command):
                asked = []
                view = lambda argv: asked.append(argv) or "2310\n"
                self.assertEqual(self.hook.merged_prs(merge_call("Bash", command=command), view), [2310])
                self.assertIn("--repo", asked[0])

    def test_other_calls_and_other_repositories_are_ignored(self):
        for payload in (merge_call("mcp__github__merge_pull_request", owner="someone", repo="else", pullNumber=1),
                        merge_call("mcp__github__pull_request_read", owner="DivyanshGolyan", repo="rui", pullNumber=1),
                        merge_call("Bash", command="gh pr merge --repo other/thing 5"),
                        merge_call("Bash", command="gh pr view 2302"),
                        merge_call("Read", file_path="x")):
            with self.subTest(payload=payload):
                self.assertEqual(self.hook.merged_prs(payload), [])

    def test_an_unreviewed_pr_is_refused_and_a_reviewed_one_passes(self):
        merge = merge_call("mcp__github__merge_pull_request", owner="DivyanshGolyan", repo="rui", pullNumber=2302)
        code, message = self.hook.judge(merge, lambda number: f"PR #{number} has no completed review. open_pr.py review")
        self.assertEqual(code, 2)
        self.assertIn("open_pr.py review", message)
        self.assertEqual(self.hook.judge(merge, lambda number: None), (0, ""))

    def test_an_unreadable_review_record_does_not_block(self):
        def offline(number):
            raise subprocess.CalledProcessError(1, ["gh"], stderr="offline")
        code, message = self.hook.judge(merge_call("Bash", command="gh pr merge 2302"), offline)
        self.assertEqual(code, 0)
        self.assertIn("not blocking", message)


def load_ready_hook():
    spec = importlib.util.spec_from_file_location("ready_pr_shape", MERGE_HOOK.with_name("ready_pr_shape.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReadyPrShapeTest(unittest.TestCase):
    def setUp(self):
        self.hook = load_ready_hook()
        self.rui = {"owner": "DivyanshGolyan", "repo": "rui"}

    def test_only_calls_that_make_a_rui_pr_ready_are_judged(self):
        create = lambda **a: {"tool_name": "mcp__github__create_pull_request", "tool_input": {**self.rui, "head": "x", **a}}
        update = lambda **a: {"tool_name": "mcp__github__update_pull_request", "tool_input": {**self.rui, "pullNumber": 9, **a}}
        self.assertEqual(self.hook.ready_call(create(body="b")), (None, "x", "b", "main"))
        self.assertEqual(self.hook.ready_call(create(draft=False, body="b")), (None, "x", "b", "main"))
        self.assertEqual(self.hook.ready_call(create(draft=True, body="b")), (None, "x", "b", "main"))
        self.assertEqual(self.hook.ready_call(create(base="parent", body="b")), (None, "x", "b", "parent"))
        self.assertEqual(self.hook.ready_call(update(draft=False)), (9, None, None, None))
        self.assertIsNone(self.hook.ready_call(update(body="new body")))
        self.assertIsNone(self.hook.ready_call(update(draft=True)))
        other = {"tool_name": "mcp__github__create_pull_request", "tool_input": {"owner": "a", "repo": "b"}}
        self.assertIsNone(self.hook.ready_call(other))

    def test_pr_2305_without_a_screen_line_is_refused_and_with_one_passes(self):
        # #2305 (one assertion in src/chat_info.zig) was marked ready with this body; admission rejected it 20 minutes later.
        body = "No issue: main is red on two tests since #2284 added `watch_github_pr`.\n\n## Summary\n\n```\nx\n```\n"
        api = lambda method, path: ({"body": body, "base": {"ref": "main"}} if path.endswith("/pulls/9")
                                    else [{"filename": "src/chat_info.zig"}, {"filename": "tests/integration/product_defaults.py"}])
        ui = lambda paths, base=None: True
        no_comment = lambda repo, number: False
        judge = lambda paths, body, **kw: ready_refusal(paths, body, needs=ui, sticky=no_comment, **kw)
        reason = self.hook.refusal((9, None, None, None), api, judge)
        self.assertIn("No screen change:", reason)
        self.assertIn("re-run verify-rui publish DIR --pr 9", reason)
        fixed = body + "No screen change: one unit-test assertion\n"
        self.assertIsNone(self.hook.refusal((9, None, fixed, None), api, judge))

    def test_the_judged_diff_is_against_the_prs_own_base(self):
        # a stacked PR changes only what it adds to its parent; judging against main blames it for the parent's files
        seen = []
        judge = lambda paths, body, **kw: seen.append((paths, kw["base"])) or None
        api = lambda method, path: (
            {"body": "b", "base": {"ref": "parent"}} if path.endswith("/pulls/9")
            else {"files": [{"filename": "docs/a.md"}]} if "/compare/" in path else [{"filename": "docs/a.md"}])
        self.hook.refusal((9, None, None, None), api, judge)
        self.hook.refusal((None, "head", "b", "parent"), api, judge)
        self.assertEqual(seen, [(["docs/a.md"], "origin/parent")] * 2)

    def test_a_refused_call_exits_2_with_the_reason_on_stderr(self):
        payload = {"tool_name": "mcp__github__create_pull_request",
                   "tool_input": {**self.rui, "head": "x", "body": "No issue: a body with no sketch needed here"}}
        api = lambda method, path: {"files": [{"filename": "src/chat_info.zig"}]}
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self.hook.main(io.StringIO(json.dumps(payload)), api), 2)
        self.assertIn("would fail admission", stderr.getvalue())
        self.assertIn("nonempty fenced sketch", stderr.getvalue())

    def test_an_unreadable_pr_does_not_block(self):
        payload = {"tool_name": "mcp__github__update_pull_request", "tool_input": {**self.rui, "pullNumber": 9, "draft": False}}
        def unreadable(*args):
            raise subprocess.CalledProcessError(1, ["gh"])
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self.hook.main(io.StringIO(json.dumps(payload)), unreadable), 0)
        self.assertIn("not blocking", stderr.getvalue())


# What the "Clean up TUI internals" thread told Divyansh on 2026-11-25 (09:47 and 09:52 UTC) and put on its checklist,
# while no decision card was open: he asked "what do you need from me?" and found nothing to answer.
UNASKED_MESSAGES = (
    "U10 (tool picker names) is merged as #2288. U11, U9, U8 and U6 are open as #2292, #2295, #2299 and #2303, each "
    "with one review done and its findings fixed; I'm waiting on CI and will merge each on green. U4, U5 and U7 "
    "wait on other PRs, and U2 waits on Divyansh's yes about glyph-leading lines.",
    "Nothing needed from you right now. U10 is merged, and #2292, #2295, #2299 and #2303 are open. U2 still waits "
    "on your yes about lines that start with a glyph and a space.")
UNASKED_CHECKLIST = ("TUI internals (U group of #2282)\n\n✓ U10 Tool picker names: merged #2288\n"
                     "○ Later: U4, U5, U7 (wait on other PRs), U2 (waits on Divyansh's yes)")


def transcript(*turns, refused=False):
    """A Claude Code transcript file: each turn is the tool names the assistant called after a person's message.

    `refused` makes every tool call of the last turn come back as an error, as a hook's refusal does.
    """
    lines = []
    for number, tools in enumerate(turns):
        failed = refused and number == len(turns) - 1
        lines.append({"type": "user", "message": {"role": "user", "content": "wake"}})
        lines.append({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": f"t{number}-{i}", "name": name, "input": {}} for i, name in enumerate(tools)]}})
        lines.append({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": f"t{number}-{i}", "content": "ok", "is_error": failed}
            for i, _ in enumerate(tools)]}})
    directory = tempfile.TemporaryDirectory()
    transcript.directories.append(directory)
    path = Path(directory.name) / "transcript.jsonl"
    path.write_text("\n".join(json.dumps(line) for line in lines))
    return str(path)


transcript.directories = []


def run_waiting(tool, text, transcript_path=None):
    args = text if isinstance(text, dict) else {"text": text}
    payload = {"tool_name": "mcp__hearthbot__" + tool, "tool_input": args, "transcript_path": transcript_path}
    return subprocess.run([sys.executable, "-B", str(WAITING_HOOK)], input=json.dumps(payload),
                          text=True, capture_output=True)


def tearDownModule():
    for directory in transcript.directories:
        directory.cleanup()


class WaitingDomainTest(unittest.TestCase):
    """The hook's whole input domain for a post_message that mentions the person."""

    def verdict(self, text, path=None):
        return run_waiting("post_message", text, path or transcript([])).returncode

    def test_claims_are_refused_and_everything_else_passes(self):
        cases = (
            ("Still waiting on your yes. I did not open a card.", 2),
            ("U2 waits on your yes. https://example.com/y?z=1", 2),
            ("Waiting on CI and on main being green.", 0),
            ("No decision is waiting on you.", 0),
            ("U2 doesn't wait on you.", 0),
            ('He wrote "waiting on you" earlier, which I answered.', 0),
            ("Do you want U2 first? I'm waiting on your yes.", 0),
            ("The card above asks; waiting on your yes.", 2),
        )
        for text, code in cases:
            with self.subTest(text=text):
                self.assertEqual(self.verdict(text), code)

    def test_a_refused_card_does_not_count_as_an_open_question(self):
        claim = "Waiting on your yes for U2."
        self.assertEqual(self.verdict(claim, transcript(["mcp__hearthbot__request_decision"])), 0)
        self.assertEqual(self.verdict(claim, transcript(["mcp__hearthbot__request_decision"], refused=True)), 2)

    def test_an_oddly_shaped_transcript_counts_as_asked(self):
        claim = "Waiting on your yes for U2."
        with tempfile.TemporaryDirectory() as directory:
            for name, content in (("array", "[1]\n"), ("string_message", json.dumps({"type": "user", "message": "x"}) + "\n"),
                                  ("garbage", "not json\n")):
                path = Path(directory, name)
                path.write_text(content)
                with self.subTest(shape=name):
                    self.assertEqual(self.verdict(claim, str(path)), 0)
        self.assertEqual(self.verdict(claim, "/no/such/transcript"), 0)


class WaitingNeedsAQuestionTest(unittest.TestCase):
    def test_waiting_on_the_person_with_no_question_open_is_refused(self):
        for text in UNASKED_MESSAGES:
            with self.subTest(text=text[:40]):
                result = run_waiting("post_message", text, transcript([]))
                self.assertEqual(result.returncode, 2)
                self.assertIn("request_decision", result.stderr)

    def test_a_checklist_never_lists_what_the_person_must_do(self):
        for opened in ([], ["mcp__hearthbot__request_decision"]):
            with self.subTest(card_open=bool(opened)):
                result = run_waiting("update_progress_checklist", UNASKED_CHECKLIST, transcript(opened))
                self.assertEqual(result.returncode, 2)
                self.assertIn("never lists what the person must do", result.stderr)

    def test_a_question_this_turn_lets_the_message_through(self):
        waits = UNASKED_MESSAGES[1]
        for text, path in ((waits, transcript(["mcp__hearthbot__request_decision", "mcp__hearthbot__post_message"])),
                           ("Should U2 stop the quote bar? It waits on your yes.", transcript([]))):
            with self.subTest(text=text[-40:]):
                self.assertEqual(run_waiting("post_message", text, path).returncode, 0)

    def test_a_card_from_an_earlier_turn_does_not_cover_a_new_claim(self):
        path = transcript(["mcp__hearthbot__request_decision"], ["mcp__hearthbot__post_message"])
        self.assertEqual(run_waiting("post_message", UNASKED_MESSAGES[1], path).returncode, 2)

    def test_ordinary_status_and_negations_pass(self):
        for text in ("Nothing is waiting on you.", "I'm waiting on CI, then I merge.", "Needs a rebase after #2305.",
                     "The PR is blocked on main being red.", "Not waiting on your answer: I chose the default."):
            with self.subTest(text=text):
                self.assertEqual(run_waiting("post_message", text, transcript([])).returncode, 0)

    def test_an_unreadable_transcript_does_not_block_a_message(self):
        self.assertEqual(run_waiting("post_message", UNASKED_MESSAGES[1], "/nonexistent").returncode, 0)


# The card Divyansh answered "didn't understand" on 2026-11-25 09:53 UTC, and the 2026-11-23 #937 card he said the same of.
CODE_CARDS = (
    {"question": 'Let a line that starts with "$ ", "│ " or "- " stop getting a quote bar?',
     "options": [{"label": "Yes, tag lines at the source",
                  "consequence": "Rui's own marks keep their hanging indent and bar. Prose that starts with \"$ \" wraps flush."},
                 {"label": "No, keep guessing from glyphs", "consequence": "Nothing changes on screen."}],
     "recommended": 0, "reason": "Only prose that starts with one of those glyphs and a space changes."},
    {"question": "Rename --to to --address?", "options": [{"label": "Yes", "consequence": "Scripts using --to break."},
                                                           {"label": "No", "consequence": "Nothing changes."}], "recommended": 0})


class PlainCardTest(unittest.TestCase):
    def test_a_card_written_in_symbols_and_names_is_refused(self):
        for card in CODE_CARDS:
            with self.subTest(question=card["question"][:30]):
                result = run_waiting("request_decision", card)
                self.assertEqual(result.returncode, 2)
                self.assertIn("everyday words", result.stderr)

    def test_a_card_in_everyday_words_passes(self):
        card = {"question": "Should a chat line that starts with a dollar sign stop getting the thin side bar?",
                "options": [{"label": "Yes, only Rui's own lines get it",
                             "consequence": "Today: your chat line \"$ ls is fine\" wraps with a bar. After: it wraps plain."},
                            {"label": "No, leave it", "consequence": "Nothing changes on screen."}],
                "recommended": 0, "reason": "Only an odd chat line changes."}
        self.assertEqual(run_waiting("request_decision", card).returncode, 0)


if __name__ == "__main__":
    unittest.main()
