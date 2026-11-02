#!/usr/bin/env python3
"""Claude Code PreToolUse hook: refuse local full suites that CI repeats.

CODING_STANDARDS.md#evidence allows a full local run only to diagnose a CI
red. Prefix the command with RUI_CI_RED=<run or issue> to say which.
"""
import json
import re
import shlex
import sys

FULL_TARGETS = {"test", "check", "check-full"}
MIRRORS = ("pr-gates.sh", "nonroot-check.sh")


def refusal(command):
    """Why the command is a full local run, or None."""
    for segment in re.split(r"&&|\|\||[;|\n]", command):
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        if any(word.startswith("RUI_CI_RED=") and len(word) > len("RUI_CI_RED=") for word in words):
            continue
        if any(word.endswith(MIRRORS) for word in words):
            return "a local mirror of CI"
        builds = [i for i, word in enumerate(words[:-1]) if word.rsplit("/", 1)[-1] == "zig" and words[i + 1] == "build"]
        if not builds:
            continue
        rest = words[builds[0] + 2:]
        steps = {word for word in rest if not word.startswith("-")}
        filtered = any(word.startswith("-Dtest-filter") for word in rest)
        if steps & {"check", "check-full"} or ("test" in steps and not filtered):
            return "zig build " + " ".join(sorted(steps & FULL_TARGETS))
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
