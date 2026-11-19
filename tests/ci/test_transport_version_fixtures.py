from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OWNER_FILE = "src/h2/h2.zig"
OWNER = re.compile(r'^pub const nghttp2_version = "([^"]+)";$', re.MULTILINE)
SCANNED = (("tests/integration", (".py", ".sh", ".go")), ("tests/qualification", (".py", ".sh", ".go")))
# "nghttp2": "1.70.0" covers Python dicts and Go map literals; nghttp2=1.70.0 covers readiness lines.
PINNED = re.compile(r'''["']nghttp2["']\s*[:=]\s*["'](\d+\.\d+\.\d+)["']|\bnghttp2=(\d+\.\d+\.\d+)\b''')
ALLOWED_FAKES = {"9.9.9"}


def owner_version(root):
    matches = OWNER.findall((root / OWNER_FILE).read_text())
    if len(matches) != 1:
        raise AssertionError(f"{OWNER_FILE} declares {len(matches)} nghttp2_version values")
    return matches[0]


def pin_findings(root):
    findings = []
    for directory, suffixes in SCANNED:
        for path in sorted((root / directory).rglob("*")):
            if not path.is_file() or path.suffix not in suffixes:
                continue
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                for match in PINNED.finditer(line):
                    if (match[1] or match[2]) not in ALLOWED_FAKES:
                        findings.append(f"{path.relative_to(root)}:{number}: {line.strip()[:120]}")
    return findings


class TransportVersionFixturesTest(unittest.TestCase):
    def test_fixtures_read_the_owner(self):
        sys.path.insert(0, str(ROOT / "tests/integration"))
        try:
            import host_process
        finally:
            sys.path.remove(str(ROOT / "tests/integration"))
        version = owner_version(ROOT)
        self.assertEqual(host_process.NGHTTP2_VERSION, version)
        self.assertEqual(host_process.READY_TRANSPORT, {"execution": "enabled", "nghttp2": version})

    def test_no_fixture_pins_nghttp2(self):
        findings = pin_findings(ROOT)
        self.assertEqual(findings, [], "read host_process.READY_TRANSPORT (fixtures) instead of an nghttp2 "
                         "version literal:\n" + "\n".join(findings))

    def test_the_pin_check_sees_each_form(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests/integration").mkdir(parents=True)
            (root / "tests/qualification").mkdir(parents=True)
            (root / "tests/integration/pinned.py").write_text(
                'required = {"execution": "enabled", "nghttp2": "1.70.0"}\n'
                "required = {'nghttp2': '1.70.0'}\n"
                "print('ready execution=enabled nghttp2=1.70.0')\n"
                'fields = {"execution": "enabled", "nghttp2": "9.9.9"}\n'
                "print('ready execution=enabled nghttp2=9.9.9')\n")
            (root / "tests/integration/pinned.sh").write_text("echo nghttp2=1.70.0\n")
            (root / "tests/qualification/pinned.go").write_text(
                'map[string]string{"h2": "rui", "nghttp2": "1.70.0"}\n')
            (root / "tests/integration/notes.txt").write_text('"nghttp2": "1.70.0"\n')
            findings = pin_findings(root)
        self.assertEqual([finding.split(":")[:2] for finding in findings],
                         [["tests/integration/pinned.py", "1"], ["tests/integration/pinned.py", "2"],
                          ["tests/integration/pinned.py", "3"], ["tests/integration/pinned.sh", "1"],
                          ["tests/qualification/pinned.go", "1"]])


if __name__ == "__main__":
    unittest.main()
