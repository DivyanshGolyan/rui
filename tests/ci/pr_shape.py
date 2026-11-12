#!/usr/bin/env python3
"""Require a Shape section in PR descriptions for changes to src/."""
import argparse
import os
import re
import sys

from select_tests import changed_paths


def refusal(changed_paths, body) -> str | None:
    if any(path.startswith("src/") for path in changed_paths) and not re.search(r"^##\s+Shape\s*$", body, re.M):
        return "PRs changing src/ need a ## Shape section in the description (CODING_STANDARDS.md#shape-before-code)."
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
