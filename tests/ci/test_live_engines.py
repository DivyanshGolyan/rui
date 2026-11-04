import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import host_process
import live_engines
import live_engine_step

ENGINE_NAME = re.compile(r"\bRUI_TEST_(?:MYSQL|PG)_[A-Z_]+|\bRUI_TEST_REQUIRE_ENGINES\b")


class LauncherTest(unittest.TestCase):
    def test_check_launches_the_unit_binary_through_the_fixture_boundary(self):
        # `check` runs the unit binary here, so what enter() keeps is what
        # the live dialect check sees (Codex P1 on #873).
        launch = [line for line in (ROOT / "tests/integration/check.sh").read_text().splitlines()
                  if '"$test_binary"' in line]
        self.assertEqual(len(launch), 1, launch)
        self.assertIn('"$directory/host_process.py" exec', launch[0])

    def test_the_fixture_boundary_keeps_every_live_engine_variable(self):
        environ = {name: f"value of {name}" for name in live_engines.VARIABLES}
        with patch.object(host_process.os, "geteuid", return_value=1000), \
                patch.dict(os.environ, dict(environ, RUI_UNRELATED="dropped"), clear=True):
            host_process.enter()
            kept = dict(os.environ)
        self.assertEqual({name: kept.get(name) for name in environ}, environ)
        self.assertNotIn("RUI_UNRELATED", kept)


class NamesTest(unittest.TestCase):
    def test_every_engine_variable_the_zig_source_reads_is_listed(self):
        read = {name for path in (ROOT / "src").rglob("*.zig") for name in ENGINE_NAME.findall(path.read_text())}
        self.assertIn(live_engines.MYSQL_RECORD, read)
        self.assertEqual(read - set(live_engines.VARIABLES), set())

    def test_every_engine_variable_the_workflow_spells_is_listed(self):
        spelled = set(ENGINE_NAME.findall((ROOT / ".github/workflows/check.yml").read_text()))
        self.assertEqual(spelled - set(live_engines.VARIABLES), set())


class ExportTest(unittest.TestCase):
    def test_export_appends_the_engine_and_names_each_value(self):
        lines = live_engines.export_lines("postgres", ["5432", "secret", "/ca.crt"], {live_engines.REQUIRE: "mysql"})
        self.assertEqual(lines, [
            "RUI_TEST_REQUIRE_ENGINES=mysql,postgres", "RUI_TEST_PG_PORT=5432",
            "RUI_TEST_PG_PASSWORD=secret", "RUI_TEST_PG_CA_FILE=/ca.crt",
        ])
        self.assertEqual(live_engines.export_lines("mysql", ["s", "p", "r"], {})[0], "RUI_TEST_REQUIRE_ENGINES=mysql")
        with self.assertRaises(ValueError):
            live_engines.export_lines("mysql", ["s", "p"], {})

    def test_the_step_appends_to_github_env(self):
        with tempfile.TemporaryDirectory() as directory:
            github_env = Path(directory, "env")
            github_env.write_text("EARLIER=1\n")
            environ = {"GITHUB_ENV": str(github_env), live_engines.REQUIRE: "postgres"}
            self.assertEqual(live_engine_step.main(["export", "mysql", "/s.sock", "pw", "/record"], environ), 0)
            self.assertEqual(github_env.read_text().splitlines(), [
                "EARLIER=1", "RUI_TEST_REQUIRE_ENGINES=postgres,mysql", "RUI_TEST_MYSQL_SOCKET=/s.sock",
                "RUI_TEST_MYSQL_ROOT_PASSWORD=pw", "RUI_TEST_MYSQL_RECORD=/record",
            ])


class VerifyTest(unittest.TestCase):
    def verify(self, record):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "record")
            if record is not None:
                path.write_text(record)
            with patch("builtins.print"):
                return live_engines.verify_mysql({live_engines.MYSQL_RECORD: str(path)})

    def test_a_record_with_prepares_passes(self):
        self.assertIsNone(self.verify("ddl=40 ddl_refused=0 prepares=812 prepare_refused=0 probes=4 migrations=1\n"))

    def test_a_missing_record_fails(self):
        self.assertIn("missing", self.verify(None))

    def test_a_record_without_prepares_fails(self):
        self.assertIn("no PREPARE", self.verify("ddl=40 ddl_refused=0 prepares=0 prepare_refused=0 probes=4 migrations=1\n"))

    def test_a_record_without_a_passed_migration_test_fails(self):
        self.assertIn("migration", self.verify("ddl=40 ddl_refused=0 prepares=812 prepare_refused=0 probes=4 migrations=0\n"))

    def test_an_unset_record_variable_fails(self):
        self.assertIn("not set", live_engines.verify_mysql({}))


if __name__ == "__main__":
    unittest.main()
