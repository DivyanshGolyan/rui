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
            for add in (f"ALTER TABLE {table} ADD COLUMN extra BIGINT", f"alter table {table} add column extra int"):
                self.assertEqual(side_table_violations({7: step(7, ["SELECT 1"], [add])}), [(7, "mysql", table)])
            rebuild = [f"ALTER TABLE {table} RENAME TO {table}_7", f"CREATE TABLE {table}(\n a BIGINT PRIMARY KEY,\n b TEXT,\n extra BIGINT CHECK(extra>0)\n)",
                       f"INSERT INTO {table}(a,b) SELECT a,b FROM {table}_7", f"DROP TABLE {table}_7"]
            self.assertEqual(side_table_violations({7: step(7, rebuild, ["SELECT 1"])}), [(7, "sqlite", table)])

    def test_a_rebuild_that_keeps_the_columns_passes(self):
        table = SIDE_TABLE_ONLY[0]
        rebuild = [f"ALTER TABLE {table} RENAME TO {table}_7", f"CREATE TABLE {table}(\n a BIGINT PRIMARY KEY,\n b TEXT,\n CHECK(a>0)\n)",
                   f"INSERT INTO {table}(a,b) SELECT a,b FROM {table}_7", f"DROP TABLE {table}_7"]
        self.assertEqual(side_table_violations({7: step(7, rebuild, [])}), [])

    def test_a_mysql_table_built_aside_and_renamed_over_a_busy_table_is_refused(self):
        mysql = ["CREATE TABLE core_command_new(a BIGINT)", "RENAME TABLE core_command TO core_command_old"]
        self.assertEqual(side_table_violations({7: step(7, ["SELECT 1"], mysql)}), [(7, "mysql", "core_command")])

    def test_a_side_table_or_another_table_passes(self):
        steps = {7: step(7, ["CREATE TABLE core_command_note(id BIGINT)", "ALTER TABLE session ADD COLUMN x BIGINT",
                             "ALTER TABLE core_command ADD INDEX i(a)"], ["ALTER TABLE core_command DROP COLUMN a"])}
        self.assertEqual(side_table_violations(steps), [])

    def test_only_what_this_branch_wrote_is_checked(self):
        old = step(7, ["ALTER TABLE tool_record RENAME TO x"], ["ALTER TABLE tool_record ADD COLUMN x BIGINT"])
        base = {7: old}
        head = {**base, 8: step(8, ["CREATE TABLE tool_note(id BIGINT)"], [])}
        self.assertEqual(list(new_steps(base, head)), [8])
        self.assertEqual(side_table_violations(new_steps(base, head), base), [])

    def test_an_edit_of_an_unreleased_step_is_checked_for_the_statements_it_adds(self):
        old = step(7, ["SELECT 1"], ["ALTER TABLE session ADD COLUMN x BIGINT"])
        edited = step(7, ["SELECT 1"], ["ALTER TABLE session ADD COLUMN x BIGINT", "ALTER TABLE tool_record ADD COLUMN y BIGINT"])
        changed = new_steps({7: old}, {7: edited})
        self.assertEqual(side_table_violations(changed, {7: old}), [(7, "mysql", "tool_record")])
        self.assertEqual(side_table_violations({7: old}, {7: old}), [])

    def test_the_message_names_the_fix(self):
        self.assertIn("CREATE TABLE", side_table_message(7, "mysql", "tool_record"))

    def test_a_table_that_gets_a_column_and_a_check_key_or_modify_is_a_copy(self):
        together = ["ALTER TABLE t ADD COLUMN a BIGINT, ADD CHECK(a IS NULL OR a>0)"]
        apart = ["ALTER TABLE t ADD COLUMN b BIGINT", "ALTER TABLE t MODIFY COLUMN b BIGINT NOT NULL, ADD CHECK(b>0)"]
        keyed = ["ALTER TABLE t ADD COLUMN c BIGINT", "ALTER TABLE t ADD UNIQUE(c)"]
        instant = ["ALTER TABLE t ADD COLUMN d BIGINT", "ALTER TABLE u ADD CHECK(d>0)", "CREATE TABLE v(id BIGINT)"]
        self.assertEqual([copy_forcing(step(1, [], texts)) for texts in (together, apart, keyed, instant)], [1, 1, 1, 0])

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
