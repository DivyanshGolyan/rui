import contextlib
import copy
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import pr_timeline as timeline


FIXTURES = json.loads(Path(__file__).with_name("pr_timeline_fixtures.json").read_text())


class TimelineTest(unittest.TestCase):
    def snapshot(self, number=1407):
        return copy.deepcopy(FIXTURES[str(number)])

    def test_two_recorded_codex_rounds_and_mutable_summary_time(self):
        row = timeline.stages(**self.snapshot())
        self.assertEqual(row["codex_rounds"], 2)
        self.assertEqual(row["stages"], {
            "opened": "2026-11-13T09:46:27Z", "codex_requested": "2026-11-13T09:46:31Z",
            "codex_reviewed": "2026-11-13T09:48:06Z", "codex_clean": "2026-11-13T10:11:08.182199Z",
            "ready": "2026-11-13T10:10:03Z", "admission_green": "2026-11-13T10:18:25Z",
            "merged": "2026-11-13T10:18:44Z", "released": None})
        self.assertEqual(row["minutes"]["codex_clean_to_ready"], -1.09)
        self.assertEqual(row["pushes"], 2)

    def test_never_draft_uses_opened_not_missing_ready_event(self):
        data = self.snapshot()
        data["timeline"] = []  # Explicit never-draft variant of the recorded PR.
        row = timeline.stages(**data)
        self.assertEqual(row["stages"]["ready"], row["stages"]["opened"])
        data["timeline"] = [{"event": "convert_to_draft"}]
        self.assertIsNone(timeline.stages(**data)["stages"]["ready"])

    def test_never_reviewed_has_no_guessed_review_or_clean_timestamp(self):
        data = self.snapshot()
        data["comments"] = [c for c in data["comments"] if c["user"]["login"] != timeline.CODEX]
        data["reviews"] = []
        row = timeline.stages(**data)
        self.assertEqual(row["codex_rounds"], 0)
        self.assertEqual(row["stages"]["codex_requested"], "2026-11-13T09:46:31Z")
        self.assertIsNone(row["stages"]["codex_reviewed"])
        self.assertIsNone(row["stages"]["codex_clean"])
        self.assertIsNone(row["minutes"]["codex_requested_to_codex_reviewed"])

    def test_unreleased_and_no_double_counting_summary_and_receipt(self):
        row = timeline.stages(**self.snapshot(1418))
        self.assertEqual(row["codex_rounds"], 1)
        self.assertIsNone(row["stages"]["released"])
        self.assertIsNone(row["release_tag"])
        self.assertIsNone(row["minutes"]["merged_to_released"])
        self.assertEqual(row["stages"]["codex_reviewed"], "2026-11-13T10:43:48Z")

    def test_clean_requires_trusted_completed_summary_on_merged_head(self):
        for change in ("wrong_head", "running", "findings", "string_false", "untrusted", "malformed"):
            with self.subTest(change=change):
                data = self.snapshot(1418)
                summary = next(c for c in data["comments"] if "codex-review-state:v1" in c["body"])
                state = json.loads(timeline.SUMMARY.search(summary["body"])[1])
                review = state["code_review"]
                if change == "wrong_head":
                    review["commit_sha"] = "other"
                elif change == "running":
                    review["status"] = "in_progress"
                elif change == "findings":
                    review["has_unresolved_findings"] = True
                elif change == "string_false":
                    review["has_unresolved_findings"] = "false"
                elif change == "untrusted":
                    summary["user"]["login"] = "someone"
                summary["body"] = "<!-- codex-review-state:v1 " + json.dumps(state) + " -->"
                if change == "malformed":
                    summary["body"] = "<!-- codex-review-state:v1 not-json -->"
                    with self.assertRaises(ValueError):
                        timeline.stages(**data)
                else:
                    self.assertIsNone(timeline.stages(**data)["stages"]["codex_clean"])

    def test_html_escaped_summary_and_updated_at_fallback(self):
        data = self.snapshot(1418)
        data["reviews"] = []
        data["comments"] = [c for c in data["comments"] if "codex-review-state:v1" in c["body"]]
        summary = data["comments"][0]
        summary["body"] = summary["body"].splitlines()[0].replace("{", "&#123;").replace("}", "&#125;")
        row = timeline.stages(**data)
        self.assertEqual(row["codex_rounds"], 1)
        self.assertEqual(row["stages"]["codex_clean"], summary["updated_at"])
        self.assertIsNone(row["stages"]["codex_requested"])  # Bot boilerplate is not a request.

    def test_first_successful_admission_on_exact_head(self):
        data = self.snapshot(1418)
        good = data["checks"][0]
        good["completed_at"] = "2026-11-13T11:00:00Z"
        for updates in ({"head_sha": "wrong"}, {"conclusion": "failure"}, {"name": "other"},
                        {"conclusion": "skipped"}, {"completed_at": None}):
            data["checks"].append({**good, "completed_at": "2026-11-13T10:00:00Z", **updates})
        data["checks"].append({**good, "completed_at": "2026-11-13T11:02:00Z"})
        self.assertEqual(timeline.stages(**data)["stages"]["admission_green"], "2026-11-13T11:00:00Z")

    def test_push_operations_not_commits_and_missing_history_unknown(self):
        data = self.snapshot(1418)
        self.assertEqual(timeline.push_count(data["pr"], data["activity"]), 2)
        push = next(r for r in data["activity"] if r["activity_type"] == "push")
        data["activity"].extend([{**push, "activity_type": "force_push"},
                                 {**push, "timestamp": "2026-11-13T12:00:00Z"},
                                 {**push, "ref": "refs/heads/other"}])
        self.assertEqual(timeline.push_count(data["pr"], data["activity"]), 3)
        self.assertIsNone(timeline.push_count(data["pr"], [push]))

    def test_list_and_object_pagination_through_collection(self):
        data = self.snapshot(1418)
        calls = []

        def api(method, path):
            self.assertEqual(method, "GET")
            calls.append(path)
            page = int(path.rsplit("page=", 1)[1])
            if "/releases?" in path:
                return []
            if "/pulls?" in path:
                return ([{**data["pr"], "merged_at": None}] * 100 if page == 1 else [data["pr"]])
            if "/timeline?" in path:
                return ([{"event": "mentioned"}] * 100 if page == 1 else data["timeline"])
            if "/comments?" in path:
                return ([{**data["comments"][0], "body": "irrelevant"}] * 100 if page == 1 else data["comments"])
            if "/reviews?" in path:
                return ([{"user": {"login": "human"}}] * 100 if page == 1 else data["reviews"])
            if "/check-runs?" in path:
                return {"check_runs": ([{**data["checks"][0], "conclusion": "failure"}] * 100
                                       if page == 1 else data["checks"])}
            self.fail(path)

        result = timeline.collect(api, "2026-11-12", [], lambda repo, ref: data["activity"])
        self.assertEqual(result, [timeline.stages(**data)])
        self.assertEqual(sum("page=2" in path for path in calls), 5)
        self.assertTrue(all("per_page=100" in path for path in calls))

    def test_activity_cursor_pagination_and_repeated_cursor_failure(self):
        data = self.snapshot(1418)["activity"]
        paths = []

        def read(path):
            paths.append(path)
            return (data[:1], "next?after=cursor") if len(paths) == 1 else (data[1:], None)

        self.assertEqual(list(timeline.activities("a/r", "branch/name", read)), data)
        self.assertIn("ref=refs%2Fheads%2Fbranch%2Fname&per_page=100", paths[0])
        self.assertEqual(paths[1], "next?after=cursor")
        with self.assertRaisesRegex(ValueError, "Repeated activity cursor"):
            list(timeline.activities("a/r", "branch", lambda path: ([], path)))
        with patch.object(timeline, "gh", return_value='HTTP/1.1 200 OK\nLink: <https://api.github.com/repos/a/r/activity?after=x>; rel="next"\n\n[]'):
            self.assertEqual(timeline.activity_page("first"), ([], "repos/a/r/activity?after=x"))

    def test_repeatable_pr_filter_since_boundary_and_updated_cutoff(self):
        data = self.snapshot()["pr"]
        calls = []

        def api(method, path):
            calls.append(path)
            if "/pulls/" in path:
                return data
            return [{**data, "merged_at": None}, data,
                    {**data, "updated_at": "2026-11-11T00:00:00Z", "merged_at": "2026-11-11T00:00:00Z"}]

        self.assertEqual(list(timeline.merged_prs(api, "2026-11-13", [1407, 1407])), [data])
        self.assertEqual(len(calls), 1)
        self.assertEqual(list(timeline.merged_prs(api, "2026-11-14", [1407])), [])
        self.assertEqual(list(timeline.merged_prs(api, "2026-11-13", [])), [data])

    def test_release_uses_ancestry_not_just_later_date(self):
        pr = self.snapshot()["pr"]
        def release(tag, when, draft=False):
            return {"tag_name": tag, "published_at": when, "draft": draft}
        releases = [release("old", "2026-11-12T00:00:00Z"), release("draft", None, True),
                    release("unrelated", "2026-11-13T10:19:00Z"),
                    release("v1/first", "2026-11-13T11:00:00Z"), release("v2", "2026-11-14T00:00:00Z")]
        calls = []
        def api(method, path):
            calls.append(path)
            return {"status": "diverged" if path.endswith("unrelated") else "ahead"}
        self.assertEqual(timeline.containing_release(api, pr, list(reversed(releases))), releases[3])
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[-1].endswith("v1%2Ffirst"))
        self.assertIsNone(timeline.containing_release(lambda *a: {"status": "behind"}, pr, releases))
        row = timeline.stages(**self.snapshot(), release=releases[3])
        self.assertEqual(row["release_tag"], "v1/first")
        self.assertEqual(row["minutes"]["merged_to_released"], 41.27)

    def test_daily_medians_exclude_unreleased_and_unknown_is_not_zero(self):
        rows = [timeline.stages(**self.snapshot()), timeline.stages(**self.snapshot(1418))]
        rows[0]["stages"]["released"] = "2026-11-13T11:00:00Z"
        days = timeline.daily(rows, "2026-11-12", "2026-11-13T12:00:00Z")
        self.assertEqual(days[0]["merged"], 0)
        self.assertEqual(days[1]["merged"], 2)
        self.assertEqual(days[1]["median_opened_to_merged_minutes"], 28.62)
        self.assertEqual(days[1]["median_merged_to_released_minutes"], 41.27)
        self.assertTrue(all(day["red_main_minutes"] is None for day in days))

    def test_red_main_carries_state_splits_midnight_and_clips_today(self):
        runs = [{"completed_at": when, "conclusion": conclusion} for when, conclusion in (
            ("2026-11-11T23:00:00Z", "success"), ("2026-11-12T23:50:00Z", "failure"),
            ("2026-11-13T00:05:00Z", "cancelled"), ("2026-11-13T00:10:00Z", "success"),
            ("2026-11-13T11:50:00Z", "failure"), ("2026-11-13T13:00:00Z", "success"))]
        days = timeline.daily([], "2026-11-12", "2026-11-13T12:00:00Z", list(reversed(runs)))
        self.assertEqual([day["red_main_minutes"] for day in days], [10, 20])
        days = timeline.daily([], "2026-11-12", "2026-11-13T12:00:00Z", runs[1:])
        self.assertEqual([day["red_main_minutes"] for day in days], [None, 20])

    def test_main_source_is_named_push_workflow_and_job_completion(self):
        calls = []
        def api(method, path):
            calls.append(path)
            if "/workflows?" in path:
                return {"workflows": [{"id": 42, "name": "Build main"}]}
            if "/runs?" in path:
                self.assertIn("branch=main&event=push", path)
                return {"workflow_runs": [{"id": 7, "status": "completed", "conclusion": "failure"},
                                          {"id": 8, "status": "in_progress"}]}
            return {"jobs": [{"completed_at": "2026-11-12T23:00:00Z"}, {"completed_at": "2026-11-12T23:10:00Z"}]}
        self.assertEqual(timeline.main_builds(api, "Build main"),
                         [{"completed_at": "2026-11-12T23:10:00Z", "conclusion": "failure"}])
        with self.assertRaisesRegex(ValueError, "found 0"):
            timeline.main_builds(api, "not a workflow")

    def test_cli_json_and_table_render_absent_stages(self):
        row = timeline.stages(**self.snapshot(1418))
        for fmt in ("table", "json"):
            with self.subTest(fmt=fmt), patch.object(timeline, "collect", return_value=[row]), \
                    patch("sys.argv", ["pr_timeline.py", "--since", "2026-11-12", "--pr", "1418", "--format", fmt]), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(timeline.main(), 0)
                if fmt == "json":
                    report = json.loads(output.getvalue())
                    self.assertEqual(report["prs"], [row])
                    self.assertIsNone(report["days"][0]["red_main_minutes"])
                else:
                    self.assertIn("unknown", output.getvalue())
                    self.assertIn("workflow name", output.getvalue())


if __name__ == "__main__":
    unittest.main()
