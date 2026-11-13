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
created_at (each interim review is a new comment; a later edit, even after the
merge, does not move it). Rounds count reviews, receipts and interim markers; the summary is
only a fallback for a head without a review or receipt. Codex-clean is the time
of the last outcome before merge when it is clean, on any head: landing.md lets
test-only fixes, merges of main and stacked heads merge without another review,
and only a later outcome with findings revokes it. A malformed summary or
interim marker (bad JSON, a missing field, a bad completion time) is dropped
from that PR's outcomes with a stderr warning naming the PR and comment URL;
the report carries on.
Pushes include branch creation and subsequent pushes through merge, starting
at the last creation before opening; missing creation/fork history is unknown.
Adjacent durations are signed minutes: stages can occur out of the listed order,
and a missing endpoint stays blank rather than bridging to a different stage.

Red-main minutes read main_build.py's record instead of judging runs again:
main is red while a "Main build red" issue (the ci-red label and
main_build.MARKER in its body) is open: from its creation, through its own
closed and reopened events in time order, and still red now while one is open.
main_build.py alone decides red and green (a stale rerun of an older SHA
changes nothing; the build job, not the whole run, is the result), and a
closed stretch counts green even when the issue is later reopened, so this
report agrees with that issue's open/closed history by construction. Intervals split at UTC midnight
and today's end at report time. The record starts with #1430's merge
(RED_MAIN_KNOWN_FROM, 2026-11-13T11:56:38Z): a day that starts before it is
unknown, never zero red minutes.
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
from main_build import MARKER as RED_MAIN_MARKER, TITLE as RED_MAIN_TITLE
from report_issue import LABEL as CI_RED_LABEL

REPO = "DivyanshGolyan/rui"
CODEX = "chatgpt-codex-connector[bot]"
# main_build.py, which files the red-main issue, merged in #1430 (c2ba6b05)
# at this time; no red-main record exists before it.
RED_MAIN_KNOWN_FROM = "2026-11-13T11:56:38Z"
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
    reviewed, clean, rounds = review_stages(review_outcomes(comments, reviews, pr["number"]), pr["merged_at"])
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


def marker_state(pattern, row, path, fields):
    """The JSON state of a review marker comment, or None when it has none.

    path is the key chain to the state; fields must be present in it. A
    malformed marker raises ValueError (hand-written interim markers can be).
    """
    match = pattern.search(row.get("body") or "")
    if not match:
        return None
    try:
        state = json.loads(html.unescape(match[1]))
        for key in path:
            state = state[key]
        missing = [field for field in fields if field not in state]
    except (ValueError, KeyError, TypeError) as error:
        raise ValueError(f"unparsable state ({error})") from error
    if missing:
        raise ValueError(f"missing {', '.join(missing)}")
    return state


def warning(message):
    print(f"warning: {message}", file=sys.stderr)


def review_outcomes(comments, reviews, number, warn=warning):
    """Every review outcome as {when, head, clean, source}; the one review record.

    Codex posts findings as a formal review ("review") and a clean result as a
    receipt comment ("receipt"). Its mutable summary ("summary") holds the
    latest state at its Code Review completion time. A maintainer's interim
    opus-review-state:v1 marker ("interim") stands in while Codex is unavailable.
    A malformed summary or interim marker is no outcome: warn names the PR and
    comment, and the report carries on.
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
        markers = []
        if row["user"]["login"] == CODEX:
            markers.append(("summary", SUMMARY, ("code_review",), lambda: utc(code_review_time(row))))
        if row.get("author_association") in MAINTAINERS:
            markers.append(("interim", INTERIM, (), lambda: utc(row["created_at"])))
        for source, pattern, path, time_of in markers:
            try:
                state = marker_state(pattern, row, path, ("commit_sha", "has_unresolved_findings")
                                     + (("status",) if source == "summary" else ()))
                when = state and time_of()  # The summary's completion time is body text too.
            except ValueError as error:
                warn(f"PR #{number}: ignoring malformed {source} marker in {row.get('html_url') or 'a comment'}: {error}")
                continue
            if state and state.get("status", "completed") == "completed":
                result.append({"when": when, "head": state["commit_sha"],
                               "clean": state["has_unresolved_findings"] is False, "source": source})
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


def daily(rows, since, until, red):
    """UTC merge-date cohorts; absent releases are excluded from the median.

    red is main's red intervals as (start, end) pairs from red_main, end None
    while still red. A day that starts before RED_MAIN_KNOWN_FROM has no
    record, so its red minutes are unknown (None), never zero.
    """
    result = []
    day = date.fromisoformat(since)
    end = instant(until)
    known_from = instant(RED_MAIN_KNOWN_FROM)
    while day <= end.date():
        start = datetime.combine(day, time(), timezone.utc)
        stop = min(start + timedelta(days=1), end)
        cohort = [row for row in rows if instant(row["stages"]["merged"]).date() == day]
        medians = {}
        for a, b in (("opened", "merged"), ("merged", "released")):
            values = [(instant(row["stages"][b]) - instant(row["stages"][a])).total_seconds() / 60
                      for row in cohort if row["stages"][b]]
            medians[f"median_{a}_to_{b}_minutes"] = round(statistics.median(values), 2) if values else None
        minutes_red = None
        if start >= known_from:
            seconds = sum(max(0, (min(stop, instant(closed) if closed else end)
                                  - max(start, instant(opened))).total_seconds()) for opened, closed in red)
            minutes_red = round(seconds / 60, 2)
        result.append({"day": day.isoformat(), "merged": len(cohort), **medians, "red_main_minutes": minutes_red})
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


def red_main(api):
    """main's red intervals as (opened, closed or None) from main_build.py's issues.

    Each "Main build red" issue (ci-red label, main_build.MARKER in its body)
    is open exactly while main_build.py judges main red. Its intervals come
    from its own record: open at created_at, then each closed event ends an
    interval and each reopened event starts one; an issue open now is red
    until now.
    """
    result = []
    for row in pages(api, f"repos/{REPO}/issues?state=all&labels={quote(CI_RED_LABEL)}"):
        if "pull_request" in row or RED_MAIN_MARKER not in (row.get("body") or ""):
            continue
        opened = utc(row["created_at"])
        events = pages(api, f"repos/{REPO}/issues/{row['number']}/events?")
        for event in sorted((e for e in events if e["event"] in ("closed", "reopened")),
                            key=lambda e: instant(e["created_at"])):
            if event["event"] == "closed" and opened is not None:
                result.append((opened, utc(event["created_at"])))
                opened = None
            elif event["event"] == "reopened" and opened is None:
                opened = utc(event["created_at"])
        if opened is not None:
            result.append((opened, None))
    return sorted(result, key=lambda interval: instant(interval[0]))


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
    print(f"Red-main source: {report['red_main_source']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", required=True, type=date.fromisoformat, metavar="YYYY-MM-DD")
    parser.add_argument("--pr", type=int, action="append", default=[])
    parser.add_argument("--format", choices=("table", "json"), default="table")
    args = parser.parse_args()
    since = args.since.isoformat()
    try:
        rows = collect(github, since, args.pr)
        red = red_main(github)
        until = datetime.now(timezone.utc).isoformat()
        report = {"since": since, "as_of": utc(until), "release_source": "releases API published_at + REST compare ancestry",
                  "red_main_source": f"open/closed {RED_MAIN_TITLE!r} issues from main_build.py, "
                                     f"recorded from {RED_MAIN_KNOWN_FROM}; earlier days are unknown",
                  "prs": rows, "days": daily(rows, since, until, red)}
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
