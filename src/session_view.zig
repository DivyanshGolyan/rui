const std = @import("std");
const tool_fold = @import("tool_fold.zig");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const content_value = @import("content_value.zig");
const value_reads = @import("value_reads.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");
pub const Destination = Renderer.Destination;
const tools = @import("tools.zig");
const failure_class = @import("failure_class.zig");
const marks = @import("marks.zig");
const work_line = @import("work_line.zig");
const unicode = @import("terminal_unicode");

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

pub const Mark = struct {
    pub const body = "\x1b[2m";
    pub const summary = "\x1b[2;8m";
    pub const sidenote = "\x1b[8m";
    pub const reset = "\x1b[0m";
};

const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(time: *const c_long, result: *Tm) ?*Tm;

pub fn clock(second: u64, buffer: *[5]u8) ?[]const u8 {
    const time = std.math.cast(c_long, second) orelse return null;
    var local: Tm = undefined;
    if (localtime_r(&time, &local) == null) return null;
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ @as(u8, @intCast(local.hour)), @as(u8, @intCast(local.min)) }) catch unreachable;
}

pub fn userPrefix(sink: anytype, colour: bool, admitted_at: u64) !void {
    try sink.feed(Style.quiet.code(colour));
    try sink.feed("›");
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var buffer: [5]u8 = undefined;
    const time = clock(admitted_at, &buffer) orelse return;
    try sink.feed(Mark.sidenote);
    try sink.feed(time);
    try sink.feed(Mark.reset);
}

test "peer Messages render as one dim line each, named, with time in the margin and never their text" {
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
    try peerLine(&sink, .inbound, peer, 1_800_000_000);
    try std.testing.expectEqualStrings(S ++ "← Received message from " ++ comptime L("9f8e7d", "9f8e7d") ++ N ++ "08:00" ++ R ++ "\n", sink.bytes[0..sink.length]);
    sink = .{};
    try peerLine(&sink, .outbound, peer, std.math.maxInt(u64));
    try std.testing.expectEqualStrings(S ++ "→ Messaged " ++ comptime L("9f8e7d", "9f8e7d") ++ R ++ "\n", sink.bytes[0..sink.length]);
    var failed: Sink = .{};
    try sendFailed(&failed, peer);
    try std.testing.expectEqualStrings(S ++ "× Messaged " ++ comptime L("9f8e7d", "9f8e7d") ++ R ++ "\n", failed.bytes[0..failed.length]);
    var named = peer;
    try named.label.set("Review\x1b[2m the WAL");
    var group: Sink = .{};
    try peerLine(&group, .outbound, named, 1_800_000_000);
    try peerLine(&group, .inbound, named, 1_800_000_000);
    try std.testing.expectEqualStrings(S ++ "→ Messaged " ++ comptime L("9f8e7d", "Review\\x1b[2m the WAL") ++ N ++ "08:00" ++ R ++ "\n" ++
        S ++ "← Received message from " ++ L("9f8e7d", "Review\\x1b[2m the WAL") ++ N ++ "08:00" ++ R ++ "\n", group.bytes[0..group.length]);
}

fn peerLink(comptime id: []const u8, comptime name: []const u8) []const u8 {
    return Text.link_open ++ Text.session_link ++ id ++ Text.link_end ++ "\x1b[4m" ++ name ++ Text.link_close ++ Mark.reset ++ Mark.summary;
}

test "failed peer Messages distinguish absent targets without changing named output" {
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
        var sink: Sink = .{};
        try sendFailed(&sink, case.target);
        var expected: [1024]u8 = undefined;
        const line = try std.fmt.bufPrint(&expected, Mark.summary ++ "{s}" ++ Mark.reset ++ "\n", .{case.line});
        try std.testing.expectEqualStrings(line, sink.bytes[0..sink.length]);
    }
}

pub fn peerLine(sink: anytype, direction: enum { inbound, outbound }, peer: protocol.NamedPeer, admitted_at: u64) !void {
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

pub fn sendFailed(sink: anytype, target: ?protocol.NamedPeer) !void {
    try sink.feed(Mark.summary);
    if (target) |peer| {
        try sink.feed("× Messaged ");
        try peerName(sink, peer);
    } else try sink.feed("× Message not delivered");
    try sink.feed(Mark.reset ++ "\n");
}

fn peerName(sink: anytype, peer: protocol.NamedPeer) !void {
    const id = peer.session.slice();
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

pub const Collapsed = struct {
    source: enum { activity, conversation },
    position: u64,
    ordinal: u64,
    content: content_value.Value,
    row: bool,

    pub fn at(self: Collapsed) value_reads.At {
        return .{ .source = switch (self.source) {
            .activity => .activity,
            .conversation => .conversation,
        }, .position = self.position, .ordinal = self.ordinal };
    }
};

pub fn writeCollapsed(sink: anytype, value: Collapsed, bytes: []const u8) !void {
    if (comptime std.meta.hasMethod(@TypeOf(sink), "collapsedSummary")) {
        try sink.collapsedSummary(value, bytes);
    } else try sink.feed(bytes);
}

pub const collapse_bytes = 1024;
const collapse_nonblank = 4;
const collapse_lines = 12;
const preview_lines = 2;
const preview_bytes = 200;

fn blank(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

pub fn UserBody(comptime Sink: type) type {
    return struct {
        const Self = @This();
        out: Indented(Sink),
        escaped: Escaped(*Indented(Sink)),
        length: u64,
        whole: bool,
        received: u64 = 0,
        small: [collapse_bytes]u8 = undefined,
        line: [256]u8 = undefined,
        line_bytes: u64 = 0,
        line_blank: bool = true,
        shown: usize = 0,
        nonblank: u64 = 0,

        pub fn init(self: *Self, sink: Sink, length: u64, whole: bool) !void {
            self.* = .{ .out = .{ .sink = sink }, .escaped = undefined, .length = length, .whole = whole };
            self.escaped = .{ .sink = &self.out, .text = .{ .mode = .multiline }, .authored = true };
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

        pub fn finish(self: *Self) anyerror!bool {
            return self.finishTarget(null);
        }

        pub fn finishMessage(self: *Self, target: Collapsed) anyerror!bool {
            return self.finishTarget(target);
        }

        fn finishTarget(self: *Self, target: ?Collapsed) anyerror!bool {
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
                if (self.shown != 0) try self.out.body("\n");
                var count: [96]u8 = undefined;
                const hidden = self.nonblank - self.shown;
                var number: [32]u8 = undefined;
                const summary = try std.fmt.bufPrint(&count, Mark.summary ++ "┄{s}" ++ Mark.reset, .{switch (hidden) {
                    0 => "",
                    1 => " 1 more line",
                    else => try std.fmt.bufPrint(&number, " {d} more lines", .{hidden}),
                }});
                if (target) |value| {
                    try writeCollapsed(&self.out, value, summary);
                    try self.out.feed(Mark.reset);
                } else try self.out.feed(summary);
                collapsed = true;
            }
            if (!collapsed) try self.out.feed(Mark.reset);
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
            if (self.shown != 0) try self.out.body("\n");
            self.shown += 1;
            const kept = self.line[0..@intCast(@min(self.line_bytes, self.line.len))];
            const cut = if (self.line_bytes <= preview_bytes) kept.len else graphemeCut(kept, preview_bytes);
            try self.escaped.feed(kept[0..cut]);
            try self.escaped.finish();
            if (cut != kept.len) try self.out.feed(Mark.reset ++ Mark.summary ++ "…" ++ Mark.reset ++ Mark.body);
        }
    };
}

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
        .{ .input = a ++ "\n" ++ a ++ "\n" ++ a ++ "\n" ++ a ++ "a", .output = B ++ a ++ "\n  " ++ a ++ "\n  " ++ a ++ "\n  " ++ a ++ "a" ++ R },
        .{ .input = "1\n2\n3\n4\n5", .output = B ++ "1\n  2\n  " ++ S ++ "┄ 3 more lines" ++ R },
        .{ .input = "a" ++ six ++ "b" ++ five ++ "c", .output = B ++ "a" ++ six ++ "  b" ++ five ++ "  c" ++ R },
        .{ .input = "a" ++ six ++ "b" ++ six ++ "c", .output = B ++ "a\n  b\n  " ++ S ++ "┄ 1 more line" ++ R },
        .{ .input = twenty ++ "a\n \t\r\n", .output = B ++ twenty ++ "  a" ++ R },
        .{ .input = "a\r\n", .output = B ++ "a\\x0d" ++ R },
        .{ .input = x[0..1025], .output = B ++ x[0..200] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        .{ .input = "\x01" ++ a[0..197] ++ "😀" ++ x[0..900], .output = B ++ "\\x01" ++ a[0..197] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        .{ .input = a[0..199] ++ "e\u{301}" ++ x[0..900], .output = B ++ a[0..199] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
        .{ .input = a[0..200] ++ "\n" ++ x[0..900], .output = B ++ a[0..200] ++ "\n  " ++ x[0..200] ++ cut ++ "\n  " ++ S ++ "┄" ++ R },
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
        .background => .{ .mark = .finished, .suffix = " · background" },
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

test "list rows share chat heading marks except unmarked finished Sessions" {
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
        _ = try overview.step(&state, .{ .host = .{ .instance = @splat(7), .started_at = 1, .slots = 1, .slots_in_use = 0 } });
        _ = try overview.step(&state, .{ .tick = 100_000 });
        _ = try overview.step(&state, .{ .list = .{ .page = .{
            .rows = &.{.{ .reference = "k7m2qx".*, .read_version = .{ .instance = @splat(7), .generation = 1 }, .workspace = "/work", .provider = .codex, .label = "Work", .state = case.state, .first = .{ .position = 1, .admission = 1, .sender = null, .content = .{ .text = .{ .length = 4, .digest = @splat(1) } } } }},
            .answer = .{ .delta = .full, .since = .{ .instance = @splat(7), .generation = 1 } },
        } } });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        for ([_]bool{ true, false }) |unicode_script| {
            const caps: overview.Caps = .{ .unicode = unicode_script };
            try std.testing.expect(!overview.Lines.spins(&state, 0, caps));
            const row = (try overview.Lines.at(arena.allocator(), &state, 0, 80, caps, 4)).?.segments;
            try std.testing.expectEqualStrings(" ", row[0].text);
            const list_mark = if (case.state == .finished) marks.marks.get(.none) else shared;
            try std.testing.expectEqualStrings(if (unicode_script) list_mark.unicode else list_mark.ascii, row[1].text);
            try std.testing.expectEqual(case.colour, row[1].style.colour);
        }
        if (case.tool) |code| {
            var heading: Sink = .{};
            try toolHeading(.{ .description = null, .code = code, .publication_position = null }, &heading, false);
            const end = std.mem.indexOfScalar(u8, heading.bytes[0..heading.length], ' ').?;
            try std.testing.expectEqualStrings(shared.unicode, heading.bytes[0..end]);
        }
    }
    var states: std.enums.EnumSet(marks.Mark) = .full;
    states.remove(.newer);
    states.remove(.none);
    try std.testing.expect(seen.eql(states));
}

pub fn toolHeading(presentation: protocol.ToolPresentation, sink: anytype, colour: bool) !void {
    return toolHeadingWith(presentation, sink, colour, "", false);
}

fn toolHeadingWith(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, exit: []const u8, foldable: bool) !void {
    const state = toolState(presentation.code);
    if (foldable) try sink.feed(tool_fold.heading_marker);
    try sink.feed(state.style.code(colour));
    try sink.feed(state.glyph);
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .label } };
    try escaped.feed(if (presentation.description) |label| label.slice() else "Tool call");
    try escaped.finish();
    try indented.feed(state.suffix);
    try indented.finish();
    if (presentation.code == .failed and exit.len != 0) {
        try sink.feed(tool_fold.exit_open);
        try sink.feed("exit ");
        try sink.feed(exit);
        try sink.feed(Text.link_close);
    }
    try sink.feed("\n");
}

pub const Live = struct {
    pub const Entry = protocol.CallActivity.Entry;
    entries: [3]Entry = undefined,
    count: usize = 0,
    total: u64 = 0,

    pub fn init(facts: protocol.CallActivity) Live {
        return .{ .entries = facts.entries, .count = facts.count, .total = facts.total };
    }

    pub const line_bytes = Text.max_bytes_per_byte * protocol.max_tool_description_bytes + 96;
    comptime {
        std.debug.assert(marks.marks.get(.active).unicode.len + " ".len + work_line.max_clock_bytes <= line_bytes - Text.max_bytes_per_byte * protocol.max_tool_description_bytes);
    }

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

pub fn Indented(comptime Sink: type) type {
    return struct {
        sink: Sink,
        prefix: []const u8 = "  ",
        marks_empty: bool = false,
        line_start: bool = false,
        sgr: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            try self.write(bytes, false);
        }
        pub fn body(self: *@This(), bytes: []const u8) anyerror!void {
            try self.write(bytes, true);
        }
        fn emit(self: *@This(), bytes: []const u8, authored: bool) !void {
            const sink = if (@typeInfo(Sink) == .pointer) self.sink else &self.sink;
            if (authored) try Text.writeBody(sink, bytes) else try sink.feed(bytes);
        }
        fn write(self: *@This(), bytes: []const u8, authored: bool) anyerror!void {
            var storage: [4096]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (out.end == storage.len) {
                    try self.emit(out.buffered(), authored);
                    out.end = 0;
                }
                if (self.line_start and (byte != '\n' or self.marks_empty)) {
                    try self.emit(out.buffered(), authored);
                    out.end = 0;
                    try self.sink.feed(if (byte == '\n') std.mem.trimEnd(u8, self.prefix, " ") else self.prefix);
                    if (byte != '\n') self.line_start = false;
                }
                if (self.sgr or byte == 0x1b) {
                    self.sgr = byte != 'm';
                } else if (byte == '\n') self.line_start = true;
                try out.writeByte(byte);
            }
            if (out.end != 0) try self.emit(out.buffered(), authored);
        }
        pub fn collapsedSummary(self: *@This(), value: Collapsed, bytes: []const u8) !void {
            if (self.line_start) try self.sink.feed(self.prefix);
            try writeCollapsed(self.sink, value, bytes);
            self.line_start = false;
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

pub const content_mark = "│ ";

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

pub fn actionTool(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File) !?ActionTool {
    const observed = try current(requests, store, session, scratch);
    return actionToolFromCapture(&observed, requests.io, scratch, action);
}

pub fn permission(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File, sink: anytype, colour: bool, unicode_script: bool) !bool {
    const tool = try actionTool(requests, store, session, action, scratch) orelse return false;
    try permissionForTool(requests, store, session, action, scratch, sink, colour, unicode_script, &tool);
    return true;
}

pub fn permissionForTool(requests: client.Requests, store: []const u8, session: []const u8, action: u64, scratch: std.Io.File, sink: anytype, colour: bool, unicode_script: bool, tool: *const ActionTool) !void {
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
    return renderPermissionArguments(requests.io, scratch, sink, colour, unicode_script, tool);
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

pub fn renderPermissionArguments(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool, unicode_script: bool, tool: *const ActionTool) !void {
    return switch (try tool.runner()) {
        .bash => request(io, scratch, sink, colour, unicode_script),
        .mcp, .read_image => toolRequest(io, scratch, sink, colour, unicode_script, tool),
        .core, .provider => error.InvalidObservation,
    };
}

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

fn permissionMark(sink: anytype, colour: bool, unicode_script: bool) !void {
    const mark = marks.marks.get(.needs_you);
    try sink.feed(Style.fromTone(mark.tone).code(colour));
    try sink.feed(if (unicode_script) mark.unicode else mark.ascii);
    try sink.feed(Style.normal.code(colour));
}

fn toolRequest(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool, unicode_script: bool, tool: *const ActionTool) !void {
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(io, &buffer);
    try sink.feed("\n");
    try permissionMark(sink, colour, unicode_script);
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (tool.description.len != 0) {
        try indented.feed(" ");
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .label } };
        try label.feed(tool.description.slice());
        try label.finish();
    }
    try indented.feed("\nTool: ");
    try indented.feed(tool.name.slice());
    if (tool.server) |server| {
        try indented.feed("\nServer: ");
        try indented.feed(server.slice());
    }
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
}

fn request(io: std.Io, scratch: std.Io.File, sink: anytype, colour: bool, unicode_script: bool) !void {
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(io, &buffer);
    var source: ArgumentSource = .{ .reader = &reader.interface };
    const arguments = try tools.inspectBashArguments(&source) orelse return error.InvalidBashArguments;
    try reader.seekTo(0);
    try sink.feed("\n");
    try permissionMark(sink, colour, unicode_script);
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (arguments.description.len != 0) {
        try indented.feed(" ");
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .label } };
        try label.feed(arguments.description.slice());
        try label.finish();
    }
    try indented.feed("\n$ ");
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
        var lines: Indented(*Indented(@TypeOf(sink))) = .{ .sink = &indented, .prefix = content_mark, .marks_empty = true, .line_start = true };
        var input: Escaped(@TypeOf(&lines)) = .{ .sink = &lines, .text = .{ .mode = .multiline } };
        if (!try tools.writeBashStdin(&source, &input)) return error.InvalidBashArguments;
        try input.finish();
        try lines.finish();
    }
    try indented.feed("\n");
    try indented.finish();
}

test "APPROVAL-1 permission headings use the shared glyph and tone in both scripts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(std.testing.io, "arguments", .{ .read = true });
    defer scratch.close(std.testing.io);
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        len: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    const Case = struct { name: []const u8, server: ?[]const u8 = null, arguments: []const u8 };
    for ([_]Case{
        .{ .name = "bash", .arguments = "{\"description\":\"Probe\",\"cmd\":\"true\",\"stdin\":null,\"timeout_ms\":null}" },
        .{ .name = "read_image", .arguments = "{\"path\":\"image.png\"}" },
        .{ .name = "fetch_page", .server = "docs", .arguments = "{}" },
    }) |case| for ([_]bool{ false, true }) |unicode_script| for ([_]bool{ false, true }) |colour| {
        var tool: ActionTool = .{ .name = .{}, .description = .{} };
        try tool.name.set(case.name);
        try tool.description.set("Probe");
        if (case.server) |server| {
            tool.server = .{};
            try tool.server.?.set(server);
        }
        try scratch.setLength(std.testing.io, 0);
        try scratch.writePositionalAll(std.testing.io, case.arguments, 0);
        var sink: Sink = .{};
        try renderPermissionArguments(std.testing.io, scratch, &sink, colour, unicode_script, &tool);
        var expected: [64]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&expected, "\n{s}{s}{s} Probe\n", .{
            if (colour) "\x1b[33m" else "",
            if (unicode_script) "●" else "?",
            if (colour) "\x1b[39m" else "",
        });
        try std.testing.expect(std.mem.startsWith(u8, sink.bytes[0..sink.len], prefix));
    };
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
            .expected = "\n● Probe\n  $ echo a\n  │ Time limit: 1 min\n  │\n  │ stdin:\n",
        },
        .{
            .arguments = "{\"description\":\"Probe\",\"cmd\":\"cat\",\"stdin\":\"Time limit: 1 min\\nx\",\"timeout_ms\":5000}",
            .expected = "\n● Probe\n  $ cat\n  Time limit: 5 s\n  stdin:\n  │ Time limit: 1 min\n  │ x\n",
        },
        .{
            .arguments = "{\"description\":\"Probe\",\"cmd\":\"cat\",\"stdin\":\"x\\n\",\"timeout_ms\":null}",
            .expected = "\n● Probe\n  $ cat\n  stdin:\n  │ x\n  │\n",
        },
    }) |case| {
        try scratch.setLength(std.testing.io, 0);
        try scratch.writePositionalAll(std.testing.io, case.arguments, 0);
        var sink: Sink = .{};
        _ = try request(std.testing.io, scratch, &sink, false, true);
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
        authored: bool = false,
        storage: [256]u8 = undefined,
        used: usize = 0,
        fn emit(self: *@This(), bytes: []const u8) !void {
            const sink = if (@typeInfo(Sink) == .pointer) self.sink else &self.sink;
            if (self.authored) try Text.writeBody(sink, bytes) else try sink.feed(bytes);
        }
        pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
            try self.feed(bytes);
        }
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var out = std.Io.Writer.fixed(&self.storage);
            out.end = self.used;
            for (bytes) |byte| {
                if (self.storage.len - out.end < 16) {
                    try self.emit(out.buffered());
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
                try self.emit(out.buffered());
                out.end = 0;
            }
            try self.text.finish(&out);
            if (out.end != 0) try self.emit(out.buffered());
            self.used = 0;
        }
    };
}

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
            const sink = if (@typeInfo(Sink) == .pointer) self.sink else &self.sink;
            Text.writeBody(sink, bytes) catch |err| {
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
        if (!colour) try std.testing.expectEqualStrings(if (destination == .viewport)
            "name\n" ++ Text.full_width_on ++ "  A\n  B\n" ++ Text.full_width_off ++ Text.full_width_on ++ "  code\n  \n" ++ Text.full_width_off
        else
            "name\n  A\n  B\n  code\n  \n", output.written());
        if (destination == .terminal) {
            try std.testing.expect(std.mem.indexOf(u8, output.written(), Text.full_width_on) == null);
            try std.testing.expect(std.mem.indexOf(u8, output.written(), Text.full_width_off) == null);
        } else {
            const Viewport = @import("ConversationViewport.zig");
            var view: Viewport.Sized(512, true) = .{};
            try view.append(output.written());
            try view.prepare();
            try std.testing.expectEqualStrings(if (colour) "name\n  A\n  B\ncode\n\n" else "name\n  A\n  B\n  code\n  \n", view.text());
        }
    };
}

fn print(sink: anytype, comptime format: []const u8, args: anytype) !void {
    var storage: [256]u8 = undefined;
    try sink.feed(try std.fmt.bufPrint(&storage, format, args));
}

pub const Labels = enum {
    none,
    excluded,
    excluded_and_queued,

    pub fn lasting(held: bool) Labels {
        return if (held) .excluded_and_queued else .excluded;
    }
};

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
    const starting: protocol.WorkState = .{ .pending = .{ .since = 1 } };
    try std.testing.expect(messageLabel(.queued, .lasting(starting.holdsQueue())) == null);
    try std.testing.expectEqualStrings("Queued", messageLabel(.queued, .lasting(working.holdsQueue())).?);
    try std.testing.expectEqualStrings("◌ not sent", messageLabel(.excluded, .lasting(false)).?);
    try std.testing.expect(messageLabel(.applied, .excluded_and_queued) == null);
    inline for (.{ .queued, .excluded, .applied }) |state| try std.testing.expect(messageLabel(state, .none) == null);
}

fn inputPrefix(sink: anytype, colour: bool, admitted_at: u64, action: ?u64) !void {
    if (action) |id| {
        try print(sink, "{s}Background Action {d}{s}\n", .{ Style.quiet.code(colour), id, Style.normal.code(colour) });
    } else try userPrefix(sink, colour, admitted_at);
}

pub fn message(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File, item: protocol.ActivityItem, value: protocol.ActivityItem.Message, labels: Labels, sink: anytype, colour: bool) !void {
    if (messageLabel(value.state, labels)) |text| {
        try print(sink, "{s}{s}{s}\n", .{ Style.quiet.code(colour), text, Style.normal.code(colour) });
    }
    if (value.sender) |sender| return peerLine(sink, .inbound, sender, value.admitted_at);
    const personal = value.source_action == null;
    if (comptime std.meta.hasMethod(@TypeOf(sink), "userMessage")) try sink.userMessage(personal);
    const block: Collapsed = .{ .source = .activity, .position = item.position, .ordinal = item.ordinal, .content = value.content, .row = item.value == .user };
    try inputPrefix(sink, colour, value.admitted_at, value.source_action);
    const display = try open(requests, store, session, scratch, item, value.content);
    var body: UserBody(@TypeOf(sink)) = undefined;
    try body.init(sink, display.length, false);
    try stream(requests, &display, &body);
    if (try body.finishMessage(block)) {
        try sink.feed("\n");
    } else try Text.writeBody(sink, "\n");
    if (comptime std.meta.hasMethod(@TypeOf(sink), "userMessage")) try sink.userMessage(false);
}

/// Opens the display of the value an activity entry shows. A parts value reads its
/// certified list into `scratch`, which the returned Display borrows.
fn open(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File, item: protocol.ActivityItem, value: content_value.Value) !value_reads.Display {
    return switch (try value_reads.Display.open(requests, store, session, .{ .source = .activity, .position = item.position, .ordinal = item.ordinal }, value, scratch)) {
        .display => |display| display,
        .failure => |failure| requests.failRead(failure),
    };
}

fn stream(requests: client.Requests, display: *const value_reads.Display, target: anytype) !void {
    if (try display.stream(requests, target)) |failure| return requests.failRead(failure);
}

fn content(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File, item: protocol.ActivityItem, value: content_value.Value, target: anytype) !void {
    const display = try open(requests, store, session, scratch, item, value);
    try stream(requests, &display, target);
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

pub fn toolResult(presentation: protocol.ToolPresentation, facts: ToolHeaderFacts, sink: anytype, colour: bool) !void {
    return toolResultRow(presentation, facts, false, sink, colour);
}

fn toolResultRow(presentation: protocol.ToolPresentation, facts: ToolHeaderFacts, foldable: bool, sink: anytype, colour: bool) !void {
    var buffer: [3]u8 = undefined;
    const exit = if (facts.exit) |value| try std.fmt.bufPrint(&buffer, "{d}", .{value}) else "";
    try toolHeadingWith(presentation, sink, colour, exit, foldable);
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
    const bodies = .{
        "Bash failed. Exit code: 7.\nProcess-group signaling reported a failure.\n" ++
            "Capture may be incomplete.\nstdout tail:\nhidden\nstderr tail:\n\x1b[2Jhidden\n" ++
            "[earlier output omitted]\nFull stdout: /secret\nOpen the tool row for saved output.\n",
        "Bash failed. Exit code: 7.\nCapture may be incomplete.\nstdout:\nhead\n[123 bytes left out]\ntail\nstderr:\n\x1b[2Jhidden\nFull stdout: /secret\nFull stderr: /secret-err\n",
    };
    const cases = .{
        .{ protocol.ToolPresentation.Code.unresolved, "◝ Tool call" },
        .{ protocol.ToolPresentation.Code.pending_permission, "● Tool call" },
        .{ protocol.ToolPresentation.Code.background, "✓ Tool call · background" },
        .{ protocol.ToolPresentation.Code.succeeded, "✓ Tool call" },
        .{ protocol.ToolPresentation.Code.failed, "× Tool call" ++ tool_fold.exit_open ++ "exit 7" ++ Text.link_close },
        .{ protocol.ToolPresentation.Code.timed_out, "× Tool call · timed out" },
        .{ protocol.ToolPresentation.Code.indeterminate, "× Tool call · may have run" },
        .{ protocol.ToolPresentation.Code.storage_failed, "× Tool call · output lost" },
        .{ protocol.ToolPresentation.Code.spawn_failed, "× Tool call · could not start" },
        .{ protocol.ToolPresentation.Code.cancelled, "▪ Tool call" },
        .{ protocol.ToolPresentation.Code.infrastructure_shutdown, "× Tool call · may have run" },
        .{ protocol.ToolPresentation.Code.denied, "▪ Tool call · denied" },
        .{ protocol.ToolPresentation.Code.unknown_tool, "× Tool call · rejected" },
        .{ protocol.ToolPresentation.Code.invalid_arguments, "× Tool call · rejected" },
    };
    try std.testing.expectEqual(std.enums.values(protocol.ToolPresentation.Code).len, cases.len);
    inline for (bodies) |body| {
        inline for (cases) |case| {
            for (0..body.len + 1) |split| {
                for ([_]bool{ false, true }) |colour| {
                    var scan: ToolHeaderScan = .{};
                    try scan.feed(body[0..split]);
                    try scan.feed(body[split..]);
                    var sink: Sink = .{};
                    const presentation: protocol.ToolPresentation = .{ .description = null, .code = case[0], .publication_position = null };
                    try toolResult(presentation, scan.facts(case[0]), &sink, colour);
                    var expected: Sink = .{};
                    const glyph_end = std.mem.indexOfScalar(u8, case[1], ' ').?;
                    if (colour) try expected.feed(switch (case[0]) {
                        .unresolved => "\x1b[94m",
                        .pending_permission => "\x1b[33m",
                        .succeeded, .background => "\x1b[90m",
                        .denied, .cancelled => "\x1b[39m",
                        else => "\x1b[91m",
                    });
                    try expected.feed(case[1][0..glyph_end]);
                    if (colour) try expected.feed("\x1b[39m");
                    try expected.feed(case[1][glyph_end..]);
                    try expected.feed("\n");
                    try std.testing.expectEqualStrings(expected.bytes[0..expected.length], sink.bytes[0..sink.length]);
                    try std.testing.expectEqual(case[0] == .succeeded, tight(.{ .tool_result = .{ .content = .{ .text = .{ .length = 0, .digest = @splat(0) } }, .presentation = presentation } }));
                    try std.testing.expectEqual(case[0] == .succeeded, tight(.{ .hosted_call = presentation }));
                }
            }
        }
    }
}

test "failed tool heading carries an explicit exit field" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    for ([_]?[]const u8{ null, "Fail with exit 127" }) |title| {
        var presentation: protocol.ToolPresentation = .{ .description = null, .code = .failed, .publication_position = null };
        if (title) |words| {
            presentation.description = .{};
            try presentation.description.?.set(words);
        }
        for ([_][]const u8{ "1", "7", "127" }) |exit| {
            var buffer: [128]u8 = undefined;
            var out = std.Io.Writer.fixed(&buffer);
            var sink: Sink = .{ .out = &out };
            try toolHeadingWith(presentation, &sink, false, exit, false);
            var expected: [128]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "× {s}" ++ tool_fold.exit_open ++ "exit {s}" ++ Text.link_close ++ "\n", .{ title orelse "Tool call", exit }), out.buffered());
        }
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

fn workEnded(sink: anytype, code: []const u8, provider: ?protocol.Provider, colour: bool) !void {
    const cause = marks.cause(code, provider);
    try ending(sink, .{ .mark = if (failure_class.of(code) == .interrupted) .stopped else .failed, .words = cause.words, .place = cause.place }, colour);
}

fn agentEnded(sink: anytype, agent: []const u8, code: []const u8, colour: bool) !void {
    const stopped = failure_class.of(code) == .interrupted;
    try ending(sink, .{ .mark = if (stopped) .stopped else .failed, .words = if (stopped) "stopped" else marks.cause(code, null).words, .agent = agent }, colour);
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
    try std.testing.expectEqualStrings("× Agent 9f8e7d · Sign-in expired\n▪ Agent 9f8e7d stopped\n× Agent bad\\x1b[2J · The model's reply didn't come through\n", out.buffered());
}

test "an ended Turn shows one plain cause line for every failure class, and its provider's usage place for quota" {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    const cases = .{
        .{ "provider_policy", null, "× Refused by the provider" },
        .{ "provider_quota", null, "× Out of quota · Settings" },
        .{ "provider_quota", .codex, "× Out of quota · Settings" },
        .{ "provider_quota", .openai, "× Out of quota · Settings" },
        .{ "provider_quota", .chatgpt, "× Out of quota · Manage usage: https://chatgpt.com/settings/usage" },
        .{ "provider_plan", null, "× Model not in plan · Settings" },
        .{ "provider_plan", .chatgpt, "× Model not in plan · Settings" },
        .{ "provider_model_unavailable", null, "× Model not served" },
        .{ "provider_http_401", null, "× Sign-in expired · Settings" },
        .{ "provider_http_401", .chatgpt, "× Sign-in expired · Settings" },
        .{ "provider_api_key_rejected", null, "× API key rejected · Settings" },
        .{ "ResourceExceeded", null, "× Context full" },
        .{ "provider_tls_verification_failed", null, "× Provider unreachable" },
        .{ "retry_exhausted", null, "× Retries ran out" },
        .{ "cancelled", null, "▪ Stopped" },
        .{ "provider_http_400", null, "× Provider refused the request" },
        .{ "unknown\x1b[2J", null, "× That didn't work" },
        .{ "malformed_provider_output", null, "× The model's reply didn't come through" },
    };
    var seen: std.enums.EnumSet(failure_class.Class) = .empty;
    inline for (cases) |case| {
        seen.insert(failure_class.of(case[0]));
        var buffer: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var sink: Sink = .{ .out = &out };
        try workEnded(&sink, case[0], case[1], false);
        try std.testing.expectEqualStrings(case[2] ++ "\n", out.buffered());
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
    try workEnded(&sink, "malformed_provider_output", null, true);
    try workEnded(&sink, "cancelled", null, true);
    try agentEnded(&sink, "9f8e7d", "malformed_provider_output", true);
    try agentEnded(&sink, "9f8e7d", "cancelled", true);
    try std.testing.expectEqualStrings("\x1b[91m×\x1b[39m The model's reply didn't come through\n" ++
        "\x1b[39m▪\x1b[39m Stopped\n" ++
        "\x1b[91m×\x1b[39m Agent 9f8e7d · The model's reply didn't come through\n" ++
        "\x1b[39m▪\x1b[39m Agent 9f8e7d stopped\n", out.buffered());
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
    try workEnded(&sink, "provider_http_401", null, true);
    try std.testing.expectEqualStrings("\x1b[91m×\x1b[39m Sign-in expired\x1b[90m · Settings\x1b[39m\n", out.buffered());
    out.end = 0;
    try ending(&sink, .{ .mark = .failed, .words = "Cause", .place = "Place", .key = "Key" }, false);
    try std.testing.expectEqualStrings("× Cause · Place · Key\n", out.buffered());
    out.end = 0;
    try ending(&sink, .{ .mark = .failed, .words = "Cause", .key = "Key" }, false);
    try std.testing.expectEqualStrings("× Cause · Key\n", out.buffered());
}

pub const Fold = union(enum) { none, closed, open: *tool_fold.Output };

pub fn tight(value: protocol.ActivityItem.Value) bool {
    return switch (value) {
        .tool_result => |result| result.presentation.code == .succeeded,
        .hosted_call => |presentation| presentation.code == .succeeded,
        .sent => true,
        .admission, .received, .user => |message_| message_.sender != null,
        .assistant, .call, .turn_ended, .stop, .send_failed, .approval_requested, .session_changed, .compacted, .model_call => false,
    };
}

pub fn gap(above: bool, below: bool, tool_pair: bool) bool {
    return !(tool_pair or (above and below));
}

/// `scratch` holds the part list of a parts value while its row draws.
pub fn render(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File, provider: ?protocol.Provider, item: protocol.ActivityItem, queued: protocol.Queued, held: bool, sink: anytype, colour: bool, home: []const u8, destination: Destination, fold: Fold) !bool {
    switch (item.value) {
        .admission => |value| {
            _ = value;
            _ = queued;
            _ = held;
            return false;
        },
        .received => |value| try message(requests, store, session, scratch, item, value, .none, sink, colour),
        .user => |value| {
            if (value.sender != null or value.source_action != null) return false;
            try message(requests, store, session, scratch, item, value, .none, sink, colour);
        },
        .assistant => |assistant| {
            var answer: Answer(@TypeOf(sink)) = undefined;
            answer.init(sink, home, colour, destination);
            try content(requests, store, session, scratch, item, .{ .text = assistant.content }, &answer);
            try answer.finish();
            try Text.writeBody(sink, "\n");
        },
        .tool_result => |result| {
            var scan: ToolHeaderScan = .{};
            switch (fold) {
                .none, .closed => try content(requests, store, session, scratch, item, result.content, &scan),
                .open => |output| {
                    const Both = struct {
                        scan: *ToolHeaderScan,
                        output: *tool_fold.Output,
                        pub fn feed(self: *@This(), bytes: []const u8) !void {
                            try self.scan.feed(bytes);
                            try self.output.feed(bytes);
                        }
                    };
                    output.* = .{};
                    var both: Both = .{ .scan = &scan, .output = output };
                    try content(requests, store, session, scratch, item, result.content, &both);
                },
            }
            try toolResultRow(result.presentation, scan.facts(result.presentation.code), fold != .none, sink, colour);
            if (fold == .open) try fold.open.finish(sink);
        },
        .hosted_call => |presentation| {
            try sink.feed(tool_fold.row_marker);
            try toolResult(presentation, .{}, sink, colour);
        },
        .call => {},
        .turn_ended => |ended| {
            if (ended.ending == .done) return false;
            if (!std.mem.eql(u8, ended.session.slice(), session)) {
                try agentEnded(sink, ended.session.slice(), ended.code.slice(), colour);
            } else try workEnded(sink, ended.code.slice(), provider, colour);
        },
        .stop => |stop| {
            const excluded = try excludedAtStop(requests, store, session, scratch, item, sink, colour);
            if (stop.turn == null) {
                if (excluded) try sink.feed("\n");
                try ending(sink, .{ .mark = .stopped, .words = "Stopped" }, colour);
            }
        },
        .sent => |sent| try peerLine(sink, .outbound, sent.target, sent.admitted_at),
        .send_failed => |failed| try sendFailed(sink, failed.target),
        .approval_requested, .session_changed, .compacted, .model_call => {},
    }
    return false;
}

fn excludedAtStop(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File, stop: protocol.ActivityItem, sink: anytype, colour: bool) !bool {
    if (stop.value.stop.cutoff == 0) return false;
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
    const lowest = first orelse return false;
    sink.excluding(lowest);
    var wrote = false;
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
            if (wrote) try sink.feed("\n");
            wrote = true;
            try message(requests, store, session, scratch, item, value, .lasting(false), sink, colour);
        }
        cursor = page.continuation() orelse return wrote;
    }
}

test "hosted calls draw as adjacent tool rows across outcomes" {
    const Sink = struct {
        bytes: [512]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var joined: Sink = .{};
    var above: ?bool = null;
    for ([_]struct { []const u8, protocol.ToolPresentation.Code, []const u8 }{
        .{ "Search “zig 0.17”", .succeeded, "✓ Search “zig 0.17”\n" },
        .{ "Open ziglang.org/x", .succeeded, "✓ Open ziglang.org/x\n" },
        .{ "Find “Io” in ziglang.org/x", .failed, "× Find “Io” in ziglang.org/x\n" },
        .{ "Search the web", .succeeded, "✓ Search the web\n" },
    }) |call| {
        var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
        try description.set(call[0]);
        const presentation: protocol.ToolPresentation = .{ .description = description, .code = call[1], .publication_position = 1 };
        var row: Sink = .{};
        try toolResult(presentation, .{}, &row, false);
        try std.testing.expectEqualStrings(call[2], row.bytes[0..row.length]);
        const below = tight(.{ .hosted_call = presentation });
        if (above) |value| if (gap(value, below, true)) try joined.feed("\n");
        try joined.feed(row.bytes[0..row.length]);
        above = below;
    }
    try std.testing.expectEqualStrings(
        "✓ Search “zig 0.17”\n✓ Open ziglang.org/x\n× Find “Io” in ziglang.org/x\n✓ Search the web\n",
        joined.bytes[0..joined.length],
    );
}

test "read_image approval displays the exact path arguments without a server" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(std.testing.io, "arguments", .{ .read = true });
    defer scratch.close(std.testing.io);
    try scratch.writePositionalAll(std.testing.io, "{\"path\":\"image.png\"}", 0);
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), text: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..text.len], text);
            self.length += text.len;
        }
    };
    var sink: Sink = .{};
    var tool: ActionTool = .{ .name = .{}, .description = .{}, .server = null };
    try tool.name.set("read_image");
    try tool.description.set("Read image");
    try renderPermissionArguments(std.testing.io, scratch, &sink, false, true, &tool);
    const rendered = sink.bytes[0..sink.length];
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Tool: read_image") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "{\"path\":\"image.png\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Server:") == null);
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
        try renderPermissionArguments(std.testing.io, scratch, &sink, false, true, &tool);
        var rendered: [2048]u8 = undefined;
        const count = try action.readPositionalAll(std.testing.io, &rendered, 0);
        var heading: [256]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, rendered[0..count], try std.fmt.bufPrint(&heading, "\n● {s}\n", .{case.description})));
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
    const arguments = "{\"cmd\":\"rm -rf build\\nzig build\",\"description\":\"Clean and build\"}";
    try scratch.writePositionalAll(std.testing.io, arguments, 0);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("rm -rf b", (try bashCommand(std.testing.io, scratch, &bash, &buffer)).?);
    var wide: [64]u8 = undefined;
    try std.testing.expectEqualStrings("rm -rf build\nzig build", (try bashCommand(std.testing.io, scratch, &bash, &wide)).?);
    try std.testing.expectEqual(null, try bashCommand(std.testing.io, scratch, &mcp, &wide));
    try std.testing.expectEqual(null, try bashCommand(std.testing.io, scratch, &other, &wide));
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
    try scratch.writePositionalAll(std.testing.io, "‮", prefix.len);
    var at: u64 = prefix.len + "‮".len;
    const fill: [4096]u8 = @splat('a');
    while (at < Viewport.capacity + 4096) : (at += fill.len) try scratch.writePositionalAll(std.testing.io, &fill, at);
    try scratch.writePositionalAll(std.testing.io, "\"\n}", at);
    var sink: Sink = .{ .file = action };
    try renderPermissionArguments(std.testing.io, scratch, &sink, false, true, &tool);
    var beginning: [512]u8 = undefined;
    const count = try action.readPositionalAll(std.testing.io, &beginning, 0);
    const shown = beginning[0..count];
    try std.testing.expect(std.mem.startsWith(u8, shown, "\n● Saved \\x1b[2J\n"));
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

test "background final input prefix names the Action instead of a person" {
    const Sink = struct {
        bytes: std.Io.Writer.Allocating,
        pub fn feed(self: *@This(), text: []const u8) !void {
            try self.bytes.writer.writeAll(text);
        }
    };
    var sink: Sink = .{ .bytes = .init(std.testing.allocator) };
    defer sink.bytes.deinit();
    try inputPrefix(&sink, false, 1, 42);
    try std.testing.expectEqualStrings("Background Action 42\n", sink.bytes.written());
}
