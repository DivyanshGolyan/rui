"""Infrastructure failures retry once; every other failure stays a check failure.

Logs and annotations are trimmed from real Selected checks runs: 42582862053
(GitHub answered 504), 41856442475 (no runner acquired macos_build),
42267648425 (pip could not resolve its host) and 42644396665 (Codeberg sent
no bytes before curl's deadline).
"""
from pathlib import Path
import re
import unittest

from failure_cause import AGGREGATES, INFRA_ACTIONS, INFRA_STEPS, cause, causes, retry_refusal

ROOT = Path(__file__).resolve().parents[2]
# Jobs of a Selected checks run come from these workflows.
WORKFLOWS = [ROOT / ".github/workflows/check.yml", ROOT / ".github/workflows/previous-release-upgrade.yml"]

LINTER_504 = """\
2026-11-09T08:02:55.1000000Z ##[group]Run python3 -m pip install ruff==0.17.0
2026-11-09T08:02:55.2000000Z Successfully installed ruff-0.17.0
2026-11-09T08:02:56.2973521Z ##[group]Run set -euo pipefail
2026-11-09T08:02:56.3608899Z curl: (22) The requested URL returned error: 504
2026-11-09T08:02:56.3609378Z Warning: Problem : HTTP error. Will retry in 1 seconds. 2 retries left.
2026-11-09T08:02:59.3783766Z curl: (22) The requested URL returned error: 504
2026-11-09T08:02:59.3810902Z ##[error]Process completed with exit code 22.
"""
PIP_UNRESOLVED = """\
2026-11-06T18:07:19.1272140Z   WARNING: Retrying (Retry(total=0)) after connection broken by 'NameResolutionError("HTTPSConnection(host='files.pythonhosted.org', port=443): Failed to resolve")'
2026-11-06T18:07:19.1371600Z error: connection-failed
2026-11-06T18:07:19.2200090Z ##[error]Process completed with exit code 1.
"""
CODEBERG_TIMEOUT = """\
2026-11-09T15:28:08.2115305Z Preparing pinned translate_c dependency ...
2026-11-09T15:32:41.2263935Z   0     0    0     0    0     0      0      0 --:--:--  0:01:30 --:--:--     0
2026-11-09T15:32:41.2264391Z curl: (28) Operation timed out after 90001 milliseconds with 0 bytes received
2026-11-09T15:32:41.2320703Z ##[error]Process completed with exit code 28.
"""
CHECKSUM = """\
2026-11-09T08:02:56.2973521Z ##[group]Run set -euo pipefail
2026-11-09T08:02:57.0000000Z sha256sum: WARNING: 1 computed checksum did NOT match
2026-11-09T08:02:57.1000000Z ##[error]Process completed with exit code 1.
"""
HOST_CRASH = """\
2026-11-09T09:00:00.0000000Z ##[group]Run set -euo pipefail
2026-11-09T09:04:00.0000000Z ConnectionResetError: [Errno 104] Connection reset by peer
2026-11-09T09:04:01.0000000Z ##[error]Process completed with exit code 1.
"""


def step(name, conclusion, started="2026-11-09T08:02:56Z", completed="2026-11-09T08:02:59Z"):
    return dict(name=name, conclusion=conclusion, started_at=started, completed_at=completed)


def job(name, *steps, conclusion="failure", status="completed"):
    return dict(id=1, name=name, status=status, conclusion=conclusion, steps=list(steps))


class CauseTest(unittest.TestCase):
    def test_a_network_error_in_a_failed_fetch_step_is_infrastructure(self):
        linter = job("policy", step("Install the pinned workflow linter", "failure"))
        self.assertEqual(cause(linter, [], LINTER_504),
                         ("infra", "failure at 'Install the pinned workflow linter': returned error: 504"))
        setup = job("macos_build", step("Run ./.github/actions/setup", "failure",
                                        "2026-11-06T18:05:00Z", "2026-11-06T18:07:19Z"))
        self.assertEqual(cause(setup, [], PIP_UNRESOLVED)[0], "infra")
        stalled = job("macos_typecheck", step("Run ./.github/actions/setup", "failure",
                                              "2026-11-09T15:28:00Z", "2026-11-09T15:32:41Z"))
        self.assertEqual(cause(stalled, [], CODEBERG_TIMEOUT)[0], "infra")

    def test_the_same_network_text_in_a_test_step_is_a_check_failure(self):
        # A Host crash resets every suite's connection (#915); that is a product bug.
        suite = job("linux suites (dispatch-integration)",
                    step("Run selected targets", "failure", "2026-11-09T09:00:00Z", "2026-11-09T09:04:01Z"))
        self.assertEqual(cause(suite, [], HOST_CRASH), ("check", "failure at 'Run selected targets'"))
        self.assertEqual(cause(suite, [], LINTER_504)[0], "check")

    def test_a_fetch_step_failing_without_a_network_error_is_a_check_failure(self):
        linter = job("policy", step("Install the pinned workflow linter", "failure"))
        self.assertEqual(cause(linter, [], CHECKSUM)[0], "check")
        self.assertEqual(cause(linter, [], None)[0], "check", "an unread log proves no network failure")

    def test_only_the_failed_steps_own_log_lines_count(self):
        # The 504 belongs to the linter step; a later step's failure stays a check failure.
        later = job("policy", step("Install the pinned workflow linter", "success"),
                    step("Install the pinned packages tests/ci imports", "failure",
                         "2026-11-09T08:03:00Z", "2026-11-09T08:03:05Z"))
        log = LINTER_504 + "2026-11-09T08:03:01.0000000Z ERROR: No matching distribution found for h2==9\n"
        self.assertEqual(cause(later, [], log)[0], "check")
        earlier = job("policy", step("Install the pinned packages tests/ci imports", "failure",
                                     "2026-11-09T08:02:55Z", "2026-11-09T08:02:55Z"))
        self.assertEqual(cause(earlier, [], LINTER_504)[0], "check", "the 504 came a second after this step ended")
        overcome = job("policy", step("Install the pinned workflow linter", "failure"))
        retried = LINTER_504.replace("##[error]", "".join(
            f"2026-11-09T08:02:59.{n:07d}Z unpacking file {n}\n" for n in range(30)) + "2026-11-09T08:02:59.9Z ##[error]")
        self.assertEqual(cause(overcome, [], retried)[0], "check", "a 504 long before the step stopped is not why")

    def test_a_job_no_runner_ran_or_kept_is_infrastructure(self):
        unacquired = job("macos_build", conclusion="cancelled")
        note = "The job was not acquired by Runner of type hosted even after multiple attempts"
        self.assertEqual(cause(unacquired, [note], None), ("infra", note))
        self.assertEqual(cause(unacquired, [], None)[0], "infra")
        lost = job("linux suites (check)", step("Run selected targets", "failure"))
        self.assertEqual(cause(lost, ["The runner has received a shutdown signal."], None)[0], "infra")
        queued = job("linux suites (check)", conclusion=None, status="queued")
        self.assertEqual(cause(queued, [], None), ("infra", "no runner took the job"))

    def test_a_cancelled_build_or_test_step_is_a_check_failure(self):
        # A timeout cancels the job; a hang in compilation or a test is not infrastructure.
        for name in ("Compile selected gates once, never test acceptance", "Run selected targets"):
            with self.subTest(step=name):
                self.assertEqual(cause(job("macos_build", step(name, "cancelled"), conclusion="cancelled"), [], None)[0],
                                 "check")
        slow_setup = job("macos_build", step("Run ./.github/actions/setup", "cancelled"), conclusion="cancelled")
        self.assertEqual(cause(slow_setup, [], None)[0], "infra")

    def test_aggregates_and_unfinished_jobs_are_not_causes_while_the_run_goes_on(self):
        jobs = [job(name, step("Require every selected Linux part", "failure")) for name in AGGREGATES]
        jobs += [job("plan", conclusion="success"), job("macos_build", conclusion="skipped"),
                 job("macos suites (check)", conclusion=None, status="queued"),
                 job("macos_build_unit", step("Run ./.github/actions/setup", "in_progress"), conclusion=None,
                     status="in_progress")]
        self.assertEqual(causes(jobs, lambda job: [], lambda job: None, finished=False), [])
        self.assertEqual([name for name, *_ in causes(jobs, lambda job: [], lambda job: None)],
                         ["macos suites (check)", "macos_build_unit"])

    def test_infra_steps_name_steps_that_exist(self):
        text = "\n".join(path.read_text() for path in WORKFLOWS)
        names = set(re.findall(r"(?m)^      - name: (.+)$", text))
        self.assertEqual(sorted(INFRA_STEPS - names - {"Set up job"}), [], "a renamed step stops counting as infra")
        uses = {use.split("@")[0] for use in re.findall(r"(?m)^      - uses: (\S+)", text)}
        self.assertEqual(sorted(set(INFRA_ACTIONS) - uses), [])


class WiringTest(unittest.TestCase):
    def test_each_aggregate_names_its_causes_when_it_fails(self):
        text = WORKFLOWS[0].read_text()
        for name in AGGREGATES:
            with self.subTest(aggregate=name):
                body = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)", text)[1]
                explain = body.split("      - name: Name each failed job and its cause\n", 1)[1]
                self.assertIn("if: ${{ failure() }}", explain)
                self.assertIn("python3 -B tests/ci/failure_cause.py explain", explain)

    def test_the_retry_runs_trusted_code_once_per_failed_pr_run(self):
        text = (ROOT / ".github/workflows/infra-retry.yml").read_text()
        self.assertIn("workflows: [Selected checks]", text)
        for condition in ("github.event.workflow_run.conclusion == 'failure'",
                          "github.event.workflow_run.event == 'pull_request'",
                          "github.event.workflow_run.run_attempt == 1"):
            self.assertIn(condition, text)
        self.assertIn("ref: ${{ github.sha }}", text)
        self.assertIn('failure_cause.py retry --run-id "$RUN_ID"', text)


class RetryTest(unittest.TestCase):
    RUN = dict(conclusion="failure", event="pull_request", run_attempt=1, head_sha="a" * 40)
    INFRA = [("policy", "infra", "failure at 'Install the pinned workflow linter': returned error: 504")]

    def test_infrastructure_only_on_the_first_attempt_of_the_current_head_retries(self):
        self.assertIsNone(retry_refusal(self.RUN, self.INFRA, "a" * 40))

    def test_anything_else_does_not_retry(self):
        cases = {
            "a check failed too": (self.RUN, self.INFRA + [("linux suites (check)", "check", "failure")], "a" * 40),
            "only an aggregate failed (a draft)": (self.RUN, [], "a" * 40),
            "already retried once": (dict(self.RUN, run_attempt=2), self.INFRA, "a" * 40),
            "a newer push superseded it": (dict(self.RUN, conclusion="cancelled"), self.INFRA, "a" * 40),
            "the PR moved on": (self.RUN, self.INFRA, "b" * 40),
            "no open PR": (self.RUN, self.INFRA, None),
            "a diagnostic dispatch": (dict(self.RUN, event="workflow_dispatch"), self.INFRA, "a" * 40),
        }
        for name, (run, found, head) in cases.items():
            with self.subTest(name):
                self.assertIsNotNone(retry_refusal(run, found, head))


if __name__ == "__main__":
    unittest.main()
