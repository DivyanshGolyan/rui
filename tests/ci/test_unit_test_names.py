import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("unit_test_names", ROOT / "tests/ci/unit_test_names.py")
names = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(names)


def metadata(items):
    strings = b"\0"
    offsets = []
    for item in items:
        offsets.append(len(strings))
        strings += item.encode() + b"\0"
    return (struct.pack("<II", len(strings), len(items)) +
            b"".join(struct.pack("<I", offset) for offset in offsets) +
            bytes(4 * len(items)) + strings)


def message(tag, body):
    return struct.pack("<II", tag, len(body)) + body


class MetadataTest(unittest.TestCase):
    def test_names_preserve_duplicates_and_unicode(self):
        expected = ["root.test_0", "nested.Inner.test.λ", "root.test_0"]
        self.assertEqual(names.parse_stream(message(0, b"0.17.0") + message(3, metadata(expected))), expected)

    def test_malformed_metadata(self):
        for body in (b"", metadata(["a"])[:-1], struct.pack("<IIII", 1, 1, 9, 0) + b"\0",
                     struct.pack("<IIII", 1, 1, 0, 0) + b"a"):
            with self.subTest(body=body), self.assertRaises(ValueError):
                names.parse_metadata(body)

    def test_malformed_stream(self):
        for data in (b"", b"a", message(3, metadata([]))[:-1], message(9, b""),
                     message(3, metadata([])) * 2, struct.pack("<II", 3, names.MAX_BYTES + 1)):
            with self.subTest(data=data), self.assertRaises(ValueError):
                names.parse_stream(data)

    def test_counter_compare(self):
        names.compare(["a", "a", "b"], ["b", "a", "a"])
        for after in (["a", "b"], ["a", "a", "b", "b"], ["a", "a", "c"]):
            with self.assertRaisesRegex(ValueError, "inventory mismatch"):
                names.compare(["a", "a", "b"], after)

    @unittest.skipIf(os.name == "nt", "executable fixture uses a POSIX shebang")
    def test_query_errors_and_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "fake runner"
            def write(body):
                script.write_text("#!" + sys.executable + "\n" + body)
                script.chmod(0o755)
            write("import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(" + repr(message(3, metadata(["a"]))) + ")\n")
            self.assertEqual(names.query(script), ["a"])
            write("import time\ntime.sleep(10)\n")
            with self.assertRaisesRegex(ValueError, "timed out"):
                names.query(script, timeout=0.05)
            write("raise SystemExit(7)\n")
            with self.assertRaisesRegex(ValueError, "failed "):
                names.query(script)
            write("import sys\nsys.stdout.buffer.write(b'x' * 100)\n")
            with patch.object(names, "MAX_BYTES", 32), self.assertRaisesRegex(ValueError, "size limit"):
                names.query(script)

    def test_cli_compare_and_dump(self):
        with patch.object(names, "query", side_effect=[["a", "b"], ["b"], ["a"]]):
            self.assertEqual(names.main(["before", "one", "two"]), 0)
        with patch.object(names, "query", return_value=["a", "a"]), patch("builtins.print") as output:
            self.assertEqual(names.main(["before", "--dump"]), 0)
            self.assertEqual(json.loads(output.call_args.args[0]), ["a", "a"])
        with patch.object(names, "query", side_effect=[["a"], ["b"]]):
            self.assertEqual(names.main(["before", "after"]), 1)


@unittest.skipUnless(shutil.which("zig") and os.environ.get("RUI_TEST_ZIG_METADATA_PROBE") == "1",
                     "set RUI_TEST_ZIG_METADATA_PROBE=1 with zig on PATH for compiler probe")
class CompilerProbe(unittest.TestCase):
    def test_partition_inventory(self):
        zig = shutil.which("zig")
        with tempfile.TemporaryDirectory(prefix="unit metadata ") as directory:
            root = Path(directory)
            (root / "nested").mkdir()
            # The monolith initially discovers hidden only through a named body.
            (root / "aggregate.zig").write_text('test { _ = @import("alpha.zig"); _ = @import("nested/beta.zig"); }\ntest "root named" {}\n')
            (root / "alpha.zig").write_text('test "mentions nested.beta.test. prefix" { _ = @import("hidden.zig"); }\nconst Inner = struct { test "nested" {} };\ntest { _ = Inner; }\n')
            (root / "hidden.zig").write_text('test "discovered from named body" {}\n')
            (root / "nested/beta.zig").write_text('test "beta named" {}\ntest {}\n')
            environment = subprocess.check_output([zig, "env"], timeout=20).decode()
            # Zig 0.17 emits ZON; older versions emitted JSON.
            if environment.lstrip().startswith(".{"):
                lib = json.loads(re.search(r'\.lib_dir = ("(?:[^"\\]|\\.)*")', environment).group(1))
            else:
                lib = json.loads(environment)["lib_dir"]
            spec = importlib.util.spec_from_file_location("generator", ROOT / "tests/ci/unit_test_runner.py")
            generator = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(generator)
            (root / "runner.zig").write_text(generator.generate((Path(lib) / "compiler/test_runner.zig").read_text()))
            (root / "partition.zig").write_text('const std = @import("std"); pub const Root = enum { aggregate, alpha, beta }; pub fn owner(n: []const u8) Root { if (std.mem.startsWith(u8,n,"alpha.")) return .alpha; if (std.mem.startsWith(u8,n,"nested.beta.")) return .beta; return .aggregate; }')
            baseline = root / "before"
            subprocess.run([zig, "test", str(root / "aggregate.zig"), "--test-no-exec", "-fno-llvm", f"-femit-bin={baseline}"], check=True, timeout=60)
            # Shards need canonical discovery even when alpha's caller body is
            # compiler-filtered out. Add an import, not another test declaration,
            # so the stock test names remain exactly unchanged.
            aggregate = root / "aggregate.zig"
            aggregate.write_text(aggregate.read_text().replace(
                '_ = @import("nested/beta.zig");',
                '_ = @import("nested/beta.zig"); _ = @import("hidden.zig");'))
            after = []
            for index, prefixes in enumerate((("aggregate.test.", "hidden.test."), ("alpha.test.", "alpha.Inner.test."), ("nested.beta.test.",))):
                options = root / f"options{index}.zig"
                options.write_text(f"pub const root: usize = {index};")
                binary = root / f"after{index}"
                filters = [argument for prefix in prefixes for argument in ("--test-filter", prefix)]
                subprocess.run([zig, "test", "--test-no-exec", "-fno-llvm", *filters,
                                "--test-runner", str(root / "runner.zig"), "--dep", "unit_test_partition", "--dep", "unit_test_options",
                                f"-Mroot={root / 'aggregate.zig'}", f"-Munit_test_partition={root / 'partition.zig'}",
                                f"-Munit_test_options={options}", f"-femit-bin={binary}"], check=True, timeout=60)
                inventory = names.query(binary)
                after.extend(inventory)
                requests = message(4, b"") + b"".join(message(5, struct.pack("<I", i)) for i in range(len(inventory))) + message(0, b"")
                executed = subprocess.run([str(binary), "--listen=-"], input=requests, capture_output=True, timeout=20, check=True)
                position, results = 0, []
                while position < len(executed.stdout):
                    tag, size = struct.unpack_from("<II", executed.stdout, position)
                    body = executed.stdout[position + 8:position + 8 + size]
                    position += 8 + size
                    if tag == 4:
                        result_index, flags = struct.unpack("<IQ", body)
                        self.assertEqual(flags, 0)
                        results.append(result_index)
                self.assertEqual(results, list(range(len(inventory))))
            self.assertIn("hidden.test.discovered from named body", after)
            names.compare(names.query(baseline), after)


if __name__ == "__main__":
    unittest.main()
