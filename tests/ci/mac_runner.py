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


def admission(event_name, event, actor, triggering_actor, repository, allowlist=ALLOWLIST):
    """Apply the shared trusted-run policy to routing and the protected Mac hook."""
    if actor not in allowlist or triggering_actor not in allowlist:
        return False, "Both actors must be allowlisted to use the personal Mac."
    if event_name == "pull_request":
        pr = _object(_object(event).get("pull_request"))
        head_repo = _object(_object(pr.get("head")).get("repo")).get("full_name")
        if not repository or head_repo != repository:
            return False, "A pull request must have its head repository here to use the personal Mac."
        if _object(pr.get("user")).get("login") not in allowlist:
            return False, "The pull request author must be allowlisted to use the personal Mac."
    elif event_name != "workflow_dispatch":
        return False, "This event type is not admitted on the personal Mac."
    return True, "The run satisfies the trusted Mac admission policy."


def decide(event_name, event, actor, triggering_actor, repository, inputs, switch, runners, queue=None):
    """Return a runs-on value and one sentence explaining the scheduling snapshot."""
    if switch == "off":
        return HOSTED, "Hosted macOS is selected because RUI_MAC_RUNNER is off."
    inputs = _object(inputs)
    if _enabled(inputs.get("promotion")) or _enabled(inputs.get("compile_only")):
        return HOSTED, "Hosted macOS is required for promotion and compile-only runs."
    admitted, reason = admission(event_name, event, actor, triggering_actor, repository)
    if not admitted:
        return HOSTED, reason
    if runners is None:
        return HOSTED, "Hosted macOS is selected because runner status is unavailable."
    keys = ("mac_queued", "hosted_queued", "hosted_running")
    valid_queue = isinstance(queue, dict) and all(type(queue.get(key)) is int and queue[key] >= 0 for key in keys)
    counts = (f" Mac queued: {queue['mac_queued']}, hosted queued: {queue['hosted_queued']},"
              f" hosted running: {queue['hosted_running']}." if valid_queue else " Queue data is unavailable.")
    if isinstance(runners, list):
        for runner in runners:
            runner = _object(runner)
            labels = runner.get("labels")
            if (runner.get("status") == "online" and isinstance(labels, list)
                    and any(_object(label).get("name") == "rui-mac" for label in labels)):
                if runner.get("busy") is False:
                    return SELF_HOSTED.copy(), "The allowlisted run will use the online, idle rui-mac runner." + counts
                if (runner.get("busy") is True and valid_queue
                        and queue["mac_queued"] < queue["hosted_queued"] + (queue["hosted_running"] >= 5)):
                    return SELF_HOSTED.copy(), "The online rui-mac queue is shorter than the hosted backlog." + counts
    return HOSTED, "Hosted macOS is selected because no eligible rui-mac runner has a shorter queue or is idle." + counts



def registration_record(name, runner_id=None):
    """Name one installation before config, then bind its confirmed remote ID."""
    record = {"version": 1, "repository": "DivyanshGolyan/rui", "name": name, "id": runner_id}
    registration_identity(record)
    return record


def registration_identity(record):
    """Validate the protected identity shared by setup, repair and removal."""
    if (not isinstance(record, dict) or type(record.get("version")) is not int or record.get("version") != 1
            or record.get("repository") != "DivyanshGolyan/rui" or "id" not in record):
        raise ValueError("Missing or invalid installed runner identity")
    name, runner_id = record.get("name"), record.get("id")
    if not isinstance(name, str) or not name or any(character in name for character in "\r\n\x00"):
        raise ValueError("Invalid installed runner name")
    if runner_id is not None and (type(runner_id) is not int or runner_id <= 0):
        raise ValueError("Invalid installed runner ID")
    return name, runner_id


def registration_candidate(registration, runners, local_id=None):
    """Match the installed identity without discarding evidence of a renamed runner."""
    name, runner_id = registration_identity(registration)
    if not isinstance(runners, list) or any(
            not isinstance(row, dict) or type(row.get("id")) is not int or row["id"] <= 0
            or not isinstance(row.get("name"), str) or not row["name"] for row in runners):
        raise ValueError("Runner status is unavailable or malformed; preserve the installation and retry.")
    candidates = [row for row in runners if row["id"] == runner_id or row["name"] == name
                  or (local_id is not None and row["id"] == local_id)]
    if not candidates:
        return None
    if (len(candidates) != 1 or candidates[0]["name"] != name
            or (runner_id is not None and candidates[0]["id"] != runner_id)):
        raise ValueError("The remote runner identity changed or is ambiguous; restore its installed name and ID before repair.")
    return candidates[0]


def removal_action(registration, runners, local, credentials):
    """Require registration-scoped proof before discarding local recovery state."""
    try:
        name, runner_id = registration_identity(registration)
    except ValueError:
        return "repair", "Repair the missing or invalid installed runner identity before uninstalling."
    if local is not None:
        if (not isinstance(local, dict) or local.get("agentName") != name
                or not isinstance(local.get("gitHubUrl"), str)
                or local["gitHubUrl"].rstrip("/") != "https://github.com/DivyanshGolyan/rui"
                or type(local.get("agentId")) is not int or local["agentId"] <= 0
                or (runner_id is not None and local["agentId"] != runner_id)):
            return "repair", "Local runner configuration differs from the installed identity; repair it before removal."
    try:
        candidate = registration_candidate(registration, runners, local["agentId"] if local else None)
    except ValueError as error:
        return "repair", str(error)
    if candidate is None:
        return "cleanup", "The API confirms the installed runner registration is absent; local cleanup may finish."
    if local is None or local["agentId"] != candidate["id"] or credentials is not True:
        return "repair", "The installed runner still exists remotely; repair its local configuration and credentials before removal."
    return "deregister", "Remove the matching installed runner registration before deleting its account and home."


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
        queue = None
        try:
            queue = json.loads(Path(os.environ.get("QUEUE_PATH", "queue.json")).read_text())
        except (OSError, ValueError):
            pass
        runs_on, reason = decide(
            os.environ.get("GITHUB_EVENT_NAME"),
            json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
            os.environ.get("GITHUB_ACTOR"), os.environ.get("GITHUB_TRIGGERING_ACTOR"),
            os.environ.get("GITHUB_REPOSITORY"), json.loads(os.environ.get("INPUTS", "{}")),
            os.environ.get("RUI_MAC_RUNNER"), runners, queue,
        )
    except (OSError, ValueError, KeyError, TypeError):
        # Status fetch/JSON failures and malformed events must never block CI.
        pass
    output = f"runs_on={json.dumps(runs_on)}\nself_hosted={str(isinstance(runs_on, list)).lower()}\n"
    print(output, end="")
    # The step summary is easy to miss; keep the reason in the job log too.
    print(f"reason: {reason}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(f"Mac runner: `{json.dumps(runs_on)}`. {reason}\n")


if __name__ == "__main__":
    main()
