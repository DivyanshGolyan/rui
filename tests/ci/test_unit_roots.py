import importlib.util
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import unittest

import build_files

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("unit_test_runner", ROOT / "tests/ci/unit_test_runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class GeneratedRunnerTest(unittest.TestCase):
    def test_unknown_stock_runner_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "runner changed"):
            runner.generate("pub fn main() void {}")

    def test_every_stock_reference_is_replaced_but_builtin_is_retained(self):
        source = "const a = builtin.test_functions;\nconst b = builtin.test_functions.len;\npub fn main(init: std.process.Init.Minimal) void {}\n"
        generated = runner.generate(source)
        self.assertTrue(generated.startswith("const a = unitTests();\nconst b = unitTests().len;\n"))
        self.assertEqual(generated.count("builtin.test_functions"), 1)
        self.assertIn("const all = builtin.test_functions;", generated)
        self.assertIn("partition.owner(test_fn.name)", generated)
        self.assertIn("unit_tests = selected[0..count]", generated)
        self.assertIn("unit_environ = init.environ;", generated)

    def test_filtered_runner_refuses_a_run_without_named_tests(self):
        generated = runner.generate_filtered("const a = builtin.test_functions;\n")
        self.assertTrue(generated.startswith("const a = filteredTests();\n"))
        self.assertIn('".test."', generated)
        self.assertIn('".decltest."', generated)
        self.assertIn("std.process.exit(1)", generated)
        with self.assertRaisesRegex(ValueError, "runner changed"):
            runner.generate_filtered("pub fn main() void {}")

    def test_changed_stock_main_fails_closed(self):
        for source in ("pub fn main(other: NewInit) void { _ = builtin.test_functions; }",
                       "pub fn main () void { _ = builtin.test_functions; }",
                       "const tests = builtin.test_functions;"):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "environment initialization"):
                runner.generate(source)

    def test_command_line_generator(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp, "stock runner.zig"), Path(tmp, "generated runner.zig")
            source.write_text("const tests = builtin.test_functions;\npub fn main(init: std.process.Init.Minimal) void {}\n")
            subprocess.run([sys.executable, str(ROOT / "tests/ci/unit_test_runner.py"), str(source), str(output)], check=True)
            self.assertEqual(output.read_text(), runner.generate(source.read_text()))


class ParallelRootsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="parallel unit roots ")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.integration = self.directory / "integration"
        self.integration.mkdir()
        ci = self.directory / "ci"
        ci.mkdir()
        self.events = self.directory / "events"
        self.native_ready = self.directory / "native ready"
        self.store_ready = self.directory / "store ready"
        os.mkfifo(self.native_ready)
        os.mkfifo(self.store_ready)
        source = (ROOT / "tests/integration/check.sh").read_text()
        before, cases = source.split("cases() {", 1)
        after = cases.split("\nrun_timed()", 1)[1]
        self.driver = self.integration / "check.sh"
        self.driver.write_text(before + "cases() { :; }\nrun_timed()" + after)
        (self.integration / "host_process.py").write_text(
            "import os, sys\nos.execvp(sys.argv[2], sys.argv[2:])\n")
        (ci / "case_deadline.py").write_text("import os, sys\nos.execvp(sys.argv[2], sys.argv[2:])\n")
        (ci / "store_shards.py").write_text(
            "import os, subprocess, sys\nfrom pathlib import Path\n"
            "expected = {'store root.py': 'run', 'native root.py': 'native'}.get(Path(sys.argv[2]).name, 'aggregate')\n"
            "assert sys.argv[1] == expected, sys.argv\n"
            "assert sys.argv[3:] == ['--timeout', '1200'], sys.argv\n"
            "assert os.environ['RUI_TEST_EXACT_INACTIVITY'] == '0'\n"
            "raise SystemExit(subprocess.call([sys.argv[2]]))\n")

    def root(self, name, status=0, barrier=True):
        path = self.directory / (name + " root.py")
        if barrier and name == "native":
            handshake = (f"with open({str(self.native_ready)!r}, 'w') as f: f.write('ready')\n"
                         f"with open({str(self.store_ready)!r}) as f: assert f.read() == 'ready'\n")
        elif barrier:
            handshake = (f"with open({str(self.native_ready)!r}) as f: assert f.read() == 'ready'\n"
                         f"with open({str(self.store_ready)!r}, 'w') as f: f.write('ready')\n")
        else:
            handshake = ""
        path.write_text(
            f"#!{sys.executable}\nimport os\n"
            "assert os.environ['RUI_TEST_EXACT_INACTIVITY'] == '0'\n"
            f"with open({str(self.events)!r}, 'a') as f: f.write('{name} started\\n')\n"
            + handshake +
            f"with open({str(self.events)!r}, 'a') as f: f.write('{name} finished\\n')\n"
            f"raise SystemExit({status})\n")
        path.chmod(0o755)
        return str(path)

    def run_gate(self, native, store=None):
        command = ["sh", str(self.driver), "release-safe", "debug", "parallel", native,
                   "host-status", "session-list", "activity", "preference-policy", "notice", "mysql-admin"]
        if store is not None:
            command.append(store)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True,
                                   env=dict(os.environ, RUI_TEST_PAUSE_SOCKET_BINARY="pause-socket"))
        try:
            stdout, stderr = process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    def test_native_and_store_start_together_and_both_finish(self):
        result = self.run_gate(self.root("native"), self.root("store"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertCountEqual(self.events.read_text().splitlines(),
                              ["native started", "store started", "native finished", "store finished"])
        self.assertIn("native passed: exit=0", result.stdout)
        self.assertIn("store passed: exit=0", result.stdout)

    def test_failure_waits_for_and_reports_both_roots(self):
        for native_status, store_status in ((7, 0), (0, 9), (7, 9)):
            with self.subTest(native_status=native_status, store_status=store_status):
                self.events.unlink(missing_ok=True)
                result = self.run_gate(self.root("native", native_status), self.root("store", store_status))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertCountEqual(self.events.read_text().splitlines(),
                                      ["native started", "store started", "native finished", "store finished"])
                output = result.stdout + result.stderr
                self.assertIn(f"native {'failed' if native_status else 'passed'}: exit={native_status}", output)
                self.assertIn(f"store {'failed' if store_status else 'passed'}: exit={store_status}", output)

    def test_an_empty_unit_selection_starts_neither_launcher(self):
        result = self.run_gate("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.events.exists())
        self.assertNotIn("native passed:", result.stdout)
        self.assertNotIn("store passed:", result.stdout)

    def test_filtered_aggregate_runs_once_without_store_launcher(self):
        result = self.run_gate(self.root("filtered aggregate", barrier=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events.read_text().splitlines(),
                         ["filtered aggregate started", "filtered aggregate finished"])
        self.assertNotIn("store passed:", result.stdout)


class BuildWiringTest(unittest.TestCase):
    def test_unit_roots_run_independently_without_ordering_compilation(self):
        partition = (ROOT / "src/unit_test_partition.zig").read_text()
        members = re.search(r"pub const Root = enum\s*\{([^}]+)\}", partition).group(1)
        self.assertEqual([name.strip() for name in members.split(",") if name.strip()],
                         ["native", "store"])
        build = build_files.source()
        self.assertNotIn("if (previous) |prior| run.step.dependOn(&prior.step)", build)
        self.assertIn("store_shards.py", build)
        self.assertNotIn("compile.step.dependOn(&run_tests.step)", build)
        self.assertIn("run.has_side_effects = true", build)
        self.assertIn('run.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0")', build)

    def test_full_execution_overlaps_units_but_unsplit_orders_processes(self):
        build = build_files.source()
        gate = build.split("    const native_gate =", 1)[1].split("    if (!pr_ci)", 1)[0]
        self.assertTrue(gate.startswith(" if (check_part == .execution) full_check_step else &process_integrations.step;"))
        self.assertIn('unit_module.attach("check-full", check_part, native_gate, &unit_runs, .runs)', gate)
        self.assertIn('if (unit_module.includes("check-full", check_part, .native_pair))', gate)
        self.assertEqual(re.findall(r"native_gate\.dependOn\(([^;]+)\);", gate), ["&units.run_renderer_allocation.step", "&units.run_os_tests.step"])
        for row in build_files.unit_roots():
            if row["name"] in ("unit-native", "unit-store") or row["source"] in ("src/h2/h2.zig", "src/store/wire/pg.zig"):
                self.assertIn(("check-full", "all"), row["owners"])
                self.assertIn(("check-full", "execution"), row["owners"])
                self.assertNotIn(("check-full", "callers"), row["owners"])
        self.assertNotIn("process_integrations.step.dependOn", gate)
        self.assertIn("full_check_step.dependOn(&process_integrations.step)", build)

    def test_filtered_runs_keep_single_stock_aggregate(self):
        build = build_files.source()
        self.assertIn("if (test_filters.len == 0) unit_partition.roots.len else 1", build)
        registry = build_files.unit_roots()
        aggregate = [row for row in registry if row.get("filtered_only")]
        self.assertEqual(len(aggregate), 1)
        self.assertEqual((aggregate[0]["name"], aggregate[0]["source"], aggregate[0]["target"]),
                         ("test", "src/tests.zig", "test"))
        self.assertIn("else native_group.filtered", build)
        self.assertIn(".name = definition.name", build)
        self.assertIn(".root_source_file = b.path(definition.source)", build)
        self.assertIn(".filters = if (definition.filtered_only) test_filters else unit_filters[@backingInt(partition)]", build)
        self.assertIn(".mode = .server } else filtered_runner", build)
        self.assertEqual(build.count(".test_runner = filtered_runner"), 2)
        self.assertIn('generate.addArg("--filtered")', build)

    def test_standalone_roots_keep_independent_target_ownership(self):
        build = build_files.source()
        partitions = {row["partition"]: row for row in build_files.unit_roots() if "partition" in row}
        self.assertEqual({key: row["target"] for key, row in partitions.items()},
                         {"native": "test-native", "store": "test-store"})
        self.assertIn('b.step(root(.native).target,', build)
        self.assertIn('b.step(root(.store).target,', build)
        self.assertIn('runs.set(identity, run)', build)
        self.assertIn('combined.dependOn(run)', build)
        self.assertIn('unitRun(b, ci, tests[index], if (identity == .store) "run" else "native")', build)
        self.assertIn('attach(entry[0], .all, entry[1], &runs, .runs)', build)
        for partition in ("native", "store"):
            self.assertIn((f"test-{partition}", "all"), partitions[partition]["owners"])
            self.assertNotIn((f"test-{'store' if partition == 'native' else 'native'}", "all"), partitions[partition]["owners"])
        for dependency in ('run_renderer_allocation', 'signal_stack_probe'):
            self.assertIn(f'native_step.dependOn(&{dependency}.step)', build)

    def test_ci_classifies_all_unit_compiles_and_filters_track_sources(self):
        build = build_files.source()
        self.assertIn("unit: []const *std.Build.Step.Compile", build)
        self.assertIn("collection.unit, compile", build)
        self.assertIn("unit_partition.owner(prefix)", build)
        self.assertIn("dependOnDirectoryContents", build)
        self.assertIn("directory.walk", build)
        shell = (ROOT / "tests/integration/check.sh").read_text()
        self.assertRegex(shell, r'run_case execution native .*store_shards\.py" "\$unit_mode" "\$test_binary" --timeout 1200')
        self.assertRegex(shell, r'run_case execution store .*store_shards\.py" run "\$store_binary" --timeout 1200')
        self.assertNotIn("--unit-roots", shell)


if __name__ == "__main__":
    unittest.main()
