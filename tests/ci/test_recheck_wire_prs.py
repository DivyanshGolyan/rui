"""Wire-release invalidation reruns only the current PR's policy job checked before publication."""
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import recheck_wire_prs as owner


REPO = "owner/repo"
FORK = "contributor/repo"
# Fixture runs and policy jobs start before publication unless a test says otherwise.
PUBLISHED_AT = "2026-11-13T12:00:00Z"
PUBLISHED = owner.timestamp(PUBLISHED_AT)
BEFORE, AT, AFTER = "2026-11-13T11:00:00Z", PUBLISHED_AT, "2026-11-13T12:00:01Z"


def head(number=1, repo=REPO, sha=None):
    return {"sha": sha or ("current-head" if number == 1 else f"head-{number}"), "repo": {"full_name": repo}}


def pull(number=1, **changes):
    return {"number": number, "state": "open", "draft": False,
            "base": {"ref": "main"}, "head": head(number), **changes}


def run(run_id=10, **changes):
    return {"id": run_id, "run_number": run_id, "run_attempt": 1, "event": "pull_request", "path": ".github/workflows/check.yml",
            "head_sha": "current-head", "head_repository": {"full_name": REPO}, "pull_requests": [{"number": 1}],
            "status": "completed", "run_started_at": BEFORE, **changes}


def job(job_id=100, **changes):
    return {"id": job_id, "run_id": 10, "run_attempt": 1, "name": "policy", "status": "completed", "conclusion": "success",
            "started_at": BEFORE, **changes}


def files(*names):
    return [{"filename": name} for name in names]


def workflow_job(workflow, name):
    return re.search(rf"^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)", workflow, re.M | re.S)[1]


def permissions(job_body):
    block = re.search(r"^    permissions:\n((?:      [^\n]+\n)+)", job_body, re.M)[1]
    return dict(line.strip().split(": ") for line in block.splitlines())


class SelectionTest(unittest.TestCase):
    def select(self, pr=None, changed=None, runs=None, jobs=None):
        return owner.select_rerun(pull() if pr is None else pr,
                                  files("openapi.json") if changed is None else changed,
                                  [run()] if runs is None else runs,
                                  [job()] if jobs is None else jobs, PUBLISHED)

    def test_each_wire_owner_qualifies_in_a_mixed_file_list(self):
        for name in ("openapi.json", "src/wire_version.zig"):
            with self.subTest(name=name):
                self.assertEqual(self.select(changed=files("README.md", name)).job_id, 100)

    def test_non_contract_files_do_not_qualify(self):
        for changed in ([], files("src/protocol.zig"), files("README.md", "nested/openapi.json"),
                        files("src/wire_version.zig.bak")):
            with self.subTest(changed=changed):
                self.assertIsNone(self.select(changed=changed).job_id)

    def test_rename_away_from_wire_owner_qualifies(self):
        for name in ("openapi.json", "src/wire_version.zig"):
            with self.subTest(name=name):
                self.assertEqual(self.select(changed=[{"filename": "moved", "previous_filename": name}]).job_id, 100)

    def test_only_open_non_draft_main_prs(self):
        for pr in (pull(draft=True), pull(base={"ref": "stable"}), pull(state="closed")):
            with self.subTest(pr=pr):
                self.assertIsNone(self.select(pr=pr).job_id)

    def test_no_check_run_yet_is_a_skip(self):
        selection = self.select(runs=[])
        self.assertIsNone(selection.job_id)
        self.assertIn("no check.yml PR run", selection.reason)

    def test_latest_active_run_never_falls_back_to_completed_green(self):
        for status in ("queued", "in_progress", "waiting", "requested", "pending"):
            with self.subTest(status=status):
                selection = self.select(runs=[run(20, status=status), run()])
                self.assertIsNone(selection.job_id)
                self.assertIn(f"latest run 20 is {status}", selection.reason)
                self.assertTrue(selection.waiting)

    def test_newest_completed_run_selects_its_policy_not_the_old_run(self):
        self.assertEqual(self.select(runs=[run(), run(20)],
                                     jobs=[job(), job(200, run_id=20)]).job_id, 200)

    def test_latest_is_workflow_sequence_not_global_id_order(self):
        self.assertEqual(self.select(runs=[run(30, run_number=1), run(20, run_number=2)],
                                     jobs=[job(200, run_id=20)]).job_id, 200)

    def test_runs_must_match_head_sha_head_repository_event_and_workflow(self):
        for unrelated in (run(20, head_sha="old-head"), run(20, head_repository={"full_name": FORK}),
                          run(20, head_repository=None), run(20, event="push"),
                          run(20, path=".github/workflows/promote.yml")):
            with self.subTest(unrelated=unrelated):
                self.assertEqual(self.select(runs=[unrelated, run()], jobs=[job(), job(200, run_id=20)]).job_id, 100)
                self.assertIsNone(self.select(runs=[unrelated], jobs=[job(200, run_id=20)]).job_id)

    def test_fork_head_run_without_pull_requests_is_the_prs_run(self):
        # GitHub lists no pull_requests on a run whose head is in a fork.
        fork_pr = pull(head=head(repo=FORK))
        fork_run = run(head_repository={"full_name": FORK}, pull_requests=[])
        self.assertEqual(self.select(pr=fork_pr, runs=[fork_run]).job_id, 100)
        self.assertIsNone(self.select(pr=fork_pr, runs=[run()]).job_id)

    def test_pr_without_head_repository_matches_no_run(self):
        self.assertIsNone(self.select(pr=pull(head={"sha": "current-head", "repo": None}),
                                      runs=[run(head_repository=None)]).job_id)

    def test_policy_started_at_or_after_publication_needs_no_wait_or_rerun(self):
        for status in ("completed", "in_progress"):
            for started in (AT, AFTER):
                with self.subTest(status=status, started=started):
                    selection = self.select(runs=[run(status=status)],
                                            jobs=[job(status=status, started_at=started)])
                    self.assertIsNone(selection.job_id)
                    self.assertFalse(selection.waiting)
                    self.assertIn("checks after publication", selection.reason)

    def test_policy_started_before_publication_waits_then_reruns(self):
        waiting = self.select(runs=[run(status="in_progress")], jobs=[job(status="completed")])
        self.assertTrue(waiting.waiting)
        self.assertEqual(self.select(runs=[run()], jobs=[job()]).job_id, 100)

    def test_unstarted_policy_uses_the_run_start(self):
        for policy in ([], [job(status="queued", started_at=AFTER)], [job(status="waiting", started_at=AFTER)]):
            with self.subTest(policy=policy):
                before = self.select(runs=[run(status="in_progress")], jobs=policy)
                self.assertTrue(before.waiting)
                after = self.select(runs=[run(status="in_progress", run_started_at=AT)], jobs=policy)
                self.assertFalse(after.waiting)
                self.assertIn("checks after publication", after.reason)

    def test_restarted_attempt_uses_its_own_policy_start(self):
        # A rerun of the run after publication is a new attempt that reads the tag itself.
        attempt = run(run_attempt=2, run_started_at=AFTER)
        self.assertIsNone(self.select(runs=[attempt], jobs=[job(run_attempt=2, started_at=AFTER)]).job_id)
        self.assertEqual(self.select(runs=[attempt], jobs=[job(run_attempt=2)]).job_id, 100)

    def test_publication_time_must_be_a_zoned_github_timestamp(self):
        for value in (None, "", "null", "2026-11-13T12:00:00"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                owner.timestamp(value)

    def test_only_completed_non_skipped_policy_job_in_selected_run(self):
        for jobs in ([], [job(name="admission")], [job(run_id=9)], [job(run_attempt=2)],
                     [job(status="in_progress")], [job(status="queued")], [job(conclusion="skipped")]):
            with self.subTest(jobs=jobs):
                self.assertIsNone(self.select(jobs=jobs).job_id)
        for conclusion in ("success", "failure", "cancelled", "timed_out", "action_required"):
            with self.subTest(conclusion=conclusion):
                self.assertEqual(self.select(jobs=[job(conclusion=conclusion)]).job_id, 100)

    def test_ambiguous_policy_jobs_fail_loudly(self):
        with self.assertRaisesRegex(ValueError, "multiple latest policy"):
            self.select(jobs=[job(), job(101)])


class GitHub:
    """Independent paginated REST snapshots, never an actual rerun request."""
    def __init__(self):
        self.pulls = [pull()]
        self.files = {1: files("openapi.json")}
        self.runs = [run()]
        self.jobs = [job(), job(101, name="admission")]
        self.current = pull()
        self.currents = {}
        self.next_current = None
        self.current_reads = 0
        self.calls = []
        self.posts = []
        self.fail = None
        self.fail_count = None  # None: every call to the failing path fails
        self.next_runs = None
        self.run_reads = 0

    def __call__(self, method, endpoint):
        self.calls.append((method, endpoint))
        parsed = urlsplit(endpoint)
        path = parsed.path.removeprefix(f"repos/{REPO}/")
        query = parse_qs(parsed.query)
        # A failing run listing fails only PR #1's head, so other PRs can be served.
        if self.fail == path and query.get("head_sha", ["current-head"]) == ["current-head"] \
                and self.fail_count != 0:
            if self.fail_count is not None:
                self.fail_count -= 1
            raise subprocess.CalledProcessError(1, ["gh", "api", endpoint], stderr="HTTP 403: denied")
        if method == "POST":
            self.posts.append(path)
            return None
        if re.fullmatch(r"pulls/\d+", path):
            number = int(path.split("/")[1])
            self.current_reads += 1
            if self.next_current is not None and self.current_reads > 1:
                return self.next_current
            return self.current if number == 1 else self.currents.get(number, pull(number))
        key = None
        if path == "pulls":
            rows = self.pulls
        elif path.endswith("/files"):
            rows = self.files[int(path.split("/")[1])]
        elif path == "actions/workflows/check.yml/runs":
            self.run_reads += 1
            rows = self.next_runs if self.run_reads > 1 and self.next_runs is not None else self.runs
            key = "workflow_runs"
        elif re.fullmatch(r"actions/runs/\d+/jobs", path):
            if query.get("filter") != ["latest"]:
                raise AssertionError("must read only the latest execution's jobs")
            run_id = int(path.split("/")[2])
            rows, key = [item for item in self.jobs if item["run_id"] == run_id], "jobs"
        else:
            raise AssertionError(f"unexpected API call: {method} {endpoint}")
        page, size = int(query["page"][0]), int(query["per_page"][0])
        batch = rows[(page - 1) * size:page * size]
        return {key: batch} if key else batch


class Clock:
    def __init__(self, on_sleep=None):
        self.now = 0
        self.sleeps = []
        self.on_sleep = on_sleep

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds
        if self.on_sleep:
            self.on_sleep()


class AdapterTest(unittest.TestCase):
    def recheck(self, api, clock=None):
        output = io.StringIO()
        clock = clock or Clock()
        with redirect_stdout(output):
            owner.recheck(api, REPO, PUBLISHED, clock=clock.monotonic, sleep=clock.sleep)
        return output.getvalue()

    def test_reruns_policy_and_logs_pr_and_job(self):
        api = GitHub()
        output = self.recheck(api)
        self.assertEqual(api.posts, ["actions/jobs/100/rerun"])
        self.assertIn("Rerun PR #1: job 100", output)
        self.assertIn("including admission", output)
        self.assertTrue(any("event=pull_request&head_sha=current-head" in path for _, path in api.calls))

    def test_nonqualifying_prs_do_not_read_runs_or_post(self):
        api = GitHub()
        api.pulls = [pull(draft=True), pull(base={"ref": "other"}), pull(2)]
        api.files[2] = files("README.md")
        self.recheck(api)
        self.assertEqual(api.posts, [])
        self.assertFalse(any("/actions/" in path for _, path in api.calls))

    def test_missing_run_logs_skip_without_reading_jobs(self):
        api = GitHub()
        api.runs = []
        clock = Clock()
        self.assertIn("Skip PR #1:", self.recheck(api, clock))
        self.assertEqual(api.posts, [])
        self.assertEqual(clock.sleeps, [])
        self.assertFalse(any("/jobs?" in path for _, path in api.calls))

    def test_in_progress_run_completes_then_reruns_policy(self):
        api = GitHub()
        api.runs = [run(status="in_progress")]
        def complete():
            self.assertEqual(api.posts, [])
            api.runs = [run()]
        clock = Clock(complete)
        output = self.recheck(api, clock)
        self.assertEqual(clock.sleeps, [60])
        self.assertIn("Wait PR #1: latest run 10 is in_progress", output)
        self.assertIn("Rerun PR #1: job 100", output)
        self.assertEqual(api.posts, ["actions/jobs/100/rerun"])

    def test_timeout_is_shared_by_all_prs_and_names_every_unrechecked_pr(self):
        api = GitHub()
        api.pulls = [pull(), pull(2)]
        api.files[2] = files("src/wire_version.zig")
        api.runs = [run(status="in_progress"), run(20, status="queued", head_sha="head-2")]
        clock = Clock()
        with redirect_stdout(io.StringIO()), self.assertRaisesRegex(
                TimeoutError, r"could not recheck PRs: #1 \(latest run 10 is in_progress\), #2 \(latest run 20 is queued\)$"):
            owner.recheck(api, REPO, PUBLISHED, clock=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(clock.now, 90 * 60)
        self.assertEqual(clock.sleeps, [60] * 90)
        self.assertEqual(api.posts, [])

    def test_ready_pr_is_not_blocked_by_another_active_run(self):
        api = GitHub()
        api.pulls = [pull(), pull(2)]
        api.files[2] = files("src/wire_version.zig")
        api.runs = [run(status="in_progress"), run(20, head_sha="head-2")]
        api.jobs.append(job(200, run_id=20))
        def complete():
            self.assertEqual(api.posts, ["actions/jobs/200/rerun"])
            api.runs[0] = run()
        clock = Clock(complete)
        self.recheck(api, clock)
        self.assertEqual(clock.sleeps, [60])
        self.assertEqual(api.posts, ["actions/jobs/200/rerun", "actions/jobs/100/rerun"])

    def test_timeout_fails_main_loudly_and_excludes_already_rechecked_prs(self):
        api = GitHub()
        api.pulls = [pull(), pull(2)]
        api.files[2] = files("openapi.json")
        api.runs = [run(status="in_progress"), run(20, head_sha="head-2")]
        api.jobs.append(job(200, run_id=20))
        clock, output = Clock(), io.StringIO()
        with mock.patch.object(owner, "github", api), mock.patch.dict(os.environ, GITHUB_REPOSITORY=REPO, RELEASE_PUBLISHED_AT=PUBLISHED_AT), \
                mock.patch.object(owner.time, "monotonic", clock.monotonic), \
                mock.patch.object(owner.time, "sleep", clock.sleep), redirect_stdout(output), redirect_stderr(output):
            self.assertEqual(owner.main(), 1)
        message = output.getvalue().split("::error::")[-1]
        self.assertIn("90-minute budget exhausted; could not recheck PRs: #1", message)
        self.assertNotIn("#2", message)
        self.assertEqual(api.posts, ["actions/jobs/200/rerun"])

    def test_discovery_consumes_the_same_budget(self):
        api, clock = GitHub(), Clock()
        def slow_api(method, endpoint):
            result = api(method, endpoint)
            if "/files?" in endpoint:
                clock.now = 90 * 60
            return result
        with self.assertRaisesRegex(TimeoutError, r"#1 \(PR discovery incomplete\)"):
            self.recheck(slow_api, clock)
        self.assertEqual(clock.sleeps, [])
        self.assertEqual(api.posts, [])

    def test_last_poll_sleep_is_clipped_to_remaining_global_budget(self):
        api, clock = GitHub(), Clock()
        api.runs = [run(status="in_progress")]
        def slow_discovery(method, endpoint):
            result = api(method, endpoint)
            if "/files?" in endpoint:
                clock.now += 30
            return result
        with self.assertRaisesRegex(TimeoutError, "could not recheck PRs: #1"):
            self.recheck(slow_discovery, clock)
        self.assertEqual(clock.sleeps, [60] * 89 + [30])
        self.assertEqual(clock.now, 90 * 60)
        self.assertEqual(api.posts, [])

    def test_watchdog_interrupts_a_real_hung_api_subprocess(self):
        api, output = GitHub(), io.StringIO()
        def hung_api(method, endpoint):
            if "/files?" in endpoint:
                # No timing assertion: the alarm must terminate this blocked
                # subprocess through subprocess.run's exception cleanup.
                subprocess.run([sys.executable, "-c", "import signal; signal.pause()"],
                               check=True, capture_output=True, text=True)
                self.fail("watchdog did not interrupt API subprocess")
            return api(method, endpoint)
        with mock.patch.object(owner, "github", hung_api), mock.patch.object(owner, "TIMEOUT_SECONDS", 1), \
                mock.patch.dict(os.environ, GITHUB_REPOSITORY=REPO, RELEASE_PUBLISHED_AT=PUBLISHED_AT), redirect_stdout(output), redirect_stderr(output):
            self.assertEqual(owner.main(), 1)
        self.assertIn("could not recheck PRs: #1 (PR discovery incomplete)", output.getvalue())
        self.assertEqual(api.posts, [])

    def test_fork_pr_is_rerun_by_its_head(self):
        api = GitHub()
        api.pulls = [pull(head=head(repo=FORK))]
        api.current = api.pulls[0]
        api.runs = [run(head_repository={"full_name": FORK}, pull_requests=[])]
        self.assertIn("Rerun PR #1: job 100", self.recheck(api))
        self.assertEqual(api.posts, ["actions/jobs/100/rerun"])

    def test_active_run_checked_after_publication_is_neither_waited_on_nor_rerun(self):
        for policy in ([job(status="in_progress", started_at=AFTER)], []):
            with self.subTest(policy=policy):
                api, clock = GitHub(), Clock()
                api.runs = [run(status="in_progress", run_started_at=BEFORE if policy else AFTER)]
                api.jobs = policy
                self.assertIn("Skip PR #1: run 10 checks after publication", self.recheck(api, clock))
                self.assertEqual(clock.sleeps, [])
                self.assertEqual(api.posts, [])

    def test_waiting_run_is_dropped_once_policy_starts_after_publication(self):
        api = GitHub()
        api.runs = [run(status="in_progress")]
        api.jobs = [job(status="queued")]
        def start_policy():
            api.jobs = [job(status="in_progress", started_at=AFTER)]
        clock = Clock(start_policy)
        output = self.recheck(api, clock)
        self.assertEqual(clock.sleeps, [60])
        self.assertIn("Wait PR #1: latest run 10 is in_progress", output)
        self.assertIn("Skip PR #1: run 10 checks after publication", output)
        self.assertEqual(api.posts, [])

    def test_missing_publication_time_fails_loudly(self):
        for env in ({}, {"RELEASE_PUBLISHED_AT": ""}, {"RELEASE_PUBLISHED_AT": "null"}):
            with self.subTest(env=env):
                api, output = GitHub(), io.StringIO()
                with mock.patch.object(owner, "github", api), \
                        mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": REPO, **env}, clear=True), \
                        redirect_stdout(output), redirect_stderr(output):
                    self.assertEqual(owner.main(), 1)
                self.assertIn("::error::Cannot recheck wire PRs:", output.getvalue())
                self.assertEqual(api.calls, [])

    def test_no_policy_check_yet_logs_skip(self):
        api = GitHub()
        api.jobs = []
        self.assertIn("no completed policy check yet", self.recheck(api))
        self.assertEqual(api.posts, [])

    def test_every_collection_is_paginated(self):
        api = GitHub()
        api.pulls = [pull(n, draft=True) for n in range(2, 102)] + [pull()]
        api.files[1] = files(*(["README.md"] * 100), "src/wire_version.zig")
        api.runs = [run(9, head_repository={"full_name": FORK})] * 100 + [run()]
        api.jobs = [job(n, name="native") for n in range(100)] + [job()]
        self.recheck(api)
        self.assertEqual(api.posts, ["actions/jobs/100/rerun"])
        second_pages = [path for _, path in api.calls if "page=2" in path]
        for path in ("/pulls?", "/files?", "/runs?", "/jobs?"):
            self.assertTrue(any(path in endpoint for endpoint in second_pages), path)

    def test_file_api_limit_is_not_silently_truncated(self):
        api = GitHub()
        api.files[1] = files(*(["README.md"] * 3000))
        with self.assertRaisesRegex(owner.Unrechecked, r"#1 \(invalid data: .*file list may be incomplete"):
            self.recheck(api)
        self.assertEqual(api.posts, [])

    def test_pr_changes_before_post_are_skipped(self):
        for current in (pull(draft=True), pull(state="closed"), pull(base={"ref": "other"})):
            with self.subTest(current=current):
                api = GitHub()
                api.current = current
                self.assertIn("PR changed while selecting", self.recheck(api))
                self.assertEqual(api.posts, [])

    def test_newer_or_restarted_run_before_post_is_polled_with_fresh_jobs(self):
        for latest in (run(20, status="in_progress"), run(status="in_progress", run_attempt=2),
                       run(20), run(run_attempt=2)):
            with self.subTest(latest=latest):
                api = GitHub()
                api.next_runs = [latest]
                def complete():
                    self.assertEqual(api.posts, [])
                    api.next_runs = [{**latest, "status": "completed"}]
                    api.jobs = [job(200, run_id=latest["id"], run_attempt=latest["run_attempt"])]
                clock = Clock(complete)
                self.assertIn("Wait PR #1:", self.recheck(api, clock))
                self.assertEqual(clock.sleeps, [60])
                self.assertEqual(api.posts, ["actions/jobs/200/rerun"])

    def test_changed_head_while_waiting_refreshes_files_and_run(self):
        for changed in (files("openapi.json"), files("README.md")):
            with self.subTest(changed=changed):
                api = GitHub()
                api.runs = [run(status="in_progress")]
                def change_head():
                    api.current = pull(head=head(sha="new-head"))
                    api.files[1] = changed
                    api.runs = [run(20, head_sha="new-head")]
                    api.jobs = [job(200, run_id=20)]
                clock = Clock(change_head)
                output = self.recheck(api, clock)
                self.assertEqual(clock.sleeps, [60])
                self.assertEqual(api.posts, ["actions/jobs/200/rerun"] if changed == files("openapi.json") else [])
                self.assertIn("Rerun PR #1:" if api.posts else "no wire contract files", output)

    def test_head_change_before_post_is_reselected_not_skipped(self):
        api = GitHub()
        api.next_current = pull(head=head(sha="new-head"))
        def complete():
            self.assertEqual(api.posts, [])
            api.runs = [run(20, head_sha="new-head")]
            api.jobs = [job(200, run_id=20)]
        clock = Clock(complete)
        self.assertIn("Wait PR #1: PR changed while selecting", self.recheck(api, clock))
        self.assertEqual(clock.sleeps, [60])
        self.assertEqual(api.posts, ["actions/jobs/200/rerun"])

    PER_PR_ENDPOINTS = ("pulls/1/files", "pulls/1", "actions/workflows/check.yml/runs",
                        "actions/runs/10/jobs", "actions/jobs/100/rerun")

    def two_prs(self):
        api = GitHub()
        api.pulls = [pull(), pull(2)]
        api.files[2] = files("openapi.json")
        api.runs = [run(), run(20, head_sha="head-2")]
        api.jobs = [job(), job(200, run_id=20)]
        return api

    def main(self, api, clock):
        output = io.StringIO()
        with mock.patch.object(owner, "github", api), \
                mock.patch.dict(os.environ, GITHUB_REPOSITORY=REPO, RELEASE_PUBLISHED_AT=PUBLISHED_AT), \
                mock.patch.object(owner.time, "monotonic", clock.monotonic), \
                mock.patch.object(owner.time, "sleep", clock.sleep), redirect_stdout(output), redirect_stderr(output):
            status = owner.main()
        return status, output.getvalue()

    def test_open_pr_list_error_fails_at_once(self):
        api, clock = GitHub(), Clock()
        api.fail = "pulls"
        status, output = self.main(api, clock)
        self.assertEqual(status, 1)
        self.assertIn("::error::Cannot recheck wire PRs: HTTP 403: denied", output)
        self.assertEqual(clock.sleeps, [])
        self.assertEqual(api.posts, [])

    def test_one_prs_api_error_does_not_stop_another_prs_rerun(self):
        for endpoint in self.PER_PR_ENDPOINTS:
            with self.subTest(endpoint=endpoint):
                api, clock = self.two_prs(), Clock()
                api.fail = endpoint
                status, output = self.main(api, clock)
                self.assertEqual(status, 1)
                self.assertEqual(api.posts, ["actions/jobs/200/rerun"])
                self.assertIn("Retry PR #1 next poll: API error: HTTP 403: denied", output)
                # Discovery and the first poll each try the file list before any sleep.
                retries_without_sleep = 2 if endpoint == "pulls/1/files" else 1
                self.assertEqual(clock.sleeps, [60] * (owner.MAX_API_FAILURES - retries_without_sleep))
                message = output.split("::error::")[-1]
                self.assertIn("could not recheck PRs: #1 (API error: HTTP 403: denied (3 consecutive failures))",
                              message)
                self.assertNotIn("#2", message)

    def test_transient_api_error_is_retried_next_poll(self):
        for endpoint in self.PER_PR_ENDPOINTS:
            with self.subTest(endpoint=endpoint):
                api, clock = self.two_prs(), Clock()
                api.fail, api.fail_count = endpoint, 1
                status, output = self.main(api, clock)
                self.assertEqual(status, 0, output)
                self.assertEqual(sorted(api.posts), ["actions/jobs/100/rerun", "actions/jobs/200/rerun"])
                self.assertIn("Retry PR #1 next poll: API error: HTTP 403: denied", output)
                self.assertIn("Rerun PR #1: job 100", output)
                self.assertEqual(clock.sleeps, [] if endpoint == "pulls/1/files" else [60])

    def test_one_prs_invalid_data_gives_it_up_without_stopping_others(self):
        api, clock = self.two_prs(), Clock()
        api.jobs.append(job(101))
        status, output = self.main(api, clock)
        self.assertEqual(status, 1)
        self.assertEqual(api.posts, ["actions/jobs/200/rerun"])
        self.assertEqual(clock.sleeps, [])
        self.assertIn("could not recheck PRs: #1 (invalid data: run 10 has multiple latest policy jobs)",
                      output.split("::error::")[-1])

    def test_actual_workflow_keeps_gate_and_admission_dependency_and_fetches_tags(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/check.yml").read_text()
        policy, admission = workflow_job(workflow, "policy"), workflow_job(workflow, "admission")
        self.assertIn("fetch-depth: 0", policy)
        self.assertIn("unittest.defaultTestLoader.discover('tests/ci')", policy)
        needs = re.search(r"needs: \[([^\]]+)\]", admission)[1].split(", ")
        self.assertIn("policy", needs)


    def test_release_rechecks_only_after_a_new_successful_publication(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/release.yml").read_text()
        job_body = workflow_job(workflow, "recheck_wire_prs")
        self.assertIn("needs: [plan, publish]", job_body)
        self.assertIn("if: ${{ needs.plan.outputs.version != '' && needs.publish.result == 'success' }}", job_body)
        self.assertEqual(permissions(job_body), {"actions": "write", "pull-requests": "read", "contents": "read"})
        self.assertIn("ref: ${{ github.sha }}", job_body)
        self.assertIn("persist-credentials: false", job_body)
        self.assertIn("GH_TOKEN: ${{ github.token }}", job_body)
        self.assertIn("VERSION: ${{ needs.plan.outputs.version }}", job_body)
        self.assertIn('RELEASE_PUBLISHED_AT=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/v$VERSION" --jq .published_at)',
                      job_body)
        self.assertIn("export RELEASE_PUBLISHED_AT", job_body)
        self.assertIn("set -euo pipefail", job_body)
        self.assertIn("python3 -B tests/ci/recheck_wire_prs.py", job_body)
        self.assertIn("runs-on: ubuntu-24.04", job_body)
        timeout = int(re.search(r"^    timeout-minutes: (\d+)$", job_body, re.M)[1])
        self.assertGreater(timeout * 60, owner.TIMEOUT_SECONDS + 3 * 60)

    def test_promote_caller_grants_only_the_extra_permissions_rechecks_need(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/promote.yml").read_text()
        caller = workflow_job(workflow, "release")
        self.assertIn("uses: ./.github/workflows/release.yml", caller)
        self.assertEqual(permissions(caller), {"contents": "write", "actions": "write",
                                               "pull-requests": "read", "id-token": "write"})


if __name__ == "__main__":
    unittest.main()
