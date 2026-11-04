"""The integration fixtures' Store format matches the Store's schema_version.

tests/integration/host_process.py states STORE_SCHEMA apart from
src/store/schema.zig so a format change updates its fixtures deliberately;
this keeps that deliberate step from being missed.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
FIXTURE = re.compile(r"^STORE_SCHEMA = (\d+)$", re.MULTILINE)


def declared(pattern, path):
    matches = pattern.findall((ROOT / path).read_text())
    if len(matches) != 1:
        raise AssertionError(f"{path} declares {len(matches)} values for {pattern.pattern}")
    return int(matches[0])


def mismatch(schema, fixture):
    """The repair a disagreement needs, or None."""
    if schema == fixture:
        return None
    return (f"tests/integration/host_process.py has STORE_SCHEMA = {fixture}, but src/store/schema.zig "
            f"declares schema_version {schema}: set STORE_SCHEMA = {schema}")


class StoreSchemaFixturesTest(unittest.TestCase):
    def test_fixtures_expect_the_store_schema(self):
        error = mismatch(declared(SCHEMA, "src/store/schema.zig"),
                         declared(FIXTURE, "tests/integration/host_process.py"))
        self.assertIsNone(error, error)

    def test_a_stale_fixture_names_its_repair(self):
        self.assertEqual(mismatch(51, 50), "tests/integration/host_process.py has STORE_SCHEMA = 50, but "
                         "src/store/schema.zig declares schema_version 51: set STORE_SCHEMA = 51")
        self.assertIsNone(mismatch(51, 51))


if __name__ == "__main__":
    unittest.main()
