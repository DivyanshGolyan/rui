"""Exercise the real Zig acceptance I/O owner without compiling Rui."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeAcceptanceTest(unittest.TestCase):
    def test_commands_stay_fresh_and_preserve_diagnostics(self):
        with tempfile.TemporaryDirectory(prefix="rui-native-acceptance-") as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "build", root / "build")
            (root / "build.zig").write_text('''
const std = @import("std");
const ci = @import("build/ci.zig");
pub fn build(b: *std.Build) void {
    const target = b.step("accept", "Exercise acceptance");
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("fixture.py"));
    run.addArg("literal $value `command` with spaces");
    target.dependOn(&run.step);
    // Two parents must not wrap a shared dependency twice.
    b.step("alias", "Shared run").dependOn(&run.step);
    const generator = b.addSystemCommand(&.{"python3"});
    generator.addFileArg(b.path("generate.py"));
    const output = generator.addOutputFileArg("generated");
    run.addFileArg(output);
    const checked = b.addSystemCommand(&.{"true"});
    checked.expectExitCode(0);
    const protocol = b.addSystemCommand(&.{"true"});
    protocol.enableTestRunnerMode();
    b.step("checked", "Explicit check").dependOn(&checked.step);
    b.step("protocol", "Test protocol").dependOn(&protocol.step);
    const captured = b.addSystemCommand(&.{"true"});
    _ = captured.captureStdOut(.{});
    b.step("captured", "Generator capture").dependOn(&captured.step);
    ci.concurrentAcceptance(b);
    std.debug.assert(run.stdio == .check and run.has_side_effects);
    std.debug.assert(run.argv.items.len == 8);
    std.debug.assert(generator.stdio == .infer_from_args and !generator.has_side_effects);
    std.debug.assert(checked.stdio == .check and !checked.has_side_effects);
    std.debug.assert(protocol.stdio == .zig_test and !protocol.has_side_effects);
    std.debug.assert(captured.stdio == .infer_from_args and !captured.has_side_effects);
}
''')
            (root / "fixture.py").write_text('''
import os
from pathlib import Path
import sys
assert sys.argv[1] == "literal $value `command` with spaces", sys.argv
assert Path(sys.argv[2]).read_text() == "generated"
with Path("executions").open("a") as output:
    print("executed", file=output)
print("fixture stdout", flush=True)
print("fixture stderr", file=sys.stderr, flush=True)
sys.exit(int(os.environ.get("FIXTURE_EXIT", "0")))
''')
            (root / "generate.py").write_text('''
from pathlib import Path
import sys
with Path("generations").open("a") as output:
    print("generated", file=output)
Path(sys.argv[1]).write_text("generated")
''')
            command = ["zig", "build", "accept", "alias", "-j1", "--summary", "all"]
            for status in (0, 0, 42):
                result = subprocess.run(command, cwd=root, env=dict(os.environ, FIXTURE_EXIT=str(status)),
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
                self.assertEqual(result.returncode == 0, status == 0, result.stdout)
                self.assertIn("fixture stdout", result.stdout)
                self.assertIn("fixture stderr", result.stdout)
            self.assertEqual((root / "executions").read_text().splitlines(), ["executed"] * 3)
            self.assertEqual((root / "generations").read_text().splitlines(), ["generated"])


    @unittest.skipUnless(os.environ.get("GITHUB_ACTIONS") == "true",
                         "Overlap proof uses two Zig jobs on hosted CI; local builds use -j1")
    def test_independent_commands_overlap_and_inherited_stdio_does_not(self):
        import signal
        import socket

        with tempfile.TemporaryDirectory(prefix="rui-native-overlap-") as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "build", root / "build")
            (root / "build.zig").write_text('''
const std = @import("std");
const ci = @import("build/ci.zig");
pub fn build(b: *std.Build) void {
    const target = b.step("overlap", "Prove independent acceptance overlaps");
    for ([_][]const u8{ "first", "second" }) |name| {
        const run = b.addSystemCommand(&.{"python3"});
        run.addFileArg(b.path("peer.py"));
        run.addArg(name);
        target.dependOn(&run.step);
    }
    if (b.option(bool, "buffered", "Buffer acceptance output") orelse true)
        ci.concurrentAcceptance(b);
}
''')
            (root / "peer.py").write_text('''
import os
import socket
import sys
with socket.create_connection(("127.0.0.1", int(os.environ["OVERLAP_PORT"])), timeout=10) as peer:
    peer.sendall(sys.argv[1].encode())
    observed = peer.recv(1) == b"1"
    print(f"{sys.argv[1]} overlap observed={observed}", flush=True)
    sys.exit(0 if observed else 42)
''')
            for buffered in (True, False):
                with self.subTest(buffered=buffered), socket.socket() as server:
                    server.bind(("127.0.0.1", 0))
                    server.listen(2)
                    server.settimeout(5)
                    command = ["zig", "build", "overlap", "-j2", "--summary", "all",
                               "-Dbuffered=" + str(buffered).lower()]
                    peers = []
                    started = []
                    with subprocess.Popen(command, cwd=root,
                                          env=dict(os.environ, OVERLAP_PORT=str(server.getsockname()[1])),
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                          start_new_session=True) as process:
                        try:
                            try:
                                for _ in range(2):
                                    peer, _ = server.accept()
                                    peers.append(peer)
                                    peer.settimeout(5)
                                    started.append(peer.recv(64).decode())
                            except TimeoutError:
                                pass
                            observed = len(started) == 2
                            for peer in peers:
                                peer.sendall(b"1" if observed else b"0")
                            # The peer records the coordinator's observation before exiting.
                            output, _ = process.communicate(timeout=20)
                            self.assertEqual(observed, buffered, output)
                            self.assertEqual(process.returncode == 0, buffered, output)
                            self.assertIn("overlap observed=" + str(buffered), output)
                        finally:
                            for peer in peers:
                                peer.close()
                            if process.poll() is None:
                                os.killpg(process.pid, signal.SIGKILL)
                                process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
