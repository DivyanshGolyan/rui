"""The fixture user's names, provisioning, environment and reuse, without creating a user."""
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fixture_user
from fixture_user import Install, TRUST, VENV


def lane_reads(path, gid):
    """Whether a user who owns nothing here and whose only group is `gid` can read `path`.

    Independent of fixture_user: every directory down to it must be searchable,
    and it readable, through its group bits when its group is `gid` and through
    its other bits otherwise.
    """
    def allowed(part, bits):
        status = os.stat(part)
        return status.st_mode & (bits << 3 if status.st_gid == gid else bits) == (bits << 3 if status.st_gid == gid
                                                                                   else bits)

    path = Path(path)
    return all(allowed(part, 0o1) for part in path.parents) and allowed(path, 0o5 if path.is_dir() else 0o4)


class FixtureUserTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def test_each_lane_gets_its_own_user_and_malformed_lanes_are_refused(self):
        self.assertEqual(fixture_user.user_for("pr4"), "rui-pr4")
        self.assertNotEqual(fixture_user.user_for("a"), fixture_user.user_for("a-1"))
        self.assertEqual(fixture_user.user_for("x" * 28), "rui-" + "x" * 28)
        for lane in ("", "A", "a_b", "-a", "a/b", "../a", "a b", "x" * 29):
            with self.subTest(lane=lane), self.assertRaises(SystemExit):
                fixture_user.user_for(lane)

    def test_the_run_sees_only_its_own_variables_with_trust_pointed_at_the_copy(self):
        caller = {
            "SSL_CERT_FILE": "/root/.ccr/ca-bundle.crt", "GIT_SSL_CAINFO": "/root/.ccr/ca-bundle.crt",
            "HTTPS_PROXY": "http://127.0.0.1:1", "NO_PROXY": "localhost", "LANG": "C.UTF-8", "TERM": "xterm",
            "HOME": "/root", "PATH": "/root/.local/bin:/usr/bin", "GH_TOKEN": "secret", "RUI_TEST_X": "1",
            "ZIG_GLOBAL_CACHE_DIR": "/root/.cache/zig",
        }
        home, bundle = Path("/home/rui-a"), Path("/home/rui-a/ca.crt")
        expected = {
            "HOME": "/home/rui-a", "USER": "rui-a", "LOGNAME": "rui-a", "SHELL": "/bin/bash", "PATH": "/p",
            "ZIG_GLOBAL_CACHE_DIR": "/home/rui-a/.cache/zig", "HTTPS_PROXY": "http://127.0.0.1:1",
            "NO_PROXY": "localhost", "LANG": "C.UTF-8", "TERM": "xterm", **dict.fromkeys(TRUST, str(bundle)),
        }
        self.assertEqual(fixture_user.environment("rui-a", home, "/p", bundle, caller), expected)
        self.assertEqual(fixture_user.environment("rui-a", home, "/p", bundle, caller, ("RUI_TEST_X",)),
                         {**expected, "RUI_TEST_X": "1"})
        without = fixture_user.environment("rui-a", home, "/p", None, caller)
        self.assertFalse(set(TRUST) & set(without), "no copy leaves trust to the system store, never /root")
        for name in ("HOME", "PATH", "SSL_CERT_FILE"):
            with self.subTest(keep=name), self.assertRaises(SystemExit):
                fixture_user.environment("rui-a", home, "/p", bundle, caller, (name,))

    def test_path_starts_with_the_environment_and_keeps_only_directories_others_can_search(self):
        closed, open_ = self.root / "closed", self.root / "open"
        (closed / "bin").mkdir(parents=True)
        open_.mkdir()
        os.chmod(self.root, 0o755)
        os.chmod(closed, 0o700)
        os.chmod(open_, 0o755)
        self.assertFalse(fixture_user.reachable(closed / "bin"))
        self.assertTrue(fixture_user.reachable(open_))
        self.assertFalse(fixture_user.reachable(Path("relative")))
        self.assertEqual(fixture_user.search_path(Path("/venv/bin"), [Path("/tools/zig")],
                                                  f"{closed / 'bin'}:{open_}::{open_}"),
                         f"/venv/bin:/tools/zig:{open_}")

    def test_the_bundle_comes_from_the_first_trust_variable_that_names_a_file(self):
        bundle = self.root / "ca.crt"
        bundle.write_text("certificate")
        self.assertEqual(fixture_user.source_bundle({"SSL_CERT_FILE": str(self.root / "missing"),
                                                     "CURL_CA_BUNDLE": str(bundle)}), bundle)
        self.assertIsNone(fixture_user.source_bundle({"PATH": "/usr/bin"}))

    def test_an_environment_is_built_once_and_reinstalls_only_changed_pins(self):
        venv = self.root / "venv"
        requirements = [self.root / "ci.txt", self.root / "integration.txt"]
        requirements[0].write_text("ruff==1\n")
        requirements[1].write_text("h2==1\n")
        ran = []

        def run(argv):
            ran.append(argv[1:3])
            if argv[1:3] == ["-m", "venv"]:
                self.assertEqual(argv[3:], ["--clear", str(venv)])
                (venv / "bin").mkdir(parents=True, exist_ok=True)
                (venv / "bin/python").touch()
                (venv / "pyvenv.cfg").write_text(f"home = {Path(argv[0]).parent}\nversion = 3.12.3\n")

        def ensure(interpreter=Path("/opt/python/bin/python3.12")):
            ran.clear()
            return fixture_user.ensure_venv(venv, interpreter, requirements, run,
                                            lambda path, text: path.write_text(text))

        self.assertTrue(ensure())
        self.assertEqual(ran, [["-m", "venv"], ["-m", "pip"]])
        self.assertFalse(ensure(), "unchanged pins reuse the environment")
        self.assertEqual(ran, [])
        requirements[1].write_text("h2==2\n")
        self.assertTrue(ensure())
        self.assertEqual(ran, [["-m", "pip"]], "changed pins keep the interpreter")
        self.assertFalse(ensure())
        self.assertTrue(ensure(Path("/var/lib/rui-fixture/tools/python-1/bin/python3.12")))
        self.assertEqual(ran, [["-m", "venv"], ["-m", "pip"]], "another interpreter rebuilds the environment")
        self.assertEqual(fixture_user.venv_home(venv), Path("/var/lib/rui-fixture/tools/python-1/bin"))

    def interpreter(self, directory, *, builds_venv=True, mode=0o755, reports=None):
        """A python3.12 in `directory` (made with `mode`) that can or cannot import venv.

        It reports running `reports`, or itself, as a shim reports the interpreter it runs.
        """
        directory.mkdir(parents=True, exist_ok=True)
        os.chmod(directory, mode)
        python = directory / fixture_user.PYTHON
        report = f"'{reports}'" if reports else '"$0"'
        python.write_text(f"#!/bin/sh\necho {report}\n" if builds_venv else "#!/bin/sh\nexit 1\n")
        python.chmod(0o755)
        return python

    def test_the_interpreter_is_the_installation_python_reports_running(self):
        os.chmod(self.root, 0o755)
        public = self.interpreter(self.root / "public/bin")
        private = self.interpreter(self.root / "private/.pyenv/versions/3.12/bin")
        os.chmod(self.root / "private", 0o700)
        shim = self.interpreter(self.root / "private/.pyenv/shims", reports=private)
        broken = self.interpreter(self.root / "broken/bin", builds_venv=False)
        cases = {
            # The search path: the installation the lane's environment comes from, or None.
            "public": ((public.parent,), Install(public.resolve(), public.resolve().parents[1])),
            "root-private": ((private.parent,), Install(private.resolve(), private.resolve().parents[1])),
            "a shim names what it runs": ((shim.parent,), Install(private.resolve(), private.resolve().parents[1])),
            "one without venv is passed over": ((broken.parent, public.parent),
                                                Install(public.resolve(), public.resolve().parents[1])),
            "none": ((broken.parent,), None),
        }
        for name, (search, expected) in cases.items():
            with self.subTest(name):
                self.assertEqual(fixture_user.find_python(os.pathsep.join(map(str, search))), expected)
        for search, status in ((private.parent, 0), (broken.parent, 1)):
            with self.subTest(python=str(search)), patch.dict(os.environ, PATH=str(search)), \
                    patch.object(fixture_user, "BASE_PATH", ""), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(fixture_user.main(["--python"]), status)

    def test_a_lane_reads_only_what_root_placed_wherever_root_keeps_its_inputs(self):
        """Provisioning over each input at a public and a private path, a linked worktree's common dir among them."""
        os.chmod(self.root, 0o755)
        if not fixture_user.reachable(self.root):
            self.skipTest(f"{self.root}'s parents are closed to other users, so nothing under it is public")
        public, private = self.root / "public", self.root / "private"
        public.mkdir()
        private.mkdir()
        os.chmod(public, 0o755)
        os.chmod(private, 0o700)
        origin = private / "origin"
        self.git("init", "--quiet", str(origin))
        self.commit(origin, "release")
        self.git("-C", str(origin), "tag", "v1.0")
        release = self.git("-C", str(origin), "rev-parse", "v1.0")

        def checkout(path):
            """A repository whose origin/main and v0.9 are its first commit."""
            self.git("init", "--quiet", str(path))
            first = self.commit(path, "one")
            self.git("-C", str(path), "update-ref", "refs/remotes/origin/main", first)
            self.git("-C", str(path), "tag", "v0.9")
            return first

        firsts = {"public checkout": checkout(public / "checkout"), "private checkout": checkout(private / "checkout"),
                  "linked worktree": checkout(private / "repository")}
        self.git("-C", str(private / "repository"), "worktree", "add", "--quiet", "--detach",
                 str(public / "linked"), "HEAD")

        def install(parent, tool, binary, data):
            """A toolchain whose binary prints itself, then, with no arguments, a file from its installation.

            Python's probe passes arguments and reads only the binary, as from sys.executable.
            """
            program = parent / tool / binary
            program.parent.mkdir(parents=True)
            (parent / tool / data).parent.mkdir(parents=True, exist_ok=True)
            (parent / tool / data).write_text(f"{tool} data\n")
            up = "/.." * (len(Path(binary).parts) - 1)
            program.write_text(f'#!/bin/sh\necho "$0"\n[ $# -eq 0 ] || exit 0\ncat "$(dirname "$0"){up}/{data}"\n')
            program.chmod(0o755)
            return program

        tools = {parent: {fixture_user.PYTHON: install(parent / "tools", fixture_user.PYTHON, "bin/python3.12",
                                                       "lib/python3.12/os.py"),
                          "zig": install(parent / "tools", "zig", "zig", "lib/std/std.zig"),
                          "go": install(parent / "tools", "go", "bin/go", "src/runtime/runtime.go")}
                 for parent in (public, private)}
        for parent in (public, private):
            (parent / "ca.crt").write_text(f"{parent.name} certificate\n")
        cases = {
            # The checkout root reads, and the directory that holds its CA bundle and installs.
            "public checkout": (public / "checkout", public),
            "private checkout": (private / "checkout", private),
            "linked worktree": (public / "linked", private),
        }
        tools_dir = self.root / "placed/tools"
        gid = os.getgid()

        def provision(source, inputs_at, lane_dir):
            caller_path = os.pathsep.join(str(program.parent) for program in tools[inputs_at].values())
            inputs = fixture_user.read_inputs("HEAD", caller_path, {"SSL_CERT_FILE": str(inputs_at / "ca.crt")},
                                              root=source)
            with redirect_stderr(io.StringIO()):
                return inputs, fixture_user.place(inputs._replace(origin=str(origin)), lane_dir, tools_dir, gid)

        for index, (name, (source, inputs_at)) in enumerate(cases.items()):
            with self.subTest(name):
                lane_dir = self.root / "placed/lanes" / f"lane{index}"
                head = self.commit(source, f"work {index}")
                inputs, placed = provision(source, inputs_at, lane_dir)

                # Every path the lane reads, and everything under it, is readable through other or the lane's group.
                for path in (placed.source, placed.bundle, *placed.binaries.values()):
                    self.assertFalse(path.is_relative_to(private), f"the lane reads {path}, inside root's own state")
                    for item in (path, *(path.rglob("*") if path.is_dir() else ())):
                        self.assertTrue(lane_reads(item, gid), f"the lane cannot read {item}")
                self.assertEqual(placed.bundle.read_text(), f"{inputs_at.name} certificate\n")
                self.assertEqual(set(placed.binaries), set(tools[inputs_at]))
                for tool, program in tools[inputs_at].items():
                    binary = placed.binaries[tool]
                    if inputs_at == public:
                        self.assertEqual(binary, program, "an install every user reaches is used in place")
                    else:
                        self.assertTrue(binary.is_relative_to(tools_dir), f"{tool} is copied for lanes")
                    output = subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout
                    self.assertEqual(output.splitlines(), [str(binary), f"{tool} data"],
                                     "the binary runs with its whole installation")

                # The export holds REF, origin/main and both release tags, and no path back to the source.
                refs = self.git("--git-dir", str(placed.source), "for-each-ref", "--format=%(refname) %(objectname)")
                self.assertEqual(dict(line.split() for line in refs.splitlines()),
                                 {"refs/heads/fixture": head, "refs/remotes/origin/main": firsts[name],
                                  "refs/tags/v0.9": firsts[name], "refs/tags/v1.0": release})
                self.assertFalse((placed.source / "objects/info/alternates").exists())
                lane = self.root / f"lane-checkout-{index}"
                self.git("init", "--quiet", str(lane))
                subprocess.run(fixture_user.local_fetch(["git", "-C", str(lane)], placed.source, "+refs/*:refs/*"),
                               check=True)
                self.git("-C", str(lane), "checkout", "--quiet", "--detach", inputs.sha)
                self.assertEqual((lane / "work.txt").read_text(), f"work {index}\n")

                # Reuse: a new commit arrives in the same export, and no install is copied again.
                copies = sorted(tools_dir.iterdir())
                later = self.commit(source, f"more {index}")
                self.assertEqual(provision(source, inputs_at, lane_dir)[1], placed)
                self.assertEqual(sorted(tools_dir.iterdir()), copies)
                self.assertEqual(self.git("--git-dir", str(placed.source), "rev-parse", "refs/heads/fixture"), later)

    def git(self, *args):
        """Run git with a fixed identity and return its output, stripped."""
        return subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                               "-c", "init.defaultBranch=main", *args],
                              capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, checkout, text):
        """Commit `text` as work.txt in `checkout`; its commit."""
        (checkout / "work.txt").write_text(text + "\n")
        self.git("-C", str(checkout), "add", "work.txt")
        self.git("-C", str(checkout), "commit", "--quiet", "-m", text)
        return self.git("-C", str(checkout), "rev-parse", "HEAD")

    def test_prepush_reexecutes_only_outside_an_existing_environment(self):
        python = self.root / VENV / "bin/python"
        with patch.dict(os.environ, HOME=str(self.root)), patch.object(fixture_user.os, "execv") as execv:
            fixture_user.reexec_pinned(["tests/ci/prepush.py", "--quick"])
            execv.assert_not_called()
            python.parent.mkdir(parents=True)
            python.touch()
            with patch.object(fixture_user.sys, "prefix", "/usr"), redirect_stderr(io.StringIO()) as warning:
                fixture_user.reexec_pinned(["tests/ci/prepush.py", "--quick"])
            execv.assert_called_once_with(python, [str(python), "tests/ci/prepush.py", "--quick"])
            self.assertIn("does not match this checkout's requirements", warning.getvalue())
            stamp = fixture_user.requirement_stamp([(fixture_user.ROOT / path).read_text()
                                                    for path in fixture_user.REQUIREMENTS])
            (self.root / VENV / fixture_user.STAMP).write_text(stamp + "\n")
            execv.reset_mock()
            with patch.object(fixture_user.sys, "prefix", "/usr"), redirect_stderr(io.StringIO()) as warning:
                fixture_user.reexec_pinned(["tests/ci/prepush.py"])
            execv.assert_called_once_with(python, [str(python), "tests/ci/prepush.py"])
            self.assertEqual(warning.getvalue(), "")
            execv.reset_mock()
            with patch.object(fixture_user.sys, "prefix", str(self.root / VENV)):
                fixture_user.reexec_pinned(["tests/ci/prepush.py"])
            execv.assert_not_called()

    def test_arguments_name_one_action_and_everything_after_the_separator_is_the_command(self):
        self.assertEqual(fixture_user.parse(["a", "--ref", "main", "--keep", "RUI_X", "--", "python3", "--ref"]),
                         ("run", "a", "main", ("RUI_X",), ["python3", "--ref"]))
        self.assertEqual(fixture_user.parse(["a", "--", "true"]), ("run", "a", "HEAD", (), ["true"]))
        self.assertEqual(fixture_user.parse(["--remove", "a"])[:2], ("remove", "a"))
        self.assertEqual(fixture_user.parse(["--venv"])[0], "venv")
        self.assertEqual(fixture_user.parse(["--python"])[0], "python")
        for argv in (["a"], ["a", "--"], ["--", "true"], ["a", "b", "--", "true"], ["A", "--", "true"],
                     ["a", "--ref"], ["--remove"]):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                fixture_user.parse(argv)


if __name__ == "__main__":
    sys.exit(unittest.main())
