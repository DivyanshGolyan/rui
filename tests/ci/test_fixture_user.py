"""The fixture user's names, environment and reuse, without creating a user."""
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import fixture_user
from fixture_user import TRUST, VENV


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
        interpreter = Path("/opt/python/bin/python3.12")

        def run(argv):
            ran.append(argv[1:3])
            if argv[1:3] == ["-m", "venv"]:
                self.assertEqual(argv[0], str(interpreter), "the environment comes from the chosen interpreter")
                (venv / "bin").mkdir(parents=True)
                (venv / "bin/python").touch()

        def ensure():
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

    def interpreter(self, directory, *, builds_venv=True, mode=0o755):
        """A python3.12 in `directory` (made with `mode`) that can or cannot import venv."""
        directory.mkdir(parents=True, exist_ok=True)
        os.chmod(directory, mode)
        python = directory / fixture_user.PYTHON
        python.write_text(f"#!/bin/sh\nexit {0 if builds_venv else 1}\n")
        python.chmod(0o755)
        return python

    def test_a_lane_builds_its_environment_only_from_an_interpreter_its_user_can_run(self):
        os.chmod(self.root, 0o755)
        private = self.interpreter(self.root / "private/.pyenv/bin", mode=0o755)
        os.chmod(self.root / "private", 0o700)
        public = self.interpreter(self.root / "public/bin")
        system = self.interpreter(self.root / "system/bin")
        linked = self.root / "links"
        linked.mkdir()
        (linked / fixture_user.PYTHON).symlink_to(private)
        broken = self.interpreter(self.root / "broken/bin", builds_venv=False)
        cases = {
            # (caller's PATH, system fallback): the interpreter the lane uses, or None to refuse.
            "public": ((public.parent,), (), public),
            "public before the system one": ((public.parent,), (system.parent,), public),
            "root-private only": ((private.parent,), (), None),
            "root-private with a system fallback": ((private.parent,), (system.parent,), system),
            "public link into root's home": ((linked,), (), None),
            "public link with a system fallback": ((linked,), (system.parent,), system),
            "public but without venv": ((broken.parent,), (system.parent,), system),
        }
        for name, (caller, fallback, expected) in cases.items():
            with self.subTest(name):
                caller_path = os.pathsep.join(map(str, caller))
                system_path = os.pathsep.join(map(str, fallback))
                if expected is None:
                    with self.assertRaises(SystemExit) as refusal:
                        fixture_user.fixture_python(caller_path, system_path)
                    self.assertIn(".agents/setup installs one", str(refusal.exception.code))
                else:
                    self.assertEqual(fixture_user.fixture_python(caller_path, system_path), expected.resolve())
        self.assertEqual(fixture_user.usable_python(str(private.parent), public=False), private.resolve(),
                         "the caller's own environment may use its private interpreter")

    def test_setup_installs_a_shared_interpreter_when_roots_is_private(self):
        os.chmod(self.root, 0o755)
        private = self.interpreter(self.root / "private/bin")
        os.chmod(self.root / "private", 0o700)
        public = self.interpreter(self.root / "public/bin")
        for euid, search, fallback, status in ((0, private.parent, "", 1), (0, private.parent, public.parent, 0),
                                               (1000, private.parent, "", 0)):
            with self.subTest(euid=euid, fallback=str(fallback)), \
                    patch.dict(os.environ, PATH=str(search)), patch.object(fixture_user, "BASE_PATH", str(fallback)), \
                    patch.object(fixture_user.os, "geteuid", return_value=euid), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(fixture_user.main(["--python"]), status)

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
