"""Verify same-tree Actions evidence; qualification always executes afresh."""
import hashlib
import importlib.metadata
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import zipfile


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def identity(targets, part):
    # The complete tree covers fixtures, policy, pins and workflow inputs, not
    # just production sources. Runner image and native tools cover SDK changes.
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Evidence requires an unchanged tracked source tree")
    return dict(tree=git("rev-parse", "HEAD^{tree}"), targets=targets, part=part,
                system=platform.system(), machine=platform.machine(),
                image=[os.environ.get("ImageOS"), os.environ.get("ImageVersion")],
                tools=digest(Path(os.environ["RUNNER_TEMP"]) / "rui-native-tools.txt"),
                compiler=digest(shutil.which("zig")),
                python=platform.python_version(),
                go=subprocess.check_output(["go", "version"], text=True).strip()
                if "measurement-check" in targets else None,
                h2=importlib.metadata.version("h2")
                if set(targets) & {"transport-h2-integration", "codex-h2-integration"} else None,
                workflow=os.environ["GITHUB_WORKFLOW_REF"].split("@", 1)[0],
                event=os.environ["GITHUB_EVENT_NAME"],
                branch=os.environ.get("GITHUB_HEAD_REF") or os.environ["GITHUB_REF"])


def name(inputs):
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    return "rui-evidence-" + key


def api(path, binary=False):
    data = subprocess.check_output(["gh", "api", path], stderr=subprocess.PIPE, timeout=90)
    return data if binary else json.loads(data)


def verify(archive, artifact, run, inputs):
    """Refuse mismatched provenance, tampered archives and absent executables."""
    if artifact.get("digest") != "sha256:" + hashlib.sha256(archive).hexdigest():
        raise ValueError("Artifact digest mismatch or unavailable")
    if artifact["workflow_run"]["id"] != run["id"]:
        raise ValueError("Artifact origin mismatch")
    if run["conclusion"] != "success" or run["event"] != inputs["event"]:
        raise ValueError("Origin did not finish successfully in the same event")
    workflow = inputs["workflow"].split("/", 2)[2]
    if run["path"] != workflow or run["head_branch"] != inputs["branch"].removeprefix("refs/heads/"):
        raise ValueError("Origin workflow or branch mismatch")
    repository = os.environ["GITHUB_REPOSITORY"]
    if run["head_repository"]["full_name"] != repository:
        raise ValueError("Foreign repository evidence")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        if zipped.namelist() != ["evidence.json"] or zipped.getinfo("evidence.json").file_size > 1024 * 1024:
            raise ValueError("Unexpected evidence archive")
        receipt = json.loads(zipped.read("evidence.json"))
    if receipt["inputs"] != inputs or receipt["run_id"] != run["id"] or receipt["run_attempt"] != run["run_attempt"]:
        raise ValueError("Evidence inputs or run identity mismatch")
    if receipt["verdict"] != "passed" or not receipt["executables"]:
        raise ValueError("No passing executable evidence")
    for executable, expected in receipt["executables"].items():
        path = Path(executable)
        # Only hash cache artifacts; never follow an artifact-supplied path out
        # of the build cache or execute downloaded content.
        if path.is_absolute() or ".." in path.parts or path.parts[:2] != (".zig-cache", "o"):
            raise ValueError("Foreign executable path")
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError("Test executable missing or changed")
    commit = api(f"repos/{repository}/git/commits/{receipt['source_sha']}")
    if commit["tree"]["sha"] != inputs["tree"]:
        raise ValueError("Origin source tree mismatch")
    if run["event"] == "push":
        if receipt["source_sha"] != run["head_sha"]:
            raise ValueError("Origin run did not test the receipt source")
    elif run["event"] == "pull_request":
        pulls = run["pull_requests"]
        if len(pulls) != 1 or pulls[0]["head"]["sha"] != run["head_sha"]:
            raise ValueError("Origin PR identity unavailable")
        base, head = pulls[0]["base"]["sha"], run["head_sha"]
        if [parent["sha"] for parent in commit["parents"]] != [base, head]:
            raise ValueError("Origin merge parents mismatch")
        # A PR run's head_sha is the PR head, not the tested merge ref. Rebuild
        # its merge tree from independent run metadata, never the receipt claim.
        subprocess.run(["git", "fetch", "--quiet", "--no-tags", "origin", base, head],
                       check=True, capture_output=True, timeout=90)
        merged = git("merge-tree", "--write-tree", base, head).splitlines()[0]
        if merged != inputs["tree"]:
            raise ValueError("Origin run merge tree mismatch")
    else:
        raise ValueError("Only selected push and PR checks support reuse")
    return receipt


def restore(inputs):
    repository = os.environ["GITHUB_REPOSITORY"]
    # Scope to this exact workflow/event/branch and input hash. Missing/expired
    # evidence, unavailable API or cache identity means run, never accept.
    artifacts = api(f"repos/{repository}/actions/artifacts?name={name(inputs)}&per_page=20")["artifacts"]
    for artifact in artifacts:
        if artifact["expired"] or artifact["size_in_bytes"] > 2 * 1024 * 1024 or artifact["workflow_run"]["id"] == int(os.environ["GITHUB_RUN_ID"]):
            continue
        try:
            run = api(f"repos/{repository}/actions/runs/{artifact['workflow_run']['id']}")
            archive = api(f"repos/{repository}/actions/artifacts/{artifact['id']}/zip", binary=True)
            verify(archive, artifact, run, inputs)
        except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
            print(f"Evidence not reusable: {error}", flush=True)
            continue
        print(f"Verified same-tree evidence: {run['html_url']} (artifact {artifact['id']})", flush=True)
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            print(f"Verified same-tree evidence: {run['html_url']} (artifact {artifact['id']}). "
                  "Inputs, archive digest and cached executable hashes match. No new execution.", file=summary)
        return True
    return False


def record(inputs):
    executables = {str(path): digest(path) for path in sorted(Path(".zig-cache/o").glob("*/*"))
                   if path.is_file() and not path.is_symlink() and os.access(path, os.X_OK)}
    if not executables:
        return  # No artifact identity: never publish reusable acceptance.
    receipt = dict(inputs=inputs, executables=executables, verdict="passed",
                   source_sha=git("rev-parse", "HEAD"), run_id=int(os.environ["GITHUB_RUN_ID"]),
                   run_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]))
    destination = Path(os.environ["RUNNER_TEMP"]) / "rui-evidence" / "evidence.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(receipt, sort_keys=True))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        print(f"evidence_name={name(inputs)}", file=output)
        print(f"evidence_path={destination}", file=output)
