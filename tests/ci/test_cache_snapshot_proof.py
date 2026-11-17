"""Pure Python filesystem/parser tests: never launch a compiler or native mock."""
import os
from pathlib import Path
import tempfile
import unittest

import cache_snapshot_proof as proof


class Fixture:
    def __init__(self, base):
        self.local = base / "local"
        self.global_cache = base / "global"
        self.candidate = self.local / "o" / ("a" * 32)
        self.mutable = self.local / "o" / ("d" * 32)
        for root in (self.local, self.global_cache):
            (root / "o" / ("b" * 32)).mkdir(parents=True)
            (root / "o" / ("b" * 32) / "object.o").write_bytes(b"preserved large output")
            (root / "h").mkdir()
            (root / "h" / "manifest").write_bytes(b"original manifest")
            (root / "b").mkdir()
            (root / "b" / "builtin.zig").write_bytes(b"original builtin")
        self.candidate.mkdir()
        (self.candidate / "rui-release-safe-check").write_bytes(b"eligible CLI bytes")
        self.mutable.mkdir()
        (self.mutable / "dependencies.zig").write_bytes(b"original generated input")
        self.source = base / "cli.zig"
        self.source.write_bytes(b"const x = 1;\n")
        self.checkpoint = proof.Checkpoint([self.local, self.global_cache], base / "checkpoint")
        self.report = {"removable": [{"path": str(self.candidate), "bytes": 18}]}


class CheckpointTests(unittest.TestCase):
    def test_only_non_o_and_known_generated_input_bytes_are_copied(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            checkpoint = fixture.checkpoint
            copies = [p for p in checkpoint.destination.rglob("*") if p.is_file()]
            self.assertEqual(sorted(p.name for p in copies),
                             ["builtin.zig", "builtin.zig", "dependencies.zig", "inventory.json", "manifest", "manifest"])
            checkpoint.validate()

    def test_quarantine_and_repeated_arms_restore_same_bytes_and_output_inodes(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            checkpoint = fixture.checkpoint
            before = proof.metadata(fixture.local / "o")
            candidate_info = (fixture.candidate / "rui-release-safe-check").stat()
            for attempt in range(2):
                checkpoint.quarantine_candidates(fixture.report)
                self.assertFalse(fixture.candidate.exists())
                # Recreated candidate digest and new output must not warm the next arm.
                fixture.candidate.mkdir()
                (fixture.candidate / "replacement").write_bytes(b"candidate result")
                for root in checkpoint.roots:
                    new = root / "o" / (str(attempt + 1) * 32)
                    new.mkdir()
                    (new / "new.o").write_bytes(b"new compilation")
                    (root / "h" / "manifest").write_bytes(b"warm from prior arm")
                    (root / "b" / "builtin.zig").write_bytes(b"rewritten builtin")
                    (root / "new-namespace").mkdir()
                # Zig atomically rewrites this known direct-hash generated input.
                generated = fixture.mutable / "dependencies.zig"
                replacement = generated.with_suffix(".tmp")
                replacement.write_bytes(b"rewritten generated input")
                replacement.replace(generated)
                checkpoint.validate()
                checkpoint.restore()
                self.assertEqual((fixture.candidate / "rui-release-safe-check").read_bytes(), b"eligible CLI bytes")
                self.assertEqual((fixture.candidate / "rui-release-safe-check").stat().st_ino, candidate_info.st_ino)
                for root in checkpoint.roots:
                    self.assertEqual({p.name for p in (root / "o").iterdir()}, checkpoint.initial[checkpoint.roots.index(root)])
                    self.assertEqual((root / "h" / "manifest").read_bytes(), b"original manifest")
                    self.assertEqual((root / "b" / "builtin.zig").read_bytes(), b"original builtin")
                    self.assertFalse((root / "new-namespace").exists())
                self.assertEqual(generated.read_bytes(), b"original generated input")
                after = proof.metadata(fixture.local / "o")
                for name, info in before.items():
                    if not name.startswith("d" * 32):
                        self.assertEqual(after[name], info)

    def test_unknown_existing_output_write_fails_even_when_size_and_mtime_match(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            path = fixture.global_cache / "o" / ("b" * 32) / "object.o"
            original = path.stat()
            replacement = path.with_suffix(".tmp")
            replacement.write_bytes(path.read_bytes())
            os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
            replacement.replace(path)
            with self.assertRaisesRegex(proof.ProofError, "fairness unproved"):
                fixture.checkpoint.validate()
            with self.assertRaisesRegex(proof.ProofError, "fairness unproved"):
                fixture.checkpoint.restore()
            self.assertEqual((fixture.local / "h" / "manifest").read_bytes(), b"original manifest")

    def test_substituted_output_namespace_never_deletes_foreign_files(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            original = fixture.local / "o"
            detached = fixture.local / "detached-o"
            original.rename(detached)
            foreign = Path(scratch) / "foreign"
            foreign.mkdir()
            (foreign / "keep").write_bytes(b"foreign data")
            original.symlink_to(foreign, target_is_directory=True)
            with self.assertRaisesRegex(proof.ProofError, "cache namespace changed"):
                fixture.checkpoint.restore()
            self.assertEqual((foreign / "keep").read_bytes(), b"foreign data")
            original.unlink()
            detached.rename(original)
            fixture.checkpoint.restore()

    def test_new_file_inside_old_output_is_an_unknown_write(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            (fixture.candidate / "unknown").write_bytes(b"write")
            with self.assertRaisesRegex(proof.ProofError, "existing output changed"):
                fixture.checkpoint.validate()

    def test_quarantine_validates_entire_report_before_first_move(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            for path in (fixture.global_cache / "o" / ("b" * 32),
                         fixture.mutable, fixture.candidate / ".." / ".."):
                with self.subTest(path=path):
                    report = {"removable": fixture.report["removable"] + [{"path": str(path), "bytes": 1}]}
                    with self.assertRaises(proof.ProofError):
                        fixture.checkpoint.quarantine_candidates(report)
                    self.assertTrue(fixture.candidate.exists())
            with self.assertRaises(proof.ProofError):
                fixture.checkpoint.quarantine_candidates({"skipped": "unknown cache", "removable": []})

    def test_failure_restores_source_and_quarantined_outputs(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            original = fixture.source.read_bytes()
            info = fixture.source.stat()
            source = proof.Source(fixture.source)
            with self.assertRaisesRegex(RuntimeError, "arm failed"):
                with source.preserved():
                    try:
                        source.apply(True)
                        first = fixture.source.stat().st_mtime_ns
                        edited = fixture.source.read_bytes()
                        fixture.checkpoint.quarantine_candidates(fixture.report)
                        fixture.checkpoint.restore()
                        self.assertEqual(fixture.source.read_bytes(), edited)
                        self.assertEqual(fixture.source.stat().st_mtime_ns, first)
                        raise RuntimeError("arm failed")
                    finally:
                        fixture.checkpoint.restore()
            self.assertEqual(fixture.source.read_bytes(), original)
            self.assertEqual(fixture.source.stat().st_mtime_ns, info.st_mtime_ns)
            self.assertTrue(fixture.candidate.exists())
            self.assertFalse(list(fixture.checkpoint.quarantine.iterdir()))


WARM = """Build Summary: 6/6 steps succeeded
ci-build success
+- install rui-release-safe-check success
|  +- compile exe rui-release-safe-check ReleaseSafe native cached 10ms MaxRSS:4M
|     +- run /opt/zig/zig cached
+- install library success
   +- zig build-lib library Debug native cached
      +- compile exe rui-release-safe-check ReleaseSafe native (reused)
"""


class ParserTests(unittest.TestCase):
    def test_ascii_unicode_ansi_reused_nodes_and_timing_do_not_change_parity(self):
        other = WARM.replace("+-", "├─").replace("|", "│").replace("10ms", "8s")
        other = other.replace("cached", "\x1b[32mcached\x1b[0m")
        control = proof.parse_output(WARM)
        self.assertEqual(control["problems"], [])
        self.assertEqual(len(control["nodes"]), 3)
        self.assertTrue(proof.compare(control, proof.parse_output(other))["parity"])

    def test_control_misses_require_specific_node_parity(self):
        miss = WARM.replace("ReleaseSafe native cached", "ReleaseSafe native success")
        self.assertTrue(proof.compare(proof.parse_output(miss), proof.parse_output(miss))["parity"])
        result = proof.compare(proof.parse_output(miss), proof.parse_output(WARM))
        self.assertFalse(result["parity"])
        self.assertIn("rui-release-safe-check", result["differences"][0]["node"])
        # Equal total misses in different nodes must still fail.
        other = WARM.replace("Debug native cached", "Debug native success")
        self.assertFalse(proof.compare(proof.parse_output(miss), proof.parse_output(other))["parity"])

    def test_nested_cc_and_linker_traces_are_counted_without_wall_time(self):
        cc = '/opt/zig/zig clang -c "source with spaces.c" -o /cache/o/' + "a" * 32 + '/file.o\n'
        link = 'ld.lld --shared /cache/o/' + "b" * 32 + '/file.o -o output.so\n'
        first = proof.parse_output(cc + link + WARM)
        second = proof.parse_output(link + cc.replace("a" * 32, "c" * 32) + WARM)
        self.assertEqual(first["problems"], [])
        self.assertTrue(proof.compare(first, second)["parity"])
        result = proof.compare(first, proof.parse_output(cc + cc + link + WARM))
        self.assertFalse(result["parity"])
        self.assertEqual(result["differences"][0]["field"], "traces")

    def test_missing_failed_or_unparsed_evidence_never_passes(self):
        for bad in ("", "Build Summary: 1/1 steps succeeded\nci-build success\n",
                    WARM.replace("6/6", "5/6"),
                    WARM.replace("ReleaseSafe native cached 10ms MaxRSS:4M", "ReleaseSafe native unknown"),
                    WARM.replace("run /opt/zig/zig cached", "run /opt/zig/zig success"),
                    '/opt/zig/zig clang "unterminated\n' + WARM):
            with self.subTest(bad=bad):
                parsed = proof.parse_output(bad)
                self.assertFalse(proof.compare(parsed, parsed)["parity"])

    def test_build_recipe_is_owned_by_compile_command(self):
        import build_artifact
        for profile in ("llvm", "pr"):
            actual = proof.command(["check-full", "test-logic"], "rest", profile, Path("/proof/prefix"), 1)
            owner = build_artifact.compile_command(["check-full", "test-logic"], "rest", jobs=1, pr_mode=profile == "pr")
            self.assertEqual(actual[:len(owner)], owner)
            self.assertEqual(actual[len(owner):], ["--prefix", "/proof/prefix", "--summary", "all", "--verbose-cc", "--verbose-link"])


if __name__ == "__main__":
    unittest.main()
