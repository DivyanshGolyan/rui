from pathlib import Path
import re
import shutil
import tempfile
import unittest

from caller_errors import lex, production


ROOT = Path(__file__).resolve().parents[2]
STORE = "src/store"

ALLOWED = {
    "sqlite.zig",
    "engine/Sqlite.zig",
    "schema.zig",
    "testing.zig",
    "history.zig",
    "sqlite_tests.zig",
    "rsql.zig",
    "column_rules_tests.zig",
}
ALLOWED_DIRECTORIES = ("sqlite_tests/",)

DOMAIN = "src/store/domain"
DOMAIN_RULE = "src/store/domain reaches the engine or the Queue only through the transition runner"
DOMAIN_IMPORTS = ('"../engine.zig"', '"../queue.zig"', '"../sqlite.zig"')
STORE_REACH = ("enter", "fence")

DOMAIN_REACH = {
    ("action.zig", '@import("../sqlite.zig")'): 1,
    ("command.zig", '@import("../sqlite.zig")'): 1,
    ("content.zig", ".queue()"): 2,
    ("content.zig", "Store.enter"): 2,
    ("content.zig", "Store.fence"): 1,
    ("historical.zig", ".queue()"): 8,
    ("historical.zig", "Store.enter"): 8,
    ("historical.zig", "Store.fence"): 1,
    ("model_settlement.zig", ".queue()"): 1,
    ("model_settlement.zig", "Store.enter"): 1,
    ("reads.zig", "Store.fence"): 3,
}


FORMAT_SOURCES = "src"
FORMAT_SUFFIXES = (".zig", ".sql")
FORMAT_OWNERS = {"src/store/history.zig", "src/store/schema.zig"}
# A generated lookup of statements the owners and tests already build (tests/ci/rsql_table.py); its text is counted where
# it is written, so the table itself is not a writer.
FORMAT_GENERATED = {"src/store/rsql_table.zig"}
FORMAT_WRITE = {
    "user_version": re.compile(r"PRAGMA\s+user_version\s*="),
    "format update": re.compile(r"UPDATE\s+store_meta\s+SET\s+meta_value\s*=(?:(?!WHERE|;).)*?WHERE\s+meta_key\s*=\s*'format'"),
    "format insert": re.compile(r"(?:INSERT|REPLACE)\s+INTO\s+store_meta\b(?:(?!;).)*?\(\s*'format'\s*,"),
    "drop column": re.compile(r"\bDROP\s+COLUMN\b"),
}
FORMAT_RULE = ("only src/store/history.zig and src/store/schema.zig write the Store format; build an old format with "
               "history.openAt or history.build (src/store/history.zig)")
# Shrink-only ratchet: each existing test-code writer of the format, by file and kind. A new writer, or a count that
# grows, fails; a count that drops must be lowered here. Each entry is a format built by hand that history.zig should own.
FORMAT_WRITERS = {
    ("src/store/mysql_dialect_check.zig", "format insert"): 12,
    ("src/store/mysql_testing.zig", "format update"): 6,
    ("src/store/sqlite_tests/archive_membership.zig", "format insert"): 1,
    ("src/store/sqlite_tests/archive_membership.zig", "user_version"): 1,
    ("src/store/sqlite_tests/context_window_migration.zig", "format insert"): 1,
    ("src/store/sqlite_tests/context_window_migration.zig", "user_version"): 1,
    ("src/store/sqlite_tests/migration.zig", "format insert"): 13,
    ("src/store/sqlite_tests/migration.zig", "format update"): 3,
    ("src/store/sqlite_tests/migration.zig", "user_version"): 15,
    ("src/store/sqlite_tests/schema.zig", "format insert"): 2,
    ("src/store/sqlite_tests/schema.zig", "format update"): 3,
    ("src/store/sqlite_tests/schema.zig", "user_version"): 2,
    ("src/store/sqlite_tests/skills_migration.zig", "format insert"): 2,
    ("src/store/sqlite_tests/skills_migration.zig", "user_version"): 2,
    ("src/store/sqlite_tests/tool_record_hint.zig", "format insert"): 1,
    ("src/store/sqlite_tests/tool_record_hint.zig", "user_version"): 1,
    ("src/store/sqlite_tests/tool_set_migration.zig", "format insert"): 1,
    ("src/store/sqlite_tests/tool_set_migration.zig", "user_version"): 1,
}


# The format lint's own tokeniser. Unlike caller_errors.lex it keeps Zig multiline-string lines (`\\`), whose SQL is
# written there, and drops only `//` comments. SQL files have no comment form the lint needs, except `--`.
FORMAT_TOKEN = re.compile(
    r'//[^\n]*|\\\\[^\n]*|@"(?:\\.|[^"\\])*"|"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|@?[A-Za-z_][A-Za-z_0-9]*|=>|[^\s]"
)


def format_code(source, suffix):
    if suffix == ".sql":
        return " ".join(re.sub(r"--[^\n]*", " ", source).split())
    return " ".join(match.group() for match in FORMAT_TOKEN.finditer(source) if not match.group().startswith("//"))


def format_writes(source, suffix=".zig"):
    code = format_code(source, suffix)
    return {kind: len(pattern.findall(code)) for kind, pattern in FORMAT_WRITE.items()}


def format_violations(root=ROOT, writers=None):
    writers = FORMAT_WRITERS if writers is None else writers
    found = {}
    for path in sorted(p for p in (root / FORMAT_SOURCES).rglob("*") if p.suffix in FORMAT_SUFFIXES):
        name = path.relative_to(root).as_posix()
        if name in FORMAT_OWNERS | FORMAT_GENERATED:
            continue
        for kind, count in format_writes(path.read_text(), path.suffix).items():
            if count:
                found[(name, kind)] = count
    messages = []
    for (name, kind) in sorted(set(found) | set(writers)):
        count, listed = found.get((name, kind), 0), writers.get((name, kind), 0)
        if count > listed:
            messages.append(f"{name} writes the Store format ({kind}) {count} times, {listed} allowed; {FORMAT_RULE}")
        elif count < listed:
            messages.append(f"{name} writes the Store format ({kind}) {count} times, {listed} allowed; lower its FORMAT_WRITERS entry")
    return messages


# Shrink-only ratchet for the fixtures a hand-built old-format Store is assembled from. Test code outside the
# fixture owners (history.zig builds old formats forward; testing.zig defines the fixtures) names them to build a
# format by hand. Counted per file as code tokens, so a struct field such as `.baseline_rows = true` is not a
# reference. A new hand-built old-format Store fails here and must go through history.build.
BASELINE_NAMES = {"baseline_sqlite_ddl", "baseline_mysql_ddl", "baseline_mysql_rows", "baseline_rows"}
BASELINE_OWNERS = {"src/store/history.zig", "src/store/testing.zig"}
BASELINE_REFERENCES = {
    "src/store/mysql_dialect_check.zig": 30,
    "src/store/sqlite_tests/archive_membership.zig": 8,
    "src/store/sqlite_tests/context_window_migration.zig": 2,
    "src/store/sqlite_tests/migration.zig": 26,
    "src/store/sqlite_tests/skills_migration.zig": 4,
    "src/store/sqlite_tests/tool_record_hint.zig": 2,
    "src/store/sqlite_tests/tool_set_migration.zig": 2,
}
BASELINE_RULE = ("hand-built old-format Stores are built through history.build (src/store/history.zig), "
                 "not from the baseline fixtures")


def baseline_references(source):
    texts = [match.group() for match in FORMAT_TOKEN.finditer(source) if not match.group().startswith("//")]
    return sum(1 for i, text in enumerate(texts) if text in BASELINE_NAMES and texts[i + 1:i + 2] != ["="])


def baseline_violations(root=ROOT, references=None):
    references = BASELINE_REFERENCES if references is None else references
    found = {}
    for path in sorted((root / "src").rglob("*.zig")):
        name = path.relative_to(root).as_posix()
        if name in BASELINE_OWNERS:
            continue
        count = baseline_references(path.read_text())
        if count:
            found[name] = count
    messages = []
    for name in sorted(set(found) | set(references)):
        count, listed = found.get(name, 0), references.get(name, 0)
        if count > listed:
            messages.append(f"{name} names the baseline fixtures {count} times, {listed} allowed; {BASELINE_RULE}")
        elif count < listed:
            messages.append(f"{name} names the baseline fixtures {count} times, {listed} allowed; lower its BASELINE_REFERENCES entry")
    return messages


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


class FormatWriteTest(unittest.TestCase):
    def test_format_writers_match_the_shrink_only_ratchet(self):
        self.assertEqual(format_violations(), [])

    def test_scan_reads_writes_in_strings_but_not_comments_or_reads(self):
        self.assertEqual(format_writes('const s = "PRAGMA user_version={d}";'), {"user_version": 1, "format update": 0, "drop column": 0, "format insert": 0})
        self.assertEqual(format_writes('x("UPDATE store_meta SET meta_value=\'" ++ f ++ "\' WHERE meta_key=\'format\'");'),
                         {"user_version": 0, "format update": 1, "drop column": 0, "format insert": 0})
        self.assertEqual(format_writes('const s = "ALTER TABLE t DROP COLUMN c";'), {"user_version": 0, "format update": 0, "drop column": 1, "format insert": 0})
        self.assertEqual(format_writes('const s = "PRAGMA user_version=5";'), {"user_version": 1, "format update": 0, "drop column": 0, "format insert": 0})
        self.assertEqual(format_writes('\\\\PRAGMA user_version=5'), {"user_version": 1, "format update": 0, "drop column": 0, "format insert": 0})
        self.assertEqual(format_writes('\\\\ALTER TABLE t DROP COLUMN c'), {"user_version": 0, "format update": 0, "drop column": 1, "format insert": 0})
        self.assertEqual(format_writes('const s = "INSERT INTO store_meta(meta_key,meta_value) VALUES(\'format\',\'74\')";'),
                         {"user_version": 0, "format update": 0, "drop column": 0, "format insert": 1})
        self.assertEqual(format_writes('const s = "REPLACE INTO store_meta(meta_key,meta_value) VALUES(\'wire_version\',\'7\'),(\'format\',?1)";'),
                         {"user_version": 0, "format update": 0, "drop column": 0, "format insert": 1})
        self.assertEqual(format_writes("ALTER TABLE t DROP COLUMN c;", ".sql"), {"user_version": 0, "format update": 0, "drop column": 1, "format insert": 0})
        for source in ('// PRAGMA user_version=5', '// \\\\ALTER TABLE t DROP COLUMN c',
                       'const s = "PRAGMA user_version";', 'try pragmaInt(db, "PRAGMA user_version");',
                       'const s = "UPDATE store_meta SET meta_value=\'x\' WHERE meta_key=\'store_id\'";',
                       'const s = "INSERT INTO store_meta(meta_key,meta_value) VALUES(\'store_id\',\'x\')";'):
            self.assertEqual(sum(format_writes(source).values()), 0, source)
        self.assertEqual(format_writes("-- PRAGMA user_version=5\n", ".sql")["user_version"], 0)

    def test_a_planted_format_write_outside_the_owners_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            planted = root / "src/store/sqlite_tests/tool_set_migration.zig"
            planted.write_text(planted.read_text() + '\nconst planted = "PRAGMA user_version=5";\n')
            self.assertEqual(format_violations(root), [
                "src/store/sqlite_tests/tool_set_migration.zig writes the Store format (user_version) 2 times, 1 allowed; "
                + FORMAT_RULE])
            self.assertEqual(format_violations(root, FORMAT_WRITERS | {("src/store/sqlite_tests/tool_set_migration.zig", "user_version"): 2}), [])

    def test_a_planted_multiline_string_drop_column_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            (root / "src/store/tests/planted_multiline.zig").write_text(
                'const sql =\n    \\\\ALTER TABLE session DROP COLUMN obligation_since;\n;\n')
            self.assertEqual(format_violations(root), [
                f"src/store/tests/planted_multiline.zig writes the Store format (drop column) 1 times, 0 allowed; {FORMAT_RULE}"])

    def test_a_planted_sql_file_format_write_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            (root / "src/store/tests/planted.sql").write_text(
                "ALTER TABLE session DROP COLUMN obligation_since;\nPRAGMA user_version=5;\n")
            self.assertEqual(format_violations(root), [
                f"src/store/tests/planted.sql writes the Store format (drop column) 1 times, 0 allowed; {FORMAT_RULE}",
                f"src/store/tests/planted.sql writes the Store format (user_version) 1 times, 0 allowed; {FORMAT_RULE}"])

    def test_a_planted_multiline_sql_format_insert_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            (root / "src/store/tests/planted_insert.sql").write_text(
                "INSERT INTO store_meta(meta_key,meta_value)\nVALUES('format','74');\n")
            self.assertEqual(format_violations(root), [
                f"src/store/tests/planted_insert.sql writes the Store format (format insert) 1 times, 0 allowed; {FORMAT_RULE}"])

    def test_a_planted_multiline_sql_format_update_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            (root / "src/store/tests/planted_update.sql").write_text(
                "UPDATE store_meta SET meta_value='74'\nWHERE meta_key='format';\n")
            self.assertEqual(format_violations(root), [
                f"src/store/tests/planted_update.sql writes the Store format (format update) 1 times, 0 allowed; {FORMAT_RULE}"])

    def test_a_planted_drop_column_or_format_update_in_a_new_file_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            (root / "src/store/tests/planted.zig").write_text(
                'const a = "ALTER TABLE session DROP COLUMN obligation_since";\n'
                'const b = "UPDATE store_meta SET meta_value=\'9\' WHERE meta_key=\'format\'";\n')
            self.assertEqual(format_violations(root), [
                f"src/store/tests/planted.zig writes the Store format (drop column) 1 times, 0 allowed; {FORMAT_RULE}",
                f"src/store/tests/planted.zig writes the Store format (format update) 1 times, 0 allowed; {FORMAT_RULE}"])

    def test_the_owners_may_write_the_format(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / FORMAT_SOURCES, root / FORMAT_SOURCES)
            for owner in FORMAT_OWNERS:
                path = root / owner
                path.write_text(path.read_text() + '\nconst owner = "PRAGMA user_version=5; DROP COLUMN x";\n')
            self.assertEqual(format_violations(root), [])


class BaselineReferenceTest(unittest.TestCase):
    def test_baseline_references_match_the_shrink_only_ratchet(self):
        self.assertEqual(baseline_violations(), [])

    def test_scan_counts_fixture_uses_but_not_fields_comments_or_strings(self):
        self.assertEqual(baseline_references("store_testing.baseline_rows; try sqlite.exec(db, baseline_sqlite_ddl);"), 2)
        self.assertEqual(baseline_references("const start: Start = .{ .format = 74, .baseline_rows = false };"), 0)
        self.assertEqual(baseline_references("// store_testing.baseline_rows\nconst s = \"baseline_rows\";"), 0)
        self.assertEqual(baseline_references("const migration_baseline_rows = 1;"), 0)

    def test_a_planted_hand_built_store_fails_and_an_increase_is_named(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / "src", root / "src")
            planted = root / "src/store/tests/planted.zig"
            planted.parent.mkdir(parents=True, exist_ok=True)
            planted.write_text('test "planted" {\n    try sqlite.exec(db, store_testing.baseline_sqlite_ddl);\n}\n')
            self.assertEqual(baseline_violations(root), [
                f"src/store/tests/planted.zig names the baseline fixtures 1 times, 0 allowed; {BASELINE_RULE}"])
            listed = BASELINE_REFERENCES | {"src/store/tests/planted.zig": 1}
            self.assertEqual(baseline_violations(root, listed), [])
            grown = root / "src/store/sqlite_tests/tool_set_migration.zig"
            grown.write_text(grown.read_text() + "\nconst more = store_testing.baseline_rows;\n")
            self.assertEqual(baseline_violations(root, listed), [
                f"src/store/sqlite_tests/tool_set_migration.zig names the baseline fixtures 3 times, 2 allowed; {BASELINE_RULE}"])


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
