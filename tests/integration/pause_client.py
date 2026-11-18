"""Test-only client for the inherited pause-control socket.

Child exits originate at the parent process watcher, not the dead child socket.
The watcher emits a length-prefixed JSON event into ``events`` and dispatches it
alongside socket replies. Socket EOF alone is distinct from process exit.
"""
import json
import queue
import socket
import struct
import threading
import time


class PauseError(RuntimeError):
    pass


class ChildExited(PauseError):
    def __init__(self, pid, returncode):
        self.pid = pid
        self.returncode = returncode
        super().__init__(f"child {pid} exited with status {returncode}")


class PauseClient:
    def __init__(self, sock, process=None, timeout=10):
        self.sock = sock
        self.timeout = timeout
        self.lock = threading.Lock()
        self.send_lock = threading.Lock()
        self.pending = {}
        self.next_seq = 1
        self.failure = None
        self.transport_failure = None
        self.process = None
        self.events = queue.Queue()
        if process is not None:
            self.attach_process(process)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def attach_process(self, process):
        with self.lock:
            if self.process is not None:
                raise ValueError("process already attached")
            self.process = process
        threading.Thread(target=self._watch, args=(process,), daemon=True).start()

    def _watch(self, process):
        code = process.wait()
        event = {"event": "child_exit", "pid": process.pid, "returncode": code}
        payload = json.dumps(event, separators=(",", ":")).encode()
        frame = struct.pack("!I", len(payload)) + payload
        self._dispatch_event(frame)
        self.events.put(frame)

    def _dispatch_event(self, frame):
        size = struct.unpack("!I", frame[:4])[0]
        event = json.loads(frame[4:4 + size])
        failure = ChildExited(event["pid"], event["returncode"])
        with self.lock:
            self.failure = failure
            for waiter, result in self.pending.values():
                result.append(failure)
                waiter.set()
            self.pending.clear()

    def _read(self):
        try:
            with self.sock.makefile("rb") as stream:
                for line in stream:
                    response = json.loads(line)
                    with self.lock:
                        pending = self.pending.pop(response["seq"], None)
                        if pending is not None:
                            pending[1].append(response)
                            pending[0].set()
            raise EOFError("pause socket closed")
        except (OSError, EOFError, ValueError, KeyError) as exc:
            with self.lock:
                self.transport_failure = exc
                for waiter, result in self.pending.values():
                    result.append(exc)
                    waiter.set()
                self.pending.clear()

    def _call(self, op, **kwargs):
        deadline = time.monotonic() + self.timeout
        event, result = threading.Event(), []
        with self.lock:
            if self.failure is not None:
                raise self.failure
            if self.transport_failure is not None:
                raise PauseError("pause socket closed") from self.transport_failure
            seq = self.next_seq
            self.next_seq += 1
            self.pending[seq] = (event, result)
        frame = json.dumps(dict(seq=seq, op=op, **kwargs)).encode() + b"\n"
        sent, send_error = threading.Event(), []

        def send():
            try:
                with self.send_lock:
                    self.sock.sendall(frame)
            except OSError as exc:
                send_error.append(exc)
            finally:
                sent.set()

        threading.Thread(target=send, daemon=True).start()
        if not sent.wait(max(0.0, deadline - time.monotonic())):
            self._abandon(seq)
            self._break_transport(TimeoutError(f"pause {op} send timed out"))
            raise TimeoutError(f"pause {op} timed out")
        if send_error:
            self._abandon(seq)
            self._break_transport(send_error[0])
            raise PauseError("pause socket closed") from send_error[0]
        if not event.wait(max(0.0, deadline - time.monotonic())):
            self._abandon(seq)
            with self.lock:
                failure = self.transport_failure
            if failure is not None:
                raise PauseError("pause socket closed while child remains alive") from failure
            raise TimeoutError(f"pause {op} timed out")
        response = result[0]
        if isinstance(response, ChildExited):
            raise response
        if isinstance(response, Exception):
            raise PauseError("pause socket closed") from response
        if response.get("err"):
            raise PauseError(response["err"])
        return response.get("arrival")

    def _abandon(self, seq):
        with self.lock:
            self.pending.pop(seq, None)

    def _break_transport(self, exc):
        with self.lock:
            if self.transport_failure is None:
                self.transport_failure = exc
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def wait_child_exit(self, timeout=None):
        try:
            frame = self.events.get(timeout=self.timeout if timeout is None else timeout)
        except queue.Empty as exc:
            raise TimeoutError("child exit timed out") from exc
        size = struct.unpack("!I", frame[:4])[0]
        return json.loads(frame[4:4 + size])

    def start(self):
        return self._call("start")

    def arm(self, point, context=None, occurrence=None):
        return self._call("arm", point=point, context=context or {}, occurrence=occurrence)

    def wait(self, point, context=None, occurrence=None):
        return self._call("wait", point=point, context=context or {}, occurrence=occurrence)

    def release(self, id):
        return self._call("release", id=id)

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        self.reader.join()
