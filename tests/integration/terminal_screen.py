"""Bounded pyte screen observations at synchronized-output commits.

This fixture understands frame delimiters, not terminal rendering: pyte owns
cursor movement, erasure, wrapping, Unicode cells and incremental updates.
"""
import codecs
from collections import OrderedDict
import fcntl
import os
import re
import struct
import sys
import termios
import unicodedata

import pyte
from wcwidth import wcwidth


LIMIT = 1024 * 1024
BOUNDARY = re.compile(r"\x1b\[\?2026([hl])")
ALTERNATE = re.compile(r"\x1b\[\?1049([hl])")
RESTORE = "\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l"


class CombiningScreen(pyte.Screen):
    """Batch cell normalization, retaining pyte 0.8.2's draw transitions.

    Pyte normalizes a growing cell once per combining scalar. Delegate the
    first mark (and all ordinary text) so pyte still owns wrapping, scrolling,
    charset translation and attributes; normalize only its unchanged target's
    remaining adjacent marks. No text or state is deferred across draw calls.
    """
    def draw(self, data):
        translated = data.translate(self.g1_charset if self.charset else self.g0_charset)
        start = index = 0
        while index < len(translated):
            width = wcwidth(translated[index])
            combining = width == 0 and unicodedata.combining(translated[index])
            if width <= 0 and not combining:
                # Stock draw discards everything after the first unprintable.
                # Delegate that suffix once, never resume after its early stop.
                break
            if combining:
                end = index + 1
                while end < len(translated) and wcwidth(translated[end]) == 0 and unicodedata.combining(translated[end]):
                    end += 1
                super().draw(data[start:index + 1])
                if self.cursor.x or self.cursor.y:
                    row = self.cursor.y if self.cursor.x else self.cursor.y - 1
                    column = self.cursor.x - 1 if self.cursor.x else self.columns - 1
                    cell = self.buffer[row][column]
                    self.buffer[row][column] = cell._replace(
                        data=unicodedata.normalize("NFC", cell.data + translated[index + 1:end]))
                start = index = end
            else:
                index += 1
        super().draw(data[start:])


class ScreenCapture:
    def __init__(self, columns=80, rows=24):
        assert 0 < columns <= 4096 and 0 < rows <= 512
        self.screen = CombiningScreen(columns, rows)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = ""
        self.frame = ""
        self.synchronized = False
        self.generation = 0
        self.completed = ""

    def resize(self, columns, rows):
        assert 0 < columns <= 4096 and 0 < rows <= 512
        self.screen.resize(lines=rows, columns=columns)

    def feed_cells(self, text):
        if self.synchronized:
            # Collect the complete frame before interpreting its cells. Pyte's
            # per-scalar combining normalization can otherwise consume the I/O
            # deadline while the rest of a valid frame waits in the PTY.
            self.frame += text
            assert len(self.frame.encode()) < LIMIT, "unexpected unbounded terminal frame"
            return
        offset = 0
        for match in ALTERNATE.finditer(text):
            self.stream.feed(text[offset:match.start()])
            if match[1] == "h":
                self.screen.reset()
                self.completed = ""
                # Keep commit numbering monotonic for a waiter already holding
                # this capture across another invocation on the same PTY.
            offset = match.end()
        self.stream.feed(text[offset:])

    def feed(self, data):
        self.pending += self.decoder.decode(data)
        assert len(self.pending.encode()) < LIMIT, "unexpected unbounded terminal output"
        while True:
            match = BOUNDARY.search(self.pending)
            if match is None:
                # Preserve only a possibly split delimiter; all other escape
                # parsing (including a split CUP) belongs to pyte's stream.
                cut = self.pending.rfind("\x1b")
                if cut < 0 or len(self.pending) - cut > 16:
                    cut = len(self.pending)
                self.feed_cells(self.pending[:cut])
                self.pending = self.pending[cut:]
                break
            if match[1] == "l" and not self.synchronized:
                # Terminal disposal closes synchronization unconditionally,
                # even after a committed frame. This exact restoration sequence
                # is not another frame and cannot establish input readiness.
                suffix = self.pending[match.start():]
                if RESTORE.startswith(suffix) and len(suffix) < len(RESTORE):
                    break
                assert suffix.startswith(RESTORE), "frame end without frame start"
                self.feed_cells(self.pending[:match.start()])
                self.feed_cells(RESTORE[len(match[0]):])
                self.pending = suffix[len(RESTORE):]
                self.completed = ""
                continue
            self.feed_cells(self.pending[:match.start()])
            self.pending = self.pending[match.end():]
            if match[1] == "h":
                assert not self.synchronized, "nested synchronized frame"
                self.synchronized = True
            else:
                assert self.synchronized, "frame end without frame start"
                self.synchronized = False
                self.feed_cells(self.frame)
                self.frame = ""
                self.generation += 1
                self.completed = "\n".join(
                    "› " if line.rstrip() == "›" else line.rstrip()
                    for line in self.screen.display)
                assert len(self.completed.encode()) < LIMIT, "unexpected unbounded terminal output"

    def reached(self, marker, composer=False):
        # Pyte composes adjacent combining marks in its cells. Match visible
        # text canonically; exact submitted bytes have separate capture checks.
        marker = unicodedata.normalize("NFC", marker)
        if self.synchronized or not self.generation or marker not in self.completed:
            return False
        if not composer and not marker.startswith("› "):
            return True
        # Editing is available during opening, submission is not. The old
        # inline frontend did not draw its composer until opening completed.
        if "Opening…" in self.completed:
            return False
        cursor = self.screen.cursor
        first = cursor.y
        while first > 0 and self.screen.display[first].startswith("> "):
            first -= 1
        if not self.screen.display[first].startswith("› ") or cursor.x < 2:
            return False
        if marker.startswith("› "):
            draft = "\n".join("› " if line.rstrip() == "›" else line.rstrip()
                for line in self.screen.display[first:])
            # An identical earlier User row is not an edited composer. Wrapped
            # composition starts at its own marker above the caret's > rows.
            return (marker in draft) if marker != "› " else not draft[2:].strip()
        return True


_captures = OrderedDict()


def release_capture(fd):
    for key in list(_captures):
        if key[0] == fd:
            del _captures[key]


def capture_for(fd):
    identity = os.fstat(fd)
    if os.isatty(fd) and sys.platform == "linux":
        # ptmx fstat identifies the multiplexor, not this terminal. Borrow a
        # slave descriptor from the kernel rather than guessing /dev/pts paths.
        peer = fcntl.ioctl(fd, 0x5441, os.O_RDWR | os.O_NOCTTY | os.O_CLOEXEC)
        try:
            identity = os.fstat(peer)
        finally:
            os.close(peer)
    key = (fd, identity.st_dev, identity.st_ino)
    # Closed/reused descriptors cannot lend an earlier process's screen.
    for old in list(_captures):
        if old[0] == fd and old != key:
            del _captures[old]
    if key not in _captures:
        if len(_captures) == 16:
            _captures.popitem(last=False)
        _captures[key] = ScreenCapture()
    _captures.move_to_end(key)
    capture = _captures[key]
    if os.isatty(fd):
        rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, bytes(8)))
        capture.resize(columns or 80, rows or 24)
    return capture
