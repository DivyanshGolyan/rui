"""Core names no provider detail: see provider_locality.py."""
import unittest

from provider_locality import ALLOWED, RULES, SRC, production, violations


class ProviderLocalityTest(unittest.TestCase):
    def test_core_names_no_provider_detail(self):
        found = violations()
        self.assertEqual(found, [], "core special-cases a provider; ask the provider table or sign-in source:\n"
                         + "\n".join(found))

    def test_a_rule_catches_what_it_names(self):
        code = production('const a = @import("codex_auth.zig");\n'
                          'test "x" {\n    const b = "usage_limit_reached";\n}\n'
                          'const c = "x-codex-turn-state"; // usage_limit_reached\n')
        hits = [name for name, pattern in RULES if pattern.search(code)]
        self.assertEqual(hits, ["imports a sign-in file", "names a ChatGPT or Codex header"])

    def test_every_allowance_is_still_needed(self):
        for relative, name in ALLOWED:
            pattern = dict(RULES)[name]
            self.assertTrue(pattern.search(production((SRC / relative).read_text())),
                            f"src/{relative} no longer {name}; drop its allowance")
