"""Same-run compiled-output handoff, never a test-acceptance receipt."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile


class Mismatch(ValueError):
    """The verified producer differs from this worker; rebuild, never execute it."""


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], stderr=subprocess.PIPE, timeout=90))


def roots():
    return {"binaries": Path(".zig-cache/o/ci-compiled").resolve(),
            "packages": Path("zig-pkg").resolve()}


def identity(targets, part):
    # Everything the transferred executables depend on that can differ inside
    # one run. Runner image versions and tool listings are logged, not compared:
    # a rollout that keeps these fields still executes the producer's binaries.
    # build.zig rejects a foreign baseline-CPU manifest before any gate runs.
    return dict(format=4, tree=git("rev-parse", "HEAD^{tree}"), targets=targets, part=part,
                system=platform.system(), machine=platform.machine(),
                compiler=digest(shutil.which("zig")))


def runner():
    return [os.environ.get("ImageOS"), os.environ.get("ImageVersion")]


def build(targets, part="all"):
    prefix = Path(os.environ["RUNNER_TEMP"]) / "rui-compiled-build"
    # A prior failed build must not supply extra or stale installed binaries.
    if prefix.exists():
        shutil.rmtree(prefix)
    subprocess.run(["zig", "build", "ci-build", "-Dci-targets=" + ",".join(targets), "-Dci-part=" + part,
                    "--prefix", str(prefix), "--summary", "all"], check=True)
    return prefix / "bin"


def linked_package_file(root, link):
    # A fetched package may link one of its files to another (WAMR links a
    # LICENSE). Ship the linked file's bytes under the link's name, so the
    # archive still holds regular files only; any other link is refused.
    package_root = (root / link.relative_to(root).parts[0]).resolve()
    target = link.resolve()
    if not target.is_relative_to(package_root) or target.is_symlink() or not target.is_file():
        raise ValueError(f"Unexpected build symlink: {link.relative_to(root)}")
    return target


def package(targets, destination, binaries=None, part="all"):
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "compiled.tar.gz"
    inputs = identity(targets, part)
    executables = {}
    sources = roots()
    if binaries is not None:
        sources["binaries"] = binaries
    if part == "unit":
        # The rest producer carries the package sources, once.
        del sources["packages"]
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
                    if label == "packages" and source.is_symlink():
                        source = linked_package_file(root, source)
                    info = source.lstat()
                    if not stat.S_ISREG(info.st_mode):
                        raise ValueError(f"Unexpected build file: {name}")
                    elif info.st_mode & 0o111:
                        executables[name] = [digest(source), stat.S_IMODE(info.st_mode)]
                    member = output.gettarinfo(source, arcname=name)
                    with source.open('rb') as stream:
                        output.addfile(member, stream)
    receipt = dict(inputs=inputs, runner=runner(),
                   source_sha=git("rev-parse", "HEAD"),
                   run_id=int(os.environ["GITHUB_RUN_ID"]),
                   run_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
                   archive=digest(archive), executables=executables)
    (destination / "compiled.json").write_text(json.dumps(receipt, sort_keys=True))
    print(f"Compiled, not tested, on runner image {runner()}: {archive.stat().st_size} compressed bytes; "
          f"{len(executables)} executable files")


def unpack(archive, receipt, targets):
    if (receipt["run_id"], receipt["run_attempt"], receipt["source_sha"]) != (
            int(os.environ["GITHUB_RUN_ID"]), int(os.environ["GITHUB_RUN_ATTEMPT"]),
            git("rev-parse", "HEAD")):
        raise Mismatch("Compiled origin differs: run, attempt or source SHA")
    inputs = identity(targets, receipt["inputs"].get("part"))
    if receipt["inputs"] != inputs:
        changed = sorted(key for key in receipt["inputs"].keys() | inputs.keys()
                         if receipt["inputs"].get(key) != inputs.get(key))
        raise Mismatch("Compiled identity differs: " + ", ".join(changed))
    if digest(archive) != receipt["archive"]:
        raise ValueError("Compiled archive digest mismatch")
    destinations = roots()
    present = {str(PurePosixPath(label, path.relative_to(root)))
               for label, root in destinations.items() for path in root.rglob("*") if path.is_file()}
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        # Validate the entire inventory before writing, and never extract through
        # a link. Hardlinks/devices/directories are not in the producer format.
        for member in source:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or len(path.parts) < 2
                    or path.parts[0] not in destinations or member.name in seen or member.name in present):
                raise ValueError("Unsafe compiled path")
            seen.add(member.name)
            if not member.isfile():
                raise ValueError("Unsafe compiled file")
        names = seen | present
        for name in names:
            if any(str(parent) in names for parent in PurePosixPath(name).parents):
                raise ValueError("Compiled file used as parent")
        # A second streaming pass avoids retaining archive payloads in RAM.
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            path = PurePosixPath(member.name)
            destination = destinations[path.parts[0]].joinpath(*path.parts[1:])
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, destination.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            destination.chmod(member.mode & 0o777)


def clear():
    for root in roots().values():
        if root.is_symlink():
            raise ValueError("Compiled root is a symlink")
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True)


def verify(receipts):
    parts = sorted(receipt["inputs"].get("part") for receipt in receipts)
    if parts not in (["all"], ["rest", "unit"]):
        raise ValueError(f"Compiled parts do not cover the selection: {parts}")
    expected = {}
    for receipt in receipts:
        if expected.keys() & receipt["executables"].keys():
            raise ValueError("Compiled parts overlap")
        expected.update(receipt["executables"])
    actual = {}
    for label, root in roots().items():
        for directory, _, files in os.walk(root, followlinks=False):
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink() and path.stat().st_mode & 0o111:
                    actual[str(PurePosixPath(label, path.relative_to(root)))] = [
                        digest(path), stat.S_IMODE(path.stat().st_mode)]
    if not actual or actual != expected:
        raise ValueError("Compiled executable identity mismatch")


def fetch(artifact_id, targets):
    repository = os.environ["GITHUB_REPOSITORY"]
    artifact = api(f"repos/{repository}/actions/artifacts/{artifact_id}")
    if artifact["expired"] or artifact["workflow_run"]["id"] != int(os.environ["GITHUB_RUN_ID"]):
        raise ValueError("Foreign or expired compiled artifact")
    # Exact immutable ID comes from the successful producer's needs output.
    with tempfile.TemporaryDirectory() as directory:
        download = Path(directory) / "artifact.zip"
        with download.open("wb") as output:
            subprocess.run(["gh", "api", f"repos/{repository}/actions/artifacts/{artifact_id}/zip"],
                           stdout=output, check=True, timeout=180)
        if artifact.get("digest") != "sha256:" + digest(download):
            raise ValueError("GitHub compiled artifact digest mismatch")
        with zipfile.ZipFile(download) as zipped:
            if sorted(zipped.namelist()) != ["compiled.json", "compiled.tar.gz"]:
                raise ValueError("Unexpected compiled artifact inventory")
            if zipped.getinfo("compiled.json").file_size > 1024 * 1024:
                raise ValueError("Oversized compiled receipt")
            receipt = json.loads(zipped.read("compiled.json"))
            print(f"Runner images: producer {receipt.get('runner')}, this worker {runner()}", flush=True)
            archive = Path(directory) / "compiled.tar.gz"
            with zipped.open("compiled.tar.gz") as incoming, archive.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
        unpack(archive, receipt, targets)
    return receipt


def rebuild(targets):
    # Downloaded bytes are discarded whole, including package sources; compile
    # this worker's own checkout from freshly fetched, hash-pinned packages.
    for root in roots().values():
        if root.is_symlink():
            root.unlink()
        elif root.exists():
            shutil.rmtree(root)
    subprocess.run(["bash", "src/fetch_dependencies.sh"], check=True)
    shutil.copytree(build(targets), roots()["binaries"])


def restore(artifact_ids, targets):
    named = ", ".join(artifact_ids)
    try:
        clear()
        verify([fetch(artifact_id, targets) for artifact_id in artifact_ids])
        message = f"Using verified producer artifact {named}; compiled only, gate acceptance not yet established"
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError,
            zipfile.BadZipFile, tarfile.TarError) as error:
        kind = "differs from this worker" if isinstance(error, Mismatch) else "was rejected"
        print(f"Producer artifact {named} {kind}: {error}. Its bytes are not executed; "
              "compiling this checkout locally before gates.", flush=True)
        rebuild(targets)
        message = f"Compiled locally because producer artifact {named} {kind}: {error}"
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            print(message, file=summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("build", "restore"))
    parser.add_argument("targets", help="Complete platform selection, JSON array")
    parser.add_argument("--part", choices=("all", "unit", "rest"), default="all")
    parser.add_argument("--artifact-id", action="append", default=[],
                        help="A producer artifact; an empty value (an unsplit build) is ignored")
    args = parser.parse_args()
    targets = json.loads(args.targets)
    try:
        if args.operation == "build":
            package(targets, Path(os.environ["RUNNER_TEMP"]) / "rui-compiled", build(targets, args.part), args.part)
        else:
            restore([artifact_id for artifact_id in args.artifact_id if artifact_id], targets)
    except subprocess.CalledProcessError as error:
        # A failed local fetch or compile stops before gates with its own status.
        print(f"{' '.join(map(str, error.cmd))} failed with exit {error.returncode}; no gates executed.",
              file=sys.stderr)
        raise SystemExit(error.returncode) from error


if __name__ == "__main__":
    main()
