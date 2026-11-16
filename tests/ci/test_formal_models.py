"""Run tests/formal/check.py: every TLA+ model holds its rules, each known
finding still breaks and each mutation is caught."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "formal"))
import check  # noqa: E402


class FormalModelsTest(unittest.TestCase):
    def test_models_hold_findings_stand_and_mutations_fail(self):
        self.assertEqual([], check.failures())


if __name__ == "__main__":
    unittest.main()
