"""Integration fixtures read the Store format from src/store/schema.zig.

tests/integration/host_process.py reads STORE_SCHEMA from the owner, so a
format change edits one line. A fixture that pins the current number instead
goes stale at the next format change; this check refuses such a pin when it is
written. Historical formats a test writes on purpose, below the current one,
stay allowed.
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
SCANNED = (("tests/integration", (".py", ".sh")), ("tests/qualification", (".go", ".py")))
PINNED_NAME = re.compile(r"^\s*(?:export\s+|const\s+|var\s+)?\w*SCHEMA\w*\s*:?=\s*\d", re.I)
SCHEMA_WORD = re.compile(r"schema|user_version", re.I)


def owner_schema(root):
    matches = SCHEMA.findall((root / "src/store/schema.zig").read_text())
    if len(matches) != 1:
        raise AssertionError(f"src/store/schema.zig declares {len(matches)} schema_version values")
    return int(matches[0])


def pin_findings(root, schema):
    """Lines that name a Store format by a number: a schema name bound to a
    literal, or the owner's current number beside a schema word."""
    current = re.compile(rf"(?<![\w.]){schema}(?![\w.])")
    findings = []
    for directory, suffixes in SCANNED:
        for path in sorted((root / directory).rglob("*")):
            if path.suffix not in suffixes:
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if PINNED_NAME.search(line) or (SCHEMA_WORD.search(line) and current.search(line)):
                    findings.append(f"{path.relative_to(root)}:{number}: {line.strip()[:120]}")
    return findings


class StoreSchemaFixturesTest(unittest.TestCase):
    def test_fixtures_read_the_owner(self):
        sys.path.insert(0, str(ROOT / "tests/integration"))
        try:
            import host_process
        finally:
            sys.path.remove(str(ROOT / "tests/integration"))
        self.assertEqual(host_process.STORE_SCHEMA, owner_schema(ROOT))

    def test_no_fixture_pins_the_store_format(self):
        findings = pin_findings(ROOT, owner_schema(ROOT))
        self.assertEqual(findings, [], "read host_process.STORE_SCHEMA (fixtures) instead of a Store format "
                         "number:\n" + "\n".join(findings))

    def test_the_pin_check_sees_each_form(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src/store").mkdir(parents=True)
            (root / "src/store/schema.zig").write_text("pub const schema_version: u32 = 60;\n")
            (root / "tests/integration").mkdir(parents=True)
            (root / "tests/integration/pinned.py").write_text(
                "STORE_SCHEMA = 60\n"
                "schema = 52\n"
                "assert database.execute('PRAGMA user_version').fetchone()[0] == 60\n"
                "assert 'supports schema 60' in stderr\n"
                # Clean: the owner's name, an older format written on purpose,
                # and the current number with no schema word.
                "assert database.execute('PRAGMA user_version').fetchone()[0] == STORE_SCHEMA\n"
                "connection.execute('PRAGMA user_version=21')\n"
                "timeout = 60\n")
            findings = pin_findings(root, owner_schema(root))
        self.assertEqual([finding.split(":")[1] for finding in findings], ["1", "2", "3", "4"])


if __name__ == "__main__":
    unittest.main()
