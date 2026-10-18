"""Same-run compiled-output handoff, never a test-acceptance receipt."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

import evidence


def roots():
    return {"binaries": Path(".zig-cache/o/ci-compiled").resolve(),
            "packages": Path("zig-pkg").resolve()}


def identity(targets):
    # Go test binaries are not transferred; their target still executes fresh.
    inputs = evidence.identity([t for t in targets if t != "measurement-check"], "all", compiled=True)
    inputs["targets"] = targets
    return inputs


def package(targets, destination, binaries=None):
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "compiled.tar.gz"
    inputs = identity(targets)
    executables = {}
    sources = roots()
    if binaries is not None:
        sources["binaries"] = binaries
    with tarfile.open(archive, "w:gz", compresslevel=1) as output:
        for label, root in sources.items():
            for directory, children, files in os.walk(root, followlinks=False):
                children.sort()
                for child in children[:]:
                    if (Path(directory) / child).is_symlink():
                        raise ValueError(f"Unexpected build symlink: {child}")
                for filename in sorted(files):
                    source = Path(directory) / filename
                    name = str(PurePosixPath(label, source.relative_to(root)))
                    info = source.lstat()
                    if not stat.S_ISREG(info.st_mode):
                        raise ValueError(f"Unexpected build file: {name}")
                    elif info.st_mode & 0o111:
                        executables[name] = [evidence.digest(source), stat.S_IMODE(info.st_mode)]
                    member = output.gettarinfo(source, arcname=name)
                    with source.open('rb') as stream:
                        output.addfile(member, stream)
    receipt = dict(verdict="compiled-not-tested", inputs=inputs,
                   source_sha=evidence.git("rev-parse", "HEAD"),
                   run_id=int(os.environ["GITHUB_RUN_ID"]),
                   run_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
                   archive=evidence.digest(archive), executables=executables)
    (destination / "compiled.json").write_text(json.dumps(receipt, sort_keys=True))
    print(f"Compiled, not tested: {archive.stat().st_size} compressed bytes; {len(executables)} executable files")


def unpack(archive, receipt, inputs):
    if receipt["verdict"] != "compiled-not-tested" or receipt["inputs"] != inputs:
        raise ValueError("Compiled inputs mismatch")
    if (receipt["run_id"], receipt["run_attempt"], receipt["source_sha"]) != (
            int(os.environ["GITHUB_RUN_ID"]), int(os.environ["GITHUB_RUN_ATTEMPT"]),
            evidence.git("rev-parse", "HEAD")):
        raise ValueError("Compiled origin mismatch")
    if evidence.digest(archive) != receipt["archive"]:
        raise ValueError("Compiled archive mismatch")
    destinations = roots()
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        # Validate the entire inventory before writing, and never extract through
        # a link. Hardlinks/devices/directories are not in the producer format.
        for member in source:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or len(path.parts) < 2
                    or path.parts[0] not in destinations or member.name in seen):
                raise ValueError("Unsafe compiled path")
            seen.add(member.name)
            if not member.isfile():
                raise ValueError("Unsafe compiled file")
        for name in seen:
            if any(str(parent) in seen for parent in PurePosixPath(name).parents):
                raise ValueError("Compiled file used as parent")
        for root in destinations.values():
            if root.is_symlink():
                raise ValueError("Compiled root is a symlink")
            if root.exists():
                shutil.rmtree(root)
            root.mkdir(parents=True)
        # A second streaming pass avoids retaining archive payloads in RAM.
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            path = PurePosixPath(member.name)
            destination = destinations[path.parts[0]].joinpath(*path.parts[1:])
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, destination.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            destination.chmod(member.mode & 0o777)
    actual = {}
    for label, root in destinations.items():
        for directory, _, files in os.walk(root, followlinks=False):
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink() and path.stat().st_mode & 0o111:
                    actual[str(PurePosixPath(label, path.relative_to(root)))] = [
                        evidence.digest(path), stat.S_IMODE(path.stat().st_mode)]
    if not actual or actual != receipt["executables"]:
        raise ValueError("Compiled executable identity mismatch")


def restore(artifact_id, targets):
    repository = os.environ["GITHUB_REPOSITORY"]
    artifact = evidence.api(f"repos/{repository}/actions/artifacts/{artifact_id}")
    if artifact["expired"] or artifact["workflow_run"]["id"] != int(os.environ["GITHUB_RUN_ID"]):
        raise ValueError("Foreign compiled artifact")
    # Exact immutable ID comes from the successful producer's needs output.
    with tempfile.TemporaryDirectory() as directory:
        download = Path(directory) / "artifact.zip"
        with download.open("wb") as output:
            subprocess.run(["gh", "api", f"repos/{repository}/actions/artifacts/{artifact_id}/zip"],
                           stdout=output, check=True, timeout=180)
        if artifact.get("digest") != "sha256:" + evidence.digest(download):
            raise ValueError("GitHub compiled artifact digest mismatch")
        with zipfile.ZipFile(download) as zipped:
            if sorted(zipped.namelist()) != ["compiled.json", "compiled.tar.gz"]:
                raise ValueError("Unexpected compiled artifact inventory")
            if zipped.getinfo("compiled.json").file_size > 1024 * 1024:
                raise ValueError("Oversized compiled receipt")
            receipt = json.loads(zipped.read("compiled.json"))
            archive = Path(directory) / "compiled.tar.gz"
            with zipped.open("compiled.tar.gz") as incoming, archive.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
        unpack(archive, receipt, identity(targets))
    print(f"Verified compiled artifact {artifact_id}; compiled only, gate acceptance not yet established", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("build", "restore"))
    parser.add_argument("targets", help="Complete platform selection, JSON array")
    parser.add_argument("--artifact-id")
    args = parser.parse_args()
    targets = json.loads(args.targets)
    if args.operation == "build":
        prefix = Path(os.environ["RUNNER_TEMP"]) / "rui-compiled-build"
        subprocess.run(["zig", "build", "ci-build", "-Dci-targets=" + ",".join(targets),
                        "--prefix", str(prefix), "--summary", "all"], check=True)
        package(targets, Path(os.environ["RUNNER_TEMP"]) / "rui-compiled", prefix / "bin")
    else:
        try:
            restore(args.artifact_id, targets)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile, tarfile.TarError) as error:
            raise SystemExit(f"Compiled artifact {args.artifact_id} rejected: {error}. "
                             "No gates executed; inspect the producer and artifact identity.") from error


if __name__ == "__main__":
    main()
