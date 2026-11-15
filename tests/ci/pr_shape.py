#!/usr/bin/env python3
"""Require a Summary sketch or legacy Shape section for changes to src/."""
import argparse
import os
import re
import sys

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
        return "PRs changing src/ need a nonempty fenced sketch in ## Summary or a legacy ## Shape section (CODING_STANDARDS.md#shape-before-code)."
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", nargs="?", default=os.environ.get("BASE"))
    args = parser.parse_args()
    if not args.base:
        parser.error("provide BASE as an argument or environment variable")
    paths, _ = changed_paths(args.base, "HEAD")
    reason = refusal(paths, os.environ.get("PR_BODY", ""))
    if reason:
        print(reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
