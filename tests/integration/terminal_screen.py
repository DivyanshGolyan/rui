import codecs
import collections
import ctypes
import itertools
import os
import re
import unicodedata
import weakref


HORIZONTAL_RULE = "┄"
VERTICAL_DIVIDER = "┆"
RULE_GLYPHS = (HORIZONTAL_RULE, "─", "-")
DIVIDER_GLYPHS = (VERTICAL_DIVIDER, "│", "|")
RULE_PATTERN = "[" + re.escape("".join(RULE_GLYPHS)) + "]"
DIVIDER_PATTERN = "[" + re.escape("".join(DIVIDER_GLYPHS)) + "]"

def split_pane_row(row, column=None):
    if column is not None:
        offset = 0
        for index, char in enumerate(row):
            if offset == column and char in DIVIDER_GLYPHS + ("┼", "┤", "+"):
                return row[:index], char, row[index + 1:]
            offset += 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
            if offset > column:
                break
        return "", "", row
    if row.startswith((" ›", " >")):
        return "", "", row
    rule = re.match(rf"^({RULE_PATTERN}{{2,}})([┼┤+])", row)
    if rule:
        return rule.group(1), rule.group(2), row[rule.end():]
    divider = min((index for glyph in DIVIDER_GLYPHS[:2] if (index := row.find(glyph)) >= 0), default=-1)
    column = 0
    for index, char in enumerate(row):
        if char == "|" and column == 40 and (divider < 0 or index < divider):
            divider = index
            break
        column += 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    if divider >= 0:
        return row[:divider], row[divider], row[divider + 1:]
    return "", "", row



LIMIT = 1024 * 1024
RESIZE_RESET = b"\x1b[H\x1b[m\x1b[J\x1b[?25l"
BOUNDARY = re.compile(rb"\x1b\[\?2026([hl])|" + re.escape(RESIZE_RESET))
MARKS = (b"\x1b[?2026h", b"\x1b[?2026l", RESIZE_RESET)
ALTERNATE = re.compile(r"(\x1b\[\?1049[hl])")
PLAIN_CONTROL = re.compile(r"\x1b\[[0-9;?$]*[A-Za-z~]|\x1b[()][A-Z0-9]|\r(?!\n)")
PLAIN_UNFINISHED = re.compile(r"\x1b(?:\[[0-9;?$]*|[()])?")
RESTORE = b"\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?25h\x1b[?1049l"

Cell = collections.namedtuple(
    "Cell", "data fg bold reverse bg italic faint underline strike invisible blink overline fg_rgb underline_rgb",
    defaults=(False, None, False, False, 0, False, False, False, False, None, None))
Cursor = collections.namedtuple("Cursor", "x y")
Screen = collections.namedtuple("Screen", "columns lines cursor display")

BACKGROUND = (0x28, 0x2c, 0x34)


class Frame(collections.namedtuple("Frame", "columns lines cursor visible cells background foreground cursor_color")):
    __slots__ = ()

    @property
    def text(self):
        return "\n".join("".join(cell.data for cell in row).rstrip() for row in self.cells)

    def colors(self, cell):
        fg, bg = cell.fg_rgb or self.foreground, cell.bg or self.background
        return (bg, fg) if cell.reverse else (fg, bg)


def shown(text, screen):
    pattern = "(?:\n *)?".join("(?: |\n *)" if c == " " else re.escape(c) for c in text)
    return re.search(pattern, screen) is not None


Handle = ctypes.c_void_p
WRITE_PTY = ctypes.CFUNCTYPE(None, Handle, Handle, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
COLOR_SCHEME = ctypes.CFUNCTYPE(ctypes.c_bool, Handle, Handle, ctypes.POINTER(ctypes.c_int))
OPT_USERDATA, OPT_WRITE_PTY, OPT_COLOR_SCHEME, OPT_COLOR_FOREGROUND, OPT_COLOR_BACKGROUND = 1, 2, 8, 12, 13
DATA_CURSOR_X, DATA_CURSOR_Y = 3, 4
STATE_DIRTY, STATE_ROW_ITERATOR = 3, 4
ROW_DIRTY, ROW_CELLS = 1, 3
CELL_RAW, CELL_STYLE, CELL_GRAPHEMES_UTF8 = 1, 2, 9
CELL_WIDE, WIDE_SPACER_TAIL = 3, 2
COLOR_PALETTE, COLOR_RGB = 1, 2
STYLE_BOLD, STYLE_INVERSE = 1, 1 << 4
OUT_OF_SPACE = -3


class Rgb(ctypes.Structure):
    _fields_ = [("r", ctypes.c_uint8), ("g", ctypes.c_uint8), ("b", ctypes.c_uint8)]


class MousePosition(ctypes.Structure):
    _fields_ = [("x", ctypes.c_float), ("y", ctypes.c_float)]


class MouseSize(ctypes.Structure):
    _fields_ = [("size", ctypes.c_size_t)] + [(name, ctypes.c_uint32) for name in
                ("width", "height", "cell_width", "cell_height", "top", "bottom", "right", "left")]


class StyleColor(ctypes.Structure):
    _fields_ = [("tag", ctypes.c_uint8), ("value", ctypes.c_uint8 * 3)]


class Style(ctypes.Structure):
    _fields_ = [("fg", StyleColor), ("bg", StyleColor), ("underline", StyleColor),
                ("flags", ctypes.c_uint16), ("reserved", ctypes.c_uint16)]


class Buffer(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("cap", ctypes.c_size_t), ("len", ctypes.c_size_t)]


_library = None


def library():
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
                ("ghostty_cell_get", [ctypes.c_uint64, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                ("ghostty_mouse_encoder_new", [Handle, ctypes.POINTER(Handle)], ctypes.c_int),
                ("ghostty_mouse_encoder_free", [Handle], None),
                ("ghostty_mouse_encoder_set", [Handle, ctypes.c_int, Handle], ctypes.c_int),
                ("ghostty_mouse_encoder_set_from_terminal", [Handle, Handle], ctypes.c_int),
                ("ghostty_mouse_encoder_encode", [Handle, Handle, Handle, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int),
                ("ghostty_mouse_event_new", [Handle, ctypes.POINTER(Handle)], ctypes.c_int),
                ("ghostty_mouse_event_free", [Handle], None),
                ("ghostty_mouse_event_set_action", [Handle, ctypes.c_int], ctypes.c_int),
                ("ghostty_mouse_event_set_button", [Handle, ctypes.c_int], ctypes.c_int),
                ("ghostty_mouse_event_set_position", [Handle, MousePosition], ctypes.c_int)):
            function = getattr(lib, name)
            function.argtypes, function.restype = arguments, result
        _library = lib
    return _library


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
    scheme[0] = _terminals[userdata].color_scheme
    return True


class ScreenCapture:

    def __init__(self, columns=80, rows=24, *, reply=None, background=None, foreground=None, color_scheme="dark"):
        if color_scheme not in ("dark", "light"):
            raise ValueError("color_scheme must be dark or light")
        self.color_scheme = 1 if color_scheme == "dark" else 0
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
        assert lib.ghostty_terminal_set(self.terminal, OPT_COLOR_BACKGROUND, ctypes.byref(Rgb(*(BACKGROUND if background is None else background)))) == 0
        if foreground is not None:
            assert lib.ghostty_terminal_set(self.terminal, OPT_COLOR_FOREGROUND, ctypes.byref(Rgb(*foreground))) == 0
        self.reply = reply
        self.replies = []
        self.grapheme = ctypes.create_string_buffer(64)
        self.columns, self.lines = columns, rows
        self.cells_by_row = [()] * rows
        self.view = None
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = b""
        self.text = ""
        self.completed = ""
        self.completed_cells = []
        self.frame = None
        self.synchronized = False
        self.generation = 0
        self.reset_generation = 0
        self.frame_reset_generation = 0
        self.listener = None
        self.received_bytes = 0
        self.alternate = False
        self.plain = ""
        self.plain_total = 0
        self.clipboard = []
        self.clipboard_pending = b""

    @property
    def screen(self):
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
        lib = library()
        get = lib.ghostty_render_state_row_cells_get
        cells, style, raw, wide = [], Style(), ctypes.c_uint64(), ctypes.c_int()
        def resolved(option):
            rgb = Rgb()
            result = get(self.row_cells, option, ctypes.byref(rgb))
            assert result in (0, -4), result
            return bytes(rgb).hex() if result == 0 else None

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
            underline = style.underline
            if underline.tag == COLOR_PALETTE:
                palette = (Rgb * 256)()
                assert lib.ghostty_render_state_get(self.state, 9, ctypes.byref(palette)) == 0
                underline_rgb = bytes(palette[underline.value[0]]).hex()
            else:
                underline_rgb = bytes(underline.value).hex() if underline.tag == COLOR_RGB else None
            flags = style.flags
            cells.append(Cell(data, fg, bool(flags & STYLE_BOLD), bool(flags & STYLE_INVERSE),
                              resolved(5), bool(flags & 2), bool(flags & 4), (flags >> 8) & 7,
                              bool(flags & 64), bool(flags & 32), bool(flags & 8), bool(flags & 128),
                              resolved(6), underline_rgb))
        assert len(cells) == self.columns, (len(cells), self.columns)
        return tuple(cells)

    def plain_since(self, total):
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
        library().ghostty_terminal_vt_write(self.terminal, data, len(data))
        if not self.synchronized:
            self.view = None
        self.answer()
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
        for _frame in self.feed_frames(data):
            pass

    def feed_frames(self, data):
        self.received_bytes += len(data)
        self.collect_clipboard(data)
        self.pending += data
        assert len(self.pending) < LIMIT, "unbounded terminal output"
        while True:
            match = BOUNDARY.search(self.pending)
            if match is None:
                held = max((length for mark in MARKS for length in range(1, min(len(mark), len(self.pending)) + 1)
                            if self.pending.endswith(mark[:length])), default=0)
                cut = len(self.pending) - held
                self.cells(self.pending[:cut])
                self.pending = self.pending[cut:]
                return
            if match[0] == RESIZE_RESET:
                self.cells(self.pending[:match.end()])
                self.pending = self.pending[match.end():]
                self.reset_generation += 1
                continue
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
                self.commit()
                yield self.frame

    def commit(self):
        assert not self.synchronized, "cannot commit an incomplete synchronized update"
        self.view = self.snapshot()
        lib = library()
        visible, background, foreground, cursor = ctypes.c_bool(), Rgb(), Rgb(), Rgb()
        assert lib.ghostty_render_state_get(self.state, 11, ctypes.byref(visible)) == 0
        assert lib.ghostty_render_state_get(self.state, 5, ctypes.byref(background)) == 0
        assert lib.ghostty_render_state_get(self.state, 6, ctypes.byref(foreground)) == 0
        result = lib.ghostty_render_state_get(self.state, 7, ctypes.byref(cursor))
        assert result in (0, -4), result
        self.frame = Frame(self.columns, self.lines, self.view.cursor, visible.value, tuple(self.cells_by_row),
                           bytes(background).hex(), bytes(foreground).hex(),
                           bytes(cursor).hex() if result == 0 else bytes(foreground).hex())
        self.frame_reset_generation = self.reset_generation
        self.generation += 1
        self.completed = self.frame.text
        self.completed_cells = list(self.frame.cells)
        assert len(self.completed.encode()) < LIMIT
        if self.listener is not None:
            self.listener(self.completed, self.view.cursor.x, self.view.cursor.y)

    def mouse(self, action, col, row, button="left", *, pressed=False):
        lib, encoder, event = library(), Handle(), Handle()
        assert lib.ghostty_mouse_encoder_new(None, ctypes.byref(encoder)) == 0
        try:
            assert lib.ghostty_mouse_event_new(None, ctypes.byref(event)) == 0
            assert lib.ghostty_mouse_encoder_set_from_terminal(encoder, self.terminal) == 0
            geometry = MouseSize(ctypes.sizeof(MouseSize), self.columns * 8, self.lines * 16, 8, 16, 0, 0, 0, 0)
            assert lib.ghostty_mouse_encoder_set(encoder, 3, ctypes.byref(geometry)) == 0
            held = ctypes.c_bool(pressed)
            assert lib.ghostty_mouse_encoder_set(encoder, 4, ctypes.byref(held)) == 0
            assert lib.ghostty_mouse_event_set_position(event, MousePosition(col * 8 + 4, row * 16 + 8)) == 0
            assert lib.ghostty_mouse_event_set_action(event, {"press": 0, "release": 1, "move": 2,
                                                            "wheel-up": 0, "wheel-down": 0}[action]) == 0
            identity = {"left": 1, "right": 2, "middle": 3}[button]
            if action.startswith("wheel-"):
                identity = 4 if action == "wheel-up" else 5
            if action != "move" or pressed:
                assert lib.ghostty_mouse_event_set_button(event, identity) == 0
            buf, length = ctypes.create_string_buffer(128), ctypes.c_size_t()
            assert lib.ghostty_mouse_encoder_encode(encoder, event, buf, len(buf), ctypes.byref(length)) == 0
            return buf.raw[:length.value]
        finally:
            lib.ghostty_mouse_event_free(event)
            lib.ghostty_mouse_encoder_free(encoder)

    def style(self, text, offset=0):
        text = unicodedata.normalize("NFC", text)
        for row in self.completed_cells:
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
        if self.synchronized or self.generation == 0:
            return False
        cursor = self.screen.cursor
        cells = self.completed_cells[cursor.y]
        row = "".join(cell.data for cell in cells[:cursor.x])
        sidebar, divider, _ = split_pane_row(row)
        remaining = len(sidebar) + len(divider)
        origin = 0
        if divider:
            for at, cell in enumerate(cells[:cursor.x]):
                remaining -= len(cell.data)
                if remaining <= 0:
                    origin = at + 1
                    break
        line = "".join(cell.data for cell in cells[origin:]).rstrip()
        margin = 1 if line.startswith(" ") and not prompt.startswith(" ") else 0
        matches = line[margin:] == (prompt + unicodedata.normalize("NFC", text)).rstrip()
        if not text and prompt in ("› ", "> ") and line[margin:] == prompt + "Type a task":
            mark = cells[origin + margin]
            start = origin + margin + len(prompt)
            matches = caret == len(prompt) and all(
                (cell.fg, cell.fg_rgb, cell.faint) != (mark.fg, mark.fg_rgb, mark.faint)
                for cell in cells[start:start + len("Type a task")])
        return (not self.synchronized and self.generation > 0
                and "Opening…" not in self.completed
                and cursor.x - origin == caret + margin
                and matches)
