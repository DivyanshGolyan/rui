from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import build_files
import build_artifact
import prepush
import report_issue

ROOT = prepush.ROOT
AVAILABLE = set(build_files.steps())
HEAD = "a" * 40
RUN = dict(id=42, run_attempt=1, name="Selected checks", path=".github/workflows/check.yml",
           head_sha=HEAD, head_branch="feature/red", status="completed", conclusion="failure")


def job(name="linux suites (test-store)", number=7, **values):
    return dict(id=number, name=name, status="completed", conclusion="failure", steps=[dict(
        name="Run selected targets", conclusion="failure")], **values)


class PreviousRedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.responses = self.directory / "responses.json"
        self.calls = self.directory / "calls"
        fake = self.directory / "gh"
        fake.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['GATE_CALLS'], 'a') as output:
    output.write(json.dumps(args) + '\\n')
data = json.loads(Path(os.environ['GATE_RESPONSES']).read_text())
endpoint = next(arg for arg in args if arg.startswith('repos/'))
if endpoint not in data:
    print('fake gh has no response for ' + endpoint, file=sys.stderr)
    sys.exit(1)
value = data[endpoint]
if value is None:
    sys.exit(1)
print(value if isinstance(value, str) else json.dumps(value))
''')
        fake.chmod(0o755)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
            "GATE_CALLS": str(self.calls), "GATE_RESPONSES": str(self.responses),
            prepush.REMOTE_REFS: "refs/heads/feature/red " + HEAD,
            prepush.REMOTE_URL: "https://github.com/owner/repo.git"}).start()
        patch.object(prepush, "git", side_effect=lambda *args: str(self.directory / "cache")).start()
        patch.object(report_issue, "LOG_RETRY_DELAYS", ()).start()
        self.mysql = patch.object(prepush, "mysql_reachable", return_value=False).start()
        self.data = {}
        self.configure()

    def configure(self, run=None, jobs=None, log=""):
        run = RUN if run is None else run
        jobs = [job()] if jobs is None else jobs
        self.data = {
            f"repos/owner/repo/actions/runs?head_sha={HEAD}&status=completed&per_page=100": [dict(workflow_runs=[run])],
            f"repos/owner/repo/actions/runs/42/attempts/{run['run_attempt']}/jobs?per_page=100": [dict(jobs=jobs)],
        }
        for item in jobs:
            self.data[f"repos/owner/repo/check-runs/{item['id']}/annotations"] = []
            self.data[f"repos/owner/repo/actions/jobs/{item['id']}/logs"] = log
        self.responses.write_text(json.dumps(self.data))

    def plan(self):
        with redirect_stderr(io.StringIO()) as warning:
            identity, checks = prepush.previous_red(AVAILABLE)
        return identity, checks, warning.getvalue()

    def test_green_and_cancelled_before_steps_have_no_checks(self):
        for conclusion in ("success", "cancelled"):
            with self.subTest(conclusion=conclusion):
                self.configure(run=dict(RUN, conclusion=conclusion), jobs=[] if conclusion == "cancelled" else [job()])
                identity, checks, warning = self.plan()
                self.assertEqual(checks, [])
                self.assertTrue(identity)
                self.assertEqual(warning, "")
                if conclusion == "success":
                    self.assertNotIn("/jobs?", self.calls.read_text())

    def test_zig_crash_and_fail_are_filtered_and_cached_for_second_push(self):
        self.configure(log="error: 'store.tests.test.queued input is pending' failed\n"
                       "1/2 store.tests.test.ending migration...FAIL (TestUnexpectedResult)\n")
        identity, checks, warning = self.plan()
        self.assertEqual(warning, "")
        commands = [command for _, command in checks if not isinstance(command, prepush.Skipped)]
        self.assertEqual(len(commands), 2)
        self.assertEqual(sum(isinstance(command, prepush.Skipped) for _, command in checks), 2)
        for command, test in zip(commands, ("queued input is pending", "ending migration")):
            start = command.index("zig")
            self.assertEqual(command[start:start + 4], ["zig", "build", "-j1", "test-store"])
            self.assertIn(f"-Dtest-filter=store.tests.test.{test}", command)
        before = self.calls.read_text().splitlines()
        self.assertEqual(self.plan()[:2], (identity, checks))
        after = self.calls.read_text().splitlines()[len(before):]
        self.assertEqual(len(after), 1, "second push only queries the latest run, never jobs or logs")
        self.assertIn("actions/runs?head_sha", after[0])

    def test_fixture_record_uses_own_target(self):
        self.configure(jobs=[job("linux suites (check)")], log='''request-wait failed: exit=1
Traceback (most recent call last):
  File "/repo/tests/integration/request_wait_integration.py", line 23, in main
    assert done
AssertionError
''')
        _, checks, _ = self.plan()
        self.assertEqual(len(checks), 1)
        self.assertEqual(checks[0][1], ["zig", "build", "-j1", "request-wait-integration", "--summary", "line"])

    def test_replayed_fixtures_run_as_the_lane_user_only_under_root(self):
        fixture = ["zig", "build", "-j1", "request-wait-integration", "--summary", "line"]
        unit = ["zig", "build", "-j1", "test-store", "-Dtest-filter=x", "--summary", "line"]
        policy = ["env", "PYTHONPATH=x", sys.executable, "-B", "-m", "unittest"]
        wrapped = [str(ROOT / ".agents/as-fixture-user"), "prepush", "--ref", "HEAD", "--", *fixture]
        for euid, command, expected in ((0, fixture, wrapped), (1000, fixture, fixture), (0, unit, unit),
                                        (1000, unit, unit), (0, policy, policy)):
            with self.subTest(euid=euid, command=command[3]):
                self.assertEqual(prepush.as_fixture_user(command, euid), expected)
        skipped = prepush.Skipped("macOS")
        mysql = prepush.NeedsMySQL(unit, True)
        checks = list(prepush.local_red_checks([("fixture", fixture), ("skip", skipped), ("store", mysql)], False, euid=0))
        self.assertEqual(checks[0], ("fixture", wrapped))
        self.assertIs(checks[1][1], skipped)
        self.assertEqual(checks[2][1][-len(unit):], unit)

    def test_compile_jobs_use_known_commands(self):
        for name, command in (("linux_build_unit", prepush.unit_compile()),
                              ("linux_build", [*build_artifact.compile_command(["request-wait-integration"], jobs=1), "--summary", "line"]),
                              ("macos_typecheck", ["zig", "build", "-j1", "typecheck-macos", "--summary", "line"])):
            with self.subTest(job=name):
                self.configure(run=dict(RUN, run_attempt=len(name)), jobs=[job(name)], log="src/foo.zig:1: error: no field\nzig build ci-build -Dci-targets=request-wait-integration -Dci-part=rest failed with exit 1; no gates executed.\n")
                self.assertEqual(self.plan()[1][0][1], command)

    def test_single_pr_job_reruns_the_failed_phase_with_its_logged_targets(self):
        def pr_job(step):
            failed = job("linux pr")
            failed["steps"] = [dict(name="Policy checks", conclusion="success"),
                               dict(name="Compile only the binaries the selected targets need",
                                    conclusion="failure" if step == "compile" else "success"),
                               dict(name="Run selected targets on SQLite, stopping at the first failure",
                                    conclusion="failure" if step == "run" else "skipped" if step == "compile" else "success"),
                               dict(name="Fail for the policy or format checks that failed above",
                                    conclusion="failure" if step == "policy" else "skipped")]
            return failed

        compile_env = 'env:\n  TARGETS: ["test-store","request-wait-integration","test-logic"]\n'
        run_env = 'env:\n  TARGETS: ["test-store","request-wait-integration"]\n  QUARANTINE: admission\n'
        cases = (
            ("compile", compile_env + "src/foo.zig:1: error: no field\n"
             "zig build ci-build -Dci-targets=test-store,request-wait-integration,test-logic -Dci-part=all failed "
             "with exit 1; no gates executed.\n",
             [*build_artifact.compile_command(["test-store", "request-wait-integration", "test-logic"], jobs=1),
              "--summary", "line"]),
            ("run", compile_env + run_env + "error: 'store.tests.test.queued input is pending' failed\n",
             ["zig", "build", "-j1", "test-store", "-Dtest-filter=store.tests.test.queued input is pending",
              "--summary", "line"]),
            ("run", compile_env + run_env + '''request-wait failed: exit=1
Traceback (most recent call last):
  File "/repo/tests/integration/request_wait_integration.py", line 23, in main
    assert done
AssertionError
''', ["zig", "build", "-j1", "request-wait-integration", "--summary", "line"]),
        )
        for attempt, (step, log, expected) in enumerate(cases, 1):
            with self.subTest(step=step, expected=expected):
                self.configure(run=dict(RUN, run_attempt=attempt), jobs=[pr_job(step)], log=log)
                command = self.plan()[1][0][1]
                if isinstance(command, prepush.NeedsMySQL):
                    command = command.command
                self.assertNotIsInstance(command, prepush.Skipped)
                self.assertEqual(command[command.index("zig"):], expected)
        self.configure(run=dict(RUN, run_attempt=9), jobs=[pr_job("policy")],
                       log=compile_env + run_env + "error: 'store.tests.test.queued input is pending' failed\n")
        self.assertIsInstance(self.plan()[1][0][1], prepush.Skipped,
                              "a unit failure outside the run step cannot borrow the run step's targets")

    def test_policy_unittest_uses_module_and_test_filter(self):
        self.configure(jobs=[job("policy")], log="FAIL: test_empty_diff_runs_nothing (test_prepush.PrepushTest.test_empty_diff_runs_nothing)\n"
                       + "-" * 70 + "\nTraceback (most recent call last):\n"
                       '  File "/repo/tests/ci/test_prepush.py", line 2, in test_empty_diff_runs_nothing\n'
                       "    assert False\nAssertionError\n" + "=" * 70 + "\n")
        command = self.plan()[1][0][1]
        self.assertEqual(command[-4:], ["-p", "test_prepush.py", "-k", "PrepushTest.test_empty_diff_runs_nothing"])

    def test_infrastructure_and_aggregates_have_no_checks(self):
        queued = job("linux suites (check)")
        queued.update(status="queued", conclusion=None, steps=[])
        self.configure(jobs=[queued, job("linux", 8), job("admission", 9)])
        self.assertEqual(self.plan()[1], [])

    def test_native_mac_and_unknown_cause_are_skipped_without_a_pass(self):
        self.configure(jobs=[job("macos suites (native)")], log="error: 'store.test.foo' failed\n")
        _, checks, _ = self.plan()
        self.assertIsInstance(checks[0][1], prepush.Skipped)
        self.assertIn("macOS", checks[0][1].reason)
        receipt = self.directory / "receipt"
        with patch.object(prepush, "receipt_path", return_value=receipt), patch.object(prepush, "clean_tree", return_value="tree"), redirect_stdout(io.StringIO()):
            results = prepush.run(checks, "quick", "base")
        self.assertNotIn("exit", results[0])
        self.assertFalse(prepush.receipt_covers(json.loads(receipt.read_text()), [("tree", "base")]))

    def test_missing_gh_and_network_failure_warn_without_blocking(self):
        for error in (FileNotFoundError(2, "No such file", "gh"), subprocess.CalledProcessError(1, ["gh", "api"])):
            with self.subTest(error=error), patch.object(report_issue, "gh", side_effect=error):
                identity, checks, warning = self.plan()
                self.assertIsNone(identity)
                self.assertEqual(checks, [])
                self.assertIn("last CI red not evaluated", warning)

    def test_only_latest_completed_run_on_exact_remote_head_is_used(self):
        endpoint = next(iter(self.data))
        self.data[endpoint] = [dict(workflow_runs=[dict(RUN, id=41), dict(RUN, conclusion="success"),
            dict(RUN, id=99, head_sha="b" * 40), dict(RUN, id=100, head_branch="other"),
            dict(RUN, id=101, status="in_progress"), dict(RUN, id=102, path=".github/workflows/other.yml")])]
        self.responses.write_text(json.dumps(self.data))
        self.assertEqual(self.plan()[1], [])
        self.data[endpoint] = [dict(workflow_runs=[])]
        self.responses.write_text(json.dumps(self.data))
        self.assertIn("no completed", self.plan()[2])

    def test_attempt_and_mapper_revision_invalidate_cached_commands(self):
        self.configure(log="error: 'store.test.foo' failed\n")
        first = self.plan()
        self.configure(run=dict(RUN, run_attempt=2), log="error: 'store.test.bar' failed\n")
        second = self.plan()
        self.assertNotEqual(first[0], second[0])
        self.assertIn("bar", second[1][0][0])
        self.configure(run=dict(RUN, run_attempt=2), log="error: 'store.test.baz' failed\n")
        with patch.object(prepush, "red_revision", return_value="changed mapper"):
            third = self.plan()
        self.assertNotEqual(second[0], third[0])
        self.assertIn("baz", third[1][0][0])

    def test_unavailable_logs_are_skipped_and_retried_next_push(self):
        self.configure(log=None)
        with redirect_stdout(io.StringIO()):
            _, checks, _ = self.plan()
        self.assertIsInstance(checks[0][1], prepush.Skipped)
        self.configure(log="error: 'store.test.recovered' failed\n")
        self.assertIn("-Dtest-filter=store.test.recovered", self.plan()[1][0][1])

    def test_unexplained_record_stays_visible_beside_parsed_failure(self):
        self.configure(log="error: 'store.test.foo' failed\nunknown-case failed: exit=1\n")
        checks = self.plan()[1]
        self.assertEqual(len(checks), 3)
        self.assertIsInstance(checks[-1][1], prepush.Skipped)

    def test_packed_unit_jobs_rerun_the_named_test(self):
        for matrix, target in (("test-native+test-store", "test-store"), ("test-store+test-logic", "test-store")):
            with self.subTest(matrix=matrix):
                cause = report_issue.Cause("store failed", paths=["src/store.zig"], zig_test="store.tests.test.foo")
                command = prepush.red_command(job(f"linux suites ({matrix})"), cause, AVAILABLE)
                self.assertIsInstance(command, prepush.NeedsMySQL)
                self.assertEqual(command.command[3], target)
                self.assertIn("-Dtest-filter=store.tests.test.foo", command.command)

    def test_ambiguous_live_root_cannot_be_replaced_by_local_subset(self):
        cause = report_issue.Cause("TLS failed", paths=["src/tls_client/tls_client.zig"], zig_test="tls.test.foo")
        for matrix in ("test-native+test-pg", "test-pg+test-native"):
            self.assertIsInstance(prepush.red_command(job(f"linux suites ({matrix})"), cause, AVAILABLE), prepush.Skipped)

    def test_cancelled_test_step_is_classified_and_rerun(self):
        cancelled = job()
        cancelled.update(conclusion="cancelled", steps=[dict(name="Run selected targets", conclusion="cancelled")])
        self.configure(run=dict(RUN, conclusion="cancelled"), jobs=[cancelled], log="error: 'store.test.foo' failed\n")
        self.assertIn("-Dtest-filter=store.test.foo", self.plan()[1][0][1])

    def test_compile_without_selected_targets_is_skipped(self):
        self.configure(jobs=[job("linux_build")], log="src/cli.zig:2: error: no field\n")
        self.assertIsInstance(self.plan()[1][0][1], prepush.Skipped)

    def test_new_second_ref_does_not_discard_first_refs_red_checks(self):
        self.configure(log="error: 'store.test.foo' failed\n")
        with patch.dict(os.environ, {prepush.REMOTE_REFS: f"refs/heads/feature/red {HEAD} refs/heads/new {'0' * 40}"}):
            identity, checks, warning = self.plan()
        self.assertIn(None, identity)
        self.assertEqual(len(checks), 2)
        self.assertIn("no previous", warning)

    def test_standalone_lookup_uses_remote_head_not_local_head(self):
        self.data["repos/owner/repo/git/ref/heads/feature/red"] = {"object": {"sha": HEAD}}
        self.responses.write_text(json.dumps(self.data))
        with patch.dict(os.environ, {prepush.REMOTE_REFS: ""}), patch.object(prepush, "git", side_effect=lambda *args:
                "feature/red" if args[0] == "branch" else str(self.directory / "cache")):
            self.assertTrue(self.plan()[0])
        self.assertIn("git/ref/heads/feature/red", self.calls.read_text())

    def test_default_quick_plan_and_receipts_include_red_and_reject_failures(self):
        self.configure(log="error: 'store.test.foo' failed\n")
        receipt_path = self.directory / "receipt"
        actual_run = subprocess.run
        commands = []
        def execute(command, **kwargs):
            if command[0] == "gh":
                return actual_run(command, **kwargs)
            commands.append(command)
            return subprocess.CompletedProcess(command, 1)
        for mode in ([], ["--quick"]):
            with self.subTest(mode=mode), patch.object(prepush, "changed_paths", return_value=([], "base")), \
                    patch.object(prepush, "clean_tree", return_value="tree"), \
                    patch.object(prepush, "receipt_path", return_value=receipt_path), \
                    patch.object(prepush.subprocess, "run", side_effect=execute), \
                    patch("sys.argv", ["prepush.py", *mode]), redirect_stdout(io.StringIO()), \
                    self.assertRaises(SystemExit) as result:
                prepush.main()
            self.assertEqual(result.exception.code, 1)
            self.assertEqual(len(commands), 1)
            commands.clear()
            receipt = json.loads(receipt_path.read_text())
            self.assertEqual(receipt["results"][0]["exit"], 1)
            self.assertTrue(receipt["red"]["runs"])
        with patch.object(prepush, "changed_paths", return_value=([], "base")), \
                patch("sys.argv", ["prepush.py", "--plan"]), redirect_stdout(io.StringIO()) as out:
            with self.assertRaises(SystemExit) as result:
                prepush.main()
        self.assertEqual(result.exception.code, 0)
        self.assertIn("-Dtest-filter=store.test.foo", json.loads(out.getvalue())["checks"][0]["command"])

    def test_new_red_invalidates_a_previously_green_receipt(self):
        receipt_path = self.directory / "receipt"
        environ = {prepush.PUSHED: HEAD}
        actual_run = subprocess.run
        commands = []
        def execute(command, **kwargs):
            if command[0] == "gh":
                return actual_run(command, **kwargs)
            commands.append(command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(prepush, "changed_paths", return_value=([], "base")), \
                patch.object(prepush, "clean_tree", return_value="tree"), \
                patch.object(prepush, "receipt_path", return_value=receipt_path), \
                patch.object(prepush, "pushed_key", return_value=("tree", str(self.directory / "cache"))), \
                patch.object(prepush.subprocess, "run", side_effect=execute), \
                patch.object(prepush, "checks", return_value=[("probe", ["true"])]), redirect_stdout(io.StringIO()):
            for conclusion, calls in (("success", 1), ("failure", 3), ("failure", 3)):
                self.configure(run=dict(RUN, conclusion=conclusion), log="error: 'store.test.foo' failed\n")
                with patch.dict(os.environ, environ), patch("sys.argv", ["prepush.py", "--quick"]), \
                        self.assertRaises(SystemExit) as result:
                    prepush.main()
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(len(commands), calls)

    def test_composed_and_packed_parts_preserve_each_failed_binary(self):
        roots = (("unit-native-tests", "codex_auth.test.refresh", "test-native"),
                 ("test-h2", "tests.test.a read cap defers expiry only for streams on that connection", "test-h2"),
                 ("test-pg", "pg.test.live query", None))
        for matrix in ("check", "check-full", "full-execution", "check+test-logic", "test-native+test-store+test-h2+test-pg"):
            for index, (binary, test, target) in enumerate(roots):
                with self.subTest(matrix=matrix, binary=binary):
                    self.configure(jobs=[job(f"linux suites ({matrix})")], run=dict(RUN, run_attempt=len(matrix) * 10 + index),
                                   log=f"error: '{test}' failed\nfailed command: ./.zig-cache/o/ci-compiled/{binary} --listen=-\n")
                    checks = self.plan()[1]
                    commands = [command for _, command in checks if not isinstance(command, prepush.Skipped)]
                    if target is None:
                        self.assertFalse(commands)
                        self.assertIn("Postgres", checks[0][1].reason)
                    else:
                        self.assertEqual(len(commands), 1)
                        start = commands[0].index("zig")
                        self.assertEqual(commands[0][start + 3], target)
                        self.assertIn(f"-Dtest-filter={test}", commands[0])
        for binary, test, _ in roots:
            cause = report_issue.Cause("a red", zig_test=test, zig_binary=binary)
            self.assertIsInstance(prepush.red_command(job("linux suites (full-callers)"), cause, AVAILABLE), prepush.Skipped)

    def test_ci_40_logic_core_replay_uses_its_owner_for_each_reporting_binary(self):
        graph = prepush.tree_graph()
        cases = (
            ("src/host_reply.zig", "host_reply.test.every reply renders its exact worst-case bound from the shape it writes",
             ("test-logic_tests", "unit-native-tests", ""), "test-logic-only"),
            ("src/ActivityBlock.zig", "ActivityBlock.test.a narrow or short activity tail keeps the clock and the oldest calls",
             ("unit-native-tests", ""), "test-native"),
        )
        pr = job("linux pr")
        pr["steps"] = [dict(name=prepush.PR_RUN_STEP, conclusion="failure")]
        for path, test, binaries, target in cases:
            for binary in binaries:
                with self.subTest(path=path, binary=binary):
                    cause = report_issue.Cause("failure", [path], zig_test=test, zig_binary=binary)
                    self.assertEqual(prepush.red_command(pr, cause, AVAILABLE, graph=graph,
                                                       compile_targets=("test-logic", "test-native")),
                                     ["zig", "build", "-j1", target, f"-Dtest-filter={test}", "--summary", "line"])

    def test_mysql_only_and_conformance_rounds_are_explicit_in_every_unit_target(self):
        mixed = report_issue.Cause("mixed", ["src/store/tests/activity.zig"], zig_test="store.tests.activity.test.queued input")
        mysql_only = report_issue.Cause("mysql only", ["src/store/mysql_dialect_check.zig"], zig_test="store.mysql_dialect_check.test.migration")
        sqlite_only = report_issue.Cause("sqlite only", ["src/store/sqlite_tests/report.zig"], zig_test="store.sqlite_tests.report.test.read")
        for target in ("test", "test-store"):
            for cause in (mixed, mysql_only):
                with self.subTest(target=target, cause=cause.signature):
                    planned = prepush.red_command(job(f"linux suites ({target})"), cause, AVAILABLE)
                    self.assertIsInstance(planned, prepush.NeedsMySQL)
                    unavailable = list(prepush.local_red_checks([("last CI red: " + cause.signature, planned)], False))
                    self.assertIsInstance(unavailable[-1][1], prepush.Skipped)
                    self.assertIn("MySQL rounds", unavailable[-1][0])
                    if cause is mixed:
                        self.assertEqual(len(unavailable), 2)
                        self.assertIn("SQLite subset", unavailable[0][0])
                        self.assertIn(prepush.live_engines.REQUIRE + "=sqlite", unavailable[0][1])
                        for variable in prepush.live_engines.ENGINES["mysql"]:
                            self.assertIn(variable, unavailable[0][1])
                    else:
                        self.assertEqual(len(unavailable), 1)
                    available = list(prepush.local_red_checks([("red", planned)], True))
                    self.assertEqual(len(available), 1)
                    self.assertEqual(available[0][1][:2], ["env", prepush.live_engines.REQUIRE + "=mysql"])
            self.assertIsInstance(prepush.red_command(job(f"linux suites ({target})"), sqlite_only, AVAILABLE), list)

    def test_every_mysql_only_owner_has_no_runnable_sqlite_subset(self):
        for module in ("mysql_dialect_check", "mysql_testing", "mysql_session_tests"):
            with self.subTest(module=module):
                cause = report_issue.Cause("live only", [f"src/store/{module}.zig"], zig_test=f"store.{module}.test.live")
                command = prepush.red_command(job("linux suites (test-store)"), cause, AVAILABLE)
                self.assertIsInstance(command, prepush.NeedsMySQL)
                unavailable = list(prepush.local_red_checks([("red", command)], False))
                self.assertEqual(len(unavailable), 1)
                self.assertIsInstance(unavailable[0][1], prepush.Skipped)

    def test_native_conformance_and_unknown_source_cannot_omit_live_obligations(self):
        graph = type("Graph", (), {"cores": set(), "live_conformance": {"src/session_view_store_tests.zig"}, "reached": {}})()
        cause = report_issue.Cause("native mixed", ["src/session_view_store_tests.zig"], zig_test="session_view_store_tests.test.view", zig_binary="unit-native-tests")
        command = prepush.red_command(job("linux suites (test-native)"), cause, AVAILABLE, graph=graph)
        self.assertIsInstance(command, prepush.NeedsMySQL)
        unknown = report_issue.Cause("unknown source", zig_test="ambiguous.test.view", zig_binary="unit-native-tests")
        self.assertIsInstance(prepush.red_command(job("linux suites (test-native)"), unknown, AVAILABLE, graph=graph), prepush.Skipped)

    def test_cached_commands_resolve_live_availability_again(self):
        self.configure(log="error: 'store.tests.activity.test.queued input' failed\n")
        first = self.plan()
        self.assertEqual(len(first[1]), 2)
        before = len(self.calls.read_text().splitlines())
        self.mysql.return_value = True
        second = self.plan()
        self.assertEqual(len(second[1]), 1)
        self.assertEqual(second[1][0][1][:2], ["env", prepush.live_engines.REQUIRE + "=mysql"])
        self.assertEqual(len(self.calls.read_text().splitlines()) - before, 1, "no logs refetched when only local availability changed")

    def test_sqlite_subset_clears_ambient_mysql_and_receipt_keeps_missing_rounds_skipped(self):
        code = "import os; assert os.environ['RUI_TEST_REQUIRE_ENGINES'] == 'sqlite'; assert 'RUI_TEST_MYSQL_SOCKET' not in os.environ"
        planned = [("last CI red: mixed", prepush.NeedsMySQL([sys.executable, "-c", code], True))]
        checks = list(prepush.local_red_checks(planned, False))
        receipt_path = self.directory / "receipt"
        with patch.object(prepush, "clean_tree", return_value="tree"), patch.object(prepush, "receipt_path", return_value=receipt_path), \
                patch.dict(os.environ, {prepush.live_engines.MYSQL_SOCKET: "unreachable"}), redirect_stdout(io.StringIO()):
            results = prepush.run(checks, "quick", "base")
        self.assertEqual(results[0]["exit"], 0)
        self.assertNotIn("exit", results[1])
        self.assertIn("MySQL rounds", results[1]["name"])

    def test_every_registered_root_matches_independent_membership_standalone_and_packed(self):
        units = {
            "unit-native-tests": ("test-native", {"test-native", "test", "check", "check-full", "full-execution"}),
            "unit-store-tests": ("test-store", {"test-store", "test", "check", "check-full", "full-execution"}),
            "test-tests": ("test", {"test-native", "test-store", "test", "check", "check-full", "full-execution"}),
            "deadline-witness-tests": ("test-full", {"test-full"}),
            "test-logic_tests": ("test-logic-only", {"test-logic", "test-logic-only"}),
            "parser-fuzz-parser_fuzz_tests": ("fuzz-parsers", {"test-logic"}),
            "parser-fuzz-llvm-parser_fuzz_tests": ("fuzz-parsers", {"fuzz-parsers"}),
            "test-h2": ("test-h2", {"test-h2", "check", "check-full", "full-execution"}),
            "test-pg": ("test-pg", {"test-pg", "check", "check-full", "full-execution"}),
            "rui-mysql-wire-test-mysql_wire_test": ("mysql-wire-integration", {"mysql-wire-integration"}),
        }
        graph = prepush.tree_graph()
        registry = build_files.unit_roots()
        self.assertEqual({root["name"] + "-" + Path(root["source"]).stem for root in registry}, units.keys())
        gates = sorted({gate for _, owners in units.values() for gate in owners} | {"full-callers", "unknown"})
        for root in registry:
            binary = root["name"] + "-" + Path(root["source"]).stem
            target, owners = units[binary]
            cause = report_issue.Cause("membership", [root["source"]], zig_test="test.registry case", zig_binary=binary)
            for gate in gates:
                for packed in (False, True):
                    selected = [gate, "test-logic"] if packed else [gate]
                    with self.subTest(binary=binary, selected=selected):
                        expected = target if owners.intersection(selected) else None
                        identities = prepush.matrix_targets("+".join(selected))
                        self.assertEqual(prepush.unit_target(identities, cause, graph), expected)
                        unknown = report_issue.Cause("unknown binary", cause.paths, zig_test=cause.zig_test, zig_binary="unregistered-binary")
                        self.assertIsNone(prepush.unit_target(identities, unknown, graph))

    def test_registered_source_identity_can_reproduce_numbered_historical_store_tests(self):
        graph = prepush.tree_graph()
        cause = report_issue.Cause("historical Store failure", ["src/store/tests/activity.zig"],
                                   zig_test="store.tests.activity.test.queued input")
        for owners in (["check"], ["test-native", "test-store"], ["test-store"]):
            self.assertEqual(prepush.unit_target([(owner, "all") for owner in owners], cause, graph), "test-store")
        cause = report_issue.Cause("unknown", zig_test="unregistered.test.named test")
        self.assertIsNone(prepush.unit_target([("test-logic", "all")], cause, graph))

    def test_live_and_upgrade_checks_are_skipped(self):
        for name in ("linux suites (test-pg)", "previous_release_upgrade"):
            with self.subTest(name=name):
                command = prepush.red_command(job(name), report_issue.Cause("a red", zig_test="pg.test.foo"), AVAILABLE)
                self.assertIsInstance(command, prepush.Skipped)


if __name__ == "__main__":
    unittest.main()
