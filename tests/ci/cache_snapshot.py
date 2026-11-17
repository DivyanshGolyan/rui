"""Audit superseded Linux CLI outputs in the pinned Zig cache.

Keep complete manifest outputs and referenced output directories across both
cache roots. The compiler owns discovered-hash calculation (zig cache-cat).
Only understood CLI executable directories are candidates; other namespaces,
C objects, libraries, generated inputs and unknown outputs remain untouched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess


HEX = re.compile(r"[a-f0-9]{32}\Z")
OUTPUT = re.compile(r'^\s*\.discovered_hash = "([a-f0-9]{32})",?$', re.M)
INPUT = re.compile(r'^\s*\.input_hash = "([a-f0-9]{32})",?$', re.M)
REFERENCE = re.compile(r"(?:^|/)o/([a-f0-9]{32})(?:/|$)")
PRODUCTS = frozenset(("rui-release-safe-check", "rui-release-small-check",
                      "rui-debug-check", "rui-upgrade-release-fixture", "rui-pr-check"))
ELF = struct.Struct("<16sHHIQQQIHHHHHH")
HEADER = struct.Struct("<QQq16sB")  # std.Build.Cache.Manifest.File, Zig 0.17.1


class SnapshotError(ValueError):
    """An unrecognized cache cannot justify removal."""


def records(raw):
    if not raw or raw[-1:] != b"\0":
        raise SnapshotError("manifest has no final sentinel")
    offset = 0
    paths = []
    while offset < len(raw) - 1:
        if offset + HEADER.size >= len(raw) - 1:
            raise SnapshotError("truncated manifest record")
        *_, flags = HEADER.unpack_from(raw, offset)
        end = raw.find(b"\0", offset + HEADER.size)
        if end <= offset + HEADER.size or end >= len(raw) - 1 or flags >> 2 > 4:
            raise SnapshotError("unknown manifest path or prefix")
        paths.append(os.fsdecode(raw[offset + HEADER.size:end]))
        offset = end + 1
    if offset != len(raw) - 1:
        raise SnapshotError("manifest has trailing data")
    return paths


def manifests(roots):
    # The producer must have exited before audit. Detect ordinary concurrent
    # writes as well: validation and cache-cat must inspect the same bytes.
    files = []
    paths = []
    contents = {}
    listings = {}
    for root in roots:
        for directory in (root, root / "h", root / "o"):
            if any(part.is_symlink() for part in (directory.absolute(), *directory.absolute().parents)):
                raise SnapshotError(f"symlinked cache namespace: {directory}")
    for root in roots:
        directory = root / "h"
        if not directory.is_dir():
            raise SnapshotError(f"missing manifest directory: {directory}")
        listings[directory] = set(directory.iterdir())
        for path in sorted(listings[directory]):
            if path.name == "timestamp":
                continue
            if not HEX.fullmatch(path.name) or not path.is_file() or path.is_symlink():
                raise SnapshotError(f"unknown manifest entry: {path}")
            raw = path.read_bytes()
            paths.extend(records(raw))
            contents[path] = raw
            files.append(path)
    if not files:
        raise SnapshotError("no complete manifests")
    hashes = set()
    owners = {}
    for start in range(0, len(files), 128):
        batch = files[start:start + 128]
        decoded = subprocess.check_output(["zig", "cache-cat", *map(str, batch)], text=True,
                                          encoding="utf-8", errors="surrogateescape")
        outputs, inputs = OUTPUT.findall(decoded), INPUT.findall(decoded)
        if len(outputs) != len(batch) or inputs != [path.name for path in batch]:
            raise SnapshotError("unexpected cache-cat output")
        hashes.update(outputs)
        for path, output in zip(batch, outputs, strict=True):
            owners.setdefault(output, []).append(dict(path=str(path), sha256=hashlib.sha256(contents[path]).hexdigest()))
    for directory, listing in listings.items():
        if set(directory.iterdir()) != listing:
            raise SnapshotError("manifest inventory changed during audit")
    if any(path.read_bytes() != raw for path, raw in contents.items()):
        raise SnapshotError("manifest changed during audit")
    bases = [*roots, Path.cwd(), Path.cwd() / "screen-emulator"]
    compiler = shutil.which("zig")
    if compiler:
        bases.append(Path(compiler).resolve().parent / "lib")
    references = set()
    for path in set(paths):
        # Prefix roots can alias local/global caches and nested screen builds.
        # Union known interpretations rather than guessing a single context;
        # resolve aliases as well as retaining literal cache path references.
        candidates = [Path(path)] if Path(path).is_absolute() else [base / path for base in bases]
        spellings = {path, os.path.normpath(path)}
        for candidate in candidates:
            try:
                spellings.add(str(candidate.resolve()))
            except (OSError, RuntimeError) as error:
                raise SnapshotError(f"cannot resolve manifest input: {path}") from error
        for spelling in spellings:
            references.update(REFERENCE.findall(spelling))
            if spelling == "o" or spelling.endswith("/o"):
                raise SnapshotError("manifest references a whole output namespace")
    return hashes, references, owners, len(files), len(paths)


def obsolete_cli(directory):
    entries = list(directory.iterdir())
    names = {path.name for path in entries}
    products = names & PRODUCTS
    if len(products) != 1:
        return False
    product = products.pop()
    if names - {product, product + "_zcu.o"}:
        return False
    for path in entries:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            return False
    return native_cli(directory / product)


def native_cli(executable):
    if executable.is_symlink() or not executable.is_file():
        return False
    if not executable.stat().st_mode & 0o111:
        return False
    with executable.open("rb") as stream:
        header = stream.read(ELF.size)
    if len(header) != ELF.size:
        return False
    ident, kind, machine, version, _, phoff, _, _, ehsize, phsize, phnum, *_ = ELF.unpack(header)
    # Complete x86_64 executable/PIE headers and program table; unknown or
    # truncated files are outside the understood producer-output class.
    return (ident[:7] == b"\x7fELF\x02\x01\x01" and kind in (2, 3)
            and machine == 62 and version == 1 and ehsize == ELF.size
            and phoff >= ELF.size and phsize == 56 and phnum > 0
            and phoff + phsize * phnum <= executable.stat().st_size)


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def protected_outputs(local, prefixes, manifest_roots):
    current = {}
    for prefix in prefixes:
        for name in PRODUCTS:
            executable = Path(prefix) / name
            if executable.exists():
                if not native_cli(executable):
                    raise SnapshotError(f"unknown current CLI: {executable}")
                current.setdefault(name, set()).add((executable.stat().st_size, file_digest(executable)))
    required = PRODUCTS - {"rui-pr-check"}
    if not required <= current.keys():
        raise SnapshotError("current LLVM producer does not emit all four protected CLIs")
    covered = {name: set() for name in current}
    protected = set()
    for directory in (local / "o").iterdir():
        if directory.is_symlink() or not directory.is_dir() or not HEX.fullmatch(directory.name):
            continue
        for name, expected in current.items():
            executable = directory / name
            if not executable.is_symlink() and executable.is_file():
                size = executable.stat().st_size
                if any(size == item[0] for item in expected):
                    identity = (size, file_digest(executable))
                    if identity in expected:
                        if directory.name not in manifest_roots:
                            raise SnapshotError(f"current CLI is absent from manifest roots: {executable}")
                        protected.add(directory.name)
                        covered[name].add(identity)
    if covered != current:
        raise SnapshotError("current installed CLI has no matching cache provenance")
    return protected


def audit(local, global_cache, *, prefixes=()):
    roots = [Path(local), Path(global_cache)]
    outputs, references, owners, manifest_count, input_count = manifests(roots)
    live = outputs | references
    protected = protected_outputs(roots[0], prefixes, live) if prefixes else set()
    # Revision-specific generated options give old CLI compiles distinct input
    # manifests. Their own old output hashes are not active graph roots. Keep
    # ALL input references, nested/unknown output classes, and the actual
    # installed current executables; only this explicit CLI class may expire.
    cli_live = references | protected if prefixes else live
    report = dict(manifests=manifest_count, inputs=input_count, retained_hashes=len(live),
                  protected_hashes=sorted(protected),
                  removable_bytes=0, removable=[], retained_cli=[], unknown=[])
    for directory in sorted((roots[0] / "o").iterdir()):
        if not HEX.fullmatch(directory.name) or directory.is_symlink() or not directory.is_dir():
            report["unknown"].append(str(directory))
        elif directory.name in cli_live:
            if obsolete_cli(directory):
                report["retained_cli"].append(str(directory))
        elif obsolete_cli(directory):
            local_owners = [owner for owner in owners.get(directory.name, [])
                            if Path(owner["path"]).parent == roots[0] / "h"]
            if prefixes and not local_owners:
                report["unknown"].append(str(directory))
                continue
            size = sum(path.stat().st_size for path in directory.iterdir())
            report["removable"].append(dict(path=str(directory), bytes=size, manifests=local_owners))
            report["removable_bytes"] += size
        else:
            report["unknown"].append(str(directory))
    return report


def invalidate_manifest_owners(report, local):
    """Invalidate proven old CLI hits before their output directories disappear.

    Called only after a successful, quiescent complete producer. An interrupted
    sweep can leave unused outputs, never complete manifests for removed ones.
    """
    local = Path(local).absolute()
    manifests_to_remove = {}
    for item in report["removable"]:
        directory = Path(item["path"]).absolute()
        if (directory.parent != local / "o" or not HEX.fullmatch(directory.name)
                or directory.is_symlink() or not obsolete_cli(directory)):
            raise SnapshotError("candidate directory changed before invalidation")
        if not item["manifests"]:
            raise SnapshotError("candidate has no proven local manifest owner")
        for owner in item["manifests"]:
            path = Path(owner["path"]).absolute()
            if (path.parent != local / "h" or not HEX.fullmatch(path.name)
                    or path.is_symlink() or file_digest(path) != owner["sha256"]):
                raise SnapshotError("owning manifest changed before invalidation")
            manifests_to_remove[path] = owner["sha256"]
    # Validate the whole plan before the first unlink.
    for path in manifests_to_remove:
        path.unlink()
    return len(manifests_to_remove)


def compact(local, global_cache, *, prefixes):
    if not prefixes:
        raise SnapshotError("compaction requires current installed producer outputs")
    report = audit(local, global_cache, prefixes=prefixes)
    report["invalidated_manifests"] = invalidate_manifest_owners(report, local)
    for item in report["removable"]:
        shutil.rmtree(item["path"])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local", type=Path, default=Path(".zig-cache"))
    parser.add_argument("--global-cache", type=Path, default=Path.home() / ".cache/zig")
    parser.add_argument("--protect-prefix", type=Path, action="append", default=[])
    parser.add_argument("--prune", action="store_true")
    args = parser.parse_args()
    try:
        if args.prune:
            report = compact(args.local, args.global_cache, prefixes=args.protect_prefix)
        else:
            report = audit(args.local, args.global_cache, prefixes=args.protect_prefix)
    except (SnapshotError, OSError, subprocess.CalledProcessError) as error:
        report = dict(skipped=str(error), removable=[], removable_bytes=0)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
