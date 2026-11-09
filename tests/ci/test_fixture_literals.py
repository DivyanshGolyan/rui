"""Fixtures and tests do not restate values another file owns.

A copy of an owned value strands its test when the owner changes on purpose.
Each rule takes its forbidden values from the owner itself, so it follows
every change without edits here:

- numbers src/product_defaults.zig and the shipped catalog decide (default
  capacities, each listed model's context window and default compaction
  triggers): read them through tests/integration/product_defaults.py;
- caller-error catalog prose (src/caller_error.zig `says` and `next`): match
  the line's stable `[code]` and the context the invocation supplies;
- the complete built-in tool list (src/built_in_tool.zig): read the owner;
- a default effort stated as a word beside its "model default" source: read
  product_defaults.start_effort(model).

The Store format and the wire version have their own checks
(test_store_schema_fixtures.py, test_wire_version.py).
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = (("tests/integration", (".py", ".sh")),)
# Zig tests outside the owner, and every fixture.
TOOL_LIST_SCANNED = (("src", (".zig",)), ("tests", (".py", ".sh", ".zig", ".go")))
TOOL_OWNER = "src/built_in_tool.zig"
# A shared run of this many words is a copy of catalog prose, not a
# coincidence: "That is not an ID" or "A required option or selector".
PROSE_WORDS = 5
# Smaller owned numbers (capacities, percents) are too common to tell apart,
# and smaller catalog windows coincide with buffer sizes such as 8192.
SMALLEST_NUMBER = 1000
SMALLEST_WINDOW = 100_000
STRING = re.compile(r'''[rbfu]{0,2}"((?:[^"\\\n]|\\.)*)"|[rbfu]{0,2}'((?:[^'\\\n]|\\.)*)\'''')


def files(root, scanned, skip=()):
    for directory, suffixes in scanned:
        for path in sorted((root / directory).rglob("*")):
            relative = str(path.relative_to(root))
            if path.suffix in suffixes and relative not in skip and "node_modules" not in path.parts:
                yield relative, path.read_text(errors="replace").splitlines()


def owned_numbers(root):
    """Each owned number a fixture could pin, with the owner to read instead."""
    sys.path.insert(0, str(root / "tests/integration"))
    try:
        import product_defaults as owner
    finally:
        sys.path.remove(str(root / "tests/integration"))
    providers = re.search(r"pub const Provider = enum \{([^}]*)\}", (root / "src/provider_name.zig").read_text())
    defaults = owner.DEFAULTS
    numbers = {}
    for name, value in vars(defaults).items():
        if isinstance(value, int):
            numbers[value] = f"DEFAULTS.{name}"
    for provider, tokens in defaults.provider_compaction_triggers.items():
        numbers[tokens] = f"DEFAULTS.provider_compaction_triggers[{provider!r}]"
    models = [(model, repr(model)) for model, row in owner.CATALOG.items()
              if row.openai_listed and owner.context_window(model) >= SMALLEST_WINDOW]
    for model, spelled in [(defaults.recommended_model, "DEFAULTS.recommended_model"), (None, "an unlisted model")] + models:
        numbers.setdefault(owner.context_window(model), f"context_window({spelled})")
        for provider in re.findall(r"\w+", providers[1]):
            numbers.setdefault(owner.compaction_trigger(provider, model), f"compaction_trigger({provider!r}, {spelled})")
    return {value: name for value, name in numbers.items() if value >= SMALLEST_NUMBER}


def number_findings(root, numbers):
    """Each owned number, as digits or grouped by commas as screens print it."""
    spellings = {spelled: value for value in numbers for spelled in (str(value), f"{value:,}")}
    pattern = re.compile(r"(?<![\w.,])(" + "|".join(map(re.escape, sorted(spellings, key=len, reverse=True)))
                         + r")(?![\w]|[.,]\d)")
    findings = []
    for path, lines in files(root, FIXTURES):
        for number, line in enumerate(lines, 1):
            for match in pattern.finditer(line):
                findings.append(f"{path}:{number}: {match[1]} is {numbers[spellings[match[1]]]}: {line.strip()[:100]}")
    return findings


def words(text):
    return re.findall(r"[A-Za-z0-9_'-]+", text)


def catalog_prose(root):
    """The opening PROSE_WORDS words of each caller-error sentence, with the
    codes that say it. Openings, not any run, so other CLI prose that happens
    to share a phrase mid-sentence is not mistaken for the catalog's."""
    source = (root / "src/caller_error.zig").read_text()
    entry = re.compile(r'^\s*\.(\w+) => \.\{.*?\.says = "((?:[^"\\]|\\.)*)", \.next = "((?:[^"\\]|\\.)*)"', re.MULTILINE)
    codes = {}
    for code, says, next_ in entry.findall(source):
        for sentence in re.split(r"(?<=[.?])\s+", says + " " + next_):
            opening = tuple(words(sentence)[:PROSE_WORDS])
            if len(opening) == PROSE_WORDS:
                codes.setdefault(opening, set()).add(code)
    runs = {opening: " or ".join(sorted(names)) for opening, names in codes.items()}
    if not runs:
        raise AssertionError("src/caller_error.zig: no catalog prose found; teach this check the new form")
    return runs


def prose_findings(root, runs):
    findings = []
    for path, lines in files(root, FIXTURES):
        for number, line in enumerate(lines, 1):
            for match in STRING.finditer(line):
                text = words(match[1] if match[1] is not None else match[2] or "")
                code = next((runs[tuple(text[i:i + PROSE_WORDS])] for i in range(len(text) - PROSE_WORDS + 1)
                             if tuple(text[i:i + PROSE_WORDS]) in runs), None)
                if code:
                    findings.append(f"{path}:{number}: [{code}] prose: {line.strip()[:100]}")
                    break
    return findings


def effort_default_findings(root):
    """An effort word written where the source says the model default chose it."""
    grammar = re.search(r"pub const ReasoningEffort = enum \{([^}]*)\}", (root / "src/model_catalog.zig").read_text())
    if grammar is None:
        raise AssertionError("src/model_catalog.zig declares no ReasoningEffort")
    word = re.compile(r"""["'](?:""" + "|".join(re.findall(r"\w+", grammar[1])) + r""")(?: model default)?["']""")
    findings = []
    for path, lines in files(root, FIXTURES):
        for number, line in enumerate(lines, 1):
            if re.search(r"model[_ ]default", line) and word.search(line):
                findings.append(f"{path}:{number}: {line.strip()[:120]}")
    return findings


def built_in_tools(root):
    match = re.search(r"pub const BuiltInTool = enum \{([^}]*)\}", (root / TOOL_OWNER).read_text())
    if match is None:
        raise AssertionError(f"{TOOL_OWNER} declares no BuiltInTool")
    return re.findall(r"\w+", match[1])


def tool_list_findings(root, tools):
    quoted = [re.compile(rf"""["']{tool}["']""") for tool in tools]
    findings = []
    for path, lines in files(root, TOOL_LIST_SCANNED, skip=(TOOL_OWNER,)):
        for number, line in enumerate(lines, 1):
            if all(pattern.search(line) for pattern in quoted):
                findings.append(f"{path}:{number}: {line.strip()[:120]}")
    return findings


class FixtureLiteralsTest(unittest.TestCase):
    def test_no_fixture_restates_an_owned_number(self):
        findings = number_findings(ROOT, owned_numbers(ROOT))
        self.assertEqual(findings, [], "read the value from tests/integration/product_defaults.py instead:\n"
                         + "\n".join(findings))

    def test_no_fixture_restates_caller_error_prose(self):
        findings = prose_findings(ROOT, catalog_prose(ROOT))
        self.assertEqual(findings, [], "assert the line's [code] and the context the invocation supplies, "
                         "not src/caller_error.zig's sentences:\n" + "\n".join(findings))

    def test_no_test_lists_every_built_in_tool(self):
        findings = tool_list_findings(ROOT, built_in_tools(ROOT))
        self.assertEqual(findings, [], f"read the list from {TOOL_OWNER} (BuiltInTool, or tools.built_in in Zig) "
                         "instead:\n" + "\n".join(findings))

    def test_no_fixture_restates_a_default_effort(self):
        findings = effort_default_findings(ROOT)
        self.assertEqual(findings, [], "read product_defaults.start_effort(model) instead:\n" + "\n".join(findings))

    def test_each_rule_sees_its_forms(self):
        numbers = {244800: "trigger", 128000: "window"}
        runs = {tuple(words("That option is not supported")): "option_unknown"}
        lines = {
            "tests/integration/pinned.py": [
                '"compaction_trigger": {"state": "value", "value": "244800"},',
                "large = 'x' * 128000",
                'assert "--x: That option is not supported" in stderr',
                "assert b': That option is not supported by this command.' in out",
                "tools = ['bash', 'skill', 'web_search']",
                'assert compact.startswith("244,800 tokens")',
                '(("--model", "m"), "m", "low", "model_default"),',
                'assert row == "low model default"',
                # Clean: owner reads, codes, near numbers and short phrases.
                "value = str(compaction_trigger('codex', model))",
                'assert "[option_unknown]" in stderr and "not supported" in stderr',
                "port = 1244800; size = 128000.5; name = 'a_128000'; grouped = '1,244,800'",
                'assert row == f"{start_effort(m)} model default"; assert source == "flag"',
            ],
            "src/store/pinned_tests.zig": ['&.{ "bash", "skill", "web_search" }', "&.{ bash, skill, web_search }"],
        }
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path, text in lines.items():
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text("\n".join(text) + "\n")
            line_numbers = lambda findings: [(f.split(":")[0], int(f.split(":")[1])) for f in findings]
            self.assertEqual(line_numbers(number_findings(root, numbers)),
                             [("tests/integration/pinned.py", 1), ("tests/integration/pinned.py", 2),
                              ("tests/integration/pinned.py", 6)])
            self.assertEqual(line_numbers(prose_findings(root, runs)),
                             [("tests/integration/pinned.py", 3), ("tests/integration/pinned.py", 4)])
            (root / "src/model_catalog.zig").write_text("pub const ReasoningEffort = enum { none, low, high };\n")
            self.assertEqual(line_numbers(effort_default_findings(root)),
                             [("tests/integration/pinned.py", 7), ("tests/integration/pinned.py", 8)])
            self.assertEqual(line_numbers(tool_list_findings(root, ["bash", "skill", "web_search"])),
                             [("src/store/pinned_tests.zig", 1), ("tests/integration/pinned.py", 5)])

    def test_readers_see_every_owner(self):
        """An owner whose form the readers stop parsing must fail here, not
        leave a rule silently empty."""
        sys.path.insert(0, str(ROOT / "tests/integration"))
        try:
            from product_defaults import DEFAULTS, context_window
        finally:
            sys.path.remove(str(ROOT / "tests/integration"))
        numbers = owned_numbers(ROOT)
        for owned in (*DEFAULTS.provider_compaction_triggers.values(), context_window(DEFAULTS.recommended_model)):
            self.assertIn(owned, numbers)
        self.assertTrue(catalog_prose(ROOT))
        self.assertTrue(built_in_tools(ROOT))

if __name__ == "__main__":
    unittest.main()
