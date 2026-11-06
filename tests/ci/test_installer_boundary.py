import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests/integration/installer_integration.py"


class InstallerBoundaryTest(unittest.TestCase):
    def test_all_native_cases_bind_the_explicit_publisher_without_running_it(self):
        spec = importlib.util.spec_from_file_location("native_installer_cases", FIXTURE)
        module = importlib.util.module_from_spec(spec)
        with patch.object(sys, "path", [str(FIXTURE.parent), *sys.path]), \
                patch.object(subprocess, "run", side_effect=AssertionError("case construction must not run a compiler or publisher")):
            spec.loader.exec_module(module)
            publisher = Path("/explicit/compiled/production/rui")
            cases = list(module.installer_suite(publisher))
        self.assertEqual(len(cases), 37)
        self.assertEqual(sum(isinstance(case, module.ReleaseInstallerTest) for case in cases), 26)
        self.assertEqual(sum(isinstance(case, module.SourceInstallerTest) for case in cases), 11)
        self.assertTrue(all(case.publisher == publisher for case in cases))
        self.assertTrue(all(not getattr(case, "__unittest_skip__", False) for case in cases))

    def test_release_policy_runs_with_no_zig_on_path(self):
        with tempfile.TemporaryDirectory(prefix="rui-policy-no-compiler-") as temporary:
            tools = Path(temporary) / "tools"
            tools.mkdir()
            for command in ("git", "sh"):
                tool = shutil.which(command)
                self.assertIsNotNone(tool)
                (tools / command).symlink_to(tool)
            environment = {**os.environ, "PATH": str(tools)}
            self.assertIsNone(shutil.which("zig", path=environment["PATH"]))
            result = subprocess.run(
                [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/ci", "-p", "test_release.py", "-v"],
                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Ran 11 tests", result.stderr)
            self.assertNotIn("skipped", result.stderr)
