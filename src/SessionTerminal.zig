//! Persistent terminal custody, separate from the fresh one-shot choice owner.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Input = @import("TerminalInput.zig");
const Text = @import("TerminalText.zig");
const View = @import("session_view.zig");
const Screen = @import("SessionScreen.zig");
const protocol = @import("protocol.zig");
const attention = @import("attention.zig");
const preferences = @import("preferences.zig");
const termios = @import("posix");
const Self = @This();

original: Editor.Attributes,
flags: [2]c_int,
/// A private duplicate of stdout: command output may be redirected while the
/// Session screen keeps drawing.
output: c_int = 1,
/// The terminal's input descriptor; tests supply a pipe.
input: c_int = 0,
screen: *Screen,
active: bool = true,
result: anyerror!void = {},
/// When leaving stops waiting for output credit; `finish` sets it.
release_deadline_ms: i64 = 0,
size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
/// Set only after the terminal reported mode 1007 reset and Rui enabled it.
alternate_scroll: bool = false,
/// The terminal's latest focus report. One that never reports stays
/// focused: Rui notifies only when it knows the person looked away.
focused: bool = true,
/// How notifications reach this terminal; null sends none.
notices: ?Notices = null,
/// The notification the next frame writes first. At most one waits; a newer
/// one replaces it.
notification: struct { bytes: [attention.max_bytes]u8 = undefined, len: usize = 0 } = .{},
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
    // Query width and alternate-scroll modes without changing them, and ask
    // for focus reports. Opening never waits for a reply; terminals ignore
    // what they do not support.
    const enter = "\x1b[?1049h\x1b[?2004h\x1b[?1004h\x1b[?2027$p\x1b[?1007$p";
    if (std.c.write(output, enter.ptr, enter.len) != @as(isize, @intCast(enter.len))) {
        owned = false;
        try self.finish();
        return error.TerminalCleanupFailed;
    }
    return self;
}

/// How long leaving waits, in all, for the terminal to take restoration and
/// the Detached notice. A key that leaves while a frame fills the terminal
/// (Darwin's PTY holds 1 KiB) restores once a reading terminal drains; one
/// that does not read fails after this, as before.
pub const release_wait_ms = 1000;

/// Restore before cancelling or joining any Client borrower. Output waits at
/// most `release_wait_ms` for credit, never for a drain; SessionFrontend owns
/// fresh exact approval input.
pub fn finish(self: *Self) !void {
    if (!self.active) return self.result;
    self.active = false;
    self.release_deadline_ms = monotonicMs() + release_wait_ms;
    const ops: NativeOutput = .{ .fd = self.output };
    // The UI owns emitted style, even if a renderer's next window was cancelled.
    // Attempt controls independently within one shared wait.
    const synchronized = writeWithin(ops, "\x1b[?2026l", self.release_deadline_ms);
    const reset = writeWithin(ops, "\x1b[0m", self.release_deadline_ms);
    // Each owned mode is reset even when an earlier reset fails.
    const paste_disabled = writeWithin(ops, "\x1b[?2004l", self.release_deadline_ms);
    const focus_disabled = writeWithin(ops, "\x1b[?1004l", self.release_deadline_ms);
    const scroll_reset = !self.alternate_scroll or writeWithin(ops, "\x1b[?1007l", self.release_deadline_ms);
    var screen_ok = true;
    for ([_][]const u8{ "\x1b[?25h", "\x1b[?1049l" }) |sequence| {
        if (!writeWithin(ops, sequence, self.release_deadline_ms)) screen_ok = false;
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
    self.result = if (restored) |_| if (flags_ok and reset and paste_disabled and focus_disabled and scroll_reset and flushed and screen_ok and synchronized) {} else error.TerminalCleanupFailed else |_| error.TerminalRestoreFailed;
    return self.result;
}

/// Optional exit notice holds a restored caller on stdout backpressure only
/// until restoration's deadline. Without a Session it names the overview
/// instead.
pub fn detached(self: *Self, store: []const u8, session: ?[]const u8, action: ?u64) !void {
    return self.detachedWithOps(store, session, action, NativeNoticeOps{});
}

const NativeNoticeOps = struct {
    fn setFlags(_: @This(), flags: c_int) c_int {
        return std.c.fcntl(1, std.c.F.SETFL, flags);
    }
    fn writeNotice(_: @This(), bytes: []const u8) error{ WouldBlock, Failed }!usize {
        return (NativeOutput{ .fd = 1 }).write(bytes);
    }
    fn waitWritable(_: @This(), milliseconds: i32) void {
        (NativeOutput{ .fd = 1 }).waitWritable(milliseconds);
    }
};

/// One nonblocking output descriptor, as `writeWithin` drives it.
const NativeOutput = struct {
    fd: c_int,

    fn write(self: NativeOutput, bytes: []const u8) error{ WouldBlock, Failed }!usize {
        while (true) {
            const n = std.c.write(self.fd, bytes.ptr, bytes.len);
            if (n >= 0) return @intCast(n);
            switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.Failed,
            }
        }
    }
    fn waitWritable(self: NativeOutput, milliseconds: i32) void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        // A failed or interrupted wait is one more attempt before the deadline.
        _ = std.posix.poll(&fds, milliseconds) catch {};
    }
};

/// Writes all of `bytes` before `deadline_ms`, waiting for credit between
/// partial writes; false when the terminal refused them or did not take them
/// in time. An expired deadline still makes one attempt.
fn writeWithin(ops: anytype, bytes: []const u8, deadline_ms: i64) bool {
    var offset: usize = 0;
    while (true) {
        offset += ops.write(bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            error.Failed => return false,
        };
        if (offset == bytes.len) return true;
        const left = deadline_ms - monotonicMs();
        if (left <= 0) return false;
        ops.waitWritable(@intCast(@min(left, std.math.maxInt(i32))));
    }
}

fn monotonicMs() i64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now) == 0);
    return @as(i64, now.sec) * std.time.ms_per_s + @divFloor(now.nsec, std.time.ns_per_ms);
}

fn detachedWithOps(self: *Self, store: []const u8, opened: ?[]const u8, action: ?u64, ops: anytype) !void {
    std.debug.assert(!self.active);
    // Resume plus three exact pending-Action commands; one bounded nonblocking
    // write after restoration. No Action means the original inline bytes.
    var buffer: [4 * (4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 128)]u8 = undefined;
    var notice = std.Io.Writer.fixed(&buffer);
    const session = opened orelse {
        try notice.writeAll("\nDetached. Host work continues.\nOverview: rui --store ");
        try Text.writeShellWord(&notice, store);
        try notice.writeAll("\n");
        return self.noticeWithOps(notice.buffered(), ops);
    };
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
    const Output = struct {
        ops: @TypeOf(ops),
        fn write(output: @This(), part: []const u8) error{ WouldBlock, Failed }!usize {
            return output.ops.writeNotice(part);
        }
        fn waitWritable(output: @This(), milliseconds: i32) void {
            output.ops.waitWritable(milliseconds);
        }
    };
    const written = enabled and writeWithin(Output{ .ops = ops }, bytes, self.release_deadline_ms);
    // Restore every attempted enable, without writing after a failed attempt.
    if (ops.setFlags(self.flags[1]) < 0) return error.TerminalCleanupFailed;
    if (!written) return error.TerminalCleanupFailed;
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
        waits: usize = 0,
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
        fn writeNotice(self: *@This(), bytes: []const u8) error{ WouldBlock, Failed }!usize {
            self.writes += 1;
            const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
            self.blocking_write = self.blocking_write or self.flags & nonblock == 0;
            @memcpy(self.bytes[0..bytes.len], bytes);
            self.len = bytes.len;
            return switch (self.delivery) {
                .failed => error.Failed,
                .zero => 0,
                .short => bytes.len - 1,
                .full => bytes.len,
            };
        }
        fn waitWritable(self: *@This(), _: i32) void {
            self.waits += 1;
        }
    };
    for ([_]bool{ false, true }) |enable_failed| {
        for ([_]bool{ false, true }) |restore_failed| {
            for ([_]@FieldType(Output, "delivery"){ .failed, .zero, .short, .full }) |delivery| {
                var output: Output = .{ .enable_failed = enable_failed, .restore_failed = restore_failed, .delivery = delivery };
                var terminal: Self = .{ .original = undefined, .flags = .{ 0, 2 }, .screen = undefined, .active = false };
                const result = terminal.detachedWithOps("/tmp/a'\\\n", "k7m2qx", null, &output);
                const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
                try std.testing.expectEqual(@as(c_int, 2) | (if (restore_failed) nonblock else 0), output.flags);
                try std.testing.expectEqual(@as(usize, 2), output.sets);
                try std.testing.expectEqual(@as(usize, if (enable_failed) 0 else 1), output.writes);
                try std.testing.expect(!output.blocking_write);
                if (!enable_failed) try std.testing.expectEqualStrings(
                    "\nDetached. Host work continues.\nResume: rui session resume --store $'/tmp/a\\'\\\\\\012' k7m2qx\n",
                    output.bytes[0..output.len],
                );
                if (!enable_failed and !restore_failed and delivery == .full) try result else try std.testing.expectError(error.TerminalCleanupFailed, result);
            }
        }
    }
    var output: Output = .{ .enable_failed = false, .restore_failed = false, .delivery = .full };
    var terminal: Self = .{ .original = undefined, .flags = .{ 0, 2 }, .screen = undefined, .active = false };
    // Leaving the overview names the overview, not a Session.
    try terminal.detachedWithOps("/tmp/store", null, null, &output);
    try std.testing.expectEqualStrings("\nDetached. Host work continues.\nOverview: rui --store $'/tmp/store'\n", output.bytes[0..output.len]);
    try terminal.detachedWithOps("/tmp/store", "09azvw", 913, &output);
    try std.testing.expectEqualStrings("\nDetached. Host work continues.\nResume: rui session resume --store $'/tmp/store' 09azvw\n" ++
        "Pending Action: inspect the complete proposal before deciding.\n" ++
        "rui action inspect --store $'/tmp/store' --session 09azvw --action 913\n" ++
        "rui action allow --store $'/tmp/store' --session 09azvw --action 913\n" ++
        "rui action deny --store $'/tmp/store' --session 09azvw --action 913\n", output.bytes[0..output.len]);
}

test "leaving writes the rest once a full terminal drains, until its deadline" {
    // A terminal full of a frame cut short takes part of the bytes now and
    // the rest after it reads.
    const Draining = struct {
        credit: []const usize,
        taken: std.ArrayList(u8) = .empty,
        writes: usize = 0,
        waits: usize = 0,

        fn write(self: *@This(), bytes: []const u8) error{ WouldBlock, Failed }!usize {
            defer self.writes += 1;
            const room = if (self.writes < self.credit.len) self.credit[self.writes] else 0;
            if (room == 0) return error.WouldBlock;
            const n = @min(room, bytes.len);
            self.taken.appendSliceAssumeCapacity(bytes[0..n]);
            return n;
        }
        fn waitWritable(self: *@This(), _: i32) void {
            self.waits += 1;
        }
    };
    var storage: [64]u8 = undefined;
    var drained: Draining = .{ .credit = &.{ 0, 3, 0, 64 }, .taken = .initBuffer(&storage) };
    try std.testing.expect(writeWithin(&drained, "\x1b[?1049l", monotonicMs() + release_wait_ms));
    try std.testing.expectEqualStrings("\x1b[?1049l", drained.taken.items);
    try std.testing.expectEqual(@as(usize, 3), drained.waits);
    // A terminal that never drains fails once the deadline passes.
    var stuck: Draining = .{ .credit = &.{}, .taken = .initBuffer(&storage) };
    const started = monotonicMs();
    try std.testing.expect(!writeWithin(&stuck, "\x1b[?1049l", started + 20));
    try std.testing.expect(monotonicMs() - started >= 20 and stuck.waits >= 1);
}

pub const Read = struct { byte: u8, at: i96 };

/// One byte, read within `wait` milliseconds, or null. The input stream owns
/// when its pending input expires; InputDeadline asks the caller to expire it.
pub fn next(self: *Self, io: std.Io, input: *const Input, wait: i32) !?Read {
    const timeout = switch (input.wait(std.Io.Clock.awake.now(io).nanoseconds, wait)) {
        .expire => return error.InputDeadline,
        .poll => |milliseconds| milliseconds,
    };
    var fds = [_]std.posix.pollfd{.{ .fd = self.input, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, timeout) == 0) return null;
    var byte: [1]u8 = undefined;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const enabled = self.active or std.c.fcntl(self.input, std.c.F.SETFL, self.flags[0] | nonblock) == 0;
    const result = if (enabled) std.posix.read(self.input, &byte) else error.TerminalCleanupFailed;
    if (!self.active and std.c.fcntl(self.input, std.c.F.SETFL, self.flags[0]) < 0) return error.TerminalCleanupFailed;
    const count = result catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (count == 0) return error.IncompleteTerminalLine;
    return .{ .byte = byte[0], .at = std.Io.Clock.awake.now(io).nanoseconds };
}

/// Writes all of `bytes`. On a full terminal the pump runs, if the borrower
/// set one; otherwise the write fails.
pub fn write(self: *Self, bytes: []const u8) !void {
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

pub const Notices = struct {
    signal: attention.Signal,
    /// Where the preference that turns notifications off lives. It is read
    /// at each notification, so /setup's change applies at once.
    home: []const u8,
    /// Inside tmux, which also changes the conversation's composing hint.
    tmux: bool,

    /// From the environment the terminal runs in.
    pub fn of(environ: *const std.process.Environ.Map, home: []const u8) Notices {
        const tmux = environ.get("TMUX") != null;
        const multiplexed = tmux or environ.get("STY") != null;
        return .{ .signal = attention.signal(environ.get("TERM") orelse "", environ.get("TERM_PROGRAM") orelse "", multiplexed), .home = home, .tmux = tmux };
    }
};

/// Holds, for the next frame, a notification of `name`'s news and `more`
/// other Sessions' while the terminal is out of focus and notifications are
/// on. Unreadable preferences leave notifications on, the default.
pub fn notify(self: *Self, name: []const u8, kind: attention.Kind, more: usize) void {
    if (self.focused) return;
    const notices = self.notices orelse return;
    const saved = preferences.load(notices.home) catch preferences.Values{};
    if (!saved.notifications) return;
    var out = std.Io.Writer.fixed(&self.notification.bytes);
    attention.write(&out, notices.signal, name, kind, more) catch unreachable;
    self.notification.len = out.buffered().len;
}

/// The waiting notification, which the caller writes as the first bytes of
/// its next frame, through that frame's write: so it never lands inside
/// another sequence, and a full terminal pumps rather than fails. The bytes
/// hold until the next `notify`; a frame that fails drops them.
pub fn takeNotification(self: *Self) []const u8 {
    defer self.notification.len = 0;
    return self.notification.bytes[0..self.notification.len];
}

pub fn notificationWaiting(self: *const Self) bool {
    return self.notification.len != 0;
}

pub fn permanent(self: *Self, bytes: []const u8) !void {
    return self.screen.append(bytes);
}

/// Writes the screen's selected frame. The receipt exists only after every
/// byte and the final flush succeeded; a failure returns no receipt.
pub fn redraw(self: *Self, bytes: []const u8, cursor: usize, footer: Screen.Footer, live: *const View.Live) !Screen.Delivered {
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
    comptime std.debug.assert(attention.max_bytes <= buffer.len);
    var output: Output = .{ .terminal = self, .writer = .{ .vtable = &.{ .drain = Output.drain }, .buffer = &buffer } };
    // The empty buffer holds it whole; the frame's flush writes it first.
    output.writer.writeAll(self.takeNotification()) catch unreachable;
    const size = self.geometry();
    const delivered = self.screen.render(&output.writer, size, bytes, cursor, footer, live) catch |err| return output.failure orelse err;
    self.size = size;
    return delivered;
}

test "a notification waits for the next frame, only while focus is away and the person has not turned them off" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var terminal: Self = .{ .original = undefined, .flags = undefined, .output = -1, .screen = undefined };
    // No way to notify, then focused: nothing.
    terminal.focused = false;
    terminal.notify("k7m2qx", .finished, 0);
    terminal.notices = .{ .signal = .osc9, .home = home, .tmux = false };
    terminal.focused = true;
    terminal.notify("k7m2qx", .finished, 0);
    try std.testing.expectEqualStrings("", terminal.takeNotification());
    // Away, with no saved preferences: on by default, and taken once.
    terminal.focused = false;
    terminal.notify("k7m2qx", .finished, 0);
    try std.testing.expectEqualStrings("\x1b]9;Rui: k7m2qx finished\x07", terminal.takeNotification());
    try std.testing.expectEqualStrings("", terminal.takeNotification());
    // Turned off, then on again, applies to the next notification; a newer
    // one replaces one still waiting.
    _ = try preferences.update(home, .{ .notifications = false }, .missing);
    terminal.notify("k7m2qx", .approval, 0);
    try std.testing.expectEqualStrings("", terminal.takeNotification());
    _ = try preferences.update(home, .{ .notifications = true }, .missing);
    terminal.notify("k7m2qx", .finished, 0);
    terminal.notify("k7m2qx", .approval, 1);
    try std.testing.expectEqualStrings("\x1b]9;Rui: k7m2qx needs approval, and 1 more\x07", terminal.takeNotification());
}
