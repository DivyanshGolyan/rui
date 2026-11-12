"""Core names no provider detail: see provider_locality.py."""
import unittest

from provider_locality import ALLOWED, CODEC_RULES, RULES, SRC, codec_violations, production, violations


class ProviderLocalityTest(unittest.TestCase):
    def test_core_names_no_provider_detail(self):
        found = violations()
        self.assertEqual(found, [], "core special-cases a provider; ask the provider table or sign-in source:\n"
                         + "\n".join(found))

    def test_codecs_treat_every_model_alike(self):
        found = codec_violations()
        self.assertEqual(found, [], "a codec branches on the model; put the fact in model_capability.zig:\n"
                         + "\n".join(found))

    def test_a_codec_rule_catches_what_it_names(self):
        code = production('const models = [_][]const u8{"gpt-5.5"};\n'
                          'const p = parallel(settings.modelName());\n'
                          'test "x" {\n    _ = "GPT-6.1-sol";\n}\n'
                          'const q = "gpt"; // "o3-mini"\n'
                          'const r =\n    \\\\codex-mini\n;\n'
                          'const s = "O0 k1";\n')
        hits = [(name, match.group(0)) for name, pattern in CODEC_RULES for match in pattern.finditer(code)]
        self.assertEqual(hits, [("reads the model name", "modelName("), ("names a model", '"gpt-5.5"'),
                                ("names a model", '"gpt"'), ("names a model", "\\\\codex-mini")])

    def test_a_rule_catches_what_it_names(self):
        code = production('const a = @import("codex_auth.zig");\n'
                          'test "x" {\n    const b = "usage_limit_reached";\n}\n'
                          'const S = struct {\n    test {\n        _ = Provider.codex;\n    }\n};\n'
                          'const c = "x-codex-turn-state"; // usage_limit_reached\n'
                          'const d = "https://chatgpt.com/backend-api";\n'
                          'const e = switch (p) { .openai => 1 };\n')
        hits = [name for name, pattern in RULES if pattern.search(code)]
        self.assertEqual(hits, ["imports a sign-in file", "names a ChatGPT or Codex header",
                                "names a ChatGPT endpoint", "switches on a provider"])
        # Blanked tests keep every later line at its own number.
        self.assertEqual(code.count("\n"), 12)
        self.assertIn("x-codex", code.splitlines()[9])

    def test_every_allowance_is_still_needed(self):
        for relative, name in ALLOWED:
            pattern = dict(RULES)[name]
            self.assertTrue(pattern.search(production((SRC / relative).read_text())),
                            f"src/{relative} no longer {name}; drop its allowance")
