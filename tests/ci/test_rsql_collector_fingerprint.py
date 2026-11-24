import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from rsql_collector_fixture import elf
from rsql_table import record_set_digest, tool_digest


class CollectorFingerprintTest(unittest.TestCase):
    def test_ci_100_fingerprints_bind_records_and_leave_acceptance_unchanged(self):
        first, second, shared = b"first\x1c", b"second\x1c", b"shared\x1c"
        expected = hashlib.sha256(len(first).to_bytes(8, "big") + first +
                                  len(second).to_bytes(8, "big") + second).hexdigest()
        self.assertEqual(record_set_digest([first, second]), expected)
        self.assertEqual(record_set_digest([second, first, first]), expected)
        self.assertNotEqual(record_set_digest([first]), expected)
        self.assertNotEqual(record_set_digest([b"ab", b"c"]), record_set_digest([b"a", b"bc"]))
        self.assertEqual(record_set_digest([]), hashlib.sha256(b"").hexdigest())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project, caller = root / "project", root / "caller"
            project.mkdir()
            caller.mkdir()
            (root / "first.elf").write_bytes(elf(shared, first, first))
            (root / "second.elf").write_bytes(elf(second, shared))
            (root / "empty.elf").write_bytes(elf())
            (root / "manifest").write_bytes(b'{"not":"an elf"}')
            script = '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
prefix = pathlib.Path(args[args.index("--prefix") + 1])
(prefix / "bin").mkdir(parents=True)
fixture = pathlib.Path(os.environ["ELF_FIXTURES"])
for name in ("first", "second", "empty"):
    source = "empty" if os.environ.get("ALL_EMPTY") == "1" else name
    shutil.copyfile(fixture / (source + ".elf"), prefix / "bin" / name)
shutil.copyfile(fixture / "manifest", prefix / "bin" / "ci-cpu.json")
'''
            expected_path = Path.cwd() / "tests/ci"
            code = ('import rsql_table,sys; from pathlib import Path; '
                    'print(sorted(rsql_table.collect(sys.argv[1], root=Path(sys.argv[2]))))')
            for spelling in ("absolute", "relative", "path"):
                with self.subTest(spelling=spelling):
                    directory_name = "tools" if spelling == "path" else "."
                    project_tool = project / directory_name / "zig"
                    caller_tool = caller / directory_name / "zig"
                    project_tool.parent.mkdir(parents=True, exist_ok=True)
                    caller_tool.parent.mkdir(parents=True, exist_ok=True)
                    project_tool.write_text(script)
                    caller_tool.write_text(script + "\n# different executable\n")
                    project_tool.chmod(0o755)
                    caller_tool.chmod(0o755)
                    executable = str(project_tool) if spelling == "absolute" else "zig" if spelling == "path" else "./zig"
                    env = dict(os.environ, PYTHONPATH=str(expected_path), ELF_FIXTURES=str(root))
                    if spelling == "path":
                        env["PATH"] = "tools" + os.pathsep + os.environ["PATH"]
                    result = subprocess.run([sys.executable, "-B", "-c", code, executable, str(project)],
                                            cwd=caller, env=env, text=True, capture_output=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, repr(sorted({first, second, shared})) + "\n")
                    tool_hash = hashlib.sha256(project_tool.read_bytes()).hexdigest()
                    kind = "path-candidate" if spelling == "path" else "explicit-path"
                    self.assertIn(f"RSQL collector {kind} sha256={tool_hash}", result.stderr)
                    self.assertIn("-Dpr-ci=true -Drsql-collect=true", result.stderr)
                    for name, records in (("first", {first, shared}), ("second", {second, shared}), ("empty", set())):
                        digest = hashlib.sha256(b"".join(len(value).to_bytes(8, "big") + value
                                                         for value in sorted(records))).hexdigest()
                        self.assertIn(f"RSQL collector records binary={name} count={len(records)} sha256={digest}", result.stderr)
                    self.assertIn("RSQL collector skipped non-ELF artifact=ci-cpu.json", result.stderr)
                    self.assertIn("RSQL collector extraction complete binaries=3 unique_records=3; not a check verdict", result.stderr)
            bad = project / "bad" / "zig"
            bad.parent.mkdir()
            bad.write_text("#!/this-interpreter-does-not-exist\n")
            bad.chmod(0o755)
            fallback_env = dict(env, PATH="bad" + os.pathsep + "tools" + os.pathsep + os.environ["PATH"])
            fallback = subprocess.run([sys.executable, "-B", "-c", code, "zig", str(project)],
                                      cwd=caller, env=fallback_env, text=True, capture_output=True, timeout=20)
            self.assertEqual(fallback.returncode, 0, fallback.stderr)
            self.assertEqual(fallback.stdout, repr(sorted({first, second, shared})) + "\n")
            self.assertIn(f"RSQL collector path-candidate sha256={hashlib.sha256(bad.read_bytes()).hexdigest()}",
                          fallback.stderr)
            self.assertNotIn("invoked-tool", fallback.stderr)
            (root / "first.elf").write_bytes(elf(first, shared, first))
            reordered = subprocess.run([sys.executable, "-B", "-c", code, str(project / "zig"), str(project)],
                                       cwd=caller, env=env, text=True, capture_output=True, timeout=20)
            self.assertEqual(reordered.returncode, 0, reordered.stderr)
            first_digest = hashlib.sha256(b"".join(len(value).to_bytes(8, "big") + value
                                                    for value in sorted({first, shared}))).hexdigest()
            self.assertIn(f"RSQL collector records binary=first count=2 sha256={first_digest}", reordered.stderr)
            self.assertLess(reordered.stderr.index("binary=empty"), reordered.stderr.index("binary=first"))
            self.assertLess(reordered.stderr.index("binary=first"), reordered.stderr.index("binary=second"))
            env["ALL_EMPTY"] = "1"
            empty = subprocess.run([sys.executable, "-B", "-c", code, str(project / "zig"), str(project)],
                                   cwd=caller, env=env, text=True, capture_output=True, timeout=20)
            self.assertNotEqual(empty.returncode, 0)
            self.assertIn("the collect build exported no statements", empty.stderr)
            self.assertNotIn("extraction complete", empty.stderr)
            self.assertIsNone(tool_digest(str(root / "missing-zig"), root=project))
            unreadable = project / "unreadable"
            unreadable.write_text("#!/bin/sh\nexit 0\n")
            unreadable.chmod(0o111)
            if not os.access(unreadable, os.R_OK):
                self.assertIsNone(tool_digest(str(unreadable), root=project))


if __name__ == "__main__":
    unittest.main()
