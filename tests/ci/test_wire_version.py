"""The wire version has one owner, src/protocol.zig, and moves only past a release.

Every Zig test, fixture and qualification harness reads the owner, so a bump
edits one line. A new release-gated number is spent only once per release:
concurrent PRs share main's unreleased number instead of racing to bump it.
"""
from pathlib import Path
import re
import sys
import unittest

from release_numbers import bump_error, git, main_base, released_tag

ROOT = Path(__file__).resolve().parents[2]
OWNER = re.compile(r'^pub const wire_version = "(\d+)";$', re.MULTILINE)
GO_OWNER = re.compile(r'^const WireVersion = "(\d+)"$', re.MULTILINE)
GO_OWNER_FILE = "tests/qualification/measurement/measurement.go"
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
        raise AssertionError("src/protocol.zig declares no wire_version")
    return int(match[1])


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
        owner = wire_version((ROOT / "src/protocol.zig").read_text())
        go = GO_OWNER.search((ROOT / GO_OWNER_FILE).read_text())
        self.assertIsNotNone(go, f"{GO_OWNER_FILE} declares no WireVersion")
        self.assertEqual(int(go[1]), owner, f"{GO_OWNER_FILE} WireVersion must equal protocol.zig's wire_version")
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

    def test_wire_version_moves_once_per_release(self):
        tag = released_tag(ROOT)
        if tag is None:
            self.skipTest("no v* release tags in this checkout; the policy job checks out with fetch-depth 0")
        base_commit = main_base(ROOT)
        if base_commit is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        released = wire_version(git(ROOT, "show", f"{tag}:src/protocol.zig"))
        base = wire_version(git(ROOT, "show", f"{base_commit}:src/protocol.zig"))
        candidate = wire_version((ROOT / "src/protocol.zig").read_text())
        error = bump_error(NAME, candidate, base, released)
        if error:
            self.fail(f"{error} (release {tag}, main at {base_commit[:12]})")


if __name__ == "__main__":
    unittest.main()
