const std = @import("std");
const TerminalText = @import("TerminalText.zig");
const Bounded = @import("bounded.zig").Bounded;
const utf8_validation = @import("utf8_validation.zig");
const first_line = @import("first_line.zig");
const model_capability = @import("model_capability.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

pub const Method = gwidth.Method;
pub const ReasoningEffort = model_capability.ReasoningEffort;

pub const max_line_bytes = first_line.max_line_bytes;

pub const separator = " · ";
pub const ellipsis = first_line.ellipsis;
pub const stop_hint = "ctrl+x stop";

pub const Name = struct { text: []const u8, hint: bool };

pub fn name(label: ?[]const u8, line: ?[]const u8, reference: []const u8) Name {
    if (label) |text| return .{ .text = text, .hint = false };
    if (line) |text| if (text.len != 0) return .{ .text = text, .hint = true };
    return .{ .text = reference, .hint = true };
}

pub const firstLine = first_line.firstLine;
pub const cut = first_line.cut;

pub fn plain(comptime limit: usize, bytes: []const u8) Bounded(limit) {
    var value: Bounded(limit) = .{ .len = 0 };
    var text: TerminalText = .{ .mode = .multiline };
    var room: usize = 0;
    for (bytes, 1..) |byte, count| {
        var storage: [32]u8 = undefined;
        var piece = std.Io.Writer.fixed(&storage);
        text.feed(&piece, &.{byte}) catch unreachable;
        if (count == bytes.len) text.finish(&piece) catch unreachable;
        const shown = piece.buffered();
        if (value.len + shown.len > limit) {
            value.len = room;
            @memcpy(value.bytes[room..][0..ellipsis.len], ellipsis);
            value.len += ellipsis.len;
            return value;
        }
        for (shown, value.bytes[value.len..][0..shown.len]) |from, *to| to.* = if (from == '\n' or from == '\t') ' ' else from;
        value.len += shown.len;
        if (value.len + ellipsis.len <= limit) room = value.len;
    }
    return value;
}

/// A chat's context reading: the tokens its next request will carry against the point where it compacts.
/// A chat has one only when both numbers are known and the trigger is not zero.
pub const Context = struct {
    estimate: u64,
    trigger: u64,

    pub const footer_bytes = "100% context left".len;

    pub fn of(estimate: ?u64, trigger: ?u64) ?Context {
        const tokens = estimate orelse return null;
        const limit = trigger orelse return null;
        if (limit == 0) return null;
        return .{ .estimate = tokens, .trigger = limit };
    }

    /// Whole percent of the trigger still free; zero exactly when the estimate reaches the trigger.
    pub fn left(self: Context) u8 {
        const remaining: u128 = self.trigger - @min(self.estimate, self.trigger);
        return @intCast((remaining * 100 + self.trigger - 1) / self.trigger);
    }

    /// "N% context left", once half of the room is used (exactly half included); null before that.
    pub fn footerWords(self: Context, buffer: *[footer_bytes]u8) ?[]const u8 {
        const percent = self.left();
        if (percent > 50) return null;
        return std.fmt.bufPrint(buffer, "{d}% context left", .{percent}) catch unreachable;
    }

    /// A reading with exactly `percent` left, for tests that care about the words and not the tokens.
    pub fn atLeft(percent: u8) Context {
        comptime std.debug.assert(@import("builtin").is_test);
        std.debug.assert(percent <= 100);
        return .{ .estimate = 100 - percent, .trigger = 100 };
    }
};

/// What the chat footer says about a chat. The name is not among them: the Session list and the
/// terminal title carry it.
pub const Facts = struct {
    model: []const u8,
    folder: ?[]const u8 = null,
    home: []const u8 = "",
    effort: ?ReasoningEffort = null,
    context: ?Context = null,
};

pub const max_name_bytes = max_line_bytes;

pub const max_effort_bytes = blk: {
    var longest = 0;
    for (std.meta.fieldNames(ReasoningEffort)) |tag| longest = @max(longest, tag.len);
    break :blk longest;
};

pub fn cells(bytes: []const u8, method: Method) usize {
    return gwidth.gwidth(bytes, method);
}

pub fn fit(bytes: []const u8, limit: usize, method: Method) struct { len: usize, cells: usize } {
    var used: usize = 0;
    var end: usize = 0;
    var clusters = unicode.graphemeIterator(bytes);
    while (clusters.next()) |cluster| {
        const taken = cells(cluster.bytes(bytes), method);
        if (used + taken > limit) break;
        used += taken;
        end = cluster.start + cluster.len;
    }
    return .{ .len = end, .cells = used };
}

test "the name is the Label, else a first line that is not blank, else the reference" {
    for ([_]?[]const u8{ "Fix it", null }) |label| for ([_]?[]const u8{ "first", "", null }) |line| {
        const named = name(label, line, "a1b2c3");
        const shown_line: ?[]const u8 = if (line != null and line.?.len == 0) null else line;
        try std.testing.expectEqualStrings(label orelse shown_line orelse "a1b2c3", named.text);
        try std.testing.expectEqual(label == null, named.hint);
    };
    try std.testing.expectEqualStrings("a1b2c3", name(null, firstLine("\nFix it"), "a1b2c3").text);
    try std.testing.expectEqualStrings("short", firstLine("  short \r\nrest"));
}

test "a long line keeps whole code points and ends in an ellipsis" {
    var line: [400]u8 = undefined;
    for (0..200) |at| @memcpy(line[at * 2 ..][0..2], "é");
    const kept = cut(max_line_bytes, &line);
    try std.testing.expect(std.unicode.utf8ValidateSlice(kept.slice()));
    try std.testing.expect(std.mem.endsWith(u8, kept.slice(), ellipsis));
    try std.testing.expect(kept.len <= max_line_bytes);
    try std.testing.expect(!std.mem.endsWith(u8, cut(max_line_bytes, line[0..max_line_bytes]).slice(), ellipsis));
}

fn leftOf(trigger: u64, pressure: u64) u8 {
    return Context.of(pressure, trigger).?.left();
}

test "SUI-171 a context reading exists only with both numbers and shows its footer words from half used" {
    try std.testing.expectEqual(@as(u8, 100), leftOf(244_800, 0));
    try std.testing.expectEqual(@as(u8, 69), leftOf(244_800, 75_888));
    try std.testing.expectEqual(@as(u8, 1), leftOf(244_800, 244_799));
    try std.testing.expectEqual(@as(u8, 0), leftOf(244_800, 244_800));
    try std.testing.expectEqual(@as(u8, 0), leftOf(244_800, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u8, 100), leftOf(std.math.maxInt(u64), 1));
    for (1..120) |trigger| for (0..trigger + 2) |pressure| {
        const value = leftOf(trigger, pressure);
        const remaining = trigger -| pressure;
        try std.testing.expectEqual(remaining == 0, value == 0);
        try std.testing.expect(@as(u64, value) * trigger >= remaining * 100);
        if (value != 0) try std.testing.expect(@as(u64, value - 1) * trigger < remaining * 100);
    };
    for ([_]?u64{ null, 1, 244_800 }) |trigger| {
        const half: u64 = (trigger orelse 0) / 2;
        for ([_]?u64{ null, 0, half -| 1, half, half + 1, trigger, if (trigger) |limit| limit + 1 else null }) |estimate| {
            const reading = Context.of(estimate, trigger);
            try std.testing.expectEqual(estimate != null and trigger != null, reading != null);
            const context = reading orelse continue;
            var buffer: [Context.footer_bytes]u8 = undefined;
            const percent = context.left();
            if (context.footerWords(&buffer)) |words| {
                try std.testing.expect(percent <= 50);
                var expected: [Context.footer_bytes]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{d}% context left", .{percent}), words);
            } else try std.testing.expect(percent > 50);
        }
    }
    try std.testing.expect(Context.of(5, 0) == null);
    var buffer: [Context.footer_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("50% context left", Context.of(122_400, 244_800).?.footerWords(&buffer).?);
    try std.testing.expect(Context.of(122_399, 244_800).?.footerWords(&buffer) == null);
    for (0..101) |percent| try std.testing.expectEqual(@as(u8, @intCast(percent)), Context.atLeft(@intCast(percent)).left());
}

test "a first Message names its Session by its first physical line, and a leading blank line names nothing" {
    try std.testing.expectEqualStrings("", firstLine("\nFix CI"));
    try std.testing.expectEqualStrings("", firstLine("\r\nFix CI"));
    try std.testing.expectEqualStrings("Fix CI", firstLine("  Fix CI \r\nmore"));
}
