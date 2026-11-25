#!/usr/bin/env python3
"""Pause PR CI while main is known red, unless the PR names the red issue."""
import json
import os
import re
import urllib.request
from datetime import datetime, timedelta, timezone

LABEL = "main-red"
# An issue untouched this long is more likely forgotten than still red; it must not stop every PR.
FRESH = timedelta(days=1)


def blocking(issues, pr_body, now):
    """Numbers of open main-red issues updated within FRESH, or [] when pr_body names any of them as #N."""
    numbers = sorted(issue["number"] for issue in issues if "pull_request" not in issue
                     and now - datetime.fromisoformat(issue["updated_at"].replace("Z", "+00:00")) < FRESH)
    mentioned = {int(number) for number in re.findall(r"#(\d+)\b", pr_body or "")}
    if mentioned.intersection(numbers):
        return []
    return numbers


def main():
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    repo = os.environ["GITHUB_REPOSITORY"]
    request = urllib.request.Request(
        f"{api}/repos/{repo}/issues?state=open&labels={LABEL}&per_page=100",
        headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            issues = json.load(response)
    except (OSError, ValueError) as error:
        # Failing open costs minutes; failing closed would stop every PR on a GitHub hiccup.
        print(f"::warning::could not list main-red issues ({error}); running the PR as usual")
        issues = []
    numbers = blocking(issues, os.environ.get("PR_BODY", ""), datetime.now(timezone.utc))
    if numbers:
        print("::notice::main is red ({}); PR build and tests are skipped".format(
            ", ".join(f"#{number}" for number in numbers)))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("main_red={}\n".format(" ".join(str(number) for number in numbers)))


if __name__ == "__main__":
    main()
