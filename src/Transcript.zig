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
quiet: vaxis.Color = .default,
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
        self.next = self.document.draw(window, self.first, true, self.colour, self.style, self.quiet).next;
        return surface;
    }
    var text = window;
    text.height -= 1;
    const drawn = self.document.draw(text, self.first, true, self.colour, self.style, self.quiet);
    self.next = drawn.next;
    var hint_style = self.style;
    hint_style.fg = self.quiet;
    const hint = try std.fmt.allocPrint(ctx.arena, "{d} more lines · {s}", .{ below - drawn.rows, self.more.? });
    _ = window.child(.{ .y_off = text.height, .height = 1 }).print(&.{.{ .text = hint, .style = hint_style }}, .{ .wrap = .none });
    return surface;
}

test "Transcript user text keeps theme contrast without terminal dim" {
    const widget_style = @import("widget_style.zig");
    const view = @import("overview_view.zig");
    const Check = struct {
        fn rgb(c: vaxis.Color) [3]u8 {
            return switch (c) {
                .rgb => |value| value,
                .index => |i| if (i < 232) blk: {
                    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
                    const n: usize = i - 16;
                    break :blk .{ levels[n / 36], levels[n / 6 % 6], levels[n % 6] };
                } else @splat(@intCast(8 + 10 * (@as(u16, i) - 232))),
                else => unreachable,
            };
        }
        fn luminance(c: [3]u8) f64 {
            var total: f64 = 0;
            for (c, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
                const value = @as(f64, @floatFromInt(channel)) / 255;
                total += weight * (if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4));
            }
            return total;
        }
    };
    const document = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("\x1b[2muser text\x1b[0m");
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |background| for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
        const quiet = widget_style.of(.{ .background = background, .depth = depth }, .{ .colour = .quiet });
        const normal = widget_style.of(.{ .background = background, .depth = depth }, .{});
        var transcript: Self = .{ .document = document, .style = normal, .quiet = quiet.fg };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 2 }, .cell_size = .{} });
        const style = surface.readCell(0, 0).style;
        try std.testing.expect(!style.dim);
        try std.testing.expectEqual(quiet.fg, style.fg);
        const fg = Check.luminance(Check.rgb(style.fg));
        const bg = Check.luminance(Check.rgb(style.bg));
        try std.testing.expect((@max(fg, bg) + 0.05) / (@min(fg, bg) + 0.05) >= 4.5);
    };
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
