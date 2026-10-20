//! Bounded public Activity presentation with one forward-only content pass.
//! A failed stream may leave a visible prefix; the terminal owner must not retry it.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");
const tools = @import("tools.zig");
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

/// The most columns a peer reference takes on its line, `…` included.
pub const peer_ref_columns = 16;

/// A peer reference as its line names it: a generated `rui/` reference by
/// the shortest prefix of its ID that tells it apart in its Store, any other
/// exactly, escaped; past `peer_ref_columns` characters it ends with `…`.
pub fn peerRef(peer: protocol.Peer, buffer: *[4 * protocol.max_session_bytes + 8]u8) []const u8 {
    const session = peer.session.slice();
    const shown = if (peer.prefix != 0) session[4..][0..peer.prefix] else session;
    var escaped: [4 * protocol.max_session_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&escaped);
    var text: Text = .{ .mode = .line };
    text.feed(&out, shown) catch unreachable;
    text.finish(&out) catch unreachable;
    const bytes = out.buffered();
    var clusters = unicode.graphemeIterator(bytes);
    var count: usize = 0;
    var cut: usize = 0;
    while (clusters.next()) |cluster| {
        count += 1;
        if (count == peer_ref_columns) cut = cluster.start;
    }
    if (count <= peer_ref_columns) {
        @memcpy(buffer[0..bytes.len], bytes);
        return buffer[0..bytes.len];
    }
    @memcpy(buffer[0..cut], bytes[0..cut]);
    @memcpy(buffer[cut..][0.."…".len], "…");
    return buffer[0 .. cut + "…".len];
}

test "a peer reference shows a generated ID's distinguishing prefix and caps at 16 columns" {
    var buffer: [4 * protocol.max_session_bytes + 8]u8 = undefined;
    var generated: protocol.Peer = .{ .session = .{}, .prefix = 7 };
    try generated.session.set("rui/1a2b3c4-5e6f-4a7b-8c9d-0e1f2a3b4c5d");
    try std.testing.expectEqualStrings("1a2b3c4", peerRef(generated, &buffer));
    var exact: protocol.Peer = .{ .session = .{} };
    try exact.session.set("reviewer");
    try std.testing.expectEqualStrings("reviewer", peerRef(exact, &buffer));
    try exact.session.set("abcdefghijklmnop");
    try std.testing.expectEqualStrings("abcdefghijklmnop", peerRef(exact, &buffer));
    try exact.session.set("abcdefghijklmnopq");
    try std.testing.expectEqualStrings("abcdefghijklmno…", peerRef(exact, &buffer));
    // Controls stay visible as escapes, and count where they show.
    try exact.session.set("a\nb");
    try std.testing.expectEqualStrings("a\\nb", peerRef(exact, &buffer));
}

test "peer Messages render as one dim line each, with size and time in the margin" {
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
    var peer: protocol.Peer = .{ .session = .{}, .prefix = 6 };
    try peer.session.set("rui/9f8e7d6c-0000-4000-8000-000000000001");
    const S = Mark.summary;
    const N = Mark.sidenote;
    const R = Mark.reset;
    // Leading blank lines and trailing blanks never show; later lines never do.
    inline for (.{
        .{ .inbound, "\n  \nPlease review\t \nsecond line", "\n" ++ S ++ "← 9f8e7d · Please review" ++ N ++ "31 B · 08:00" ++ R ++ "\n" },
        .{ .outbound, "done", "\n" ++ S ++ "→ 9f8e7d · done" ++ N ++ "4 B · 08:00" ++ R ++ "\n" },
        .{ .inbound, " \n", "\n" ++ S ++ "← 9f8e7d" ++ N ++ "2 B · 08:00" ++ R ++ "\n" },
        // Peer text cannot draw controls or styles.
        .{ .outbound, "\x1b[2mx", "\n" ++ S ++ "→ 9f8e7d · \\x1b[2mx" ++ N ++ "5 B · 08:00" ++ R ++ "\n" },
        // Under 1000 bytes the size is exact; from there it is in KB.
        .{ .inbound, comptime repeat("x", 999), "\n" ++ S ++ "← 9f8e7d · " ++ comptime repeat("x", 200) ++ "…" ++ N ++ "999 B · 08:00" ++ R ++ "\n" },
    }) |case| {
        var sink: Sink = .{};
        var line: PeerLine(*Sink) = undefined;
        try line.init(&sink, case[0], peer, case[1].len);
        try line.feed(case[1][0..1]);
        try line.feed(case[1][1..]);
        try line.finish(1_800_000_000);
        try std.testing.expectEqualStrings(case[2], sink.bytes[0..sink.length]);
    }
    // A first line past the preview keeps whole graphemes and says it continues.
    var sink: Sink = .{};
    var line: PeerLine(*Sink) = undefined;
    const long = comptime repeat("é", 500);
    try line.init(&sink, .inbound, peer, long.len);
    try line.feed(long);
    try line.finish(1_800_000_000);
    try std.testing.expectEqualStrings("\n" ++ S ++ "← 9f8e7d · " ++ comptime repeat("é", 100) ++ "…" ++ N ++ "1.0 KB · 08:00" ++ R ++ "\n", sink.bytes[0..sink.length]);
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
/// from a peer, `→ ref · first line` sent to one. Its size and admission
/// time go in the right margin, size first so a narrow view drops it.
/// Initialize in final storage, feed the Message's exact bytes, then finish.
pub fn PeerLine(comptime Sink: type) type {
    return struct {
        const Self = @This();
        sink: Sink,
        length: u64,
        received: u64 = 0,
        line: [preview_bytes + 4]u8 = undefined,
        line_bytes: usize = 0,
        // Before the first non-blank byte, in it, or past its line.
        phase: enum { leading, first, after } = .leading,
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
                .after => return,
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

        pub fn finish(self: *Self, admitted_at: u64) anyerror!void {
            if (self.received != self.length) return error.ContentLengthMismatch;
            const kept = trimmed(self.line[0..self.line_bytes]);
            if (kept.len != 0) {
                try self.sink.feed(" · ");
                const cut = if (!self.longer and kept.len <= preview_bytes) kept.len else graphemeCut(kept, preview_bytes);
                var escaped: Escaped(Sink) = .{ .sink = self.sink, .text = .{ .mode = .multiline } };
                try escaped.feed(kept[0..cut]);
                try escaped.finish();
                if (cut != kept.len or self.longer) try self.sink.feed("…");
            }
            try self.sink.feed(Mark.sidenote);
            // Short peer Messages are common; "0.0 KB" would say nothing.
            var size: [24]u8 = undefined;
            try self.sink.feed(if (self.length < 1000) std.fmt.bufPrint(&size, "{d} B", .{self.length}) catch unreachable else kilobytes(self.length, &size));
            var buffer: [5]u8 = undefined;
            if (clock(admitted_at, &buffer)) |time| {
                try self.sink.feed(" · ");
                try self.sink.feed(time);
            }
            try self.sink.feed(Mark.reset ++ "\n");
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
/// `┄ N more lines · X KB` row, and trailing blank lines never show. `whole`
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
                try self.escaped.feed(self.small[0..drawn(self.small[0..self.length])]);
                try self.escaped.finish();
            } else {
                if (self.length <= collapse_bytes) try self.scan(self.small[0..self.length]);
                try self.endLine();
                if (self.shown != 0) try self.out.feed("\n");
                try self.out.feed(Mark.summary);
                var count: [32]u8 = undefined;
                var size: [24]u8 = undefined;
                const hidden = self.nonblank - self.shown;
                try self.out.feed(switch (hidden) {
                    0 => "┄ ",
                    1 => "┄ 1 more line · ",
                    else => std.fmt.bufPrint(&count, "┄ {d} more lines · ", .{hidden}) catch unreachable,
                });
                try self.out.feed(kilobytes(self.length, &size));
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
fn drawn(bytes: []const u8) usize {
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
        .{ .input = "1\n2\n3\n4\n5", .output = B ++ "1\n  2\n  " ++ S ++ "┄ 3 more lines · 0.0 KB" ++ R },
        // Twelve lines from the first non-blank to the last fit; thirteen do not.
        .{ .input = "a" ++ six ++ "b" ++ five ++ "c", .output = B ++ "a" ++ six ++ "  b" ++ five ++ "  c" ++ R },
        .{ .input = "a" ++ six ++ "b" ++ six ++ "c", .output = B ++ "a\n  b\n  " ++ S ++ "┄ 1 more line · 0.0 KB" ++ R },
        // Leading and trailing blank lines do not count; trailing ones never show.
        .{ .input = twenty ++ "a\n \t\r\n", .output = B ++ twenty ++ "  a" ++ R },
        .{ .input = "a\r\n", .output = B ++ "a\\x0d" ++ R },
        // Long only by its bytes: a cut line counts as shown.
        .{ .input = x[0..1025], .output = B ++ x[0..200] ++ cut ++ "\n  " ++ S ++ "┄ 1.0 KB" ++ R },
        // Cuts count source bytes and never split a grapheme.
        .{ .input = "\x01" ++ a[0..197] ++ "😀" ++ x[0..900], .output = B ++ "\\x01" ++ a[0..197] ++ cut ++ "\n  " ++ S ++ "┄ 1.1 KB" ++ R },
        .{ .input = a[0..199] ++ "e\u{301}" ++ x[0..900], .output = B ++ a[0..199] ++ cut ++ "\n  " ++ S ++ "┄ 1.1 KB" ++ R },
        .{ .input = a[0..200] ++ "\n" ++ x[0..900], .output = B ++ a[0..200] ++ "\n  " ++ x[0..200] ++ cut ++ "\n  " ++ S ++ "┄ 1.1 KB" ++ R },
        // Preview lines skip blank ones; a large Message streams.
        .{ .input = "\n \nfirst\n\nsecond\nthird\n" ++ x ++ "\n\n", .output = B ++ "first\n  second\n  " ++ S ++ "┄ 2 more lines · 1.1 KB" ++ R },
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
        .tool_unavailable => .{ .glyph = "•", .suffix = " — Rejected: tool unavailable", .style = .normal },
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

    // Worst terminal escaping is four bytes per input byte; allow glyph/suffix.
    pub const line_bytes = 4 * protocol.max_tool_description_bytes + 96;
    pub fn line(self: *const Live, index: usize, buffer: *[line_bytes]u8) ![]const u8 {
        const entry = self.entries[index];
        const state = toolState(entry.presentation.code);
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{s} ", .{state.glyph});
        var text: Text = .{ .mode = .line };
        try text.feed(&writer, if (entry.presentation.description) |label| label.slice() else "Tool call");
        try text.finish(&writer);
        try writer.writeAll(state.suffix);
        return writer.buffered();
    }

    pub fn style(self: *const Live, index: usize) Style {
        return toolState(self.entries[index].presentation.code).style;
    }
};

/// Live conversation and inspection share hanging indentation. Input is already
/// escaped or rendered; cell layout owns wrapping in the alternate screen.
pub fn Indented(comptime Sink: type) type {
    return struct {
        sink: Sink,
        line_start: bool = false,
        sgr: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var storage: [4096]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (storage.len - out.end < 3) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                if (self.line_start and byte != '\n') {
                    try out.writeAll("  ");
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

/// What the Action heading says, for keeping it beside the choice.
pub const ActionSummary = struct {
    description: protocol.Bounded(protocol.max_tool_description_bytes) = .{},
    // The Workspace the Action document names, not whatever is current later.
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    timeout_ms: ?u64 = null,
};

pub fn permission(requests: client.Requests, store: []const u8, session: []const u8, action: u64, workspace: []const u8, scratch: std.Io.File, sink: anytype, colour: bool) !ActionSummary {
    // Action reads write at the descriptor's streaming offset, not positionally.
    try requests.io.vtable.fileSeekTo(requests.io.userdata, scratch, 0);
    try scratch.setLength(requests.io, 0);
    var reply: client.ReplyBuffer = .{};
    const result = try requests.readActionArguments(store, session, action, scratch, &reply);
    if (result == .command) {
        const failure = requests.captureReadFailure(result.command) catch {
            try client.checkCanonicalFailure(result.command);
            return error.ActionReadFailed;
        };
        if (failure.err() == error.CanonicalStoreFailure) return error.CanonicalStoreFailure;
        return error.ActionReadFailed;
    }
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(requests.io, &buffer);
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
    // Where and how long first, then the exact command; the description is
    // the model's label, never a substitute for the command.
    try sink.feed("\n");
    try sink.feed(Style.attention.code(colour));
    try sink.feed("? Run Bash");
    try sink.feed(Style.normal.code(colour));
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (arguments.description.len != 0) {
        try indented.feed(" · ");
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
        try label.feed(arguments.description.slice());
        try label.finish();
    }
    try indented.feed("\nWorkspace: ");
    var location: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
    try location.feed(workspace);
    try location.finish();
    if (arguments.timeout_ms) |timeout| {
        try print(&indented, "\nTime limit: {d} ms", .{timeout});
    } else try indented.feed("\nTime limit: Host default");
    try indented.feed("\n$ ");
    var command: Indented(*Indented(@TypeOf(sink))) = .{ .sink = &indented };
    var escaped: Escaped(@TypeOf(&command)) = .{ .sink = &command, .text = .{ .mode = .multiline } };
    if (!try tools.writeBashCommand(&source, &escaped)) return error.InvalidBashArguments;
    try escaped.finish();
    try command.finish();
    try indented.feed("\n");
    try indented.finish();
    var summary: ActionSummary = .{ .description = arguments.description, .timeout_ms = arguments.timeout_ms };
    try summary.workspace.set(workspace);
    return summary;
}

pub fn current(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File) !client.Current {
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
    return switch (try client.CurrentReply.decode(requests.io, scratch, session, report)) {
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

/// Exact fixed-end summary requires a metadata walk, not Current or the newest
/// page. Retains no identity or payload: a transcript lists unapplied Messages
/// in full where they belong (see `message`).
pub const Pending = struct {
    total: u64 = 0,
    /// The newest queued Message's admission id. Once applied, its row shows
    /// nothing live, so live reads count it shown (see session_reads.Messages).
    newest: u64 = 0,
    /// The lowest position of a Message not applied at the end, if any:
    /// where a transcript's search for unapplied Messages may stop.
    lowest: ?u64 = null,

    pub fn render(self: *const Pending, sink: anytype) !void {
        if (self.total == 0) return;
        try print(sink, "Rui: {d} queued messages.\n", .{self.total});
    }
};

pub fn pending(requests: client.Requests, store: []const u8, session: []const u8, end: u64) !Pending {
    var summary: Pending = .{};
    var cursor: client.ActivityCursor = .{ .end = end };
    while (true) {
        const page = switch (try requests.activityPage(store, session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.facts.items[0..page.facts.count]) |item| {
            if (item.value != .admission or item.value.admission.state == .applied) continue;
            if (summary.lowest == null) summary.lowest = item.position;
            if (item.value.admission.state != .queued) continue;
            summary.total += 1;
            summary.newest = @max(summary.newest, item.value.admission.admission);
        }
        cursor = page.continuation() orelse return summary;
    }
}

/// What a Message's state was when read: a transcript labels it as of then.
pub fn messageLabel(state: @FieldType(protocol.ActivityItem.Message, "state")) ?[]const u8 {
    return switch (state) {
        .applied => null,
        .queued => "Queued",
        .excluded => "Stopped before it ran · send it again to run it",
    };
}

/// One Message in full, labelled unless applied: live, in the opening and in
/// a transcript's listing alike.
pub fn message(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, value: protocol.ActivityItem.Message, label: bool, sink: anytype, colour: bool) !void {
    if (label) if (messageLabel(value.state)) |text| try print(sink, "\n! {s}", .{text});
    if (value.sender) |sender| {
        var line: PeerLine(@TypeOf(sink)) = undefined;
        try line.init(sink, .inbound, sender, value.content.length);
        try content(requests, store, session, item, value.content, &line);
        return line.finish(value.admitted_at);
    }
    try userPrefix(sink, colour, value.admitted_at);
    var body: UserBody(@TypeOf(sink)) = undefined;
    try body.init(sink, value.content.length, false);
    try content(requests, store, session, item, value.content, &body);
    if (try body.finish()) try noteCollapsed(sink, .{ .source = .activity, .position = item.position, .ordinal = item.ordinal, .content = value.content, .row = item.value == .user });
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
            .denied, .unknown_tool, .invalid_arguments, .tool_unavailable => .ended,
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
            const routine = !self.omitted and
                (std.mem.eql(u8, line, "Bash succeeded. Exit code: 0.") or
                    std.mem.eql(u8, line, "Process retirement confirmed: the child was reaped and the original process group was observed absent. macOS group signaling returned EPERM, which can mean no live targets or permission denial."));
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
                // Strip the canonical trailer that follows stderr bytes.
                while (self.stderr.count != 0) {
                    const line = self.stderr.last(0);
                    if (line.len == 0 or std.mem.eql(u8, line, "Full output was not retained.") or
                        std.mem.startsWith(u8, line, "Full stdout: ") or std.mem.startsWith(u8, line, "Full stderr: "))
                    {
                        self.stderr.dropLast();
                    } else if (std.mem.eql(u8, line, "[earlier output omitted]")) {
                        self.earlier_omitted = true;
                        self.stderr.dropLast();
                    } else break;
                }
                while (self.stdout.count != 0 and self.stdout.last(0).len == 0) self.stdout.dropLast();
                const tail = if (self.stderr.total != 0) &self.stderr else &self.stdout;
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
    const retirement = "Process retirement confirmed: the child was reaped and the original process group was observed absent. macOS group signaling returned EPERM, which can mean no live targets or permission denial.";
    const warning = "Process-group signaling reported a failure.";
    const incomplete = "Capture may be incomplete because writers outlived process-group termination.";
    const capture_failure = "Capture failure: read; output may be incomplete.";
    const cases = .{
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ retirement ++ "\nstdout tail:\nhidden", "", "" },
        .{ .succeeded, retirement, "", "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ incomplete ++ "\n" ++ retirement ++ "\n" ++ warning ++ "\nstderr tail:\nhidden", "  " ++ incomplete ++ "\n  " ++ warning, "" },
        .{ .failed, "Bash failed. Exit code: 7.\n" ++ retirement ++ "\n" ++ capture_failure, "  " ++ capture_failure, "7" },
        .{ .timed_out, "Bash timed_out. Signal: 15.\n" ++ retirement ++ "\n" ++ warning, "  Signal: 15.\n  " ++ warning, "" },
        .{ .cancelled, "Bash cancelled. Signal: 15.\n" ++ retirement, "  Signal: 15.", "" },
        .{ .indeterminate, "Bash indeterminate. Unknown process status: 0.\n" ++ warning, "  Unknown process status: 0.\n  " ++ warning, "" },
        .{ .failed, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning.", "" },
        .{ .succeeded, "Bash failed. Exit code: 7.", "  Bash failed. Exit code: 7.", "" },
        .{ .succeeded, retirement ++ " Additional warning.", "  " ++ retirement ++ " Additional warning.", "" },
        .{ .succeeded, "Process retirement unconfirmed.\n" ++ warning, "  Process retirement unconfirmed.\n  " ++ warning, "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning.", "" },
        .{ .succeeded, retirement ++ @as([256]u8, @splat('x')) ++ "\n" ++ warning, "  " ++ (retirement ++ @as([256]u8, @splat('x')))[0..256] ++ " [summary shortened; /details]\n  " ++ warning, "" },
        .{ .succeeded, "stdout tail: unavailable\n" ++ warning, "  stdout tail: unavailable\n  " ++ warning, "" },
        // Failures show the last stderr lines, else stdout, without the trailer.
        .{ .failed, "Bash failed. Exit code: 127.\nstdout tail:\n\nstderr tail:\nbash: line 1: rui: command not found\n\nFull stdout: /s/o\nFull stderr: /s/e\n", "  bash: line 1: rui: command not found", "127" },
        .{ .failed, "Bash failed. Exit code: 1.\nstdout tail:\nusage: x\nhelp\n\nstderr tail:\n\nFull output was not retained.\n", "  usage: x\n  help", "1" },
        .{ .failed, "Bash failed. Exit code: 2.\nstdout tail:\n\nstderr tail:\none\ntwo\nthree\nfour\n\n[earlier output omitted]\n\nFull output was not retained.\n", "  two\n  three\n  four\n  /details for full output.", "2" },
        .{ .failed, "Bash failed. Exit code: 3.\nstdout tail:\n\nstderr tail:\nonly\n\n[earlier output omitted]\n", "  only\n  /details for full output.", "3" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\nstdout tail:\nhidden\n\nstderr tail:\nalso hidden\n", "", "" },
        .{ .failed, "Bash failed. Exit code: 4.\nstdout tail:\n\nstderr tail:\n\x1b[2Jcontrol\n", "  \\x1b[2Jcontrol", "4" },
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

fn workEnded(sink: anytype, code: []const u8) !void {
    try print(sink, "\n! Work ended: {s}. Send a message to continue.\n", .{code});
}

test "an ended Turn says what happened and what to do next where it ended" {
    var buffer: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    var sink: Sink = .{ .out = &out };
    try workEnded(&sink, "retry_exhausted");
    // /status only repeats the code, so the line itself carries the next step.
    try std.testing.expectEqualStrings("\n! Work ended: retry_exhausted. Send a message to continue.\n", out.buffered());
}

pub fn render(requests: client.Requests, store: []const u8, session: []const u8, page: *const client.ActivityPage, sink: anytype, colour: bool, compact_tools: *bool) !void {
    const historical = page.facts.direction == .backward;
    for (0..page.facts.count) |index| {
        const item = page.facts.items[if (historical) page.facts.count - index - 1 else index];
        // The sink learns which item its next bytes belong to: some items
        // render nothing, and a read boundary must name the first that does.
        sink.item(item);
        switch (item.value) {
            .admission => |value| {
                if (historical and value.state == .applied) continue;
                compact_tools.* = false;
                try message(requests, store, session, item, value, historical, sink, colour);
            },
            .user => |value| {
                if (!historical) continue; // Live Admission already showed it.
                compact_tools.* = false;
                try message(requests, store, session, item, value, false, sink, colour);
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
                try workEnded(sink, outcome.code.slice());
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
                try line.finish(sent.admitted_at);
            },
            .send_failed => |failed| {
                compact_tools.* = false;
                try sendFailed(sink, failed.target);
            },
        }
    }
}
