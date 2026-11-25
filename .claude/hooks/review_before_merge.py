#!/usr/bin/env python3
"""Refuse a merge or auto-merge of a Rui PR whose latest review is missing or unclean (tests/ci/merge_review.py).

An unreadable review record (no network, no `gh`) lets the merge through with a warning:
the hook catches a forgotten review, and GitHub's own checks still gate the merge.
"""
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests" / "ci"))

REPO = "DivyanshGolyan/rui"
MERGE_TOOLS = ("mcp__github__merge_pull_request", "mcp__github__enable_pr_auto_merge")
# `gh pr merge` options that take a value, so the value is not mistaken for the PR selector.
VALUE_FLAGS = {"-b", "--body", "-F", "--body-file", "-t", "--subject", "-A", "--author-email", "--match-head-commit"}
SELECTOR = re.compile(r"^(?:https?://\S*/pull/|#)?(\d+)/?$")


def selector_number(selector, repo):
    """The PR number a `gh pr merge` selector names; a branch or none means the current branch's PR (gh resolves it)."""
    match = SELECTOR.match(selector or "")
    if match:
        return int(match[1])
    command = ["gh", "pr", "view", *([selector] if selector else []), "--repo", repo, "--json", "number", "--jq", ".number"]
    return int(subprocess.run(command, check=True, capture_output=True, text=True).stdout)


def gh_merges(command):
    """(repo, selector) for each `gh pr merge` and each PUT to .../pulls/N/merge in a shell command."""
    merges = []
    for segment in re.split(r"[;&|\n]+", command):
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        for i in range(len(words) - 2):
            if words[i:i + 3] == ["gh", "pr", "merge"]:
                repo, selector, skip = REPO, None, False
                rest = words[i + 3:]
                for j, word in enumerate(rest):
                    if skip:
                        skip = False
                    elif word in ("-R", "--repo"):
                        repo, skip = rest[j + 1] if j + 1 < len(rest) else repo, True
                    elif word.startswith("--repo="):
                        repo = word.split("=", 1)[1]
                    elif word in VALUE_FLAGS:
                        skip = True
                    elif not word.startswith("-") and selector is None:
                        selector = word
                merges.append((repo, selector))
        for match in re.finditer(r"repos/([\w.-]+/[\w.-]+)/pulls/(\d+)/merge\b", segment):
            merges.append((match[1], match[2]))
    return merges


def merged_prs(payload):
    """The Rui PR numbers this tool call would merge; resolving a branch selector may call `gh`."""
    tool, args = payload.get("tool_name", ""), payload.get("tool_input", {})
    if tool in MERGE_TOOLS:
        slug = f"{args.get('owner')}/{args.get('repo')}"
        return [args["pullNumber"]] if slug.lower() == REPO.lower() and args.get("pullNumber") else []
    if tool == "Bash":
        return [selector_number(selector, repo) for repo, selector in gh_merges(args.get("command", ""))
                if repo.lower() == REPO.lower()]
    return []


def main():
    payload = json.load(sys.stdin)
    try:
        from merge_review import pr_refusal
        for number in merged_prs(payload):
            if reason := pr_refusal(int(number)):
                print(f"Refused the merge: {reason}", file=sys.stderr)
                return 2
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, TypeError, ImportError) as error:
        print(f"warning: could not read the review record ({error}); not blocking.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
