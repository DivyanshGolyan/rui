const vaxis = @import("vaxis");

pub const Line = enum { horizontal, vertical };

pub fn cell(unicode: bool, which: Line, style: vaxis.Style) vaxis.Cell {
    const glyph = switch (which) {
        .horizontal => if (unicode) "┄" else "-",
        .vertical => if (unicode) "┆" else "|",
    };
    return .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style };
}
