"""A move of main comments once per head on each open PR it left conflicting."""
import subprocess
import unittest
from unittest.mock import patch

import conflict_alert

from conflict_alert import MARKER, alert

MAIN = "a" * 40


class FakeGitHub:
    """PRs as number -> (head, mergeable, test-merge base); stale reads give an old clean answer."""

    def __init__(self, prs, comments=None, stale=0, failing=(), failing_after=0):
        self.prs, self.comments, self.failing = prs, comments or {}, set(failing)
        self.failing_after = failing_after  # Reads of a failing PR that succeed first.
        self.stale = dict.fromkeys(prs, stale)
        self.posted, self.listed, self.reads = [], [], dict.fromkeys(prs, 0)

    def __call__(self, method, path, fields=()):
        route, _, query = path.partition("?")
        parts = route.split("/")
        if method == "POST":
            number = int(parts[-2])
            self.posted.append((number, dict(fields)["body"]))
            self.comments.setdefault(number, []).append(dict(fields))
            return {}
        page = int(query.rsplit("page=", 1)[1]) if "page=" in query else 1
        if parts[-1] == "pulls":
            self.listed.append(query)
            return [{"number": number} for number in self.prs][(page - 1) * 100:page * 100]
        if parts[-1] == "comments":
            return self.comments.get(int(parts[-2]), [])[(page - 1) * 100:page * 100]
        if parts[-2] == "commits":
            return {"parents": [{"sha": parts[-1].split("-")[0]}]}
        number = int(parts[-1])
        self.reads[number] += 1
        if number in self.failing and self.reads[number] > self.failing_after:
            raise subprocess.CalledProcessError(1, "gh", stderr="HTTP 502")
        head, mergeable, base = self.prs[number]
        if self.stale[number]:
            self.stale[number] -= 1
            mergeable, base = True, "old"
        return {"number": number, "state": "open", "head": {"sha": head}, "mergeable": mergeable,
                "merge_commit_sha": f"{base}-merge"}


def run(github):
    return alert(github, "o/r", MAIN, sleep=lambda _: None)


class ConflictAlertTest(unittest.TestCase):
    def test_comments_only_on_conflicting_prs(self):
        github = FakeGitHub({1: ("h1", True, MAIN), 2: ("h2", False, MAIN)})
        self.assertEqual(run(github), ([2], [], []))
        self.assertEqual([number for number, _ in github.posted], [2])
        self.assertIn(MARKER.format(head="h2"), github.posted[0][1])
        self.assertIn(MAIN[:12], github.posted[0][1])
        self.assertTrue(all("base=main" in query for query in github.listed))

    def test_one_comment_per_head_however_many_moves(self):
        github = FakeGitHub({2: ("h2", False, MAIN)})
        run(github)
        run(github)
        self.assertEqual(len(github.posted), 1)
        github.prs[2] = ("h2b", False, MAIN)
        run(github)
        self.assertEqual(len(github.posted), 2, "a new push that still conflicts gets a new comment")

    def test_finds_its_marker_past_the_first_page(self):
        earlier = [{"body": "review"}] * 150 + [{"body": MARKER.format(head="h2")}]
        github = FakeGitHub({2: ("h2", False, MAIN)}, comments={2: earlier})
        self.assertEqual(run(github), ([], [], []))

    def test_reads_every_page_of_open_prs(self):
        github = FakeGitHub({number: (f"h{number}", number != 150, MAIN) for number in range(1, 151)})
        self.assertEqual(run(github), ([150], [], []))

    def test_a_clean_answer_from_before_main_moved_is_not_trusted(self):
        github = FakeGitHub({2: ("h2", False, MAIN)}, stale=3)
        self.assertEqual(run(github), ([2], [], []))
        never = FakeGitHub({2: ("h2", False, MAIN)}, stale=100)
        self.assertEqual(run(never), ([], [2], []), "a PR never judged against main is reported as late, not dropped")

    def test_one_failing_pr_does_not_stop_the_rest(self):
        github = FakeGitHub({1: ("h1", False, MAIN), 2: ("h2", False, MAIN)}, failing=[1])
        self.assertEqual(run(github), ([2], [], [1]))

    def test_a_read_that_fails_in_a_later_round_does_not_stop_the_rest(self):
        github = FakeGitHub({1: ("h1", False, MAIN), 2: ("h2", False, MAIN)}, stale=2, failing=[1], failing_after=1)
        self.assertEqual(run(github), ([2], [], [1]))
        self.assertEqual(github.reads[1], 2, "a failed PR is not read again")

    def test_unjudged_prs_share_one_deadline(self):
        # GitHub leaves a clean PR's test merge on an older main: such PRs
        # wait together, not ten sleeps each in turn.
        prs = {number: (f"h{number}", True, "old") for number in range(1, 6)}
        github = FakeGitHub({**prs, 6: ("h6", False, MAIN)}, stale=0)
        github.stale[6] = 4
        sleeps = []
        self.assertEqual(alert(github, "o/r", MAIN, sleep=sleeps.append), ([6], [1, 2, 3, 4, 5], []))
        self.assertEqual(sleeps, [6] * 9)
        self.assertEqual(github.reads[6], 5, "a judged PR is not read again")

    def test_no_wait_once_every_pr_is_judged(self):
        github = FakeGitHub({1: ("h1", True, MAIN), 2: ("h2", False, MAIN)})
        sleeps = []
        alert(github, "o/r", MAIN, sleep=sleeps.append)
        self.assertEqual(sleeps, [])


class GitHubCommandTest(unittest.TestCase):
    def test_command_captures_output_and_propagates_failures(self):
        with patch.object(conflict_alert.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, "response\n", "")) as run:
            self.assertEqual(conflict_alert.gh("api", "repos/o/r"), "response\n")
        run.assert_called_once_with(["gh", "api", "repos/o/r"], check=True,
                                    capture_output=True, text=True)
        with patch.object(conflict_alert.subprocess, "run", side_effect=
                          subprocess.CalledProcessError(1, "gh", stderr="HTTP 502")):
            with self.assertRaises(subprocess.CalledProcessError):
                conflict_alert.gh("api", "repos/o/r")


if __name__ == "__main__":
    unittest.main()
