import argparse
import io
import subprocess
import tempfile
from pathlib import Path
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import call, patch

import open_pr
import pr_shape
from pr_timeline import review_outcomes
from test_pr_shape import GOAL


class OpenPrTest(unittest.TestCase):
    def test_opens_ready_over_rest_when_requested(self):
        args = open_pr.create_args("o/r", "Title", "Description", "main", "fix-x", draft=False)
        self.assertEqual(args[:4], ["api", "-X", "POST", "repos/o/r/pulls"])
        self.assertIn("draft=false", args)
        self.assertIn("head=fix-x", args)
        self.assertIn("body=Description", args)

    def test_opens_draft_over_rest(self):
        args = open_pr.create_args("o/r", "Title", "Description", "main", "fix-x", draft=True)
        self.assertEqual(args[:4], ["api", "-X", "POST", "repos/o/r/pulls"])
        self.assertEqual(args[args.index("-F") + 1], "draft=true")
        self.assertNotIn("draft=false", args)
        self.assertIn("head=fix-x", args)
        self.assertIn("body=Description", args)

    def test_open_drafts_by_default_and_requests_codex_review_only_on_drafts(self):
        url = "https://github.com/example/rui/pull/9"
        for draft in (False, True):
            for comment_error in ((None, subprocess.CalledProcessError(1, ["gh", "api"], stderr="denied"))
                                  if draft else (None,)):
                with self.subTest(draft=draft, comment_error=comment_error):
                    stdout, stderr = io.StringIO(), io.StringIO()
                    created = '{"number": 9, "html_url": "%s"}' % url
                    argv = ["open_pr.py", "open", "--title", "Title", "--body-file", "body.md"]
                    if not draft:
                        argv.append("--ready")
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
                    self.assertEqual(github.call_args_list, ([
                        call("POST", "repos/example/rui/issues/9/comments", [("body", "@codex review")])]
                        if draft else []))
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
                            self.assertIn("comment `@codex review` after each push", stdout.getvalue())
                            self.assertIn("open_pr.py ready", stdout.getvalue())
                            self.assertNotIn("Opened ready", stdout.getvalue())
                            self.assertNotIn("Selected CI runs beside review", stdout.getvalue())
                        else:
                            self.assertIn("Opened ready; Codex reviews automatically", stdout.getvalue())
                            self.assertIn("Selected CI runs beside review", stdout.getvalue())
                            self.assertNotIn("Opened draft", stdout.getvalue())

    def test_open_validates_body_before_github_with_the_selected_base(self):
        cases = (
            ({"src/cli.zig"}, "Description", False),
            ({"src/cli.zig"}, "## Summary\n```text\ninput -> owner\n```", True),
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
                     patch.object(open_pr, "screens_required", return_value=False), \
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
                        "example/rui", "Title", body, "parent", "fix-x", draft=True))
                    self.assertEqual(body_file.read_text(encoding="utf-8"), "Replaced after validation")
                    github.assert_called_once_with("POST", "repos/example/rui/issues/9/comments",
                                                   [("body", "@codex review")])
                else:
                    self.assertIn("nonempty fenced sketch", stderr.getvalue())
                    overlaps.assert_not_called()
                    gh.assert_not_called()
                    github.assert_not_called()

    def test_a_ui_pr_opens_only_with_captured_frames_and_prints_the_publish_command(self):
        with tempfile.TemporaryDirectory() as directory:
            body, frames = Path(directory, "body.md"), Path(directory, "frames")
            body.write_text(GOAL + "## Summary\n```text\ninput -> owner\n```", encoding="utf-8")
            frames.mkdir()
            for captured in (False, True):
                if captured:
                    (frames / "index.html").write_text("<html></html>", encoding="utf-8")
                stdout, stderr = io.StringIO(), io.StringIO()
                with patch("sys.argv", ["open_pr.py", "open", "--title", "Title", "--body-file", str(body),
                                        "--frames", str(frames)]), \
                     patch.object(open_pr, "git", side_effect=["fix-x", "a" * 40, "a" * 40, ""]), \
                     patch.object(open_pr, "origin_repo", return_value="example/rui"), \
                     patch.object(open_pr, "branch_changes", return_value=({"src/overview_view.zig"}, {})), \
                     patch.object(open_pr, "screens_required", return_value=True), \
                     patch.object(open_pr, "overlaps", return_value=[]), patch.object(open_pr, "report"), \
                     patch.object(open_pr, "gh", return_value='{"number": 9, "html_url": "url"}') as gh, \
                     patch.object(open_pr, "github"), redirect_stdout(stdout), redirect_stderr(stderr):
                    self.assertEqual(open_pr.main(), 0 if captured else 1)
                self.assertEqual(gh.call_count, 1 if captured else 0)
                if captured:
                    self.assertIn(f"verify-rui publish {frames} --pr 9", stdout.getvalue())
                    self.assertIn("subscribe_pr_activity for PR #9", stdout.getvalue())
                else:
                    self.assertIn("open_pr.py open --frames", stderr.getvalue())

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
        draft = {"number": 9, "draft": True, "head": {"sha": head}, "body": "No issue: a test body"}
        stdout = io.StringIO()
        with patch("sys.argv", ["open_pr.py", "ready"]), \
             patch.object(open_pr, "branch_changes", return_value=(["docs/a.md"], [])), \
             patch.object(open_pr, "git", side_effect=["fix/x", head, ""]), \
             patch.object(open_pr, "origin_repo", return_value="example/rui"), \
             patch.object(open_pr, "github", return_value=[draft]) as github, \
             patch.object(open_pr, "gh", return_value="") as gh, redirect_stdout(stdout):
            self.assertEqual(open_pr.main(), 0)
        github.assert_called_once_with("GET", "repos/example/rui/pulls?state=open&head=example:fix/x")
        gh.assert_called_once_with("pr", "ready", "9", "--repo", "example/rui")

    def test_review_verdicts_are_read_back_by_the_merge_gate(self):
        head = "c" * 40
        row = lambda body: {"user": {"login": "DivyanshGolyan"}, "author_association": "OWNER",
                            "created_at": "2026-11-25T10:00:00Z", "body": body}
        for findings, fixed, clean in ((None, False, True), ("P2 a.py:3 drops the error", False, False),
                                       ("P2 a.py:3 drops the error", True, True)):
            with self.subTest(findings=findings, fixed=fixed):
                body = open_pr.review_comment(head, findings, fixed)
                outcomes = review_outcomes([row(body)], [], 9)
                self.assertEqual([(o["head"], o["clean"]) for o in outcomes], [(head, clean)])
                self.assertTrue(body.endswith("_Generated by [Claude Code](https://claude.ai/code)_"))

    def test_review_posts_the_verdict_on_the_reported_head(self):
        head, reviewed = "c" * 40, "d" * 40
        posted = []
        args = argparse.Namespace(head=reviewed, findings=None, fixed=False)
        code, message = open_pr.post_review(lambda *call: posted.append(call), "example/rui",
                                            {"number": 9, "head": {"sha": head}}, args, lambda: [])
        self.assertEqual(code, 0)
        method, path, fields = posted[0]
        self.assertEqual((method, path), ("POST", "repos/example/rui/issues/9/comments"))
        self.assertIn(reviewed, fields[0][1])
        self.assertIn('"has_unresolved_findings": false', fields[0][1])
        self.assertIn(reviewed[:10], message)

    def test_review_refuses_a_verdict_without_the_reviewed_head_and_a_fix_with_nothing_to_fix(self):
        head = "c" * 40
        pr = {"number": 9, "head": {"sha": head}}
        clean = [{"source": "interim", "clean": True, "when": "t", "head": head}]
        for fields, last in ((dict(), []), (dict(fixed=True), []), (dict(fixed=True), clean),
                             (dict(head=head, findings="/nonexistent"), [])):
            with self.subTest(fields=fields):
                posted = []
                args = argparse.Namespace(**{"head": None, "findings": None, "fixed": False, **fields})
                code, message = open_pr.post_review(lambda *call: posted.append(call), "example/rui", pr, args, lambda: last)
                self.assertEqual((code, posted), (1, []))
                self.assertTrue(message)

    def test_a_ui_pr_opens_or_turns_ready_only_with_its_screens_on_hand(self):
        # #2277, #2297, #2299, #2305 and #2306 changed UI with no screens; only admission, last, said so.
        body = "No issue: fix main's red tests after the watch tool arrived\n\n## Summary\n\n```\nx\n```\n"
        ui, no_ui = (lambda paths, base=None: True), (lambda paths, base=None: False)
        comment, no_comment = (lambda repo, number: True), (lambda repo, number: False)
        judge = lambda **kw: pr_shape.ready_refusal(["src/chat_info.zig"], body, **kw)
        with tempfile.TemporaryDirectory() as frames:
            self.assertIn("open_pr.py open --frames", judge(needs=ui, sticky=no_comment))
            self.assertIn("open_pr.py open --frames", judge(needs=ui, sticky=no_comment, frames=frames))
            Path(frames, "index.html").write_text("<html></html>")
            for screens in ({"frames": frames}, {"number": 9, "sticky": comment}):
                self.assertIsNone(judge(needs=ui, **{"sticky": no_comment, **screens}))
        self.assertIsNone(judge(needs=no_ui, sticky=no_comment))
        self.assertIsNone(pr_shape.ready_refusal(["src/chat_info.zig"], body + "No screen change: one assertion\n",
                                                 needs=ui, sticky=no_comment))

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
