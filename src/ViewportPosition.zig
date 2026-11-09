//! A row in retained text: its logical line's byte offset and wrapped row.
const std = @import("std");
const Self = @This();

offset: usize = 0,
row: u16 = 0,

/// Past every row; a view that has shown this far has shown everything.
pub const end: Self = .{ .offset = std.math.maxInt(usize) };

pub fn order(a: Self, b: Self) std.math.Order {
    const lines = std.math.order(a.offset, b.offset);
    return if (lines != .eq) lines else std.math.order(a.row, b.row);
}

pub fn min(a: Self, b: Self) Self {
    return if (a.order(b) == .gt) b else a;
}
