"""The wire version has one owner, src/wire_version.zig, and moves only past a release.

Every Zig test, fixture and qualification harness reads the owner, so a bump
edits one line. A new release-gated number is spent only once per release:
concurrent PRs share main's unreleased number instead of racing to bump it.
Changes to the generated wire contract since that release require a newer number.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import unittest

from release_numbers import bump_error, git, main_base, released_tag

ROOT = Path(__file__).resolve().parents[2]
OWNER = re.compile(r'^pub const wire_version = "(\d+)";$', re.MULTILINE)
GO_OWNER = re.compile(r'^const WireVersion = "(\d+)"$', re.MULTILINE)
GO_OWNER_FILE = "tests/qualification/measurement/measurement.go"
OWNER_FILE = "src/wire_version.zig"
# Where releases cut before the owner moved declared it.
EARLIER_OWNER_FILE = "src/protocol.zig"
NAME = "wire_version"
HEADER = r'Wire-Version\\?"?\s*:\s*\\?"?\d'
# Literal version digits, per language, in the forms the wire takes in source.
LITERALS = (
    ("src", (".zig",), re.compile(r'\\"(?:version|vers\\\\u0069on)\\":\s*(?:\\")?\d|\.version\s*=\s*"\d|' + HEADER, re.I)),
    ("tests/integration", (".py", ".sh"), re.compile(
        r"""\\?["']version\\?["']\s*:\s*\\?["']?\d|\bversion\s*=\s*["']\d|\[["']version["']\]\s*==?\s*["']\d|"""
        + HEADER, re.I)),
    ("tests/qualification", (".go",), re.compile(r'\bVersion:\s*"\d|\\?"version\\?":\s*\\?"?\d|' + HEADER, re.I)),
)


def wire_version(source):
    match = OWNER.search(source)
    if match is None:
        raise AssertionError(f"{OWNER_FILE} declares no wire_version")
    return int(match[1])


def wire_version_at(revision):
    """The wire version a commit declares, from the owner file it had."""
    for path in (OWNER_FILE, EARLIER_OWNER_FILE):
        if subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{revision}:{path}"],
                          capture_output=True).returncode == 0:
            return wire_version(git(ROOT, "show", f"{revision}:{path}"))
    raise AssertionError(f"{revision} has no {OWNER_FILE}")


def normalized_contract(document):
    """Ignore release labels and prose, retaining every wire constraint."""
    documentation = {"description", "summary", "example", "examples"}

    def normalize(value, path=()):
        if isinstance(value, dict):
            return {key: normalize(item, (*path, key)) for key, item in value.items()
                    if key not in documentation and (*path, key) != ("info", "version")}
        if isinstance(value, list):
            return [normalize(item, (*path, index)) for index, item in enumerate(value)]
        return value

    return normalize(document)


def first_difference(released, candidate, path="$"):
    """The first differing JSON path, in deterministic object-key order."""
    if type(released) is not type(candidate):
        return path
    if isinstance(released, dict):
        for key in sorted(released.keys() | candidate.keys()):
            child = f"{path}[{json.dumps(key)}]"
            if key not in released or key not in candidate:
                return child
            difference = first_difference(released[key], candidate[key], child)
            if difference is not None:
                return difference
    elif isinstance(released, list):
        for index, (before, after) in enumerate(zip(released, candidate)):
            difference = first_difference(before, after, f"{path}[{index}]")
            if difference is not None:
                return difference
        if len(released) != len(candidate):
            return f"{path}[{min(len(released), len(candidate))}]"
    elif released != candidate:
        return path
    return None


def wire_contract_error(tag, released, candidate, released_document, candidate_document):
    """A changed released contract requires a newer owner-declared wire version."""
    difference = first_difference(normalized_contract(released_document),
                                  normalized_contract(candidate_document))
    if difference is not None and candidate <= released:
        return (f"wire contract differs from release {tag} (wire_version {released}) at {difference}, "
                f"but wire_version is {candidate}; set src/wire_version.zig to {released + 1}, "
                "regenerate openapi.json")
    return None


def literal_findings(root):
    findings = []
    for directory, suffixes, pattern in LITERALS:
        for path in sorted((root / directory).rglob("*")):
            if path.suffix not in suffixes:
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if pattern.search(line):
                    findings.append(f"{path.relative_to(root)}:{number}: {line.strip()[:120]}")
    return findings


class WireVersionTest(unittest.TestCase):
    def test_no_literal_wire_version_outside_the_owner(self):
        findings = literal_findings(ROOT)
        self.assertEqual(findings, [], "read protocol.wire_version (Zig), host_process.WIRE_VERSION "
                         "(fixtures) or measurement.WireVersion (Go) instead:\n" + "\n".join(findings))

    def test_the_literal_check_sees_each_form(self):
        cases = {
            ".zig": ['"{\\"version\\":\\"4\\",\\"type\\":\\"busy\\"}"', '"{\\"version\\":4}"',
                     '"{\\"vers\\\\u0069on\\":\\"4\\"}"', '"X-Rui-Wire-Version: 4\\r\\n"',
                     '"{\\"version\\": \\"4\\"}"', '.{ .version = "4" }'],
            ".py": ['{"version": "4"}', "{'version': '4'}", 'b\'{"version":"4"}\'', 'dict(version="4")',
                    'page["version"] = "2"', 'value["version"] == "4"', 'b"X-Rui-Wire-Version : 3\\r\\n"',
                    '{"X-Rui-Wire-Version": "4"}'],
            ".go": ['Request{Version: "4"}', '`{"version":"4"}`', '"X-Rui-Wire-Version: 4\\r\\n"', '`{"version": "4"}`'],
        }
        clean = {".zig": ['"{\\"version\\":\\"" ++ protocol.wire_version ++ "\\"}"'],
                 ".py": ['{"version": host_process.WIRE_VERSION}', 'b"version=1\\nstore=\\n"', "version=0 if x else 1"],
                 ".go": ["Request{Version: measurement.WireVersion}", 'const WireVersion = "4"']}
        patterns = {suffix: pattern for _, suffixes, pattern in LITERALS for suffix in suffixes}
        for suffix, lines in cases.items():
            for line in lines:
                self.assertRegex(line, patterns[suffix])
        for suffix, lines in clean.items():
            for line in lines:
                self.assertNotRegex(line, patterns[suffix])

    def test_fixtures_and_qualification_read_the_owner(self):
        owner = wire_version((ROOT / OWNER_FILE).read_text())
        go = GO_OWNER.search((ROOT / GO_OWNER_FILE).read_text())
        self.assertIsNotNone(go, f"{GO_OWNER_FILE} declares no WireVersion")
        self.assertEqual(int(go[1]), owner, f"{GO_OWNER_FILE} WireVersion must equal {OWNER_FILE}'s wire_version")
        sys.path.insert(0, str(ROOT / "tests/integration"))
        try:
            import host_process
        finally:
            sys.path.remove(str(ROOT / "tests/integration"))
        self.assertEqual(host_process.WIRE_VERSION, str(owner))

    def test_bump_rule(self):
        self.assertIsNone(bump_error(NAME, 4, 4, 4))
        self.assertIsNone(bump_error(NAME, 5, 4, 4), "one past the release is a fresh bump")
        self.assertIsNone(bump_error(NAME, 5, 5, 4), "a PR shares main's unreleased number")
        self.assertIsNotNone(bump_error(NAME, 6, 5, 4), "a second bump before a release")
        self.assertIsNotNone(bump_error(NAME, 6, 4, 4), "a skipped number")
        self.assertIsNone(bump_error(NAME, 4, 4, 2), "main already past the release is not the PR's bump")
        self.assertIsNotNone(bump_error(NAME, 5, 4, 2))
        self.assertIsNotNone(bump_error(NAME, 3, 4, 2), "a downgrade below main")

    def test_wire_contract_comparison(self):
        cases = (
            ("enum added without bump", {"enum": ["old"]}, {"enum": ["old", "new"]}, 13, '$["enum"][1]'),
            ("enum added with bump", {"enum": ["old"]}, {"enum": ["old", "new"]}, 14, None),
            ("documentation at every depth", {"description": "before", "items": [{"summary": "old"}]},
             {"description": "after", "items": [{"summary": "new", "example": 1, "examples": [2]}]}, 13, None),
            ("wire bound changed", {"items": {"x-rui-max-bytes": 10}},
             {"items": {"x-rui-max-bytes": 20}}, 13, '$["items"]["x-rui-max-bytes"]'),
            ("release label only", {"info": {"version": "13"}}, {"info": {"version": "14"}}, 13, None),
            ("nested version is wire", {"items": {"info": {"version": "a"}}},
             {"items": {"info": {"version": "b"}}}, 13, '$["items"]["info"]["version"]'),
            ("wire field removed", {"required": True}, {}, 13, '$["required"]'),
            ("JSON type changed", {"value": 1}, {"value": True}, 13, '$["value"]'),
            ("enum removed", {"enum": ["old", "new"]}, {"enum": ["old"]}, 13, '$["enum"][1]'),
            ("object order only", {"a": 1, "b": 2}, {"b": 2, "a": 1}, 13, None),
        )
        for name, before, after, candidate, path in cases:
            with self.subTest(name=name):
                error = wire_contract_error("v0.69.1", 13, candidate, before, after)
                if path is None:
                    self.assertIsNone(error)
                else:
                    self.assertEqual(error, f"wire contract differs from release v0.69.1 (wire_version 13) at {path}, "
                                     f"but wire_version is {candidate}; set src/wire_version.zig to 14, "
                                     "regenerate openapi.json")

    def test_wire_contract_changes_bump_wire_version(self):
        tag = released_tag(ROOT)
        if tag is None:
            self.skipTest("no v* release tags in this checkout; the policy job checks out with fetch-depth 0")
        if main_base(ROOT) is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        if subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{tag}:openapi.json"],
                          capture_output=True).returncode:
            self.skipTest(f"release {tag} has no openapi.json")
        released_document = json.loads(git(ROOT, "show", f"{tag}:openapi.json"))
        candidate_document = json.loads((ROOT / "openapi.json").read_text())
        error = wire_contract_error(tag, wire_version_at(tag), wire_version((ROOT / OWNER_FILE).read_text()),
                                    released_document, candidate_document)
        if error:
            self.fail(error)

    def test_wire_version_moves_once_per_release(self):
        tag = released_tag(ROOT)
        if tag is None:
            self.skipTest("no v* release tags in this checkout; the policy job checks out with fetch-depth 0")
        base_commit = main_base(ROOT)
        if base_commit is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        released = wire_version_at(tag)
        base = wire_version_at(base_commit)
        candidate = wire_version((ROOT / OWNER_FILE).read_text())
        error = bump_error(NAME, candidate, base, released)
        if error:
            self.fail(f"{error} (release {tag}, main at {base_commit[:12]})")


if __name__ == "__main__":
    unittest.main()
