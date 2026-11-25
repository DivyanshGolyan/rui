"""CI-86: Invariant identifiers uniquely name their rows across catalogs."""
import hashlib
import json
import re
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path

import verify_vaxis_test_owners


ROOT = Path(__file__).resolve().parents[2]
CATALOGS = ROOT / 'docs/invariants'
ROW = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|")
TEST = re.compile(r'^\s*test\s*[\( ]\s*"([^"\n]+)"', re.MULTILINE)


def catalogs():
    """Every invariant catalog document; the README indexes them and holds no rows."""
    return sorted(path for path in CATALOGS.rglob('*.md') if path.name != 'README.md')


def catalog_rows():
    for path in catalogs():
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
        duplicates = duplicate_ids('\n'.join(path.read_text() for path in catalogs()))
        self.assertEqual(duplicates, [], f'duplicate invariant IDs: {", ".join(duplicates)}')

    def test_catalog_rows_stay_inside_their_table(self):
        """A blank line ends a Markdown table, so a row after one renders as loose text."""
        def detached(text):
            lines = text.splitlines()
            return [number for number, line in enumerate(lines, 1)
                    if ROW.match(line) and (number == 1 or not lines[number - 2].startswith('|'))]
        self.assertEqual(detached('| ID | Owner |\n| --- | --- |\n| CI-1 | a |\n| CI-2 | b |\n'), [])
        self.assertEqual(detached('| ID | Owner |\n| --- | --- |\n| CI-1 | a |\n\n| CI-2 | b |\n'), [5])
        found = [f'{path.relative_to(ROOT)}:{number}' for path in catalogs()
                 for number in detached(path.read_text())]
        self.assertEqual(found, [], f'catalog rows outside their table: {", ".join(found)}')

    def assert_external_owners_require_the_pin_and_exact_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            revision = "a" * 40
            source = b'test "SUI-127 example" {}\n'
            (root / "owner.zig").write_bytes(source)
            data = {"revision": revision, "sources": {"owner.zig": {
                "sha256": hashlib.sha256(source).hexdigest(), "tests": ["SUI-127 example"]}}}
            manifest = root / "owners.json"
            manifest.write_text(json.dumps(data))
            build = root / "build.zig.zon"
            build.write_text(f'git+https://github.com/DivyanshGolyan/libvaxis#{revision}')
            loaded, owners = verify_vaxis_test_owners.load(manifest, build)
            self.assertEqual(owners, [("owner.zig", "SUI-127 example")])
            verify_vaxis_test_owners.verify(loaded, root)
            build.write_text('git+https://github.com/DivyanshGolyan/libvaxis#' + "b" * 40)
            with self.assertRaisesRegex(ValueError, "pinned revision"):
                verify_vaxis_test_owners.load(manifest, build)
            (root / "owner.zig").write_bytes(source + b"// changed\n")
            with self.assertRaisesRegex(ValueError, "source changed"):
                verify_vaxis_test_owners.verify(loaded, root)
            (root / "owner.zig").write_bytes(source)
            (root / "other.zig").write_bytes(source)
            with self.assertRaisesRegex(ValueError, "not unique"):
                verify_vaxis_test_owners.verify(loaded, root)

    def test_named_migrated_owners_exist_once(self):
        """CI-87: Migrated owner names identify one source test."""
        self.assert_external_owners_require_the_pin_and_exact_source()
        # Unmigrated catalog rows name future owners without an ID prefix.
        # Enforce the ID-prefixed owners that the migration has landed.
        tests = defaultdict(list)
        for root, suffix in ((ROOT / 'src', '*.zig'), (ROOT / 'build', '*.zig'), (ROOT / 'clients/ts/test', '*.ts')):
            for path in root.rglob(suffix):
                for name in TEST.findall(path.read_text()):
                    tests[name].append(path.relative_to(ROOT))
        for path in (ROOT / 'build').glob('*.patch'):
            added = '\n'.join(line[1:] for line in path.read_text().splitlines() if line.startswith('+'))
            for name in TEST.findall(added):
                tests[name].append(path.relative_to(ROOT))
        _, external = verify_vaxis_test_owners.load(
            ROOT / 'tests/ci/vaxis_test_owners.json', ROOT / 'build.zig.zon')
        for source, name in external:
            tests[name].append(Path('libvaxis') / source)
        for path, number, cells in catalog_rows():
            identity = cells[1]
            owner = re.search(r"`(" + re.escape(identity) + r" [^`]+)`", cells[5])
            if owner:
                name = owner.group(1)
                self.assertEqual(1, len(tests[name]), f"{path}:{number}: {name}: {tests[name]}")


if __name__ == '__main__':
    unittest.main()
