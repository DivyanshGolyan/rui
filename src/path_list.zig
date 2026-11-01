//! A colon-separated search path as a value, built the way macOS's
//! `path_helper` builds the system PATH.

const std = @import("std");

/// Appends `segment` to the list in `buffer[0..length]` and returns the new
/// length. An empty segment, or one already in the list at entry boundaries
/// (path_helper's `(^|:)segment(:|$)`), leaves it unchanged. Null when the
/// segment does not fit.
pub fn append(buffer: []u8, length: usize, segment: []const u8) ?usize {
    if (segment.len == 0 or contains(buffer[0..length], segment)) return length;
    const separator: usize = @intFromBool(length != 0);
    if (segment.len > buffer.len - length - separator) return null;
    if (separator != 0) buffer[length] = ':';
    @memcpy(buffer[length + separator ..][0..segment.len], segment);
    return length + separator + segment.len;
}

fn contains(list: []const u8, segment: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, list, start, segment)) |at| : (start = at + 1) {
        const end = at + segment.len;
        if ((at == 0 or list[at - 1] == ':') and (end == list.len or list[end] == ':')) return true;
    }
    return false;
}

/// path_helper's order for the files in `/etc/paths.d`: two names that both
/// start with a number (as C's strtol reads one) sort by that number, then
/// by the rest; any other pair sorts bytewise, as strcoll does in the C
/// locale path_helper runs in.
pub fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    if (numberPrefix(a)) |left| if (numberPrefix(b)) |right| {
        if (left.value != right.value) return left.value < right.value;
        return std.mem.lessThan(u8, left.rest, right.rest);
    };
    return std.mem.lessThan(u8, a, b);
}

const Prefix = struct { value: i64, rest: []const u8 };

/// strtol(name, &end, 10): leading C whitespace, an optional sign, then
/// decimal digits, saturating at the i64 bounds. Null without a digit.
fn numberPrefix(name: []const u8) ?Prefix {
    var index: usize = 0;
    while (index < name.len and std.mem.indexOfScalar(u8, " \t\n\x0b\x0c\r", name[index]) != null) index += 1;
    var negative = false;
    if (index < name.len and (name[index] == '+' or name[index] == '-')) {
        negative = name[index] == '-';
        index += 1;
    }
    const digits = index;
    var value: i64 = 0;
    while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {
        const digit: i64 = name[index] - '0';
        value = std.math.mul(i64, value, 10) catch std.math.maxInt(i64);
        value = if (negative) std.math.sub(i64, value, digit) catch std.math.minInt(i64) else std.math.add(i64, value, digit) catch std.math.maxInt(i64);
    }
    if (index == digits) return null;
    return .{ .value = value, .rest = name[index..] };
}

test "append keeps order, skips empty and present entries, and refuses overflow" {
    var buffer: [128]u8 = undefined;
    var length: usize = 0;
    for ([_][]const u8{ "/usr/local/bin", "/usr/bin", "", "/bin", "/usr/bin", " /opt/homebrew/bin", "/usr", "/usr/local/bin" }) |segment|
        length = append(&buffer, length, segment).?;
    try std.testing.expectEqualStrings("/usr/local/bin:/usr/bin:/bin: /opt/homebrew/bin:/usr", buffer[0..length]);
    // A segment holding ':' matches the same run of entries, as strstr does.
    try std.testing.expectEqual(length, append(&buffer, length, "/usr/bin:/bin").?);
    try std.testing.expectEqual(length, append(&buffer, length, "/usr/local/bin:/usr/bin").?);
    var exact: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), append(&exact, 0, "/a").?);
    try std.testing.expectEqual(@as(usize, 5), append(&exact, 2, "/b").?);
    try std.testing.expectEqual(null, append(&exact, 2, "/bc"));
    try std.testing.expectEqual(@as(usize, 5), append(&exact, 5, "/a").?);
    try std.testing.expectEqual(null, append(&exact, 0, "/abcde"));
}

test "names sort by numeric prefix when both have one, else bytewise" {
    var names = [_][]const u8{ "homebrew", "10-late", "2-early", "2-a", "Zed", "-1x", "99999999999999999999", "x10" };
    std.mem.sort([]const u8, &names, {}, nameLessThan);
    const expected = [_][]const u8{ "-1x", "2-a", "2-early", "10-late", "99999999999999999999", "Zed", "homebrew", "x10" };
    for (expected, names) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(nameLessThan({}, " 3y", "10")); // strtol skips leading spaces.
    try std.testing.expect(!nameLessThan({}, "10", "9"));
}
