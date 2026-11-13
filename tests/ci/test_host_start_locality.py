"""Start reporting remains at the CLI door, not in server.zig."""
import unittest

from host_start_locality import scan, violations


class HostStartLocalityTest(unittest.TestCase):
    def test_host_produces_failures_without_publishing(self):
        found = violations()
        self.assertEqual([], found, "\n".join(found))

    def test_both_forbidden_names_are_rejected(self):
        source = ('fn f() void {\n'
                  '    launch_frame.writeRefusal(io, failure);\n'
                  '    std . Io . File\n . stdout().writeStreamingAll(io, line);\n'
                  '}\n')
        found = scan(source)
        self.assertEqual(2, len(found))
        self.assertIn('src/server.zig:2: names writeRefusal', found[0])
        self.assertIn('src/server.zig:3: names File.stdout', found[1])

    def test_references_aliases_and_quoted_names_are_rejected(self):
        for source in ('const publish = launch_frame.writeRefusal;',
                       'const stdout = std.Io.File.stdout;',
                       'const publish = frame.@"writeRefusal";',
                       'const stdout = std.Io.@"File".@"stdout";'):
            with self.subTest(source=source):
                self.assertEqual(1, len(scan(source)))

    def test_origin_coupling_is_rejected_in_every_host_file(self):
        for source in ('const frame = @import("launch_frame.zig");',
                       'const frame = @import ( "./launch_frame.zig" );',
                       'const @"launched" = true;',
                       'test "field domain" { var launched = false; }'):
            with self.subTest(source=source):
                found = scan(source, "src/server_host.zig")
                self.assertEqual(1, len(found))
                self.assertIn("src/server_host.zig:1:", found[0])
        self.assertEqual([], scan('// launched @import("launch_frame.zig")\n'
                                  'const s = "launched";'))

    def test_comments_strings_and_balanced_tests_are_not_production(self):
        source = ('// writeRefusal and File.stdout\n'
                  'const s = "File.stdout writeRefusal // }";\n'
                  'const multiline =\n    \\\\File.stdout writeRefusal\n;\n'
                  'test "writeRefusal" {\n'
                  '    if (true) { _ = std.Io.File.stdout(); }\n'
                  '    const brace = "}";\n'
                  '}\n'
                  'const S = struct { test { launch_frame.writeRefusal(io, f); } };\n')
        self.assertEqual([], scan(source))
        found = scan(source + 'const publish = frame.writeRefusal;\n')
        self.assertEqual(1, len(found))
        self.assertIn('src/server.zig:11:', found[0])


if __name__ == "__main__":
    unittest.main()
