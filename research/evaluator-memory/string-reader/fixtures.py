"""Streaming inputs and a Python UTF-16/structure oracle, independent of C."""
import codecs
import dataclasses
import hashlib
import os
import struct

@dataclasses.dataclass(frozen=True)
class Text:
    pattern: str = 'x'
    repeat: int = 1
    suffix: str = ''
    all_scalars: bool = False

    def chunks(self):
        if self.all_scalars:
            window = bytearray()
            for scalar in range(0x110000):
                if 0xD800 <= scalar <= 0xDFFF:
                    continue
                window.extend(chr(scalar).encode('utf-8'))
                if len(window) >= 16380:
                    yield bytes(window)
                    window.clear()
            if window:
                yield bytes(window)
            return
        pattern = self.pattern.encode('utf-8')
        assert len(pattern) <= 16384
        chunk_count = max(1, 16384 // max(1, len(pattern)))
        remaining = self.repeat
        while remaining:
            count = min(remaining, chunk_count)
            yield pattern * count
            remaining -= count
        suffix = self.suffix.encode('utf-8')
        assert len(suffix) <= 16384
        if suffix:
            yield suffix

    def lengths(self):
        if self.all_scalars:
            return (128 + 1920*2 + (65536-2048-2048)*3 + 1048576*4,
                    65536-2048 + 1048576*2)
        return (len(self.pattern.encode('utf-8')) * self.repeat + len(self.suffix.encode('utf-8')),
                len(self.pattern.encode('utf-16le'))//2 * self.repeat + len(self.suffix.encode('utf-16le'))//2)

@dataclasses.dataclass
class Object:
    entries: list

@dataclasses.dataclass
class Raw:
    data: bytes

class Hash:
    def __init__(self):
        self.value = 2166136261

    def add(self, data):
        for byte in data:
            self.value = ((self.value ^ byte) * 16777619) & 0xffffffff

    def integer(self, value):
        self.add(struct.pack('<I', value))

    def string(self, value):
        if isinstance(value, str):
            value = Text(value)
        self.integer(value.lengths()[1])
        decode = codecs.getincrementaldecoder('utf-8')()
        for chunk in value.chunks():
            self.add(decode.decode(chunk).encode('utf-16le'))
        self.add(decode.decode(b'', final=True).encode('utf-16le'))

    def walk(self, value):
        if value is None:
            self.add(b'\0')
        elif isinstance(value, bool):
            self.add(bytes([2 if value else 1]))
        elif isinstance(value, (int, float)):
            self.add(b'\3' + struct.pack('<d', 0 if value == 0 else value))
        elif isinstance(value, (str, Text)):
            self.add(b'\4')
            self.string(value)
        elif isinstance(value, list):
            self.add(b'\5')
            self.integer(len(value))
            for item in value:
                self.walk(item)
        elif isinstance(value, Object):
            self.add(b'\6')
            self.integer(len(value.entries))
            # JS enumerates canonical uint32 property names before other strings.
            def index(entry):
                key = entry[0]
                if isinstance(key, str) and key.isascii() and key.isdecimal() and str(int(key)) == key and int(key) < 2**32-1:
                    return int(key)
                return None
            numeric = sorted((e for e in value.entries if index(e) is not None), key=index)
            other = [e for e in value.entries if index(e) is None]
            for key, item in numeric + other:
                self.string(key)
                self.walk(item)
        else:
            raise TypeError(value)

def prepare(path, value):
    digest = hashlib.sha256()
    with path.open('wb', buffering=0) as out:
        def emit(data):
            view = memoryview(data)
            while view:
                count = out.write(view)
                if count is None or count <= 0:
                    raise OSError('short scratch write')
                view = view[count:]
            digest.update(data)

        def text(value):
            if isinstance(value, str):
                value = Text(value)
            emit(struct.pack('<Q', value.lengths()[0]))
            for chunk in value.chunks():
                emit(chunk)

        def walk(value):
            if isinstance(value, Raw):
                emit(value.data)
            elif value is None:
                emit(b'\0')
            elif isinstance(value, bool):
                emit(bytes([2 if value else 1]))
            elif isinstance(value, (int, float)):
                emit(b'\3' + struct.pack('<d', value))
            elif isinstance(value, (str, Text)):
                emit(b'\4')
                text(value)
            elif isinstance(value, list):
                emit(b'\5' + struct.pack('<I', len(value)))
                for item in value:
                    walk(item)
            elif isinstance(value, Object):
                emit(b'\6' + struct.pack('<I', len(value.entries)))
                for key, item in value.entries:
                    text(key)
                    walk(item)
            else:
                raise TypeError(value)
        walk(value)
        os.fsync(out.fileno())
    check = hashlib.sha256()
    with path.open('rb', buffering=0) as source:
        while chunk := source.read(16384):
            check.update(chunk)
    assert check.digest() == digest.digest()
    return digest.hexdigest()
