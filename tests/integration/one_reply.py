"""One fixture-owned Unix exchange; callers own the response, including malformations."""

import contextlib
import pathlib
import select
import socket
import threading
import time

from host_process import dispose_all

# These read-only typed requests contain identities/cursors, never input payloads.
# Keep generous finite fixture limits without retaining their request bodies.
HEADER_LIMIT = 16 * 1024
BODY_LIMIT = 64 * 1024


class _Cancelled(Exception):
    pass


@contextlib.contextmanager
def one_reply(path, response, *, timeout=10):
    """Yield the original deadline for the caller's subprocess timeout.

    All I/O and normal retirement use that deadline. Failure wakes every wait
    and reaps the worker before releasing its resources; reaping is mandatory,
    not a timed join that abandons a live thread. OS scheduling is not bounded.
    The supplied response is borrowed and sent unchanged without a full copy.
    """
    deadline = time.monotonic() + timeout
    path = pathlib.Path(path)
    sockets = []
    worker = None
    bound = False
    errors = []
    try:
        listener = socket.socket(socket.AF_UNIX)
        sockets.append(listener)
        cancel, wake = socket.socketpair()
        sockets.extend((cancel, wake))
        path.unlink(missing_ok=True)  # Only the stopped fixture Host's endpoint.
        listener.bind(str(path))
        bound = True
        listener.listen(1)
        listener.setblocking(False)

        def wait(sock, *, writing=False):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("one-reply exchange deadline expired")
            readable, writable, _ = select.select(
                [cancel] if writing else [cancel, sock],
                [sock] if writing else [], [], remaining)
            if cancel in readable:
                raise _Cancelled()
            if not (writable if writing else sock in readable):
                raise TimeoutError("one-reply exchange deadline expired")

        def receive(peer, size, phase):
            while True:
                wait(peer)
                try:
                    chunk = peer.recv(size)
                except BlockingIOError:
                    continue
                if not chunk:
                    raise EOFError(f"truncated one-reply request {phase}")
                return chunk

        def serve():
            try:
                while True:
                    wait(listener)
                    try:
                        peer, _ = listener.accept()
                        break
                    except BlockingIOError:
                        continue
                try:
                    peer.setblocking(False)
                    data = bytearray()
                    while b"\r\n\r\n" not in data:
                        if len(data) == HEADER_LIMIT:
                            raise ValueError("one-reply request header exceeds limit")
                        data.extend(receive(peer, min(4096, HEADER_LIMIT - len(data)), "header"))
                    head, received = data.split(b"\r\n\r\n", 1)
                    lengths = [line.partition(b":")[2].strip()
                               for line in head.split(b"\r\n")[1:]
                               if line.partition(b":")[0].lower() == b"content-length"]
                    if len(lengths) != 1 or not lengths[0].isdigit():
                        raise ValueError("one-reply request needs one decimal Content-Length")
                    length = int(lengths[0])
                    if length > BODY_LIMIT:
                        raise ValueError("one-reply request body exceeds limit")
                    remaining = length - len(received)
                    if remaining < 0:
                        raise ValueError("one-reply request exceeds Content-Length")
                    while remaining:
                        remaining -= len(receive(peer, min(4096, remaining), "body"))
                    pending = memoryview(response)
                    while pending:
                        wait(peer, writing=True)
                        try:
                            sent = peer.send(pending[:65536])
                        except BlockingIOError:
                            continue
                        if sent == 0:
                            raise EOFError("one-reply response peer closed")
                        pending = pending[sent:]
                except _Cancelled:
                    pass
                finally:
                    dispose_all(peer.close)
            except _Cancelled:
                pass
            except BaseException as error:
                errors.append(error)

        worker = threading.Thread(target=serve, name="one-reply")
        worker.start()
        yield deadline
        worker.join(max(0, deadline - time.monotonic()))
        if errors:
            raise errors[0]
        if worker.is_alive() or time.monotonic() > deadline:
            raise TimeoutError("one-reply retirement deadline expired")
    finally:
        def retire():
            if worker is not None and worker.ident is not None:
                # EOF on the private cancellation socket wakes accept/read/write.
                # Only the worker ever touches the accepted socket.
                dispose_all(lambda: wake.shutdown(socket.SHUT_WR), worker.join)
            if errors:
                raise errors[0]

        dispose_all(retire, *(sock.close for sock in sockets),
                    lambda: path.unlink(missing_ok=True) if bound else None)
