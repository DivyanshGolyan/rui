//! Persistent terminal custody, separate from the fresh one-shot choice owner.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Text = @import("TerminalText.zig");
const View = @import("session_view.zig");
const Style = View.Style;
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
    // SETFL may mutate before reporting failure. Register restoration before
    // each attempt; an enable failure already reports TerminalCleanupFailed.
    errdefer _ = std.c.fcntl(0, std.c.F.SETFL, flags[0]);
    if (std.c.fcntl(0, std.c.F.SETFL, flags[0] | nonblock) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(1, std.c.F.SETFL, flags[1]);
    if (std.c.fcntl(1, std.c.F.SETFL, flags[1] | nonblock) < 0) return error.TerminalCleanupFailed;
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
    // Disposal must not leave a transient call or draft in the transcript.
    // One nonblocking attempt cannot hold restoration on output credit.
    var control: [6 * (1 + 5 + 3 * 5 + 5 + 5) + 32]u8 = undefined;
    const erase = self.clearSequence(geometry(), &control);
    const erased = erase.len == 0 or std.c.write(1, erase.ptr, erase.len) == @as(isize, @intCast(erase.len));
    self.rows = 0;
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
    self.result = if (restored) |_| if (erased and flags_ok and reset and disabled and flushed) {} else error.TerminalCleanupFailed else |_| error.TerminalRestoreFailed;
    return self.result;
}

/// Optional exit notice cannot hold a restored caller on stdout backpressure.
pub fn detached(self: *Self, store: []const u8, session: []const u8) !void {
    return self.detachedWithOps(store, session, NativeNoticeOps{});
}

const NativeNoticeOps = struct {
    fn setFlags(_: @This(), flags: c_int) c_int {
        return std.c.fcntl(1, std.c.F.SETFL, flags);
    }
    fn writeNotice(_: @This(), bytes: []const u8) isize {
        return std.c.write(1, bytes.ptr, bytes.len);
    }
};

fn detachedWithOps(self: *Self, store: []const u8, session: []const u8, ops: anytype) !void {
    std.debug.assert(!self.active);
    // Four characters per escaped byte, plus fixed labels and quoting.
    var buffer: [4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 128]u8 = undefined;
    var notice = std.Io.Writer.fixed(&buffer);
    try notice.writeAll("\nDetached. Host work continues.\nResume: rui resume --store ");
    try Text.writeShellWord(&notice, store);
    try Text.writeShellSession(&notice, session, true);
    try notice.writeAll("\n");
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const enabled = ops.setFlags(self.flags[1] | nonblock) == 0;
    const written = if (enabled) ops.writeNotice(notice.buffered()) else -1;
    // Restore every attempted enable, without writing after a failed attempt.
    if (ops.setFlags(self.flags[1]) < 0) return error.TerminalCleanupFailed;
    if (written != @as(isize, @intCast(notice.buffered().len))) return error.TerminalCleanupFailed;
}

test "detached notice restores flags and requires one complete nonblocking write" {
    const Output = struct {
        enable_failed: bool,
        restore_failed: bool,
        delivery: enum { failed, zero, short, full },
        flags: c_int = 2,
        sets: usize = 0,
        writes: usize = 0,
        blocking_write: bool = false,
        bytes: [1024]u8 = undefined,
        len: usize = 0,

        fn setFlags(self: *@This(), flags: c_int) c_int {
            self.sets += 1;
            if (self.sets == 1) {
                // Model the harder failure: enable mutates before failing.
                self.flags = flags;
                return if (self.enable_failed) -1 else 0;
            }
            if (self.restore_failed) return -1;
            self.flags = flags;
            return 0;
        }
        fn writeNotice(self: *@This(), bytes: []const u8) isize {
            self.writes += 1;
            const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
            self.blocking_write = self.blocking_write or self.flags & nonblock == 0;
            @memcpy(self.bytes[0..bytes.len], bytes);
            self.len = bytes.len;
            return switch (self.delivery) {
                .failed => -1,
                .zero => 0,
                .short => @intCast(bytes.len - 1),
                .full => @intCast(bytes.len),
            };
        }
    };
    for ([_]bool{ false, true }) |enable_failed| {
        for ([_]bool{ false, true }) |restore_failed| {
            for ([_]@FieldType(Output, "delivery"){ .failed, .zero, .short, .full }) |delivery| {
                var output: Output = .{ .enable_failed = enable_failed, .restore_failed = restore_failed, .delivery = delivery };
                var terminal: Self = .{ .original = undefined, .flags = .{ 0, 2 }, .colour = false, .active = false };
                const result = terminal.detachedWithOps("/tmp/a'\\\n", "--s", &output);
                const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
                try std.testing.expectEqual(@as(c_int, 2) | (if (restore_failed) nonblock else 0), output.flags);
                try std.testing.expectEqual(@as(usize, 2), output.sets);
                try std.testing.expectEqual(@as(usize, if (enable_failed) 0 else 1), output.writes);
                try std.testing.expect(!output.blocking_write);
                if (!enable_failed) try std.testing.expectEqualStrings(
                    "\nDetached. Host work continues.\nResume: rui resume --store $'/tmp/a\\'\\\\\\012' -- $'--s'\n",
                    output.bytes[0..output.len],
                );
                if (!enable_failed and !restore_failed and delivery == .full) try result else try std.testing.expectError(error.TerminalCleanupFailed, result);
            }
        }
    }
    var output: Output = .{ .enable_failed = false, .restore_failed = false, .delivery = .full };
    var terminal: Self = .{ .original = undefined, .flags = .{ 0, 2 }, .colour = false, .active = false };
    try terminal.detachedWithOps("/tmp/store", "A\x00Z", &output);
    try std.testing.expectEqualStrings("\nDetached. Host work continues.\nResume: rui resume --store $'/tmp/store' --session-hex 41005a\n", output.bytes[0..output.len]);
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

// Spacer, five status rows, three five-row calls, five overflow rows and five
// draft rows bound the erase controls independently of history/population.
fn clearSequence(self: *const Self, size: std.posix.winsize, buffer: *[6 * (1 + 5 + 3 * 5 + 5 + 5) + 32]u8) []const u8 {
    var control = std.Io.Writer.fixed(buffer);
    if (self.rows != 0) {
        if (size.row != self.size.row or size.col != self.size.col) {
            // Old physical rows cannot be erased reliably after reflow. Start
            // the retained composer on a fresh line without transcript chatter.
            control.writeAll("\r\n") catch unreachable;
        } else {
            if (self.caret_row != 0) control.print("\x1b[{d}A", .{self.caret_row}) catch unreachable;
            control.writeAll("\r") catch unreachable;
            for (0..self.rows) |row| {
                control.writeAll("\x1b[2K") catch unreachable;
                if (row + 1 < self.rows) control.writeAll("\r\n") catch unreachable;
            }
            if (self.rows > 1) control.print("\x1b[{d}A", .{self.rows - 1}) catch unreachable;
            control.writeAll("\r") catch unreachable;
        }
    }
    return control.buffered();
}

fn clear(self: *Self) !void {
    const size = geometry();
    var control: [6 * (1 + 5 + 3 * 5 + 5 + 5) + 32]u8 = undefined;
    try self.write(self.clearSequence(size, &control));
    self.rows = 0;
    self.size = size;
}

pub fn permanent(self: *Self, bytes: []const u8) !void {
    try self.clear();
    try self.write(bytes);
}

pub fn redraw(self: *Self, bytes: []const u8, cursor: usize, status: []const u8, prompt: []const u8, live: *const View.Live) !void {
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
    var status_snapshot: [status_buffer.len]u8 = undefined;
    const status_limit = @min(5, size.row - 2 - @as(usize, if (live.total != 0 and size.row > 2) 1 else 0));
    const status_view = if (status_limit != 0) try viewport(status_writer.buffered(), 0, size.col - 1, status_limit, &status_snapshot) else Viewport{ .rows = 0, .first = 0, .caret = .{} };
    const heading: usize = if (status.len == 0) 0 else status_view.rows;
    const available = size.row - heading - 2;
    var visible: usize = 0;
    var activity_rows: usize = 0;
    var activity_buffer: [3][View.Live.line_bytes]u8 = undefined;
    var activity: [3]Viewport = undefined;
    var line_buffer: [View.Live.line_bytes]u8 = undefined;
    var overflow_buffer: [80]u8 = undefined;
    var overflow_snapshot: [overflow_buffer.len]u8 = undefined;
    // Fit complete call descriptions and outcome explanations, not clipped
    // one-line prefixes that can make denial or uncertainty look unresolved.
    for (0..live.count) |index| {
        const line = try live.line(index, &line_buffer);
        const wrapped = try viewport(line, 0, size.col - 1, 5, &activity_buffer[index]);
        const remaining = live.total - index - 1;
        const extra = if (remaining != 0) try viewport(try std.fmt.bufPrint(&overflow_buffer, "+{d} more calls · /status", .{remaining}), 0, size.col - 1, 5, &overflow_snapshot) else Viewport{ .rows = 0, .first = 0, .caret = .{} };
        if (wrapped.total_rows != wrapped.rows or activity_rows + wrapped.rows + extra.total_rows > available) break;
        activity[index] = wrapped;
        activity_rows += wrapped.rows;
        visible += 1;
    }
    const overflow = live.total > visible and available != 0;
    const overflow_line = if (overflow) try std.fmt.bufPrint(&overflow_buffer, "+{d} more calls · /status", .{live.total - visible}) else "";
    const overflow_view = if (overflow) try viewport(overflow_line, 0, size.col - 1, 5, &overflow_snapshot) else Viewport{ .rows = 0, .first = 0, .caret = .{} };
    if (overflow_view.total_rows > available - activity_rows or overflow_view.total_rows != overflow_view.rows) return error.UncertainTerminalCursor;
    activity_rows += overflow_view.rows;
    const prompt_columns = try std.unicode.utf8CountCodepoints(prompt);
    // Visible raw bytes cannot exceed the complete semantic draft. Tabs expand
    // only during emission, without consuming a second semantic-byte budget.
    var snapshot: [@import("SessionInput.zig").capacity]u8 = undefined;
    const columns = size.col - prompt_columns - 1;
    const view = try viewport(bytes, cursor, columns, @min(5, size.row - heading - activity_rows - 1), &snapshot);
    try self.clear();
    // Own the spacer along with the composer, so repeated redraws erase it
    // rather than growing scrollback or moving transcript rows.
    try self.write("\r\n");
    const status_style: Style = if (std.mem.eql(u8, prompt, "> ")) .attention else if (std.mem.startsWith(u8, status, "!") or std.mem.startsWith(u8, status, "Rejected") or std.mem.startsWith(u8, status, "Work failed")) .failure else .quiet;
    try self.write(status_style.code(self.colour));
    for (0..heading) |row| {
        if (row != 0) try self.write("\r\n");
        try self.writeRow(status_view.data[row], size.col - 1);
    }
    for (activity[0..visible], 0..) |wrapped, index| {
        if (heading != 0 or index != 0) try self.write("\r\n");
        try self.write(live.style(index).code(self.colour));
        for (0..wrapped.rows) |row| {
            if (row != 0) try self.write("\r\n");
            try self.writeRow(wrapped.data[row], size.col - 1);
        }
    }
    if (overflow) {
        if (heading + visible != 0) try self.write("\r\n");
        try self.write(Style.quiet.code(self.colour));
        for (0..overflow_view.rows) |row| {
            if (row != 0) try self.write("\r\n");
            try self.writeRow(overflow_view.data[row], size.col - 1);
        }
    }
    try self.write(Style.normal.code(self.colour));
    for (0..view.rows) |row| {
        if (row != 0 or heading + activity_rows != 0) try self.write("\r\n");
        try self.write((if (std.mem.eql(u8, prompt, "> ")) Style.attention else Style.user).code(self.colour));
        try self.write(if (row == 0) prompt else "> ");
        try self.write(Style.normal.code(self.colour));
        try self.writeRow(view.data[row], columns);
    }
    var control: [32]u8 = undefined;
    const up = view.rows - 1 - view.caret.row;
    if (up != 0) try self.write(try std.fmt.bufPrint(&control, "\x1b[{d}A", .{up}));
    try self.write(try std.fmt.bufPrint(&control, "\r\x1b[{d}C", .{view.caret.col + @as(usize, if (view.caret.row == 0) prompt_columns else 2)}));
    self.rows = view.rows + heading + activity_rows + 1;
    self.caret_row = view.caret.row + heading + activity_rows + 1;
    self.size = size;
}

fn writeRow(self: *Self, bytes: []const u8, columns: usize) !void {
    if (std.mem.indexOfScalar(u8, bytes, '\t') == null) return self.write(bytes);
    var clusters: Clusters = .{ .bytes = bytes };
    var start: usize = 0;
    var column: usize = 0;
    while (try clusters.next()) |cluster| {
        const width = cluster.widthAt(column, columns);
        if (cluster.bytes[0] == '\t') {
            try self.write(bytes[start .. clusters.offset - cluster.bytes.len]);
            try self.write("        "[0..width]);
            start = clusters.offset;
        }
        column += width;
    }
    try self.write(bytes[start..]);
}

const Position = struct { row: usize = 0, col: usize = 0 };
const Viewport = struct {
    data: [5][]const u8 = @splat(""),
    rows: usize,
    total_rows: usize = 0,
    first: usize,
    caret: Position,
};

const Clusters = struct {
    bytes: []const u8,
    offset: usize = 0,
    prior: ?c_int = null,
    state: c_int = 0,

    const Cluster = struct {
        bytes: []const u8,
        width: usize,

        fn widthAt(self: Cluster, column: usize, columns: usize) usize {
            return if (self.bytes[0] == '\t') @min(8 - column % 8, columns) else self.width;
        }
    };

    fn next(self: *Clusters) !?Cluster {
        if (self.offset == self.bytes.len) return null;
        const start = self.offset;
        var width: usize = 0;
        while (self.offset < self.bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(self.bytes[self.offset]) catch return error.UncertainTerminalCursor;
            if (n > self.bytes.len - self.offset) return error.UncertainTerminalCursor;
            const scalar: c_int = @intCast(std.unicode.utf8Decode(self.bytes[self.offset..][0..n]) catch return error.UncertainTerminalCursor);
            if (self.prior) |p| {
                var next_state = self.state;
                if (utf8proc_grapheme_break_stateful(p, scalar, &next_state) != 0 and self.offset != start) break;
                self.state = next_state;
            }
            self.prior = scalar;
            self.offset += n;
            width = @max(width, @as(usize, @intCast(@max(0, utf8proc_charwidth(scalar)))));
            if (scalar == 0xfe0f or scalar == 0x20e3 or scalar >= 0x1f1e6 and scalar <= 0x1f1ff) width = @max(width, 2);
        }
        return .{ .bytes = self.bytes[start..self.offset], .width = width };
    }
};

fn viewport(bytes: []const u8, cursor: usize, columns: usize, limit: usize, storage: []u8) !Viewport {
    var caret: Position = .{};
    var result: Viewport = undefined;
    for (0..2) |pass| {
        var pos: Position = .{};
        var clusters: Clusters = .{ .bytes = bytes };
        var used: usize = 0;
        while (try clusters.next()) |cluster| {
            const start = clusters.offset - cluster.bytes.len;
            const special = cluster.bytes[0];
            var width = cluster.widthAt(pos.col, columns);
            if (width > columns) return error.UncertainTerminalCursor;
            if (special != '\n' and pos.col + width > columns) {
                pos = .{ .row = pos.row + 1 };
                width = cluster.widthAt(0, columns);
            }
            if (start == cursor) caret = pos;
            if (pass == 1 and special != '\n' and pos.row >= result.first and pos.row < result.first + result.rows) {
                const row = pos.row - result.first;
                const n = cluster.bytes.len;
                if (n > storage.len - used) return error.UncertainTerminalCursor;
                @memcpy(storage[used..][0..n], cluster.bytes);
                const row_start = used - result.data[row].len;
                used += n;
                result.data[row] = storage[row_start..used];
            }
            if (special == '\n') pos = .{ .row = pos.row + 1 } else pos.col += width;
            if (clusters.offset == cursor) caret = pos;
        }
        if (cursor == 0) caret = .{};
        if (pass == 0) {
            const first = if (caret.row >= limit) caret.row - limit + 1 else 0;
            const rows = @min(limit, pos.row - first + 1);
            result = .{ .rows = rows, .total_rows = pos.row + 1, .first = first, .caret = .{ .row = caret.row - first, .col = caret.col } };
        }
    }
    return result;
}
