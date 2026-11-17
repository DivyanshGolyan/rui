import io
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import pr_shape
import select_tests


ROOT = Path(__file__).resolve().parents[2]
GOAL = "Goal: #123 Explain the intended change\n"


def refusal(paths, body, **kwargs):
    return pr_shape.refusal(paths, GOAL + body, **kwargs)


class GoalTest(unittest.TestCase):
    def test_goal_is_required_for_all_paths(self):
        cases = (
            ("Goal: #12 Support the workstream goal", True),
            ("Goal: https://github.com/owner/repo/issues/123 Support the workstream goal", True),
            ("Goal: Support the workstream goal", False),
            ("Goal: #12", False),
            ("Goal: #12 one two", False),
            ("No issue: Routine housekeeping", True),
            ("No issue:   ", False),
            ("```text\nGoal: #12 Support the workstream goal\n```", False),
            ("<!-- Goal: #12 Support the workstream goal -->", False),
            ("~~~\nNo issue: housekeeping\n~~~", False),
            ("<!--\nGoal: #12 Support the workstream goal", False),
            ("<!--\nNo issue: Routine housekeeping", False),
        )
        for paths in (["docs/guide.md"], ["src/cli.zig"]):
            for body, accepted in cases:
                with self.subTest(paths=paths, body=body):
                    reason = pr_shape.refusal(paths, body + "\n## Shape")
                    self.assertEqual(reason is None, accepted, reason)
                    if not accepted:
                        self.assertIn("Body edits do not re-trigger", reason)
                        self.assertIn("re-run the failed jobs", reason)


class VisibleTextTest(unittest.TestCase):
    def test_comment_and_fence_states_for_both_consumers(self):
        cases = (
            ("<!--\n{evidence}\n-->", False),
            ("<!--\n{evidence}", False),
            ("```text\n<!--\n```\n{evidence}", True),
            ("```text <!--\n```\n{evidence}", True),
            ("```text\n<!--\n{evidence}", False),
            ("<!--\n```\n-->\n{evidence}", True),
            ("<!-- hidden -->{evidence}<!-- hidden -->", True),
            ("<!-- first --><!-- second -->{evidence}", True),
            ("<!-- first -->{evidence}<!-- second -->", True),
            ("<!-- hidden -->```text <!--\n```\n{evidence}", True),
        )
        consumers = (
            (pr_shape.goal_present, "Goal: #12 Support the workstream goal"),
            (pr_shape.screen_exemption, "No screen change: visible reason"),
        )
        for template, expected in cases:
            for consumer, evidence in consumers:
                with self.subTest(template=template, evidence=evidence):
                    self.assertEqual(consumer(template.format(evidence=evidence)), expected)

    def test_text_around_multiple_comments_remains_visible(self):
        self.assertEqual(pr_shape.visible_lines("before<!-- one -->middle<!-- two -->after"),
                         ["beforemiddleafter"])
        self.assertEqual(pr_shape.visible_lines("before<!-- open\nclose -->after"),
                         ["before", "after"])


class PrShapeTest(unittest.TestCase):
    def assertRefused(self, paths, body):
        reason = refusal(paths, body)
        self.assertIsInstance(reason, str)
        self.assertIn("## Shape", reason)
        self.assertEqual(len(reason.splitlines()), 1)

    def test_refusal_explains_edit_and_rerun(self):
        reason = refusal(["src/cli.zig"], "")
        self.assertIn("Add a ## Shape section to the PR body", reason)
        self.assertIn("re-run the failed jobs of this run", reason)
        self.assertIn("no push needed", reason)

    def test_src_changes_need_shape(self):
        for paths in (["src/cli.zig"], ["src/store/Store.zig"],
                      ["README.md", "src/cli.zig", "tests/ci/test_pr_shape.py"]):
            for body in ("", "Describe the change.", "Shape", "The ## Shape section follows."):
                with self.subTest(paths=paths, body=body):
                    self.assertRefused(paths, body)

    def test_exact_heading_is_enough_anywhere_in_the_body(self):
        for heading in ("## Shape", "##  Shape", "##\tShape", "## Shape  ", "## Shape\t"):
            for body in (heading, heading + "\n", "Summary\n" + heading + "\nDetails",
                         "Summary\r\n" + heading + "\r\nDetails"):
                with self.subTest(body=body):
                    self.assertIsNone(refusal(["src/cli.zig"], body))

    def test_summary_sketch_replaces_a_separate_shape_heading(self):
        sketches = (
            "```text\nSign in\n├─ Browser → Explicit copy\n└─ API key → Connect\n```",
            "```\nsubmitForm\n  persistPrompt\n  launchAgent\n```",
            "~~~mermaid\nflowchart LR\n  Input --> Owner\n~~~",
            "````diff\n-old owner\n+shared owner\n````",
        )
        for sketch in sketches:
            for newline in ("\n", "\r\n"):
                body = ("## Summary\n\n" + sketch + "\n\n## Evidence\nBefore and after.\n\n"
                        "## Merge Danger\nTwo-way. Authentication.").replace("\n", newline)
                with self.subTest(sketch=sketch, newline=newline):
                    self.assertIsNone(refusal(["src/cli.zig"], body))

    def test_summary_needs_a_nonempty_closed_sketch_in_its_own_section(self):
        bodies = (
            "## Summary", "## Summary\nFixed the code.",
            "## Summary\n```text\n```", "## Summary\n```text\n  \n```",
            "## Summary\n```text\nInput -> Owner", "## Summary\n~~~text\nInput -> Owner\n```",
            "## Summary\nGeneric prose.\n## Evidence\n```text\nInput -> Owner\n```",
            "# Summary\n```text\nInput -> Owner\n```",
            "Summary\n```text\nInput -> Owner\n```",
            "```text\n## Summary\n```\n```text\nInput -> Owner\n```",
        )
        for body in bodies:
            with self.subTest(body=body):
                self.assertRefused(["src/cli.zig"], body)

    def test_indented_section_headings_end_summary_before_other_sketches(self):
        for indent in (" ", "  ", "   "):
            for level in ("#", "##"):
                body = ("## Summary\nGeneric prose only.\n" + indent + level
                        + " Evidence\n```text\nnot in Summary\n```\n## Merge Danger\nNone.")
                with self.subTest(indent=indent, level=level):
                    self.assertRefused(["src/cli.zig"], body)

    def test_other_levels_case_and_trailing_text_do_not_count(self):
        for heading in ("# Shape", "### Shape", "#### Shape", "## shape", "## SHAPE",
                        "## ShApE", "##Shape", " ## Shape", "## Shape details", "## Shape:",
                        "## Shape ##", "## Shapes"):
            with self.subTest(heading=heading):
                self.assertRefused(["src/cli.zig"], "Summary\n" + heading + "\nDetails")

    def test_non_src_changes_never_need_shape(self):
        for paths in ([], ["docs/agents/landing.md"], ["tests/ci/pr_shape.py"], ["build.zig"],
                      ["docs/agents/landing.md", "tests/ci/test_pr_shape.py", "build.zig"],
                      ["src"], ["src-other/cli.zig"], ["clients/ts/src/wire.ts"]):
            for body in ("", "Summary", "## shape", "## Shape"):
                with self.subTest(paths=paths, body=body):
                    self.assertIsNone(refusal(paths, body))


class ScreenEvidenceTest(unittest.TestCase):
    def test_ui_shape_does_not_require_screens(self):
        self.assertIsNone(refusal(["src/overview_view.zig"], "## Shape"))


    def test_screen_decisions_for_head_and_exemption(self):
        head = "a" * 40
        def run(status, conclusion, *, sha=head, number=42, id=1):
            return {"id": id, "event": "pull_request", "head_sha": sha, "status": status,
                    "conclusion": conclusion, "pull_requests": [{"number": number, "head": {"sha": sha}}]}
        cases = (
            ([], "wait", "Timed out"),
            ([run("queued", None)], "wait", "still running"),
            ([run("in_progress", None)], "wait", "still running"),
            ([run("completed", "success")], None, None),
            ([run("completed", "failure")], "failure", "failure"),
            ([run("completed", "cancelled")], "cancelled", "cancelled"),
            ([run("completed", "success", sha="b" * 40)], "wait", "no matching"),
            ([run("completed", "success", number=43)], "wait", "no matching"),
            ([run("completed", "success"), run("in_progress", None, id=2)], "wait", "still running"),
            ([run("completed", "failure"), run("completed", "success", id=2)], None, None),
        )
        for runs, immediate, timeout in cases:
            with self.subTest(runs=runs):
                result = pr_shape.screen_refusal("", runs, head, 42)
                if immediate is None:
                    self.assertIsNone(result)
                else:
                    self.assertIn(immediate, result)
                result = pr_shape.screen_refusal("", runs, head, 42, timed_out=True)
                if timeout is None:
                    self.assertIsNone(result)
                else:
                    self.assertIn(timeout, result)
                self.assertIsNone(pr_shape.screen_refusal("No screen change: unchanged", runs, head, 42, timed_out=True))

    def test_exemption_requires_visible_nonempty_reason(self):
        for text in ("", "No screen change:", "No screen change:   ",
                     "No screen change:\nreason", "```\nNo screen change: hidden\n```",
                     "<!-- No screen change: hidden -->", "![screen](https://example.test/screen.png)"):
            with self.subTest(text=text):
                self.assertFalse(pr_shape.screen_exemption(text))
        self.assertTrue(pr_shape.screen_exemption("No screen change: reason\r\n"))

    def test_non_ui_does_not_need_screens(self):
        for path in ("src/server.zig", "src/store/Store.zig", "src/cli.zig", "docs/agents/landing.md"):
            with self.subTest(path=path):
                self.assertFalse(pr_shape.screens_required([path]))

    def test_poll_reads_one_snapshot_per_attempt_and_stops_at_bound(self):
        head = "a" * 40
        running = {"id": 1, "event": "pull_request", "head_sha": head, "status": "in_progress",
                   "conclusion": None, "pull_requests": [{"number": 42, "head": {"sha": head}}]}
        success = {**running, "status": "completed", "conclusion": "success"}
        now = [0]
        def sleep(seconds):
            now[0] += seconds
        with patch.object(pr_shape, "github", side_effect=[{"workflow_runs": []}, {"workflow_runs": [running]},
                                                           {"workflow_runs": [success]}]) as api:
            self.assertIsNone(pr_shape.wait_for_screens("", "o/r", "42", head, timeout=20, interval=10,
                                                      clock=lambda: now[0], sleep=sleep))
            self.assertEqual(api.call_count, 3)
            self.assertEqual(api.call_args.args, ("GET", f"repos/o/r/actions/workflows/screens.yml/runs?event=pull_request&head_sha={head}&per_page=100"))
        now[0] = 0
        with patch.object(pr_shape, "github", return_value={"workflow_runs": [running]}) as api:
            reason = pr_shape.wait_for_screens("", "o/r", "42", head, timeout=20, interval=10,
                                               clock=lambda: now[0], sleep=sleep)
            self.assertIn("Timed out", reason)
            self.assertEqual(api.call_count, 3)
        with patch.object(pr_shape, "github", side_effect=OSError("offline")):
            self.assertIn("Cannot read Screens", pr_shape.wait_for_screens("", "o/r", "42", head))
        with patch.object(pr_shape, "github") as api:
            self.assertIsNone(pr_shape.wait_for_screens("No screen change: reason", "o/r", "42", head))
            api.assert_not_called()

    def test_graph_classifies_transitive_ui_but_excludes_host_and_test_imports(self):
        graph = select_tests.tree_graph()
        self.assertIn("src/Overview.zig", graph.production["src/cli.zig"])
        paths = pr_shape.ui_paths(graph)
        for path in ("src/TerminalApp.zig", "src/Root.zig", "src/SessionScreen.zig", "src/Composer.zig",
                     "src/widgets/List.zig", "src/theme.zig", "src/overview_view.zig"):
            self.assertIn(path, paths)
        self.assertFalse(paths & graph.host)
        self.assertFalse(paths & graph.tests)
        # New imports join the rule automatically; no path list to update.
        graph = type("Graph", (), dict(production={"src/Overview.zig": {"src/new_screen.zig", "src/shared.zig"}},
                     host={"src/shared.zig"}, tests=set(), closure=staticmethod(select_tests.Graph.closure)))()
        self.assertEqual(pr_shape.ui_paths(graph), {"src/Overview.zig", "src/new_screen.zig"})

    def test_deleted_ui_paths_use_base_graph(self):
        with patch.object(pr_shape, "revision_ui_paths", return_value={"src/removed_screen.zig"}) as base:
            self.assertTrue(pr_shape.screens_required(["src/removed_screen.zig"], base="old"))
            base.assert_called_once_with("old")


    def test_base_archive_preserves_deleted_ui_edges_and_binary_embeds(self):
        archive = io.BytesIO()
        sources = {"src/Overview.zig": b'const view = @import("removed_screen.zig");\n',
                   "src/removed_screen.zig": b'const image = @embedFile("image.bin");\n',
                   "src/image.bin": b"\xff\x80",
                   "src/logic_tests.zig": b"const cores = .{\n};\n",
                   "tests/ci/stack_frames.json": b'{"host_modules": []}'}
        with tarfile.open(fileobj=archive, mode="w") as tree:
            for name, data in sources.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                tree.addfile(entry, io.BytesIO(data))
        with patch("subprocess.check_output", return_value=archive.getvalue()):
            paths = pr_shape.revision_ui_paths.__wrapped__("deleted-ui-base")
        self.assertIn("src/removed_screen.zig", paths)
        self.assertIn("src/image.bin", paths)


class PrShapeMainTest(unittest.TestCase):
    def setUp(self):
        base = patch.object(pr_shape, "revision_ui_paths", return_value=set())
        base.start()
        self.addCleanup(base.stop)

    def test_current_body_wins_and_failed_reads_fall_back(self):
        cases = (
            ("placeholder", {"body": "## Shape"}, None, 0, "current PR body from GitHub"),
            ("## Shape", {"body": "placeholder"}, None, 1, "current PR body from GitHub"),
            ("## Shape", None, OSError("offline"), 0, "event payload body"),
            ("placeholder", None, OSError("offline"), 1, "event payload body"),
            ("## Shape", {"body": None}, None, 1, "current PR body from GitHub"),
        )
        for payload, live, failure, expected, source in cases:
            with self.subTest(payload=payload, live=live, failure=failure), \
                 patch.dict(os.environ, {"BASE": "base", "PR_BODY": GOAL + payload,
                                         "GITHUB_REPOSITORY": "owner/repo", "PR_NUMBER": "42"}, clear=True), \
                 patch.object(sys, "argv", ["pr_shape.py"]), \
                 patch.object(select_tests, "changed_paths", return_value=(["src/cli.zig"], "base")), \
                 patch.object(pr_shape, "github", return_value=({"body": GOAL + live["body"]} if live and live["body"] is not None else live), side_effect=failure) as api, \
                 redirect_stdout(io.StringIO()) as stdout, redirect_stderr(io.StringIO()):
                self.assertEqual(pr_shape.main(), expected)
                api.assert_called_once_with("GET", "repos/owner/repo/pulls/42")
                self.assertIn(source, stdout.getvalue())

    def test_argument_overrides_base_environment_and_body_stays_data(self):
        for body, expected in (("", 1), ("Summary\n## Shape\n$(exit 99)", 0)):
            with self.subTest(body=body), \
                 patch.dict(os.environ, {"BASE": "environment-base", "PR_BODY": GOAL + body}, clear=True), \
                 patch.object(sys, "argv", ["pr_shape.py", "argument-base"]), \
                 patch.object(select_tests, "changed_paths", return_value=(["src/cli.zig"], "base")) as changed, \
                 redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(pr_shape.main(), expected)
                changed.assert_called_once_with("argument-base", "HEAD")
                if expected:
                    self.assertIn("## Shape", stderr.getvalue())
                    self.assertEqual(len(stderr.getvalue().splitlines()), 1)
                else:
                    self.assertEqual(stderr.getvalue(), "")

    def test_base_environment_and_missing_body(self):
        with patch.dict(os.environ, {"BASE": "environment-base"}, clear=True), \
             patch.object(sys, "argv", ["pr_shape.py"]), \
             patch.object(select_tests, "changed_paths", return_value=(["README.md"], "base")) as changed, \
             redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(pr_shape.main(), 1)
            changed.assert_called_once_with("environment-base", "HEAD")
            self.assertIn("Goal:", stderr.getvalue())

    def test_screens_mode_reads_live_body_and_head_without_diff(self):
        head = "a" * 40
        for body, result, expected in (("No screen change: unchanged", None, 0), ("", "Screens failed", 1)):
            with self.subTest(body=body), patch.dict(os.environ, {"PR_BODY": "stale", "PR_NUMBER": "42", "PR_HEAD_SHA": head, "GITHUB_REPOSITORY": "o/r"}, clear=True), \
                 patch.object(sys, "argv", ["pr_shape.py", "--screens"]), \
                 patch.object(pr_shape, "github", return_value={"body": body}), \
                 patch.object(pr_shape, "wait_for_screens", return_value=result) as wait, \
                 patch.object(select_tests, "changed_paths") as changed, \
                 redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(pr_shape.main(), expected)
                wait.assert_called_once_with(body, "o/r", "42", head)
                changed.assert_not_called()

    def test_screens_cli_uses_live_body_and_workflow_api(self):
        head = "a" * 40
        run = {"id": 10, "event": "pull_request", "head_sha": head, "status": "completed",
               "conclusion": "success", "pull_requests": [{"number": 42, "head": {"sha": head}}]}
        for conclusion, expected in (("success", 0), ("failure", 1), ("cancelled", 1)):
            with self.subTest(conclusion=conclusion), \
                 patch.dict(os.environ, {"PR_BODY": "stale", "PR_NUMBER": "42", "PR_HEAD_SHA": head,
                                         "GITHUB_REPOSITORY": "o/r"}, clear=True), \
                 patch.object(sys, "argv", ["pr_shape.py", "--screens"]), \
                 patch.object(pr_shape, "github", side_effect=[{"body": ""}, {"workflow_runs": [{**run, "conclusion": conclusion}]}]) as api, \
                 redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(pr_shape.main(), expected)
                self.assertEqual(api.call_count, 2)
                if expected:
                    self.assertIn(conclusion, stderr.getvalue())

    def test_screens_mode_runs_with_only_ci_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "tests/ci", root / "tests/ci", ignore=shutil.ignore_patterns("__pycache__"))
            env = {**os.environ, "PR_BODY": "No screen change: unchanged", "PR_NUMBER": "", "GITHUB_REPOSITORY": ""}
            result = subprocess.run([sys.executable, "tests/ci/pr_shape.py", "--screens"], cwd=root,
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_plan_emits_screen_classification(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            for paths, expected in ((["src/overview_view.zig"], "true"), (["docs/a.md"], "false")):
                with self.subTest(paths=paths), patch.dict(os.environ, {"PR_BODY": GOAL + "## Shape", "GITHUB_OUTPUT": str(output)}, clear=True), \
                     patch.object(sys, "argv", ["pr_shape.py", "base"]), \
                     patch.object(select_tests, "changed_paths", return_value=(paths, "base")):
                    self.assertEqual(pr_shape.main(), 0)
                    self.assertEqual(output.read_text().splitlines()[-1], f"screens_required={expected}")

    def test_deleted_src_file_still_requires_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=directory, text=True).strip()

            def commit():
                git("add", "-A")
                git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")

            git("init", "-q")
            source = Path(directory) / "src/deleted.zig"
            source.parent.mkdir()
            source.write_text("// Deleted source.\n")
            (Path(directory) / "src/logic_tests.zig").write_text("const cores = .{\n};\n")
            integration = Path(directory) / "tests/integration"
            integration.mkdir(parents=True)
            (integration / "placeholder.txt").write_text("fixture\n")
            gate = Path(directory) / "tests/ci/stack_frames.json"
            gate.parent.mkdir()
            gate.write_text('{"host_modules": []}')
            base = commit()
            source.unlink()
            commit()
            for body, expected in (("", 1), ("## Shape", 0)):
                with self.subTest(body=body):
                    result = subprocess.run([sys.executable, "-B", str(ROOT / "tests/ci/pr_shape.py")],
                                            cwd=directory, env={**os.environ, "BASE": base, "PR_BODY": GOAL + body},
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stdout, "")
                    if expected:
                        self.assertIn("## Shape", result.stderr)
                    else:
                        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
