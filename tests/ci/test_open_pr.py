import io
import subprocess
import tempfile
from pathlib import Path
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import call, patch

import open_pr
from test_pr_shape import GOAL


class OpenPrTest(unittest.TestCase):
    def test_opens_ready_over_rest_by_default(self):
        args = open_pr.create_args("o/r", "Title", "Description", "main", "fix-x")
        self.assertEqual(args[:4], ["api", "-X", "POST", "repos/o/r/pulls"])
        self.assertIn("draft=false", args)
        self.assertIn("head=fix-x", args)
        self.assertIn("body=Description", args)

    def test_opens_draft_over_rest_when_requested(self):
        args = open_pr.create_args("o/r", "Title", "Description", "main", "fix-x", draft=True)
        self.assertEqual(args[:4], ["api", "-X", "POST", "repos/o/r/pulls"])
        self.assertEqual(args[args.index("-F") + 1], "draft=true")
        self.assertNotIn("draft=false", args)
        self.assertIn("head=fix-x", args)
        self.assertIn("body=Description", args)

    def test_open_requests_codex_review_on_ready_and_draft_candidates(self):
        url = "https://github.com/example/rui/pull/9"
        for draft in (False, True):
            for comment_error in (None, subprocess.CalledProcessError(1, ["gh", "api"], stderr="denied")):
                with self.subTest(draft=draft, comment_error=comment_error):
                    stdout, stderr = io.StringIO(), io.StringIO()
                    created = '{"number": 9, "html_url": "%s"}' % url
                    argv = ["open_pr.py", "open", "--title", "Title", "--body-file", "body.md"]
                    if draft:
                        argv.append("--draft")
                    with patch("sys.argv", argv), \
                         patch.object(open_pr, "git", side_effect=["fix-x", "a" * 40, "a" * 40, ""]), \
                         patch.object(open_pr, "origin_repo", return_value="example/rui"), \
                         patch.object(open_pr, "gh", return_value=created) as gh, \
                         patch.object(open_pr, "github", side_effect=[comment_error or None]) as github, \
                         patch.object(open_pr.Path, "read_text", return_value=GOAL + "Description"), \
                         patch.object(open_pr, "branch_changes", return_value=([], {})), \
                         patch.object(open_pr, "overlaps", return_value=[]), \
                         patch.object(open_pr, "report"), redirect_stdout(stdout), redirect_stderr(stderr):
                        result = open_pr.main()
                    self.assertEqual(gh.call_args_list, [
                        call(*open_pr.create_args("example/rui", "Title", GOAL + "Description",
                                                 "main", "fix-x", draft=draft))])
                    self.assertIn("draft=true" if draft else "draft=false", gh.call_args.args)
                    self.assertEqual(github.call_args_list, [
                        call("POST", "repos/example/rui/issues/9/comments", [("body", "@codex review")])])
                    self.assertIn(url, stdout.getvalue())
                    if comment_error:
                        self.assertEqual(result, 1)
                        self.assertIn("denied", stderr.getvalue())
                        self.assertNotIn("requested Codex review", stdout.getvalue())
                    else:
                        self.assertEqual(result, 0)
                        self.assertIn("clean Codex evidence", stdout.getvalue())
                        if draft:
                            self.assertIn("Opened draft and requested Codex review", stdout.getvalue())
                            self.assertIn("open_pr.py ready", stdout.getvalue())
                            self.assertNotIn("Opened ready", stdout.getvalue())
                            self.assertNotIn("Selected CI runs beside review", stdout.getvalue())
                        else:
                            self.assertIn("Opened ready and requested Codex review", stdout.getvalue())
                            self.assertIn("Selected CI runs beside review", stdout.getvalue())
                            self.assertNotIn("Opened draft", stdout.getvalue())

    def test_open_validates_body_before_github_with_the_selected_base(self):
        cases = (
            ({"src/cli.zig"}, "Description", False),
            ({"src/cli.zig"}, "## Summary\n```text\ninput -> owner\n```", True),
            ({"src/cli.zig"}, "## Shape\nLegacy description", True),
            ({"docs/guide.md"}, "Description", True),
        )
        for paths, body, accepted in cases:
            body = GOAL + body
            with self.subTest(paths=paths, body=body), tempfile.TemporaryDirectory() as directory:
                body_file = Path(directory) / "body.md"
                body_file.write_text(body, encoding="utf-8")
                stderr = io.StringIO()
                removed = {"old_name"}

                def change_body_after_validation(*args):
                    body_file.write_text("Replaced after validation", encoding="utf-8")
                    return []

                with patch("sys.argv", ["open_pr.py", "open", "--title", "Title",
                                        "--body-file", str(body_file), "--base", "parent"]), \
                     patch.object(open_pr, "git", side_effect=["fix-x", "a" * 40, "a" * 40, ""]), \
                     patch.object(open_pr, "origin_repo", return_value="example/rui"), \
                     patch.object(open_pr, "branch_changes", return_value=(paths, removed)) as changes, \
                     patch.object(open_pr, "overlaps", side_effect=change_body_after_validation) as overlaps, \
                     patch.object(open_pr, "gh", return_value='{"number": 9, "html_url": "url"}') as gh, \
                     patch.object(open_pr, "github") as github, \
                     redirect_stdout(io.StringIO()), redirect_stderr(stderr):
                    result = open_pr.main()
                changes.assert_called_once_with("origin/parent")
                self.assertEqual(result, 0 if accepted else 1)
                if accepted:
                    overlaps.assert_called_once_with(github, "example/rui", "fix-x", paths, removed)
                    gh.assert_called_once_with(*open_pr.create_args(
                        "example/rui", "Title", body, "parent", "fix-x"))
                    self.assertEqual(body_file.read_text(encoding="utf-8"), "Replaced after validation")
                    github.assert_called_once()
                else:
                    self.assertIn("nonempty fenced sketch", stderr.getvalue())
                    overlaps.assert_not_called()
                    gh.assert_not_called()
                    github.assert_not_called()

    def test_open_reports_unreadable_body_without_github(self):
        for error in (FileNotFoundError("missing body"), PermissionError("unreadable body"),
                      UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid body")):
            with self.subTest(error=error):
                stderr = io.StringIO()
                with patch("sys.argv", ["open_pr.py", "open", "--title", "Title", "--body-file", "body.md"]), \
                     patch.object(open_pr, "git", side_effect=["fix-x", "a" * 40, "a" * 40, ""]), \
                     patch.object(open_pr, "origin_repo", return_value="example/rui"), \
                     patch.object(open_pr.Path, "read_text", side_effect=error), \
                     patch.object(open_pr, "branch_changes") as changes, \
                     patch.object(open_pr, "gh") as gh, patch.object(open_pr, "github") as github, \
                     redirect_stderr(stderr):
                    self.assertEqual(open_pr.main(), 1)
                self.assertIn("Cannot read PR body", stderr.getvalue())
                self.assertNotIn("Cannot reach GitHub", stderr.getvalue())
                changes.assert_not_called()
                gh.assert_not_called()
                github.assert_not_called()

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
        self.assertIn("local changes", open_pr.open_refusal("a" * 40, "a" * 40, dirty=True))
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
