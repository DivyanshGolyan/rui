#!/usr/bin/env python3
"""Check Rui's Python-owned source boundaries and test reachability.

This is a source architecture check, not Zig's lazy declaration analysis. Both
platform branches count; test declarations, comments and string contents do not.
It owns the widgets and Store boundaries, the Store's access-source list, and
that every test file is named by a test that a test root reaches. Module cycles
belong to `zig build deep-modules` (tests/ci/deep_modules/ModuleCycle.zig).
The Store's boundary is checked over every file under src/, tests included.
"""
import argparse
import json
import os
from pathlib import Path
import re

import build_files


ROOT = Path(__file__).resolve().parents[2]
TEST_ONLY_ROOTS = ("src/tests.zig", "src/logic_tests.zig", "src/parser_fuzz_tests.zig", "tests/integration/mysql_wire_test.zig",
                   "tests/ci/deep_modules/tests.zig")
MODULE_TEST_ROOTS = ("src/h2/h2.zig", "src/store/wire/pg.zig", "src/url.zig", "src/os/os.zig")
STORE_DIRECTORY = "src/store/"
STORE_FACADE = "src/store.zig"
STORE_WIRE = "src/store/wire/"
STORE_TESTS = "src/store/tests.zig"
STORE_TEST_FILES = (STORE_TESTS, "src/store/sqlite_tests.zig", "src/store/history.zig", "src/store/mysql_dialect_check.zig",
                    "src/store/mysql_session_tests.zig", "src/store/mysql_testing.zig", "src/store/engine_contract.zig",
                    "src/store/column_rules_tests.zig")
STORE_TEST_DIRECTORIES = ("src/store/tests/", "src/store/sqlite_tests/")
SOURCE_SCAN_TESTS = ("Store entry points queue and fence only through canonical access",
                     "every function that enters the Store has a round budget")
WRITER_SCAN_TEST = SOURCE_SCAN_TESTS[0]
TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@[A-Za-z_][A-Za-z_0-9]*|[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def scoped_imports(source):
    tokens = [m.group() for m in TOKEN.finditer(source)
              if not m.group().startswith(("//", "\\\\"))]
    depth = 0
    test_depth = None
    has_tests = False
    production, tested, aliases, named = set(), set(), {}, set()
    for i, token in enumerate(tokens):
        if token == "test" and test_depth is None and (i == 0 or tokens[i - 1] != "@"):
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
            named.add(token)
    tested.update(target for name, target in aliases.items() if name in named)
    return production, tested, has_tests


def production_imports(source, tests=False):
    production, tested, _ = scoped_imports(source)
    return production | tested if tests else production


def tests_reached(root, test_only=TEST_ONLY_ROOTS, modules=MODULE_TEST_ROOTS):
    build = build_files.source(root)
    registered = ({row["source"] for row in build_files.unit_root_rows(root)}
                  if (root / "build/unit.zig").is_file() else set())
    if stale := [name for name in (*test_only, *modules)
                 if name not in registered and f'b.path("{name}")' not in build]:
        raise ValueError(f"The build no longer builds test roots {stale}; update TEST_ONLY_ROOTS/MODULE_TEST_ROOTS")
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


def widgets_boundary(root):
    directory = root / "src/widgets"
    resolved = directory.resolve()
    for path in sorted(directory.rglob("*.zig")):
        for imported in production_imports(path.read_text(), tests=True):
            if imported in ("std", "vaxis"):
                continue
            target = (path.parent / imported).resolve()
            if (Path(imported).is_absolute() or not imported.endswith(".zig")
                    or not target.is_relative_to(resolved)):
                raise ValueError(f"{path.relative_to(root)} imports {imported}; widgets import only "
                                 "std, vaxis or files inside src/widgets/")


def store_boundary(root):
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
            if source == "src/logic_tests.zig" and target in ("src/store/command_replay.zig", "src/store/engine/mysql_commit.zig", "src/store/engine/mysql_refusal.zig", "src/store/page_slots.zig", "src/store/pass_plan.zig",
                                                                 "src/store/round_order.zig", "src/store/write_batch.zig"):
                continue
            if target.startswith(STORE_DIRECTORY) and not source.startswith(STORE_DIRECTORY) and source != STORE_FACADE:
                raise ValueError(f"{source} imports {target}; import {STORE_FACADE} instead")
            if target == STORE_FACADE and source.startswith(STORE_DIRECTORY):
                raise ValueError(f"{source} imports {STORE_FACADE}; Store files import each other directly")


def store_access_sources(root):
    directory = root / STORE_DIRECTORY

    def test_file(path):
        relative = path.relative_to(root).as_posix()
        return relative in STORE_TEST_FILES or relative.startswith(STORE_TEST_DIRECTORIES)

    expected = sorted(path.relative_to(directory).as_posix() for path in directory.rglob("*.zig")
                      if not test_file(path) and not path.is_relative_to(root / STORE_WIRE))
    tests = sorted(path.relative_to(directory).as_posix() for path in directory.rglob("*.zig") if test_file(path))
    holders = [root / STORE_TESTS, *sorted((root / STORE_TEST_DIRECTORIES[0]).rglob("*.zig"))]
    for name in SOURCE_SCAN_TESTS:
        found = [(path, test) for path in holders if path.is_file()
                 for test in [re.search(rf'^test "{re.escape(name)}" \{{\n(.*?)^\}}$', path.read_text(), re.M | re.S)]
                 if test]
        if not found:
            raise ValueError(f'{STORE_TESTS} or a file under {STORE_TEST_DIRECTORIES[0]} has no test "{name}"')
        path, test = found[0]
        listed = sorted(Path(os.path.normpath(path.parent / embedded)).relative_to(directory).as_posix()
                        for embedded in re.findall(r'@embedFile\("([^"]+)"\)', test[1]))
        files = sorted(expected + tests) if name == WRITER_SCAN_TEST else expected
        if listed != files:
            raise ValueError(f'"{name}" reads {listed}; the Store\'s files are {files}')
    if "fn" in TOKEN.findall((root / STORE_FACADE).read_text()):
        raise ValueError(f"{STORE_FACADE} declares a function; add it to the source-scan tests' sources")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        widgets_boundary(args.root)
        store_boundary(args.root)
        store_access_sources(args.root)
        tests_reached(args.root)
    except ValueError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
