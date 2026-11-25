#!/usr/bin/env python3
"""Refuse to merge a PR whose latest completed review is missing or has unresolved findings.

The reviewer is whoever answered last: Codex, or while Codex is out of
allowance the `pr-reviewer` agent whose verdict `open_pr.py review` posts as a
sonnet-review-state:v1 marker. pr_timeline.review_outcomes owns reading both, so
a comment from anyone but the repository's maintainers never counts, and a bare Codex
"no major issues" receipt is not clean (docs/agents/landing.md). The gate is per PR,
not per head: one review, then fixes ship without another.

  merge_review.py PR_NUMBER   exit 1 and name the missing step when the PR may not merge
"""
import sys

from conflict_alert import github, pages
from pr_timeline import REPO, review_outcomes

NEXT_STEP = ("Codex is the review. While it is out of allowance, run the pr-reviewer agent once "
             "(.claude/agents/pr-reviewer.md) and post its verdict with `python3 tests/ci/open_pr.py review`; "
             "after fixing findings, post `open_pr.py review --fixed`. docs/agents/landing.md#review-evidence")


def verdicts(outcomes):
    """The outcomes that can clear a merge: a receipt alone is not a review."""
    return [outcome for outcome in outcomes if outcome["source"] != "receipt"]


def refusal(number, outcomes, ignored=()):
    """The reason a PR may not merge yet, or None when its latest completed review is clean."""
    outcomes = verdicts(outcomes)
    note = "".join(f" Ignored a malformed marker: {message}" for message in ignored)
    if not outcomes:
        return f"PR #{number} has no completed review.{note} {NEXT_STEP}"
    last = outcomes[-1]
    if not last["clean"]:
        return f"PR #{number}'s latest review ({last['source']}, {last['when']}) has unresolved findings.{note} {NEXT_STEP}"
    return None


def pr_outcomes(number, repo=REPO, api=github):
    """(review outcomes, warnings about markers that could not be read) for a PR."""
    comments = list(pages(api, f"repos/{repo}/issues/{number}/comments?"))
    reviews = list(pages(api, f"repos/{repo}/pulls/{number}/reviews?"))
    ignored = []
    return review_outcomes(comments, reviews, number, warn=ignored.append), ignored


def pr_refusal(number, repo=REPO, api=github):
    outcomes, ignored = pr_outcomes(number, repo, api)
    return refusal(number, outcomes, ignored)


def main():
    reason = pr_refusal(int(sys.argv[1]))
    if reason:
        print(reason, file=sys.stderr)
    return 1 if reason else 0


if __name__ == "__main__":
    sys.exit(main())
