"""CI-78 and CI-79: statement table comparison and input fingerprint policy."""
import re
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

        def record(*fields):
            return b"\x1f".join(fields) + b"\x1c"

        def schema(name, value, inputs=b"inputs"):
            return record(b"schema", name, value, inputs)

        def statement_record(kind, text, signature=b"sig", sqlite=b"sqlite", parts=b"mysql", inputs=b"inputs"):
            return record(kind, text, signature, sqlite, parts, b"a0,n,", b"0", b"select_one", inputs)

        def fixture_record(text, parts=b"mysql", inputs=b"inputs"):
            return record(b"fixture", text, parts, b"a0,n,", inputs)

        values = {
            b"sqlite_objects": b"table\x1esqlite_object\x1eCREATE TABLE s",
            b"mysql_objects": b"table\x1emysql_object\x1eCREATE TABLE m",
            b"sqlite_ddl": b"sqlite ddl", b"mysql_ddl": b"mysql ddl",
            b"mysql_migrations": b"first\x1dsecond\x1d", b"digest": b"42",
        }
        schema_records = [schema(name, value) for name, value in values.items()]
        read = statement_record(b"read", b"z_statement")
        write = statement_record(b"write", b"shared")
        fixture_a = fixture_record(b"shared")
        fixture_z = fixture_record(b"z_fixture", b'a\x1e\\b')
        original = [read, write, fixture_a, fixture_z, *schema_records]
        reference = render(original)
        text, statement_count, fixture_count = reference
        self.assertEqual((statement_count, fixture_count), (2, 2))
        entries = text.split("pub const entries = struct {", 1)[1].split("\n};", 1)[0]
        fixtures = text.split("pub const fixtures = struct {", 1)[1].split("\n};", 1)[0]
        self.assertEqual(re.findall(r'pub const @"([^"]+)"', entries), ["shared", "z_statement"])
        self.assertEqual(re.findall(r'pub const @"([^"]+)"', fixtures), ["shared", "z_fixture"])
        self.assertIn("sqlite ddl", text.split("pub const schema = struct {", 1)[1])
        self.assertIn("mysql ddl", text.split("pub const schema = struct {", 1)[1])

        split = [schema(b"mysql_migrations_2", b""), schema(b"mysql_migrations_0", b"first"),
                 schema(b"mysql_migrations_1", b"second")]
        without_migrations = [item for item in original if item != schema(b"mysql_migrations", values[b"mysql_migrations"])]
        accepted = (
            ("records in reverse order", list(reversed(original))),
            ("duplicate records of every kind", original + [read, write, fixture_a, *schema_records]),
            ("migration fragments in arbitrary order", without_migrations + split),
            ("combined and fragmented migrations agree", original + split),
        )
        for name, records in accepted:
            with self.subTest(name):
                self.assertEqual(render(records), reference)

        variants = original + [statement_record(b"read", b"z_statement", b"other", b"other sqlite")]
        self.assertEqual(render(variants)[1], statement_count)
        self.assertEqual(render(variants + variants[-1:]), render(variants))
        rejected = [
            ("unknown schema value", original + [schema(b"unexpected", b"value")]),
            ("conflicting statement rendering", original + [statement_record(b"read", b"z_statement", parts=b"different")]),
            ("conflicting SQLite variant", original + [statement_record(b"read", b"z_statement", sqlite=b"different")]),
            ("conflicting fixture rendering", original + [fixture_record(b"shared", b"different")]),
            ("conflicting migration fragment", without_migrations + split + [schema(b"mysql_migrations_0", b"different")]),
            ("conflicting combined and fragmented migrations", original + [schema(b"mysql_migrations_0", b"different"),
                                                                            schema(b"mysql_migrations_1", b"")]),
            ("noncanonical migration index", without_migrations + split + [schema(b"mysql_migrations_00", b"first")]),
            ("unknown record kind", original + [record(b"unknown", b"inputs")]),
            ("unterminated record", original + [read[:-1]]),
        ]
        rejected.extend((f"missing schema value {name!r}", [item for item in original if item != schema(name, value)])
                        for name, value in values.items())
        rejected.extend((f"conflicting schema value {name!r}", original + [schema(name, b"different")])
                        for name in values)
        rejected.extend((f"missing migration fragment {index}", without_migrations + [item for i, item in enumerate(split) if i != index])
                        for index in range(len(split)))
        rejected.append(("missing multiple final migration fragments", without_migrations + [split[1]]))
        rejected.extend((f"different inputs for {kind}", original + [record_with_other_inputs]) for kind, record_with_other_inputs in (
            ("read", statement_record(b"read", b"z_statement", inputs=b"other")),
            ("write", statement_record(b"write", b"shared", inputs=b"other")),
            ("fixture", fixture_record(b"shared", inputs=b"other")),
            ("schema", schema(b"digest", b"42", inputs=b"other")),
        ))
        for name, records in rejected:
            with self.subTest(name), self.assertRaises(ValueError):
                render(records)

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


if __name__ == "__main__":
    unittest.main()
