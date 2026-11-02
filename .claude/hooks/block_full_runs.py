#!/usr/bin/env python3
"""Claude Code PreToolUse hook: refuse local full suites that CI repeats.

CODING_STANDARDS.md#evidence allows a full local run only to diagnose a CI
red. Prefix the command with RUI_CI_RED=<run or issue> to say which. This
guards against habit, not against a determined bypass.
"""
import json
import re
import sys

# A zig build anywhere, including inside `bash -c '...'` or `(...)`, and its
# arguments up to the end of its simple command.
BUILD = re.compile(r"""(?:^|[\s;&|(){}'"`])(?:\S*/)?zig\s+build\b([^;&|()'"`\n]*)""")
# The exemption is an assignment prefix of that same command.
NAMED_RED = re.compile(r"""(?:^|[;&|(){}'"`])\s*(?:env\s+)?(?:\w+=\S*\s+)*RUI_CI_RED=\S+\s+"""
                       r"""(?:(?:\w+=\S*|env|time|timeout\s+\S+)\s+)*$""")
NAMED_PREFIX = re.compile(r"\s*(?:env\s+)?(?:\w+=\S*\s+)*RUI_CI_RED=\S+\s")
MIRROR = re.compile(r"(?:pr-gates|nonroot-check)\.sh\b")


def refusal(command):
    """Why the command is a full local run, or None."""
    for match in BUILD.finditer(command):
        start = max(command.rfind(c, 0, match.start() + 1) for c in ";&|\n") + 1
        if NAMED_RED.search(command[start:match.start() + 1] + " "):
            continue
        words = match.group(1).split()
        steps = {word for word in words if not word.startswith("-")}
        if steps & {"check", "check-full"}:
            return "zig build " + " ".join(sorted(steps & {"check", "check-full"}))
        if "test" in steps and not any(word.startswith("-Dtest-filter=") for word in words):
            return "zig build test without -Dtest-filter"
    for match in MIRROR.finditer(command):
        start = max(command.rfind(c, 0, match.start()) for c in ";&|\n") + 1
        if not NAMED_PREFIX.match(command, start):
            return "a local mirror of CI"
    return None


def main():
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    reason = refusal(command)
    if reason:
        print(f"Refused {reason}: CI runs it on the pushed head (CODING_STANDARDS.md#evidence). "
              "Run python3 tests/ci/prepush.py and focused -Dtest-filter tests instead. "
              "To diagnose a CI red, prefix the command with RUI_CI_RED=<run URL or issue>.", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
