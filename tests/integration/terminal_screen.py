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
RESTORE = "\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l"


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
        self.synchronized = False
        self.generation = 0

    def resize(self, columns, rows):
        assert 0 < columns <= 4096 and 0 < rows <= 512
        self.screen.resize(lines=rows, columns=columns)

    def cells(self, text):
        if self.synchronized:
            self.frame += text
            assert len(self.frame.encode()) < LIMIT, "unbounded terminal frame"
        else:
            # pyte does not implement the alternate-screen buffer.
            for part in re.split(r"(\x1b\[\?1049h)", text):
                if part == "\x1b[?1049h":
                    self.screen.reset()
                    self.completed = ""
                else:
                    self.stream.feed(part)

    def feed(self, data):
        self.pending += self.decoder.decode(data)
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
                assert len(self.completed.encode()) < LIMIT

    def reached(self, marker):
        return (not self.synchronized and self.generation > 0
                and unicodedata.normalize("NFC", marker) in self.completed)

    def draft(self, text, caret):
        """Check the actual caret row, not an identical earlier User row."""
        cursor = self.screen.cursor
        return (not self.synchronized and self.generation > 0
                and "Opening…" not in self.completed
                and cursor.x == caret
                and self.screen.display[cursor.y].rstrip() == ("› " + unicodedata.normalize("NFC", text)).rstrip())
