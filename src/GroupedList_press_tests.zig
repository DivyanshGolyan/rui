const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const GroupedList = @import("GroupedList.zig");
const Target = GroupedList.Target;
const RowInset = @import("widgets/RowInset.zig");
const widget_style = @import("widget_style.zig");

// Independent input values: every overview target tag, both pin intentions,
// and update snapshots with absent, available, running and completed status.
const targets = [_]Target{
    .{ .open = "k7m2qx".* },
    .{ .open = "rhvzwc".* },
    .{ .pin = .{ .reference = "k7m2qx".*, .pinned = true } },
    .{ .pin = .{ .reference = "rhvzwc".*, .pinned = false } },
    .new_session,
    .sessions,
    .archived,
    .settings,
    .{ .update = .{ .available = null, .run = null } },
    .{ .update = .{ .available = .{ .schema = 42, .patch = 17 }, .run = null } },
    .{ .update = .{ .available = .{ .schema = 43, .patch = 2 }, .run = .{ .installing = .{ .found = .{ .host = .{ .running = 23 } }, .step = .restarting } } } },
    .{ .update = .{ .available = null, .run = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 44, .patch = 9 }, .restarted = true } }, .outcome = .compatible } } } },
};

const Pressed = struct {
    count: usize = 0,
    last: ?Target = null,

    fn handler(self: *Pressed) GroupedList.Press {
        return .{ .userdata = self, .pressed = pressed };
    }

    fn pressed(raw: *anyopaque, _: *vxfw.EventContext, target: Target) anyerror!void {
        const self: *Pressed = @ptrCast(@alignCast(raw));
        self.count += 1;
        self.last = target;
    }

    fn expect(self: *Pressed, list: *GroupedList, ctx: *vxfw.EventContext, mouse: vaxis.Mouse, expected: ?Target) !void {
        const before = self.count;
        ctx.consume_event = false;
        try list.widget().handleEvent(ctx, .{ .mouse = mouse });
        try std.testing.expectEqual(before + @intFromBool(expected != null), self.count);
        try std.testing.expectEqual(expected != null, ctx.consume_event);
        if (expected) |target| try std.testing.expectEqualDeep(target, self.last.?);
    }
};

fn left(col: i16, row: i16) vaxis.Mouse {
    return .{ .col = col, .row = row, .button = .left, .type = .press, .mods = .{} };
}

fn draw(list: *GroupedList, arena: std.mem.Allocator, width: u16, height: u16) !vxfw.Surface {
    return list.widget().draw(.{ .arena = arena, .cell_arena = arena, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
}

fn expectColumns(pressed: *Pressed, list: *GroupedList, events: *vxfw.EventContext, primary: Target, alternate: Target, first: Target, second: Target) !void {
    for (0..24) |column| {
        const col: i16 = @intCast(column);
        const expected = if (column >= 6 and column < 11) first else if (column >= 14 and column < 19) second else primary;
        try pressed.expect(list, events, left(col, 0), expected);
        var right = left(col, 0);
        right.button = .right;
        try pressed.expect(list, events, right, alternate);
        var alt = left(col, 0);
        alt.mods.alt = true;
        try pressed.expect(list, events, alt, alternate);
    }
}

test "GroupedList press domain preserves every target and region boundary across source changes and redraw" {
    // A new target tag must be added to the independent fixture above.
    inline for (std.enums.values(std.meta.Tag(Target))) |tag| {
        var covered = false;
        for (targets) |target| if (std.meta.activeTag(target) == tag) {
            covered = true;
        };
        try std.testing.expect(covered);
    }
    for (targets, 0..) |primary, index| for ([_]bool{ false, true }) |selected| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const alternate = targets[(index + 1) % targets.len];
        const first = targets[(index + 2) % targets.len];
        const second = targets[(index + 3) % targets.len];
        var regions = [_]GroupedList.Region{
            .{ .start = 4, .end = 9, .target = first },
            .{ .start = 12, .end = 17, .target = second, .selected = true },
        };
        var rows = [_]GroupedList.Row{.{ .segments = &.{.{ .text = "click targets", .style = .{} }}, .target = primary, .alternate_target = alternate, .regions = &regions }};
        const source: []const GroupedList.Row = &rows;
        var pressed: Pressed = .{};
        var list: GroupedList = .{ .props = .{ .rows = .of(&source), .selected = if (selected) 0 else null, .on_press = pressed.handler() } };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer events.cmds.deinit(events.alloc);
        const surface = try draw(&list, arena.allocator(), 24, 1);
        const line = surface.children[0].surface;
        try std.testing.expectEqualStrings("c", line.readCell(RowInset.left, 0).char.grapheme);
        for (0..24) |column| {
            const expected = widget_style.of(list.props.caps, .{ .background = if (selected or (column >= 14 and column < 19)) .selection else .ground });
            const actual = line.readCell(@intCast(column), 0).style;
            try std.testing.expectEqual(expected.bg, actual.bg);
            try std.testing.expectEqual(expected.reverse, actual.reverse);
        }
        const next_primary = targets[(index + 4) % targets.len];
        const next_alternate = targets[(index + 5) % targets.len];
        const next_first = targets[(index + 6) % targets.len];
        const next_second = targets[(index + 7) % targets.len];
        rows[0].target = next_primary;
        rows[0].alternate_target = next_alternate;
        regions[0].target = next_first;
        regions[1].target = next_second;
        try expectColumns(&pressed, &list, &events, primary, alternate, first, second);
        _ = try draw(&list, arena.allocator(), 24, 1);
        try expectColumns(&pressed, &list, &events, next_primary, next_alternate, next_first, next_second);
    };
}

test "GroupedList press domain leaves gaps empty lines headings and outside cells inactive" {
    const rows = [_]GroupedList.Row{
        .{ .segments = &.{.{ .text = "Session", .style = .{} }}, .target = targets[0] },
        .{ .segments = &.{} }, // Pinned/unpinned separator.
        .{ .segments = &.{.{ .text = "No Sessions", .style = .{} }}, .heading = true },
        .{ .segments = &.{.{ .text = "    ", .style = .{} }} },
        .{ .segments = &.{.{ .text = "Sessions / Archived", .style = .{} }}, .regions = &.{
            .{ .start = 2, .end = 7, .target = .sessions },
            .{ .start = 10, .end = 18, .target = .archived },
        } },
        .{ .segments = &.{.{ .text = "Settings", .style = .{} }}, .target = .settings },
    };
    const source: []const GroupedList.Row = &rows;
    var pressed: Pressed = .{};
    var list: GroupedList = .{ .props = .{ .rows = .of(&source), .on_press = pressed.handler() } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    defer events.cmds.deinit(events.alloc);
    try pressed.expect(&list, &events, left(0, 0), null);
    _ = try draw(&list, arena.allocator(), 24, 8);
    for (0..8) |row| for (0..24) |column| {
        const expected: ?Target = switch (row) {
            0 => targets[0],
            4 => if (column >= 4 and column < 9) .sessions else if (column >= 12 and column < 20) .archived else null,
            5 => .settings,
            else => null,
        };
        const mouse = left(@intCast(column), @intCast(row));
        try pressed.expect(&list, &events, mouse, expected);
        var right = mouse;
        right.button = .right;
        try pressed.expect(&list, &events, right, null);
        var alt = mouse;
        alt.mods.alt = true;
        try pressed.expect(&list, &events, alt, null);
    };
    for ([_]vaxis.Mouse{ left(-1, 0), left(24, 0), left(0, -1), left(0, 8) }) |mouse| {
        try pressed.expect(&list, &events, mouse, null);
    }
    for ([_]vaxis.Mouse{
        .{ .col = 3, .row = 0, .button = .left, .type = .release, .mods = .{} },
        .{ .col = 3, .row = 0, .button = .right, .type = .release, .mods = .{} },
        .{ .col = 3, .row = 0, .button = .middle, .type = .press, .mods = .{} },
        .{ .col = 3, .row = 0, .button = .left, .type = .motion, .mods = .{} },
    }) |mouse| try pressed.expect(&list, &events, mouse, null);
}

test "GroupedList press domain clears old targets for empty and zero size frames and absent handlers" {
    const rows = [_]GroupedList.Row{.{ .segments = &.{.{ .text = "Session", .style = .{} }}, .target = targets[0], .alternate_target = targets[2], .regions = &.{.{ .start = 4, .end = 9, .target = .settings }} }};
    const source: []const GroupedList.Row = &rows;
    for (0..4) |mode| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pressed: Pressed = .{};
        var list: GroupedList = .{ .props = .{ .rows = .of(&source), .on_press = pressed.handler() } };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer events.cmds.deinit(events.alloc);
        _ = try draw(&list, arena.allocator(), 24, 2);
        try pressed.expect(&list, &events, left(0, 0), targets[0]);
        switch (mode) {
            0 => list.props.rows = .none,
            1, 2 => {},
            3 => list.props.on_press = null,
            else => unreachable,
        }
        _ = try draw(&list, arena.allocator(), if (mode == 1) 0 else 24, if (mode == 2) 0 else 2);
        for ([_]i16{ 0, 4, 6, 10, 11, 23 }) |column| {
            const mouse = left(column, 0);
            try pressed.expect(&list, &events, mouse, null);
            var right = mouse;
            right.button = .right;
            try pressed.expect(&list, &events, right, null);
            var alt = mouse;
            alt.mods.alt = true;
            try pressed.expect(&list, &events, alt, null);
        }
    }
}

test "GroupedList press domain maps every target through scrolling past gaps and empty lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var labels: [targets.len][1]u8 = undefined;
    var segments: [targets.len][1]GroupedList.Segment = undefined;
    var regions: [targets.len][1]GroupedList.Region = undefined;
    var rows: [targets.len * 3]GroupedList.Row = undefined;
    for (targets, 0..) |target, index| {
        labels[index] = .{@as(u8, 'A') + @as(u8, @intCast(index))};
        segments[index] = .{.{ .text = &labels[index], .style = .{} }};
        regions[index] = .{.{ .start = 4, .end = 9, .target = targets[(index + 2) % targets.len] }};
        rows[index * 3] = .{ .segments = &.{} };
        rows[index * 3 + 1] = .{ .segments = &segments[index], .target = target, .alternate_target = targets[(index + 1) % targets.len], .regions = &regions[index] };
        rows[index * 3 + 2] = .{ .segments = &.{.{ .text = "", .style = .{} }}, .heading = true };
    }
    const source: []const GroupedList.Row = &rows;
    var pressed: Pressed = .{};
    var list: GroupedList = .{ .props = .{ .rows = .of(&source), .on_press = pressed.handler() } };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    defer events.cmds.deinit(events.alloc);
    for (targets, 0..) |_, selected| {
        list.props.selected = @intCast(selected * 3 + 1);
        const surface = try draw(&list, arena.allocator(), 24, 5);
        if (selected > 1) try std.testing.expect(list.shown.first > 0);
        var saw_selected = false;
        // Read the fixture's visible letter from terminal cells. This oracle
        // does not use shown_at, the adapter's target table or scroll indices.
        for (surface.children) |child| {
            if (child.origin.row < 0 or child.origin.row >= 5 or child.surface.size.height == 0) continue;
            const glyph = child.surface.readCell(RowInset.left, 0).char.grapheme;
            const index: ?usize = if (glyph.len == 1 and glyph[0] >= 'A' and glyph[0] < 'A' + targets.len) glyph[0] - 'A' else null;
            if (index == selected) saw_selected = true;
            for ([_]i16{ 0, 4, 5, 6, 10, 11, 12, 23 }) |col| {
                const mouse = left(col, @intCast(child.origin.row));
                const expected: ?Target = if (index) |at| targets[(at + @as(usize, if (col >= 6 and col < 11) 2 else 0)) % targets.len] else null;
                try pressed.expect(&list, &events, mouse, expected);
                const alternate: ?Target = if (index) |at| targets[(at + 1) % targets.len] else null;
                var right = mouse;
                right.button = .right;
                try pressed.expect(&list, &events, right, alternate);
                var alt = mouse;
                alt.mods.alt = true;
                try pressed.expect(&list, &events, alt, alternate);
            }
        }
        try std.testing.expect(saw_selected);
    }
}
