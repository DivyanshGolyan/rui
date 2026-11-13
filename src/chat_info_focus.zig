//! Chat info's drawn focus order. Facts-only rows are not keyboard stops.
const std = @import("std");

pub const Focus = enum(usize) { effort = 0, permissions = 1, tools = 2, model = 4, rename = 6, archive = 7, copy = 8 };
pub const Move = enum { up, down, left, right, next, previous };
const order = std.enums.values(Focus);

pub fn step(focus: Focus, move: Move) Focus {
    const at = std.mem.indexOfScalar(Focus, order, focus).?;
    return switch (move) {
        .next => order[(at + 1) % order.len],
        .previous => order[(at + order.len - 1) % order.len],
        .left => if (at >= 4) order[@max(at - 1, 4)] else focus,
        .right => if (at >= 4) order[@min(at + 1, order.len - 1)] else focus,
        .up => order[if (at >= 4) 3 else at -| 1],
        .down => if (at < 4) order[at + 1] else focus,
    };
}

test "Chat info focus domain follows rows horizontally clamped actions and wrapping tabs" {
    const expected = [_][6]Focus{
        .{ .effort, .permissions, .effort, .effort, .permissions, .copy },
        .{ .effort, .tools, .permissions, .permissions, .tools, .effort },
        .{ .permissions, .model, .tools, .tools, .model, .permissions },
        .{ .tools, .rename, .model, .model, .rename, .tools },
        .{ .model, .rename, .rename, .archive, .archive, .model },
        .{ .model, .archive, .rename, .copy, .copy, .rename },
        .{ .model, .copy, .archive, .copy, .effort, .archive },
    };
    for (order, expected) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(focus, move));
    }
}
