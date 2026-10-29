#!/usr/bin/env python3
"""Ratchet literal first-party imports reachable from Rui's production roots.

This is a source architecture check, not Zig's lazy declaration analysis. Both
platform branches count; test declarations, comments and string contents do not.
addRui in build.zig owns the Zig executable root. Package imports are external.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]
ROOTS = ("src/cli.zig",)
BASELINE = Path(__file__).with_name("import_cycles.json")
BOOTSTRAP_BASE = "cdad5aaf4dc43cbb7864f0fa0a4a08bf4f25a8ff"
# Preserve strings as tokens so braces/import spellings inside them are inert.
TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@[A-Za-z_][A-Za-z_0-9]*|[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def production_imports(source):
    tokens = [m.group() for m in TOKEN.finditer(source)
              if not m.group().startswith(("//", "\\\\"))]
    depth = 0
    test_depth = None
    imports = set()
    for i, token in enumerate(tokens):
        if token == "test" and test_depth is None and (i == 0 or tokens[i - 1] != "@"):
            # Preserve the outermost test scope, including nested container tests.
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


def graph(root, roots=ROOTS, read_source=None):
    read_source = read_source or (lambda name: (root / name).read_text())
    result = {}
    pending = list(roots)
    while pending:
        name = pending.pop()
        if name in result:
            continue
        path = root / name
        dependencies = set()
        try:
            source = read_source(name)
        except OSError as error:
            raise ValueError(f"missing first-party source: {name}") from error
        for imported in production_imports(source):
            if imported == "root":
                # Zig's special module alias refers to addRui's executable root.
                target = (root / roots[0]).resolve()
            elif imported.endswith(".zig"):
                target = (path.parent / imported).resolve()
            else:
                continue
            relative = target.relative_to(root.resolve()).as_posix()
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


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True)
    if result.returncode:
        raise ValueError("import allowance requires complete trusted Git history: " + result.stderr.strip())
    return result.stdout.strip()


def trusted_allowance(root, baseline, roots):
    review_base = git(root, "merge-base", "HEAD", "origin/main")
    name = baseline.resolve().relative_to(root.resolve()).as_posix()
    if git(root, "ls-tree", "--name-only", review_base, "--", name):
        return json.loads(git(root, "show", f"{review_base}:{name}"))["cyclic_edges"]
    # First introduction: derive the original exceptions from the authorized
    # immutable source, never from the candidate's self-declared measurement.
    git(root, "merge-base", "--is-ancestor", BOOTSTRAP_BASE, review_base)
    return cyclic_edges(graph(root, roots, lambda path: git(root, "show", f"{BOOTSTRAP_BASE}:{path}")))


def check(root=ROOT, baseline=BASELINE, roots=ROOTS):
    dependencies = graph(root, roots)
    actual = cyclic_edges(dependencies)
    allowed = json.loads(baseline.read_text())["cyclic_edges"]
    added = [edge for edge in actual if edge not in allowed]
    if added:
        raise ValueError("new production cyclic imports:\n" + "\n".join(
            f"  {source} -> {target}" for source, target in added))
    if any(edge not in actual for edge in allowed):
        raise ValueError("remove stale cycle allowance for eliminated production cycles")
    trusted = trusted_allowance(root, baseline, roots)
    if any(edge not in trusted for edge in allowed):
        raise ValueError("production cycle allowance grew beyond the trusted review base")
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
