"""A push to main comments once per head on each open PR it left conflicting."""
import unittest

from conflict_alert import MARKER, alert


class FakeGitHub:
    def __init__(self, prs, comments=None, unsettled=0):
        self.prs = prs  # number -> (head sha, mergeable)
        self.comments = comments or {}
        self.unsettled = dict.fromkeys(prs, unsettled)
        self.posted = []

    def __call__(self, method, path, body=None):
        parts = path.split("?")[0].split("/")
        if method == "POST":
            number = int(parts[-2])
            self.posted.append((number, body["body"]))
            self.comments.setdefault(number, []).append(body)
            return {}
        if parts[-1] == "pulls":
            return [{"number": number} for number in self.prs]
        if parts[-1] == "comments":
            number = int(parts[-2])
            page = int(path.rsplit("page=", 1)[1])
            return self.comments.get(number, [])[(page - 1) * 100:page * 100]
        number = int(parts[-1])
        head, mergeable = self.prs[number]
        if self.unsettled[number]:
            self.unsettled[number] -= 1
            mergeable = None
        return {"number": number, "head": {"sha": head}, "mergeable": mergeable}


def run(github):
    return alert(github, "o/r", "a" * 40, sleep=lambda _: None)


class ConflictAlertTest(unittest.TestCase):
    def test_comments_only_on_conflicting_prs(self):
        github = FakeGitHub({1: ("h1", True), 2: ("h2", False), 3: ("h3", None)})
        self.assertEqual(run(github), [2])
        self.assertEqual([number for number, _ in github.posted], [2])
        self.assertIn(MARKER.format(head="h2"), github.posted[0][1])
        self.assertIn("aaaaaaaaaaaa", github.posted[0][1])

    def test_one_comment_per_head_however_many_pushes(self):
        github = FakeGitHub({2: ("h2", False)})
        run(github)
        run(github)
        self.assertEqual(len(github.posted), 1)
        github.prs[2] = ("h2b", False)
        run(github)
        self.assertEqual(len(github.posted), 2, "a new push that still conflicts gets a new comment")

    def test_finds_its_marker_past_the_first_page(self):
        earlier = [{"body": "review"}] * 150 + [{"body": MARKER.format(head="h2")}]
        github = FakeGitHub({2: ("h2", False)}, comments={2: earlier})
        self.assertEqual(run(github), [])

    def test_waits_for_github_to_settle_mergeability(self):
        github = FakeGitHub({2: ("h2", False)}, unsettled=3)
        self.assertEqual(run(github), [2])


if __name__ == "__main__":
    unittest.main()
