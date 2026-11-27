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

fn repeat(comptime unit: []const u8, comptime count: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        for (0..count) |_| out = out ++ unit;
        return out;
    }
}

/// What reading a provider's code and message leaves: the parts as the decoder builds them.
fn read(code: []const u8, message: []const u8) Report {
    var report: Report = .{};
    for ([_]*Part{ &report.code, &report.message }, [_][]const u8{ code, message }) |part, bytes| {
        _ = part.append(bytes);
        part.finish();
    }
    return report;
}

test "CM-69 a provider failure report keeps its code and message, each whole or cut, as one line" {
    const cases = [_]struct { code: []const u8, message: []const u8, kept_code: []const u8, kept_message: []const u8, cut: [2]bool, line: []const u8 }{
        // Absent parts: nothing, one part without a separator, both with one.
        .{ .code = "", .message = "", .kept_code = "", .kept_message = "", .cut = .{ false, false }, .line = "" },
        .{ .code = "", .message = "m", .kept_code = "", .kept_message = "m", .cut = .{ false, false }, .line = "m" },
        .{ .code = "c", .message = "", .kept_code = "c", .kept_message = "", .cut = .{ false, false }, .line = "c" },
        .{ .code = "c", .message = "m", .kept_code = "c", .kept_message = "m", .cut = .{ false, false }, .line = "c: m" },
        // Each part is cut at its own bound, and the flags are independent.
        .{ .code = comptime repeat("c", 300), .message = "m", .kept_code = comptime repeat("c", 256), .kept_message = "m", .cut = .{ true, false }, .line = repeat("c", 256) ++ "…: m" },
        .{ .code = "c", .message = comptime repeat("m", 300), .kept_code = "c", .kept_message = comptime repeat("m", 256), .cut = .{ false, true }, .line = "c: " ++ repeat("m", 256) ++ "…" },
        .{ .code = comptime repeat("c", 257), .message = comptime repeat("m", 257), .kept_code = comptime repeat("c", 256), .kept_message = comptime repeat("m", 256), .cut = .{ true, true }, .line = repeat("c", 256) ++ "…: " ++ repeat("m", 256) ++ "…" },
        // A part exactly at the bound is whole.
        .{ .code = "", .message = comptime repeat("m", 256), .kept_code = "", .kept_message = comptime repeat("m", 256), .cut = .{ false, false }, .line = comptime repeat("m", 256) },
        // A cut never splits a scalar: it keeps the longest valid prefix.
        .{ .code = "", .message = comptime repeat("é", 200), .kept_code = "", .kept_message = comptime repeat("é", 128), .cut = .{ false, true }, .line = repeat("é", 128) ++ "…" },
        .{ .code = "", .message = "x" ++ repeat("é", 200), .kept_code = "", .kept_message = "x" ++ repeat("é", 127), .cut = .{ false, true }, .line = "x" ++ repeat("é", 127) ++ "…" },
        // An ellipsis the provider sent is text, not a cut.
        .{ .code = "c…", .message = "wait…", .kept_code = "c…", .kept_message = "wait…", .cut = .{ false, false }, .line = "c…: wait…" },
        // Control bytes become spaces, so a part is one line.
        .{ .code = "a\nb", .message = "x\ty\x7fz", .kept_code = "a b", .kept_message = "x y z", .cut = .{ false, false }, .line = "a b: x y z" },
        // A part that is not UTF-8 is dropped.
        .{ .code = "c", .message = "\xff", .kept_code = "c", .kept_message = "", .cut = .{ false, false }, .line = "c" },
    };
    var out: [outcome_code.max_report_bytes]u8 = undefined;
    for (cases) |case| {
        const report = read(case.code, case.message);
        try std.testing.expectEqualStrings(case.kept_code, report.code.text.slice());
        try std.testing.expectEqualStrings(case.kept_message, report.message.text.slice());
        try std.testing.expectEqual(case.cut, [2]bool{ report.code.cut, report.message.cut });
        try std.testing.expectEqualStrings(case.line, report.joined(&out));
        try std.testing.expectEqual(case.line.len == 0, report.isEmpty());
    }
}
