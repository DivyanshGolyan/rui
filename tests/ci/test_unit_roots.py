"""Fast contracts for partitioned unit execution (no Zig compilation)."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("unit_test_runner", ROOT / "tests/ci/unit_test_runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class GeneratedRunnerTest(unittest.TestCase):
    def test_unknown_stock_runner_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "runner changed"):
            runner.generate("pub fn main() void {}")

    def test_every_stock_reference_is_replaced_but_builtin_is_retained(self):
        source = "const a = builtin.test_functions;\nconst b = builtin.test_functions.len;\n"
        generated = runner.generate(source)
        self.assertTrue(generated.startswith("const a = unitTests();\nconst b = unitTests().len;\n"))
        self.assertEqual(generated.count("builtin.test_functions"), 1)
        self.assertIn("const all = builtin.test_functions;", generated)
        self.assertIn("partition.owner(test_fn.name)", generated)
        self.assertIn("unit_tests = selected[0..count]", generated)

    def test_command_line_generator(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp, "stock runner.zig"), Path(tmp, "generated runner.zig")
            source.write_text("const tests = builtin.test_functions;\n")
            subprocess.run([sys.executable, str(ROOT / "tests/ci/unit_test_runner.py"), str(source), str(output)], check=True)
            self.assertEqual(output.read_text(), runner.generate(source.read_text()))


class DeadlineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="unit roots ")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.events = self.directory / "events"
        text = (ROOT / "tests/integration/check.sh").read_text()
        function = text.split("with_deadline() {", 1)[1].split("\nrun_timed()", 1)[0]
        self.helper = self.directory / "deadline helper.sh"
        self.helper.write_text("with_deadline() {" + function + '\nwith_deadline "$@"\n')

    def root(self, name, delay=0, status=0):
        path = self.directory / (name + " root.py")
        path.write_text(
            "import os, time\n"
            f"with open({str(self.events)!r}, 'a') as f:\n"
            f"    f.write({name!r} + ':' + str(os.getpid()) + '\\n')\n"
            f"time.sleep({delay!r})\nraise SystemExit({status})\n"
        )
        return str(path)

    def run_roots(self, budget, roots):
        return subprocess.run(["sh", str(self.helper), str(budget), sys.executable,
                               "--unit-roots", *roots], capture_output=True, text=True, timeout=8)

    def names(self):
        return [line.split(":")[0] for line in self.events.read_text().splitlines()]

    def test_success_runs_roots_in_order_with_spaces(self):
        result = self.run_roots(3, [self.root("native"), self.root("store")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names(), ["native", "store"])

    def test_failure_suppresses_later_roots(self):
        result = self.run_roots(3, [self.root("native", status=7), self.root("store")])
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(self.names(), ["native"])

    def test_budget_is_shared_and_active_child_is_reaped(self):
        # Each root individually fits; together they exceed the ONE deadline.
        result = self.run_roots(1.5, [self.root("native", delay=0.9),
                                      self.root("store", delay=0.9), self.root("must not run")])
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn("last test named above stalled", result.stdout)
        self.assertEqual(self.names(), ["native", "store"])
        pid = int(self.events.read_text().splitlines()[-1].split(":")[1])
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_empty_root_list_fails_closed(self):
        result = self.run_roots(3, [])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No unit roots supplied", result.stderr)
        self.assertFalse(self.events.exists())

    def test_single_command_interface_is_preserved(self):
        result = subprocess.run(["sh", str(self.helper), "3", sys.executable, self.root("legacy")],
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names(), ["legacy"])


class BuildWiringTest(unittest.TestCase):
    def test_store_is_last_and_runs_are_serial_but_compiles_are_not(self):
        partition = (ROOT / "src/unit_test_partition.zig").read_text()
        members = re.search(r"pub const Root = enum\s*\{([^}]+)\}", partition).group(1)
        self.assertEqual([name.strip() for name in members.split(",") if name.strip()],
                         ["native", "store"])
        build = (ROOT / "build.zig").read_text()
        self.assertIn("run.step.dependOn(&run_tests.step)", build)
        self.assertNotIn("compile.step.dependOn(&run_tests.step)", build)
        self.assertIn("run.has_side_effects = true", build)
        self.assertIn('run.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0")', build)

    def test_filtered_runs_keep_single_stock_aggregate(self):
        build = (ROOT / "build.zig").read_text()
        self.assertIn("if (test_filters.len == 0) unit_partition.roots.len else 1", build)
        self.assertIn('if (test_filters.len != 0) "test"', build)
        self.assertIn('.root_source_file = b.path("src/tests.zig")', build)
        self.assertIn(".filters = if (test_filters.len != 0) test_filters else unit_filters[index]", build)
        self.assertIn(".mode = .server } else null", build)

    def test_ci_classifies_all_unit_compiles_and_filters_track_sources(self):
        build = (ROOT / "build.zig").read_text()
        self.assertIn("unit: []const *std.Build.Step.Compile", build)
        self.assertIn("collection.unit, compile", build)
        self.assertIn("unit_partition.owner(prefix)", build)
        self.assertIn("dependOnDirectoryContents", build)
        self.assertIn("directory.walk", build)
        shell = (ROOT / "tests/integration/check.sh").read_text()
        self.assertRegex(shell, r'with_deadline 1200 .*--unit-roots "\$test_binary" "\$@"')


if __name__ == "__main__":
    unittest.main()
