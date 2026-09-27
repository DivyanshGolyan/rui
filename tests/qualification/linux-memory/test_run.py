"""Run with Python and h2 installed: python3 -m unittest discover -s tests/qualification/linux-memory."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run


class CaptureTest(unittest.TestCase):
    def test_optional_counters_are_independent(self):
        def read(path):
            if path.name in ("memory.swap.current", "cpu.max"):
                raise FileNotFoundError(str(path))
            if path.name == "memory.events":
                raise PermissionError(str(path))
            return "observed:" + str(path)

        with patch.object(Path, "read_text", read):
            result = run.system_snapshot()
        for name in ("memory.swap.current", "cpu.max", "memory.events"):
            self.assertEqual(result[name]["status"], "unavailable")
        self.assertEqual(result["memory.current"], "observed:/sys/fs/cgroup/memory.current")
        self.assertEqual(result["meminfo"], "observed:/proc/meminfo")

    def test_no_optional_counters_does_not_disable_host_measurement(self):
        with patch.object(Path, "read_text", side_effect=FileNotFoundError("no counters")):
            result = run.system_snapshot()
            with self.assertRaises(FileNotFoundError):
                run.sample(123)
        self.assertEqual(len(result), 11)
        self.assertTrue(all(value["status"] == "unavailable" for name, value in result.items() if name != "cgroup_scope"))

    def test_initial_capture_failure_is_serialized(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / "capture"
            with patch.object(run.sys, "platform", "linux"), \
                 patch.object(run.sys, "argv", ["run.py", "/missing/rui", "--output", str(out)]), \
                 patch.object(run.os, "confstr", return_value="glibc test"), \
                 patch.object(Path, "read_bytes", side_effect=OSError("binary capture failed")), \
                 patch.object(Path, "read_text", side_effect=PermissionError("telemetry denied")), \
                 self.assertRaisesRegex(OSError, "binary capture failed"):
                run.main()
            self.assertTrue((out / "result.json").exists(), "capture failure lost result.json")
            result = json.loads((out / "result.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error"], "binary capture failed")
            self.assertEqual(result["after"]["memory.current"]["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
