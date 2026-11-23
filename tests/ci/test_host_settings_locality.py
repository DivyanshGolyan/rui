"""Mutation tests for settings knowledge, including shared wire vocabulary."""
import json
import tempfile
import unittest
from pathlib import Path

from host_settings_locality import ROOT, declaration_members, facts, scan, surfaces, violations, vocabulary, host_child_violations, host_environment_violations, credential_location_violations


class HostSettingsLocalityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.derived = facts()

    def check(self, source, relative="src/cli.zig"):
        return scan(source, relative, self.derived)

    def test_surfaces_name_no_host_setting(self):
        found = violations()
        self.assertEqual(found, [], "move Host-setting knowledge to its owner:\n" + "\n".join(found))

    def test_every_derived_path_is_rejected(self):
        _, paths, _, _ = self.derived
        for path in paths:
            if len(path) < 2:
                continue
            value = ".".join("sample" if part == "*" else part for part in path)
            with self.subTest(path=value):
                self.assertTrue(self.check("const injected = " + json.dumps(value) + ";"))

    def test_every_derived_key_is_rejected_on_a_typed_document(self):
        keys, _, _, _ = self.derived
        for key in keys:
            with self.subTest(key=key):
                code = "function use(doc: HostSettings) { return doc[" + json.dumps(key) + "]; }"
                self.assertTrue(self.check(code, "clients/ts/src/client.ts"))

    def test_json_and_setting_names_without_dots(self):
        for code in ('const x = "timeoutMs";', 'const x = "caFile";',
                     'const x = .{ .bearer_token = source };',
                     'const credential_file = source;',
                     'const x = "{\\"timeoutMs\\":42}";',
                     'const x = parsed.get("activeCapacity");'):
            with self.subTest(code=code):
                self.assertTrue(self.check(code))

    def test_json_structure_is_settings_knowledge_without_dotted_literals(self):
        for value in ({"store": {"sqlite": {"dir": "/tmp/x"}}},
                      {"tools": {"bash": {"path": "/bin/sh"}}},
                      {"providers": {"openai": {"endpoint": "https://example.org"}}}):
            with self.subTest(value=value):
                self.assertTrue(self.check("const x = " + json.dumps(json.dumps(value)) + ";"))
        self.assertTrue(self.check('const x: host_settings.Settings = .{ .store = source };'))
        self.assertTrue(self.check('const x: HostSettings = { store: source };', "clients/ts/src/client.ts"))

    def test_literals_comments_escapes_and_line_numbers(self):
        self.assertFalse(self.check('// "tools.bash.path"\ntest "network.caFile" {\n _ = "timeoutMs";\n}\n'))
        self.assertEqual(self.check('// comment\nconst x = "network.caFile";')[0].split(':')[1], '2')
        self.assertTrue(self.check('const x = "network.\\u0063aFile";'))
        self.assertTrue(self.check('const x =\n    \\\\tools.bash.timeoutMs\n;'))
        self.assertFalse(self.check('/* timeoutMs */ const x = "https://example.org";', 'clients/ts/src/client.ts'))
        self.assertTrue(self.check('const x = `tools.bash.path`;', 'clients/ts/src/client.ts'))

    def test_shared_and_generic_words_are_not_inherently_settings(self):
        self.assertFalse(self.check('''
fn read(session: Session, parsed: Parsed, host: HostInfo) void {
    const settings = &session.settings;
    _ = settings.tools;
    _ = settings.provider;
    _ = host.active_capacity;
    _ = host.paused;
    _ = host.capabilities.providers;
    _ = arguments.timeout_ms;
    _ = .mcp;
    _ = parsed.get("store");
    const path = "path";
    _ = path;
    _ = .mysql;
    _ = .sqlite;
}
fn start(started: Timestamp, timeout_ms: u64) void { _ = timeout_ms; }
'''))

    def test_shared_words_fail_in_host_paths_and_typed_accesses(self):
        for code in ('const x = "store.sqlite.dir";',
                     'const x = host.tools.bash.path;',
                     'fn f(h: *host_settings.Settings) void { _ = h.store; }',
                     'fn f(h: *host_settings.Settings) void { const alias = h; _ = alias.providers; }',
                     'const x = HostSettings["providers"];',
                     'function f(h: HostSettings) { return Object.hasOwn(h, "store"); }',
                     'function f(h: HostSettings) { return h["store"]; }',
                     'function f(h: HostSettings) { const {store} = h; }'):
            with self.subTest(code=code):
                self.assertTrue(self.check(code, "clients/ts/src/client.ts" if 'function' in code or 'HostSettings[' in code else "src/cli.zig"))

    def test_host_bindings_do_not_taint_session_settings_in_another_function(self):
        self.assertFalse(self.check('''
fn serve(settings: *host_settings.Settings) void { consume(settings); }
fn read(settings: *SessionSettings) void { _ = settings.tools; }
'''))

    def test_independent_domain_members_include_last_uncommaed_tag(self):
        self.assertEqual(declaration_members("pub const Kind = enum { one, two };", "Kind"), {"one", "two"})
        self.assertEqual(declaration_members("pub const Args = struct { count: ?u64 = null, };", "Args"), {"count"})

    def test_new_schema_leaf_automatically_extends_vocabulary(self):
        schema = {"properties": {"newGroup": {"properties": {"newLeaf": {"type": "string"}}}}}
        keys, paths = vocabulary(schema)
        self.assertEqual(keys, {"newGroup", "newLeaf"})
        derived = keys, paths, set(), set()
        self.assertTrue(scan('const x = "newLeaf";', derived=derived))
        self.assertTrue(scan('const x = "newGroup.newLeaf";', derived=derived))

    def test_surface_scope(self):
        paths = {path.relative_to(ROOT).as_posix() for path in surfaces(ROOT)}
        for expected in ('src/cli.zig', 'src/serve_grammar.zig', 'src/cli_grammar.zig',
                         'src/Root.zig', 'src/Overview.zig', 'src/HostLifecycle.zig',
                         'src/session_view.zig', 'clients/ts/src/client.ts'):
            self.assertIn(expected, paths)
        self.assertNotIn('src/host_settings.zig', paths)
        self.assertNotIn('src/h2/Engine.zig', paths)
        self.assertNotIn('clients/ts/src/settings.ts', paths)

    def test_host_environment_allowlist_and_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            path = root / "src/providers.zig"
            path.write_text('fn f(environ: Env) void { _ = environ.get("HOME"); }\n')
            self.assertEqual(host_environment_violations(root), [])
            path.write_text(path.read_text() + 'fn x(environ: Env) void { _ = environ.get("RUI_X"); }\n')
            self.assertIn('src/providers.zig:2:', host_environment_violations(root)[0])

    def test_credential_location_is_the_only_variable_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            provider = root / "src/providers.zig"
            for name in ("RUI_OPENAI_KEY_FILE", "RUI_CODEX_CREDENTIAL_FILE", "RUI_CHATGPT_CREDENTIAL_FILE"):
                provider.write_text(f'fn f(environ: Env) void {{ _ = environ.get("{name}"); }}\n')
                self.assertTrue(host_environment_violations(root))
                self.assertTrue(credential_location_violations(root))
            provider.write_text('const loc = @import("credential_location.zig");\n')
            self.assertIn("import not allowed", credential_location_violations(root)[0])
            provider.unlink()
            (root / "src/host_start.zig").write_text('const loc = @import("credential_location.zig");\n')
            self.assertEqual(credential_location_violations(root), [])
            (root / "src/credential_location.zig").write_text('const n = "RUI_OPENAI_KEY_FILE";\n')
            self.assertEqual(credential_location_violations(root), [])

    def test_real_file_mutation_is_red_then_reverted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'src').mkdir()
            (root / 'openapi.json').write_text((ROOT / 'openapi.json').read_text())
            path = root / 'src/cli.zig'
            clean = 'const x = "store";\n'
            path.write_text(clean)
            self.assertEqual(violations(root), [])
            path.write_text(clean + 'const mutation = "timeoutMs";\n')
            self.assertTrue(violations(root))
            path.write_text(clean)
            self.assertEqual(violations(root), [])


if __name__ == "__main__":
    unittest.main()


class HostChildLocalityTest(unittest.TestCase):
    def test_duplicate_child_builder_mutation_turns_gate_red(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "src").mkdir()
            owner = root / "src/host_start.zig"
            owner.write_text('pub fn spawn() void { argv[1] = "host"; argv[2] = "serve"; }\n')
            other = root / "src/HostLifecycle.zig"
            clean = 'fn read() void { _ = eql(argv[1], "host"); _ = eql(argv[2], "serve"); }\n'
            other.write_text(clean)
            self.assertEqual(host_child_violations(root), [])
            for mutation in (
                'fn duplicate() void { const argv = &.{"rui", "host", "serve"}; }\n',
                'fn duplicate() void { argv[1] = "host"; argv[2] = "serve"; }\n',
            ):
                other.write_text(clean + mutation)
                found = host_child_violations(root)
                self.assertEqual(len(found), 1, found)
                self.assertIn("Host child argv must be built only by host_start.spawn", found[0])
            other.write_text(clean)
            owner.write_text(owner.read_text() + 'fn second() void { const args = &.{"host", "serve"}; }\n')
            self.assertEqual(len(host_child_violations(root)), 1)
