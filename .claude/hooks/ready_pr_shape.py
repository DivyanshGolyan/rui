#!/usr/bin/env python3
"""Refuse to open or mark ready a Rui PR whose body admission would reject (tests/ci/pr_shape.py ready_refusal).

Admission is the last job of a ready PR's run, so a missing Goal, Summary sketch or screen line surfaces
20 minutes after the PR is ready, and only to whoever reads the failure. The hook asks the same owner first.
An unreadable PR (no network, no `gh`, no local main) lets the call through with a warning.
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests" / "ci"))

REPO = "DivyanshGolyan/rui"


def ready_call(payload):
    """(number or None, head, body override) when this call makes a Rui PR ready for review, else None."""
    tool, args = payload.get("tool_name", ""), payload.get("tool_input", {})
    if f"{args.get('owner')}/{args.get('repo')}" != REPO:
        return None
    if tool == "mcp__github__create_pull_request" and args.get("draft") is not True:
        return None, args.get("head"), args.get("body")
    if tool == "mcp__github__update_pull_request" and args.get("draft") is False:
        return args.get("pullNumber"), None, args.get("body")
    return None


def refusal(call, api):
    from pr_shape import ready_refusal
    number, head, body = call
    if number:
        pr = api("GET", f"repos/{REPO}/pulls/{number}")
        files = api("GET", f"repos/{REPO}/pulls/{number}/files?per_page=100")
        body = pr["body"] or "" if body is None else body
    else:
        files = api("GET", f"repos/{REPO}/compare/main...{head}")["files"]
        body = body or ""
    reason = ready_refusal([row["filename"] for row in files], body, base="origin/main", repo=REPO, number=number)
    return f"Refused: this PR would fail admission on its body. {reason}" if reason else None


def main():
    call = ready_call(json.load(sys.stdin))
    if call is None:
        return 0
    from conflict_alert import github
    try:
        reason = refusal(call, github)
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"warning: could not judge the PR body ({error}); not blocking.", file=sys.stderr)
        return 0
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
