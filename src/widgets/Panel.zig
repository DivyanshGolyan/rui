//! A bounded field-and-action panel with inline choices. All text, styles and
//! effects belong to its caller; Escape belongs to the enclosing Layer.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();
const Hover = @import("Hover.zig");
const cell_line = @import("cell_line.zig");

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
/// Fit hosted content, including one trailing ground row; full pages fill by default.
natural_height: bool = false,
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

fn move(self: *Self, down: bool, only: ?usize) void {
    if (only) |field| if (self.choice == null) {
        self.selected = field;
        return;
    };
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

fn activate(self: *Self, ctx: *vxfw.EventContext, only: ?usize) !void {
    if (self.choice) |choice| {
        self.closeChoice();
        if (self.on_pick) |callback| try callback(self.userdata.?, ctx, choice.field, choice.selected);
    } else if (self.selectable(only orelse self.selected)) {
        self.selected = only orelse self.selected;
        if (self.on_activate) |callback| try callback(self.userdata.?, ctx, self.selected);
    }
}

/// The only keys a panel takes; every other key is its caller's.
pub fn takesKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.enter, .{});
}

/// The caller derives this field from its current standalone presentation.
/// No presentation lifetime or mode is retained by Panel.
pub fn choiceEvent(self: *Self, ctx: *vxfw.EventContext, input: vxfw.Event, field: usize) !void {
    try self.eventFor(ctx, input, field);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.eventFor(ctx, input, null);
}

fn eventFor(self: *Self, ctx: *vxfw.EventContext, input: vxfw.Event, only: ?usize) !void {
    if (self.custom_choice) |choice| {
        // The child owns all input while open, including pointer feedback.
        try self.hover.handleEvent(ctx, .mouse_leave);
        if (input == .key_press and input.key_press.matches(vaxis.Key.escape, .{})) return;
        var local = input;
        if (local == .mouse) {
            if (local.mouse.row < self.custom_origin or local.mouse.row >= self.custom_origin + self.custom_height) return;
            local.mouse.row -= @intCast(self.custom_origin);
        }
        try choice.widget.handleEvent(ctx, local);
        return;
    }
    try self.hover.handleEvent(ctx, input);
    switch (input) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.up, .{})) {
                self.move(false, only);
            } else if (key.matches(vaxis.Key.down, .{})) {
                self.move(true, only);
            } else if (key.matches(vaxis.Key.enter, .{})) {
                try self.activate(ctx, only);
            } else return;
            ctx.consumeAndRedraw();
        },
        .mouse => |mouse| {
            switch (mouse.button) {
                .wheel_up => self.move(false, only),
                .wheel_down => self.move(true, only),
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
                        try self.activate(ctx, only);
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
    const available = ctx.max.size();
    self.targets = &.{};
    self.custom_origin = 0;
    self.custom_height = 0;
    self.hover.targets = &.{};
    // At tiny heights, content takes precedence over the trailing ground row.
    const bottom_padding: u16 = @intFromBool(self.natural_height and available.height > 3);
    const available_body = available.height -| 2 -| bottom_padding;
    // Measure a custom choice once. Its actual result count is also the sole
    // height used for later rows, scrolling and mouse dispatch this frame.
    var custom_surface: ?vxfw.Surface = null;
    if (available.width > 0) if (self.custom_choice) |choice| if (available_body > 1) {
        custom_surface = try choice.widget.draw(ctx.withConstraints(.{}, .{ .width = available.width, .height = @min(choice.height, available_body - 1) }));
        self.custom_height = custom_surface.?.size.height;
    };
    var visible_fields: usize = 0;
    for (self.fields) |field| visible_fields += @intFromBool(field.visible);
    const rows = visible_fields + self.custom_height + (if (self.actions.len > 0) (if (self.stacked_actions) self.actions.len else @as(usize, 1)) + self.action_gap else 0) + if (self.choice) |choice| choice.labels.len else @as(usize, 0);
    var size = available;
    if (self.natural_height) size.height = @intCast(@min(available.height, @max(ctx.min.height, 2 + rows + bottom_padding)));
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.ground });
    if (size.width == 0 or size.height == 0) return surface;
    for (0..size.width) |col| surface.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = if (self.unicode) "─" else "-", .width = 1 }, .style = self.rule_style });
    if (size.height == 1) return surface;
    _ = paint(ctx, surface, try displayText(ctx.arena, self.title, self.unicode), 1, 1, self.title_style);
    var children: std.array_list.Managed(vxfw.SubSurface) = .init(ctx.arena);
    if (self.title_widget) |title_widget| if (size.width > 1) {
        try children.append(.{ .origin = .{ .row = 1, .col = 1 }, .surface = try title_widget.draw(ctx.withConstraints(.{}, .{ .width = size.width - 1, .height = 1 })) });
    };
    const body_height = size.height -| 2 -| bottom_padding;
    if (body_height == 0) {
        surface.children = children.items;
        return surface;
    }
    const count = self.fields.len + self.actions.len;
    if (count > 0) self.selected = @min(self.selected, count - 1);
    const active = self.activeRow();
    if (active < self.scroll) self.scroll = active;
    const active_end = if (self.custom_choice) |choice| self.rowOf(choice.field) + self.custom_height else active;
    if (active_end >= self.scroll + body_height) self.scroll = active_end - body_height + 1;
    self.scroll = @min(self.scroll, rows -| body_height);
    var targets: std.array_list.Managed(Target) = .init(ctx.arena);
    for (self.fields, 0..) |field, index| {
        if (!field.visible) continue;
        if (self.visible(self.rowOf(index), body_height)) |row| {
            const selected = self.choice == null and self.custom_choice == null and self.selected == index and field.selectable;
            const style = if (self.custom_choice == null and field.selectable) self.look(selected, .{ .row = row, .width = size.width }) else self.ground;
            fillRow(surface, row, style);
            _ = paintTo(ctx, surface, try displayText(ctx.arena, field.label, self.unicode), 3, row, style, @min(value_column, size.width));
            try self.drawFieldValue(ctx, &surface, index, row, value_column, style, &children, &targets);
        }
        if (self.choice) |choice| if (choice.field == index) {
            for (choice.labels, 0..) |label, at| {
                const row = self.visible(self.rowOf(index) + 1 + at, body_height) orelse continue;
                const style = self.look(at == choice.selected, .{ .row = row, .width = size.width });
                fillRow(surface, row, style);
                _ = paint(ctx, surface, if (choice.current == at) (if (self.unicode) "✓" else "+") else " ", 5, row, style);
                _ = paint(ctx, surface, try displayText(ctx.arena, label, self.unicode), 7, row, style);
                try targets.append(.{ .row = row, .start = 0, .end = size.width, .index = at, .choice = true });
            }
        };
    }
    if (self.custom_choice) |choice| if (self.custom_height > 0) {
        if (self.visible(self.rowOf(choice.field) + 1, body_height)) |row| {
            self.custom_origin = row;
            try children.append(.{ .origin = .{ .row = row, .col = 0 }, .surface = custom_surface.? });
        }
    };
    {
        var col: u16 = @min(3, size.width);
        for (self.actions, 0..) |action, at| {
            const row = self.visible(self.rowOf(self.fields.len + at), body_height) orelse continue;
            if (self.stacked_actions) col = @min(3, size.width);
            const start = col;
            const selected = self.choice == null and self.custom_choice == null and self.selected == self.fields.len + at;
            const displayed = try displayText(ctx.arena, action, self.unicode);
            col = paint(ctx, surface, displayed, col, row, if (selected) self.selection else self.ground);
            if (!selected and self.custom_choice == null and self.hover.contains(.{ .row = row, .col = start, .width = col - start })) {
                _ = paint(ctx, surface, displayed, start, row, self.hover_style);
            }
            if (col > start) try targets.append(.{ .row = row, .start = start, .end = col, .index = self.fields.len + at });
            col = @intCast(@min(@as(u32, col) + 5, size.width));
        }
    }
    try self.bindTargets(ctx.arena, targets.items);
    surface.children = children.items;
    return surface;
}

/// Draw a field's value and register exactly the selectable row it occupies.
/// Full pages and retained standalone outcomes share clipping and hit identity.
fn drawFieldValue(self: *Self, ctx: vxfw.DrawContext, surface: *vxfw.Surface, index: usize, row: u16, start: u16, style: vaxis.Style, children: *std.array_list.Managed(vxfw.SubSurface), targets: *std.array_list.Managed(Target)) std.mem.Allocator.Error!void {
    const field = self.fields[index];
    const value_widget = if (self.custom_choice) |choice| if (choice.field == index) choice.value_widget else null else null;
    if (value_widget) |value| {
        if (surface.size.width > start) {
            const drawn = try value.draw(ctx.withConstraints(.{}, .{ .width = surface.size.width - start, .height = 1 }));
            try children.append(.{ .origin = .{ .row = row, .col = start }, .surface = drawn });
            if (drawn.cursor) |cursor| {
                surface.cursor = cursor;
                surface.cursor.?.row += row;
                surface.cursor.?.col += start;
            }
        }
    } else {
        // Keep status/failure words visible even beside a long saved value.
        const tail = try displayText(ctx.arena, field.tail orelse "", self.unicode);
        const limit: u16 = @intCast(surface.size.width -| ctx.stringWidth(tail));
        const end = paintTo(ctx, surface.*, try displayText(ctx.arena, field.value, self.unicode), start, row, style, limit);
        if (tail.len > 0) {
            var quiet = self.quiet;
            quiet.bg = style.bg;
            quiet.reverse = style.reverse;
            quiet.ul_style = style.ul_style;
            _ = paint(ctx, surface.*, tail, end, row, quiet);
        }
    }
    if (field.selectable) try targets.append(.{ .row = row, .start = 0, .end = surface.size.width, .index = index });
}

fn bindTargets(self: *Self, arena: std.mem.Allocator, targets: []const Target) std.mem.Allocator.Error!void {
    self.targets = targets;
    const hover_targets = try arena.alloc(Hover.Rect, if (self.custom_choice == null) targets.len else 0);
    for (targets[0..hover_targets.len], hover_targets) |target, *rect| rect.* = .{ .row = target.row, .col = target.start, .width = target.end - target.start };
    self.hover.targets = hover_targets;
}

/// Draw the current owner's field without retaining a standalone mode.
/// Its wrapper routes events through choiceEvent with the same current field.
pub fn drawChoice(self: *Self, ctx: vxfw.DrawContext, index: usize) std.mem.Allocator.Error!vxfw.Surface {
    self.targets = &.{};
    self.hover.targets = &.{};
    self.custom_origin = 0;
    self.custom_height = 0;
    const available = ctx.max.size();
    if (index >= self.fields.len or available.width == 0 or available.height == 0) return .empty(self.widget());
    const field = self.fields[index];
    var children: std.array_list.Managed(vxfw.SubSurface) = .init(ctx.arena);
    var targets: std.array_list.Managed(Target) = .init(ctx.arena);
    var custom: ?vxfw.Surface = null;
    const input_rows: u16 = if (self.custom_choice) |choice| @intFromBool(choice.value_widget != null) else 0;
    if (self.custom_choice) |choice| {
        custom = try choice.widget.draw(ctx.withConstraints(.{}, .{ .width = available.width, .height = @min(choice.height, available.height -| 1 -| input_rows) }));
        self.custom_height = custom.?.size.height;
    }
    const rows: usize = if (self.choice) |choice| choice.labels.len else if (custom != null) self.custom_height + input_rows else 1;
    const size: vxfw.Size = .{ .width = available.width, .height = @intCast(@min(available.height, 1 + rows)) };
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.ground });
    _ = paint(ctx, surface, try displayText(ctx.arena, field.label, self.unicode), 1, 0, self.title_style);
    if (self.custom_choice) |choice| {
        if (choice.value_widget) |value| if (size.height > 1) {
            const drawn = try value.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
            try children.append(.{ .origin = .{ .row = 1, .col = 0 }, .surface = drawn });
            if (drawn.cursor) |cursor| {
                surface.cursor = cursor;
                surface.cursor.?.row += 1;
            }
        };
        self.custom_origin = @min(size.height, 1 + input_rows);
        if (self.custom_height > 0) try children.append(.{ .origin = .{ .row = self.custom_origin, .col = 0 }, .surface = custom.? });
    } else if (self.choice) |choice| {
        const height = size.height -| 1;
        if (choice.selected < self.scroll) self.scroll = choice.selected;
        if (choice.selected >= self.scroll + height) self.scroll = choice.selected + 1 -| height;
        self.scroll = @min(self.scroll, choice.labels.len -| height);
        for (0..height) |offset| {
            const at = self.scroll + offset;
            const row: u16 = @intCast(offset + 1);
            const rect: Hover.Rect = .{ .row = row, .width = size.width };
            const style = self.look(at == choice.selected, rect);
            fillRow(surface, row, style);
            _ = paint(ctx, surface, if (choice.current == at) (if (self.unicode) "✓" else "+") else " ", 1, row, style);
            _ = paint(ctx, surface, try displayText(ctx.arena, choice.labels[at], self.unicode), 3, row, style);
            try targets.append(.{ .row = row, .start = 0, .end = size.width, .index = at, .choice = true });
        }
    } else if (size.height > 1) {
        const style = if (field.selectable) self.look(false, .{ .row = 1, .width = size.width }) else self.ground;
        fillRow(surface, 1, style);
        try self.drawFieldValue(ctx, &surface, index, 1, 1, style, &children, &targets);
    }
    try self.bindTargets(ctx.arena, targets.items);
    surface.children = children.items;
    return surface;
}

/// Selection wins over hover; hover wins over the panel ground.
fn look(self: *const Self, selected: bool, rect: Hover.Rect) vaxis.Style {
    if (selected) return self.selection;
    return if (self.hover.contains(rect)) self.hover_style else self.ground;
}

fn visible(self: *const Self, logical: usize, height: u16) ?u16 {
    if (logical < self.scroll or logical - self.scroll >= height) return null;
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
    return cell_line.paint(ctx, surface, text, start, row, style, surface.size.width);
}

const paintTo = cell_line.paint;

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
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 26, .height = 7 }, .cell_size = .{} };
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
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 8 }, .cell_size = .{} };
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
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 28, .height = 8 }, .cell_size = .{} };
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
    _ = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
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
            return vxfw.Surface.init(ctx.cell_arena, self.widget(), ctx.max.size());
        }
    };
    var child: Child = .{};
    var title: Child = .{};
    var panel: Self = .{ .title = "Title", .title_widget = title.widget(), .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Model", .value = "x" } }, .selected = 1, .custom_choice = .{ .field = 1, .widget = child.widget() } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 99, 46 }) |width| {
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 9 }, .cell_size = .{} });
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
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        for (drawn.children) |part| try std.testing.expect(part.origin.row + part.surface.size.height <= height);
    };
}

test "Panel stacked actions retain independent navigation and mouse targets" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Title", .fields = &.{.{ .label = "One", .value = "1" }}, .actions = &.{ "Rename", "Archive: couldn't archive", "Copy: couldn't copy" }, .stacked_actions = true, .userdata = &fixture, .on_activate = Fixture.activateRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    _ = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
    for (0..3) |at| {
        const selected = panel.selected;
        try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .none, .type = .motion, .mods = .{}, .row = @intCast(3 + at), .col = 3 } });
        const hovered = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
        try std.testing.expectEqual(panel.hover_style, hovered.readCell(3, @intCast(3 + at)).style);
        try std.testing.expect(panel.hover.pointing);
        try std.testing.expectEqual(selected, panel.selected);
        try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(3 + at), .col = 3 } });
        try std.testing.expectEqual(at + 1, panel.selected);
        try std.testing.expectEqual(@as(?usize, at + 1), fixture.activated);
    }
    for (0..10) |width| for (0..8) |height| {
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        for (drawn.buffer, 0..) |cell, at| try std.testing.expect(at % @max(width, 1) + cell.char.width <= width);
    };
}

test "Panel reserves failure words beside long ASCII and Unicode field values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ &(@as([100]u8, @splat('n'))), "界界界界界界界界界界界界界界界界界界界界界界" }) |value| for ([_]u16{ 99, 46 }) |width| {
        var panel: Self = .{ .title = "Title", .fields = &.{.{ .label = "Model", .value = value, .tail = " · couldn't save" }} };
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 4 }, .cell_size = .{} });
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
        const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 9 }, .cell_size = .{} });
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
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 16 }, .cell_size = .{} };
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

test "Panel natural height counts visible rows choices gaps and stacked actions without changing fill pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |natural| for ([_]bool{ false, true }) |context| for ([_]bool{ false, true }) |actions| for ([_]bool{ false, true }) |stacked| for ([_]bool{ false, true }) |choice| {
        const fields = [_]Field{
            .{ .label = "Effort", .value = "high" },
            .{ .label = "Context", .value = "0 of 100", .visible = context, .selectable = false },
            .{ .label = "Model", .value = "model" },
        };
        var panel: Self = .{ .title = "Chat", .natural_height = natural, .fields = &fields, .actions = if (actions) &.{ "Rename", "Archive" } else &.{}, .action_gap = 1, .stacked_actions = stacked };
        if (choice) panel.openChoice(&.{ "high", "low" }, 0);
        const rows: u16 = @as(u16, 2) + @intFromBool(context) + (if (actions) @as(u16, if (stacked) 3 else 2) else 0) + (if (choice) @as(u16, 2) else 0);
        for ([_]u16{ 0, 1, 19, 46, 99 }) |width| for (0..20) |height| {
            const drawn = try panel.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = @intCast(height) }, .cell_size = .{} });
            const expected = if (natural) @min(height, rows + 2 + @intFromBool(height > 3)) else height;
            try std.testing.expectEqual(@as(u16, @intCast(expected)), drawn.size.height);
            for (drawn.children) |child| {
                try std.testing.expect(child.origin.row + child.surface.size.height <= drawn.size.height);
                try std.testing.expect(child.origin.col + child.surface.size.width <= drawn.size.width);
            }
            _ = arena.reset(.retain_capacity);
        };
    };
}

test "Panel natural custom choice measures once shrinks and keeps cursor and mouse inside its bounded window" {
    const Child = struct {
        count: u16 = 5,
        draws: usize = 0,
        clicked: ?i16 = null,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = drawList, .eventHandler = click };
        }
        fn drawList(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.draws += 1;
            return vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = ctx.max.width.?, .height = @min(self.count, ctx.max.height.?) });
        }
        fn drawValue(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var shown = try vxfw.Surface.init(ctx.cell_arena, self.widget(), ctx.max.size());
            if (shown.size.width > 0 and shown.size.height > 0) shown.cursor = .{ .row = 0, .col = @min(2, shown.size.width - 1) };
            return shown;
        }
        fn click(raw: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .mouse) self.clicked = input.mouse.row;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var child: Child = .{};
    var panel: Self = .{ .title = "Chat", .natural_height = true, .fields = &.{ .{ .label = "Effort", .value = "high" }, .{ .label = "Hidden", .value = "", .visible = false }, .{ .label = "Model", .value = "model" }, .{ .label = "Context", .value = "0 of 100" } }, .actions = &.{ "Rename", "Archive" }, .action_gap = 1, .custom_choice = .{ .field = 2, .widget = child.widget(), .value_widget = .{ .userdata = &child, .drawFn = Child.drawValue } } };
    const roomy: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 99, .height = 40 }, .cell_size = .{} };
    const initial = try panel.widget().draw(roomy);
    try std.testing.expectEqual(@as(u16, 13), initial.size.height);
    try std.testing.expectEqual(@as(u16, 5), panel.custom_height);
    try std.testing.expectEqual(@as(usize, 1), child.draws);
    try std.testing.expectEqual(@as(u16, 3), initial.cursor.?.row);
    try std.testing.expectEqual(@as(u16, 21), initial.cursor.?.col);
    child.count = 2;
    const narrowed = try panel.widget().draw(roomy);
    try std.testing.expectEqual(@as(u16, 10), narrowed.size.height);
    try std.testing.expectEqual(@as(u16, 2), panel.custom_height);
    try std.testing.expectEqual(@as(usize, 2), child.draws);
    for ([_]u16{ 0, 1, 19, 20, 46, 99 }) |width| for (0..21) |height| {
        child.count = 8;
        child.clicked = null;
        const before = child.draws;
        const drawn = try panel.widget().draw(roomy.withConstraints(.{}, .{ .width = width, .height = @intCast(height) }));
        try std.testing.expect(drawn.size.height <= height);
        try std.testing.expect(child.draws - before <= 1);
        if (drawn.cursor) |cursor| {
            try std.testing.expect(cursor.row < drawn.size.height);
            try std.testing.expect(cursor.col < drawn.size.width);
        }
        for (drawn.children) |part| {
            try std.testing.expect(part.origin.row + part.surface.size.height <= drawn.size.height);
            try std.testing.expect(part.origin.col + part.surface.size.width <= drawn.size.width);
        }
        try panel.widget().handleEvent(&events, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(panel.custom_origin + panel.custom_height), .col = 0 } });
        try std.testing.expect(child.clicked == null);
        if (panel.custom_height > 0) {
            try panel.widget().handleEvent(&events, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(panel.custom_origin + panel.custom_height - 1), .col = 0 } });
            try std.testing.expectEqual(@as(?i16, @intCast(panel.custom_height - 1)), child.clicked);
        }
        _ = arena.reset(.retain_capacity);
    };
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
        const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
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
        const surface = try reference.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 4 }, .cell_size = .{} });
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

test "Panel hover highlights fields choices and actions without changing keyboard state" {
    var fixture: Fixture = .{};
    var panel: Self = .{ .title = "Settings", .fields = &.{ .{ .label = "One", .value = "1" }, .{ .label = "Two", .value = "2" } }, .actions = &.{ "Rename", "Archive" }, .ground = .{ .bg = .{ .index = 1 } }, .selection = .{ .bg = .{ .index = 2 } }, .hover_style = .{ .bg = .{ .index = 5 } }, .userdata = &fixture, .on_activate = Fixture.activateRow, .on_pick = Fixture.pickRow };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 10 }, .cell_size = .{} };
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

test "Panel choice-only renders title checked rows and bounded natural content without page chrome" {
    var fixture: Fixture = .{};
    var panel: Self = .{
        .title = "Settings must not appear",
        .fields = &.{ .{ .label = "Hidden", .value = "hidden" }, .{ .label = "Effort", .value = "high" } },
        .actions = &.{"No action"},
        .selected = 1,
        .userdata = &fixture,
        .on_pick = Fixture.pickRow,
    };
    panel.openChoice(&.{ "low", "high", "xhigh" }, 1);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 30 }, .cell_size = .{} };
    const drawn = try panel.drawChoice(ctx, 1);
    try std.testing.expectEqual(@as(u16, 4), drawn.size.height);
    try std.testing.expectEqualStrings("E", drawn.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings("✓", drawn.readCell(1, 2).char.grapheme);
    try std.testing.expectEqualStrings("h", drawn.readCell(3, 2).char.grapheme);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try panel.choiceEvent(&events, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 3, .col = 2 } }, 1);
    try std.testing.expectEqual(@as(?usize, 1), fixture.picked_field);
    try std.testing.expectEqual(@as(?usize, 2), fixture.picked);
    for ([_]u16{ 0, 1, 2, 3, 46 }) |width| for (0..8) |height| {
        panel.openChoice(&.{ "low", "high", "xhigh" }, 1);
        const tiny = try panel.drawChoice(ctx.withConstraints(.{}, .{ .width = width, .height = @intCast(height) }), 1);
        try std.testing.expect(tiny.size.height <= height);
        try std.testing.expect(tiny.size.width <= width);
        for (tiny.children) |child| {
            try std.testing.expect(child.origin.row + child.surface.size.height <= tiny.size.height);
            try std.testing.expect(child.origin.col + child.surface.size.width <= tiny.size.width);
        }
    };
}

test "Panel choice-only outcome navigation never activates hidden fields" {
    var fixture: Fixture = .{};
    var panel: Self = .{
        .title = "Settings",
        .fields = &.{ .{ .label = "Permissions", .value = "ask" }, .{ .label = "Effort", .value = "high", .tail = " · couldn't save" }, .{ .label = "Notifications", .value = "on" } },
        .selected = 1,
        .userdata = &fixture,
        .on_activate = Fixture.activateRow,
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u21{ vaxis.Key.up, vaxis.Key.down }) |key| {
        try panel.choiceEvent(&ctx, .{ .key_press = .{ .codepoint = key } }, 1);
        try std.testing.expectEqual(@as(usize, 1), panel.selected);
        try panel.choiceEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, 1);
        try std.testing.expectEqual(@as(?usize, 1), fixture.activated);
    }
    for ([_]vaxis.Mouse.Button{ .wheel_up, .wheel_down }) |button| {
        try panel.choiceEvent(&ctx, .{ .mouse = .{ .button = button, .type = .press, .mods = .{}, .row = 1, .col = 0 } }, 1);
        try std.testing.expectEqual(@as(usize, 1), panel.selected);
        try panel.choiceEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, 1);
        try std.testing.expectEqual(@as(?usize, 1), fixture.activated);
    }
    // Even stale field selection cannot grant Enter authority over a hidden field.
    panel.selected = 2;
    try panel.choiceEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, 1);
    try std.testing.expectEqual(@as(?usize, 1), fixture.activated);
}

test "Panel retained standalone fields share field targets hover and clipping with full pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} };
    for ([_]bool{ false, true }) |standalone| for ([_]bool{ false, true }) |selectable_field| {
        var fixture: Fixture = .{};
        var panel: Self = .{
            .title = "Settings",
            .fields = &.{ .{ .label = "Hidden", .value = "never" }, .{ .label = "Effort", .value = "high", .tail = " · couldn't save", .selectable = selectable_field } },
            .selected = 0,
            .userdata = &fixture,
            .on_activate = Fixture.activateRow,
            .hover_style = .{ .ul_style = .single },
        };
        const row: u16 = if (standalone) 1 else 3;
        _ = if (standalone) try panel.drawChoice(draw_ctx, 1) else try panel.widget().draw(draw_ctx);
        if (standalone) try panel.choiceEvent(&events, .{ .mouse = .{ .col = 45, .row = @intCast(row), .button = .none, .type = .motion, .mods = .{} } }, 1) else try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 45, .row = @intCast(row), .button = .none, .type = .motion, .mods = .{} } });
        const hovered = if (standalone) try panel.drawChoice(draw_ctx, 1) else try panel.widget().draw(draw_ctx);
        try std.testing.expectEqual(if (selectable_field) panel.hover_style.ul_style else panel.ground.ul_style, hovered.readCell(45, row).style.ul_style);
        try std.testing.expectEqual(@as(?usize, null), fixture.activated);
        // Tail/blank cells belong to the same full-width field action.
        if (standalone) try panel.choiceEvent(&events, .{ .mouse = .{ .col = 45, .row = @intCast(row), .button = .left, .type = .release, .mods = .{} } }, 1) else try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 45, .row = @intCast(row), .button = .left, .type = .release, .mods = .{} } });
        try std.testing.expectEqual(@as(?usize, null), fixture.activated);
        if (standalone) try panel.choiceEvent(&events, .{ .mouse = .{ .col = 45, .row = @intCast(row), .button = .left, .type = .press, .mods = .{} } }, 1) else try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 45, .row = @intCast(row), .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(if (selectable_field) @as(?usize, 1) else null, fixture.activated);
    };
    for ([_]u16{ 0, 1, 2, 46, 140 }) |width| for ([_]u16{ 0, 1, 2, 8 }) |height| {
        var fixture: Fixture = .{};
        var panel: Self = .{
            .title = "Settings",
            .fields = &.{ .{ .label = "Hidden", .value = "never" }, .{ .label = "Model", .value = "unavailable", .tail = " · couldn't read settings" } },
            .selected = 0,
            .userdata = &fixture,
            .on_activate = Fixture.activateRow,
        };
        // Draw a larger frame first: clipping must replace, not retain, targets.
        _ = try panel.drawChoice(draw_ctx, 1);
        const drawn = try panel.drawChoice(draw_ctx.withConstraints(.{}, .{ .width = width, .height = height }), 1);
        const actionable = width > 0 and height > 1;
        try std.testing.expectEqual(@as(usize, @intFromBool(actionable)), panel.targets.len);
        for (drawn.buffer, 0..) |cell, at| try std.testing.expect(at % @max(width, 1) + cell.char.width <= width);
        try panel.choiceEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .left, .type = .press, .mods = .{} } }, 1);
        try std.testing.expectEqual(if (actionable) @as(?usize, 1) else null, fixture.activated);
        if (!actionable) continue;
        fixture.activated = null;
        panel.openChoice(&.{ "one", "two" }, 0);
        _ = try panel.drawChoice(draw_ctx.withConstraints(.{}, .{ .width = width, .height = height }), 1);
        try std.testing.expect(panel.targets.len > 0);
        for (panel.targets) |target| try std.testing.expect(target.choice);
        panel.closeChoice();
        _ = try panel.drawChoice(draw_ctx.withConstraints(.{}, .{ .width = width, .height = 1 }), 1);
        try std.testing.expectEqual(@as(usize, 0), panel.targets.len);
        try panel.choiceEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .left, .type = .press, .mods = .{} } }, 1);
        try std.testing.expectEqual(@as(?usize, null), fixture.activated);
    };
}

test "Panel explicit choice scope never persists into normal page events or drawing" {
    var fixture: Fixture = .{};
    var panel: Self = .{
        .title = "Settings",
        .fields = &.{ .{ .label = "Model", .value = "model" }, .{ .label = "Effort", .value = "high" } },
        .userdata = &fixture,
        .on_activate = Fixture.activateRow,
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} };
    _ = try panel.drawChoice(ctx, 1);
    try panel.choiceEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, 1);
    try std.testing.expectEqual(@as(?usize, 1), fixture.activated);
    // No mode reset is needed: a later ordinary page draw/event is ordinary.
    const page = try panel.widget().draw(ctx);
    try std.testing.expectEqualStrings("─", page.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("M", page.readCell(3, 2).char.grapheme);
    try pressKey(&panel, &events, vaxis.Key.up);
    try pressKey(&panel, &events, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?usize, 0), fixture.activated);
    // The next standalone event likewise carries its own field, not page selection.
    try panel.choiceEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, 1);
    try std.testing.expectEqual(@as(?usize, 1), fixture.activated);
}
