//! Shared terminal-cell admission, independent of grids and terminal I/O.
pub const max_cells = 49_152;
pub fn validate(width: u16, height: u16) !void {
    if (width < 8 or height < 2) return error.TerminalTooSmall;
    if (@as(u32, width) * height > max_cells) return error.TerminalTooLarge;
}

test "every supported width admits exactly the capped height and rejects the next" {
    const std = @import("std");
    try std.testing.expectError(error.TerminalTooSmall, validate(7, 2));
    try std.testing.expectError(error.TerminalTooSmall, validate(8, 1));
    for (8..@as(usize, max_cells / 2) + 1) |width| {
        const height = max_cells / width;
        try validate(@intCast(width), @intCast(height));
        try std.testing.expectError(error.TerminalTooLarge, validate(@intCast(width), @intCast(height + 1)));
    }
    try std.testing.expectError(error.TerminalTooLarge, validate(max_cells / 2 + 1, 2));
    try std.testing.expectError(error.TerminalTooLarge, validate(65535, 65535));
}
