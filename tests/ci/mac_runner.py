#!/usr/bin/env python3
"""Choose the Mac runner; unavailable or untrusted inputs always use hosted CI."""

import json
import os
import sys
from pathlib import Path

ALLOWLIST = ("DivyanshGolyan",)
HOSTED = "macos-15"
SELF_HOSTED = ["self-hosted", "macOS", "ARM64", "rui-mac"]


def _object(value):
    return value if isinstance(value, dict) else {}


def _enabled(value):
    return value is True or value == "true"


def decide(event_name, event, actor, triggering_actor, repository, inputs, switch, runners):
    """Return a runs-on value and one sentence explaining the scheduling snapshot."""
    if switch == "off":
        return HOSTED, "Hosted macOS is selected because RUI_MAC_RUNNER is off."
    inputs = _object(inputs)
    if _enabled(inputs.get("promotion")) or _enabled(inputs.get("compile_only")):
        return HOSTED, "Hosted macOS is required for promotion and compile-only runs."
    if actor not in ALLOWLIST or triggering_actor not in ALLOWLIST:
        return HOSTED, "Hosted macOS is selected because both actors must be allowlisted."
    if event_name == "pull_request":
        pr = _object(_object(event).get("pull_request"))
        head_repo = _object(_object(pr.get("head")).get("repo")).get("full_name")
        if not repository or head_repo != repository:
            return HOSTED, "Hosted macOS is required for a pull request from a fork or missing head repository."
        if _object(pr.get("user")).get("login") not in ALLOWLIST:
            return HOSTED, "Hosted macOS is selected because the pull request author is not allowlisted."
    elif event_name != "workflow_dispatch":
        return HOSTED, "Hosted macOS is required for this event type."
    if runners is None:
        return HOSTED, "Hosted macOS is selected because runner status is unavailable."
    if isinstance(runners, list):
        for runner in runners:
            runner = _object(runner)
            labels = runner.get("labels")
            if (runner.get("status") == "online" and runner.get("busy") is False
                    and isinstance(labels, list)
                    and any(_object(label).get("name") == "rui-mac" for label in labels)):
                return SELF_HOSTED.copy(), "The allowlisted run will use the online, idle rui-mac runner."
    return HOSTED, "Hosted macOS is selected because no rui-mac runner is online and idle."


def main():
    if sys.argv[1:] == ["allowlist"]:
        print("\n".join(ALLOWLIST))
        return
    runs_on, reason = HOSTED, "Hosted macOS is selected because routing could not read its inputs."
    try:
        runners = None
        status = Path(os.environ.get("RUNNERS_PATH", "runners.json"))
        if status.exists():
            payload = json.loads(status.read_text())
            if isinstance(payload, dict) and isinstance(payload.get("runners"), list):
                runners = payload["runners"]
        runs_on, reason = decide(
            os.environ.get("GITHUB_EVENT_NAME"),
            json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
            os.environ.get("GITHUB_ACTOR"), os.environ.get("GITHUB_TRIGGERING_ACTOR"),
            os.environ.get("GITHUB_REPOSITORY"), json.loads(os.environ.get("INPUTS", "{}")),
            os.environ.get("RUI_MAC_RUNNER"), runners,
        )
    except (OSError, ValueError, KeyError, TypeError):
        # Status fetch/JSON failures and malformed events must never block CI.
        pass
    output = f"runs_on={json.dumps(runs_on)}\nself_hosted={str(isinstance(runs_on, list)).lower()}\n"
    print(output, end="")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(f"Mac runner: `{json.dumps(runs_on)}`. {reason}\n")


if __name__ == "__main__":
    main()
