import copy
import json
from pathlib import Path
import unittest

import merge_review
from pr_timeline import review_outcomes

FIXTURES = json.loads(Path(__file__).with_name("merge_review_fixtures.json").read_text())


def verdict(findings, when, association="OWNER", marker="sonnet", login="DivyanshGolyan"):
    state = {"commit_sha": "7ba38bdf89613a8cf19174af1cc3dc840f92bfa9", "has_unresolved_findings": findings}
    return {"user": {"login": login}, "author_association": association, "created_at": when,
            "body": f"## Review\n<!-- {marker}-review-state:v1 {json.dumps(state)} -->"}


def refusal(comments, reviews=()):
    return merge_review.refusal(7, review_outcomes(comments, list(reviews), 7, warn=lambda message: None))


class MergeReviewTest(unittest.TestCase):
    def test_pull_requests_merged_with_no_review_are_refused(self):
        # #2302 and #2289 merged on 2026-11-25 while Codex answered only "failed" and its usage-limit notice.
        for number in ("2302", "2289"):
            with self.subTest(pr=number):
                reason = refusal(copy.deepcopy(FIXTURES[number]))
                self.assertIn("has no completed review", reason)
                self.assertIn("open_pr.py review", reason)

    def test_a_clean_review_passes_whoever_gave_it(self):
        self.assertIsNone(refusal([verdict(False, "2026-11-25T10:00:00Z")]))
        self.assertIsNone(refusal([verdict(False, "2026-11-25T10:00:00Z", marker="opus")]))

    def test_the_latest_review_decides(self):
        comments = [verdict(False, "2026-11-25T10:00:00Z"), verdict(True, "2026-11-25T11:00:00Z")]
        self.assertIn("unresolved findings", refusal(comments))
        self.assertIsNone(refusal(comments + [verdict(False, "2026-11-25T12:00:00Z")]))

    def test_a_marker_from_a_non_maintainer_never_counts(self):
        forged = verdict(False, "2026-11-25T10:00:00Z", association="NONE", login="stranger")
        self.assertIn("has no completed review", refusal([forged]))

    def test_codex_clean_receipt_passes(self):
        receipt = {"user": {"login": "chatgpt-codex-connector[bot]"}, "author_association": "NONE",
                   "created_at": "2026-11-25T10:00:00Z",
                   "body": "<!-- codex-review-receipt:v1 -->\n**Reviewed commit:** `7ba38bdf89`"}
        self.assertIsNone(refusal([receipt]))


if __name__ == "__main__":
    unittest.main()
