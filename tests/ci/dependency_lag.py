#!/usr/bin/env python3
"""Keep one deps-behind issue listing pinned dependencies behind upstream (#1893).

Reads the pins in build.zig.zon, asks each tracked upstream for its newest
release and keeps a single open issue current. Never fails a PR, never opens
a PR, never closes the issue.
"""
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple

from conflict_alert import github, pages

ISSUE_LABEL = "deps-behind"
MARKER = "<!-- deps-behind -->"
TITLE = "Pinned dependencies behind upstream"
SERIES = {"openssl": 2}
PRERELEASE = re.compile(r"alpha|beta|rc|pre|dev", re.IGNORECASE)
NUMBERS = re.compile(r"\d+(?:\.\d+)*")
RELEASE_URL = re.compile(r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/.+")
TAG_URL = re.compile(r"https://github\.com/([^/]+/[^/]+)/archive/refs/tags/(.+)\.tar\.gz")
SQLITE_URL = re.compile(r"https://www\.sqlite\.org/\d{4}/sqlite-amalgamation-(\d{7})\.zip")
SQLITE_CANDIDATE = re.compile(r"sqlite-amalgamation-(\d{7})\.zip")
ENTRY = re.compile(r'\.([A-Za-z_]\w*) = \.\{\s*\.url = "([^"]+)"')


class Pin(NamedTuple):
    name: str
    url: str


class Source(NamedTuple):
    kind: str
    repo: str | None
    current: str


class Behind(NamedTuple):
    name: str
    source: Source
    latest: str


def pins(manifest):
    section = manifest.split(".dependencies = .{", 1)[1].split("\n    },", 1)[0]
    return [Pin(name, url) for name, url in ENTRY.findall(section)]


def tracked(pin):
    if match := RELEASE_URL.fullmatch(pin.url):
        return Source("releases", match.group(1), match.group(2))
    if match := TAG_URL.fullmatch(pin.url):
        return Source("tags", match.group(1), match.group(2))
    if match := SQLITE_URL.fullmatch(pin.url):
        return Source("sqlite", None, match.group(1))
    return None


def _first_digit(tag):
    for index, char in enumerate(tag):
        if char.isdigit():
            return index
    return None


def numbers(tag):
    start = _first_digit(tag)
    if start is None or PRERELEASE.search(tag[start:]):
        return None
    return tuple(int(part) for part in NUMBERS.match(tag[start:]).group().split("."))


def _prefix(tag):
    start = _first_digit(tag)
    return None if start is None else tag[:start]


def newest(name, current, candidates):
    current_numbers, current_prefix = numbers(current), _prefix(current)
    best = None
    for tag in candidates:
        found = numbers(tag)
        if found is None or _prefix(tag) != current_prefix:
            continue
        if name in SERIES and found[:SERIES[name]] != current_numbers[:SERIES[name]]:
            continue
        if found > current_numbers and (best is None or found > best[0]):
            best = (found, tag)
    return None if best is None else best[1]


def _link(source, version):
    if source.kind == "sqlite":
        return f"[{version}](https://sqlite.org/download.html)"
    return f"[{version}](https://github.com/{source.repo}/releases/tag/{version})"


def body(behind, unchecked, failed, today):
    lines = [MARKER, f"Weekly check of the pins in `build.zig.zon`, as of {today}.", ""]
    if behind:
        lines += ["| Dependency | Pinned | Latest |", "| --- | --- | --- |"]
        lines += [f"| {entry.name} | {entry.source.current} | {_link(entry.source, entry.latest)} |"
                  for entry in behind]
    else:
        lines.append(f"All checked pins are current as of {today}.")
    lines.append("")
    if unchecked:
        lines += [f"Not checked (pinned to a commit): {', '.join(unchecked)}", ""]
    if failed:
        lines += [f"Could not check: {name} ({reason})" for name, reason in failed] + [""]
    if behind:
        lines.append("The PR that bumps these pins should say `Fixes #N` so merging closes this issue.")
    return "\n".join(lines).rstrip() + "\n"


def candidates(api, source, fetch_text):
    if source.kind == "releases":
        releases = pages(api, f"repos/{source.repo}/releases?")
        return [release["tag_name"] for release in releases
                if not release["draft"] and not release["prerelease"]]
    if source.kind == "tags":
        return [tag["name"] for tag in pages(api, f"repos/{source.repo}/tags?")]
    return SQLITE_CANDIDATE.findall(fetch_text("https://sqlite.org/download.html"))


def _reason(failure):
    text = (getattr(failure, "stderr", "") or str(failure)).strip()
    return text.splitlines()[0] if text else type(failure).__name__


def run(api, repo, manifest, fetch_text, today):
    behind, unchecked, failed, checked = [], [], [], 0
    for pin in pins(manifest):
        source = tracked(pin)
        if source is None:
            unchecked.append(pin.name)
            continue
        checked += 1
        try:
            latest = newest(pin.name, source.current, candidates(api, source, fetch_text))
        except (subprocess.CalledProcessError, OSError, ValueError) as failure:
            print(f"::warning::{pin.name}: {_reason(failure)}")
            failed.append((pin.name, _reason(failure)))
            continue
        if latest is not None:
            behind.append(Behind(pin.name, source, latest))

    text = body(behind, unchecked, failed, today)
    issues = [issue for issue in pages(api, f"repos/{repo}/issues?labels={ISSUE_LABEL}&state=open")
              if "pull_request" not in issue]
    if issues:
        issue = issues[0]
        if issue["body"] != text:
            api("PATCH", f"repos/{repo}/issues/{issue['number']}", [("body", text)])
            action = f"updated issue #{issue['number']}"
        else:
            action = f"issue #{issue['number']} already current"
    elif behind:
        api("POST", f"repos/{repo}/issues", [("title", TITLE), ("body", text), ("labels[]", ISSUE_LABEL)])
        action = "opened the issue"
    else:
        action = "nothing behind, no issue"
    print(f"behind: {len(behind)} of {checked} checked; not checked: {len(unchecked)}; "
          f"could not check: {len(failed)}; {action}")
    return 1 if checked and len(failed) == checked else 0


def fetch_text(url):
    request = urllib.request.Request(url, headers={"User-Agent": "rui-dependency-lag"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "replace")


def main():
    root = Path(__file__).resolve().parents[2]
    manifest = (root / "build.zig.zon").read_text()
    today = datetime.now(timezone.utc).date().isoformat()
    sys.exit(run(github, os.environ["GITHUB_REPOSITORY"], manifest, fetch_text, today))


if __name__ == "__main__":
    main()
