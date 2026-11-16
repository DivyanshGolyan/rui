const std = @import("std");

pub const Focus = enum(usize) { effort = 0, permissions = 1, tools = 2, model = 4, rename = 6, archive = 7, copy = 8 };
pub const Move = enum { up, down, left, right };
pub const Layout = enum { horizontal, stacked };
const order = std.enums.values(Focus);

pub fn step(layout: Layout, focus: Focus, move: Move) Focus {
    const at = std.mem.indexOfScalar(Focus, order, focus).?;
    return switch (move) {
        .left => if (layout == .horizontal and at >= 4) order[@max(at - 1, 4)] else focus,
        .right => if (layout == .horizontal and at >= 4) order[@min(at + 1, order.len - 1)] else focus,
        .up => order[if (layout == .horizontal and at >= 4) 3 else at -| 1],
        .down => if (layout == .stacked or at < 4) order[@min(at + 1, order.len - 1)] else focus,
    };
}

test "Chat info focus domain follows rows horizontally clamped actions without a Tab policy" {
    const expected = [_][4]Focus{
        .{ .effort, .permissions, .effort, .effort },
        .{ .effort, .tools, .permissions, .permissions },
        .{ .permissions, .model, .tools, .tools },
        .{ .tools, .rename, .model, .model },
        .{ .model, .rename, .rename, .archive },
        .{ .model, .archive, .rename, .copy },
        .{ .model, .copy, .archive, .copy },
    };
    for (order, expected) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(.horizontal, focus, move));
    }
}

test "Chat info stacked focus domain follows the drawn vertical action rows" {
    const expected = [_][4]Focus{
        .{ .effort, .permissions, .effort, .effort },
        .{ .effort, .tools, .permissions, .permissions },
        .{ .permissions, .model, .tools, .tools },
        .{ .tools, .rename, .model, .model },
        .{ .model, .archive, .rename, .rename },
        .{ .rename, .copy, .archive, .archive },
        .{ .archive, .copy, .copy, .copy },
    };
    for (order, expected) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(.stacked, focus, move));
    }
}
