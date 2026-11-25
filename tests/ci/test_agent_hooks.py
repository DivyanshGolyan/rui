import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

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

    def run_hook(self, payload, refusal=None, error=None):
        stderr = io.StringIO()
        with patch("sys.stdin", io.StringIO(json.dumps(payload))), contextlib.redirect_stderr(stderr), \
                patch("merge_review.pr_refusal", side_effect=error, return_value=refusal):
            return self.hook.main(), stderr.getvalue()

    def test_every_way_to_merge_a_rui_pr_is_recognised(self):
        rui = {"owner": "DivyanshGolyan", "repo": "rui"}
        for payload, number in (
                (merge_call("mcp__github__merge_pull_request", pullNumber=2302, **rui), 2302),
                (merge_call("mcp__github__enable_pr_auto_merge", pullNumber=2289, **rui), 2289),
                (merge_call("Bash", command="gh pr merge 2302 --squash"), 2302),
                (merge_call("Bash", command="cd rui && gh pr merge --squash --auto 2289"), 2289),
                (merge_call("Bash", command="gh pr merge https://github.com/DivyanshGolyan/rui/pull/2305"), 2305),
                (merge_call("Bash", command="gh api -X PUT repos/DivyanshGolyan/rui/pulls/2288/merge"), 2288)):
            with self.subTest(payload=payload):
                self.assertEqual(self.hook.merged_pr(payload), number)

    def test_other_calls_and_other_repositories_are_ignored(self):
        for payload in (merge_call("mcp__github__merge_pull_request", owner="someone", repo="else", pullNumber=1),
                        merge_call("mcp__github__pull_request_read", owner="DivyanshGolyan", repo="rui", pullNumber=1),
                        merge_call("Bash", command="gh pr view 2302"),
                        merge_call("Read", file_path="x")):
            with self.subTest(payload=payload):
                self.assertIsNone(self.hook.merged_pr(payload))

    def test_an_unreviewed_pr_is_refused_and_a_reviewed_one_passes(self):
        merge = merge_call("mcp__github__merge_pull_request", owner="DivyanshGolyan", repo="rui", pullNumber=2302)
        code, message = self.run_hook(merge, refusal="PR #2302 has no completed review. open_pr.py review")
        self.assertEqual(code, 2)
        self.assertIn("open_pr.py review", message)
        self.assertEqual(self.run_hook(merge)[0], 0)

    def test_an_unreadable_review_record_does_not_block(self):
        merge = merge_call("Bash", command="gh pr merge 2302")
        code, message = self.run_hook(merge, error=subprocess.CalledProcessError(1, ["gh"], stderr="offline"))
        self.assertEqual(code, 0)
        self.assertIn("not blocking", message)


if __name__ == "__main__":
    unittest.main()
