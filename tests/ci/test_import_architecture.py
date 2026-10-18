import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from import_architecture import check, cyclic_edges, production_imports


class ImportArchitectureTest(unittest.TestCase):
    def test_repository_production_imports_do_not_add_cycles(self):
        check()

    def test_baseline_test_only_and_new_cycle_controls(self):
        with tempfile.TemporaryDirectory() as directory, patch(
            "import_architecture.trusted_allowance", create=True,
            return_value=[["a.zig", "b.zig"], ["b.zig", "a.zig"]],
        ):
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
            # Extending an existing cycle through another module is a regression.
            with (root / "a.zig").open("a") as output:
                output.write('\nconst c = @import("c.zig");')
            with self.assertRaisesRegex(ValueError, "new production cyclic imports"):
                check(root, baseline, ("a.zig",))

    def test_root_alias_and_explicit_root_return_paths_are_both_cycles(self):
        for declaration, imported in ((declaration, imported)
                                      for declaration in ('test', 'test "nested"')
                                      for imported in ("root", "a.zig")):
            with self.subTest(declaration=declaration, imported=imported), tempfile.TemporaryDirectory() as directory, patch(
                "import_architecture.trusted_allowance", create=True, return_value=[],
            ):
                root = Path(directory)
                baseline = root / "baseline.json"
                baseline.write_text('{"cyclic_edges": []}')
                (root / "a.zig").write_text('const b = @import("b.zig");')
                (root / "c.zig").write_text('const value = 1;')
                source = f'''{declaration} {{
    const S = struct {{ {declaration} {{ _ = @import("std"); }} }};
    _ = S;
    _ = @import("{imported}");
}}
const c = @import("c.zig");'''
                (root / "b.zig").write_text(source)
                self.assertEqual(check(root, baseline, ("a.zig",))["modules"], 3)
                (root / "b.zig").write_text(source + f'\nconst a = @import("{imported}");')
                with self.assertRaisesRegex(ValueError, "new production cyclic imports"):
                    check(root, baseline, ("a.zig",))

    def test_candidate_cannot_enlarge_allowance_from_trusted_git_base(self):
        for bootstrap in (True, False):
            with self.subTest(bootstrap=bootstrap), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                baseline = root / "baseline.json"
                if not bootstrap:
                    baseline.write_text('{"cyclic_edges": []}')
                (root / "a.zig").write_text('const b = @import("b.zig");')
                (root / "b.zig").write_text('const value = 1;')
                git = ["git", "-C", str(root)]
                subprocess.run(git + ["init", "-q"], check=True)
                subprocess.run(git + ["add", "."], check=True)
                subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                      "commit", "-qm", "trusted baseline"], check=True)
                subprocess.run(git + ["update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
                trusted = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                baseline.write_text('{"cyclic_edges": []}')
                with patch("import_architecture.BOOTSTRAP_BASE", trusted):
                    check(root, baseline, ("a.zig",))
                    (root / "b.zig").write_text('const a = @import("a.zig");')
                    baseline.write_text(json.dumps({"cyclic_edges": [["a.zig", "b.zig"], ["b.zig", "a.zig"]]}))
                    with self.assertRaisesRegex(ValueError, "cycle allowance grew"):
                        check(root, baseline, ("a.zig",))

    def test_removed_cycles_must_also_remove_their_allowance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "a.zig").write_text('const value = 1;')
            baseline = root / "baseline.json"
            baseline.write_text('{"cyclic_edges": [["a.zig", "a.zig"]]}')
            with self.assertRaisesRegex(ValueError, "remove stale cycle allowance"):
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
