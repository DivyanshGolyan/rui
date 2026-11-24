import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


def elf(record):
    names = b"\0rsqlstmt_fixture\0"
    start = 64 + 4 * 64
    symbol_offset = start + len(names)
    data_offset = symbol_offset + 24
    image = bytearray(data_offset + len(record))
    image[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<Q", image, 0x28, 64)
    struct.pack_into("<HH", image, 0x3a, 64, 4)
    section = struct.Struct("<IIQQQQIIQQ")
    section.pack_into(image, 64 + 64, 0, 3, 0, 0, start, len(names), 0, 0, 1, 0)
    section.pack_into(image, 64 + 2 * 64, 0, 2, 0, 0, symbol_offset, 24, 1, 0, 8, 24)
    section.pack_into(image, 64 + 3 * 64, 0, 1, 0, 4096, data_offset, len(record), 0, 0, 1, 0)
    image[start:symbol_offset] = names
    struct.pack_into("<IBBHQQ", image, symbol_offset, 1, 0, 0, 3, 4096, len(record))
    image[data_offset:] = record
    return image


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
if args[-2:] == ["--summary", "all"]:
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
