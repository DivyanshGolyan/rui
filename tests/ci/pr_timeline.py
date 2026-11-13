#!/usr/bin/env python3
"""Report where merged PRs spent their time (read-only, GitHub REST only).

  python3 tests/ci/pr_timeline.py --since 2026-11-12 [--pr 1418] [--format json]

Release source: published releases API, ordered by published_at, with REST
compare proving that the release tag contains the merge commit (not merely a
later date). No checkout, fetch, tag, or GitHub mutation is performed.
Codex rounds count formal reviews and no-findings receipts; the mutable summary
is only a fallback for a head without either. Clean uses the summary's Code
Review completion time, or updated_at if its older format has no such time.
Pushes include branch creation and subsequent pushes through merge, starting
at the last creation before opening; missing creation/fork history is unknown.
Adjacent durations are signed minutes: stages can occur out of the listed order,
and a missing endpoint stays blank rather than bridging to a different stage.

Red-main minutes stay unknown without --main-workflow NAME. Supply only the
workflow that builds every push to main, not PR or manually dispatched Promote
runs. Its failed-completion -> successful-completion intervals are split at UTC
midnight; completion comes from job completed_at, not run updated_at. A day
without known incoming health is unknown. Today's intervals end at report time.
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
STAGES = ("opened", "codex_requested", "codex_reviewed", "codex_clean", "ready",
          "admission_green", "merged", "released")
SUMMARY = re.compile(r"<!--\s*codex-review-state:v1\s+(.*?)\s*-->", re.S)


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
    codex = [row for row in comments if row["user"]["login"] == CODEX]
    completed = [(row["submitted_at"], row["commit_id"]) for row in reviews
                 if row["user"]["login"] == CODEX and row.get("submitted_at") and row["state"] != "PENDING"]
    for row in codex:
        if "<!-- codex-review-receipt:v1 -->" in (row.get("body") or ""):
            match = re.search(r"\*\*Reviewed commit:\*\*\s*`([0-9a-f]+)`", row["body"])
            completed.append((row["created_at"], match[1] if match else None))
    clean, summaries = [], []
    for row in codex:
        match = SUMMARY.search(row.get("body") or "")
        if not match:
            continue
        state = json.loads(html.unescape(match[1]))["code_review"]
        if state["status"] != "completed":
            continue
        when = utc(code_review_time(row))
        sha = state["commit_sha"]
        summaries.append((when, sha))
        if sha == head and state["has_unresolved_findings"] is False:
            clean.append(when)
    # A summary is mutable, so it is not another round when a durable review
    # or receipt already records its head. Never infer lost historical rounds.
    for when, sha in summaries:
        if not any(commit and sha and sha.startswith(commit) for _, commit in completed):
            completed.append((when, sha))
    ready = [row["created_at"] for row in timeline if row["event"] == "ready_for_review"]
    if not ready and not pr["draft"] and not any(row["event"] in ("convert_to_draft", "converted_to_draft") for row in timeline):
        ready = [pr["created_at"]]
    values = [pr["created_at"], first(row["created_at"] for row in comments
              if row["user"]["login"] != CODEX and re.search(r"@codex\s+review\b", row.get("body") or "", re.I)),
              first(when for when, _ in completed), first(clean), first(ready),
              first(row["completed_at"] for row in checks if row["name"] == "admission"
                    and row["head_sha"] == head and row["conclusion"] == "success"
                    and row.get("completed_at")),
              pr["merged_at"], release["published_at"] if release else None]
    result = dict(zip(STAGES, map(utc, values)))
    return {"number": pr["number"], "head": head, "stages": result,
            "minutes": {f"{a}_to_{b}": minutes(result[a], result[b]) for a, b in zip(STAGES, STAGES[1:])},
            "codex_rounds": len(completed), "pushes": push_count(pr, activity),
            "release_tag": release["tag_name"] if release else None}


def daily(rows, since, until, main_runs=None):
    """UTC merge-date cohorts; absent releases are excluded from the median.

    main_runs is the optional trusted workflow's runs, with completed_at derived
    from its jobs. None means no reliable source, never zero red minutes.
    """
    result = []
    day = date.fromisoformat(since)
    end = instant(until)
    health = sorted((instant(run["completed_at"]), run["conclusion"]) for run in (main_runs or [])
                    if run.get("completed_at") and run["conclusion"] in ("success", "failure", "timed_out", "action_required"))
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


def object_pages(api, path, key):
    """REST list envelopes (checks/runs/jobs); pages() owns plain-list paging."""
    page = 1
    while True:
        batch = api("GET", f"{path}&per_page=100&page={page}")[key]
        yield from batch
        if len(batch) < 100:
            return
        page += 1


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


def main_builds(api, name):
    workflows = object_pages(api, f"repos/{REPO}/actions/workflows?", "workflows")
    matches = [workflow for workflow in workflows if workflow["name"] == name]
    if len(matches) != 1:
        raise ValueError(f"Expected one workflow named {name!r}; found {len(matches)}")
    result = []
    for run in object_pages(api, f"repos/{REPO}/actions/workflows/{matches[0]['id']}/runs?branch=main&event=push", "workflow_runs"):
        if run["status"] != "completed":
            continue
        jobs = list(object_pages(api, f"repos/{REPO}/actions/runs/{run['id']}/jobs?filter=latest", "jobs"))
        when = max((job["completed_at"] for job in jobs if job.get("completed_at")), key=instant, default=None)
        if not when:
            raise ValueError(f"Main build {run['id']} has no job completion time")
        result.append({"completed_at": when, "conclusion": run["conclusion"]})
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
        checks = list(object_pages(api, f"{prefix}/commits/{head['sha']}/check-runs?filter=all&check_name=admission", "check_runs"))
        activity = list(read_activity(head["repo"]["full_name"], head["ref"])) if head.get("repo") else []
        result.append(stages(pr, timeline, comments, reviews, checks, activity, containing_release(api, pr, releases)))
    return sorted(result, key=lambda row: (row["stages"]["merged"], row["number"]))


def table(report):
    print("UTC timestamps; signed adjacent durations in minutes; blank = absent, unknown = unavailable")
    print("Release source: releases API published_at + REST compare merge commit...tag (ahead/identical)")
    print("Rounds = completed reviews/receipts (summary fallback); pushes = branch creation + pushes through merge")
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
    if not report["main_workflow"]:
        print("Red-main source unavailable: what is the workflow name for builds on every push to main? Use --main-workflow NAME.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", required=True, type=date.fromisoformat, metavar="YYYY-MM-DD")
    parser.add_argument("--pr", type=int, action="append", default=[])
    parser.add_argument("--format", choices=("table", "json"), default="table")
    parser.add_argument("--main-workflow", help="trusted workflow name that builds every push to main")
    args = parser.parse_args()
    since = args.since.isoformat()
    try:
        rows = collect(github, since, args.pr)
        runs = main_builds(github, args.main_workflow) if args.main_workflow else None
        until = datetime.now(timezone.utc).isoformat()
        report = {"since": since, "as_of": utc(until), "release_source": "releases API published_at + REST compare ancestry",
                  "main_workflow": args.main_workflow, "prs": rows, "days": daily(rows, since, until, runs)}
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
