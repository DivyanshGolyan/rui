"""CI-86: Invariant identifiers uniquely name their rows across catalogs."""
import re
import unittest
from collections import Counter
from pathlib import Path


CATALOGS = Path(__file__).resolve().parents[2] / 'docs/invariants'


def duplicate_ids(text):
    ids = re.findall(r'^\|\s*([A-Z][A-Z0-9]*-\d+)\s*\|', text, re.MULTILINE)
    return sorted(identifier for identifier, count in Counter(ids).items() if count > 1)


class InvariantCatalogTest(unittest.TestCase):
    def test_catalog_ids_are_unique(self):
        cases = (
            ('unique', '| CI-1 | first |\n| CI-2 | second |\n', []),
            ('duplicate', '| CI-78 | first |\n| CI-79 | other |\n| CI-78 | second |\n', ['CI-78']),
            ('other prefix', '| CLI-17 | first |\n| CLI-18 | other |\n| CLI-17 | second |\n', ['CLI-17']),
            ('multiple duplicates', '| CI-2 | a |\n| CI-1 | b |\n| CI-2 | c |\n| CI-1 | d |\n', ['CI-1', 'CI-2']),
        )
        for name, text, expected in cases:
            with self.subTest(case=name):
                self.assertEqual(duplicate_ids(text), expected)
        catalogs = sorted(path for path in CATALOGS.rglob('*.md') if path.name != 'README.md')
        duplicates = duplicate_ids('\n'.join(path.read_text() for path in catalogs))
        self.assertEqual(duplicates, [], f'duplicate invariant IDs: {", ".join(duplicates)}')
