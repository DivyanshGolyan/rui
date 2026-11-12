//! Canonical opaque Store identity, shared by routing, wire and schema checks.
const std = @import("std");

pub fn valid(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}
