import contextlib
import copy
import io
import json
import re
from pathlib import Path
import unittest
from unittest.mock import patch

import conflict_alert
from main_build import MARKER
import pr_timeline as timeline
from report_issue import LABEL


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

    def test_clean_requires_trusted_completed_summary(self):
        for change in ("running", "findings", "string_false", "untrusted"):
            with self.subTest(change=change):
                data = self.snapshot(1418)
                # Without the receipt, the summary alone decides.
                data["comments"] = [c for c in data["comments"] if "codex-review-receipt:v1" not in c["body"]]
                summary = next(c for c in data["comments"] if "codex-review-state:v1" in c["body"])
                state = json.loads(timeline.SUMMARY.search(summary["body"])[1])
                review = state["code_review"]
                if change == "running":
                    review["status"] = "in_progress"
                elif change == "findings":
                    review["has_unresolved_findings"] = True
                elif change == "string_false":
                    review["has_unresolved_findings"] = "false"
                elif change == "untrusted":
                    summary["user"]["login"] = "someone"
                summary["body"] = "<!-- codex-review-state:v1 " + json.dumps(state) + " -->"
                self.assertIsNone(timeline.stages(**data)["stages"]["codex_clean"])

    def test_clean_on_earlier_head_survives_unreviewed_commits_landing_allows(self):
        # #1316: clean on 22355cf, then a test-only commit merged unreviewed.
        # #1322: clean on 230e06b, then "Merge main" merged unreviewed.
        for number, clean_head, clean in ((1316, "22355cf8fe", "2026-11-12T05:05:50.297698Z"),
                                          (1322, "230e06b86e", "2026-11-12T07:10:33.486335Z")):
            with self.subTest(number=number):
                data = self.snapshot(number)
                self.assertFalse(data["pr"]["head"]["sha"].startswith(clean_head))
                row = timeline.stages(**data)
                self.assertEqual(row["stages"]["codex_clean"], clean)
                self.assertIsNotNone(row["minutes"]["codex_reviewed_to_codex_clean"])
                self.assertIsNotNone(row["minutes"]["codex_clean_to_ready"])

    def test_later_findings_revoke_clean_and_post_merge_reviews_do_not_count(self):
        data = self.snapshot(1316)
        codex = {"login": timeline.CODEX}
        findings = {"user": codex, "submitted_at": "2026-11-12T05:10:00Z",
                    "commit_id": data["pr"]["head"]["sha"], "state": "COMMENTED"}
        data["reviews"].append(findings)
        self.assertIsNone(timeline.stages(**data)["stages"]["codex_clean"])
        receipt = {"user": codex, "author_association": "NONE", "created_at": "2026-11-12T05:20:00Z",
                   "updated_at": "2026-11-12T05:20:00Z",
                   "body": "<!-- codex-review-receipt:v1 -->\n**Reviewed commit:** `c98448974d`"}
        data["comments"].append(receipt)
        self.assertEqual(timeline.stages(**data)["stages"]["codex_clean"], "2026-11-12T05:20:00Z")
        data["comments"].append({**receipt, "created_at": "2026-11-12T06:00:00Z"})  # After merge.
        self.assertEqual(timeline.stages(**data)["stages"]["codex_clean"], "2026-11-12T05:20:00Z")
        data["comments"].remove(receipt)
        self.assertIsNone(timeline.stages(**data)["stages"]["codex_clean"])

    def interim(self, when, findings=False, association="OWNER", edited="2026-11-13T23:59:00Z"):
        # Edited later than posted, so the posting time must be the one read.
        state = {"commit_sha": "7ba38bdf89613a8cf19174af1cc3dc840f92bfa9", "has_unresolved_findings": findings}
        return {"user": {"login": "DivyanshGolyan"}, "author_association": association,
                "created_at": when, "updated_at": edited,
                "body": "## Opus review\n<!-- opus-review-state:v1 " + json.dumps(state) + " -->"}

    def test_interim_only_review_gives_every_review_stage(self):
        data = self.snapshot(1418)
        data["comments"] = [c for c in data["comments"] if c["user"]["login"] != timeline.CODEX]
        data["reviews"] = []
        data["comments"].append(self.interim("2026-11-13T10:51:00Z"))
        row = timeline.stages(**data)
        self.assertEqual(row["stages"]["codex_reviewed"], "2026-11-13T10:51:00Z")
        self.assertEqual(row["stages"]["codex_clean"], "2026-11-13T10:51:00Z")
        self.assertEqual(row["codex_rounds"], 1)
        self.assertEqual(row["minutes"]["codex_reviewed_to_codex_clean"], 0)
        for change in ({"association": "NONE"}, {"findings": True}):
            with self.subTest(change=change):
                data["comments"][-1] = self.interim("2026-11-13T10:51:00Z", **change)
                row = timeline.stages(**data)
                self.assertIsNone(row["stages"]["codex_clean"])
                self.assertEqual(row["codex_rounds"], 0 if "association" in change else 1)

    def test_interim_edited_after_merge_keeps_its_posting_time(self):
        data = self.snapshot(1418)  # Merged 11:06:41.
        data["comments"] = [c for c in data["comments"] if c["user"]["login"] != timeline.CODEX]
        data["reviews"] = []
        data["comments"].append(self.interim("2026-11-13T10:51:00Z", edited="2026-11-13T12:00:00Z"))
        row = timeline.stages(**data)
        self.assertEqual(row["stages"]["codex_reviewed"], "2026-11-13T10:51:00Z")
        self.assertEqual(row["stages"]["codex_clean"], "2026-11-13T10:51:00Z")
        self.assertEqual(row["codex_rounds"], 1)

    def test_mixed_codex_and_interim_outcomes_share_one_record(self):
        data = self.snapshot(1418)  # Codex receipt 10:43:48 and summary 10:45:43 on one head.
        data["comments"].append(self.interim("2026-11-13T10:50:00Z", findings=True))
        row = timeline.stages(**data)
        self.assertEqual(row["stages"]["codex_reviewed"], "2026-11-13T10:43:48Z")
        self.assertIsNone(row["stages"]["codex_clean"])  # Interim findings revoke Codex clean.
        self.assertEqual(row["codex_rounds"], 2)
        data["comments"].append(self.interim("2026-11-13T10:55:00Z"))
        row = timeline.stages(**data)
        self.assertEqual(row["stages"]["codex_clean"], "2026-11-13T10:55:00Z")
        self.assertEqual(row["codex_rounds"], 3)
        self.assertEqual(row["minutes"]["codex_reviewed_to_codex_clean"], 11.2)
        sources = [o["source"] for o in timeline.review_outcomes(data["comments"], data["reviews"], 1418)]
        self.assertEqual(sources, ["receipt", "summary", "interim", "interim"])

    def test_malformed_marker_is_dropped_with_a_warning_and_the_report_carries_on(self):
        # Invalid JSON (an unfilled template) and a missing field, in each marker kind.
        bad_interim = ('<!-- opus-review-state:v1 {"commit_sha":"7ba38bd","has_unresolved_findings":<true|false>} -->',
                       '<!-- opus-review-state:v1 {"commit_sha":"7ba38bd"} -->')
        bad_summary = ("<!-- codex-review-state:v1 not-json -->",
                       '<!-- codex-review-state:v1 {"code_review":{"commit_sha":"7ba38bd","status":"completed"}} -->',
                       '<!-- codex-review-state:v1 {"code_review":{"commit_sha":"7ba38bd","status":"completed",'
                       '"has_unresolved_findings":false}} -->\n| **Code Review** | <relative-time datetime="soon">')
        url = "https://github.com/DivyanshGolyan/rui/pull/1418#issuecomment-1"
        for kind, bodies in (("interim", bad_interim), ("summary", bad_summary)):
            for body in bodies:
                with self.subTest(kind=kind, body=body):
                    data = self.snapshot(1418)  # Clean receipt 10:43:48, clean summary 10:45:43.
                    if kind == "interim":
                        data["comments"].append({**self.interim("2026-11-13T10:50:00Z"), "body": body, "html_url": url})
                        expected = "2026-11-13T10:45:43.596757Z"
                    else:
                        summary = next(c for c in data["comments"] if "codex-review-state:v1" in c["body"])
                        summary.update(body=body, html_url=url)
                        expected = "2026-11-13T10:43:48Z"
                    with contextlib.redirect_stderr(io.StringIO()) as errors:
                        row = timeline.stages(**data)
                    self.assertEqual(row["stages"]["codex_clean"], expected)
                    self.assertEqual(row["codex_rounds"], 1)
                    self.assertIn(f"PR #1418: ignoring malformed {kind} marker in {url}", errors.getvalue())

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

        with patch.object(timeline, "pages", wraps=conflict_alert.pages) as pager:
            result = timeline.collect(api, "2026-11-12", [], lambda repo, ref: data["activity"])
        self.assertEqual(result, [timeline.stages(**data)])
        # Envelope paging goes through the one shared pager, not a local copy.
        self.assertIn("check_runs", [call.args[2:] and call.args[2] for call in pager.call_args_list])
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
        days = timeline.daily(rows, "2026-11-12", "2026-11-13T12:00:00Z", [])
        self.assertEqual(days[0]["merged"], 0)
        self.assertEqual(days[1]["merged"], 2)
        self.assertEqual(days[1]["median_opened_to_merged_minutes"], 28.62)
        self.assertEqual(days[1]["median_merged_to_released_minutes"], 41.27)
        # Both days start before main_build.py's record: unknown, not zero.
        self.assertTrue(all(day["red_main_minutes"] is None for day in days))

    def issue(self, number, created, *events, body=MARKER, **extra):
        """A ci-red issue row plus its closed/reopened events as (event, at) pairs."""
        closes = [at for event, at in events if event == "closed"]
        state = "open" if not events or events[-1][0] == "reopened" else "closed"
        row = {"number": number, "created_at": created, "closed_at": closes[-1] if closes else None,
               "state": state, "body": body, **extra}
        return row, [{"event": event, "created_at": at} for event, at in events]

    def red_main_api(self, issues):
        rows = [row for row, _ in issues]
        events = {row["number"]: history for row, history in issues}
        calls = []
        def api(method, path):
            # Runs and jobs are never read: a stale rerun of an older SHA or a
            # failed report job cannot move red; only main_build.py's issue can.
            self.assertEqual(method, "GET")
            calls.append(path)
            if path.startswith(f"repos/{timeline.REPO}/issues?"):
                return rows
            match = re.fullmatch(rf"repos/{timeline.REPO}/issues/(\d+)/events\?&per_page=100&page=1", path)
            self.assertIsNotNone(match, path)
            # Unrelated events (labels, mentions) sit beside the transitions.
            return [{"event": "labeled", "created_at": "2026-11-14T00:00:01Z"}, *events[int(match[1])]]
        return api, calls

    def test_red_main_is_main_build_issues_only(self):
        api, calls = self.red_main_api([
            self.issue(1, "2026-11-14T23:00:00Z", ("closed", "2026-11-15T01:30:00Z")),
            self.issue(2, "2026-11-15T11:00:00Z"),
            # Closed, then reopened by hand: green while closed, red again until now.
            self.issue(3, "2026-11-14T02:00:00Z", ("closed", "2026-11-14T03:00:00Z"),
                       ("reopened", "2026-11-14T05:00:00Z")),
            # report_issue's per-signature ci-red issue: not main's state.
            self.issue(4, "2026-11-14T00:00:00Z", body="<!-- ci-signature: {} -->"),
            self.issue(5, "2026-11-14T00:00:00Z", body=None),
            self.issue(6, "2026-11-14T00:00:00Z", pull_request={"url": "..."})])
        self.assertEqual(timeline.red_main(api), [
            ("2026-11-14T02:00:00Z", "2026-11-14T03:00:00Z"), ("2026-11-14T05:00:00Z", None),
            ("2026-11-14T23:00:00Z", "2026-11-15T01:30:00Z"), ("2026-11-15T11:00:00Z", None)])
        self.assertIn("state=all", calls[0])
        self.assertIn(f"labels={LABEL}", calls[0])
        self.assertEqual(sorted(path.split("/")[4] for path in calls[1:]), ["1", "2", "3"])

    def test_red_main_counts_a_reopened_issue_only_while_open(self):
        # main_build.py opens at 10:00, a green build closes at 11:00, a hand
        # reopen at 15:00, the next green build closes at 15:30: 90 red minutes.
        api, _ = self.red_main_api([self.issue(
            1, "2026-11-14T10:00:00Z", ("reopened", "2026-11-14T15:00:00Z"),
            ("closed", "2026-11-14T15:30:00Z"), ("closed", "2026-11-14T11:00:00Z"))])
        red = timeline.red_main(api)
        self.assertEqual(red, [("2026-11-14T10:00:00Z", "2026-11-14T11:00:00Z"),
                               ("2026-11-14T15:00:00Z", "2026-11-14T15:30:00Z")])
        self.assertEqual(timeline.daily([], "2026-11-14", "2026-11-14T20:00:00Z", red)[0]["red_main_minutes"], 90)
        # Reopened and still open: red from the reopen until the report.
        api, _ = self.red_main_api([self.issue(
            1, "2026-11-14T10:00:00Z", ("closed", "2026-11-14T11:00:00Z"), ("reopened", "2026-11-14T15:00:00Z"))])
        red = timeline.red_main(api)
        self.assertEqual(red, [("2026-11-14T10:00:00Z", "2026-11-14T11:00:00Z"), ("2026-11-14T15:00:00Z", None)])
        self.assertEqual(timeline.daily([], "2026-11-14", "2026-11-14T20:00:00Z", red)[0]["red_main_minutes"], 360)

    def test_red_main_minutes_split_midnight_clip_today_and_unknown_before_record(self):
        red = [("2026-11-12T10:00:00Z", "2026-11-14T00:30:00Z"),  # Spans the record's start.
               ("2026-11-14T23:00:00Z", "2026-11-15T01:30:00Z"),  # Closed, spans midnight.
               ("2026-11-15T11:00:00Z", None)]                    # Still open at report time.
        days = timeline.daily([], "2026-11-12", "2026-11-15T12:00:00Z", red)
        self.assertEqual([day["red_main_minutes"] for day in days], [None, None, 90, 150])
        days = timeline.daily([], "2026-11-14", "2026-11-15T12:00:00Z", [])
        self.assertEqual([day["red_main_minutes"] for day in days], [0, 0])

    def test_cli_json_and_table_render_absent_stages(self):
        row = timeline.stages(**self.snapshot(1418))
        for fmt in ("table", "json"):
            argv = ["pr_timeline.py", "--since", "2026-11-12", "--pr", "1418", "--format", fmt]
            with self.subTest(fmt=fmt), patch.object(timeline, "collect", return_value=[row]), \
                    patch.object(timeline, "red_main", return_value=[]) as red, \
                    patch("sys.argv", argv), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(timeline.main(), 0)
                red.assert_called_once_with(timeline.github)
                if fmt == "json":
                    report = json.loads(output.getvalue())
                    self.assertEqual(report["prs"], [row])
                    self.assertIn(timeline.RED_MAIN_KNOWN_FROM, report["red_main_source"])
                    self.assertIsNone(report["days"][0]["red_main_minutes"])
                else:
                    self.assertIn("unknown", output.getvalue())
                    self.assertIn("Main build red", output.getvalue())

    def test_help_names_the_red_main_record(self):
        with patch("sys.argv", ["pr_timeline.py", "--help"]), contextlib.redirect_stdout(io.StringIO()) as output, \
                self.assertRaises(SystemExit):
            timeline.main()
        self.assertIn("Main build red", output.getvalue())
        self.assertIn("unknown", output.getvalue())
        self.assertNotIn("--main-workflow", output.getvalue())


if __name__ == "__main__":
    unittest.main()
