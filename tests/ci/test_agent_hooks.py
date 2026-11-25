import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest

from pr_shape import ready_refusal

HOOK = Path(__file__).resolve().parents[2] / ".claude/hooks/block_full_runs.py"
MERGE_HOOK = HOOK.with_name("review_before_merge.py")


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
        self.assertEqual(self.hook.ready_call(create(body="b")), (None, "x", "b"))
        self.assertEqual(self.hook.ready_call(create(draft=False, body="b")), (None, "x", "b"))
        self.assertEqual(self.hook.ready_call(create(draft=True, body="b")), (None, "x", "b"))
        self.assertEqual(self.hook.ready_call(update(draft=False)), (9, None, None))
        self.assertIsNone(self.hook.ready_call(update(body="new body")))
        self.assertIsNone(self.hook.ready_call(update(draft=True)))
        other = {"tool_name": "mcp__github__create_pull_request", "tool_input": {"owner": "a", "repo": "b"}}
        self.assertIsNone(self.hook.ready_call(other))

    def test_pr_2305_without_a_screen_line_is_refused_and_with_one_passes(self):
        # #2305 (one assertion in src/chat_info.zig) was marked ready with this body; admission rejected it 20 minutes later.
        body = "No issue: main is red on two tests since #2284 added `watch_github_pr`.\n\n## Summary\n\n```\nx\n```\n"
        api = lambda method, path: ({"body": body} if path.endswith("/pulls/9")
                                    else [{"filename": "src/chat_info.zig"}, {"filename": "tests/integration/product_defaults.py"}])
        ui = lambda paths, base=None: True
        no_comment = lambda repo, number: False
        judge = lambda paths, body, **kw: ready_refusal(paths, body, needs=ui, sticky=no_comment, **kw)
        reason = self.hook.refusal((9, None, None), api, judge)
        self.assertIn("No screen change:", reason)
        self.assertIn("open_pr.py open --frames", reason)
        fixed = body + "No screen change: one unit-test assertion\n"
        self.assertIsNone(self.hook.refusal((9, None, fixed), api, judge))

    def test_an_unreadable_pr_does_not_block(self):
        payload = {"tool_name": "mcp__github__update_pull_request", "tool_input": {**self.rui, "pullNumber": 9, "draft": False}}
        def unreadable(*args):
            raise subprocess.CalledProcessError(1, ["gh"])
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self.hook.main(io.StringIO(json.dumps(payload)), unreadable), 0)
        self.assertIn("not blocking", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
