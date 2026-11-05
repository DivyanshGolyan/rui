#!/usr/bin/env python3
"""Run the mechanical pre-push checks of CODING_STANDARDS.md#evidence in one step.

Whitespace, formatting, caller-error coverage, the CI policy tests, undefined fixture
names, the development selection and the macOS type check whenever CI's
review selection would run it. The selection covers committed changes since the merge base with
--base; formatting and the tests read the working tree. Focused
`-Dtest-filter` runs and fix mutations stay the author's. Run it before
every push, including after merging main.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from select_tests import changed_paths, select

ROOT = Path(__file__).resolve().parents[2]


def checks(paths, available, base):
    development = select(paths, "development", available)
    # Server targets need CI's live MySQL or Postgres; CI runs them on the draft.
    targets = [target for target in development["targets"] if target not in development["server_targets"]]
    # check.yml's macos_typecheck runs whenever the review selection is non-empty.
    typecheck = bool(select(paths, "review", available)["targets"])
    # The plan job runs this first; a failure there turns every check red.
    yield "whitespace", ["git", "diff", "--check", base, "HEAD"]
    yield "zig fmt", ["zig", "fmt", "--check", "--ast-check", "build.zig", "src"]
    yield "caller errors", [sys.executable, "-B", "tests/ci/caller_errors.py"]
    yield "tests/ci", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/ci"]
    yield "undefined fixture names", [sys.executable, "-m", "ruff", "check", "--select", "F821", "tests"]
    if targets:
        yield "development selection", ["zig", "build", *targets, "--summary", "line"]
    if typecheck:
        yield "macOS type check", ["zig", "build", "typecheck-macos", "--summary", "line"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (ROOT / "build.zig").read_text()))
    base = subprocess.check_output(["git", "merge-base", "HEAD", args.base], cwd=ROOT, text=True).strip()
    paths, _ = changed_paths(base, "HEAD")
    failed = []
    for name, command in checks(paths, available, base):
        print(f"== {name}: {' '.join(command)}", flush=True)
        if subprocess.run(command, cwd=ROOT).returncode:
            failed.append(name)
    print(json.dumps({"failed": failed}))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
