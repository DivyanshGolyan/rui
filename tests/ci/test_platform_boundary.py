import json
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from platform_boundary import mac_path, python_sites, sites, violations, zig_sites  # noqa: E402
from select_tests import select  # noqa: E402


AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (Path(__file__).parents[2] / "build.zig").read_text()))


class PlatformBoundaryTest(unittest.TestCase):
    def test_repository_platform_sites_are_all_under_mac_paths(self):
        self.assertEqual(violations(sites()), [])

    def test_zig_scan_reads_platform_names_and_divergent_syscalls(self):
        for source in ('const os = builtin.os.tag;', 'if (@import("builtin").os.tag == .macos) {}',
                       '_ = std.c.shutdown(fd, std.c.SHUT.WR);', 'std.posix.kill(-pgid, .KILL) catch {};',
                       'const r = c.setrlimit(c.RLIMIT_NOFILE, &l);', '_ = std.c.listen(fd, 0);', '_ = c.kill(-group, c.SIGKILL);'):
            self.assertEqual(zig_sites(source), 1, source)
        for source in ('// builtin.os in a comment', 'const s = "std.c.shutdown";', '\\\\builtin.os.tag',
                       'fn f(os: std.Target.Os.Tag) void {}', 'const a = builtin.mode;',
                       'self.listen(io)', 'address.listen(io, .{})', '_ = std.c.fcntl(fd, 3);',
                       'std.posix.kill(leader, .KILL) catch {};', '_ = c.kill(pid, c.SIGKILL);'):
            self.assertEqual(zig_sites(source), 0, source)

    def test_python_scan_ignores_comments_strings_and_attributes(self):
        self.assertEqual(python_sites('if sys.platform == "darwin":\n    pass\n'), 1)
        self.assertEqual(python_sites('name = platform.system()\nos.uname()\n'), 2)
        self.assertEqual(python_sites('# sys.platform\ntext = "sys.platform"\nx.sys.platform\n'), 0)

    def test_sites_outside_mac_paths_are_violations(self):
        self.assertEqual(violations({}), [])
        self.assertIn("src/a.zig: 2 platform sites outside src/os/", violations({"src/a.zig": 2})[0])

    def test_mac_specific_paths(self):
        for path in ("src/os/socket.zig", "tests/integration/os_semantics.py", "src/host_launch.c",
                     "src/evaluator_policy.h", "src/evaluator_policy.inc", "src/curl-post-retry.patch",
                     "src/build_transport.sh", "tests/integration/evaluator_driver.c", "build.zig", "build.zig.zon",
                     ".github/actions/setup/action.yml", ".github/workflows/daily-macos.yml",
                     ".github/workflows/qualify-macos.yml", "tests/ci/qualification.py", "install.sh",
                     "src/os/process.zig", "src/os/descriptor_limit.zig", "src/h2/Connection.zig",
                     "src/h2/testing/Peer.zig"):
            self.assertTrue(mac_path(path), path)
        for path in ("src/session_view.zig", "src/server.zig", "tests/integration/dispatch_integration.py",
                     ".github/workflows/check.yml", "README.md"):
            self.assertFalse(mac_path(path), path)

    def test_selection_requires_mac_for_review_of_mac_specific_paths(self):
        self.assertTrue(select(["src/os/socket.zig"], "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["README.md", "src/host_launch.c"], "review", AVAILABLE)["mac_required"])
        self.assertFalse(select(["src/turn_policy.zig"], "review", AVAILABLE)["mac_required"])
        # Drafts get development feedback only.
        self.assertFalse(select(["src/os/socket.zig"], "development", AVAILABLE)["mac_required"])

    def test_linux_gate_requires_the_macos_type_check(self):
        self.assertIn("typecheck-macos", AVAILABLE)
        workflow = (Path(__file__).parents[2] / ".github/workflows/check.yml").read_text()
        job = re.search(r"(?ms)^  macos_typecheck:\n(.*?)(?=^  [a-z_]+:|\Z)", workflow)[1]
        self.assertIn("runs-on: ubuntu-", job)
        self.assertIn("zig build typecheck-macos", job)
        gate = re.search(r"(?ms)^  linux:\n(.*?)(?=^  [a-z_]+:|\Z)", workflow)[1]
        self.assertIn("macos_typecheck", gate.split("\n", 2)[1])
        self.assertIn('test "$TYPECHECK_RESULT" = success', gate)

    def test_executed_plan_runs_mac_on_pull_requests_only_for_mac_specific_paths(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/check.yml").read_text()
        script = textwrap.dedent(re.search(r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY$", workflow)[1])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "tests").symlink_to((Path(__file__).parents[1]).resolve(), target_is_directory=True)
            cases = (("src/turn_policy.zig", "pull_request", False), ("src/os/socket.zig", "push", False),
                     ("src/os/socket.zig", "pull_request", True), (".github/workflows/qualify-macos.yml", "pull_request", True))
            for path, event, mac in cases:
                with self.subTest(path=path, event=event):
                    selection = select([path], "review", AVAILABLE)
                    (root / "selection.json").write_text(json.dumps(selection))
                    (root / "output").write_text("")
                    subprocess.run([sys.executable, "-B", "-c", script], cwd=root, check=True,
                                   env=dict(os.environ, STABLE="false", EVENT_NAME=event, GITHUB_REF_NAME="branch",
                                            GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary")))
                    outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                    native = json.loads(outputs["native_targets"])
                    self.assertEqual(outputs["native"], str(mac).lower())
                    if mac:
                        self.assertEqual(native, selection["native_targets"] or ["check"])
                        self.assertTrue(json.loads(outputs["macos_matrix"])["include"])
                    else:
                        self.assertEqual(native, [])


if __name__ == "__main__":
    unittest.main()
