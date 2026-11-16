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
    for entry in unit_root_rows(root):
        defined.setdefault(entry["target"], "build/unit.zig")
    return defined


def _registry_rows(text, name, kind, path):
    match = re.search(r"pub const " + name + r" = \[_\]" + kind + r"\{(.*?)\n\};", text, re.S)
    if match is None:
        raise ValueError(f"{path}: missing {name} registry")
    return [line.strip() for line in match[1].splitlines()
            if line.strip() and not line.lstrip().startswith("//")]


def _registry_ids(text, path):
    if not re.fullmatch(r"\s*\.[a-z0-9_]+(?:\s*,\s*\.[a-z0-9_]+)*\s*", text):
        raise ValueError(f"{path}: unsupported registry item list: {text}")
    result = re.findall(r"\.([a-z0-9_]+)", text)
    if len(result) != len(set(result)):
        raise ValueError(f"{path}: repeated registry item: {text}")
    return result


def unit_root_rows(root=ROOT):
    """Build test identities with membership derived from operational composition.

    Only build/unit.zig is needed for target/source discovery. The same groups
    drive native compilation/serial execution and the build's shell arguments;
    compositions attach those groups and ordinary roots to actual gate parts.
    """
    path = root / "build/unit.zig"
    text = path.read_text()
    rows = {}
    for line in _registry_rows(text, "roots", "UnitRoot", path):
        row = re.fullmatch(r'\.\{ \.id = \.([a-z0-9_]+), \.name = ("(?:[^"\\]|\\.)*"), '
                           r'\.source = ("(?:[^"\\]|\\.)*"), \.target = ("[a-z0-9-]+")'
                           r'(?:, \.partition = ("[a-z]+"))?'
                           r'(?:, \.filter = ("(?:[^"\\]|\\.)*"))?'
                           r'(?:, \.filtered_only = (true|false))? \},', line)
        if row is None:
            raise ValueError(f"{path}: unsupported unit-root row: {line}")
        identifier, name, source, target, partition, test_filter, filtered_only = row.groups()
        if identifier in rows:
            raise ValueError(f"{path}: duplicate unit-root id {identifier}")
        entry = dict(name=json.loads(name), source=json.loads(source), target=json.loads(target), owners=[])
        if partition:
            entry["partition"] = json.loads(partition)
        if test_filter:
            entry["filter"] = json.loads(test_filter)
        if filtered_only:
            entry["filtered_only"] = json.loads(filtered_only)
        rows[identifier] = entry
    if not rows:
        raise ValueError(f"{path}: empty unit-root registry")
    groups = {}
    for line in _registry_rows(text, "groups", "UnitGroup", path):
        group = re.fullmatch(r'\.\{ \.id = \.([a-z0-9_]+), \.roots = &\.\{([^{}]+)\}, \.filtered = \.([a-z0-9_]+) \},', line)
        if group is None:
            raise ValueError(f"{path}: unsupported unit group: {line}")
        identifier, items, filtered = group.groups()
        if identifier in rows or identifier in groups:
            raise ValueError(f"{path}: duplicate unit group {identifier}")
        items = _registry_ids(items, path)
        if any(item not in rows or rows[item].get("filtered_only") for item in items):
            raise ValueError(f"{path}: unit group has unknown or filtered ordinary root")
        if filtered not in rows or not rows[filtered].get("filtered_only"):
            raise ValueError(f"{path}: unit group lacks a filtered aggregate")
        groups[identifier] = [*items, filtered]
    gates = set()
    for line in _registry_rows(text, "compositions", "Composition", path):
        composition = re.fullmatch(r'\.\{ \.gate = ("[a-z0-9-]+"), \.items = &\.\{([^{}]+)\}'
                                   r', \.parts = &\.\{([^{}]+)\} \},', line)
        if composition is None:
            raise ValueError(f"{path}: unsupported unit composition: {line}")
        gate, items, parts = composition.groups()
        gate = json.loads(gate)
        if gate in gates:
            raise ValueError(f"{path}: duplicate unit gate {gate}")
        gates.add(gate)
        parts = _registry_ids(parts, path)
        if not set(parts) <= {"all", "execution", "callers"}:
            raise ValueError(f"{path}: unknown unit composition part")
        for item in _registry_ids(items, path):
            members = groups.get(item, [item])
            for member in members:
                if member not in rows:
                    raise ValueError(f"{path}: unknown unit composition item {item}")
                rows[member]["owners"].extend((gate, part) for part in parts)
    return list(rows.values())


def unit_roots(root=ROOT):
    """Enrich build identities with the test runner's namespace partition rule.

    Mapping needs both owners: an absent or changed runner must fail closed.
    Target/source discovery uses unit_root_rows instead and needs no runner.
    """
    rows = unit_root_rows(root)
    partition_path = root / "src/unit_test_partition.zig"
    partition_source = partition_path.read_text()
    owner = re.search(r'pub fn owner\(name: \[\]const u8\) Root \{\s*'
                      r'return if \(std\.mem\.startsWith\(u8, name, ("(?:[^"\\]|\\.)*")\)\) '
                      r'\.([a-z_]+) else \.([a-z_]+);\s*\}', partition_source)
    if owner is None or owner[2] == owner[3]:
        raise ValueError(f"{partition_path}: unsupported unit partition owner")
    prefix = json.loads(owner[1])
    for entry in rows:
        if "partition" in entry:
            if entry["partition"] == owner[2]:
                entry["prefix"] = prefix
            elif entry["partition"] == owner[3]:
                entry["exclude_prefix"] = prefix
            else:
                raise ValueError(f"{root / 'build/unit.zig'}: partition has no runner owner: {entry['partition']}")
    return rows
