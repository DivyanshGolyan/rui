"""The deep-modules allowance ratchet: size growth fails, renames and shrinkage pass."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import deep_modules_allowance as allowance

TANGLE_BASE = "tangle a,b,c\ntangle d,e\n"


def run_git(root, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


class GrowthTest(unittest.TestCase):
    def test_bootstrap_without_a_trusted_file_has_nothing_to_compare(self):
        self.assertEqual(allowance.growth(None, "tangle a,b,c,d,e,f\n"), [])

    def test_unchanged_file_passes(self):
        self.assertEqual(allowance.growth(TANGLE_BASE, TANGLE_BASE), [])

    def test_renamed_members_and_files_pass(self):
        # Same entries and member counts under new names: a behavior-neutral refactor.
        renamed = "tangle a,b,x\ntangle d,y\n"
        self.assertEqual(allowance.growth(TANGLE_BASE, renamed), [])
        moved = "module-cycle src/x.zig,src/y.zig\n"
        self.assertEqual(allowance.growth("module-cycle src/a.zig,src/b.zig\n", moved), [])

    def test_fewer_entries_and_members_pass(self):
        self.assertEqual(allowance.growth(TANGLE_BASE, "tangle a,b\n"), [])
        self.assertEqual(allowance.growth(TANGLE_BASE, ""), [])

    def test_extra_entry_fails_and_names_the_lint_and_counts(self):
        failures = allowance.growth("tangle a,b\n", "tangle a,b\ntangle c,d\n")
        self.assertEqual(len(failures), 1)
        self.assertIn("tangle", failures[0])
        self.assertIn("entries 1 -> 2", failures[0])
        self.assertIn("members 2 -> 4", failures[0])

    def test_circle_that_gains_a_member_fails_even_with_the_same_entries(self):
        failures = allowance.growth("tangle a,b\n", "tangle a,b,c\n")
        self.assertEqual(len(failures), 1)
        self.assertIn("tangle", failures[0])
        self.assertIn("members 2 -> 3", failures[0])
        self.assertNotIn("entries", failures[0])

    def test_module_cycle_members_are_counted_too(self):
        failures = allowance.growth("module-cycle a,b\n", "module-cycle a,b,c\n")
        self.assertEqual(len(failures), 1)
        self.assertIn("module-cycle", failures[0])
        self.assertIn("members 2 -> 3", failures[0])

    def test_non_circle_lints_count_entries_only(self):
        base = "field-leak T.x\n"
        self.assertEqual(allowance.growth(base, "field-leak T.y\n"), [])
        failures = allowance.growth(base, "field-leak T.x\nfield-leak U.z\n")
        self.assertEqual(len(failures), 1)
        self.assertIn("field-leak", failures[0])
        self.assertIn("entries 1 -> 2", failures[0])

    def test_each_grown_lint_gets_its_own_message(self):
        failures = allowance.growth("tangle a,b\n", "tangle a,b\nfield-leak T.x\ntangle c,d\n")
        self.assertEqual(len(failures), 2)
        self.assertTrue(any(failure.startswith("field-leak") for failure in failures))
        self.assertTrue(any(failure.startswith("tangle") for failure in failures))

    def test_comments_blank_lines_and_duplicates_do_not_count(self):
        self.assertEqual(allowance.entries("# header\n\ntangle a,b\n  tangle a,b  \n"), {("tangle", "a,b")})
        self.assertEqual(allowance.growth("tangle a,b\n", "# c\n\ntangle a,b\ntangle a,b\n"), [])

    def test_invalid_entry_names_its_line(self):
        with self.assertRaisesRegex(ValueError, r"deep_modules\.allow:2: expected"):
            allowance.entries("tangle a,b\ntangle\n")


class CheckTest(unittest.TestCase):
    """The merge-base wiring, against a temporary repository whose origin/main is its first commit."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        run_git(self.root, "init", "-q")
        (self.root / "tests/ci").mkdir(parents=True)

    def commit(self, text=None):
        path = self.root / allowance.ALLOWANCE
        if text is None:
            path.unlink(missing_ok=True)
            run_git(self.root, "add", "-A")
        else:
            path.write_text(text)
            run_git(self.root, "add", allowance.ALLOWANCE)
        run_git(self.root, "commit", "-q", "--allow-empty", "-m", "change")

    def base(self):
        run_git(self.root, "update-ref", "refs/remotes/origin/main", "HEAD")
        return run_git(self.root, "rev-parse", "HEAD")

    def test_check_compares_with_the_merge_base_with_origin_main(self):
        self.commit(TANGLE_BASE)
        self.base()
        self.commit("tangle a,b,x\ntangle d,e\n")
        base, trusted, failures = allowance.check(self.root, base=None)
        self.assertEqual(trusted, TANGLE_BASE.strip())
        self.assertEqual(failures, [])
        self.commit("tangle a,b,x\ntangle d,e\ntangle p,q\n")
        self.assertEqual(len(allowance.check(self.root)[2]), 1)

    def test_check_bootstraps_when_the_file_is_absent_at_the_merge_base(self):
        self.commit(None)
        self.base()
        self.commit("tangle a,b,c,d,e,f\n")
        base, trusted, failures = allowance.check(self.root)
        self.assertIsNone(trusted)
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
