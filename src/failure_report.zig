//! A provider's failure as the provider said it: a short code and a short message, each kept whole or
//! cut to its bound, with a flag that says which was cut.
//! Control bytes are rewritten to spaces when a part is read, so a part is always one line of UTF-8.
const std = @import("std");
const outcome_code = @import("outcome_code.zig");
const protocol = @import("protocol.zig");
const utf8_validation = @import("utf8_validation.zig");

pub const max_part_bytes = 256;
/// The mark a one-line rendering shows after a cut part. Stored parts never contain it.
pub const cut_mark = "…";

comptime {
    std.debug.assert(outcome_code.max_report_bytes == 2 * max_part_bytes + ": ".len + 2 * cut_mark.len);
}

pub const Part = struct {
    text: protocol.Bounded(max_part_bytes) = .{},
    cut: bool = false,

    pub fn clear(self: *Part) void {
        self.text.len = 0;
        self.cut = false;
    }

    /// Add bytes while they fit. When they do not, keep what fits up to the longest valid prefix, mark the part
    /// cut and return false.
    pub fn append(self: *Part, bytes: []const u8) bool {
        const kept = @min(bytes.len, self.text.bytes.len - self.text.len);
        @memcpy(self.text.bytes[self.text.len..][0..kept], bytes[0..kept]);
        self.text.len += kept;
        if (kept == bytes.len) return true;
        self.text.len = utf8_validation.validPrefix(self.text.slice()).len;
        self.cut = true;
        return false;
    }

    /// End of reading: drop a part that is not UTF-8 and make the rest one line.
    pub fn finish(self: *Part) void {
        if (!std.unicode.utf8ValidateSlice(self.text.slice())) self.text.len = 0;
        for (self.text.bytes[0..self.text.len]) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
            byte.* = ' ';
        };
    }
};

pub const Report = struct {
    code: Part = .{},
    message: Part = .{},

    pub const empty: Report = .{};

    /// A report that is only a message, whole.
    pub fn ofMessage(message: []const u8) Report {
        var report: Report = .{};
        report.message.text.set(message) catch unreachable;
        return report;
    }

    pub fn clear(self: *Report) void {
        self.code.clear();
        self.message.clear();
    }

    pub fn isEmpty(self: *const Report) bool {
        return self.code.text.len == 0 and self.message.text.len == 0;
    }

    /// One line, "code: message", with the cut mark after each cut part.
    pub fn joined(self: *const Report, out: *[outcome_code.max_report_bytes]u8) []const u8 {
        var len: usize = 0;
        const separator: []const u8 = if (self.code.text.len != 0 and self.message.text.len != 0) ": " else "";
        for ([_][]const u8{
            self.code.text.slice(),
            if (self.code.cut) cut_mark else "",
            separator,
            self.message.text.slice(),
            if (self.message.cut) cut_mark else "",
        }) |piece| {
            @memcpy(out[len..][0..piece.len], piece);
            len += piece.len;
        }
        return out[0..len];
    }
};

test "joined puts the separator only between two parts and marks each cut part" {
    var out: [outcome_code.max_report_bytes]u8 = undefined;
    var report: Report = .{};
    try std.testing.expectEqualStrings("", report.joined(&out));
    try report.message.text.set("m");
    try std.testing.expectEqualStrings("m", report.joined(&out));
    try report.code.text.set("c");
    try std.testing.expectEqualStrings("c: m", report.joined(&out));
    report.code.cut = true;
    report.message.cut = true;
    try std.testing.expectEqualStrings("c…: m…", report.joined(&out));
    report.message.clear();
    try std.testing.expectEqualStrings("c…", report.joined(&out));
}

test "append keeps a whole scalar or none of it and marks the cut" {
    var part: Part = .{};
    for (0..max_part_bytes / 2) |_| try std.testing.expect(part.append("é"));
    try std.testing.expect(!part.cut);
    try std.testing.expect(!part.append("é"));
    try std.testing.expect(part.cut);
    try std.testing.expectEqual(@as(usize, max_part_bytes), part.text.len);
    var odd: Part = .{};
    try std.testing.expect(odd.append("x"));
    for (0..max_part_bytes / 2 - 1) |_| try std.testing.expect(odd.append("é"));
    try std.testing.expect(!odd.append("é"));
    try std.testing.expectEqual(@as(usize, max_part_bytes - 1), odd.text.len);
}

test "finish makes a part one line and drops one that is not UTF-8" {
    var part: Part = .{};
    try part.text.set("a\nb\tc\x7fd");
    part.finish();
    try std.testing.expectEqualStrings("a b c d", part.text.slice());
    part.text.bytes[0] = 0xff;
    part.text.len = 1;
    part.finish();
    try std.testing.expectEqual(@as(usize, 0), part.text.len);
}
