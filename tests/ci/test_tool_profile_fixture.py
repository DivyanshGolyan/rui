"""Focused lifecycle and runner checks for the tool-profile database matrix."""
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
with patch.object(sys, "argv", [__file__, str(ROOT / "zig-out/bin/rui")]):
    import fresh_tool_profile_cases as cases
    import tool_profile_fixture as fixture


SERVER = {"RUI_TEST_MYSQL_SOCKET": "/tmp/mysql socket.sock",
          "RUI_TEST_MYSQL_ROOT_PASSWORD": "p@ss:/word",
          "RUI_TEST_MYSQL_ADMIN": "/tmp/mysql-admin"}
INPUTS = (SERVER["RUI_TEST_MYSQL_SOCKET"], SERVER["RUI_TEST_MYSQL_ROOT_PASSWORD"], SERVER["RUI_TEST_MYSQL_ADMIN"])


class InputsTest(unittest.TestCase):
    def test_absent_optional_mysql_runs_sqlite_and_reports_skip(self):
        output = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), patch("sys.stdout", output), \
                patch.object(fixture.live_engines, "mysql_lease") as lease:
            with fixture.profile_worlds() as worlds:
                self.assertEqual(worlds, [("sqlite", fixture.overview_fixture.world)])
        lease.assert_not_called()
        self.assertIn("skipped", output.getvalue())

    def test_required_mysql_never_skips_missing_inputs(self):
        for required in ("mysql", "sqlite,mysql"):
            with self.subTest(required=required), self.assertRaisesRegex(AssertionError, "required MySQL"):
                fixture.mysql_inputs({"RUI_TEST_REQUIRE_ENGINES": required})

    def test_partial_server_configuration_fails_even_when_optional(self):
        for key in ("RUI_TEST_MYSQL_SOCKET", "RUI_TEST_MYSQL_ROOT_PASSWORD"):
            with self.subTest(key=key), self.assertRaisesRegex(AssertionError, "both"):
                fixture.mysql_inputs({key: SERVER[key]})

    def test_supplied_server_requires_the_admin_helper(self):
        env = {name: value for name, value in SERVER.items() if name != "RUI_TEST_MYSQL_ADMIN"}
        with self.assertRaisesRegex(AssertionError, "RUI_TEST_MYSQL_ADMIN"):
            fixture.mysql_inputs(env)

    def test_supplied_server_runs_both_backends_under_the_shared_lease(self):
        events = []

        @contextmanager
        def lease(environ):
            self.assertEqual(environ["RUI_TEST_MYSQL_SOCKET"], SERVER["RUI_TEST_MYSQL_SOCKET"])
            events.append("lease")
            try:
                yield
            finally:
                events.append("release")

        with patch.dict(os.environ, SERVER, clear=True), patch.object(fixture.live_engines, "mysql_lease", lease):
            with fixture.profile_worlds() as worlds:
                self.assertEqual([engine for engine, _ in worlds], ["sqlite", "mysql"])
                self.assertEqual(worlds[1][1].args, (INPUTS,))
                self.assertEqual(events, ["lease"])
        self.assertEqual(events, ["lease", "release"])


class LaunchTest(unittest.TestCase):
    def test_saved_placement_keeps_the_url_in_the_host_environment(self):
        runtime = Path("/tmp/private-interface")
        store = fixture.MysqlStore(INPUTS, runtime)
        host = Mock()
        with patch.object(fixture.subprocess, "run") as command, \
                patch.object(fixture, "start_ready_process", return_value=(host, {})) as launch:
            self.assertIs(store.start_host(Path("/tmp/profile-store"), "http://127.0.0.1:1/responses", active_capacity=2), host)
        self.assertEqual(command.call_count, 2)
        saved_url, saved_interface = command.call_args_list
        self.assertEqual(saved_url.args[0][-2:], ["store.mysql.url", "env:RUI_TOOL_PROFILE_MYSQL_URL"])
        self.assertEqual(saved_interface.args[0][-2:], ["interface.dir", str(runtime)])
        self.assertNotIn("env", saved_url.kwargs)
        args = launch.call_args.args[0]
        self.assertIn("execution.activeCapacity=2", args)
        self.assertIn("providers.codex.endpoint=http://127.0.0.1:1/responses", args)
        url = launch.call_args.kwargs["env"]["RUI_TOOL_PROFILE_MYSQL_URL"]
        self.assertEqual(url, f"mysql://root:p%40ss%3A%2Fword@%2Ftmp%2Fmysql%20socket.sock/{store.database}")
        self.assertNotIn(url, " ".join(args))

    def test_standalone_human_cli_target_supplies_the_admin_helper(self):
        import build_files

        source = build_files.source()
        start = source.index("    const human_cli = ")
        end = source.index('    human_cli.addArg("python3");', start)
        self.assertIn('human_cli.addPrefixedFileArg("RUI_TEST_MYSQL_ADMIN=", ci.path(mysql_launch_admin));',
                      source[start:end])

    def test_admin_uses_the_selected_server_and_a_bounded_command(self):
        store = fixture.MysqlStore(INPUTS, Path("/tmp/runtime"))
        with patch.object(fixture.subprocess, "run", return_value=SimpleNamespace(stdout="answer\n")) as command:
            self.assertEqual(store.sql("SELECT 1"), "answer")
        self.assertEqual(command.call_args.args[0], [INPUTS[2]])
        self.assertEqual(command.call_args.kwargs["input"], "SELECT 1")
        self.assertEqual(command.call_args.kwargs["env"]["RUI_TEST_MYSQL_SOCKET"], INPUTS[0])
        self.assertEqual(command.call_args.kwargs["timeout"], 30)


class LifecycleTest(unittest.TestCase):
    @contextmanager
    def scope(self, *, schema_failure=False, cleanup_failure=False):
        events = []
        store = Mock(database="rui_tool_profile_test")
        store.database = "rui_tool_profile_test"

        def sql(text):
            events.append(text)
            if text.startswith("SELECT meta_value"):
                return "durable-mysql-id"
            return ""

        store.sql.side_effect = sql

        def drop():
            events.append("drop database")
            if cleanup_failure:
                raise RuntimeError("drop failed")

        store.drop.side_effect = drop

        @contextmanager
        def runtime():
            events.append("runtime")
            try:
                yield Path("/tmp/runtime")
            finally:
                events.append("remove runtime")

        @contextmanager
        def world(*args, **kwargs):
            self.assertIs(kwargs["host_factory"], store.start_host)
            self.assertEqual(kwargs["active_capacity"], 2)
            events.append("start Host")
            try:
                with tempfile.TemporaryDirectory() as directory:
                    yield SimpleNamespace(store=Path(directory), run=Mock(return_value=json.dumps(
                        {"status": "ready", "store": "durable-mysql-id"})))
            finally:
                events.append("stop Host")

        result = SimpleNamespace(stdout="SCHEMA")
        failure = subprocess.CalledProcessError(1, ["rui", "store", "schema"])
        with patch.object(fixture, "short_interface_directory", runtime), \
                patch.object(fixture, "MysqlStore", return_value=store), \
                patch.object(fixture.overview_fixture, "world", world), \
                patch.object(fixture.subprocess, "run", side_effect=failure if schema_failure else None,
                             return_value=result):
            yield events, store

    def test_host_stops_before_database_and_runtime_cleanup(self):
        with self.scope() as (events, store):
            with fixture.mysql_world(INPUTS, "test", active_capacity=2):
                events.append("journey")
        self.assertLess(events.index("stop Host"), events.index("drop database"))
        self.assertLess(events.index("drop database"), events.index("remove runtime"))
        self.assertIn("USE rui_tool_profile_test;SCHEMA", events)
        store.drop.assert_called_once_with()

    def test_schema_failure_drops_the_new_database(self):
        with self.scope(schema_failure=True) as (events, store):
            with self.assertRaises(subprocess.CalledProcessError):
                with fixture.mysql_world(INPUTS, "test", active_capacity=2):
                    self.fail("schema failure yielded a World")
        store.drop.assert_called_once_with()
        self.assertNotIn("start Host", events)

    def test_body_failure_remains_primary_when_database_cleanup_also_fails(self):
        with self.scope(cleanup_failure=True) as (events, store):
            with self.assertRaisesRegex(AssertionError, "journey failed") as failure:
                with fixture.mysql_world(INPUTS, "test", active_capacity=2):
                    raise AssertionError("journey failed")
        self.assertTrue(any("drop failed" in note for note in failure.exception.__notes__))
        store.drop.assert_called_once_with()
        self.assertIn("stop Host", events)

    def test_database_cleanup_failure_fails_a_successful_journey(self):
        with self.scope(cleanup_failure=True):
            with self.assertRaisesRegex(RuntimeError, "drop failed"):
                with fixture.mysql_world(INPUTS, "test", active_capacity=2):
                    pass

    def test_failed_host_start_closes_the_endpoint_and_fixture_root(self):
        endpoint = Mock(server_port=1)
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "world"
            root.mkdir()
            with patch.object(fixture.overview_fixture, "screen_fixture_root", return_value=root), \
                    patch.object(fixture.overview_fixture.fixture, "SuccessEndpoint", return_value=endpoint), \
                    patch.object(fixture.overview_fixture.threading, "Thread"), \
                    patch.object(fixture.overview_fixture.codex_fixture, "credentials"):
                with self.assertRaisesRegex(RuntimeError, "launch failed"):
                    fixture.overview_fixture.World("test", host_factory=Mock(side_effect=RuntimeError("launch failed")))
            self.assertFalse(root.exists())
        endpoint.shutdown.assert_called_once_with()
        endpoint.server_close.assert_called_once_with()

    def test_database_drop_waits_for_the_host_lock(self):
        store = fixture.MysqlStore(INPUTS, Path("/tmp/runtime"))
        with patch.object(store, "sql", side_effect=["0", "1", ""]) as sql:
            store.drop()
        self.assertEqual(sql.call_args_list[-1].args, (f"DROP DATABASE IF EXISTS {store.database}",))
        self.assertEqual(sql.call_count, 3)


class MatrixTest(unittest.TestCase):
    def test_the_real_profile_entry_runs_every_scenario_for_both_backends(self):
        sqlite, mysql = Mock(), Mock()

        @contextmanager
        def worlds():
            yield [("sqlite", sqlite), ("mysql", mysql)]

        names = ("fresh_callers", "restrictions_and_resume", "discovery", "attached_child")
        mocks = {name: Mock() for name in names}
        with patch.object(cases, "profile_worlds", worlds), patch.multiple(cases, **mocks):
            cases.main()
        for name, scenario in mocks.items():
            with self.subTest(scenario=name):
                self.assertEqual(scenario.call_args_list, [call(sqlite, "sqlite"),
                                                          call(mysql, "mysql")])

    def test_the_scoped_fixture_is_a_live_mysql_consumer(self):
        from select_tests import Graph

        files = {"src/logic_tests.zig": "const cores = .{\n};\n", "src/cli.zig": ""}
        for name in ("human_cli_integration.py", "fresh_tool_profile_cases.py", "tool_profile_fixture.py",
                     "overview_fixture.py"):
            path = "tests/integration/" + name
            files[path] = (ROOT / path).read_text()
        fixtures = {"human-cli-integration": (("tests/integration/human_cli_integration.py",), (), ()),
                    "overview-integration": (("tests/integration/overview_fixture.py",), (), ())}
        with patch("select_tests.FIXTURES", fixtures):
            graph = Graph(files, files.__getitem__)
        self.assertIn("human-cli-integration", graph.live_mysql)
        self.assertNotIn("overview-integration", graph.live_mysql)
        self.assertIn("human-cli-integration", graph.targets("tests/integration/tool_profile_fixture.py"))


if __name__ == "__main__":
    unittest.main()
