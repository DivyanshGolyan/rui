import unittest

from admission_notice import comment, rerun

REPO = "o/r"


class Api:
    def __init__(self, routes):
        self.routes, self.posts = routes, []

    def __call__(self, method, path, fields=()):
        if method == "POST":
            self.posts.append((path, dict(fields)))
            return {}
        for prefix, value in self.routes.items():
            if path.startswith(prefix):
                return value
        raise AssertionError(path)


def job(name, conclusion, id=7):
    return {"name": name, "conclusion": conclusion, "id": id, "html_url": "https://x/job"}


def comment_api(conclusion="failure", jobs=None, pr=None, comments=()):
    return Api({
        f"repos/{REPO}/actions/runs/1/jobs": {"jobs": jobs or [job("plan", "success", 1), job("admission", "failure")]},
        f"repos/{REPO}/actions/runs/1": {"id": 1, "run_attempt": 1, "event": "pull_request", "conclusion": conclusion,
                                         "head_sha": "a" * 40, "pull_requests": [{"number": 5}]},
        f"repos/{REPO}/pulls/5": pr or {"state": "open", "draft": False, "head": {"sha": "a" * 40}},
        f"repos/{REPO}/check-runs/7/annotations": [
            {"annotation_level": "failure", "message": "UI PRs need screen evidence"},
            {"annotation_level": "failure", "message": "Process completed with exit code 1."},
            {"annotation_level": "warning", "message": "slow"}],
        f"repos/{REPO}/issues/5/comments": list(comments),
    })


class CommentTest(unittest.TestCase):
    def test_failed_admission_names_its_errors_once(self):
        api = comment_api()
        self.assertEqual(comment(api, REPO, 1), 5)
        (path, fields), = api.posts
        self.assertEqual(path, f"repos/{REPO}/issues/5/comments")
        self.assertIn("- UI PRs need screen evidence", fields["body"])
        self.assertNotIn("exit code", fields["body"])
        self.assertNotIn("slow", fields["body"])
        again = comment_api(comments=[{"body": fields["body"]}])
        self.assertIsNone(comment(again, REPO, 1))
        self.assertEqual(again.posts, [])

    def test_quiet_when_nothing_to_say(self):
        for api in (comment_api(conclusion="success"),
                    comment_api(jobs=[job("admission", "success")]),
                    comment_api(pr={"state": "open", "draft": True, "head": {"sha": "a" * 40}}),
                    comment_api(pr={"state": "open", "draft": False, "head": {"sha": "b" * 40}})):
            self.assertIsNone(comment(api, REPO, 1))
            self.assertEqual(api.posts, [])


def rerun_api(jobs, status="completed"):
    return Api({
        f"repos/{REPO}/actions/runs?head_sha=h": {"workflow_runs": [
            {"id": 1, "run_number": 1, "name": "Selected checks", "event": "pull_request", "status": "completed"},
            {"id": 2, "run_number": 2, "name": "Selected checks", "event": "pull_request", "status": status},
            {"id": 3, "run_number": 9, "name": "Other", "event": "pull_request", "status": "completed"}]},
        f"repos/{REPO}/actions/runs/2/jobs": {"jobs": jobs},
    })


class RerunTest(unittest.TestCase):
    def test_body_only_failure_reruns_the_newest_run(self):
        for failed in (["admission"], ["plan", "admission"]):
            api = rerun_api([job(name, "failure") for name in failed] + [job("linux pr", "skipped")])
            self.assertEqual(rerun(api, REPO, "h"), 2)
            self.assertEqual(api.posts, [(f"repos/{REPO}/actions/runs/2/rerun-failed-jobs", {})])

    def test_no_rerun_for_test_failures_running_or_passing_runs(self):
        for api in (rerun_api([job("linux pr", "failure"), job("admission", "failure")]),
                    rerun_api([job("admission", "success")]),
                    rerun_api([job("admission", "failure")], status="in_progress")):
            self.assertIsNone(rerun(api, REPO, "h"))
            self.assertEqual(api.posts, [])


if __name__ == "__main__":
    unittest.main()
