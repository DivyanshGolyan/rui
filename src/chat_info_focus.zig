const std = @import("std");

/// The Chat panel rows that take focus, valued by their row index in the panel.
/// Folder (3) and Context (6) are read-only; `account` appears only while the
/// chat has another account to move to.
pub const Focus = enum(usize) { effort = 0, permissions = 1, tools = 2, model = 4, account = 5, rename = 7, archive = 8, copy = 9 };
pub const Move = enum { up, down, left, right };
pub const Layout = enum { horizontal, stacked };
const with_account = std.enums.values(Focus);
const without_account = blk: {
    var rows: [with_account.len - 1]Focus = undefined;
    var count: usize = 0;
    for (with_account) |row| {
        if (row == .account) continue;
        rows[count] = row;
        count += 1;
    }
    break :blk rows;
};

pub fn step(layout: Layout, accounts: bool, focus: Focus, move: Move) Focus {
    return walk(if (accounts) with_account else &without_account, layout, focus, move);
}

fn walk(order: []const Focus, layout: Layout, focus: Focus, move: Move) Focus {
    const first_action = std.mem.indexOfScalar(Focus, order, .rename).?;
    const at = std.mem.indexOfScalar(Focus, order, focus) orelse return .model;
    return switch (move) {
        .left => if (layout == .horizontal and at >= first_action) order[@max(at - 1, first_action)] else focus,
        .right => if (layout == .horizontal and at >= first_action) order[@min(at + 1, order.len - 1)] else focus,
        .up => order[if (layout == .horizontal and at >= first_action) first_action - 1 else at -| 1],
        .down => if (layout == .stacked or at < first_action) order[@min(at + 1, order.len - 1)] else focus,
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
    for (without_account, expected) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(.horizontal, false, focus, move));
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
    for (without_account, expected) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(.stacked, false, focus, move));
    }
}

test "Chat info focus passes through the Account row only while it is shown" {
    const horizontal = [_][4]Focus{
        .{ .effort, .permissions, .effort, .effort },
        .{ .effort, .tools, .permissions, .permissions },
        .{ .permissions, .model, .tools, .tools },
        .{ .tools, .account, .model, .model },
        .{ .model, .rename, .account, .account },
        .{ .account, .rename, .rename, .archive },
        .{ .account, .archive, .rename, .copy },
        .{ .account, .copy, .archive, .copy },
    };
    for (with_account, horizontal) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(.horizontal, true, focus, move));
    }
    const stacked = [_][4]Focus{
        .{ .effort, .permissions, .effort, .effort },
        .{ .effort, .tools, .permissions, .permissions },
        .{ .permissions, .model, .tools, .tools },
        .{ .tools, .account, .model, .model },
        .{ .model, .rename, .account, .account },
        .{ .account, .archive, .rename, .rename },
        .{ .rename, .copy, .archive, .archive },
        .{ .archive, .copy, .copy, .copy },
    };
    for (with_account, stacked) |focus, row| {
        for (std.enums.values(Move), row) |move, want| try std.testing.expectEqual(want, step(.stacked, true, focus, move));
    }
    // A selection left on a hidden Account row falls back to the Model row.
    for (std.enums.values(Move)) |move| try std.testing.expectEqual(Focus.model, step(.horizontal, false, .account, move));
}
