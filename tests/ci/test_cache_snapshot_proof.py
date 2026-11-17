"""Pure Python filesystem/parser tests: never launch a compiler or native mock."""
from contextlib import chdir, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import cache_snapshot as snapshot

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
        self.candidate_bytes = b"\x7fELF\x02\x01\x01" + b"\0" * 9 + b"\x02\0\x3e\0eligible CLI bytes"
        (self.candidate / "rui-release-safe-check").write_bytes(self.candidate_bytes)
        self.mutable.mkdir()
        (self.mutable / "dependencies.zig").write_bytes(b"original generated input")
        self.source = base / "cli.zig"
        self.source.write_bytes(b"const x = 1;\n")
        self.checkpoint = proof.Checkpoint([self.local, self.global_cache], base / "checkpoint", reserve_bytes=0)
        self.report = {"removable": [{"path": str(self.candidate), "bytes": 18}]}


class CheckpointTests(unittest.TestCase):
    def test_non_executable_outputs_are_copied_without_copying_cli_bytes(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            checkpoint = fixture.checkpoint
            copies = [p for p in checkpoint.destination.rglob("*") if p.is_file()]
            self.assertEqual(sorted(p.name for p in copies),
                             ["builtin.zig", "builtin.zig", "dependencies.zig", "inventory.json", "manifest", "manifest", "object.o", "object.o"])
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
                self.assertEqual((fixture.candidate / "rui-release-safe-check").read_bytes(), fixture.candidate_bytes)
                self.assertEqual((fixture.candidate / "rui-release-safe-check").stat().st_ino, candidate_info.st_ino)
                for root in checkpoint.roots:
                    self.assertEqual({p.name for p in (root / "o").iterdir()}, checkpoint.initial[checkpoint.roots.index(root)])
                    self.assertEqual((root / "h" / "manifest").read_bytes(), b"original manifest")
                    self.assertEqual((root / "b" / "builtin.zig").read_bytes(), b"original builtin")
                    self.assertFalse((root / "new-namespace").exists())
                self.assertEqual(generated.read_bytes(), b"original generated input")
                after = proof.metadata(fixture.local / "o")
                for name, info in before.items():
                    if name.split("/")[0] not in checkpoint.mutable[0]:
                        self.assertEqual(after[name], info)

    def test_unknown_existing_output_write_fails_even_when_size_and_mtime_match(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            path = fixture.candidate / "rui-release-safe-check"
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

    def test_generated_headers_and_global_outputs_restore_atomic_and_inplace_writes(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            for root in (fixture.local, fixture.global_cache):
                path = root / "o" / ("b" * 32) / "object.o"
                path.write_bytes(b"in-place generated header write")
                extra = path.parent / "new-header.h"
                extra.write_bytes(b"atomic generated header")
            fixture.checkpoint.validate()  # These classes are backed up, not immutable.
            fixture.checkpoint.restore()
            for root in (fixture.local, fixture.global_cache):
                path = root / "o" / ("b" * 32) / "object.o"
                self.assertEqual(path.read_bytes(), b"preserved large output")
                self.assertFalse((path.parent / "new-header.h").exists())

    def test_copy_budget_is_checked_before_any_cache_mutation(self):
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            fixture = Fixture(base)
            before = proof.metadata(fixture.local / "o")
            with self.assertRaisesRegex(proof.ProofError, "copy budget exceeded"):
                proof.Checkpoint([fixture.local, fixture.global_cache], base / "too-large",
                                 budget_bytes=1, reserve_bytes=0)
            self.assertEqual(proof.metadata(fixture.local / "o"), before)
            self.assertFalse((base / "too-large").exists())

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

    def test_cleanup_attempts_h_and_other_roots_after_independent_failures(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            checkpoint = fixture.checkpoint
            checkpoint.quarantine_candidates(fixture.report)
            failed_new = fixture.local / "o" / "failed-new"
            other_new = fixture.local / "o" / "other-new"
            failed_new.mkdir()
            other_new.mkdir()
            for root in checkpoint.roots:
                (root / "h" / "manifest").write_bytes(b"changed h")
                (root / "o" / ("b" * 32) / "object.o").write_bytes(b"changed object")
            original_remove, original_copy = proof.remove, proof.copy
            failed_saved = checkpoint.destination / "0" / "mutable" / fixture.mutable.name

            def remove(path):
                if path == failed_new:
                    raise OSError("injected new-dir removal failure")
                return original_remove(path)

            def copy(path, destination):
                if path == failed_saved:
                    raise OSError("injected generated-input copy failure")
                return original_copy(path, destination)

            with patch.object(proof, "remove", side_effect=remove), patch.object(proof, "copy", side_effect=copy):
                with self.assertRaises(proof.ProofError) as error:
                    checkpoint.restore()
            self.assertIn("new-dir removal failure", str(error.exception))
            self.assertIn("generated-input copy failure", str(error.exception))
            self.assertTrue(fixture.candidate.exists())
            self.assertFalse(other_new.exists())
            for root in checkpoint.roots:
                self.assertEqual((root / "h" / "manifest").read_bytes(), b"original manifest")
                self.assertEqual((root / "o" / ("b" * 32) / "object.o").read_bytes(), b"preserved large output")
            checkpoint.restore()

    def test_unsafe_local_root_still_allows_global_cleanup(self):
        with tempfile.TemporaryDirectory() as scratch:
            fixture = Fixture(Path(scratch))
            root = fixture.local
            moved = root.with_name("detached-local")
            root.rename(moved)
            foreign = Path(scratch) / "foreign"
            foreign.mkdir()
            (foreign / "keep").write_bytes(b"foreign")
            root.symlink_to(foreign, target_is_directory=True)
            (fixture.global_cache / "h" / "manifest").write_bytes(b"changed")
            try:
                with self.assertRaisesRegex(proof.ProofError, "cache namespace changed"):
                    fixture.checkpoint.restore()
                self.assertEqual((foreign / "keep").read_bytes(), b"foreign")
                self.assertEqual((fixture.global_cache / "h" / "manifest").read_bytes(), b"original manifest")
            finally:
                root.unlink()
                moved.rename(root)
            fixture.checkpoint.restore()

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


class RunOwnerTests(unittest.TestCase):
    def run_fixture(self, base, *, fail_unlink=False, archives=False):
        fixture = Fixture(base)
        workspace = base / "workspace"
        (workspace / "src").mkdir(parents=True)
        fixture.source.rename(workspace / "src" / "cli.zig")
        fixture.source = workspace / "src" / "cli.zig"
        original_source = fixture.source.read_bytes()
        original_mtime = fixture.source.stat().st_mtime_ns
        # Enough real ELF structure for the real invalidation owner's eligibility check.
        executable = fixture.candidate / "rui-release-safe-check"
        executable.write_bytes(snapshot.ELF.pack(
            b"\x7fELF\x02\x01\x01" + b"\0" * 9, 2, 62, 1, 0x400078,
            64, 0, 0, 64, 56, 1, 0, 0, 0) + b"\0" * 56)
        executable.chmod(0o755)
        owners = [fixture.local / "h" / (letter * 32) for letter in ("e", "f")]
        for owner in owners:
            owner.write_bytes(b"old CLI manifest " + owner.name.encode())
        report = {"removable": [{"path": str(fixture.candidate), "bytes": executable.stat().st_size,
                                "manifests": [{"path": str(owner), "sha256": hashlib.sha256(owner.read_bytes()).hexdigest()}
                                              for owner in owners]}]}
        baseline_h = {root: {p.name: p.read_bytes() for p in (root / "h").iterdir()}
                      for root in (fixture.local, fixture.global_cache)}
        runner_temp = base / "runner"
        runner_temp.mkdir()
        (runner_temp / "zig-cache-restat").write_bytes(b"not executed")
        args = SimpleNamespace(local=fixture.local, global_cache=fixture.global_cache,
                               zig_lib=base / "zig-lib", targets=["check-full", "test-logic"], part="rest",
                               jobs=1, profiles=["llvm", "pr"], checkpoint_budget_gb=1, disk_reserve_gb=0,
                               protect_prefix=[base / "llvm" / "bin"], measure_archives=archives)
        events, builds, source_pairs, measurements = [], [], {}, []
        original_invalidate = snapshot.invalidate_manifest_owners
        original_quarantine = proof.Checkpoint.quarantine_candidates
        original_unlink = Path.unlink

        def audit(local, global_cache, *, prefixes):
            self.assertEqual(prefixes, args.protect_prefix)
            self.assertEqual((local, global_cache), (fixture.local, fixture.global_cache))
            return report

        def invalidate(report, local):
            self.assertEqual({p.name: p.read_bytes() for p in (local / "h").iterdir()}, baseline_h[local])
            events.append("invalidate")
            return original_invalidate(report, local)

        def quarantine(checkpoint, report):
            self.assertEqual(events[-1], "invalidate")
            self.assertTrue(all(not owner.exists() for owner in owners))
            events.append("quarantine")
            return original_quarantine(checkpoint, report)

        def unlink(path, *args, **kwargs):
            fail_now = fail_unlink is True or (fail_unlink == "edit" and fixture.source.read_bytes().endswith(proof.Source.COMMENT))
            if fail_now and path == owners[1]:
                self.assertFalse(owners[0].exists())
                raise OSError("injected failure after one owner unlink")
            return original_unlink(path, *args, **kwargs)

        def stage(argv, destination, **kwargs):
            destination.mkdir(parents=True, exist_ok=False)
            candidate = destination.parent.name == "candidate"
            if destination.name == "restat" or destination.name == "final-restat":
                for root, expected in baseline_h.items():
                    if candidate and root == fixture.local:
                        expected = {name: value for name, value in expected.items() if name not in {p.name for p in owners}}
                    self.assertEqual({p.name: p.read_bytes() for p in (root / "h").iterdir()}, expected)
                return "restat diagnostic"
            self.assertEqual(destination.name, "build")
            if candidate:
                self.assertEqual(events[-1], "quarantine")
            events.append("build-candidate" if candidate else "build-control")
            builds.append(argv)
            key = tuple(destination.parts[-4:-2])
            value = (fixture.source.read_bytes(), fixture.source.stat().st_mtime_ns)
            self.assertEqual(source_pairs.setdefault(key, value), value)
            for root in baseline_h:
                (root / "h" / "manifest").write_bytes(b"prior arm warmed h")
                new = root / "o" / f"new-{len(builds)}"
                new.mkdir()
                (new / "compiled").write_bytes(b"prior arm output")
            return WARM.replace("ReleaseSafe native cached", "ReleaseSafe native success") if "-Dpr-ci=true" in argv else WARM

        def measure(roots, destination, **kwargs):
            measurements.append((tuple(roots), destination.name))
            if destination.name == "before":
                self.assertTrue(fixture.candidate.exists())
                self.assertTrue(all(owner.exists() for owner in owners))
            else:
                self.assertFalse(fixture.candidate.exists())
                self.assertTrue(all(not owner.exists() for owner in owners))
            return dict(compressed_bytes=100 if destination.name == "before" else 50, elapsed_seconds=1)

        with chdir(workspace), patch.dict(os.environ, RUNNER_TEMP=str(runner_temp)), \
                patch.object(snapshot, "audit", side_effect=audit), \
                patch.object(snapshot, "invalidate_manifest_owners", side_effect=invalidate), \
                patch.object(proof.Checkpoint, "quarantine_candidates", new=quarantine), \
                patch.object(Path, "unlink", new=unlink), patch.object(proof, "stage", side_effect=stage), \
                patch.object(proof, "measure_archive", side_effect=measure), redirect_stdout(io.StringIO()):
            status = proof.run(args)
        summary = json.loads((runner_temp / "rui-cache-profile" / "proof" / "summary.json").read_text())
        self.assertEqual(fixture.source.read_bytes(), original_source)
        self.assertEqual(fixture.source.stat().st_mtime_ns, original_mtime)
        self.assertTrue(fixture.candidate.exists())
        for root, expected in baseline_h.items():
            self.assertEqual({p.name: p.read_bytes() for p in (root / "h").iterdir()}, expected)
            self.assertFalse(any(p.name.startswith("new-") for p in (root / "o").iterdir()))
        return status, summary, events, builds, measurements

    def test_all_pairs_start_at_main_checkpoint_and_invalidate_before_quarantine(self):
        with tempfile.TemporaryDirectory() as scratch:
            status, summary, events, builds, _ = self.run_fixture(Path(scratch))
            self.assertEqual(status, 0, summary["errors"])
            self.assertTrue(summary["parity"])
            self.assertEqual(len(builds), 8)  # No PR priming build.
            self.assertEqual([(p["profile"], p["scenario"]) for p in summary["pairs"]],
                             [("llvm", "unchanged"), ("llvm", "edit"), ("pr", "unchanged"), ("pr", "edit")])
            self.assertEqual(events, ["build-control", "invalidate", "quarantine", "build-candidate"] * 4)

    def test_partial_owner_invalidation_failure_prevents_candidate_build_and_restores(self):
        with tempfile.TemporaryDirectory() as scratch:
            status, summary, events, builds, _ = self.run_fixture(Path(scratch), fail_unlink=True)
            self.assertEqual(status, 1)
            self.assertFalse(summary["parity"])
            self.assertEqual(len(builds), 1)
            self.assertEqual(events, ["build-control", "invalidate"])
            self.assertIn("failure after one owner unlink", "".join(summary["errors"]))

    def test_partial_owner_failure_during_edit_restores_original_source(self):
        with tempfile.TemporaryDirectory() as scratch:
            status, summary, events, builds, _ = self.run_fixture(Path(scratch), fail_unlink="edit")
            self.assertEqual(status, 1)
            self.assertFalse(summary["parity"])
            self.assertEqual(len(builds), 3)
            self.assertEqual(events[-2:], ["build-control", "invalidate"])
            self.assertEqual(summary["pairs"][-1]["scenario"], "edit")
            self.assertEqual(set(summary["pairs"][-1]["arms"]), {"control"})

    def test_archive_pair_is_separate_and_restores_main_checkpoint_before_builds(self):
        with tempfile.TemporaryDirectory() as scratch:
            status, summary, events, builds, measurements = self.run_fixture(Path(scratch), archives=True)
            self.assertEqual(status, 0, summary["errors"])
            self.assertEqual(len(builds), 8)
            self.assertEqual([item[1] for item in measurements], ["before", "candidate"])
            self.assertEqual(measurements[0][0], measurements[1][0])
            self.assertEqual(len(measurements[0][0]), 4)
            self.assertEqual(summary["archives"]["before"]["compressed_bytes"], 100)
            self.assertEqual(summary["archives"]["candidate"]["compressed_bytes"], 50)
            self.assertEqual(events[:2], ["invalidate", "quarantine"])

    def test_archive_command_matches_publication_settings(self):
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            roots = [base / name for name in (".zig-cache", "global", "zig-pkg", "screen/zig-pkg")]
            listing = base / "files.txt"
            self.assertEqual(proof.archive_command(roots, listing),
                             ["tar", "--posix", "-c", "-f", "-", "--exclude", "cache.tzst", "-P", "--use-compress-program", "zstdmt", "--files-from", str(listing)])
            self.assertEqual(listing.read_text().splitlines(), list(map(str, roots)))


if __name__ == "__main__":
    unittest.main()
