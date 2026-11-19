#!/usr/bin/env python3
"""Run change-scoped local feedback before a push.

Use --plan to inspect commands without running them. Paths come from the
committed diff against --base; deleted paths still select their owning checks.
File tools and tests read the working tree; unstaged and untracked-only edits
do not select checks. GitHub CI owns review-phase acceptance.

Default and --quick run the same cheap feedback. --full is an opt-in diagnostic
that adds the CI policy suite, development builds, cross-compilation, all-unit compilation, stack
frames and reachable live MySQL checks. UID-global Upgrade stays hosted.
Generation runs only for the emitter's input closure or generated wire inputs.
The hook reuses a passing receipt for the same tree and merge base.
Receipts describe local feedback only. Hosted acceptance is never evaluated
here, and cached output retains every recorded CI deferral.

Run as a script, it re-executes itself in the caller's pinned Python 3.12
environment when .agents/setup made one (tests/ci/fixture_user.py --venv).
"""
import argparse
from contextlib import redirect_stdout
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
from typing import NamedTuple
from urllib.parse import quote

import failure_cause
import report_issue
from qualification import matrix_targets
from pr_overlap import repo_from_remote
from select_tests import FIXTURES

import build_artifact
import build_files
from caller_errors import inventory_path
import fixture_user
from platform_boundary import SCANNED as PLATFORM_SCANNED
from select_tests import ACCEPTANCE_INPUTS, CLIENT_LOCALITY_INPUTS, LIVE_MYSQL_DIALECT_TARGETS, changed_paths, matches, select, tree_graph

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import live_engines
import runtime_leftovers

ROOT = Path(__file__).resolve().parents[2]


SOURCE_POLICY = (
    (ACCEPTANCE_INPUTS, (("native_acceptance_test.py", "*"),)),
    (CLIENT_LOCALITY_INPUTS, (("test_client_locality.py", "*"),)),
    ((".claude/skills/verify-rui/scripts/frames.json", ".claude/skills/verify-rui/features/*.md"),
     (("test_verify_rui_map.py", "*"),)),
    (("tests/integration/settings_fixture.py",), (("test_settings_fixture.py", "*"),)),
    (("tests/integration/previous_release_upgrade.py", "tests/integration/host_serve_dialect.py"),
     (("test_previous_release_upgrade.py", "*"),)),
    (("tests/integration/upgrade_integration.py",), (("test_upgrade_fixture.py", "*"),)),
    (("src/*.zig", "tests/*.zig"), (("test_import_architecture.py", "*"),)),
    (("src/*.zig",), (("test_provider_locality.py", "*"), ("test_wire_version.py", "*"))),
    (("src/*.zig", "tests/*.zig", "tests/integration/*.py", "tests/ci/test_*.py", "tests/ci/*_test.py"),
     (("test_flake_sources.py", "SleepOrderingTest.test_tree_matches_the_shrink_only_allowlist"),)),
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
    (("build.zig.zon", "src/h2/h2.zig", "tests/integration/*.py",
      "tests/integration/*.sh", "tests/qualification/*.go", "tests/qualification/*.py", "tests/qualification/*.sh"),
     (("test_transport_version_fixtures.py", "*"),)),
    (("src/store/schema.zig", "src/store/migration_baseline.sqlite.sql",
      "src/store/migration_baseline.mysql.sql", "src/store/migration_baseline_rows.sql"),
     (("test_store_schema_version.py", "*"),)),
    (("tests/ci/prepush.py",), (("test_prepush_red.py", "*"),
                              ("test_caller_errors.py", "CallerErrors.test_gate_is_explicitly_wired_in_local_feedback"),
                              ("test_selection.py", "SelectionTest.test_prepush_leaves_server_targets_to_ci"))),
)


def policy_tests(paths):
    focused = {}
    for path in paths:
        if path.endswith(".md"):
            continue
        if path.startswith("tests/ci/") and path.endswith(".py"):
            name = Path(path).name
            test = name if name.startswith("test_") else f"test_{name}"
            if (ROOT / "tests/ci" / test).is_file():
                focused.setdefault(test, set()).add("*")
    for patterns, tests in SOURCE_POLICY:
        if any(matches(path, patterns) for path in paths):
            for module, test in tests:
                focused.setdefault(module, set()).add(test)
    return focused


GENERATED = ("openapi.json", "clients/ts/src/wire.ts", "clients/ts/src/settings-kinds.ts")
WHITESPACE_LINES = re.compile(r"^([^\s:][^:\n]*):(\d+): (trailing whitespace|new blank line at EOF)\.$", re.M)
UNFIXABLE = ("*.patch", "*.diff")
PUSHED = "RUI_PREPUSH_PUSHED"
REMOTE_REFS = "RUI_PREPUSH_REMOTE_REFS"
REMOTE_URL = "RUI_PREPUSH_REMOTE_URL"
HOOK = f"""#!/bin/sh
# Installed by tests/ci/prepush.py --install-hook; skip once with git push --no-verify.
top=$(git rev-parse --show-toplevel) || exit 0
[ -f "$top/tests/ci/prepush.py" ] || exit 0
pushed=
remote_refs=
while read -r _ local_sha remote_ref remote_sha; do
    case $local_sha in *[!0]*) pushed="$pushed $local_sha"; remote_refs="$remote_refs $remote_ref $remote_sha" ;; esac
done
[ -n "$pushed" ] || exit 0
{PUSHED}=$pushed
{REMOTE_REFS}=$remote_refs
{REMOTE_URL}=$2
export {PUSHED} {REMOTE_REFS} {REMOTE_URL}
exec python3 "$top/tests/ci/prepush.py" --quick
"""
PREVIOUS_HOOKS = ("""#!/bin/sh
# Installed by tests/ci/prepush.py --install-hook; skip once with git push --no-verify.
top=$(git rev-parse --show-toplevel) || exit 0
[ -f "$top/tests/ci/prepush.py" ] || exit 0
pushed=
while read -r _ local_sha _ _; do
    case $local_sha in *[!0]*) pushed="$pushed $local_sha" ;; esac
done
[ -n "$pushed" ] || exit 0
RUI_PREPUSH_PUSHED=$pushed
export RUI_PREPUSH_PUSHED
exec python3 "$top/tests/ci/prepush.py" --quick
""", """#!/bin/sh
# Installed by tests/ci/prepush.py --install-hook; skip once with git push --no-verify.
top=$(git rev-parse --show-toplevel) || exit 0
[ -f "$top/tests/ci/prepush.py" ] || exit 0
while read -r _ local_sha _ _; do
    case $local_sha in *[!0]*) exec python3 "$top/tests/ci/prepush.py" --quick ;; esac
done
""",)

STACK_FRAMES = ["zig", "build", "-j1", "stack-frames", "-Dcpu=baseline", "--summary", "line"]
RECEIPT = "rui-prepush-receipt.json"


def unit_compile():
    return [*build_artifact.compile_command(["test"], "unit", jobs=1), "--summary", "line"]


class Skipped(NamedTuple):
    reason: str


class NeedsMySQL(NamedTuple):
    command: list
    sqlite: bool


def red_record(name, command):
    if isinstance(command, NeedsMySQL):
        return {"name": name, "mysql": command.command, "sqlite": command.sqlite}
    if isinstance(command, Skipped):
        return {"name": name, "skipped": command.reason}
    return {"name": name, "command": command}


# Rui fixtures refuse root (tests/integration/host_process.py), and cloud machines push as root, so a
# replayed fixture runs at HEAD as the non-root lane user .agents/as-fixture-user creates.
FIXTURE_LANE = "prepush"


def as_fixture_user(command, euid=None):
    euid = os.geteuid() if euid is None else euid
    if euid != 0 or command[:3] != ["zig", "build", "-j1"] or command[3] not in FIXTURES:
        return command
    return [str(ROOT / fixture_user.COMMAND), FIXTURE_LANE, "--ref", "HEAD", "--", *command]


def local_red_checks(planned, mysql, euid=None):
    for name, command in planned:
        if not isinstance(command, NeedsMySQL):
            yield name, command if isinstance(command, Skipped) else as_fixture_user(command, euid)
        elif mysql:
            yield name, ["env", f"{live_engines.REQUIRE}=mysql", *command.command]
        else:
            if command.sqlite:
                unset = [arg for variable in live_engines.ENGINES["mysql"] for arg in ("-u", variable)]
                yield name + " (SQLite subset)", ["env", *unset, f"{live_engines.REQUIRE}=sqlite", *command.command]
            yield name + " (MySQL rounds)", Skipped("MySQL rounds not evaluated: no reachable configured local MySQL server")


def unit_target(targets, cause, graph, registry=None):
    # Logic cores are directly imported by the logic root, even when another binary reported them.
    if any(path in graph.cores for path in cause.paths):
        return "test-logic-only"
    registry = build_files.unit_roots() if registry is None else registry
    selected = set(targets)
    candidates = [root for root in registry if selected.intersection(root["owners"])]
    if cause.zig_binary:
        candidates = [root for root in candidates if cause.zig_binary in
                      (root["name"], root["name"] + "-" + Path(root["source"]).stem)]
    else:
        candidates = [root for root in candidates if not root.get("filtered_only")
                      and (not root.get("prefix") or cause.zig_test.startswith(root["prefix"]))
                      and (not root.get("exclude_prefix") or not cause.zig_test.startswith(root["exclude_prefix"]))
                      and (not root.get("filter") or root["filter"] in cause.zig_test)]
        exact = [root for root in candidates if root["source"] in cause.paths]
        candidates = exact or [root for root in candidates if any(
            path in graph.closure(graph.every, [root["source"]]) for path in cause.paths)]
    mapped = {root["target"] for root in candidates}
    return next(iter(mapped)) if len(mapped) == 1 else None


# check.yml's single ready-PR job and its compile and execution steps.
PR_JOB = "linux pr"
PR_COMPILE_STEP = "Compile only the binaries the selected targets need"
PR_RUN_STEP = "Run selected targets on SQLite, stopping at the first failure"


def red_command(job, cause, available, *, compile_targets=(), graph=None):
    name = job["name"]
    zig = ["zig", "build", "-j1"]
    if name == "macos_typecheck":
        return [*zig, "typecheck-macos", "--summary", "line"]
    if name.startswith("macos") or "macos" in name:
        return Skipped("native macOS check requires a macOS runner")
    if "upgrade" in name.lower():
        return Skipped("Upgrade requires an exclusive ordinary hosted runner UID")
    if name == "linux_build_unit":
        return unit_compile()
    if name == PR_JOB:
        # The single PR job logs its compile targets, then (when compile passes) its execution
        # targets; compile_targets holds those of the phase that failed.
        failed = {step["name"] for step in job.get("steps", ()) if step.get("conclusion") in ("failure", "cancelled")}
        if PR_COMPILE_STEP in failed:
            name = "linux_build"
        elif PR_RUN_STEP not in failed:
            compile_targets = ()
    if name == "linux_build":
        if not compile_targets or not set(compile_targets) <= available:
            return Skipped("producer's selected compile targets are unavailable in this checkout")
        return [*build_artifact.compile_command(compile_targets, jobs=1), "--summary", "line"]
    if name == PR_JOB:
        selected = tuple((target, "all") for target in compile_targets)
    else:
        selected = matrix_targets(name.partition("(")[2].removesuffix(")"))
    targets = [target for target, _ in selected]
    if cause.zig_test:
        graph = graph or tree_graph()
        target = unit_target(selected, cause, graph)
        if target is None:
            return Skipped("unit root is not uniquely registered for the failed binary/source and selected targets")
        if target not in available:
            return Skipped("the registered filtered target is unavailable in this checkout")
        if target == "test-pg":
            return Skipped("test-pg requires CI's live TLS Postgres server")
        if target == "mysql-wire-integration":
            return Skipped("mysql-wire-integration requires CI's live MySQL server")
        command = [*zig, target, f"-Dtest-filter={cause.zig_test}", "--summary", "line"]
        if target in ("test", "test-native", "test-store"):
            store = cause.zig_test.startswith("store.") or any(path.startswith("src/store/") for path in cause.paths)
            native_live = any(path in graph.live_conformance for path in cause.paths)
            if store or native_live:
                mysql_only = any(path in ("src/store/mysql_dialect_check.zig", "src/store/mysql_testing.zig", "src/store/mysql_session_tests.zig") for path in cause.paths)
                sqlite_only = cause.paths and all(path == "src/store/sqlite_tests.zig" or path.startswith("src/store/sqlite_tests/") for path in cause.paths)
                if not sqlite_only:
                    return NeedsMySQL(command, not mysql_only)
            elif not cause.paths:
                return Skipped("test source is ambiguous, so its live-engine requirements are unknown")
        return command
    if cause.python_test:
        module, _, test = cause.python_test.partition(".")
        if f"tests/ci/{module}.py" not in cause.paths:
            return Skipped("unittest is not a tests/ci module")
        return ["env", f"PYTHONPATH={ROOT / 'tests/integration'}", sys.executable, "-B", "-m", "unittest",
                "discover", "-s", "tests/ci", "-p", f"{module}.py", "-k", test]
    candidates = {target for target, (scripts, _, _) in FIXTURES.items()
                  if target in available and any(path in scripts for path in cause.paths)}
    selected = candidates.intersection(targets)
    if len(selected) == 1:
        candidates = selected
    elif any(target in ("check", "check-full") for target in targets):
        candidates = {target for target in candidates if "-debug-" not in target}
    if len(candidates) != 1:
        return Skipped("cause unexplained or fixture target ambiguous in this checkout")
    target = next(iter(candidates))
    if target == "upgrade-integration":
        return Skipped("Upgrade requires an exclusive ordinary hosted runner UID")
    if target in (graph or tree_graph()).live_mysql or any("mysql" in path for path in cause.paths):
        return Skipped("fixture requires CI's live MySQL server")
    return [*zig, target, "--summary", "line"]


def red_revision():
    digest = hashlib.sha256()
    for path in ("prepush.py", "report_issue.py", "failure_cause.py", "select_tests.py", "build_files.py", "qualification.py"):
        digest.update((Path(__file__).parent / path).read_bytes())
    digest.update(build_files.source(ROOT).encode())
    digest.update((ROOT / "src/unit_test_partition.zig").read_bytes())
    for path in sorted((ROOT / "tests/integration").glob("*.py")):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    digest.update((ROOT / "tests/integration/check.sh").read_bytes())
    graph = tree_graph()
    digest.update(json.dumps({target: sorted(reached) for target, reached in graph.reached.items()}, sort_keys=True).encode())
    digest.update(json.dumps({path: sorted(imports) for path, imports in graph.every.items()}, sort_keys=True).encode())
    digest.update(json.dumps(sorted(graph.live_mysql)).encode())
    digest.update(json.dumps(sorted(graph.live_conformance)).encode())
    digest.update(str((ROOT, sys.executable, sys.platform)).encode())
    return digest.hexdigest()


def previous_red(available, euid=None):
    try:
        repository = repo_from_remote(os.environ.get(REMOTE_URL) or git("remote", "get-url", "origin"))
        refs = os.environ.get(REMOTE_REFS, "").split()
        if refs:
            destinations = list(zip(refs[::2], refs[1::2]))
        else:
            branch = git("branch", "--show-current")
            if not branch or branch == "main":
                raise ValueError("no pushed feature branch")
            ref = "refs/heads/" + branch
            head = json.loads(report_issue.gh("api", f"repos/{repository}/git/ref/heads/{quote(branch, safe='/')}"))["object"]["sha"]
            destinations = [(ref, head)]
        identities, planned = [], []
        revision = red_revision()
        for ref, head in destinations:
            try:
                identity, derived = remote_red(repository, ref, head, revision, available)
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
                red_warning(error)
                identities.append(None)
                continue
            identities.append(identity)
            planned.extend(derived)
        needs_mysql = any(isinstance(command, NeedsMySQL) for _, command in planned)
        if needs_mysql:
            environment = [os.environ.get(variable) for variable in live_engines.VARIABLES]
            identities.append(hashlib.sha256(json.dumps(environment).encode()).hexdigest())
        planned = list(local_red_checks(planned, needs_mysql and mysql_reachable(os.environ), euid))
        return identities if any(identity is not None for identity in identities) else None, planned
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        red_warning(error)
        return None, []


def red_warning(error):
    reason = "gh is unavailable" if isinstance(error, FileNotFoundError) and error.filename == "gh" else str(error).split("\n")[0]
    print(f"prepush: last CI red not evaluated: {reason}", file=sys.stderr, flush=True)


def remote_red(repository, ref, head, revision, available):
    if not ref.startswith("refs/heads/") or ref == "refs/heads/main" or not head.strip("0"):
        raise ValueError("no previous feature-branch head")
    pages = json.loads(report_issue.gh("api", "--paginate", "--slurp",
        f"repos/{repository}/actions/runs?head_sha={head}&status=completed&per_page=100"))
    runs = [run for page in pages for run in page["workflow_runs"]
            if run["name"] == "Selected checks" and run["path"].split("@", 1)[0] == ".github/workflows/check.yml"
            and run["head_sha"] == head and run["head_branch"] == ref.removeprefix("refs/heads/")
            and run["status"] == "completed"]
    if not runs:
        raise ValueError("no completed Selected checks run on the remote head")
    latest = max(runs, key=lambda run: run["id"])
    identity = [repository, ref, head, latest["id"], latest["run_attempt"], latest["conclusion"], revision]
    if latest["conclusion"] == "success":
        return identity, []
    cache = Path(git("rev-parse", "--path-format=absolute", "--git-path", "rui-prepush-red"))
    cache_file = cache / f"{latest['id']}-{latest['run_attempt']}.json"
    try:
        saved = json.loads(cache_file.read_text())
    except (OSError, ValueError):
        saved = {}
    if saved.get("identity") == identity:
        return identity, [(item["name"], NeedsMySQL(item["mysql"], item["sqlite"]) if "mysql" in item
                          else Skipped(item["skipped"]) if "skipped" in item else item["command"])
                          for item in saved["checks"]]
    derived, logs = [], {}
    def log_of(job):
        if job["id"] not in logs:
            with redirect_stdout(sys.stderr):
                logs[job["id"]] = report_issue.job_log(repository, job["id"])
        return logs[job["id"]]
    jobs = report_issue.run_jobs(repository, latest["id"], latest["run_attempt"])
    classified = failure_cause.causes(jobs, lambda job: failure_cause.annotations(repository, job), log_of)
    failed = {name for name, kind, _ in classified if kind == "check"}
    for job in jobs:
        if job["name"] not in failed:
            continue
        log = log_of(job)
        causes = report_issue.failure_causes(log, report_issue.fixtures(ROOT / "tests/integration/check.sh"),
                                             keep_unexplained=True) if log is not None else []
        causes = causes or [report_issue.Cause(f"{job['name']}: cause unexplained")]
        targets = (report_issue.compile_targets(log)
                   if log is not None and job["name"] in ("linux_build", PR_JOB) else ())
        for cause in causes:
            command = red_command(job, cause, available, compile_targets=targets) if log is not None else Skipped("job log unavailable")
            item = (f"last CI red: {cause.signature}", command)
            if item not in derived:
                derived.append(item)
    if all(log is not None for log in logs.values()):
        cache.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps({"identity": identity, "checks": [red_record(name, command) for name, command in derived]}))
    return identity, derived


def checks(paths, available, base, mode="default", mysql=False):
    paths = sorted(set(paths))
    if not paths:
        return
    existing = [path for path in paths if (ROOT / path).is_file()]
    build_paths = [path for path in paths if not path.startswith("clients/ts/")]
    development = select(build_paths, "development", available)
    targets = [target for target in development["targets"]
               if target not in development["server_targets"] and target != "upgrade-integration"]
    yield "whitespace", [sys.executable, "-B", "tests/ci/prepush.py", "--fix-whitespace", base]
    zig = [path for path in existing if path.endswith(".zig")]
    if zig:
        yield "zig fmt", ["zig", "fmt", "--check", "--ast-check", *zig]
    if any(inventory_path(path) for path in paths):
        yield "caller errors", [sys.executable, "-B", "tests/ci/caller_errors.py"]
    if any(path.endswith(".zig")
           or (path.startswith("tests/") and path.endswith(".py"))
           or (path.startswith("clients/ts/test/") and path.endswith(".test.ts"))
           or path == "tests/ci/flake_sources.json" for path in paths):
        yield "flake sources", [sys.executable, "-B", "tests/ci/flake_sources.py"]
    if any(matches(path, CLIENT_LOCALITY_INPUTS) for path in paths):
        yield "client locality", [sys.executable, "-B", "tests/ci/client_locality.py"]
    if "src/store/schema.zig" in paths:
        yield "schema number", [sys.executable, "-B", "tests/ci/schema_number.py", "--check"]
    generation = {"openapi.json", *GENERATED[1:], "clients/ts/scripts/generate-settings.mjs"}
    if any(path.startswith("src/") for path in paths):
        graph = tree_graph()
        generation |= graph.closure(graph.production, ["src/openapi_main.zig"])
        if graph.cores.intersection(paths):
            yield "core boundary", ["zig", "build", "-j1", "test-logic-only",
                                    "-Dtest-filter=functional cores stay within the core boundary"]
    if generation.intersection(paths):
        yield "generated files", [sys.executable, "-B", "tests/ci/prepush.py", "--regenerate"]
    pythonpath = os.pathsep.join(filter(None, (str(ROOT / "tests/integration"), os.environ.get("PYTHONPATH"))))
    unittest = ["env", f"PYTHONPATH={pythonpath}", sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/ci"]
    if mode == "full":
        skips = select(paths, "development", available)["policy_skips"]
        yield "tests/ci (CI policy suite)", ["env", f"PYTHONPATH={pythonpath}", sys.executable, "-B",
                                             "tests/ci/policy_suite.py", "--skips", json.dumps(skips)]
    else:
        for module, filters in sorted(policy_tests(paths).items()):
            command = [*unittest, "-p", module]
            if "*" not in filters:
                for test in sorted(filters):
                    command.extend(["-k", test])
            yield f"tests/ci: {module}", command
    python = [path for path in existing if path.endswith(".py")]
    if python:
        yield "undefined Python names", [sys.executable, "-m", "ruff", "check", "--select", "F821", *python]
    if mode == "full" and any(path == "openapi.json" or path.startswith("clients/ts/") and not path.endswith(".md") for path in paths):
        yield "TypeScript client", ["npm", "--prefix", "clients/ts", "run", "check"]
    if any(not path.endswith(".md") for path in paths):
        deferred = sorted(set(development["targets"]) | set(development["server_targets"]))
        reason = "Selected hosted acceptance is not evaluated by local feedback"
        if deferred:
            reason += ": " + " ".join(deferred)
        if "upgrade-integration" in deferred:
            reason += "; upgrade-integration needs an exclusive ordinary hosted runner UID"
        yield "hosted acceptance", Skipped(reason)
    if mode != "full":
        return
    if targets:
        yield "development selection", ["zig", "build", *targets, "--summary", "line"]
    zig_inputs = [path for path in paths if path.endswith((".zig", ".zon"))]
    if zig_inputs and select(zig_inputs, "review", available)["targets"]:
        yield "macOS type check", ["zig", "build", "typecheck-macos", "--summary", "line"]
    if mode == "full":
        yield "unfiltered unit compile", unit_compile()
    yield "stack frames", STACK_FRAMES
    reads_mysql = LIVE_MYSQL_DIALECT_TARGETS | set(development["mysql_suites"])
    live = sorted({root for root, _ in development["live_needs"] if root in reads_mysql})
    if live and mysql:
        yield "live MySQL", ["env", f"{live_engines.REQUIRE}=mysql", "zig", "build", *live, "--summary", "line"]
    elif live:
        yield "live MySQL", Skipped(f"no reachable MySQL in {live_engines.MYSQL_SOCKET} and "
                                    f"{live_engines.MYSQL_ROOT_PASSWORD}, so CI runs {' '.join(live)}")
    left = [f"{reason} ({root or 'no target runs only these tests'})"
            for root, reason in development["live_needs"] if root not in reads_mysql]
    if left:
        yield "live, CI only", Skipped("; ".join(left) + ": CI runs it")


def mysql_reachable(environ):
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


def receipt_path():
    return Path(git("rev-parse", "--path-format=absolute", "--git-path", RECEIPT))


def clean_tree():
    return None if git("status", "--porcelain", "--untracked-files=all") else git("rev-parse", "HEAD^{tree}")


def read_receipt():
    try:
        return json.loads(receipt_path().read_text())
    except (OSError, ValueError):
        return None


def pushed_key(sha, ref):
    base = subprocess.run(["git", "merge-base", sha, ref], cwd=ROOT, capture_output=True, text=True)
    return None if base.returncode else (git("rev-parse", f"{sha}^{{tree}}"), base.stdout.strip())


def receipt_covers(receipt, pushes):
    if receipt is None or receipt.get("tree") is None or set(pushes) != {(receipt["tree"], receipt.get("base"))}:
        return False
    ran = [result for result in receipt["results"] if "skipped" not in result]
    return bool(ran) and all(result.get("exit") == 0 for result in ran)


def run(planned, mode, base, red=None):
    before = clean_tree()
    results = []
    for name, command in planned:
        if isinstance(command, Skipped):
            print(f"== {name}: skipped: {command.reason}", flush=True)
            results.append({"name": name, "skipped": command.reason})
            continue
        print(f"== {name}: {' '.join(command)}", flush=True)
        code = subprocess.run(command, cwd=ROOT).returncode
        # Local feedback only cleans: another worktree's run under this uid may own a leak. CI fails it.
        if removed := runtime_leftovers.sweep():
            print(f"Removed {len(removed)} leftover Host sockets whose Store no longer exists: "
                  f"{runtime_leftovers.describe(removed)}", flush=True)
        results.append({"name": name, "command": command, "exit": code})
    tree = before if clean_tree() == before else None
    path = receipt_path()
    path.write_text(json.dumps({"tree": tree, "base": base, "mode": mode, "scope": "local-feedback", "red": red, "results": results}, indent=2) + "\n")
    if tree is None:
        print(f"The working tree differs from HEAD, so {path} matches no push.")
    return results


def fix_whitespace(base):
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
    if subprocess.run(["zig", "build", "-j1", "openapi", "--summary", "none"], cwd=ROOT).returncode:
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
    modes.add_argument("--quick", action="store_true", help="alias for default cheap feedback, used by installed hooks")
    modes.add_argument("--full", action="store_true", help="also run the CI policy suite, compile the unit binaries unfiltered, run stack-frames "
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
    available = set(build_files.steps())
    red, red_checks = previous_red(available)
    if red is not None:
        red = {"runs": red, "checks": [
            {"name": name, "skipped": command.reason} if isinstance(command, Skipped)
            else {"name": name, "command": command} for name, command in red_checks]}
    if pushed:
        receipt = read_receipt()
        if receipt_covers(receipt, [pushed_key(sha, args.base) for sha in pushed]) and receipt.get("red") == red:
            print(f"prepush: local feedback from the {receipt['mode']} run on tree {receipt['tree']} against {receipt['base']} passed; "
                  "not running it again. Hosted acceptance was not evaluated.")
            for result in receipt["results"]:
                if "skipped" in result:
                    print(f"== {result['name']}: skipped: {result['skipped']}")
            raise SystemExit(0)
    base = git("merge-base", "HEAD", args.base)
    paths, _ = changed_paths(base, "HEAD")
    planned = list(checks(paths, available, base, mode,
                          mode == "full" and mysql_reachable(os.environ))) + red_checks
    if args.plan:
        print(json.dumps({"base": base, "paths": paths, "checks": [
            {"name": name, "skipped": command.reason} if isinstance(command, Skipped) else {"name": name, "command": command}
            for name, command in planned]}, indent=2))
        raise SystemExit(0)
    print("Local feedback only. Hosted acceptance is not evaluated.", flush=True)
    results = run(planned, mode, base, red)
    failed = [result["name"] for result in results if result.get("exit")]
    print(json.dumps({"failed": failed, "skipped": [result["name"] for result in results if "skipped" in result]}))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    fixture_user.reexec_pinned(sys.argv)
    main()
