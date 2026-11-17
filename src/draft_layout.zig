const std = @import("std");

pub const max_rows = 10;

pub const FixedBottom = struct {
    footer_rows: u16,
    rule: ?u16,

    pub fn rows(self: FixedBottom) u16 {
        return self.footer_rows + @intFromBool(self.rule != null);
    }
};

pub fn fixedBottom(height: u16) FixedBottom {
    const footer_rows = @min(1, height -| 1);
    return .{ .footer_rows = footer_rows, .rule = if (height >= 2) height - footer_rows - 1 else null };
}

pub fn cap(height: u16) u16 {
    return @max(1, @min(max_rows, height / 3));
}

pub const Marks = struct { up: []const u8, down: []const u8, dot: []const u8 };

pub fn label(buffer: *[64]u8, above: usize, below: usize, marks: Marks) []const u8 {
    return (if (above == 0 and below == 0) "" else if (below == 0)
        std.fmt.bufPrint(buffer, " {s} {d} more {s} ", .{ marks.up, above, if (above == 1) "line" else "lines" })
    else if (above == 0)
        std.fmt.bufPrint(buffer, " {s} {d} more {s} ", .{ marks.down, below, if (below == 1) "line" else "lines" })
    else
        std.fmt.bufPrint(buffer, " {s} {d} {s} {s} {d} more lines ", .{ marks.up, above, marks.dot, marks.down, below })) catch unreachable;
}

pub fn labelColumn(label_cells: usize, cells: usize) ?usize {
    if (label_cells == 0 or label_cells + 4 > cells) return null;
    return (cells - label_cells) / 2;
}

test "the rule label names what the view hides and centres where it fits" {
    var buffer: [64]u8 = undefined;
    const marks: Marks = .{ .up = "^", .down = "v", .dot = "-" };
    const cases = [_]struct { above: usize, below: usize, text: []const u8 }{
        .{ .above = 0, .below = 0, .text = "" },
        .{ .above = 1, .below = 0, .text = " ^ 1 more line " },
        .{ .above = 3, .below = 0, .text = " ^ 3 more lines " },
        .{ .above = 0, .below = 1, .text = " v 1 more line " },
        .{ .above = 4, .below = 1, .text = " ^ 4 - v 1 more lines " },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.text, label(&buffer, case.above, case.below, marks));
    try std.testing.expectEqual(@as(?usize, 12), labelColumn(16, 40));
    try std.testing.expectEqual(@as(?usize, 2), labelColumn(16, 20));
    try std.testing.expectEqual(@as(?usize, null), labelColumn(16, 19));
    try std.testing.expectEqual(@as(?usize, null), labelColumn(0, 40));
}

test "the cap is ten rows, a third of a short screen, and at least one" {
    const cases = [_][2]u16{ .{ 2, 1 }, .{ 3, 1 }, .{ 8, 2 }, .{ 24, 8 }, .{ 30, 10 }, .{ 60, 10 } };
    for (cases) |case| try std.testing.expectEqual(case[1], cap(case[0]));
}

test "fixed input bottom keeps one footer below its rule across every height" {
    for (0..65536) |height| {
        const bottom = fixedBottom(@intCast(height));
        try std.testing.expectEqual(@as(u16, if (height >= 2) 1 else 0), bottom.footer_rows);
        try std.testing.expectEqual(@as(?u16, if (height >= 2) @intCast(height - 2) else null), bottom.rule);
        try std.testing.expectEqual(@as(u16, if (height >= 2) 2 else 0), bottom.rows());
    }
}
