from pathlib import Path
import unittest

from release_numbers import SCHEMA, migration_steps
from release_numbers import main_base
from schema_rules import (SIDE_TABLE_ONLY, check, copy_forcing, new_steps, rebuilds, scoreboard, side_table_message,
                          side_table_violations, statements)

ROOT = Path(__file__).resolve().parents[2]


def step(start, sqlite, mysql):
    quote = lambda texts: ",".join('"' + text + '"' for text in texts)
    return f"{{.from={start},.sqlite=&.{{{quote(sqlite)}}},.mysql=&.{{{quote(mysql)}}},}}"


def source(version, steps):
    return (f"pub const schema_version: u32 = {version};\n\npub const migrations = [_]Migration{{\n"
            + "\n".join(steps) + "\n};\n")


class SchemaRulesTest(unittest.TestCase):
    def test_statements_split_by_dialect(self):
        text = step(5, ["A", "B"], ["C"])
        self.assertEqual(statements(text, "sqlite"), ["A", "B"])
        self.assertEqual(statements(text, "mysql"), ["C"])

    def test_a_column_on_each_busy_table_is_refused_in_either_dialect(self):
        for table in SIDE_TABLE_ONLY:
            add = f"ALTER TABLE {table} ADD COLUMN extra BIGINT"
            self.assertEqual(side_table_violations({7: step(7, [add], ["SELECT 1"])}), [(7, "sqlite", table)])
            self.assertEqual(side_table_violations({7: step(7, ["SELECT 1"], [add])}), [(7, "mysql", table)])

    def test_a_side_table_or_another_table_passes(self):
        steps = {7: step(7, ["CREATE TABLE core_command_note(id BIGINT)", "ALTER TABLE session ADD COLUMN x BIGINT",
                             "ALTER TABLE core_command ADD INDEX i(a)"], ["ALTER TABLE core_command DROP COLUMN a"])}
        self.assertEqual(side_table_violations(steps), [])

    def test_only_the_steps_a_branch_adds_are_checked(self):
        base = {7: step(7, ["ALTER TABLE tool_record ADD COLUMN x BIGINT"], [])}
        head = {**base, 8: step(8, ["CREATE TABLE tool_note(id BIGINT)"], [])}
        self.assertEqual(list(new_steps(base, head)), [8])
        self.assertEqual(side_table_violations(new_steps(base, head)), [])

    def test_the_message_names_the_fix(self):
        self.assertIn("CREATE TABLE", side_table_message(7, "mysql", "tool_record"))

    def test_a_copy_forcing_add_is_an_added_column_with_a_check_or_a_foreign_key(self):
        copy = ["ALTER TABLE t ADD COLUMN a BIGINT, ADD CHECK(a IS NULL OR a>0)",
                "ALTER TABLE t ADD COLUMN b BIGINT, ADD FOREIGN KEY(b) REFERENCES u(id)",
                "ALTER TABLE t ADD COLUMN c BIGINT CHECK(c>0)"]
        instant = ["ALTER TABLE t ADD COLUMN d BIGINT", "ALTER TABLE t ADD CHECK(d>0)", "CREATE TABLE u(id BIGINT)"]
        self.assertEqual(copy_forcing(step(1, [], copy)), 3)
        self.assertEqual(copy_forcing(step(1, [], instant)), 0)

    def test_a_rebuild_is_a_table_renamed_aside(self):
        text = step(1, ["ALTER TABLE a RENAME TO a_old", "CREATE TABLE a(x BIGINT)", "DROP TABLE a_old",
                        "ALTER TABLE b ADD COLUMN y BIGINT"], [])
        self.assertEqual(rebuilds(text), 1)

    def test_the_scoreboard_counts_each_release_by_its_steps(self):
        old = source(10, [step(9, ["X"], ["Y"])])
        mid = source(12, [step(9, ["X"], ["Y"]),
                          step(10, ["ALTER TABLE a RENAME TO a_old"], ["ALTER TABLE a ADD COLUMN c BIGINT, ADD CHECK(c>0)"]),
                          step(11, ["Z"], ["ALTER TABLE a ADD COLUMN d BIGINT"])])
        self.assertEqual(scoreboard([("v0.1.0", old), ("v0.2.0", mid)]),
                         [{"release": "v0.2.0", "formats": 2, "steps": 2, "sqlite_rebuilds": 1,
                           "mysql_statements": 2, "mysql_copies": 1}])

    def test_every_current_step_reads_back_its_sqlite_statements(self):
        steps = migration_steps((ROOT / SCHEMA).read_text())
        self.assertTrue(steps)
        for start, text in steps.items():
            self.assertTrue(statements(text, "sqlite"), f"step {start} has no SQLite statement")

    def test_the_steps_this_branch_adds_pass_the_rules(self):
        if main_base(ROOT) is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        self.assertEqual(check(ROOT), [])


if __name__ == "__main__":
    unittest.main()
