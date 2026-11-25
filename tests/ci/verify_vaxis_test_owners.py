#!/usr/bin/env python3
"""Verify the pinned Vaxis invariant owners against the dependency source."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys

TEST = re.compile(r'^\s*test\s*[\( ]\s*"([^"\n]+)"', re.MULTILINE)
REVISION = re.compile(r'git\+https://github\.com/DivyanshGolyan/libvaxis#([0-9a-f]{40})')


def load(manifest, build_manifest):
    data = json.loads(Path(manifest).read_text())
    revision = REVISION.findall(Path(build_manifest).read_text())
    if revision != [data["revision"]]:
        raise ValueError("Vaxis invariant owners do not match the pinned revision")
    owners = []
    for name, source in data["sources"].items():
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
            raise ValueError(f"Invalid Vaxis invariant source: {name}")
        owners.extend((name, test) for test in source["tests"])
    if len(owners) != len({test for _, test in owners}):
        raise ValueError("Duplicate Vaxis invariant owner")
    return data, owners


def verify(data, sources):
    root = Path(sources)
    expected = {test: name for name, source in data["sources"].items() for test in source["tests"]}
    found = {test: [] for test in expected}
    for path in root.rglob("*.zig"):
        for test in TEST.findall(path.read_text()):
            if test in found:
                found[test].append(path.relative_to(root).as_posix())
    for test, owner in expected.items():
        if found[test] != [owner]:
            raise ValueError(f"Vaxis invariant test is not unique: {test}")
    for name, source in data["sources"].items():
        body = (root / name).read_bytes()
        if hashlib.sha256(body).hexdigest() != source["sha256"]:
            raise ValueError(f"Vaxis invariant source changed: {name}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: verify_vaxis_test_owners.py MANIFEST BUILD_ZON VAXIS_SRC")
    data, _ = load(sys.argv[1], sys.argv[2])
    verify(data, sys.argv[3])
    print("Pinned Vaxis invariant owners match dependency source")
