"""Bounded reader for the installed Zig runner's test metadata protocol."""
from pathlib import Path
import struct
import subprocess

MAX_BYTES = 64 * 1024 * 1024


def parse_metadata(body):
    if len(body) < 8:
        raise ValueError("truncated metadata header")
    strings_len, count = struct.unpack_from("<II", body)
    if len(body) != 8 + count * 8 + strings_len:
        raise ValueError("invalid metadata length")
    strings = body[8 + count * 8:]
    names = []
    for (offset,) in struct.iter_unpack("<I", body[8:8 + count * 4]):
        if offset >= len(strings):
            raise ValueError("invalid test name offset")
        end = strings.find(b"\0", offset)
        if end < 0:
            raise ValueError("unterminated test name")
        names.append(strings[offset:end].decode("utf-8"))
    return names


def parse_stream(data):
    names = None
    position = 0
    while position < len(data):
        if len(data) - position < 8:
            raise ValueError("truncated server header")
        tag, size = struct.unpack_from("<II", data, position)
        position += 8
        if size > MAX_BYTES or size > len(data) - position:
            raise ValueError("invalid server message length")
        body = data[position:position + size]
        position += size
        if tag == 3:
            if names is not None:
                raise ValueError("duplicate metadata response")
            names = parse_metadata(body)
        elif tag != 0:
            raise ValueError(f"unexpected server message {tag}")
    if names is None:
        raise ValueError("missing metadata response")
    return names


def query(binary, timeout=30, environ=None):
    import threading
    process = subprocess.Popen([str(Path(binary).resolve()), "--listen=-"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environ)
    buffers = [bytearray(), bytearray()]
    oversized = threading.Event()

    def consume(stream, buffer, limit):
        while True:
            chunk = stream.read(min(65536, limit + 1 - len(buffer)))
            if not chunk:
                break
            buffer.extend(chunk)
            if len(buffer) > limit:
                oversized.set()
                process.kill()
                break
        stream.close()

    threads = [threading.Thread(target=consume, args=(stream, buffer, limit), daemon=True)
               for stream, buffer, limit in zip((process.stdout, process.stderr), buffers,
                                                 (MAX_BYTES, 4096))]
    for thread in threads:
        thread.start()
    try:
        try:
            process.stdin.write(struct.pack("<IIII", 4, 0, 0, 0))
            process.stdin.close()
        except BrokenPipeError:
            pass
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise ValueError(f"metadata query timed out: {binary}") from None
    finally:
        for thread in threads:
            thread.join(timeout=60)
    if any(thread.is_alive() for thread in threads):
        raise ValueError("metadata query left open output streams")
    if oversized.is_set():
        raise ValueError("metadata response or diagnostic exceeds size limit")
    if process.returncode:
        diagnostic = buffers[1].decode("utf-8", errors="replace")
        raise ValueError(f"metadata query failed ({process.returncode}): {binary}: {diagnostic}")
    return parse_stream(buffers[0])
