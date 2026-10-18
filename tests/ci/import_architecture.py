#!/usr/bin/env python3
"""Ratchet literal first-party imports reachable from Rui's production roots.

This is a source architecture check, not Zig's lazy declaration analysis. Both
platform branches count; test declarations, comments and string contents do not.
addRui in build.zig owns the Zig executable root. addEvaluator is C-only; its
private Zig host adapter is currently fixture-only. Package imports are external.
"""
import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
ROOTS = ("src/cli.zig",)
BASELINE = Path(__file__).with_name("import_cycles.json")
# Preserve strings as tokens so braces/import spellings inside them are inert.
TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@[A-Za-z_][A-Za-z_0-9]*|[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def production_imports(source):
    tokens = [m.group() for m in TOKEN.finditer(source)
              if not m.group().startswith(("//", "\\\\"))]
    depth = 0
    test_depth = None
    imports = set()
    for i, token in enumerate(tokens):
        if token == "test" and (i == 0 or tokens[i - 1] != "@"):
            # Zig test declarations are `test ["name"] { ... }`.
            following = i + 1
            if following < len(tokens) and tokens[following].startswith('"'):
                following += 1
            if following < len(tokens) and tokens[following] == "{":
                test_depth = depth + 1
        if token == "{":
            depth += 1
        elif token == "}":
            if test_depth == depth:
                test_depth = None
            depth -= 1
        elif token == "@import" and test_depth is None:
            if tokens[i + 1:i + 2] != ["("] or i + 3 >= len(tokens):
                raise ValueError("unrecognized @import syntax")
            literal = tokens[i + 2]
            if not literal.startswith('"') or tokens[i + 3] != ")":
                raise ValueError("architecture check requires literal @import")
            imports.add(json.loads(literal))
    return imports


def graph(root, roots=ROOTS):
    result = {}
    pending = list(roots)
    while pending:
        name = pending.pop()
        if name in result:
            continue
        path = root / name
        dependencies = set()
        for imported in production_imports(path.read_text()):
            if not imported.endswith(".zig"):
                continue
            target = (path.parent / imported).resolve()
            relative = target.relative_to(root.resolve()).as_posix()
            if not target.is_file():
                raise ValueError(f"{name}: missing first-party import {imported}")
            dependencies.add(relative)
        result[name] = dependencies
        pending.extend(dependencies)
    return result


def cyclic_edges(dependencies):
    """Every edge with a return path, including self edges (no SCC exemptions)."""
    def reaches(start, goal):
        pending = [start]
        visited = set()
        while pending:
            node = pending.pop()
            if node == goal:
                return True
            if node not in visited:
                visited.add(node)
                pending.extend(dependencies[node])
        return False

    return sorted([source, target] for source, targets in dependencies.items()
                  for target in targets if reaches(target, source))


def check(root=ROOT, baseline=BASELINE, roots=ROOTS):
    dependencies = graph(root, roots)
    actual = cyclic_edges(dependencies)
    allowed = json.loads(baseline.read_text())["cyclic_edges"]
    added = [edge for edge in actual if edge not in allowed]
    if added:
        raise ValueError("new production cyclic imports:\n" + "\n".join(
            f"  {source} -> {target}" for source, target in added))
    return {"modules": len(dependencies), "cyclic_edges": actual}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.root, args.baseline), indent=2))
    except ValueError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
