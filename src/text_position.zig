//! A row of laid-out text, which the conversation's views and what a visit
//! has seen of it both name.
const std = @import("std");

/// The logical line starting at byte `offset`, and the row within that
/// line's wrapping.
pub const Position = struct {
    offset: usize = 0,
    row: u16 = 0,
    /// Past every row; a view that has shown this far has shown everything.
    pub const end: Position = .{ .offset = std.math.maxInt(usize) };

    pub fn order(a: Position, b: Position) std.math.Order {
        const lines = std.math.order(a.offset, b.offset);
        return if (lines != .eq) lines else std.math.order(a.row, b.row);
    }

    pub fn min(a: Position, b: Position) Position {
        return if (a.order(b) == .gt) b else a;
    }
};
