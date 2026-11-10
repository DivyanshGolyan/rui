#!/usr/bin/env python3
"""Report, per ISO week, the share of closed `ci-red` issues that were real bugs.

Every CI failure files one `ci-red` issue per cause (report_issue.py). Whoever
closes it adds exactly one cause label, so this counts what CI caught rather
than what it cost. A week is the ISO week the issue was last closed in.

    strict = real / labelled          a product bug or regression
    broad  = (real + compile) / labelled

Unlabelled and multiply-labelled issues stay out of both rates and are listed
by number, so a gap in labelling shows instead of skewing the rate.
--create-labels creates or updates the cause labels themselves.
"""
import argparse
from collections import defaultdict
import datetime
import json
import subprocess
import sys

LABEL = "ci-red"
PREFIX = "cause:"
# The classes of the CI report's failure ledgers, in the order its table uses.
CAUSES = {
    "real": ("B60205", "CI red: the fix changed product behavior (a bug or regression)"),
    "compile": ("D93F0B", "CI red: a compile, type-check or format error"),
    "stale": ("FBCA04", "CI red: a test lagged a deliberate change, or restated a value the product owns"),
    "fixture": ("C5DEF5", "CI red: a test or fixture bug, race or platform assumption"),
    "flake": ("BFD4F2", "CI red: intermittent; passed on rerun with no fix found yet"),
    "policy": ("D4C5F9", "CI red: CI's own policy checks or tooling (whitespace, generated files, schema number, reporting)"),
    "infra": ("EDEDED", "CI red: runner, network or service setup, not the tested code"),
}


def week(closed_at):
    """The ISO week, as 2026-W45, an RFC 3339 UTC time falls in."""
    year, number, _ = datetime.datetime.fromisoformat(closed_at.replace("Z", "+00:00")).isocalendar()
    return f"{year}-W{number:02d}"


def cause(issue):
    """The one cause label's name, or None when it has none or several."""
    found = [label["name"][len(PREFIX):] for label in issue["labels"]
             if label["name"].startswith(PREFIX) and label["name"][len(PREFIX):] in CAUSES]
    return found[0] if len(found) == 1 else None


def weeks(issues):
    """Per-week counts, oldest first, from `gh issue list --json number,closedAt,labels`."""
    rows = defaultdict(lambda: {"closed": 0, "unlabelled": [], **{name: 0 for name in CAUSES}})
    for issue in issues:
        if not issue.get("closedAt"):
            continue
        row = rows[week(issue["closedAt"])]
        row["closed"] += 1
        name = cause(issue)
        if name is None:
            row["unlabelled"].append(issue["number"])
        else:
            row[name] += 1
    result = []
    for name, row in sorted(rows.items()):
        labelled = row["closed"] - len(row["unlabelled"])
        result.append({"week": name, **row, "unlabelled": sorted(row["unlabelled"]), "labelled": labelled,
                       "strict": row["real"] / labelled if labelled else None,
                       "broad": (row["real"] + row["compile"]) / labelled if labelled else None})
    return result


def percent(value):
    return "-" if value is None else f"{value:.0%}"


def table(rows):
    header = ["week", "closed", "labelled", "real", "compile", "strict", "broad", "unlabelled"]
    lines = ["| " + " | ".join(header) + " |", "|" + " --- |" * len(header)]
    for row in rows:
        missing = " ".join(f"#{number}" for number in row["unlabelled"]) or "-"
        lines.append(f"| {row['week']} | {row['closed']} | {row['labelled']} | {row['real']} | {row['compile']} | "
                     f"{percent(row['strict'])} | {percent(row['broad'])} | {missing} |")
    return "\n".join(lines)


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--weeks", type=int, default=8, help="the most recent weeks to show (default 8)")
    parser.add_argument("--json", action="store_true", help="print the rows as JSON instead of a table")
    parser.add_argument("--create-labels", action="store_true", help="create or update the cause labels, then report")
    args = parser.parse_args()
    if args.create_labels:
        for name, (color, description) in CAUSES.items():
            gh("label", "create", PREFIX + name, "--color", color, "--description", description, "--force")
    issues = json.loads(gh("issue", "list", "--label", LABEL, "--state", "closed", "--limit", "1000",
                           "--json", "number,closedAt,labels"))
    rows = weeks(issues)[-args.weeks:]
    print(json.dumps(rows, indent=2) if args.json else table(rows))
    if any(row["unlabelled"] for row in rows):
        print(f"Label each closed {LABEL} issue with one of: " + ", ".join(PREFIX + name for name in CAUSES), file=sys.stderr)


if __name__ == "__main__":
    main()
