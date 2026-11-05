from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from caller_errors import (
    CATALOG, ROOT, allowance_growth, check, error_sites, inventory_path, lex, mapped_names,
    needs_bootstrap, pending_names, production, read_sources, standard_names, toolchain_version,
)


def catalog(pending=(), mapped=("Classified",)):
    entries = "".join(f'    "{name}",\n' for name in pending)
    arms = "".join(f"        error.{name} => .classified,\n" for name in mapped)
    return ("pub const pending = .{\n" + entries + "};\n"
            "fn mapped(err: anyerror) ?Code {\n"
            "    return switch (err) {\n" + arms +
            "        else => null,\n    };\n}\n")


class CallerErrors(unittest.TestCase):
    def test_inventory_is_exactly_the_cli_owners_and_root_caller_modules(self):
        for path in ("src/cli.zig", "src/cli_args.zig", "src/client.zig", "src/preferences.zig",
                     "src/caller_error.zig", "src/caller_exit.zig", "src/caller_new.zig"):
            with self.subTest(path=path):
                self.assertTrue(inventory_path(path))
                if path != CATALOG:
                    failures = check({CATALOG: catalog(), path: "return error.NewCallerError;"})
                    self.assertEqual(len(failures), 1)
        for path in ("src/store/access.zig", "src/read_transcript.zig", "src/platform.zig",
                     "src/provider_selection.zig", "src/nested/caller_new.zig", "tests/cli.zig"):
            with self.subTest(path=path):
                self.assertFalse(inventory_path(path))
                self.assertEqual(check({CATALOG: catalog(), path: "return error.NewInternalError;"}), [])

    def test_catalog_is_the_single_inventory(self):
        source = catalog(("OldFailure",), ("Classified", "Contextual"))
        self.assertEqual(pending_names(source), {"OldFailure"})
        self.assertEqual(mapped_names(source), {"Classified", "Contextual"})
        self.assertEqual(check({CATALOG: source, "src/cli.zig":
                                "return error.OldFailure; return error.Contextual;"}), [])

    def test_new_unmapped_caller_error_fails_after_anyerror_widening(self):
        # The compile-time closed-set check cannot recover this name once a
        # legacy owner has widened it to anyerror. Inventory the source too.
        failures = check({CATALOG: catalog(), "src/cli.zig":
                          "fn legacy() anyerror!void {\n    return error.NewCallerError;\n}\n"})
        self.assertEqual(failures, [
            "src/cli.zig:2: error.NewCallerError needs a mapped code or an existing pending entry",
        ])

    def test_raw_error_name_is_forbidden_in_every_caller_owner(self):
        for path in ("src/cli.zig", "src/cli_args.zig", "src/caller_exit.zig", "src/caller_new.zig"):
            with self.subTest(path=path):
                failures = check({CATALOG: catalog(), path: "\n@errorName // a comment\n (err);"})
                self.assertEqual(failures, [f"{path}:2: raw @errorName is forbidden on the caller surface"])
        # Internal legacy owners may still log names; their errors are inventoried.
        self.assertEqual(check({CATALOG: catalog(), "src/client.zig": "@errorName(err);"}), [])

    def test_declared_error_set_names_cannot_bypass_cli_coverage(self):
        source = 'const E = error{NewCallerError, @"Another failure"};'
        failures = check({CATALOG: catalog(), "src/client.zig": source})
        self.assertEqual(failures, [
            "src/client.zig:1: error.NewCallerError needs a mapped code or an existing pending entry",
            "src/client.zig:1: error.Another failure needs a mapped code or an existing pending entry",
        ])
        self.assertEqual(check({CATALOG: catalog(("NewCallerError", "Another failure")),
                                "src/client.zig": source}), [])
        self.assertEqual(list(error_sites(production(lex('test { const E = error{TestOnly}; }')))), [])

    def test_comments_strings_chars_and_multiline_strings_are_not_code(self):
        source = r'''
// return error.CommentOnly; @errorName(err)
const a = "error.StringOnly @errorName(err) \" }";
const b = '\x7d';
const c =
    \\error.MultilineOnly @errorName(err) }
;
return error.Classified;
'''
        self.assertEqual(check({CATALOG: catalog(), "src/cli.zig": source}), [])

    def test_test_blocks_are_balanced_and_production_after_them_is_checked(self):
        source = r'''
test "a } in the name" {
    const x = struct { fn f() void { _ = "} \\\""; } };
    // } cannot close the test
    if (true) { return error.TestOnly; }
}
test { return error.AnonymousTestOnly; }
fn live() anyerror!void { return error.NewCallerError; }
'''
        self.assertEqual(list(error_sites(production(lex(source)))), [("NewCallerError", 8)])
        failures = check({CATALOG: catalog(), "src/cli.zig": source})
        self.assertEqual(len(failures), 1)
        self.assertIn("src/cli.zig:8:", failures[0])

    def test_test_helpers_outside_blocks_remain_in_scope(self):
        failures = check({CATALOG: catalog(), "src/cli.zig":
                          "fn fixture() anyerror!void { return error.TestHelperFailure; }"})
        self.assertEqual(len(failures), 1)

    def test_raw_rendering_is_not_allowed_even_in_test_blocks(self):
        failures = check({CATALOG: catalog(), "src/caller_exit.zig": 'test "bad" { _ = @errorName(err); }'})
        self.assertEqual(len(failures), 1)
        self.assertIn("raw @errorName", failures[0])

    def test_quoted_error_identifiers_cannot_bypass_coverage(self):
        failures = check({CATALOG: catalog(), "src/cli.zig": 'return error.@"NewCallerError";'})
        self.assertEqual(len(failures), 1)
        self.assertIn("error.NewCallerError", failures[0])

    def test_only_literal_mapping_arms_count(self):
        source = catalog(mapped=("A", "B")).replace(
            "error.A => .classified,\n        error.B", "error.A, error.B")
        self.assertEqual(mapped_names(source), {"A", "B"})
        for replacement in ("error.Classified => null", "error.Classified => compute()",
                            "error.Classified => .classified, else => .classified"):
            with self.subTest(replacement=replacement):
                with self.assertRaises(ValueError):
                    mapped_names(catalog().replace("error.Classified => .classified", replacement))
        # A test that mentions an error does not classify it.
        source = catalog() + 'test "not a mapping" { _ = error.NewCallerError; }'
        self.assertEqual(mapped_names(source), {"Classified"})

    def test_pending_must_be_a_literal_unique_tuple(self):
        for source in ('pub const pending = computed;', 'pub const pending = .{ error.Bad };',
                       catalog(("Repeated", "Repeated"))):
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    pending_names(source)
        self.assertIsNone(pending_names("// pub const pending = .{};"))
        with self.assertRaisesRegex(ValueError, "missing pending"):
            check({CATALOG: ""})

    def test_unclosed_test_block_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unclosed block"):
            production(lex('test "broken" { return error.TestOnly;'))

    def test_bootstrap_uses_the_trusted_install_owners_exact_compiler_pin(self):
        setup = "archive=zig-x86_64-linux-0.17.0\narchive=zig-aarch64-macos-0.17.0\n"
        self.assertEqual(toolchain_version(setup), "0.17.0")
        for invalid in ("", setup + "archive=zig-aarch64-linux-0.18.0\n"):
            with self.subTest(setup=invalid):
                with self.assertRaisesRegex(ValueError, "one exact Zig release"):
                    toolchain_version(invalid)

    def test_standard_bootstrap_reads_pinned_sources_and_skips_test_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            std = Path(directory)
            (std / "io.zig").write_text('pub const ReadError = error{NotOpenForReading};\n'
                                        'return error.@"Expected closing ]";\n'
                                        'test fixture { const E = error{NotStandardProduction}; }')
            environment = '.{ .version = "0.17.0", .std_dir = "' + str(std) + '" }'
            self.assertEqual(standard_names("0.17.0", environment),
                             {"NotOpenForReading", "Expected closing ]"})
            with self.assertRaisesRegex(ValueError, "needs pinned Zig"):
                standard_names("0.18.0", environment)
        with self.assertRaisesRegex(ValueError, "no Zig std sources"):
            standard_names("0.17.0", environment)

    def test_repository_caller_sources_are_classified(self):
        self.assertEqual(check(read_sources()), [])

    def test_repository_pending_names_occur_in_the_cli_inventory(self):
        sources = read_sources()
        names = {name for source in sources.values() for name, _ in error_sites(production(lex(source)))}
        self.assertEqual(pending_names(sources[CATALOG]) - names, set())

    def test_repository_pending_does_not_grow_from_trusted_base(self):
        self.assertEqual(allowance_growth(), [])

    def test_gate_is_explicitly_wired_before_development_builds(self):
        import prepush
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (ROOT / "build.zig").read_text()))
        commands = list(prepush.checks(["src/cli_args.zig"], available, "HEAD"))
        names = [name for name, _ in commands]
        self.assertLess(names.index("caller errors"), names.index("development selection"))
        command = dict(commands)["caller errors"]
        self.assertEqual(command[1:], ["-B", "tests/ci/caller_errors.py"])
        workflow = (ROOT / ".github/workflows/check.yml").read_text()
        self.assertIn("run: python3 -B tests/ci/caller_errors.py", workflow)


class TrustedPending(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "src").mkdir()
        self.git("init", "-q")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test",
                               "-c", "user.email=test@example.invalid", *args],
                              check=True, capture_output=True, text=True)

    def write(self, path, source):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)

    def commit(self, message, trusted=False):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        if trusted:
            self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def test_bootstrap_comes_from_trusted_production_names_not_candidate_pending(self):
        self.write(CATALOG, "// Before the pending tuple existed.\n")
        self.write("src/cli.zig", 'return error.OldFailure;\ntest "fixture" { return error.TestOnly; }\n')
        self.write("src/client.zig", "return error.LegacyClientFailure;")
        self.write("src/store/nested/owner.zig", "return error.NestedOwnerFailure;")
        self.commit("trusted legacy owners", trusted=True)
        self.write(CATALOG, catalog(("OldFailure", "LegacyClientFailure"), ("Classified", "NewContextual")))
        self.write("src/preferences.zig", "return error.NewContextual;")
        self.assertEqual(allowance_growth(self.root, bootstrap_names=set()), [])
        self.assertEqual(check(read_sources(self.root)), [])
        self.write(CATALOG, catalog(("OldFailure", "NestedOwnerFailure", "NewCallerError", "TestOnly")))
        self.write("src/cli.zig", "return error.NewCallerError;")
        # Even a committed candidate cannot bootstrap arbitrary new names.
        self.commit("candidate grows bootstrap")
        self.assertEqual(allowance_growth(self.root, bootstrap_names=set()), [
            f"{CATALOG}: pending error NestedOwnerFailure exceeds the trusted allowance",
            f"{CATALOG}: pending error NewCallerError exceeds the trusted allowance",
            f"{CATALOG}: pending error TestOnly exceeds the trusted allowance",
        ])

    def test_std_only_names_are_bootstrap_eligible_but_never_enlarge_an_existing_tuple(self):
        self.write(CATALOG, "// Before pending existed.\n")
        self.commit("before the catalog ratchet", trusted=True)
        self.assertTrue(needs_bootstrap(self.root))
        self.write(CATALOG, catalog(("NotOpenForReading",)))
        self.write("src/client.zig", "const E = error{NotOpenForReading};")
        external = {"NotOpenForReading", "AnotherStdError"}
        self.assertEqual(allowance_growth(self.root, bootstrap_names=external), [])
        self.commit("seed inherited std failure", trusted=True)
        self.assertFalse(needs_bootstrap(self.root))
        self.write(CATALOG, catalog(("NotOpenForReading", "AnotherStdError")))
        self.assertEqual(allowance_growth(self.root, bootstrap_names=external), [
            f"{CATALOG}: pending error AnotherStdError exceeds the trusted allowance",
        ])

    def test_existing_pending_can_only_shrink_and_cannot_restore_a_removed_name(self):
        self.write(CATALOG, catalog(("A", "B")))
        self.write("src/cli.zig", "return error.A; return error.B; return error.MentionedButNotPending;")
        self.commit("trusted pending", trusted=True)
        self.write(CATALOG, catalog(("A",)))
        self.assertEqual(allowance_growth(self.root), [])
        self.commit("shrink", trusted=True)
        self.write(CATALOG, catalog(("A", "B", "MentionedButNotPending")))
        self.commit("candidate reintroduces pending")
        self.assertEqual(allowance_growth(self.root), [
            f"{CATALOG}: pending error B exceeds the trusted allowance",
            f"{CATALOG}: pending error MentionedButNotPending exceeds the trusted allowance",
        ])

    def test_mapping_a_new_error_needs_no_pending_allowance(self):
        self.write(CATALOG, catalog(("A",)))
        self.write("src/client.zig", "return error.A;")
        self.commit("trusted pending", trusted=True)
        self.write(CATALOG, catalog(("A",), ("NewCallerError",)))
        self.write("src/client.zig", "return error.NewCallerError;")
        self.assertEqual(check(read_sources(self.root)), [])
        self.assertEqual(allowance_growth(self.root), [])

    def test_host_internal_errors_do_not_expand_the_cli_inventory(self):
        self.write(CATALOG, catalog())
        self.write("src/cli.zig", "fn run() anyerror!void { try imported.run(); }")
        self.write("src/provider_selection.zig", "return error.NewCallerError;")
        self.write("src/new_session_selection.zig", "return error.NewCallerError;")
        self.write("src/read_transcript.zig", "return error.EntryNotFound;")
        self.write("src/store/nested/owner.zig", "return error.NestedCallerError;")
        self.write("src/store/access.zig", "return error.StoreConnectionLost;")
        self.assertEqual(set(read_sources(self.root)), {CATALOG, "src/cli.zig"})
        self.assertEqual(check(read_sources(self.root)), [])
        self.write("src/client.zig", "fn run() anyerror!void { return error.NewClientError; }")
        self.assertEqual(check(read_sources(self.root)), [
            "src/client.zig:1: error.NewClientError needs a mapped code or an existing pending entry",
        ])

    def test_trusted_broad_pending_cannot_move_host_internal_errors_into_cli(self):
        self.write(CATALOG, catalog(("CallerFailure", "HostInternal")))
        self.write("src/client.zig", "return error.CallerFailure;")
        self.write("src/store/access.zig", "return error.HostInternal;")
        self.commit("trusted broad inventory", trusted=True)
        self.write(CATALOG, catalog(("CallerFailure",)))
        self.assertEqual(allowance_growth(self.root), [])
        self.write(CATALOG, catalog(("CallerFailure", "HostInternal")))
        self.write("src/client.zig", "return error.CallerFailure; return error.HostInternal;")
        self.assertEqual(allowance_growth(self.root), [
            f"{CATALOG}: pending error HostInternal exceeds the trusted allowance",
        ])

    def test_missing_trusted_ref_fails_closed(self):
        self.write(CATALOG, catalog(("A",)))
        self.commit("candidate alone")
        with self.assertRaises(subprocess.CalledProcessError):
            allowance_growth(self.root)


if __name__ == "__main__":
    unittest.main()
