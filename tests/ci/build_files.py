#!/usr/bin/env python3
"""The build's Zig files: build.zig and the modules it imports from build/.

Checks that read the build read every file here, so moving code between
build modules cannot hide a target or a call from them.
"""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
STEP = re.compile(r'(?:b\.step\(\s*|\.step\s*=\s*)"([a-z0-9-]+)"')


def files(root=ROOT):
    return [root / "build.zig", *sorted((root / "build").glob("*.zig"))]


def source(root=ROOT):
    """Every build file's text, for checks that look for a call anywhere in the build."""
    return "\n".join(path.read_text() for path in files(root))


def steps(root=ROOT):
    """Each build target and the build file that defines it."""
    defined = {}
    for path in files(root):
        for name in STEP.findall(path.read_text()):
            defined[name] = path.relative_to(root).as_posix()
    for entry in unit_roots(root):
        defined.setdefault(entry["target"], "build/unit.zig")
    return defined


def unit_roots(root=ROOT):
    """Read the literal test-root registry used by the Zig build constructors.

    Names are compile names; ci.zig appends the source stem for installed test
    binaries. Owners include the execution partition of check-full, never its
    callers partition. Unknown row syntax is an error, not partial coverage.
    """
    path = root / "build/unit.zig"
    text = path.read_text()
    match = re.search(r"pub const roots = \[_\]UnitRoot\{(.*?)\n\};", text, re.S)
    if match is None:
        raise ValueError(f"{path}: missing unit-root registry")
    partition_path = root / "src/unit_test_partition.zig"
    partition_source = partition_path.read_text()
    owner = re.search(r'pub fn owner\(name: \[\]const u8\) Root \{\s*'
                      r'return if \(std\.mem\.startsWith\(u8, name, ("(?:[^"\\]|\\.)*")\)\) '
                      r'\.([a-z_]+) else \.([a-z_]+);\s*\}', partition_source)
    if owner is None or owner[2] == owner[3]:
        raise ValueError(f"{partition_path}: unsupported unit partition owner")
    prefix = json.loads(owner[1])
    rows = []
    identities = set()
    for line in match[1].splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        row = re.fullmatch(r'\.\{ \.id = \.([a-z0-9_]+), \.name = ("(?:[^"\\]|\\.)*"), '
                           r'\.source = ("(?:[^"\\]|\\.)*"), \.target = ("[a-z0-9-]+"), '
                           r'\.owners = &\.\{\s*([^{}]+?)\s*\}'
                           r'(?:, \.partition = ("[a-z]+"))?'
                           r'(?:, \.filter = ("(?:[^"\\]|\\.)*"))?'
                           r'(?:, \.filtered_only = (true|false))? \},', line)
        if row is None:
            raise ValueError(f"{path}: unsupported unit-root row: {line}")
        identifier, name, source, target, owners, partition, test_filter, filtered_only = row.groups()
        entry = dict(name=json.loads(name), source=json.loads(source), target=json.loads(target),
                     owners=json.loads("[" + owners + "]"))
        if identifier in identities:
            raise ValueError(f"{path}: duplicate unit-root id {identifier}")
        identities.add(identifier)
        if partition:
            entry["partition"] = json.loads(partition)
            if entry["partition"] == owner[2]:
                entry["prefix"] = prefix
            elif entry["partition"] == owner[3]:
                entry["exclude_prefix"] = prefix
            else:
                raise ValueError(f"{path}: partition has no runner owner: {entry['partition']}")
        if test_filter:
            entry["filter"] = json.loads(test_filter)
        if filtered_only:
            entry["filtered_only"] = json.loads(filtered_only)
        rows.append(entry)
    if not rows:
        raise ValueError(f"{path}: empty unit-root registry")
    return rows
