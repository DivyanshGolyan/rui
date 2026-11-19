"""Streaming provider disconnect accounting covers the whole response."""
import errno
from pathlib import Path
import socket
import sys
import threading
import unittest
from unittest.mock import patch

import h2.config
import h2.connection
import h2.errors
import h2.events

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
with patch.object(sys, "argv", [__file__, "/unused/rui"]):
    import control_fixture
import host_process


class StreamingDisconnectTest(unittest.TestCase):
    def check_response(self, phase, failure=None):
        entered, release, handled, reported = (threading.Event() for _ in range(4))
        paused, errors = [], []

        class Handler(control_fixture.StreamingHandler):
            def end_headers(self):
                if phase == "body":
                    super().end_headers()
                paused.append((self.wfile.connection, self.wfile.stream))
                entered.set()
                if not release.wait(300):
                    raise AssertionError("response barrier was not released")
                if failure is not None:
                    raise failure
                if phase == "headers":
                    super().end_headers()

            def do_POST(self):
                try:
                    super().do_POST()
                finally:
                    handled.set()

        endpoint = control_fixture.StreamingEndpoint()
        endpoint.RequestHandlerClass = Handler

        def report(*_args):
            errors.append(sys.exception())
            reported.set()

        endpoint.handle_error = report
        worker = threading.Thread(target=endpoint.serve_forever)
        peer = None
        worker.start()
        try:
            peer = socket.create_connection(endpoint.server_address, timeout=60)
            client = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
            client.initiate_connection()
            client.send_headers(1, [(":method", "POST"), (":scheme", "http"),
                                   (":authority", "localhost"), (":path", "/responses"),
                                   ("content-length", "0")], end_stream=True)
            peer.sendall(client.data_to_send())
            self.assertTrue(entered.wait(60), "response did not reach the barrier")
            self.assertEqual(endpoint.counts(), (1, 0))
            if failure is None:
                connection, stream = paused[0]
                client.reset_stream(1, error_code=h2.errors.ErrorCodes.CANCEL)
                peer.sendall(client.data_to_send())
                with connection.cond:
                    self.assertTrue(connection.cond.wait_for(lambda: stream.reset, timeout=60),
                                    "server did not observe the stream reset")
            release.set()
            self.assertTrue(handled.wait(60), "provider handler did not retire")
            if failure is None:
                self.assertEqual(endpoint.counts(), (1, 1))
                self.assertEqual(errors, [])
                endpoint.release.set()
                client.send_headers(3, [(":method", "POST"), (":scheme", "http"),
                                       (":authority", "localhost"), (":path", "/responses"),
                                       ("content-length", "0")], end_stream=True)
                peer.sendall(client.data_to_send())
                finished = False
                while not finished:
                    data = peer.recv(65536)
                    self.assertTrue(data, "one cancelled stream closed the shared connection")
                    for event in client.receive_data(data):
                        if isinstance(event, h2.events.StreamEnded) and event.stream_id == 3:
                            finished = True
                self.assertEqual(endpoint.counts(), (2, 1))
            else:
                self.assertTrue(reported.wait(60), "non-peer error was swallowed")
                self.assertEqual(errors, [failure])
                self.assertEqual(endpoint.counts(), (1, 0))
        finally:
            def join():
                worker.join(60)
                self.assertFalse(worker.is_alive(), "provider acceptor did not retire")

            host_process.dispose_all(release.set, endpoint.release.set,
                                     lambda: peer.close() if peer is not None else None,
                                     endpoint.shutdown, endpoint.server_close, join)

    def test_reset_before_response_headers_is_counted_once(self):
        self.check_response("headers")

    def test_reset_before_first_keepalive_is_counted_once(self):
        self.check_response("body")

    def test_unrelated_header_error_is_not_a_disconnect(self):
        self.check_response("headers", OSError(errno.EIO, "forced provider write failure"))


if __name__ == "__main__":
    unittest.main()
