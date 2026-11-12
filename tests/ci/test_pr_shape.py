import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

import pr_shape


ROOT = Path(__file__).resolve().parents[2]


class PrShapeTest(unittest.TestCase):
    def assertRefused(self, paths, body):
        reason = pr_shape.refusal(paths, body)
        self.assertIsInstance(reason, str)
        self.assertIn("## Shape", reason)
        self.assertEqual(len(reason.splitlines()), 1)

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
                    self.assertIsNone(pr_shape.refusal(["src/cli.zig"], body))

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
                    self.assertIsNone(pr_shape.refusal(paths, body))


class PrShapeMainTest(unittest.TestCase):
    def test_argument_overrides_base_environment_and_body_stays_data(self):
        for body, expected in (("", 1), ("Summary\n## Shape\n$(exit 99)", 0)):
            with self.subTest(body=body), \
                 patch.dict(os.environ, {"BASE": "environment-base", "PR_BODY": body}, clear=True), \
                 patch.object(sys, "argv", ["pr_shape.py", "argument-base"]), \
                 patch.object(pr_shape, "changed_paths", return_value=(["src/cli.zig"], "base")) as changed, \
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
             patch.object(pr_shape, "changed_paths", return_value=(["README.md"], "base")) as changed, \
             redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(pr_shape.main(), 0)
            changed.assert_called_once_with("environment-base", "HEAD")
            self.assertEqual(stderr.getvalue(), "")

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
            base = commit()
            source.unlink()
            commit()
            for body, expected in (("", 1), ("## Shape", 0)):
                with self.subTest(body=body):
                    result = subprocess.run([sys.executable, "-B", str(ROOT / "tests/ci/pr_shape.py")],
                                            cwd=directory, env={**os.environ, "BASE": base, "PR_BODY": body},
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stdout, "")
                    if expected:
                        self.assertIn("## Shape", result.stderr)
                    else:
                        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
