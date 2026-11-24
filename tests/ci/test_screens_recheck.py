import unittest

import screens_recheck


HEAD = "a" * 40
REPO = "owner/repo"


def pr(**changes):
    result = {"state": "open", "draft": False,
              "head": {"sha": HEAD, "ref": "feature", "repo": {"full_name": REPO}}}
    result.update(changes)
    return result


def run(number, status="completed", branch="feature", event="pull_request", sha=HEAD):
    return {"id": number, "run_number": number, "run_attempt": 1, "status": status, "created_at": "2026-11-24T08:15:51Z",
            "event": event, "head_sha": sha, "head_branch": branch,
            "head_repository": {"full_name": REPO}, "path": ".github/workflows/check.yml",
            "pull_requests": [{"number": 42}]}


def job(number, status="completed", conclusion="failure"):
    return {"id": number, "name": "admission", "status": status, "conclusion": conclusion}


class FakeGitHub:
    def __init__(self, runs, jobs, pull=None):
        self.runs, self.jobs, self.pull = runs, jobs, pull or pr()
        self.posts = []
        self.timeline = []

    def __call__(self, method, path):
        if method == "POST":
            self.posts.append(path)
            return None
        if "/timeline?" in path:
            return self.timeline
        if "/pulls/" in path:
            return self.pull
        if "/workflows/" in path:
            return {"workflow_runs": self.runs}
        if "/jobs?" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": self.jobs.get(run_id, [])}
        raise AssertionError(path)


class ScreensRecheckTest(unittest.TestCase):
    def execute(self, api, sleep=lambda _: None, clock=lambda: 0):
        return screens_recheck.recheck(api, REPO, 42, HEAD, sleep=sleep, clock=clock)

    def test_latest_run_is_the_only_candidate(self):
        api = FakeGitHub([run(1), run(2, "in_progress")], {1: [job(11)], 2: [job(22, "queued", None)]})
        self.execute(api)
        self.assertEqual(api.posts, [])
        api.runs[1]["status"] = "completed"
        api.jobs[2] = [job(22)]
        self.execute(api)
        self.assertEqual(api.posts, [f"repos/{REPO}/actions/jobs/22/rerun"])

    def test_admission_that_already_started_is_observed_to_completion(self):
        for conclusion, expected in (("failure", 1), ("success", 0)):
            with self.subTest(conclusion=conclusion):
                current = run(2, "in_progress")
                api = FakeGitHub([current], {2: [job(22, "in_progress", None)]})
                def finish(_):
                    current["status"] = "completed"
                    api.jobs[2] = [job(22, conclusion=conclusion)]
                self.execute(api, sleep=finish)
                self.assertEqual(len(api.posts), expected)

    def test_pending_or_missing_admission_will_read_published_screens(self):
        for jobs in ([], [job(22, "queued", None)]):
            api = FakeGitHub([run(2, "in_progress")], {2: jobs})
            self.execute(api)
            self.assertEqual(api.posts, [])

    def test_other_heads_branches_and_dispatches_never_choose_retry(self):
        api = FakeGitHub([run(1), run(2, branch="other"), run(3, event="workflow_dispatch"), run(4, sha="b" * 40)], {1: [job(11)]})
        self.execute(api)
        self.assertEqual(api.posts, [f"repos/{REPO}/actions/jobs/11/rerun"])
        api = FakeGitHub([run(1)], {1: [job(11)]}, pr(head={"sha": "b" * 40, "ref": "feature", "repo": {"full_name": REPO}}))
        self.execute(api)
        self.assertEqual(api.posts, [])

    def test_draft_and_success_do_not_retry(self):
        for pull, admission in ((pr(draft=True), job(11)), (pr(), job(11, conclusion="success"))):
            api = FakeGitHub([run(1)], {1: [admission]}, pull)
            self.execute(api)
            self.assertEqual(api.posts, [])

    def test_new_run_appearing_before_retry_takes_precedence(self):
        class Changed(FakeGitHub):
            reads = 0
            def __call__(self, method, path):
                if "/workflows/" in path:
                    self.reads += 1
                    if self.reads == 2:
                        self.runs.append(run(2, "in_progress"))
                        self.jobs[2] = [job(22, "queued", None)]
                return super().__call__(method, path)
        api = Changed([run(1)], {1: [job(11)]})
        self.execute(api)
        self.assertEqual(api.posts, [])

    def test_ready_transition_prevents_retrying_prior_draft_run(self):
        api = FakeGitHub([run(1)], {1: [job(11)]})
        api.timeline = [{"event": "ready_for_review", "created_at": "2026-11-24T08:15:52Z"}]
        self.execute(api)
        self.assertEqual(api.posts, [])

    def test_same_second_transition_uses_run_trigger_state(self):
        for marker, expected in (("PR admission trigger 42 ready", 1),
                                 ("PR admission trigger 42 draft", 0), (None, 0)):
            with self.subTest(marker=marker):
                current = run(1)
                plan = {"name": "plan", "steps": ([{"name": marker}] if marker else [])}
                api = FakeGitHub([current], {1: [plan, job(11)]})
                api.timeline = [{"event": "ready_for_review", "created_at": current["created_at"]}]
                self.execute(api)
                self.assertEqual(len(api.posts), expected)

    def test_run_must_belong_to_the_published_pr(self):
        for association, marker, expected in (([42], None, 1), ([], None, 0),
                                              ([43], None, 0), ([42, 43], None, 0),
                                              ([], "PR admission trigger 42 ready", 1),
                                              ([42], "PR admission trigger 43 ready", 0)):
            with self.subTest(association=association, marker=marker):
                current = run(1)
                current["pull_requests"] = [{"number": number} for number in association]
                plan = {"name": "plan", "steps": ([{"name": marker}] if marker else [])}
                api = FakeGitHub([current], {1: [plan, job(11)]})
                self.execute(api)
                self.assertEqual(len(api.posts), expected)

    def test_timeout_warns_without_retry(self):
        api = FakeGitHub([run(1, "in_progress")], {1: [job(11, "in_progress", None)]})
        ticks = iter((0, 421))
        result = self.execute(api, clock=lambda: next(ticks))
        self.assertIn("::warning::", result)
        self.assertEqual(api.posts, [])


if __name__ == "__main__":
    unittest.main()
