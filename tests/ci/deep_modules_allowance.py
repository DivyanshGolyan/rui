#!/usr/bin/env python3
"""Ratchet the deep-modules allow file so it may not grow past trusted main.

`zig build deep-modules` judges only new findings and stale entries, by exact key. A pure
rename of an allowed finding therefore reads as one new finding plus one stale entry until
the allow file is regenerated, and this check does not see renames as growth. Growth is
judged here, by size, against the merge base with origin/main:

- per lint, the number of entries may not exceed the trusted file's count;
- for the circle lints (module-cycle, tangle), the total member count may not exceed the
  trusted file's total.

When the allow file is absent at the merge base, this is the bootstrap run and there is
nothing to compare against.
"""
import subprocess
import sys
from pathlib import Path

from caller_errors import git

ROOT = Path(__file__).resolve().parents[2]
ALLOWANCE = "tests/ci/deep_modules.allow"
CIRCLES = ("tangle", "module-cycle")


def entries(text):
    """The distinct (lint, key) pairs of an allow file. Blank lines and `#` comments are skipped."""
    found = set()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lint, _, key = line.partition(" ")
        key = key.strip()
        if not lint or not key:
            raise ValueError(f"{ALLOWANCE}:{number}: expected `<lint> <key>`")
        found.add((lint, key))
    return found


def sizes(text):
    """Per lint: (entry count, member count). Members count only for the circle lints."""
    totals = {}
    for lint, key in entries(text):
        count, members = totals.get(lint, (0, 0))
        if lint in CIRCLES:
            members += key.count(",") + 1
        totals[lint] = (count + 1, members)
    return totals


def growth(trusted, current):
    """Messages for each lint that grew past the trusted allow file; none when there is no trusted file."""
    if trusted is None:
        return []
    before, after = sizes(trusted), sizes(current)
    failures = []
    for lint, (count, members) in sorted(after.items()):
        base_count, base_members = before.get(lint, (0, 0))
        grew = []
        if count > base_count:
            grew.append(f"entries {base_count} -> {count}")
        if lint in CIRCLES and members > base_members:
            grew.append(f"members {base_members} -> {members}")
        if grew:
            failures.append(
                f"{lint}: the allowance grew past trusted main ({', '.join(grew)}); "
                "fix the finding instead of allowing it (AGENTS.md, Deep modules)")
    return failures


def trusted_text(root, base):
    """The allow file at the merge base, or None when it is absent there."""
    if not git(root, "ls-tree", "--name-only", base, "--", ALLOWANCE):
        return None
    return git(root, "show", f"{base}:{ALLOWANCE}")


def check(root=ROOT, base=None):
    """The merge base compared with, the trusted allow file there (None when absent), and the growth messages."""
    if base is None:
        base = git(root, "merge-base", "HEAD", "origin/main")
    trusted = trusted_text(root, base)
    return base, trusted, growth(trusted, (root / ALLOWANCE).read_text())


def main():
    try:
        base, trusted, failures = check()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"deep-modules allowance check failed: {error}", file=sys.stderr)
        return 1
    if failures:
        print("deep-modules allowance check failed:\n" + "\n".join(f"  {failure}" for failure in failures),
              file=sys.stderr)
        return 1
    if trusted is None:
        print(f"deep-modules allowance: {ALLOWANCE} is absent at {base}; bootstrap run, nothing to compare")
    else:
        print("deep-modules allowance: no growth past trusted main")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
