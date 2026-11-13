"""Wire-release invalidation selects only the current PR's completed policy job."""
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import re
import subprocess
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
        if path == "pulls/1":
            return self.current
        key = None
        if path == "pulls":
            rows = self.pulls
        elif path.endswith("/files"):
            rows = self.files[int(path.split("/")[1])]
        elif path == "actions/workflows/check.yml/runs":
            self.run_reads += 1
            rows = self.next_runs if self.run_reads > 1 and self.next_runs is not None else self.runs
            key = "workflow_runs"
        elif path == "actions/runs/10/jobs":
            if query.get("filter") != ["latest"]:
                raise AssertionError("must read only the latest execution's jobs")
            rows, key = self.jobs, "jobs"
        else:
            raise AssertionError(f"unexpected API call: {method} {endpoint}")
        page, size = int(query["page"][0]), int(query["per_page"][0])
        batch = rows[(page - 1) * size:page * size]
        return {key: batch} if key else batch


class AdapterTest(unittest.TestCase):
    def recheck(self, api):
        output = io.StringIO()
        with redirect_stdout(output):
            owner.recheck(api, REPO)
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

    def test_missing_and_active_runs_log_skips_without_reading_jobs(self):
        for runs in ([], [run(status="in_progress")]):
            with self.subTest(runs=runs):
                api = GitHub()
                api.runs = runs
                self.assertIn("Skip PR #1:", self.recheck(api))
                self.assertEqual(api.posts, [])
                self.assertFalse(any("/jobs?" in path for _, path in api.calls))

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
        for current in (pull(draft=True), pull(state="closed"), pull(base={"ref": "other"}),
                        pull(head={"sha": "new-head"})):
            with self.subTest(current=current):
                api = GitHub()
                api.current = current
                self.assertIn("PR changed while selecting", self.recheck(api))
                self.assertEqual(api.posts, [])

    def test_newer_or_restarted_active_run_before_post_is_skipped(self):
        for latest in (run(20, status="in_progress"), run(status="in_progress"),
                       run(20), run(run_attempt=2)):
            with self.subTest(latest=latest):
                api = GitHub()
                api.next_runs = [latest]
                self.assertIn("Skip PR #1:", self.recheck(api))
                self.assertEqual(api.posts, [])

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
        def job_body(name):
            return re.search(rf"^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)", workflow, re.M | re.S)[1]
        policy, admission = job_body("policy"), job_body("admission")
        self.assertIn("fetch-depth: 0", policy)
        self.assertIn("unittest.defaultTestLoader.discover('tests/ci')", policy)
        needs = re.search(r"needs: \[([^\]]+)\]", admission)[1].split(", ")
        self.assertIn("policy", needs)


if __name__ == "__main__":
    unittest.main()
