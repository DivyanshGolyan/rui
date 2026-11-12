#!/usr/bin/env python3
"""Run change-scoped local feedback before a push.

Use --plan to inspect commands without running them. Paths come from the
committed diff against --base; deleted paths still select their owning checks.
File tools and tests read the working tree; unstaged and untracked-only edits
do not select checks. GitHub CI owns review-phase acceptance.

--quick leaves out the Zig builds and is what the git pre-push hook runs;
--install-hook installs that hook. Whitespace errors in committed lines and
stale generated files (openapi.json, the client's wire.ts) are fixed in the
working tree and still fail the run, so the fix is committed before the push.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import build_files
from caller_errors import inventory_path
from platform_boundary import SCANNED as PLATFORM_SCANNED
from select_tests import changed_paths, matches, select

ROOT = Path(__file__).resolve().parents[2]


SOURCE_POLICY = (
    (("src/*.zig", "tests/*.zig"), (("test_import_architecture.py", "*"),)),
    (("src/*.zig",), (("test_provider_locality.py", "*"), ("test_wire_version.py", "*"))),
    (("src/*.zig", "tests/*.zig", "tests/integration/*.py", "tests/ci/test_*.py", "tests/ci/*_test.py"),
     (("test_harness_contracts.py", "SleepOrderingTest.test_tree_matches_the_shrink_only_allowlist"),)),
    (PLATFORM_SCANNED, (("test_platform_boundary.py", "*"),)),
    (("tests/integration/*.py", "tests/integration/*.sh", "tests/qualification/*.go"),
     (("test_wire_version.py", "*"), ("test_store_schema_fixtures.py", "*"))),
    (("src/*.zig", "tests/*.zig", "tests/integration/*.py", "tests/integration/*.sh"),
     (("test_fixture_literals.py", "*"),)),
    (("src/TestObservation.zig", "tests/integration/host_process.py", "tests/qualification/measurement/observation.go"),
     (("test_harness_contracts.py", "ObservationCodecTest"),)),
    (("tests/qualification/*.go",), (("test_harness_contracts.py", "QualificationEvidenceTest"),)),
    (("src/store/*.zig", "src/store.zig"), (("test_store_engine_boundary.py", "*"),
                                          ("test_store_conformance.py", "*"))),
    (("tests/ci/caller_errors.py",), (("test_store_engine_boundary.py", "*"),)),
    (("src/store/schema.zig", "tests/integration/host_process.py"),(("test_store_schema_fixtures.py", "*"),)),
    (("src/store/schema.zig",), (("test_store_schema_version.py", "*"),)),
    (("tests/ci/prepush.py",), (("test_caller_errors.py", "CallerErrors.test_gate_is_explicitly_wired_before_development_builds"),
                              ("test_selection.py", "SelectionTest.test_prepush_leaves_server_targets_to_ci"))),
)


def policy_tests(paths):
    """Return module-to-test filters, or None for the full policy suite."""
    focused = {}
    for path in paths:
        if path.endswith(".md"):
            continue
        if path.startswith("tests/ci/") and path.endswith(".py"):
            name = Path(path).name
            test = name if name.startswith("test_") else f"test_{name}"
            if (ROOT / "tests/ci" / test).is_file():
                focused.setdefault(test, set()).add("*")
            else:
                return None
        elif path.startswith(("tests/ci/", ".github/", ".claude/")) or path in ("build.zig", "build.zig.zon", ".agents/setup") or path.startswith("build/"):
            return None
    for patterns, tests in SOURCE_POLICY:
        if any(matches(path, patterns) for path in paths):
            for module, test in tests:
                focused.setdefault(module, set()).add(test)
    return focused


# Generated from the wire types, then from openapi.json; CI fails when either is stale.
GENERATED = ("openapi.json", "clients/ts/src/wire.ts")
# The two `git diff --check` problems with one fix; a patch's whitespace is its content.
WHITESPACE_LINES = re.compile(r"^([^\s:][^:\n]*):(\d+): (trailing whitespace|new blank line at EOF)\.$", re.M)
UNFIXABLE = ("*.patch", "*.diff")
HOOK = """#!/bin/sh
# Installed by tests/ci/prepush.py --install-hook; skip once with git push --no-verify.
top=$(git rev-parse --show-toplevel) || exit 0
[ -f "$top/tests/ci/prepush.py" ] || exit 0
while read -r _ local_sha _ _; do
    case $local_sha in *[!0]*) exec python3 "$top/tests/ci/prepush.py" --quick ;; esac
done
"""


def checks(paths, available, base, quick=False):
    paths = sorted(set(paths))
    if not paths:
        return
    existing = [path for path in paths if (ROOT / path).is_file()]
    build_paths = [path for path in paths if not path.startswith("clients/ts/")]
    development = select(build_paths, "development", available)
    # These targets require CI's live MySQL or Postgres rather than a local skip.
    targets = [target for target in development["targets"] if target not in development["server_targets"]]
    yield "whitespace", [sys.executable, "-B", "tests/ci/prepush.py", "--fix-whitespace", base]
    zig = [path for path in existing if path.endswith(".zig")]
    if zig:
        yield "zig fmt", ["zig", "fmt", "--check", "--ast-check", *zig]
    if any(inventory_path(path) for path in paths):
        yield "caller errors", [sys.executable, "-B", "tests/ci/caller_errors.py"]
    if "src/store/schema.zig" in paths:
        yield "schema number", [sys.executable, "-B", "tests/ci/schema_number.py", "--check"]
    if any(matches(path, ("src/*.zig", "openapi.json")) for path in paths):
        yield "generated files", [sys.executable, "-B", "tests/ci/prepush.py", "--regenerate"]
    policy = policy_tests(paths)
    # Focused discovery cannot depend on another test importing fixture helpers first.
    pythonpath = os.pathsep.join(filter(None, (str(ROOT / "tests/integration"), os.environ.get("PYTHONPATH"))))
    unittest = ["env", f"PYTHONPATH={pythonpath}", sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/ci"]
    if policy is None:
        yield "tests/ci", unittest
    else:
        for module, filters in sorted(policy.items()):
            command = [*unittest, "-p", module]
            if "*" not in filters:
                for test in sorted(filters):
                    command.extend(["-k", test])
            yield f"tests/ci: {module}", command
    python = [path for path in existing if path.endswith(".py")]
    if python:
        yield "undefined Python names", [sys.executable, "-m", "ruff", "check", "--select", "F821", *python]
    if any(path == "openapi.json" or path.startswith("clients/ts/") and not path.endswith(".md") for path in paths):
        yield "TypeScript client", ["npm", "--prefix", "clients/ts", "run", "check"]
    if quick:
        return
    if targets:
        yield "development selection", ["zig", "build", *targets, "--summary", "line"]
    zig_inputs = [path for path in paths if path.endswith((".zig", ".zon"))]
    if zig_inputs and select(zig_inputs, "review", available)["targets"]:
        yield "macOS type check", ["zig", "build", "typecheck-macos", "--summary", "line"]


def fix_whitespace(base):
    """Fix `git diff --check`'s trailing whitespace and blank lines at EOF; 1 if anything was wrong."""
    report = subprocess.run(["git", "diff", "--check", base, "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout
    if not report:
        return 0
    print(report, end="")
    lines = {}
    for path, line, kind in WHITESPACE_LINES.findall(report):
        lines.setdefault(path, []).append((int(line), kind))
    fixed = []
    for path, problems in sorted(lines.items()):
        target = ROOT / path
        # Line numbers are HEAD's; a file with uncommitted edits or a patch is left to its author.
        if (matches(path, UNFIXABLE) or not target.is_file()
                or subprocess.run(["git", "diff", "--quiet", "HEAD", "--", path], cwd=ROOT).returncode):
            continue
        text = target.read_text().split("\n")
        for number, kind in problems:
            if kind == "trailing whitespace":
                text[number - 1] = text[number - 1].rstrip(" \t")
        content = "\n".join(text)
        if any(kind == "new blank line at EOF" for _, kind in problems):
            content = content.rstrip("\n") + "\n"
        if content != target.read_text():
            target.write_text(content)
            fixed.append(path)
    if fixed:
        print("Fixed whitespace in the working tree of " + ", ".join(fixed) + ": commit it, then push again.")
    return 1


def regenerate():
    """Regenerate openapi.json and wire.ts; 1 if either differs from HEAD's."""
    if subprocess.run(["zig", "build", "openapi", "--summary", "none"], cwd=ROOT).returncode:
        return 1
    if (ROOT / "clients/ts/node_modules").is_dir():
        if subprocess.run(["npm", "--prefix", "clients/ts", "run", "--silent", "generate"], cwd=ROOT).returncode:
            return 1
    else:
        print("clients/ts has no node_modules, so wire.ts was not regenerated: npm --prefix clients/ts ci")
    stale = subprocess.run(["git", "diff", "--name-only", "HEAD", "--", *GENERATED], cwd=ROOT,
                           capture_output=True, text=True, check=True).stdout.split()
    if stale:
        print("Regenerated " + ", ".join(stale) + " in the working tree: commit them, then push again.")
    return 1 if stale else 0


def install_hook():
    hooks = Path(subprocess.check_output(["git", "rev-parse", "--path-format=absolute", "--git-path", "hooks"],
                                         cwd=ROOT, text=True).strip())
    hook = hooks / "pre-push"
    if hook.exists() and hook.read_text() != HOOK:
        raise SystemExit(f"{hook} already exists and is not Rui's; add `python3 tests/ci/prepush.py --quick` to it.")
    hooks.mkdir(parents=True, exist_ok=True)
    hook.write_text(HOOK)
    hook.chmod(0o755)
    print(f"Installed {hook}: each push runs python3 tests/ci/prepush.py --quick.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--plan", action="store_true", help="print selected commands without executing them")
    parser.add_argument("--quick", action="store_true", help="leave out the Zig builds, as the pre-push hook does")
    parser.add_argument("--install-hook", action="store_true", help="install the git pre-push hook that runs --quick")
    parser.add_argument("--fix-whitespace", metavar="BASE", help=argparse.SUPPRESS)
    parser.add_argument("--regenerate", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.install_hook:
        return install_hook()
    if args.fix_whitespace:
        raise SystemExit(fix_whitespace(args.fix_whitespace))
    if args.regenerate:
        raise SystemExit(regenerate())
    available = set(build_files.steps())
    base = subprocess.check_output(["git", "merge-base", "HEAD", args.base], cwd=ROOT, text=True).strip()
    paths, _ = changed_paths(base, "HEAD")
    planned = list(checks(paths, available, base, args.quick))
    if args.plan:
        print(json.dumps({"base": base, "paths": paths,
                          "checks": [{"name": name, "command": command} for name, command in planned]}, indent=2))
        raise SystemExit(0)
    failed = []
    for name, command in planned:
        print(f"== {name}: {' '.join(command)}", flush=True)
        if subprocess.run(command, cwd=ROOT).returncode:
            failed.append(name)
    print(json.dumps({"failed": failed}))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
