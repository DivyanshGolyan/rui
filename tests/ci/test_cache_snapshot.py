import os
import json
import copy
from pathlib import Path
import tempfile
import struct
import shutil
import subprocess
import unittest
from unittest.mock import patch

import cache_snapshot as snapshot


def write_executable(directory, name, *, companion=True):
    directory.mkdir(parents=True)
    executable = directory / name
    # Independent ELF64 ABI fixture, with one complete PT_LOAD header.
    executable.write_bytes(struct.pack("<16sHHIQQQIHHHHHH",
        b"\x7fELF\x02\x01\x01" + b"\0" * 9, 2, 62, 1, 0x400078,
        64, 0, 0, 64, 56, 1, 0, 0, 0)
        + struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 121, 121, 4096)
        + b"\xc3")
    executable.chmod(0o755)
    if companion:
        (directory / (name + "_zcu.o")).write_bytes(b"object")
    return directory


def decode_manifests(outputs, command):
    """Stand-in for zig cache-cat over the fixture's own manifest-to-output map."""
    return "\n".join('.{\n    .input_hash = "' + Path(path).name + '",\n'
                     '    .files = .{},\n    .discovered_hash = "' + outputs[path] + '",\n}'
                     for path in command[2:])


class ManifestTest(unittest.TestCase):
    def record(self, path, prefix=4):
        return snapshot.HEADER.pack(17, 23, 31, b"a" * 16, prefix << 2) + os.fsencode(path) + b"\0"

    def test_complete_records_preserve_paths_and_prefix_variants(self):
        for prefix in range(5):
            with self.subTest(prefix=prefix):
                raw = self.record("src/cli.zig", prefix) + self.record("o/" + "a" * 32 + "/file", prefix) + b"\0"
                self.assertEqual(snapshot.records(raw), ["src/cli.zig", "o/" + "a" * 32 + "/file"])
        self.assertEqual(snapshot.records(b"\0"), [])

    def test_directory_and_metadata_flags_for_every_known_prefix(self):
        for prefix in range(5):
            for metadata in range(4):
                with self.subTest(prefix=prefix, metadata=metadata):
                    raw = bytearray(self.record("file", prefix) + b"\0")
                    raw[40] |= metadata
                    self.assertEqual(snapshot.records(bytes(raw)), ["file"])

    def test_literal_pinned_manifest_record(self):
        raw = bytes.fromhex("1100000000000000 1700000000000000 1f00000000000000 "
                            "61616161616161616161616161616161 10 7372632f636c692e7a6967 00 00")
        self.assertEqual(snapshot.records(raw), ["src/cli.zig"])

    @unittest.skipUnless(shutil.which("zig"), "pinned compiler is unavailable")
    def test_literal_manifest_is_accepted_by_pinned_cache_cat(self):
        self.assertEqual(subprocess.check_output(["zig", "version"], text=True).strip(), "0.17.1")
        raw = bytes.fromhex("1100000000000000 1700000000000000 1f00000000000000 "
                            "61616161616161616161616161616161 10 7372632f636c692e7a6967 00 00")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ("a" * 32)
            path.write_bytes(raw)
            decoded = subprocess.check_output(["zig", "cache-cat", str(path)], text=True)
        self.assertIn('.input_hash = "' + "a" * 32 + '"', decoded)
        self.assertIn('.prefix = 4, .path = "src/cli.zig"', decoded)
        self.assertEqual(len(snapshot.OUTPUT.findall(decoded)), 1)

    def test_partial_unknown_and_trailing_records_fail_closed(self):
        valid = self.record("src/cli.zig") + b"\0"
        for raw in (b"", b"not a manifest", valid[:-1], valid + b"extra\0",
                    self.record("x", 5) + b"\0", self.record("") + b"\0", b"a" * 41 + b"\0\0"):
            with self.subTest(raw=raw):
                with self.assertRaises(snapshot.SnapshotError):
                    snapshot.records(raw)


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.roots = [self.root / "local", self.root / "global"]
        for root in self.roots:
            (root / "h").mkdir(parents=True)
            (root / "o").mkdir()
        self.outputs = {}
        self.add_manifest(self.roots[0], "a" * 32, "b" * 32)
        self.cat = patch.object(snapshot.subprocess, "check_output", side_effect=self.decode)
        self.mock_cat = self.cat.start()
        self.addCleanup(self.cat.stop)

    def add_manifest(self, root, seed, output, paths=()):
        path = root / "h" / seed
        record = ManifestTest().record
        path.write_bytes(b"".join(record(value) for value in paths) + b"\0")
        self.outputs[str(path)] = output

    def decode(self, command, **kwargs):
        self.assertEqual(command[:2], ["zig", "cache-cat"])
        return decode_manifests(self.outputs, command)

    def executable(self, digest, name="rui-debug-check", *, root=None, companion=True):
        return write_executable((root or self.roots[0]) / "o" / digest, name, companion=companion)

    def audit(self):
        return snapshot.audit(*self.roots)

    def test_superseded_known_cli_only_is_a_candidate(self):
        active = self.executable("b" * 32)
        obsolete = self.executable("c" * 32)
        report = self.audit()
        self.assertEqual(report["retained_cli"], [str(active)])
        self.assertEqual(report["removable"], [{"path": str(obsolete), "bytes": 127, "manifests": []}])
        self.assertEqual(report["removable_bytes"], 127)
        self.assertTrue((obsolete / "rui-debug-check").exists(), "audit must never delete")

    def test_every_known_product_with_or_without_companion_and_pie(self):
        expected = ("rui-debug-check", "rui-pr-check", "rui-release-safe-check",
                    "rui-release-small-check", "rui-upgrade-release-fixture")
        self.assertEqual(snapshot.PRODUCTS, frozenset(expected))
        for index, name in enumerate(expected, 40):
            for companion in (False, True):
                with self.subTest(name=name, companion=companion):
                    digest = f"{index * 2 + int(companion):032x}"
                    directory = self.executable(digest, name, companion=companion)
                    self.assertTrue(snapshot.obsolete_cli(directory))
                    executable = directory / name
                    raw = bytearray(executable.read_bytes())
                    raw[16] = 3
                    executable.write_bytes(raw)
                    self.assertTrue(snapshot.obsolete_cli(directory), "PIE is also an executable")

    def test_truncated_invalid_and_non_native_elf_headers_are_unknown(self):
        directory = self.executable("c" * 32)
        executable = directory / "rui-debug-check"
        valid = executable.read_bytes()
        for length in range(64):
            with self.subTest(truncated_length=length):
                executable.write_bytes(valid[:length])
                self.assertFalse(snapshot.obsolete_cli(directory))
        for offset, value in ((4, 1), (5, 2), (6, 0), (16, 1), (18, 183),
                              (20, 0), (52, 63), (54, 55), (56, 0)):
            with self.subTest(offset=offset):
                changed = bytearray(valid)
                changed[offset] = value
                executable.write_bytes(changed)
                self.assertFalse(snapshot.obsolete_cli(directory))
        executable.write_bytes(valid[:64])
        self.assertFalse(snapshot.obsolete_cli(directory), "truncated program table")

    def current_prefix(self):
        prefix = self.root / "installed"
        prefix.mkdir()
        expected = ("rui-debug-check", "rui-release-safe-check", "rui-release-small-check", "rui-upgrade-release-fixture")
        for index, name in enumerate(expected, 80):
            digest = f"{index:032x}"
            directory = self.executable(digest, name)
            self.add_manifest(self.roots[0], f"{index + 100:032x}", digest)
            shutil.copy2(directory / name, prefix / name)
        return prefix

    def test_historical_cli_own_manifest_is_not_a_current_graph_root(self):
        prefix = self.current_prefix()
        obsolete = self.executable("c" * 32)
        self.add_manifest(self.roots[0], "d" * 32, "c" * 32)
        # Give the historical executable different valid content from current.
        with (obsolete / "rui-debug-check").open("ab") as out:
            out.write(b"old revision")
        report = snapshot.audit(*self.roots, prefixes=[prefix])
        self.assertEqual([item["path"] for item in report["removable"]], [str(obsolete)])
        self.assertEqual(len(report["protected_hashes"]), 4)

    def test_ordinary_main_three_product_publisher_retains_unselected_optional_profiles(self):
        prefix = self.current_prefix()
        (prefix / "rui-upgrade-release-fixture").unlink()
        expected = {"rui-debug-check", "rui-release-safe-check", "rui-release-small-check"}
        for index, name in enumerate(("rui-debug-check", "rui-upgrade-release-fixture", "rui-pr-check"), 400):
            directory = self.executable(f"{index:032x}", name)
            with (directory / name).open("ab") as out:
                out.write(b"old revision")
            self.add_manifest(self.roots[0], f"{index + 100:032x}", directory.name)
        report = snapshot.audit(*self.roots, prefixes=[prefix])
        self.assertEqual(set(report["eligible_products"]), expected)
        self.assertEqual([Path(item["path"]).name for item in report["removable"]], [f"{400:032x}"])
        self.assertEqual(len(report["protected_hashes"]), 3)

    def test_referenced_historical_cli_is_preserved(self):
        prefix = self.current_prefix()
        obsolete = self.executable("c" * 32)
        with (obsolete / "rui-debug-check").open("ab") as out:
            out.write(b"old revision")
        self.add_manifest(self.roots[0], "d" * 32, "c" * 32, [str(obsolete / "rui-debug-check")])
        self.assertEqual(snapshot.audit(*self.roots, prefixes=[prefix])["removable"], [])

    def test_compaction_invalidates_old_owner_before_removing_output(self):
        prefix = self.current_prefix()
        obsolete = self.executable("c" * 32)
        owner = self.roots[0] / "h" / ("d" * 32)
        self.add_manifest(self.roots[0], "d" * 32, "c" * 32)
        with (obsolete / "rui-debug-check").open("ab") as out:
            out.write(b"old revision")
        rmtree = shutil.rmtree
        events = []
        def remove(path):
            self.assertFalse(owner.exists(), "complete old hits must be invalidated first")
            events.append(str(path))
            rmtree(path)
        with patch.object(snapshot.shutil, "rmtree", side_effect=remove):
            report = snapshot.compact(*self.roots, prefixes=[prefix])
        self.assertEqual(events, [str(obsolete)])
        self.assertEqual(report["invalidated_manifests"], 1)
        self.assertFalse(obsolete.exists())
        self.assertTrue((self.roots[0] / "h" / f"{180:032x}").exists(), "active owner stays")

    def test_changed_own_manifest_blocks_all_invalidation(self):
        prefix = self.current_prefix()
        obsolete = self.executable("c" * 32)
        self.add_manifest(self.roots[0], "d" * 32, "c" * 32)
        with (obsolete / "rui-debug-check").open("ab") as out:
            out.write(b"old revision")
        report = snapshot.audit(*self.roots, prefixes=[prefix])
        owner = self.roots[0] / "h" / ("d" * 32)
        owner.write_bytes(b"changed\0")
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.invalidate_manifest_owners(report, self.roots[0])
        self.assertTrue(owner.exists())
        self.assertTrue(obsolete.exists())

    def test_protected_prefix_and_ancestor_aliases_block_a_plan(self):
        prefix = self.current_prefix()
        for path in (prefix, self.root):
            with self.subTest(path=path):
                moved = path.with_name(path.name + "-real")
                path.rename(moved)
                path.symlink_to(moved, target_is_directory=True)
                try:
                    with self.assertRaises(snapshot.SnapshotError):
                        snapshot.audit(*self.roots, prefixes=[prefix])
                finally:
                    path.unlink()
                    moved.rename(path)

    def test_required_optional_and_broken_protected_leaf_aliases_block_a_plan(self):
        prefix = self.current_prefix()
        for name in ("rui-debug-check", "rui-pr-check"):
            for broken in (False, True):
                with self.subTest(name=name, broken=broken):
                    path = prefix / name
                    original = path.read_bytes() if path.exists() else None
                    if original is not None:
                        path.unlink()
                    path.symlink_to(self.root / "missing" if broken else prefix / "rui-release-safe-check")
                    try:
                        with self.assertRaises(snapshot.SnapshotError):
                            snapshot.audit(*self.roots, prefixes=[prefix])
                    finally:
                        path.unlink()
                        if original is not None:
                            path.write_bytes(original)
                            path.chmod(0o755)

    def test_namespace_substitution_before_invalidation_unlinks_no_owner(self):
        prefix = self.current_prefix()
        obsolete = self.executable("c" * 32)
        self.add_manifest(self.roots[0], "d" * 32, "c" * 32)
        with (obsolete / "rui-debug-check").open("ab") as out:
            out.write(b"old revision")
        report = snapshot.audit(*self.roots, prefixes=[prefix])
        for path in (self.roots[0] / "h", self.roots[0] / "o", self.roots[0]):
            with self.subTest(path=path):
                moved = path.with_name(path.name + "-real")
                path.rename(moved)
                path.symlink_to(moved, target_is_directory=True)
                try:
                    with self.assertRaises(snapshot.SnapshotError):
                        snapshot.invalidate_manifest_owners(report, self.roots[0])
                    self.assertTrue((self.roots[0] / "h" / ("d" * 32)).exists())
                    self.assertTrue(obsolete.exists())
                finally:
                    path.unlink()
                    moved.rename(path)

    def test_incomplete_current_product_set_blocks_historical_pruning(self):
        prefix = self.current_prefix()
        (prefix / "rui-release-safe-check").unlink()
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.audit(*self.roots, prefixes=[prefix])

    def test_missing_current_cache_provenance_blocks_historical_pruning(self):
        prefix = self.current_prefix()
        (self.roots[0] / "h" / f"{180:032x}").unlink()
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.audit(*self.roots, prefixes=[prefix])

    def test_global_outputs_and_unknown_local_products_are_preserved(self):
        global_output = self.executable("c" * 32, root=self.roots[1])
        for index, name in enumerate(("rui", "configurer", "libcrypto.a", "dependencies.zig"), 10):
            self.executable(f"{index:032x}", name)
        report = self.audit()
        self.assertEqual(report["removable"], [])
        self.assertTrue(global_output.exists())
        self.assertEqual(len(report["unknown"]), 4)

    def test_all_manifest_outputs_survive_even_when_input_names_collide(self):
        self.add_manifest(self.roots[1], "a" * 32, "c" * 32)
        for digest in ("b" * 32, "c" * 32):
            self.executable(digest)
        report = self.audit()
        self.assertEqual(len(report["retained_cli"]), 2)
        self.assertEqual(report["removable"], [])
        self.assertEqual(report["manifests"], 2)

    def test_all_input_references_retain_whole_companion_directory(self):
        digest = "d" * 32
        self.add_manifest(self.roots[0], "e" * 32, "f" * 32,
                          ["../prefix/o/" + digest + "/rui-debug-check.o"])
        directory = self.executable(digest)
        self.assertIn(str(directory), self.audit()["retained_cli"])
        self.assertTrue((directory / "rui-debug-check_zcu.o").exists())

    def test_nonregular_or_unknown_companions_are_kept(self):
        for index, kind in enumerate(("extra-file", "directory", "symlink", "nonexecutable", "object-elf"), 20):
            with self.subTest(kind=kind):
                directory = self.executable(f"{index:032x}")
                if kind == "extra-file":
                    (directory / "other.o").touch()
                elif kind == "directory":
                    (directory / "nested").mkdir()
                elif kind == "symlink":
                    (directory / "rui-debug-check_zcu.o").unlink()
                    (directory / "rui-debug-check_zcu.o").symlink_to(self.root / "elsewhere")
                elif kind == "nonexecutable":
                    (directory / "rui-debug-check").chmod(0o644)
                else:
                    exe = directory / "rui-debug-check"
                    raw = bytearray(exe.read_bytes())
                    raw[16] = 1
                    exe.write_bytes(raw)
        self.assertEqual(self.audit()["removable"], [])

    def test_symlink_output_directory_and_nonhash_names_are_unknown(self):
        directory = self.executable("c" * 32)
        directory.rename(self.root / "elsewhere")
        directory.symlink_to(self.root / "elsewhere", target_is_directory=True)
        (self.roots[0] / "o" / "ci-compiled").mkdir()
        self.assertEqual(self.audit()["removable"], [])
        self.assertEqual(len(self.audit()["unknown"]), 2)

    def test_unknown_or_partial_manifests_block_a_plan(self):
        for name, contents in (("unexpected", b"\0"), ("d" * 32, b"incomplete")):
            path = self.roots[1] / "h" / name
            path.write_bytes(contents)
            with self.assertRaises(snapshot.SnapshotError):
                self.audit()
            path.unlink()

    def test_empty_manifest_placeholders_are_retained_without_decoder_roots(self):
        placeholders = []
        for root in self.roots:
            path = root / "h" / ("c" * 32)
            path.touch()
            placeholders.append(path)
        # The official decoder must never give an empty placeholder an owner.
        # The mock has no output mapping for these paths, so decoding fails.
        report = self.audit()
        self.assertEqual(report["unfinalized_manifests"], list(map(str, placeholders)))
        self.assertEqual(report["manifests"], 1)
        decoded = [path for call in self.mock_cat.call_args_list for path in call.args[0][2:]]
        self.assertEqual(decoded, [str(self.roots[0] / "h" / ("a" * 32))])
        self.assertTrue(all(path.read_bytes() == b"" for path in placeholders))

    def test_empty_placeholder_cannot_prove_cli_ownership_or_current_provenance(self):
        prefix = self.current_prefix()
        obsolete = self.executable("c" * 32)
        with (obsolete / "rui-debug-check").open("ab") as stream:
            stream.write(b"obsolete revision")
        placeholder = self.roots[0] / "h" / ("d" * 32)
        placeholder.touch()
        report = snapshot.audit(*self.roots, prefixes=[prefix])
        self.assertIn(str(obsolete), report["unknown"])
        self.assertEqual(report["removable"], [])
        active_owner = self.roots[0] / "h" / f"{180:032x}"
        active_owner.write_bytes(b"")
        with self.assertRaisesRegex(snapshot.SnapshotError, "current CLI is absent from manifest roots"):
            snapshot.audit(*self.roots, prefixes=[prefix])

    def test_colliding_complete_and_empty_manifests_do_not_fabricate_local_owners(self):
        prefix = self.current_prefix()
        for index, local_complete in enumerate((False, True), 210):
            digest = f"{index:032x}"
            seed = f"{index + 100:032x}"
            directory = self.executable(digest)
            with (directory / "rui-debug-check").open("ab") as stream:
                stream.write(b"obsolete revision")
            complete_root, empty_root = self.roots if local_complete else self.roots[::-1]
            self.add_manifest(complete_root, seed, digest)
            empty = empty_root / "h" / seed
            empty.touch()
            report = snapshot.compact(*self.roots, prefixes=[prefix])
            self.assertEqual(empty.read_bytes(), b"")
            self.assertEqual(directory.exists(), not local_complete)
            if local_complete:
                self.assertIn(str(directory), [item["path"] for item in report["removable"]])
                self.assertFalse((complete_root / "h" / seed).exists())
            else:
                self.assertIn(str(directory), report["unknown"])
                self.assertTrue((complete_root / "h" / seed).exists())

    def test_empty_unknown_manifest_entries_still_block_the_plan(self):
        for kind in ("symlink", "directory", "nonhex"):
            with self.subTest(kind=kind):
                path = self.roots[1] / "h" / ("unknown" if kind == "nonhex" else "d" * 32)
                if kind == "symlink":
                    target = self.root / "empty"
                    target.touch()
                    path.symlink_to(target)
                elif kind == "directory":
                    path.mkdir()
                else:
                    path.touch()
                with self.assertRaises(snapshot.SnapshotError):
                    self.audit()
                path.rmdir() if path.is_dir() else path.unlink()

    def test_all_empty_manifests_still_skip_without_a_complete_inventory(self):
        (self.roots[0] / "h" / ("a" * 32)).write_bytes(b"")
        with self.assertRaisesRegex(snapshot.SnapshotError, "no complete manifests"):
            self.audit()
        self.mock_cat.assert_not_called()

    def test_empty_placeholder_mutation_during_decode_blocks_the_plan(self):
        for kind in ("filled", "finalized", "removed", "new"):
            with self.subTest(kind=kind):
                path = self.roots[1] / "h" / ("d" * 32)
                if kind != "new":
                    path.touch()
                def mutate(command, **kwargs):
                    decoded = self.decode(command, **kwargs)
                    if kind == "removed":
                        path.unlink()
                    else:
                        path.write_bytes(b"\0" if kind == "finalized" else b"" if kind == "new" else b"changed")
                    return decoded
                self.mock_cat.side_effect = mutate
                with self.assertRaises(snapshot.SnapshotError):
                    self.audit()
                if path.exists():
                    path.unlink()

    def test_whole_output_namespace_reference_blocks_a_plan(self):
        self.add_manifest(self.roots[0], "d" * 32, "e" * 32, [".zig-cache/o"])
        with self.assertRaises(snapshot.SnapshotError):
            self.audit()

    def test_symlinked_manifest_input_retains_its_target(self):
        directory = self.executable("c" * 32)
        alias = self.root / "input-alias"
        alias.symlink_to(directory / "rui-debug-check_zcu.o")
        self.add_manifest(self.roots[0], "d" * 32, "e" * 32, [str(alias)])
        self.assertIn(str(directory), self.audit()["retained_cli"])

    def test_symlinked_cache_namespaces_block_a_plan(self):
        for name in ("h", "o"):
            with self.subTest(name=name):
                original = self.roots[1] / name
                moved = self.root / ("moved-" + name)
                original.rename(moved)
                original.symlink_to(moved, target_is_directory=True)
                with self.assertRaises(snapshot.SnapshotError):
                    self.audit()
                original.unlink()
                moved.rename(original)

    def test_concurrent_manifest_change_blocks_a_plan(self):
        decode = self.decode
        def mutate(command, **kwargs):
            result = decode(command, **kwargs)
            (self.roots[0] / "h" / ("a" * 32)).write_bytes(b"changed\0")
            return result
        self.mock_cat.side_effect = mutate
        with self.assertRaises(snapshot.SnapshotError):
            self.audit()

    def test_decoder_batches_more_than_128_manifests(self):
        for index in range(130):
            self.add_manifest(self.roots[0], f"{index:032x}", f"{index + 1000:032x}")
        report = self.audit()
        self.assertEqual(report["manifests"], 131)
        self.assertEqual(self.mock_cat.call_count, 2)
        self.assertTrue(all(len(call.args[0]) <= 130 for call in self.mock_cat.call_args_list))

    def test_unexpected_official_decoder_output_blocks_a_plan(self):
        self.mock_cat.side_effect = None
        self.mock_cat.return_value = '.{ .discovered_hash = "' + "b" * 32 + '" }'
        with self.assertRaises(snapshot.SnapshotError):
            self.audit()


class PublicationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = dict(GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="workflow_dispatch",
                        RUNNER_OS="Linux", RUNNER_ARCH="X64", SETUP_OUTCOME="success",
                        WORK_OUTCOME="success", RUNNER_TEMP=str(self.root), GITHUB_RUN_ID="42",
                        GITHUB_RUN_ATTEMPT="2", RUI_CACHE_BUILD_KEY="rui-build-v4-Linux-X64-0.17.1-"
                        + "a" * 64 + "-compiled." + "b" * 64 + "-" + "c" * 64)
        self.outputs = {}
        self.inputs = dict(format=5, pr_ci=False, part="rest", targets=["check-full"], tree="tree",
                           system="Linux", machine="x86_64", compiler="compiler")
        self.receipt = dict(inputs=self.inputs, source_sha="current-head", run_id=42, run_attempt=2)
        (self.root / "rui-compiled").mkdir()
        self.path = self.root / "rui-compiled/compiled.json"
        self.write()
        import build_artifact
        patches = (patch.object(build_artifact, "identity", return_value=self.inputs),
                   patch.object(build_artifact, "git", return_value="current-head"),
                   patch.object(snapshot.subprocess, "check_output", side_effect=self.zig))
        for replacement in patches:
            replacement.start()
            self.addCleanup(replacement.stop)

    def zig(self, command, **kwargs):
        if command == ["zig", "version"]:
            return "0.17.1\n"
        self.assertEqual(command[:2], ["zig", "cache-cat"])
        return decode_manifests(self.outputs, command)

    def write(self):
        self.path.write_text(json.dumps(self.receipt))

    def manifest(self, root, seed, output, atime, paths=()):
        path = root / "h" / seed
        path.write_bytes(b"".join(ManifestTest().record(value) for value in paths) + b"\0")
        os.utime(path, ns=(atime, 0))
        self.outputs[str(path)] = output
        return path

    def publisher_cache(self, name, read):
        """One restored-and-compiled cache: (local, global, expected removals by rule)."""
        unread = snapshot.UNREAD_NS
        local, global_cache = self.root / name / "local", self.root / name / "global"
        for root in (local, global_cache):
            (root / "h").mkdir(parents=True)
            (root / "o").mkdir()
        def output(index, executable, **kwargs):
            return write_executable(local / "o" / f"{index:032x}", executable, **kwargs)
        old_test = output(1, "test")
        old_cli = output(2, "rui-debug-check")
        with (old_cli / "rui-debug-check").open("ab") as out:
            out.write(b"old revision")
        library = output(3, "libghostty-vt.so.1.0.0", companion=False)
        (library / "ghostty-vt_zcu.o").write_bytes(b"object")
        (library / "libghostty-vt.so.1").symlink_to("libghostty-vt.so.1.0.0")
        (library / "libghostty-vt.so").symlink_to("libghostty-vt.so.1")
        read_tool, shared, global_owned = output(4, "translate-c"), output(5, "configurer"), output(6, "generate-def")
        referenced, orphan = output(7, "parser-fuzz"), output(8, "uucode_generate")
        c_object = local / "o" / f"{9:032x}"
        c_object.mkdir()
        (c_object / "sqlite3.o").write_bytes(b"\x7fELF relocatable")
        owners = {}
        for seed, directory, atime in ((21, old_test, unread), (22, old_cli, unread), (23, library, unread),
                                       (24, read_tool, read), (25, shared, unread), (26, shared, read),
                                       (27, global_owned, unread), (28, referenced, unread), (29, c_object, unread)):
            owners[directory] = self.manifest(local, f"{seed:032x}", directory.name, atime)
        self.manifest(global_cache, f"{30:032x}", global_owned.name, read)
        self.manifest(local, f"{31:032x}", "f" * 32, read, [str(referenced / "parser-fuzz")])
        prefix = self.root / "rui-compiled-build/bin"
        prefix.mkdir(parents=True, exist_ok=True)
        current = []
        for index, product in enumerate(("rui-debug-check", "rui-release-safe-check", "rui-release-small-check"), 10):
            directory = output(index, product)
            owners[directory] = self.manifest(local, f"{index + 30:032x}", directory.name, read)
            shutil.copy2(directory / product, prefix / product)
            current.append(directory)
        kept = [read_tool, shared, global_owned, referenced, orphan, c_object, *current]
        return local, global_cache, owners, dict(read=[old_test, old_cli, library], cli=[old_cli]), kept

    def test_current_full_llvm_producer_can_prepare_a_save(self):
        """CI-30: a qualified main producer publishes only the linked outputs its build read, failing closed."""
        for event in ("push", "workflow_dispatch", "workflow_call", "schedule"):
            for part in ("all", "rest"):
                for gate in ("check", "check-full"):
                    with self.subTest(event=event, part=part, gate=gate):
                        self.env["GITHUB_EVENT_NAME"] = event
                        self.inputs.update(part=part, targets=[gate])
                        self.write()
                        self.assertEqual(snapshot.publication_prefix(self.env), self.root / "rui-compiled-build/bin")
        unread = snapshot.UNREAD_NS
        # The probe writes a mark only when a read moved the access time forward.
        for after, expected in ((unread + 1, True), (unread + 10**18, True), (unread, False),
                                (unread - 1, False), (0, False)):
            with self.subTest(probe_after=after):
                self.assertIs(snapshot.reads_move_atime(unread, after), expected)
        # Liveness is only the manifests still at the mark, and only with a usable mark.
        atimes = {"a" * 32: unread, "b" * 32: unread + 1, "c" * 32: unread - 1, "d" * 32: 0}
        for record in (None, {}, {"atime": False}, {"atime": None}, {"atime": 1}, {"atime": "true"},
                       [], "scalar", 42):
            with self.subTest(mark_record=record):
                self.assertIsNone(snapshot.unread_names(record, atimes))
        usable = {"atime": True, "marked": 4}
        self.assertEqual(snapshot.unread_names(usable, atimes), {"a" * 32},
                         "advanced, backwards and zeroed access times all count as read")
        self.assertEqual(snapshot.unread_names(usable, {}), set())
        # The real mark on this filesystem follows the probe's decision.
        probe = self.root / "probe"
        (probe / "h").mkdir(parents=True)
        self.manifest(probe, "a" * 32, "b" * 32, unread + 1)
        record = self.root / "probe-mark.json"
        marked = snapshot.mark(probe, record)
        self.assertFalse((probe / "rui-atime-probe").exists())
        self.assertEqual(record.exists(), marked["atime"])
        self.assertEqual(marked["marked"], 1 if marked["atime"] else 0)
        if marked["atime"]:
            self.assertEqual(snapshot.unread_manifests(probe, record), {"a" * 32})
            (probe / "h" / ("a" * 32)).read_bytes()
            self.assertEqual(snapshot.unread_manifests(probe, record), set())
        else:
            self.assertIsNone(snapshot.unread_manifests(probe, record))
        # Only linked outputs are eligible: executables or libraries, unit objects, in-directory aliases.
        classes = self.root / "classes"
        for index, (names, expected) in enumerate(((("test", "test_zcu.o"), True),
                                                   (("sqlite3.o",), False), (("libcrypto.a",), False),
                                                   (("tables.zig",), False), (("test_zcu.o",), False))):
            with self.subTest(linked=names):
                directory = classes / f"{index:032x}"
                if names[0] == "test":
                    write_executable(directory, "test")
                else:
                    directory.mkdir(parents=True)
                    (directory / names[0]).write_bytes(b"data")
                self.assertIs(snapshot.linked_output(directory), expected)
        escaping = write_executable(classes / ("e" * 32), "test")
        (escaping / "alias").symlink_to("../" + "0" * 32 + "/test")
        self.assertFalse(snapshot.linked_output(escaping), "aliases stay inside the directory")
        # Publication: a usable mark removes every unread linked output; without one, only old CLIs.
        key = self.env["RUI_CACHE_BUILD_KEY"]
        for state in ("usable", "missing", "false"):
            with self.subTest(mark=state):
                local, global_cache, owners, removed, kept = self.publisher_cache(state, unread + 1)
                mark = self.root / snapshot.MARK
                mark.unlink(missing_ok=True)
                if state != "missing":
                    mark.write_text(json.dumps(dict(atime=state == "usable", marked=13)))
                report = snapshot.publication_report(self.env, key, local, global_cache)
                expected = removed["read" if state == "usable" else "cli"]
                self.assertEqual(report["key"], key)
                self.assertEqual([item["path"] for item in report["removable"]], [str(path) for path in expected])
                self.assertEqual(report["unread_manifests"], 7 if state == "usable" else None)
                for directory in expected:
                    self.assertFalse(directory.exists())
                    self.assertFalse(owners[directory].exists(), "owners go with their outputs")
                for directory in kept:
                    self.assertTrue(directory.exists(), directory)
        # A mark that missed the producer's current output declines publication and removes nothing.
        local, global_cache, owners, removed, kept = self.publisher_cache("missed", unread + 1)
        mark.write_text(json.dumps(dict(atime=True, marked=13)))
        os.utime(owners[kept[-3]], ns=(unread, 0))
        with self.assertRaisesRegex(snapshot.SnapshotError, "mark missed"):
            snapshot.publication_report(self.env, key, local, global_cache)
        self.assertTrue(all(directory.exists() for directory in removed["read"]))
        with self.assertRaisesRegex(snapshot.SnapshotError, "current producer outputs"):
            snapshot.audit(local, global_cache, unread=set())

    def test_complete_partial_by_work_outcome_uses_one_compaction_policy(self):
        original = self.env["RUI_CACHE_BUILD_KEY"]
        for partial in (False, True):
            for outcome in ("success", "failure", "cancelled"):
                for successful in ("true", "false"):
                    with self.subTest(partial=partial, outcome=outcome, job_success=successful):
                        env = dict(self.env, WORK_OUTCOME=outcome, JOB_SUCCESS=successful)
                        key = original + ("-partial-42-2" if partial else "")
                        with patch.object(snapshot, "compact", return_value=dict(
                                removable=[], removable_bytes=0, invalidated_manifests=0)) as compact:
                            if not partial and outcome == "success":
                                report = snapshot.publication_report(env, key, "local", "global")
                                self.assertEqual(report["key"], original)
                                self.assertEqual(report["invalidated_manifests"], 0)
                                compact.assert_called_once_with("local", "global", prefixes=[
                                    self.root / "rui-compiled-build/bin"], unread=None)
                            else:
                                with self.assertRaises(snapshot.SnapshotError):
                                    snapshot.publication_report(env, key, "local", "global")
                                compact.assert_not_called()

    def test_target_key_cannot_bypass_compaction_with_missing_or_mismatched_environment(self):
        key = self.env["RUI_CACHE_BUILD_KEY"]
        for changes in ({"RUI_CACHE_BUILD_KEY": ""}, {"RUNNER_OS": "macOS"},
                        {"RUNNER_ARCH": "ARM64"}, {"SETUP_OUTCOME": "failure"}):
            with self.subTest(changes=changes), patch.object(snapshot, "compact") as compact:
                with self.assertRaises(snapshot.SnapshotError):
                    snapshot.publication_report(dict(self.env, **changes), key, "local", "global")
                compact.assert_not_called()
        with patch.object(snapshot, "compact", side_effect=snapshot.SnapshotError("audit failed")):
            with self.assertRaisesRegex(snapshot.SnapshotError, "audit failed"):
                snapshot.publication_report(self.env, key, "local", "global")

    def test_other_platform_and_partition_candidates_keep_their_partial_policy(self):
        key = self.env["RUI_CACHE_BUILD_KEY"]
        for other in (key.replace("Linux-X64", "macOS-ARM64"),
                      key.replace("-compiled.", "-compiled-unit."),
                      key.replace("-compiled.", "-baseline."),
                      key.replace("-compiled.", "-typecheck.")):
            for partial in ("", "-partial-42-2"):
                with self.subTest(key=other, partial=partial), patch.object(snapshot, "compact") as compact:
                    self.assertEqual(snapshot.publication_report({}, other + partial, "local", "global"),
                                     dict(key=other + partial))
                    compact.assert_not_called()

    def test_nonpublishers_failed_work_partitions_and_exact_hits_do_not_compact(self):
        cases = (("GITHUB_REF", "refs/pull/1/merge"), ("GITHUB_REF", "refs/heads/feature"),
                 ("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_EVENT_NAME", "pull_request_target"),
                 ("GITHUB_EVENT_NAME", ""), ("RUNNER_OS", "macOS"), ("RUNNER_ARCH", "ARM64"),
                 ("SETUP_OUTCOME", "failure"), ("WORK_OUTCOME", "failure"), ("WORK_OUTCOME", "cancelled"),
                 ("RUI_CACHE_BUILD_KEY", ""),
                 ("RUI_CACHE_BUILD_KEY", self.env["RUI_CACHE_BUILD_KEY"].replace("-compiled.", "-compiled-unit.")),
                 ("RUI_CACHE_BUILD_KEY", self.env["RUI_CACHE_BUILD_KEY"].replace("-compiled.", "-baseline.")),
                 ("RUI_CACHE_BUILD_KEY", self.env["RUI_CACHE_BUILD_KEY"] + "-partial-42-1"),
                 ("RUI_CACHE_BUILD_KEY", self.env["RUI_CACHE_BUILD_KEY"].replace("v4", "v3")),
                 ("RUI_CACHE_BUILD_KEY", self.env["RUI_CACHE_BUILD_KEY"].replace("v4", "v2")))
        for field, value in cases:
            with self.subTest(field=field, value=value):
                env = dict(self.env, **{field: value})
                with self.assertRaises(snapshot.SnapshotError):
                    snapshot.publication_prefix(env)

    def test_stale_malformed_narrower_or_wrong_profile_receipts_do_not_compact(self):
        changes = (("source_sha", "previous-head"), ("run_id", 41), ("run_attempt", 1),
                   ("inputs", dict(self.inputs, pr_ci=True)), ("inputs", dict(self.inputs, part="unit")),
                   ("inputs", dict(self.inputs, targets=["test-logic"])), ("inputs", dict(self.inputs, targets=[{}])), ("inputs", dict(self.inputs, format=4)),
                   ("inputs", dict(self.inputs, compiler="different")), ("inputs", None))
        original = copy.deepcopy(self.receipt)
        for field, value in changes:
            with self.subTest(field=field, value=value):
                self.receipt = dict(original, **{field: value})
                self.write()
                with self.assertRaises(snapshot.SnapshotError):
                    snapshot.publication_prefix(self.env)
        for malformed in (None, [], "scalar", 42, False):
            with self.subTest(receipt=malformed):
                self.path.write_text(json.dumps(malformed))
                with self.assertRaises(snapshot.SnapshotError):
                    snapshot.publication_prefix(self.env)
        self.path.write_text("not JSON")
        with self.assertRaises(json.JSONDecodeError):
            snapshot.publication_prefix(self.env)


if __name__ == "__main__":
    unittest.main()
