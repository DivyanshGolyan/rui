"""CI-86: CI tooling invariant identifiers uniquely name their rows."""
import re
import unittest
from collections import Counter
from pathlib import Path


CATALOG = Path(__file__).resolve().parents[2] / 'docs/invariants/ci-tooling.md'


def duplicate_ids(text):
    ids = re.findall(r'^\|\s*(CI-\d+)\s*\|', text, re.MULTILINE)
    return sorted(identifier for identifier, count in Counter(ids).items() if count > 1)


class InvariantCatalogTest(unittest.TestCase):
    def test_ci_tooling_ids_are_unique(self):
        cases = (
            ('unique', '| CI-1 | first |\n| CI-2 | second |\n', []),
            ('duplicate', '| CI-78 | first |\n| CI-79 | other |\n| CI-78 | second |\n', ['CI-78']),
            ('multiple duplicates', '| CI-2 | a |\n| CI-1 | b |\n| CI-2 | c |\n| CI-1 | d |\n', ['CI-1', 'CI-2']),
        )
        for name, text, expected in cases:
            with self.subTest(case=name):
                self.assertEqual(duplicate_ids(text), expected)
        duplicates = duplicate_ids(CATALOG.read_text())
        self.assertEqual(duplicates, [], f'duplicate CI invariant IDs: {", ".join(duplicates)}')
