//! A dialog above the screen: content laid on the raised ground, centred, and with room a card
//! whose stitched edge sits one cell inside a margin of that ground (DESIGN.md §8). Root fades
//! the covered screen onto the darker scrim beneath it. Sign-in and Settings both open as one.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");

/// The widest a dialog's content grows.
pub const max_width: u16 = 72;
/// Narrower or shorter screens give the dialog every cell, so codes and links keep their width.
pub const min_framed: vxfw.Size = .{ .width = 40, .height = 10 };
/// From the card's outer edge to its content: one cell of margin, the stitch, then on the
/// sides one column of ground.
pub const inset: vxfw.Size = .{ .width = 3, .height = 2 };

/// The dialog's palette: every cell of it (title, rule, stitch, text) carries the raised ground.
pub const Look = struct {
    ground: vaxis.Style,
    quiet: vaxis.Style,
    selection: vaxis.Style,
    hover: vaxis.Style,
    title: vaxis.Style,
    caps: view.Caps,

    pub fn of(caps: view.Caps) Look {
        const style = widget_style.of;
        return .{
            .ground = style(caps, .{ .background = .raised }),
            .quiet = style(caps, .{ .colour = .quiet, .background = .raised }),
            .selection = style(caps, .{ .background = .selection }),
            .hover = style(caps, .{ .background = .hover }),
            .title = style(caps, .{ .colour = .strong, .background = .raised, .bold = true }),
            .caps = caps,
        };
    }

    /// The running stitch in the thread colour, on the raised ground.
    pub fn stitch(self: Look, which: widget_style.Line) vaxis.Cell {
        return @import("widgets/Stitch.zig").cell(self.caps.unicode, which, widget_style.of(self.caps, .{ .colour = .rule, .background = .raised }));
    }
};

pub fn framed(size: vxfw.Size) bool {
    return size.width >= min_framed.width and size.height >= min_framed.height;
}

/// The bound a dialog's content may fill on a screen of `size`.
pub fn bound(size: vxfw.Size) vxfw.Size {
    const frame: vxfw.Size = if (framed(size)) .{ .width = 2 * inset.width, .height = 2 * inset.height } else .{};
    return .{ .width = @min(size.width - frame.width, max_width), .height = size.height - frame.height };
}

/// Where content of `content` size sits, centred on a screen of `size`.
pub fn origin(size: vxfw.Size, content: vxfw.Size) vxfw.RelativePoint {
    return .{ .row = @intCast((size.height - content.height) / 2), .col = @intCast((size.width - content.width) / 2) };
}

/// The screen-sized layer for drawn `content`: centred above the card when framed; otherwise
/// on a cover of the raised ground, so no covered text sits beside the dialog's rows. `owner`
/// owns the layer, so every click on the screen lands on the dialog.
pub fn lay(ctx: vxfw.DrawContext, owner: vxfw.Widget, look: Look, content: vxfw.Surface, size: vxfw.Size) std.mem.Allocator.Error!vxfw.Surface {
    const at = origin(size, content.size);
    const children = try ctx.arena.alloc(vxfw.SubSurface, if (framed(size)) 2 else 1);
    // The card lies beneath the content by z index (rendering sorts by it).
    children[0] = .{ .origin = at, .surface = content, .z_index = 1 };
    if (framed(size)) {
        children[1] = .{ .origin = .{ .row = at.row - inset.height, .col = at.col - inset.width }, .surface = try card(ctx, owner, look, content.size) };
        return .{ .size = size, .widget = owner, .buffer = &.{}, .children = children };
    }
    var cover = try vxfw.Surface.init(ctx.cell_arena, owner, size);
    @memset(cover.buffer, .{ .style = look.ground });
    cover.children = children;
    return cover;
}

/// The card under content of `content` size: a margin of ground, then the running stitch on
/// top and bottom and its upright at the sides, then one column of ground before content.
fn card(ctx: vxfw.DrawContext, owner: vxfw.Widget, look: Look, content: vxfw.Size) std.mem.Allocator.Error!vxfw.Surface {
    const size: vxfw.Size = .{ .width = content.width + 2 * inset.width, .height = content.height + 2 * inset.height };
    var surface = try vxfw.Surface.init(ctx.cell_arena, owner, size);
    @memset(surface.buffer, .{ .style = look.ground });
    const across = look.stitch(.horizontal);
    const upright = look.stitch(.vertical);
    for (1..size.width - 1) |col| {
        surface.writeCell(@intCast(col), 1, across);
        surface.writeCell(@intCast(col), size.height - 2, across);
    }
    for (2..size.height - 2) |row| {
        surface.writeCell(1, @intCast(row), upright);
        surface.writeCell(size.width - 2, @intCast(row), upright);
    }
    return surface;
}

test "A dialog lays its content centred above a stitched card when framed, and on a raised cover otherwise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blank: vxfw.Text = .{ .text = "" };
    for ([_]bool{ false, true }) |unicode| for ([_]u16{ 1, 20, 39, 40, 80, 200 }) |width| for ([_]u16{ 1, 9, 10, 24 }) |height| {
        const size: vxfw.Size = .{ .width = width, .height = height };
        const look: Look = .of(.{ .unicode = unicode });
        const fit = bound(size);
        try std.testing.expect(fit.width <= max_width and fit.width <= width and fit.height <= height);
        const content = try vxfw.Surface.init(a, blank.widget(), .{ .width = fit.width, .height = @min(fit.height, 5) });
        const layer = try lay(.{ .arena = a, .cell_arena = a, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} }, blank.widget(), look, content, size);
        try std.testing.expectEqual(size, layer.size);
        try std.testing.expectEqual(origin(size, content.size), layer.children[0].origin);
        if (!framed(size)) {
            try std.testing.expectEqual(@as(usize, 1), layer.children.len);
            for (layer.buffer) |cell| try std.testing.expect(cell.style.eql(look.ground));
            continue;
        }
        try std.testing.expectEqual(@as(usize, 0), layer.buffer.len);
        const edge = layer.children[1];
        try std.testing.expect(edge.z_index < layer.children[0].z_index);
        try std.testing.expect(edge.origin.row >= 0 and edge.origin.col >= 0);
        try std.testing.expect(edge.origin.row + edge.surface.size.height <= height and edge.origin.col + edge.surface.size.width <= width);
        const w = edge.surface.size.width;
        try std.testing.expectEqualStrings(if (unicode) "┄" else "-", edge.surface.readCell(1, 1).char.grapheme);
        try std.testing.expectEqualStrings(if (unicode) "┆" else "|", edge.surface.readCell(w - 2, 2).char.grapheme);
        for (edge.surface.buffer) |cell| try std.testing.expect(cell.style.bg.eql(look.ground.bg));
    };
}
