import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from rsql_collector_fixture import elf


class CollectorSummaryTest(unittest.TestCase):
    def test_ci_98_collector_reports_summary_and_preserves_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "first.elf").write_bytes(elf(b"first\x1c"))
            (root / "second.elf").write_bytes(elf(b"second\x1c"))
            zig = root / "zig"
            zig.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
if any(args[index:index + 2] == ["--summary", "all"] for index in range(len(args) - 1)):
    print("compile-step summary", file=sys.stderr)
prefix = pathlib.Path(args[args.index("--prefix") + 1])
(prefix / "bin").mkdir(parents=True)
for name in ("first", "second"):
    shutil.copyfile(pathlib.Path(os.environ["ELF_FIXTURES"]) / (name + ".elf"), prefix / "bin" / name)
if os.environ.get("FAIL_BUILD") == "1":
    raise SystemExit(7)
''')
            zig.chmod(0o755)
            code = 'import rsql_table,sys; print(sorted(rsql_table.collect(sys.argv[1])))'
            for fail in (False, True):
                with self.subTest(fail=fail):
                    env = dict(os.environ, PYTHONPATH="tests/ci", ELF_FIXTURES=str(root),
                               FAIL_BUILD="1" if fail else "0")
                    result = subprocess.run([sys.executable, "-B", "-c", code, str(zig)],
                                            env=env, text=True, capture_output=True, timeout=20)
                    if fail:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, "")
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("compile-step summary", result.stderr)
                        self.assertEqual(result.stdout, "[b'first\\x1c', b'second\\x1c']\n")


if __name__ == "__main__":
    unittest.main()
