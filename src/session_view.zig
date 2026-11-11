//! Bounded public Activity presentation with one forward-only content pass.
//! A failed stream may leave a visible prefix; the terminal owner must not retry it.
const std = @import("std");
const tool_fold = @import("tool_fold.zig");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");
pub const Destination = Renderer.Destination;
const tools = @import("tools.zig");
const failure_class = @import("failure_class.zig");
const marks = @import("marks.zig");
const work_line = @import("work_line.zig");
const unicode = @import("terminal_unicode");

/// Only presentation-owned foreground changes. Content cannot select a style.
pub const Style = enum {
    user,
    quiet,
    attention,
    failure,
    normal,

    fn fromTone(tone: marks.Tone) Style {
        return switch (tone) {
            .ink => .user,
            .normal => .normal,
            .quiet => .quiet,
            .attention => .attention,
            .failure => .failure,
        };
    }

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

test "peer Messages render as one dim line each, named, grouped with tool rows, with time in the margin and never their text" {
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
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("9f8e7d");
    const S = Mark.summary;
    const N = Mark.sidenote;
    const R = Mark.reset;
    const L = peerLink;
    var sink: Sink = .{};
    var compact = false;
    try peerLine(&sink, .inbound, peer, 1_800_000_000, &compact);
    try std.testing.expectEqualStrings("\n" ++ S ++ "← Received message from " ++ comptime L("9f8e7d", "9f8e7d") ++ N ++ "08:00" ++ R ++ "\n", sink.bytes[0..sink.length]);
    // Without a time the margin stays empty.
    sink = .{};
    compact = false;
    try peerLine(&sink, .outbound, peer, std.math.maxInt(u64), &compact);
    try std.testing.expectEqualStrings("\n" ++ S ++ "→ Messaged " ++ comptime L("9f8e7d", "9f8e7d") ++ R ++ "\n", sink.bytes[0..sink.length]);
    var failed: Sink = .{};
    try sendFailed(&failed, peer, &compact);
    try std.testing.expectEqualStrings("\n" ++ S ++ "× Messaged " ++ comptime L("9f8e7d", "9f8e7d") ++ R ++ "\n", failed.bytes[0..failed.length]);
    try std.testing.expect(!compact);
    // A named peer shows by its name, escaped as a label is, and rows in a
    // row share one group with no blank line between them.
    var named = peer;
    try named.label.set("Review\x1b[2m the WAL");
    var group: Sink = .{};
    try peerLine(&group, .outbound, named, 1_800_000_000, &compact);
    try peerLine(&group, .inbound, named, 1_800_000_000, &compact);
    try std.testing.expectEqualStrings("\n" ++ S ++ "→ Messaged " ++ comptime L("9f8e7d", "Review\\x1b[2m the WAL") ++ N ++ "08:00" ++ R ++ "\n" ++
        S ++ "← Received message from " ++ L("9f8e7d", "Review\\x1b[2m the WAL") ++ N ++ "08:00" ++ R ++ "\n", group.bytes[0..group.length]);
}

/// A peer's name as its row writes it: a link to its Session.
fn peerLink(comptime id: []const u8, comptime name: []const u8) []const u8 {
    return Text.link_open ++ Text.session_link ++ id ++ Text.link_end ++ "\x1b[4m" ++ name ++ Text.link_close ++ Mark.reset ++ Mark.summary;
}

test "failed peer Messages distinguish absent targets and reset grouping without changing named output" {
    const Sink = struct {
        bytes: [1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("k7m2qx");
    var named = peer;
    try named.label.set("Review\x1b[2m the WAL");
    const cases = [_]struct { target: ?protocol.NamedPeer, line: []const u8 }{
        .{ .target = null, .line = "× Message not delivered" },
        .{ .target = peer, .line = "× Messaged " ++ comptime peerLink("k7m2qx", "k7m2qx") },
        .{ .target = named, .line = "× Messaged " ++ comptime peerLink("k7m2qx", "Review\\x1b[2m the WAL") },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |grouped| {
            var sink: Sink = .{};
            var compact = grouped;
            try sendFailed(&sink, case.target, &compact);
            try std.testing.expect(!compact);
            var expected: [1024]u8 = undefined;
            const line = try std.fmt.bufPrint(&expected, "\n" ++ Mark.summary ++ "{s}" ++ Mark.reset ++ "\n", .{case.line});
            try std.testing.expectEqualStrings(line, sink.bytes[0..sink.length]);
            // The next ordinary peer row starts a new group, even when the
            // rejected Message interrupted an existing compact group.
            const boundary = sink.length;
            try peerLine(&sink, .outbound, peer, std.math.maxInt(u64), &compact);
            try std.testing.expect(compact);
            try std.testing.expectEqualStrings("\n" ++ Mark.summary ++ "→ Messaged " ++ comptime peerLink("k7m2qx", "k7m2qx") ++ Mark.reset ++ "\n", sink.bytes[boundary..sink.length]);
        }
    }
}

/// One peer Message as one upright dim line, never `›`, in the tool rows'
/// group: `← Received message from NAME` from a peer, `→ Messaged NAME` sent
/// to one, NAME being its label or, with none, its ID. Its admission time goes
/// in the right margin. The Message's text never shows; the model reads it.
/// `compact` is the tool rows' grouping: a row after another one joins it
/// without a blank line.
pub fn peerLine(sink: anytype, direction: enum { inbound, outbound }, peer: protocol.NamedPeer, admitted_at: u64, compact: *bool) !void {
    if (!compact.*) try sink.feed("\n");
    compact.* = true;
    try sink.feed(Mark.summary);
    try sink.feed(if (direction == .inbound) "← Received message from " else "→ Messaged ");
    try peerName(sink, peer);
    var buffer: [5]u8 = undefined;
    if (clock(admitted_at, &buffer)) |time| {
        try sink.feed(Mark.sidenote);
        try sink.feed(time);
    }
    try sink.feed(Mark.reset ++ "\n");
}

/// A Message this Session sent that was rejected: set apart, as a failed
/// tool row is. No target means the attempt named no valid Session reference.
pub fn sendFailed(sink: anytype, target: ?protocol.NamedPeer, compact: *bool) !void {
    compact.* = false;
    try sink.feed("\n" ++ Mark.summary);
    if (target) |peer| {
        try sink.feed("× Messaged ");
        try peerName(sink, peer);
    } else try sink.feed("× Message not delivered");
    try sink.feed(Mark.reset ++ "\n");
}

/// A peer's label, escaped as any label is, or its ID when it has none,
/// underlined as a link to its Session. The view keeps the ID as the link's
/// hidden address. The row's dim summary style resumes after the name.
fn peerName(sink: anytype, peer: protocol.NamedPeer) !void {
    const id = peer.session.slice();
    // An ID that could end the sequence it rides in is shown, not linked.
    const linked = id.len != 0 and for (id) |byte| {
        if (byte <= ' ' or byte >= 0x7f or byte == '\\') break false;
    } else true;
    if (linked) {
        try sink.feed(Text.link_open ++ Text.session_link);
        try sink.feed(id);
        try sink.feed(Text.link_end ++ "\x1b[4m");
    }
    var escaped: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .label } };
    try escaped.feed(peer.name());
    try escaped.finish();
    if (linked) try sink.feed(Text.link_close ++ Mark.reset ++ Mark.summary);
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
/// shows every byte in a Message page. Initialize in final storage.
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
    const state: struct { mark: marks.Mark, suffix: []const u8 } = switch (code) {
        .unresolved => .{ .mark = .active, .suffix = "" },
        .pending_permission => .{ .mark = .needs_you, .suffix = "" },
        .succeeded => .{ .mark = .finished, .suffix = "" },
        .denied => .{ .mark = .stopped, .suffix = " · denied" },
        .unknown_tool => .{ .mark = .failed, .suffix = " · rejected" },
        .invalid_arguments => .{ .mark = .failed, .suffix = " · rejected" },
        .failed => .{ .mark = .failed, .suffix = "" },
        .timed_out => .{ .mark = .failed, .suffix = " · timed out" },
        .indeterminate => .{ .mark = .failed, .suffix = " · may have run" },
        .storage_failed => .{ .mark = .failed, .suffix = " · output lost" },
        .spawn_failed => .{ .mark = .failed, .suffix = " · could not start" },
        .cancelled => .{ .mark = .stopped, .suffix = "" },
        .infrastructure_shutdown => .{ .mark = .failed, .suffix = " · may have run" },
    };
    const shown = marks.marks.get(state.mark);
    return .{ .glyph = shown.unicode, .suffix = state.suffix, .style = Style.fromTone(shown.tone) };
}

test "list rows share every mark and script with the chat heading table" {
    const overview = @import("overview_view.zig");
    const Case = struct {
        mark: marks.Mark,
        state: overview.WorkState,
        colour: overview.Colour,
        tool: ?protocol.ToolPresentation.Code,
    };
    const cases = [_]Case{
        .{ .mark = .needs_you, .state = .{ .approval = .{ .since = 1 } }, .colour = .attention, .tool = .pending_permission },
        .{ .mark = .active, .state = .{ .working = .{ .since = 1 } }, .colour = .ink, .tool = .unresolved },
        .{ .mark = .queued, .state = .{ .pending = .{ .since = 1 } }, .colour = .quiet, .tool = null },
        .{ .mark = .waiting, .state = .{ .idle = .{ .since = 1 } }, .colour = .normal, .tool = null },
        .{ .mark = .finished, .state = .{ .finished = .{ .since = 1 } }, .colour = .mark, .tool = .succeeded },
        .{ .mark = .failed, .state = .{ .failed = .{ .since = 1, .code = .{}, .resets_at = null } }, .colour = .failure, .tool = .failed },
        .{ .mark = .stopped, .state = .{ .stopped = .{ .since = 1, .cause = .stop } }, .colour = .normal, .tool = .denied },
    };
    const Sink = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,

        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    try std.testing.expect(overview.Mark == marks.Mark);
    var seen: std.enums.EnumSet(marks.Mark) = .empty;
    for (cases) |case| {
        seen.insert(case.mark);
        const shared = marks.marks.get(case.mark);
        var state: overview.State = undefined;
        try state.init(std.testing.allocator, .{ .cwd = "/work", .home = "/home" });
        defer state.deinit();
        _ = try overview.step(&state, .{ .tick = 100_000 });
        _ = try overview.step(&state, .{ .list = .{ .page = .{
            .rows = &.{.{ .reference = "k7m2qx".*, .workspace = "/work", .label = "Work", .state = case.state }},
            .answer = .{ .delta = .full, .since = .{ .instance = @splat(7), .generation = 1 } },
        } } });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        for ([_]bool{ true, false }) |unicode_script| {
            const caps: overview.Caps = .{ .unicode = unicode_script };
            try std.testing.expect(!overview.markSpins(&state, .{ .row = 0 }, caps));
            const row = try overview.rowSegments(arena.allocator(), &state, 0, 80, caps, 4);
            try std.testing.expectEqualStrings(" ", row[0].text);
            try std.testing.expectEqualStrings(if (unicode_script) shared.unicode else shared.ascii, row[1].text);
            // List colours remain their own policy, including idle and finished.
            try std.testing.expectEqual(case.colour, row[1].style.colour);
        }
        // Tool headings use Unicode; queued and idle have no Tool outcome.
        if (case.tool) |code| {
            var heading: Sink = .{};
            try toolHeading(.{ .description = null, .code = code, .publication_position = null }, &heading, false, false);
            const end = std.mem.indexOfScalar(u8, heading.bytes[0..heading.length], ' ').?;
            try std.testing.expectEqualStrings(shared.unicode, heading.bytes[0..end]);
        }
    }
    try std.testing.expect(seen.eql(.full));
}

pub fn toolHeading(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, separate: bool) !void {
    return toolHeadingWith(presentation, sink, colour, separate, "", null);
}

/// `exit` is a digits-only exit status, shown only for a failed call.
fn toolHeadingWith(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, separate: bool, exit: []const u8, reference: ?tool_fold.Reference) !void {
    const state = toolState(presentation.code);
    if (separate) try sink.feed("\n");
    if (reference) |ref| if (comptime std.meta.hasMethod(@TypeOf(sink), "tool")) try sink.tool(ref);
    try sink.feed(state.style.code(colour));
    try sink.feed(state.glyph);
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .label } };
    try escaped.feed(if (presentation.description) |label| label.slice() else "Tool call");
    try escaped.finish();
    try indented.feed(state.suffix);
    if (presentation.code == .failed and exit.len != 0) {
        try indented.feed(" · exit ");
        try indented.feed(exit);
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
        std.debug.assert(marks.marks.get(.active).unicode.len + " ".len + work_line.max_clock_bytes <= line_bytes - Text.max_bytes_per_byte * protocol.max_tool_description_bytes);
    }

    /// The call's row; `running` is the clock after the words of the
    /// running call the work line names, and empty for every other call.
    pub fn line(self: *const Live, index: usize, buffer: *[line_bytes]u8, running: []const u8) ![]const u8 {
        const entry = self.entries[index];
        const state = toolState(entry.presentation.code);
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{s} ", .{state.glyph});
        var text: Text = .{ .mode = .label };
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

/// Frozen call identity and its saved conversation line, never the latest tool set.
pub const ActionTool = struct {
    name: protocol.Bounded(protocol.max_tool_name_bytes),
    description: protocol.Bounded(protocol.max_tool_description_bytes),
    server: ?protocol.Bounded(64) = null,

    pub fn runner(self: *const ActionTool) !tools.Runner {
        if (!protocol.validToolName(self.name.slice())) return error.InvalidObservation;
        if (self.server) |server| {
            if (!protocol.validToolName(server.slice()) or protocol.builtInTool(self.name.slice()) != null) return error.InvalidObservation;
            const record: tools.Record = .{ .name = self.name.slice(), .owner = .mcp, .server = server.slice() };
            return record.runner();
        }
        const builtin = protocol.builtInTool(self.name.slice()) orelse return error.InvalidObservation;
        return tools.record(builtin).runner();
    }
};

/// Selects frozen identity and saved presentation from a verified Current capture.
pub fn actionToolFromCapture(observed: *const protocol_reply.Current, io: std.Io, scratch: std.Io.File, action: u64) !?ActionTool {
    const Selection = struct {
        action: u64,
        selected: ?ActionTool = null,
        pub fn visit(self: *@This(), attention: protocol_reply.Current.Attention) !void {
            switch (attention) {
                .unresolved => |row| if (row.action.value == self.action) {
                    if (self.selected != null) return error.InvalidObservation;
                    var tool: ActionTool = .{ .name = .{}, .description = row.presentation.value.description orelse return error.InvalidObservation };
                    try tool.name.set(row.tool.slice());
                    if (row.server.value) |server| {
                        tool.server = .{};
                        try tool.server.?.set(server.slice());
                    }
                    self.selected = tool;
                },
                else => {},
            }
        }
    };
    var selection: Selection = .{ .action = action };
    try observed.traverse(io, scratch, &selection);
    return selection.selected;
}

/// Reads unresolved call identity and saved line before arguments reuse the capture.
/// A resolved or absent Action has no current approval metadata.
pub fn actionTool(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File) !?ActionTool {
    const observed = try current(requests, store, session, scratch);
    return actionToolFromCapture(&observed, requests.io, scratch, action);
}

/// Null means the selected approval target resolved since the activity scan.
pub fn permission(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File, sink: anytype, colour: bool) !?ActionSummary {
    const tool = try actionTool(requests, store, session, action, scratch) orelse return null;
    return try permissionForTool(requests, store, session, action, scratch, sink, colour, &tool);
}

/// The CLI's inspection and the conversation approval share the same MCP
/// presentation; neither guesses a runner from the arguments' shape.
pub fn permissionForTool(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File, sink: anytype, colour: bool, tool: *const ActionTool) !ActionSummary {
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
    return renderPermissionArguments(requests.io, scratch, sink, colour, tool);
}

const ArgumentSource = struct {
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

/// Renders a complete captured argument file; the consent owner applies the
/// same viewport bound to either runner before offering a decision.
pub fn renderPermissionArguments(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool, tool: *const ActionTool) !ActionSummary {
    return switch (try tool.runner()) {
        .bash => request(io, scratch, sink, colour),
        .mcp => mcpRequest(io, scratch, sink, colour, tool),
        .core, .provider => error.InvalidObservation,
    };
}

/// The leading bytes of the command a Bash Action's captured arguments
/// hold, as many as `buffer` takes; null for every other tool, whatever
/// its arguments look like, and for arguments that are not a command.
pub fn bashCommand(io: std.Io, scratch: std.Io.File, tool: *const ActionTool, buffer: []u8) !?[]const u8 {
    if (try tool.runner() != .bash) return null;
    var read_buffer: [4096]u8 = undefined;
    var reader = scratch.reader(io, &read_buffer);
    var source: ArgumentSource = .{ .reader = &reader.interface };
    const Leading = struct {
        bytes: []u8,
        len: usize = 0,
        pub fn writeAll(sink: *@This(), bytes: []const u8) !void {
            const kept = @min(sink.bytes.len - sink.len, bytes.len);
            @memcpy(sink.bytes[sink.len..][0..kept], bytes[0..kept]);
            sink.len += kept;
        }
    };
    var leading: Leading = .{ .bytes = buffer };
    const shown = tools.writeBashCommand(&source, &leading) catch |err| {
        if (tools.isBashDescriptorError(err)) return null;
        return err;
    };
    return if (shown) buffer[0..leading.len] else null;
}

/// Arguments remain exact JSON, not a Bash command or a schema interpretation.
/// Like Bash, render to the Action file in full: SessionScreen applies its
/// viewport bound and refuses consent when that file is only a preview.
fn mcpRequest(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool, tool: *const ActionTool) !ActionSummary {
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(io, &buffer);
    const summary: ActionSummary = .{ .description = tool.description };
    try sink.feed("\n");
    try sink.feed(Style.attention.code(colour));
    try sink.feed("?");
    try sink.feed(Style.normal.code(colour));
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (summary.description.len != 0) {
        try indented.feed(" ");
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .label } };
        try label.feed(summary.description.slice());
        try label.finish();
    }
    try indented.feed("\nTool: ");
    try indented.feed(tool.name.slice());
    try indented.feed("\nServer: ");
    try indented.feed(tool.server.?.slice());
    try indented.feed("\nArguments:\n");
    var lines: Indented(*Indented(@TypeOf(sink))) = .{ .sink = &indented, .prefix = content_mark, .marks_empty = true, .line_start = true };
    var escaped: Escaped(@TypeOf(&lines)) = .{ .sink = &lines, .text = .{ .mode = .multiline } };
    while (true) {
        const bytes = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try escaped.feed(bytes);
        reader.interface.toss(bytes.len);
    }
    try escaped.finish();
    try lines.finish();
    try indented.feed("\n");
    try indented.finish();
    return summary;
}

/// The request block from an Action's arguments JSON in `scratch`.
fn request(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool) !ActionSummary {
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(io, &buffer);
    var source: ArgumentSource = .{ .reader = &reader.interface };
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
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .label } };
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
    var summary: ActionSummary = .{};
    try summary.description.set(arguments.description.slice());
    return summary;
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
        pub fn init(self: *@This(), sink: Sink, home: []const u8, colour: bool, destination: Destination) void {
            self.* = .{ .sink = sink, .writer = undefined, .renderer = undefined };
            self.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.storage };
            self.renderer = .{ .out = &self.writer, .home = home, .colour = colour, .destination = destination };
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

test "answer table columns align in the viewport for every negotiated width and escaped cluster" {
    const vaxis = @import("vaxis");
    const Viewport = @import("ConversationViewport.zig");
    const input = "| Value | X |\n| --- | --- |\n" ++
        "| **\u{200b}** | X |\n| 雪 | X |\n| 🧑‍🌾 | X |\n" ++
        "| 🧑‍🧑‍🧑‍🧑‍🧑 | X |\n| \u{feff} | X |\n| \u{ad} | X |\n" ++
        "| \u{301} | X |\n| \x01 | X |\n| \x1b | X |\n| \u{202e} | X |\n" ++
        "| e\u{301} | X |\n| \u{600} | X |\n| `a\tb` | X |\n" ++
        "| e" ++ "\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}" ++ " | X |\n";
    const Sink = struct {
        document: *Viewport.Sized(4096, true),
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.document.append(bytes);
        }
    };
    for (std.enums.values(Viewport.Method)) |method| for ([_]bool{ false, true }) |colour| {
        for (0..input.len + 1) |split| {
            var document: Viewport.Sized(4096, true) = .{ .width_method = method };
            var answer: Answer(Sink) = undefined;
            answer.init(.{ .document = &document }, "", colour, .{ .viewport = method });
            try answer.feed(input[0..split]);
            try answer.feed(input[split..]);
            try answer.finish();
            try document.prepare();
            try std.testing.expect(std.mem.indexOf(u8, document.text(), "\\u{200b}") != null);
            try std.testing.expect(std.mem.indexOf(u8, document.text(), "\\u{feff}") != null);
            try std.testing.expect(std.mem.indexOf(u8, document.text(), "\\x01") != null);
            try std.testing.expect(std.mem.indexOf(u8, document.text(), "\\x1b") != null);
            try std.testing.expect(std.mem.indexOf(u8, document.text(), "\\u202e") != null);
            var cells: [120 * 16]vaxis.Cell = @splat(.{});
            var screen: vaxis.Screen = .{ .width = 120, .height = 16, .width_method = method, .buf = &cells };
            const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 16, .screen = &screen };
            const drawn = document.draw(window, .{}, true, colour, .{}, .{});
            errdefer std.debug.print("method={s} colour={} split={d} text={s}\n", .{ @tagName(method), colour, split, document.text() });
            try std.testing.expectEqual(@as(usize, 15), drawn.rows);
            var column: ?u16 = null;
            for (0..15) |row| {
                var found: ?u16 = null;
                for (0..120) |col| if (std.mem.eql(u8, screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme, "X")) {
                    try std.testing.expect(found == null);
                    found = @intCast(col);
                };
                try std.testing.expect(found != null);
                errdefer std.debug.print("row={d} marker={?d} wanted={?d}\n", .{ row, found, column });
                if (column) |wanted| try std.testing.expectEqual(wanted, found.?) else column = found;
            }
        }
    };
}

test "answer adapters pass NO_COLOR through inline names tables and fenced code" {
    const Sink = struct {
        output: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.output.writeAll(bytes);
        }
    };
    for ([_]Destination{ .terminal, .{ .viewport = .wcwidth } }) |destination| for ([_]bool{ false, true }) |colour| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var answer: Answer(Sink) = undefined;
        answer.init(.{ .output = &output.writer }, "", colour, destination);
        for ("`name`\n| A |\n| --- |\n| B |\n```zig\ncode\n\n```\n") |byte| try answer.feed(&.{byte});
        try answer.finish();
        try std.testing.expectEqual(colour, std.mem.indexOf(u8, output.written(), "\x1b[94m") != null);
        try std.testing.expectEqual(colour, std.mem.indexOf(u8, output.written(), "\x1b[90m") != null);
        try std.testing.expectEqual(destination == .viewport and colour, std.mem.indexOf(u8, output.written(), "\x1b[40m") != null);
        if (!colour) try std.testing.expectEqualStrings("name\n  A\n  B\n  code\n  \n", output.written());
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

/// What a Message's state was when read; an excluded Message was not sent.
pub fn messageLabel(state: @FieldType(protocol.ActivityItem.Message, "state"), labels: Labels) ?[]const u8 {
    if (labels == .none) return null;
    return switch (state) {
        .applied => null,
        .queued => if (labels == .excluded_and_queued) "Queued" else null,
        .excluded => "◌ not sent",
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
    try std.testing.expectEqualStrings("◌ not sent", messageLabel(.excluded, .lasting(false)).?);
    try std.testing.expect(messageLabel(.applied, .excluded_and_queued) == null);
    // Live output's next pages say what became of each Message.
    inline for (.{ .queued, .excluded, .applied }) |state| try std.testing.expect(messageLabel(state, .none) == null);
}

/// One Message in full, labelled unless applied: live, in the opening and in
/// a transcript's listing alike.
pub fn message(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, value: protocol.ActivityItem.Message, labels: Labels, sink: anytype, colour: bool, compact: *bool) !void {
    if (messageLabel(value.state, labels)) |text| {
        compact.* = false;
        try print(sink, "\n{s}{s}{s}", .{ Style.quiet.code(colour), text, Style.normal.code(colour) });
    }
    if (value.sender) |sender| return peerLine(sink, .inbound, sender, value.admitted_at, compact);
    const block: Collapsed = .{ .source = .activity, .position = item.position, .ordinal = item.ordinal, .content = value.content, .row = item.value == .user };
    compact.* = false;
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

pub const ToolHeaderFacts = struct {
    exit: ?u16 = null,
};

pub const ToolHeaderScan = struct {
    line: [64]u8 = undefined,
    length: usize = 0,
    ended: bool = false,
    overflow: bool = false,

    pub fn feed(self: *@This(), bytes: []const u8) !void {
        for (bytes) |byte| {
            if (self.ended) return;
            if (byte == '\n') {
                self.ended = true;
            } else if (self.length < self.line.len) {
                self.line[self.length] = byte;
                self.length += 1;
            } else {
                self.overflow = true;
                self.ended = true;
            }
        }
    }

    pub fn facts(self: *const @This(), code: protocol.ToolPresentation.Code) ToolHeaderFacts {
        if (self.overflow or toolState(code).style != .failure) return .{};
        var buffer: [64]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buffer, "Bash {s}. Exit code: ", .{@tagName(code)}) catch unreachable;
        const line = self.line[0..self.length];
        if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, ".")) return .{};
        const digits = line[prefix.len .. line.len - 1];
        if (digits.len == 0 or digits.len > 3) return .{};
        for (digits) |byte| if (!std.ascii.isDigit(byte)) return .{};
        return .{ .exit = std.fmt.parseInt(u16, digits, 10) catch return .{} };
    }
};

pub fn toolResult(presentation: protocol.ToolPresentation, facts: ToolHeaderFacts, sink: anytype, colour: bool, compact: *bool) !void {
    return toolResultRow(presentation, facts, null, sink, colour, compact);
}

pub fn toolResultRow(presentation: protocol.ToolPresentation, facts: ToolHeaderFacts, reference: ?tool_fold.Reference, sink: anytype, colour: bool, compact: *bool) !void {
    const succeeded = presentation.code == .succeeded;
    var buffer: [3]u8 = undefined;
    const exit = if (facts.exit) |value| try std.fmt.bufPrint(&buffer, "{d}", .{value}) else "";
    try toolHeadingWith(presentation, sink, colour, !compact.* or !succeeded, exit, reference);
    compact.* = succeeded;
}

test "tool header hides all body lines for every outcome and first-line split" {
    const Sink = struct {
        bytes: [1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const body = "Bash failed. Exit code: 7.\nProcess-group signaling reported a failure.\n" ++
        "Capture may be incomplete.\nstdout tail:\nhidden\nstderr tail:\n\x1b[2Jhidden\n" ++
        "[earlier output omitted]\nFull stdout: /secret\nOpen the tool row for saved output.\n";
    const cases = .{
        .{ protocol.ToolPresentation.Code.unresolved, "⠹ Tool call" },
        .{ protocol.ToolPresentation.Code.pending_permission, "? Tool call" },
        .{ protocol.ToolPresentation.Code.succeeded, "✓ Tool call" },
        .{ protocol.ToolPresentation.Code.failed, "× Tool call · exit 7" },
        .{ protocol.ToolPresentation.Code.timed_out, "× Tool call · timed out" },
        .{ protocol.ToolPresentation.Code.indeterminate, "× Tool call · may have run" },
        .{ protocol.ToolPresentation.Code.storage_failed, "× Tool call · output lost" },
        .{ protocol.ToolPresentation.Code.spawn_failed, "× Tool call · could not start" },
        .{ protocol.ToolPresentation.Code.cancelled, "■ Tool call" },
        .{ protocol.ToolPresentation.Code.infrastructure_shutdown, "× Tool call · may have run" },
        .{ protocol.ToolPresentation.Code.denied, "■ Tool call · denied" },
        .{ protocol.ToolPresentation.Code.unknown_tool, "× Tool call · rejected" },
        .{ protocol.ToolPresentation.Code.invalid_arguments, "× Tool call · rejected" },
    };
    try std.testing.expectEqual(std.enums.values(protocol.ToolPresentation.Code).len, cases.len);
    inline for (cases) |case| {
        for (0..body.len + 1) |split| {
            for ([_]bool{ false, true }) |colour| {
                var scan: ToolHeaderScan = .{};
                try scan.feed(body[0..split]);
                try scan.feed(body[split..]);
                var sink: Sink = .{};
                var compact = false;
                try toolResult(.{ .description = null, .code = case[0], .publication_position = null }, scan.facts(case[0]), &sink, colour, &compact);
                var expected: Sink = .{};
                try expected.feed("\n");
                const glyph_end = std.mem.indexOfScalar(u8, case[1], ' ').?;
                if (colour) try expected.feed(switch (case[0]) {
                    .unresolved => "\x1b[94m",
                    .pending_permission => "\x1b[33m",
                    .succeeded => "\x1b[90m",
                    .denied, .cancelled => "\x1b[39m",
                    else => "\x1b[91m",
                });
                try expected.feed(case[1][0..glyph_end]);
                if (colour) try expected.feed("\x1b[39m");
                try expected.feed(case[1][glyph_end..]);
                try expected.feed("\n");
                try std.testing.expectEqualStrings(expected.bytes[0..expected.length], sink.bytes[0..sink.length]);
                try std.testing.expectEqual(case[0] == .succeeded, compact);
            }
        }
    }
}

test "failed tool exit status is named rather than read as a count" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    for ([_][]const u8{ "1", "7", "127" }) |exit| {
        var buffer: [128]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var sink: Sink = .{ .out = &out };
        try toolHeadingWith(.{ .description = null, .code = .failed, .publication_position = null }, &sink, false, true, exit, null);
        var expected: [128]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "\n× Tool call · exit {s}\n", .{exit}), out.buffered());
    }
}

test "tool header numeric exit accepts only a complete canonical first line" {
    for (std.enums.values(protocol.ToolPresentation.Code)) |code| {
        if (toolState(code).style != .failure) continue;
        for ([_]u16{ 0, 1, 7, 127, 255, 999 }) |exit| {
            var buffer: [128]u8 = undefined;
            const body = try std.fmt.bufPrint(&buffer, "Bash {s}. Exit code: {d}.\nignored", .{ @tagName(code), exit });
            for (0..body.len + 1) |split| {
                var scan: ToolHeaderScan = .{};
                try scan.feed(body[0..split]);
                try scan.feed(body[split..]);
                try std.testing.expectEqual(exit, scan.facts(code).exit.?);
            }
        }
    }
    for ([_][]const u8{
        "Bash failed. Exit code: 1000.",                                "Bash failed. Exit code: -1.",
        "Bash failed. Exit code: 7. warning",                           "Bash failed. Exit code: .",
        "Bash failed. Exit code: 0007.",                                "Bash failed. Exit code: +7.",
        "ignored\nBash failed. Exit code: 7.",                          "Bash succeeded. Exit code: 7.",
        "Bash failed. Exit code: " ++ @as([128]u8, @splat('0')) ++ ".",
    }) |body| {
        var scan: ToolHeaderScan = .{};
        try scan.feed(body);
        try std.testing.expectEqual(null, scan.facts(.failed).exit);
    }
}

/// One state line. Optional tails are quiet destinations or future key hints.
const Ending = struct {
    mark: marks.Mark,
    words: []const u8,
    place: ?[]const u8 = null,
    key: ?[]const u8 = null,
    agent: ?[]const u8 = null,
};

fn ending(sink: anytype, end: Ending, colour: bool) !void {
    const mark = marks.marks.get(end.mark);
    const style = Style.fromTone(mark.tone);
    try sink.feed("\n");
    try sink.feed(style.code(colour));
    try sink.feed(mark.unicode);
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    if (end.agent) |agent| {
        try sink.feed("Agent ");
        var name: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .label } };
        try name.feed(agent);
        try name.finish();
        try sink.feed(if (end.mark == .stopped) " " else " · ");
    }
    try sink.feed(end.words);
    for ([_]?[]const u8{ end.place, end.key }) |tail| {
        if (tail) |words| {
            try sink.feed(Style.quiet.code(colour));
            try sink.feed(" · ");
            try sink.feed(words);
            try sink.feed(Style.normal.code(colour));
        }
    }
    try sink.feed("\n");
}

fn workEnded(sink: anytype, code: []const u8, colour: bool) !void {
    const cause = marks.cause(code);
    try ending(sink, .{ .mark = if (failure_class.of(code) == .interrupted) .stopped else .failed, .words = cause.words, .place = cause.place }, colour);
}

/// A descendant's outcome names that agent, never a saved code or report.
fn agentEnded(sink: anytype, agent: []const u8, code: []const u8, colour: bool) !void {
    const stopped = failure_class.of(code) == .interrupted;
    try ending(sink, .{ .mark = if (stopped) .stopped else .failed, .words = if (stopped) "stopped" else marks.cause(code).words, .agent = agent }, colour);
}

test "a descendant's ending names the agent without codes or advice" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var sink: Sink = .{ .out = &out };
    try agentEnded(&sink, "9f8e7d", "provider_http_401", false);
    try agentEnded(&sink, "9f8e7d", "cancelled", false);
    try agentEnded(&sink, "bad\x1b[2J", "malformed_provider_output", false);
    try std.testing.expectEqualStrings("\n× Agent 9f8e7d · Sign-in expired\n\n■ Agent 9f8e7d stopped\n\n× Agent bad\\x1b[2J · Model reply unreadable\n", out.buffered());
}

test "an ended Turn shows one plain cause line for every failure class" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    const cases = .{
        .{ "provider_policy", "× Refused by the provider" },
        .{ "provider_quota", "× Out of quota · Settings" },
        .{ "provider_plan", "× Model not in plan · Settings" },
        .{ "provider_model_unavailable", "× Model not served" },
        .{ "provider_http_401", "× Sign-in expired · Settings" },
        .{ "provider_api_key_rejected", "× API key rejected · Settings" },
        .{ "ResourceExceeded", "× Context full" },
        .{ "provider_tls_verification_failed", "× Provider unreachable" },
        .{ "retry_exhausted", "× Retries ran out" },
        .{ "cancelled", "■ Stopped" },
        .{ "provider_http_400", "× Provider refused the request" },
        .{ "unknown\x1b[2J", "× Something went wrong" },
        .{ "malformed_provider_output", "× Model reply unreadable" },
    };
    var seen: std.enums.EnumSet(failure_class.Class) = .empty;
    inline for (cases) |case| {
        seen.insert(failure_class.of(case[0]));
        var buffer: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var sink: Sink = .{ .out = &out };
        try workEnded(&sink, case[0], false);
        try std.testing.expectEqualStrings("\n" ++ case[1] ++ "\n", out.buffered());
    }
    try std.testing.expect(seen.eql(.full));
}

test "turn and agent ending marks use their table tones" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var sink: Sink = .{ .out = &out };
    try workEnded(&sink, "malformed_provider_output", true);
    try workEnded(&sink, "cancelled", true);
    try agentEnded(&sink, "9f8e7d", "malformed_provider_output", true);
    try agentEnded(&sink, "9f8e7d", "cancelled", true);
    try std.testing.expectEqualStrings("\n\x1b[91m×\x1b[39m Model reply unreadable\n" ++
        "\n\x1b[39m■\x1b[39m Stopped\n" ++
        "\n\x1b[91m×\x1b[39m Agent 9f8e7d · Model reply unreadable\n" ++
        "\n\x1b[39m■\x1b[39m Agent 9f8e7d stopped\n", out.buffered());
}

test "ending tails are quiet and joined in destination then key order" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var sink: Sink = .{ .out = &out };
    try workEnded(&sink, "provider_http_401", true);
    try std.testing.expectEqualStrings("\n\x1b[91m×\x1b[39m Sign-in expired\x1b[90m · Settings\x1b[39m\n", out.buffered());
    out.end = 0;
    try ending(&sink, .{ .mark = .failed, .words = "Cause", .place = "Place", .key = "Key" }, false);
    try std.testing.expectEqualStrings("\n× Cause · Place · Key\n", out.buffered());
    out.end = 0;
    try ending(&sink, .{ .mark = .failed, .words = "Cause", .key = "Key" }, false);
    try std.testing.expectEqualStrings("\n× Cause · Key\n", out.buffered());
}

/// Only the oldest waiting Message echoes in the feed when no work holds it.
/// This row is provisional: once applied, the Message belongs at its user row.
pub fn showsAtAdmission(position: u64, value: protocol.ActivityItem.Message, queued: protocol.Queued, held: bool) bool {
    return value.state == .queued and !held and position == queued.oldest_position;
}

test "a waiting Message shows at its Admission only when nothing holds it and nothing older waits" {
    const body: protocol.ActivityItem.Content = .{ .length = 1, .digest = @splat(0) };
    const waiting: protocol.ActivityItem.Message = .{ .admission = 12, .key = .{}, .turn = null, .state = .queued, .content = body, .admitted_at = 1, .sender = null };
    const alone: protocol.Queued = .{ .count = 1, .oldest_position = 30, .newest_admission = 12, .newest_position = 30 };
    // A pending Session can wait long before it takes the Message, as after
    // Ctrl-R recovery: the conversation shows it at once, as on an idle send.
    try std.testing.expect(showsAtAdmission(30, waiting, alone, false));
    // Work under way holds it: it waits in the queued row.
    try std.testing.expect(!showsAtAdmission(30, waiting, alone, true));
    // An older Message waits, which the queued row shows: this one waits
    // with it, so the conversation shows both in order once taken.
    try std.testing.expect(!showsAtAdmission(34, waiting, .{ .count = 2, .oldest_position = 30, .newest_admission = 12, .newest_position = 34 }, false));
    // Taken or excluded by the page's end.
    var taken = waiting;
    taken.state = .applied;
    try std.testing.expect(!showsAtAdmission(30, taken, .{}, false));
    taken.state = .excluded;
    try std.testing.expect(!showsAtAdmission(30, taken, alone, false));
}

/// Writes one Activity row, independent of traversal direction and prior reads.
/// Returns whether its output is provisional and must be replaced when the
/// current page's queue/work facts change. Settled rows use only Store content.
pub fn render(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, queued: protocol.Queued, held: bool, sink: anytype, colour: bool, compact_tools: *bool, home: []const u8, destination: Destination) !bool {
    switch (item.value) {
        .admission => |value| {
            if (!showsAtAdmission(item.position, value, queued, held)) return false;
            try message(requests, store, session, item, value, .none, sink, colour, compact_tools);
            return true;
        },
        .received => |value| try message(requests, store, session, item, value, .none, sink, colour, compact_tools),
        .user => |value| {
            if (value.sender != null) return false;
            try message(requests, store, session, item, value, .none, sink, colour, compact_tools);
        },
        .assistant => |assistant| {
            compact_tools.* = false;
            try sink.feed("\n");
            var answer: Answer(@TypeOf(sink)) = undefined;
            answer.init(sink, home, colour, destination);
            try content(requests, store, session, item, assistant.content, &answer);
            try answer.finish();
            try sink.feed("\n");
        },
        .tool_result => |result| {
            var scan: ToolHeaderScan = .{};
            try content(requests, store, session, item, result.content, &scan);
            try toolResultRow(result.presentation, scan.facts(result.presentation.code), .{ .position = item.position, .ordinal = item.ordinal, .content = result.content }, sink, colour, compact_tools);
        },
        // A call the provider ran is its line alone, grouped with
        // other tool rows like a result with no output.
        .hosted_call => |presentation| {
            try toolResult(presentation, .{}, sink, colour, compact_tools);
        },
        // Hidden call rows use admission-certified page metadata. Exact
        // proposal and permission inspection authenticate originals instead.
        .call => {},
        .turn_ended => |ended| {
            // A done Turn's answer is its final assistant row, never a second answer.
            if (ended.ending == .done) return false;
            compact_tools.* = false;
            // The report is deliberately not read: the shared cause owns the words.
            if (!std.mem.eql(u8, ended.session.slice(), session)) {
                try agentEnded(sink, ended.session.slice(), ended.code.slice(), colour);
            } else try workEnded(sink, ended.code.slice(), colour);
        },
        .stop => |stop| {
            compact_tools.* = false;
            try excludedAtStop(requests, store, session, item, sink, colour);
            // A selected Turn owns its terminal line, even across page boundaries.
            // Without a Turn, the stop itself is the completed outcome.
            if (stop.turn == null) try ending(sink, .{ .mark = .stopped, .words = "Stopped" }, colour);
        },
        .sent => |sent| try peerLine(sink, .outbound, sent.target, sent.admitted_at, compact_tools),
        .send_failed => |failed| {
            try sendFailed(sink, failed.target, compact_tools);
        },
        // The call's own line and the work status show the wait.
        .approval_requested, .session_changed, .compacted => {},
    }
    return false;
}

/// A stop owns the admission-order prefix it excluded, labelled oldest first.
/// At the instant before the stop, these were the queued suffix through its
/// cutoff. Earlier applied/excluded Messages end the search. Two bounded
/// passes keep oldest-first output without retaining pages or recursing.
fn excludedAtStop(requests: client.Requests, store: []const u8, session: []const u8, stop: protocol.ActivityItem, sink: anytype, colour: bool) !void {
    if (stop.value.stop.cutoff == 0) return;
    var cursor: protocol_reply.ActivityCursor = .{ .end = stop.position - 1, .direction = .backward, .kinds = .initOne(.admission) };
    var first: ?u64 = null;
    search: while (true) {
        const page = switch (try requests.activityPage(store, session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.facts.items[0..page.facts.count]) |item| {
            const value = item.value.admission;
            if (value.admission > stop.value.stop.cutoff) continue;
            if (value.state != .queued) break :search;
            first = item.position;
        }
        cursor = page.continuation() orelse break;
    }
    const lowest = first orelse return;
    sink.excluding(lowest);
    cursor = .{ .end = stop.position - 1, .position = lowest - 1, .kinds = .initOne(.admission) };
    while (true) {
        const page = switch (try requests.activityPage(store, session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.facts.items[0..page.facts.count]) |item| {
            var value = item.value.admission;
            if (value.state != .queued or value.admission > stop.value.stop.cutoff) continue;
            value.state = .excluded;
            var compact = false;
            try message(requests, store, session, item, value, .lasting(false), sink, colour, &compact);
        }
        cursor = page.continuation() orelse return;
    }
}

test "hosted calls draw as tool rows: successes pack together, a failure stands apart" {
    const Sink = struct {
        bytes: [512]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var sink: Sink = .{};
    var compact = false;
    for ([_]struct { []const u8, protocol.ToolPresentation.Code }{
        .{ "Search “zig 0.17”", .succeeded },
        .{ "Open ziglang.org/x", .succeeded },
        .{ "Find “Io” in ziglang.org/x", .failed },
        .{ "Search the web", .succeeded },
    }) |call| {
        var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
        try description.set(call[0]);
        try toolResult(.{ .description = description, .code = call[1], .publication_position = 1 }, .{}, &sink, false, &compact);
    }
    try std.testing.expectEqualStrings(
        "\n✓ Search “zig 0.17”\n✓ Open ziglang.org/x\n\n× Find “Io” in ziglang.org/x\n\n✓ Search the web\n",
        sink.bytes[0..sink.length],
    );
}

test "MCP approval uses the saved description and renders exact arguments with Allow once and Deny" {
    const Screen = @import("SessionScreen.zig");
    const Consent = @import("session_consent.zig");
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(std.testing.io, "arguments", .{ .read = true });
    defer scratch.close(std.testing.io);
    const action = try tmp.dir.createFile(std.testing.io, "action", .{ .read = true });
    defer action.close(std.testing.io);
    const Sink = struct {
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(std.testing.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var tool: ActionTool = .{ .name = .{}, .description = .{}, .server = .{} };
    try tool.name.set("fetch_page");
    try tool.server.?.set("docs");
    const Case = struct { arguments: []const u8, description: []const u8 };
    for ([_]Case{
        .{ .arguments = "{}", .description = "fetch_page" },
        .{ .arguments = " { \"q\" : [1, null] } ", .description = "Fetch saved page" },
        .{ .arguments = "{\"rui_call_description\":\"Fetch \\u00e9\\npage\",\"url\":\"https://example.test\"}", .description = "Fetch saved é page" },
        .{ .arguments = "{\"rui_call_description\":\"" ++ @as([200]u8, @splat('a')) ++ "\"}", .description = &@as([200]u8, @splat('a')) },
        .{ .arguments = "{\"rui_call_description\":\"" ++ @as([201]u8, @splat('a')) ++ "\"}", .description = "fetch_page" },
    }) |case| {
        try tool.description.set(case.description);
        try scratch.setLength(std.testing.io, 0);
        try scratch.writePositionalAll(std.testing.io, case.arguments, 0);
        try action.setLength(std.testing.io, 0);
        var sink: Sink = .{ .file = action };
        const summary = try renderPermissionArguments(std.testing.io, scratch, &sink, false, &tool);
        try std.testing.expectEqualStrings(case.description, summary.description.slice());
        var rendered: [2048]u8 = undefined;
        const count = try action.readPositionalAll(std.testing.io, &rendered, 0);
        var heading: [256]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, rendered[0..count], try std.fmt.bufPrint(&heading, "\n? {s}\n", .{case.description})));
        try std.testing.expect(std.mem.indexOf(u8, rendered[0..count], "\n  Tool: fetch_page\n  Server: docs\n  Arguments:\n  │ ") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered[0..count], case.arguments) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered[0..count], "\n  $ ") == null);
        screen.releaseAction();
        screen.consent = null;
        try screen.adopt(std.testing.io, action, 7, true);
        try std.testing.expect(screen.consent.?.presentation == .complete);
        var pending = screen.consent.?;
        var projection = Consent.project(pending, .{ .action_page = true, .read = true }, false);
        try std.testing.expect(Consent.offered(pending, projection.approval).? == .allow_once);
        pending.highlight = .deny;
        projection = Consent.project(pending, .{ .action_page = true, .read = true }, false);
        try std.testing.expect(Consent.offered(pending, projection.approval).? == .deny);
    }
}

test "only a Bash Action names a command for its row, whatever another tool's arguments look like" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(std.testing.io, "arguments", .{ .read = true });
    defer scratch.close(std.testing.io);
    var bash: ActionTool = .{ .name = .{}, .description = .{} };
    try bash.name.set("bash");
    var mcp: ActionTool = .{ .name = .{}, .description = .{}, .server = .{} };
    try mcp.name.set("run");
    try mcp.server.?.set("shell");
    var other: ActionTool = .{ .name = .{}, .description = .{} };
    try other.name.set("web_search");
    // Arguments every one of the three would accept as Bash's.
    const arguments = "{\"cmd\":\"rm -rf build\\nzig build\",\"description\":\"Clean and build\"}";
    try scratch.writePositionalAll(std.testing.io, arguments, 0);
    var buffer: [8]u8 = undefined;
    // Bash: the command's leading bytes, as many as the buffer holds.
    try std.testing.expectEqualStrings("rm -rf b", (try bashCommand(std.testing.io, scratch, &bash, &buffer)).?);
    var wide: [64]u8 = undefined;
    try std.testing.expectEqualStrings("rm -rf build\nzig build", (try bashCommand(std.testing.io, scratch, &bash, &wide)).?);
    // An MCP call or another built-in tool names none.
    try std.testing.expectEqual(null, try bashCommand(std.testing.io, scratch, &mcp, &wide));
    try std.testing.expectEqual(null, try bashCommand(std.testing.io, scratch, &other, &wide));
    // Bash arguments that are not a command name none either.
    try scratch.setLength(std.testing.io, 0);
    try scratch.writePositionalAll(std.testing.io, "{\"description\":\"No command\"}", 0);
    try std.testing.expectEqual(null, try bashCommand(std.testing.io, scratch, &bash, &wide));
}

test "MCP approval marks argument lines escapes controls and refuses a viewport preview" {
    const Screen = @import("SessionScreen.zig");
    const Consent = @import("session_consent.zig");
    const Viewport = @import("ConversationViewport.zig");
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Screen);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(std.testing.io, "arguments", .{ .read = true });
    defer scratch.close(std.testing.io);
    const action = try tmp.dir.createFile(std.testing.io, "action", .{ .read = true });
    defer action.close(std.testing.io);
    const Sink = struct {
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(std.testing.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var tool: ActionTool = .{ .name = .{}, .description = .{}, .server = .{} };
    try tool.name.set("fetch_page");
    try tool.server.?.set("docs");
    try tool.description.set("Saved \x1b[2J");
    const prefix = "{\n\"rui_call_description\":\"Fetch \\u001b[2J\",\n\"body\":\"";
    try scratch.writePositionalAll(std.testing.io, prefix, 0);
    // Literal bidi content is valid JSON, but cannot direct the terminal.
    try scratch.writePositionalAll(std.testing.io, "‮", prefix.len);
    var at: u64 = prefix.len + "‮".len;
    const fill: [4096]u8 = @splat('a');
    while (at < Viewport.capacity + 4096) : (at += fill.len) try scratch.writePositionalAll(std.testing.io, &fill, at);
    try scratch.writePositionalAll(std.testing.io, "\"\n}", at);
    var sink: Sink = .{ .file = action };
    _ = try renderPermissionArguments(std.testing.io, scratch, &sink, false, &tool);
    var beginning: [512]u8 = undefined;
    const count = try action.readPositionalAll(std.testing.io, &beginning, 0);
    const shown = beginning[0..count];
    try std.testing.expect(std.mem.startsWith(u8, shown, "\n? Saved \\x1b[2J\n"));
    try std.testing.expect(std.mem.indexOf(u8, shown, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "‮") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\n  │ \"rui_call_description\"") != null);
    try std.testing.expect(sink.offset > Viewport.capacity);
    try screen.adopt(std.testing.io, action, 9, true);
    try std.testing.expect(screen.consent.?.presentation == .preview);
    const projection = Consent.project(screen.consent, .{ .action_page = true, .read = true }, false);
    try std.testing.expect(projection.approval == .preview);
    try std.testing.expect(Consent.offered(screen.consent, projection.approval) == null);
}
