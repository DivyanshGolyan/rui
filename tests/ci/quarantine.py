#!/usr/bin/env python3
"""Listed flakes: known intermittent failures that do not block PR admission.

quarantine.json lists fixture-and-assertion signatures, as report_issue.py
names them, each with the file it fails in, its tracking issue, an owner and
an expiry at most 14 days after it was added. A listed signature still runs
and reports. When every failure of a suite batch is a listed, unexpired
signature, run_selected.py reruns the batch once; if it fails again only on
listed signatures, PR admission passes with a warning and promotion fails, so
promotion blocks on two consecutive failures. An expired entry blocks again.
Store, recovery and upgrade tests are never listed, and a PR that touches a
strict path gets no quarantine.
"""
import datetime
import json
from pathlib import Path
import re

from report_issue import COMMAND, SCRIPT, failure_causes, untimed
from strict_paths import strict

LIST = Path(__file__).with_name("quarantine.json")
FIELDS = {"signature", "path", "issue", "owner", "added", "expires"}
MAX_DAYS = 14
# Strict paths fail for real and are never rerun; so are these suites wherever they live.
NEVER = re.compile(r"store|recovery|upgrade", re.IGNORECASE)
# report_issue.py's Zig suffixes; a test name may hold apostrophes, so the suffix ends it.
ZIG_TEST = re.compile(r"zig test '(.*)' (?:failed(?: \(\w+\))?|terminated with signal \w+)")
SUMMARY = re.compile(r"^Build Summary: \d+/\d+ steps succeeded \((\d+) failed\)", re.M)
OWNER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})")


def subject(signature):
    """The test a signature names: a Zig test's name or a fixture's path, not
    the failing line, whose call text may mention a Store (`--store`)."""
    if signature.startswith("zig test "):
        zig = ZIG_TEST.fullmatch(signature)
        return zig[1] if zig else signature  # Unparsed: judge all of it.
    return signature.split(": ", 1)[0]


def entries(path=LIST):
    return json.loads(path.read_text())["flakes"]


def problems(listed, root):
    """Why each entry may not be listed; empty for a valid list."""
    found, seen = [], set()
    for index, entry in enumerate(listed):
        name = f"entry {index} ({entry.get('signature', '?')[:60]})"
        if set(entry) != FIELDS:
            found.append(f"{name} has fields {sorted(entry)}, not {sorted(FIELDS)}")
            continue
        if entry["signature"] in seen:
            found.append(f"{name} repeats a signature")
        seen.add(entry["signature"])
        if not (root / entry["path"]).is_file():
            found.append(f"{name} names {entry['path']}, which does not exist")
        if strict([entry["path"]]) or NEVER.search(entry["path"]) or NEVER.search(subject(entry["signature"])):
            found.append(f"{name} is a Store, recovery or upgrade test, which always fails for real")
        if entry["path"].startswith("tests/integration/") and not entry["signature"].startswith(entry["path"] + ": "):
            found.append(f"{name}: a fixture's signature starts with its path, as report_issue.py names it")
        if not (isinstance(entry["issue"], int) and entry["issue"] > 0):
            found.append(f"{name} needs its tracking issue's number")
        if not (isinstance(entry["owner"], str) and OWNER.fullmatch(entry["owner"])):
            found.append(f"{name} needs an owner's GitHub login")
        try:
            days = (datetime.date.fromisoformat(entry["expires"]) - datetime.date.fromisoformat(entry["added"])).days
        except (TypeError, ValueError):
            found.append(f"{name} needs ISO dates for added and expires")
            continue
        if not 0 < days <= MAX_DAYS:
            found.append(f"{name} expires {days} days after it was added; the most is {MAX_DAYS}")
    return found


def today():
    return datetime.datetime.now(datetime.timezone.utc).date().isoformat()


def listed(output, flakes, day, cases):
    """The unexpired entries that explain every failure in a batch's output, or [] if anything else failed.

    Each failed command must be accounted for: the check.sh driver, whose
    failed cases all become signatures, or a listed fixture run directly. A
    failed step without a failed command, such as a compile error, or a
    failure without a parsed traceback is never a listed flake.
    """
    log = untimed(output)
    active = {flake["signature"]: flake for flake in flakes if flake["added"] <= day <= flake["expires"]}
    paths = {flake["path"] for flake in active.values()}
    commands = COMMAND.findall(log)
    summary = SUMMARY.search(log)
    if not active or not commands or not summary or int(summary[1]) != len(commands):
        return []
    for command in commands:
        script = SCRIPT.search(command)
        if "check.sh" not in command and not (script and script[0] in paths):
            return []
    causes = failure_causes(log, cases, keep_unexplained=True)
    if not causes or any(cause.signature not in active for cause in causes):
        return []
    return [active[cause.signature] for cause in causes]
