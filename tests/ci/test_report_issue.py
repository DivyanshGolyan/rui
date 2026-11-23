import contextlib
from datetime import datetime, timedelta, timezone
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
NOW = datetime(2026, 11, 22, 12, tzinfo=timezone.utc)


def logged(*lines):
    return "﻿" + "\n".join(STAMP + line for line in lines) + "\n"


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
UNITTEST = logged(
    "test_other (test_selection.SelectionTest.test_other) ... ok",
    "",
    "======================================================================",
    "ERROR: test_root_disposal_requires_the_whole_group_to_retire (test_selection.FullCheckPartitionTest."
    "test_root_disposal_requires_the_whole_group_to_retire) (delivery='lost')",
    "----------------------------------------------------------------------",
    "Traceback (most recent call last):",
    '  File "/home/runner/work/rui/rui/tests/ci/test_selection.py", line 1082, in test_root_disposal_requires_the_whole_group_to_retire',
    "    self.wait_for_group_retirement(group, time.monotonic() + 5)",
    '  File "/home/runner/work/rui/rui/tests/ci/test_selection.py", line 683, in wait_for_group_retirement',
    '    raise TimeoutError(f"live driver group {group} did not retire")',
    "TimeoutError: live driver group 22993 did not retire",
    "",
    "----------------------------------------------------------------------",
    "Ran 162 tests in 104.483s",
    "",
    "FAILED (errors=1)",
)
GATE = logged(
    "renderer mutation gate failed: mark-collision: expected exactly one anchor, found 0",
    "Evidence: /home/runner/work/_temp/mutations/report.json (logs beside it).",
)
WHITESPACE = logged(
    "clients/ts/node_modules/yaml-ast-parser/src/loader.ts:208: trailing whitespace.",
    "+    ",
    "clients/ts/node_modules/yaml-ast-parser/workspace.json:31: new blank line at EOF.",
    "clients/ts/node_modules/yargs-parser/CHANGELOG.md:235: trailing whitespace.",
    "+* \\_\\_proto\\_\\_ will now be replaced",
    "##[error]Process completed with exit code 2.",
)


class GhCompatibilityTest(unittest.TestCase):
    def test_compile_selection_comes_from_the_failed_producer(self):
        self.assertEqual(report_issue.compile_targets("zig build ci-build -Dci-targets=check,test-logic -Dci-part=rest failed with exit 1; no gates executed.\n"), ["check", "test-logic"])
        self.assertEqual(report_issue.compile_targets(logged('  TARGETS: ["request-wait-integration"]')), ["request-wait-integration"])
        self.assertEqual(report_issue.compile_targets(logged('  TARGETS: [', '    "check",', '    "test-logic"', '  ]', '  PART: rest')), ["check", "test-logic"])
        self.assertEqual(report_issue.compile_targets("TARGETS: [truncated\n"), [])
        self.assertEqual(report_issue.compile_targets("src/cli.zig:2: error: no field"), [])

    def test_old_gh_retries_only_the_unsupported_escape_flag(self):
        error = subprocess.CalledProcessError(1, ["gh"], stderr="unknown flag: --allow-escape-sequences")
        with mock.patch.object(report_issue.subprocess, "run", side_effect=[error, subprocess.CompletedProcess([], 0, stdout="log")]) as run:
            self.assertEqual(report_issue.gh("api", "--allow-escape-sequences", "repos/o/r/logs"), "log")
        self.assertEqual(run.call_args.args[0], ["gh", "api", "repos/o/r/logs"])
        with mock.patch.object(report_issue.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["gh"], stderr="HTTP 503")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                report_issue.gh("api", "--allow-escape-sequences", "repos/o/r/logs")
        self.assertEqual(run.call_count, 1)


class CauseTest(unittest.TestCase):
    def setUp(self):
        self.cases = report_issue.fixtures()

    def test_driver_cases_map_to_their_fixture_files(self):
        self.assertEqual(self.cases['bash'], 'tests/integration/bash_integration.py')
        self.assertEqual(self.cases['host-stop'], 'tests/integration/host_stop_integration.py')
        self.assertEqual(self.cases['terminal-restoration'], 'tests/integration/terminal_restoration_integration.py')
        self.assertEqual(self.cases['human-cli-renderer'], 'tests/integration/human_cli_integration.py')
        causes = report_issue.failure_causes(BASH + logged('terminal-restoration failed: exit=1 elapsed=3s'),
                                             self.cases)
        self.assertEqual([cause.paths for cause in causes],
                         [['tests/integration/bash_integration.py'],
                          ['tests/integration/terminal_restoration_integration.py']])
        for path in self.cases.values():
            self.assertTrue(Path(path).is_file(), path)

    def test_unit_launchers_are_not_registered_as_integration_fixtures(self):
        self.assertNotIn("native", self.cases)
        self.assertNotIn("store", self.cases)
        shell = '\n'.join([
            'run_case execution native python3 "$directory/host_process.py" exec python3 "$directory/../ci/store_shards.py" native',
            'run_case execution store python3 "$directory/host_process.py" exec python3 "$directory/../ci/store_shards.py" run',
            'run_case callers host-stop python3 "$directory/nested/../host_stop_integration.py"',
        ])
        with mock.patch.object(Path, "read_text", return_value=shell):
            self.assertEqual(report_issue.fixtures(), {"host-stop": "tests/integration/host_stop_integration.py"})

    def test_checked_termination_preserves_failed_command_attribution(self):
        for term in ("exited with code 42", "terminated with signal SIGTERM"):
            for expected in ("", " (expected exited with code 0)"):
                with self.subTest(term=term, expected=expected):
                    log = logged(f"error: process {term}{expected}",
                                 "failed command: sh -c 'exec \"$@\" >&2' rui-acceptance python3 "
                                 "/w/tests/integration/host_stop_integration.py /tmp/rui")
                    self.assertEqual(len(report_issue.COMMAND.findall(report_issue.untimed(log))), 1)
                    self.assertTrue(report_issue.failure_causes(log, self.cases))

    def test_launcher_command_aliases_do_not_add_a_second_cause_to_a_zig_failure(self):
        for launcher in ("tests/ci/store_shards.py", "tests/integration/../ci/store_shards.py",
                         "tests/integration/./../ci/store_shards.py"):
            with self.subTest(launcher=launcher):
                log = ZIG_FAIL + logged("error: process exited with code 1",
                                        f"failed command: python3 /w/{launcher} run /tmp/unit-store-tests")
                [cause] = report_issue.failure_causes(log, self.cases)
                self.assertEqual(cause.zig_test,
                                 "codex_auth.test.refresh transport keeps not-sent evidence")
                self.assertEqual(cause.paths, ["src/codex_auth.zig"])

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
        other = log.replace('"running": 1,', '"held": 1,')
        [second] = report_issue.failure_causes(other, self.cases)
        self.assertNotEqual(second.signature, cause.signature)

    def test_zig_tests_and_gates_carry_their_own_cause(self):
        [crash] = report_issue.failure_causes(ZIG_CRASH, self.cases)
        self.assertEqual(crash.signature, "zig test 'tests.test.a read cap defers expiry only for streams "
                                          "on that connection' terminated with signal ABRT")
        self.assertEqual(crash.detail.splitlines()[0], 'expected 1, found 6')
        self.assertEqual(crash.paths, [])
        [failed] = report_issue.failure_causes(ZIG_FAIL, self.cases)
        self.assertEqual(failed.paths, ['src/codex_auth.zig'])
        self.assertIn('failed (TestUnexpectedResult)', failed.signature)
        [gate] = report_issue.failure_causes(GATE, self.cases)
        self.assertEqual(gate.signature,
                         'renderer mutation gate failed: mark-collision: expected exactly one anchor, found 0')

    def test_zig_binary_identity_stays_with_each_failed_root(self):
        [h2] = report_issue.failure_causes(ZIG_CRASH, self.cases)
        self.assertEqual(h2.zig_binary, "test-h2")
        log = ZIG_CRASH + ZIG_CRASH.replace("test-h2", "test-pg")
        causes = report_issue.failure_causes(log, self.cases)
        self.assertEqual([cause.zig_binary for cause in causes], ["test-h2", "test-pg"])
        numbered = logged("1/2 tests.test.shared...FAIL (TestUnexpectedResult)",
                          "failed command: ./.zig-cache/o/ci-compiled/test-h2 --listen=-")
        self.assertEqual(report_issue.failure_causes(numbered, self.cases)[0].zig_binary, "test-h2")
        separated = ZIG_FAIL + logged("failed command: ./.zig-cache/o/ci-compiled/test-pg --listen=-")
        self.assertEqual(report_issue.failure_causes(separated, self.cases)[0].zig_binary, "")

    def test_interleaved_unit_diagnostics_cannot_borrow_a_peer_binary(self):
        for first, second in (("test-pg", "unit-native-tests"), ("unit-native-tests", "test-pg")):
            log = logged("error: 'tests.test.native failure' failed",
                         "error: 'tests.test.pg failure' failed",
                         f"failed command: /tmp/{first} --listen=-",
                         f"failed command: /tmp/{second} --listen=-")
            causes = report_issue.failure_causes(log, self.cases)
            self.assertEqual(len(causes), 2)
            self.assertEqual([cause.zig_binary for cause in causes], ["", ""])

    def test_zig_source_uses_complete_nested_module_namespace(self):
        self.assertEqual(report_issue.zig_paths("store.tests.activity.test.queued input"), ["src/store/tests/activity.zig"])
        self.assertEqual(report_issue.zig_paths("store.sqlite_tests.report.test.read"), ["src/store/sqlite_tests/report.zig"])
        self.assertEqual(report_issue.zig_paths("tests.test.ambiguous"), [])

    def test_a_whitespace_check_names_its_files(self):
        [cause] = report_issue.failure_causes(WHITESPACE, self.cases)
        self.assertEqual(cause.signature, "whitespace check (git diff --check) failed")
        self.assertEqual(cause.paths, ["clients/ts/node_modules/yaml-ast-parser/src/loader.ts",
                                       "clients/ts/node_modules/yaml-ast-parser/workspace.json",
                                       "clients/ts/node_modules/yargs-parser/CHANGELOG.md"])
        self.assertEqual(cause.detail.splitlines()[:2],
                         ["3 problems in 3 files, first:",
                          "clients/ts/node_modules/yaml-ast-parser/src/loader.ts: trailing whitespace"])
        many = logged(*(f"vendor/{index}.js:1: trailing whitespace." for index in range(50)))
        [bounded] = report_issue.failure_causes(many, self.cases)
        self.assertEqual(len(bounded.paths), report_issue.WHITESPACE_PATHS)

    def test_a_python_unit_test_is_named_by_its_id_and_raising_line(self):
        [cause] = report_issue.failure_causes(UNITTEST, self.cases)
        self.assertEqual(cause.signature,
                         "python test 'test_selection.FullCheckPartitionTest."
                         "test_root_disposal_requires_the_whole_group_to_retire': "
                         'raise TimeoutError(f"live driver group {group} did not retire") raised TimeoutError')
        self.assertEqual(cause.paths, ['tests/ci/test_selection.py'])
        self.assertEqual(cause.detail, 'TimeoutError: live driver group 22993 did not retire')
        [again] = report_issue.failure_causes(UNITTEST.replace("'lost'", "'delayed'").replace('22993', '7'),
                                              self.cases)
        self.assertEqual(again.signature, cause.signature)

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
        log = logged(*case("human-cli", "assert caller_ok"), "human-cli-renderer failed: exit=1 elapsed=1s")
        self.assertEqual([cause.signature for cause in report_issue.failure_causes(log, self.cases)],
                         ["tests/integration/human_cli_integration.py: assert caller_ok raised AssertionError",
                          "tests/integration/human_cli_integration.py: exit without a parsed traceback"])

    def test_a_fixture_whose_cases_live_in_its_cases_library_keeps_their_raising_lines(self):
        def case(statement):
            return logged("canonical-failure failed: exit=1 elapsed=4.000s",
                          "Traceback (most recent call last):",
                          '  File "/w/rui/tests/integration/canonical_failure_integration.py", line 9, in <module>',
                          '    main(sys.argv[2] if len(sys.argv) == 3 else "all")',
                          '  File "/w/rui/tests/integration/canonical_failure_cases.py", line 80, in main',
                          "    binding_cases(state)",
                          '  File "/w/rui/tests/integration/canonical_failure_cases.py", line 40, in binding_cases',
                          f"    {statement}",
                          '  File "/w/rui/tests/integration/host_process.py", line 900, in wait_for',
                          "    raise AssertionError(label)",
                          "AssertionError")
        cases = dict(self.cases, **{"canonical-failure": "tests/integration/canonical_failure_integration.py"})
        self.assertEqual([report_issue.failure_causes(case(statement), cases)[0].signature
                          for statement in ("wait_for(bound, 'binding')", "wait_for(fenced, 'fence')")],
                         ["tests/integration/canonical_failure_integration.py: wait_for(bound, 'binding') raised AssertionError",
                          "tests/integration/canonical_failure_integration.py: wait_for(fenced, 'fence') raised AssertionError"])

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
        recorded = logged("Traceback (most recent call last):",
                          '  File "/w/rui/tests/integration/codex_h2_integration.py", line 50, in main',
                          "    assert stream_reset",
                          "AssertionError: mismatch",
                          "codex-h2 failed: exit=1 elapsed=1s")
        cases = dict(self.cases, **{"codex-h2": "tests/integration/codex_h2_integration.py"})
        self.assertEqual([cause.signature for cause in report_issue.failure_causes(recorded, cases)],
                         [signatures[0][0].signature])
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

    def __init__(self, jobs=(), logs=None, issues=(), timeline=(), compare='ahead', annotations=()):
        self.jobs = [dict(status='completed', **job) for job in jobs]
        self.logs, self.issues, self.calls = logs or {}, list(issues), []
        self.timeline, self.compare, self.annotations = list(timeline), compare, list(annotations)

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('issue', 'list'):
            return json.dumps(self.issues)
        if args[0] == 'api' and args[-1].endswith('/logs'):
            log = self.logs[int(args[-1].split('/')[-2])]
            if log is None:
                raise subprocess.CalledProcessError(1, ['gh', *args], stderr='HTTP 404')
            if '\x1b' in log and '--allow-escape-sequences' not in args:
                raise subprocess.CalledProcessError(1, ['gh', *args], stderr=(
                    'the response contains terminal escape sequences; '
                    'pass --allow-escape-sequences to output it anyway'))
            return log
        if args[0] == 'api' and args[1].endswith('/annotations'):
            return json.dumps([dict(message=note) for note in self.annotations])
        if args[0] == 'api' and '/timeline' in args[1]:
            return json.dumps([self.timeline])
        if args[0] == 'api' and '/compare/' in args[1]:
            return json.dumps({'status': self.compare})
        if args[0] == 'api':
            return json.dumps([{'jobs': self.jobs}])
        if args[:2] == ('issue', 'create'):
            return 'https://github.com/o/r/issues/77\n'
        return ''

    def made(self, verb):
        return [call for call in self.calls if call[:2] == ('issue', verb)]


def issue(number, signature, paths, workflows, last_sha, state='OPEN', escape='', created=NOW):
    recorded = dict(signature=signature, paths=paths, workflows=workflows, last_sha=last_sha)
    labels = [dict(name=f'escape:{escape}')] if escape else []
    return dict(number=number, state=state, body=report_issue.render(recorded, ''), labels=labels,
                createdAt=created.strftime('%Y-%m-%dT%H:%M:%SZ'))


MYSQL_BUNDLE = ('qualify / selected / linux suites (chatgpt-login-integration+codex-credential-integration+'
                'dispatch-debug-integration+installer-integration+mysql-wire-integration+server-delivery-integration+'
                'test-full+ts-client)')
MEASUREMENT_BUNDLE = ('qualify / selected / linux suites (admission-debug-integration+cli-image-integration+'
                      'current-facts-integration+human-cli-integration+measurement-check+public-parts-integration+'
                      'skills-integration+transport-h2-integration)')
FULL_CALLERS = 'qualify / selected / linux suites (full-callers)'
FULL_EXECUTION = 'qualify / selected / linux suites (full-execution)'
DIALECT = 'Require that the live MySQL dialect check ran'


class EscapeClassTest(unittest.TestCase):
    def test_each_escape_class_and_an_unmatched_job_map_from_the_real_job_and_its_stopping_step(self):
        owners = report_issue.escape_owners()
        cases = report_issue.fixtures()
        Cause = report_issue.Cause
        failed, cancelled = 'failure', 'cancelled'
        selected = 'Run selected targets'
        rows = [
            # job name, job conclusion, steps (name, conclusion), cause, expected class
            (MYSQL_BUNDLE, 'failure', [(selected, failed)], Cause('signature', zig_binary='test-full'), 'unknown'),
            (MYSQL_BUNDLE, 'failure', [(selected, failed)], Cause('signature', ['tests/integration/mysql_wire_integration.py']),
             'own-files:mysql-wire-integration'),
            (MEASUREMENT_BUNDLE, 'failure', [(selected, failed)], Cause('signature', zig_binary='measurement-check'),
             'own-files:measurement-check'),
            (MEASUREMENT_BUNDLE, 'failure', [(selected, failed)], Cause('signature'), 'unknown'),
            ('qualify / selected / linux suites (stack-frames)', 'failure', [(selected, failed)], Cause('signature'),
             'pr-tier'),
            ('qualify / selected / linux suites (rsql-table)', 'failure', [(selected, failed)], Cause('signature'),
             'promotion-only:rsql-table'),
            ('qualify / selected / cache execution (ubuntu-24.04)', 'failure',
             [('Prove warm compilation does not cache test acceptance', failed)], Cause('signature'), 'promotion-only'),
            ('qualify / renderer / contracts', 'failure', [('Run the contracts', failed)], Cause('signature'),
             'promotion-only'),
            ('qualify / release_build / build (darwin-arm64)', 'failure', [('Build the artifact', failed)],
             Cause('signature'), 'promotion-only'),
            ('qualify / selected / linux suites (full-execution)', 'failure', [(selected, failed)],
             Cause('signature', zig_test='store.archive_tests.test.MySQL plans a list row'), 'live-mysql:check-full'),
            ('qualify / selected / macos suites (native)', 'timed_out', [('Run required native targets', cancelled)],
             Cause('signature'), 'cold-cache-timeout'),
            ('qualify / upgrade (macos-15)', 'failure', [('Start detached, then install', failed)], Cause('signature'),
             'upgrade'),
            ('qualify / selected / macos suites (full-callers)', 'failure', [(selected, failed)], Cause('signature'),
             'macos'),
            ('qualify / selected / linux suites (test-logic)', 'failure', [(selected, failed)], Cause('signature'),
             'pr-tier'),
            (FULL_CALLERS, 'failure', [(selected, failed)],
             Cause('signature', ['tests/integration/human_cli_integration.py']), 'pr-tier'),
            (MEASUREMENT_BUNDLE, 'failure', [(selected, failed)],
             Cause('signature', zig_binary='admission-debug-integration'), 'pr-tier'),
            (FULL_EXECUTION, 'failure', [(selected, failed)], Cause('signature'), 'unknown'),
            (FULL_EXECUTION, 'failure', [('Build the artifact', failed), (DIALECT, failed)], Cause('signature'),
             'unknown'),
            (FULL_EXECUTION, 'failure', [(DIALECT, failed)], Cause('signature'), 'live-mysql:check-full'),
            ('qualify / selected / linux_build', 'failure', [('Build the artifact', failed)], Cause('signature'),
             'unknown'),
        ]
        self.assertEqual({expected.split(':')[0] for *_, expected in rows}, set(report_issue.ESCAPE_REASONS))
        for name, conclusion, steps, cause, expected in rows:
            job = dict(name=name, conclusion=conclusion, steps=[dict(name=step, conclusion=c) for step, c in steps])
            with self.subTest(job=name, expected=expected):
                self.assertEqual(report_issue.escape_class(job, cause, owners, cases), expected)


class ReportTest(unittest.TestCase):
    def run_main(self, fake, *args, now=NOW):
        argv = ['report_issue.py', '--workflow', 'Daily macOS qualification', '--run-id', '9', '--sha', 'c' * 40]
        with mock.patch.object(report_issue, 'gh', fake), mock.patch.object(sys, 'argv', argv + list(args)), \
                mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                mock.patch.object(report_issue, 'LOG_RETRY_DELAYS', (0, 0)), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            report_issue.main(now=now)
        return out.getvalue()

    def test_a_new_escape_repeating_its_class_within_14_days_is_flagged_once(self):
        earlier = [(5, 'OPEN', {}, 'macos', NOW - timedelta(days=3))]
        self.assertEqual(report_issue.repeat_of('macos', earlier, NOW), 5)
        self.assertIsNone(report_issue.repeat_of('macos', [(5, 'CLOSED', {}, 'macos', NOW - timedelta(days=15))], NOW))
        self.assertIsNone(report_issue.repeat_of('upgrade', earlier, NOW))
        self.assertIsNone(report_issue.repeat_of('unknown', [(5, 'OPEN', {}, 'unknown', NOW)], NOW))
        for kind in ('pr-tier', 'cold-cache-timeout', 'unknown'):
            with self.subTest(kind=kind):
                self.assertIsNone(report_issue.repeat_of(kind, [(5, 'OPEN', {}, kind, NOW)], NOW))
        target_keyed = [(5, 'OPEN', {}, 'live-mysql:check-full', NOW)]
        self.assertEqual(report_issue.repeat_of('live-mysql:check-full', target_keyed, NOW), 5)
        self.assertIsNone(report_issue.repeat_of('live-mysql:test-store', target_keyed, NOW))

        def run_against(*existing, jobs=None):
            fake = FakeGitHub(jobs or [dict(id=1, name='macos / full-execution', conclusion='failure')], {1: BASH, 2: HOST_STOP},
                              list(existing))
            self.run_main(fake)
            return fake

        # Two new causes of one class in one run: each sees only the issues from before the run's jobs.
        same_run = run_against(jobs=[dict(id=1, name='macos / full-execution', conclusion='failure'),
                                     dict(id=2, name='macos / full-callers', conclusion='failure')])
        self.assertEqual(len(same_run.made('create')), 2)
        self.assertEqual(same_run.made('comment'), [])

        signature = 'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError'
        flagged = run_against(issue(5, 'other', [], ['Promote'], 'a' * 40, escape='macos', created=NOW - timedelta(days=3)))
        [create] = flagged.made('create')
        labels = [create[i + 1] for i, arg in enumerate(create) if arg == '--label']
        self.assertEqual(labels, ['ci-red', 'escape:macos', 'escape-repeat'])
        self.assertIn('Escape class: macos: the ready PR tier runs no macOS job',
                      create[create.index('--body') + 1])
        [comment] = flagged.made('comment')
        self.assertEqual(comment[comment.index('--body') + 1],
                         'Second macos escape in 14 days (#5): add a narrow select_tests rule (see #1965 unit 2)')

        older = run_against(issue(5, 'other', [], ['Promote'], 'a' * 40, escape='macos', created=NOW - timedelta(days=15)))
        self.assertNotIn('escape-repeat', older.made('create')[0])
        self.assertEqual(older.made('comment'), [])

        other_class = run_against(issue(5, 'other', [], ['Promote'], 'a' * 40, escape='upgrade', created=NOW - timedelta(days=3)))
        self.assertNotIn('escape-repeat', other_class.made('create')[0])
        self.assertEqual(other_class.made('comment'), [])

        recurrence = run_against(issue(5, signature, [], ['Promote'], 'a' * 40, escape='macos', created=NOW - timedelta(days=3)))
        self.assertEqual(recurrence.made('create'), [])
        [comment] = recurrence.made('comment')
        self.assertEqual(comment[2], '5')
        self.assertNotIn('Second', comment[comment.index('--body') + 1])
        # A recurrence renders its body's class from the issue's own label, so a hand-relabel sticks.
        [edit] = recurrence.made('edit')
        self.assertIn('Escape class: macos: the ready PR tier runs no macOS job', edit[edit.index('--body') + 1])

    def test_a_new_cause_opens_one_labelled_issue_and_a_recurrence_comments(self):
        fake = FakeGitHub([dict(id=1, name='macos / full-execution', conclusion='failure')], {1: BASH})
        self.run_main(fake, '--label', 'stable-red')
        [create] = fake.made('create')
        self.assertIn('CI red: tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError', create)
        self.assertEqual([create[i + 1] for i, arg in enumerate(create) if arg == '--label'],
                         ['ci-red', 'stable-red', 'escape:macos'])
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

    def test_an_infrastructure_red_is_filed_without_an_escape_class(self):
        lost = dict(id=1, name='macos / full-execution', conclusion='failure')
        cancelled_setup = dict(id=1, name='macos / full-execution', conclusion='failure',
                               steps=[dict(name='Set up job', conclusion='cancelled')])
        for job, annotations in ((lost, ['The runner has received a shutdown signal']), (cancelled_setup, [])):
            with self.subTest(annotations=annotations):
                fake = FakeGitHub([job], {1: BASH}, annotations=annotations)
                self.run_main(fake)
                [create] = fake.made('create')
                labels = [create[i + 1] for i, arg in enumerate(create) if arg == '--label']
                self.assertEqual(labels, ['ci-red'])
                self.assertNotIn('Escape class', create[create.index('--body') + 1])

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

    def test_an_unparsed_failure_is_still_filed_under_its_job_and_step(self):
        steps = [dict(name='Run the resources', conclusion='failure')]
        fake = FakeGitHub([dict(id=1, name='macos / resources', conclusion='failure', steps=steps)], {1: logged('boom')})
        self.run_main(fake)
        [create] = fake.made('create')
        self.assertIn("job 'macos / resources' failed at step 'Run the resources'", create[create.index('--title') + 1])
        self.assertIn('boom', create[create.index('--body') + 1])

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

    def test_a_failure_on_a_commit_without_the_fix_leaves_the_issue_closed(self):
        signature = 'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError'
        closed = [issue(6, signature, [], ['W'], 'b' * 40, state='CLOSED')]
        for timeline in ([dict(event='closed', commit_id='f' * 40)],
                         [dict(event='commented', body=f"Fixed by {'f' * 40} (Fix it), landed on main."),
                          dict(event='closed', commit_id=None)]):
            fake = FakeGitHub([dict(id=1, name='j', conclusion='failure')], {1: BASH}, closed,
                              timeline, compare='behind')
            self.run_main(fake)
            self.assertIn(('api', f"repos/o/r/compare/{'f' * 40}...{'c' * 40}"), fake.calls)
            self.assertEqual(fake.made('reopen'), [])
            self.assertEqual(fake.made('edit'), [])
            [comment] = fake.made('comment')
            self.assertIn(f"predates its fix `{'f' * 40}`", comment[comment.index('--body') + 1])

            fake = FakeGitHub([dict(id=1, name='j', conclusion='failure')], {1: BASH}, closed,
                              timeline, compare='ahead')
            self.run_main(fake)
            self.assertEqual([call[2] for call in fake.made('reopen')], ['6'])

    def test_a_promotion_bisect_verdict_rides_on_the_failure_it_located(self):
        verdict = 'Promotion bisect: check: first fails at ' + 'd' * 40 + ' (Change the bash owner)'
        fake = FakeGitHub([dict(id=1, name='linux suites (check)', conclusion='failure')],
                          {1: BASH + logged('check: replay at ' + 'd' * 40 + ': failed (exit 1)') + logged(verdict)})
        self.run_main(fake, '--label', 'promotion-red')
        [create] = fake.made('create')
        body = create[create.index('--body') + 1]
        self.assertIn('bash_integration.py: assert process_exists', create[create.index('--title') + 1])
        self.assertIn(verdict, body)
        self.assertNotIn('replay at', body)
        self.assertEqual(report_issue.signature_state(body)['signature'],
                         'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError')
        self.assertNotIn('causes', body)

    def test_a_promotion_suspects_line_rides_on_the_failure_it_ranked(self):
        suspect = ('Promotion suspects: stack-frames: 1. ' + 'e' * 40 + ' PR #1692, tier b (import or rule): '
                   'Change the stack frames; touched src/server.zig')
        fake = FakeGitHub([dict(id=1, name='linux suites (check)', conclusion='failure')],
                          {1: BASH + logged('stack-frames: failed (exit 1)') + logged(suspect)
                           + logged('--- stack-frames: last 1 lines of the failed step\'s output ---')})
        self.run_main(fake, '--label', 'promotion-red')
        [create] = fake.made('create')
        body = create[create.index('--body') + 1]
        self.assertIn(suspect, body)
        self.assertNotIn('last 1 lines', body)

    def test_a_job_with_several_causes_carries_every_steps_verdict(self):
        verdicts = ['Promotion bisect: bash-integration: first fails at ' + 'd' * 40 + ' (Change the bash owner)',
                    'Promotion bisect: host-stop-integration: first fails at ' + 'e' * 40 + ' (Change Host stop)']
        fake = FakeGitHub([dict(id=1, name='linux suites (check)', conclusion='failure')],
                          {1: BASH + HOST_STOP + ''.join(logged(line) for line in verdicts)})
        self.run_main(fake, '--label', 'promotion-red')
        creates = fake.made('create')
        self.assertEqual(len(creates), 2)
        for create in creates:
            body = create[create.index('--body') + 1]
            for line in verdicts:
                self.assertIn(line, body)
            self.assertIn("The job 'linux suites (check)' failed with 2 causes", body)

    def test_only_failed_jobs_are_read(self):
        passing = (logged('::warning::check failed (exit 1); one automatic retry. A pass after this retry '
                          'is a flake to fix, not a clean pass.') + BASH)
        jobs = [dict(id=1, name='linux suites (check)', conclusion='success'),
                dict(id=2, name='linux suites (logic)', conclusion='failure'),
                dict(id=3, name='plan', conclusion='success')]
        fake = FakeGitHub(jobs, {1: passing, 2: GATE, 3: logged('planned')})
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
        self.assertNotIn('repos/o/r/actions/jobs/2/logs', [call[-1] for call in fake.calls])
        steps = re.findall(r'^      - name: (Require every selected .+)$', Path('.github/workflows/check.yml').read_text(),
                           re.M)
        # The Linux part check runs in linux (off pull requests) and in admission (on them), plus the Mac check.
        self.assertEqual(len(steps), 3)
        promotion = {name: re.findall(r'^      - name: (Require every selected .+)$',
                                      Path(f'.github/workflows/{name}').read_text(), re.M)
                     for name in ('qualification-tier.yml', 'promote.yml')}
        self.assertEqual(promotion, {'qualification-tier.yml': ['Require every selected qualification tier'],
                                     'promote.yml': []})
        gate = dict(id=3, name='mutations', conclusion='failure',
                    steps=[dict(name='Require behavioral kills in isolated source copies', conclusion='failure')])
        self.assertFalse(report_issue.aggregate_only(gate))

    def test_a_coloured_log_is_read_and_filed_under_its_cause(self):
        coloured = logged('\x1b[36;1mpython3 -B tests/integration/check.sh\x1b[0m') + BASH
        fake = FakeGitHub([dict(id=1, name='macos suites (native)', conclusion='failure')], {1: coloured})
        self.run_main(fake, '--label', 'stable-red')
        [create] = fake.made('create')
        self.assertIn('CI red: tests/integration/bash_integration.py: assert process_exists(child_pid) '
                      'raised AssertionError', create)
        self.assertNotIn('log unavailable', create[create.index('--title') + 1])

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


def numbered_log(count, prefix='build output line'):
    return logged(*(f"{prefix} {number}" for number in range(1, count + 1)))


class JobCauseTest(unittest.TestCase):
    def setUp(self):
        self.cases = report_issue.fixtures()

    def causes(self, log, name, steps, workflow='Promote'):
        job = dict(name=name, steps=[dict(name=step, conclusion=conclusion) for step, conclusion in steps])
        return report_issue.job_causes(log, self.cases, workflow, job)

    def test_aggregate_failing_only_on_its_requirement_is_skipped(self):
        for steps in ([('Set up job', 'success'), ('Require every selected Linux part', 'failure')],
                      [('Require every selected qualification tier', 'failure')]):
            with self.subTest(steps=steps):
                job = dict(name='qualify / selected / linux',
                           steps=[dict(name=name, conclusion=conclusion) for name, conclusion in steps])
                self.assertTrue(report_issue.aggregate_only(job))

    def test_aggregate_failing_on_its_requirement_and_explain_step_is_skipped(self):
        for steps in (
            [('Require every selected Linux part', 'failure'), ('Name each failed job and its cause', 'failure')],
            [('Require every selected Apple Silicon part', 'failure'),
             ('Name each failed job and its cause', 'failure')],
            [('Name each failed job and its cause', 'failure')],
        ):
            with self.subTest(steps=steps):
                job = dict(name='qualify / selected / macos',
                           steps=[dict(name=name, conclusion=conclusion) for name, conclusion in steps])
                self.assertTrue(report_issue.aggregate_only(job))

    def test_a_job_with_a_real_failed_step_beside_an_aggregate_step_is_not_skipped(self):
        job = dict(name='build (linux-x86_64)', steps=[dict(name='Build the artifact', conclusion='failure'),
                                                       dict(name='Name each failed job and its cause', conclusion='failure')])
        self.assertFalse(report_issue.aggregate_only(job))

    def test_a_matrix_job_with_an_unparsed_log_names_its_failed_step_and_keeps_the_log_tail(self):
        steps = [('Set up job', 'success'), ('Build the artifact', 'failure'), ('Upload', 'skipped')]
        first = self.causes(numbered_log(60), 'release_build / build (linux-x86_64)', steps,
                            workflow='Promote')
        second = self.causes(numbered_log(75, prefix='build output line, rerun'), 'release_build / build (linux-x86_64)',
                             steps, workflow='Promote')
        self.assertEqual([cause.signature for cause in first],
                         ["Promote: job 'release_build / build (linux-x86_64)' failed at step 'Build the artifact'"])
        self.assertEqual([cause.signature for cause in second], [cause.signature for cause in first])
        self.assertEqual(len(first[0].detail.splitlines()), report_issue.UNPARSED_TAIL_LINES)
        self.assertIn('build output line 60', first[0].detail)
        self.assertNotIn('build output line 1\n', first[0].detail + '\n')
        self.assertNotIn('2026-', first[0].detail)

    def test_several_failed_steps_are_all_named_in_the_signature(self):
        steps = [('Build the artifact', 'failure'), ('Test the artifact', 'failure')]
        [cause] = self.causes(numbered_log(3), 'linux suites (native)', steps)
        self.assertEqual(cause.signature,
                         "Promote: job 'linux suites (native)' failed at steps 'Build the artifact', 'Test the artifact'")

    def test_a_job_with_no_failed_step_recorded_still_has_a_stable_signature(self):
        [cause] = self.causes(numbered_log(2), 'plan', [('Set up job', 'success')])
        self.assertEqual(cause.signature, "Promote: job 'plan' failed with no failed step recorded")

    def test_a_timed_out_job_is_named_by_the_step_it_stopped_in(self):
        [cause] = self.causes(numbered_log(2), 'linux suites (check)',
                              [('Set up job', 'success'), ('check', 'cancelled'), ('Upload', 'skipped')])
        self.assertEqual(cause.signature, "Promote: job 'linux suites (check)' failed at step 'check'")

    def test_the_unparsed_tail_ends_where_the_failed_step_exited_not_in_later_cleanup(self):
        log = (numbered_log(50, prefix='build output line')
               + logged('##[error]Process completed with exit code 1.')
               + numbered_log(60, prefix='cleanup line'))
        [cause] = self.causes(log, 'linux suites (check)', [('check', 'failure')])
        self.assertIn('build output line 50', cause.detail)
        self.assertTrue(cause.detail.endswith('##[error]Process completed with exit code 1.'))
        self.assertNotIn('cleanup line', cause.detail)

    def test_a_rendered_body_stays_under_the_issue_limit_and_inside_its_fences(self):
        detail = '\n'.join(['~~~~~ closes a short fence', 'x' * 5000]
                           + [f'Promotion excerpt: step {n}: ' + 'y' * 300 for n in range(400)])
        state = dict(signature='W: job failed', paths=[])
        body = report_issue.render(state, detail)
        self.assertLess(len(body), 65536)
        self.assertIn(report_issue.TRUNCATED, body)
        self.assertNotIn('x' * (report_issue.DETAIL_LINE_WIDTH + 1), body)
        self.assertIn('\n~~~~~~\n~~~~~ closes a short fence', body)
        self.assertEqual(report_issue.signature_state(body), state)

    def test_a_job_whose_log_carries_excerpt_lines_is_described_by_them_not_by_its_tail(self):
        log = (numbered_log(50, prefix='early output')
               + logged('stack-frames: failed (exit 1)',
                        'Promotion excerpt: stack-frames: last 2 lines of the failed step\'s output:',
                        'Promotion excerpt: stack-frames: boom',
                        'Promotion excerpt: stack-frames: end of excerpt'))
        [cause] = self.causes(log, 'linux suites (stack-frames)', [('stack-frames', 'failure')])
        self.assertEqual(cause.signature, "Promote: job 'linux suites (stack-frames)' failed at step 'stack-frames'")
        self.assertIn('Promotion excerpt: stack-frames: boom', cause.detail)
        self.assertIn('Promotion excerpt: stack-frames: end of excerpt', cause.detail)
        self.assertNotIn('early output', cause.detail)

    def test_a_job_with_parsed_causes_keeps_its_signature_and_no_tail(self):
        [cause] = self.causes(BASH, 'macos suites (native)', [('Run the native tests', 'failure')])
        self.assertEqual(cause.signature,
                         'tests/integration/bash_integration.py: assert process_exists(child_pid) raised AssertionError')
        self.assertEqual(cause.detail, 'AssertionError')
        self.assertNotIn('bash failed', cause.detail)

    def test_a_job_with_parsed_causes_keeps_the_promotion_lines_that_locate_them(self):
        verdict = 'Promotion bisect: bash: first fails at ' + 'd' * 40 + ' (Change the bash owner)'
        [cause] = self.causes(BASH + logged(verdict), 'linux suites (check)', [('check', 'failure')])
        self.assertEqual(cause.detail, 'AssertionError\n' + verdict)

    def test_an_excerpt_only_log_has_no_fallback_cause(self):
        log = logged('Promotion excerpt: check: nothing parsed here')
        [cause] = self.causes(log, 'linux suites (check)', [('check', 'failure')])
        self.assertEqual(cause.detail, 'Promotion excerpt: check: nothing parsed here')

    def test_a_coloured_unparsed_log_tail_is_stripped_of_escape_codes(self):
        [cause] = self.causes(logged('\x1b[36;1mrunning\x1b[0m the step'), 'macos / resources',
                              [('Run the resources', 'failure')], workflow='W')
        self.assertIn('running the step', cause.detail)
        self.assertNotIn('\x1b', cause.detail)


if __name__ == '__main__':
    unittest.main()
