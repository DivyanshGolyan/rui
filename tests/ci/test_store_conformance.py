from pathlib import Path
import unittest

import re

from store_conformance import ROOT, SQLITE_TESTS, TESTS, check, fixture_verdict, main, not_portable, rewrite, table

PRE_SPLIT = '''//! The Store's tests.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const store_testing = @import("testing.zig");
const c = sqlite.c;

fn testingStore(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io) !void {
    return storage.open(io, "x", "y");
}

fn queryU64(database: *c.sqlite3, sql: [:0]const u8) !u64 {
    _ = c.sqlite3_step(database, sql);
    return 0;
}

/// Shared by both kinds of test.
fn seed(storage: *Store) !void {
    _ = try storage.configure();
}

test "a portable test" {
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    try seed(&storage);
    try std.testing.expectEqual(1, try queryU64(storage.database, "SELECT count(*) FROM turn"));
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    try sqlite.exec(storage.database, "DELETE FROM turn");
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
    var sql: [64]u8 = undefined;
    try sqlite.exec(storage.database, try std.fmt.bufPrintSentinel(&sql, "UPDATE turn SET at={d} WHERE ref='{s}'", .{ 7, ref }, 0));
}

test "a SQLite test" {
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    try seed(&storage);
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    _ = storage.configure();
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
}

test "no Store" {
    try std.testing.expect(true);
}
'''


class StoreConformanceTest(unittest.TestCase):
    def test_fixture_verdicts_agree_with_the_zig_check(self):
        # testing.zig's test checks fixtureTextError on these same cases.
        source = (ROOT / "src/store/testing.zig").read_text()
        cases = source[source.index("pub const fixture_text_cases"):]
        cases = re.findall(r'\.text = "((?:\\.|[^"\\])*)", \.refused = (true|false)', cases[:cases.index("};")])
        self.assertGreater(len(cases), 10)
        for text, refused in cases:
            with self.subTest(text=text):
                self.assertEqual(fixture_verdict(text.replace('\\"', '"')), refused == "true")

    def test_a_refused_fixture_text_stays_raw(self):
        self.assertTrue(not_portable('"SELECT name FROM " ++ "pragma_table_info(\'turn\')"'))
        self.assertFalse(not_portable('"UPDATE turn SET note=\'PRAGMA\'"'))
        source = PRE_SPLIT.replace('"SELECT count(*) FROM turn"', '"SELECT count(*) FROM sqlite_schema"')
        _, moved, stats = rewrite(source)
        self.assertEqual(stats["moved_tests"], 2)
        self.assertIn('queryU64(storage.database, "SELECT count(*) FROM sqlite_schema")', moved)

    def test_table_names_each_test_and_its_reason(self):
        self.assertEqual(table(PRE_SPLIT), [
            ("a portable test", "tests.zig", "every engine"),
            ("a SQLite test", "sqlite_tests.zig", "a SQLite mechanism"),
            ("no Store", "tests.zig", "opens no Store"),
        ])
        counted = PRE_SPLIT.replace('test "no Store" {\n    try std.testing.expect(true);',
                                    'test "no Store" {\n    try std.testing.expect(storage.testing_content_work.read.load(.monotonic) == 0);')
        self.assertEqual(table(counted)[2], ("no Store", "sqlite_tests.zig", "a SQLite mechanism"))

    def test_repository_tests_zig_names_no_sqlite_mechanism(self):
        self.assertIsNone(check((ROOT / TESTS).read_text()))

    def test_check_refuses_each_sqlite_name_in_code(self):
        for line in ("x(storage.database);", "try sqlite.exec(db, s);", "_ = c.sqlite3_step(s);",
                     "if (r == c.SQLITE_ROW) {}", "try expect(2, a.passes);", "storage.statements.count();",
                     "try storage.open(std.testing.io, database, root);", "storage.openWithOptions(io, d, r, .{});"):
            with self.subTest(line=line):
                self.assertIsNotNone(check(f"test \"t\" {{\n    {line}\n}}\n"))
        self.assertIsNotNone(check('const sqlite = @import("sqlite.zig");\n'))

    def test_check_ignores_strings_and_comments(self):
        self.assertIsNone(check('// sqlite.exec(storage.database)\nconst s = @embedFile("sqlite.zig");\n'
                                'const t = "c.sqlite3_step";\n'))

    def test_rewrite_moves_sqlite_tests_and_wraps_the_rest(self):
        tests, moved, stats = rewrite(PRE_SPLIT)
        self.assertEqual(stats, {"kept_tests": 2, "conformance": 1, "moved_tests": 1})
        self.assertIsNone(check(tests))
        self.assertIn('''test "a portable test" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try seed(&storage);
            try std.testing.expectEqual(1, try store_testing.queryU64(&storage, "SELECT count(*) FROM turn", .{}));
            try store_testing.withoutForeignKeys(&storage, "DELETE FROM turn", .{});
            try store_testing.exec(&storage, "UPDATE turn SET at=?1 WHERE ref=?2", .{7, ref});
        }
    }.run);
}''', tests)
        self.assertIn('test "no Store" {\n    try std.testing.expect(true);\n}', tests)
        self.assertIn("pub fn seed(", tests)
        self.assertNotIn("fn queryU64", tests)
        self.assertNotIn("fn testingStore", tests)
        self.assertIn("const seed = tests.seed;", moved)
        self.assertIn('test "a SQLite test" {\n    var storage: Store = undefined;\n    try testingStore(&storage', moved)
        self.assertIn("fn testingStore(", moved)
        self.assertNotIn('test "a portable test"', moved)

    def test_a_foreign_keys_run_with_an_entry_point_stays_raw(self):
        _, moved, _ = rewrite(PRE_SPLIT)
        self.assertIn('try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");\n    _ = storage.configure();', moved)

    def test_a_placeholder_inside_a_sql_string_stays_raw(self):
        source = PRE_SPLIT.replace("UPDATE turn SET at={d} WHERE ref='{s}'", "UPDATE turn SET key='k-{d}'").replace(
            ".{ 7, ref }", ".{7}")
        tests, moved, stats = rewrite(source)
        self.assertEqual(stats["moved_tests"], 2)
        self.assertIn("'k-{d}'", moved)

    def test_rewrite_of_its_own_output_changes_nothing(self):
        tests, _, _ = rewrite(PRE_SPLIT)
        again, moved, stats = rewrite(tests)
        self.assertEqual(again.rstrip("\n"), tests.rstrip("\n"))
        self.assertEqual(stats["moved_tests"], 0)

    def test_rewrite_refuses_split_input_and_writes_nothing(self):
        before = [(ROOT / name).read_bytes() for name in (TESTS, SQLITE_TESTS)]
        self.assertEqual(main(["store_conformance.py", "rewrite"]), 2)
        self.assertEqual(main(["store_conformance.py", "rewrite", str(ROOT / TESTS)]), 1)
        self.assertEqual([(ROOT / name).read_bytes() for name in (TESTS, SQLITE_TESTS)], before)


if __name__ == "__main__":
    unittest.main()
