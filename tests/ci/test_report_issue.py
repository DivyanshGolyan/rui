"""CI failure reports: cause signatures from real log shapes, one issue per cause, reopened on recurrence."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest import mock

import report_issue

STAMP = "2026-10-29T13:44:55.1234567Z "


def logged(*lines):
    """A job log as GitHub serves it: a BOM, then a timestamp on every line."""
    return "﻿" + "\n".join(STAMP + line for line in lines) + "\n"


# Shapes copied from real failed jobs: fixtures run in parallel, so a
# fixture's traceback can sit above its record and beside expected
# BrokenPipe tracebacks from fixtures that passed.
HOST_STOP = logged(
    "Traceback (most recent call last):",
    '  File "/Users/runner/work/rui/rui/tests/integration/canonical_failure_integration.py", line 88, in main',
    "    peer.sendall(payload)",
    "BrokenPipeError: [Errno 32] Broken pipe",
    "canonical-failure passed: exit=0 elapsed=3.100s",
    "----------------------------------------",
    "host-stop failed: exit=1 elapsed=8.311s",
    "Traceback (most recent call last):",
    '  File "/Users/runner/work/rui/rui/tests/integration/host_stop_integration.py", line 404, in <module>',
    "    main()",
    "    ~~~~^^",
    '  File "/Users/runner/work/rui/rui/tests/integration/host_stop_integration.py", line 290, in main',
    '    upload.sendall(header[:-2] if phase == "header" else header + body[:-3])',
    "    ~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^",
    "BrokenPipeError: [Errno 32] Broken pipe",
    "Completed check: 183.489s; exit 1",
)
BASH = logged(
    "Traceback (most recent call last):",
    '  File "/Users/runner/work/rui/rui/tests/integration/bash_integration.py", line 1704, in main',
    "    assert process_exists(child_pid)",
    "           ~~~~~~~~~~~~~~^^^^^^^^^^^",
    "AssertionError",
    "bash failed: exit=1 elapsed=18.942s",
)
ZIG_CRASH = logged(
    "error: 'tests.test.a read cap defers expiry only for streams on that connection' "
    "terminated with signal ABRT with stderr:",
    "       expected 1, found 6",
    "       thread 22928 panic: reached unreachable code",
    "       ???:?:?: 0x10481c1e3 in _h2.Client.deinit (test-h2)",
    "failed command: ./.zig-cache/o/ci-compiled/test-h2 --listen=-",
)
ZIG_FAIL = logged(
    "5/793 codex_auth.test.refresh transport keeps not-sent evidence...FAIL (TestUnexpectedResult)",
    "native failed: exit=1 elapsed=92.153s",
)
GATE = logged(
    "renderer mutation gate failed: mark-collision: expected exactly one anchor, found 0",
    "Evidence: /home/runner/work/_temp/mutations/report.json (logs beside it).",
)


class CauseTest(unittest.TestCase):
    def setUp(self):
        self.cases = report_issue.fixtures()

    def test_driver_cases_map_to_their_fixture_files(self):
        self.assertEqual(self.cases['bash'], 'tests/integration/bash_integration.py')
        self.assertEqual(self.cases['host-stop'], 'tests/integration/host_stop_integration.py')
        # Cases run through `env VAR=… python3` keep their fixture.
        self.assertEqual(self.cases['terminal-restoration'], 'tests/integration/terminal_restoration_integration.py')
        self.assertEqual(self.cases['human-cli-renderer'], 'tests/integration/human_cli_integration.py')
        causes = report_issue.failure_causes(BASH + logged('terminal-restoration failed: exit=1 elapsed=3s'),
                                             self.cases)
        self.assertEqual([cause.paths for cause in causes],
                         [['tests/integration/bash_integration.py'],
                          ['tests/integration/terminal_restoration_integration.py']])
        for path in self.cases.values():
            self.assertTrue(Path(path).is_file(), path)

    def test_a_fixture_is_named_by_its_raising_line_not_by_neighbouring_tracebacks(self):
        [cause] = report_issue.failure_causes(HOST_STOP, self.cases)
        self.assertEqual(cause.signature, 'tests/integration/host_stop_integration.py: upload.sendall(header[:-2] if phase == "header" '
                                          'else header + body[:-3]) raised BrokenPipeError')
        self.assertEqual(cause.paths, ['tests/integration/host_stop_integration.py'])
        self.assertEqual(cause.detail, 'BrokenPipeError: [Errno 32] Broken pipe')
        [cause] = report_issue.failure_causes(BASH, self.cases)
        self.assertEqual(cause.signature, 'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError')

    def test_a_multi_line_raising_statement_keeps_the_whole_statement(self):
        log = logged(
            "Traceback (most recent call last):",
            '  File "/w/tests/integration/bash_integration.py", line 900, in main',
            "    assert states == {",
            "           ^^^^^^^^^^",
            '        "running": 1,',
            "    }, states",
            "AssertionError: {'running': 0}",
            "bash failed: exit=1 elapsed=2.000s",
        )
        [cause] = report_issue.failure_causes(log, self.cases)
        self.assertEqual(cause.signature, 'tests/integration/bash_integration.py: assert states == { "running": 1, }, states raised AssertionError')
        self.assertEqual(cause.detail, "AssertionError: {'running': 0}")
        # Two assertions sharing a first line keep separate signatures.
        other = log.replace('"running": 1,', '"held": 1,')
        [second] = report_issue.failure_causes(other, self.cases)
        self.assertNotEqual(second.signature, cause.signature)

    def test_zig_tests_and_gates_carry_their_own_cause(self):
        [crash] = report_issue.failure_causes(ZIG_CRASH, self.cases)
        self.assertEqual(crash.signature, "zig test 'tests.test.a read cap defers expiry only for streams "
                                          "on that connection' terminated with signal ABRT")
        self.assertEqual(crash.detail.splitlines()[0], 'expected 1, found 6')
        # Two tests.zig files exist, so no single path can claim the fix.
        self.assertEqual(crash.paths, [])
        # The native case's record adds nothing once the failing test is named.
        [failed] = report_issue.failure_causes(ZIG_FAIL, self.cases)
        self.assertEqual(failed.paths, ['src/codex_auth.zig'])
        self.assertIn('failed (TestUnexpectedResult)', failed.signature)
        [gate] = report_issue.failure_causes(GATE, self.cases)
        self.assertEqual(gate.signature,
                         'renderer mutation gate failed: mark-collision: expected exactly one anchor, found 0')

    def test_cases_sharing_a_fixture_file_keep_their_own_raising_lines(self):
        def case(name, statement):
            return [f"{name} failed: exit=1 elapsed=4.000s",
                    "Traceback (most recent call last):",
                    '  File "/w/rui/tests/integration/human_cli_integration.py", line 9, in main',
                    f"    {statement}",
                    "AssertionError"]
        log = logged(*case("human-cli", "assert caller_ok"), *case("human-cli-renderer", "assert frame_ok"))
        self.assertEqual([cause.signature for cause in report_issue.failure_causes(log, self.cases)],
                         ["tests/integration/human_cli_integration.py: assert caller_ok raised AssertionError",
                          "tests/integration/human_cli_integration.py: assert frame_ok raised AssertionError"])
        # A failed case without its own traceback never borrows its same-file neighbour's.
        log = logged(*case("human-cli", "assert caller_ok"), "human-cli-renderer failed: exit=1 elapsed=1s")
        self.assertEqual([cause.signature for cause in report_issue.failure_causes(log, self.cases)],
                         ["tests/integration/human_cli_integration.py: assert caller_ok raised AssertionError",
                          "tests/integration/human_cli_integration.py: exit without a parsed traceback"])

    def test_a_standalone_gate_is_named_by_its_script_and_raising_line(self):
        def gate(statement):
            return logged("Traceback (most recent call last):",
                          '  File "/w/rui/tests/integration/codex_h2_integration.py", line 50, in main',
                          f"    {statement}",
                          "AssertionError: mismatch",
                          "error: process exited with code 1",
                          "failed command: python3 /w/rui/tests/integration/codex_h2_integration.py "
                          "./.zig-cache/o/ci-compiled/rui-release-safe")
        signatures = [report_issue.failure_causes(gate(statement), self.cases)
                      for statement in ("assert stream_reset", "assert goaway_sent")]
        self.assertEqual([[cause.signature for cause in causes] for causes in signatures],
                         [["tests/integration/codex_h2_integration.py: assert stream_reset raised AssertionError"],
                          ["tests/integration/codex_h2_integration.py: assert goaway_sent raised AssertionError"]])
        self.assertEqual(signatures[0][0].paths, ["tests/integration/codex_h2_integration.py"])
        # The same assertion through check.sh's case record files under the same signature.
        recorded = logged("Traceback (most recent call last):",
                          '  File "/w/rui/tests/integration/codex_h2_integration.py", line 50, in main',
                          "    assert stream_reset",
                          "AssertionError: mismatch",
                          "codex-h2 failed: exit=1 elapsed=1s")
        cases = dict(self.cases, **{"codex-h2": "tests/integration/codex_h2_integration.py"})
        self.assertEqual([cause.signature for cause in report_issue.failure_causes(recorded, cases)],
                         [signatures[0][0].signature])
        # A passing step's stderr also ends in "failed command:", without an exit line.
        passing = logged("renderer allocation wide: retained=1",
                         "failed command: python3 /w/rui/tests/integration/codex_h2_integration.py")
        self.assertEqual(report_issue.failure_causes(passing, self.cases), [])

    def test_zig_failures_keep_their_names_across_assertion_diagnostics(self):
        log = logged("1/4 store.test.opens...OK",
                     "2/4 store.test.claims a position...expected 3, found 4",
                     "FAIL (TestExpectedEqual)",
                     "3/4 h2.test.resets a stream...OK",
                     "4/4 h2.test.sends goaway...expected true, found false",
                     "  extra diagnostic line",
                     "FAIL (TestUnexpectedResult)",
                     "native failed: exit=1 elapsed=9s")
        self.assertEqual([cause.signature for cause in report_issue.failure_causes(log, self.cases)],
                         ["zig test 'store.test.claims a position' failed (TestExpectedEqual)",
                          "zig test 'h2.test.sends goaway' failed (TestUnexpectedResult)"])

    def test_a_record_without_a_traceback_still_names_its_fixture(self):
        [cause] = report_issue.failure_causes(logged('host-stop failed: exit=124 elapsed=60.000s'), self.cases)
        self.assertEqual(cause.signature, 'tests/integration/host_stop_integration.py: exit without a parsed traceback')
        self.assertEqual(cause.paths, ['tests/integration/host_stop_integration.py'])
        self.assertEqual(report_issue.failure_causes(logged('all good'), self.cases), [])


class FakeGitHub:
    """Records gh calls; serves jobs, logs and open issues."""

    def __init__(self, jobs=(), logs=None, issues=()):
        self.jobs, self.logs, self.issues, self.calls = list(jobs), logs or {}, list(issues), []

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('issue', 'list'):
            return json.dumps(self.issues)
        if args[0] == 'api' and args[-1].endswith('/logs'):
            log = self.logs[int(args[-1].split('/')[-2])]
            if log is None:
                raise subprocess.CalledProcessError(1, ['gh', *args], stderr='HTTP 404')
            return log
        if args[0] == 'api':
            return json.dumps([{'jobs': self.jobs}])
        if args[:2] == ('issue', 'create'):
            return 'https://github.com/o/r/issues/77\n'
        return ''

    def made(self, verb):
        return [call for call in self.calls if call[:2] == ('issue', verb)]


def issue(number, signature, paths, workflows, last_sha, state='OPEN'):
    recorded = dict(signature=signature, paths=paths, workflows=workflows, last_sha=last_sha)
    return dict(number=number, state=state, body=report_issue.render(recorded, ''))


class ReportTest(unittest.TestCase):
    def run_main(self, fake, *args):
        argv = ['report_issue.py', '--workflow', 'Daily macOS qualification', '--run-id', '9', '--sha', 'c' * 40]
        with mock.patch.object(report_issue, 'gh', fake), mock.patch.object(sys, 'argv', argv + list(args)), \
                mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                mock.patch.object(report_issue, 'LOG_RETRY_DELAYS', (0, 0)), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            report_issue.main()
        return out.getvalue()

    def test_a_new_cause_opens_one_labelled_issue_and_a_recurrence_comments(self):
        fake = FakeGitHub([dict(id=1, name='macos / full-execution', conclusion='failure')], {1: BASH})
        self.run_main(fake, '--label', 'stable-red')
        [create] = fake.made('create')
        self.assertIn('CI red: tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError', create)
        self.assertEqual([create[i + 1] for i, arg in enumerate(create) if arg == '--label'],
                         ['ci-red', 'stable-red'])
        state = report_issue.signature_state(create[create.index('--body') + 1])
        self.assertEqual(state['paths'], ['tests/integration/bash_integration.py'])

        signature = 'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError'
        fake = FakeGitHub([dict(id=1, name='j', conclusion='failure')], {1: BASH},
                          [issue(5, signature, state['paths'], ['Stable qualification'], 'a' * 40)])
        self.run_main(fake)
        self.assertEqual(fake.made('create'), [])
        [edit] = fake.made('edit')
        updated = report_issue.signature_state(edit[edit.index('--body') + 1])
        self.assertEqual(updated['last_sha'], 'c' * 40)
        self.assertEqual(updated['workflows'], ['Daily macOS qualification', 'Stable qualification'])
        [comment] = fake.made('comment')
        self.assertEqual(comment[2], '5')
        self.assertNotIn('--add-label', edit)

    def test_a_stable_red_labels_an_issue_another_workflow_filed(self):
        signature = 'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError'
        fake = FakeGitHub([dict(id=1, name='j', conclusion='failure')], {1: BASH},
                          [issue(5, signature, [], ['Daily macOS qualification'], 'a' * 40, state='CLOSED')])
        self.run_main(fake, '--label', 'stable-red')
        self.assertEqual(fake.made('create'), [])
        [edit] = fake.made('edit')
        self.assertEqual(edit[2], '5')
        self.assertEqual(edit[edit.index('--add-label') + 1], 'stable-red')
        self.assertEqual([call[2] for call in fake.made('reopen')], ['5'])

    def test_an_unparsed_failure_is_still_filed_under_its_job(self):
        fake = FakeGitHub([dict(id=1, name='macos / resources', conclusion='failure')], {1: logged('boom')})
        self.run_main(fake)
        [create] = fake.made('create')
        self.assertIn("job 'macos / resources' failed; cause not parsed", create[create.index('--title') + 1])

    def test_a_recurrence_after_a_claimed_fix_reopens_the_issue(self):
        signature = 'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError'
        fake = FakeGitHub([dict(id=1, name='j', conclusion='failure')], {1: BASH},
                          [issue(4, signature, [], ['W'], 'a' * 40, state='CLOSED'),
                           issue(6, signature, [], ['W'], 'b' * 40, state='CLOSED')])
        self.run_main(fake)
        self.assertEqual(fake.made('create'), [])
        self.assertEqual([call[2] for call in fake.made('reopen')], ['6'])
        [comment] = fake.made('comment')
        self.assertTrue(comment[comment.index('--body') + 1].startswith('Failed again after its fix.'))

    def test_passing_jobs_are_read_only_for_retried_failures_on_landing_tips(self):
        retried = (logged('::warning::check failed (exit 1); one automatic retry. A pass after this retry '
                          'is a flake to fix, not a clean pass.') + BASH +
                   logged('::warning::test-h2 failed (exit 1); one automatic retry.') + ZIG_CRASH)
        jobs = [dict(id=1, name='linux suites (check)', conclusion='success'),
                dict(id=2, name='linux suites (logic)', conclusion='failure'),
                dict(id=3, name='plan', conclusion='success')]
        fake = FakeGitHub(jobs, {1: retried, 2: GATE, 3: logged('planned')})
        self.run_main(fake, '--retried-only')
        titles = [call[call.index('--title') + 1] for call in fake.made('create')]
        # Both retried batches are filed, however many retries the job made.
        self.assertEqual(len(titles), 2)
        self.assertIn('tests/integration/bash_integration.py: assert process_exists', titles[0])
        self.assertIn('read cap defers expiry', titles[1])
        body = fake.made('create')[0]
        self.assertIn('passed only on its automatic retry', body[body.index('--body') + 1])
        # The landing tip's own red belongs to its author, not an issue.
        self.assertNotIn(('api', 'repos/o/r/actions/jobs/2/logs'), fake.calls)

        # A run that is not a landing tip reads only its failed jobs.
        fake = FakeGitHub(jobs, {1: retried, 2: GATE, 3: logged('planned')})
        self.run_main(fake)
        self.assertEqual([call[-1] for call in fake.calls if call[0] == 'api' and call[-1].endswith('/logs')],
                         ['repos/o/r/actions/jobs/2/logs'])

    def test_an_aggregate_failing_only_on_its_needs_files_nothing_of_its_own(self):
        require = [dict(name='Set up job', conclusion='success'),
                   dict(name='Require every selected Apple Silicon part', conclusion='failure')]
        jobs = [dict(id=1, name='macos suites (check)', conclusion='failure'),
                dict(id=2, name='macos', conclusion='failure', steps=require)]
        fake = FakeGitHub(jobs, {1: BASH, 2: logged('test "$NATIVE_RESULT" = success')})
        self.run_main(fake)
        [create] = fake.made('create')
        self.assertIn('tests/integration/bash_integration.py: assert process_exists', create[create.index('--title') + 1])
        self.assertNotIn(('api', 'repos/o/r/actions/jobs/2/logs'), fake.calls)
        # Every aggregate step check.yml runs carries the name the reporter skips.
        steps = re.findall(r'^      - name: (Require every selected .+)$', Path('.github/workflows/check.yml').read_text(),
                           re.M)
        self.assertEqual(len(steps), 2)
        # A real gate that fails is still filed.
        gate = dict(id=3, name='mutations', conclusion='failure',
                    steps=[dict(name='Require behavioral kills in isolated source copies', conclusion='failure')])
        self.assertFalse(report_issue.aggregate_only(gate))

    def test_an_unavailable_log_is_retried_then_filed_without_aborting_the_run(self):
        jobs = [dict(id=1, name='macos / native', conclusion='failure'),
                dict(id=2, name='macos / resources', conclusion='failure')]
        fake = FakeGitHub(jobs, {1: None, 2: BASH})
        out = self.run_main(fake)
        self.assertEqual(sum(call[-1] == 'repos/o/r/actions/jobs/1/logs' for call in fake.calls), 3)
        titles = [call[call.index('--title') + 1] for call in fake.made('create')]
        self.assertEqual(len(titles), 2)
        self.assertIn("job 'macos / native' log unavailable", titles[0])
        self.assertIn('::warning::', out)


class WiringTest(unittest.TestCase):
    def report_job(self, name):
        text = Path('.github/workflows', name).read_text()
        return re.search(r'(?ms)^  report:\n(.*?)(?=^  [a-z_]+:\n|\Z)', text)[1]

    def test_every_reporting_workflow_files_by_cause_from_job_logs(self):
        for name in ('daily-macos.yml', 'qualify-linux.yml', 'renderer-contracts.yml', 'check.yml'):
            with self.subTest(workflow=name):
                job = self.report_job(name)
                self.assertIn('report_issue.py --workflow', job)
                self.assertIn('--run-id "$GITHUB_RUN_ID" --sha "$GITHUB_SHA"', job)
                self.assertIn('actions: read', job)
                self.assertIn('issues: write', job)
                self.assertIn('always()', job)
                self.assertNotIn('--title', job)

    def test_stable_reds_are_labelled_and_landing_tips_report_only_flakes(self):
        job = self.report_job('check.yml')
        self.assertIn('--workflow "Stable qualification"', job)
        self.assertIn('--label stable-red', job)
        self.assertIn('--workflow "Selected checks"', job)
        self.assertIn('--retried-only', job)
        self.assertIn("startsWith(github.ref, 'refs/heads/wip/land-')", job)
        self.assertIn('inputs.stable', job)
        self.assertIn("needs.macos.result != 'success'", job)
        self.assertNotIn("'pull_request'", job)


if __name__ == '__main__':
    unittest.main()
