//! The approval-style input choice: one prompt and padded labels, with only
//! reverse background marking the selection. No colour-specific label syntax.
const std = @import("std");
const vaxis = @import("vaxis");

/// Borrows labels through drawing. The caller places the row, decides
/// whether its narrow layout has room for the prompt, and says which labels
/// are marked: the selected one, and one under the pointer where it hovers.
pub fn segments(labels: [2][]const u8, marked: [2]bool, style: vaxis.Style, prompt: bool) [8]vaxis.Cell.Segment {
    var first = style;
    var second = style;
    first.reverse = marked[0];
    second.reverse = marked[1];
    return .{
        .{ .text = if (prompt) " ›" else "", .style = style },
        .{ .text = " ", .style = first },
        .{ .text = labels[0], .style = first },
        .{ .text = " ", .style = first },
        .{ .text = "  ", .style = style },
        .{ .text = " ", .style = second },
        .{ .text = labels[1], .style = second },
        .{ .text = " ", .style = second },
    };
}

test "Choice row preserves the approval labels and reverses only the marked padded labels" {
    for ([_]bool{ false, true }) |prompt| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } }) |marked| {
            for ([_]vaxis.Style{ .{}, .{ .fg = .{ .rgb = .{ 20, 40, 60 } }, .bg = .{ .rgb = .{ 80, 100, 120 } } } }) |style| {
                const row = segments(.{ "Allow once", "Deny" }, marked, style, prompt);
                var bytes: [64]u8 = undefined;
                var writer = std.Io.Writer.fixed(&bytes);
                for (row, 0..) |segment, index| {
                    try writer.writeAll(segment.text);
                    const highlighted = if (index >= 1 and index <= 3) marked[0] else if (index >= 5) marked[1] else false;
                    try std.testing.expectEqual(highlighted, segment.style.reverse);
                    try std.testing.expectEqual(style.fg, segment.style.fg);
                    try std.testing.expectEqual(style.bg, segment.style.bg);
                }
                try std.testing.expectEqualStrings(if (prompt) " › Allow once    Deny " else " Allow once    Deny ", writer.buffered());
            }
        }
    }
}
