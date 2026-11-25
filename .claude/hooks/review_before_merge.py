#!/usr/bin/env python3
"""Refuse a merge or auto-merge of a Rui PR whose latest review is missing or unclean (tests/ci/merge_review.py).

An unreadable review record (no network, no `gh`) lets the merge through with a warning:
the hook catches a forgotten review, and GitHub's own checks still gate the merge.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests" / "ci"))

REPO = "DivyanshGolyan/rui"
MERGE_TOOLS = ("mcp__github__merge_pull_request", "mcp__github__enable_pr_auto_merge")
GH_MERGE = re.compile(r"""(?:^|[\s;&|(){}'"`])gh\s+pr\s+merge\s+(?:\S+\s+)*?(?:\S*/pull/|#)?(\d+)\b""")
GH_API_MERGE = re.compile(r"""repos/DivyanshGolyan/rui/pulls/(\d+)/merge\b""")


def merged_pr(payload):
    """The PR number of a Rui merge this tool call would perform, or None."""
    tool, args = payload.get("tool_name", ""), payload.get("tool_input", {})
    if tool in MERGE_TOOLS:
        slug = f"{args.get('owner')}/{args.get('repo')}"
        return args.get("pullNumber") if slug == REPO else None
    if tool == "Bash":
        match = GH_MERGE.search(args.get("command", "")) or GH_API_MERGE.search(args.get("command", ""))
        return int(match[1]) if match else None
    return None


def main():
    number = merged_pr(json.load(sys.stdin))
    if number is None:
        return 0
    from merge_review import pr_refusal
    try:
        reason = pr_refusal(int(number))
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"warning: could not read PR #{number}'s review record ({error}); not blocking.", file=sys.stderr)
        return 0
    if reason:
        print(f"Refused the merge: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
