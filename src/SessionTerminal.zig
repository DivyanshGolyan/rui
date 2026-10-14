//! Terminal custody and bounded writes. SessionScreen owns cells and layout;
//! this owner restores native state before any worker cancellation or join.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Text = @import("TerminalText.zig");
const View = @import("session_view.zig");
const Screen = @import("SessionScreen.zig");
const protocol = @import("protocol.zig");
const termios = @import("posix");
const Self = @This();

original: Editor.Attributes,
flags: [2]c_int,
colour: bool,
screen: ?*Screen = null,
active: bool = true,
result: anyerror!void = {},
size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
pending_at: i96 = 0,
pump: ?struct { context: *anyopaque, step: *const fn (*anyopaque) anyerror!void } = null,

pub fn begin(colour: bool) !Self {
    const original = try Editor.getAttributes();
    var mode = original;
    mode.c_lflag &= ~@as(termios.tcflag_t, termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN);
    mode.c_iflag &= ~@as(termios.tcflag_t, termios.IXON);
    mode.c_cc[termios.VMIN] = 1;
    mode.c_cc[termios.VTIME] = 0;
    const flags = [2]c_int{ std.c.fcntl(0, std.c.F.GETFL), std.c.fcntl(1, std.c.F.GETFL) };
    if (flags[0] < 0 or flags[1] < 0) return error.TerminalCleanupFailed;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    errdefer _ = std.c.fcntl(0, std.c.F.SETFL, flags[0]);
    if (std.c.fcntl(0, std.c.F.SETFL, flags[0] | nonblock) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(1, std.c.F.SETFL, flags[1]);
    if (std.c.fcntl(1, std.c.F.SETFL, flags[1] | nonblock) < 0) return error.TerminalCleanupFailed;
    try Editor.setAttributes(.FLUSH, mode);
    var self: Self = .{ .original = original, .flags = flags, .colour = colour };
    // Observe the alternate screen's width mode without changing it. Legacy
    // terminals may ignore DECRQM; the screen then keeps its wcwidth default.
    const enter = "\x1b[?1049h\x1b[?2004h\x1b[?2027$p";
    if (std.c.write(1, enter, enter.len) != enter.len) {
        try self.finish();
        return error.TerminalCleanupFailed;
    }
    return self;
}

pub fn finish(self: *Self) !void {
    if (!self.active) return self.result;
    self.active = false;
    // Each cleanup control receives one nonblocking attempt. None can prevent
    // input/flag restoration or wait on output credit. A partial frame remains
    // an error, including when its synchronized-output terminator was blocked.
    var output_ok = true;
    for ([_][]const u8{ "\x1b[?2026l", "\x1b[0m", "\x1b[?2004l", "\x1b[?25h", "\x1b[?1049l" }) |control| {
        if (std.c.write(1, control.ptr, control.len) != @as(isize, @intCast(control.len))) output_ok = false;
    }
    const flushed = termios.tcflush(0, termios.TCIFLUSH) == 0;
    const restored = Editor.setAttributes(.NOW, self.original);
    var flags_ok = true;
    for (self.flags, 0..) |flags, fd| {
        if (std.c.fcntl(@intCast(fd), std.c.F.SETFL, flags) < 0) flags_ok = false;
    }
    self.result = if (restored) |_| if (flags_ok and output_ok and flushed) {} else error.TerminalCleanupFailed else |_| error.TerminalRestoreFailed;
    return self.result;
}

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
    var buffer: [4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 128]u8 = undefined;
    var notice = std.Io.Writer.fixed(&buffer);
    try notice.writeAll("\nDetached. Host work continues.\nResume: rui resume --store ");
    try Text.writeShellWord(&notice, store);
    try Text.writeShellSession(&notice, session, true);
    try notice.writeAll("\n");
    try self.noticeWithOps(notice.buffered(), ops);
}

fn noticeWithOps(self: *Self, bytes: []const u8, ops: anytype) !void {
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const enabled = ops.setFlags(self.flags[1] | nonblock) == 0;
    const written = if (enabled) ops.writeNotice(bytes) else -1;
    if (ops.setFlags(self.flags[1]) < 0) return error.TerminalCleanupFailed;
    if (written != @as(isize, @intCast(bytes.len))) return error.TerminalCleanupFailed;
}

/// Keep complete command output visible with native terminal custody restored.
/// Confirmation bytes are disposable, never draft or permission input.
pub fn awaitReturn(self: *Self, io: std.Io, stopped: *const std.atomic.Value(bool)) !void {
    std.debug.assert(!self.active);
    if (stopped.load(.acquire)) return error.InteractiveInterrupted;
    if (termios.tcflush(0, termios.TCIFLUSH) != 0) return error.TerminalCleanupFailed;
    try self.noticeWithOps("\nPress Enter to return to the Session.\n", NativeNoticeOps{});
    while (!stopped.load(.acquire)) {
        const byte = (self.next(io, .none, 16) catch |err| switch (err) {
            error.IncompleteTerminalLine => return error.InteractiveInterrupted,
            else => return err,
        }) orelse continue;
        switch (byte) {
            '\n', '\r' => return,
            3, 4 => return error.InteractiveInterrupted,
            else => {},
        }
    }
    return error.InteractiveInterrupted;
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
    // Canonical Ctrl-C can discard a ready line between poll and read. Borrow
    // nonblocking flags only for the read, not the restored-screen wait.
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const enabled = self.active or std.c.fcntl(0, std.c.F.SETFL, self.flags[0] | nonblock) == 0;
    const result = if (enabled) std.posix.read(0, &byte) else error.TerminalCleanupFailed;
    if (!self.active and std.c.fcntl(0, std.c.F.SETFL, self.flags[0]) < 0) return error.TerminalCleanupFailed;
    const count = result catch |err| switch (err) {
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
                if (self.pump) |pump| pump.step(pump.context) catch |err| {
                    // A frame may already be partly written. Never execute a
                    // command and re-enter with this frame's mutated cache.
                    return if (err == error.CommandHandoff) error.Cancelled else err;
                } else return error.TerminalCleanupFailed;
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

pub fn permanent(self: *Self, bytes: []const u8) !void {
    try self.screen.?.append(bytes);
}

pub fn redraw(self: *Self, bytes: []const u8, cursor: usize, status: []const u8, prompt: []const u8, live: *const View.Live) !void {
    const Output = struct {
        terminal: *Self,
        writer: std.Io.Writer,
        failure: ?anyerror = null,

        fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const output: *@This() = @fieldParentPtr("writer", writer);
            output.forward(writer.buffered()) catch return error.WriteFailed;
            writer.end = 0;
            var count: usize = 0;
            for (parts[0 .. parts.len - 1]) |part| {
                output.forward(part) catch return error.WriteFailed;
                count += part.len;
            }
            for (0..splat) |_| output.forward(parts[parts.len - 1]) catch return error.WriteFailed;
            return count + parts[parts.len - 1].len * splat;
        }

        fn forward(output: *@This(), text: []const u8) !void {
            output.terminal.write(text) catch |err| {
                output.failure = err;
                return err;
            };
        }
    };
    var buffer: [4096]u8 = undefined;
    var output: Output = .{ .terminal = self, .writer = .{ .vtable = &.{ .drain = Output.drain }, .buffer = &buffer } };
    const size = geometry();
    self.screen.?.render(&output.writer, size, bytes, cursor, status, prompt, live) catch |err| return output.failure orelse err;
    self.size = size;
}
