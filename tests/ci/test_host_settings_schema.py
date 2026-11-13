"""The generated settings grammar's byte and name patterns reject whole strings."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def schema_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from schema_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from schema_nodes(child)


class HostSettingsSchemaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        document = json.loads((ROOT / "openapi.json").read_text())
        cls.nodes = list(schema_nodes(document["components"]["schemas"]["HostSettings"]))

    def test_byte_hex_patterns_reject_terminal_newlines(self):
        found = 0
        for node in self.nodes:
            if node.get("x-rui-kind") != "bytes" or "oneOf" not in node:
                continue
            hex_object = node["oneOf"][1]
            self.assertEqual(hex_object["required"], ["hex"])
            self.assertIs(hex_object["additionalProperties"], False)
            pattern = re.compile(hex_object["properties"]["hex"]["pattern"])
            for valid in ("", "00", "ff", "0123456789abcdef"):
                self.assertIsNotNone(pattern.search(valid), valid)
            for invalid in ("f", "FF", "fg", "ff\n", "ff\r", "ff\r\n", "\n"):
                self.assertIsNone(pattern.search(invalid), repr(invalid))
            found += 1
        self.assertGreater(found, 0)

    def test_named_property_patterns_reject_terminal_newlines(self):
        found = 0
        for node in self.nodes:
            if "propertyNames" not in node:
                continue
            pattern = re.compile(node["propertyNames"]["pattern"])
            self.assertIsNotNone(pattern.search("sample_2-fast"))
            for invalid in ("", "sample.name", "sample\n", "sample\r", "sample\r\n"):
                self.assertIsNone(pattern.search(invalid), repr(invalid))
            found += 1
        self.assertGreater(found, 0)


if __name__ == "__main__":
    unittest.main()
