"""Owner/classifier controls only; these never execute the native witness."""

import json
import os
import pathlib
import signal
import select
import socket
import subprocess
import struct
import sys
import tempfile
import unittest
import time
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


def metadata(names):
    strings = bytearray(b"\0")
    offsets = []
    for name in names:
        offsets.append(len(strings))
        strings.extend(name.encode() + b"\0")
    return (struct.pack("<II", len(strings), len(names)) +
            b"".join(struct.pack("<I", offset) for offset in offsets) +
            bytes(4 * len(names)) + bytes(strings))


def server_stub(parent, names, descendant=False):
    binary = parent / "test-server-stub"
    binary.write_text(f"#!{sys.executable}\n" + r'''import os, struct, sys
assert sys.argv[1:] == ["--listen=-"]
def send(tag, body=b""):
    sys.stdout.buffer.write(struct.pack("<II", tag, len(body)) + body)
    sys.stdout.buffer.flush()
def receive():
    header = sys.stdin.buffer.read(8)
    if not header:
        raise SystemExit(0)
    tag, size = struct.unpack("<II", header)
    return tag, sys.stdin.buffer.read(size)
send(0, b"0.17.0")
assert receive() == (4, b"")
''' + f"send(3, {metadata(names)!r})\n" + r'''tag, body = receive()
assert tag == 5 and len(body) == 4
index, = struct.unpack("<I", body)
print(f"STUB-SELECTED {index}", file=sys.stderr, flush=True)
send(5)
send(4)
assert receive() == (0, b"")
''' + ("import subprocess\nsubprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n" if descendant else ""))
    binary.chmod(0o700)
    return binary


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

    def test_metadata_selects_only_exact_test_in_unfiltered_artifact(self):
        names = ["unrelated.destructive test", probe.FULL_TEST_NAME, "anonymous.discovery"]
        self.assertEqual(probe.select_test(metadata(names)), (1, 3))
        for invalid in (["wrong.test"], [probe.FULL_TEST_NAME, probe.FULL_TEST_NAME],
                        [probe.FULL_TEST_NAME + " extra"]):
            with self.subTest(names=invalid):
                with self.assertRaises(ValueError):
                    probe.select_test(metadata(invalid))
        with self.assertRaises(ValueError):
            probe.select_test(metadata(names)[:-1])

    def test_unfiltered_server_runs_only_verified_index(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            binary = server_stub(parent, ["unrelated.destructive", probe.FULL_TEST_NAME, "other.test"])
            evidence = parent / "evidence"
            real_popen = subprocess.Popen

            def launch(argv, **options):
                manifest = json.loads((evidence / "manifest.json").read_text())
                root = pathlib.Path(options["env"]["RUI_APPROVAL_OCCUPIED_ROOT"])
                registered = options["env"]["RUI_APPROVAL_OCCUPIED_SOCKET"]
                self.assertEqual(manifest["root"], str(root))
                self.assertEqual(manifest["socket"], registered)
                self.assertEqual(argv[2], "--supervise")
                self.assertEqual(argv[3], str(binary.resolve()))
                self.assertEqual(len(options["pass_fds"]), 1)
                self.assertEqual(options["cwd"], root)
                self.assertIs(options["start_new_session"], True)
                self.assertEqual(options["umask"], 0o077)
                self.assertEqual(root.stat().st_mode & 0o777, 0o700)
                return real_popen(argv, **options)

            with mock.patch.object(probe.subprocess, "Popen", launch):
                result = probe.run(binary, evidence, 2)
            self.assertFalse(result["red_control_observed"])
            self.assertNotIn("error", result)
            self.assertEqual(result["cleanup"], "complete", result)
            selection = json.loads((evidence / "selection.json").read_text())
            self.assertEqual(selection["index"], 1)
            self.assertEqual(selection["compiled_tests"], 3)
            self.assertEqual((evidence / "stderr.log").read_text(), "STUB-SELECTED 1\n")
            self.assertFalse(pathlib.Path(result["owned_paths"]["root"]).exists())
            self.assertFalse(pathlib.Path(result["owned_paths"]["socket"]).exists())

    def test_wrong_server_artifact_never_receives_run_test(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            binary = server_stub(parent, ["unrelated.destructive", "wrong.test"])
            evidence = parent / "evidence"
            result = probe.run(binary, evidence, 2)
            self.assertFalse(result["red_control_observed"])
            self.assertIn("exactly one matching", result["error"])
            self.assertEqual((evidence / "stderr.log").read_text(), "")
            self.assertFalse((evidence / "selection.json").exists())
            self.assertEqual(result["cleanup"], "complete", result)

    def test_root_setup_failure_still_releases_owned_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            binary = parent / "not-executed"
            binary.write_bytes(b"not a native binary")
            with mock.patch.object(probe, "canonical_fixture_root", side_effect=OSError("resolve failed")):
                result = probe.run(binary, parent / "evidence", 1)
            self.assertIn("resolve failed", result["error"])
            self.assertEqual(result["cleanup"], "complete", result)
            self.assertFalse(pathlib.Path(result["owned_paths"]["root"]).exists())

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

    def test_supervisor_retires_descendant_after_native_child_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "owned"
            root.mkdir(mode=0o700)
            binary = server_stub(parent, [probe.FULL_TEST_NAME], descendant=True)
            evidence = parent / "evidence"
            evidence.mkdir()
            status_read, status_write = os.pipe()
            process = subprocess.Popen([sys.executable, str(pathlib.Path(probe.__file__).resolve()),
                                        "--supervise", str(binary), str(status_write), "6"],
                                       pass_fds=(status_write,), stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       start_new_session=True, bufsize=0)
            os.close(status_write)
            retained_stdout = os.dup(process.stdout.fileno())
            try:
                deadline = time.monotonic() + 2
                with (evidence / "stdout.log").open("wb") as log:
                    probe.protocol(process, deadline, evidence, log)
                self.assertEqual(probe.read_status(status_read, deadline), 0)
                self.assertIsNone(process.returncode)  # Supervisor still owns PGID.
                self.assertFalse(select.select([retained_stdout], [], [], 0)[0])
                probe.cleanup(process, root, parent / "absent.sock")
                self.assertEqual(process.returncode, -signal.SIGKILL)
                self.assertTrue(select.select([retained_stdout], [], [], 2)[0])
                self.assertEqual(os.read(retained_stdout, 1), b"")
            finally:
                if process.returncode is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=2)
                    process.stdin.close()
                    process.stdout.close()
                os.close(status_read)
                os.close(retained_stdout)

    def test_previously_reaped_leader_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / "owned"
            root.mkdir()
            with self.assertRaisesRegex(RuntimeError, "already reaped"):
                probe.cleanup(type("Reaped", (), {"returncode": 0})(), root, None)
            self.assertTrue(root.exists())

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
