//! The display line of a first Message, in bytes only (no terminal width), so the Host, the Store and the
//! client share one rule. session_line re-exports it for the overview.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const utf8_validation = @import("utf8_validation.zig");

pub const max_line_bytes = 256;
pub const ellipsis = "…";

/// The display line of a first Message: its first physical line, trimmed of spaces and tabs. Blank means no
/// line: the Session is then named by its reference. Every reader of a first Message's line calls this one
/// function (the client's first-line read, the overview and the Archived window), so a Session is named the
/// same way wherever it is listed.
pub fn firstLine(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
    return std.mem.trim(u8, bytes[0..end], " \t");
}

/// `bytes` within `limit`, cut at a scalar boundary and marked with an ellipsis when shortened.
pub fn cut(comptime limit: usize, bytes: []const u8) Bounded(limit) {
    var value: Bounded(limit) = .{};
    const kept = if (bytes.len <= limit) bytes.len else utf8_validation.scalarStart(bytes, limit - ellipsis.len);
    @memcpy(value.bytes[0..kept], bytes[0..kept]);
    value.len = kept;
    if (kept < bytes.len) {
        @memcpy(value.bytes[kept..][0..ellipsis.len], ellipsis);
        value.len += ellipsis.len;
    }
    return value;
}
