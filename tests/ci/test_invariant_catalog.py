"""Keep catalog identities and migrated invariant owners unambiguous."""

from collections import defaultdict
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
ROW = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|")
TEST = re.compile(r'^\s*test\s*[\( ]\s*"([^"\n]+)"', re.MULTILINE)


def catalog_rows():
    for path in sorted((ROOT / "docs/invariants").glob("*.md")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if not ROW.match(line):
                continue
            cells = [cell.strip() for cell in line.split("|")]
            yield path, number, cells


class InvariantCatalogTest(unittest.TestCase):
    def test_catalog_ids_are_unique(self):
        """CI-83: Catalog identities are unique."""
        seen = {}
        for path, number, cells in catalog_rows():
            identity = cells[1]
            self.assertNotIn(identity, seen, f"{identity} repeated at {path}:{number}; first at {seen.get(identity)}")
            seen[identity] = f"{path}:{number}"

    def test_named_migrated_owners_exist_once(self):
        """CI-84: Migrated owner names identify one source test."""
        # Unmigrated catalog rows name future owners without an ID prefix.
        # Enforce the ID-prefixed owners that the migration has landed.
        tests = defaultdict(list)
        for root, suffix in ((ROOT / "src", "*.zig"), (ROOT / "clients/ts/test", "*.ts")):
            for path in root.rglob(suffix):
                for name in TEST.findall(path.read_text()):
                    tests[name].append(path.relative_to(ROOT))
        for path, number, cells in catalog_rows():
            identity = cells[1]
            owner = re.search(r"`(" + re.escape(identity) + r" [^`]+)`", cells[5])
            if owner:
                name = owner.group(1)
                self.assertEqual(1, len(tests[name]), f"{path}:{number}: {name}: {tests[name]}")


if __name__ == "__main__":
    unittest.main()
