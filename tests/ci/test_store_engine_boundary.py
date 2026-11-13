"""Only the SQLite engine and its own tests reach the SQLite C binding, and
src/store/domain reaches neither the engine nor the Queue.

Access and the Store run rounds through `engine.Engine`, so a second engine
can sit behind it without touching them. A Store file outside `ALLOWED`
that names a `sqlite3_` function or type, the binding `sqlite.c`, or the C
module `@import("sqlite")` reaches past the engine.

Outside test blocks, a domain file that imports the engine, the Queue or the
binding, or reaches them through the Store (`.engine`, `.queue()`, and the
Store's `enter` and `fence`), counts against `DOMAIN_REACH`.

Comments and strings are inert. Both lists only shrink: an entry above what
the tree holds must be lowered or removed.
"""
from pathlib import Path
import shutil
import tempfile
import unittest

from caller_errors import lex, production


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
# The per-domain SQLite mechanism tests: any file there may name the binding.
ALLOWED_DIRECTORIES = ("sqlite_tests/",)

DOMAIN = "src/store/domain"
DOMAIN_RULE = "src/store/domain reaches the engine or the Queue only through the transition runner"
DOMAIN_IMPORTS = ('"../engine.zig"', '"../queue.zig"', '"../sqlite.zig"')
STORE_REACH = ("enter", "fence")

# Shrink-only: occurrences per (domain file, reach) today.
DOMAIN_REACH = {
    ("action.zig", '@import("../sqlite.zig")'): 1,
    ("command.zig", '@import("../sqlite.zig")'): 1,
    ("content.zig", ".queue()"): 2,
    ("content.zig", "Store.enter"): 2,
    ("content.zig", "Store.fence"): 1,
    ("historical.zig", ".queue()"): 8,
    ("historical.zig", "Store.enter"): 8,
    ("historical.zig", "Store.fence"): 8,
    ("model_settlement.zig", ".queue()"): 1,
    ("model_settlement.zig", "Store.enter"): 1,
    ("reads.zig", "Store.fence"): 3,
}


def binding_sites(source):
    tokens = [token.text for token in lex(source)]
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
                if count and name not in ALLOWED and not name.startswith(ALLOWED_DIRECTORIES)]
    messages += [f"{STORE}/{name} no longer names the SQLite binding; remove it from ALLOWED"
                 for name in sorted(ALLOWED) if not found.get(name)]
    return messages


def domain_reaches(source):
    """Reaches outside test blocks, counted by the label a violation names."""
    tokens = [token.text for token in production(lex(source))]
    store = {tokens[i - 1] for i in range(1, len(tokens) - 4)
             if tokens[i:i + 5] == ["=", "@import", "(", '"../Store.zig"', ")"]}
    found = {}
    for i, token in enumerate(tokens):
        name = tokens[i + 1] if i + 1 < len(tokens) else ""
        if token == "@import" and name == "(" and (tokens[i + 2] in DOMAIN_IMPORTS or tokens[i + 2].startswith('"../engine/')):
            label = f"@import({tokens[i + 2]})"
        elif token == "." and name == "engine":
            label = ".engine"
        elif token == "." and tokens[i + 1:i + 4] == ["queue", "(", ")"]:
            label = ".queue()"
        elif token == "." and name in STORE_REACH and tokens[i - 1] in store:
            label = f"Store.{name}"
        else:
            continue
        found[label] = found.get(label, 0) + 1
    return found


def domain_violations(root=ROOT, allowed=None):
    allowed = DOMAIN_REACH if allowed is None else allowed
    found = {(path.name, label): count for path in sorted((root / DOMAIN).glob("*.zig"))
             for label, count in domain_reaches(path.read_text()).items()}
    messages = []
    for (name, label) in sorted(set(found) | set(allowed)):
        count, listed = found.get((name, label), 0), allowed.get((name, label), 0)
        if count > listed:
            messages.append(f"{DOMAIN}/{name} reaches through {label} {count} times, {listed} allowed; {DOMAIN_RULE}")
        elif count < listed:
            messages.append(f"{DOMAIN}/{name} reaches through {label} {count} times, {listed} allowed; "
                            "lower its DOMAIN_REACH entry")
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


class DomainReachTest(unittest.TestCase):
    def test_domain_reaches_match_the_shrink_only_allowlist(self):
        self.assertEqual(domain_violations(), [])

    def test_scan_reads_imports_and_reaches_but_not_tests_comments_strings_or_own_queues(self):
        source = ('const store_core = @import("../Store.zig");\nconst core = @import("../Store.zig");\n'
                  'const q = @import("../queue.zig");\nconst e = @import("../engine/Sqlite.zig");\n'
                  'fn f() void {\n    _ = a.store.engine.batches();\n    const g = a.store.engine;\n'
                  '    self.queue().run(x, .{});\n    _ = store_core.enter(self, .none);\n'
                  '    return core.fence(self.store, err);\n}\n')
        self.assertEqual(domain_reaches(source), {'@import("../queue.zig")': 1, '@import("../engine/Sqlite.zig")': 1,
                                                  ".engine": 2, ".queue()": 1, "Store.enter": 1, "Store.fence": 1})
        inert = ('const store_core = @import("../Store.zig");\n// a.store.engine.batches()\n'
                 'const s = "self.queue()";\nfn f() void {\n    read.queue(a);\n    _ = store_core.Faults;\n'
                 '    _ = store_core.readUnixMilliseconds(io);\n    _ = other.enter(x);\n}\n'
                 'test "fixture" {\n    _ = a.store.engine.batches();\n}\n')
        self.assertEqual(domain_reaches(inert), {})

    def test_a_new_reach_fails_naming_file_reach_and_rule(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / DOMAIN, root / DOMAIN)
            turn = root / DOMAIN / "turn.zig"
            turn.write_text(turn.read_text() + "\nfn batches(x: anytype) bool {\n    return x.store.engine.batches();\n}\n")
            self.assertEqual(domain_violations(root), [f"{DOMAIN}/turn.zig reaches through .engine 1 times, 0 allowed; {DOMAIN_RULE}"])
            self.assertEqual(domain_violations(root, DOMAIN_REACH | {("turn.zig", ".engine"): 1}), [])

    def test_a_reach_that_drops_fails_until_its_entry_is_lowered(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / DOMAIN, root / DOMAIN)
            path = root / DOMAIN / "model_settlement.zig"
            path.write_text(path.read_text().replace("self.queue().run(checkAttemptHeld", "self.run(checkAttemptHeld"))
            self.assertEqual(domain_violations(root), [f"{DOMAIN}/model_settlement.zig reaches through .queue() 0 times, "
                                                       "1 allowed; lower its DOMAIN_REACH entry"])
            lowered = {key: count for key, count in DOMAIN_REACH.items() if key != ("model_settlement.zig", ".queue()")}
            self.assertEqual(domain_violations(root, lowered), [])


if __name__ == "__main__":
    unittest.main()
