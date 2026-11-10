//! Visible rows of the retained conversation. History and reading position
//! remain with the screen; drawing allocates cells only for this viewport.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const viewport = @import("ConversationViewport.zig");
const Self = @This();

document: *const viewport.Document,
first: viewport.Position = .{},
next: viewport.Position = .end,
size: vxfw.Size = .{},
method: vaxis.gwidth.Method = .unicode,
colour: bool = true,
style: vaxis.Style = .{},
/// The key that scrolls this view. When set and the text runs past the
/// view, the last row says how many rows lie below and names the key.
more: ?[]const u8 = null,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    self.size = surface.size;
    const layout: viewport.Layout = .{ .width = @max(1, self.size.width), .method = self.method };
    self.first = self.document.first(layout, self.size.height);
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{
        .width = surface.size.width,
        .height = surface.size.height,
        .width_method = self.method,
        .buf = surface.buffer,
    };
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    const below = if (self.more == null or self.size.height < 2) 0 else self.document.measure(layout, self.first, std.math.maxInt(u16)).rows;
    if (below <= self.size.height) {
        self.next = self.document.draw(window, self.first, true, self.colour, self.style).next;
        return surface;
    }
    var text = window;
    text.height -= 1;
    const drawn = self.document.draw(text, self.first, true, self.colour, self.style);
    self.next = drawn.next;
    var dim = self.style;
    dim.dim = true;
    const hint = try std.fmt.allocPrint(ctx.arena, "{d} more lines · {s}", .{ below - drawn.rows, self.more.? });
    _ = window.child(.{ .y_off = text.height, .height = 1 }).print(&.{.{ .text = hint, .style = dim }}, .{ .wrap = .none });
    return surface;
}

test "Transcript draws only the requested rows and retains the first unread row" {
    const document = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("first\nsecond\nthird\nfourth");
    document.top = .{ .offset = 6 };
    var transcript: Self = .{ .document = document, .style = .{ .bg = .{ .index = 19 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 16), surface.buffer.len);
    try std.testing.expectEqualStrings("s", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("t", surface.readCell(0, 1).char.grapheme);
    try std.testing.expectEqual(viewport.Position{ .offset = 19 }, transcript.next);
    try std.testing.expectEqualStrings("first\nsecond\nthird\nfourth", document.text());
    for (surface.buffer) |cell| try std.testing.expectEqual(vaxis.Color{ .index = 19 }, cell.style.bg);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const resized = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(resized.size.width <= size.width and resized.size.height <= size.height);
        try std.testing.expectEqual(viewport.Position{ .offset = 6 }, document.top.?);
    }
    const restored = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqualDeep(surface.buffer, restored.buffer);
    try std.testing.expectEqual(viewport.Position{ .offset = 19 }, transcript.next);
}
