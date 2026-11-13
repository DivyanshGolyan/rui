#!/usr/bin/env python3
"""Run change-scoped local feedback before a push.

Use --plan to inspect commands without running them. Paths come from the
committed diff against --base; deleted paths still select their owning checks.
File tools and tests read the working tree; unstaged and untracked-only edits
do not select checks. GitHub CI owns review-phase acceptance.

When history since the merge base holds a merge of --base, the unit binaries
are also compiled unfiltered, as CI's unit producer compiles them (#1415).
--full adds that compile, stack-frames at the baseline CPU and, when
RUI_TEST_MYSQL_* name a reachable server, the selected targets that read it;
without one it says so and skips only that part (#1422).

--quick leaves out the Zig builds and is what the git pre-push hook runs;
--install-hook installs that hook. Whitespace errors in committed lines and
stale generated files (openapi.json, the client's wire.ts) are fixed in the
working tree and still fail the run, so the fix is committed before the push.

Each run writes a receipt to the checkout's own git directory: HEAD's tree
(null when the working tree differs from HEAD), the mode and each command's
exit code. The hook skips its checks when that receipt holds the pushed tree
and every command in it passed.

Run as a script, it re-executes itself in the caller's pinned Python 3.12
environment when .agents/setup made one (tests/ci/fixture_user.py --venv).
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
from typing import NamedTuple

import build_files
from caller_errors import inventory_path
import fixture_user
from platform_boundary import SCANNED as PLATFORM_SCANNED
from select_tests import LIVE_MYSQL_DIALECT_TARGETS, changed_paths, matches, select

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import live_engines

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
# Every worktree of a repository shares its hook, so the pushed commits travel
# in the environment, which a checkout's older prepush.py ignores.
PUSHED = "RUI_PREPUSH_PUSHED"
HOOK = f"""#!/bin/sh
# Installed by tests/ci/prepush.py --install-hook; skip once with git push --no-verify.
top=$(git rev-parse --show-toplevel) || exit 0
[ -f "$top/tests/ci/prepush.py" ] || exit 0
pushed=
while read -r _ local_sha _ _; do
    case $local_sha in *[!0]*) pushed="$pushed $local_sha" ;; esac
done
[ -n "$pushed" ] || exit 0
{PUSHED}=$pushed
export {PUSHED}
exec python3 "$top/tests/ci/prepush.py" --quick
"""
# Earlier --install-hook texts, which --install-hook replaces as its own.
PREVIOUS_HOOKS = ("""#!/bin/sh
# Installed by tests/ci/prepush.py --install-hook; skip once with git push --no-verify.
top=$(git rev-parse --show-toplevel) || exit 0
[ -f "$top/tests/ci/prepush.py" ] || exit 0
while read -r _ local_sha _ _; do
    case $local_sha in *[!0]*) exec python3 "$top/tests/ci/prepush.py" --quick ;; esac
done
""",)

# CI's unit producer compile (build_artifact.py for check.yml's compiled-unit
# part): every unit root, unfiltered, without running a test.
UNIT_COMPILE = ["zig", "build", "ci-build", "-Dci-targets=test", "-Dci-part=unit", "--summary", "line"]
# check.yml's linux_codegen gate, one compile at a time.
STACK_FRAMES = ["zig", "build", "-j1", "stack-frames", "-Dcpu=baseline", "--summary", "line"]
RECEIPT = "rui-prepush-receipt.json"


class Skipped(NamedTuple):
    """A planned check this run cannot execute, and why."""
    reason: str


def checks(paths, available, base, mode="default", merged_base=False, mysql=False):
    """(name, command or Skipped) pairs for the changed paths.

    `mode` is "quick", "default" or "full"; `merged_base` says history since
    the merge base merges --base; `mysql` says RUI_TEST_MYSQL_* name a server.
    """
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
    if mode == "quick":
        return
    if targets:
        yield "development selection", ["zig", "build", *targets, "--summary", "line"]
    zig_inputs = [path for path in paths if path.endswith((".zig", ".zon"))]
    if zig_inputs and select(zig_inputs, "review", available)["targets"]:
        yield "macOS type check", ["zig", "build", "typecheck-macos", "--summary", "line"]
    # A filtered or narrower build never analyzes tests a merge brought back (#1245).
    if merged_base or mode == "full":
        yield "unfiltered unit compile", UNIT_COMPILE
    if mode != "full":
        return
    yield "stack frames", STACK_FRAMES
    # The server targets that read RUI_TEST_MYSQL_*; test-pg needs Postgres and
    # mysql-wire-integration starts its own server in Docker, so both stay with CI.
    reads_mysql = LIVE_MYSQL_DIALECT_TARGETS | set(development["mysql_suites"])
    live = [target for target in development["server_targets"] if target in reads_mysql]
    if live and mysql:
        yield "live MySQL", ["env", f"{live_engines.REQUIRE}=mysql", "zig", "build", *live, "--summary", "line"]
    elif live:
        yield "live MySQL", Skipped(f"no reachable MySQL in {live_engines.MYSQL_SOCKET} and "
                                    f"{live_engines.MYSQL_ROOT_PASSWORD}, so CI runs {' '.join(live)}")


def mysql_reachable(environ):
    """Whether the environment names a MySQL socket that accepts a connection."""
    path, password = environ.get(live_engines.MYSQL_SOCKET), environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    if not path or not password:
        return False
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2)
        try:
            client.connect(path)
        except OSError:
            return False
    return True


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def merged_base(base, ref):
    """Whether a commit in base..HEAD merges in a commit that `ref` reaches."""
    for line in git("rev-list", "--merges", "--parents", f"{base}..HEAD").splitlines():
        for parent in line.split()[2:]:
            if subprocess.run(["git", "merge-base", "--is-ancestor", parent, ref], cwd=ROOT).returncode == 0:
                return True
    return False


def receipt_path():
    return Path(git("rev-parse", "--path-format=absolute", "--git-path", RECEIPT))


def clean_tree():
    """HEAD's tree when the working tree matches it, untracked files included; else None."""
    return None if git("status", "--porcelain", "--untracked-files=all") else git("rev-parse", "HEAD^{tree}")


def read_receipt():
    try:
        return json.loads(receipt_path().read_text())
    except (OSError, ValueError):
        return None


def receipt_covers(receipt, trees):
    """Whether the receipt records a run on every one of `trees` in which every command passed."""
    return (receipt is not None and receipt.get("tree") is not None and set(trees) == {receipt["tree"]}
            and all(result.get("exit") == 0 for result in receipt["results"] if "skipped" not in result))


def run(planned, mode):
    """Run each planned command once, write the receipt and return its results."""
    before = clean_tree()
    results = []
    for name, command in planned:
        if isinstance(command, Skipped):
            print(f"== {name}: skipped: {command.reason}", flush=True)
            results.append({"name": name, "skipped": command.reason})
            continue
        print(f"== {name}: {' '.join(command)}", flush=True)
        results.append({"name": name, "command": command, "exit": subprocess.run(command, cwd=ROOT).returncode})
    # A check that changed the working tree checked what HEAD does not hold.
    tree = before if clean_tree() == before else None
    path = receipt_path()
    path.write_text(json.dumps({"tree": tree, "mode": mode, "results": results}, indent=2) + "\n")
    if tree is None:
        print(f"The working tree differs from HEAD, so {path} matches no push.")
    return results


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
    if hook.exists() and hook.read_text() not in (HOOK, *PREVIOUS_HOOKS):
        raise SystemExit(f"{hook} already exists and is not Rui's; add `python3 tests/ci/prepush.py --quick` to it.")
    hooks.mkdir(parents=True, exist_ok=True)
    hook.write_text(HOOK)
    hook.chmod(0o755)
    print(f"Installed {hook}: each push runs python3 tests/ci/prepush.py --quick.")


# Git runs a hook with these naming the pushing repository, and in a linked
# worktree they outrank `git -C`: a check's scratch repository would commit
# to the pushing branch. Every git this script starts finds its repository
# from its directory.
HOOK_REPOSITORY = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_PREFIX")


def leave_hook_repository():
    for name in HOOK_REPOSITORY:
        os.environ.pop(name, None)


def main():
    leave_hook_repository()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--plan", action="store_true", help="print selected commands without executing them")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--quick", action="store_true", help="leave out the Zig builds, as the pre-push hook does")
    modes.add_argument("--full", action="store_true", help="also compile the unit binaries unfiltered, run stack-frames "
                       "and, with a reachable local MySQL, the selected targets that read it")
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
    mode = "full" if args.full else "quick" if args.quick else "default"
    pushed = os.environ.pop(PUSHED, "").split()
    if pushed:
        receipt = read_receipt()
        if receipt_covers(receipt, [git("rev-parse", f"{sha}^{{tree}}") for sha in pushed]):
            print(f"prepush: the {receipt['mode']} run on tree {receipt['tree']} passed; not running it again.")
            raise SystemExit(0)
    available = set(build_files.steps())
    base = git("merge-base", "HEAD", args.base)
    paths, _ = changed_paths(base, "HEAD")
    planned = list(checks(paths, available, base, mode, merged_base(base, args.base),
                          mode == "full" and mysql_reachable(os.environ)))
    if args.plan:
        print(json.dumps({"base": base, "paths": paths, "checks": [
            {"name": name, "skipped": command.reason} if isinstance(command, Skipped) else {"name": name, "command": command}
            for name, command in planned]}, indent=2))
        raise SystemExit(0)
    results = run(planned, mode)
    failed = [result["name"] for result in results if result.get("exit")]
    print(json.dumps({"failed": failed, "skipped": [result["name"] for result in results if "skipped" in result]}))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    # The pinned Python 3.12 environment that .agents/setup makes, when it exists (#1420).
    fixture_user.reexec_pinned(sys.argv)
    main()
