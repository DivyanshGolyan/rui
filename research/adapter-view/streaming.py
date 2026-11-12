"""Bounded lexical copying of ALREADY VALIDATED canonical fixture JSON.

This is not a provider-output validator. Values, including unknown fields,
are copied with exact string spelling. Only top-level created_by is removed.
No full object, string, property name or list is decoded into memory.
"""
import tempfile
from core import ResourceExceeded, Unavailable
from adapter import selected


class Source:
    def __init__(self, chunks):
        self.iterator = iter(chunks)
        self.chunk, self.index = b'', 0

    def peek(self):
        while self.index == len(self.chunk):
            self.chunk = next(self.iterator,b'')
            self.index = 0
            if not self.chunk:
                return None
        return self.chunk[self.index]

    def take(self):
        byte = self.peek()
        if byte is None:
            raise Unavailable('unexpected JSON end')
        self.index += 1
        return byte

    def space(self):
        while self.peek() in (9,10,13,32):
            self.take()

    def expect(self, byte):
        self.space()
        if self.take() != byte:
            raise Unavailable('unexpected JSON delimiter')

    def finish(self):
        self.space()
        if self.peek() is not None:
            raise Unavailable('trailing JSON')

    def close(self):
        self.iterator.close()


class Sink:
    def __init__(self, file, allowance):
        self.file, self.allowance = file, allowance
        self.buffer = bytearray()

    def write(self, data):
        if self.file.tell()+len(self.buffer)+len(data) > self.allowance:
            raise ResourceExceeded('request scratch')
        self.buffer.extend(data)
        if len(self.buffer)>=4096:
            self.flush()

    def byte(self, byte):
        self.write(bytes((byte,)))

    def flush(self):
        if self.buffer:
            if self.file.write(self.buffer) != len(self.buffer):
                raise OSError('short scratch write')
            self.buffer.clear()

    def mark(self):
        self.flush()
        return self.file.tell()

    def rewind(self, mark):
        self.buffer.clear()
        self.file.seek(mark)
        self.file.truncate()


def string(source, sink, match=None):
    source.expect(34)
    sink.byte(34)
    # Small decoded key prefix only; a long unknown key is still copied whole.
    prefix = bytearray()
    matching = match is not None
    while True:
        byte = source.take()
        sink.byte(byte)
        if byte == 34:
            break
        if byte == 92:
            escape = source.take()
            sink.byte(escape)
            if escape == 117:
                digits = bytes(source.take() for _ in range(4))
                sink.write(digits)
                decoded = int(digits,16)
            else:
                decoded = {34:34,92:92,47:47,98:8,102:12,110:10,114:13,116:9}[escape]
        else:
            decoded = byte
        if matching:
            if len(prefix)>=len(match) or decoded != match[len(prefix)]:
                matching = False
            else:
                prefix.append(decoded)
    return matching and bytes(prefix)==match


def copy_value(source,sink):
    source.space()
    first = source.peek()
    if first == 34:
        string(source,sink)
        return
    if first in (91,123):
        # Accepted syntax already establishes matching nesting and UTF-8.
        depth = 0
        while True:
            byte = source.peek()
            if byte == 34:
                string(source,sink)
                continue
            byte = source.take()
            sink.byte(byte)
            if byte in (91,123): depth += 1
            if byte in (93,125): depth -= 1
            if depth == 0: return
    copied = False
    while source.peek() not in (None,9,10,13,32,44,93,125):
        sink.byte(source.take())
        copied = True
    if not copied:
        raise Unavailable('missing JSON value')


def copy_object(view,ref,sink,strip_created_by=False,braces=True):
    source = Source(view.chunks(ref))
    try:
        source.expect(123)
        if braces: sink.byte(123)
        first = True
        source.space()
        while source.peek()!=125:
            mark = sink.mark()
            if not first: sink.byte(44)
            excluded = string(source,sink,b'created_by' if strip_created_by else None)
            source.expect(58)
            sink.byte(58)
            copy_value(source,sink)
            if excluded:
                sink.rewind(mark)
            else:
                first = False
            source.space()
            if source.peek()==125: break
            source.expect(44)
            source.space()
        source.expect(125)
        if braces: sink.byte(125)
        source.finish()  # Exhaust reader and verify digest before sealing request.
        return not first
    finally:
        source.close()


def prepare(view,allowance=128*1024*1024,file_factory=tempfile.TemporaryFile,compacting=False):
    """Return complete scratch at offset zero; failure closes it, never dispatches.

    Caller owns returned scratch through transport cleanup. No database read
    transaction or payload handle remains active when this returns.
    """
    file = file_factory(mode='w+b')
    sink = Sink(file,allowance)
    try:
        sink.write(b'{')
        settings_present = copy_object(view,view.settings(),sink,braces=False)
        if settings_present: sink.write(b',')
        sink.write(b'"store":false,"stream":true,"include":["reasoning.encrypted_content"],"input":[')
        first = True
        def emit(ref,provider=False):
            nonlocal first
            if not first: sink.write(b',')
            copy_object(view,ref,sink,strip_created_by=provider)
            first = False
        for kind,ref,anchored in selected(view):
            if kind in ('user','instruction'):
                emit(ref)
                continue
            for payload in view.model_output(ref,from_anchor=anchored):
                emit(payload,True)
            for payload in view.tool_results(ref,from_anchor=anchored):
                emit(payload)
        if compacting:
            if not first: sink.write(b',')
            sink.write(b'{"type":"compaction_trigger"}')
        sink.write(b']}')
        sink.flush()
        file.flush()
        file.seek(0)
        return file
    except BaseException:
        file.close()
        raise
