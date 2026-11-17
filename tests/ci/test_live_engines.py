import os
import fcntl
from pathlib import Path
import re
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import host_process
import live_engines
import live_engine_step
import mysql_server

ENGINE_NAME = re.compile(r"\bRUI_TEST_(?:MYSQL|PG)_[A-Z_]+|\bRUI_TEST_REQUIRE_ENGINES\b")


class ProxyConfigTest(unittest.TestCase):
    def test_the_proxy_fronts_the_supplied_socket_whatever_its_name(self):
        for basename in ("mysqld.sock", "other.sock"):
            config = mysql_server.proxy_config(f"/run/db/{basename}", "px", "pw")
            self.assertIn(f'address="/var/run/mysqld/{basename}"', config)
            self.assertIn('interfaces="/var/run/mysqld/px.sock"', config)
            self.assertEqual(mysql_server.proxy_socket_path(f"/run/db/{basename}", "px"), "/run/db/px.sock")

    def test_a_password_is_one_quoted_configuration_string(self):
        for password, rendered in (("0123abcd", '"0123abcd"'), ('a"b', '"a\\"b"'), ("a\\b", '"a\\\\b"')):
            self.assertIn(f"password={rendered},", mysql_server.proxy_config("/run/db/mysqld.sock", "px", password))


class LauncherTest(unittest.TestCase):
    def test_check_launches_the_unit_binary_through_the_fixture_boundary(self):
        launch = [line for line in (ROOT / "tests/integration/check.sh").read_text().splitlines()
                  if 'run_case execution native ' in line]
        self.assertEqual(len(launch), 1, launch)
        self.assertIn('store_shards.py" "$unit_mode" "$test_binary" --timeout 1200', launch[0])
        self.assertIn('"$directory/host_process.py" exec', launch[0])

    def test_the_fixture_boundary_keeps_every_live_engine_variable(self):
        environ = {name: f"value of {name}" for name in live_engines.VARIABLES}
        with patch.object(host_process.os, "geteuid", return_value=1000), \
                patch.dict(os.environ, dict(environ, RUI_UNRELATED="dropped"), clear=True):
            host_process.enter()
            kept = dict(os.environ)
        self.assertEqual({name: kept.get(name) for name in environ}, environ)
        self.assertNotIn("RUI_UNRELATED", kept)


class LeaseTest(unittest.TestCase):
    def test_exclusive_phase_blocks_other_process_descriptions_until_downgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            environ = {live_engines.MYSQL_SOCKET: str(Path(directory) / "server.sock")}
            with live_engines.mysql_lease(environ, exclusive=True) as writer:
                # Independent open descriptions see the same server lock, even
                # through a symlink spelling of its socket directory.
                import hashlib
                key = hashlib.sha256(os.path.realpath(environ[live_engines.MYSQL_SOCKET]).encode()).hexdigest()
                path = Path(tempfile.gettempdir()) / f"rui-unit-mysql-{key}.lock"
                with path.open() as other:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(other, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    fcntl.flock(writer, fcntl.LOCK_SH)
                    fcntl.flock(other, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with live_engines.mysql_lease(environ, exclusive=True, timeout=.1):
                pass

    def test_competing_writer_cannot_enter_a_nonatomic_downgrade_gap(self):
        class ProbeComplete(Exception):
            pass
        with tempfile.TemporaryDirectory() as directory:
            environ = {live_engines.MYSQL_SOCKET: str(Path(directory) / "server.sock")}
            flock = fcntl.flock
            with live_engines.mysql_lease(environ, exclusive=True) as writer:
                def probe(observe, description, **kwargs):
                    # An independent open description represents the other
                    # cohort. Observe its real nonblocking acquisition once.
                    self.assertFalse(observe(), "competing writer entered the non-atomic downgrade gap")
                    raise ProbeComplete
                def convert(descriptor, operation):
                    if descriptor == writer and operation == fcntl.LOCK_SH:
                        # flock permits this unlock/relock implementation. The
                        # first ordinary test is active during the whole gap.
                        flock(writer, fcntl.LOCK_UN)
                        try:
                            with patch.object(host_process, "wait_for", side_effect=probe):
                                with self.assertRaises(ProbeComplete):
                                    with live_engines.mysql_lease(environ, exclusive=True):
                                        self.fail("competing writer reached its exclusive phase")
                        finally:
                            flock(writer, fcntl.LOCK_SH)
                    else:
                        flock(descriptor, operation)
                with patch.object(fcntl, "flock", side_effect=convert):
                    fcntl.flock(writer, fcntl.LOCK_SH)
                # The writer turn protects only competing exclusive cohorts;
                # ordinary readers still overlap after the downgrade.
                with live_engines.mysql_lease(environ) as reader:
                    self.assertNotEqual(reader, writer)
            with live_engines.mysql_lease(environ, exclusive=True):
                pass

    def test_both_acquisitions_share_one_deadline_and_close_in_reverse_order(self):
        with tempfile.TemporaryDirectory() as directory:
            environ = {live_engines.MYSQL_SOCKET: str(Path(directory) / "server.sock")}
            opened, closed, deadlines = [], [], []
            open_descriptor, close_descriptor = os.open, os.close
            clock = [10.0]
            def record_open(*args, **kwargs):
                descriptor = open_descriptor(*args, **kwargs)
                opened.append(descriptor)
                return descriptor
            def record_close(descriptor):
                closed.append(descriptor)
                close_descriptor(descriptor)
            def acquire(observe, description, *, deadline, **kwargs):
                deadlines.append(deadline)
                self.assertTrue(observe())
                clock[0] += 2
            with patch.object(live_engines.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(host_process, "wait_for", side_effect=acquire), \
                    patch.object(os, "open", side_effect=record_open), \
                    patch.object(os, "close", side_effect=record_close):
                with live_engines.mysql_lease(environ, exclusive=True, timeout=5) as descriptor:
                    self.assertEqual(descriptor, opened[-1])
            self.assertEqual(deadlines, [15.0, 15.0])
            self.assertEqual(len(opened), 2)
            self.assertEqual(closed, list(reversed(opened)))

    def test_cancellation_at_either_acquisition_closes_all_descriptors(self):
        for interrupted_acquisition in (1, 2):
            with self.subTest(acquisition=interrupted_acquisition), tempfile.TemporaryDirectory() as directory:
                environ = {live_engines.MYSQL_SOCKET: str(Path(directory) / "server.sock")}
                stop = threading.Event()
                calls = 0
                open_descriptor = os.open
                opened = []
                def record_open(*args, **kwargs):
                    descriptor = open_descriptor(*args, **kwargs)
                    opened.append(descriptor)
                    return descriptor
                def acquire(observe, description, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == interrupted_acquisition:
                        stop.set()
                    self.assertTrue(observe())
                with patch.object(host_process, "wait_for", side_effect=acquire), \
                        patch.object(os, "open", side_effect=record_open):
                    with self.assertRaises(InterruptedError):
                        with live_engines.mysql_lease(environ, exclusive=True, stop=stop):
                            self.fail("cancelled MySQL lease was yielded")
                self.assertEqual(len(opened), interrupted_acquisition)
                for descriptor in opened:
                    with self.assertRaises(OSError):
                        os.fstat(descriptor)
                # A cancelled owner leaves neither lease held.
                with live_engines.mysql_lease(environ, exclusive=True, timeout=.1):
                    pass

    def test_every_external_consumer_holds_the_shared_lease(self):
        for filename in ("host_status_integration.py", "settings_mysql_integration.py"):
            source = (ROOT / "tests/integration" / filename).read_text()
            self.assertIn("with live_engines.mysql_lease(os.environ):", source)

    def test_typescript_uses_the_shared_mysql_exec_boundary(self):
        import build_files
        self.assertIn('ts_client.addArgs(&.{ "exec-mysql", "env" });', build_files.source())

    def test_no_server_needs_no_lease(self):
        with live_engines.mysql_lease({}) as descriptor:
            self.assertIsNone(descriptor)


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
        self.assertIsNone(self.verify("ddl=40 ddl_refused=0 prepares=812 prepare_refused=0 probes=4 migrations=1 conformance=1\n"))

    def test_a_missing_record_fails(self):
        self.assertIn("missing", self.verify(None))

    def test_a_record_without_prepares_fails(self):
        self.assertIn("no PREPARE", self.verify("ddl=40 ddl_refused=0 prepares=0 prepare_refused=0 probes=4 migrations=1 conformance=1\n"))

    def test_a_record_without_a_passed_migration_test_fails(self):
        self.assertIn("migration", self.verify("ddl=40 ddl_refused=0 prepares=812 prepare_refused=0 probes=4 migrations=0\n"))

    def test_a_record_without_conformance_fails(self):
        self.assertIn("conformance", self.verify("prepares=812 migrations=1 conformance=0\n"))

    def test_an_older_record_without_conformance_fails(self):
        self.assertIn("conformance", self.verify("prepares=812 migrations=1\n"))

    def test_an_unset_record_variable_fails(self):
        self.assertIn("not set", live_engines.verify_mysql({}))


if __name__ == "__main__":
    unittest.main()
