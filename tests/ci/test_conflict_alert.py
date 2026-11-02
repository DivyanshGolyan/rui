"""A move of main comments once per head on each open PR it left conflicting."""
import subprocess
import unittest

from conflict_alert import MARKER, alert

MAIN = "a" * 40


class FakeGitHub:
    """PRs as number -> (head, mergeable, test-merge base); stale reads give an old clean answer."""

    def __init__(self, prs, comments=None, stale=0, failing=()):
        self.prs, self.comments, self.failing = prs, comments or {}, set(failing)
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
        if number in self.failing and self.reads[number] > 1:  # The warm-up read succeeds.
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
        self.assertEqual(run(github), ([2], []))
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
        self.assertEqual(run(github), ([], []))

    def test_reads_every_page_of_open_prs(self):
        github = FakeGitHub({number: (f"h{number}", number != 150, MAIN) for number in range(1, 151)})
        self.assertEqual(run(github), ([150], []))

    def test_a_clean_answer_from_before_main_moved_is_not_trusted(self):
        github = FakeGitHub({2: ("h2", False, MAIN)}, stale=3)
        self.assertEqual(run(github), ([2], []))
        never = FakeGitHub({2: ("h2", False, MAIN)}, stale=100)
        self.assertEqual(run(never), ([], [2]), "a PR never judged against main is reported, not dropped")

    def test_one_failing_pr_does_not_stop_the_rest(self):
        github = FakeGitHub({1: ("h1", False, MAIN), 2: ("h2", False, MAIN)}, failing=[1])
        self.assertEqual(run(github), ([2], [1]))


if __name__ == "__main__":
    unittest.main()
