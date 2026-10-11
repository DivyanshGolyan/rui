//! Persistent terminal custody, separate from the fresh one-shot choice owner.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Text = @import("TerminalText.zig");
const Style = @import("session_view.zig").Style;
const protocol = @import("protocol.zig");
const termios = @cImport(@cInclude("termios.h"));
const Self = @This();
extern fn utf8proc_grapheme_break_stateful(c_int, c_int, *c_int) c_int;
extern fn utf8proc_charwidth(c_int) c_int;

original: std.posix.termios,
flags: [2]c_int,
colour: bool,
active: bool = true,
result: anyerror!void = {},
size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
rows: usize = 0,
caret_row: usize = 0,
pending_at: i96 = 0,
pump: ?struct { context: *anyopaque, step: *const fn (*anyopaque) anyerror!void } = null,

pub fn begin(colour: bool) !Self {
    const original = try std.posix.tcgetattr(0);
    var mode = original;
    mode.lflag.ICANON = false;
    mode.lflag.ECHO = false;
    mode.lflag.ISIG = false;
    mode.lflag.IEXTEN = false;
    mode.iflag.IXON = false;
    mode.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    mode.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    const flags = [2]c_int{ std.c.fcntl(0, std.c.F.GETFL), std.c.fcntl(1, std.c.F.GETFL) };
    if (flags[0] < 0 or flags[1] < 0) return error.TerminalCleanupFailed;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (std.c.fcntl(0, std.c.F.SETFL, flags[0] | nonblock) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(0, std.c.F.SETFL, flags[0]);
    if (std.c.fcntl(1, std.c.F.SETFL, flags[1] | nonblock) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(1, std.c.F.SETFL, flags[1]);
    try std.posix.tcsetattr(0, .FLUSH, mode);
    var self: Self = .{ .original = original, .flags = flags, .colour = colour };
    if (std.c.write(1, "\x1b[?2004h", 8) != 8) {
        try self.finish();
        return error.TerminalCleanupFailed;
    }
    return self;
}

/// Restore before cancelling or joining any Client borrower. No output-credit
/// dependency or drain here; SessionFrontend owns fresh exact approval input.
pub fn finish(self: *Self) !void {
    if (!self.active) return self.result;
    self.active = false;
    // The UI owns emitted style, even if a renderer's next window was cancelled.
    // Attempt controls independently; neither may hold restoration on output credit.
    const reset = std.c.write(1, "\x1b[0m", 4) == 4;
    const disabled = std.c.write(1, "\x1b[?2004l", 8) == 8;
    // Input discard is independent of output credit. TCSAFLUSH can drain the
    // same terminal's output and keep it raw while an output peer is absent.
    const flushed = termios.tcflush(0, termios.TCIFLUSH) == 0;
    const restored = std.posix.tcsetattr(0, .NOW, self.original);
    var flags_ok = true;
    for (self.flags, 0..) |flags, fd| {
        if (std.c.fcntl(@intCast(fd), std.c.F.SETFL, flags) < 0) flags_ok = false;
    }
    self.result = if (restored) |_| if (flags_ok and reset and disabled and flushed) {} else error.TerminalCleanupFailed else |_| error.TerminalRestoreFailed;
    return self.result;
}

/// Optional exit notice cannot hold a restored caller on stdout backpressure.
pub fn detached(self: *Self, store: []const u8, session: []const u8) !void {
    std.debug.assert(!self.active);
    // Four characters per escaped byte, plus fixed labels and quoting.
    var buffer: [4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 128]u8 = undefined;
    var notice = std.Io.Writer.fixed(&buffer);
    try notice.writeAll("\nDetached. Host work continues.\nResume: rui resume --store ");
    try Text.writeShellWord(&notice, store);
    try Text.writeShellSession(&notice, session, true);
    try notice.writeAll("\n");
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (std.c.fcntl(1, std.c.F.SETFL, self.flags[1] | nonblock) < 0) return error.TerminalCleanupFailed;
    _ = std.c.write(1, notice.buffered().ptr, notice.buffered().len);
    if (std.c.fcntl(1, std.c.F.SETFL, self.flags[1]) < 0) return error.TerminalCleanupFailed;
}

pub fn next(self: *Self, io: std.Io, pending: Editor.Pending, wait: i32) !?u8 {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    if (self.pending_at == 0) self.pending_at = now;
    if (pending != .none and now - self.pending_at >= (if (pending == .escape) @as(i96, 80_000_000) else 2_000_000_000))
        return error.InputDeadline;
    var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, wait) == 0) return null;
    var byte: [1]u8 = undefined;
    const count = std.posix.read(0, &byte) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (count == 0) return error.IncompleteTerminalLine;
    self.pending_at = std.Io.Clock.awake.now(io).nanoseconds;
    return byte[0];
}

fn write(self: *Self, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => {
                if (self.pump) |pump| try pump.step(pump.context);
                continue;
            },
            else => return error.TerminalCleanupFailed,
        };
        if (n == 0) return error.TerminalCleanupFailed;
        offset += @intCast(n);
    }
}

pub fn geometry() std.posix.winsize {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(1, @intCast(std.c.T.IOCGWINSZ), &size) != 0 or size.row == 0 or size.col == 0)
        return .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    return size;
}

fn clear(self: *Self) !void {
    const size = geometry();
    var control: [32]u8 = undefined;
    if (self.rows != 0) {
        if (size.row != self.size.row or size.col != self.size.col) {
            // Old physical rows cannot be erased reliably after reflow. Start
            // the retained composer on a fresh line without transcript chatter.
            try self.write("\r\n");
        } else {
            if (self.caret_row != 0) try self.write(try std.fmt.bufPrint(&control, "\x1b[{d}A", .{self.caret_row}));
            try self.write("\r");
            for (0..self.rows) |row| {
                try self.write("\x1b[2K");
                if (row + 1 < self.rows) try self.write("\r\n");
            }
            if (self.rows > 1) try self.write(try std.fmt.bufPrint(&control, "\x1b[{d}A", .{self.rows - 1}));
            try self.write("\r");
        }
    }
    self.rows = 0;
    self.size = size;
}

pub fn permanent(self: *Self, bytes: []const u8) !void {
    try self.clear();
    try self.write(bytes);
}

pub fn redraw(self: *Self, bytes: []const u8, cursor: usize, status: []const u8, prompt: []const u8) !void {
    const size = geometry();
    if (size.row < 2 or size.col < 8) return error.UncertainTerminalCursor;
    // Stage the bounded view before output can pump and mutate the draft.
    var status_buffer: [256]u8 = undefined;
    var status_writer = std.Io.Writer.fixed(&status_buffer);
    var words = std.mem.splitScalar(u8, status, ' ');
    var column: usize = 0;
    while (words.next()) |word| {
        const width = try std.unicode.utf8CountCodepoints(word);
        if (column != 0) {
            const wrap = column + 1 + width >= size.col;
            try status_writer.writeByte(if (wrap) '\n' else ' ');
            column = if (wrap) 0 else column + 1;
        }
        try status_writer.writeAll(word);
        column += width;
    }
    const status_view = try viewport(status_writer.buffered(), 0, size.col - 1, 5);
    const heading: usize = if (status.len == 0) 0 else status_view.rows;
    const prompt_columns = try std.unicode.utf8CountCodepoints(prompt);
    if (heading + 1 >= size.row) return error.UncertainTerminalCursor;
    const view = try viewport(bytes, cursor, size.col - prompt_columns - 1, @min(5, size.row - heading - 1));
    try self.clear();
    // Own the spacer along with the composer, so repeated redraws erase it
    // rather than growing scrollback or moving transcript rows.
    try self.write("\r\n");
    const status_style: Style = if (std.mem.eql(u8, prompt, "> ")) .attention else if (std.mem.startsWith(u8, status, "!") or std.mem.startsWith(u8, status, "Rejected") or std.mem.startsWith(u8, status, "Work failed")) .failure else .quiet;
    try self.write(status_style.code(self.colour));
    for (0..heading) |row| {
        if (row != 0) try self.write("\r\n");
        try self.write(status_view.data[row][0..status_view.lengths[row]]);
    }
    try self.write(Style.normal.code(self.colour));
    for (0..view.rows) |row| {
        if (row != 0 or heading != 0) try self.write("\r\n");
        try self.write((if (std.mem.eql(u8, prompt, "> ")) Style.attention else Style.user).code(self.colour));
        try self.write(if (row == 0) prompt else "> ");
        try self.write(Style.normal.code(self.colour));
        try self.write(view.data[row][0..view.lengths[row]]);
    }
    var control: [32]u8 = undefined;
    const up = view.rows - 1 - view.caret.row;
    if (up != 0) try self.write(try std.fmt.bufPrint(&control, "\x1b[{d}A", .{up}));
    try self.write(try std.fmt.bufPrint(&control, "\r\x1b[{d}C", .{view.caret.col + @as(usize, if (view.caret.row == 0) prompt_columns else 2)}));
    self.rows = view.rows + heading + 1;
    self.caret_row = view.caret.row + heading + 1;
    self.size = size;
}

const Position = struct { row: usize = 0, col: usize = 0 };
const Viewport = struct {
    data: [5][4096]u8 = undefined,
    lengths: [5]usize = @splat(0),
    rows: usize,
    first: usize,
    caret: Position,
};

fn viewport(bytes: []const u8, cursor: usize, columns: usize, limit: usize) !Viewport {
    var caret: Position = .{};
    var result: Viewport = undefined;
    for (0..2) |pass| {
        var pos: Position = .{};
        var offset: usize = 0;
        var prior: ?c_int = null;
        var state: c_int = 0;
        while (offset < bytes.len) {
            const start = offset;
            var width: usize = 0;
            while (offset < bytes.len) {
                const n = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return error.UncertainTerminalCursor;
                const scalar: c_int = @intCast(std.unicode.utf8Decode(bytes[offset..][0..n]) catch return error.UncertainTerminalCursor);
                if (prior) |p| {
                    var next_state = state;
                    if (utf8proc_grapheme_break_stateful(p, scalar, &next_state) != 0 and offset != start) break;
                    state = next_state;
                }
                prior = scalar;
                offset += n;
                width = @max(width, @as(usize, @intCast(@max(0, utf8proc_charwidth(scalar)))));
                if (scalar == 0xfe0f or scalar == 0x20e3 or scalar >= 0x1f1e6 and scalar <= 0x1f1ff) width = @max(width, 2);
            }
            const special = bytes[start];
            if (special == '\t') width = @min(8 - pos.col % 8, columns);
            if (width > columns) return error.UncertainTerminalCursor;
            if (special != '\n' and pos.col + width > columns) pos = .{ .row = pos.row + 1 };
            if (start == cursor) caret = pos;
            if (pass == 1 and special != '\n' and pos.row >= result.first and pos.row < result.first + result.rows) {
                const row = pos.row - result.first;
                const n = if (special == '\t') width else offset - start;
                const used = result.lengths[row];
                if (used + n > result.data[row].len) return error.UncertainTerminalCursor;
                if (special == '\t') @memset(result.data[row][used..][0..n], ' ') else @memcpy(result.data[row][used..][0..n], bytes[start..offset]);
                result.lengths[row] += n;
            }
            if (special == '\n') pos = .{ .row = pos.row + 1 } else pos.col += width;
            if (offset == cursor) caret = pos;
        }
        if (cursor == 0) caret = .{};
        if (pass == 0) {
            const first = if (caret.row >= limit) caret.row - limit + 1 else 0;
            const rows = @min(limit, pos.row - first + 1);
            result = .{ .rows = rows, .first = first, .caret = .{ .row = caret.row - first, .col = caret.col } };
        }
    }
    return result;
}
