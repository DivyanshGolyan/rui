from pathlib import Path
import os
import re
import socket
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from platform_boundary import (bind_sites, build_violations, flag_violations, mac_path, pty_close_violations, python_sites, shell_sites, sites, typescript_sites,  # noqa: E402
                               unlistened_binds, violations, zig_sites)
import build_files  # noqa: E402
from select_tests import select  # noqa: E402


AVAILABLE = set(build_files.steps())


class PlatformBoundaryTest(unittest.TestCase):
    def test_pty_close_discipline(self):
        bad = "def f():\n    master, slave = open_pty()\n    os.close(master)\n"
        good = "def f():\n    master, slave = open_pty()\n    close_pty(master, slave)\n"
        self.assertIn("close_pty", pty_close_violations(bad)[0])
        self.assertEqual(pty_close_violations(good), [])
        self.assertIn("close_pty", pty_close_violations(
            "class Chrome:\n    def open(self):\n        master, slave = open_pty()\n"
            "        self.descriptors += [master, slave]\n"
            "    def close(self):\n        return (lambda fd=fd: os.close(fd) for fd in self.descriptors)\n")[0])
        self.assertIn("close_pty", pty_close_violations(
            "class P:\n    def open(self):\n        self.master, self.slave = open_pty()\n"
            "    def close(self):\n        os.close(self.master)\n")[0])
        for folder in ("integration", "qualification"):
            for path in (Path(__file__).parents[1] / folder).rglob("*.py"):
                self.assertEqual(pty_close_violations(path.read_text(), str(path)), [])

    def test_repository_platform_sites_are_all_under_mac_paths(self):
        self.assertEqual(violations(sites()), [])

    def test_file_flag_comparisons_use_portable_owner(self):
        self.assertEqual(flag_violations(), [])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            directory = root / "tests/integration"
            directory.mkdir(parents=True)
            fixture = directory / "example.py"
            fixture.write_text(textwrap.dedent('''\
                def check(fd, expected):
                    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
                    assert flags == expected
                    assert expected != fcntl.fcntl(fd, fcntl.F_GETFL)
                    assert os_semantics.user_file_flags(flags) == expected
                    assert user_file_flags(fcntl.fcntl(fd, fcntl.F_GETFL)) != expected
                    assert termios.tcgetattr(fd) == expected
                    assert b"a" != b"b"
                def unrelated(flags, expected):
                    assert flags == expected
            '''))
            for exempt in ("os_semantics.py", "terminal_restoration_fixture.py"):
                (directory / exempt).write_text("def check(fd):\n    assert fcntl.fcntl(fd, fcntl.F_GETFL) == 0\n")
            messages = flag_violations(root)
            self.assertEqual(len(messages), 2)
            self.assertIn("tests/integration/example.py:3:", messages[0])
            self.assertIn("tests/integration/example.py:4:", messages[1])
            self.assertTrue(all("assert_file_flags or os_semantics.user_file_flags" in m for m in messages))

    def test_darwin_build_branches_delegate_to_mac_path(self):
        for path in build_files.files():
            name = path.relative_to(build_files.ROOT).as_posix()
            if not mac_path(name):
                self.assertEqual(build_violations(path.read_text(), name), [], name)
        for inline in (
                'if (target.result.os.tag == .macos) { module.linkFramework("Security", .{}); }',
                'if (host.isDarwin()) "lib.dylib" else "lib.so"',
                'if (target.result.os.tag == .macos) { darwin.linkTrust(module); sideEffect(); }',
                'if (target.result.os.tag == .macos and enabled) { sideEffect(); }',
                'switch (target.result.os.tag) { .macos => sideEffect(), else => {} }',
                'if (target.result.os.tag == .ios) { sideEffect(); }'):
            with self.subTest(inline=inline):
                self.assertIn("build/darwin.zig", build_violations(inline)[0])
        for portable in (
                'if (target.result.os.tag == .linux) { linuxOnly(); }',
                'if (target.result.os.tag == .macos) { darwin.linkTrust(module); }',
                'if (target.result.os.tag == .macos) { darwin.one(); darwin.two(b, output.path); }',
                '.{ .cpu_arch = .aarch64, .os_tag = .macos }',
                '// if (host.isDarwin()) not code'):
            with self.subTest(portable=portable):
                self.assertEqual(build_violations(portable), [])

    def test_scan_reaches_files_in_subdirectories(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for path in ("src/mcp/test_server.zig", "src/os/socket.zig"):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text("_ = std.c.shutdown(listener, std.c.SHUT.RDWR);\n")
            self.assertEqual(sites(root), {"src/mcp/test_server.zig": 1})

    def test_zig_scan_reads_platform_names_and_divergent_syscalls(self):
        for source in ('const os = builtin.os.tag;', 'if (@import("builtin").os.tag == .macos) {}',
                       '_ = std.c.shutdown(fd, std.c.SHUT.WR);', 'std.posix.kill(-pgid, .KILL) catch {};',
                       'const r = c.setrlimit(c.RLIMIT_NOFILE, &l);', '_ = std.c.listen(fd, 0);', '_ = c.kill(-group, c.SIGKILL);',
                       '_ = std.c.getpeername(fd, addr, len);'):
            self.assertEqual(zig_sites(source), 1, source)
        for source in ('// builtin.os in a comment', 'const s = "std.c.shutdown";', '\\\\builtin.os.tag',
                       'fn f(os: std.Target.Os.Tag) void {}', 'const a = builtin.mode;',
                       'self.listen(io)', 'address.listen(io, .{})', '_ = std.c.fcntl(fd, 3);',
                       'std.posix.kill(leader, .KILL) catch {};', '_ = c.kill(pid, c.SIGKILL);'):
            self.assertEqual(zig_sites(source), 0, source)

    def test_process_observation_and_retirement_are_mac_sites(self):
        for source in ('const ps = "/bin/ps";', '_ = std.posix.system.flock(fd, 0);',
                       'platform.StoreLease.observe(io, store);',
                       'client.upgradeGenerationRetired(a, b, c, d, e);',
                       'const HostLifecycle = @import("HostLifecycle.zig"); HostLifecycle.activate(init);', 'rui_launch_detached_reported(a);',
                       'rui_process_generation(pid, &started);'):
            self.assertEqual(zig_sites(source), 1, source)
        for source in ('// "/bin/ps"', 'const s = "flock";', 'lease.acquire(io);'):
            self.assertEqual(zig_sites(source), 0, source)

    def test_new_lifecycle_consumers_must_be_mac_paths(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "src").mkdir()
            for module, methods in (
                    ("HostLifecycle.zig", ("observe", "activate", "awaitRetirement")),
                    ("host_coordinator.zig", ("restart", "restartAll", "run")),
                    ("host_restart_all.zig", ("discover", "restart", "run")),
                    ("host_identity.zig", ("generation", "peer", "snapshot")),
                    ("host_start.zig", ("spawn",))):
                for method in methods:
                    for directory, prefix in (("src", ""), ("src/nested", "../")):
                        (root / directory).mkdir(exist_ok=True)
                        path = f"{directory}/new_consumer.zig"
                        for expression in (f'const lifecycle = @import("{prefix}{module}");\nlifecycle.{method}(arg);\n',
                                           f'@import("{prefix}{module}").{method}(arg);\n'):
                            with self.subTest(module=module, method=method, expression=expression):
                                (root / path).write_text(expression)
                                self.assertEqual(sites(root), {path: 1})
                                (root / path).unlink()

    def test_process_observation_sites_in_new_files_require_mac_paths(self):
        examples = (
            ('src/new.zig', 'const path = "/proc/{d}/stat";'),
            ('tests/integration/new.py', 'from pathlib import Path\nPath(f"/proc/{pid}/stat")\n'),
            ('tests/integration/new.py', 'import subprocess as sp\nsp.check_output(["ps", "-p", str(pid)])\n'),
            ('tests/integration/new.py', 'import fcntl as locks\nlocks.flock(fd, 1)\n'),
            ('tests/integration/new.py', 'from fcntl import flock as lock\nlock(fd, 1)\n'),
        )
        for path, source in examples:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                file = root / path
                file.parent.mkdir(parents=True)
                file.write_text(source)
                self.assertEqual(sites(root), {path: 1})
        self.assertEqual(python_sites('import subprocess\ntext = "ps"\n# /proc/123\n'), 0)
        self.assertEqual(python_sites('import fcntl\nx.flock(fd, 1)\n'), 0)

    def test_upgrade_lifecycle_paths_select_mac(self):
        paths = ["build.zig", "docs/contracts/store.md", "docs/host.md",
                 "src/HostLifecycle.zig", "src/cli.zig", "src/client.zig",
                 "src/host_coordinator.zig", "src/host_restart_all.zig", "src/host_start.zig",
                 "src/serve_grammar.zig", "src/upgrade.zig", "src/upgrade_process.zig",
                 "tests/ci/host_settings_locality.py", "tests/ci/prepush.py",
                 "tests/ci/test_host_settings_locality.py", "tests/ci/test_prepush.py",
                 "tests/ci/test_previous_release_upgrade.py", "tests/ci/test_upgrade_fixture.py",
                 "tests/integration/host_launch_integration.py",
                 "tests/integration/previous_release_upgrade.py", "tests/integration/upgrade_integration.py"]
        self.assertTrue(select(paths, "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["src/cli.zig"], "review", AVAILABLE)["mac_required"])
        for path in ("src/HostLifecycle.zig", "src/host_coordinator.zig",
                     "src/host_restart_all.zig", "src/host_start.zig", "src/host_identity.zig", "src/upgrade.zig",
                     "src/upgrade_process.zig"):
            self.assertTrue(select([path], "review", AVAILABLE)["mac_required"], path)

    def test_python_scan_ignores_comments_strings_and_attributes(self):
        self.assertEqual(python_sites('if sys.platform == "darwin":\n    pass\n'), 1)
        self.assertEqual(python_sites('name = platform.system()\nos.uname()\n'), 2)
        self.assertEqual(python_sites('# sys.platform\ntext = "sys.platform"\nx.sys.platform\n'), 0)

    def test_sigpipe_constants_belong_to_socket_owner(self):
        for source in ('std.c.MSG.NOSIGNAL', 'c.SO.NOSIGPIPE', 'MSG . NOSIGNAL'):
            self.assertEqual(zig_sites(source), 1, source)
        for source in ('// MSG.NOSIGNAL', '"SO.NOSIGPIPE"', 'socket_os.send_flags', 'MSG.OTHER'):
            self.assertEqual(zig_sites(source), 0, source)

    def test_unix_stream_constructors_belong_to_fixture_owner(self):
        self.assertEqual(python_sites('socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)'), 1)
        self.assertEqual(python_sites('# socket.socket(socket.AF_UNIX)\ns = "socket.socket(socket.AF_UNIX)"\n'), 0)
        self.assertEqual(python_sites('os_semantics.unix_stream()\nsocket.socket(socket.AF_INET)'), 0)
        self.assertEqual(shell_sites("python3 - <<'PY'\npeer = socket.socket(socket.AF_UNIX)\nPY\n"), 1)
        self.assertEqual(shell_sites("python3 - <<'PY'\n# socket.socket(socket.AF_UNIX)\ns = 'socket.socket(socket.AF_UNIX)'\nPY\n"), 0)

    def test_unix_stream_limits_unread_linux_send_capacity(self):
        sys.path.insert(0, str(Path(__file__).parents[1] / "integration"))
        import os_semantics
        if not os_semantics.PROC_FS:
            self.skipTest("Linux socket buffer sizing")
        with socket.socket(socket.AF_UNIX) as listener:
            path = f"\0rui-buffer-{os.getpid()}"
            listener.bind(path)
            listener.listen(1)
            with os_semantics.unix_stream() as sender:
                sender.connect(path)
                receiver, _ = listener.accept()
                with receiver:
                    sender.setblocking(False)
                    total = 0
                    while True:
                        try:
                            total += sender.send(b"x" * 65536)
                        except BlockingIOError:
                            break
                    self.assertGreaterEqual(total, 4096)
                    self.assertLessEqual(total, 8192)

    def test_fixture_trust_through_ssl_cert_variables_is_a_platform_site(self):
        self.assertEqual(typescript_sites(
            'writeFileSync(wrapper, `#!/bin/sh\\nexport SSL_CERT_FILE=${quote(cert)}\\nexec rui "$@"\\n`);'), 1)
        self.assertEqual(typescript_sites('// SSL_CERT_FILE is ignored on Darwin\n/* SSL_CERT_DIR */ const a = 1;'), 0)
        self.assertEqual(python_sites('env = {"SSL_CERT_FILE": cert}\n'), 1)
        self.assertEqual(python_sites('script = f"SSL_CERT_DIR={path} rui host serve"\n'), 1)
        self.assertEqual(python_sites('# SSL_CERT_FILE\nenv = os_semantics.system_trust(cert)\n'), 0)

    def test_system_trust_is_linux_only(self):
        sys.path.insert(0, str(Path(__file__).parents[1] / "integration"))
        import os_semantics
        with os_semantics.simulate("linux"):
            self.assertEqual(os_semantics.system_trust(Path("/ca.pem")), {"SSL_CERT_FILE": "/ca.pem"})
        with os_semantics.simulate("darwin"), self.assertRaises(AssertionError):
            os_semantics.system_trust(Path("/ca.pem"))

    def test_file_access_tracer_is_optional_on_linux_and_absent_on_darwin(self):
        sys.path.insert(0, str(Path(__file__).parents[1] / "integration"))
        import os_semantics
        from unittest.mock import patch
        for executable in ("/usr/bin/strace", None):
            with self.subTest(executable=executable), os_semantics.simulate("linux"), \
                    patch.object(os_semantics.shutil, "which", return_value=executable) as which:
                self.assertEqual(os_semantics.file_access_tracer(), executable)
                which.assert_called_once_with("strace")
        with os_semantics.simulate("darwin"), patch.object(os_semantics.shutil, "which") as which:
            self.assertIsNone(os_semantics.file_access_tracer())
            which.assert_not_called()

    def test_a_bound_socket_that_never_listens_is_refused(self):
        unlistened = textwrap.dedent('''
            test "down" {
                const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
                // std.c.listen(fd, 1) would make it a listener.
                if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
            }''')
        self.assertEqual(unlistened_binds(unlistened), ['"down"'])
        listener = textwrap.dedent('''
            fn tcp(port: *u16) !Peer {
                if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.Bind;
                if (std.c.listen(fd, 1) != 0) return error.Listen;
            }
            test "refused" { const port = try socket_fixture.refusedPort(); _ = port; }''')
        self.assertEqual(unlistened_binds(listener), [])
        self.assertEqual(bind_sites(), {})

    def test_sites_outside_mac_paths_are_violations(self):
        self.assertEqual(violations({}), [])
        self.assertIn("src/a.zig: 2 platform sites outside Mac paths", violations({"src/a.zig": 2})[0])

    def test_mac_specific_paths(self):
        for path in ("src/client.zig", "src/os/socket.zig", "tests/integration/os_semantics.py", "src/host_launch.c",
                     "src/build_transport.sh", "tests/integration/session_list_release_probe.c",
                     ".github/workflows/qualify-macos.yml", "install.sh", "build/darwin.zig", "tests/ci/build_artifact.py",
                     "src/os/process.zig", "src/os/descriptor_limit.zig", "src/os/Waker.zig",
                     "tests/integration/terminal_process.py",
                     "tests/integration/terminal_leader.py", "tests/integration/terminal_restoration_cases.py"):
            self.assertTrue(mac_path(path), path)
        for path in ("src/session_view.zig", "src/server.zig", "src/h2/Connection.zig", "src/h2/testing/Peer.zig",
                     "tests/integration/dispatch_integration.py",
                     "tests/integration/upgrade_integration.py", "tests/integration/host_launch_integration.py",
                     "tests/integration/terminal_process_test.py",
                     ".github/workflows/check.yml", "README.md",
                     "build.zig", "build.zig.zon", ".github/actions/setup/action.yml", "tests/ci/qualification.py"):
            self.assertFalse(mac_path(path), path)

    def test_selection_requires_mac_for_review_of_mac_specific_paths(self):
        self.assertTrue(select(["src/os/socket.zig"], "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["README.md", "src/host_launch.c"], "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["tests/integration/terminal_restoration_cases.py"], "review", AVAILABLE)["mac_required"])
        self.assertFalse(select(["src/turn_policy.zig"], "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["tests/integration/terminal_leader.py"], "review", AVAILABLE)["mac_required"])
        self.assertFalse(select(["src/os/socket.zig"], "development", AVAILABLE)["mac_required"])

    def test_ci_producer_darwin_policy_requires_native_in_promotion_not_on_prs(self):
        from ci_plan import plan
        from docs_only import ChangeKind

        selected = select(["tests/ci/build_artifact.py"], "review", AVAILABLE)
        self.assertTrue(selected["mac_required"])
        self.assertTrue({"check-full", "admission-debug-integration", "test-full"}
                        <= set(selected["native_targets"]))
        ready = plan(selected, event_name="pull_request", draft=False,
                     promotion=False, change_kind=ChangeKind.NORMAL).outputs
        self.assertFalse(ready["native"], "the PR tier runs no macOS")
        self.assertEqual(ready["change_kind"], "normal")
        promoted = plan(selected, event_name="workflow_dispatch", draft=False,
                        promotion=True, change_kind=ChangeKind.NORMAL).outputs
        self.assertTrue(promoted["native"])
        self.assertIn("check-full", promoted["native_targets"])
        draft = plan(selected, event_name="pull_request", draft=True,
                     promotion=False, change_kind=ChangeKind.NORMAL).outputs
        self.assertFalse(draft["native"])
        self.assertEqual(draft["native_targets"], [])
        self.assertFalse(select(["tests/ci/build_artifact.py"], "development", AVAILABLE)["mac_required"])

    def test_client_process_observation_keeps_native_mac_upgrade_in_promotion(self):
        from ci_plan import plan
        from docs_only import ChangeKind
        selection = select(["src/client.zig"], "review", AVAILABLE)
        self.assertTrue(selection["mac_required"])
        ready = plan(selection, event_name="pull_request", draft=False,
                     promotion=False, change_kind=ChangeKind.NORMAL)
        self.assertFalse(ready.outputs["native"])
        promoted = plan(selection, event_name="workflow_dispatch", draft=False,
                        promotion=True, change_kind=ChangeKind.NORMAL)
        self.assertTrue(promoted.outputs["native"])
        self.assertIn("upgrade-integration", promoted.outputs["native_targets"])

    def test_linux_gate_requires_the_macos_type_check(self):
        self.assertIn("typecheck-macos", AVAILABLE)
        workflow = (Path(__file__).parents[2] / ".github/workflows/check.yml").read_text()
        job = re.search(r"(?ms)^  macos_typecheck:\n(.*?)(?=^  [a-z_]+:|\Z)", workflow)[1]
        self.assertIn("runs-on: ubuntu-", job)
        self.assertIn("zig build typecheck-macos", job)
        gate = re.search(r"(?ms)^  linux:\n(.*?)(?=^  [a-z_]+:|\Z)", workflow)[1]
        needs = re.search(r"(?m)^    needs: \[(.*?)\]$", gate)[1]
        self.assertIn("macos_typecheck", [name.strip() for name in needs.split(",")])
        self.assertIn('test "$TYPECHECK_RESULT" = success', gate)


if __name__ == "__main__":
    unittest.main()
