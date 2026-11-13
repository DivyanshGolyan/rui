//! The approval-style input choice: one prompt and padded labels. Reverse
//! marks the selection; a pointer's label takes the quieter hover look. No
//! colour-specific label syntax.
const std = @import("std");
const vaxis = @import("vaxis");
const Hover = @import("widgets/Hover.zig");

/// How one label is drawn. The selection wins over the pointer.
pub const Look = enum { plain, hovered, selected };

const prompt_text = " ›";
/// Cells the prompt takes; a caller aligns content after it by this.
pub const prompt_cells = 2;
const pad = " ";
const gap = "  ";

/// Where one label is drawn on the row, its padding included.
pub const Span = struct { col: u16, width: u16 };

/// Where `segments` draws each label, from the row's first cell. Labels are
/// ASCII, so a byte is a cell.
pub fn spans(labels: [2][]const u8, prompt: bool) [2]Span {
    const first: Span = .{ .col = if (prompt) prompt_cells else 0, .width = @intCast(pad.len + labels[0].len + pad.len) };
    return .{ first, .{ .col = first.col + first.width + @as(u16, gap.len), .width = @intCast(pad.len + labels[1].len + pad.len) } };
}

/// Borrows labels through drawing. The caller places the row, decides
/// whether its narrow layout has room for the prompt, and says each label's
/// look. Of `hover` only its background, reverse and underline apply.
pub fn segments(labels: [2][]const u8, looks: [2]Look, style: vaxis.Style, hover: vaxis.Style, prompt: bool) [8]vaxis.Cell.Segment {
    const first = labelStyle(looks[0], style, hover);
    const second = labelStyle(looks[1], style, hover);
    return .{
        .{ .text = if (prompt) prompt_text else "", .style = style },
        .{ .text = pad, .style = first },
        .{ .text = labels[0], .style = first },
        .{ .text = pad, .style = first },
        .{ .text = gap, .style = style },
        .{ .text = pad, .style = second },
        .{ .text = labels[1], .style = second },
        .{ .text = pad, .style = second },
    };
}

fn labelStyle(look: Look, style: vaxis.Style, hover: vaxis.Style) vaxis.Style {
    return switch (look) {
        .plain => style,
        .selected => selected: {
            var drawn = style;
            drawn.reverse = true;
            break :selected drawn;
        },
        .hovered => Hover.look(style, hover),
    };
}

test "Choice row preserves the approval labels and draws each label plain, hovered or selected" {
    const hovers = [_]vaxis.Style{ .{ .ul_style = .single }, .{ .bg = .{ .index = 5 } } };
    for ([_]bool{ false, true }) |prompt| for (std.enums.values(Look)) |first| for (std.enums.values(Look)) |second| {
        for ([_]vaxis.Style{ .{}, .{ .fg = .{ .rgb = .{ 20, 40, 60 } }, .bg = .{ .rgb = .{ 80, 100, 120 } } } }) |style| for (hovers) |hover| {
            const row = segments(.{ "Allow once", "Deny" }, .{ first, second }, style, hover, prompt);
            var bytes: [64]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            for (row, 0..) |segment, index| {
                try writer.writeAll(segment.text);
                const look: Look = if (index >= 1 and index <= 3) first else if (index >= 5) second else .plain;
                // The foreground always stays the row's.
                try std.testing.expectEqual(style.fg, segment.style.fg);
                switch (look) {
                    .plain => try std.testing.expectEqual(style, segment.style),
                    .selected => {
                        try std.testing.expect(segment.style.reverse);
                        try std.testing.expectEqual(style.bg, segment.style.bg);
                        try std.testing.expectEqual(style.ul_style, segment.style.ul_style);
                    },
                    .hovered => {
                        try std.testing.expectEqual(hover.reverse, segment.style.reverse);
                        try std.testing.expectEqual(hover.bg, segment.style.bg);
                        try std.testing.expectEqual(hover.ul_style, segment.style.ul_style);
                    },
                }
            }
            try std.testing.expectEqualStrings(if (prompt) " › Allow once    Deny " else " Allow once    Deny ", writer.buffered());
            // Each span covers exactly its padded label in the drawn row.
            const drawn = writer.buffered();
            const offset: usize = if (prompt) prompt_text.len - prompt_cells else 0;
            for (spans(.{ "Allow once", "Deny" }, prompt), [_][]const u8{ " Allow once ", " Deny " }) |span, label| {
                try std.testing.expectEqualStrings(label, drawn[span.col + offset ..][0..span.width]);
            }
        };
    };
}
