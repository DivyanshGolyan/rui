"""Tracked paths stay distinct on a case-insensitive filesystem."""
from collections import defaultdict
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CaseDistinctPaths(unittest.TestCase):
    def test_no_two_paths_differ_only_by_case(self):
        # macOS checks out one of two such files over the other, so an import
        # of either reads the same bytes there (src/mcp/request.zig and
        # Request.zig broke every Mac build, #916).
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT, text=True).split("\0")
        folded = defaultdict(list)
        for path in filter(None, tracked):
            parts = Path(path).parts
            for depth in range(1, len(parts) + 1):
                prefix = "/".join(parts[:depth])
                folded[prefix.casefold()].append(prefix)
        clashes = sorted(sorted(set(paths)) for paths in folded.values() if len(set(paths)) > 1)
        self.assertEqual(clashes, [], "paths that are one file on macOS; rename one")


if __name__ == "__main__":
    unittest.main()
