#!/usr/bin/env python3
"""Run change-scoped local feedback before a push.

Use --plan to inspect commands without running them. Paths come from the
committed diff against --base; deleted paths still select their owning checks.
File tools and tests read the working tree; unstaged and untracked-only edits
do not select checks. GitHub CI owns review-phase acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

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
     (("test_wire_version.py", "*"),)),
    (("src/TestObservation.zig", "tests/integration/host_process.py", "tests/qualification/measurement/observation.go"),
     (("test_harness_contracts.py", "ObservationCodecTest"),)),
    (("tests/qualification/*.go",), (("test_harness_contracts.py", "QualificationEvidenceTest"),)),
    (("src/store/*.zig", "src/store.zig"), (("test_store_engine_boundary.py", "*"),
                                          ("test_store_conformance.py", "*"))),
    (("src/store/schema.zig", "tests/integration/host_process.py"), (("test_store_schema_fixtures.py", "*"),)),
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
        elif path.startswith(("tests/ci/", ".github/", ".claude/")) or path in ("build.zig", "build.zig.zon", ".agents/setup"):
            return None
    for patterns, tests in SOURCE_POLICY:
        if any(matches(path, patterns) for path in paths):
            for module, test in tests:
                focused.setdefault(module, set()).add(test)
    return focused


def checks(paths, available, base):
    paths = sorted(set(paths))
    if not paths:
        return
    existing = [path for path in paths if (ROOT / path).is_file()]
    build_paths = [path for path in paths if not path.startswith("clients/ts/")]
    development = select(build_paths, "development", available)
    # These targets require CI's live MySQL or Postgres rather than a local skip.
    targets = [target for target in development["targets"] if target not in development["server_targets"]]
    yield "whitespace", ["git", "diff", "--check", base, "HEAD"]
    documents = [path for path in existing if path.endswith(".md")
                 and ("/" not in path or path.startswith("docs/")) and path != "THIRD_PARTY_NOTICES.md"]
    if documents:
        yield "markdown sentences", [sys.executable, "tests/ci/sentence_lines.py", "--check", *documents]
    zig = [path for path in existing if path.endswith(".zig")]
    if zig:
        yield "zig fmt", ["zig", "fmt", "--check", "--ast-check", *zig]
    if any(inventory_path(path) for path in paths):
        yield "caller errors", [sys.executable, "-B", "tests/ci/caller_errors.py"]
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
    if targets:
        yield "development selection", ["zig", "build", *targets, "--summary", "line"]
    zig_inputs = [path for path in paths if path.endswith((".zig", ".zon"))]
    if zig_inputs and select(zig_inputs, "review", available)["targets"]:
        yield "macOS type check", ["zig", "build", "typecheck-macos", "--summary", "line"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--plan", action="store_true", help="print selected commands without executing them")
    args = parser.parse_args()
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (ROOT / "build.zig").read_text()))
    base = subprocess.check_output(["git", "merge-base", "HEAD", args.base], cwd=ROOT, text=True).strip()
    paths, _ = changed_paths(base, "HEAD")
    planned = list(checks(paths, available, base))
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
