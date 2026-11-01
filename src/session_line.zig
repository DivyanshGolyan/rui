//! The line under the conversation's input: the Session's name, model,
//! effort, the context left before automatic compaction and, when Bash asks
//! first, that. Narrow lines drop effort first, then shorten the name. This
//! core takes the facts its shell read and the terminal's width method, and
//! returns text; it holds no terminal, clock or Store fact.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const model_capability = @import("model_capability.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

pub const Method = gwidth.Method;
pub const ReasoningEffort = model_capability.ReasoningEffort;

/// The longest first line a name keeps, ellipsis included.
pub const max_line_bytes = 256;

pub const separator = " · ";
pub const ellipsis = "…";
const asks_text = "asks before Bash";
const left_text = "100% left";

/// A Session's name: its Label, else the first line of its first Message (a
/// hint), else its reference (a hint). A blank first line is no first line.
/// The overview's rows and the conversation's line both use it.
pub const Name = struct { text: []const u8, hint: bool };

pub fn name(label: ?[]const u8, line: ?[]const u8, reference: []const u8) Name {
    if (label) |text| return .{ .text = text, .hint = false };
    if (line) |text| if (text.len != 0) return .{ .text = text, .hint = true };
    return .{ .text = reference, .hint = true };
}

/// `bytes` up to its first line end, without surrounding spaces and tabs.
pub fn firstLine(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
    return std.mem.trim(u8, bytes[0..end], " \t");
}

/// `bytes` within `limit`, cut at a code point and ended with an ellipsis
/// when it is longer.
pub fn cut(comptime limit: usize, bytes: []const u8) Bounded(limit) {
    var value: Bounded(limit) = .{};
    const kept = if (bytes.len <= limit) bytes.len else codepointStart(bytes, limit - ellipsis.len);
    @memcpy(value.bytes[0..kept], bytes[0..kept]);
    value.len = kept;
    if (kept < bytes.len) {
        @memcpy(value.bytes[kept..][0..ellipsis.len], ellipsis);
        value.len += ellipsis.len;
    }
    return value;
}

/// The start of the code point holding byte `at`, so a cut there keeps whole
/// code points.
fn codepointStart(bytes: []const u8, at: usize) usize {
    var start = at;
    while (start > 0 and start < bytes.len and bytes[start] & 0xc0 == 0x80) start -= 1;
    return start;
}

/// The percentage of `trigger` still left before `pressure` reaches it,
/// rounded up, so 0 means the pressure reached the trigger.
pub fn left(trigger: u64, pressure: u64) u8 {
    std.debug.assert(trigger != 0);
    const remaining: u128 = trigger - @min(pressure, trigger);
    return @intCast((remaining * 100 + trigger - 1) / trigger);
}

pub const Facts = struct {
    name: []const u8,
    model: []const u8,
    effort: ?ReasoningEffort = null,
    /// Percent left before automatic compaction; null when no estimate
    /// decides the next model call.
    left: ?u8 = null,
    asks: bool = false,
};

/// The longest name a shell passes: a first line, or a shorter Label or
/// reference.
pub const max_name_bytes = max_line_bytes;

const max_effort_bytes = blk: {
    var longest = 0;
    for (std.meta.fieldNames(ReasoningEffort)) |tag| longest = @max(longest, tag.len);
    break :blk longest;
};

/// Bytes the longest line takes: every part, the separators between them and
/// the ellipsis that ends a shortened name.
pub const capacity = max_name_bytes + ellipsis.len + model_capability.max_model_bytes + max_effort_bytes + left_text.len + asks_text.len + 4 * separator.len;

/// The line for `width` cells as `method` measures them. It never takes more
/// than `width` cells.
pub fn write(buffer: *[capacity]u8, facts: Facts, width: usize, method: Method) []const u8 {
    std.debug.assert(facts.name.len <= max_name_bytes and facts.model.len <= model_capability.max_model_bytes);
    var percent: [left_text.len]u8 = undefined;
    const shown_left: ?[]const u8 = if (facts.left) |value| std.fmt.bufPrint(&percent, "{d}% left", .{value}) catch unreachable else null;
    const asks: ?[]const u8 = if (facts.asks) asks_text else null;
    const effort: ?[]const u8 = if (facts.effort) |value| @tagName(value) else null;
    const tail = [_]?[]const u8{ facts.model, shown_left, asks };
    var out = join(buffer, &.{ facts.name, facts.model, effort, shown_left, asks }, "");
    if (cells(out, method) <= width) return out;
    out = join(buffer, &(.{facts.name} ++ tail), "");
    if (cells(out, method) <= width) return out;
    // Joined text measures at most the sum of its parts, so a name cut to
    // what `fixed` leaves keeps the line within `width`.
    const tail_cells = cells(out[facts.name.len + separator.len ..], method);
    const fixed = tail_cells + cells(separator, method) + cells(ellipsis, method);
    if (width > fixed) {
        const kept = fit(facts.name, width - fixed, method);
        if (kept.cells != 0 and kept.len < facts.name.len) return join(buffer, &(.{facts.name[0..kept.len]} ++ tail), ellipsis);
    }
    out = join(buffer, &tail, "");
    if (cells(out, method) <= width) return out;
    if (width < 2) return buffer[0..0];
    const end = fit(out, width - 1, method).len;
    @memcpy(buffer[end..][0..ellipsis.len], ellipsis);
    return buffer[0 .. end + ellipsis.len];
}

/// The line as last written, kept until its facts or its width change, so
/// a frame that changes neither writes nothing.
pub const Shown = struct {
    /// Null until written, and after the facts change.
    width: ?usize = null,
    len: usize = 0,
    bytes: [capacity]u8 = undefined,

    pub fn text(self: *Shown, facts: Facts, width: usize, method: Method) []const u8 {
        if (self.width != width) {
            self.len = write(&self.bytes, facts, width, method).len;
            self.width = width;
        }
        return self.bytes[0..self.len];
    }
};

pub fn cells(bytes: []const u8, method: Method) usize {
    return gwidth.gwidth(bytes, method);
}

/// The longest run of whole clusters at the start of `bytes` within `limit`
/// cells: its byte length and the cells it takes. The conversation's work
/// line cuts its words with it too.
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

/// The present parts joined by the separator; `mark` follows the first.
fn join(buffer: *[capacity]u8, parts: []const ?[]const u8, mark: []const u8) []const u8 {
    var out = std.Io.Writer.fixed(buffer);
    var first = true;
    for (parts) |maybe| {
        const part = maybe orelse continue;
        if (!first) out.writeAll(separator) catch unreachable;
        out.writeAll(part) catch unreachable;
        if (first) out.writeAll(mark) catch unreachable;
        first = false;
    }
    return out.buffered();
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

test "context left is zero exactly when the pressure reaches the trigger" {
    try std.testing.expectEqual(@as(u8, 100), left(244_800, 0));
    try std.testing.expectEqual(@as(u8, 69), left(244_800, 75_888));
    try std.testing.expectEqual(@as(u8, 1), left(244_800, 244_799));
    try std.testing.expectEqual(@as(u8, 0), left(244_800, 244_800));
    try std.testing.expectEqual(@as(u8, 0), left(244_800, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u8, 100), left(std.math.maxInt(u64), 1));
    // Every trigger and pressure in a small domain against exact rationals.
    for (1..120) |trigger| for (0..trigger + 2) |pressure| {
        const value = left(trigger, pressure);
        const remaining = trigger -| pressure;
        try std.testing.expectEqual(remaining == 0, value == 0);
        // value is the least whole percent at or above remaining / trigger.
        try std.testing.expect(@as(u64, value) * trigger >= remaining * 100);
        if (value != 0) try std.testing.expect(@as(u64, value - 1) * trigger < remaining * 100);
    };
}

test "the mock's line at its widths" {
    var buffer: [capacity]u8 = undefined;
    const facts: Facts = .{ .name = "Fix flaky store tests", .model = "gpt-6.1-sol", .effort = .low, .left = 69 };
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · low · 69% left", write(&buffer, facts, 80, .unicode));
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · 69% left", write(&buffer, facts, 51, .unicode));
    try std.testing.expectEqualStrings("Fix flaky st… · gpt-6.1-sol · 69% left", write(&buffer, facts, 38, .unicode));
    try std.testing.expectEqualStrings("F… · gpt-6.1-sol · 69% left", write(&buffer, facts, 27, .unicode));
    try std.testing.expectEqualStrings("gpt-6.1-sol · 69% left", write(&buffer, facts, 26, .unicode));
    try std.testing.expectEqualStrings("gpt-6.1-sol · 6…", write(&buffer, facts, 16, .unicode));
    var asks = facts;
    asks.asks = true;
    asks.left = null;
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · low · asks before Bash", write(&buffer, asks, 80, .unicode));
}

test "the longest facts fit the buffer" {
    var buffer: [capacity]u8 = undefined;
    const longest_name: [max_name_bytes]u8 = @splat('n');
    const longest_model: [model_capability.max_model_bytes]u8 = @splat('m');
    const line = write(&buffer, .{ .name = &longest_name, .model = &longest_model, .effort = .medium, .left = 100, .asks = true }, std.math.maxInt(usize), .unicode);
    try std.testing.expectEqual(capacity - ellipsis.len, line.len);
}

/// Each line `write` prefers, in its order: the whole line, then without
/// effort, then the name cut to fewer clusters one at a time, then without
/// the name. Built by formatting, not by `write`'s joins and room.
fn candidates(storage: []u8, facts: Facts, method: Method, out: [][]const u8) usize {
    var used: usize = 0;
    var count: usize = 0;
    var percent: [12]u8 = undefined;
    const left_shown = if (facts.left) |value| std.fmt.bufPrint(&percent, "{d}% left", .{value}) catch unreachable else "";
    const rest = std.fmt.bufPrint(storage[used..], "{s}{s}{s}{s}", .{ if (facts.left != null) " · " else "", left_shown, if (facts.asks) " · " else "", if (facts.asks) asks_text else "" }) catch unreachable;
    used += rest.len;
    if (facts.effort) |effort| {
        out[count] = std.fmt.bufPrint(storage[used..], "{s} · {s} · {s}{s}", .{ facts.name, facts.model, @tagName(effort), rest }) catch unreachable;
        used += out[count].len;
        count += 1;
    }
    out[count] = std.fmt.bufPrint(storage[used..], "{s} · {s}{s}", .{ facts.name, facts.model, rest }) catch unreachable;
    used += out[count].len;
    count += 1;
    var ends: [64]usize = undefined;
    var clusters: usize = 0;
    var iterator = unicode.graphemeIterator(facts.name);
    while (iterator.next()) |cluster| {
        ends[clusters] = cluster.start + cluster.len;
        clusters += 1;
    }
    var keep = clusters;
    while (keep > 1) {
        keep -= 1;
        // A name cut to clusters that show nothing is not a name.
        if (gwidth.gwidth(facts.name[0..ends[keep - 1]], method) == 0) break;
        out[count] = std.fmt.bufPrint(storage[used..], "{s}… · {s}{s}", .{ facts.name[0..ends[keep - 1]], facts.model, rest }) catch unreachable;
        used += out[count].len;
        count += 1;
    }
    out[count] = std.fmt.bufPrint(storage[used..], "{s}{s}", .{ facts.model, rest }) catch unreachable;
    count += 1;
    return count;
}

test "every width keeps the most a line can hold, in its order, and never more than the width" {
    var buffer: [capacity]u8 = undefined;
    var storage: [16 * 1024]u8 = undefined;
    var lines: [80][]const u8 = undefined;
    const names = [_][]const u8{ "Fix flaky store tests", "a1b2c3", "修复测试 then more", "x", "e\u{301}e\u{301} combining", "\u{301}a", "\u{200d}中", "👩‍🚀 crew", "中中中" };
    for ([_]Method{ .unicode, .wcwidth }) |method| for (names) |name_text| for ([_]?ReasoningEffort{ null, .high }) |effort| for ([_]?u8{ null, 0, 100 }) |percent| for ([_]bool{ false, true }) |asks| {
        const facts: Facts = .{ .name = name_text, .model = "gpt-6.1-sol", .effort = effort, .left = percent, .asks = asks };
        const count = candidates(&storage, facts, method, &lines);
        for (0..90) |width| {
            const line = write(&buffer, facts, width, method);
            try std.testing.expect(gwidth.gwidth(line, method) <= width);
            const preferred = for (lines[0..count]) |candidate| {
                if (gwidth.gwidth(candidate, method) <= width) break candidate;
            } else null;
            if (preferred) |expected| {
                try std.testing.expectEqualStrings(expected, line);
            } else {
                // Nothing whole fits: the model and the rest are cut at the
                // edge, ending in an ellipsis, or nothing shows.
                const whole = lines[count - 1];
                if (width < 2) {
                    try std.testing.expectEqualStrings("", line);
                } else {
                    try std.testing.expect(std.mem.endsWith(u8, line, ellipsis));
                    try std.testing.expect(std.mem.startsWith(u8, whole, line[0 .. line.len - ellipsis.len]));
                    try std.testing.expect(gwidth.gwidth(line, method) + 2 > width);
                }
            }
        }
    };
}

test "a line is written again only when its width or facts change" {
    var shown: Shown = .{};
    const facts: Facts = .{ .name = "Fix flaky store tests", .model = "gpt-6.1-sol", .effort = .low, .left = 69 };
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · low · 69% left", shown.text(facts, 80, .unicode));
    // Unchanged width: the kept text, even for other facts, until reset.
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · low · 69% left", shown.text(.{ .name = "x", .model = "y" }, 80, .unicode));
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · 69% left", shown.text(facts, 51, .unicode));
    shown = .{};
    try std.testing.expectEqualStrings("x · y", shown.text(.{ .name = "x", .model = "y" }, 51, .unicode));
}
