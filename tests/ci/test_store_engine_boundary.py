"""Only the SQLite engine and its own tests reach the SQLite C binding.

Access and the Store run rounds through `engine.Engine`, so a second engine
can sit behind it without touching them. A Store file outside `ALLOWED`
that names a `sqlite3_` function or type, the binding `sqlite.c`, or the C
module `@import("sqlite")` reaches past the engine. Comments and strings
are inert. The list only shrinks: a listed file that no longer names the
binding must leave it.
"""
from pathlib import Path
import re
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
STORE = "src/store"

ALLOWED = {
    # The C binding itself, and the engine that owns the connection.
    "sqlite.zig",
    "engine/Sqlite.zig",
    # Schema validation and bootstrap run on the connection at open.
    "schema.zig",
    # SQLite-only fixtures and tests.
    "testing.zig",
    "sqlite_tests.zig",
    # A test of `rui_served` against an in-memory database.
    "rsql.zig",
}

# Zig tokens; comments and multiline string lines are dropped, strings stay
# whole so `@import("sqlite")` is recognizable and their contents are inert.
TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@?[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def binding_sites(source):
    tokens = [m.group() for m in TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\"))]
    sites = 0
    for i, token in enumerate(tokens):
        if token.startswith("sqlite3_"):
            sites += 1
        elif token == "sqlite" and tokens[i + 1:i + 3] == [".", "c"] and (i == 0 or tokens[i - 1] != "."):
            sites += 1
        elif token == "@import" and tokens[i + 1:i + 4] == ["(", '"sqlite"', ")"]:
            sites += 1
    return sites


def violations(root=ROOT):
    store = root / STORE
    found = {path.relative_to(store).as_posix(): binding_sites(path.read_text()) for path in sorted(store.rglob("*.zig"))}
    messages = [f"{STORE}/{name} names the SQLite binding {count} times; run it through engine.Engine "
                "(src/store/engine.zig) or engine/Sqlite.zig" for name, count in found.items()
                if count and name not in ALLOWED]
    messages += [f"{STORE}/{name} no longer names the SQLite binding; remove it from ALLOWED"
                 for name in sorted(ALLOWED) if not found.get(name)]
    return messages


class StoreEngineBoundaryTest(unittest.TestCase):
    def test_only_the_sqlite_engine_names_the_binding(self):
        self.assertEqual(violations(), [])

    def test_scan_reads_calls_types_and_imports_but_not_comments_or_strings(self):
        for source in ("_ = c.sqlite3_step(statement);", "var s: ?*c.sqlite3_stmt = null;",
                       "const c = sqlite.c;", 'pub const c = @import("sqlite");'):
            self.assertEqual(binding_sites(source), 1, source)
        for source in ("// c.sqlite3_step", 'const s = "sqlite3_" ++ "prepare";', "\\\\sqlite.c",
                       "a.store.engine.nextRow(statement)", "x.sqlite.c", 'const sqlite = @import("sqlite.zig");'):
            self.assertEqual(binding_sites(source), 0, source)

    def test_a_step_moved_back_into_access_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / STORE, root / STORE)
            access = root / STORE / "access.zig"
            access.write_text(access.read_text() + "\nfn step(s: *c.sqlite3_stmt) c_int {\n    return c.sqlite3_step(s);\n}\n")
            self.assertEqual(len(violations(root)), 1)
            self.assertIn("src/store/access.zig names the SQLite binding 2 times", violations(root)[0])

    def test_a_listed_file_that_stops_naming_the_binding_must_leave_the_list(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / STORE, root / STORE)
            (root / STORE / "rsql.zig").write_text("const std = @import(\"std\");\n")
            self.assertEqual(violations(root), [f"{STORE}/rsql.zig no longer names the SQLite binding; remove it from ALLOWED"])


if __name__ == "__main__":
    unittest.main()
