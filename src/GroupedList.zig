//! Shared virtual list for Session groups and model choices. The screen's
//! core selects rows and skips headings; ListView owns scrolling only.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

pub const Row = struct {
    text: []const u8,
    heading: bool = false,
};

rows: []Row = &.{},
selected: ?u32 = null,
body: vaxis.Style = .{},
heading: vaxis.Style = .{ .bold = true },
selection: vaxis.Style = .{ .reverse = true },
list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false },

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    // ListView's j/k, Ctrl-P/N and Esc must never steal composer input.
    if (input == .mouse) try self.list.handleEvent(ctx, input);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.selected) |selected| {
        std.debug.assert(selected < self.rows.len and !self.rows[selected].heading);
    }
    const cursor = self.selected orelse 0;
    const count: u32 = @intCast(self.rows.len);
    const changed = self.list.item_count != count or self.list.cursor != cursor;
    const labels = try ctx.arena.alloc(vxfw.Text, self.rows.len);
    const children = try ctx.arena.alloc(vxfw.Widget, self.rows.len);
    for (self.rows, labels, children, 0..) |row, *label, *child, index| {
        label.* = .{
            .text = try ctx.arena.dupe(u8, row.text),
            .style = if (row.heading) self.heading else if (self.selected != null and self.selected.? == index) self.selection else self.body,
            .width_basis = .parent,
            .softwrap = false,
        };
        child.* = label.widget();
    }
    self.list.children = .{ .slice = children };
    defer self.list.children = .{ .slice = &.{} };
    self.list.item_count = count;
    self.list.cursor = cursor;
    if (changed) self.list.ensureScroll();
    var surface = try self.list.draw(ctx);
    surface.widget = self.widget();
    return surface;
}

test "GroupedList keeps a selected item visible while its keys stay with the composer" {
    var rows = [_]Row{
        .{ .text = "Needs you", .heading = true },
        .{ .text = "Approve a tool" },
        .{ .text = "Active", .heading = true },
        .{ .text = "First task" },
        .{ .text = "Last task" },
    };
    var list: Self = .{ .rows = &rows, .selected = 4 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    var visible = false;
    for (surface.children) |child| {
        if (child.origin.row >= surface.size.height or child.origin.row < 0) continue;
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "L")) {
            visible = true;
            try std.testing.expectEqualStrings("L", child.surface.readCell(0, 0).char.grapheme);
            try std.testing.expect(child.surface.readCell(0, 0).style.reverse);
        }
    }
    try std.testing.expect(visible);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]vaxis.Key{
        .{ .codepoint = 'j' },                            .{ .codepoint = 'k' },              .{ .codepoint = 'p', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'n', .mods = .{ .ctrl = true } }, .{ .codepoint = vaxis.Key.escape },
    }) |key| {
        try list.widget().handleEvent(&events, .{ .key_press = key });
        try std.testing.expect(!events.consume_event);
        try std.testing.expectEqual(@as(?u32, 4), list.selected);
    }
    list.selected = 1;
    const first = try list.widget().draw(ctx);
    try std.testing.expect(first.children.len > 0);
    var returned = false;
    for (first.children) |child| {
        if (child.origin.row >= first.size.height or child.origin.row < 0) continue;
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "N")) try std.testing.expect(!child.surface.readCell(0, 0).style.reverse);
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "A") and std.mem.eql(u8, child.surface.readCell(1, 0).char.grapheme, "p")) {
            returned = true;
            try std.testing.expectEqualStrings("A", child.surface.readCell(0, 0).char.grapheme);
            try std.testing.expect(child.surface.readCell(0, 0).style.reverse);
        }
    }
    try std.testing.expect(returned);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const resized = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(resized.size.width <= size.width and resized.size.height <= size.height);
        try std.testing.expectEqual(@as(?u32, 1), list.selected);
    }
    const restored = try list.widget().draw(ctx);
    returned = false;
    for (restored.children) |child| {
        if (child.origin.row >= restored.size.height or child.origin.row < 0) continue;
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "A") and std.mem.eql(u8, child.surface.readCell(1, 0).char.grapheme, "p")) returned = true;
    }
    try std.testing.expect(returned);
    list.rows = &.{};
    list.selected = null;
    const empty = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), empty.children.len);
}

test "GroupedList retains frame children when row data refreshes before a mouse event" {
    var text = "Before".*;
    var rows = [_]Row{.{ .text = &text }};
    var replacement = [_]Row{.{ .text = "After" }};
    var list: Self = .{ .rows = &rows };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} };
    const before = try list.widget().draw(ctx);
    list.rows = &replacement;
    @memset(&text, 'X');
    rows[0] = .{ .text = "Recycled" };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try before.children[0].surface.widget.handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = .left, .type = .press, .mods = .{} } });
    const retained = try before.children[0].surface.widget.draw(ctx);
    try std.testing.expectEqualStrings("B", retained.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("B", before.children[0].surface.readCell(0, 0).char.grapheme);
    const after = try list.widget().draw(ctx);
    try std.testing.expectEqualStrings("A", after.children[0].surface.readCell(0, 0).char.grapheme);
}
