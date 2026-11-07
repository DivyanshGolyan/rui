#!/usr/bin/env python3
"""Ratchet literal first-party imports reachable from Rui's production roots.

This is a source architecture check, not Zig's lazy declaration analysis. Both
platform branches count; test declarations, comments and string contents do not.
addRui in build.zig owns the Zig executable root. Package imports are external.
The Store's boundary is checked over every file under src/, tests included.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]
ROOTS = ("src/cli.zig",)
# build.zig's addTest roots. Zig compiles a file's tests only when the test
# build analyzes the file, and a production import is analyzed only if
# something the tests run uses it. A test that names the file is the
# guarantee. The test-only roots name their imports from tests, so each
# of their imports counts; a module root counts only what its tests name.
TEST_ONLY_ROOTS = ("src/tests.zig", "src/logic_tests.zig", "tests/integration/mysql_wire_test.zig",
                   "tests/vaxis/layout.zig")
MODULE_TEST_ROOTS = ("src/h2/h2.zig", "src/store/wire/pg.zig")
BASELINE = Path(__file__).with_name("import_cycles.json")
STORE_DIRECTORY = "src/store/"
STORE_FACADE = "src/store.zig"
# Wire clients are protocol leaves with no Store types: any root may test them,
# and they import nothing else of the Store.
STORE_WIRE = "src/store/wire/"
STORE_TESTS = "src/store/tests.zig"
# Test files hold no entry point, so the lock-and-fence test does not read them.
STORE_TEST_FILES = (STORE_TESTS, "src/store/sqlite_tests.zig", "src/store/mysql_dialect_check.zig",
                    "src/store/mysql_session_tests.zig", "src/store/mysql_testing.zig")
# The tests that scan every Store file's source, each by its own embed list.
SOURCE_SCAN_TESTS = ("Store entry points queue and fence only through canonical access",
                     "every function that enters the Store has a round budget")
BOOTSTRAP_BASE = "cdad5aaf4dc43cbb7864f0fa0a4a08bf4f25a8ff"
# Preserve strings as tokens so braces/import spellings inside them are inert.
TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@[A-Za-z_][A-Za-z_0-9]*|[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def scoped_imports(source):
    """Literal imports outside test declarations, the imports a test
    declaration references (literally or through a top-level alias), and
    whether the source declares a test."""
    tokens = [m.group() for m in TOKEN.finditer(source)
              if not m.group().startswith(("//", "\\\\"))]
    depth = 0
    test_depth = None
    has_tests = False
    production, tested, aliases, named = set(), set(), {}, set()
    for i, token in enumerate(tokens):
        if token == "test" and test_depth is None and (i == 0 or tokens[i - 1] != "@"):
            # Preserve the outermost test scope, including nested container tests.
            following = i + 1
            if following < len(tokens) and tokens[following].startswith('"'):
                following += 1
            if following < len(tokens) and tokens[following] == "{":
                test_depth = depth + 1
                has_tests = True
        if token == "{":
            depth += 1
        elif token == "}":
            if test_depth == depth:
                test_depth = None
            depth -= 1
        elif token == "@import":
            if tokens[i + 1:i + 2] != ["("] or i + 3 >= len(tokens):
                raise ValueError("unrecognized @import syntax")
            literal = tokens[i + 2]
            if not literal.startswith('"') or tokens[i + 3] != ")":
                raise ValueError("architecture check requires literal @import")
            (production if test_depth is None else tested).add(json.loads(literal))
            if test_depth is None and i >= 3 and tokens[i - 3] == "const" and tokens[i - 1] == "=":
                aliases[tokens[i - 2]] = json.loads(literal)
        elif test_depth is not None:
            # Zig forbids a local from shadowing a declaration. A name after
            # "." still counts, since nested aliases are reached that way.
            named.add(token)
    tested.update(target for name, target in aliases.items() if name in named)
    return production, tested, has_tests


def production_imports(source, tests=False):
    """Literal imports outside test declarations, or every import with tests=True."""
    production, tested, _ = scoped_imports(source)
    return production | tested if tests else production


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


def tests_reached(root, test_only=TEST_ONLY_ROOTS, modules=MODULE_TEST_ROOTS):
    """Every Zig file under src/ and tests/ that declares tests is named by a
    test reached from a test root, so its tests cannot silently stop running."""
    build = (root / "build.zig").read_text()
    if stale := [name for name in (*test_only, *modules) if f'b.path("{name}")' not in build]:
        raise ValueError(f"build.zig no longer builds test roots {stale}; update TEST_ONLY_ROOTS/MODULE_TEST_ROOTS")
    scanned = {path.resolve(): scoped_imports(path.read_text())
               for directory in ("src", "tests") for path in (root / directory).rglob("*.zig")}
    reached = set()
    pending = [((root / name).resolve(), name in test_only) for name in (*test_only, *modules)]
    while pending:
        path, every_import = pending.pop()
        if path in reached or path not in scanned:
            continue
        reached.add(path)
        production, tested, _ = scanned[path]
        pending.extend(((path.parent / imported).resolve(), False)
                       for imported in (production | tested if every_import else tested)
                       if imported.endswith(".zig"))
    resolved = root.resolve()
    unreached = sorted(path.relative_to(resolved).as_posix()
                       for path, (_, _, has_tests) in scanned.items() if has_tests and path not in reached)
    if unreached:
        raise ValueError("no test names these files, so their tests may never compile; import each "
                         "from a test that a test root reaches (src/tests.zig, for example):\n"
                         + "\n".join(f"  {name}" for name in unreached))


def store_boundary(root):
    """Across every file under src/, test declarations included: outside
    src/store/ only the facade imports a Store file, no Store file imports
    the facade, and a wire client imports no Store file outside wire/."""
    resolved = root.resolve()
    for path in sorted((root / "src").rglob("*.zig")):
        source = path.relative_to(root).as_posix()
        for imported in production_imports(path.read_text(), tests=True):
            if not imported.endswith(".zig"):
                continue
            target = (path.parent / imported).resolve()
            if not target.is_relative_to(resolved):
                continue
            target = target.relative_to(resolved).as_posix()
            if source.startswith(STORE_WIRE) and target.startswith(STORE_DIRECTORY) and not target.startswith(STORE_WIRE):
                raise ValueError(f"{source} imports {target}; a wire client imports only wire/")
            if target.startswith(STORE_WIRE):
                continue
            if source == "src/logic_tests.zig" and target == "src/store/engine/mysql_refusal.zig":
                # The refusal decision is a registered value-only core.
                continue
            if target.startswith(STORE_DIRECTORY) and not source.startswith(STORE_DIRECTORY) and source != STORE_FACADE:
                raise ValueError(f"{source} imports {target}; import {STORE_FACADE} instead")
            if target == STORE_FACADE and source.startswith(STORE_DIRECTORY):
                raise ValueError(f"{source} imports {STORE_FACADE}; Store files import each other directly")


def store_access_sources(root):
    """Each source-scan test (`SOURCE_SCAN_TESTS`) reads every Store file
    but its test files (`STORE_TEST_FILES`) and the wire clients, which
    hold no Store state.

    The facade holds only re-exports, so it has no entry point to check; a
    function there must join the tests' sources.
    """
    directory = root / STORE_DIRECTORY
    expected = sorted(path.relative_to(directory).as_posix() for path in directory.rglob("*.zig")
                      if path.relative_to(root).as_posix() not in STORE_TEST_FILES
                      and not path.is_relative_to(root / STORE_WIRE))
    text = (root / STORE_TESTS).read_text()
    for name in SOURCE_SCAN_TESTS:
        test = re.search(rf'^test "{re.escape(name)}" \{{\n(.*?)^\}}$', text, re.M | re.S)
        if not test:
            raise ValueError(f'{STORE_TESTS} has no test "{name}"')
        listed = sorted(re.findall(r'@embedFile\("([^"]+)"\)', test[1]))
        if listed != expected:
            raise ValueError(f'"{name}" reads {listed}; the Store\'s files are {expected}')
    if "fn" in TOKEN.findall((root / STORE_FACADE).read_text()):
        raise ValueError(f"{STORE_FACADE} declares a function; add it to the source-scan tests' sources")


def store_unit(dependencies):
    """Collapse src/store/ into its facade for the cycle ratchet.

    The Store's files hold one type's declarations: Store.zig's entry points
    call the domain files, which call back into Store.zig's locking and
    statement helpers. Those cycles are inherent to splitting one type, so
    they are not counted; store_boundary keeps them inside src/store/.
    """
    def unit(name):
        return STORE_FACADE if name.startswith(STORE_DIRECTORY) and not name.startswith(STORE_WIRE) else name

    collapsed = {}
    for source, targets in dependencies.items():
        collapsed.setdefault(unit(source), set()).update(unit(target) for target in targets)
    collapsed.get(STORE_FACADE, set()).discard(STORE_FACADE)
    return collapsed


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
    dependencies = store_unit(graph(root, roots))
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
        store_boundary(args.root)
        store_access_sources(args.root)
        tests_reached(args.root)
        print(json.dumps(check(args.root, args.baseline), indent=2))
    except ValueError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
