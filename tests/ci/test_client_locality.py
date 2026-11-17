"""Client policy moves to the Host; inherited exceptions can only shrink."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Also support the documented root invocation:
# python3 -m unittest tests/ci/test_client_locality.py
sys.path.insert(0, str(Path(__file__).resolve().parent))

from client_locality import (
    ALLOWED, CLASSIFIER, DEFAULT_IMPORT, GATE, ISSUES, MESSAGE, REQUIRED_SOURCES,
    ROOT, SELECTION_ISSUES, TS_DEFAULT, allowance_growth, allowed_entries, findings, scan,
    stale_allowances, surfaces, violations,
)


class ClientLocalityTest(unittest.TestCase):
    def test_repository_has_no_unallowed_client_policy(self):
        found = violations()
        self.assertEqual(found, [], "\n".join(found))

    def test_every_allowance_is_still_needed_and_names_its_issue(self):
        self.assertEqual(stale_allowances(), [])
        self.assertEqual(allowed_entries((ROOT / GATE).read_text()), ALLOWED)
        for pair, issue in ALLOWED.items():
            self.assertEqual(issue, SELECTION_ISSUES.get(pair, ISSUES[pair[1]]))
        self.assertNotIn(("src/client_defaults.zig", DEFAULT_IMPORT), ALLOWED)

    def test_allowances_do_not_grow_from_trusted_base(self):
        self.assertEqual(allowance_growth(), [])

    def test_product_defaults_imports_include_relative_and_spaced_forms(self):
        for source in ('const defaults = @import("product_defaults.zig");',
                       'const defaults = @import ( "../product_defaults.zig" );',
                       'const tools = @import("./product_defaults.zig").tools;'):
            with self.subTest(source=source):
                self.assertEqual(findings(source, "src/client.zig"), [(1, DEFAULT_IMPORT)])
        self.assertEqual(findings('const defaults = "product_defaults.zig";', "src/client.zig"), [])

    def test_every_known_classifier_is_detected(self):
        for source in (
            'fn orderClass(work: Kind) Group { return switch (work) { .working => .active, else => .done }; }',
            'fn needsDecision(work: Kind) bool { return work == .approval; }',
            'const Status = enum { idle, pub fn of(work: Work) Status { return switch (work.state) { .working => .idle }; } };',
            'const Attention = struct { pub fn of(work: Work) ?Attention { return switch (work.state) { .approval => .{}, else => null }; } };',
            'fn stoppable(state: State, work: Kind) bool { return rules.get(work).stoppable; }',
        ):
            with self.subTest(source=source):
                self.assertEqual(findings(source, "src/overview_view.zig"), [(1, CLASSIFIER)])
        for body in ('return kind === "working" || kind === "retrying";',
                     'switch (kind) { case "working": return true; default: return false; }'):
            with self.subTest(body=body):
                self.assertEqual(findings('function modelCallCurrent(kind: string): boolean { ' + body + ' }',
                                          "clients/ts/src/sessions.ts"), [(1, CLASSIFIER)])

    def test_classifiers_can_be_replaced_by_host_facts(self):
        source = ('fn orderClass(row: Row) Group { return row.group; }\n'
                  'fn needsDecision(row: Row) bool { return row.needs_decision; }\n'
                  'fn stoppable(row: Row) bool { return row.capabilities.stoppable; }\n'
                  'const Attention = struct { pub fn of(row: Row) ?Attention { return row.attention; } };\n'
                  'const Status = enum { idle, pub fn of(row: Row) Status { return row.status; } };\n'
                  'const Unrelated = struct { pub fn of(work: Work) bool { return work == .approval; } };\n')
        self.assertEqual(findings(source, "src/attention.zig"), [])
        self.assertEqual(findings('function modelCallCurrent(row: Row): boolean { return row.modelCallCurrent; }',
                                  "clients/ts/src/sessions.ts"), [])

    def test_typescript_literal_session_defaults_are_detected(self):
        for source in (
            'const spec = { tools: ["bash", "web_search"] };',
            "const spec = { 'tools': ['bash'] };",
            'const tools = [];',
            'const loadedTools = ["bash"];',
            'const tools: readonly string[] = ["bash"];',
            'const spec = { permissionMode: "bypass" };',
            'const spec = { permission_mode: "ask" };',
            'const spec = { effort: "low" };',
            'const spec = { reasoning_effort: null };',
            'const permissionMode = input.permissionMode ?? "bypass";',
            'const spec = { tools: input.tools || ["bash"] };',
            'const spec = { effort: input.effort ?? "low" };',
            'function create(permissionMode = "ask") {}',
        ):
            with self.subTest(source=source):
                self.assertEqual(findings(source, "clients/ts/src/new-client.ts"), [(1, TS_DEFAULT)])

    def test_typescript_ternary_session_defaults_are_detected(self):
        for field, literal in (("tools", '["bash", "web_search"]'),
                               ("permissionMode", '"ask"'), ("effort", '"medium"')):
            for expression in (f"spec.{field} === undefined ? {literal} : spec.{field}",
                               f"spec.{field} !== undefined ? spec.{field} : {literal}"):
                for source in (f"const request = {{ {field}: {expression} }};",
                               f"const {field} = {expression};"):
                    with self.subTest(source=source):
                        self.assertEqual(findings(source, "clients/ts/src/new.ts"), [(1, TS_DEFAULT)])

    def test_types_and_values_read_from_host_or_caller_are_not_defaults(self):
        source = ('interface Spec { permissionMode: "ask" | "bypass"; effort: "low" | null; tools: string[]; }\n'
                  'type Settings = { effort: "low"; permissionMode: "ask" };\n'
                  'const spec = { tools: [...new Set(input.tools)].sort(), permissionMode: input.permissionMode, effort: reply.effort };\n'
                  'const tools = reply.tools;\n'
                  'const effort = input.effort ?? reply.effort;\n'
                  'const permissionMode: "ask" | "bypass" = reply.permissionMode;\n'
                  'function configure(permissionMode: "ask" | "bypass") {}\n'
                  'function setEffort(effort: "low" | "medium" | "high") {}\n'
                  'function configureObject(spec: { permissionMode: "ask" | "bypass" }) {}\n'
                  'const typed: { effort: "low" | "high" } = reply.settings;\n'
                  'if (spec.permissionMode === "ask" || spec.effort !== "low") {}\n')
        self.assertEqual(findings(source, "clients/ts/src/sessions.ts"), [])

    def test_test_blocks_comments_and_strings_do_not_contain_zig_policy(self):
        source = ('// @import("product_defaults.zig")\n'
                  'const text = "fn orderClass() { return .working; }";\n'
                  'const multiline =\n    \\\\@import("product_defaults.zig")\n;\n'
                  'test "nested braces" {\n'
                  '    if (true) { _ = @import("product_defaults.zig"); }\n'
                  '    const s = "}";\n'
                  '}\n'
                  'const S = struct { test { const x = @import("product_defaults.zig"); } };\n')
        self.assertEqual(findings(source, "src/client.zig"), [])
        found = scan(source + 'const defaults = @import("product_defaults.zig");\n', "src/client.zig")
        self.assertEqual(found, [f"src/client.zig:11: {DEFAULT_IMPORT}: {MESSAGE}"])

    def test_typescript_comments_strings_and_test_files_are_ignored(self):
        source = ('// const permissionMode = "bypass";\n'
                  '/* function modelCallCurrent(k) { return k === "working"; } */\n'
                  'const prose = \'tools: ["bash"], effort: "low"\';\n'
                  'const template = `permissionMode: "ask"`;\n')
        self.assertEqual(findings(source, "clients/ts/src/sessions.ts"), [])
        for path in ("clients/ts/src/client.test.ts", "clients/ts/src/client.spec.ts",
                     "clients/ts/src/__tests__/client.ts"):
            with self.subTest(path=path):
                self.assertEqual(findings('const effort = "low";', path), [])
        found = scan(source + 'const effort = "low";\n', "clients/ts/src/sessions.ts")
        self.assertEqual(found, [f"clients/ts/src/sessions.ts:5: {TS_DEFAULT}: {MESSAGE}"])

    def test_allowances_are_specific_to_file_and_rule(self):
        pair = ("src/client.zig", DEFAULT_IMPORT)
        source = ('const defaults = @import("product_defaults.zig");\n'
                  'fn needsDecision(work: Kind) bool { return work == .approval; }\n')
        allowed = {pair: "#1621"}
        self.assertEqual(scan(source, "src/client.zig", allowed),
                         [f"src/client.zig:2: {CLASSIFIER}: {MESSAGE}"])
        self.assertEqual(len(scan(source, "src/other.zig", allowed)), 2)


class ClientSourceInventoryTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.write("src/logic_tests.zig", 'const cores = .{\n};\n')
        self.write("src/cli.zig", 'const ui = @import("Overview.zig"); const host = @import("server.zig");')
        self.write("src/Overview.zig", 'const view = @import("nested/view.zig");')
        self.write("src/server.zig", 'const shared = @import("shared.zig"); const args = @import("cli_args.zig");')
        self.write("src/shared.zig", 'const defaults = @import("product_defaults.zig");')
        self.write("src/cli_args.zig", 'const defaults = @import("product_defaults.zig");')
        self.write("src/product_defaults.zig", "pub const effort = \"low\";")
        self.write("src/nested/view.zig", 'const shared = @import("../shared.zig");')
        self.write("clients/ts/src/wire.ts", 'const effort = "low";')
        self.write("clients/ts/src/nested/client.ts", 'const effort = "low";')

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def test_closure_excludes_host_owners_but_retains_required_shared_clients(self):
        names = {path.relative_to(self.root).as_posix() for path in surfaces(self.root)}
        self.assertIn("src/nested/view.zig", names)
        self.assertIn("src/cli_args.zig", names)
        self.assertIn("clients/ts/src/nested/client.ts", names)
        self.assertNotIn("src/server.zig", names)
        self.assertNotIn("src/shared.zig", names)
        self.assertNotIn("clients/ts/src/wire.ts", names)
        found = violations(self.root, {})
        self.assertEqual(found, [f"clients/ts/src/nested/client.ts:1: {TS_DEFAULT}: {MESSAGE}",
                                 f"src/cli_args.zig:1: {DEFAULT_IMPORT}: {MESSAGE}"])

    def test_new_imported_client_and_typescript_file_are_scanned(self):
        self.write("src/nested/view.zig", 'const added = @import("new_view.zig");\n'
                   'test { const fixture = @import("fixture.zig"); }')
        self.write("src/nested/new_view.zig", 'const defaults = @import("../product_defaults.zig");')
        self.write("src/nested/fixture.zig", 'const defaults = @import("../product_defaults.zig");')
        self.write("clients/ts/src/new.ts", 'const tools = ["bash"];')
        self.write("clients/ts/src/nested/wire.ts", 'const effort = "low";')
        self.write("clients/ts/src/new-client.mts", 'const permissionMode = "bypass";')
        self.write("clients/ts/src/extensionless", 'const tools = ["bash"];')
        names = {path.relative_to(self.root).as_posix() for path in surfaces(self.root)}
        self.assertIn("src/nested/new_view.zig", names)
        self.assertNotIn("src/nested/fixture.zig", names)
        found = violations(self.root, {})
        self.assertIn(f"src/nested/new_view.zig:1: {DEFAULT_IMPORT}: {MESSAGE}", found)
        self.assertIn(f"clients/ts/src/new.ts:1: {TS_DEFAULT}: {MESSAGE}", found)
        for name in ("nested/wire.ts", "new-client.mts", "extensionless"):
            self.assertIn(f"clients/ts/src/{name}:1: {TS_DEFAULT}: {MESSAGE}", found)

    def test_required_inventory_stays_covered_even_when_host_reaches_it(self):
        for name in REQUIRED_SOURCES:
            self.write(name, "")
        self.write("src/server.zig", "\n".join('const x%d = @import("%s");' % (i, Path(name).name)
                                               for i, name in enumerate(REQUIRED_SOURCES)))
        names = {path.relative_to(self.root).as_posix() for path in surfaces(self.root)}
        self.assertTrue(set(REQUIRED_SOURCES) <= names)

    def test_retagged_selection_allowance_still_requires_its_import(self):
        for pair, issue in SELECTION_ISSUES.items():
            with self.subTest(pair=pair):
                self.write("src/Overview.zig", f'const selection = @import("{Path(pair[0]).name}");')
                self.write(pair[0], 'const defaults = @import("product_defaults.zig");')
                allowed = {pair: issue}
                self.assertEqual(stale_allowances(self.root, allowed), [])
                self.write(pair[0], "// The Host supplies provider and model now.\n")
                self.assertEqual(stale_allowances(self.root, allowed), [
                    f"{pair[0]}: remove stale allowance for {pair[1]} (#1697)"
                ])

    def test_removing_local_policy_requires_removing_its_allowance(self):
        allowed = {("src/cli_args.zig", DEFAULT_IMPORT): "#1621"}
        self.assertEqual(stale_allowances(self.root, allowed), [])
        self.write("src/cli_args.zig", "// The Host supplies defaults now.\n")
        self.assertEqual(stale_allowances(self.root, allowed),
                         [f"src/cli_args.zig: remove stale allowance for {DEFAULT_IMPORT} (#1621)"])



class ClientAllowanceRatchetTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git("init", "-q")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test",
                               "-c", "user.email=test@example.invalid", *args],
                              capture_output=True, text=True, check=True)

    def write_allowances(self, entries):
        path = self.root / GATE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("ALLOWED = " + repr(entries) + "\n")

    def commit(self, trusted=False):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        if trusted:
            self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def test_missing_main_gate_has_no_allowance_baseline(self):
        (self.root / "old.txt").write_text("before the gate")
        self.commit(trusted=True)
        self.write_allowances({("src/cli.zig", DEFAULT_IMPORT): "#1621"})
        self.commit()
        self.assertEqual(allowance_growth(self.root), [])

    def test_existing_baseline_rejects_growth_and_allows_shrink(self):
        old = ("src/cli.zig", DEFAULT_IMPORT)
        removed = ("src/attention.zig", CLASSIFIER)
        new = ("src/new.zig", DEFAULT_IMPORT)
        self.write_allowances({old: "#1621", removed: "#1622"})
        self.commit(trusted=True)
        self.write_allowances({old: "#1621"})
        self.assertEqual(allowance_growth(self.root), [])
        self.commit(trusted=True)
        self.write_allowances({old: "#1621", removed: "#1622", new: "#1621"})
        self.commit()
        found = allowance_growth(self.root)
        self.assertEqual(found, [f"{file}: {rule}: allowance exceeds the trusted review base: {MESSAGE}"
                                 for file, rule in sorted((removed, new))])

    def test_selection_retag_preserves_the_existing_pair_ratchet(self):
        old = {pair: "#1621" for pair in SELECTION_ISSUES}
        self.write_allowances(old)
        self.commit(trusted=True)
        self.write_allowances(SELECTION_ISSUES)
        self.assertEqual(allowance_growth(self.root), [])
        self.commit(trusted=True)
        self.write_allowances({})
        self.commit(trusted=True)
        self.write_allowances(SELECTION_ISSUES)
        self.assertEqual(allowance_growth(self.root), [
            f"{file}: {rule}: allowance exceeds the trusted review base: {MESSAGE}"
            for file, rule in sorted(SELECTION_ISSUES)
        ])

    def test_selection_issue_is_specific_to_existing_pairs_and_trusted_history(self):
        for pair, issue in SELECTION_ISSUES.items():
            with self.subTest(pair=pair):
                current = "ALLOWED = " + repr({pair: issue})
                historical = "ALLOWED = " + repr({pair: "#1621"})
                self.assertEqual(allowed_entries(current), {pair: issue})
                self.assertEqual(allowed_entries(current, trusted=True), {pair: issue})
                self.assertEqual(allowed_entries(historical, trusted=True), {pair: "#1621"})
                with self.assertRaises(ValueError):
                    allowed_entries(historical)
                with self.assertRaises(ValueError):
                    allowed_entries("ALLOWED = " + repr({pair: "#1629"}), trusted=True)
        for pair in (("src/client_defaults.zig", DEFAULT_IMPORT),
                     ("src/new_selection.zig", DEFAULT_IMPORT),
                     ("src/app_settings.zig", DEFAULT_IMPORT),
                     ("src/SignIn.zig", CLASSIFIER)):
            with self.subTest(pair=pair):
                source = "ALLOWED = " + repr({pair: "#1697"})
                with self.assertRaises(ValueError):
                    allowed_entries(source)
                with self.assertRaises(ValueError):
                    allowed_entries(source, trusted=True)

    def test_removed_allowance_cannot_be_reintroduced(self):
        pair = ("src/client_defaults.zig", DEFAULT_IMPORT)
        self.write_allowances({})
        self.commit(trusted=True)
        self.write_allowances({pair: "#1621"})
        self.assertEqual(allowance_growth(self.root),
                         [f"{pair[0]}: {pair[1]}: allowance exceeds the trusted review base: {MESSAGE}"])

    def test_candidate_cannot_supply_its_own_trusted_baseline(self):
        self.write_allowances({})
        self.commit(trusted=True)
        self.write_allowances({("src/new.zig", CLASSIFIER): "#1622"})
        self.commit()
        self.assertEqual(len(allowance_growth(self.root)), 1)

    def test_missing_trusted_ref_fails_closed(self):
        self.write_allowances({})
        self.commit()
        with self.assertRaises(subprocess.CalledProcessError):
            allowance_growth(self.root)

    def test_allowances_must_be_literal_pairs_with_their_removal_issue(self):
        for source in ('ALLOWED = computed()', 'ALLOWED = []', 'ALLOWED = {}\nALLOWED = {}',
                       'ALLOWED = {("src/cli.zig", "imports product_defaults.zig"): "#1622"}',
                       'ALLOWED = {"src/cli.zig": "#1621"}'):
            with self.subTest(source=source):
                with self.assertRaises((ValueError, TypeError)):
                    allowed_entries(source)


if __name__ == "__main__":
    unittest.main()
