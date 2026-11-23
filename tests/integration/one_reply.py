
import contextlib
import os
import pathlib
import select
import socket
import os_semantics
import threading
import time

from host_process import WaitTimeout, dispose_all, wait_for

HEADER_LIMIT = 16 * 1024
BODY_LIMIT = 64 * 1024


class _Cancelled(Exception):
    pass


@contextlib.contextmanager
def one_reply(path, response, *, timeout=10):
    deadline = time.monotonic() + timeout
    path = pathlib.Path(path)
    sockets = []
    worker = None
    bound = False
    parent_made = False
    lock_fd = None
    acquired = None
    errors = []
    try:
        listener = os_semantics.unix_stream()
        sockets.append(listener)
        cancel, wake = socket.socketpair()
        sockets.extend((cancel, wake))
        # The mock claims D the way a Host does: it holds D/rui.lock while it
        # serves, so no census proves D dead under it.
        if not path.parent.exists():
            path.parent.mkdir(mode=0o700)
            parent_made = True
        def claim():
            # One attempt: the held fd, or None after closing every fd it opened.
            nonlocal parent_made, acquired
            try:
                fd = os.open(path.parent / "rui.lock",
                             os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                             0o600)
            except FileNotFoundError:
                try:
                    path.parent.mkdir(mode=0o700)
                    parent_made = True
                except FileExistsError:
                    pass
                return None
            if not os_semantics.try_lock(fd):
                os.close(fd)
                return None
            try:
                named = os.stat(path.parent / "rui.lock", follow_symlinks=False).st_ino
            except FileNotFoundError:
                named = None
            if named != os.fstat(fd).st_ino:
                os.close(fd)
                return None
            acquired = fd
            return fd

        try:
            lock_fd = wait_for(claim, "one-reply interface directory lock", deadline=deadline,
                               drain=False, ready=lambda fd: fd is not None)
        except WaitTimeout as error:
            # wait_for can time out just after claim() succeeded; that fd is not returned, so close it here.
            if acquired is not None:
                os.close(acquired)
            raise TimeoutError("one-reply interface directory is in use") from error
        path.unlink(missing_ok=True)
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
                dispose_all(lambda: wake.shutdown(socket.SHUT_WR), worker.join)
            if errors:
                raise errors[0]

        dispose_all(retire, *(sock.close for sock in sockets),
                    lambda: path.unlink(missing_ok=True) if bound else None,
                    lambda: (path.parent / "rui.lock").unlink(missing_ok=True) if lock_fd is not None else None,
                    lambda: _remove_empty_directory(path.parent) if parent_made else None,
                    lambda: os.close(lock_fd) if lock_fd is not None else None)


def _remove_empty_directory(directory):
    with contextlib.suppress(OSError):
        directory.rmdir()
