//! A bounded field-and-action panel with inline choices. All text, styles and
//! effects belong to its caller; Escape belongs to the enclosing Layer.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

/// Aligned field values start here; callers may fit bounded values to it.
pub const value_column: u16 = 19;

pub const Field = struct { label: []const u8, value: []const u8, tail: ?[]const u8 = null, selectable: bool = true, visible: bool = true };
pub const Choice = struct { field: usize, labels: []const []const u8, current: ?usize, selected: usize };
/// A field's full-width choice. The child owns its selection and scrolling.
pub const CustomChoice = struct {
    field: usize,
    widget: vxfw.Widget,
    /// While open, this replaces the field's saved value at its value column.
    value_widget: ?vxfw.Widget = null,
    height: u16 = 8,
};
const Target = struct { row: u16, start: u16, end: u16, index: usize, choice: bool = false };

title: []const u8,
unicode: bool = true,
title_widget: ?vxfw.Widget = null,
action_gap: u16 = 0,
stacked_actions: bool = false,
custom_choice: ?CustomChoice = null,
custom_origin: u16 = 0,
custom_height: u16 = 0,
fields: []const Field = &.{},
actions: []const []const u8 = &.{},
selected: usize = 0,
choice: ?Choice = null,
userdata: ?*anyopaque = null,
on_activate: ?*const fn (*anyopaque, *vxfw.EventContext, usize) anyerror!void = null,
on_pick: ?*const fn (*anyopaque, *vxfw.EventContext, usize, usize) anyerror!void = null,
ground: vaxis.Style = .{},
selection: vaxis.Style = .{ .reverse = true },
title_style: vaxis.Style = .{ .bold = true },
quiet: vaxis.Style = .{},
rule_style: vaxis.Style = .{},
scroll: usize = 0,
/// Borrowed from the last draw arena, just like the framework's hit surface.
/// Replaced on every draw; never read outside a mouse event for that frame.
targets: []const Target = &.{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn openChoice(self: *Self, labels: []const []const u8, current: ?usize) void {
    if (self.selected >= self.fields.len or (!self.fields[self.selected].selectable or !self.fields[self.selected].visible) or labels.len == 0) return;
    const checked = if (current) |at| if (at < labels.len) current else null else null;
    self.choice = .{ .field = self.selected, .labels = labels, .current = checked, .selected = checked orelse 0 };
}

pub fn closeChoice(self: *Self) void {
    self.choice = null;
}

fn selectable(self: *const Self, at: usize) bool {
    return at < self.fields.len + self.actions.len and (at >= self.fields.len or (self.fields[at].selectable and self.fields[at].visible));
}

fn move(self: *Self, down: bool) void {
    if (self.choice) |*choice| {
        if (down) choice.selected = @min(choice.selected + 1, choice.labels.len - 1) else choice.selected -|= 1;
        return;
    }
    const count = self.fields.len + self.actions.len;
    if (count == 0) return;
    var at = @min(self.selected, count - 1);
    while (if (down) at + 1 < count else at > 0) {
        at = if (down) at + 1 else at - 1;
        if (self.selectable(at)) {
            self.selected = at;
            return;
        }
    }
}

fn activate(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.choice) |choice| {
        self.closeChoice();
        if (self.on_pick) |callback| try callback(self.userdata.?, ctx, choice.field, choice.selected);
    } else if (self.selectable(self.selected)) {
        if (self.on_activate) |callback| try callback(self.userdata.?, ctx, self.selected);
    }
}

/// The only keys a panel takes; every other key is its caller's.
pub fn takesKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.enter, .{});
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.custom_choice) |choice| {
        if (input == .key_press and input.key_press.matches(vaxis.Key.escape, .{})) return;
        var local = input;
        if (local == .mouse) {
            if (local.mouse.row < self.custom_origin or local.mouse.row >= self.custom_origin + self.custom_height) return;
            local.mouse.row -= @intCast(self.custom_origin);
        }
        try choice.widget.handleEvent(ctx, local);
        return;
    }
    switch (input) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.up, .{})) {
                self.move(false);
            } else if (key.matches(vaxis.Key.down, .{})) {
                self.move(true);
            } else if (key.matches(vaxis.Key.enter, .{})) {
                try self.activate(ctx);
            } else return;
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
    // Hiding a fact compacts presentation, never its semantic field/action ID.
    var row: usize = 0;
    for (self.fields[0..@min(field, self.fields.len)]) |before| row += @intFromBool(before.visible);
    if (field >= self.fields.len and self.stacked_actions) row += field - self.fields.len;
    if (self.choice) |choice| if (field > choice.field) {
        row += choice.labels.len;
    };
    if (self.custom_choice) |choice| if (field > choice.field) {
        row += self.custom_height;
    };
    if (field >= self.fields.len) row += self.action_gap;
    return row;
}

fn activeRow(self: *const Self) usize {
    if (self.custom_choice) |choice| return self.rowOf(choice.field) + @as(usize, if (choice.value_widget == null) 1 else 0);
    if (self.choice) |choice| return self.rowOf(choice.field) + 1 + choice.selected;
    return self.rowOf(@min(self.selected, (self.fields.len + self.actions.len) -| 1));
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.ground });
    self.targets = &.{};
    self.custom_origin = 0;
    self.custom_height = 0;
    if (size.width == 0 or size.height == 0) return surface;
    for (0..size.width) |col| surface.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = if (self.unicode) "─" else "-", .width = 1 }, .style = self.rule_style });
    if (size.height == 1) return surface;
    _ = paint(ctx, surface, try displayText(ctx.arena, self.title, self.unicode), 1, 1, self.title_style);
    var children: std.array_list.Managed(vxfw.SubSurface) = .init(ctx.arena);
    if (self.title_widget) |title_widget| if (size.width > 1) {
        try children.append(.{ .origin = .{ .row = 1, .col = 1 }, .surface = try title_widget.draw(ctx.withConstraints(.{}, .{ .width = size.width - 1, .height = 1 })) });
    };
    if (size.height == 2) {
        surface.children = children.items;
        return surface;
    }
    const count = self.fields.len + self.actions.len;
    if (count > 0) self.selected = @min(self.selected, count - 1);
    const body_height = size.height - 2;
    // Ask the base choice for its natural height before laying out later facts.
    // Narrowing a query must not retain rows from the previous result list.
    var custom_surface: ?vxfw.Surface = null;
    if (self.custom_choice) |choice| if (body_height > 1) {
        custom_surface = try choice.widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = @min(choice.height, body_height - 1) }));
        self.custom_height = custom_surface.?.size.height;
    };
    var visible_fields: usize = 0;
    for (self.fields) |field| visible_fields += @intFromBool(field.visible);
    const rows = visible_fields + self.custom_height + (if (self.actions.len > 0) (if (self.stacked_actions) self.actions.len else @as(usize, 1)) + self.action_gap else 0) + if (self.choice) |choice| choice.labels.len else @as(usize, 0);
    const active = self.activeRow();
    if (active < self.scroll) self.scroll = active;
    const active_end = if (self.custom_choice) |choice| self.rowOf(choice.field) + self.custom_height else active;
    if (active_end >= self.scroll + body_height) self.scroll = active_end - body_height + 1;
    self.scroll = @min(self.scroll, rows -| body_height);
    var targets: std.array_list.Managed(Target) = .init(ctx.arena);
    for (self.fields, 0..) |field, index| {
        if (!field.visible) continue;
        if (self.visible(self.rowOf(index), size.height)) |row| {
            const selected = self.choice == null and self.custom_choice == null and self.selected == index and field.selectable;
            const style = if (selected) self.selection else self.ground;
            fillRow(surface, row, style);
            _ = paintTo(ctx, surface, try displayText(ctx.arena, field.label, self.unicode), 3, row, style, @min(value_column, size.width));
            // Status/failure words belong to the field, even beside a long
            // saved value. Reserve them here for every Panel consumer.
            const value_widget = if (self.custom_choice) |choice| if (choice.field == index) choice.value_widget else null else null;
            if (value_widget) |value| {
                if (size.width > value_column) {
                    const drawn = try value.draw(ctx.withConstraints(.{}, .{ .width = size.width - value_column, .height = 1 }));
                    try children.append(.{ .origin = .{ .row = row, .col = value_column }, .surface = drawn });
                    if (drawn.cursor) |cursor| {
                        surface.cursor = cursor;
                        surface.cursor.?.row += row;
                        surface.cursor.?.col += value_column;
                    }
                }
            } else {
                const tail = try displayText(ctx.arena, field.tail orelse "", self.unicode);
                const limit: u16 = @intCast(size.width -| ctx.stringWidth(tail));
                const end = paintTo(ctx, surface, try displayText(ctx.arena, field.value, self.unicode), value_column, row, style, limit);
                if (tail.len > 0) {
                    var quiet = self.quiet;
                    quiet.bg = style.bg;
                    quiet.reverse = style.reverse;
                    _ = paint(ctx, surface, tail, end, row, quiet);
                }
            }
            if (field.selectable) try targets.append(.{ .row = row, .start = 0, .end = size.width, .index = index });
        }
        if (self.choice) |choice| if (choice.field == index) {
            for (choice.labels, 0..) |label, at| {
                const row = self.visible(self.rowOf(index) + 1 + at, size.height) orelse continue;
                const style = if (at == choice.selected) self.selection else self.ground;
                fillRow(surface, row, style);
                _ = paint(ctx, surface, if (choice.current == at) (if (self.unicode) "✓" else "+") else " ", 5, row, style);
                _ = paint(ctx, surface, try displayText(ctx.arena, label, self.unicode), 7, row, style);
                try targets.append(.{ .row = row, .start = 0, .end = size.width, .index = at, .choice = true });
            }
        };
    }
    if (self.custom_choice) |choice| if (self.custom_height > 0) {
        if (self.visible(self.rowOf(choice.field) + 1, size.height)) |row| {
            self.custom_origin = row;
            try children.append(.{ .origin = .{ .row = row, .col = 0 }, .surface = custom_surface.? });
        }
    };
    {
        var col: u16 = @min(3, size.width);
        for (self.actions, 0..) |action, at| {
            const row = self.visible(self.rowOf(self.fields.len + at), size.height) orelse continue;
            if (self.stacked_actions) col = @min(3, size.width);
            const start = col;
            const style = if (self.choice == null and self.custom_choice == null and self.selected == self.fields.len + at) self.selection else self.ground;
            col = paint(ctx, surface, try displayText(ctx.arena, action, self.unicode), col, row, style);
            if (col > start) try targets.append(.{ .row = row, .start = start, .end = col, .index = self.fields.len + at });
            col = @intCast(@min(@as(u32, col) + 5, size.width));
        }
    }
    self.targets = targets.items;
    surface.children = children.items;
    return surface;
}

fn visible(self: *const Self, logical: usize, height: u16) ?u16 {
    if (logical < self.scroll or logical - self.scroll >= height - 2) return null;
    return @intCast(logical - self.scroll + 2);
}

fn fillRow(surface: vxfw.Surface, row: u16, style: vaxis.Style) void {
    for (0..surface.size.width) |col| surface.writeCell(@intCast(col), row, .{ .style = style });
}

/// Presentation only: keep canonical text unchanged. Unicode and ASCII text
/// are borrowed; an ASCII fallback for decoration or other scalars lives in
/// the draw arena. Unknown non-ASCII scalars use the overview's `?` stand-in.
pub fn displayText(arena: std.mem.Allocator, text: []const u8, unicode: bool) std.mem.Allocator.Error![]const u8 {
    if (unicode) return text;
    for (text) |byte| {
        if (byte >= 0x80) break;
    } else return text;
    const out = try arena.alloc(u8, text.len);
    var used: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        const end = @min(at + length, text.len);
        const scalar = std.unicode.utf8Decode(text[at..end]) catch 0xfffd;
        out[used] = switch (scalar) {
            0...0x7f => @intCast(scalar),
            '─' => '-',
            '✓' => '+',
            '·', '…' => '.',
            '↑' => '^',
            '↓' => 'v',
            '‹' => '<',
            '›' => '>',
            else => '?',
        };
        used += 1;
        at = end;
    }
    return out[0..used];
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
    try std.testing.expectEqualStrings("t", surface.readCell(25, 2).char.grapheme);
    try std.testing.expectEqual(panel.quiet.fg, surface.readCell(25, 2).style.fg);
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

test "Panel read-only fields skip navigation clicks and activation" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Title", .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Read only", .value = "2", .selectable = false }, .{ .label = "Three", .value = "3" } }, .userdata = &fixture, .on_activate = Fixture.activateRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try pressKey(&panel, &ctx, vaxis.Key.down);
    try std.testing.expectEqual(@as(usize, 2), panel.selected);
    try pressKey(&panel, &ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(usize, 0), panel.selected);
    _ = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
    try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 3, .col = 2 } });
    try std.testing.expectEqual(@as(usize, 0), panel.selected);
    try std.testing.expectEqual(@as(?usize, null), fixture.activated);
    panel.selected = 1;
    try pressKey(&panel, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?usize, null), fixture.activated);
    panel.openChoice(&.{"no"}, null);
    try std.testing.expect(panel.choice == null);
}

test "Panel full-width choice and editable title remain bounded and own input" {
    const Child = struct {
        event_row: ?i16 = null,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = eventChild, .drawFn = drawChild };
        }
        fn eventChild(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .mouse) self.event_row = input.mouse.row;
            ctx.consumeAndRedraw();
        }
        fn drawChild(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        }
    };
    var child: Child = .{};
    var title: Child = .{};
    var panel: Self = .{ .title = "Title", .title_widget = title.widget(), .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Model", .value = "x" } }, .selected = 1, .custom_choice = .{ .field = 1, .widget = child.widget() } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 99, 46 }) |width| {
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 9 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(u16, width - 1), drawn.children[0].surface.size.width);
        try std.testing.expectEqual(width, drawn.children[1].surface.size.width);
        try std.testing.expectEqual(@as(i17, 0), drawn.children[1].origin.col);
        try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(panel.custom_origin + 1), .col = 30 } });
        try std.testing.expectEqual(@as(?i16, 1), child.event_row);
        try pressKey(&panel, &ctx, vaxis.Key.escape);
        try std.testing.expect(!ctx.consume_event);
        try std.testing.expect(panel.custom_choice != null);
    }
    for (0..6) |width| for (0..9) |height| {
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        for (drawn.children) |part| try std.testing.expect(part.origin.row + part.surface.size.height <= height);
    };
}

test "Panel stacked actions retain independent navigation and mouse targets" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Title", .fields = &.{.{ .label = "One", .value = "1" }}, .actions = &.{ "Rename", "Archive: couldn't archive", "Copy: couldn't copy" }, .stacked_actions = true, .userdata = &fixture, .on_activate = Fixture.activateRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    _ = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
    for (0..3) |at| {
        try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(3 + at), .col = 3 } });
        try std.testing.expectEqual(at + 1, panel.selected);
        try std.testing.expectEqual(@as(?usize, at + 1), fixture.activated);
    }
    for (0..10) |width| for (0..8) |height| {
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        for (drawn.buffer, 0..) |cell, at| try std.testing.expect(at % @max(width, 1) + cell.char.width <= width);
    };
}

test "Panel reserves failure words beside long ASCII and Unicode field values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ &(@as([100]u8, @splat('n'))), "界界界界界界界界界界界界界界界界界界界界界界" }) |value| for ([_]u16{ 99, 46 }) |width| {
        var panel: Self = .{ .title = "Title", .fields = &.{.{ .label = "Model", .value = value, .tail = " · couldn't save" }} };
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 4 }, .cell_size = .{} });
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (0..width) |x| try text.writer.writeAll(drawn.readCell(@intCast(x), 2).char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "couldn't save") != null);
        try std.testing.expectEqualStrings(value, panel.fields[0].value);
    };
}

test "Panel shared ASCII rendering keeps rules choices tails and canonical values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("- + . . ^v <> ?", try displayText(arena.allocator(), "─ ✓ · … ↑↓ ‹› 界", false));
    const original = "model 界";
    var panel: Self = .{ .title = "Title", .unicode = false, .fields = &.{.{ .label = "Model", .value = original, .tail = " · saving…" }} };
    panel.openChoice(&.{ "one", "✓ two" }, 1);
    for ([_]u16{ 1, 19, 28, 46, 99 }) |width| {
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 9 }, .cell_size = .{} });
        for (drawn.buffer) |cell| for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
        try std.testing.expectEqualStrings("-", drawn.readCell(0, 0).char.grapheme);
        if (width > 7) try std.testing.expectEqualStrings("+", drawn.readCell(5, 4).char.grapheme);
    }
    try std.testing.expectEqualStrings(original, panel.fields[0].value);
}

test "Panel hidden fields compact rows while preserving navigation actions and choice identities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]bool{ false, true }) |context_visible| for ([_]bool{ false, true }) |stacked| {
        var fixture: Fixture = .{};
        const fields: [4]Field = .{
            .{ .label = "Effort", .value = "high" },
            .{ .label = "Hidden", .value = "never shown", .visible = false },
            .{ .label = "Context", .value = "18 of 244,800", .visible = context_visible, .selectable = false },
            .{ .label = "Model", .value = "gpt-5.5" },
        };
        var panel: Self = .{ .title = "Chat", .fields = &fields, .actions = &.{ "Rename", "Archive" }, .action_gap = 1, .stacked_actions = stacked, .userdata = &fixture, .on_activate = Fixture.activateRow };
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 16 }, .cell_size = .{} };
        const drawn = try panel.widget().draw(ctx);
        const model_row: u16 = if (context_visible) 4 else 3;
        try std.testing.expectEqualStrings("M", drawn.readCell(3, model_row).char.grapheme);
        const actions_row = model_row + 2;
        for (0..46) |col| try std.testing.expectEqualStrings(" ", drawn.readCell(@intCast(col), actions_row - 1).char.grapheme);
        try pressKey(&panel, &events, vaxis.Key.down);
        try std.testing.expectEqual(@as(usize, 3), panel.selected);
        try pressKey(&panel, &events, vaxis.Key.down);
        try std.testing.expectEqual(@as(usize, 4), panel.selected);
        try panel.widget().handleEvent(&events, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(actions_row), .col = 3 } });
        try std.testing.expectEqual(@as(?usize, 4), fixture.activated);
        panel.selected = 3;
        panel.openChoice(&.{ "first", "second" }, 0);
        const choice = try panel.widget().draw(ctx);
        try std.testing.expectEqualStrings("f", choice.readCell(7, model_row + 1).char.grapheme);
        panel.closeChoice();
        const content: vxfw.Text = .{ .text = "Model choice" };
        panel.custom_choice = .{ .field = 3, .widget = content.widget(), .height = 3 };
        const custom = try panel.widget().draw(ctx);
        try std.testing.expectEqual(@as(i17, model_row + 1), custom.children[0].origin.row);
    };
}
