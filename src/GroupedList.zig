//! Convert overview rows and press meanings to the generic list widget.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const List = @import("widgets/List.zig");

pub const Segment = overview_view.Segment;
/// What a press on a row means, as the screen's core takes it.
pub const Target = overview_view.Click;
pub const Row = struct {
    segments: []const Segment,
    heading: bool = false,
    /// What a left press on this row means; null for a row that takes
    /// none, as a heading or a gap.
    target: ?Target = null,
};

/// The list's rows, built one at a time as they come on screen, so a long
/// list costs only what shows.
pub const Rows = struct {
    userdata: *const anyopaque,
    count: u32,
    rowFn: *const fn (userdata: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row,

    pub const none: Rows = .{ .userdata = undefined, .count = 0, .rowFn = undefined };

    /// Rows already built, as `rows` holds them.
    pub fn of(rows: *const []const Row) Rows {
        return .{ .userdata = @ptrCast(rows), .count = @intCast(rows.len), .rowFn = struct {
            fn at(userdata: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
                const all: *const []const Row = @ptrCast(@alignCast(userdata));
                return all.*[index];
            }
        }.at };
    }
};

/// Who hears the meaning captured when a row was drawn.
pub const Press = struct {
    userdata: *anyopaque,
    pressed: *const fn (*anyopaque, *vxfw.EventContext, Target) anyerror!void,
};

rows: Rows = .none,
selected: ?u32 = null,
on_press: ?Press = null,
caps: overview_view.Caps = .{},
inner: List = .{},
/// Borrowed alias to the widget's scrolling owner, established by widget().
list: *vxfw.ListView = undefined,
shown: List.Range = .{},
shown_at: []const Span = &.{},

const Span = struct { row: i17, height: u16, target: ?Target };
const Captured = struct { id: u32, target: Target };

/// Per-draw conversion state and captured meanings live with the frame.
const Frame = struct {
    owner: *Self,
    targets: std.ArrayList(Captured) = .empty,

    fn row(raw: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!List.Row {
        const self: *Frame = @ptrCast(@alignCast(@constCast(raw)));
        const owner = self.owner;
        const built = try owner.rows.rowFn(owner.rows.userdata, index, arena);
        const selected = owner.selected != null and owner.selected.? == index;
        std.debug.assert(!(selected and built.heading));
        const segments = try arena.alloc(vaxis.Segment, built.segments.len);
        for (built.segments, segments) |segment, *dest| {
            var role = segment.style;
            if (selected) role.background = .selection;
            dest.* = .{ .text = segment.text, .style = widget_style.of(owner.caps, role) };
        }
        if (built.target) |target| try self.targets.append(arena, .{ .id = @intCast(index), .target = target });
        const lines = try arena.alloc(List.Line, 1);
        lines[0] = segments;
        return .{ .lines = lines, .target = if (built.target != null) @intCast(index) else null };
    }
};

pub fn widget(self: *Self) vxfw.Widget {
    self.list = &self.inner.list;
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn reportPress(raw: *anyopaque, ctx: *vxfw.EventContext, id: u32) anyerror!void {
    const frame: *Frame = @ptrCast(@alignCast(raw));
    const press = frame.owner.on_press orelse return;
    for (frame.targets.items) |target| if (target.id == id) return press.pressed(press.userdata, ctx, target.target);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.inner.widget().handleEvent(ctx, input);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const frame = try ctx.arena.create(Frame);
    frame.* = .{ .owner = self };
    self.inner.rows = .{ .userdata = frame, .count = self.rows.count, .rowFn = Frame.row };
    self.inner.selected = self.selected;
    self.inner.on_press = if (self.on_press != null) .{ .userdata = frame, .pressed = reportPress } else null;
    self.inner.base_style = widget_style.of(self.caps, .{});
    self.inner.selection_style = widget_style.of(self.caps, .{ .background = .selection });
    var surface = try self.inner.widget().draw(ctx);
    surface.widget = self.widget();
    self.shown = self.inner.shown;
    const spans = try ctx.arena.alloc(Span, self.inner.shown_at.len);
    for (self.inner.shown_at, spans) |span, *dest| {
        const target = if (span.target) |id| for (frame.targets.items) |item| {
            if (item.id == id) break item.target;
        } else null else null;
        dest.* = .{ .row = span.row, .height = span.height, .target = target };
    }
    self.shown_at = spans;
    return surface;
}

test "GroupedList selection preserves each segment foreground" {
    var rows = [_]Row{.{ .segments = &.{
        .{ .text = "!", .style = .{ .colour = .failure, .bold = true } },
        .{ .text = " task", .style = .{ .colour = .strong } },
    } }};
    const all: []const Row = &rows;
    var list: Self = .{ .rows = .of(&all), .selected = 0 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 12, .height = 2 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    const cells = surface.children[0].surface;
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xf0, 0x8b, 0x74 } }, cells.readCell(0, 0).style.fg);
    try std.testing.expect(cells.readCell(0, 0).style.bold);
    try std.testing.expect(!cells.readCell(2, 0).style.bold);
    try std.testing.expect(!std.meta.eql(cells.readCell(0, 0).style.fg, cells.readCell(2, 0).style.fg));
    for ([_]u16{ 0, 2, 11 }) |column| {
        try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x2a, 0x34, 0x67 } }, cells.readCell(column, 0).style.bg);
    }
    list.caps.depth = .none;
    const plain = try list.widget().draw(ctx);
    for ([_]u16{ 0, 2, 11 }) |column| {
        const cell = plain.children[0].surface.readCell(column, 0);
        try std.testing.expectEqual(vaxis.Color.default, cell.style.fg);
        try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
        try std.testing.expect(cell.style.reverse);
    }
}

/// Records each press GroupedList reports, for the press tests.
const Pressed = struct {
    targets: [8]Target = undefined,
    count: usize = 0,

    fn press(self: *Pressed) Press {
        return .{ .userdata = self, .pressed = pressed };
    }

    fn pressed(raw: *anyopaque, _: *vxfw.EventContext, target: Target) anyerror!void {
        const self: *Pressed = @ptrCast(@alignCast(raw));
        self.targets[self.count] = target;
        self.count += 1;
    }
};

fn leftPress(column: i16, row: i16) vxfw.Event {
    return .{ .mouse = .{ .col = column, .row = row, .button = .left, .type = .press, .mods = .{} } };
}

/// The Session a numbered test row names.
fn numbered(index: usize) overview_view.Reference {
    var reference: overview_view.Reference = undefined;
    _ = std.fmt.bufPrint(&reference, "r{d:0>5}", .{index}) catch unreachable;
    return reference;
}

test "GroupedList reports a left press as what the row under it drew with, after scrolling; a row with nothing takes none" {
    const Numbered = struct {
        fn row(_: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const heading = index % 3 == 0;
            return .{ .segments = try arena.dupe(Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "row {d}", .{index}), .style = .{} }}), .heading = heading, .target = if (heading) null else .{ .open = numbered(index) } };
        }
    };
    var presses: Pressed = .{};
    var list: Self = .{ .rows = .{ .userdata = undefined, .count = 40, .rowFn = Numbered.row }, .selected = 25, .on_press = presses.press() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try list.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 5 }, .cell_size = .{} });
    try std.testing.expect(list.shown.first > 0);
    // Find the screen row each index landed on from what was drawn, not
    // from how the list scrolls.
    var drawn_at: [40]?i17 = @splat(null);
    for (surface.children, list.list.scroll.top..) |child, index| {
        if (index < drawn_at.len) drawn_at[index] = child.origin.row;
    }
    // A shown heading, the first multiple of three on screen.
    const heading = (list.shown.first + 2) / 3 * 3;
    try std.testing.expect(heading < list.shown.end and heading != 25);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var expected: usize = 0;
    for ([_]u32{ list.shown.first, 25, list.shown.end - 1 }) |index| {
        if (index % 3 == 0) continue;
        try list.widget().handleEvent(&events, leftPress(3, @intCast(drawn_at[index].?)));
        expected += 1;
        try std.testing.expectEqual(expected, presses.count);
        try std.testing.expectEqualStrings(&numbered(index), &presses.targets[presses.count - 1].open);
        try std.testing.expect(events.consume_event);
        events.consume_event = false;
    }
    try std.testing.expect(expected >= 1);
    // A heading drew with nothing to press, so its press reaches no one.
    try list.widget().handleEvent(&events, leftPress(3, @intCast(drawn_at[heading].?)));
    try std.testing.expectEqual(expected, presses.count);
    try std.testing.expect(!events.consume_event);
    // Only a left press counts.
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = @intCast(drawn_at[25].?), .button = .right, .type = .press, .mods = .{} } });
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = @intCast(drawn_at[25].?), .button = .left, .type = .release, .mods = .{} } });
    try std.testing.expectEqual(expected, presses.count);
}

test "GroupedList ignores a press below its last row" {
    var rows = [_]Row{
        .{ .segments = &.{.{ .text = "Active", .style = .{ .bold = true } }}, .heading = true },
        .{ .segments = &.{.{ .text = "Only task", .style = .{} }}, .target = .{ .open = numbered(1) } },
    };
    const all: []const Row = &rows;
    var presses: Pressed = .{};
    var list: Self = .{ .rows = .of(&all), .on_press = presses.press() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try list.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 6 }, .cell_size = .{} });
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]i16{ 2, 5 }) |row| try list.widget().handleEvent(&events, leftPress(0, row));
    try std.testing.expectEqual(@as(usize, 0), presses.count);
    try std.testing.expect(!events.consume_event);
    try list.widget().handleEvent(&events, leftPress(0, 1));
    try std.testing.expectEqual(@as(usize, 1), presses.count);
    try std.testing.expectEqualStrings(&numbered(1), &presses.targets[0].open);
}

test "GroupedList reports what a row drew with, not what its index holds by the time of the press" {
    var rows = [_]Row{
        .{ .segments = &.{.{ .text = "First task", .style = .{} }}, .target = .{ .open = numbered(1) } },
        .{ .segments = &.{.{ .text = "Second task", .style = .{} }}, .target = .{ .open = numbered(2) } },
    };
    var all: []const Row = &rows;
    var presses: Pressed = .{};
    var list: Self = .{ .rows = .of(&all), .on_press = presses.press() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try list.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 6 }, .cell_size = .{} });
    // The rows change before the next frame: the first is gone.
    all = rows[1..];
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, leftPress(0, 0));
    try std.testing.expectEqualStrings(&numbered(1), &presses.targets[0].open);
}

test "GroupedList without on_press only scrolls on the wheel" {
    const Plain = struct {
        fn row(_: *const anyopaque, _: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row {
            return .{ .segments = try arena.dupe(Segment, &.{.{ .text = "task", .style = .{} }}) };
        }
    };
    var list: Self = .{ .rows = .{ .userdata = undefined, .count = 40, .rowFn = Plain.row } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 5 }, .cell_size = .{} };
    _ = try list.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, leftPress(0, 1));
    try std.testing.expect(!events.consume_event);
    try std.testing.expectEqual(@as(?u32, null), list.selected);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .wheel_down, .type = .press, .mods = .{} } });
    _ = try list.widget().draw(ctx);
    try std.testing.expect(list.shown.first > 0);
}
