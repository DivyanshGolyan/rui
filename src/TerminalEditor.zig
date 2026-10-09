const std = @import("std");
const Editor = @This();
const termios = @cImport(@cInclude("termios.h"));

extern fn utf8proc_grapheme_break_stateful(c_int, c_int, *c_int) c_int;
extern fn utf8proc_category(c_int) c_int;
extern fn utf8proc_charwidth(c_int) c_int;

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

pub const Event = enum { none, append, redraw, submit, eof, interrupt, invalid, overflow };
const paste_end = "\x1b[201~";

/// Parser-owned classification; adapters must not inspect escape/paste scratch.
pub const Pending = enum { none, escape, incomplete };

pub fn pending(self: *const Editor) Pending {
    if (self.paste or self.partial_length != 0 or self.escape == .csi or self.escape == .ss3) return .incomplete;
    return if (self.escape == .esc) .escape else .none;
}

/// Call only after the adapter's input inactivity deadline expires. Bare ESC
/// is discarded; all other incomplete input fails without accepting a prefix.
pub fn expire(self: *Editor) !void {
    switch (self.pending()) {
        .none => {},
        .escape => self.escape = .none,
        .incomplete => return error.IncompleteTerminalInput,
    }
}

/// Optional terminal reporting after custody has unwound. One nonblocking
/// write, without retries/drain; restoring shared descriptor flags is required.
pub fn writeAvailable(fd: c_int, vectors: []const std.posix.iovec_const) !void {
    if (std.c.isatty(fd) != 1) return;
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.TerminalCleanupFailed;
    const nonblocking: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const changed = flags & nonblocking == 0;
    if (changed and std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0) return error.TerminalCleanupFailed;
    _ = std.c.writev(fd, vectors.ptr, @intCast(vectors.len));
    if (changed and std.c.fcntl(fd, std.c.F.SETFL, flags) < 0) return error.TerminalCleanupFailed;
}

/// Fatal guidance cannot replace the retained fatal result or reopen blocking
/// reporting to explain an unconfirmed descriptor restoration.
pub fn writeDiagnostic(vectors: []const std.posix.iovec_const) void {
    writeAvailable(2, vectors) catch {};
}

/// One serialized stdin/stdout owner in final caller storage. No draft, history,
/// allocator, worker or borrowed view survives a method return. The input owner
/// feeds byte events and decides submit/Ctrl-C/Ctrl-D; ticks service Client jobs.
pub const Terminal = struct {
    original: std.posix.termios,
    active: bool = false,
    size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
    anchored: bool = false,
    permanent_partial: bool = false,
    pending_since: i96 = 0,
    flags: [2]c_int = undefined,
    painted: usize = 0,
    caret_row: usize = 0,
    frame_size: ?std.posix.winsize = null,
    /// Attach only after constructing the caller in final storage. UI thread
    /// only; callback may service input/owner work, but must never render.
    /// All write slices must remain immutable until that synchronous call ends.
    pump: ?struct { context: *anyopaque, service: *const fn (*anyopaque, std.Io, i32) anyerror!void } = null,

    fn service(self: *Terminal, io: std.Io, wait: i32) !void {
        if (self.pump) |pump| return pump.service(pump.context, io, wait);
        try std.Io.sleep(io, .fromMilliseconds(wait), .awake);
    }

    fn write(self: *Terminal, io: std.Io, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.checkGeometry();
            const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => {
                    try self.service(io, 10);
                    continue;
                },
                else => return error.TerminalCleanupFailed,
            };
            if (n == 0) return error.TerminalCleanupFailed;
            offset += @intCast(n);
            try self.checkGeometry();
        }
    }

    fn checkGeometry(self: *Terminal) !void {
        try self.observeGeometry(windowSize());
    }

    fn observeGeometry(self: *Terminal, current: std.posix.winsize) !void {
        if (self.frame_size) |expected| {
            if (current.row != expected.row or current.col != expected.col) {
                self.anchored = false;
                return error.UncertainTerminalCursor;
            }
        }
    }

    pub const Input = union(enum) {
        byte: u8,
        tick,
        retry, // Ctrl-R, only outside parser custody
        approve, // Ctrl-G, only outside parser custody; not authorization
        timeout, // caller must invoke Editor.expire before reading again
        physical_eof, // invocation failure, never successful detach
    };

    /// Successful begin must be followed by finish. On begin failure after raw
    /// entry, cleanup is performed here instead.
    pub fn begin(io: std.Io) !Terminal {
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
        const nonblock: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (std.c.fcntl(0, std.c.F.SETFL, flags[0] | nonblock) < 0) return error.TerminalCleanupFailed;
        errdefer _ = std.c.fcntl(0, std.c.F.SETFL, flags[0]);
        if (std.c.fcntl(1, std.c.F.SETFL, flags[1] | nonblock) < 0) return error.TerminalCleanupFailed;
        errdefer _ = std.c.fcntl(1, std.c.F.SETFL, flags[1]);
        try std.posix.tcsetattr(0, .FLUSH, mode);
        var self: Terminal = .{ .original = original, .active = true, .flags = flags };
        self.write(io, "\x1b[?2004h") catch |err| {
            try self.finish();
            return err;
        };
        return self;
    }

    /// Persistent cancellation never borrows output credit or pumps workers.
    /// Paste disable is best effort on our still-nonblocking stdout; release
    /// custody and restore configuration before any borrower cancellation/join.
    pub fn finish(self: *Terminal) !void {
        std.debug.assert(self.active);
        _ = std.c.write(1, "\x1b[?2004l", 8);
        try self.restore();
    }

    /// Exact proposal/prompt bytes have been written. Drain stdout while the
    /// invocation services input, then flush old typeahead before fresh choice.
    /// This is authorization handoff, not persistent cancellation policy.
    pub fn prepareChoice(self: *Terminal, io: std.Io, parser: *Editor) !void {
        if (windowSize().col < 16) return error.UncertainTerminalCursor;
        try self.drain(io);
        while (parser.pending() == .incomplete) try self.service(io, 10);
        if (termios.tcflush(0, termios.TCIFLUSH) != 0) return error.TerminalFlushFailed;
        if (std.c.getenv("RUI_TEST_ACTION_READY_FD")) |text| {
            const fd = try std.fmt.parseInt(std.posix.fd_t, std.mem.span(text), 10);
            const ready: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            try ready.writeStreamingAll(io, "x");
        }
    }

    fn restore(self: *Terminal) !void {
        // End output custody before independently restoring both descriptors.
        // NOW restores configuration, not identical kernel history: Darwin
        // may retain PENDIN and FWASWRITTEN. Single-prompt readLine stays FLUSH.
        self.active = false;
        const restored = std.posix.tcsetattr(0, .NOW, self.original);
        var failed = false;
        for (self.flags, 0..) |flags, fd| {
            if (std.c.fcntl(@intCast(fd), std.c.F.SETFL, flags) < 0) failed = true;
        }
        restored catch return error.TerminalRestoreFailed;
        if (failed) return error.TerminalCleanupFailed;
    }

    /// Poll at most 25ms; ticks never renew the 80ms ESC / 2s incomplete input
    /// inactivity deadline. Positive bytes renew it, matching readLine semantics.
    pub fn next(self: *Terminal, io: std.Io, kind: Pending) !Input {
        std.debug.assert(self.active);
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (self.pending_since == 0) self.pending_since = now;
        var wait: i32 = 25;
        if (kind != .none) {
            const budget: i96 = if (kind == .escape) 80_000_000 else 2_000_000_000;
            const remaining = self.pending_since + budget - now;
            if (remaining <= 0) return .timeout;
            wait = @intCast(@min(25, @divTrunc(remaining + 999_999, 1_000_000)));
        }
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, wait) == 0) return .tick;
        var byte: [1]u8 = undefined;
        const count = std.posix.read(0, &byte) catch |err| switch (err) {
            error.WouldBlock => return .tick,
            else => return err,
        };
        if (count == 0) return .physical_eof;
        self.pending_since = std.Io.Clock.awake.now(io).nanoseconds;
        return classify(byte[0], kind);
    }

    fn classify(byte: u8, kind: Pending) Input {
        if (kind == .none) switch (byte) {
            18 => return .retry,
            7 => return .approve,
            else => {},
        };
        return .{ .byte = byte };
    }

    /// Reanchor after geometry changes without erasing uncertain old rows.
    /// No history replay, alternate screen or scroll-region authority.
    fn clear(self: *Terminal, io: std.Io) !void {
        const current = windowSize();
        self.frame_size = current;
        defer self.frame_size = null;
        errdefer self.anchored = false;
        if (self.anchored) {
            if (current.row == self.size.row and current.col == self.size.col) {
                var control: [32]u8 = undefined;
                if (self.caret_row != 0) try self.write(io, try std.fmt.bufPrint(&control, "\x1b[{d}A", .{self.caret_row}));
                try self.write(io, "\r");
                for (0..self.painted) |row| {
                    try self.write(io, "\x1b[2K");
                    if (row + 1 < self.painted) try self.write(io, "\r\n");
                }
                if (self.painted > 1) try self.write(io, try std.fmt.bufPrint(&control, "\x1b[{d}A", .{self.painted - 1}));
                try self.write(io, "\r");
            } else {
                for (0..@max(current.row, 1)) |_| try self.write(io, "\r\n");
                try self.write(io, "[Rui: terminal resized; draft retained]\r\n");
            }
        }
        self.anchored = false;
        self.size = current;
    }

    /// Permanent bytes are already terminal-safe presentation, synchronously
    /// borrowed. Caller streams complete history once, never through redraw.
    /// Chunk boundaries do not add newlines or duplicate content. Redraw ends a
    /// final partial line before installing its footer; don't redraw mid-stream.
    pub fn writePermanent(self: *Terminal, io: std.Io, bytes: []const u8) !void {
        std.debug.assert(self.active);
        try self.clear(io);
        try self.write(io, bytes);
        if (bytes.len != 0) self.permanent_partial = bytes[bytes.len - 1] != '\n';
    }

    /// At most six physical rows, including status; logical bytes stay intact.
    pub fn redraw(self: *Terminal, io: std.Io, bytes: []const u8, cursor: usize, status: []const u8) !void {
        std.debug.assert(self.active and cursor <= bytes.len);
        // Output may pump Input and mutate its banks. Stage every borrowed
        // display byte before the first write, including clear's resize notice.
        const geometry = windowSize();
        if (geometry.row < 2 or geometry.col < 8) return error.UncertainTerminalCursor;
        // Reserve the widest prefix and one non-wrapping terminal column.
        const view = try viewport(bytes, cursor, geometry.col - 6, @min(5, geometry.row - 1));
        var status_copy: [4096]u8 = undefined;
        var status_length = @min(status.len, @min(geometry.col - 3, status_copy.len));
        while (status_length < status.len and status_length != 0 and status[status_length] & 0xc0 == 0x80)
            status_length -= 1;
        @memcpy(status_copy[0..status_length], status[0..status_length]);
        for (status_copy[0..status_length]) |byte| if (byte < 32 or byte > 126) return error.UncertainTerminalCursor;
        try self.clear(io);
        self.frame_size = geometry;
        defer self.frame_size = null;
        errdefer self.anchored = false;
        try self.checkGeometry();
        if (self.permanent_partial) {
            try self.write(io, "\r\n");
            self.permanent_partial = false;
        }
        try self.write(io, "\r");
        try self.write(io, status_copy[0..status_length]);
        if (view.first != 0 or view.hidden_after) try self.write(io, " ~");
        for (0..view.rows) |row| {
            try self.write(io, "\r\n");
            try self.write(io, if (row == 0) "rui> " else "> ");
            try self.write(io, view.data[row][0..view.lengths[row]]);
        }
        var control: [32]u8 = undefined;
        const up = view.rows - 1 - view.caret.row;
        if (up != 0) try self.write(io, try std.fmt.bufPrint(&control, "\x1b[{d}A", .{up}));
        try self.write(io, try std.fmt.bufPrint(&control, "\r\x1b[{d}C", .{view.caret.col + @as(usize, if (view.caret.row == 0) 5 else 2)}));
        self.painted = view.rows + 1;
        self.caret_row = view.caret.row + 1;
        self.size = geometry;
        self.anchored = true; // cursor remains at the actual draft caret
    }

    const Position = struct { row: usize = 0, col: usize = 0 };
    const Viewport = struct {
        data: [5][4096]u8 = undefined,
        lengths: [5]usize = @splat(0),
        rows: usize,
        first: usize,
        caret: Position,
        hidden_after: bool,
    };

    // Two forward scans: geometry first, then immutable bounded presentation.
    // No index or logical payload cache. An unrenderably large cluster fails.
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
                var regional: usize = 0;
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
                    if (scalar == 0xfe0f or scalar == 0x20e3) width = @max(width, 2);
                    if (scalar >= 0x1f1e6 and scalar <= 0x1f1ff) regional += 1;
                    if (regional == 2) width = @max(width, 2);
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
                result = .{ .rows = rows, .first = first, .caret = .{ .row = caret.row - first, .col = caret.col }, .hidden_after = pos.row >= first + rows };
            }
        }
        return result;
    }

    const Drain = struct {
        stopped: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        result: anyerror!void = undefined,
        fn interrupted(_: std.posix.SIG) callconv(.c) void {}
        fn run(self: *Drain) void {
            self.result = self.wait();
            self.done.store(true, .release);
        }
        fn wait(self: *Drain) !void {
            var set = std.posix.sigemptyset();
            std.posix.sigaddset(&set, .USR1);
            var original: std.posix.sigset_t = undefined;
            if (std.c.pthread_sigmask(@intCast(std.posix.SIG.UNBLOCK), &set, &original) != 0) return error.TerminalCleanupFailed;
            defer _ = std.c.pthread_sigmask(@intCast(std.posix.SIG.SETMASK), &original, &set);
            while (true) {
                if (self.stopped.load(.acquire)) return error.InteractiveInterrupted;
                const rc = termios.tcdrain(1);
                if (self.stopped.load(.acquire)) return error.InteractiveInterrupted;
                if (rc == 0) return;
                if (std.posix.errno(rc) != .INTR) return error.TerminalCleanupFailed;
            }
        }
    };

    // Private joinable native drain borrower; it never reads input or writes.
    fn drain(self: *Terminal, io: std.Io) !void {
        var saved_action: std.posix.Sigaction = undefined;
        std.posix.sigaction(.USR1, null, &saved_action);
        if (saved_action.handler.handler != std.posix.SIG.DFL and saved_action.handler.handler != std.posix.SIG.IGN) return error.TerminalDrainSignalInUse;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = Drain.interrupted }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.USR1, &action, null);
        defer std.posix.sigaction(.USR1, &saved_action, null);
        var borrower: Drain = .{};
        const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 + (std.options.signal_stack_size orelse 0) }, Drain.run, .{&borrower});
        var failure: ?anyerror = null;
        while (!borrower.done.load(.acquire)) {
            if (failure == null) self.service(io, 10) catch |err| {
                failure = err;
                // Do not leave raw mode hostage to native drain interruption.
                if (self.active) self.finish() catch |cleanup| {
                    failure = cleanup;
                };
                borrower.stopped.store(true, .release);
            };
            if (failure != null) {
                _ = std.c.pthread_kill(thread.getHandle(), .USR1);
                std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(10), .awake) catch unreachable;
            }
        }
        thread.join();
        if (failure) |err| return err;
        try borrower.result;
    }
};

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
    const restored = std.posix.tcsetattr(0, .FLUSH, original);
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
        // Borrowed fixture descriptor: prompt visibility alone does not prove
        // the input flush finished. Signal only after that boundary.
        if (std.c.getenv("RUI_TEST_ACTION_READY_FD")) |text| {
            const fd = try std.fmt.parseInt(std.posix.fd_t, std.mem.span(text), 10);
            const ready: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            try ready.writeStreamingAll(io, "x");
        }
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

/// Empty visible text is not replaceable while keyboard/paste input or a sticky
/// rejection still has custody. Completed escape scratch is not pending input.
pub fn pristine(self: *const Editor) bool {
    return self.length == 0 and self.partial_length == 0 and self.escape == .none and
        !self.paste and self.paste_prefix_length == 0 and self.rejected == null;
}

// This transition is also the production byte-ingress path. Its result is
// observable through the accepted line; no escape parser reads past a prompt.
pub fn feed(self: *Editor, byte: u8) Event {
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

test "persistent terminal pending expiry preserves draft and delegates controls" {
    std.testing.refAllDecls(Terminal);
    var storage: [80]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("draft\x1b") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Pending.escape, editor.pending());
    try editor.expire();
    try std.testing.expectEqual(Pending.none, editor.pending());
    try std.testing.expectEqualStrings("draft", storage[0..editor.length]);
    for ("\x1b[") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Pending.incomplete, editor.pending());
    try std.testing.expectError(error.IncompleteTerminalInput, editor.expire());
    editor = .{ .buffer = &storage };
    _ = editor.feed(0xc3);
    try std.testing.expectError(error.IncompleteTerminalInput, editor.expire());
    editor = .{ .buffer = &storage };
    for ("\x1b[200~") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Pending.incomplete, editor.pending());
    try std.testing.expectError(error.IncompleteTerminalInput, editor.expire());
    try std.testing.expectEqual(.retry, std.meta.activeTag(Terminal.classify(18, .none)));
    try std.testing.expectEqual(.approve, std.meta.activeTag(Terminal.classify(7, .none)));
    for ([_]u8{ 7, 18, 3, 4 }) |byte| {
        try std.testing.expectEqual(byte, Terminal.classify(byte, .incomplete).byte);
    }
    try std.testing.expectEqual(@as(u8, 3), Terminal.classify(3, .none).byte);
    try std.testing.expectEqual(@as(u8, 4), Terminal.classify(4, .none).byte);
}

test "production viewport owns multiline Unicode tab and clipped caret presentation" {
    var bytes = "prior\nA\t中e\u{301}🧑‍🌾tail\nnext".*;
    const cursor = "prior\nA\t中e\u{301}".len;
    const view = try Terminal.viewport(&bytes, cursor, 20, 1);
    try std.testing.expectEqualStrings("A       中e\u{301}🧑‍🌾tail", view.data[0][0..view.lengths[0]]);
    try std.testing.expectEqual(Terminal.Position{ .row = 0, .col = 11 }, view.caret);
    try std.testing.expect(view.first != 0 and view.hidden_after);
    @memset(&bytes, 'x'); // Input bank reuse cannot alter any displayed bytes.
    try std.testing.expectEqualStrings("A       中e\u{301}🧑‍🌾tail", view.data[0][0..view.lengths[0]]);
    try std.testing.expect(@sizeOf(Terminal) <= 256);
}

test "partial footer geometry loss retires relative cursor authority" {
    const size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    var terminal: Terminal = .{ .original = undefined, .size = size, .frame_size = size, .anchored = true, .painted = 6, .caret_row = 4 };
    try terminal.observeGeometry(size);
    var resized = size;
    resized.row = 3;
    try std.testing.expectError(error.UncertainTerminalCursor, terminal.observeGeometry(resized));
    try std.testing.expect(!terminal.anchored);
    terminal.anchored = true;
    resized = size;
    resized.col = 20;
    try std.testing.expectError(error.UncertainTerminalCursor, terminal.observeGeometry(resized));
    try std.testing.expect(!terminal.anchored);
    const view = try Terminal.viewport("retained draft", 14, resized.col - 6, @min(5, resized.row - 1));
    try std.testing.expect(view.rows <= 5);
    try std.testing.expect(view.caret.col + 5 < resized.col);
}

test "persistent viewport wraps cells and clips physical rows without losing logical bytes" {
    const bytes = "a\n界é\n👩‍💻\nz";
    const view = try Terminal.viewport(bytes, bytes.len, 8, 2);
    try std.testing.expectEqual(@as(usize, 2), view.first);
    try std.testing.expectEqual(@as(usize, 2), view.rows);
    try std.testing.expectEqual(Terminal.Position{ .row = 1, .col = 1 }, view.caret);
    try std.testing.expectEqualStrings("👩‍💻", view.data[0][0..view.lengths[0]]);
    const wrap = try Terminal.viewport("xxxxxxx🇺🇸Z", 7 + "🇺🇸".len, 8, 5);
    try std.testing.expectEqual(Terminal.Position{ .row = 1, .col = 2 }, wrap.caret);
    const tab = try Terminal.viewport("x\tZ", 2, 10, 5);
    try std.testing.expectEqual(@as(usize, 8), tab.caret.col);
    try std.testing.expectEqualStrings("x       Z", tab.data[0][0..tab.lengths[0]]);
    const clipped = try Terminal.viewport(bytes, 1, 8, 2);
    try std.testing.expect(clipped.hidden_after);
    var mutable = "A中é".*;
    const owned = try Terminal.viewport(&mutable, mutable.len, 8, 5);
    @memset(&mutable, 'x');
    try std.testing.expectEqualStrings("A中é", owned.data[0][0..owned.lengths[0]]);
    try std.testing.expectEqual(@as(usize, 4), owned.caret.col);
}
