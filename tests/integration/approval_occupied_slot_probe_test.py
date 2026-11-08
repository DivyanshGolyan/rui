"""Owner/classifier controls only; these never execute the native witness."""

import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import approval_occupied_slot_probe as probe


def diagnostics(root, registered_socket, key="12345678-1234-1234-1234-123456789abc"):
    return (
        f"OCCUPIED-SETUP store={root} socket={registered_socket}\n"
        f"OCCUPIED-MESSAGE key={key} bytes=19 wire=exact response=withheld\n"
        f"OCCUPIED-ARMED session=k7m2qx action=10 choice=allow_once scope=7 frame=9 key={key} task_live=true\n"
        "thread 10 panic: reached unreachable code\n"
        "src/SessionSubmission.zig:102:21: 0x1234 in begin (test)\n"
        "    std.debug.assert(self.intent == null and self.task.thread == null);\n"
    )


class OccupiedProbeTest(unittest.TestCase):
    def test_only_exact_armed_begin_assertion_is_classified(self):
        root = pathlib.Path("/private/tmp/owned")
        registered_socket = probe.socket_path(root)
        good = diagnostics(root, registered_socket)
        self.assertTrue(probe.classify(-signal.SIGABRT, good, root, registered_socket)["red_control_observed"])
        wrong = [
            good.replace("OCCUPIED-ARMED", "NOT-ARMED"),
            good.replace("SessionSubmission.zig", "SessionScreen.zig"),
            good.replace("in begin", "in other"),
            good.replace("self.intent == null", "self.intent != null"),
            good.replace("response=withheld", "response=accepted"),
            good.replace("scope=7 frame=9", "scope=7 frame=0"),
            good + "OCCUPIED-RETURNED consent=false original=true\n",
            good.replace("OCCUPIED-SETUP", "NO-SETUP"),
        ]
        for text in wrong:
            with self.subTest(text=text):
                self.assertFalse(probe.classify(-signal.SIGABRT, text, root, registered_socket)["red_control_observed"])
        for code in (0, 1, -signal.SIGSEGV, -signal.SIGKILL):
            with self.subTest(code=code):
                self.assertFalse(probe.classify(code, good, root, registered_socket)["red_control_observed"])

    def test_message_and_armed_identity_must_match(self):
        root = pathlib.Path("/tmp/owned")
        registered_socket = probe.socket_path(root)
        text = diagnostics(root, registered_socket)
        armed = text.index("OCCUPIED-ARMED")
        text = text[:armed] + text[armed:].replace("12345678", "87654321")
        self.assertFalse(probe.classify(-signal.SIGABRT, text, root, registered_socket)["red_control_observed"])

    def test_pre_registered_manifest_precedes_launch_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            binary = parent / "not-executed"
            binary.write_bytes(b"classifier-control-only")
            evidence = parent / "evidence"

            class FakeProcess:
                returncode = None

                def __init__(self, argv, **options):
                    manifest = json.loads((evidence / "manifest.json").read_text())
                    self.root = pathlib.Path(options["env"]["RUI_APPROVAL_OCCUPIED_ROOT"])
                    self.socket = pathlib.Path(options["env"]["RUI_APPROVAL_OCCUPIED_SOCKET"])
                    assert manifest["root"] == str(self.root)
                    assert manifest["socket"] == str(self.socket)
                    assert options["cwd"] == self.root
                    assert options["start_new_session"] is True
                    assert options["umask"] == 0o077
                    assert self.root.stat().st_mode & 0o777 == 0o700
                    options["stderr"].write(diagnostics(self.root, self.socket).encode())
                    options["stderr"].flush()

                def wait(self, timeout):
                    self.returncode = -signal.SIGABRT
                    return self.returncode

            with mock.patch.object(probe.subprocess, "Popen", FakeProcess):
                result = probe.run(binary, evidence, 1)
            self.assertTrue(result["red_control_observed"])
            self.assertEqual(result["cleanup"], "complete")
            self.assertFalse(pathlib.Path(result["owned_paths"]["root"]).exists())
            self.assertFalse(pathlib.Path(result["owned_paths"]["socket"]).exists())

    def test_cleanup_removes_only_owned_socket_and_root(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "owned"
            root.mkdir(mode=0o700)
            registered_socket = parent / "registered.sock"
            other = parent / "untouched"
            other.write_text("keep")
            with socket.socket(socket.AF_UNIX) as peer:
                peer.bind(str(registered_socket))
            probe.cleanup(None, root, registered_socket)
            self.assertFalse(root.exists())
            self.assertFalse(registered_socket.exists())
            self.assertEqual(other.read_text(), "keep")

    def test_live_owned_process_group_is_killed_and_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "owned"
            root.mkdir(mode=0o700)
            registered_socket = parent / "absent.sock"
            process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                probe.cleanup(process, root, registered_socket)
                self.assertEqual(process.returncode, -signal.SIGKILL)
                self.assertFalse(root.exists())
                with self.assertRaises(ProcessLookupError):
                    os.kill(process.pid, 0)
            finally:
                if process.returncode is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=2)

    def test_cleanup_refuses_an_unexpected_node(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "owned"
            root.mkdir()
            registered_socket = parent / "not-a-socket"
            registered_socket.write_text("do not unlink")
            with self.assertRaisesRegex(RuntimeError, "refuse unexpected node"):
                probe.cleanup(None, root, registered_socket)
            self.assertEqual(registered_socket.read_text(), "do not unlink")
            self.assertTrue(root.exists())


if __name__ == "__main__":
    unittest.main()
