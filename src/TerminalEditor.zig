const std = @import("std");
const Editor = @This();
const termios = @import("posix");
const vaxis = @import("vaxis");
const Input = @import("TerminalInput.zig");

extern fn utf8proc_grapheme_break_stateful(c_int, c_int, *c_int) c_int;
extern fn utf8proc_category(c_int) c_int;

buffer: []u8,
length: usize = 0,
cursor: usize = 0,
partial: [4]u8 = undefined,
partial_length: u3 = 0,
partial_need: u3 = 0,
allow_paste: bool = true,
rejected: ?Event = null,
plain_ascii: bool = true,
paste_start: struct { cursor: usize = 0, length: usize = 0, plain_ascii: bool = true } = .{},
/// This editor saw the current marked paste begin. A replacement editor
/// receiving the rest of a paste rejects it rather than adopting it.
pasting: bool = false,

/// Navigation events leave the draft unchanged. Up/Down beyond the draft's
/// first/last line scroll the transcript; terminals in the alternate screen
/// also deliver mouse wheel and trackpad scrolling as these arrow keys.
pub const Event = enum { none, append, redraw, submit, eof, interrupt, invalid, edit_rejected, unbound, overflow, page_up, page_down, scroll_up, scroll_down, latest, close_view, expand };

/// Enter ends a line as `submit`, or as the rejection that withheld it;
/// end of input and interrupt end it too.
pub fn endsLine(event: Event) bool {
    return switch (event) {
        .submit, .invalid, .overflow, .eof, .interrupt => true,
        else => false,
    };
}

pub const Pending = Input.Pending;
const paste_end = "\x1b[201~";

// libc's termios is not the Linux kernel ABI used by std.posix.termios.
// Keep the native type at this boundary, including speeds and all cc entries.
pub const Attributes = termios.struct_termios;

pub fn getAttributes() std.posix.TermiosGetError!Attributes {
    var attributes: Attributes = undefined;
    while (true) switch (std.posix.errno(termios.tcgetattr(0, &attributes))) {
        .SUCCESS => return attributes,
        .INTR => {},
        .BADF => unreachable,
        .NOTTY => return error.NotATerminal,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

pub fn setAttributes(action: std.posix.TCSA, attributes: Attributes) std.posix.TermiosSetError!void {
    while (true) switch (std.posix.errno(termios.tcsetattr(0, @intCast(@backingInt(action)), &attributes))) {
        .SUCCESS => return,
        .INTR => {},
        .BADF, .INVAL => unreachable,
        .NOTTY => return error.NotATerminal,
        .IO => return error.ProcessOrphaned,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

/// Literal command-line text is not keyboard input or a permission choice.
pub fn validateText(bytes: []const u8) !void {
    var characters = (try std.unicode.Utf8View.init(bytes)).iterator();
    while (characters.nextCodepoint()) |point| {
        if (!validScalar(point, true)) return error.InvalidTerminalInput;
    }
}

fn validScalar(point: u21, multiline: bool) bool {
    return !((point < 32 and !(point == '\t' or (multiline and point == '\n'))) or
        (point >= 0x7f and point < 0xa0) or
        (utf8proc_category(@intCast(point)) == 27 and point != 0x200d));
}

/// Returns a slice borrowed from buffer until its caller next reuses it.
/// No draft, terminal mode or buffered input survives a prompt.
pub fn readLine(io: std.Io, buffer: []u8, prompt: []const u8, allow_paste: bool) !?[]const u8 {
    const original = try getAttributes();
    var mode = original;
    mode.c_lflag &= ~@as(termios.tcflag_t, termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN);
    mode.c_iflag &= ~@as(termios.tcflag_t, termios.IXON);
    mode.c_cc[termios.VMIN] = 1;
    mode.c_cc[termios.VTIME] = 0;
    try setAttributes(.FLUSH, mode);

    // Always attempt both effects, even when rendering or input fails. Do
    // not return an accepted line if either cleanup step is unconfirmed.
    const result = drive(io, buffer, prompt, allow_paste);
    const disabled: anyerror!void = blk: {
        std.Io.File.stdout().writeStreamingAll(io, "\x1b[?2004l") catch |err| break :blk err;
        // Input and output may be different terminals. Confirm transmission
        // on stdout before releasing this prompt's accepted input.
        while (true) switch (std.posix.errno(termios.tcdrain(1))) {
            .SUCCESS => break :blk,
            .INTR => {},
            else => break :blk error.TerminalCleanupFailed,
        };
    };
    // Discard this prompt's queued input before restoring exact attributes.
    // NOW also leaves Darwin's PENDIN set when re-entering canonical mode.
    const restored = setAttributes(.FLUSH, original);
    restored catch return error.TerminalRestoreFailed;
    disabled catch return error.TerminalCleanupFailed;
    return try result;
}

/// Complete presentation, then discard pre-prompt input before consent.
pub fn freshChoice(io: std.Io) !void {
    if (termios.tcdrain(1) != 0 or termios.tcflush(0, termios.TCIFLUSH) != 0) return error.TerminalFlushFailed;
    try testChoiceReady(io);
}

pub fn testChoiceReady(io: std.Io) !void {
    // Borrowed fixture descriptor witnesses the completed input boundary.
    if (std.c.getenv("RUI_TEST_ACTION_READY_FD")) |text| {
        const fd = try std.fmt.parseInt(std.posix.fd_t, std.mem.span(text), 10);
        const ready: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        try ready.writeStreamingAll(io, "x");
    }
}

fn drive(io: std.Io, buffer: []u8, prompt: []const u8, allow_paste: bool) !?[]const u8 {
    const output = std.Io.File.stdout();
    try output.writeStreamingAll(io, "\x1b[?2004h");
    try output.writeStreamingAll(io, prompt);
    if (!allow_paste) {
        // The provider choice must come after its complete fresh prompt,
        // never from queued input or a marked paste.
        try freshChoice(io);
    }
    var editor: Editor = .{ .buffer = buffer, .allow_paste = allow_paste };
    var input: Input = .{};
    const initial_size = windowSize();
    var plain_prompt = true;
    for (prompt) |char| {
        if (char < 32 or char > 126) plain_prompt = false;
    }
    var backspaces: usize = 0;
    var repaint_deadline: i96 = 0;
    while (true) {
        if (backspaces != 0) {
            const remaining = repaint_deadline - std.Io.Clock.awake.now(io).nanoseconds;
            if (remaining <= 0 or backspaces == editor.length) {
                try paintTailDeletion(io, &editor, backspaces, prompt, initial_size);
                backspaces = 0;
                continue;
            }
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, @intCast(@divTrunc(remaining + 999_999, 1_000_000))) == 0) {
                try paintTailDeletion(io, &editor, backspaces, prompt, initial_size);
                backspaces = 0;
                continue;
            }
        }
        if (input.pending() != .none) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            // Only bare ESC is ambiguous with a standalone key. A recognized
            // sequence, scalar or marked paste may arrive fragmented.
            if (try std.posix.poll(&fds, if (input.pending() == .escape) 80 else 2000) == 0) {
                _ = input.expire() catch |err| {
                    try output.writeStreamingAll(io, "\n");
                    return err;
                };
                continue;
            }
        }
        var byte: [1]u8 = undefined;
        if (try std.posix.read(0, &byte) == 0) {
            if (backspaces != 0) try paintTailDeletion(io, &editor, backspaces, prompt, initial_size);
            return if (editor.length == 0) null else error.IncompleteTerminalLine;
        }
        if ((byte[0] == 8 or byte[0] == 127) and input.pending() == .none and editor.rejected == null and editor.cursor == editor.length and editor.length != 0) {
            // The last printable ASCII cell has a known width. Clear it in
            // place even when key repeats arrive slower than the batch window.
            const current_size = windowSize();
            if (backspaces == 0 and plain_prompt and editor.plain_ascii and initial_size.row >= 2 and
                prompt.len + editor.length < initial_size.col and
                current_size.col == initial_size.col and current_size.row == initial_size.row)
            {
                editor.deleteTail(1);
                try output.writeStreamingAll(io, "\x08\x1b[0K");
                continue;
            }
            if (backspaces == 0) repaint_deadline = std.Io.Clock.awake.now(io).nanoseconds + 16_000_000;
            backspaces += 1;
            continue;
        }
        if (backspaces != 0) {
            try paintTailDeletion(io, &editor, backspaces, prompt, initial_size);
            backspaces = 0;
        }
        const may_edit = editor.cursor != editor.length or input.pending() != .none or byte[0] == 0x1b or
            std.mem.indexOfScalar(u8, "\x01\x04\x05\x08\x0b\x15\x17\x7f", byte[0]) != null;
        const old_row = if (may_edit) visibleRow(&editor, prompt.len, initial_size) else null;
        const old_length = editor.length;
        const event = editor.feed(&input, byte[0]);
        switch (event) {
            // The prompt is a one-letter choice; a dropped chord leaves it as typed.
            .none, .unbound, .page_up, .page_down, .scroll_up, .scroll_down, .latest, .close_view, .expand => {},
            .append => try output.writeStreamingAll(io, editor.buffer[old_length..editor.length]),
            .redraw => try redraw(io, &editor, prompt, initial_size, old_row),
            .submit => {
                try output.writeStreamingAll(io, "\n");
                return editor.buffer[0..editor.length];
            },
            .eof => {
                try output.writeStreamingAll(io, "\n");
                return null;
            },
            .interrupt => {
                try output.writeStreamingAll(io, "^C\n");
                return error.InteractiveInterrupted;
            },
            .invalid => {
                try output.writeStreamingAll(io, "\n");
                return error.InvalidTerminalInput;
            },
            .edit_rejected => unreachable, // The inline editor does not decline renderer-only edits.
            .overflow => {
                try output.writeStreamingAll(io, "\n");
                return error.StreamTooLong;
            },
        }
    }
}

fn paintTailDeletion(io: std.Io, editor: *Editor, count: usize, prompt: []const u8, size: std.posix.winsize) !void {
    const old_row = visibleRow(editor, prompt.len, size);
    editor.deleteTail(count);
    try redraw(io, editor, prompt, size, old_row);
}

fn redraw(io: std.Io, editor: *const Editor, prompt: []const u8, size: std.posix.winsize, old_row: ?usize) !void {
    const output = std.Io.File.stdout();
    if (old_row == null or windowSize().col != size.col or windowSize().row != size.row or
        visibleRow(editor, prompt.len, size) == null)
    {
        try output.writeStreamingAll(io, "\n");
        return error.UncertainTerminalCursor;
    }
    // Repaint only while each row is known not to wrap. The terminal positions
    // the cursor when it paints Unicode; grapheme counts are not cell counts.
    var control: [32]u8 = undefined;
    if (old_row.? != 0) try output.writeStreamingAll(io, try std.fmt.bufPrint(&control, "\x1b[{d}A", .{old_row.?}));
    try output.writeStreamingAll(io, "\r\x1b[0J");
    try output.writeStreamingAll(io, prompt);
    try output.writeStreamingAll(io, editor.buffer[0..editor.cursor]);
    try output.writeStreamingAll(io, "\x1b7");
    try output.writeStreamingAll(io, editor.buffer[editor.cursor..editor.length]);
    try output.writeStreamingAll(io, "\x1b8");
}

fn windowSize() std.posix.winsize {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(1, @intCast(std.c.T.IOCGWINSZ), &size) != 0) size.row = 0;
    return size;
}

fn visibleRow(editor: *const Editor, prompt_size: usize, size: std.posix.winsize) ?usize {
    if (size.row < 2 or size.col <= prompt_size or editor.partial_length != 0) return null;
    var row: usize = 0;
    var column = prompt_size;
    for (editor.buffer[0..editor.length]) |byte| {
        if (byte == '\t') return null;
        if (byte == '\n') {
            row += 1;
            column = 0;
        } else {
            column += 1; // UTF-8 byte count is a conservative cell upper bound.
            if (column >= size.col) return null;
        }
        if (row >= size.row) return null;
    }
    row = 0;
    for (editor.buffer[0..editor.cursor]) |byte| if (byte == '\n') {
        row += 1;
    };
    return row;
}

/// Applies one decoded event from the invocation's terminal stream. The
/// stream, not this editor, owns parsing, paste provenance and partial input,
/// so replacing an editor never loses or reinterprets terminal bytes.
pub fn apply(self: *Editor, decoded: Input.Decoded) Event {
    const value = switch (decoded) {
        .none, .report => return .none,
        .invalid => |invalid| {
            self.reject(.invalid);
            return if (invalid.line_end) .invalid else .none;
        },
        .event => |value| value,
    };
    return switch (value.event) {
        .paste_start => blk: {
            if (value.pasted or !self.allow_paste) self.reject(.invalid);
            if (!value.pasted) self.paste_start = .{ .cursor = self.cursor, .length = self.length, .plain_ascii = self.plain_ascii };
            self.pasting = true;
            break :blk .none;
        },
        .paste_end => blk: {
            if (!value.pasted or !self.pasting) self.reject(.invalid);
            self.pasting = false;
            if (self.rejected == .edit_rejected) {
                self.rejected = null;
                break :blk .edit_rejected;
            }
            break :blk .none;
        },
        .key_press => |key_value| self.key(key_value, value.pasted),
        else => .none,
    };
}

/// One byte through `input` and every event it completes, for a lone editor
/// (line prompts and tests). Returns the last event that is not `.none`.
pub fn feed(self: *Editor, input: *Input, byte: u8) Event {
    var last: Event = .none;
    var decoded = input.feed(byte);
    while (decoded != .none) : (decoded = input.next()) {
        const event = self.apply(decoded);
        if (event != .none) last = event;
    }
    return last;
}

fn reject(self: *Editor, reason: Event) void {
    if (self.rejected == null) self.rejected = reason;
}

fn key(self: *Editor, value: vaxis.Key, pasted_input: bool) Event {
    const Key = vaxis.Key;
    if (pasted_input) {
        if (!self.pasting) {
            self.reject(.invalid);
            return .none;
        }
        if (value.matchExact('j', .{ .ctrl = true })) return self.insert('\n', true);
        if (value.matchExact(Key.tab, .{})) return self.insert('\t', true);
        if (value.text) |text| return self.insertText(text, true);
        self.reject(.invalid);
        return .none;
    }
    // Every binding matches exact modifiers. Vaxis's looser match accepts a
    // key's associated text or shifted key and drops Shift, so Ctrl-Shift-J
    // with text j would send and Shift-Enter with text CR would too.
    if (value.matchExact('c', .{ .ctrl = true })) return .interrupt;
    if (value.matchExact('d', .{ .ctrl = true })) return if (self.length == 0) .eof else self.deleteNext();
    if (value.matchExact(Key.enter, .{}) or value.matchExact('j', .{ .ctrl = true })) return self.rejected orelse .submit;
    if (self.rejected != null) return .none;
    // A CSI-u report (Kitty or tmux extended keys) can name Alt-Escape;
    // it still means Esc. Legacy ESC ESC already decodes as Esc.
    if (value.matchExact(Key.escape, .{}) or value.matchExact(Key.escape, .{ .alt = true })) return .close_view;
    if (value.matchExact(Key.tab, .{})) return self.insert('\t', false);
    // Alt-Enter adds a line in every form: Ghostty and other terminals send
    // Shift-Enter as ESC CR, which decodes exactly as Kitty's Alt-Enter.
    if (value.matchExact(Key.enter, .{ .shift = true }) or value.matchExact(Key.enter, .{ .alt = true }) or value.matchExact('j', .{ .alt = true })) return self.insert('\n', true);
    if (value.matchExact(Key.page_up, .{}) or value.matchExact(Key.page_up, .{ .shift = true })) return .page_up;
    if (value.matchExact(Key.page_down, .{}) or value.matchExact(Key.page_down, .{ .shift = true })) return .page_down;
    if (value.matchExact(Key.up, .{ .shift = true })) return .scroll_up;
    if (value.matchExact(Key.down, .{ .shift = true })) return .scroll_down;
    if (value.matchExact(Key.end, .{ .ctrl = true })) return .latest;
    if (value.matchExact('g', .{ .ctrl = true })) return .close_view;
    if (value.matchExact('o', .{ .ctrl = true })) return .expand;
    if (value.matchExact(Key.left, .{})) return self.move(self.previous(self.cursor));
    if (value.matchExact(Key.right, .{})) return self.move(self.next(self.cursor));
    if (value.matchExact(Key.up, .{})) return self.vertical(false) orelse .scroll_up;
    if (value.matchExact(Key.down, .{})) return self.vertical(true) orelse .scroll_down;
    if (value.matchExact(Key.home, .{}) or value.matchExact('a', .{ .ctrl = true })) return self.move(self.lineStart());
    // With nothing to edit, End returns to the latest view like Ctrl-G.
    if (value.matchExact(Key.end, .{}) and self.length == 0) return .close_view;
    if (value.matchExact(Key.end, .{}) or value.matchExact('e', .{ .ctrl = true })) return self.move(self.lineEnd());
    if (value.matchExact(Key.delete, .{})) return self.deleteNext();
    if (value.matchExact(Key.backspace, .{})) return self.deletePrevious();
    if (value.matchExact('u', .{ .ctrl = true })) return self.deleteTo(self.lineStart());
    if (value.matchExact('k', .{ .ctrl = true })) return self.deleteTo(self.lineEnd());
    if (value.matchExact('w', .{ .ctrl = true })) return self.backwardWord(true);
    if (value.matchExact(Key.backspace, .{ .alt = true }) or value.matchExact(127, .{ .alt = true })) return self.backwardWord(false);
    if (value.matchExact('b', .{ .alt = true }) or value.matchExact(Key.left, .{ .alt = true })) return self.moveWord(false);
    if (value.matchExact('f', .{ .alt = true }) or value.matchExact(Key.right, .{ .alt = true })) return self.moveWord(true);
    // Any Alt, Super, Hyper or Meta chord the bindings above do not consume,
    // on a character, a control or a named key such as Enter, is dropped
    // whole and reported. Its bare key (ESC . as ".", ESC ^A as Ctrl-A) was
    // never typed, and the draft around it was: an Esc pressed just before
    // a key arrives as one chord.
    if (value.mods.alt or value.mods.super or value.mods.hyper or value.mods.meta) return .unbound;
    // Vaxis represents C0 controls as Ctrl keys or textless Kitty codepoints;
    // those are not text, so an unbound one rejects the input.
    const control = value.codepoint < 0x20 and value.codepoint != Key.enter and value.codepoint != Key.tab and value.codepoint != Key.escape;
    if (value.mods.ctrl or control) {
        self.reject(.invalid);
        return .none;
    }
    if (!validScalar(value.codepoint, false)) {
        self.reject(.invalid);
        return .none;
    }
    if (value.text) |text| return self.insertText(text, false);
    return .none;
}

test "modified kitty text cannot become an ordinary permission choice" {
    var storage: [64]u8 = undefined;
    for ([_]u8{ 3, 9, 17, 33, 57 }) |modifier| {
        for ([_][]const u8{ "", ";97" }) |text| {
            var sequence: [32]u8 = undefined;
            const input = try std.fmt.bufPrint(&sequence, "\x1b[97;{d}{s}u", .{ modifier, text });
            var editor: Editor = .{ .buffer = &storage, .allow_paste = false };
            var stream: Input = .{};
            var event: Event = .none;
            for (input) |byte| event = editor.feed(&stream, byte);
            try std.testing.expectEqual(Event.unbound, event);
            try std.testing.expectEqual(@as(usize, 0), editor.length);
            try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
        }
    }
    for ([_]u8{ 1, 2, 65, 129 }) |modifier| {
        var sequence: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&sequence, "\x1b[97;{d};97u", .{modifier});
        var editor: Editor = .{ .buffer = &storage, .allow_paste = false };
        var stream: Input = .{};
        for (input) |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
        try std.testing.expectEqualStrings("a", storage[0..editor.length]);
    }
}

test "marked paste rejects encoded controls without releasing paste custody" {
    var storage: [64]u8 = undefined;
    for ([_][]const u8{
        "\x1b[123;4~", "\x1b[0;1:3u", "\x1b[97;1;98u",  "\x1b[200~",
        "\x1b[201x",   "\x1b[20~",    "\x1b]title\x07", "\x1bOQ",
        "\x1b_print",  "\x1bx",
    }) |sequence| {
        var editor: Editor = .{ .buffer = &storage };
        var stream: Input = .{};
        for ("\x1b[200~left") |byte| _ = editor.feed(&stream, byte);
        for (sequence) |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqual(Pending.incomplete, stream.pending());
        try std.testing.expectEqual(Event.none, editor.feed(&stream, '\n'));
        for ("right\x7f\x1b[201~") |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqual(Pending.none, stream.pending());
        try std.testing.expectEqual(Event.invalid, editor.feed(&stream, '\r'));
    }
}

test "renderer declines standalone zero-width edits and rolls back an unrepresentable paste" {
    var storage: [256]u8 = undefined;
    for ([_][]const u8{ "\u{301}", "\u{200d}", "\u{fe0f}" }) |scalar| {
        var editor: Editor = .{ .buffer = &storage };
        var stream: Input = .{};
        for ("kept\x01") |byte| _ = editor.feed(&stream, byte);
        var event: Event = .none;
        for (scalar) |byte| event = editor.feed(&stream, byte);
        try std.testing.expectEqual(Event.edit_rejected, event);
        try std.testing.expectEqualStrings("kept", storage[0..editor.length]);
        try std.testing.expectEqual(@as(usize, 0), editor.cursor);
        // Roll back a whole paste, including accepted text before a newline,
        // while retaining both the pre-paste prefix and suffix.
        for ("\x1b[200~pasted\n") |byte| _ = editor.feed(&stream, byte);
        for (scalar) |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqual(Pending.incomplete, stream.pending());
        for ("discarded\x1b[201~") |byte| event = editor.feed(&stream, byte);
        try std.testing.expectEqual(Event.edit_rejected, event);
        try std.testing.expectEqualStrings("kept", storage[0..editor.length]);
        try std.testing.expectEqual(@as(usize, 0), editor.cursor);
        try std.testing.expectEqual(Pending.none, stream.pending());
        for ("é🧑‍🌾") |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqualStrings("é🧑‍🌾kept", storage[0..editor.length]);
        try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
    }
}

fn insertText(self: *Editor, text: []const u8, pasted_input: bool) Event {
    var event: Event = .none;
    for (text) |byte| {
        const next_event = self.insert(byte, pasted_input);
        if (next_event == .edit_rejected) return next_event;
        if (next_event == .redraw or (next_event == .append and event == .none)) event = next_event;
    }
    return event;
}

fn insert(self: *Editor, byte: u8, pasted_input: bool) Event {
    if (self.rejected != null) return .none;
    if (self.partial_length == 0) {
        self.partial_need = std.unicode.utf8ByteSequenceLength(byte) catch {
            self.reject(.invalid);
            return .none;
        };
    }
    if (self.length + self.partial_length + 1 > self.buffer.len) {
        self.reject(.overflow);
        return .none;
    }
    self.partial[self.partial_length] = byte;
    self.partial_length += 1;
    if (self.partial_length != self.partial_need) return .none;
    const codepoint = std.unicode.utf8Decode(self.partial[0..self.partial_length]) catch {
        self.reject(.invalid);
        self.partial_length = 0;
        return .none;
    };
    if (!validScalar(codepoint, pasted_input)) {
        self.reject(.invalid);
        self.partial_length = 0;
        return .none;
    }
    if (codepoint != '\n' and codepoint != '\t' and vaxis.gwidth.gwidth(self.partial[0..self.partial_length], .wcwidth) == 0) {
        // A zero-width scalar is safe only when it joins an existing cluster.
        // Inspect the actual renderer's boundary rather than rejecting valid
        // decomposed accents, variation selectors or joined emoji generally.
        var pair: [8]u8 = undefined;
        var start = self.cursor -| 1;
        while (start > 0 and self.buffer[start] & 0xc0 == 0x80) start -= 1;
        const prefix = self.buffer[start..self.cursor];
        @memcpy(pair[0..prefix.len], prefix);
        @memcpy(pair[prefix.len..][0..self.partial_length], self.partial[0..self.partial_length]);
        var clusters = vaxis.unicode.graphemeIterator(pair[0 .. prefix.len + self.partial_length]);
        const joins = prefix.len != 0 and clusters.next().?.len == prefix.len + self.partial_length;
        if (!joins) {
            self.partial_length = 0;
            if (pasted_input) {
                // Paste insertion is contiguous. Roll it back without losing
                // the pre-existing suffix, draft or decoder's paste custody.
                const added = self.length - self.paste_start.length;
                const suffix = self.paste_start.cursor + added;
                std.mem.copyForwards(u8, self.buffer[self.paste_start.cursor..], self.buffer[suffix..self.length]);
                self.length = self.paste_start.length;
                self.cursor = self.paste_start.cursor;
                self.plain_ascii = self.paste_start.plain_ascii;
                self.reject(.edit_rejected);
                return .none;
            }
            return .edit_rejected;
        }
    }
    if (codepoint < 32 or codepoint > 126) self.plain_ascii = false;
    const at_end = self.cursor == self.length;
    std.mem.copyBackwards(u8, self.buffer[self.cursor + self.partial_length .. self.length + self.partial_length], self.buffer[self.cursor..self.length]);
    @memcpy(self.buffer[self.cursor .. self.cursor + self.partial_length], self.partial[0..self.partial_length]);
    self.length += self.partial_length;
    self.cursor += self.partial_length;
    self.partial_length = 0;
    if (!at_end) {
        // A combining mark or joiner can merge the inserted scalar with the
        // suffix. Never leave the caret inside the newly joined cluster.
        const cluster_end = self.next(self.previous(self.cursor));
        self.cursor = @max(self.cursor, cluster_end);
    }
    return if (at_end) .append else .redraw;
}

fn previous(self: *const Editor, position: usize) usize {
    var offset: usize = 0;
    var prior: ?c_int = null;
    var state: c_int = 0;
    var boundary: usize = 0;
    while (offset < position) {
        const start = offset;
        const scalar = self.decodeScalar(&offset);
        if (prior) |previous_scalar| {
            if (utf8proc_grapheme_break_stateful(previous_scalar, scalar, &state) != 0) boundary = start;
        }
        prior = scalar;
    }
    return boundary;
}

fn next(self: *const Editor, position: usize) usize {
    var offset: usize = 0;
    var prior: ?c_int = null;
    var state: c_int = 0;
    while (offset < self.length) {
        const start = offset;
        const scalar = self.decodeScalar(&offset);
        if (prior) |previous_scalar| {
            if (utf8proc_grapheme_break_stateful(previous_scalar, scalar, &state) != 0 and start > position) return start;
        }
        prior = scalar;
    }
    return self.length;
}

fn decodeScalar(self: *const Editor, offset: *usize) c_int {
    const size = std.unicode.utf8ByteSequenceLength(self.buffer[offset.*]) catch unreachable;
    const point = std.unicode.utf8Decode(self.buffer[offset.* .. offset.* + size]) catch unreachable;
    offset.* += size;
    return @intCast(point);
}

fn move(self: *Editor, position: usize) Event {
    if (self.rejected != null or self.cursor == position) return .none;
    self.cursor = position;
    return .redraw;
}

fn erase(self: *Editor, from: usize, to: usize) Event {
    if (self.rejected != null or from == to) return .none;
    std.mem.copyForwards(u8, self.buffer[from .. self.length - (to - from)], self.buffer[to..self.length]);
    self.length -= to - from;
    // Removing a separator may join the suffix to the preceding cluster.
    // Snap to the first boundary at or after the erased range's start.
    self.cursor = if (from == 0) 0 else self.next(from - 1);
    return .redraw;
}

fn deleteTo(self: *Editor, position: usize) Event {
    return self.erase(@min(self.cursor, position), @max(self.cursor, position));
}

fn deletePrevious(self: *Editor) Event {
    return self.erase(self.previous(self.cursor), self.cursor);
}

// Consecutive tail deletions cannot change the segmentation of the retained
// prefix. Count clusters, then find the retained boundary in one forward scan.
fn deleteTail(self: *Editor, count: usize) void {
    std.debug.assert(self.cursor == self.length and count != 0);
    if (self.plain_ascii) {
        self.length -|= count;
        self.cursor = self.length;
        return;
    }
    var offset: usize = 0;
    var prior: ?c_int = null;
    var state: c_int = 0;
    var clusters: usize = 0;
    while (offset < self.length) {
        const scalar = self.decodeScalar(&offset);
        if (prior == null or utf8proc_grapheme_break_stateful(prior.?, scalar, &state) != 0) clusters += 1;
        prior = scalar;
    }
    const keep = clusters -| count;
    if (keep == 0) {
        self.length = 0;
        self.cursor = 0;
        return;
    }
    offset = 0;
    prior = null;
    state = 0;
    clusters = 0;
    while (offset < self.length) {
        const start = offset;
        const scalar = self.decodeScalar(&offset);
        if (prior == null or utf8proc_grapheme_break_stateful(prior.?, scalar, &state) != 0) {
            if (clusters == keep) {
                self.length = start;
                self.cursor = start;
                return;
            }
            clusters += 1;
        }
        prior = scalar;
    }
    unreachable;
}

fn deleteNext(self: *Editor) Event {
    return self.erase(self.cursor, self.next(self.cursor));
}

fn lineStart(self: *const Editor) usize {
    return if (std.mem.lastIndexOfScalar(u8, self.buffer[0..self.cursor], '\n')) |i| i + 1 else 0;
}

fn lineEnd(self: *const Editor) usize {
    return if (std.mem.indexOfScalarPos(u8, self.buffer[0..self.length], self.cursor, '\n')) |i| i else self.length;
}

/// Null when no draft line lies in that direction.
fn vertical(self: *Editor, down: bool) ?Event {
    const start = self.lineStart();
    const destination = if (down)
        if (self.lineEnd() < self.length) self.lineEnd() + 1 else return null
    else if (start > 0)
        if (std.mem.lastIndexOfScalar(u8, self.buffer[0 .. start - 1], '\n')) |i| i + 1 else 0
    else
        return null;
    const limit = if (std.mem.indexOfScalarPos(u8, self.buffer[0..self.length], destination, '\n')) |i| i else self.length;
    var column: usize = 0;
    var at = start;
    while (at < self.cursor) : (column += 1) at = self.next(at);
    at = destination;
    while (column > 0 and at < limit) : (column -= 1) at = @min(self.next(at), limit);
    return self.move(at);
}

fn space(self: *const Editor, start: usize) bool {
    return std.mem.indexOfScalar(u8, " \t\n", self.buffer[start]) != null or utf8proc_category(self.codepointAt(start)) == 23;
}

fn codepointAt(self: *const Editor, start: usize) c_int {
    var offset = start;
    return self.decodeScalar(&offset);
}

fn word(self: *const Editor, start: usize) bool {
    const point_value = self.codepointAt(start);
    const category = utf8proc_category(point_value);
    return point_value == '_' or (category >= 1 and category <= 5) or (category >= 9 and category <= 11);
}

fn backwardWord(self: *Editor, whitespace: bool) Event {
    var offset: usize = 0;
    var cluster_start: usize = 0;
    var previous_scalar: ?c_int = null;
    var state: c_int = 0;
    var nonspace_start: usize = 0;
    var word_start: usize = 0;
    var in_nonspace = false;
    var in_word = false;
    while (offset < self.cursor) {
        const start = offset;
        const scalar_value = self.decodeScalar(&offset);
        if (previous_scalar) |prior| {
            if (utf8proc_grapheme_break_stateful(prior, scalar_value, &state) != 0) {
                const is_space = self.space(cluster_start);
                const is_word = self.word(cluster_start);
                if (!is_space and !in_nonspace) nonspace_start = cluster_start;
                if (is_word and !in_word) word_start = cluster_start;
                in_nonspace = !is_space;
                in_word = is_word;
                cluster_start = start;
            }
        }
        previous_scalar = scalar_value;
    }
    if (self.cursor > 0) {
        if (!self.space(cluster_start) and !in_nonspace) nonspace_start = cluster_start;
        if (self.word(cluster_start) and !in_word) word_start = cluster_start;
    }
    return self.erase(if (whitespace) nonspace_start else word_start, self.cursor);
}

fn moveWord(self: *Editor, forward: bool) Event {
    var offset: usize = 0;
    var cluster_start: usize = 0;
    var prior: ?c_int = null;
    var state: c_int = 0;
    var in_word = false;
    var word_start: usize = 0;
    var found_forward = false;
    while (offset < self.length) {
        const start = offset;
        const scalar_value = self.decodeScalar(&offset);
        if (prior) |previous_scalar| {
            if (utf8proc_grapheme_break_stateful(previous_scalar, scalar_value, &state) != 0) {
                const is_word = self.word(cluster_start);
                if (!forward and cluster_start < self.cursor) {
                    if (is_word and !in_word) word_start = cluster_start;
                    in_word = is_word;
                } else if (forward and cluster_start >= self.cursor) {
                    if (found_forward and !is_word) return self.move(cluster_start);
                    found_forward = found_forward or is_word;
                }
                cluster_start = start;
            }
        }
        prior = scalar_value;
    }
    if (forward) return self.move(self.length);
    if (cluster_start < self.cursor and self.word(cluster_start) and !in_word) word_start = cluster_start;
    return self.move(word_start);
}

test "an unbound Alt or Meta chord never inserts its bare character" {
    var storage: [64]u8 = undefined;
    // Legacy ESC prefix (Option as Meta, and tmux's re-encoding of Kitty or
    // modifyOtherKeys chords), Kitty with and without associated text, and
    // Super/Meta bits. Each is dropped as it arrives, keeping the draft
    // around it, rather than adding ".".
    // Enter with Alt and another modifier is still a dropped chord.
    for ([_][]const u8{ "\x1b.", "\x1b ", "\x1bx", "\x1b[46;3u", "\x1b[46;3;46u", "\x1b[32;3u", "\x1b[46;9u", "\x1b[46;33u", "\x1b[13;4u", "\x1b[13;4;13u", "\x1b[13:13;4u", "\x1b[13;7u", "\x1b[13;9u", "\x1b[1;3A", "\x1b\x00", "\x1b\x01", "\x1b\x12", "\x1b[28;3u", "\x1b[97;7u", "\x1b[27;3;46~", "\x1b[27;3;32~", "\x1b[27;9;46~", "\x1b[27;4;13~" }) |chord| {
        for ([_]bool{ true, false }) |allow_paste| {
            var editor: Editor = .{ .buffer = &storage, .allow_paste = allow_paste };
            var stream: Input = .{};
            for ("o") |byte| _ = editor.feed(&stream, byte);
            var dropped = false;
            for (chord) |byte| {
                const event = editor.feed(&stream, byte);
                try std.testing.expect(event != .submit);
                dropped = event == .unbound or dropped;
            }
            try std.testing.expect(dropped);
            try std.testing.expectEqualStrings("o", storage[0..editor.length]);
            for ("k") |byte| _ = editor.feed(&stream, byte);
            try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
            try std.testing.expectEqualStrings("ok", storage[0..editor.length]);
        }
    }
    // Bound chords, plain text and marked paste keep their meaning.
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("a. b\x1bb\x1bj\x1b[200~c. d\x1b[201~") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqualStrings("a. \nc. db", storage[0..editor.length]);
    try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
}

test "xterm modifyOtherKeys bindings mean what the same Kitty keys mean" {
    var storage: [64]u8 = undefined;
    // Ghostty's legacy table sends Shift-Enter as CSI 27;2;13~ unasked. It
    // adds a line like Kitty's CSI 13;2u; Ctrl-A still moves to the line start and Ctrl-J sends.
    for ([_][]const u8{ "\x1b[27;2;13~", "\x1b[13;2u", "\x1b[13;2;13u", "\x1b[13:13;2u" }) |shift_enter| {
        for ([_]bool{ true, false }) |allow_paste| {
            var editor: Editor = .{ .buffer = &storage, .allow_paste = allow_paste };
            var stream: Input = .{};
            for ("one") |byte| _ = editor.feed(&stream, byte);
            for (shift_enter) |byte| try std.testing.expect(editor.feed(&stream, byte) != .submit);
            for ("two") |byte| _ = editor.feed(&stream, byte);
            try std.testing.expectEqualStrings("one\ntwo", storage[0..editor.length]);
            for ("\x1b[27;5;97~X") |byte| _ = editor.feed(&stream, byte);
            try std.testing.expectEqualStrings("one\nXtwo", storage[0..editor.length]);
            var sent = false;
            for ("\x1b[27;5;106~") |byte| sent = editor.feed(&stream, byte) == .submit or sent;
            try std.testing.expect(sent);
        }
    }
    // Malformed forms decode nothing: no line, no dropped-chord notice.
    for ([_][]const u8{ "\x1b[27;2~", "\x1b[27;;13~", "\x1b[27;2;~", "\x1b[27;2;13;1~", "\x1b[27;0;13~", "\x1b[27;17;13~", "\x1b[27;2:3;13~" }) |malformed| {
        var editor: Editor = .{ .buffer = &storage };
        var stream: Input = .{};
        for ("ok") |byte| _ = editor.feed(&stream, byte);
        for (malformed) |byte| {
            const event = editor.feed(&stream, byte);
            try std.testing.expect(event != .submit and event != .unbound);
        }
        try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
        try std.testing.expectEqualStrings("ok", storage[0..editor.length]);
    }
}

test "a dropped chord reports itself as it arrives" {
    var storage: [16]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    _ = editor.feed(&stream, 'o');
    _ = editor.feed(&stream, 0x1b);
    try std.testing.expectEqual(Event.unbound, editor.feed(&stream, '.'));
    _ = editor.feed(&stream, 0x1b);
    try std.testing.expectEqual(Event.unbound, editor.feed(&stream, 'x'));
    // ESC ESC waits for what follows; alone, it expires as one Esc.
    _ = editor.feed(&stream, 0x1b);
    _ = editor.feed(&stream, 0x1b);
    try std.testing.expectEqual(Input.Pending.escape, stream.pending());
    try std.testing.expectEqualStrings("o", storage[0..editor.length]);
}

test "an ESC prefix decodes its key as typed alone, and ESC ESC keeps what follows whole" {
    const cases = .{
        // Alt-Backspace where Backspace sends ^H, like ESC DEL.
        .{ "first second\x1b\x08Z", "first Z", Event.none },
        // Option as Meta on a multibyte key is one dropped chord.
        .{ "o\x1b\xc3\xa9k", "ok", Event.unbound },
        // Esc just before a marked paste: Esc, then the whole paste.
        .{ "\x1b\x1b[200~first\nsecond\x1b[201~", "first\nsecond", Event.close_view },
        // Esc just before an arrow, or Meta-Up as ESC ESC [A: no "[A".
        .{ "o\x1b\x1b[A", "o", Event.close_view },
        .{ "o\x1b\x1b\x1b.", "o", Event.unbound },
    };
    inline for (cases) |case| {
        var storage: [32]u8 = undefined;
        var editor: Editor = .{ .buffer = &storage };
        var stream: Input = .{};
        var seen = false;
        for (case[0]) |byte| {
            const event = editor.feed(&stream, byte);
            try std.testing.expect(event != .submit and event != .invalid);
            if (event == case[2]) seen = true;
        }
        try std.testing.expect(seen or case[2] == .none);
        try std.testing.expectEqual(Input.Pending.none, stream.pending());
        try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
        try std.testing.expectEqualStrings(case[1], storage[0..editor.length]);
    }
}

test "meta-backspace deletes a word without swallowing the next character" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("first second\x1b\x7fZ\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("first Z", editor.buffer[0..editor.length]);
}

test "grapheme deletion, distinct word bindings and multiline paste" {
    var storage: [100]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("A中e\u{301}🧑‍🌾\x7f\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("A中e\u{301}", storage[0..editor.length]);

    editor = .{ .buffer = &storage };
    for ("ask src/foo-bar\x1b\x7f\n") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqualStrings("ask src/foo-", storage[0..editor.length]);
    editor = .{ .buffer = &storage };
    for ("ask src/foo-bar\x17\n") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqualStrings("ask ", storage[0..editor.length]);

    editor = .{ .buffer = &storage };
    for ("\x1b[200~line1\nline2\x1b[201~\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n' and !stream.paste) try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("line1\nline2", storage[0..editor.length]);
    for ([_][]const u8{ "left\tright", "left\x1b[9uright" }) |input| {
        editor = .{ .buffer = &storage };
        for (input) |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\n'));
        try std.testing.expectEqualStrings("left\tright", storage[0..editor.length]);
    }
    editor = .{ .buffer = &storage };
    for ("left\x1b[27uright") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\n'));
    try std.testing.expectEqualStrings("leftright", storage[0..editor.length]);
}

test "batched tail deletion retains exact Unicode clusters and following input" {
    const cases = .{
        .{ "abc", 1, "ab" },
        .{ "abc", 3, "" },
        .{ "abc", 5, "" },
        .{ "first second", 6, "first " },
        .{ "éa", 2, "" },
        .{ "A中e\u{301}🧑‍🌾", 1, "A中e\u{301}" },
        .{ "A中e\u{301}🧑‍🌾", 2, "A中" },
        .{ "🇺🇸🇨🇦", 1, "🇺🇸" },
        .{ "⌚\u{fe0f}🇺🇸", 2, "" },
        .{ "a\u{301}", 9, "" },
    };
    inline for (cases) |case| {
        var storage: [100]u8 = undefined;
        var editor: Editor = .{ .buffer = &storage };
        var stream: Input = .{};
        for (case[0]) |byte| _ = editor.feed(&stream, byte);
        editor.deleteTail(case[1]);
        try std.testing.expectEqualStrings(case[2], storage[0..editor.length]);
        try std.testing.expectEqual(editor.length, editor.cursor);
        try std.testing.expectEqual(Event.append, editor.feed(&stream, 'Z'));
        try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\n'));
        try std.testing.expectEqualStrings(case[2] ++ "Z", storage[0..editor.length]);
    }
}

test "exact UTF-8 bound and sticky rejection after backspace" {
    var storage: [65536]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for (0..65534) |_| _ = editor.feed(&stream, 'a');
    for ("é\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqual(@as(usize, 65536), editor.length);
    editor = .{ .buffer = &storage };
    for (0..65535) |_| _ = editor.feed(&stream, 'a');
    for ("é\x7f\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.overflow, event);
    }
    try std.testing.expectEqual(@as(usize, 65535), editor.length);
}

test "unknown CSI retains following text; malformed input and marked choice reject" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("\x1b[123;4~Z\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("Z", storage[0..editor.length]);
    editor = .{ .buffer = &storage };
    for ("\xc3(\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.invalid, event);
    }
    for ([_][]const u8{
        "invalid\x00x", "invalid\x12x", "invalid\x1cx",
        "a\x1b[0u",     "a\x1b[28u",
    }) |input| for ([_]bool{ true, false }) |allow_paste| {
        editor = .{ .buffer = &storage, .allow_paste = allow_paste };
        for (input) |byte| _ = editor.feed(&stream, byte);
        try std.testing.expectEqual(Event.invalid, editor.feed(&stream, '\n'));
    };
    editor = .{ .buffer = &storage, .allow_paste = false };
    for ("\x1b[200~a\x1b[201~\n") |byte| {
        const event = editor.feed(&stream, byte);
        if (byte == '\n' and !stream.paste) try std.testing.expectEqual(Event.invalid, event);
    }
    // Alt-a never becomes the choice "a": it is dropped, and the frontend
    // resets the choice on the report.
    editor = .{ .buffer = &storage, .allow_paste = false };
    _ = editor.feed(&stream, 0x1b);
    try std.testing.expectEqual(Event.unbound, editor.feed(&stream, 'a'));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "inserting a joiner before an emoji leaves the caret at a cluster boundary" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("🧑🌾\x1b[D\u{200d}") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqualStrings("🧑‍🌾", storage[0..editor.length]);
    try std.testing.expectEqual(editor.length, editor.cursor);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "deleting a separator does not leave the caret inside a joined grapheme" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("\x1b[200~🧑\u{200d}\n🌾\x1b[201~\x01") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqualStrings("🧑\u{200d}\n🌾", storage[0..editor.length]);
    try std.testing.expectEqual("🧑\u{200d}\n".len, editor.cursor);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 0x7f));
    try std.testing.expectEqualStrings("🧑‍🌾", storage[0..editor.length]);
    try std.testing.expectEqual(editor.length, editor.cursor);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "arrows beyond the draft's lines scroll instead of moving the caret" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    // Wheel scrolling arrives as arrow keys in the alternate screen.
    var event: Event = .none;
    for ("\x1b[A") |byte| event = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.scroll_up, event);
    for ("\x1b[200~one\ntwo\x1b[201~") |byte| _ = editor.feed(&stream, byte);
    for ("\x1b[A") |byte| event = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.redraw, event);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    for ("\x1b[A") |byte| event = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.scroll_up, event);
    for ("\x1b[B") |byte| event = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.redraw, event);
    for ("\x1b[B") |byte| event = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.scroll_down, event);
    for ([_][]const u8{ "\x1b[5~", "\x1b[5;2~" }) |sequence| {
        for (sequence) |byte| event = editor.feed(&stream, byte);
        try std.testing.expectEqual(Event.page_up, event);
    }
    for ("\x1b[6;2~") |byte| event = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.page_down, event);
    try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
    try std.testing.expectEqualStrings("one\ntwo", storage[0..editor.length]);
}

test "Ctrl-D exits only on an empty draft and otherwise deletes forward" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    try std.testing.expectEqual(Event.eof, editor.feed(&stream, 4));
    for ("ab\x01") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 4));
    try std.testing.expectEqualStrings("b", storage[0..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 5));
    try std.testing.expectEqual(Event.none, editor.feed(&stream, 4));
    try std.testing.expectEqualStrings("b", storage[0..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 0x7f));
    try std.testing.expectEqual(Event.eof, editor.feed(&stream, 4));
}

test "flag and variation selector are each deleted as one grapheme" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("⌚\u{fe0f}🇺🇸") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 0x7f));
    try std.testing.expectEqualStrings("⌚\u{fe0f}", storage[0..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.feed(&stream, 0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "incomplete escape cannot swallow Enter or Ctrl-C" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("ok\x1b[") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\n'));
    try std.testing.expectEqualStrings("ok", storage[0..editor.length]);
    editor = .{ .buffer = &storage };
    for ("\x1b[") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.interrupt, editor.feed(&stream, 3));
    editor = .{ .buffer = &storage };
    // ESC with a following key is an Alt chord: unbound, it is dropped.
    for ("ok\x1b") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.unbound, editor.feed(&stream, 'Z'));
    try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\n'));
    try std.testing.expectEqualStrings("ok", storage[0..editor.length]);
}

test "word movement skips separators and stops at word edges" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("one two/三") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expectEqual(Event.redraw, editor.moveWord(false));
    try std.testing.expectEqualStrings("三", storage[editor.cursor..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.moveWord(false));
    try std.testing.expectEqualStrings("two/三", storage[editor.cursor..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.moveWord(false));
    try std.testing.expectEqualStrings("one two/三", storage[editor.cursor..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.moveWord(true));
    try std.testing.expectEqualStrings(" two/三", storage[editor.cursor..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.moveWord(true));
    try std.testing.expectEqualStrings("/三", storage[editor.cursor..editor.length]);
}

test "Shift-Enter sent as ESC CR adds a line at the caret, as every Alt-Enter does" {
    var storage: [64]u8 = undefined;
    // ESC CR is Ghostty's Shift-Enter as captured (#538); ESC LF is the same
    // key under ICRNL. Kitty and modifyOtherKeys Alt-Enter decode alike.
    for ([_][]const u8{ "\x1b\r", "\x1b\n", "\x1b[13;3u", "\x1b[13;3;13u", "\x1b[27;3;13~" }) |alt_enter| {
        for ([_]bool{ true, false }) |allow_paste| {
            var editor: Editor = .{ .buffer = &storage, .allow_paste = allow_paste };
            var stream: Input = .{};
            for ("onetwo\x1b[D\x1b[D\x1b[D") |byte| _ = editor.feed(&stream, byte);
            for (alt_enter) |byte| {
                const event = editor.feed(&stream, byte);
                try std.testing.expect(event != .submit and event != .unbound);
            }
            try std.testing.expectEqual(Input.Pending.none, stream.pending());
            try std.testing.expectEqualStrings("one\ntwo", storage[0..editor.length]);
            try std.testing.expectEqual(@as(usize, 4), editor.cursor);
            try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
        }
    }
    // A bare Esc that expires before Enter is Esc, then Enter: it sends.
    var editor: Editor = .{ .buffer = &storage };
    var stream: Input = .{};
    for ("ok\x1b") |byte| _ = editor.feed(&stream, byte);
    try std.testing.expect(try stream.expire());
    try std.testing.expectEqual(Event.submit, editor.feed(&stream, '\r'));
    try std.testing.expectEqualStrings("ok", storage[0..editor.length]);
}

test "Shift held with a binding's key is never that binding, whatever text the key reports" {
    var storage: [64]u8 = undefined;
    // Kitty may report associated text or a shifted key equal to the base
    // key; neither may hide Shift. Ctrl-Shift-J does not send, Alt-Shift-J
    // and Alt-Shift-Enter add no line, Ctrl-Shift-C does not interrupt.
    for ([_][]const u8{ "\x1b[106;6;106u", "\x1b[106:106;6u", "\x1b[106;4;106u", "\x1b[106:106;4u", "\x1b[13;4;13u", "\x1b[99;6;99u", "\x1b[99:99;6u", "\x1b[13;2;13u" }) |chord| {
        var editor: Editor = .{ .buffer = &storage };
        var stream: Input = .{};
        for ("ok") |byte| _ = editor.feed(&stream, byte);
        for (chord) |byte| {
            const event = editor.feed(&stream, byte);
            try std.testing.expect(event != .submit and event != .interrupt);
        }
        // Shift-Enter is the one bound Shift chord here: it adds a line.
        const expected: []const u8 = if (std.mem.eql(u8, chord, "\x1b[13;2;13u")) "ok\n" else "ok";
        try std.testing.expectEqualStrings(expected, storage[0..editor.length]);
    }
}
