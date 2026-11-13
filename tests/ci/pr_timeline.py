#!/usr/bin/env python3
"""Report where merged PRs spent their time (read-only, GitHub REST only).

  python3 tests/ci/pr_timeline.py --since 2026-11-12 [--pr 1418] [--format json]

Release source: published releases API, ordered by published_at, with REST
compare proving that the release tag contains the merge commit (not merely a
later date). No checkout, fetch, tag, or GitHub mutation is performed.
Every review stage (first review, Codex-clean, rounds) derives from one list
of review outcomes: formal Codex reviews (findings), Codex receipt comments (no
findings), the mutable summary at its Code Review completion time (updated_at in
its older format), and a maintainer's interim opus-review-state:v1 marker at its
updated_at. Rounds count reviews, receipts and interim markers; the summary is
only a fallback for a head without a review or receipt. Codex-clean is the time
of the last outcome before merge when it is clean, on any head: landing.md lets
test-only fixes, merges of main and stacked heads merge without another review,
and only a later outcome with findings revokes it.
Pushes include branch creation and subsequent pushes through merge, starting
at the last creation before opening; missing creation/fork history is unknown.
Adjacent durations are signed minutes: stages can occur out of the listed order,
and a missing endpoint stays blank rather than bridging to a different stage.

Red-main minutes use the "Main build" every-push workflow by default; override
with --main-workflow NAME. A missing workflow is unknown, not an error. Only
completed success/failure runs signal health; superseded cancelled runs do not.
Red intervals run from the first failed completion to the next success, split
at UTC midnight; completion comes from job completed_at, not the head commit's
time or run updated_at. A day without known incoming health is unknown.
Today's intervals end at report time. Runs are read newest-first only back to
the last completed success/failure before --since.
"""
import argparse
from datetime import date, datetime, time, timedelta, timezone
import html
import json
import re
import statistics
import subprocess
import sys
from urllib.parse import quote, urlencode, urlsplit

from conflict_alert import gh, github, pages

REPO = "DivyanshGolyan/rui"
CODEX = "chatgpt-codex-connector[bot]"
DEFAULT_MAIN_WORKFLOW = "Main build"
MAIN_RESULTS = ("success", "failure")
STAGES = ("opened", "codex_requested", "codex_reviewed", "codex_clean", "ready",
          "admission_green", "merged", "released")
SUMMARY = re.compile(r"<!--\s*codex-review-state:v1\s+(.*?)\s*-->", re.S)
# Interim stand-in for Codex, posted by a maintainer: same commit_sha and
# has_unresolved_findings fields as Codex's code_review state.
INTERIM = re.compile(r"<!--\s*opus-review-state:v1\s+(.*?)\s*-->", re.S)
MAINTAINERS = ("OWNER", "MEMBER", "COLLABORATOR")


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def utc(value):
    return instant(value).isoformat().replace("+00:00", "Z") if value else None


def first(values):
    return min((utc(value) for value in values if value), key=instant, default=None)


def minutes(start, end):
    return round((instant(end) - instant(start)).total_seconds() / 60, 2) if start and end else None


def code_review_time(comment):
    # Do not take the Security Review row's timestamp, or the summary's creation
    # time: the latter is when Codex started, often on a different head.
    row = next((line for line in comment["body"].splitlines() if "**Code Review**" in line), "")
    match = re.search(r'datetime="([^"]+)"', row)
    return match[1] if match else comment["updated_at"]


def push_count(pr, activity):
    """Count the branch's push operations, not commits or CI runs."""
    ref = "refs/heads/" + pr["head"]["ref"]
    rows = [row for row in activity if row["ref"] == ref and instant(row["timestamp"]) <= instant(pr["merged_at"])]
    created = [row["timestamp"] for row in rows if row["activity_type"] == "branch_creation"
               and instant(row["timestamp"]) <= instant(pr["created_at"])]
    if not created:
        return None
    start = max(map(instant, created))
    return sum(row["activity_type"] in ("branch_creation", "push", "force_push")
               and instant(row["timestamp"]) >= start for row in rows)


def stages(pr, timeline, comments, reviews, checks, activity, release=None):
    """Pure projection of recorded API JSON; the PR head is the head merged."""
    head = pr["head"]["sha"]
    reviewed, clean, rounds = review_stages(review_outcomes(comments, reviews), pr["merged_at"])
    ready = [row["created_at"] for row in timeline if row["event"] == "ready_for_review"]
    if not ready and not pr["draft"] and not any(row["event"] in ("convert_to_draft", "converted_to_draft") for row in timeline):
        ready = [pr["created_at"]]
    values = [pr["created_at"], first(row["created_at"] for row in comments
              if row["user"]["login"] != CODEX and re.search(r"@codex\s+review\b", row.get("body") or "", re.I)),
              reviewed, clean, first(ready),
              first(row["completed_at"] for row in checks if row["name"] == "admission"
                    and row["head_sha"] == head and row["conclusion"] == "success"
                    and row.get("completed_at")),
              pr["merged_at"], release["published_at"] if release else None]
    result = dict(zip(STAGES, map(utc, values)))
    return {"number": pr["number"], "head": head, "stages": result,
            "minutes": {f"{a}_to_{b}": minutes(result[a], result[b]) for a, b in zip(STAGES, STAGES[1:])},
            "codex_rounds": rounds, "pushes": push_count(pr, activity),
            "release_tag": release["tag_name"] if release else None}


def review_outcomes(comments, reviews):
    """Every review outcome as {when, head, clean, source}; the one review record.

    Codex posts findings as a formal review ("review") and a clean result as a
    receipt comment ("receipt"). Its mutable summary ("summary") holds the
    latest state at its Code Review completion time. A maintainer's interim
    opus-review-state:v1 marker ("interim") stands in while Codex is unavailable.
    """
    result = []
    for row in reviews:
        if row["user"]["login"] == CODEX and row.get("submitted_at") and row["state"] != "PENDING":
            result.append({"when": utc(row["submitted_at"]), "head": row["commit_id"], "clean": False, "source": "review"})
    for row in comments:
        body = row.get("body") or ""
        if row["user"]["login"] == CODEX:
            if "<!-- codex-review-receipt:v1 -->" in body:
                match = re.search(r"\*\*Reviewed commit:\*\*\s*`([0-9a-f]+)`", body)
                result.append({"when": utc(row["created_at"]), "head": match[1] if match else None,
                               "clean": True, "source": "receipt"})
            match = SUMMARY.search(body)
            if match:
                state = json.loads(html.unescape(match[1]))["code_review"]
                if state["status"] == "completed":
                    result.append({"when": utc(code_review_time(row)), "head": state["commit_sha"],
                                   "clean": state["has_unresolved_findings"] is False, "source": "summary"})
        match = INTERIM.search(body)
        if match and row.get("author_association") in MAINTAINERS:
            state = json.loads(html.unescape(match[1]))
            result.append({"when": utc(row["updated_at"]), "head": state.get("commit_sha"),
                           "clean": state["has_unresolved_findings"] is False, "source": "interim"})
    return sorted(result, key=lambda outcome: instant(outcome["when"]))


def review_stages(outcomes, merged_at):
    """First review time, Codex-clean time and round count from review_outcomes.

    A round is a review, receipt or interim outcome. The mutable summary is a
    round only for a head no review or receipt records: it is overwritten, so
    lost historical rounds are never inferred.
    Clean is the time of the last outcome before merge when that outcome is
    clean, on any head: landing.md lets test-only fixes, merges of main and
    unchanged stacked heads merge without another review, so the clean head
    need not be the merged head. Only a later outcome with findings revokes it.
    """
    durable = [o["head"] for o in outcomes if o["source"] in ("review", "receipt") and o["head"]]
    rounds = [o for o in outcomes if o["source"] != "summary"
              or not any(o["head"] and o["head"].startswith(commit) for commit in durable)]
    before = [o for o in outcomes if instant(o["when"]) <= instant(merged_at)]
    clean = before[-1]["when"] if before and before[-1]["clean"] else None
    return (rounds[0]["when"] if rounds else None), clean, len(rounds)


def daily(rows, since, until, main_runs=None):
    """UTC merge-date cohorts; absent releases are excluded from the median.

    main_runs is the optional trusted workflow's runs, with completed_at derived
    from its jobs. None means no reliable source, never zero red minutes.
    """
    result = []
    day = date.fromisoformat(since)
    end = instant(until)
    health = sorted((instant(run["completed_at"]), run["conclusion"]) for run in (main_runs or [])
                    if run.get("completed_at") and run["conclusion"] in MAIN_RESULTS)
    while day <= end.date():
        start = datetime.combine(day, time(), timezone.utc)
        stop = min(start + timedelta(days=1), end)
        cohort = [row for row in rows if instant(row["stages"]["merged"]).date() == day]
        medians = {}
        for a, b in (("opened", "merged"), ("merged", "released")):
            values = [(instant(row["stages"][b]) - instant(row["stages"][a])).total_seconds() / 60
                      for row in cohort if row["stages"][b]]
            medians[f"median_{a}_to_{b}_minutes"] = round(statistics.median(values), 2) if values else None
        prior = [conclusion for when, conclusion in health if when <= start]
        red = None
        if main_runs is not None and prior:
            failed, cursor, seconds = prior[-1] != "success", start, 0
            for when, conclusion in health:
                if start < when < stop:
                    if failed:
                        seconds += (when - cursor).total_seconds()
                    failed, cursor = conclusion != "success", when
            if failed:
                seconds += (stop - cursor).total_seconds()
            red = round(seconds / 60, 2)
        result.append({"day": day.isoformat(), "merged": len(cohort), **medians, "red_main_minutes": red})
        day += timedelta(days=1)
    return result


def activity_page(path):
    response = gh("api", "--include", path)
    headers, body = response.split("\n\n", 1)
    link = next((line for line in headers.splitlines() if line.lower().startswith("link:")), "")
    match = re.search(r'<([^>]+)>; rel="next"', link)
    next_path = None
    if match:
        url = urlsplit(match[1])
        if url.hostname != "api.github.com":
            raise ValueError("Unexpected activity pagination host")
        next_path = url.path.lstrip("/") + "?" + url.query
    return json.loads(body), next_path


def activities(repo, ref, read_page=activity_page):
    # The activity endpoint ignores page=N. Follow its REST after cursor by
    # hand instead; treating the repeated first page as history overcounts.
    path = f"repos/{repo}/activity?" + urlencode({"ref": "refs/heads/" + ref, "per_page": 100})
    seen = set()
    while path:
        if path in seen:
            raise ValueError("Repeated activity cursor")
        seen.add(path)
        batch, path = read_page(path)
        yield from batch


def merged_prs(api, since, numbers):
    prefix = f"repos/{REPO}"
    if numbers:
        candidates = (api("GET", f"{prefix}/pulls/{number}") for number in dict.fromkeys(numbers))
    else:
        candidates = pages(api, f"{prefix}/pulls?state=closed&sort=updated&direction=desc")
    for pr in candidates:
        if not numbers and pr["updated_at"][:10] < since:
            break
        if pr.get("merged_at") and pr["merged_at"][:10] >= since:
            yield pr


def containing_release(api, pr, releases):
    for release in sorted((r for r in releases if not r["draft"] and r.get("published_at")
                           and instant(r["published_at"]) >= instant(pr["merged_at"])),
                          key=lambda r: instant(r["published_at"])):
        comparison = api("GET", f"repos/{REPO}/compare/{pr['merge_commit_sha']}...{quote(release['tag_name'], safe='')}")
        if comparison["status"] in ("ahead", "identical"):
            return release
    return None


def main_builds(api, name, since):
    """Main build health from the last completion before since onward.

    The runs API lists newest-first, and paging stops at the first completed
    success/failure run that finished before since: the incoming health.
    Jobs are read only for the runs kept.
    """
    start = datetime.combine(date.fromisoformat(since), time(), timezone.utc)
    workflows = pages(api, f"repos/{REPO}/actions/workflows?", "workflows")
    matches = [workflow for workflow in workflows if workflow["name"] == name]
    if not matches:
        return None
    if len(matches) != 1:
        raise ValueError(f"Expected one workflow named {name!r}; found {len(matches)}")
    result = []
    for run in pages(api, f"repos/{REPO}/actions/workflows/{matches[0]['id']}/runs?branch=main&event=push", "workflow_runs"):
        # Superseded/cancelled runs are no signal, even if their jobs have no
        # completion timestamp. Keep the last completed success/failure.
        if run["status"] != "completed" or run["conclusion"] not in MAIN_RESULTS:
            continue
        jobs = list(pages(api, f"repos/{REPO}/actions/runs/{run['id']}/jobs?filter=latest", "jobs"))
        when = max((job["completed_at"] for job in jobs if job.get("completed_at")), key=instant, default=None)
        if not when:
            raise ValueError(f"Main build {run['id']} has no job completion time")
        result.append({"completed_at": when, "conclusion": run["conclusion"]})
        if instant(when) < start:
            break
    return result


def collect(api, since, numbers, read_activity=activities):
    releases = list(pages(api, f"repos/{REPO}/releases?"))
    result = []
    for pr in merged_prs(api, since, numbers):
        prefix = f"repos/{REPO}"
        n, head = pr["number"], pr["head"]
        timeline = list(pages(api, f"{prefix}/issues/{n}/timeline?"))
        comments = list(pages(api, f"{prefix}/issues/{n}/comments?"))
        reviews = list(pages(api, f"{prefix}/pulls/{n}/reviews?"))
        checks = list(pages(api, f"{prefix}/commits/{head['sha']}/check-runs?filter=all&check_name=admission", "check_runs"))
        activity = list(read_activity(head["repo"]["full_name"], head["ref"])) if head.get("repo") else []
        result.append(stages(pr, timeline, comments, reviews, checks, activity, containing_release(api, pr, releases)))
    return sorted(result, key=lambda row: (row["stages"]["merged"], row["number"]))


def table(report):
    print("UTC timestamps; signed adjacent durations in minutes; blank = absent, unknown = unavailable")
    print("Release source: releases API published_at + REST compare merge commit...tag (ahead/identical)")
    print("Rounds = Codex reviews/receipts and interim markers (summary fallback); pushes = branch creation + pushes through merge")
    print("PR | " + " | ".join(STAGES) + " | release_tag | rounds | pushes | adjacent minutes (stage order)")
    for row in report["prs"]:
        print(" | ".join([str(row["number"]), *(row["stages"][stage] or "" for stage in STAGES),
                          row["release_tag"] or "", str(row["codex_rounds"]),
                          str(row["pushes"]) if row["pushes"] is not None else "unknown",
                          "/".join(str(value) if value is not None else "" for value in row["minutes"].values())]))
    print("\nDay | merged | median open->merge min | median merge->release min | red-main min")
    for day in report["days"]:
        print(" | ".join(str(value) if value is not None else ("unknown" if key == "red_main_minutes" else "")
                         for key, value in day.items()))
    if not report["main_workflow_available"]:
        print(f"Red-main source unavailable: workflow {report['main_workflow']!r} not found; red-main minutes are unknown.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", required=True, type=date.fromisoformat, metavar="YYYY-MM-DD")
    parser.add_argument("--pr", type=int, action="append", default=[])
    parser.add_argument("--format", choices=("table", "json"), default="table")
    parser.add_argument("--main-workflow", default=DEFAULT_MAIN_WORKFLOW,
                        help="trusted workflow name that builds every push to main (default: %(default)s)")
    args = parser.parse_args()
    since = args.since.isoformat()
    try:
        rows = collect(github, since, args.pr)
        runs = main_builds(github, args.main_workflow, since)
        until = datetime.now(timezone.utc).isoformat()
        report = {"since": since, "as_of": utc(until), "release_source": "releases API published_at + REST compare ancestry",
                  "main_workflow": args.main_workflow, "main_workflow_available": runs is not None,
                  "prs": rows, "days": daily(rows, since, until, runs)}
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot build PR timeline: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1
    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        table(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
