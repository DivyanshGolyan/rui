//! The slash-command overlay. The screen owns its draft and completion;
//! the same Shown value supplies both these rows and the screen's key policy.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("slash_commands.zig");
const Self = @This();
const Hover = @import("widgets/Hover.zig");

shown: *commands.Shown,
method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},
quiet: vaxis.Style = .{ .dim = true },
/// The pointer's row: only its background, reverse and underline apply, and the highlighted
/// row keeps its reverse under the pointer.
hover_style: vaxis.Style = .{ .ul_style = .single },
userdata: ?*anyopaque = null,
/// Receives the pressed row as the latest frame drew it: its absolute entry
/// index and that frame's list identity. The screen's owner decides what it
/// does; the list may have changed since.
on_select: ?*const fn (*anyopaque, *vxfw.EventContext, commands.Shown.Pick) anyerror!void = null,
hover: Hover = .{},
first: usize = 0,
/// The list identity the latest frame drew, which a press names.
drawn: commands.Shown.Pick = .{ .index = 0, .revision = 0, .source = 0 },

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    if (input != .mouse) return;
    // Never let a click through to a covered transcript or Session row.
    ctx.consumeEvent();
    if (self.shown.seen != .drawn) return;
    switch (input.mouse.button) {
        .left => if (input.mouse.type == .press) {
            const callback = self.on_select orelse return;
            for (self.hover.targets, 0..) |rect, index| {
                if (rect.contains(input.mouse.col, input.mouse.row)) {
                    var pressed = self.drawn;
                    pressed.index = self.first + index;
                    return callback(self.userdata.?, ctx, pressed);
                }
            }
        },
        .wheel_up, .wheel_down => {
            self.shown.move(input.mouse.button == .wheel_down);
            ctx.redraw = true;
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const height: u16 = @intCast(@min(self.shown.rows(), ctx.max.height.?));
    const width = ctx.max.width.?;
    self.hover.targets = &.{};
    self.shown.drew(width > 2 and height != 0);
    if (self.shown.seen != .drawn) return .empty(self.widget());
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = self.method, .buf = surface.buffer };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
    const list = &self.shown.list;
    const count = commands.named(list.count, height);
    const first = list.firstShown(self.shown.highlight, height);
    self.first = first;
    self.drawn = self.shown.pick(first);
    const targets = try ctx.arena.alloc(Hover.Rect, if (self.on_select != null) count else 0);
    for (targets, 0..) |*rect, index| rect.* = .{ .row = @intCast(index), .width = width };
    self.hover.targets = targets;
    const column = list.descriptionColumn();
    for (list.shown()[first..][0..count], first..) |entry, index| {
        var style = self.style;
        const row: u16 = @intCast(index - first);
        const hovered = index != self.shown.highlight and self.on_select != null and self.hover.contains(.{ .row = row, .width = width });
        style.reverse = index == self.shown.highlight;
        if (hovered) hovering(&style, self.hover_style);
        if (style.reverse or hovered) @memset(surface.buffer[@as(usize, row) * width ..][0..width], .{ .style = style });
        const line = window.child(.{ .y_off = row, .height = 1 });
        _ = line.printSegment(.{ .text = entry.shown, .style = style }, .{ .wrap = .none });
        if (column < width) {
            var description = self.quiet;
            description.reverse = style.reverse;
            if (hovered) hovering(&description, self.hover_style);
            _ = line.child(.{ .x_off = @intCast(column) }).printSegment(.{ .text = entry.description, .style = description }, .{ .wrap = .none });
        }
    }
    if (count < list.count and count < height) {
        const label = try std.fmt.allocPrint(ctx.arena, commands.more, .{list.count - count});
        _ = window.child(.{ .y_off = @intCast(count), .height = 1 }).printSegment(.{ .text = label, .style = self.quiet }, .{ .wrap = .none });
    }
    return surface;
}

fn hovering(style: *vaxis.Style, hover: vaxis.Style) void {
    style.bg = hover.bg;
    style.reverse = hover.reverse;
    style.ul_style = hover.ul_style;
}

test "Palette keeps the selected command visible at one row and hides closed or clipped choices" {
    var shown = commands.Shown.next(null, 7, commands.conversation.suggest("/", .{})).?;
    shown.highlight = shown.list.count - 1;
    var palette: Self = .{ .shown = &shown };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} };
    const surface = try palette.widget().draw(ctx);
    try std.testing.expectEqual(.drawn, shown.seen);
    try std.testing.expectEqual(@as(u16, 1), surface.size.height);
    try std.testing.expect(surface.readCell(0, 0).style.reverse);
    var text: [80]u8 = undefined;
    var used: usize = 0;
    for (surface.buffer) |cell| {
        if (cell.char.grapheme.len == 0) continue;
        @memcpy(text[used..][0..cell.char.grapheme.len], cell.char.grapheme);
        used += cell.char.grapheme.len;
    }
    try std.testing.expect(std.mem.startsWith(u8, text[0..used], shown.list.entries[shown.highlight].shown));
    const clipped = try palette.widget().draw(ctx.withConstraints(.{}, .{ .width = 2, .height = 1 }));
    try std.testing.expectEqual(@as(usize, 0), clipped.buffer.len);
    try std.testing.expectEqual(.hidden, shown.seen);
    shown.close();
    const closed = try palette.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), closed.buffer.len);
    try std.testing.expectEqual(.closed, shown.seen);
}

test "Palette hover is transient and clicks activate only visible command rows" {
    const Selected = struct {
        index: ?usize = null,
        revision: ?u64 = null,
        fn select(raw: *anyopaque, _: *vxfw.EventContext, pressed: commands.Shown.Pick) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.index = pressed.index;
            self.revision = pressed.revision;
        }
    };
    var selected: Selected = .{};
    var shown = commands.Shown.next(null, 7, commands.conversation.suggest("/", .{})).?;
    var palette: Self = .{ .shown = &shown, .userdata = &selected, .on_select = Selected.select, .style = .{ .fg = .{ .index = 3 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 3 }, .cell_size = .{} };
    const initial = try palette.widget().draw(draw_ctx);
    try std.testing.expect(!initial.readCell(0, 1).style.reverse);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try palette.widget().handleEvent(&ctx, .mouse_enter);
    const motion: vaxis.Mouse = .{ .row = 1, .col = 0, .button = .none, .mods = .{}, .type = .motion };
    try palette.widget().handleEvent(&ctx, .{ .mouse = motion });
    const hovered = try palette.widget().draw(draw_ctx);
    // Hover takes the quieter look; the keyboard's row keeps its reverse.
    try std.testing.expect(!hovered.readCell(0, 1).style.reverse);
    try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.readCell(0, 1).style.ul_style);
    try std.testing.expect(hovered.readCell(0, 0).style.reverse);
    try std.testing.expectEqual(palette.style.fg, hovered.readCell(0, 1).style.fg);
    palette.hover_style = .{ .bg = .{ .index = 5 } };
    const coloured = try palette.widget().draw(draw_ctx);
    for (0..80) |col| try std.testing.expectEqual(vaxis.Color{ .index = 5 }, coloured.readCell(@intCast(col), 1).style.bg);
    try std.testing.expect(coloured.readCell(0, 0).style.reverse);
    try std.testing.expectEqual(@as(usize, 0), shown.highlight);
    try std.testing.expect(selected.index == null);
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
    var press = motion;
    press.button = .left;
    press.type = .press;
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expectEqual(@as(?usize, 1), selected.index);
    // A press names the list the frame drew, not one stored since.
    shown.revision = 8;
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expectEqual(@as(?u64, 7), selected.revision);
    shown.revision = 7;
    try palette.widget().handleEvent(&ctx, .mouse_leave);
    const left = try palette.widget().draw(draw_ctx);
    try std.testing.expectEqual(initial.readCell(0, 1).style, left.readCell(0, 1).style);
    try std.testing.expectEqual(vaxis.Mouse.Shape.default, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
    // One-row viewport maps to the selected absolute index, not row zero.
    shown.highlight = shown.list.count - 1;
    _ = try palette.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 80, .height = 1 }));
    press.row = 0;
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expectEqual(@as(?usize, shown.highlight), selected.index);
    // Closed, clipped, and callback-free overlays expose no targets.
    selected.index = null;
    _ = try palette.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 2, .height = 1 }));
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expect(selected.index == null);
    palette.on_select = null;
    _ = try palette.widget().draw(draw_ctx);
    try std.testing.expectEqual(@as(usize, 0), palette.hover.targets.len);
    shown.close();
    _ = try palette.widget().draw(draw_ctx);
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expect(selected.index == null);
}

test "Palette renders names-only slash lists on conversation and overview" {
    const cases = .{
        .{ commands.conversation, &[_][]const u8{ "/archive", "/configure", "/copy           code · file", "/effort", "/model", "/reload-skills", "/rename", "/setup", "/status", "/unarchive" } },
        .{ commands.overview, &[_][]const u8{ "/archive", "/configure", "/model", "/rename", "/sessions   unarchived · archived · all", "/setup", "/unarchive" } },
    };
    inline for (cases) |case| {
        var shown = commands.Shown.next(null, 1, case[0].suggest("/", .{})).?;
        var palette: Self = .{ .shown = &shown };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
        const surface = try palette.widget().draw(ctx);
        try std.testing.expectEqual(case[1].len, surface.size.height);
        std.debug.print("\n{s} / list:\n", .{if (case[0] == commands.conversation) "Conversation" else "Overview"});
        for (case[1], 0..) |expected, row| {
            var text: [256]u8 = undefined;
            var used: usize = 0;
            for (surface.buffer[row * 80 ..][0..80]) |cell| {
                @memcpy(text[used..][0..cell.char.grapheme.len], cell.char.grapheme);
                used += cell.char.grapheme.len;
            }
            const line = std.mem.trimEnd(u8, text[0..used], " ");
            try std.testing.expectEqualStrings(expected, line);
            std.debug.print("{s}\n", .{line});
            if (std.mem.indexOf(u8, expected, " · ") != null) {
                try std.testing.expect(!surface.readCell(0, @intCast(row)).style.dim);
                try std.testing.expect(surface.readCell(@intCast(shown.list.descriptionColumn()), @intCast(row)).style.dim);
            }
        }
    }
}
