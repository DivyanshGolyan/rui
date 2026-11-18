"""CI-78 and CI-79: statement table comparison and input fingerprint policy."""
import tempfile
import unittest
from pathlib import Path

from rsql_table import fingerprint_error, render, table_error

PRODUCT = 'pub const rsql_table_inputs = [_][]const u8{ "a.zig", "b.zig" };\n'
# sha256(b"a.zig\0one\0b.zig\0two\0")[:16], written out rather than computed by the code under test.
CURRENT = "d1311121114a1397a0efc2efd738bfd9"


class RsqlTableTest(unittest.TestCase):
    def test_ci_78_statement_table_comparison(self):
        def table(inputs, statements, fixtures):
            return (f'pub const inputs = "{inputs}";\n'
                    'pub const entries = struct {\n' + statements + '};\n'
                    + ('pub const fixtures = struct {\n' + fixtures + '};\n' if fixtures
                       else 'pub const fixtures = struct {};\n'))

        statement = '    pub const @"select": rsql.TableEntry = .{};\n'
        extra_statement = '    pub const @"insert": rsql.TableEntry = .{};\n'
        fixture = '    pub const @"fixture": rsql.Template = .{ .parts = &.{ "a" } };\n'
        changed_fixture = '    pub const @"fixture": rsql.Template = .{ .parts = &.{ "b" } };\n'
        other_fixture = '    pub const @"other": rsql.Template = .{};\n'
        base = table("abc", statement, fixture)
        error = ("src/store/rsql_table.zig differs from what the comptime path renders; "
                 "run `python3 tests/ci/rsql_table.py generate` and commit it")
        cases = (
            ("identical", base, base, (None, 0, 0)),
            ("missing fixture", table("abc", statement, ""), base, (None, 1, 0)),
            ("unused fixture", table("abc", statement, fixture + other_fixture), base, (None, 0, 1)),
            ("different fixture", table("abc", statement, changed_fixture), base, (error, 0, 0)),
            ("missing statement", table("abc", "", fixture), base, (error, 0, 0)),
            ("extra statement", table("abc", statement + extra_statement, fixture), base, (error, 0, 0)),
            ("different inputs", table("def", statement, fixture), base, (error, 0, 0)),
            ("different schema", base + "schema value one\n", base + "schema value two\n", (error, 0, 0)),
            ("escaped fixture name", table("abc", statement, '    pub const @"x\\"y": rsql.Template = .{};\n'),
             table("abc", statement, '    pub const @"x\\"y": rsql.Template = .{};\n'), (None, 0, 0)),
        )
        for name, checked_in, rendered, expected in cases:
            with self.subTest(name):
                self.assertEqual(table_error(checked_in, rendered), expected)

    def tree(self, table_inputs, a="one", b="two", unlisted="x"):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        root = Path(scratch.name)
        (root / "build").mkdir()
        (root / "src/store").mkdir(parents=True)
        (root / "build/product.zig").write_text(PRODUCT)
        (root / "a.zig").write_text(a)
        (root / "b.zig").write_text(b)
        (root / "c.zig").write_text(unlisted)
        line = "" if table_inputs is None else f'pub const inputs = "{table_inputs}";\n'
        (root / "src/store/rsql_table.zig").write_text('const rsql = @import("rsql.zig");\n\n' + line + "pub const entries = struct {};\n")
        return root

    def test_fingerprint_names_every_input_and_policy_fails_a_stale_table(self):
        cases = (
            ("table generated from these inputs", dict(table_inputs=CURRENT), False),
            ("a file outside the list changed", dict(table_inputs=CURRENT, unlisted="y"), False),
            ("the first listed file changed", dict(table_inputs=CURRENT, a="one!"), True),
            ("the last listed file changed", dict(table_inputs=CURRENT, b="two!"), True),
            ("the empty table of a fresh tree", dict(table_inputs=""), True),
            ("a table with no inputs line", dict(table_inputs=None), True),
        )
        for name, tree, stale in cases:
            with self.subTest(name):
                error = fingerprint_error(self.tree(**tree))
                if stale:
                    self.assertIn("python3 tests/ci/rsql_table.py generate", error)
                else:
                    self.assertIsNone(error)


class SchemaRecordTest(unittest.TestCase):
    def record(self, name, value):
        return b"schema\x1f" + name + b"\x1f" + value + b"\x1finputs\x1c"

    def test_split_migration_records_reassemble_in_order(self):
        common = [self.record(name, value) for name, value in (
            (b"sqlite_objects", b""), (b"mysql_objects", b""),
            (b"sqlite_ddl", b""), (b"mysql_ddl", b""), (b"digest", b"0"),
        )]
        combined = common + [self.record(b"mysql_migrations", b"first\x1dsecond\x1d")]
        split = common + [self.record(b"mysql_migrations_2", b""),
                          self.record(b"mysql_migrations_0", b"first"),
                          self.record(b"mysql_migrations_1", b"second")]
        self.assertEqual(render(combined), render(split))
        with self.assertRaises(ValueError):
            render(split[:-1])
        with self.assertRaises(ValueError):
            render(split + [self.record(b"mysql_migrations_0", b"different")])
        for missing in (split[:-3] + split[-2:], split[:-2], split[:-3] + [split[-2]]):
            with self.assertRaises(ValueError):
                render(missing)
        with self.assertRaises(ValueError):
            render(split + [self.record(b"mysql_migrations_00", b"different")])

    def test_fixture_records_coexist_with_schema_and_reject_conflicts(self):
        schema = [self.record(name, value) for name, value in (
            (b"sqlite_objects", b""), (b"mysql_objects", b""),
            (b"sqlite_ddl", b""), (b"mysql_ddl", b""), (b"digest", b"0"),
            (b"mysql_migrations", b""),
        )]
        first = b'fixture\x1ffirst"\x1fa\x1e\\b\x1fa0,n,\x1finputs\x1c'
        second = b"fixture\x1fsecond\x1fother\x1f\x1finputs\x1c"
        self.assertEqual(render(schema + [first, second]), render(schema + [second, first, first]))
        self.assertEqual(render(schema + [first, second])[2], 2)
        with self.assertRaises(ValueError):
            render(schema + [first, first.replace(b"a0,n,", b"a1,")])
        with self.assertRaises(ValueError):
            render(schema + [first, second.replace(b"inputs", b"other")])


if __name__ == "__main__":
    unittest.main()
