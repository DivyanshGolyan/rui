"""Previous-red planning uses fake REST responses and logs, never GitHub."""
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
        self.assertEqual(len(checks), 2)
        for (_, command), test in zip(checks, ("queued input is pending", "ending migration")):
            self.assertEqual(command[:4], ["zig", "build", "-j1", "test-store"])
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

    def test_compile_jobs_use_known_commands(self):
        for name, command in (("linux_build_unit", [*prepush.UNIT_COMPILE, "-j1"]),
                              ("linux_build", ["zig", "build", "-j1", "ci-build", "-Dci-targets=request-wait-integration", "-Dci-part=all", "--summary", "line"]),
                              ("macos_typecheck", ["zig", "build", "-j1", "typecheck-macos", "--summary", "line"]),
                              ("linux_codegen", prepush.STACK_FRAMES)):
            with self.subTest(job=name):
                self.configure(run=dict(RUN, run_attempt=len(name)), jobs=[job(name)], log="src/foo.zig:1: error: no field\nzig build ci-build -Dci-targets=request-wait-integration -Dci-part=rest failed with exit 1; no gates executed.\n")
                self.assertEqual(self.plan()[1][0][1], command)

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
        self.assertEqual(len(checks), 2)
        self.assertIsInstance(checks[1][1], prepush.Skipped)

    def test_packed_unit_jobs_rerun_the_named_test(self):
        for matrix, target in (("test-native+test-store", "test"), ("test-store+test-logic", "test-store")):
            with self.subTest(matrix=matrix):
                cause = report_issue.Cause("store failed", paths=["src/store.zig"], zig_test="store.tests.test.foo")
                command = prepush.red_command(job(f"linux suites ({matrix})"), cause, AVAILABLE)
                self.assertEqual(command[3], target)
                self.assertIn("-Dtest-filter=store.tests.test.foo", command)

    def test_ambiguous_live_root_cannot_be_replaced_by_local_subset(self):
        cause = report_issue.Cause("TLS failed", paths=["src/tls_client/tls_client.zig"], zig_test="tls.test.foo")
        graph = type("Graph", (), {"reached": {"test-native": set(cause.paths), "test-pg": set(cause.paths)}})()
        for matrix in ("test-native+test-pg", "test-pg+test-native"):
            self.assertIsInstance(prepush.red_command(job(f"linux suites ({matrix})"), cause, AVAILABLE, graph=graph), prepush.Skipped)

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
        self.assertIsNone(identity[-1])
        self.assertEqual(len(checks), 1)
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

    def test_live_and_upgrade_checks_are_skipped(self):
        for name in ("linux suites (test-pg)", "previous_release_upgrade"):
            with self.subTest(name=name):
                command = prepush.red_command(job(name), report_issue.Cause("a red", zig_test="pg.test.foo"), AVAILABLE)
                self.assertIsInstance(command, prepush.Skipped)


if __name__ == "__main__":
    unittest.main()
