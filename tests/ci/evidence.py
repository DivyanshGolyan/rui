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


def target_executables(targets):
    root = Path(".zig-cache/o/ci-compiled")
    rows = json.loads((root / "ci-targets.json").read_text())
    result = set()
    for target in targets:
        matches = [row["executables"] for row in rows if row["target"] == target]
        if len(matches) != 1 or not matches[0]:
            raise ValueError("Missing or ambiguous target executable inventory")
        for name in matches[0]:
            if not isinstance(name, str) or Path(name).name != name or name.startswith("."):
                raise ValueError("Foreign target executable path")
            result.add(str(root / name))
    return sorted(result)


def identity(targets, part, *, compiled=False):
    # Go's test runner discards its executable. Unrelated restored Zig binaries
    # cannot establish that test artifact's identity, so run these cheap checks.
    if "measurement-check" in targets:
        raise ValueError("measurement-check requires fresh Go execution")
    # Process fixtures compile temporary C helpers, and the sanitizer discards
    # its executable. Cached product binaries cannot identify those artifacts.
    # Only native unit gates retain their complete executable set today.
    if not compiled and set(targets) - {"test", "test-full", "test-logic"}:
        raise ValueError("Process/sanitizer gates require fresh execution: temporary native helpers are not retained")
    # The complete tree covers fixtures, policy, pins and workflow inputs, not
    # just production sources. Runner image and native tools cover SDK changes.
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Evidence requires an unchanged tracked source tree")
    system, machine = platform.system(), platform.machine()
    floors = {("Linux", "x86_64"): ("x86_64", "x86_64"),
              ("Darwin", "arm64"): ("aarch64", "apple_m1")}
    arch, model = floors[(system, machine)]
    cpu = dict(policy="baseline", arch=arch, model=model)
    if not compiled:
        manifest = json.loads(Path(".zig-cache/o/ci-compiled/ci-cpu.json").read_text())
        if any(manifest.get(key) != value for key, value in cpu.items()):
            raise ValueError("CI CPU identity mismatch")
        cpu = manifest
    return dict(format=2, tree=git("rev-parse", "HEAD^{tree}"), targets=targets, part=part,
                executables=target_executables(targets) if not compiled else None,
                system=system, machine=machine, cpu=cpu,
                image=[os.environ.get("ImageOS"), os.environ.get("ImageVersion")],
                tools=digest(Path(os.environ["RUNNER_TEMP"]) / "rui-native-tools.txt"),
                compiler=digest(shutil.which("zig")),
                python=platform.python_version(),
                h2={package: importlib.metadata.version(package)
                    for package in ("h2", "hpack", "hyperframe")}
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
    """Verify the exact artifact that passed, not a nondeterministic rebuild."""
    if artifact.get("digest") != "sha256:" + hashlib.sha256(archive).hexdigest():
        raise ValueError("Artifact digest mismatch or unavailable")
    if artifact["workflow_run"]["id"] != run["id"]:
        raise ValueError("Artifact origin mismatch")
    if run["conclusion"] != "success" or run["event"] != inputs["event"]:
        raise ValueError("Origin did not finish successfully in the same event")
    workflow = inputs["workflow"].split("/", 2)[2]
    if run["path"].split("@", 1)[0] != workflow or run["head_branch"] != inputs["branch"].removeprefix("refs/heads/"):
        raise ValueError("Origin workflow or branch mismatch")
    repository = os.environ["GITHUB_REPOSITORY"]
    if run["head_repository"]["full_name"] != repository:
        raise ValueError("Foreign repository evidence")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        paths = inputs["executables"]
        expected_files = ["evidence.json"] + ["executables/" + Path(path).name for path in paths]
        if (sorted(zipped.namelist()) != sorted(expected_files)
                or zipped.getinfo("evidence.json").file_size > 1024 * 1024
                or sum(info.file_size for info in zipped.infolist()) > 256 * 1024 * 1024):
            raise ValueError("Unexpected evidence archive")
        receipt = json.loads(zipped.read("evidence.json"))
        if receipt["inputs"] != inputs or receipt["run_id"] != run["id"] or receipt["run_attempt"] != run["run_attempt"]:
            raise ValueError("Evidence inputs or run identity mismatch")
        if receipt["verdict"] != "passed" or not paths or set(receipt["executables"]) != set(paths):
            raise ValueError("No passing evidence for the complete target executable set")
        for executable, expected in receipt["executables"].items():
            path = Path(executable)
            if path.parent != Path(".zig-cache/o/ci-compiled"):
                raise ValueError("Foreign executable path")
            # Stream archived bytes. Never strip debug sections, normalize
            # embedded paths/timestamps, or execute artifact-supplied code.
            with zipped.open("executables/" + path.name) as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != expected:
                    raise ValueError("Test executable missing or changed")
    commit = api(f"repos/{repository}/git/commits/{receipt['source_sha']}")
    if commit["tree"]["sha"] != inputs["tree"]:
        raise ValueError("Origin source tree mismatch")
    if run["event"] == "push":
        if receipt["source_sha"] != run["head_sha"]:
            raise ValueError("Origin run did not test the receipt source")
    elif run["event"] == "pull_request":
        pulls = run["pull_requests"]
        if len(pulls) != 1:
            raise ValueError("Origin PR identity unavailable")
        # Nested PR heads advance even on historical runs. Only the run's
        # immutable head_sha binds the source merge's second parent below.
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
        if artifact["expired"] or artifact["size_in_bytes"] > 256 * 1024 * 1024 or artifact["workflow_run"]["id"] == int(os.environ["GITHUB_RUN_ID"]):
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
                  "Source and platform inputs match; the retained target executables match their exact passing hashes. "
                  "No new execution; this run's rebuilt executables are not accepted by this evidence.", file=summary)
        return True
    return False


def record(inputs):
    destination = Path(os.environ["RUNNER_TEMP"]) / "rui-evidence"
    if destination.exists():
        shutil.rmtree(destination)
    (destination / "executables").mkdir(parents=True)
    executables = {}
    for executable in inputs["executables"]:
        path = Path(executable)
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError("Target executable missing or not executable")
        retained = destination / "executables" / path.name
        shutil.copyfile(path, retained)
        executables[executable] = digest(retained)
    if not executables:
        raise ValueError("No target executable evidence")
    receipt = dict(inputs=inputs, executables=executables, verdict="passed",
                   source_sha=git("rev-parse", "HEAD"), run_id=int(os.environ["GITHUB_RUN_ID"]),
                   run_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]))
    (destination / "evidence.json").write_text(json.dumps(receipt, sort_keys=True))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        print(f"evidence_name={name(inputs)}", file=output)
        print(f"evidence_path={destination}", file=output)
