//! Bounded public Activity presentation with one forward-only content pass.
//! A failed stream may leave a visible prefix; the terminal owner must not retry it.
const std = @import("std");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");
const tools = @import("tools.zig");
const failure_class = @import("failure_class.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
const unicode = @import("terminal_unicode");

/// Only presentation-owned foreground changes. Content cannot select a style.
pub const Style = enum {
    user,
    quiet,
    attention,
    failure,
    normal,

    pub fn code(self: Style, colour: bool) []const u8 {
        if (!colour) return "";
        return switch (self) {
            .user => "\x1b[94m",
            .quiet => "\x1b[90m",
            .attention => "\x1b[33m",
            .failure => "\x1b[91m",
            .normal => "\x1b[39m",
        };
    }
};

/// Codes only the conversation view interprets, written whatever the colour
/// setting: it draws them dim (user body, summary) or in the right margin
/// (sidenote), and `reset` ends all three. Escaped content cannot form them.
pub const Mark = struct {
    pub const body = "\x1b[2m";
    pub const summary = "\x1b[2;8m";
    pub const sidenote = "\x1b[8m";
    pub const reset = "\x1b[0m";
};

const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(time: *const c_long, result: *Tm) ?*Tm;

/// Local 24-hour `HH:MM` of a Host wall-clock second, or null when the C
/// library cannot represent it.
pub fn clock(second: u64, buffer: *[5]u8) ?[]const u8 {
    const time = std.math.cast(c_long, second) orelse return null;
    var local: Tm = undefined;
    if (localtime_r(&time, &local) == null) return null;
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ @as(u8, @intCast(local.hour)), @as(u8, @intCast(local.min)) }) catch unreachable;
}

/// A user block's first row up to its body: `›` and the admission time.
pub fn userPrefix(sink: anytype, colour: bool, admitted_at: u64) !void {
    try sink.feed("\n");
    try sink.feed(Style.user.code(colour));
    try sink.feed("›");
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var buffer: [5]u8 = undefined;
    const time = clock(admitted_at, &buffer) orelse return;
    try sink.feed(Mark.sidenote);
    try sink.feed(time);
    try sink.feed(Mark.reset);
}

/// A peer label is its complete routing identity, never a second abbreviation.
pub fn peerRef(peer: protocol.Peer, buffer: *[4 * protocol.max_session_bytes + 8]u8) []const u8 {
    const session = peer.session;
    @memcpy(buffer[0..session.len], session.slice());
    return buffer[0..session.len];
}

test "a peer reference is the complete six character routing ID" {
    var buffer: [4 * protocol.max_session_bytes + 8]u8 = undefined;
    var exact: protocol.Peer = .{ .session = .{} };
    try exact.session.set("k7m2qx");
    try std.testing.expectEqualStrings("k7m2qx", peerRef(exact, &buffer));
}

test "peer Messages render as one dim line each, with time in the margin and `…` when they continue" {
    const Sink = struct {
        bytes: [1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var saved: [256:0]u8 = undefined;
    const previous: ?[:0]const u8 = if (getenv("TZ")) |value| copy: {
        const zone = std.mem.span(value);
        if (zone.len > saved.len) return error.SkipZigTest;
        @memcpy(saved[0..zone.len], zone);
        saved[zone.len] = 0;
        break :copy saved[0..zone.len :0];
    } else null;
    defer {
        _ = if (previous) |value| setenv("TZ", value, 1) else unsetenv("TZ");
        tzset();
    }
    try std.testing.expectEqual(@as(c_int, 0), setenv("TZ", "UTC0", 1));
    tzset();
    var peer: protocol.Peer = .{ .session = .{} };
    try peer.session.set("9f8e7d");
    const S = Mark.summary;
    const N = Mark.sidenote;
    const R = Mark.reset;
    const preview: [200]u8 = @splat('x');
    // Leading blank lines and trailing blanks never show; later lines never
    // do, but a later non-blank one ends the line in `…`. A line ending in
    // `…` is a collapsed block (`true`), whose Message Ctrl-O opens.
    inline for (.{
        .{ .inbound, "\n  \nPlease review\t \nsecond line", "\n" ++ S ++ "← 9f8e7d · Please review…" ++ N ++ "08:00" ++ R ++ "\n", true },
        .{ .outbound, "first\n\n \t\n  \nsecond", "\n" ++ S ++ "→ 9f8e7d · first…" ++ N ++ "08:00" ++ R ++ "\n", true },
        .{ .outbound, "done", "\n" ++ S ++ "→ 9f8e7d · done" ++ N ++ "08:00" ++ R ++ "\n", false },
        .{ .inbound, "done\n \n\t\r\n\n", "\n" ++ S ++ "← 9f8e7d · done" ++ N ++ "08:00" ++ R ++ "\n", false },
        .{ .inbound, " \n", "\n" ++ S ++ "← 9f8e7d" ++ N ++ "08:00" ++ R ++ "\n", false },
        // Peer text cannot draw controls or styles.
        .{ .outbound, "\x1b[2mx", "\n" ++ S ++ "→ 9f8e7d · \\x1b[2mx" ++ N ++ "08:00" ++ R ++ "\n", false },
        // A whole preview needs no `…`; one byte more does.
        .{ .inbound, &preview, "\n" ++ S ++ "← 9f8e7d · " ++ preview ++ N ++ "08:00" ++ R ++ "\n", false },
        .{ .inbound, preview ++ "y", "\n" ++ S ++ "← 9f8e7d · " ++ preview ++ "…" ++ N ++ "08:00" ++ R ++ "\n", true },
        .{ .inbound, preview ++ "\ny", "\n" ++ S ++ "← 9f8e7d · " ++ preview ++ "…" ++ N ++ "08:00" ++ R ++ "\n", true },
        // A line already ending in `…` looks continued, so it opens too.
        .{ .outbound, "wait…", "\n" ++ S ++ "→ 9f8e7d · wait…" ++ N ++ "08:00" ++ R ++ "\n", true },
        .{ .outbound, "wait…\nmore", "\n" ++ S ++ "→ 9f8e7d · wait……" ++ N ++ "08:00" ++ R ++ "\n", true },
    }) |case| {
        for (0..case[1].len + 1) |split| {
            var sink: Sink = .{};
            var line: PeerLine(*Sink) = undefined;
            try line.init(&sink, case[0], peer, case[1].len);
            try line.feed(case[1][0..split]);
            try line.feed(case[1][split..]);
            try std.testing.expectEqual(case[3], try line.finish(1_800_000_000));
            try std.testing.expectEqualStrings(case[2], sink.bytes[0..sink.length]);
        }
    }
    // A first line past the preview keeps whole graphemes and says it continues.
    var sink: Sink = .{};
    var line: PeerLine(*Sink) = undefined;
    const long = comptime repeat("é", 500);
    try line.init(&sink, .inbound, peer, long.len);
    try line.feed(long);
    try std.testing.expect(try line.finish(1_800_000_000));
    try std.testing.expectEqualStrings("\n" ++ S ++ "← 9f8e7d · " ++ comptime repeat("é", 100) ++ "…" ++ N ++ "08:00" ++ R ++ "\n", sink.bytes[0..sink.length]);
    // Unread bytes are more than the line shows; without a time the margin
    // stays empty.
    sink = .{};
    try line.init(&sink, .inbound, peer, 9000);
    line.received = 9000;
    line.phase = .more;
    try std.testing.expect(try line.finish(std.math.maxInt(u64)));
    try std.testing.expectEqualStrings("\n" ++ S ++ "← 9f8e7d · …" ++ R ++ "\n", sink.bytes[0..sink.length]);
    var failed: Sink = .{};
    try sendFailed(&failed, peer);
    try std.testing.expectEqualStrings("\n" ++ S ++ "! → 9f8e7d — Failed" ++ R ++ "\n", failed.bytes[0..failed.length]);
}

/// A line's end before trailing blanks.
fn trimmed(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and blank(bytes[end - 1])) end -= 1;
    return bytes[0..end];
}

/// One peer Message as one upright dim line, never `›`: `← ref · first line`
/// from a peer, `→ ref · first line` sent to one. Its admission time goes in
/// the right margin. A Message with more than its preview shows ends in `…`.
/// Initialize in final storage, feed the Message's exact bytes, then finish.
pub fn PeerLine(comptime Sink: type) type {
    return struct {
        const Self = @This();
        sink: Sink,
        length: u64,
        received: u64 = 0,
        line: [preview_bytes + 4]u8 = undefined,
        line_bytes: usize = 0,
        // Before the first non-blank byte, in it, past its line, or past a
        // later non-blank byte. A caller that reads no bytes sets `more`.
        phase: enum { leading, first, after, more } = .leading,
        longer: bool = false,

        pub fn init(self: *Self, sink: Sink, direction: enum { inbound, outbound }, peer: protocol.Peer, length: u64) !void {
            self.* = .{ .sink = sink, .length = length };
            var buffer: [4 * protocol.max_session_bytes + 8]u8 = undefined;
            try sink.feed("\n" ++ Mark.summary);
            try sink.feed(if (direction == .inbound) "← " else "→ ");
            try sink.feed(peerRef(peer, &buffer));
        }

        pub fn feed(self: *Self, bytes: []const u8) anyerror!void {
            self.received += bytes.len;
            if (self.received > self.length) return error.ContentLengthMismatch;
            for (bytes) |byte| switch (self.phase) {
                .leading => if (byte != '\n' and !blank(byte)) {
                    self.phase = .first;
                    self.push(byte);
                },
                .first => if (byte == '\n') {
                    self.phase = .after;
                } else self.push(byte),
                .after => if (byte != '\n' and !blank(byte)) {
                    self.phase = .more;
                },
                .more => return,
            };
        }

        fn push(self: *Self, byte: u8) void {
            if (self.line_bytes == self.line.len) {
                self.longer = true;
                return;
            }
            self.line[self.line_bytes] = byte;
            self.line_bytes += 1;
        }

        /// Returns whether the line ends in `…`, its own or the preview's:
        /// the caller notes it as a collapsed block, which Ctrl-O opens.
        /// `ConversationViewport.collapsed` counts such lines alike.
        pub fn finish(self: *Self, admitted_at: u64) anyerror!bool {
            if (self.received != self.length) return error.ContentLengthMismatch;
            const kept = trimmed(self.line[0..self.line_bytes]);
            const cut = if (!self.longer and kept.len <= preview_bytes) kept.len else graphemeCut(kept, preview_bytes);
            const continues = self.phase == .more or self.longer or cut != kept.len;
            if (kept.len != 0 or continues) try self.sink.feed(" · ");
            var escaped: Escaped(Sink) = .{ .sink = self.sink, .text = .{ .mode = .multiline } };
            try escaped.feed(kept[0..cut]);
            try escaped.finish();
            if (continues) try self.sink.feed("…");
            var buffer: [5]u8 = undefined;
            if (clock(admitted_at, &buffer)) |time| {
                try self.sink.feed(Mark.sidenote);
                try self.sink.feed(time);
            }
            try self.sink.feed(Mark.reset ++ "\n");
            return continues or std.mem.endsWith(u8, kept, "…");
        }
    };
}

/// A send this Session made that its target refused.
pub fn sendFailed(sink: anytype, target: protocol.Peer) !void {
    var buffer: [4 * protocol.max_session_bytes + 8]u8 = undefined;
    try sink.feed("\n" ++ Mark.summary ++ "! → ");
    try sink.feed(peerRef(target, &buffer));
    try sink.feed(" — Failed" ++ Mark.reset ++ "\n");
}

/// Size as a reader says it: thousands of bytes, one decimal below 9.95,
/// both rounded half-up.
pub fn kilobytes(bytes: u64, buffer: *[24]u8) []const u8 {
    const tenths = (bytes + 50) / 100;
    if (tenths < 100) return std.fmt.bufPrint(buffer, "{d}.{d} KB", .{ tenths / 10, tenths % 10 }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d} KB", .{(bytes + 500) / 1000}) catch unreachable;
}

/// The Message behind a collapsed user block, for its Ctrl-O page: which
/// read returns its bytes, and whether a conversation row exports them.
pub const Collapsed = struct {
    source: enum { activity, conversation },
    position: u64,
    ordinal: u64,
    content: protocol.ActivityItem.Content,
    row: bool,
};

/// The Messages of one Document's collapsed blocks in order. Each block
/// draws exactly one summary run starting `┄`, so the Document's k-th such
/// run from its end is the k-th entry from the end. Live output appends and
/// evicts from the front; a transcript also gains older pages at the front
/// and loses newer rows from the end. Beyond capacity the oldest entries
/// are only counted.
pub const Blocks = struct {
    pub const capacity = 1024;
    items: [capacity]?Collapsed = undefined,
    start: usize = 0,
    count: usize = 0,
    // Blocks before `items`, oldest first, whose Messages are not kept.
    unknown: u64 = 0,

    fn at(self: *const Blocks, index: usize) usize {
        return (self.start + index) % capacity;
    }

    pub fn append(self: *Blocks, value: ?Collapsed) void {
        if (self.count == capacity) {
            self.start = self.at(1);
            self.count -= 1;
            self.unknown += 1;
        }
        self.items[self.at(self.count)] = value;
        self.count += 1;
    }

    /// Places an older page's blocks, oldest first, before every other.
    /// Behind blocks already unknown they are unknown too: placing them
    /// next to the kept ones would shift every older index.
    pub fn prepend(self: *Blocks, older: []const ?Collapsed) void {
        if (self.unknown != 0) {
            self.unknown += older.len;
            return;
        }
        var index = older.len;
        while (index > 0) : (index -= 1) {
            if (self.count == capacity) {
                self.unknown += index;
                return;
            }
            self.start = (self.start + capacity - 1) % capacity;
            self.items[self.start] = older[index - 1];
            self.count += 1;
        }
    }

    /// Forgets the newest `count` blocks, which left the Document's end.
    pub fn dropNewest(self: *Blocks, count: u64) void {
        const kept: usize = @intCast(@min(count, self.count));
        self.count -= kept;
        self.unknown -|= count - kept;
    }

    /// The block `index` from the end (0 is the newest), if kept.
    pub fn fromEnd(self: *const Blocks, index: u64) ?Collapsed {
        if (index >= self.count) return null;
        return self.items[self.at(self.count - 1 - @as(usize, @intCast(index)))];
    }

    /// A copy holding only the newest `count` blocks.
    pub fn newest(self: *const Blocks, count: u64) Blocks {
        var copy = self.*;
        const kept: usize = @intCast(@min(count, self.count));
        copy.start = self.at(self.count - kept);
        copy.count = kept;
        copy.unknown = count - kept;
        return copy;
    }
};

test "collapsed blocks keep their order from the end as pages join and leave" {
    var blocks: Blocks = .{};
    const body_ref: protocol.ActivityItem.Content = .{ .length = 0, .digest = @splat(0) };
    const at = struct {
        fn f(position: u64, c: protocol.ActivityItem.Content) ?Collapsed {
            return .{ .source = .activity, .position = position, .ordinal = 0, .content = c, .row = false };
        }
    }.f;
    for (0..Blocks.capacity + 3) |index| blocks.append(at(index + 10, body_ref));
    try std.testing.expectEqual(@as(u64, 3), blocks.unknown);
    try std.testing.expectEqual(@as(u64, Blocks.capacity + 12), blocks.fromEnd(0).?.position);
    try std.testing.expectEqual(@as(u64, 13), blocks.fromEnd(Blocks.capacity - 1).?.position);
    try std.testing.expect(blocks.fromEnd(Blocks.capacity) == null);
    var copy = blocks.newest(5);
    try std.testing.expectEqual(@as(u64, Blocks.capacity + 8), copy.fromEnd(4).?.position);
    copy.prepend(&.{ at(1, body_ref), null, at(3, body_ref) });
    try std.testing.expectEqual(@as(u64, 3), copy.fromEnd(5).?.position);
    try std.testing.expect(copy.fromEnd(6) == null);
    try std.testing.expectEqual(@as(u64, 1), copy.fromEnd(7).?.position);
    copy.dropNewest(6);
    try std.testing.expect(copy.fromEnd(0) == null and copy.fromEnd(2) == null);
    try std.testing.expectEqual(@as(u64, 1), copy.fromEnd(1).?.position);
    // An older page beyond capacity counts its oldest blocks only.
    var full = blocks.newest(Blocks.capacity - 1);
    full.prepend(&.{ at(1, body_ref), at(2, body_ref) });
    try std.testing.expectEqual(@as(u64, 2), full.fromEnd(Blocks.capacity - 1).?.position);
    try std.testing.expectEqual(@as(u64, 1), full.unknown);
    // Behind an unknown block, slots freed at the end never let an older
    // page's Message take a kept index: the oldest kept block stays 13 and
    // every index past it stays unknown.
    var gap = blocks.newest(Blocks.capacity + 1);
    try std.testing.expectEqual(@as(u64, 13), gap.fromEnd(Blocks.capacity - 1).?.position);
    gap.prepend(&.{at(2, body_ref)});
    gap.dropNewest(1);
    gap.prepend(&.{at(1, body_ref)});
    try std.testing.expectEqual(@as(u64, 13), gap.fromEnd(Blocks.capacity - 2).?.position);
    for (Blocks.capacity - 1..Blocks.capacity + 3) |index| try std.testing.expect(gap.fromEnd(index) == null);
}

/// Tells a sink that records collapsed blocks which Message the one just
/// written shows.
pub fn noteCollapsed(sink: anytype, value: Collapsed) !void {
    if (comptime std.meta.hasMethod(@TypeOf(sink), "collapsed")) try sink.collapsed(value);
}

/// A Message longer than any of these shows a preview and a summary row.
pub const collapse_bytes = 1024;
const collapse_nonblank = 4;
const collapse_lines = 12;
const preview_lines = 2;
const preview_bytes = 200;

fn blank(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

/// A user Message's body, fed its exact bytes after `userPrefix`. The view
/// draws it dim; a long one keeps its first two non-blank lines and a
/// `┄ N more lines` row, and trailing blank lines never show. `whole`
/// (/details) shows every byte. Initialize in final storage.
pub fn UserBody(comptime Sink: type) type {
    return struct {
        const Self = @This();
        out: Indented(Sink),
        escaped: Escaped(*Indented(Sink)),
        length: u64,
        whole: bool,
        received: u64 = 0,
        small: [collapse_bytes]u8 = undefined,
        // Collapsed: the current line's prefix and the lines shown and seen.
        line: [256]u8 = undefined,
        line_bytes: u64 = 0,
        line_blank: bool = true,
        shown: usize = 0,
        nonblank: u64 = 0,

        pub fn init(self: *Self, sink: Sink, length: u64, whole: bool) !void {
            self.* = .{ .out = .{ .sink = sink }, .escaped = undefined, .length = length, .whole = whole };
            self.escaped = .{ .sink = &self.out, .text = .{ .mode = .multiline } };
            try self.out.feed(Mark.body);
        }

        pub fn feed(self: *Self, bytes: []const u8) anyerror!void {
            self.received += bytes.len;
            if (self.received > self.length) return error.ContentLengthMismatch;
            if (self.whole) return self.escaped.feed(bytes);
            if (self.length <= collapse_bytes) {
                @memcpy(self.small[self.received - bytes.len ..][0..bytes.len], bytes);
                return;
            }
            try self.scan(bytes);
        }

        /// Returns whether the body collapsed.
        pub fn finish(self: *Self) anyerror!bool {
            if (self.received != self.length) return error.ContentLengthMismatch;
            var collapsed = false;
            if (self.whole) {
                try self.escaped.finish();
            } else if (self.length <= collapse_bytes and !collapses(self.small[0..self.length])) {
                try self.escaped.feed(self.small[0..beforeBlankLines(self.small[0..self.length])]);
                try self.escaped.finish();
            } else {
                if (self.length <= collapse_bytes) try self.scan(self.small[0..self.length]);
                try self.endLine();
                if (self.shown != 0) try self.out.feed("\n");
                try self.out.feed(Mark.summary);
                var count: [32]u8 = undefined;
                const hidden = self.nonblank - self.shown;
                try self.out.feed(switch (hidden) {
                    0 => "┄",
                    1 => "┄ 1 more line",
                    else => std.fmt.bufPrint(&count, "┄ {d} more lines", .{hidden}) catch unreachable,
                });
                collapsed = true;
            }
            try self.out.feed(Mark.reset);
            try self.out.finish();
            return collapsed;
        }

        fn scan(self: *Self, bytes: []const u8) !void {
            for (bytes) |byte| {
                if (byte == '\n') {
                    try self.endLine();
                    continue;
                }
                if (!blank(byte)) self.line_blank = false;
                if (self.line_bytes < self.line.len) self.line[@intCast(self.line_bytes)] = byte;
                self.line_bytes += 1;
            }
        }

        fn endLine(self: *Self) !void {
            defer {
                self.line_bytes = 0;
                self.line_blank = true;
            }
            if (self.line_blank) return;
            self.nonblank += 1;
            if (self.shown == preview_lines) return;
            if (self.shown != 0) try self.out.feed("\n");
            self.shown += 1;
            const kept = self.line[0..@intCast(@min(self.line_bytes, self.line.len))];
            const cut = if (self.line_bytes <= preview_bytes) kept.len else graphemeCut(kept, preview_bytes);
            try self.escaped.feed(kept[0..cut]);
            try self.escaped.finish();
            if (cut != kept.len) try self.out.feed(Mark.reset ++ Mark.summary ++ "…" ++ Mark.reset ++ Mark.body);
        }
    };
}

/// Whether a Message of at most `collapse_bytes` collapses: more non-blank
/// lines or lines from its first to last non-blank one than the view keeps.
fn collapses(bytes: []const u8) bool {
    var nonblank: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        for (line) |byte| {
            if (blank(byte)) continue;
            nonblank += 1;
            if (first == null) first = index;
            last = index;
            break;
        }
    }
    return nonblank > collapse_nonblank or (first != null and last - first.? + 1 > collapse_lines);
}

/// The bytes before trailing blank lines.
fn beforeBlankLines(bytes: []const u8) usize {
    var end: usize = 0;
    var start: usize = 0;
    while (start <= bytes.len) {
        const stop = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        for (bytes[start..stop]) |byte| if (!blank(byte)) {
            end = stop;
            break;
        };
        start = stop + 1;
    }
    return end;
}

/// The longest prefix of whole graphemes within `limit` bytes. `bytes` may
/// end early inside a grapheme; a cluster reaching its end does not fit.
fn graphemeCut(bytes: []const u8, limit: usize) usize {
    var cut: usize = 0;
    var clusters = unicode.graphemeIterator(bytes);
    while (clusters.next()) |cluster| {
        if (cluster.start + cluster.len > limit) break;
        cut = cluster.start + cluster.len;
    }
    return cut;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn tzset() void;

test "a Message's time is the local hour and minute of its Host second" {
    var saved: [256:0]u8 = undefined;
    const previous: ?[:0]const u8 = if (getenv("TZ")) |value| copy: {
        const zone = std.mem.span(value);
        if (zone.len > saved.len) return error.SkipZigTest;
        @memcpy(saved[0..zone.len], zone);
        saved[zone.len] = 0;
        break :copy saved[0..zone.len :0];
    } else null;
    defer {
        _ = if (previous) |value| setenv("TZ", value, 1) else unsetenv("TZ");
        tzset();
    }
    // 1,800,000,000 is 2027-01-15 08:00:00 UTC.
    var buffer: [5]u8 = undefined;
    for ([_]struct { zone: [*:0]const u8, time: []const u8 }{
        .{ .zone = "UTC0", .time = "08:00" },
        .{ .zone = "IST-5:30", .time = "13:30" },
        .{ .zone = "PST8", .time = "00:00" },
    }) |case| {
        try std.testing.expectEqual(@as(c_int, 0), setenv("TZ", case.zone, 1));
        tzset();
        try std.testing.expectEqualStrings(case.time, clock(1_800_000_000, &buffer).?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), clock(std.math.maxInt(u64), &buffer));
}

test "sizes are thousands of bytes with one decimal below 9.95" {
    var buffer: [24]u8 = undefined;
    for ([_]struct { u64, []const u8 }{ .{ 9, "0.0 KB" }, .{ 1_025, "1.0 KB" }, .{ 1_049, "1.0 KB" }, .{ 1_050, "1.1 KB" }, .{ 9_949, "9.9 KB" }, .{ 9_950, "10 KB" }, .{ 10_499, "10 KB" }, .{ 10_500, "11 KB" }, .{ 65_536, "66 KB" } }) |case| {
        try std.testing.expectEqualStrings(case[1], kilobytes(case[0], &buffer));
    }
}

fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    comptime {
        var result: [text.len * count]u8 = undefined;
        for (0..count) |index| @memcpy(result[index * text.len ..][0..text.len], text);
        const final = result;
        return &final;
    }
}

test "a long user Message shows two non-blank lines and what it hides" {
    const Sink = struct {
        bytes: [4096]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const B = Mark.body;
    const S = Mark.summary;
    const R = Mark.reset;
    const cut = R ++ S ++ "…" ++ R ++ B;
    const a = @as([255]u8, @splat('a'));
    const x = @as([1100]u8, @splat('x'));
    const lines = comptime repeat("line\n", 29) ++ "line";
    const five = comptime repeat("\n", 5);
    const six = comptime repeat("\n", 6);
    const twenty = comptime repeat("\n", 20);
    const more = comptime repeat("\n  line", 29);
    const Case = struct { input: []const u8, whole: bool = false, output: []const u8 };
    for ([_]Case{
        // At every limit: 4 non-blank lines in exactly 1,024 bytes.
        .{ .input = a ++ "\n" ++ a ++ "\n" ++ a ++ "\n" ++ a ++ "a", .output = B ++ a ++ "\n  " ++ a ++ "\n  " ++ a ++ "\n  " ++ a ++ "a" ++ R },
        .{ .input = "1\n2\n3\n4\n5", .output = B ++ "1\n  2\n  " ++ S ++ "┄ 3 more lines" ++ R },
        // Twelve lines from the first non-blank to the last fit; thirteen do not.
        .{ .input = "a" ++ six ++ "b" ++ five ++ "c", .output = B ++ "a" ++ six ++ "  b" ++ five ++ "  c" ++ R },
        .{ .input = "a" ++ six ++ "b" ++ six ++ "c", .output = B ++ "a\n  b\n  " ++ S ++ "┄ 1 more line" ++ R },
        // Leading and trailing blank lines do not count; trailing ones never show.
        .{ .input = twenty ++ "a\n \t\r\n", .output = B ++ twenty ++ "  a" ++ R },
        .{ .input = "a\r\n", .output = B ++ "a\\x0d" ++ R },
        // Long only by its bytes: a cut line counts as shown.
        .{ .input = x[0..1025], .output = B ++ x[0..200] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        // Cuts count source bytes and never split a grapheme.
        .{ .input = "\x01" ++ a[0..197] ++ "😀" ++ x[0..900], .output = B ++ "\\x01" ++ a[0..197] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        .{ .input = a[0..199] ++ "e\u{301}" ++ x[0..900], .output = B ++ a[0..199] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        .{ .input = a[0..200] ++ "\n" ++ x[0..900], .output = B ++ a[0..200] ++ "\n  " ++ x[0..200] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        // Preview lines skip blank ones; a large Message streams.
        .{ .input = "\n \nfirst\n\nsecond\nthird\n" ++ x ++ "\n\n", .output = B ++ "first\n  second\n  " ++ S ++ "┄ 2 more lines" ++ R },
        .{ .input = lines, .whole = true, .output = B ++ "line" ++ more ++ R },
    }) |case| {
        for ([_]usize{ 0, 1, case.input.len / 2, case.input.len }) |split| {
            var sink: Sink = .{};
            var body: UserBody(*Sink) = undefined;
            try body.init(&sink, case.input.len, case.whole);
            try body.feed(case.input[0..split]);
            try body.feed(case.input[split..]);
            try std.testing.expectEqual(std.mem.indexOf(u8, case.output, "┄") != null, try body.finish());
            try std.testing.expectEqualStrings(case.output, sink.bytes[0..sink.length]);
        }
    }
    var sink: Sink = .{};
    var body: UserBody(*Sink) = undefined;
    try body.init(&sink, 3, false);
    try std.testing.expectError(error.ContentLengthMismatch, body.feed("abcd"));
}

fn toolState(code: protocol.ToolPresentation.Code) struct { glyph: []const u8, suffix: []const u8, style: Style } {
    return switch (code) {
        .unresolved => .{ .glyph = "•", .suffix = "", .style = .quiet },
        .pending_permission => .{ .glyph = "?", .suffix = "", .style = .attention },
        .succeeded => .{ .glyph = "✓", .suffix = "", .style = .normal },
        .denied => .{ .glyph = "•", .suffix = " — Denied", .style = .normal },
        .unknown_tool => .{ .glyph = "•", .suffix = " — Rejected: unknown tool", .style = .normal },
        .invalid_arguments => .{ .glyph = "•", .suffix = " — Rejected: invalid arguments", .style = .normal },
        .failed => .{ .glyph = "!", .suffix = " — Failed", .style = .failure },
        .timed_out => .{ .glyph = "!", .suffix = " — Timed out", .style = .failure },
        .indeterminate => .{ .glyph = "!", .suffix = " — Outcome unknown; may have run", .style = .failure },
        .storage_failed => .{ .glyph = "!", .suffix = " — Output capture failed", .style = .failure },
        .spawn_failed => .{ .glyph = "!", .suffix = " — Could not start", .style = .failure },
        .cancelled => .{ .glyph = "!", .suffix = " — Cancelled", .style = .failure },
        .infrastructure_shutdown => .{ .glyph = "!", .suffix = " — Host stopped; outcome unknown", .style = .failure },
    };
}

pub fn toolHeading(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, separate: bool) !void {
    return toolHeadingWith(presentation, sink, colour, separate, "");
}

/// `exit` is a digits-only exit status, shown after the failure suffix.
fn toolHeadingWith(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, separate: bool, exit: []const u8) !void {
    const state = toolState(presentation.code);
    if (separate) try sink.feed("\n");
    try sink.feed(state.style.code(colour));
    try sink.feed(state.glyph);
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
    try escaped.feed(if (presentation.description) |label| label.slice() else "Tool call");
    try escaped.finish();
    try indented.feed(state.suffix);
    if (exit.len != 0) {
        try indented.feed(" (exit ");
        try indented.feed(exit);
        try indented.feed(")");
    }
    try indented.finish();
    try sink.feed("\n");
}

/// Presentation of the Store-owned, cursor-relative Activity capture.
pub const Live = struct {
    pub const Entry = protocol.CallActivity.Entry;
    entries: [3]Entry = undefined,
    count: usize = 0,
    total: u64 = 0,

    pub fn init(facts: protocol.CallActivity) Live {
        return .{ .entries = facts.entries, .count = facts.count, .total = facts.total };
    }

    // The escaped description, then glyph and suffix, or a running call's
    // clock.
    pub const line_bytes = Text.max_bytes_per_byte * protocol.max_tool_description_bytes + 96;
    comptime {
        std.debug.assert("• ".len + work_line.max_clock_bytes <= line_bytes - Text.max_bytes_per_byte * protocol.max_tool_description_bytes);
    }

    /// The call's row; `running` is the clock after the words of the
    /// running call the work line names, and empty for every other call.
    pub fn line(self: *const Live, index: usize, buffer: *[line_bytes]u8, running: []const u8) ![]const u8 {
        const entry = self.entries[index];
        const state = toolState(entry.presentation.code);
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{s} ", .{state.glyph});
        var text: Text = .{ .mode = .line };
        try text.feed(&writer, if (entry.presentation.description) |label| label.slice() else "Tool call");
        try text.finish(&writer);
        try writer.writeAll(state.suffix);
        try writer.writeAll(running);
        return writer.buffered();
    }

    pub fn style(self: *const Live, index: usize) Style {
        return toolState(self.entries[index].presentation.code).style;
    }
};

/// Live conversation and inspection share hanging indentation. Input is already
/// escaped or rendered; cell layout owns wrapping in the alternate screen.
/// `prefix` begins each later non-empty line: two spaces, or a mark that sets
/// quoted content apart from the lines around it. A mark also begins each
/// empty line, without its trailing space, so quoted blank lines stay quoted,
/// including the one a final newline leaves at `finish`.
pub fn Indented(comptime Sink: type) type {
    return struct {
        sink: Sink,
        prefix: []const u8 = "  ",
        marks_empty: bool = false,
        line_start: bool = false,
        sgr: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var storage: [4096]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (storage.len - out.end < self.prefix.len + 1) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                if (self.line_start and byte == '\n' and self.marks_empty) {
                    try out.writeAll(std.mem.trimEnd(u8, self.prefix, " "));
                } else if (self.line_start and byte != '\n') {
                    try out.writeAll(self.prefix);
                    self.line_start = false;
                }
                if (self.sgr or byte == 0x1b) {
                    self.sgr = byte != 'm';
                } else if (byte == '\n') self.line_start = true;
                try out.writeByte(byte);
            }
            if (out.end != 0) try self.sink.feed(out.buffered());
        }
        pub fn finish(self: *@This()) !void {
            if (self.sgr) return error.IncompleteRenderedText;
            if (!self.marks_empty or !self.line_start) return;
            try self.sink.feed(std.mem.trimEnd(u8, self.prefix, " "));
            self.line_start = false;
        }
    };
}

test "hanging indentation survives split windows and trusted styles" {
    const Sink = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const input = "first\n\x1b[1msecond\x1b[0m\n\nthird";
    for (0..input.len + 1) |split| {
        var sink: Sink = .{};
        var presentation: Indented(*Sink) = .{ .sink = &sink };
        try presentation.feed(input[0..split]);
        try presentation.feed(input[split..]);
        try presentation.finish();
        try std.testing.expectEqualStrings("first\n  \x1b[1msecond\x1b[0m\n\n  third", sink.bytes[0..sink.length]);
    }
}

/// What the Action's `?` row says, for keeping it beside the choice.
pub const ActionSummary = struct {
    description: protocol.Bounded(protocol.max_tool_description_bytes) = .{},
};

/// A time limit as exactly as the model set it, in its largest whole unit.
fn writeTimeLimit(out: anytype, milliseconds: u64) !void {
    if (milliseconds != 0 and milliseconds % 60_000 == 0) return print(out, "{d} min", .{milliseconds / 60_000});
    if (milliseconds != 0 and milliseconds % 1000 == 0) return print(out, "{d} s", .{milliseconds / 1000});
    return print(out, "{d} ms", .{milliseconds});
}

test "a time limit shows in its largest whole unit, never rounded" {
    const Sink = struct {
        bytes: [32]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    for ([_]struct { u64, []const u8 }{
        .{ 600_000, "10 min" },
        .{ 60_000, "1 min" },
        .{ 90_000, "90 s" },
        .{ 1000, "1 s" },
        .{ 1500, "1500 ms" },
        .{ 1, "1 ms" },
        .{ 0, "0 ms" },
        .{ std.math.maxInt(u64), "18446744073709551615 ms" },
    }) |case| {
        var sink: Sink = .{};
        try writeTimeLimit(&sink, case[0]);
        try std.testing.expectEqualStrings(case[1], sink.bytes[0..sink.length]);
    }
}

/// The request block of one Bash Action: what it is for, the exact command,
/// then a time limit and piped-in input only when the model set them.
/// Begins each line of an Action's command after its first, and each line of
/// its stdin. ConversationViewport hangs wrapped rows under the text after it.
pub const content_mark = "│ ";

pub fn permission(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File, sink: anytype, colour: bool) !ActionSummary {
    // Action reads write at the descriptor's streaming offset, not positionally.
    try requests.io.vtable.fileSeekTo(requests.io.userdata, scratch, 0);
    try scratch.setLength(requests.io, 0);
    var reply: client.ReplyBuffer = .{};
    const result = try requests.readActionArguments(store, session, action, scratch, &reply);
    if (result == .command) {
        const failure = requests.captureReadFailure(result.command) catch {
            try protocol_reply.checkCanonicalFailure(result.command);
            return error.ActionReadFailed;
        };
        if (failure.err() == error.CanonicalStoreFailure) return error.CanonicalStoreFailure;
        return error.ActionReadFailed;
    }
    return request(requests.io, scratch, sink, colour);
}

/// The request block from an Action's arguments JSON in `scratch`.
fn request(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool) !ActionSummary {
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(io, &buffer);
    const Source = struct {
        reader: *std.Io.Reader,
        pub fn peek(self: *@This()) !?u8 {
            return self.reader.peekByte() catch |err| switch (err) {
                error.EndOfStream => null,
                else => return err,
            };
        }
        pub fn take(self: *@This()) !u8 {
            return self.reader.takeByte();
        }
    };
    var source: Source = .{ .reader = &reader.interface };
    const arguments = try tools.inspectBashArguments(&source) orelse return error.InvalidBashArguments;
    try reader.seekTo(0);
    // What it is for, then the exact command; the description is the
    // model's label, never a substitute for the command.
    try sink.feed("\n");
    try sink.feed(Style.attention.code(colour));
    try sink.feed("?");
    try sink.feed(Style.normal.code(colour));
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (arguments.description.len != 0) {
        try indented.feed(" ");
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
        try label.feed(arguments.description.slice());
        try label.finish();
    }
    try indented.feed("\n$ ");
    // Every later line of the command and of stdin carries the content mark,
    // so their text can never pass for the fields between them.
    var command: Indented(*Indented(@TypeOf(sink))) = .{ .sink = &indented, .prefix = content_mark, .marks_empty = true };
    var escaped: Escaped(@TypeOf(&command)) = .{ .sink = &command, .text = .{ .mode = .multiline } };
    if (!try tools.writeBashCommand(&source, &escaped)) return error.InvalidBashArguments;
    try escaped.finish();
    try command.finish();
    if (arguments.timeout_ms) |timeout| {
        try indented.feed("\nTime limit: ");
        try writeTimeLimit(&indented, timeout);
    }
    if (arguments.stdin_present) {
        try reader.seekTo(0);
        try indented.feed("\nstdin:\n");
        // Every line of stdin, its first included, carries the mark.
        var lines: Indented(*Indented(@TypeOf(sink))) = .{ .sink = &indented, .prefix = content_mark, .marks_empty = true, .line_start = true };
        var input: Escaped(@TypeOf(&lines)) = .{ .sink = &lines, .text = .{ .mode = .multiline } };
        if (!try tools.writeBashStdin(&source, &input)) return error.InvalidBashArguments;
        try input.finish();
        try lines.finish();
    }
    try indented.feed("\n");
    try indented.finish();
    return .{ .description = arguments.description };
}

test "an Action's command and stdin lines carry the content mark, so neither can pass for a field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(std.testing.io, "arguments", .{ .read = true });
    defer scratch.close(std.testing.io);
    const Sink = struct {
        bytes: [512]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const Case = struct { arguments: []const u8, expected: []const u8 };
    for ([_]Case{
        .{
            .arguments = "{\"description\":\"Probe\",\"cmd\":\"echo a\\nTime limit: 1 min\\n\\nstdin:\",\"stdin\":null,\"timeout_ms\":null}",
            .expected = "\n? Probe\n  $ echo a\n  │ Time limit: 1 min\n  │\n  │ stdin:\n",
        },
        .{
            .arguments = "{\"description\":\"Probe\",\"cmd\":\"cat\",\"stdin\":\"Time limit: 1 min\\nx\",\"timeout_ms\":5000}",
            .expected = "\n? Probe\n  $ cat\n  Time limit: 5 s\n  stdin:\n  │ Time limit: 1 min\n  │ x\n",
        },
        .{
            .arguments = "{\"description\":\"Probe\",\"cmd\":\"cat\",\"stdin\":\"x\\n\",\"timeout_ms\":null}",
            .expected = "\n? Probe\n  $ cat\n  stdin:\n  │ x\n  │\n",
        },
    }) |case| {
        try scratch.setLength(std.testing.io, 0);
        try scratch.writePositionalAll(std.testing.io, case.arguments, 0);
        var sink: Sink = .{};
        _ = try request(std.testing.io, scratch, &sink, false);
        try std.testing.expectEqualStrings(case.expected, sink.bytes[0..sink.length]);
    }
}

pub fn current(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File) !protocol_reply.Current {
    try scratch.setLength(requests.io, 0);
    const Capture = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var capture: Capture = .{ .io = requests.io, .file = scratch };
    var reply: client.ReplyBuffer = .{};
    const report = try requests.inspectSession(store, session, .current, &capture, &reply);
    return switch (try protocol_reply.CurrentReply.decode(requests.io, scratch, session, report)) {
        .current => |value| value,
        .unconfigured => error.SessionNotConfigured,
        .failure => |failure| requests.failRead(failure),
    };
}

pub fn Escaped(comptime Sink: type) type {
    return struct {
        sink: Sink,
        text: Text,
        storage: [256]u8 = undefined,
        used: usize = 0,
        pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
            try self.feed(bytes);
        }
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var out = std.Io.Writer.fixed(&self.storage);
            out.end = self.used;
            for (bytes) |byte| {
                if (self.storage.len - out.end < 16) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                try self.text.feed(&out, &.{byte});
            }
            self.used = out.end;
        }
        pub fn finish(self: *@This()) anyerror!void {
            var out = std.Io.Writer.fixed(&self.storage);
            out.end = self.used;
            if (self.storage.len - out.end < 16) {
                try self.sink.feed(out.buffered());
                out.end = 0;
            }
            try self.text.finish(&out);
            if (out.end != 0) try self.sink.feed(out.buffered());
            self.used = 0;
        }
    };
}

/// Initialize in final storage: Renderer borrows the embedded Writer. Preserve
/// the original rendezvous error rather than narrowing Cancelled to WriteFailed.
pub fn Answer(comptime Sink: type) type {
    return struct {
        sink: Sink,
        storage: [4096]u8 = undefined,
        writer: std.Io.Writer,
        renderer: Renderer,
        failure: ?anyerror = null,
        pub fn init(self: *@This(), sink: Sink) void {
            self.* = .{ .sink = sink, .writer = undefined, .renderer = undefined };
            self.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.storage };
            self.renderer = .{ .out = &self.writer };
        }
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            if (self.failure) |err| return err;
            self.renderer.feed(bytes) catch |err| return self.failure orelse err;
            self.writer.flush() catch |err| return self.failure orelse err;
        }
        pub fn finish(self: *@This()) anyerror!void {
            if (self.failure) |err| return err;
            self.renderer.finish() catch |err| return self.failure orelse err;
            self.writer.flush() catch |err| return self.failure orelse err;
        }
        fn forward(self: *@This(), bytes: []const u8) std.Io.Writer.Error!void {
            if (bytes.len == 0) return;
            self.sink.feed(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
        }
        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", writer);
            try self.forward(writer.buffered());
            writer.end = 0;
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try self.forward(bytes);
                consumed += bytes.len;
            }
            const last = data[data.len - 1];
            for (0..splat) |_| try self.forward(last);
            return consumed + last.len * splat;
        }
    };
}

fn print(sink: anytype, comptime format: []const u8, args: anytype) !void {
    var storage: [256]u8 = undefined;
    try sink.feed(try std.fmt.bufPrint(&storage, format, args));
}

/// Which Message states a read labels. Live output labels none: its next
/// pages show what became of each Message. A read that stays on screen
/// labels a stop's exclusion, which lasts, and a queued Message only while
/// work under way holds the queue (`WorkState.holdsQueue`). A pending
/// Session acts at once, so that label would be stale at the next frame.
pub const Labels = enum {
    none,
    excluded,
    excluded_and_queued,

    pub fn lasting(held: bool) Labels {
        return if (held) .excluded_and_queued else .excluded;
    }
};

/// What a Message's state was when read. Only a stop's exclusion asks
/// something of the person, so only it carries the mark.
pub fn messageLabel(state: @FieldType(protocol.ActivityItem.Message, "state"), labels: Labels) ?[]const u8 {
    if (labels == .none) return null;
    return switch (state) {
        .applied => null,
        .queued => if (labels == .excluded_and_queued) "Queued" else null,
        .excluded => "! Stopped before it ran · send it again to run it",
    };
}

test "a queued Message is labelled only while work under way holds it" {
    const working: protocol.WorkState = .{ .working = .{ .since = 1 } };
    // Opened between admission and the model request that reads it: the
    // Session is pending, so a label would be stale by the next frame.
    const starting: protocol.WorkState = .{ .pending = .{ .since = 1 } };
    try std.testing.expect(messageLabel(.queued, .lasting(starting.holdsQueue())) == null);
    try std.testing.expectEqualStrings("Queued", messageLabel(.queued, .lasting(working.holdsQueue())).?);
    // A stop's exclusion asks the person to act whatever the work is doing.
    try std.testing.expectEqualStrings("! Stopped before it ran · send it again to run it", messageLabel(.excluded, .lasting(false)).?);
    try std.testing.expect(messageLabel(.applied, .excluded_and_queued) == null);
    // Live output's next pages say what became of each Message.
    inline for (.{ .queued, .excluded, .applied }) |state| try std.testing.expect(messageLabel(state, .none) == null);
}

/// One Message in full, labelled unless applied: live, in the opening and in
/// a transcript's listing alike.
pub fn message(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, value: protocol.ActivityItem.Message, labels: Labels, sink: anytype, colour: bool) !void {
    if (messageLabel(value.state, labels)) |text| try print(sink, "\n{s}", .{text});
    const block: Collapsed = .{ .source = .activity, .position = item.position, .ordinal = item.ordinal, .content = value.content, .row = item.value == .user };
    if (value.sender) |sender| {
        var line: PeerLine(@TypeOf(sink)) = undefined;
        try line.init(sink, .inbound, sender, value.content.length);
        try content(requests, store, session, item, value.content, &line);
        if (try line.finish(value.admitted_at)) try noteCollapsed(sink, block);
        return;
    }
    try userPrefix(sink, colour, value.admitted_at);
    var body: UserBody(@TypeOf(sink)) = undefined;
    try body.init(sink, value.content.length, false);
    try content(requests, store, session, item, value.content, &body);
    if (try body.finish()) try noteCollapsed(sink, block);
    try sink.feed("\n");
}

fn content(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, reference: protocol.ActivityItem.Content, target: anytype) !void {
    if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, target)) |failure| return requests.failRead(failure);
}

/// Compact tool outcome shared by live Activity and the scrolled transcript.
/// Failures keep their last output lines in view; /details stays exact.
pub fn toolResult(presentation: protocol.ToolPresentation, source: anytype, sink: anytype, colour: bool, compact: *bool) !void {
    const succeeded = presentation.code == .succeeded;
    var summary: Summary(@TypeOf(sink)) = .{
        .presentation = presentation,
        .separate = !compact.* or !succeeded,
        .escaped = .{ .sink = sink, .text = .{ .mode = .multiline } },
        .code = presentation.code,
        .colour = colour,
        .section = switch (presentation.code) {
            .denied, .unknown_tool, .invalid_arguments => .ended,
            else => .summary,
        },
    };
    try source.read(&summary);
    try summary.finish();
    if (summary.emitted) try sink.feed("\n");
    compact.* = succeeded and !summary.emitted;
}

fn failing(code: protocol.ToolPresentation.Code) bool {
    return toolState(code).style == .failure;
}

fn Summary(comptime Sink: type) type {
    return struct {
        const excerpt_lines = 3;
        const line_bytes = 256;
        const Tail = struct {
            // A few lines beyond the excerpt absorb the canonical trailer.
            lines: [excerpt_lines + 6][line_bytes]u8 = undefined,
            lengths: [excerpt_lines + 6]usize = undefined,
            shortened: [excerpt_lines + 6]bool = undefined,
            count: usize = 0,
            total: usize = 0,

            fn push(tail: *@This(), line: []const u8, shortened: bool) void {
                const slot = tail.total % tail.lines.len;
                @memcpy(tail.lines[slot][0..line.len], line);
                tail.lengths[slot] = line.len;
                tail.shortened[slot] = shortened;
                tail.total += 1;
                tail.count = @min(tail.count + 1, tail.lines.len);
            }
            fn last(tail: *const @This(), back: usize) []const u8 {
                const slot = (tail.total - 1 - back) % tail.lines.len;
                return tail.lines[slot][0..tail.lengths[slot]];
            }
            fn dropLast(tail: *@This()) void {
                tail.total -= 1;
                tail.count -= 1;
            }
        };
        escaped: Escaped(Sink),
        // The heading waits for the first detail: a failed exit status joins it.
        presentation: ?protocol.ToolPresentation = null,
        separate: bool = true,
        code: protocol.ToolPresentation.Code,
        colour: bool,
        section: enum { summary, stdout, stderr, ended } = .summary,
        line: [line_bytes]u8 = undefined,
        length: usize = 0,
        emitted: bool = false,
        omitted: bool = false,
        earlier_omitted: bool = false,
        stdout: Tail = .{},
        stderr: Tail = .{},
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            for (bytes) |byte| {
                if (self.section == .ended) return;
                if (byte == '\n') {
                    try self.emit();
                } else if (self.length < self.line.len) {
                    self.line[self.length] = byte;
                    self.length += 1;
                } else {
                    // Shorten only this line; later capture/cleanup
                    // warnings remain visible before output tails.
                    self.omitted = true;
                }
            }
        }
        fn emit(self: *@This()) !void {
            const line = self.line[0..self.length];
            defer {
                self.length = 0;
                self.omitted = false;
            }
            const heading = !self.omitted and (std.mem.eql(u8, line, "stdout tail:") or std.mem.eql(u8, line, "stderr tail:"));
            switch (self.section) {
                .ended => return,
                .stdout, .stderr => |stream| {
                    if (stream == .stdout and heading and std.mem.eql(u8, line, "stderr tail:")) {
                        self.section = .stderr;
                    } else (if (stream == .stdout) &self.stdout else &self.stderr).push(line, self.omitted);
                    return;
                },
                .summary => {},
            }
            // Only complete, known informational lines are quiet. Unknown or
            // qualified diagnostics stay visible, even after successful exit.
            // Keep canonical Bash evidence and detailed inspection unchanged.
            const routine = !self.omitted and std.mem.eql(u8, line, "Bash succeeded. Exit code: 0.");
            if (heading) {
                // Output tails matter only to explain a failure.
                self.section = if (!failing(self.code)) .ended else if (std.mem.eql(u8, line, "stdout tail:")) .stdout else .stderr;
            } else if (line.len != 0 and !routine) {
                var prefix_buffer: [64]u8 = undefined;
                const prefix = if (failing(self.code)) try std.fmt.bufPrint(&prefix_buffer, "Bash {s}. ", .{@tagName(self.code)}) else "";
                const detail = if (!self.omitted and prefix.len != 0 and std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else line;
                if (self.presentation != null and !self.emitted and prefix.len != 0 and !self.omitted) {
                    const status = if (std.mem.startsWith(u8, detail, "Exit code: ") and std.mem.endsWith(u8, detail, ".")) detail["Exit code: ".len .. detail.len - 1] else "";
                    var digits = status.len != 0 and status.len <= 3;
                    for (status) |byte| digits = digits and std.ascii.isDigit(byte);
                    if (digits) {
                        try self.writeHeading(status);
                        return;
                    }
                }
                try self.writeHeading("");
                try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                try self.escaped.feed(detail);
                if (self.omitted) try self.escaped.feed(" [summary shortened; /details]");
                self.emitted = true;
            }
        }
        fn writeHeading(self: *@This(), exit: []const u8) !void {
            const presentation = self.presentation orelse return;
            self.presentation = null;
            try toolHeadingWith(presentation, self.escaped.sink, self.colour, self.separate, exit);
        }
        fn finish(self: *@This()) !void {
            if (self.length != 0) try self.emit();
            try self.writeHeading("");
            if (failing(self.code) and self.section != .ended) {
                // The canonical trailer follows only the stream written last;
                // trailing blank lines end either. Select after cleaning, so a
                // blank-only stderr falls back to useful stdout.
                const last = if (self.stderr.total != 0) &self.stderr else &self.stdout;
                for ([_]*Tail{ &self.stdout, &self.stderr }) |stream| {
                    while (stream.count != 0) {
                        const line = stream.last(0);
                        const trailer = stream == last and (std.mem.eql(u8, line, "Full output was not retained.") or
                            std.mem.startsWith(u8, line, "Full stdout: ") or std.mem.startsWith(u8, line, "Full stderr: "));
                        if (line.len == 0 or trailer) {
                            stream.dropLast();
                        } else if (stream == last and std.mem.eql(u8, line, "[earlier output omitted]")) {
                            self.earlier_omitted = true;
                            stream.dropLast();
                        } else break;
                    }
                }
                const tail = if (self.stderr.count != 0) &self.stderr else &self.stdout;
                const shown = @min(tail.count, excerpt_lines);
                var shortened = self.earlier_omitted or tail.total > shown;
                for (0..shown) |index| {
                    const back = shown - 1 - index;
                    shortened = shortened or tail.shortened[(tail.total - 1 - back) % tail.lines.len];
                    try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                    try self.escaped.feed(tail.last(back));
                    self.emitted = true;
                }
                if (shortened) {
                    try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                    try self.escaped.feed("/details for full output.");
                    self.emitted = true;
                }
            }
            try self.escaped.finish();
        }
    };
}

test "tool summary hides only complete routine metadata and retains warnings" {
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const warning = "Process-group signaling reported a failure.";
    const incomplete = "Capture may be incomplete because writers outlived process-group termination.";
    const capture_failure = "Capture failure: read; output may be incomplete.";
    const cases = .{
        .{ .succeeded, "Bash succeeded. Exit code: 0.\nstdout tail:\nhidden", "", "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n", "", "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ incomplete ++ "\n" ++ warning ++ "\nstderr tail:\nhidden", "  " ++ incomplete ++ "\n  " ++ warning, "" },
        .{ .failed, "Bash failed. Exit code: 7.\n" ++ capture_failure, "  " ++ capture_failure, "7" },
        .{ .timed_out, "Bash timed_out. Signal: 15.\n" ++ warning, "  Signal: 15.\n  " ++ warning, "" },
        .{ .cancelled, "Bash cancelled. Signal: 15.\n", "  Signal: 15.", "" },
        .{ .indeterminate, "Bash indeterminate. Unknown process status: 0.\n" ++ warning, "  Unknown process status: 0.\n  " ++ warning, "" },
        .{ .failed, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning.", "" },
        .{ .succeeded, "Bash failed. Exit code: 7.", "  Bash failed. Exit code: 7.", "" },
        // Earlier results saved a retirement line; it is no longer routine.
        .{ .succeeded, "Process retirement confirmed: the child was reaped.\n" ++ warning, "  Process retirement confirmed: the child was reaped.\n  " ++ warning, "" },
        .{ .succeeded, "Process retirement unconfirmed.\n" ++ warning, "  Process retirement unconfirmed.\n  " ++ warning, "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning.", "" },
        .{ .succeeded, warning ++ @as([256]u8, @splat('x')) ++ "\n" ++ incomplete, "  " ++ (warning ++ @as([256]u8, @splat('x')))[0..256] ++ " [summary shortened; /details]\n  " ++ incomplete, "" },
        .{ .succeeded, "stdout tail: unavailable\n" ++ warning, "  stdout tail: unavailable\n  " ++ warning, "" },
        // Failures show the last stderr lines, else stdout, without the trailer.
        .{ .failed, "Bash failed. Exit code: 127.\nstderr tail:\nbash: line 1: rui: command not found", "  bash: line 1: rui: command not found", "127" },
        .{ .failed, "Bash failed. Exit code: 1.\nstdout tail:\nusage: x\nhelp", "  usage: x\n  help", "1" },
        .{ .failed, "Bash failed. Exit code: 1.\nstdout tail:\nusage: x\nhelp\n\n[earlier output omitted]\n\nFull stdout: /s/o\n", "  usage: x\n  help\n  /details for full output.", "1" },
        .{ .failed, "Bash failed. Exit code: 2.\nstdout tail:\nx\nstderr tail:\none\ntwo\nthree\nfour\n[earlier output omitted]\n\nFull stderr: /s/e\n", "  two\n  three\n  four\n  /details for full output.", "2" },
        .{ .failed, "Bash failed. Exit code: 3.\nstderr tail:\nonly\n[earlier output omitted]\n\nFull output was not retained.\n", "  only\n  /details for full output.", "3" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\nstdout tail:\nhidden\nstderr tail:\nalso hidden", "", "" },
        .{ .failed, "Bash failed. Exit code: 4.\nstderr tail:\n\x1b[2Jcontrol", "  \\x1b[2Jcontrol", "4" },
        .{ .failed, "Bash failed. Exit code: 5.\n", "", "5" },
        // A blank-only stderr does not hide useful stdout, whole or truncated.
        .{ .failed, "Bash failed. Exit code: 7.\nstdout tail:\nuseful diagnostic B\nstderr tail:\n\n", "  useful diagnostic B", "7" },
        .{ .failed, "Bash failed. Exit code: 7.\nstdout tail:\nuseful\n\nstderr tail:\n\n\n", "  useful", "7" },
        .{ .failed, "Bash failed. Exit code: 1.\nstdout tail:\nu1\nu2\nstderr tail:\n\n[earlier output omitted]\n\nFull stdout: /s/o\n", "  u1\n  u2\n  /details for full output.", "1" },
        // Meaningful stderr still wins; warnings stay visible beside the fallback.
        .{ .failed, "Bash failed. Exit code: 1.\nstdout tail:\nout\n\nstderr tail:\nerr\n", "  err", "1" },
        .{ .failed, "Bash failed. Exit code: 7.\n" ++ warning ++ "\nstdout tail:\nB\nstderr tail:\n\n", "  " ++ warning ++ "\n  B", "7" },
    };
    inline for (cases) |case| {
        for (0..case[1].len + 1) |split| {
            var sink: Sink = .{};
            const presentation: protocol.ToolPresentation = .{ .description = null, .code = case[0], .publication_position = null };
            var summary: Summary(*Sink) = .{ .presentation = presentation, .code = case[0], .colour = false, .escaped = .{ .sink = &sink, .text = .{ .mode = .multiline } } };
            try summary.feed(case[1][0..split]);
            try summary.feed(case[1][split..]);
            try summary.finish();
            // A failed exit status joins the heading instead of a detail row.
            var heading: Sink = .{};
            try toolHeadingWith(presentation, &heading, false, true, case[3]);
            try std.testing.expectEqualStrings(heading.bytes[0..heading.length], sink.bytes[0..heading.length]);
            try std.testing.expectEqualStrings(case[2], sink.bytes[heading.length..sink.length]);
        }
    }
}

/// Why a Turn ended, in the person's terms, and the one step that helps.
/// A reason of null shows the saved code itself.
const Ending = struct { reason: ?[]const u8, next: []const u8 };

fn ending(code: []const u8) Ending {
    const again = "Send a message to continue.";
    return switch (failure_class.of(code)) {
        .policy => .{ .reason = "OpenAI refused this request", .next = "Rephrase it, or start a new Session; sending more here will likely be refused again." },
        .quota => .{ .reason = "the OpenAI account is out of quota", .next = "Add credit or wait for the limit to reset, then send a message to continue." },
        .plan => .{ .reason = "the OpenAI plan does not include this Session's model", .next = "Choose another with /configure --model, then send a message to continue." },
        .model => .{ .reason = "OpenAI cannot serve this Session's model", .next = "Choose another with /configure --model, then send a message to continue." },
        .sign_in => .{ .reason = "sign-in expired", .next = "Run rui auth login codex, then send a message to continue." },
        // A running Host keeps the key it started with.
        .api_key => .{ .reason = "the OpenAI API key was rejected", .next = "Save a new one with rui auth login openai, restart the Host with rui host stop, then send a message to continue." },
        .overflow => .{ .reason = "the conversation no longer fits the model's context", .next = "Start a new Session; more here will not fit either." },
        .refused => .{ .reason = null, .next = "Sending this again will likely fail the same way; change what the error names, or start a new Session." },
        .unreachable_provider => .{ .reason = "OpenAI could not be reached", .next = "Check the network, proxy or provider endpoint, then send a message to continue." },
        .retries_exhausted => .{ .reason = "retries ran out", .next = again },
        .interrupted => .{ .reason = "it was interrupted", .next = again },
        .other => .{ .reason = null, .next = again },
    };
}

/// `report` is the provider's own words, escaped: never trusted as
/// terminal text.
fn workEnded(sink: anytype, code: []const u8, report: ?[]const u8) !void {
    const end = ending(code);
    try sink.feed("\n! Work ended: ");
    try sink.feed(end.reason orelse code);
    if (report) |words| {
        try sink.feed(" (");
        var escaped: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .multiline } };
        try escaped.feed(words);
        try escaped.finish();
        try sink.feed(")");
    }
    try sink.feed(".\n  ");
    try sink.feed(end.next);
    try sink.feed("\n");
}

/// A failed outcome's report, read whole before its line is drawn. A
/// longer one than the Store keeps shows its prefix.
const ReportBytes = struct {
    bytes: [protocol.max_report_bytes]u8,
    len: usize,

    pub fn feed(self: *ReportBytes, bytes: []const u8) !void {
        const kept = @min(bytes.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..kept], bytes[0..kept]);
        self.len += kept;
    }
};

test "an ended Turn says why and the one next step that helps, where it ended" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    const cases = [_]struct { code: []const u8, report: ?[]const u8, shown: []const u8 }{
        // The captured cyber_policy refusal: resending is no next step.
        .{ .code = "provider_cyber_policy", .report = "cyber_policy: This request has been flagged for potentially high-risk cyber activity.", .shown = "\n! Work ended: OpenAI refused this request (cyber_policy: This request has been flagged for potentially high-risk cyber activity.).\n  Rephrase it, or start a new Session; sending more here will likely be refused again.\n" },
        .{ .code = "provider_invalid_prompt", .report = null, .shown = "\n! Work ended: OpenAI refused this request.\n  Rephrase it, or start a new Session; sending more here will likely be refused again.\n" },
        .{ .code = "provider_insufficient_quota", .report = "insufficient_quota: You exceeded your current quota.", .shown = "\n! Work ended: the OpenAI account is out of quota (insufficient_quota: You exceeded your current quota.).\n  Add credit or wait for the limit to reset, then send a message to continue.\n" },
        .{ .code = "provider_model_not_found", .report = "model_not_found: The model `gpt-x` does not exist.", .shown = "\n! Work ended: OpenAI cannot serve this Session's model (model_not_found: The model `gpt-x` does not exist.).\n  Choose another with /configure --model, then send a message to continue.\n" },
        .{ .code = "provider_http_401", .report = null, .shown = "\n! Work ended: sign-in expired.\n  Run rui auth login codex, then send a message to continue.\n" },
        .{ .code = "provider_api_key_rejected", .report = "Incorrect API key provided", .shown = "\n! Work ended: the OpenAI API key was rejected (Incorrect API key provided).\n  Save a new one with rui auth login openai, restart the Host with rui host stop, then send a message to continue.\n" },
        .{ .code = "ResourceExceeded", .report = null, .shown = "\n! Work ended: the conversation no longer fits the model's context.\n  Start a new Session; more here will not fit either.\n" },
        // Retries keep the last Attempt's words.
        .{ .code = "retry_exhausted", .report = "server_is_overloaded: Try again later.", .shown = "\n! Work ended: retries ran out (server_is_overloaded: Try again later.).\n  Send a message to continue.\n" },
        .{ .code = "cancelled", .report = null, .shown = "\n! Work ended: it was interrupted.\n  Send a message to continue.\n" },
        // Any other code shows itself, beside whatever the provider said.
        .{ .code = "provider_http_400", .report = "invalid_request_error: Unsupported \"x\"\x1b[2J", .shown = "\n! Work ended: provider_http_400 (invalid_request_error: Unsupported \"x\"\\x1b[2J).\n  Sending this again will likely fail the same way; change what the error names, or start a new Session.\n" },
        .{ .code = "provider_usage_not_included", .report = null, .shown = "\n! Work ended: the OpenAI plan does not include this Session's model.\n  Choose another with /configure --model, then send a message to continue.\n" },
        .{ .code = "provider_tls_verification_failed", .report = null, .shown = "\n! Work ended: OpenAI could not be reached.\n  Check the network, proxy or provider endpoint, then send a message to continue.\n" },
        // The provider's words for an overflow say how far over it went.
        .{ .code = "ResourceExceeded", .report = "context_length_exceeded: Your input exceeds the context window.", .shown = "\n! Work ended: the conversation no longer fits the model's context (context_length_exceeded: Your input exceeds the context window.).\n  Start a new Session; more here will not fit either.\n" },
        .{ .code = "malformed_provider_output", .report = null, .shown = "\n! Work ended: malformed_provider_output.\n  Send a message to continue.\n" },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var sink: Sink = .{ .out = &out };
        try workEnded(&sink, case.code, case.report);
        try std.testing.expectEqualStrings(case.shown, out.buffered());
    }
}

/// What a live page needs to show the Messages people and scripts sent as
/// they are taken.
pub const Taking = struct {
    /// The newest such Message shown while it waited, at its Admission: its
    /// row never shows live.
    drawn: queued_line.Drawn,
    /// A position before the Admission of every such Message that waits at
    /// the page's start, where a stop's search for those it excluded begins;
    /// null when none waits.
    from: ?u64,
};

/// Whether live output shows a waiting Message a person or script sent at
/// its Admission: nothing holds the queue and it is the oldest waiting, so
/// it is taken next and never waits above the input. Any other waits in
/// the queued row and shows as its row once taken.
pub fn showsAtAdmission(position: u64, value: protocol.ActivityItem.Message, drawn: queued_line.Drawn, queued: protocol.Queued, held: bool) bool {
    return value.state == .queued and value.admission > drawn.admission and !held and position == queued.oldest_position;
}

test "a waiting Message shows at its Admission only when nothing holds it and nothing older waits" {
    const body: protocol.ActivityItem.Content = .{ .length = 1, .digest = @splat(0) };
    const waiting: protocol.ActivityItem.Message = .{ .admission = 12, .key = .{}, .turn = null, .state = .queued, .content = body, .admitted_at = 1, .sender = null };
    const alone: protocol.Queued = .{ .count = 1, .oldest_position = 30, .newest_admission = 12, .newest_position = 30 };
    // A pending Session can wait long before it takes the Message, as after
    // Ctrl-R recovery: the conversation shows it at once, as on an idle send.
    const before: queued_line.Drawn = .{ .admission = 10, .position = 20 };
    try std.testing.expect(showsAtAdmission(30, waiting, before, alone, false));
    // Work under way holds it: it waits in the queued row.
    try std.testing.expect(!showsAtAdmission(30, waiting, before, alone, true));
    // An older Message waits, which the queued row shows: this one waits
    // with it, so the conversation shows both in order once taken.
    try std.testing.expect(!showsAtAdmission(34, waiting, before, .{ .count = 2, .oldest_position = 30, .newest_admission = 12, .newest_position = 34 }, false));
    // Taken or excluded by the page's end, or shown already.
    var taken = waiting;
    taken.state = .applied;
    try std.testing.expect(!showsAtAdmission(30, taken, before, .{}, false));
    try std.testing.expect(!showsAtAdmission(30, waiting, .{ .admission = 12, .position = 30 }, alone, false));
}

/// Writes a page and returns the newest Message a person or script sent
/// that it or an earlier read showed while it waited (`Taking.drawn`). The
/// sink learns each one as it shows (`drew`).
pub fn render(requests: client.Requests, store: []const u8, session: []const u8, page: *const protocol_reply.ActivityPage, sink: anytype, colour: bool, compact_tools: *bool, taking: Taking) !queued_line.Drawn {
    const historical = page.facts.direction == .backward;
    var from = taking.from;
    var drawn = taking.drawn;
    for (0..page.facts.count) |index| {
        const item = page.facts.items[if (historical) page.facts.count - index - 1 else index];
        if (!historical and item.value == .stop) {
            compact_tools.* = false;
            if (from) |position| try excludedAtStop(requests, store, session, item, position, sink, colour);
        }
        // The sink learns which item its next bytes belong to: some items
        // render nothing, and a read boundary must name the first that does.
        sink.item(item);
        switch (item.value) {
            .admission => |value| {
                if (historical and value.state == .applied) continue;
                // A person's or script's Message shows live when it is
                // taken: as its row, or at the stop that excluded it. Until
                // then it waits above the input, unless it is taken next;
                // one waiting at the opening too. The opening shows one a
                // stop excluded, labelled.
                if (value.sender == null and (!historical or value.state == .queued)) {
                    if (!historical and from == null and value.state != .applied) from = item.position - 1;
                    if (!showsAtAdmission(item.position, value, drawn, page.facts.queued, page.facts.work.work.state.holdsQueue())) continue;
                    drawn = .{ .admission = value.admission, .position = item.position };
                    sink.drew(drawn.admission);
                }
                compact_tools.* = false;
                try message(requests, store, session, item, value, if (historical) .lasting(page.facts.work.work.state.holdsQueue()) else .none, sink, colour);
            },
            .user => |value| {
                // Live, another Session's Message showed as its Admission,
                // and one shown while it waited never shows again.
                if (!historical and (value.sender != null or value.admission <= drawn.admission)) continue;
                compact_tools.* = false;
                try message(requests, store, session, item, value, .none, sink, colour);
            },
            .assistant => |reference| {
                compact_tools.* = false;
                try sink.feed("\n");
                var answer: Answer(@TypeOf(sink)) = undefined;
                answer.init(sink);
                try content(requests, store, session, item, reference, &answer);
                try answer.finish();
                try sink.feed("\n");
            },
            .tool_result => |result| {
                // Keep outcomes and warnings, not routine zero exit codes or
                // output tails. This affects presentation only, never execution,
                // permission or outcome classification; /details stays exact.
                const Source = struct {
                    requests: client.Requests,
                    store: []const u8,
                    session: []const u8,
                    item: protocol.ActivityItem,
                    reference: protocol.ActivityItem.Content,
                    pub fn read(self: @This(), summary: anytype) !void {
                        if (try self.requests.readActivityContent(self.store, self.session, self.item.position, self.item.ordinal, .{ .bytes = self.reference.length, .digest = self.reference.digest }, summary)) |read_failure| return self.requests.failRead(read_failure);
                    }
                };
                try toolResult(result.presentation, Source{ .requests = requests, .store = store, .session = session, .item = item, .reference = result.content }, sink, colour, compact_tools);
            },
            // Hidden call rows use admission-certified page metadata. Exact
            // proposal and permission inspection authenticate originals instead.
            .call => {},
            .outcome => |outcome| {
                // Successful content aggregates assistant rows, never a second answer.
                if (outcome.code.eql("completed")) continue;
                compact_tools.* = false;
                // A failed outcome's content is its report.
                var report: ReportBytes = undefined;
                report.len = 0;
                if (outcome.content) |reference| try content(requests, store, session, item, reference, &report);
                try workEnded(sink, outcome.code.slice(), if (outcome.content != null) report.bytes[0..report.len] else null);
            },
            .stop => {
                compact_tools.* = false;
                try sink.feed("\n! Session stopped.\n");
            },
            .sent => |sent| {
                compact_tools.* = false;
                var line: PeerLine(@TypeOf(sink)) = undefined;
                try line.init(sink, .outbound, sent.target, sent.content.length);
                try content(requests, store, session, item, sent.content, &line);
                // Conversation pages hold no sent Message, so no row exports it.
                if (try line.finish(sent.admitted_at)) try noteCollapsed(sink, .{ .source = .activity, .position = item.position, .ordinal = item.ordinal, .content = sent.content, .row = false });
            },
            .send_failed => |failed| {
                compact_tools.* = false;
                try sendFailed(sink, failed.target);
            },
        }
    }
    return drawn;
}

/// Shows the Messages a person or script sent that a live page's stop
/// excluded, oldest first and labelled, before the stop's own line: those
/// waiting just before it, at or below its cutoff and admitted after `from`.
/// One shown while it waited is labelled here too: the stop is what asks the
/// person to send it again. Their bytes belong to no item.
fn excludedAtStop(requests: client.Requests, store: []const u8, session: []const u8, stop: protocol.ActivityItem, from: u64, sink: anytype, colour: bool) !void {
    var cursor: protocol_reply.ActivityCursor = .{ .end = stop.position - 1, .position = from };
    var first = true;
    while (true) {
        const page = switch (try requests.activityPage(store, session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.facts.items[0..page.facts.count]) |item| {
            var value = switch (item.value) {
                .admission => |value| value,
                else => continue,
            };
            if (value.sender != null or value.state != .queued or value.admission > stop.value.stop.cutoff) continue;
            if (first) sink.excluding(item.position);
            first = false;
            value.state = .excluded;
            try message(requests, store, session, item, value, .lasting(false), sink, colour);
        }
        cursor = page.continuation() orelse return;
    }
}
