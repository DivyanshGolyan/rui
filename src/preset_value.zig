//! Borrowed preset values and their name policy.
const std = @import("std");
const protocol = @import("protocol.zig");

/// Presets live in their Host settings, never in the Store. The spec's JSON
/// strings and objects are borrowed for the Host's life, not copied per slot.
pub const Preset = struct {
    name: []const u8,
    spec: std.json.ObjectMap,
};
pub const max_presets = 64;
pub const max_preset_name_bytes = protocol.max_preset_name_bytes;

pub fn validPresetName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_preset_name_bytes) return false;
    for (name) |byte| if (!(byte >= 'a' and byte <= 'z') and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') return false;
    return true;
}

test "preset names cover the byte domain and length boundaries" {
    try std.testing.expect(!validPresetName(""));
    try std.testing.expect(validPresetName("review_2-fast"));
    try std.testing.expect(validPresetName(&@as([max_preset_name_bytes]u8, @splat('a'))));
    try std.testing.expect(!validPresetName(&@as([max_preset_name_bytes + 1]u8, @splat('a'))));
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const allowed = (value >= 'a' and value <= 'z') or (value >= '0' and value <= '9') or value == '_' or value == '-';
        try std.testing.expectEqual(allowed, validPresetName(&.{byte}));
        try std.testing.expectEqual(allowed, validPresetName(&.{ 'a', byte, 'z' }));
    }
}
