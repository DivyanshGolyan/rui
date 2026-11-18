"""CI-86: policy fails a statement table generated from other inputs than the files hold."""
import tempfile
import unittest
from pathlib import Path

from rsql_table import fingerprint_error

PRODUCT = 'pub const rsql_table_inputs = [_][]const u8{ "a.zig", "b.zig" };\n'
# sha256(b"a.zig\0one\0b.zig\0two\0")[:16], written out rather than computed by the code under test.
CURRENT = "d1311121114a1397a0efc2efd738bfd9"


class RsqlTableTest(unittest.TestCase):
    def tree(self, table_inputs, a="one", b="two", unlisted="x"):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        root = Path(scratch.name)
        (root / "build").mkdir()
        (root / "src/store").mkdir(parents=True)
        (root / "build/product.zig").write_text(PRODUCT)
        (root / "a.zig").write_text(a)
        (root / "b.zig").write_text(b)
        (root / "c.zig").write_text(unlisted)
        line = "" if table_inputs is None else f'pub const inputs = "{table_inputs}";\n'
        (root / "src/store/rsql_table.zig").write_text('const rsql = @import("rsql.zig");\n\n' + line + "pub const entries = struct {};\n")
        return root

    def test_fingerprint_names_every_input_and_policy_fails_a_stale_table(self):
        cases = (
            ("table generated from these inputs", dict(table_inputs=CURRENT), False),
            ("a file outside the list changed", dict(table_inputs=CURRENT, unlisted="y"), False),
            ("the first listed file changed", dict(table_inputs=CURRENT, a="one!"), True),
            ("the last listed file changed", dict(table_inputs=CURRENT, b="two!"), True),
            ("the empty table of a fresh tree", dict(table_inputs=""), True),
            ("a table with no inputs line", dict(table_inputs=None), True),
        )
        for name, tree, stale in cases:
            with self.subTest(name):
                error = fingerprint_error(self.tree(**tree))
                if stale:
                    self.assertIn("python3 tests/ci/rsql_table.py generate", error)
                else:
                    self.assertIsNone(error)


if __name__ == "__main__":
    unittest.main()
