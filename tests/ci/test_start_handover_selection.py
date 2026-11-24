import subprocess
import unittest
from pathlib import Path

import build_files
import prepush
from select_tests import Graph, select


class StartHandoverSelectionTest(unittest.TestCase):
    def test_fixture_is_hosted_and_selected(self):
        path = "tests/integration/host_start_handover_integration.py"
        tracked = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
        files = {name for name in tracked if name and Path(name).is_file()} | {path}
        graph = Graph(files, lambda name: Path(name).read_text())
        available = set(build_files.steps())
        result = select([path], "review", available, graph=graph)
        for field in ("targets", "native_targets", "fast_targets"):
            self.assertIn("start-handover-integration", result[field])
        for mode in ("default", "quick"):
            checks = list(prepush.checks([path], available, "HEAD", mode=mode))
            self.assertFalse(any(name == "development selection" for name, _ in checks))
            self.assertFalse(any(isinstance(command, list) and "start-handover-integration" in command
                                 for _, command in checks))


if __name__ == "__main__":
    unittest.main()
