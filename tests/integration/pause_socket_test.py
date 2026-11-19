import json
import socket
import subprocess
import sys
import threading
import unittest

import host_process

from pause_client import ChildExited, PauseClient, PauseError

BINARY = sys.argv.pop(1)
POINT = "action.before_handoff"


class ObservedSocket:
    def __init__(self, sock):
        self.sock = sock
        self.wait_sent = threading.Event()

    def sendall(self, data):
        self.sock.sendall(data)
        if json.loads(data)["op"] == "wait":
            self.wait_sent.set()

    def __getattr__(self, name):
        return getattr(self.sock, name)


class SocketTest(unittest.TestCase):
    def setUp(self):
        parent, child = socket.socketpair()
        self.process = subprocess.Popen([BINARY, str(child.fileno())], pass_fds=(child.fileno(),), stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        child.close()
        self.socket = ObservedSocket(parent)
        self.client = PauseClient(self.socket, self.process)
        self.addCleanup(self.cleanup_process)

    def cleanup_process(self):
        self.client.close()
        try:
            self.process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate()

    def test_pau_8_arm_ack_then_repeated_arrivals(self):
        self.client.arm(POINT)
        with self.assertRaisesRegex(PauseError, "AlreadyArmed"):
            self.client.arm(POINT)
        self.client.start()
        with self.assertRaisesRegex(PauseError, "AlreadyStarted"):
            self.client.arm(POINT)
        for number in (1, 2):
            self.process.stdin.write(bytes([number]))
            self.process.stdin.flush()
            self.assertEqual(self.process.stdout.read(1), b"A")
            arrival = self.client.wait(POINT, {"action": number})
            self.assertEqual(arrival["occurrence"], number)
            self.assertEqual(arrival["context"]["action"], number)
            self.client.release(arrival["id"])
            self.assertEqual(self.process.stdout.read(1), b"R")

    def test_pau_9_wait_does_not_block_other_requests(self):
        self.client.arm(POINT)
        self.client.start()
        result = []
        thread = threading.Thread(target=lambda: result.append(self.client.wait(POINT)))
        thread.start()
        self.assertTrue(self.socket.wait_sent.wait(5))
        with self.assertRaisesRegex(PauseError, "UnknownArrival"):
            self.client.release(999)
        self.process.stdin.write(b"\x05")
        self.process.stdin.flush()
        self.assertEqual(self.process.stdout.read(1), b"A")
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.client.release(result[0]["id"])
        self.assertEqual(self.process.stdout.read(1), b"R")

    def test_pau_10_eof_closes_owner_and_releases_worker(self):
        self.client.arm(POINT)
        self.client.start()
        self.process.stdin.write(b"\xff")
        self.process.stdin.flush()
        self.assertEqual(self.process.stdout.read(1), b"A")
        self.client.close()
        self.assertEqual(self.process.stdout.read(1), b"C")

    def test_pau_11_child_death_while_parked_reports_status(self):
        self.client.arm(POINT)
        self.client.start()
        self.process.stdin.write(b"\xff")
        self.process.stdin.flush()
        self.assertEqual(self.process.stdout.read(1), b"A")
        self.process.kill()
        self.assertEqual(self.client.wait_child_exit(timeout=5), {"event": "child_exit", "pid": self.process.pid, "returncode": -9})
        with self.assertRaises(ChildExited) as raised:
            self.client.wait(POINT, {"action": 2})
        self.assertEqual(raised.exception.pid, self.process.pid)
        self.assertEqual(raised.exception.returncode, -9)

    def test_pau_12_disconnect_unblocks_start_barrier(self):
        self.client.close()
        self.assertNotEqual(self.process.wait(timeout=5), 0)

    def test_pau_13_watchdog_bounds_wait(self):
        self.client.arm(POINT)
        self.client.start()
        self.client.timeout = 0.05
        with self.assertRaises(TimeoutError):
            self.client.wait(POINT)

    def test_pau_13_watchdog_bounds_send_backpressure(self):
        writer, reader = socket.socketpair()
        writer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        client = PauseClient(writer, timeout=0.05)
        try:
            # MSG_DONTWAIT makes only these sends non-blocking. Switching the socket
            # itself would race the client's reader thread, whose read on a
            # non-blocking socket returns nothing and ends as EOF.
            try:
                while True:
                    writer.send(b"x" * 4096, socket.MSG_DONTWAIT)
            except BlockingIOError:
                pass
            started = threading.Event()
            outcome = []
            def call():
                started.set()
                try:
                    client.arm(POINT, context={"pad": "y" * 65536})
                except Exception as exc:
                    outcome.append(exc)
            thread = threading.Thread(target=call)
            thread.start()
            self.assertTrue(started.wait(5))
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
            self.assertIsInstance(outcome[0], TimeoutError)
        finally:
            client.close()
            reader.close()

    def test_pau_14_independent_eof_is_not_child_exit(self):
        self.client.arm(POINT)
        self.client.start()
        result = []
        def wait():
            try:
                self.client.wait(POINT)
            except Exception as exc:
                result.append(exc)
        thread = threading.Thread(target=wait)
        thread.start()
        self.assertTrue(self.socket.wait_sent.wait(5))
        with self.assertRaisesRegex(PauseError, "UnknownArrival"):
            self.client.release(999)
        self.client.close()
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertIsNone(self.process.poll())
        self.assertEqual(len(result), 1)
        self.assertIsInstance(result[0], PauseError)
        self.assertNotIsInstance(result[0], ChildExited)


if __name__ == "__main__":
    host_process.enter()
    unittest.main()
