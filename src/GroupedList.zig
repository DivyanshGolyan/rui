const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const List = @import("widgets/List.zig").List(overview_view.Target);
const RowInset = @import("widgets/RowInset.zig");

pub const Segment = overview_view.Segment;
pub const Target = overview_view.Target;
pub const Region = struct { start: u16, end: u16, target: Target, selected: bool = false };
pub const Row = struct {
    segments: []const Segment,
    heading: bool = false,
    target: ?Target = null,
    alternate_target: ?Target = null,
    regions: []const Region = &.{},
};

pub const Rows = struct {
    userdata: *const anyopaque,
    count: u32,
    countFromFn: ?*const fn (*const anyopaque, u32) u32 = null,
    findFn: ?*const fn (*const anyopaque, Target) ?u32 = null,
    rowFn: *const fn (userdata: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row,

    pub const none: Rows = .{ .userdata = undefined, .count = 0, .rowFn = undefined };

    pub fn of(rows: *const []const Row) Rows {
        return .{ .userdata = @ptrCast(rows), .count = @intCast(rows.len), .rowFn = struct {
            fn at(userdata: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
                const all: *const []const Row = @ptrCast(@alignCast(userdata));
                return all.*[index];
            }
        }.at };
    }
};

pub const Press = struct {
    userdata: *anyopaque,
    pressed: *const fn (*anyopaque, *vxfw.EventContext, Target) anyerror!void,
};
pub const Pointer = List.Pointer;
pub const Held = List.Held;

rows: Rows = .none,
selected: ?u32 = null,
selection_background: @import("overview_style.zig").Background = .selection,
on_press: ?Press = null,
on_pointer: ?Pointer = null,
on_presence: ?List.Presence = null,
edges: ?List.Edges = null,
caps: overview_view.Caps = .{},
inner: List = .{},
tail: ?Tail = null,
aboveFn: ?*const fn (u32, std.mem.Allocator) std.mem.Allocator.Error!List.Line = null,
belowFn: ?*const fn (u32, std.mem.Allocator) std.mem.Allocator.Error!List.Line = null,
list: *vxfw.ListView = undefined,
shown: List.Range = .{},
shown_at: []const List.Span = &.{},
anchor: ?struct { target: Target, index: u32, row: i17 } = null,
anchor_after_scroll: ?i16 = null,
pointer_row: ?i16 = null,

pub const Tail = struct { widget: vxfw.Widget, rows: u16 };

const Frame = struct {
    fn count(raw: *const anyopaque, first: u32) u32 {
        const owner: *const Self = @ptrCast(@alignCast(raw));
        return owner.rows.countFromFn.?(owner.rows.userdata, first);
    }

    fn row(raw: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!List.Row {
        const owner: *const Self = @ptrCast(@alignCast(raw));
        const built = try owner.rows.rowFn(owner.rows.userdata, index, arena);
        const selected = owner.selected != null and owner.selected.? == index;
        std.debug.assert(!(selected and built.heading));
        const segments = try widget_style.segments(arena, owner.caps, built.segments, if (selected) owner.selection_background else null);
        if (selected) for (built.segments, segments) |segment, *dest| {
            if (segment.style.background == .hover) dest.style.bold = true;
        };
        const regions = try arena.alloc(List.Region, built.regions.len);
        for (built.regions, regions) |region, *dest| {
            dest.* = .{ .start = region.start +| RowInset.left, .end = region.end +| RowInset.left, .target = region.target, .selected = region.selected };
        }
        const lines = try arena.dupe(List.Line, &.{segments});
        return .{ .lines = lines, .target = built.target, .alternate_target = built.alternate_target, .regions = regions };
    }
};

pub fn widget(self: *Self) vxfw.Widget {
    self.list = &self.inner.list;
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn reportPress(raw: *anyopaque, ctx: *vxfw.EventContext, target: Target) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const press = self.on_press orelse return;
    return press.pressed(press.userdata, ctx, target);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .mouse_leave => {
            self.anchor = null;
            self.anchor_after_scroll = null;
            self.pointer_row = null;
        },
        .mouse => |mouse| if (mouse.type == .motion or mouse.type == .press) {
            self.pointer_row = mouse.row;
            self.anchor = null;
            self.anchor_after_scroll = null;
            if (mouse.button == .wheel_up or mouse.button == .wheel_down or mouse.button == .wheel_left or mouse.button == .wheel_right) {
                try self.inner.widget().handleEvent(ctx, input);
                return;
            }
            for (self.shown_at, 0..) |span, offset| {
                if (mouse.row >= span.row and mouse.row < span.row + span.height) {
                    if (span.target) |target| self.anchor = .{ .target = target, .index = self.shown.first + @as(u32, @intCast(offset)), .row = span.row };
                    break;
                }
            }
        },
        else => {},
    }
    try self.inner.widget().handleEvent(ctx, input);
}

/// The shown rows after a wheel scroll, once a draw has applied it (see List.scrollReport). The pointer's anchor
/// moves with the scroll: the Session under the pointer, or the nearest one shown, so the next draw keeps it.
pub fn scrollReport(self: *Self) ?List.Scroll {
    const report = self.inner.scrollReport() orelse return null;
    self.recaptureAt(report.pointer_row);
    return report;
}

/// Anchors the Session shown under `row`, or else the nearest shown Session with a target (headings and the pinned
/// gap hold none). No shown Session leaves no anchor.
fn recaptureAt(self: *Self, row: i32) void {
    self.anchor = null;
    var best: ?struct { offset: usize, distance: i32 } = null;
    for (self.shown_at, 0..) |span, offset| {
        if (span.target == null) continue;
        const bottom = span.row + span.height - 1;
        const distance: i32 = if (row < span.row) span.row - row else if (row > bottom) row - bottom else 0;
        if (best == null or distance < best.?.distance) best = .{ .offset = offset, .distance = distance };
        if (distance == 0) break;
    }
    const pick = best orelse return;
    const span = self.shown_at[pick.offset];
    self.anchor = .{ .target = span.target.?, .index = self.shown.first + @as(u32, @intCast(pick.offset)), .row = span.row };
}

pub fn followSelection(self: *Self) void {
    if (self.pointer_row) |row| {
        self.anchor = null;
        self.anchor_after_scroll = row;
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.inner.anchor = null;
    if (self.anchor) |*anchor| if (self.rows.findFn) |find| {
        if (find(self.rows.userdata, anchor.target)) |index| {
            const top: i64 = @as(i64, self.inner.list.scroll.top) + @as(i64, index) - @as(i64, anchor.index);
            self.inner.list.scroll.top = @intCast(@max(0, top));
            anchor.index = index;
            self.inner.anchor = .{ .index = index, .row = @intCast(@max(0, anchor.row)) };
        } else self.anchor = null;
    };
    self.inner.on_presence = self.on_presence;
    self.inner.edges = self.edges;
    self.inner.inset_rows = true;
    self.inner.rows = .{ .userdata = self, .count = self.rows.count, .rowFn = Frame.row, .countFromFn = if (self.rows.countFromFn != null) Frame.count else null };
    self.inner.aboveFn = self.aboveFn;
    self.inner.belowFn = self.belowFn;
    self.inner.indicator_align = .center;
    self.inner.indicator_style = widget_style.of(self.caps, .{ .colour = .quiet });
    self.inner.selected = self.selected;
    self.inner.on_press = if (self.on_press != null) .{ .userdata = self, .pressed = reportPress } else null;
    self.inner.on_pointer = self.on_pointer;
    self.inner.base_style = widget_style.of(self.caps, .{});
    self.inner.selection_style = widget_style.of(self.caps, .{ .background = self.selection_background });
    self.inner.hover_style = widget_style.of(self.caps, .{ .background = .hover });
    const size = ctx.max.size();
    const tail_rows = if (self.tail) |tail| @min(tail.rows, size.height) else 0;
    const room = size.height - tail_rows;
    const tail = if (self.tail) |pinned| try pinned.widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = tail_rows })) else null;
    var surface = try self.inner.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = room }));
    if (tail) |drawn| {
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = surface };
        children[1] = .{ .origin = .{ .row = room, .col = 0 }, .surface = drawn };
        surface = .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
    }
    surface.widget = self.widget();
    self.shown = self.inner.shown;
    self.shown_at = self.inner.shown_at;
    if (self.anchor_after_scroll) |pointer_row| {
        self.anchor_after_scroll = null;
        for (self.shown_at, 0..) |span, offset| {
            if (pointer_row >= span.row and pointer_row < span.row + span.height) {
                if (span.target) |target| self.anchor = .{ .target = target, .index = self.shown.first + @as(u32, @intCast(offset)), .row = span.row };
                break;
            }
        }
    }

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
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 12, .height = 2 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    const cells = surface.children[0].surface;
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xeb, 0x9c, 0x84 } }, cells.readCell(2, 0).style.fg);
    try std.testing.expect(cells.readCell(2, 0).style.bold);
    try std.testing.expect(!cells.readCell(4, 0).style.bold);
    try std.testing.expect(!std.meta.eql(cells.readCell(2, 0).style.fg, cells.readCell(4, 0).style.fg));
    for ([_]u16{ 0, 2, 11 }) |column| {
        try std.testing.expectEqual(widget_style.of(list.caps, .{ .background = .selection }).bg, cells.readCell(column, 0).style.bg);
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

test "GroupedList quiet rows normalize whole lines before selection and hover in every colour depth" {
    const view = overview_view;
    for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| for ([_]bool{ false, true }) |wrote| for ([_]bool{ false, true }) |selected| for ([_]?i16{ null, 0, 1 }) |hover_row| for ([_]u16{ 46, 140 }) |width| {
        const caps: view.Caps = .{ .depth = depth };
        const token: view.Token = .{ .instance = @splat(0xab), .generation = 1 };
        var state: view.State = undefined;
        try state.init(std.testing.allocator, .{ .cwd = "/work/quiet", .home = "/work" });
        defer state.deinit();
        _ = try view.step(&state, .{ .host = .{ .instance = token.instance, .started_at = 100, .slots = 2, .slots_in_use = 0 } });
        _ = try view.step(&state, .{ .tick = 100_000 });
        const listed: view.Listed = .{
            .reference = "quiet1".*,
            .read_version = token,
            .workspace = "/work/quiet",
            .provider = @import("connection.zig").Name.parse("codex").?,
            .label = "Quiet row",
            .state = .{ .finished = .{ .since = 100 } },
            .state_change_at = 100,
            .subtree_state_change_at = 100,
            .descendant_count = 0,
            .descendant_needs_you_count = 0,
            .first = .{ .position = 1, .admission = 1, .sender = null, .content = .{ .text = .{ .length = 5, .digest = @splat(0xaa) } } },
            .from_person_at = if (wrote) 100 else null,
            .last_line = .{ .position = 1, .text = "Last answer" },
        };
        _ = try view.step(&state, .{ .list = .{ .page = .{ .rows = &.{listed}, .answer = .{ .delta = .full, .since = token } } } });
        state.selected = if (selected) .{ .session = listed.reference } else .new_session;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const first = (try view.Lines.at(arena.allocator(), &state, 0, width, caps, 0)).?;
        const rows: []const Row = &.{.{
            .segments = first.segments,
            .target = .{ .open = listed.reference },
        }};
        var presses: Pressed = .{};
        var list: Self = .{ .rows = .of(&rows), .selected = if (selected) 0 else null, .caps = caps, .on_press = presses.press() };
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 2 }, .cell_size = .{} };
        _ = try list.widget().draw(ctx);
        if (hover_row) |row| {
            var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = row, .button = .none, .type = .motion, .mods = .{} } });
        }
        const surface = try list.widget().draw(ctx);
        const hovered = hover_row == 0;
        const background: view.Background = if (selected) .selection else if (hovered) .hover else .ground;
        const highlight = widget_style.of(caps, .{ .background = background });
        for (surface.children[0].surface.buffer) |cell| {
            try std.testing.expectEqual(!wrote and !selected and !hovered, cell.style.dim);
            try std.testing.expectEqual(highlight.bg, cell.style.bg);
            try std.testing.expectEqual(highlight.reverse, cell.style.reverse);
            try std.testing.expectEqual(highlight.ul_style, cell.style.ul_style);
            if (depth == .none) try std.testing.expectEqual(vaxis.Color.default, cell.style.fg);
        }
        try std.testing.expectEqual(selected, surface.children[0].surface.readCell(5, 0).style.bold);
    };
}

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
    const surface = try list.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 5 }, .cell_size = .{} });
    try std.testing.expect(list.shown.first > 0);
    var drawn_at: [40]?i17 = @splat(null);
    for (surface.children, list.list.scroll.top..) |child, index| {
        if (index < drawn_at.len) drawn_at[index] = child.origin.row;
    }
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
    try list.widget().handleEvent(&events, leftPress(3, @intCast(drawn_at[heading].?)));
    try std.testing.expectEqual(expected, presses.count);
    try std.testing.expect(!events.consume_event);
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
    _ = try list.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 6 }, .cell_size = .{} });
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
    _ = try list.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 6 }, .cell_size = .{} });
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
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 5 }, .cell_size = .{} };
    _ = try list.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, leftPress(0, 1));
    try std.testing.expect(!events.consume_event);
    try std.testing.expectEqual(@as(?u32, null), list.selected);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .wheel_down, .type = .press, .mods = .{} } });
    _ = try list.widget().draw(ctx);
    try std.testing.expect(list.shown.first > 0);
}

test "GroupedList selects and presses a row with a pinned tail" {
    const rows: []const Row = &.{.{ .segments = &.{.{ .text = "first", .style = .{ .colour = .strong, .bold = true } }}, .target = .{ .open = numbered(1) } }};
    var presses: Pressed = .{};
    const tail: vxfw.Text = .{ .text = "rule\nSettings" };
    var list: Self = .{ .rows = .of(&rows), .selected = 0, .on_press = presses.press(), .tail = .{ .widget = tail.widget(), .rows = 2 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 8 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(i17, 6), surface.children[1].origin.row);
    const row = surface.children[0].surface.children[0].surface;
    try std.testing.expectEqual(@as(u16, 1), row.size.height);
    for ([_]u16{ 0, 10, 39 }) |x| try std.testing.expectEqual(widget_style.of(.{}, .{ .background = .selection }).bg, row.readCell(x, 0).style.bg);
    try std.testing.expect(row.readCell(2, 0).style.bold);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, leftPress(3, 0));
    try std.testing.expectEqual(@as(usize, 1), presses.count);
    try std.testing.expectEqualStrings(&numbered(1), &presses.targets[0].open);
}

test "GroupedList markers count Sessions not the New Session entry and stay quiet centered" {
    const Source = struct {
        fn row(_: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
            return .{ .segments = &.{.{ .text = "row", .style = .{} }}, .target = if (index == 0) .new_session else .{ .open = numbered(index) } };
        }
        fn count(_: *const anyopaque, first: u32) u32 {
            return 6 -| (first -| 1);
        }
        fn above(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!List.Line {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count_}) }});
        }
        fn below(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!List.Line {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↓ {d} more", .{count_}) }});
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]overview_view.Caps.Depth{ .direct, .none }) |depth| for ([_]u32{ 0, 6 }) |selected| {
        var list: Self = .{ .rows = .{ .userdata = undefined, .count = 7, .rowFn = Source.row, .countFromFn = Source.count }, .selected = selected, .aboveFn = Source.above, .belowFn = Source.below, .caps = .{ .depth = depth } };
        const surface = try list.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 4 }, .cell_size = .{} });
        const indicator = surface.children[if (selected == 0) surface.children.len - 1 else 1];
        try std.testing.expectEqual(@as(i17, if (selected == 0) 3 else 0), indicator.origin.row);
        var text: std.ArrayList(u8) = .empty;
        for (0..30) |x| try text.appendSlice(arena.allocator(), indicator.surface.readCell(@intCast(x), 0).char.grapheme);
        try std.testing.expectEqualStrings(if (selected == 0) "           ↓ 4 more           " else "           ↑ 3 more           ", text.items);
        try std.testing.expectEqual(widget_style.of(list.caps, .{ .colour = .quiet }).fg, indicator.surface.readCell(11, 0).style.fg);
    };
}

test "GroupedList selected row uses the owner's focused or inactive background" {
    const row = [_]Row{.{ .segments = &.{.{ .text = "Open chat", .style = .{} }} }};
    const rows: []const Row = &row;
    var list: Self = .{ .rows = .of(&rows), .selected = 0, .caps = .{ .depth = .direct } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    for ([_]@import("overview_style.zig").Background{ .selection, .bar }) |background| {
        list.selection_background = background;
        _ = try list.widget().draw(ctx);
        try std.testing.expectEqual(widget_style.of(list.caps, .{ .background = background }).bg, list.inner.selection_style.bg);
    }
}

test "Session pin gestures retain the drawn target and desired value without normal activation" {
    const first: Target = .{ .pin = .{ .reference = "k7m2qx".*, .pinned = true } };
    const second: Target = .{ .pin = .{ .reference = "rhvzwc".*, .pinned = false } };
    var rows = [_]Row{
        .{ .segments = &.{.{ .text = "header", .style = .{} }}, .heading = true },
        .{ .segments = &.{.{ .text = "Session", .style = .{} }}, .target = .{ .open = "k7m2qx".* }, .alternate_target = first },
        .{ .segments = &.{.{ .text = "New Session", .style = .{} }}, .target = .new_session },
        .{ .segments = &.{.{ .text = "Settings", .style = .{} }}, .target = .settings },
    };
    const source: []const Row = &rows;
    var pressed: Pressed = .{};
    var list: Self = .{ .rows = .of(&source), .on_press = pressed.press() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try list.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 8 }, .cell_size = .{} });
    rows[1].target = .{ .open = "rhvzwc".* };
    rows[1].alternate_target = second;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    defer events.cmds.deinit(events.alloc);
    for ([_]vaxis.Mouse{
        .{ .col = 3, .row = 1, .button = .right, .type = .press, .mods = .{} },
        .{ .col = 3, .row = 1, .button = .left, .type = .press, .mods = .{ .alt = true } },
    }) |mouse| {
        events.consume_event = false;
        try list.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expect(events.consume_event);
        try std.testing.expectEqualDeep(first, pressed.targets[pressed.count - 1]);
        var release = mouse;
        release.type = .release;
        try list.widget().handleEvent(&events, .{ .mouse = release });
    }
    try std.testing.expectEqual(@as(usize, 2), pressed.count);
    for ([_]i16{ 0, 2, 3 }) |row| for ([_]bool{ false, true }) |alt| {
        events.consume_event = false;
        try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = row, .button = if (alt) .left else .right, .type = .press, .mods = .{ .alt = alt } } });
        try std.testing.expectEqual(@as(usize, 2), pressed.count);
    };
    try list.widget().handleEvent(&events, leftPress(3, 1));
    try std.testing.expectEqualDeep(Target{ .open = "k7m2qx".* }, pressed.targets[2]);
    for (events.cmds.items) |cmd| switch (cmd) {
        .set_mouse_shape => {},
        else => return error.TestUnexpectedCommand,
    };
}

test "GroupedList row inset is stable for selection hover and plain rows" {
    const segments: []const Segment = &.{.{ .text = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", .style = .{} }};
    const row: Row = .{ .segments = segments, .target = .new_session };
    const rows: []const Row = &.{ row, row, row };
    for ([_]overview_view.Caps.Depth{ .direct, .indexed, .none }) |depth| for ([_]u16{ 0, 1, 2, 3, 4, 5, 8, 9, 20, 40, 46, 140 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var presses: Pressed = .{};
        var list: Self = .{ .rows = .of(&rows), .selected = 0, .caps = .{ .depth = depth }, .on_press = presses.press() };
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 3 }, .cell_size = .{} };
        _ = try list.widget().draw(ctx);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        if (width > 0) try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
        const surface = try list.widget().draw(ctx);
        if (width == 0) {
            try std.testing.expectEqual(@as(usize, 0), surface.children.len);
            continue;
        }
        const reference = surface.children[0].surface;
        if (width >= 5) try std.testing.expect(!std.mem.eql(u8, " ", reference.readCell(2, 0).char.grapheme));
        for (0..3) |y| {
            const line = surface.children[y].surface;
            for (0..width) |x| {
                const actual = line.readCell(@intCast(x), 0).char.grapheme;
                try std.testing.expectEqualStrings(reference.readCell(@intCast(x), 0).char.grapheme, actual);
                if (x < 2 or x >= width -| 2) try std.testing.expectEqualStrings(" ", actual);
                const ground: overview_view.Background = if (y == 0) .selection else if (y == 1) .hover else .ground;
                const style = widget_style.of(list.caps, .{ .background = ground });
                try std.testing.expectEqual(style.bg, line.readCell(@intCast(x), 0).style.bg);
                try std.testing.expectEqual(style.reverse, line.readCell(@intCast(x), 0).style.reverse);
            }
        }
    };
}
fn anchorStationaryCase() !void {
    const Fixture = struct {
        rows: []const Row,
        fn at(raw: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            return self.rows[index];
        }
        fn find(raw: *const anyopaque, target: Target) ?u32 {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            for (self.rows, 0..) |row, index| {
                if (row.target) |item| if (std.meta.eql(item, target)) return @intCast(index);
            }
            return null;
        }
        fn edge(_: *const anyopaque, side: List.Edge, _: List.Range, counts: List.Counts, _: std.mem.Allocator) std.mem.Allocator.Error!?List.Line {
            if (side == .above and counts.above > 0) return &.{.{ .text = "above" }};
            if (side == .below and counts.below > 0) return &.{.{ .text = "below" }};
            return null;
        }
    };
    const hovered: Target = .{ .open = "a1b2c3".* };
    const other: Target = .{ .open = "b4n8wd".* };
    const extra: Target = .{ .open = "c2d3f4".* };
    const before = [_]Row{
        .{ .segments = &.{.{ .text = "first", .style = .{} }}, .target = other },
        .{ .segments = &.{.{ .text = "hovered", .style = .{} }}, .target = hovered },
        .{ .segments = &.{.{ .text = "last", .style = .{} }}, .target = extra },
    };
    const after = [_]Row{
        before[0],
        .{ .segments = &.{.{ .text = "new child", .style = .{} }} },
        before[1],
        before[2],
    };
    var fixture: Fixture = .{ .rows = &before };
    var list: Self = .{
        .rows = .{ .userdata = &fixture, .count = before.len, .rowFn = Fixture.at, .findFn = Fixture.find },
        .edges = .{ .userdata = &fixture, .lineFn = Fixture.edge },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 3 }, .cell_size = .{} };
    _ = try list.widget().draw(ctx);
    const original = list.shown_at[1].row;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = @intCast(original), .button = .none, .type = .motion, .mods = .{} } });
    fixture.rows = &after;
    list.rows.count = after.len;
    _ = try list.widget().draw(ctx);
    const physical = for (list.shown_at) |span| {
        if (span.target) |target| if (std.meta.eql(target, hovered)) break span.row;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(original, physical);
    try list.widget().handleEvent(&events, .mouse_leave);
    try std.testing.expect(list.anchor == null);
}

fn flashStyleCase() !void {
    for ([_]overview_view.Caps.Depth{ .direct, .indexed, .none }) |depth| for ([_]bool{ false, true }) |selected| {
        var segments = [_]Segment{.{ .text = "task", .style = .{ .background = .hover } }};
        const rows: []const Row = &.{.{ .segments = &segments }};
        var list: Self = .{ .rows = .of(&rows), .selected = if (selected) 0 else null, .caps = .{ .depth = depth } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 12, .height = 1 }, .cell_size = .{} };
        const flashed = (try list.widget().draw(ctx)).children[0].surface.readCell(0, 0).style;
        segments[0].style.background = .ground;
        const settled = (try list.widget().draw(ctx)).children[0].surface.readCell(0, 0).style;
        try std.testing.expect(!std.meta.eql(flashed, settled));
        if (selected) {
            try std.testing.expect(flashed.bold);
            try std.testing.expectEqual(settled.bg, flashed.bg);
            try std.testing.expectEqual(settled.reverse, flashed.reverse);
        }
    };
}

fn anchorRecaptureCase() !void {
    const Fixture = struct {
        rows: []const Row,
        fn at(raw: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.rows[index];
        }
        fn find(raw: *const anyopaque, target: Target) ?u32 {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            for (self.rows, 0..) |row, index| {
                if (row.target) |item| if (std.meta.eql(item, target)) return @intCast(index);
            }
            return null;
        }
    };
    for ([_]?u32{ null, 0, 8 }) |selection| for ([_]bool{ false, true }) |keyboard| {
        var before: [8]Row = undefined;
        for (&before, 0..) |*row, index| row.* = .{ .segments = &.{.{ .text = "row", .style = .{} }}, .target = .{ .open = numbered(index) } };
        var after: [9]Row = undefined;
        after[0] = .{ .segments = &.{.{ .text = "new child", .style = .{} }}, .target = .{ .open = numbered(99) } };
        @memcpy(after[1..], &before);
        var fixture: Fixture = .{ .rows = &before };
        var list: Self = .{ .rows = .{ .userdata = &fixture, .count = before.len, .rowFn = Fixture.at, .findFn = Fixture.find } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 3 }, .cell_size = .{} };
        const first = try list.widget().draw(ctx);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
        if (keyboard) {
            list.selected = 7;
            list.followSelection();
            _ = try list.widget().draw(ctx);
        } else {
            try deliverWheel(arena.allocator(), first, &events, 1, 1);
            _ = try list.widget().draw(ctx);
            _ = list.scrollReport() orelse return error.TestExpectedEqual;
        }
        _ = try list.widget().draw(ctx);
        try std.testing.expect(list.shown.first > 0);
        const anchor = list.anchor orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(@as(i17, 1), anchor.row);
        fixture.rows = &after;
        list.rows.count = after.len;
        list.selected = selection;
        _ = try list.widget().draw(ctx);
        const physical = for (list.shown_at) |span| {
            if (span.target) |target| if (std.meta.eql(target, anchor.target)) break span.row;
        } else return error.TestExpectedEqual;
        try std.testing.expectEqual(anchor.row, physical);
    };
}

/// Delivers a wheel the way vxfw's App does: the hit test's deepest widget under the pointer first, then each
/// ancestor until one consumes the event.
fn deliverWheel(allocator: std.mem.Allocator, surface: vxfw.Surface, events: *vxfw.EventContext, row: u16, col: u16) !void {
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    defer hits.deinit(allocator);
    try surface.hitTest(allocator, &hits, .{ .row = row, .col = col });
    while (hits.pop()) |hit| {
        try hit.widget.handleEvent(events, .{ .mouse = .{ .row = @intCast(hit.local.row), .col = @intCast(hit.local.col), .button = .wheel_down, .type = .press, .mods = .{} } });
        if (events.consume_event) return;
    }
}

fn anchorHeadingCase() !void {
    const Fixture = struct {
        rows: []const Row,
        fn at(raw: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.rows[index];
        }
        fn find(raw: *const anyopaque, target: Target) ?u32 {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            for (self.rows, 0..) |row, index| {
                if (row.target) |item| if (std.meta.eql(item, target)) return @intCast(index);
            }
            return null;
        }
    };
    var rows: [9]Row = undefined;
    rows[0] = .{ .segments = &.{.{ .text = "heading", .style = .{} }} };
    for (rows[1..], 1..) |*row, index| row.* = .{ .segments = &.{.{ .text = "row", .style = .{} }}, .target = .{ .open = numbered(index) } };
    var fixture: Fixture = .{ .rows = &rows };
    var list: Self = .{ .rows = .{ .userdata = &fixture, .count = rows.len, .rowFn = Fixture.at, .findFn = Fixture.find } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 3 }, .cell_size = .{} };
    const first = try list.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    // The pointer is over the heading, which holds no Session: no anchor until a wheel scroll.
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
    try std.testing.expect(list.anchor == null);
    try deliverWheel(arena.allocator(), first, &events, 0, 1);
    _ = try list.widget().draw(ctx);
    _ = list.scrollReport() orelse return error.TestExpectedEqual;
    // The anchor is the nearest shown Session, and the next draw keeps it on its row.
    const anchor = list.anchor orelse return error.TestExpectedEqual;
    _ = try list.widget().draw(ctx);
    const physical = for (list.shown_at) |span| {
        if (span.target) |target| if (std.meta.eql(target, anchor.target)) break span.row;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(anchor.row, physical);
}

test "SUI-105 GroupedList preserves the pointer anchor across changes" {
    try anchorStationaryCase();
    try anchorRecaptureCase();
    try anchorHeadingCase();
}

test "SUI-106 GroupedList shows release flash with selection" {
    try flashStyleCase();
}
