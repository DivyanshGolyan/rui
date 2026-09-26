const std = @import("std");
const Editor = @This();
const termios = @cImport(@cInclude("termios.h"));

extern fn utf8proc_grapheme_break_stateful(c_int, c_int, *c_int) c_int;
extern fn utf8proc_category(c_int) c_int;

buffer: []u8,
length: usize = 0,
cursor: usize = 0,
partial: [4]u8 = undefined,
partial_length: u3 = 0,
partial_need: u3 = 0,
escape: enum { none, esc, csi, ss3 } = .none,
sequence: [24]u8 = undefined,
sequence_length: usize = 0,
paste: bool = false,
allow_paste: bool = true,
paste_prefix: [6]u8 = undefined,
paste_prefix_length: usize = 0,
rejected: ?Event = null,
plain_ascii: bool = true,

const Event = enum { none, append, redraw, submit, eof, interrupt, invalid, overflow };
const paste_end = "\x1b[201~";

/// Returns a slice borrowed from buffer until its caller next reuses it.
/// No draft, terminal mode or buffered input survives a prompt.
pub fn readLine(io: std.Io, buffer: []u8, prompt: []const u8, allow_paste: bool) !?[]const u8 {
    const original = try std.posix.tcgetattr(0);
    var mode = original;
    mode.lflag.ICANON = false;
    mode.lflag.ECHO = false;
    mode.lflag.ISIG = false;
    mode.lflag.IEXTEN = false;
    mode.iflag.IXON = false;
    mode.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    mode.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .FLUSH, mode);

    // Always attempt both effects, even when rendering or input fails. Do
    // not return an accepted line if either cleanup step is unconfirmed.
    const result = drive(io, buffer, prompt, allow_paste);
    const disabled = std.Io.File.stdout().writeStreamingAll(io, "\x1b[?2004l");
    const restored = std.posix.tcsetattr(0, .NOW, original);
    restored catch return error.TerminalRestoreFailed;
    disabled catch return error.TerminalCleanupFailed;
    return try result;
}

fn drive(io: std.Io, buffer: []u8, prompt: []const u8, allow_paste: bool) !?[]const u8 {
    const output = std.Io.File.stdout();
    try output.writeStreamingAll(io, "\x1b[?2004h");
    try output.writeStreamingAll(io, prompt);
    if (!allow_paste) {
        // The exact Action is already printed. Nothing received before the
        // complete fresh prompt may count as its decision.
        if (termios.tcdrain(1) != 0 or termios.tcflush(0, termios.TCIFLUSH) != 0) return error.TerminalFlushFailed;
    }
    var editor: Editor = .{ .buffer = buffer, .allow_paste = allow_paste };
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
        if (editor.escape != .none or editor.paste or editor.partial_length != 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            // Only bare ESC is ambiguous with a standalone key. Once CSI or
            // SS3 is recognized, allow a fragmented sequence to complete.
            if (try std.posix.poll(&fds, if (editor.escape == .esc) 80 else 2000) == 0) {
                if (editor.paste or editor.partial_length != 0) {
                    try output.writeStreamingAll(io, "\n");
                    return error.IncompleteTerminalInput;
                }
                if (editor.escape == .csi or editor.escape == .ss3) {
                    try output.writeStreamingAll(io, "\n");
                    return error.IncompleteTerminalInput;
                }
                editor.escape = .none;
                continue;
            }
        }
        var byte: [1]u8 = undefined;
        if (try std.posix.read(0, &byte) == 0) {
            if (backspaces != 0) try paintTailDeletion(io, &editor, backspaces, prompt, initial_size);
            return if (editor.length == 0) null else error.IncompleteTerminalLine;
        }
        if ((byte[0] == 8 or byte[0] == 127) and editor.escape == .none and !editor.paste and
            editor.partial_length == 0 and editor.rejected == null and editor.cursor == editor.length and editor.length != 0)
        {
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
        const may_edit = editor.cursor != editor.length or editor.escape != .none or
            std.mem.indexOfScalar(u8, "\x01\x04\x05\x08\x0b\x15\x17\x7f", byte[0]) != null;
        const old_row = if (may_edit) visibleRow(&editor, prompt.len, initial_size) else null;
        const old_length = editor.length;
        const event = editor.feed(byte[0]);
        switch (event) {
            .none => {},
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

// This transition is also the production byte-ingress path. Its result is
// observable through the accepted line; no escape parser reads past a prompt.
fn feed(self: *Editor, byte: u8) Event {
    if (self.paste) return self.pasted(byte);
    if (self.escape != .none and (byte == 3 or byte == 4 or byte == '\r' or byte == '\n')) {
        self.escape = .none;
        return self.feed(byte);
    }
    switch (self.escape) {
        .esc => {
            self.escape = .none;
            return switch (byte) {
                '[' => blk: {
                    self.escape = .csi;
                    self.sequence_length = 0;
                    break :blk .none;
                },
                'O' => blk: {
                    self.escape = .ss3;
                    break :blk .none;
                },
                8, 127 => self.backwardWord(false),
                'b' => self.moveWord(false),
                'f' => self.moveWord(true),
                else => if (self.allow_paste) self.feed(byte) else blk: {
                    self.reject(.invalid);
                    break :blk .none;
                },
            };
        },
        .ss3 => {
            self.escape = .none;
            return switch (byte) {
                'H' => self.move(self.lineStart()),
                'F' => self.move(self.lineEnd()),
                else => .none,
            };
        },
        .csi => {
            if (self.sequence_length == self.sequence.len) {
                self.escape = .none;
                self.reject(.invalid);
                return .none;
            }
            self.sequence[self.sequence_length] = byte;
            self.sequence_length += 1;
            if (byte < 0x40 or byte > 0x7e) return .none;
            self.escape = .none;
            return self.csi(self.sequence[0..self.sequence_length]);
        },
        .none => {},
    }
    return switch (byte) {
        0x1b => blk: {
            self.escape = .esc;
            break :blk .none;
        },
        '\r', '\n' => if (self.rejected) |reason| reason else if (self.partial_length != 0) .invalid else .submit,
        3 => .interrupt,
        4 => if (self.length == 0 and self.partial_length == 0) .eof else self.deleteNext(),
        8, 127 => self.deletePrevious(),
        1 => self.move(self.lineStart()),
        5 => self.move(self.lineEnd()),
        21 => self.deleteTo(self.lineStart()),
        11 => self.deleteTo(self.lineEnd()),
        23 => self.backwardWord(true),
        else => self.insert(byte, false),
    };
}

fn reject(self: *Editor, reason: Event) void {
    if (self.rejected == null) self.rejected = reason;
}

fn csi(self: *Editor, sequence: []const u8) Event {
    if (std.mem.eql(u8, sequence, "200~")) {
        self.paste = true;
        if (!self.allow_paste) self.reject(.invalid);
        return .none;
    }
    if (std.mem.eql(u8, sequence, "201~")) {
        self.reject(.invalid);
        return .none;
    }
    if (self.rejected != null) return .none;
    if (std.mem.eql(u8, sequence, "D")) return self.move(self.previous(self.cursor));
    if (std.mem.eql(u8, sequence, "C")) return self.move(self.next(self.cursor));
    if (std.mem.eql(u8, sequence, "H") or std.mem.eql(u8, sequence, "1~") or std.mem.eql(u8, sequence, "7~")) return self.move(self.lineStart());
    if (std.mem.eql(u8, sequence, "F") or std.mem.eql(u8, sequence, "4~") or std.mem.eql(u8, sequence, "8~")) return self.move(self.lineEnd());
    if (std.mem.eql(u8, sequence, "3~")) return self.deleteNext();
    if (std.mem.eql(u8, sequence, "A")) return self.vertical(false);
    if (std.mem.eql(u8, sequence, "B")) return self.vertical(true);
    if (std.mem.eql(u8, sequence, "1;3D")) return self.moveWord(false);
    if (std.mem.eql(u8, sequence, "1;3C")) return self.moveWord(true);
    return .none;
}

fn pasted(self: *Editor, byte: u8) Event {
    self.paste_prefix[self.paste_prefix_length] = byte;
    self.paste_prefix_length += 1;
    var event: Event = .none;
    while (self.paste_prefix_length > 0 and !std.mem.startsWith(u8, paste_end, self.paste_prefix[0..self.paste_prefix_length])) {
        const first = self.paste_prefix[0];
        std.mem.copyForwards(u8, self.paste_prefix[0 .. self.paste_prefix_length - 1], self.paste_prefix[1..self.paste_prefix_length]);
        self.paste_prefix_length -= 1;
        const next_event = self.insert(first, true);
        if (next_event == .redraw or (next_event == .append and event == .none)) event = next_event;
    }
    if (self.paste_prefix_length == paste_end.len) {
        self.paste = false;
        self.paste_prefix_length = 0;
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
    if ((codepoint < 32 and !(codepoint == '\t' or (pasted_input and codepoint == '\n'))) or
        (codepoint >= 0x7f and codepoint < 0xa0) or
        (utf8proc_category(@intCast(codepoint)) == 27 and codepoint != 0x200d))
    {
        self.reject(.invalid);
        self.partial_length = 0;
        return .none;
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

fn vertical(self: *Editor, down: bool) Event {
    const start = self.lineStart();
    const destination = if (down)
        if (self.lineEnd() < self.length) self.lineEnd() + 1 else return .none
    else if (start > 0)
        if (std.mem.lastIndexOfScalar(u8, self.buffer[0 .. start - 1], '\n')) |i| i + 1 else 0
    else
        return .none;
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

test "meta-backspace deletes a word without swallowing the next character" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("first second\x1b\x7fZ\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("first Z", editor.buffer[0..editor.length]);
}

test "grapheme deletion, distinct word bindings and multiline paste" {
    var storage: [100]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("A中e\u{301}🧑‍🌾\x7f\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("A中e\u{301}", storage[0..editor.length]);

    editor = .{ .buffer = &storage };
    for ("ask src/foo-bar\x1b\x7f\n") |byte| _ = editor.feed(byte);
    try std.testing.expectEqualStrings("ask src/foo-", storage[0..editor.length]);
    editor = .{ .buffer = &storage };
    for ("ask src/foo-bar\x17\n") |byte| _ = editor.feed(byte);
    try std.testing.expectEqualStrings("ask ", storage[0..editor.length]);

    editor = .{ .buffer = &storage };
    for ("\x1b[200~line1\nline2\x1b[201~\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n' and !editor.paste) try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("line1\nline2", storage[0..editor.length]);
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
        for (case[0]) |byte| _ = editor.feed(byte);
        editor.deleteTail(case[1]);
        try std.testing.expectEqualStrings(case[2], storage[0..editor.length]);
        try std.testing.expectEqual(editor.length, editor.cursor);
        try std.testing.expectEqual(Event.append, editor.feed('Z'));
        try std.testing.expectEqual(Event.submit, editor.feed('\n'));
        try std.testing.expectEqualStrings(case[2] ++ "Z", storage[0..editor.length]);
    }
}

test "exact UTF-8 bound and sticky rejection after backspace" {
    var storage: [65536]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for (0..65534) |_| _ = editor.feed('a');
    for ("é\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqual(@as(usize, 65536), editor.length);
    editor = .{ .buffer = &storage };
    for (0..65535) |_| _ = editor.feed('a');
    for ("é\x7f\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.overflow, event);
    }
    try std.testing.expectEqual(@as(usize, 65535), editor.length);
}

test "unknown CSI retains following text; malformed input and marked choice reject" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("\x1b[123;4~Z\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.submit, event);
    }
    try std.testing.expectEqualStrings("Z", storage[0..editor.length]);
    editor = .{ .buffer = &storage };
    for ("\xc3(\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.invalid, event);
    }
    editor = .{ .buffer = &storage, .allow_paste = false };
    for ("\x1b[200~a\x1b[201~\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n' and !editor.paste) try std.testing.expectEqual(Event.invalid, event);
    }
    editor = .{ .buffer = &storage, .allow_paste = false };
    for ("\x1ba\n") |byte| {
        const event = editor.feed(byte);
        if (byte == '\n') try std.testing.expectEqual(Event.invalid, event);
    }
}

test "inserting a joiner before an emoji leaves the caret at a cluster boundary" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("🧑🌾\x1b[D\u{200d}") |byte| _ = editor.feed(byte);
    try std.testing.expectEqualStrings("🧑‍🌾", storage[0..editor.length]);
    try std.testing.expectEqual(editor.length, editor.cursor);
    try std.testing.expectEqual(Event.redraw, editor.feed(0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "deleting a separator does not leave the caret inside a joined grapheme" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("\x1b[200~a\n\u{301}\x1b[201~\x01") |byte| _ = editor.feed(byte);
    try std.testing.expectEqualStrings("a\n\u{301}", storage[0..editor.length]);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    try std.testing.expectEqual(Event.redraw, editor.feed(0x7f));
    try std.testing.expectEqualStrings("a\u{301}", storage[0..editor.length]);
    try std.testing.expectEqual(editor.length, editor.cursor);
    try std.testing.expectEqual(Event.redraw, editor.feed(0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "Ctrl-D exits only on an empty draft and otherwise deletes forward" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    try std.testing.expectEqual(Event.eof, editor.feed(4));
    for ("ab\x01") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Event.redraw, editor.feed(4));
    try std.testing.expectEqualStrings("b", storage[0..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.feed(5));
    try std.testing.expectEqual(Event.none, editor.feed(4));
    try std.testing.expectEqualStrings("b", storage[0..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.feed(0x7f));
    try std.testing.expectEqual(Event.eof, editor.feed(4));
}

test "flag and variation selector are each deleted as one grapheme" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("⌚\u{fe0f}🇺🇸") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Event.redraw, editor.feed(0x7f));
    try std.testing.expectEqualStrings("⌚\u{fe0f}", storage[0..editor.length]);
    try std.testing.expectEqual(Event.redraw, editor.feed(0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "incomplete escape cannot swallow Enter or Ctrl-C" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("ok\x1b[") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Event.submit, editor.feed('\n'));
    try std.testing.expectEqualStrings("ok", storage[0..editor.length]);
    editor = .{ .buffer = &storage };
    for ("\x1b[") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Event.interrupt, editor.feed(3));
    editor = .{ .buffer = &storage };
    for ("\x1bZ\n") |byte| _ = editor.feed(byte);
    try std.testing.expectEqualStrings("Z", storage[0..editor.length]);
}

test "word movement skips separators and stops at word edges" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("one two/三") |byte| _ = editor.feed(byte);
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
