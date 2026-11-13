import io
import subprocess
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import call, patch

import open_pr


class OpenPrTest(unittest.TestCase):
    def test_opens_only_drafts_over_rest(self):
        args = open_pr.create_args("o/r", "Title", "body.md", "main", "fix-x")
        self.assertEqual(args[:4], ["api", "-X", "POST", "repos/o/r/pulls"])
        self.assertIn("draft=true", args)
        self.assertIn("head=fix-x", args)
        self.assertIn("body=@body.md", args)

    def test_open_requests_codex_review_on_the_created_draft(self):
        url = "https://github.com/example/rui/pull/9"
        for comment_error in (None, subprocess.CalledProcessError(1, ["gh", "api"], stderr="denied")):
            with self.subTest(comment_error=comment_error):
                stdout, stderr = io.StringIO(), io.StringIO()
                created = '{"number": 9, "html_url": "%s"}' % url
                with patch("sys.argv", ["open_pr.py", "open", "--title", "Title", "--body-file", "body.md"]), \
                     patch.object(open_pr, "git", side_effect=["fix-x", "a" * 40, "a" * 40]), \
                     patch.object(open_pr, "origin_repo", return_value="example/rui"), \
                     patch.object(open_pr, "gh", return_value=created) as gh, \
                     patch.object(open_pr, "github", side_effect=[comment_error or None]) as github, \
                     patch.object(open_pr, "branch_changes", return_value=([], {})), \
                     patch.object(open_pr, "overlaps", return_value=[]), \
                     patch.object(open_pr, "report"), redirect_stdout(stdout), redirect_stderr(stderr):
                    result = open_pr.main()
                self.assertEqual(gh.call_args_list, [
                    call(*open_pr.create_args("example/rui", "Title", "body.md", "main", "fix-x"))])
                self.assertEqual(github.call_args_list, [
                    call("POST", "repos/example/rui/issues/9/comments", [("body", "@codex review")])])
                self.assertIn(url, stdout.getvalue())
                if comment_error:
                    self.assertEqual(result, 1)
                    self.assertIn("denied", stderr.getvalue())
                    self.assertNotIn("requested Codex review", stdout.getvalue())
                else:
                    self.assertEqual(result, 0)
                    self.assertIn("after each push", stdout.getvalue())
                    self.assertIn("starts the full suite", stdout.getvalue())

    def test_ready_finds_the_pr_over_rest(self):
        head = "c" * 40
        draft = {"number": 9, "draft": True, "head": {"sha": head}}
        stdout = io.StringIO()
        with patch("sys.argv", ["open_pr.py", "ready"]), \
             patch.object(open_pr, "git", side_effect=["fix/x", head, ""]), \
             patch.object(open_pr, "origin_repo", return_value="example/rui"), \
             patch.object(open_pr, "github", return_value=[draft]) as github, \
             patch.object(open_pr, "gh", return_value="") as gh, redirect_stdout(stdout):
            self.assertEqual(open_pr.main(), 0)
        github.assert_called_once_with("GET", "repos/example/rui/pulls?state=open&head=example:fix/x")
        gh.assert_called_once_with("pr", "ready", "9", "--repo", "example/rui")

    def test_opens_only_a_pushed_head(self):
        self.assertIsNone(open_pr.open_refusal("a" * 40, "a" * 40))
        self.assertIn("no upstream", open_pr.open_refusal("a" * 40, None))
        self.assertIn("Push the branch first", open_pr.open_refusal("a" * 40, "b" * 40))

    def test_ready_only_after_the_last_planned_push(self):
        head = "c" * 40
        draft = {"number": 9, "draft": True, "head": {"sha": head}}
        self.assertIsNone(open_pr.ready_refusal(draft, head, dirty=False))
        self.assertIn("no open PR", open_pr.ready_refusal(None, head, dirty=False))
        self.assertIn("already ready", open_pr.ready_refusal(dict(draft, draft=False), head, dirty=False))
        self.assertIn("local changes", open_pr.ready_refusal(draft, head, dirty=True))
        self.assertIn("push the last planned commit", open_pr.ready_refusal(draft, "d" * 40, dirty=False))


if __name__ == "__main__":
    unittest.main()
