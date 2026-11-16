import ast
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
with patch.object(sys, "argv", [__file__, "/candidate/rui"]):
    import model_fixture


SOURCE = '''pub const BuiltinInstructions = enum {
    generic,
    first,
    second,

    pub fn bytes(self: BuiltinInstructions) []const u8 {
        return switch (self) {
            .generic => "",
            .first, .second => @embedFile("model_instructions/shared.txt"),
        };
    }
};

pub fn builtinInstructions(model: []const u8) BuiltinInstructions {
    const reviewed = .{
        .{ "fixture-model", BuiltinInstructions.first },
        .{ "other-model", BuiltinInstructions.second },
    };
    inline for (reviewed) |entry| if (std.mem.eql(u8, model, entry[0])) return entry[1];
    return .generic;
}
'''


class ModelInstructionFixtureTest(unittest.TestCase):
    def test_selection_and_shared_asset_follow_source(self):
        self.assertEqual(model_fixture._builtin_instruction_paths(SOURCE), {
            "fixture-model": "model_instructions/shared.txt",
            "other-model": "model_instructions/shared.txt",
        })
        changed = SOURCE.replace('"fixture-model"', '"new-model"').replace("shared.txt", "changed.txt")
        self.assertEqual(model_fixture._builtin_instruction_paths(changed), {
            "new-model": "model_instructions/changed.txt",
            "other-model": "model_instructions/changed.txt",
        })

        smaller = SOURCE.replace('        .{ "other-model", BuiltinInstructions.second },', "")
        self.assertEqual(model_fixture._builtin_instruction_paths(smaller), {
            "fixture-model": "model_instructions/shared.txt"})

    def test_unsupported_source_never_falls_back_to_generic(self):
        changes = (
            ("BuiltinInstructions = enum", "BuiltinInstructions = struct"),
            ("return switch (self)", "return switch (other)"),
            (".generic => \"\"", '.generic => @embedFile("model_instructions/shared.txt")'),
            (".first, .second =>", ".first =>"),
            ("    second,", "    first,"),
            (".first, .second =>", ".first, .second, .missing =>"),
            ("shared.txt", "../shared.txt"),
            ("BuiltinInstructions.second },", "BuiltinInstructions.missing },"),
            ('"other-model"', '"fixture-model"'),
            ("return entry[1]", "return .generic"),
            ("return .generic;", "return .first;"),
            ("    const reviewed", "    // unsupported shape\n    const reviewed"),
        )
        for before, after in changes:
            with self.subTest(before=before, after=after):
                changed = SOURCE.replace(before, after)
                with self.assertRaisesRegex(ValueError, "src/model_catalog.zig"):
                    model_fixture._builtin_instruction_paths(changed)
        for changed in ("", SOURCE + SOURCE, SOURCE.replace("            .generic => \"\",", ""),
                        SOURCE.replace('        .{ "fixture-model", BuiltinInstructions.first },', "")
                        .replace('        .{ "other-model", BuiltinInstructions.second },', "")):
            with self.subTest(source=changed):
                with self.assertRaisesRegex(ValueError, "src/model_catalog.zig"):
                    model_fixture._builtin_instruction_paths(changed)

    def test_composition_uses_known_model_and_independent_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "model_instructions").mkdir()
            body = 'Literal {} "body"\\\n雪'
            (root / "model_instructions/shared.txt").write_text(body)
            paths = model_fixture._builtin_instruction_paths(SOURCE)
            with patch.object(model_fixture, "_INSTRUCTION_ROOT", root), patch.object(model_fixture, "_INSTRUCTION_PATHS", paths):
                self.assertEqual(model_fixture.builtin_instructions("fixture-model"), body)
                for model in ("unknown-model", "FIXTURE-MODEL", "fixture-model-extra", "namespace/fixture-model"):
                    self.assertEqual(model_fixture.builtin_instructions(model), "")
                workspace = '/workspace/"quoted"\\雪\n'
                prefix, address, middle, suffix = model_fixture.MODEL_CONTEXT_PARTS
                expected = prefix + '/workspace/\\"quoted\\"\\\\雪\\n' + address + "k7m2qx" + middle + body + suffix + "caller rules"
                self.assertEqual(model_fixture.model_instructions(
                    workspace, "caller rules", store=None, session="k7m2qx", model="fixture-model"), expected)
                with self.assertRaises(TypeError):
                    model_fixture.model_instructions(workspace, store=None, session="k7m2qx")

    def test_every_python_caller_supplies_its_model(self):
        for path in (ROOT / "tests/integration").glob("*.py"):
            tree = ast.parse(path.read_text())
            local = {node.name for node in tree.body if isinstance(node, ast.FunctionDef)}
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                function = node.func
                direct = isinstance(function, ast.Name) and function.id == "model_instructions" and function.id not in local
                qualified = isinstance(function, ast.Attribute) and function.attr == "model_instructions"
                if direct or qualified:
                    with self.subTest(path=path.name, line=node.lineno):
                        self.assertIn("model", [keyword.arg for keyword in node.keywords])
