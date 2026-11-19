"""CI-86: Invariant identifiers uniquely name their rows across catalogs."""
import re
import unittest
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CATALOGS = ROOT / 'docs/invariants'
ROW = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|")
TEST = re.compile(r'^\s*test\s*[\( ]\s*"([^"\n]+)"', re.MULTILINE)


def catalog_rows():
    for path in sorted(CATALOGS.glob('*.md')):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if ROW.match(line):
                yield path, number, [cell.strip() for cell in line.split('|')]


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

    def test_named_migrated_owners_exist_once(self):
        """CI-87: Migrated owner names identify one source test."""
        # Unmigrated catalog rows name future owners without an ID prefix.
        # Enforce the ID-prefixed owners that the migration has landed.
        tests = defaultdict(list)
        for root, suffix in ((ROOT / 'src', '*.zig'), (ROOT / 'clients/ts/test', '*.ts')):
            for path in root.rglob(suffix):
                for name in TEST.findall(path.read_text()):
                    tests[name].append(path.relative_to(ROOT))
        for path, number, cells in catalog_rows():
            identity = cells[1]
            owner = re.search(r"`(" + re.escape(identity) + r" [^`]+)`", cells[5])
            if owner:
                name = owner.group(1)
                self.assertEqual(1, len(tests[name]), f"{path}:{number}: {name}: {tests[name]}")


if __name__ == '__main__':
    unittest.main()
