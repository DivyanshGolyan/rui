//! A bounded field-and-action panel with inline choices. All text, styles and
//! effects belong to its caller; Escape belongs to the enclosing Layer.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();
const Hover = @import("Hover.zig");

pub const Field = struct { label: []const u8, value: []const u8, tail: ?[]const u8 = null };
pub const Choice = struct { field: usize, labels: []const []const u8, current: ?usize, selected: usize };
const Target = struct { row: u16, start: u16, end: u16, index: usize, choice: bool = false };

title: []const u8,
fields: []const Field = &.{},
actions: []const []const u8 = &.{},
selected: usize = 0,
choice: ?Choice = null,
userdata: ?*anyopaque = null,
on_activate: ?*const fn (*anyopaque, *vxfw.EventContext, usize) anyerror!void = null,
on_pick: ?*const fn (*anyopaque, *vxfw.EventContext, usize, usize) anyerror!void = null,
ground: vaxis.Style = .{},
selection: vaxis.Style = .{ .reverse = true },
/// The pointer's field, choice or action, quieter than the selection, which wins where both apply.
hover_style: vaxis.Style = .{ .ul_style = .single },
title_style: vaxis.Style = .{ .bold = true },
quiet: vaxis.Style = .{},
rule_style: vaxis.Style = .{},
scroll: usize = 0,
/// Borrowed from the last draw arena, just like the framework's hit surface.
/// Replaced on every draw; never read outside a mouse event for that frame.
targets: []const Target = &.{},
hover: Hover = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn openChoice(self: *Self, labels: []const []const u8, current: ?usize) void {
    if (self.selected >= self.fields.len or labels.len == 0) return;
    const checked = if (current) |at| if (at < labels.len) current else null else null;
    self.choice = .{ .field = self.selected, .labels = labels, .current = checked, .selected = checked orelse 0 };
}

pub fn closeChoice(self: *Self) void {
    self.choice = null;
}

fn move(self: *Self, down: bool) void {
    const at = if (self.choice) |*choice| &choice.selected else &self.selected;
    const count = if (self.choice) |choice| choice.labels.len else self.fields.len + self.actions.len;
    if (count == 0) return;
    at.* = @min(at.*, count - 1);
    if (down) {
        at.* = @min(at.* + 1, count - 1);
    } else at.* -|= 1;
}

fn activate(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.choice) |choice| {
        self.closeChoice();
        if (self.on_pick) |callback| try callback(self.userdata.?, ctx, choice.field, choice.selected);
    } else if (self.selected < self.fields.len + self.actions.len) {
        if (self.on_activate) |callback| try callback(self.userdata.?, ctx, self.selected);
    }
}

/// The only keys a panel takes; every other key is its caller's.
pub fn takesKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.enter, .{});
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    switch (input) {
        .key_press => |key| {
            if (!takesKey(key)) return;
            if (key.matches(vaxis.Key.enter, .{})) {
                try self.activate(ctx);
            } else self.move(key.matches(vaxis.Key.down, .{}));
            ctx.consumeAndRedraw();
        },
        .mouse => |mouse| {
            switch (mouse.button) {
                .wheel_up => self.move(false),
                .wheel_down => self.move(true),
                .left => {
                    if (mouse.type != .press) return;
                    for (self.targets) |target| {
                        if (mouse.row != target.row or mouse.col < target.start or mouse.col >= target.end) continue;
                        if (target.choice) {
                            if (self.choice) |*choice| choice.selected = target.index else return;
                        } else {
                            self.closeChoice();
                            self.selected = target.index;
                        }
                        try self.activate(ctx);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    return;
                },
                else => return,
            }
            ctx.consumeAndRedraw();
        },
        else => {},
    }
}

fn rowOf(self: *const Self, field: usize) usize {
    return field + if (self.choice) |choice| if (field > choice.field) choice.labels.len else @as(usize, 0) else @as(usize, 0);
}

fn activeRow(self: *const Self) usize {
    if (self.choice) |choice| return choice.field + 1 + choice.selected;
    return self.rowOf(@min(self.selected, self.fields.len));
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.ground });
    self.targets = &.{};
    self.hover.targets = &.{};
    if (size.width == 0 or size.height == 0) return surface;
    for (0..size.width) |col| surface.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.rule_style });
    if (size.height == 1) return surface;
    _ = paint(ctx, surface, self.title, 1, 1, self.title_style);
    if (size.height == 2) return surface;
    const count = self.fields.len + self.actions.len;
    if (count > 0) self.selected = @min(self.selected, count - 1);
    const body_height = size.height - 2;
    const rows = self.fields.len + @intFromBool(self.actions.len > 0) + if (self.choice) |choice| choice.labels.len else @as(usize, 0);
    const active = self.activeRow();
    if (active < self.scroll) self.scroll = active;
    if (active >= self.scroll + body_height) self.scroll = active - body_height + 1;
    self.scroll = @min(self.scroll, rows -| body_height);
    var targets: std.array_list.Managed(Target) = .init(ctx.arena);
    for (self.fields, 0..) |field, index| {
        if (self.visible(self.rowOf(index), size.height)) |row| {
            const selected = self.choice == null and self.selected == index;
            const style = self.look(selected, .{ .row = row, .width = size.width });
            fillRow(surface, row, style);
            _ = paintTo(ctx, surface, field.label, 3, row, style, @min(19, size.width));
            const end = paint(ctx, surface, field.value, 19, row, style);
            if (field.tail) |tail| {
                var quiet = self.quiet;
                quiet.bg = style.bg;
                quiet.reverse = style.reverse;
                quiet.ul_style = style.ul_style;
                _ = paint(ctx, surface, tail, end, row, quiet);
            }
            try targets.append(.{ .row = row, .start = 0, .end = size.width, .index = index });
        }
        if (self.choice) |choice| if (choice.field == index) {
            for (choice.labels, 0..) |label, at| {
                const row = self.visible(index + 1 + at, size.height) orelse continue;
                const style = self.look(at == choice.selected, .{ .row = row, .width = size.width });
                fillRow(surface, row, style);
                _ = paint(ctx, surface, if (choice.current == at) "✓" else " ", 5, row, style);
                _ = paint(ctx, surface, label, 7, row, style);
                try targets.append(.{ .row = row, .start = 0, .end = size.width, .index = at, .choice = true });
            }
        };
    }
    if (self.actions.len > 0) if (self.visible(self.rowOf(self.fields.len), size.height)) |row| {
        var col: u16 = @min(3, size.width);
        for (self.actions, 0..) |action, at| {
            const start = col;
            const selected = self.choice == null and self.selected == self.fields.len + at;
            col = paint(ctx, surface, action, col, row, if (selected) self.selection else self.ground);
            if (!selected and self.hover.contains(.{ .row = row, .col = start, .width = col - start })) {
                _ = paint(ctx, surface, action, start, row, self.hover_style);
            }
            if (col > start) try targets.append(.{ .row = row, .start = start, .end = col, .index = self.fields.len + at });
            col = @intCast(@min(@as(u32, col) + 5, size.width));
        }
    };
    self.targets = targets.items;
    const hover_targets = try ctx.arena.alloc(Hover.Rect, targets.items.len);
    for (targets.items, hover_targets) |target, *rect| rect.* = .{ .row = target.row, .col = target.start, .width = target.end - target.start };
    self.hover.targets = hover_targets;
    return surface;
}

/// Selection wins over hover; hover wins over the panel ground.
fn look(self: *const Self, selected: bool, rect: Hover.Rect) vaxis.Style {
    if (selected) return self.selection;
    return if (self.hover.contains(rect)) self.hover_style else self.ground;
}

fn visible(self: *const Self, logical: usize, height: u16) ?u16 {
    if (logical < self.scroll or logical - self.scroll >= height - 2) return null;
    return @intCast(logical - self.scroll + 2);
}

fn fillRow(surface: vxfw.Surface, row: u16, style: vaxis.Style) void {
    for (0..surface.size.width) |col| surface.writeCell(@intCast(col), row, .{ .style = style });
}

/// Single-line, terminal-cell clipping, including labels and quiet tails.
fn paint(ctx: vxfw.DrawContext, surface: vxfw.Surface, text: []const u8, start: u16, row: u16, style: vaxis.Style) u16 {
    return paintTo(ctx, surface, text, start, row, style, surface.size.width);
}

fn paintTo(ctx: vxfw.DrawContext, surface: vxfw.Surface, text: []const u8, start: u16, row: u16, style: vaxis.Style, limit: u16) u16 {
    var col = @min(start, limit);
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |part| {
        const grapheme = part.bytes(text);
        if (std.mem.indexOfAny(u8, grapheme, "\r\n") != null) break;
        const width = ctx.stringWidth(grapheme);
        if (width > limit - col) break;
        if (width == 0) continue;
        surface.writeCell(col, row, .{ .char = .{ .grapheme = grapheme, .width = @intCast(width) }, .style = style });
        col += @intCast(width);
    }
    return col;
}

const Fixture = struct {
    activated: ?usize = null,
    picked_field: ?usize = null,
    picked: ?usize = null,
    fn activateRow(raw: *anyopaque, _: *vxfw.EventContext, index: usize) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.activated = index;
    }
    fn pickRow(raw: *anyopaque, _: *vxfw.EventContext, field: usize, index: usize) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.picked_field = field;
        self.picked = index;
    }
};

fn pressKey(panel: *Self, ctx: *vxfw.EventContext, codepoint: u21) !void {
    ctx.consume_event = false;
    try panel.widget().handleEvent(ctx, .{ .key_press = .{ .codepoint = codepoint } });
}

test "Panel draws bounded text ground selection and quiet tails without wrapping" {
    var panel: Self = .{
        .title = "Title",
        .fields = &.{ .{ .label = "Field", .value = "long value that must not wrap", .tail = " quiet" }, .{ .label = "Other", .value = "x", .tail = " tail" } },
        .ground = .{ .bg = .{ .index = 1 } },
        .selection = .{ .bg = .{ .index = 2 } },
        .quiet = .{ .fg = .{ .index = 3 } },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 26, .height = 7 }, .cell_size = .{} };
    const surface = try panel.widget().draw(ctx);
    try std.testing.expectEqualStrings("T", surface.readCell(1, 1).char.grapheme);
    try std.testing.expect(surface.readCell(1, 1).style.bold);
    try std.testing.expectEqualStrings("F", surface.readCell(3, 2).char.grapheme);
    try std.testing.expectEqualStrings("l", surface.readCell(19, 2).char.grapheme);
    try std.testing.expectEqualStrings("a", surface.readCell(25, 2).char.grapheme);
    try std.testing.expectEqualStrings("O", surface.readCell(3, 3).char.grapheme);
    try std.testing.expectEqualStrings("t", surface.readCell(21, 3).char.grapheme);
    try std.testing.expectEqual(panel.quiet.fg, surface.readCell(21, 3).style.fg);
    try std.testing.expectEqual(panel.selection.bg, surface.readCell(0, 2).style.bg);
    try std.testing.expectEqual(panel.ground.bg, surface.readCell(0, 6).style.bg);
    for (0..27) |width| for (0..8) |height| {
        const tiny = try panel.widget().draw(ctx.withConstraints(.{}, .{ .width = @intCast(width), .height = @intCast(height) }));
        try std.testing.expectEqual(@as(u16, @intCast(width)), tiny.size.width);
        for (tiny.buffer, 0..) |cell, at| try std.testing.expect(at % @max(width, 1) + cell.char.width <= width);
    };
    panel.fields = &.{.{ .label = "界", .value = "界e\u{301}q\nnever" }};
    const unicode = try panel.widget().draw(ctx.withConstraints(.{}, .{ .width = 22, .height = 4 }));
    try std.testing.expectEqualStrings("界", unicode.readCell(19, 2).char.grapheme);
    try std.testing.expectEqualStrings("e\u{301}", unicode.readCell(21, 2).char.grapheme);
    try std.testing.expectEqualStrings(" ", unicode.readCell(0, 3).char.grapheme);
}

test "Panel key and mouse movement stops at ends and activates distinct actions" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Title", .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Two", .value = "2" } }, .actions = &.{ "Rename", "Archive", "Copy last answer" }, .userdata = &fixture, .on_activate = Fixture.activateRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try pressKey(&panel, &ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(usize, 0), panel.selected);
    for (0..7) |_| try pressKey(&panel, &ctx, vaxis.Key.down);
    try std.testing.expectEqual(@as(usize, 4), panel.selected);
    try pressKey(&panel, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?usize, 4), fixture.activated);
    try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .wheel_up, .type = .press, .mods = .{}, .row = 0, .col = 0 } });
    try std.testing.expectEqual(@as(usize, 3), panel.selected);
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 8 }, .cell_size = .{} };
    _ = try panel.widget().draw(draw_ctx);
    try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 3, .col = 2 } });
    try std.testing.expectEqual(@as(usize, 1), panel.selected);
    try std.testing.expectEqual(@as(?usize, 1), fixture.activated);
    for ([_]i16{ 3, 14, 26 }, 2..) |col, index| {
        try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 4, .col = col } });
        try std.testing.expectEqual(index, panel.selected);
        try std.testing.expectEqual(@as(?usize, index), fixture.activated);
    }
    // Clicking whitespace between actions doesn't activate a neighbor.
    fixture.activated = null;
    try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 4, .col = 10 } });
    try std.testing.expectEqual(@as(?usize, null), fixture.activated);
}

test "Panel inline choices open pick cancel and scroll in the same field" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Title", .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Two", .value = "2" } }, .userdata = &fixture, .on_pick = Fixture.pickRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    panel.openChoice(&.{ "alpha", "beta", "gamma", "delta" }, 1);
    try std.testing.expectEqual(@as(usize, 1), panel.choice.?.selected);
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 28, .height = 8 }, .cell_size = .{} };
    const drawn = try panel.widget().draw(draw_ctx);
    try std.testing.expectEqualStrings("✓", drawn.readCell(5, 4).char.grapheme);
    try std.testing.expect(drawn.readCell(7, 4).style.reverse);
    try pressKey(&panel, &ctx, vaxis.Key.up);
    try pressKey(&panel, &ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(usize, 0), panel.choice.?.selected);
    try pressKey(&panel, &ctx, vaxis.Key.down);
    try pressKey(&panel, &ctx, vaxis.Key.enter);
    try std.testing.expect(panel.choice == null);
    try std.testing.expectEqual(@as(?usize, 0), fixture.picked_field);
    try std.testing.expectEqual(@as(?usize, 1), fixture.picked);
    panel.openChoice(&.{ "alpha", "beta" }, 0);
    try pressKey(&panel, &ctx, vaxis.Key.escape);
    try std.testing.expect(!ctx.consume_event); // Layer, not Panel, owns cancel.
    try std.testing.expect(panel.choice != null);
    panel.closeChoice();
    try std.testing.expect(panel.choice == null);
    try std.testing.expectEqual(@as(?usize, 1), fixture.picked);
    panel.openChoice(&.{ "alpha", "beta", "gamma", "delta" }, 0);
    for (0..5) |_| try pressKey(&panel, &ctx, vaxis.Key.down);
    try std.testing.expectEqual(@as(usize, 3), panel.choice.?.selected);
    const clipped = try panel.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 28, .height = 4 }));
    try std.testing.expectEqualStrings("d", clipped.readCell(7, 3).char.grapheme);
    try std.testing.expect(panel.scroll > 0);
    try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .wheel_up, .type = .press, .mods = .{}, .row = 3, .col = 7 } });
    try std.testing.expectEqual(@as(usize, 2), panel.choice.?.selected);
    _ = try panel.widget().draw(draw_ctx);
    try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 3, .col = 7 } });
    try std.testing.expect(panel.choice == null);
    try std.testing.expectEqual(@as(?usize, 0), fixture.picked);
}

test "Panel hover highlights fields choices and actions without changing keyboard state" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Settings", .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Two", .value = "2" } }, .actions = &.{ "Rename", "Archive" }, .ground = .{ .bg = .{ .index = 1 } }, .selection = .{ .bg = .{ .index = 2 } }, .hover_style = .{ .bg = .{ .index = 5 } }, .userdata = &fixture, .on_activate = Fixture.activateRow, .on_pick = Fixture.pickRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 10 }, .cell_size = .{} };
    _ = try panel.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try panel.widget().handleEvent(&events, .mouse_enter);
    for ([_]struct { row: i16, col: i16 }{ .{ .row = 3, .col = 39 }, .{ .row = 4, .col = 14 } }) |point| {
        try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = point.col, .row = point.row, .button = .none, .type = .motion, .mods = .{} } });
        const surface = try panel.widget().draw(ctx);
        try std.testing.expectEqual(panel.hover_style.bg, surface.readCell(@intCast(point.col), @intCast(point.row)).style.bg);
        try std.testing.expectEqual(panel.selection.bg, surface.readCell(39, 2).style.bg);
        try std.testing.expectEqual(@as(usize, 0), panel.selected);
        try std.testing.expectEqual(@as(?usize, null), fixture.activated);
        try std.testing.expect(panel.hover.pointing);
    }
    try panel.widget().handleEvent(&events, .mouse_leave);
    var surface = try panel.widget().draw(ctx);
    try std.testing.expectEqual(panel.ground.bg, surface.readCell(39, 3).style.bg);
    panel.openChoice(&.{ "First", "Second" }, 0);
    _ = try panel.widget().draw(ctx);
    try panel.widget().handleEvent(&events, .mouse_enter);
    try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 39, .row = 3, .button = .none, .type = .motion, .mods = .{} } });
    surface = try panel.widget().draw(ctx);
    try std.testing.expectEqual(panel.selection.bg, surface.readCell(39, 3).style.bg);
    try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 39, .row = 4, .button = .none, .type = .motion, .mods = .{} } });
    surface = try panel.widget().draw(ctx);
    try std.testing.expectEqual(panel.hover_style.bg, surface.readCell(39, 4).style.bg);
    try std.testing.expectEqual(panel.selection.bg, surface.readCell(39, 3).style.bg);
    try std.testing.expectEqual(@as(usize, 0), panel.choice.?.selected);
    try std.testing.expectEqual(@as(?usize, null), fixture.picked);
    try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 39, .row = 4, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqual(@as(?usize, 1), fixture.picked);
    try panel.widget().handleEvent(&events, .mouse_leave);
    _ = try panel.widget().draw(ctx);
    try std.testing.expect(!panel.hover.pointing);
}

/// A read-only reference in fitting columns, without selection or input ownership.
/// It shares the panel's cell clipping; labels are strong, values are plain.
pub const KeyList = struct {
    fields: []const Field,
    ground: vaxis.Style = .{},
    strong: vaxis.Style = .{ .bold = true },

    pub fn widget(self: *KeyList) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawReference };
    }

    fn drawReference(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *KeyList = @ptrCast(@alignCast(raw));
        const size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        @memset(surface.buffer, .{ .style = self.ground });
        var key_widths = [_]usize{ 0, 0 };
        var value_widths = [_]usize{ 0, 0 };
        for (self.fields, 0..) |field, index| {
            const column = index % 2;
            key_widths[column] = @max(key_widths[column], ctx.stringWidth(field.label));
            value_widths[column] = @max(value_widths[column], ctx.stringWidth(field.value));
        }
        const margin = 1;
        const key_gap = 3;
        const column_gap = 2;
        const left_width = margin + key_widths[0] + key_gap + value_widths[0];
        const right_width = margin + key_widths[1] + key_gap + value_widths[1];
        const columns: usize = if (self.fields.len > 1 and left_width + column_gap + right_width <= size.width) 2 else 1;
        if (columns == 1) key_widths[0] = @max(key_widths[0], key_widths[1]);
        for (self.fields, 0..) |field, index| {
            const row = index / columns;
            if (row >= size.height) break;
            const column = index % columns;
            const start = if (column == 0) 0 else left_width + column_gap;
            const column_width = if (column == 0) left_width else right_width;
            const limit: u16 = if (columns == 1) size.width else @intCast(start + column_width);
            const label: u16 = @intCast(@min(start + margin, limit));
            const value: u16 = @intCast(@min(start + margin + key_widths[column] + key_gap, limit));
            _ = paintTo(ctx, surface, field.label, label, @intCast(row), self.strong, limit);
            _ = paintTo(ctx, surface, field.value, value, @intCast(row), self.ground, limit);
        }
        return surface;
    }
};

test "Panel KeyList fits measured columns and aligns values after the widest key in cells" {
    var reference: KeyList = .{ .fields = &.{
        .{ .label = "界界界", .value = "one" },
        .{ .label = "x", .value = "two" },
        .{ .label = "long", .value = "three" },
        .{ .label = "xy", .value = "four" },
    } };
    for ([_]u16{ 26, 27 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try reference.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 4 }, .cell_size = .{} });
        // The left key is six terminal cells, the right key two. The
        // measured widths are 15 + 2 + 10, unrelated to the app's table.
        const columns: usize = if (width == 27) 2 else 1;
        for ([_][]const u8{ "one", "two", "three", "four" }, 0..) |value, index| {
            const start: usize = if (columns == 2 and index % 2 == 1) 23 else 10;
            for (value, 0..) |byte, col| {
                const cell = surface.readCell(@intCast(start + col), @intCast(index / columns));
                try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
            }
        }
    }
}
