from pathlib import Path
import re
import unittest

from failure_cause import (AGGREGATES, INFRA_ACTIONS, INFRA_STEPS, PINNED, PROMOTE_AGGREGATES, cause, causes,
                           retry_refusal)

ROOT = Path(__file__).resolve().parents[2]
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


def job(name, *steps, conclusion="failure", status="completed", labels=("ubuntu-24.04",)):
    return dict(id=1, name=name, status=status, conclusion=conclusion, steps=list(steps), labels=list(labels))


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
        suite = job("linux suites (dispatch-integration)",
                    step("Run selected targets", "failure", "2026-11-09T09:00:00Z", "2026-11-09T09:04:01Z"))
        self.assertEqual(cause(suite, [], HOST_CRASH), ("check", "failure at 'Run selected targets'"))
        self.assertEqual(cause(suite, [], LINTER_504)[0], "check")

    def test_a_fetch_step_failing_without_a_network_error_is_a_check_failure(self):
        linter = job("policy", step("Install the pinned workflow linter", "failure"))
        self.assertEqual(cause(linter, [], CHECKSUM)[0], "check")
        self.assertEqual(cause(linter, [], None)[0], "check", "an unread log proves no network failure")

    def test_only_the_failed_steps_own_log_lines_count(self):
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

    def test_promotion_aggregates_under_their_caller_job_are_not_causes(self):
        # The shared tier nests under Promote's qualify job: "qualify / selected / linux".
        verdicts = [job(f"qualify / selected / {name}", step("Require every selected Linux part", "failure"))
                    for name in AGGREGATES]
        verdicts += [job(f"qualify / {name}", step("Require every selected qualification tier", "failure"))
                     for name in PROMOTE_AGGREGATES]
        unacquired = job("qualify / selected / macos suites (check)", conclusion="cancelled", labels=("macos-15",))
        found = causes(verdicts + [unacquired], lambda job: [], lambda job: None)
        self.assertEqual(found, [("qualify / selected / macos suites (check)", "infra", "cancelled before any step ran")])

    def test_a_job_routed_to_the_personal_mac_says_so(self):
        lost = job("macos_build", conclusion="cancelled", labels=("self-hosted", "macOS", "ARM64", "rui-mac"))
        self.assertEqual(causes([lost], lambda job: [], lambda job: None),
                         [("macos_build", "infra", "cancelled before any step ran" + PINNED)])

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

    def test_promotion_publishes_only_after_its_verdict(self):
        tier = (ROOT / ".github/workflows/qualification-tier.yml").read_text()
        for name in PROMOTE_AGGREGATES:
            body = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)", tier)[1]
            self.assertIn("needs: [release_build, selected, upgrade, renderer]", body)
        text = (ROOT / ".github/workflows/promote.yml").read_text()
        release = re.search(r"(?ms)^  release:\n(.*?)(?=^  [a-z_]+:|\Z)", text)[1]
        # A rerun reruns the failed tier jobs, its verdict and Release, which waits for the rerun verdict.
        self.assertIn("needs: [batch, qualify]", release, "a rerun's Release waits for the rerun verdict")
        self.assertIn("if: ${{ !cancelled() && needs.batch.result == 'success' && needs.batch.outputs.size != '0' && "
                      "(needs.batch.outputs.reuse == 'true' || needs.qualify.result == 'success') && "
                      "!(github.event_name == 'schedule' && vars.SCHEDULED_RELEASES == 'paused') }}", release,
                      "Release runs only on a reused green record or a successful tier")

    def test_a_red_scheduled_head_fails_as_a_check_so_no_retry_reruns_it(self):
        # main_qualified's red HEAD: Promote's batch fails at the step after the choice, which must classify as a check.
        text = (ROOT / ".github/workflows/promote.yml").read_text()
        step = re.search(r"(?ms)^      - name: (Fail a scheduled run whose main HEAD is red)\n(.*?)(?=^      - name: |^  \w|\Z)",
                         text)
        self.assertIn("if: ${{ steps.batch.outputs.red_run != '' }}", step[2])
        stamp = "2026-11-22T10:00:00Z"
        job = {"id": 1, "name": "batch", "status": "completed", "conclusion": "failure", "labels": ["ubuntu-24.04"],
               "steps": [{"name": "Set up job", "conclusion": "success", "started_at": stamp, "completed_at": stamp},
                         {"name": step[1], "conclusion": "failure", "started_at": stamp, "completed_at": stamp}]}
        found = causes([job], lambda _: [], lambda _: None)
        self.assertEqual([kind for _, kind, _ in found], ["check"])
        run = dict(id=7, name="Promote", event="schedule", conclusion="failure", run_attempt=1, head_sha="a" * 40)
        self.assertEqual(retry_refusal(run, found, 7), "checks failed: batch")
        # qualify has no status function, so a failed batch skips it; Release needs batch's result to be success.
        qualify = re.search(r"(?ms)^  qualify:\n(.*?)(?=^  \w)", text)[1]
        self.assertIn("if: ${{ needs.batch.outputs.size != '0' && needs.batch.outputs.reuse != 'true' }}", qualify)
        self.assertNotIn("always()", qualify)

    def test_the_retry_runs_trusted_code_once_per_failed_pr_run_or_promotion(self):
        text = (ROOT / ".github/workflows/infra-retry.yml").read_text()
        self.assertIn("workflows: [Selected checks, Promote]", text)
        for condition in ("github.event.workflow_run.conclusion == 'failure'",
                          "github.event.workflow_run.event == 'pull_request'",
                          "github.event.workflow_run.name == 'Promote' && "
                          "(github.event.workflow_run.event == 'workflow_dispatch' || "
                          "github.event.workflow_run.event == 'schedule')",
                          "github.event.workflow_run.run_attempt == 1"):
            self.assertIn(condition, text)
        self.assertIn("ref: ${{ github.sha }}", text)
        self.assertIn('failure_cause.py retry --run-id "$RUN_ID"', text)


class RetryTest(unittest.TestCase):
    RUN = dict(id=7, name="Selected checks", conclusion="failure", event="pull_request", run_attempt=1,
               head_sha="a" * 40)
    PROMOTION = dict(RUN, name="Promote", event="workflow_dispatch")
    INFRA = [("policy", "infra", "failure at 'Install the pinned workflow linter': returned error: 504")]

    def test_infrastructure_only_on_the_first_attempt_of_the_current_head_retries(self):
        self.assertIsNone(retry_refusal(self.RUN, self.INFRA, "a" * 40))

    def test_infrastructure_only_on_the_first_attempt_of_the_latest_promotion_retries(self):
        self.assertIsNone(retry_refusal(self.PROMOTION, self.INFRA, 7))
        unacquired = [("release / build (darwin-arm64)", "infra", "cancelled before any step ran")]
        self.assertIsNone(retry_refusal(self.PROMOTION, unacquired, 7))

    def test_each_kind_of_run_retries_exactly_as_its_row_says(self):
        # Rows: run kind, the run's head or the newest run of its workflow, and whether one rerun is allowed.
        scheduled = dict(self.PROMOTION, event="schedule")
        other_schedule = dict(self.RUN, name="Renderer contracts", event="schedule")
        table = (
            ("pull request on its head", self.RUN, self.INFRA, "a" * 40, True),
            ("pull request on a moved head", self.RUN, self.INFRA, "b" * 40, False),
            ("Promote dispatch, latest", self.PROMOTION, self.INFRA, 7, True),
            ("Promote dispatch, superseded", self.PROMOTION, self.INFRA, 8, False),
            ("Promote schedule, latest", scheduled, self.INFRA, 7, True),
            ("Promote schedule, superseded by a dispatch", scheduled, self.INFRA, 8, False),
            ("Promote schedule, superseded by a schedule", scheduled, self.INFRA, 9, False),
            ("another workflow's schedule", other_schedule, self.INFRA, "a" * 40, False),
            ("push", dict(self.RUN, event="push"), self.INFRA, "a" * 40, False),
            ("Promote push", dict(self.PROMOTION, event="push"), self.INFRA, 7, False),
        )
        for name, run, found, current, retries in table:
            with self.subTest(name):
                self.assertEqual(retry_refusal(run, found, current) is None, retries)

    def test_anything_else_does_not_retry(self):
        cases = {
            "a check failed too": (self.RUN, self.INFRA + [("linux suites (check)", "check", "failure")], "a" * 40),
            "only an aggregate failed (a draft)": (self.RUN, [], "a" * 40),
            "already retried once": (dict(self.RUN, run_attempt=2), self.INFRA, "a" * 40),
            "a newer push superseded it": (dict(self.RUN, conclusion="cancelled"), self.INFRA, "a" * 40),
            "the PR moved on": (self.RUN, self.INFRA, "b" * 40),
            "no open PR": (self.RUN, self.INFRA, None),
            "a diagnostic dispatch": (dict(self.RUN, event="workflow_dispatch"), self.INFRA, "a" * 40),
            "a job on the personal Mac": (self.RUN, [("macos_build", "infra", "lost" + PINNED)], "a" * 40),
            "a promotion's check failed": (self.PROMOTION, self.INFRA + [("qualify / selected / linux suites (check)",
                                                                          "check", "failure")], 7),
            "a promotion's verdict alone failed": (self.PROMOTION, [], 7),
            "a promotion already retried": (dict(self.PROMOTION, run_attempt=2), self.INFRA, 7),
            "a promotion cancelled": (dict(self.PROMOTION, conclusion="cancelled"), self.INFRA, 7),
            "a later promotion": (self.PROMOTION, self.INFRA, 8),
            "a scheduled promotion, then a later one": (dict(self.PROMOTION, event="schedule"), self.INFRA, 8),
            "a scheduled promotion's check failed": (dict(self.PROMOTION, event="schedule"),
                                                     self.INFRA + [("qualify / selected / linux suites (check)",
                                                                    "check", "failure")], 7),
            "no promotion listed": (self.PROMOTION, self.INFRA, None),
            "a promotion on the personal Mac": (self.PROMOTION, [("selected / macos_build", "infra", "lost" + PINNED)],
                                                7),
            "Promote's name on another event": (dict(self.PROMOTION, event="push"), self.INFRA, 7),
            "another workflow's dispatch": (dict(self.PROMOTION, name="Renderer contracts"), self.INFRA, 7),
        }
        for name, (run, found, head) in cases.items():
            with self.subTest(name):
                self.assertIsNotNone(retry_refusal(run, found, head))


if __name__ == "__main__":
    unittest.main()
