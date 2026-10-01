const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Self = @This();
const native = @cImport({
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});
extern fn utf8proc_charwidth(c_int) c_int;
extern fn utf8proc_grapheme_break_stateful(c_int, c_int, *c_int) c_int;

io: std.Io,
editor: Editor,
spare: []u8,
submitted: ?Editor = null,
original: std.posix.termios,
raw: std.posix.termios,
active: bool = true,
output: bool = true,
size: std.posix.winsize,
painted: usize = 0,
caret_row: usize = 0,
deadline: ?i96 = null,
status: [256]u8 = undefined,
status_len: usize = 0,
needs_paint: bool = false,
ready: bool = false,
pending_focus: Event = .none,
// One scoped command may coexist with the immutable unresolved Message and
// editable next draft. Its argument loan ends at finishCommand, not at dequeue.
command_buffer: [65536]u8 = undefined,
command_held: bool = false,
failure: ?anyerror = null,
flags: [2]c_int = undefined,
generation: usize = 0,
painting: bool = false,
focus: enum { draft, staging, choice } = .draft,
focus_buffer: [16]u8 = undefined,
focus_editor: Editor = .{ .buffer = &.{} },
focus_deadline: ?i96 = null,
focus_event: Editor.Event = .none,
output_buffer: [4096]u8 = undefined,
writer_interface: std.Io.Writer = .{ .vtable = &.{ .drain = drainWriter }, .buffer = &.{} },

pub const Event = union(enum) { none, submit: []u8, command: []u8, busy, approve, recover, eof, interrupt, invalid, overflow };
pub const detach_notice = "Rui: Detached. Host work continues.\n";

/// No callbacks or self-pointers: returned value may move into final storage.
/// Both fixed draft banks are exclusively borrowed until close. One immutable
/// submitted draft may coexist with the next composition; there is no queue.
pub fn init(io: std.Io, buffers: *[2][65536]u8) !Self {
    const original = try std.posix.tcgetattr(0);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    var self: Self = .{ .io = io, .editor = .{ .buffer = &buffers[0] }, .spare = &buffers[1], .original = original, .raw = raw, .active = false, .size = windowSize() };
    try self.@"resume"();
    return self;
}

pub fn writer(self: *Self) *std.Io.Writer {
    if (self.writer_interface.buffer.len == 0) self.writer_interface.buffer = &self.output_buffer;
    return &self.writer_interface;
}

fn drainWriter(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Self = @alignCast(@fieldParentPtr("writer_interface", w));
    self.write(w.buffer[0..w.end]) catch |err| {
        self.failure = err;
        return error.WriteFailed;
    };
    w.end = 0;
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        self.write(bytes) catch |err| {
            self.failure = err;
            return error.WriteFailed;
        };
        consumed += bytes.len;
    }
    for (0..splat) |_| {
        const bytes = data[data.len - 1];
        self.write(bytes) catch |err| {
            self.failure = err;
            return error.WriteFailed;
        };
        consumed += bytes.len;
    }
    return consumed;
}

/// A bounded immutable output window permits input service even when a caller
/// passed bytes borrowed from the editable draft. Only this thread writes.
pub fn write(self: *Self, bytes: []const u8) anyerror!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var window: [4096]u8 = undefined;
        const n = @min(window.len, bytes.len - offset);
        @memcpy(window[0..n], bytes[offset..][0..n]);
        var sent: usize = 0;
        while (sent < n) {
            const count = std.c.write(1, window[sent..n].ptr, n - sent);
            if (count < 0) {
                switch (std.posix.errno(count)) {
                    .AGAIN => {
                        try self.service(10);
                        continue;
                    },
                    .INTR => continue,
                    else => return error.TerminalCleanupFailed,
                }
            }
            if (count == 0) return error.TerminalCleanupFailed;
            sent += @intCast(count);
        }
        offset += n;
        if (!self.painting) try self.service(0);
    }
}

/// Both effects are attempted. An error is fatal; do not continue prompting.
pub fn close(self: *Self) !void {
    // Restoration cannot depend on stdout draining. Paste disable is a best
    // effort nonblocking write, not another wait while the terminal is raw.
    self.writeAvailable("\x1b[?2004l");
    const restored = std.posix.tcsetattr(0, .NOW, self.original);
    var failed = false;
    for (self.flags, 1..) |flags, fd| {
        if (std.c.fcntl(@intCast(fd), std.c.F.SETFL, flags) < 0) failed = true;
    }
    restored catch return error.TerminalRestoreFailed;
    self.active = false;
    if (failed) return error.TerminalCleanupFailed;
}

/// Optional detachment notices must not reopen output custody or wait for a
/// reader. Only call before restoring the shared descriptor's blocking flags.
pub fn writeAvailable(self: *Self, bytes: []const u8) void {
    std.debug.assert(self.active);
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

pub fn draft(self: *const Self) []const u8 {
    return self.editor.buffer[0..self.editor.length];
}

/// Borrowed sealed Message, never the current editor. The loan survives input
/// service until capture takes custody or finishReady releases it.
pub fn readyDraft(self: *const Self) ?[]u8 {
    if (!self.ready) return null;
    return self.submitted.?.buffer[0..self.submitted.?.length];
}

pub fn clearDraft(self: *Self) void {
    self.editor.reset();
    self.deadline = null;
    self.needs_paint = true;
}

pub fn finishReady(self: *Self) void {
    if (!self.ready) return;
    self.ready = false;
    self.releaseSubmitted();
}

pub fn finishCommand(self: *Self) void {
    std.debug.assert(self.command_held);
    self.command_held = false;
}

pub fn repaint(self: *Self) !void {
    if (self.needs_paint) try self.paint();
}

/// Capture now owns the sealed bytes on disk. Retain this bank read-only until
/// confirmation/rejection; the composing bank already changed at Enter.
pub fn captureReady(self: *Self) void {
    std.debug.assert(self.ready);
    self.ready = false;
}

pub fn releaseSubmitted(self: *Self) void {
    self.spare = self.submitted.?.buffer;
    self.submitted = null;
    self.needs_paint = true;
}

/// Definite rejection restores the original only if no new composition would
/// be displaced. Otherwise retain both until explicit discard of the original.
pub fn rejectSubmission(self: *Self) bool {
    if (self.editor.length != 0) return false;
    self.spare = self.editor.buffer;
    self.editor = self.submitted.?;
    self.submitted = null;
    self.needs_paint = true;
    return true;
}

fn windowSize() std.posix.winsize {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    _ = std.c.ioctl(1, @intCast(std.c.T.IOCGWINSZ), &size);
    return size;
}

fn move(self: *Self, rows: usize, direction: u8) !void {
    if (rows == 0) return;
    var bytes: [32]u8 = undefined;
    try self.write(try std.fmt.bufPrint(&bytes, "\x1b[{d}{c}", .{ rows, direction }));
}

fn resized(self: *Self) !bool {
    const size = windowSize();
    if (size.row == self.size.row and size.col == self.size.col) return false;
    // Old coordinates are no longer authority. Move forward only, below the
    // viewport, leaving marked stale fragments in ordinary scrollback.
    self.size = size;
    self.painted = 0;
    self.caret_row = 0;
    var n: usize = 0;
    while (n < @max(size.row, 1)) : (n += 1) try self.write("\r\n");
    try self.write("[display restarted after resize]\r\n");
    return true;
}

/// Caller serializes all stdout/stderr rendering inside this boundary.
pub fn beginOutput(self: *Self) !void {
    std.debug.assert(self.active);
    try self.writer().flush();
    _ = try self.resized();
    try self.eraseFooter();
    self.output = true;
}

/// Physical custody survives logical edits. Cleanup uses only the rows and
/// cursor actually emitted, never the now-invalid draft/layout iterator.
fn eraseFooter(self: *Self) !void {
    if (self.painted != 0) {
        try self.move(self.caret_row, 'A');
        self.caret_row = 0;
        try self.write("\r");
        for (0..self.painted) |i| {
            try self.write("\x1b[2K");
            if (i + 1 < self.painted) {
                try self.write("\r\n");
                self.caret_row += 1;
            }
        }
        try self.move(self.caret_row, 'A');
        self.caret_row = 0;
        try self.write("\r");
    }
    self.painted = 0;
}

/// status is bounded presentation only. Long/unsafe status is rejected;
/// its visible presentation may clip to terminal width like the draft.
pub fn endOutput(self: *Self, status: []const u8) !void {
    std.debug.assert(self.active and self.output);
    try self.writer().flush();
    if (status.len > self.status.len) return error.StatusTooLong;
    for (status) |byte| if (byte < 32 or byte > 126) return error.InvalidStatus;
    @memcpy(self.status[0..status.len], status);
    self.status_len = status.len;
    _ = try self.resized();
    try self.write("\r\n");
    self.output = false;
    try self.paint();
}

const Position = struct { row: usize = 0, col: usize = 0 };
const Layout = struct { end: Position, caret: Position, first: usize, rows: usize };
const Cluster = struct { start: usize, end: usize, width: usize, special: u8 };
const Clusters = struct {
    bytes: []const u8,
    offset: usize = 0,
    prior: ?c_int = null,
    state: c_int = 0,

    fn next(self: *Clusters) ?Cluster {
        if (self.offset == self.bytes.len) return null;
        const start = self.offset;
        var width: usize = 0;
        var regional_indicators: u2 = 0;
        while (self.offset < self.bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(self.bytes[self.offset]) catch unreachable;
            const scalar: c_int = @intCast(std.unicode.utf8Decode(self.bytes[self.offset..][0..n]) catch unreachable);
            if (self.prior) |prior| {
                var state = self.state;
                if (utf8proc_grapheme_break_stateful(prior, scalar, &state) != 0 and self.offset != start) break;
                self.state = state;
            }
            self.prior = scalar;
            self.offset += n;
            width = @max(width, @as(usize, @intCast(@max(utf8proc_charwidth(scalar), 0))));
            // Emoji presentation selectors and keycaps occupy a wide cluster.
            if (scalar == 0xfe0f or scalar == 0x20e3) width = @max(width, 2);
            // utf8proc gives each regional indicator width one, but a paired
            // flag is one two-cell grapheme. A lone indicator remains narrow.
            if (scalar >= 0x1f1e6 and scalar <= 0x1f1ff) {
                regional_indicators += 1;
                if (regional_indicators == 2) width = @max(width, 2);
            }
        }
        return .{ .start = start, .end = self.offset, .width = width, .special = self.bytes[start] };
    }
};

fn advance(pos: *Position, cluster: Cluster, columns: usize) usize {
    if (cluster.special == '\n') {
        pos.row += 1;
        pos.col = 0;
        return 0;
    }
    const width = if (cluster.special == '\t') @min(8 - pos.col % 8, columns) else @min(cluster.width, columns);
    if (pos.col + width > columns) {
        pos.row += 1;
        pos.col = 0;
    }
    pos.col += width;
    return width;
}

fn layout(bytes: []const u8, cursor: usize, columns: usize, limit: usize) Layout {
    var pos: Position = .{};
    var caret: Position = .{};
    var it: Clusters = .{ .bytes = bytes };
    while (it.next()) |cluster| {
        const before = pos;
        const width = advance(&pos, cluster, columns);
        if (cluster.start == cursor) {
            caret = if (pos.row != before.row and cluster.special != '\n') .{ .row = pos.row, .col = pos.col - width } else before;
        }
        if (cluster.end == cursor) caret = pos;
    }
    if (cursor == 0) caret = .{};
    const first = if (caret.row >= limit) caret.row - limit + 1 else 0;
    return .{ .end = pos, .caret = caret, .first = first, .rows = @min(limit, pos.row - first + 1) };
}

fn paint(self: *Self) !void {
    self.painting = true;
    defer self.painting = false;
    _ = try self.resized();
    try self.eraseFooter();
    self.paintOnce(self.generation) catch |err| {
        if (err != error.PaintChanged) return err;
        // Only an observed physical resize invalidates footer coordinates.
        // An edit invalidates the plan, not the already emitted row custody.
        if (!try self.resized()) try self.eraseFooter();
        self.needs_paint = true;
    };
}

fn paintWrite(self: *Self, bytes: []const u8, row: usize, generation: usize) !void {
    std.debug.assert(bytes.len <= 4096);
    // Complete the immutable scalar-aligned window even if input changes
    // during EAGAIN. Publish physical geometry BEFORE abandoning the plan.
    try self.write(bytes);
    self.caret_row = row;
    self.painted = @max(self.painted, row + 1);
    if (self.generation != generation) return error.PaintChanged;
}

fn paintOnce(self: *Self, generation: usize) !void {
    if (self.size.row < 2 or self.size.col < 12) return error.TerminalTooSmall;
    const rows: usize = @min(self.size.row - 1, 6);
    // Prompt/continuation occupy two columns on EVERY physical row; leave a spare last
    // column so terminal autowrap never becomes a second geometry authority.
    const columns: usize = self.size.col - 3;
    const header: usize = if (rows > 1 and self.status_len != 0) 1 else 0;
    const plan = layout(self.draft(), self.editor.cursor, columns, rows - header);
    const total = plan.rows + header;
    var control: [32]u8 = undefined;
    self.painted = 1;
    self.caret_row = 0;
    for (1..total) |row| try self.paintWrite("\r\n", row, generation);
    if (total > 1) try self.paintWrite(try std.fmt.bufPrint(&control, "\x1b[{d}A", .{total - 1}), 0, generation);
    if (header != 0) {
        try self.paintWrite("\r", 0, generation);
        try self.paintWrite(self.status[0..@min(self.status_len, self.size.col - 1)], 0, generation);
        try self.paintWrite("\r\n", 1, generation);
    }
    try self.paintWrite("\r> ", header, generation);
    var pos: Position = .{};
    var rendered_row: usize = plan.first;
    var it: Clusters = .{ .bytes = self.draft() };
    // Fixed output window: never a retained transcript or payload-sized copy.
    var window: [4096]u8 = undefined;
    var used: usize = 0;
    while (it.next()) |cluster| {
        const width = advance(&pos, cluster, columns);
        if (pos.row < plan.first or pos.row >= plan.first + plan.rows) continue;
        if (pos.row != rendered_row) {
            try self.paintWrite(window[0..used], self.caret_row, generation);
            used = 0;
            try self.paintWrite("\r\n  ", self.caret_row + 1, generation);
            rendered_row = pos.row;
        }
        if (cluster.special == '\n') continue;
        if (cluster.special == '\t') {
            if (used + width > window.len) {
                try self.paintWrite(window[0..used], self.caret_row, generation);
                used = 0;
            }
            @memset(window[used..][0..width], ' ');
            used += width;
        } else {
            // A combining cluster may exceed the output window. Split only
            // between scalars, checking the generation before rereading draft.
            var offset = cluster.start;
            while (offset < cluster.end) {
                const n = std.unicode.utf8ByteSequenceLength(self.editor.buffer[offset]) catch unreachable;
                if (used + n > window.len) {
                    try self.paintWrite(window[0..used], self.caret_row, generation);
                    used = 0;
                }
                @memcpy(window[used..][0..n], self.editor.buffer[offset..][0..n]);
                used += n;
                offset += n;
            }
        }
    }
    try self.paintWrite(window[0..used], self.caret_row, generation);
    const caret_row = plan.caret.row - plan.first + header;
    if (self.caret_row != caret_row) try self.paintWrite(try std.fmt.bufPrint(&control, "\x1b[{d}A", .{self.caret_row - caret_row}), caret_row, generation);
    try self.paintWrite(try std.fmt.bufPrint(&control, "\r\x1b[{d}C", .{2 + plan.caret.col}), caret_row, generation);
    self.needs_paint = false;
}

fn incomplete(editor: *const Editor) bool {
    return editor.escape != .none or editor.paste or editor.partial_length != 0;
}

pub fn poll(self: *Self, timeout_ms: i32) !Event {
    std.debug.assert(self.active and !self.output);
    if (self.readyDraft()) |bytes| return .{ .submit = bytes };
    if (self.pending_focus != .none) {
        const event = self.pending_focus;
        self.pending_focus = .none;
        return event;
    }
    const event = try self.pollInput(timeout_ms, true);
    if (event == .approve) self.stageApproval();
    return event;
}

/// Enter establishes custody before any write can service another input byte.
/// Both ordinary polling and output/network service use this same transition.
fn sealInput(self: *Self) Event {
    const bytes = self.draft();
    if (isCommand(bytes)) {
        if (self.command_held or self.pending_focus != .none) return .none;
        return self.holdCommand(bytes);
    }
    if (self.submitted != null) return .busy;
    self.submitted = self.editor;
    self.editor = .{ .buffer = self.spare };
    self.deadline = null;
    self.needs_paint = true;
    self.ready = true;
    return .{ .submit = self.readyDraft().? };
}

fn isCommand(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "/") and !std.mem.startsWith(u8, bytes, "//");
}

fn holdCommand(self: *Self, bytes: []const u8) Event {
    std.debug.assert(!self.command_held and bytes.len <= self.command_buffer.len);
    @memcpy(self.command_buffer[0..bytes.len], bytes);
    self.command_held = true;
    self.clearDraft();
    if (std.mem.eql(u8, self.command_buffer[0..bytes.len], "/approve")) self.stageApproval();
    return .{ .command = self.command_buffer[0..bytes.len] };
}

fn stageApproval(self: *Self) void {
    // Establish focus at the key boundary, not after the next network wait.
    // Following typeahead must never become an ordinary message admission.
    self.resetFocus(.staging);
}

/// Preserve any staging input/deadline already established at Ctrl-G/Enter.
pub fn beginApproval(self: *Self) void {
    if (self.focus == .draft) self.stageApproval();
    std.debug.assert(self.focus == .staging);
}

pub fn finishApproval(self: *Self) void {
    self.focus = .draft;
    self.focus_deadline = null;
    self.focus_event = .none;
}

fn resetFocus(self: *Self, focus: @FieldType(Self, "focus")) void {
    std.debug.assert(focus != .draft);
    self.focus = focus;
    self.focus_editor = .{ .buffer = &self.focus_buffer, .allow_paste = false };
    self.focus_deadline = null;
    self.focus_event = .none;
}

fn inputWait(editor: *Editor, deadline: *?i96, now: i96, timeout_ms: i32) !i32 {
    const due = deadline.* orelse return timeout_ms;
    if (now >= due) {
        if (editor.escape != .esc or editor.paste or editor.partial_length != 0) return error.IncompleteTerminalInput;
        editor.escape = .none;
        deadline.* = null;
        return timeout_ms;
    }
    const remaining: i32 = @intCast(@divTrunc(due - now + 999999, 1000000));
    return if (timeout_ms < 0 or remaining < timeout_ms) remaining else timeout_ms;
}

fn receivedDeadline(editor: *const Editor, now: i96) ?i96 {
    return if (incomplete(editor)) now + (if (editor.escape == .esc) @as(i96, 80000000) else 2000000000) else null;
}

fn focusByte(self: *Self, byte: u8, received: i96) !void {
    // Poll readiness is not proof the byte arrived before expiry. Validate
    // ingress before feeding a delayed tail, including during blocked output.
    _ = try inputWait(&self.focus_editor, &self.focus_deadline, received, 0);
    const event = self.focus_editor.feed(byte);
    self.focus_deadline = receivedDeadline(&self.focus_editor, received);
    if (event == .interrupt or event == .eof) return error.InteractiveInterrupted;
    if (self.focus == .choice and (event == .submit or event == .invalid or event == .overflow)) {
        self.focus_event = event;
    } else if (self.focus == .staging and event == .submit) {
        self.resetFocus(.staging);
    }
}

/// Network/output wait service changes only logical input, never renders or
/// recursively dispatches a command. Enter transfers the existing draft bank.
pub fn service(self: *Self, timeout_ms: i32) !void {
    if (self.focus != .draft) {
        var wait = timeout_ms;
        while (true) {
            wait = try inputWait(&self.focus_editor, &self.focus_deadline, std.Io.Clock.awake.now(self.io).nanoseconds, wait);
            if (self.focus == .choice and self.focus_event != .none) return;
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, wait) == 0) {
                _ = try inputWait(&self.focus_editor, &self.focus_deadline, std.Io.Clock.awake.now(self.io).nanoseconds, 0);
                return;
            }
            wait = 0;
            var byte: [1]u8 = undefined;
            if (try std.posix.read(0, &byte) == 0) return error.InteractiveInterrupted;
            try self.focusByte(byte[0], std.Io.Clock.awake.now(self.io).nanoseconds);
        }
    }
    const event = try self.pollInput(timeout_ms, false);
    switch (event) {
        .interrupt, .eof => return error.InteractiveInterrupted,
        .command => |bytes| {
            if (std.mem.eql(u8, bytes, "/exit")) {
                self.writeAvailable(detach_notice);
                return error.InteractiveInterrupted;
            }
            self.pending_focus = event;
        },
        .approve => if (self.pending_focus == .none) {
            self.stageApproval();
            self.pending_focus = event;
        },
        .recover => if (self.pending_focus == .none) {
            self.pending_focus = event;
        },
        .none, .submit => {},
        .busy, .invalid, .overflow => if (self.pending_focus == .none) {
            self.pending_focus = event;
        },
    }
}

fn pollInput(self: *Self, timeout_ms: i32, paint_input: bool) !Event {
    var dirty = if (paint_input) try self.resized() else false;
    dirty = dirty or self.needs_paint;
    const start = std.Io.Clock.awake.now(self.io).nanoseconds;
    var first = true;
    while (true) {
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        const wait = try inputWait(&self.editor, &self.deadline, now, if (first) timeout_ms else 0);
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, wait) == 0) break;
        var byte: [1]u8 = undefined;
        const count = std.posix.read(0, &byte) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (count == 0) return if (self.editor.length == 0 and !incomplete(&self.editor)) .eof else error.IncompleteTerminalLine;
        first = false;
        const received = std.Io.Clock.awake.now(self.io).nanoseconds;
        _ = try inputWait(&self.editor, &self.deadline, received, 0);
        // Explicit focus entry never interprets existing draft or marked paste
        // as authorization. A fresh choice parser owns the subsequent input.
        if (byte[0] == 7 and !incomplete(&self.editor)) return .approve;
        // Recovery resends the held capture, never the composing draft. Like
        // approval entry, this shortcut is not recognized inside marked paste.
        if (byte[0] == 18 and !incomplete(&self.editor)) return .recover;
        // The owning layout establishes a single-row ASCII tail. Its one
        // erased cell cannot reflow or move another row; retain the existing
        // paced-edit bound without repainting the entire footer per key.
        const erase_tail = paint_input and !dirty and self.painted != 0 and
            (byte[0] == 8 or byte[0] == 127) and !incomplete(&self.editor) and
            self.editor.rejected == null and self.editor.plain_ascii and
            self.editor.cursor == self.editor.length and self.editor.length != 0 and
            self.editor.length < self.size.col - 9;
        const event = self.editor.feed(byte[0]);
        self.generation +%= 1;
        self.deadline = receivedDeadline(&self.editor, received);
        if (erase_tail) {
            std.debug.assert(event == .redraw);
            const generation = self.generation;
            try self.write("\x08\x1b[0K");
            if (self.generation != generation) dirty = true;
            continue;
        }
        switch (event) {
            .append, .redraw => dirty = true,
            .submit => {
                self.needs_paint = dirty;
                const sealed = self.sealInput();
                if (self.needs_paint and paint_input) try self.paint();
                return sealed;
            },
            .eof => return .eof,
            .interrupt => return .interrupt,
            .invalid => return .invalid,
            .overflow => return .overflow,
            .none => {},
        }
        if (now - start >= 16000000) break;
    }
    self.needs_paint = dirty;
    if (dirty and paint_input) try self.paint();
    return .none;
}

/// After beginOutput and exact Action display. Choice storage/parser are
/// independent; ordinary draft and any partial marked paste remain untouched.
pub fn readChoice(self: *Self, prompt: []const u8) !?[]const u8 {
    std.debug.assert(self.active and self.output);
    std.debug.assert(self.focus == .staging);
    const size = windowSize();
    if (size.col <= prompt.len) return error.TerminalTooSmall;
    try self.writer().flush();
    try self.drainOutput();
    _ = try inputWait(&self.focus_editor, &self.focus_deadline, std.Io.Clock.awake.now(self.io).nanoseconds, 0);
    if (native.tcflush(0, native.TCIFLUSH) != 0) return error.TerminalFlushFailed;
    // This flush retires staging input and its deadline together. The same
    // terminal-owned storage becomes a fresh paste-rejecting choice parser.
    self.resetFocus(.choice);
    defer if (self.focus == .choice) self.resetFocus(.staging);
    if (std.c.getenv("RUI_TEST_ACTION_READY_FD")) |text| {
        const fd = try std.fmt.parseInt(std.posix.fd_t, std.mem.span(text), 10);
        const ready: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        try ready.writeStreamingAll(self.io, "x");
    }
    try self.write(prompt);
    while (true) {
        try self.service(100);
        switch (self.focus_event) {
            .submit => {
                const length = self.focus_editor.length;
                const selected = self.focus_buffer[0];
                self.resetFocus(.staging);
                try self.write("\r\n");
                if (length != 1) return error.InvalidTerminalInput;
                return switch (selected) {
                    'a' => "a",
                    'd' => "d",
                    'l' => "l",
                    else => error.InvalidTerminalInput,
                };
            },
            .eof => return null,
            .interrupt => return error.InteractiveInterrupted,
            .invalid, .overflow => return error.InvalidTerminalInput,
            else => {},
        }
    }
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
        if (std.c.pthread_sigmask(@intCast(std.posix.SIG.UNBLOCK), &set, &original) != 0) return error.TerminalFlushFailed;
        defer _ = std.c.pthread_sigmask(@intCast(std.posix.SIG.SETMASK), &original, &set);
        while (true) {
            if (self.stopped.load(.acquire)) return error.InteractiveInterrupted;
            const result = native.tcdrain(1);
            // A racing stop never publishes successful presentation, including
            // a native success which raced with the final signal delivery.
            if (self.stopped.load(.acquire)) return error.InteractiveInterrupted;
            if (result == 0) return;
            if (std.posix.errno(result) != .INTR) return error.TerminalFlushFailed;
        }
    }
};

/// Actual native drain has a private joinable borrower, not an output worker.
/// Repeated targeted signals cover the stop-check-to-syscall lost-signal race.
fn drainOutput(self: *Self) !void {
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR1, null, &previous);
    if (previous.handler.handler != std.posix.SIG.DFL and previous.handler.handler != std.posix.SIG.IGN) return error.TerminalDrainSignalInUse;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = Drain.interrupted }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.USR1, &action, null);
    defer std.posix.sigaction(.USR1, &previous, null);
    var drain: Drain = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 + (std.options.signal_stack_size orelse 0) }, Drain.run, .{&drain});
    var failure: ?anyerror = null;
    while (!drain.done.load(.acquire)) {
        if (failure == null) self.service(10) catch |err| {
            failure = err;
            drain.stopped.store(true, .release);
            // Native termios and shared flags are restored independently of
            // paste output before waiting for interrupted drain completion.
            if (self.active) self.close() catch @panic("terminal restoration failed");
        };
        if (failure != null) {
            _ = std.c.pthread_kill(thread.getHandle(), .USR1);
            std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(10), .awake) catch unreachable;
        }
    }
    thread.join();
    if (failure) |err| return err;
    try drain.result;
}

pub fn @"suspend"(self: *Self) !void {
    if (!self.output) try self.beginOutput();
    try self.close();
}

pub fn @"resume"(self: *Self) !void {
    std.debug.assert(!self.active);
    // stdout/stderr may share an open-file description; snapshot BOTH first.
    self.flags = .{ std.c.fcntl(1, std.c.F.GETFL), std.c.fcntl(2, std.c.F.GETFL) };
    if (self.flags[0] < 0 or self.flags[1] < 0) return error.TerminalCleanupFailed;
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (std.c.fcntl(1, std.c.F.SETFL, self.flags[0] | nonblocking) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(1, std.c.F.SETFL, self.flags[0]);
    if (std.c.fcntl(2, std.c.F.SETFL, self.flags[1] | nonblocking) < 0) return error.TerminalCleanupFailed;
    errdefer _ = std.c.fcntl(2, std.c.F.SETFL, self.flags[1]);
    try std.posix.tcsetattr(0, .FLUSH, self.raw);
    self.active = true;
    self.write("\x1b[?2004h") catch |err| {
        // Raw mode is already installed. Keep custody until restoration is
        // confirmed, even when stdout cannot accept the paste-mode sequence.
        std.posix.tcsetattr(0, .NOW, self.original) catch return error.TerminalRestoreFailed;
        self.active = false;
        return err;
    };
    self.size = windowSize();
    self.deadline = if (incomplete(&self.editor)) std.Io.Clock.awake.now(self.io).nanoseconds + 2000000000 else null;
    self.output = true;
}

test "SessionTerminal layout clips rows without clipping exact draft" {
    std.testing.refAllDecls(Self);
    const plan = layout("a\n界é\n👩‍💻\nz", "a\n界é\n👩‍💻\nz".len, 8, 2);
    try std.testing.expectEqual(@as(usize, 2), plan.first);
    try std.testing.expectEqual(@as(usize, 2), plan.rows);
    try std.testing.expectEqual(@as(usize, 1), plan.caret.col);
    try std.testing.expectEqual(@as(usize, 3), layout("界é", "界é".len, 8, 2).caret.col);
    try std.testing.expectEqual(@as(usize, 2), layout("👩‍💻", "👩‍💻".len, 8, 2).caret.col);
    try std.testing.expectEqual(@as(usize, 8), layout("x\t", 2, 10, 2).caret.col);
}

test "SessionTerminal flag pair occupies two cells across cursor and wrap" {
    const flag = "🇺🇸";
    try std.testing.expectEqual(@as(usize, 2), layout(flag ++ "Z", flag.len, 8, 2).caret.col);
    try std.testing.expectEqual(Position{ .row = 1, .col = 2 }, layout("xxxxxxx" ++ flag ++ "Z", 7 + flag.len, 8, 2).caret);
    try std.testing.expectEqual(@as(usize, 1), layout("🇺", "🇺".len, 8, 2).caret.col);
}

test "SessionTerminal unresolved submission is immutable while the next draft changes" {
    var buffers: [2][65536]u8 = undefined;
    var owner: Self = .{ .io = std.testing.io, .editor = .{ .buffer = &buffers[0] }, .spare = &buffers[1], .original = undefined, .raw = undefined, .size = undefined };
    for ("original") |byte| _ = owner.editor.feed(byte);
    _ = owner.sealInput();
    owner.captureReady();
    try std.testing.expectEqual(@as(usize, 0), owner.draft().len);
    for ("next") |byte| _ = owner.editor.feed(byte);
    try std.testing.expectEqualStrings("original", owner.submitted.?.buffer[0..owner.submitted.?.length]);
    try std.testing.expect(!owner.rejectSubmission());
    owner.releaseSubmitted();
    try std.testing.expectEqualStrings("next", owner.draft());
    _ = owner.sealInput();
    owner.captureReady();
    try std.testing.expect(owner.rejectSubmission());
    try std.testing.expectEqualStrings("next", owner.draft());
}

test "SessionTerminal command loan is independent of unresolved admission and next composition" {
    var buffers: [2][65536]u8 = undefined;
    var owner: Self = .{ .io = std.testing.io, .editor = .{ .buffer = &buffers[0] }, .spare = &buffers[1], .original = undefined, .raw = undefined, .size = undefined };
    for ("original") |byte| _ = owner.editor.feed(byte);
    _ = owner.sealInput();
    owner.captureReady();
    for ("/result old-key") |byte| _ = owner.editor.feed(byte);
    const event = owner.holdCommand(owner.draft());
    for ("next-draft") |byte| _ = owner.editor.feed(byte);
    try std.testing.expectEqualStrings("/result old-key", event.command);
    try std.testing.expectEqualStrings("original", owner.submitted.?.buffer[0..owner.submitted.?.length]);
    owner.finishCommand();
    try std.testing.expectEqualStrings("next-draft", owner.draft());
    owner.releaseSubmitted();
    owner.clearDraft();
    _ = owner.holdCommand("/status");
    for ("next message") |byte| _ = owner.editor.feed(byte);
    _ = owner.sealInput();
    owner.finishCommand();
    try std.testing.expect(owner.ready);
    try std.testing.expectEqualStrings("next message", owner.submitted.?.buffer[0..owner.submitted.?.length]);
    owner.finishReady();
}

test "SessionTerminal Enter seals Message and command before subsequent input service" {
    var buffers: [2][65536]u8 = undefined;
    var owner: Self = .{ .io = std.testing.io, .editor = .{ .buffer = &buffers[0] }, .spare = &buffers[1], .original = undefined, .raw = undefined, .size = undefined };
    for ("hello") |byte| _ = owner.editor.feed(byte);
    const message = owner.sealInput();
    _ = owner.editor.feed('!');
    try std.testing.expectEqualStrings("hello", message.submit);
    try std.testing.expectEqualStrings("hello", owner.readyDraft().?);
    try std.testing.expectEqual(Event.busy, owner.sealInput());
    try std.testing.expectEqualStrings("!", owner.draft());
    owner.clearDraft();
    for ("/status") |byte| _ = owner.editor.feed(byte);
    const command = owner.sealInput();
    for ("next") |byte| _ = owner.editor.feed(byte);
    try std.testing.expectEqualStrings("/status", command.command);
    try std.testing.expectEqualStrings("hello", message.submit);
    try std.testing.expectEqualStrings("next", owner.draft());
    owner.finishCommand();
    owner.finishReady();
    try std.testing.expect(owner.readyDraft() == null);
    try std.testing.expectEqualStrings("next", owner.draft());
}

test "SessionTerminal output and independent choice do not reset draft parser" {
    var storage: [8]u8 = undefined;
    var editor: Editor = .{ .buffer = &storage };
    for ("\x1b[200~a\n") |byte| _ = editor.feed(byte);
    var choice_storage: [2]u8 = undefined;
    var choice: Editor = .{ .buffer = &choice_storage, .allow_paste = false };
    for ("\x1b[200~a\x1b[201~") |byte| _ = choice.feed(byte);
    try std.testing.expectEqual(Editor.Event.invalid, choice.feed('\r'));
    try std.testing.expect(editor.paste);
    for ("b\x1b[201~") |byte| _ = editor.feed(byte);
    try std.testing.expectEqual(Editor.Event.submit, editor.feed('\r'));
    try std.testing.expectEqualStrings("a\nb", editor.buffer[0..editor.length]);
    editor.reset();
    try std.testing.expect(!incomplete(&editor));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "SessionTerminal focused ingress expires before delayed tails and retires staging deadline" {
    var buffers: [2][65536]u8 = undefined;
    var owner: Self = .{ .io = std.testing.io, .editor = .{ .buffer = &buffers[0] }, .spare = &buffers[1], .original = undefined, .raw = undefined, .size = undefined };
    for ("retained") |byte| _ = owner.editor.feed(byte);
    for ([_]@FieldType(Self, "focus"){ .staging, .choice }) |focus| {
        for ([_]u8{ '[', 'O' }) |prefix| {
            owner.resetFocus(focus);
            try owner.focusByte(27, 1000000000);
            try std.testing.expectEqual(@as(i32, 80), try inputWait(&owner.focus_editor, &owner.focus_deadline, 1000000000, -1));
            try owner.focusByte(prefix, 1020000000);
            const due = owner.focus_deadline.?;
            try std.testing.expectEqual(@as(i32, 1), try inputWait(&owner.focus_editor, &owner.focus_deadline, due - 1, 100));
            try std.testing.expectError(error.IncompleteTerminalInput, owner.focusByte('C', due));
            try std.testing.expect(owner.focus_editor.escape != .none);
            try std.testing.expectEqualStrings("retained", owner.draft());
            owner.resetFocus(focus);
            try owner.focusByte(27, 1000000000);
            try owner.focusByte(prefix, 1020000000);
            try owner.focusByte('C', 3019999999);
            try std.testing.expect(owner.focus_deadline == null);
        }
        owner.resetFocus(focus);
        try owner.focusByte(27, 1000000000);
        try owner.focusByte('l', 1080000000);
        try std.testing.expectEqualStrings("l", owner.focus_editor.buffer[0..owner.focus_editor.length]);
        try std.testing.expect(owner.focus_deadline == null);
    }
    owner.stageApproval();
    try owner.focusByte(27, 1000000000);
    try owner.focusByte('[', 1020000000);
    owner.beginApproval();
    try std.testing.expectEqual(@as(?i96, 3020000000), owner.focus_deadline);
    owner.resetFocus(.choice); // The successful drain/flush transition.
    try std.testing.expect(owner.focus_deadline == null);
    try owner.focusByte('l', 5000000000);
    try owner.focusByte('\n', 5000000001);
    try std.testing.expectEqual(Editor.Event.submit, owner.focus_event);
    owner.finishApproval();
    try std.testing.expectEqualStrings("retained", owner.draft());
}

test "SessionTerminal failed stdout restores native PTY on init and resume" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const flags: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true })));
    const master = native.posix_openpt(flags);
    if (master < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(master);
    if (native.grantpt(master) != 0 or native.unlockpt(master) != 0) return error.TestPtyOpenFailed;
    const name = native.ptsname(master) orelse return error.TestPtyOpenFailed;
    const slave = std.c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(slave);
    const original = try std.posix.tcgetattr(slave);
    try std.testing.expect(original.lflag.ICANON and original.lflag.ECHO and original.lflag.ISIG);
    for ([_]bool{ false, true }) |resuming| {
        const child = std.c.fork();
        if (child < 0) return error.TestForkFailed;
        if (child == 0) {
            if (std.c.dup2(slave, 0) < 0 or std.c.dup2(slave, 1) < 0) std.c._exit(20);
            var buffers: [2][65536]u8 = undefined;
            const io = std.Io.Threaded.global_single_threaded.io();
            if (resuming) {
                var owner = Self.init(io, &buffers) catch std.c._exit(21);
                owner.@"suspend"() catch std.c._exit(22);
                _ = native.close(1);
                if (owner.@"resume"()) |_| std.c._exit(23) else |_| {}
                // Leave the OS mode for the parent to inspect independently.
            } else {
                _ = native.close(1);
                if (Self.init(io, &buffers)) |_| std.c._exit(24) else |_| {}
            }
            std.c._exit(0);
        }
        var status: c_int = undefined;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
        const restored = try std.posix.tcgetattr(slave);
        try std.testing.expect(restored.lflag.ICANON and restored.lflag.ECHO and restored.lflag.ISIG);
    }
}
