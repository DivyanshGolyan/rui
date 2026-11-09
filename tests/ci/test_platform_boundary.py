from contextlib import contextmanager
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
from platform_boundary import (bind_sites, mac_path, python_sites, sites, typescript_sites,  # noqa: E402
                               unlistened_binds, violations, zig_sites)
from select_tests import select  # noqa: E402
from qualification import split_build  # noqa: E402


AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (Path(__file__).parents[2] / "build.zig").read_text()))


@contextmanager
def committed_selection(path):
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)

        def git(*args):
            return subprocess.check_output(["git", *args], cwd=root, text=True, stderr=subprocess.PIPE).strip()

        def commit():
            git("-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture")
            return git("rev-parse", "HEAD")

        git("init", "-q")
        base = commit()
        changed = root / path
        changed.parent.mkdir(parents=True, exist_ok=True)
        changed.write_text("Changed fixture.\n")
        git("add", "--", path)
        head = commit()
        paths = git("diff", "--name-only", base, head, "--").splitlines()
        selection = select(paths, "review", AVAILABLE)
        selection.update(base=base, head=head)
        (root / "tests").symlink_to((Path(__file__).parents[1]).resolve(), target_is_directory=True)
        yield root, selection


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

    def test_fixture_trust_through_ssl_cert_variables_is_a_platform_site(self):
        # The feed-host test before #997 trusted its CA this way and failed only on Darwin.
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

    def test_a_bound_socket_that_never_listens_is_refused(self):
        # server_mcp_tests.zig before #1002: Darwin dropped its SYNs instead of refusing.
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
        self.assertIn("src/a.zig: 2 platform sites outside src/os/", violations({"src/a.zig": 2})[0])

    def test_mac_specific_paths(self):
        for path in ("src/os/socket.zig", "tests/integration/os_semantics.py", "src/host_launch.c",
                     "src/build_transport.sh", "tests/integration/session_list_release_probe.c",
                     "build.zig", "build.zig.zon",
                     ".github/actions/setup/action.yml",
                     ".github/workflows/qualify-macos.yml", "tests/ci/qualification.py", "install.sh",
                     "src/os/process.zig", "src/os/descriptor_limit.zig", "src/h2/Connection.zig",
                     "src/h2/testing/Peer.zig", "tests/integration/terminal_process.py",
                     "tests/integration/terminal_leader.py"):
            self.assertTrue(mac_path(path), path)
        for path in ("src/session_view.zig", "src/server.zig", "tests/integration/dispatch_integration.py",
                     ".github/workflows/check.yml", "README.md"):
            self.assertFalse(mac_path(path), path)

    def test_selection_requires_mac_for_review_of_mac_specific_paths(self):
        self.assertTrue(select(["src/os/socket.zig"], "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["README.md", "src/host_launch.c"], "review", AVAILABLE)["mac_required"])
        self.assertFalse(select(["src/turn_policy.zig"], "review", AVAILABLE)["mac_required"])
        self.assertTrue(select(["tests/integration/terminal_leader.py"], "review", AVAILABLE)["mac_required"])
        # Drafts get development feedback only.
        self.assertFalse(select(["src/os/socket.zig"], "development", AVAILABLE)["mac_required"])

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

    def test_executed_plan_runs_mac_on_every_normal_ready_pr_and_retains_platform_mapping(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/check.yml").read_text()
        script = textwrap.dedent(re.search(r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY$", workflow)[1])
        # Ready PRs run Mac only for Mac paths; promotion runs it for every batch.
        cases = (("src/turn_policy.zig", "pull_request", False), ("src/os/socket.zig", "push", False),
                 ("src/os/socket.zig", "pull_request", True), (".github/workflows/qualify-macos.yml", "pull_request", True),
                 ("README.md", "pull_request", False), ("README.md", "workflow_dispatch", False))
        for path, event, mac in cases:
            with self.subTest(path=path, event=event):
                with committed_selection(path) as (root, selection):
                    (root / "selection.json").write_text(json.dumps(selection))
                    (root / "output").write_text("")
                    subprocess.run([sys.executable, "-B", "-c", script], cwd=root, check=True,
                                   env=dict(os.environ, PROMOTION="false", EVENT_NAME=event, GITHUB_REF_NAME="branch",
                                            CANDIDATE_REF=selection["head"],
                                            GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary")))
                    outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                    kind = "documentation" if path == "README.md" and event == "pull_request" else "normal"
                    self.assertEqual(outputs["change_kind"], kind)
                    native = json.loads(outputs["native_targets"])
                    self.assertEqual(outputs["native"], str(mac).lower())
                    self.assertEqual(outputs["macos_split"], str(split_build(native)).lower())
                    self.assertEqual(outputs["linux_split"], str(split_build(selection["targets"])).lower())
                    if mac:
                        self.assertEqual(native, selection["native_targets"] or ["check"])
                        self.assertTrue(json.loads(outputs["macos_matrix"])["include"])
                    else:
                        self.assertEqual(native, [])

    def test_executed_plan_splits_the_final_native_selection(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/check.yml").read_text()
        script = textwrap.dedent(re.search(r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY$", workflow)[1])
        for native, mac_required, expected, split in (
                ([], True, ["check"], True),
                (["test"], True, ["test"], False),
                (["check-full"], True, ["check-full"], True),
                (["test-logic"], True, ["test-logic"], False),
                (["check"], False, [], False)):
            with self.subTest(native=native, mac_required=mac_required):
                with committed_selection(".github/workflows/check.yml") as (root, selection):
                    selection.update(native_targets=native, mac_required=mac_required)
                    (root / "selection.json").write_text(json.dumps(selection))
                    (root / "output").write_text("")
                    subprocess.run([sys.executable, "-B", "-c", script], cwd=root, check=True,
                                   env=dict(os.environ, EVENT_NAME="pull_request", PROMOTION="false",
                                            GITHUB_REF_NAME="main", CANDIDATE_REF=selection["head"],
                                            GITHUB_OUTPUT=str(root / "output"),
                                            GITHUB_STEP_SUMMARY=str(root / "summary")))
                    outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                    self.assertEqual(outputs["change_kind"], "normal")
                    self.assertEqual(outputs["macos_split"], str(split).lower())
                    self.assertEqual(outputs["linux_split"], "false")
                    self.assertEqual(json.loads(outputs["native_targets"]), expected)
                    self.assertEqual(outputs["retry"], "false")



if __name__ == "__main__":
    unittest.main()
