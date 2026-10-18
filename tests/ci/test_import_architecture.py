import json
from pathlib import Path
import tempfile
import unittest

from import_architecture import check, cyclic_edges, graph, production_imports


class ImportArchitectureTest(unittest.TestCase):
    def test_repository_production_imports_do_not_add_cycles(self):
        check()

    def test_baseline_test_only_and_new_cycle_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline.json"
            (root / "a.zig").write_text('const b = @import("b.zig");')
            (root / "b.zig").write_text('const a = @import("a.zig");')
            (root / "c.zig").write_text('const a = @import("a.zig");')
            baseline.write_text(json.dumps({"cyclic_edges": [["a.zig", "b.zig"], ["b.zig", "a.zig"]]}))
            check(root, baseline, ("a.zig",))
            # A return edge only in a test must not make c a production cycle.
            with (root / "a.zig").open("a") as output:
                output.write('\ntest "nested { braces }" { if (true) { _ = @import("c.zig"); } }')
            check(root, baseline, ("a.zig",))
            # A new cyclic edge inside an existing SCC is also a regression.
            with (root / "a.zig").open("a") as output:
                output.write('\nconst c = @import("c.zig");')
            with self.assertRaisesRegex(ValueError, "new production cyclic imports"):
                check(root, baseline, ("a.zig",))

    def test_lexical_noise_and_anonymous_tests_do_not_create_dependencies(self):
        source = r'''
// @import("comment.zig") {
const text = "@import(\"string.zig\") }";
const multiline =
    \\ @import("multiline.zig") {
;
test { _ = @import("test.zig"); }
const x = @import("real.zig");
const brace = '}';
test "nested" { const S = struct { fn f() void { _ = @import("nested.zig"); } }; }
const y = @import("after.zig");
'''
        self.assertEqual(production_imports(source), {"real.zig", "after.zig"})

    def test_new_disjoint_and_self_cycles_are_rejected(self):
        self.assertEqual(cyclic_edges({"a": {"b"}, "b": set()}), [])
        self.assertEqual(cyclic_edges({"a": {"b"}, "b": {"a"}, "c": {"c"}}),
                         [["a", "b"], ["b", "a"], ["c", "c"]])

    def test_store_test_adapter_is_not_a_production_dependency(self):
        root = Path(__file__).resolve().parents[2]
        self.assertNotIn("model_adapter.zig", production_imports((root / "src/store.zig").read_text()))
