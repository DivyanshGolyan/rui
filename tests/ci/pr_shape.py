#!/usr/bin/env python3
"""Require a Summary sketch or legacy Shape section for changes to src/."""
import argparse
import os
import re
import subprocess
import sys

from conflict_alert import github
from select_tests import changed_paths


def summary_sketch(body):
    """Whether Summary contains a nonempty, closed Markdown code fence."""
    summary, content = False, False
    fence = None
    for line in body.splitlines():
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + r"{%d,}[ \t]*" % len(fence), line):
                if summary and content:
                    return True
                fence = None
            elif line.strip():
                content = True
            continue
        if opened := re.match(r"^ {0,3}(`{3,}|~{3,})", line):
            fence, content = opened[1], False
        elif heading := re.fullmatch(r" {0,3}(#{1,2})[ \t]+(.+?)[ \t]*", line):
            summary = heading[1] == "##" and heading[2] == "Summary"
    return False


def refusal(changed_paths, body) -> str | None:
    if any(path.startswith("src/") for path in changed_paths) and not (
            re.search(r"^##\s+Shape\s*$", body, re.M) or summary_sketch(body)):
        return ("PRs changing src/ need a nonempty fenced sketch in ## Summary or a legacy ## Shape section "
                "(CODING_STANDARDS.md#shape-before-code). Add a ## Shape section to the PR body, "
                "then re-run the failed jobs of this run; no push needed.")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", nargs="?", default=os.environ.get("BASE"))
    args = parser.parse_args()
    if not args.base:
        parser.error("provide BASE as an argument or environment variable")
    paths, _ = changed_paths(args.base, "HEAD")
    body = os.environ.get("PR_BODY", "")
    repo, number = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("PR_NUMBER")
    if repo and number:
        try:
            result = github("GET", f"repos/{repo}/pulls/{number}")
            live_body = result["body"]
            if live_body is not None and not isinstance(live_body, str):
                raise ValueError("invalid PR body")
            body = live_body or ""
            print("Judging current PR body from GitHub.")
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError) as error:
            print(f"Could not read current PR body from GitHub ({error}); judging event payload body.")
    reason = refusal(paths, body)
    if reason:
        print(reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
