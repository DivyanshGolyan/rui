#!/usr/bin/env python3
"""Say which Store schema number this branch should use, read from main as it is now.

Each format PR appends one schema_version after main's (D226). Two open PRs
that take the same next number race, and the second to land must renumber.
CI compares a PR with its merge base; this compares the working tree with
origin/main after fetching it, so a branch learns before CI or a conflict that
main moved past it. --check exits 1 when the branch's number is not the one to
use.
"""
import argparse
from pathlib import Path
import subprocess
import sys

import git_command
from release_numbers import SCHEMA, schema_version

ROOT = Path(__file__).resolve().parents[2]


def advice(branch, base, main):
    """(ok, message) for a branch at schema `branch` whose merge base has `base` and main has `main`."""
    if branch == base:
        return True, f"This branch keeps the Store format; main is at schema {main}."
    if branch < base:
        return False, f"schema_version {branch} goes back below its base's {base}: restore {base}."
    if main > base:
        # CI judges the merge base, so a renumbered branch must also rebase.
        renumber = (f"keep schema {branch}" if branch == main + 1 else
                    f"renumber this branch's format from {branch} to {main + 1}: schema_version = {main + 1}, "
                    f"its bootstrap_digests row and its migration step .from = {main}")
        return False, f"main reached schema {main} after this branch's base ({base}). Rebase onto origin/main and {renumber}."
    if branch == main + 1:
        return True, f"This branch appends schema {branch}, one past main's {main}."
    return False, (f"schema_version {branch} skips past {main + 1}: a format PR appends exactly one version, "
                   f"so use {main + 1}.")


def git(*args):
    return git_command.git(*args, cwd=ROOT, strip=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 unless the branch uses the right number")
    parser.add_argument("--no-fetch", action="store_true", help="use the local origin/main as it is")
    args = parser.parse_args()
    if not args.no_fetch:
        fetched = subprocess.run(["git", "fetch", "--quiet", "origin", "main"], cwd=ROOT, capture_output=True, text=True)
        if fetched.returncode:
            print(f"Could not fetch origin main ({fetched.stderr.strip()}); using the local origin/main.", file=sys.stderr)
    base = git("merge-base", "HEAD", "origin/main").strip()
    ok, message = advice(schema_version((ROOT / SCHEMA).read_text()),
                         schema_version(git("show", f"{base}:{SCHEMA}")),
                         schema_version(git("show", f"origin/main:{SCHEMA}")))
    print(message)
    if args.check and not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
