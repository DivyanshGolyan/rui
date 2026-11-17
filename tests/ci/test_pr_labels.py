import subprocess
import unittest
from unittest.mock import patch

import pr_labels

from pr_labels import goal_issues, label

REPO = "o/r"


class FakeGitHub:

    def __init__(self, issues, files=()):
        self.issues, self.files, self.posted = issues, list(files), []

    def __call__(self, method, path, fields=()):
        route = path.partition("?")[0]
        if method == "POST":
            self.posted.append((route, [value for _, value in fields]))
            return []
        if route.endswith("/files"):
            return [{"filename": name} for name in self.files]
        number = int(route.rsplit("/", 1)[1])
        if number not in self.issues:
            raise subprocess.CalledProcessError(1, ["gh"], stderr="gh: Not Found (HTTP 404)")
        if self.issues[number] is None:
            raise subprocess.CalledProcessError(1, ["gh"], stderr="gh: Server Error (HTTP 502)")
        labels, parent = self.issues[number]
        return {"labels": [{"name": name} for name in labels],
                "parent_issue_url": parent and f"https://api.github.com/repos/{REPO}/issues/{parent}"}


def pr(body, labels=()):
    return {"number": 7, "body": body, "labels": [{"name": name} for name in labels]}


class PrLabelsTest(unittest.TestCase):

    def test_goal_issues_reads_visible_goal_lines_only(self):
        body = "<!-- Goal: #1 -->\n```\nGoal: #2\n```\nGoal: #3 and https://github.com/o/r/issues/4, see #3\nRefs #5"
        self.assertEqual(goal_issues(body, REPO), [3, 4])
        self.assertEqual(goal_issues("Goal: https://github.com/x/y/issues/9 elsewhere", REPO), [])
        self.assertEqual(goal_issues(None, REPO), [])

    def test_nearest_labelled_ancestor_wins(self):
        api = FakeGitHub({10: (["active"], 20), 20: (["host parity"], 30), 30: (["drift"], None)})
        self.assertEqual(label(api, REPO, pr("Goal: #10 finish the thing")), ["Host parity"])
        self.assertEqual(api.posted, [(f"repos/{REPO}/issues/7/labels", ["Host parity"])])

    def test_existing_labels_are_kept_and_not_reposted(self):
        api = FakeGitHub({10: (["TUI", "images"], None)})
        self.assertEqual(label(api, REPO, pr("Goal: #10 x", labels=["tui", "bug"])), ["images"])

    def test_ci_only_paths_fall_back_to_ci(self):
        issues = {10: ([], None)}
        self.assertEqual(label(FakeGitHub(issues, [".github/workflows/a.yml", "tests/ci/b.py"]), REPO,
                               pr("Goal: #10 speed up CI")), ["CI"])
        self.assertEqual(label(FakeGitHub(issues, ["tests/ci/b.py", "src/a.zig"]), REPO,
                               pr("No issue: tidy")), [])
        api = FakeGitHub({10: (["Store"], None)}, ["tests/ci/b.py"])
        self.assertEqual(label(api, REPO, pr("Goal: #10 x")), ["Store"])

    def test_parent_cycle_stops(self):
        api = FakeGitHub({10: ([], 11), 11: ([], 10)})
        self.assertEqual(label(api, REPO, pr("Goal: #10 x")), [])

    def test_missing_goal_issue_falls_back_to_paths(self):
        api = FakeGitHub({}, ["tests/ci/b.py"])
        self.assertEqual(label(api, REPO, pr("Goal: #404 speed up CI")), ["CI"])

    def test_other_api_errors_still_fail(self):
        with self.assertRaises(subprocess.CalledProcessError):
            label(FakeGitHub({10: None}), REPO, pr("Goal: #10 x"))

    def test_all_open_continues_after_a_failed_pr(self):
        api = FakeGitHub({10: None, 11: (["TUI"], None)})
        prs = [dict(pr("Goal: #10 x"), number=1), dict(pr("Goal: #11 x"), number=2)]
        with patch.object(pr_labels, "github", api), patch.object(pr_labels, "pages", return_value=iter(prs)), \
                patch("sys.argv", ["pr_labels.py", "--repo", REPO, "--all-open"]), \
                self.assertRaises(SystemExit) as exit:
            pr_labels.main()
        self.assertIn("#1", str(exit.exception.code))
        self.assertEqual(api.posted, [(f"repos/{REPO}/issues/2/labels", ["TUI"])])


if __name__ == "__main__":
    unittest.main()
