import io
import subprocess
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import call, patch

import open_pr


class OpenPrTest(unittest.TestCase):
    def test_opens_only_drafts(self):
        args = open_pr.create_args("Title", "body.md", "main", "fix-x")
        self.assertIn("--draft", args)
        self.assertEqual(args[:2], ["pr", "create"])
        self.assertEqual(args[args.index("--head") + 1], "fix-x")

    def test_open_requests_codex_review_on_the_created_draft(self):
        url = "https://github.com/example/rui/pull/9"
        for comment_error in (None, subprocess.CalledProcessError(1, ["gh", "pr", "comment"], stderr="denied")):
            with self.subTest(comment_error=comment_error):
                stdout, stderr = io.StringIO(), io.StringIO()
                replies = ['{"nameWithOwner": "example/rui"}', url + "\n", comment_error or ""]
                with patch("sys.argv", ["open_pr.py", "open", "--title", "Title", "--body-file", "body.md"]), \
                     patch.object(open_pr, "git", side_effect=["fix-x", "a" * 40, "a" * 40]), \
                     patch.object(open_pr, "gh", side_effect=replies) as gh, \
                     patch.object(open_pr, "branch_changes", return_value=([], {})), \
                     patch.object(open_pr, "overlaps", return_value=[]), \
                     patch.object(open_pr, "report"), redirect_stdout(stdout), redirect_stderr(stderr):
                    result = open_pr.main()
                self.assertEqual(gh.call_args_list, [
                    call("repo", "view", "--json", "nameWithOwner"),
                    call("pr", "create", "--draft", "--base", "main", "--head", "fix-x",
                         "--title", "Title", "--body-file", "body.md"),
                    call("pr", "comment", url, "--body", "@codex review"),
                ])
                self.assertIn(url, stdout.getvalue())
                if comment_error:
                    self.assertEqual(result, 1)
                    self.assertIn("denied", stderr.getvalue())
                    self.assertNotIn("requested Codex review", stdout.getvalue())
                else:
                    self.assertEqual(result, 0)
                    self.assertIn("after each push", stdout.getvalue())
                    self.assertIn("starts the full suite", stdout.getvalue())

    def test_opens_only_a_pushed_head(self):
        self.assertIsNone(open_pr.open_refusal("a" * 40, "a" * 40))
        self.assertIn("no upstream", open_pr.open_refusal("a" * 40, None))
        self.assertIn("Push the branch first", open_pr.open_refusal("a" * 40, "b" * 40))

    def test_ready_only_after_the_last_planned_push(self):
        head = "c" * 40
        draft = {"number": 9, "isDraft": True, "headRefOid": head}
        self.assertIsNone(open_pr.ready_refusal(draft, head, dirty=False))
        self.assertIn("no open PR", open_pr.ready_refusal(None, head, dirty=False))
        self.assertIn("already ready", open_pr.ready_refusal(dict(draft, isDraft=False), head, dirty=False))
        self.assertIn("local changes", open_pr.ready_refusal(draft, head, dirty=True))
        self.assertIn("push the last planned commit", open_pr.ready_refusal(draft, "d" * 40, dirty=False))


if __name__ == "__main__":
    unittest.main()
