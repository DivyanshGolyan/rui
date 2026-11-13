"""Wire-release invalidation selects only the current PR's completed policy job."""
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


def pull(number=1, **changes):
    return {"number": number, "state": "open", "draft": False,
            "base": {"ref": "main"}, "head": {"sha": "current-head"}, **changes}


def run(run_id=10, **changes):
    return {"id": run_id, "run_number": run_id, "run_attempt": 1, "event": "pull_request", "path": ".github/workflows/check.yml",
            "head_sha": "current-head", "pull_requests": [{"number": 1}], "status": "completed", **changes}


def job(job_id=100, **changes):
    return {"id": job_id, "run_id": 10, "run_attempt": 1, "name": "policy", "status": "completed", "conclusion": "success", **changes}


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
                                  [job()] if jobs is None else jobs)

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

    def test_runs_must_match_head_pr_event_and_workflow(self):
        for unrelated in (run(20, head_sha="old-head"), run(20, pull_requests=[{"number": 2}]),
                          run(20, pull_requests=[]), run(20, event="push"),
                          run(20, path=".github/workflows/promote.yml")):
            with self.subTest(unrelated=unrelated):
                self.assertEqual(self.select(runs=[unrelated, run()]).job_id, 100)
                self.assertIsNone(self.select(runs=[unrelated]).job_id)

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
        self.next_runs = None
        self.run_reads = 0

    def __call__(self, method, endpoint):
        self.calls.append((method, endpoint))
        parsed = urlsplit(endpoint)
        path = parsed.path.removeprefix(f"repos/{REPO}/")
        query = parse_qs(parsed.query)
        if self.fail == path:
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
            owner.recheck(api, REPO, clock=clock.monotonic, sleep=clock.sleep)
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
            self.assertFalse(any("/jobs?" in path for _, path in api.calls))
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
        api.runs = [run(status="in_progress"), run(20, status="queued", pull_requests=[{"number": 2}])]
        clock = Clock()
        with redirect_stdout(io.StringIO()), self.assertRaisesRegex(TimeoutError, r"could not recheck PRs: #1, #2"):
            owner.recheck(api, REPO, clock=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(clock.now, 90 * 60)
        self.assertEqual(clock.sleeps, [60] * 90)
        self.assertEqual(api.posts, [])

    def test_ready_pr_is_not_blocked_by_another_active_run(self):
        api = GitHub()
        api.pulls = [pull(), pull(2)]
        api.files[2] = files("src/wire_version.zig")
        api.runs = [run(status="in_progress"), run(20, pull_requests=[{"number": 2}])]
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
        api.runs = [run(status="in_progress"), run(20, pull_requests=[{"number": 2}])]
        api.jobs.append(job(200, run_id=20))
        clock, output = Clock(), io.StringIO()
        with mock.patch.object(owner, "github", api), mock.patch.dict(os.environ, GITHUB_REPOSITORY=REPO), \
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
                mock.patch.dict(os.environ, GITHUB_REPOSITORY=REPO), redirect_stdout(output), redirect_stderr(output):
            self.assertEqual(owner.main(), 1)
        self.assertIn("could not recheck PRs: #1 (PR discovery incomplete)", output.getvalue())
        self.assertEqual(api.posts, [])

    def test_no_policy_check_yet_logs_skip(self):
        api = GitHub()
        api.jobs = []
        self.assertIn("no completed policy check yet", self.recheck(api))
        self.assertEqual(api.posts, [])

    def test_every_collection_is_paginated(self):
        api = GitHub()
        api.pulls = [pull(n, draft=True) for n in range(2, 102)] + [pull()]
        api.files[1] = files(*(["README.md"] * 100), "src/wire_version.zig")
        api.runs = [run(9, pull_requests=[{"number": 2}])] * 100 + [run()]
        api.jobs = [job(n, name="native") for n in range(100)] + [job()]
        self.recheck(api)
        self.assertEqual(api.posts, ["actions/jobs/100/rerun"])
        second_pages = [path for _, path in api.calls if "page=2" in path]
        for path in ("/pulls?", "/files?", "/runs?", "/jobs?"):
            self.assertTrue(any(path in endpoint for endpoint in second_pages), path)

    def test_file_api_limit_is_not_silently_truncated(self):
        api = GitHub()
        api.files[1] = files(*(["README.md"] * 3000))
        with self.assertRaisesRegex(ValueError, "file list may be incomplete"):
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
                    api.current = pull(head={"sha": "new-head"})
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
        api.next_current = pull(head={"sha": "new-head"})
        def complete():
            self.assertEqual(api.posts, [])
            api.runs = [run(20, head_sha="new-head")]
            api.jobs = [job(200, run_id=20)]
        clock = Clock(complete)
        self.assertIn("Wait PR #1: PR changed while selecting", self.recheck(api, clock))
        self.assertEqual(clock.sleeps, [60])
        self.assertEqual(api.posts, ["actions/jobs/200/rerun"])

    def test_each_api_error_fails_command_loudly(self):
        for endpoint in ("pulls", "pulls/1/files", "actions/workflows/check.yml/runs",
                         "actions/runs/10/jobs", "pulls/1", "actions/jobs/100/rerun"):
            with self.subTest(endpoint=endpoint):
                api = GitHub()
                api.fail = endpoint
                output = io.StringIO()
                with mock.patch.object(owner, "github", api), mock.patch.dict(os.environ, GITHUB_REPOSITORY=REPO), \
                        redirect_stdout(output), redirect_stderr(output):
                    self.assertEqual(owner.main(), 1)
                self.assertIn("::error::Cannot recheck wire PRs: HTTP 403: denied", output.getvalue())

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
        self.assertIn("run: python3 -B tests/ci/recheck_wire_prs.py", job_body)
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
