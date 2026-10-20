//! Persistent terminal custody, separate from the fresh one-shot choice owner.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Input = @import("TerminalInput.zig");
const Text = @import("TerminalText.zig");
const View = @import("session_view.zig");
const Screen = @import("SessionScreen.zig");
const protocol = @import("protocol.zig");
const termios = @import("posix");
const Self = @This();

original: Editor.Attributes,
flags: [2]c_int,
/// A private duplicate of stdout: command output may be redirected while the
/// Session screen keeps drawing.
output: c_int = 1,
screen: *Screen,
active: bool = true,
result: anyerror!void = {},
size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
/// Set only after the terminal reported mode 1007 reset and Rui enabled it.
alternate_scroll: bool = false,
pump: ?struct { context: *anyopaque, step: *const fn (*anyopaque) anyerror!void } = null,

pub fn begin(screen: *Screen) !Self {
    const original = try Editor.getAttributes();
    var mode = original;
    mode.c_lflag &= ~@as(termios.tcflag_t, termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN);
    mode.c_iflag &= ~@as(termios.tcflag_t, termios.IXON);
    mode.c_cc[termios.VMIN] = 1;
    mode.c_cc[termios.VTIME] = 0;
    const output = std.c.fcntl(1, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (output < 0) return error.TerminalCleanupFailed;
    var owned = true; // Until finish takes over closing it.
    errdefer if (owned) {
        _ = std.c.close(output);
    };
    const flags = [2]c_int{ std.c.fcntl(0, std.c.F.GETFL), std.c.fcntl(output, std.c.F.GETFL) };
    if (flags[0] < 0 or flags[1] < 0) return error.TerminalCleanupFailed;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    // SETFL may mutate before reporting failure. Register restoration before
    // each attempt; an enable failure already reports TerminalCleanupFailed.
    errdefer _ = std.c.fcntl(0, std.c.F.SETFL, flags[0]);
    if (std.c.fcntl(0, std.c.F.SETFL, flags[0] | nonblock) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(output, std.c.F.SETFL, flags[1]);
    if (std.c.fcntl(output, std.c.F.SETFL, flags[1] | nonblock) < 0) return error.TerminalCleanupFailed;
    try Editor.setAttributes(.FLUSH, mode);
    var self: Self = .{ .original = original, .flags = flags, .output = output, .screen = screen };
    // Query width and alternate-scroll modes without changing them. Opening
    // never waits for a reply; unsupported queries are ignored.
    const enter = "\x1b[?1049h\x1b[?2004h\x1b[?2027$p\x1b[?1007$p";
    if (std.c.write(output, enter.ptr, enter.len) != @as(isize, @intCast(enter.len))) {
        owned = false;
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
    const synchronized = std.c.write(self.output, "\x1b[?2026l", 8) == 8;
    const reset = std.c.write(self.output, "\x1b[0m", 4) == 4;
    // Each owned mode is reset even when an earlier reset fails.
    const paste_disabled = std.c.write(self.output, "\x1b[?2004l", 8) == 8;
    const scroll_reset = !self.alternate_scroll or std.c.write(self.output, "\x1b[?1007l", 8) == 8;
    var screen_ok = true;
    for ([_][]const u8{ "\x1b[?25h", "\x1b[?1049l" }) |sequence| {
        if (std.c.write(self.output, sequence.ptr, sequence.len) != @as(isize, @intCast(sequence.len))) screen_ok = false;
    }
    // Input discard is independent of output credit. TCSAFLUSH can drain the
    // same terminal's output and keep it raw while an output peer is absent.
    const flushed = termios.tcflush(0, termios.TCIFLUSH) == 0;
    const restored = Editor.setAttributes(.NOW, self.original);
    var flags_ok = true;
    for (self.flags, [2]c_int{ 0, self.output }) |flags, fd| {
        if (std.c.fcntl(fd, std.c.F.SETFL, flags) < 0) flags_ok = false;
    }
    // The duplicate shares stdout's description: flags already apply to fd 1.
    if (self.output != 1 and std.c.close(self.output) != 0) flags_ok = false;
    self.result = if (restored) |_| if (flags_ok and reset and paste_disabled and scroll_reset and flushed and screen_ok and synchronized) {} else error.TerminalCleanupFailed else |_| error.TerminalRestoreFailed;
    return self.result;
}

/// Optional exit notice cannot hold a restored caller on stdout backpressure.
pub fn detached(self: *Self, store: []const u8, session: []const u8, action: ?u64) !void {
    return self.detachedWithOps(store, session, action, NativeNoticeOps{});
}

const NativeNoticeOps = struct {
    fn setFlags(_: @This(), flags: c_int) c_int {
        return std.c.fcntl(1, std.c.F.SETFL, flags);
    }
    fn writeNotice(_: @This(), bytes: []const u8) isize {
        return std.c.write(1, bytes.ptr, bytes.len);
    }
};

fn detachedWithOps(self: *Self, store: []const u8, session: []const u8, action: ?u64, ops: anytype) !void {
    std.debug.assert(!self.active);
    // Resume plus three exact pending-Action commands; one bounded nonblocking
    // write after restoration. No Action means the original inline bytes.
    var buffer: [4 * (4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 128)]u8 = undefined;
    var notice = std.Io.Writer.fixed(&buffer);
    try notice.writeAll("\nDetached. Host work continues.\nResume: rui session resume --store ");
    try Text.writeShellWord(&notice, store);
    try Text.writeShellSession(&notice, session, true);
    try notice.writeAll("\n");
    if (action) |id| {
        try notice.writeAll("Pending Action: inspect the complete proposal before deciding.\n");
        for ([_][]const u8{ "inspect", "allow", "deny" }) |command| {
            try notice.print("rui action {s} --store ", .{command});
            try Text.writeShellWord(&notice, store);
            try Text.writeShellSession(&notice, session, false);
            try notice.print(" --action {d}\n", .{id});
        }
    }
    try self.noticeWithOps(notice.buffered(), ops);
}

fn noticeWithOps(self: *Self, bytes: []const u8, ops: anytype) !void {
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const enabled = ops.setFlags(self.flags[1] | nonblock) == 0;
    const written = if (enabled) ops.writeNotice(bytes) else -1;
    // Restore every attempted enable, without writing after a failed attempt.
    if (ops.setFlags(self.flags[1]) < 0) return error.TerminalCleanupFailed;
    if (written != @as(isize, @intCast(bytes.len))) return error.TerminalCleanupFailed;
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
                var terminal: Self = .{ .original = undefined, .flags = .{ 0, 2 }, .screen = undefined, .active = false };
                const result = terminal.detachedWithOps("/tmp/a'\\\n", "--s", null, &output);
                const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
                try std.testing.expectEqual(@as(c_int, 2) | (if (restore_failed) nonblock else 0), output.flags);
                try std.testing.expectEqual(@as(usize, 2), output.sets);
                try std.testing.expectEqual(@as(usize, if (enable_failed) 0 else 1), output.writes);
                try std.testing.expect(!output.blocking_write);
                if (!enable_failed) try std.testing.expectEqualStrings(
                    "\nDetached. Host work continues.\nResume: rui session resume --store $'/tmp/a\\'\\\\\\012' -- $'--s'\n",
                    output.bytes[0..output.len],
                );
                if (!enable_failed and !restore_failed and delivery == .full) try result else try std.testing.expectError(error.TerminalCleanupFailed, result);
            }
        }
    }
    var output: Output = .{ .enable_failed = false, .restore_failed = false, .delivery = .full };
    var terminal: Self = .{ .original = undefined, .flags = .{ 0, 2 }, .screen = undefined, .active = false };
    try terminal.detachedWithOps("/tmp/store", "A\x00Z", 913, &output);
    try std.testing.expectEqualStrings("\nDetached. Host work continues.\nResume: rui session resume --store $'/tmp/store' --session-hex 41005a\n" ++
        "Pending Action: inspect the complete proposal before deciding.\n" ++
        "rui action inspect --store $'/tmp/store' --session-hex 41005a --action 913\n" ++
        "rui action allow --store $'/tmp/store' --session-hex 41005a --action 913\n" ++
        "rui action deny --store $'/tmp/store' --session-hex 41005a --action 913\n", output.bytes[0..output.len]);
}

pub const Read = struct { byte: u8, at: i96 };

/// One byte, read within `wait` milliseconds, or null. The input stream owns
/// when its pending input expires; InputDeadline asks the caller to expire it.
pub fn next(self: *Self, io: std.Io, input: *const Input, wait: i32) !?Read {
    const timeout = switch (input.wait(std.Io.Clock.awake.now(io).nanoseconds, wait)) {
        .expire => return error.InputDeadline,
        .poll => |milliseconds| milliseconds,
    };
    var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, timeout) == 0) return null;
    // Poll rounds up and the scheduler may run late: a byte that became
    // readable after the deadline stays queued until pending input expires.
    if (input.wait(std.Io.Clock.awake.now(io).nanoseconds, 0) == .expire) return error.InputDeadline;
    var byte: [1]u8 = undefined;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const enabled = self.active or std.c.fcntl(0, std.c.F.SETFL, self.flags[0] | nonblock) == 0;
    const result = if (enabled) std.posix.read(0, &byte) else error.TerminalCleanupFailed;
    if (!self.active and std.c.fcntl(0, std.c.F.SETFL, self.flags[0]) < 0) return error.TerminalCleanupFailed;
    const count = result catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (count == 0) return error.IncompleteTerminalLine;
    return .{ .byte = byte[0], .at = std.Io.Clock.awake.now(io).nanoseconds };
}

fn write(self: *Self, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(self.output, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => {
                if (self.pump) |pump| try pump.step(pump.context) else return error.TerminalCleanupFailed;
                continue;
            },
            else => return error.TerminalCleanupFailed,
        };
        if (n == 0) return error.TerminalCleanupFailed;
        offset += @intCast(n);
    }
}

pub fn geometry(self: *const Self) std.posix.winsize {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(self.output, @intCast(std.c.T.IOCGWINSZ), &size) != 0 or size.row == 0 or size.col == 0)
        return .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    return size;
}

/// Wheel motion then arrives as arrow keys in the alternate screen. Finish
/// restores the reported reset state.
pub fn enableAlternateScroll(self: *Self) !void {
    if (self.alternate_scroll) return;
    self.alternate_scroll = true;
    try self.write("\x1b[?1007h");
}

pub fn permanent(self: *Self, bytes: []const u8) !void {
    return self.screen.append(bytes);
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
    const size = self.geometry();
    self.screen.render(&output.writer, size, bytes, cursor, status, prompt, live) catch |err| return output.failure orelse err;
    self.size = size;
}
