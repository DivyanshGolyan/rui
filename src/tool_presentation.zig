//! How a tool call shows to a reader: its saved description, outcome code
//! and publication position. A Session Label has its own smaller byte bound.
//! protocol.zig renders it as JSON.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

pub const max_description_bytes = @import("mcp/shape.zig").description_max_bytes;

/// A Session Label obeys the saved Bash description rule.
pub const max_label_bytes = 100;

pub const ToolPresentation = struct {
    description: ?Bounded(max_description_bytes),
    code: Code,
    publication_position: ?u64,
    pub const Code = enum { unresolved, pending_permission, succeeded, failed, timed_out, indeterminate, storage_failed, spawn_failed, cancelled, infrastructure_shutdown, denied, unknown_tool, invalid_arguments };

    /// One non-blank line of UTF-8 within the description bound.
    pub fn validDescription(bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > max_description_bytes or !std.unicode.utf8ValidateSlice(bytes)) return false;
        var nonblank = false;
        var index: usize = 0;
        while (index < bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch unreachable;
            const scalar = std.unicode.utf8Decode(bytes[index..][0..length]) catch unreachable;
            index += length;
            switch (scalar) {
                '\n', '\r', 0x85, 0x2028, 0x2029 => return false,
                ' ', '\t', 0xb, 0xc, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => {},
                else => nonblank = true,
            }
        }
        return nonblank;
    }
};

/// Whether `bytes` is a Session Label: one non-blank line of UTF-8 within
/// `max_label_bytes`.
pub fn validLabel(bytes: []const u8) bool {
    return bytes.len <= max_label_bytes and ToolPresentation.validDescription(bytes);
}

test "a Label is one non-blank line of at most 100 bytes" {
    const longest: [max_label_bytes]u8 = @splat('x');
    const overlong: [max_label_bytes + 1]u8 = @splat('x');
    try std.testing.expect(validLabel("Review PR 412") and validLabel(&longest) and validLabel("Café"));
    for ([_][]const u8{ "", " \t", "one\ntwo", "one\u{2028}two", "\xff", &overlong }) |invalid|
        try std.testing.expect(!validLabel(invalid));
}

test "saved call descriptions allow 200 bytes without widening Labels" {
    const longest: [200]u8 = @splat('x');
    const overlong: [201]u8 = @splat('x');
    try std.testing.expect(ToolPresentation.validDescription(&longest));
    try std.testing.expect(!ToolPresentation.validDescription(&overlong));
    try std.testing.expect(!validLabel(&longest));
    for ([_][]const u8{ "", " \t", "one\ntwo", "one\rtwo", "one\u{85}two", "one\u{2028}two", "one\u{2029}two", "\xff" }) |invalid|
        try std.testing.expect(!ToolPresentation.validDescription(invalid));
}
