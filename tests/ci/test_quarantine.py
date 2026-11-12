"""Listed flakes stop blocking PR admission only while every failure is listed, unexpired and not strict."""
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import quarantine
import run_selected
from report_issue import fixtures

ROOT = Path(__file__).resolve().parents[2]
CODEX = "tests/integration/codex_h2_integration.py"
FLAKE = dict(
    signature=f'{CODEX}: assert "transport reactor initialization failure: HttpsProxySchemeUnsupported" '
              'in required.stderr, required raised AssertionError',
    path=CODEX, issue=1093, owner="DivyanshGolyan", added="2026-11-09", expires="2026-11-23")
# A direct gate's output as zig build prints it (#1093).
FLAKY_RUN = f"""\
Traceback (most recent call last):
  File "/home/runner/work/rui/rui/{CODEX}", line 449, in <module>
    catalog_unusable_proxy_run()
  File "/home/runner/work/rui/rui/{CODEX}", line 365, in catalog_unusable_proxy_run
    assert "transport reactor initialization failure: HttpsProxySchemeUnsupported" in required.stderr, required
AssertionError: CompletedProcess(args=['rui'], returncode=1, stderr='[internal_unexpected]')
error: process exited with code 1
failed command: python3 /home/runner/work/rui/rui/{CODEX} ./.zig-cache/o/ci-compiled/rui-release-safe
"""
OTHER_FIXTURE = """\
Traceback (most recent call last):
  File "/home/runner/work/rui/rui/tests/integration/transport_h2_integration.py", line 80, in <module>
    assert reply.status == 200, reply
AssertionError: 503
error: process exited with code 1
failed command: python3 /home/runner/work/rui/rui/tests/integration/transport_h2_integration.py ./rui
"""
# A gate that exits nonzero without output any parser recognises.
SILENT_GATE = """\
error: process exited with code 1
failed command: ./.zig-cache/o/abc/frame-gate
"""
ZIG_TEST = """\
3/40 h2.test.settings ack...FAIL (TestUnexpectedResult)
error: process exited with code 1
failed command: ./.zig-cache/o/abc/test-h2
"""


def summary(failed, total=4):
    return f"Build Summary: {total - failed}/{total} steps succeeded ({failed} failed)\n"


def listed(output, day="2026-11-10", flakes=(FLAKE,)):
    return quarantine.listed(output, list(flakes), day, fixtures())


class ListTest(unittest.TestCase):
    def test_the_committed_list_is_valid(self):
        self.assertEqual(quarantine.problems(quarantine.entries(), ROOT), [])

    def test_each_rule_rejects_its_violation(self):
        cases = {
            "an owner": dict(FLAKE, owner=""),
            "an issue": dict(FLAKE, issue=None),
            "a window over 14 days": dict(FLAKE, expires="2026-11-24"),
            "an expiry after it was added": dict(FLAKE, expires="2026-11-09"),
            "ISO dates": dict(FLAKE, expires="next week"),
            "a strict path (recovery)": dict(FLAKE, path="tests/integration/bash_integration.py",
                                             signature="tests/integration/bash_integration.py: x raised E"),
            "an upgrade test": dict(FLAKE, path="tests/integration/upgrade_integration.py",
                                    signature="tests/integration/upgrade_integration.py: x raised E"),
            "a Store unit test": dict(FLAKE, path="src/store/tests.zig", signature="zig test 'store x' failed (E)"),
            "a Store test named outside src/store": dict(FLAKE, path="src/tests.zig",
                                                         signature="zig test 'store.tests.x' failed (E)"),
            "a Store test whose name has apostrophes": dict(FLAKE, path="src/launch_frame.zig", signature=(
                "zig test 'launch_frame.test.a launched Host's start failure is refused with its Store's "
                "codes only' failed (TestUnexpectedResult)")),
            "a crashed Store test": dict(FLAKE, path="src/tests.zig",
                                         signature="zig test 'store.tests.x' terminated with signal SIGABRT"),
            "a Store fixture": dict(FLAKE, path="tests/integration/store_rounds_cases.py",
                                    signature="tests/integration/store_rounds_cases.py: x raised E"),
            "the fixture's path first": dict(FLAKE, signature="assert x raised AssertionError"),
            "an existing file": dict(FLAKE, path="tests/integration/gone.py",
                                     signature="tests/integration/gone.py: x raised E"),
            "exactly the six fields": dict(FLAKE, reason="flaky"),
        }
        for rule, entry in cases.items():
            with self.subTest(rule):
                self.assertNotEqual(quarantine.problems([entry], ROOT), [])
        self.assertNotEqual(quarantine.problems([FLAKE, FLAKE], ROOT), [], "a signature is listed once")
        self.assertEqual(quarantine.problems([FLAKE], ROOT), [])

    def test_a_failing_line_that_mentions_a_store_does_not_make_a_store_test(self):
        restoration = "tests/integration/terminal_restoration_integration.py"
        entry = dict(FLAKE, path=restoration, signature=f'{restoration}: caller = spawn([str(fixture.RUI), '
                     '"session", "resume", "--store", str(store), "--", session]) raised PermissionError')
        self.assertEqual(quarantine.problems([entry], ROOT), [])


class ListedTest(unittest.TestCase):
    def test_a_run_failing_only_on_a_listed_signature_is_a_listed_flake(self):
        self.assertEqual(listed(FLAKY_RUN + summary(1)), [FLAKE])

    def test_any_other_failure_in_the_batch_keeps_it_red(self):
        for name, output in (("another fixture", FLAKY_RUN + OTHER_FIXTURE + summary(2)),
                             ("a Zig test", FLAKY_RUN + ZIG_TEST + summary(2)),
                             ("a gate failing without a parsed cause", FLAKY_RUN + SILENT_GATE + summary(2)),
                             ("a failed step without a command, such as a compile error", FLAKY_RUN + summary(2)),
                             ("no build summary", FLAKY_RUN)):
            with self.subTest(name):
                self.assertEqual(listed(output), [])
        self.assertEqual(listed(OTHER_FIXTURE + summary(1)), [])

    def test_a_listing_counts_only_from_its_first_to_its_last_day(self):
        self.assertEqual(listed(FLAKY_RUN + summary(1), day="2026-11-23"), [FLAKE])
        self.assertEqual(listed(FLAKY_RUN + summary(1), day="2026-11-24"), [], "expired: blocks again")
        self.assertEqual(listed(FLAKY_RUN + summary(1), day="2026-11-08"), [])


class RunSelectedTest(unittest.TestCase):
    """run_selected's verdict for a batch whose runs return these results in turn."""

    def verdict(self, mode, *runs):
        runs = list(runs)
        calls = []

        def execute(batch, artifacts):
            calls.append(batch)
            return runs.pop(0)

        with tempfile.TemporaryDirectory() as scratch, \
                patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(Path(scratch, "summary")), RUNNER_TEMP=scratch), \
                patch.object(run_selected, "execute", execute), \
                patch.object(quarantine, "entries", return_value=[FLAKE]), \
                patch.object(quarantine, "today", return_value="2026-11-10"), \
                patch.object(sys, "argv", ["run_selected.py", '["codex-h2-integration"]', "--quarantine", mode]), \
                redirect_stdout(io.StringIO()):
            try:
                run_selected.main()
                code = 0
            except SystemExit as exit:
                code = exit.code
        return code, len(calls)

    FLAKY = (1, FLAKY_RUN + summary(1))
    PASS = (0, "")
    REAL = (1, OTHER_FIXTURE + summary(1))

    def test_admission_reruns_a_listed_flake_and_does_not_block_on_it(self):
        self.assertEqual(self.verdict("admission", self.FLAKY, self.PASS), (0, 2))
        self.assertEqual(self.verdict("admission", self.FLAKY, self.FLAKY), (0, 2))
        self.assertEqual(self.verdict("admission", self.FLAKY, self.REAL), (1, 2))

    def test_promotion_blocks_only_on_two_consecutive_failures(self):
        self.assertEqual(self.verdict("promotion", self.FLAKY, self.PASS), (0, 2))
        self.assertEqual(self.verdict("promotion", self.FLAKY, self.FLAKY), (1, 2))

    def test_a_real_failure_or_a_strict_change_never_reruns(self):
        self.assertEqual(self.verdict("admission", self.REAL), (1, 1))
        self.assertEqual(self.verdict("off", self.FLAKY), (1, 1))


if __name__ == "__main__":
    unittest.main()
