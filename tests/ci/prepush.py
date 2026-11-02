#!/usr/bin/env python3
"""Run the mechanical pre-push checks of CODING_STANDARDS.md#evidence in one step.

Formatting, the CI policy tests, undefined fixture names, the development
selection and, when Zig changed, the macOS type check. Focused
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


def checks(paths, available):
    targets = select(paths, "development", available)["targets"]
    yield "zig fmt", ["zig", "fmt", "--check", "--ast-check", "build.zig", "src"]
    yield "tests/ci", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/ci"]
    yield "undefined fixture names", [sys.executable, "-m", "ruff", "check", "--select", "F821", "tests"]
    if targets:
        yield "development selection", ["zig", "build", *targets, "--summary", "line"]
    if any(path.endswith(".zig") or path == "build.zig.zon" for path in paths):
        yield "macOS type check", ["zig", "build", "typecheck-macos", "--summary", "line"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (ROOT / "build.zig").read_text()))
    paths, _ = changed_paths(args.base, "HEAD")
    failed = []
    for name, command in checks(paths, available):
        print(f"== {name}: {' '.join(command)}", flush=True)
        if subprocess.run(command, cwd=ROOT).returncode:
            failed.append(name)
    print(json.dumps({"failed": failed}))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
