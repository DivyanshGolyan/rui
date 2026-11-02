"""Bounded committed-screen observer for the explicitly selected renderer suite.

pyte owns terminal cells; frame delimiters establish repaint completion, not
submission or consent readiness. Exact input is checked at the Host separately.
"""
import codecs
import re
import unicodedata

import pyte
from wcwidth import wcwidth


LIMIT = 1024 * 1024
BOUNDARY = re.compile(r"\x1b\[\?2026([hl])")
PLAIN_CONTROL = re.compile(r"\x1b\[[0-9;?$]*[A-Za-z~]|\x1b[()][A-Z0-9]|\r(?!\n)")
RESTORE = "\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l"


def shown(text, screen):
    """`text` appears on `screen` even where rows broke it: inside a long word
    the frame breaks between characters; at a space, word wrap drops it."""
    pattern = "\n?".join("[ \n]" if c == " " else re.escape(c) for c in text)
    return re.search(pattern, screen) is not None


class CombiningScreen(pyte.Screen):
    """Normalize adjacent combining marks once, retaining pyte draw semantics."""
    def draw(self, data):
        translated = data.translate(self.g1_charset if self.charset else self.g0_charset)
        start = index = 0
        while index < len(translated):
            width = wcwidth(translated[index])
            combining = width == 0 and unicodedata.combining(translated[index])
            if width <= 0 and not combining:
                break  # Stock draw discards the suffix after an unprintable.
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
        self.screen = CombiningScreen(columns, rows)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = self.frame = self.completed = ""
        # Cells of the latest committed frame, for style oracles.
        self.completed_cells = []
        self.synchronized = False
        self.generation = 0
        # Optional observer of every committed frame, not only the latest:
        # a frame can be replaced within the same read.
        self.listener = None
        self.received_bytes = 0  # Output volume, for repaint-cost oracles.
        self.alternate = False
        self.plain = ""
        self.plain_total = 0
        # Each complete OSC 52 sequence, as written; pyte drops them.
        self.clipboard = []
        self.clipboard_pending = ""

    def plain_since(self, total):
        """Main-screen text written after `plain_total` was `total`."""
        return self.plain[max(0, len(self.plain) - (self.plain_total - total)):]

    def resize(self, columns, rows):
        assert 0 < columns <= 4096 and 0 < rows <= 512
        self.screen.resize(lines=rows, columns=columns)

    def cells(self, text):
        if self.synchronized:
            self.frame += text
            assert len(self.frame.encode()) < LIMIT, "unbounded terminal frame"
        else:
            # pyte does not implement the alternate-screen buffer.
            for part in re.split(r"(\x1b\[\?1049[hl])", text):
                if part == "\x1b[?1049h":
                    self.screen.reset()
                    self.completed = ""
                    self.alternate = True
                elif part == "\x1b[?1049l":
                    self.alternate = False
                else:
                    self.stream.feed(part)
                    if not self.alternate:
                        # Main-screen text (before entry or after restoration),
                        # such as diagnostics and detach notices, is a stream.
                        visible = PLAIN_CONTROL.sub("", part).replace("\r\n", "\n")
                        self.plain = (self.plain + visible)[-LIMIT // 4:]
                        self.plain_total += len(visible)

    def collect_clipboard(self, text):
        self.clipboard_pending += text
        while True:
            start = self.clipboard_pending.find("\x1b]52;")
            if start < 0:
                self.clipboard_pending = self.clipboard_pending[-4:]
                return
            end = self.clipboard_pending.find("\x1b\\", start)
            if end < 0:
                self.clipboard_pending = self.clipboard_pending[start:]
                assert len(self.clipboard_pending) < LIMIT, "unbounded clipboard sequence"
                return
            self.clipboard.append(self.clipboard_pending[start:end + 2])
            self.clipboard_pending = self.clipboard_pending[end + 2:]

    def feed(self, data):
        self.received_bytes += len(data)
        text = self.decoder.decode(data)
        self.collect_clipboard(text)
        self.pending += text
        assert len(self.pending.encode()) < LIMIT, "unbounded terminal output"
        while True:
            match = BOUNDARY.search(self.pending)
            if match is None:
                cut = self.pending.rfind("\x1b")
                if cut < 0 or len(self.pending) - cut > 16:
                    cut = len(self.pending)
                self.cells(self.pending[:cut])
                self.pending = self.pending[cut:]
                return
            if match[1] == "l" and not self.synchronized:
                suffix = self.pending[match.start():]
                if RESTORE.startswith(suffix) and len(suffix) < len(RESTORE):
                    return
                assert suffix.startswith(RESTORE), "frame end without frame start"
                self.cells(self.pending[:match.start()])
                self.cells(RESTORE[len(match[0]):])
                self.pending = suffix[len(RESTORE):]
                self.completed = ""
                continue
            self.cells(self.pending[:match.start()])
            self.pending = self.pending[match.end():]
            if match[1] == "h":
                assert not self.synchronized, "nested synchronized frame"
                self.synchronized = True
            else:
                self.synchronized = False
                self.cells(self.frame)
                self.frame = ""
                self.generation += 1
                self.completed = "\n".join(line.rstrip() for line in self.screen.display)
                self.completed_cells = [[self.screen.buffer[y][x] for x in range(self.screen.columns)]
                                        for y in range(self.screen.lines)]
                assert len(self.completed.encode()) < LIMIT
                if self.listener is not None:
                    self.listener(self.completed, self.screen.cursor.x, self.screen.cursor.y)

    def style(self, text, offset=0):
        """Committed cell `offset` characters into the first `text`, or None."""
        text = unicodedata.normalize("NFC", text)
        for row in self.completed_cells:
            # A wide character's trailing cell is empty; index drawn cells.
            drawn = [cell for cell in row if cell.data]
            starts, position = {}, 0
            for cell in drawn:
                starts[position] = cell
                position += len(cell.data)
            line = "".join(cell.data for cell in drawn)
            index = line.find(text)
            while index >= 0:
                if index in starts:
                    cell = starts[index]
                    for _ in range(offset):
                        index += len(cell.data)
                        cell = starts[index]
                    return cell
                index = line.find(text, index + 1)
        return None

    def reached(self, marker):
        return (not self.synchronized and self.generation > 0
                and unicodedata.normalize("NFC", marker) in self.completed)

    def draft(self, text, caret, *, prompt="› "):
        """Check the actual caret row, not an identical earlier User row."""
        cursor = self.screen.cursor
        return (not self.synchronized and self.generation > 0
                and "Opening…" not in self.completed
                and cursor.x == caret
                and self.screen.display[cursor.y].rstrip() == (prompt + unicodedata.normalize("NFC", text)).rstrip())
