//! Shared virtual list for Session groups and model choices. The screen's
//! core selects rows and skips headings; ListView owns scrolling only.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

pub const Row = struct {
    label: vxfw.Text,
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

fn build(raw: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Self = @ptrCast(@alignCast(raw));
    if (index >= self.rows.len) return null;
    const row = &self.rows[index];
    row.label.style = if (row.heading) self.heading else if (self.selected != null and self.selected.? == index) self.selection else self.body;
    row.label.width_basis = .parent;
    row.label.softwrap = false;
    return row.label.widget();
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.selected) |selected| {
        std.debug.assert(selected < self.rows.len and !self.rows[selected].heading);
    }
    const cursor = self.selected orelse 0;
    const count: u32 = @intCast(self.rows.len);
    const changed = self.list.item_count != count or self.list.cursor != cursor;
    self.list.children = .{ .builder = .{ .userdata = self, .buildFn = build } };
    self.list.item_count = count;
    self.list.cursor = cursor;
    if (changed) self.list.ensureScroll();
    var surface = try self.list.draw(ctx);
    surface.widget = self.widget();
    return surface;
}

test "GroupedList keeps a selected item visible while its keys stay with the composer" {
    var rows = [_]Row{
        .{ .label = .{ .text = "Needs you" }, .heading = true },
        .{ .label = .{ .text = "Approve a tool" } },
        .{ .label = .{ .text = "Active" }, .heading = true },
        .{ .label = .{ .text = "First task" } },
        .{ .label = .{ .text = "Last task" } },
    };
    var list: Self = .{ .rows = &rows, .selected = 4 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    var visible = false;
    for (surface.children) |child| {
        if (child.origin.row >= surface.size.height or child.origin.row < 0) continue;
        if (child.surface.widget.eql(rows[4].label.widget())) {
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
    try std.testing.expect(!rows[0].label.style.reverse);
    var returned = false;
    for (first.children) |child| {
        if (child.origin.row >= first.size.height or child.origin.row < 0) continue;
        if (child.surface.widget.eql(rows[1].label.widget())) {
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
        if (child.surface.widget.eql(rows[1].label.widget())) returned = true;
    }
    try std.testing.expect(returned);
    list.rows = &.{};
    list.selected = null;
    const empty = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), empty.children.len);
}
