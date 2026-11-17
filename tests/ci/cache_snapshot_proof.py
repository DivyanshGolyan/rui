"""Paired diagnostic only: run after the normal producer has exited.

Example (use the producer's full target selection):
  python3 tests/ci/cache_snapshot_proof.py --targets '["check-full"]' \
      --protect-prefix "$RUNNER_TEMP/rui-compiled-build/bin" \
      --global-cache "$ZIG_GLOBAL_CACHE_DIR" --zig-lib "$RUNNER_TEMP/rui-zig/lib" --jobs 1

Owns no build recipe: build_artifact.compile_command owns every build invocation.
No test acceptance is inferred. Never run concurrently with another cache user.
"""
import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import time
import traceback

import build_artifact


class ProofError(ValueError):
    """The experiment cannot establish parity."""


def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def copy(path, destination):
    if path.is_symlink():
        raise ProofError(f"symlink in checkpoint: {path}")
    if path.is_dir():
        shutil.copytree(path, destination, copy_function=shutil.copy2, symlinks=True)
    elif path.is_file():
        shutil.copy2(path, destination)
    else:
        raise ProofError(f"special checkpoint file: {path}")


def output_link(path, directory):
    """Validate a relative cached-file alias without copying through it."""
    target = os.readlink(path)
    lexical = Path(os.path.normpath(path.parent / target))
    if Path(target).is_absolute() or not lexical.is_relative_to(directory):
        raise ProofError(f"output symlink leaves its cached file tree: {path}")
    try:
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(directory) or not resolved.is_file():
            raise ProofError(f"output symlink leaves its cached file tree: {path}")
    except (OSError, RuntimeError) as error:
        raise ProofError(f"invalid output symlink: {path}: {error}") from error
    return target


def metadata(directory):
    """Read metadata, never the multi-GB output bytes; atime is immaterial."""
    found = {}
    for parent, dirs, files in os.walk(directory, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(parent) / name
            info = path.lstat()
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                raise ProofError(f"unsupported output entry: {path}")
            # Directory ctime/mtime changes on quarantine rename; file identity must not.
            value = (info.st_dev, info.st_ino, info.st_mode)
            if stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                value += (info.st_size, info.st_mtime_ns, info.st_ctime_ns)
            if stat.S_ISLNK(info.st_mode):
                value += (output_link(path, directory),)
            found[str(path.relative_to(directory))] = value
    return found


def tree_bytes(path, directory=None):
    directory = path if directory is None else directory
    if path.is_symlink():
        output_link(path, directory)
        return path.lstat().st_size
    if path.is_file():
        return path.stat().st_size
    if not path.is_dir():
        raise ProofError(f"special checkpoint entry: {path}")
    return sum(tree_bytes(child, directory) for child in path.iterdir())


def contains_elf_output(directory, inventory):
    """Conservatively retain ELF ET_EXEC/ET_DYN trees without copying their GBs."""
    for relative, info in inventory.items():
        if stat.S_ISREG(info[2]):
            with (directory / relative).open("rb") as stream:
                header = stream.read(20)
            if header[:4] == b"\x7fELF" and len(header) == 20:
                if header[5] not in (1, 2):
                    raise ProofError(f"unknown ELF byte order: {directory / relative}")
                order = "little" if header[5] == 1 else "big"
                if int.from_bytes(header[16:18], order) in (2, 3):
                    return True
    return False


class Checkpoint:
    """Copy non-o, all global o and local o trees without ELF executables.

    Generated ve.zig and hwy headers can mutate their old output directories.
    Copying the non-executable trees covers these and newly generated options;
    executable trees retain their original inodes and must stay unchanged.
    """

    def __init__(self, roots, destination, *, budget_bytes=4 * 1024**3, reserve_bytes=8 * 1024**3):
        self.roots = [Path(root).absolute() for root in roots]
        self.destination = Path(destination).absolute()
        if len(set(self.roots)) != len(self.roots):
            raise ProofError("local and global caches must differ")
        for root in self.roots:
            if root.is_symlink() or root.resolve() != root or (root / "o").is_symlink() or not (root / "o").is_dir():
                raise ProofError(f"cache must have a real output directory: {root}")
            if self.destination.is_relative_to(root) or root.is_relative_to(self.destination):
                raise ProofError("checkpoint and caches must be disjoint")
        if any(a.is_relative_to(b) for a in self.roots for b in self.roots if a != b):
            raise ProofError("cache roots must be disjoint")
        if self.destination.exists():
            raise ProofError(f"checkpoint already exists: {self.destination}")
        self.destination.parent.mkdir(parents=True, exist_ok=True)
        if self.destination.parent.stat().st_dev != (self.roots[0] / "o").stat().st_dev:
            raise ProofError("RUNNER_TEMP quarantine must be on the local cache filesystem")
        self.quarantine = self.destination / "quarantine"
        self.initial = []
        self.mutable = []
        self.frozen = []
        self.moved = {}
        planned = []
        for index, root in enumerate(self.roots):
            saved = self.destination / str(index)
            planned.extend((path, saved / "non-o" / path.name)
                           for path in root.iterdir() if path.name != "o")
            names = {path.name for path in (root / "o").iterdir()}
            mutable, frozen = set(), {}
            for name in names:
                directory = root / "o" / name
                if not directory.is_dir() or directory.is_symlink():
                    raise ProofError(f"unexpected output namespace: {directory}")
                inventory = metadata(directory)
                if index == 1 or not contains_elf_output(directory, inventory):
                    mutable.add(name)
                    planned.append((directory, saved / "mutable" / name))
                else:
                    frozen[name] = inventory
            self.initial.append(names)
            self.mutable.append(mutable)
            self.frozen.append(frozen)
        self.copied_bytes = sum(tree_bytes(path) for path, _ in planned)
        if self.copied_bytes > budget_bytes:
            raise ProofError(f"checkpoint copy budget exceeded: {self.copied_bytes} > {budget_bytes}")
        available_bytes = shutil.disk_usage(self.destination.parent).free
        if available_bytes < self.copied_bytes + reserve_bytes:
            raise ProofError(f"checkpoint would exhaust the configured disk reserve: "
                             f"{self.copied_bytes} copy + {reserve_bytes} reserve > {available_bytes} available")
        self.quarantine.mkdir(parents=True, exist_ok=False)
        for index in range(len(self.roots)):
            (self.destination / str(index) / "non-o").mkdir(parents=True)
            (self.destination / str(index) / "mutable").mkdir()
        for path, target in planned:
            copy(path, target)
        self.validate()
        (self.destination / "inventory.json").write_text(json.dumps({
            "roots": list(map(str, self.roots)), "initial_o": [sorted(n) for n in self.initial],
            "mutable_o": [sorted(n) for n in self.mutable], "metadata": self.frozen,
            "copied_bytes": self.copied_bytes, "budget_bytes": budget_bytes,
            "reserve_bytes": reserve_bytes, "available_bytes_before_copy": available_bytes,
            "strategy": "all global o; local o without ELF ET_EXEC/ET_DYN; all non-o",
        }, sort_keys=True))

    def check_paths(self):
        for root in self.roots:
            if root.resolve() != root or (root / "o").is_symlink() or not (root / "o").is_dir():
                raise ProofError(f"cache namespace changed: {root}")

    def validate(self):
        self.check_paths()
        changed = []
        for index, root in enumerate(self.roots):
            for name, expected in self.frozen[index].items():
                path = self.moved.get(name, root / "o" / name) if index == 0 else root / "o" / name
                if path.is_symlink() or not path.is_dir() or metadata(path) != expected:
                    changed.append(str(root / "o" / name))
        if changed:
            raise ProofError("existing output changed; fairness unproved (bytes were not backed up): " + ", ".join(changed))

    def quarantine_candidates(self, report):
        if report.get("skipped") or "removable" not in report:
            raise ProofError("audit did not produce an eligible directory list")
        candidates = []
        for item in report["removable"]:
            path = Path(item["path"]).absolute()
            if (path.parent != self.roots[0] / "o" or path.is_symlink()
                    or path.name not in self.frozen[0] or path.name in self.moved
                    or path in candidates):
                raise ProofError(f"audit candidate is outside eligible local outputs: {path}")
            candidates.append(path)
        self.validate()
        for path in candidates:
            destination = self.quarantine / path.name
            path.rename(destination)
            self.moved[path.name] = destination

    def restore(self):
        # Each root, namespace and saved directory gets its own cleanup attempt.
        failures = []

        def attempt(label, action):
            try:
                action()
                return True
            except Exception as error:
                failures.append(f"{label}: {type(error).__name__}: {error}")
                return False

        def check(root, outputs=False):
            if root.resolve() != root or not root.is_dir():
                raise ProofError(f"cache namespace changed: {root}")
            if outputs and ((root / "o").is_symlink() or not (root / "o").is_dir()):
                raise ProofError(f"cache namespace changed: {root / 'o'}")

        def restore_copy(saved, target):
            if target.is_symlink():
                raise ProofError(f"refusing to copy through symlink: {target}")
            copy(saved, target)

        safe = [attempt(str(root), lambda root=root: check(root)) for root in self.roots]
        outputs = [safe[index] and attempt(str(root / "o"), lambda root=root: check(root, True))
                   for index, root in enumerate(self.roots)]
        for index, root in enumerate(self.roots):
            if not outputs[index]:
                continue
            for name, expected in self.frozen[index].items():
                path = self.moved.get(name, root / "o" / name) if index == 0 else root / "o" / name
                def validate(path=path, expected=expected):
                    if path.is_symlink() or not path.is_dir() or metadata(path) != expected:
                        raise ProofError(f"existing output changed; fairness unproved (bytes were not backed up): {path}")
                attempt(str(path), validate)
        if outputs[0]:
            for name, saved in list(self.moved.items()):
                target = self.roots[0] / "o" / name
                if target.exists() or target.is_symlink():
                    attempt(str(target), lambda target=target: remove(target))
                if attempt(str(saved), lambda saved=saved, target=target: saved.rename(target)):
                    del self.moved[name]
        for index, root in enumerate(self.roots):
            if outputs[index]:
                entries = []
                attempt(str(root / "o"), lambda: entries.extend((root / "o").iterdir()))
                for path in entries:
                    if path.name not in self.initial[index]:
                        attempt(str(path), lambda path=path: remove(path))
                for name in sorted(self.mutable[index]):
                    target = root / "o" / name
                    if target.exists() or target.is_symlink():
                        attempt(str(target), lambda target=target: remove(target))
                    saved = self.destination / str(index) / "mutable" / name
                    attempt(str(saved), lambda saved=saved, target=target: restore_copy(saved, target))
            if safe[index]:
                saved_entries = []
                saved_root = self.destination / str(index) / "non-o"
                attempt(str(saved_root), lambda: saved_entries.extend(saved_root.iterdir()))
                saved_names = {path.name for path in saved_entries}
                entries = []
                attempt(str(root), lambda: entries.extend(root.iterdir()))
                for path in entries:
                    # A substituted o can leave its original tree at another
                    # root entry. Preserve unknown entries in this failure
                    # state, while still restoring independent saved h/b/etc.
                    if path.name != "o" and (outputs[index] or path.name in saved_names):
                        attempt(str(path), lambda path=path: remove(path))
                for path in saved_entries:
                    attempt(str(path), lambda path=path: restore_copy(path, root / path.name))
        if failures:
            raise ProofError("checkpoint cleanup: " + "; ".join(failures))


class Source:
    COMMENT = b"\n// rui cache snapshot proof: fixed diagnostic source edit\n"

    def __init__(self, path):
        self.path = Path(path)
        if self.path.is_symlink() or not self.path.is_file():
            raise ProofError("source must be a regular file")
        self.info = self.path.stat()
        self.original = self.path.read_bytes()
        self.edit_time = max(time.time_ns(), self.info.st_mtime_ns + 1)

    def apply(self, edited):
        self.path.write_bytes(self.original + self.COMMENT if edited else self.original)
        os.chmod(self.path, stat.S_IMODE(self.info.st_mode))
        os.utime(self.path, ns=(self.info.st_atime_ns, self.edit_time if edited else self.info.st_mtime_ns))

    @contextmanager
    def preserved(self):
        try:
            yield self
        finally:
            self.apply(False)


ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[()][0-2A-Z])")
TREE = re.compile(r"^[\s|+`\\\-│├└─]*")
STATUS = re.compile(r"^(.*?) (cached|success)(?:\s+(?:\d+(?:\.\d+)?(?:ns|us|µs|ms|s|m)|MaxRSS:\S+))*\s*$")
SUMMARY = re.compile(r"^Build Summary: (\d+)/(\d+) steps succeeded(?:[^\n]*)$", re.M)
COMPILE = re.compile(r"^(?:compile |zig (?:build-exe|build-lib|build-obj|test) )")
DIGEST = re.compile(r"(?<=/)[0-9a-f]{32}(?=/)")


def parse_output(text):
    """Compare named compile/run nodes and unordered compiler/linker argv traces."""
    text = ANSI.sub("", text)
    summaries = SUMMARY.findall(text)
    nodes = defaultdict(Counter)
    traces = Counter()
    problems = []
    in_summary = False
    for line in text.splitlines():
        if line.startswith("Build Summary:"):
            in_summary = True
            continue
        body = TREE.sub("", line)
        if in_summary and (COMPILE.match(body) or body.startswith("run ")):
            match = STATUS.fullmatch(body)
            if match:
                name, status = match.groups()
                nodes[DIGEST.sub("<digest>", name)][status] += 1
                # screen's child suppresses its own summary; a miss has no inner-node proof.
                if body.startswith("run ") and status == "success" and re.search(r"(?:^|[/ ])zig(?:\.exe)?(?:\s|$)", name):
                    problems.append("nested build ran without per-node cache evidence: " + name)
            elif not re.search(r"\((?:reused|\+\d+ more reused dependencies)\)$", body):
                problems.append("unparsed build node: " + body)
            continue
        try:
            argv = shlex.split(line.strip())
        except ValueError:
            if re.search(r"\b(?:clang|ld\.lld|zig (?:clang|cc|build-exe|build-lib|build-obj))\b", line):
                problems.append("unparsed compiler trace: " + line)
            continue
        if not argv:
            continue
        executable = Path(argv[0]).name
        compiler = executable in {"cc", "c++", "gcc", "g++", "clang", "clang++", "ld", "ld.lld", "lld", "lld-link", "ar", "llvm-ar"}
        compiler |= executable in {"zig", "zig.exe"} and len(argv) > 1 and argv[1] in {
            "cc", "c++", "clang", "build-exe", "build-lib", "build-obj", "test", "ar", "ld.lld"}
        if compiler:
            # Keep source, flags and output identities; only transient cache hashes vary.
            key = json.dumps([DIGEST.sub("<digest>", arg) for arg in argv])
            traces[key] += 1
    if not summaries or any(a != b for a, b in summaries):
        problems.append("missing or unsuccessful full build summary")
    if not any(COMPILE.match(name) for name in nodes):
        problems.append("no named compilation nodes parsed")
    return {"nodes": {name: dict(counts) for name, counts in sorted(nodes.items())},
            "traces": dict(sorted(traces.items())), "problems": problems,
            "summaries": summaries}


def compare(control, candidate):
    differences = []
    for arm, parsed in (("control", control), ("candidate", candidate)):
        differences.extend(f"{arm}: {problem}" for problem in parsed["problems"])
    for field in ("nodes", "traces"):
        for name in sorted(control[field].keys() | candidate[field].keys()):
            before, after = control[field].get(name), candidate[field].get(name)
            if before != after:
                differences.append(dict(field=field, node=name, control=before, candidate=after))
    return dict(parity=not differences, differences=differences)


def command(targets, part, profile, prefix, jobs):
    return [*build_artifact.compile_command(targets, part, jobs=jobs, pr_mode=profile == "pr"),
            "--prefix", str(prefix), "--summary", "all", "--verbose-cc", "--verbose-link"]


def stage(argv, destination, *, workspace, env):
    destination.mkdir(parents=True, exist_ok=False)
    record = dict(command=list(map(str, argv)), started_ns=time.time_ns())
    started = time.monotonic()
    print(json.dumps(dict(stage=str(destination), event="start", command=record["command"])), flush=True)
    try:
        with (destination / "output.log").open("wb") as output:
            result = subprocess.run(argv, cwd=workspace, env=env, stdout=output, stderr=subprocess.STDOUT)
        record["returncode"] = result.returncode
    except BaseException as error:
        record["error"] = str(error)
        raise
    finally:
        record["elapsed_seconds"] = time.monotonic() - started
        (destination / "status.json").write_text(json.dumps(record, indent=2))
        print(json.dumps(dict(stage=str(destination), event="finish", **record)), flush=True)
    if result.returncode:
        raise ProofError(f"stage failed ({result.returncode}): {destination}")
    return (destination / "output.log").read_text(errors="replace")


def archive_command(roots, listing):
    paths = [Path(root).absolute() for root in roots]
    if any("\n" in str(path) or "\r" in str(path) for path in paths):
        raise ProofError("archive paths cannot contain newlines")
    listing.write_text("".join(str(path) + "\n" for path in paths))
    return ["tar", "--posix", "-c", "-f", "-", "--exclude", "cache.tzst", "-P", "--use-compress-program", "zstdmt",
            "--files-from", str(listing)]


def measure_archive(roots, destination, *, workspace, env):
    """Count streamed compressed bytes; retain only stderr and timing metadata."""
    destination.mkdir(parents=True, exist_ok=False)
    argv = archive_command(roots, destination / "files.txt")
    record = dict(command=argv, roots=list(map(str, roots)), started_ns=time.time_ns(),
                  compressed_bytes=0)
    started = time.monotonic()
    process = None
    try:
        with (destination / "stderr.log").open("wb") as errors:
            process = subprocess.Popen(argv, cwd=workspace, env=env, stdout=subprocess.PIPE, stderr=errors)
            try:
                with process.stdout:
                    while chunk := process.stdout.read(1024 * 1024):
                        record["compressed_bytes"] += len(chunk)
                record["returncode"] = process.wait()
            except BaseException:
                process.kill()
                process.wait()
                raise
        if record["returncode"]:
            raise ProofError(f"archive measurement failed ({record['returncode']}): {destination}")
        return record
    except BaseException as error:
        record["error"] = str(error)
        raise
    finally:
        record["elapsed_seconds"] = time.monotonic() - started
        (destination / "status.json").write_text(json.dumps(record, indent=2))


def run(args):
    import cache_snapshot  # The parent's audit helper, deliberately not duplicated here.

    workspace = Path.cwd().resolve()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    output = runner_temp / "rui-cache-profile" / "proof"
    output.mkdir(parents=True, exist_ok=False)
    local, global_cache = args.local.absolute(), args.global_cache.absolute()
    restat = runner_temp / "zig-cache-restat"
    if not restat.is_file():
        raise ProofError(f"existing restat helper required: {restat}")
    restat_command = [str(restat), str(local / "h"), str(global_cache / "h"), "--",
                      str(workspace), str(args.zig_lib.resolve()), str(local), str(global_cache)]
    env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(local), ZIG_GLOBAL_CACHE_DIR=str(global_cache),
               NO_COLOR="1", TERM="dumb")
    result = dict(diagnostic_only=True, parity=False, pairs=[], targets=args.targets, part=args.part,
                  profiles=args.profiles, checkpoint_profile="main-llvm", roots=[str(local), str(global_cache)], errors=[])
    checkpoint = None
    source = Source(workspace / "src" / "cli.zig")
    prefix = output / "prefix"
    (output / "source.original").write_bytes(source.original)
    result["source"] = dict(path=str(source.path), original_mtime_ns=source.info.st_mtime_ns,
                            edited_mtime_ns=source.edit_time,
                            original_sha256=hashlib.sha256(source.original).hexdigest(),
                            edited_sha256=hashlib.sha256(source.original + source.COMMENT).hexdigest())
    try:
        with source.preserved():
            checkpoint = Checkpoint([local, global_cache], output / "checkpoint",
                                    budget_bytes=args.checkpoint_budget_gb * 1024**3,
                                    reserve_bytes=args.disk_reserve_gb * 1024**3)
            audit = cache_snapshot.audit(local, global_cache, prefixes=args.protect_prefix)
            (output / "audit.json").write_text(json.dumps(audit, indent=2))
            if not audit.get("removable") or audit.get("skipped"):
                raise ProofError("audit found no eligible outputs; candidate experiment unavailable")
            if args.measure_archives:
                roots = [global_cache, local, workspace / "zig-pkg", workspace / "screen-emulator" / "zig-pkg"]
                result["archives"] = {}
                try:
                    checkpoint.restore()
                    result["archives"]["before"] = measure_archive(
                        roots, output / "archives" / "before", workspace=workspace, env=env)
                    cache_snapshot.invalidate_manifest_owners(audit, local)
                    checkpoint.quarantine_candidates(audit)
                    result["archives"]["candidate"] = measure_archive(
                        roots, output / "archives" / "candidate", workspace=workspace, env=env)
                    checkpoint.validate()
                finally:
                    checkpoint.restore()
            for profile in args.profiles:
                for edited in (False, True):
                    scenario = "edit" if edited else "unchanged"
                    # Apply once per pair: the two arms see identical source bytes and mtime.
                    source.apply(edited)
                    pair = dict(profile=profile, scenario=scenario, arms={})
                    result["pairs"].append(pair)
                    for arm in ("control", "candidate"):
                        checkpoint.restore()
                        directory = output / profile / scenario / arm
                        if arm == "candidate":
                            cache_snapshot.invalidate_manifest_owners(audit, local)
                            checkpoint.quarantine_candidates(audit)
                        stage(restat_command, directory / "restat", workspace=workspace, env=env)
                        if prefix.exists():
                            shutil.rmtree(prefix)
                        argv = command(args.targets, args.part, profile, prefix, args.jobs)
                        text = stage(argv, directory / "build", workspace=workspace, env=env)
                        checkpoint.validate()
                        parsed = parse_output(text)
                        (directory / "parsed.json").write_text(json.dumps(parsed, indent=2))
                        pair["arms"][arm] = parsed
                    pair.update(compare(pair["arms"]["control"], pair["arms"]["candidate"]))
            result["parity"] = all(pair["parity"] for pair in result["pairs"])
    except BaseException as error:
        result["errors"].append("".join(traceback.format_exception(error)))
    finally:
        # Attempt every cleanup, retaining both primary and cleanup failures.
        for cleanup in (lambda: checkpoint.restore() if checkpoint is not None else None,
                        lambda: stage(restat_command, output / "final-restat", workspace=workspace, env=env)
                        if checkpoint is not None else None):
            try:
                cleanup()
            except BaseException as error:
                result["errors"].append(f"cleanup {type(error).__name__}: {error}")
        result["parity"] &= not result["errors"]
        (output / "summary.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(dict(summary=str(output / "summary.json"), parity=result["parity"],
                          errors=result["errors"],
                          pairs=[{key: pair[key] for key in ("profile", "scenario", "parity", "differences")
                                  if key in pair} for pair in result["pairs"]]), indent=2))
    return 0 if result["parity"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", type=json.loads, required=True, help="producer's full JSON target list")
    parser.add_argument("--protect-prefix", type=Path, action="append", required=True,
                        help="existing LLVM producer bin directory; repeat for other current outputs")
    parser.add_argument("--part", choices=("all", "unit", "rest"), default="rest")
    parser.add_argument("--profiles", nargs="+", choices=("llvm", "pr"), default=["llvm", "pr"])
    parser.add_argument("--checkpoint-budget-gb", type=int, default=4)
    parser.add_argument("--disk-reserve-gb", type=int, default=8)
    parser.add_argument("--measure-archives", action="store_true",
                        help="stream one main-state before/after tar+zstd measurement")
    parser.add_argument("--jobs", type=int, help="use 1 locally; hosted Linux owner defaults to 8")
    parser.add_argument("--local", type=Path, default=Path(".zig-cache"))
    parser.add_argument("--global-cache", type=Path, default=Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR", Path.home() / ".cache/zig")))
    parser.add_argument("--zig-lib", type=Path, required=True)
    args = parser.parse_args()
    if (not isinstance(args.targets, list) or not args.targets
            or any(not isinstance(target, str) or not target or target.startswith("-") for target in args.targets)):
        parser.error("--targets must be the nonempty producer JSON target list")
    if args.checkpoint_budget_gb < 1 or args.disk_reserve_gb < 0:
        parser.error("checkpoint budget must be positive and disk reserve nonnegative")
    if args.jobs is not None and args.jobs < 1:
        parser.error("--jobs must be positive")
    if len(set(args.profiles)) != len(args.profiles):
        parser.error("--profiles must be unique")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
