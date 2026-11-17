//! Shared content bounds for list rows. Tint and hit targets retain the full row.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const left: u16 = 2;
pub const right: u16 = 2;

pub const Bounds = struct {
    start: u16,
    end: u16,

    pub fn width(self: Bounds) u16 {
        return self.end - self.start;
    }
};

pub fn bounds(width: u16) Bounds {
    const end = width -| right;
    return .{ .start = @min(left, end), .end = end };
}

pub fn contentWidth(width: u16) u16 {
    return bounds(width).width();
}

/// Paint an unwrapped rich line into an already-filled full-width row.
pub fn draw(ctx: vxfw.DrawContext, surface: vxfw.Surface, y: u16, line: []const vaxis.Segment, base: vaxis.Style) std.mem.Allocator.Error!void {
    const b = bounds(surface.size.width);
    if (b.width() == 0) return;
    var label: vxfw.RichText = .{ .text = line, .base_style = base, .width_basis = .parent, .softwrap = false };
    const drawn = try label.widget().draw(ctx.withConstraints(.{}, .{ .width = b.width(), .height = 1 }));
    if (drawn.size.height == 0) return;
    const row = surface.buffer[@as(usize, y) * surface.size.width ..][0..surface.size.width];
    @memcpy(row[b.start..b.end], drawn.buffer[0..b.width()]);
    // Carry the line's edge styles into padding, including quiet-row dimming.
    for (row[0..b.start]) |*cell| cell.style = row[b.start].style;
    for (row[b.end..]) |*cell| cell.style = row[b.end - 1].style;
}
