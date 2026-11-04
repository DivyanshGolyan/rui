"""Installed dependency trees never belong in git."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NoVendoredDependencies(unittest.TestCase):
    def test_no_tracked_node_modules(self):
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT, text=True).split("\0")
        vendored = [path for path in tracked if "node_modules" in Path(path).parts]
        self.assertEqual(vendored[:5], [], f"{len(vendored)} tracked files under node_modules; add the directory to .gitignore")


if __name__ == "__main__":
    unittest.main()
