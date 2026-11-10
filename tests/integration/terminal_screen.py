"""Bounded committed-screen observer for the explicitly selected renderer suite.

libghostty-vt owns terminal cells and answers the program's queries; frame
delimiters establish repaint completion, not submission or consent readiness.
Exact input is checked at the Host separately.
"""
import codecs
import collections
import ctypes
import itertools
import os
import re
import unicodedata
import weakref


LIMIT = 1024 * 1024
BOUNDARY = re.compile(rb"\x1b\[\?2026([hl])")
MARKS = (b"\x1b[?2026h", b"\x1b[?2026l")
ALTERNATE = re.compile(r"(\x1b\[\?1049[hl])")
PLAIN_CONTROL = re.compile(r"\x1b\[[0-9;?$]*[A-Za-z~]|\x1b[()][A-Z0-9]|\r(?!\n)")
PLAIN_UNFINISHED = re.compile(r"\x1b(?:\[[0-9;?$]*|[()])?")
RESTORE = b"\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?25h\x1b[?1049l"

# One drawn cell. `data` is its grapheme in NFC, " " where nothing was drawn
# and "" for a wide character's second cell; `fg` is None for the default
# foreground, a palette index, or "rrggbb".
Cell = collections.namedtuple("Cell", "data fg bold")
Cursor = collections.namedtuple("Cursor", "x y")
# The screen as it stands outside a synchronized frame: `display` holds one
# string per row, a character per drawn cell.
Screen = collections.namedtuple("Screen", "columns lines cursor display")

# The profile the observer's terminal answers queries with: Ghostty's default
# dark background, reported to OSC 11 and as a dark scheme to CSI ? 996 n.
BACKGROUND = (0x28, 0x2c, 0x34)


def shown(text, screen):
    """`text` appears on `screen` even where rows broke it: inside a long word
    the frame breaks between characters; at a space, word wrap drops it. A
    row continued under an indented line's text starts with that indent."""
    pattern = "(?:\n *)?".join("(?: |\n *)" if c == " " else re.escape(c) for c in text)
    return re.search(pattern, screen) is not None


# libghostty-vt 1.0's C ABI, as include/ghostty/vt/*.h declares it.
Handle = ctypes.c_void_p
WRITE_PTY = ctypes.CFUNCTYPE(None, Handle, Handle, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
COLOR_SCHEME = ctypes.CFUNCTYPE(ctypes.c_bool, Handle, Handle, ctypes.POINTER(ctypes.c_int))
OPT_USERDATA, OPT_WRITE_PTY, OPT_COLOR_SCHEME, OPT_COLOR_BACKGROUND = 1, 2, 8, 13
DATA_CURSOR_X, DATA_CURSOR_Y = 3, 4
STATE_DIRTY, STATE_ROW_ITERATOR = 3, 4
ROW_DIRTY, ROW_CELLS = 1, 3
CELL_RAW, CELL_STYLE, CELL_GRAPHEMES_UTF8 = 1, 2, 9
CELL_WIDE, WIDE_SPACER_TAIL = 3, 2
COLOR_PALETTE, COLOR_RGB = 1, 2
STYLE_BOLD = 1
OUT_OF_SPACE = -3


class Rgb(ctypes.Structure):
    _fields_ = [("r", ctypes.c_uint8), ("g", ctypes.c_uint8), ("b", ctypes.c_uint8)]


class StyleColor(ctypes.Structure):
    _fields_ = [("tag", ctypes.c_uint8), ("value", ctypes.c_uint8 * 3)]


class Style(ctypes.Structure):
    _fields_ = [("fg", StyleColor), ("bg", StyleColor), ("underline", StyleColor),
                ("flags", ctypes.c_uint16), ("reserved", ctypes.c_uint16)]


class Buffer(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("cap", ctypes.c_size_t), ("len", ctypes.c_size_t)]


_library = None


def library():
    """The shared library build.zig names in RUI_TEST_GHOSTTY_VT."""
    global _library
    if _library is None:
        path = os.environ.get("RUI_TEST_GHOSTTY_VT")
        assert path, "RUI_TEST_GHOSTTY_VT names no libghostty-vt; run the fixture through its zig build step"
        lib = ctypes.CDLL(path)
        for name, arguments, result in (
                ("ghostty_terminal_new", [Handle, ctypes.POINTER(Handle), ctypes.c_uint16, ctypes.c_uint16], ctypes.c_int),
                ("ghostty_terminal_free", [Handle], None),
                ("ghostty_terminal_set", [Handle, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                ("ghostty_terminal_get", [Handle, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                ("ghostty_terminal_vt_write", [Handle, ctypes.c_char_p, ctypes.c_size_t], None),
                ("ghostty_terminal_resize", [Handle, ctypes.c_uint16, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_uint32], ctypes.c_int),
                ("ghostty_render_state_new", [Handle, ctypes.POINTER(Handle)], ctypes.c_int),
                ("ghostty_render_state_free", [Handle], None),
                ("ghostty_render_state_update", [Handle, Handle], ctypes.c_int),
                ("ghostty_render_state_get", [Handle, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                ("ghostty_render_state_clean", [Handle], ctypes.c_int),
                ("ghostty_render_state_row_iterator_new", [Handle, ctypes.POINTER(Handle)], ctypes.c_int),
                ("ghostty_render_state_row_iterator_free", [Handle], None),
                ("ghostty_render_state_row_iterator_next", [Handle], ctypes.c_bool),
                ("ghostty_render_state_row_get", [Handle, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                ("ghostty_render_state_row_cells_new", [Handle, ctypes.POINTER(Handle)], ctypes.c_int),
                ("ghostty_render_state_row_cells_free", [Handle], None),
                ("ghostty_render_state_row_cells_next", [Handle], ctypes.c_bool),
                ("ghostty_render_state_row_cells_get", [Handle, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                ("ghostty_cell_get", [ctypes.c_uint64, ctypes.c_int, ctypes.c_void_p], ctypes.c_int)):
            function = getattr(lib, name)
            function.argtypes, function.restype = arguments, result
        _library = lib
    return _library


# Each live capture, by the userdata its terminal passes to callbacks. The
# registry does not own them: a capture nobody holds is collected, and its
# finalizer frees its native terminal.
_terminals = weakref.WeakValueDictionary()
_keys = itertools.count(1)


def _free(lib, terminal, state, rows_iterator, row_cells):
    lib.ghostty_render_state_row_cells_free(row_cells)
    lib.ghostty_render_state_row_iterator_free(rows_iterator)
    lib.ghostty_render_state_free(state)
    lib.ghostty_terminal_free(terminal)


@WRITE_PTY
def _write_pty(terminal, userdata, data, length):
    _terminals[userdata].replies.append(ctypes.string_at(data, length))


@COLOR_SCHEME
def _color_scheme(terminal, userdata, scheme):
    scheme[0] = 1  # Dark, matching BACKGROUND.
    return True


class ScreenCapture:
    """`reply` takes each answer the terminal gives a query, to write to the
    PTY the query came from; None drops them, for a silent terminal."""

    def __init__(self, columns=80, rows=24, *, reply=None):
        lib = library()
        self.terminal, self.state = Handle(), Handle()
        self.rows_iterator, self.row_cells = Handle(), Handle()
        assert lib.ghostty_terminal_new(None, ctypes.byref(self.terminal), columns, rows) == 0
        for create, handle in ((lib.ghostty_render_state_new, self.state),
                               (lib.ghostty_render_state_row_iterator_new, self.rows_iterator),
                               (lib.ghostty_render_state_row_cells_new, self.row_cells)):
            assert create(None, ctypes.byref(handle)) == 0
        self.free = weakref.finalize(self, _free, lib, self.terminal, self.state, self.rows_iterator, self.row_cells)
        self.key = next(_keys)
        _terminals[self.key] = self
        assert lib.ghostty_terminal_set(self.terminal, OPT_USERDATA, self.key) == 0
        assert lib.ghostty_terminal_set(self.terminal, OPT_WRITE_PTY, ctypes.cast(_write_pty, ctypes.c_void_p)) == 0
        assert lib.ghostty_terminal_set(self.terminal, OPT_COLOR_SCHEME, ctypes.cast(_color_scheme, ctypes.c_void_p)) == 0
        assert lib.ghostty_terminal_set(self.terminal, OPT_COLOR_BACKGROUND, ctypes.byref(Rgb(*BACKGROUND))) == 0
        self.reply = reply
        self.replies = []
        self.grapheme = ctypes.create_string_buffer(64)
        self.columns, self.lines = columns, rows
        self.cells_by_row = [()] * rows
        self.view = None  # The Screen, until the terminal next changes.
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = b""
        self.text = ""  # Decoded output not yet routed to `plain`.
        self.completed = ""
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
        # Each complete OSC 52 sequence, as written: the copy oracles check
        # its exact bytes, which the terminal's clipboard effect decodes.
        self.clipboard = []
        self.clipboard_pending = b""

    @property
    def screen(self):
        """The screen outside a frame; within one, as the frame found it."""
        if self.view is None:
            self.view = self.snapshot()
        return self.view

    def snapshot(self):
        lib = library()
        assert lib.ghostty_render_state_update(self.state, self.terminal) == 0
        dirty = ctypes.c_int()
        assert lib.ghostty_render_state_get(self.state, STATE_DIRTY, ctypes.byref(dirty)) == 0
        if dirty.value or () in self.cells_by_row:
            assert lib.ghostty_render_state_get(self.state, STATE_ROW_ITERATOR, ctypes.byref(self.rows_iterator)) == 0
            changed, y = ctypes.c_bool(), 0
            while lib.ghostty_render_state_row_iterator_next(self.rows_iterator):
                assert lib.ghostty_render_state_row_get(self.rows_iterator, ROW_DIRTY, ctypes.byref(changed)) == 0
                if changed.value or not self.cells_by_row[y]:
                    assert lib.ghostty_render_state_row_get(self.rows_iterator, ROW_CELLS, ctypes.byref(self.row_cells)) == 0
                    self.cells_by_row[y] = self.row()
                y += 1
            assert y == self.lines, (y, self.lines)
            assert lib.ghostty_render_state_clean(self.state) == 0
        x, y = ctypes.c_uint16(), ctypes.c_uint16()
        assert lib.ghostty_terminal_get(self.terminal, DATA_CURSOR_X, ctypes.byref(x)) == 0
        assert lib.ghostty_terminal_get(self.terminal, DATA_CURSOR_Y, ctypes.byref(y)) == 0
        display = ["".join(cell.data for cell in row) for row in self.cells_by_row]
        return Screen(self.columns, self.lines, Cursor(x.value, y.value), display)

    def row(self):
        """The cells of the row the render state's cell iterator holds."""
        lib = library()
        get = lib.ghostty_render_state_row_cells_get
        cells, style, raw, wide = [], Style(), ctypes.c_uint64(), ctypes.c_int()
        while lib.ghostty_render_state_row_cells_next(self.row_cells):
            text = Buffer(ctypes.cast(self.grapheme, ctypes.c_void_p), len(self.grapheme), 0)
            result = get(self.row_cells, CELL_GRAPHEMES_UTF8, ctypes.byref(text))
            if result == OUT_OF_SPACE:
                self.grapheme = ctypes.create_string_buffer(text.len)
                text = Buffer(ctypes.cast(self.grapheme, ctypes.c_void_p), len(self.grapheme), 0)
                result = get(self.row_cells, CELL_GRAPHEMES_UTF8, ctypes.byref(text))
            assert result == 0, result
            if text.len:
                data = unicodedata.normalize("NFC", self.grapheme.raw[:text.len].decode())
            else:
                assert get(self.row_cells, CELL_RAW, ctypes.byref(raw)) == 0
                assert lib.ghostty_cell_get(raw.value, CELL_WIDE, ctypes.byref(wide)) == 0
                data = "" if wide.value == WIDE_SPACER_TAIL else " "
            assert get(self.row_cells, CELL_STYLE, ctypes.byref(style)) == 0
            colour = style.fg
            fg = (colour.value[0] if colour.tag == COLOR_PALETTE
                  else bytes(colour.value).hex() if colour.tag == COLOR_RGB else None)
            cells.append(Cell(data, fg, bool(style.flags & STYLE_BOLD)))
        assert len(cells) == self.columns, (len(cells), self.columns)
        return tuple(cells)

    def plain_since(self, total):
        """Main-screen text written after `plain_total` was `total`."""
        return self.plain[max(0, len(self.plain) - (self.plain_total - total)):]

    def resize(self, columns, rows):
        assert 0 < columns <= 4096 and 0 < rows <= 512
        assert library().ghostty_terminal_resize(self.terminal, columns, rows, 8, 16) == 0
        self.columns, self.lines = columns, rows
        self.cells_by_row = [()] * rows
        self.view = None
        self.answer()

    def answer(self):
        replies, self.replies = self.replies, []
        if self.reply is not None:
            for data in replies:
                self.reply(data)

    def cells(self, data):
        """Write `data` to the terminal; route main-screen text to `plain`."""
        library().ghostty_terminal_vt_write(self.terminal, data, len(data))
        if not self.synchronized:
            self.view = None
        self.answer()
        # A control split across writes completes in the next one.
        self.text += self.decoder.decode(data)
        cut = self.text.rfind("\x1b")
        if cut < 0 or not PLAIN_UNFINISHED.fullmatch(self.text[cut:]):
            cut = len(self.text)
        text, self.text = self.text[:cut], self.text[cut:]
        for part in ALTERNATE.split(text):
            if part == "\x1b[?1049h":
                self.completed = ""
                self.alternate = True
            elif part == "\x1b[?1049l":
                self.alternate = False
            elif not self.alternate:
                # Main-screen text (before entry or after restoration),
                # such as diagnostics and detach notices, is a stream.
                visible = PLAIN_CONTROL.sub("", part).replace("\r\n", "\n")
                self.plain = (self.plain + visible)[-LIMIT // 4:]
                self.plain_total += len(visible)

    def collect_clipboard(self, data):
        self.clipboard_pending += data
        while True:
            start = self.clipboard_pending.find(b"\x1b]52;")
            if start < 0:
                self.clipboard_pending = self.clipboard_pending[-4:]
                return
            end = self.clipboard_pending.find(b"\x1b\\", start)
            if end < 0:
                self.clipboard_pending = self.clipboard_pending[start:]
                assert len(self.clipboard_pending) < LIMIT, "unbounded clipboard sequence"
                return
            self.clipboard.append(self.clipboard_pending[start:end + 2].decode())
            self.clipboard_pending = self.clipboard_pending[end + 2:]

    def feed(self, data):
        self.received_bytes += len(data)
        self.collect_clipboard(data)
        self.pending += data
        assert len(self.pending) < LIMIT, "unbounded terminal output"
        while True:
            match = BOUNDARY.search(self.pending)
            if match is None:
                # Hold back only a frame mark's start: a complete query
                # must reach the terminal, which answers it, now.
                cut = self.pending.rfind(b"\x1b")
                if cut < 0 or not any(mark.startswith(self.pending[cut:]) for mark in MARKS):
                    cut = len(self.pending)
                self.cells(self.pending[:cut])
                self.pending = self.pending[cut:]
                return
            if match[1] == b"l" and not self.synchronized:
                suffix = self.pending[match.start():]
                if RESTORE.startswith(suffix) and len(suffix) < len(RESTORE):
                    self.cells(self.pending[:match.start()])
                    self.pending = suffix
                    return
                assert suffix.startswith(RESTORE), "frame end without frame start"
                self.cells(self.pending[:match.start() + len(RESTORE)])
                self.pending = suffix[len(RESTORE):]
                self.completed = ""
                continue
            self.cells(self.pending[:match.end()])
            self.pending = self.pending[match.end():]
            if match[1] == b"h":
                assert not self.synchronized, "nested synchronized frame"
                self.view = self.snapshot()
                self.synchronized = True
            else:
                self.synchronized = False
                self.view = self.snapshot()
                self.generation += 1
                self.completed = "\n".join(line.rstrip() for line in self.view.display)
                self.completed_cells = list(self.cells_by_row)
                assert len(self.completed.encode()) < LIMIT
                if self.listener is not None:
                    self.listener(self.completed, self.view.cursor.x, self.view.cursor.y)

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
