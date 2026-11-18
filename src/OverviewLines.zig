const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const Hover = @import("widgets/Hover.zig");

pub const Header = struct {
    drawn: bool = false,
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},
    pub fn widget(self: *Header) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Header = @ptrCast(@alignCast(raw));
        const width = ctx.max.width orelse 0;
        const lines = try overview_view.headerSegments(ctx.arena, self.state, width, self.caps);
        const spans = try widget_style.segments(ctx.arena, self.caps, lines, null);
        const text: vxfw.RichText = .{ .text = spans, .softwrap = false, .width_basis = .parent };
        var surface = try text.draw(ctx.withConstraints(.{ .width = width }, ctx.max));
        self.drawn = width > 0 and surface.size.height > 0 and lines.len > 0;
        surface.widget = self.widget();
        return surface;
    }
};

pub const SessionControls = struct {
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},
    userdata: *anyopaque,
    on_click: *const fn (*anyopaque, *vxfw.EventContext, overview_view.Click) anyerror!void,
    row: @import("GroupedList.zig") = .{},

    pub fn widget(self: *SessionControls) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw, .eventHandler = event };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        const self: *SessionControls = @ptrCast(@alignCast(raw));
        if (value == .mouse and (value.mouse.button == .wheel_up or value.mouse.button == .wheel_down)) return;
        try self.row.widget().handleEvent(ctx, value);
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SessionControls = @ptrCast(@alignCast(raw));
        const GroupedList = @import("GroupedList.zig");
        const width = @import("widgets/RowInset.zig").contentWidth(ctx.max.width.?);
        const lines = try overview_view.controls(ctx.arena, self.state, width, self.caps);
        const rows = try ctx.arena.create([]const GroupedList.Row);
        const projected = try ctx.arena.alloc(GroupedList.Row, lines.len);
        for (lines, projected) |line, *row| {
            const regions = try ctx.arena.alloc(GroupedList.Region, line.regions.len);
            for (line.regions, regions) |region, *target| target.* = .{ .start = region.start, .end = region.end, .target = region.target, .selected = region.selected };
            row.* = .{ .segments = line.segments, .target = line.target, .regions = regions };
        }
        rows.* = projected;
        self.row.rows = .of(rows);
        self.row.selected = if (self.state.selected == .new_session) 0 else null;
        self.row.caps = self.caps;
        self.row.on_press = .{ .userdata = self.userdata, .pressed = self.on_click };
        var surface = try self.row.widget().draw(ctx.withConstraints(.{}, .{ .width = ctx.max.width.?, .height = @min(2, ctx.max.height.?) }));
        surface.widget = self.widget();
        return surface;
    }
};

fn cells(arena: std.mem.Allocator, surface: vxfw.Surface, row: u16) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..surface.size.width) |column| try text.appendSlice(arena, surface.readCell(@intCast(column), row).char.grapheme);
    return text.items;
}

const Clicks = struct {
    got: ?overview_view.Click = null,
    fn take(raw: *anyopaque, _: *vxfw.EventContext, click: overview_view.Click) anyerror!void {
        const self: *Clicks = @ptrCast(@alignCast(raw));
        self.got = click;
    }
};

test "overview header draws no counts view name or Host-stopped band" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var header: Header = .{ .state = &state };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 50, .height = 6 }, .cell_size = .{} };
    const plain = try header.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 0), plain.size.height);
    state.archive = .archived;
    state.list_stale = true;
    const stopped = try header.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 0), stopped.size.height);
}

pub const Settings = struct {
    selected: bool,
    memory: ?overview_view.Memory = null,
    available: ?@import("upgrade_status.zig").Version = null,
    run: ?@import("upgrade_status.zig").Run = null,
    update_target: ?Hover.Rect = null,
    update_identity: @import("upgrade_status.zig").Target = .{ .available = null, .run = null },
    hover: Hover = .{},
    size: vxfw.Size = .{ .width = 0, .height = 0 },
    caps: overview_view.Caps,
    userdata: *anyopaque,
    on_click: *const fn (*anyopaque, *vxfw.EventContext, overview_view.Click) anyerror!void,

    pub fn widget(self: *Settings) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    /// Runs the semantic Settings action selected by the screen focus owner.
    pub fn activate(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
        const self: *Settings = @ptrCast(@alignCast(raw));
        try self.on_click(self.userdata, ctx, .settings);
        ctx.consumeAndRedraw();
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
        const self: *Settings = @ptrCast(@alignCast(raw));
        try self.hover.handleEvent(ctx, input);
        if (input != .mouse) return;
        const mouse = input.mouse;
        if (mouse.button != .left or mouse.mods.alt or mouse.type != .press or mouse.col < 0 or mouse.col >= self.size.width) return;
        const click: overview_view.Click = if (mouse.row == 1 and self.size.height > 1 and mouse.col >= 5 and mouse.col < @min(13, self.size.width -| 2)) .settings else if (self.update_target) |target| (if (target.contains(mouse.col, mouse.row)) .{ .update = self.update_identity } else return) else return;
        try self.on_click(self.userdata, ctx, click);
        ctx.consumeAndRedraw();
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Settings = @ptrCast(@alignCast(raw));
        const size = ctx.max.size();
        const height = @min(2, size.height);
        self.size = .{ .width = size.width, .height = height };
        self.update_target = null;
        self.update_identity = .{ .available = self.available, .run = self.run };
        const target: Hover.Rect = .{ .row = 1, .col = @min(5, size.width), .width = @min(13, size.width -| 2) -| @min(5, size.width) };
        const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), self.size);
        @memset(surface.buffer, .{ .style = widget_style.of(self.caps, .{ .colour = .quiet }) });
        self.hover.targets = &.{};
        if (height == 0 or size.width == 0) return surface;
        for (0..size.width) |column| surface.writeCell(@intCast(column), 0, widget_style.line(self.caps, .horizontal));
        if (height < 2) return surface;
        const ground: overview_view.Background = if (self.selected) .selection else if (self.hover.contains(target)) .hover else .ground;
        const row_style = widget_style.of(self.caps, .{ .background = ground });
        @memset(surface.buffer[size.width .. 2 * size.width], .{ .style = row_style });
        try @import("widgets/RowInset.zig").draw(ctx, surface, 1, &.{.{ .text = "   Settings", .style = widget_style.of(self.caps, .{ .colour = if (self.selected) .strong else .normal, .bold = self.selected, .background = ground }) }}, row_style);
        self.hover.targets = try ctx.arena.dupe(Hover.Rect, &.{target});
        const status = @import("upgrade_status.zig");
        var buffer: [status.max_line_bytes]u8 = undefined;
        const update = status.control(@import("transport_options").version, self.available, self.run, &buffer, if (self.caps.unicode) .unicode else .ascii);
        const busy = if (self.run) |run| run.going() else false;
        const show_update = update.tone != .quiet or busy;
        const text = if (show_update)
            if (update.tone == .warning) "Update failed" else update.text
        else
            try @import("memory_text.zig").sidebar(ctx.arena, self.memory, size.width -| 15);
        const text_width = @import("display_text.zig").width(text, .terminal);
        if (text_width > 0 and text_width + 15 <= size.width) {
            const start: u16 = size.width - @as(u16, @intCast(text_width)) - 1;
            const style = widget_style.of(self.caps, .{ .colour = if (!show_update) .quiet else switch (update.tone) {
                .quiet => .quiet,
                .link => .ink,
                .warning => .attention,
            }, .background = ground });
            const stable = try ctx.arena.dupe(u8, text);
            const label: vxfw.RichText = .{ .text = &.{.{ .text = stable, .style = style }}, .softwrap = false, .width_basis = .parent };
            const drawn = try label.draw(ctx.withConstraints(.{}, .{ .width = @intCast(text_width), .height = 1 }));
            @memcpy(surface.buffer[size.width + start ..][0..text_width], drawn.buffer[0..text_width]);
            if (show_update and update.enabled) {
                const hit: Hover.Rect = .{ .row = 1, .col = start, .width = @intCast(text_width) };
                self.update_target = hit;
                self.hover.targets = try ctx.arena.dupe(Hover.Rect, &.{ target, hit });
            }
        }
        return surface;
    }
};

test "SUI-45 chat tabs paint and accept only their visible cells" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    for ([_]bool{ false, true }) |sidebar| for ([_]bool{ false, true }) |unicode| for (0..27) |raw_width| for ([_]u16{ 0, 1, 2 }) |height| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const width: u16 = if (raw_width == 25) 46 else if (raw_width == 26) 140 else @intCast(raw_width);
        state.conversing = if (sidebar) "aaaaaa".* else null;
        var clicks: Clicks = .{};
        var controls: SessionControls = .{ .state = &state, .caps = .{ .unicode = unicode }, .userdata = &clicks, .on_click = Clicks.take };
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        _ = try controls.widget().draw(draw.withConstraints(.{}, .{ .width = 140, .height = 2 }));
        const shown = try controls.widget().draw(draw);
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        try shown.render(window, controls.widget());
        if (height >= 2) for (0..width) |col| {
            const chat_end = @min(10, width -| 3);
            const archive_end = @min(20, width -| 3);
            const expected: []const u8 = if (col >= 5 and col < chat_end)
                (if (chat_end < 10 and col + 1 == chat_end) (if (unicode) "…" else ".") else "Chats"[col - 5 ..][0..1])
            else if (col >= 12 and col < archive_end)
                (if (archive_end < 20 and col + 1 == archive_end) (if (unicode) "…" else ".") else "Archived"[col - 12 ..][0..1])
            else
                " ";
            try std.testing.expectEqualStrings(expected, screen.readCell(@intCast(col), 1).?.char.grapheme);
        };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        for (0..141) |col| {
            clicks.got = null;
            events.consume_event = false;
            try controls.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(col), .row = 1, .button = .left, .type = .press, .mods = .{} } });
            const expected: ?overview_view.Click = if (height < 2 or col >= width) null else if (col >= 5 and col < @min(10, width -| 3)) .sessions else if (col >= 12 and col < @min(20, width -| 3)) .archived else null;
            try std.testing.expectEqual(expected, clicks.got);
        }
    };
}

test "sidebar bottom separates Settings memory and update targets across geometry and states" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const status = @import("upgrade_status.zig");
    const runs = [_]?status.Run{ null, .checking, .cancelling, .{ .installing = .{ .found = .{ .host = .none } } }, .{ .ended = .{ .how = .{ .failed = .download }, .outcome = .unchanged } }, .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 76, .patch = 0 }, .restarted = true } }, .outcome = .compatible } } };
    for (runs) |run| for ([_]?status.Version{ null, .{ .schema = 76, .patch = 0 } }) |available| for ([_]overview_view.Caps{ .{}, .{ .unicode = false }, .{ .depth = .none }, .{ .background = .{ 255, 255, 255 } }, .{ .unicode = false, .background = .{ 255, 255, 255 } } }) |caps| for ([_]bool{ false, true }) |selected| for ([_]u16{ 0, 1, 8, 9, 10, 12, 13, 14, 15, 16, 17, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 31, 34, 35, 36, 37, 44, 45, 46, 140 }) |width| for ([_]u16{ 0, 1, 2, 3, 4 }) |height| {
        defer _ = arena.reset(.retain_capacity);
        var clicks: Clicks = .{};
        var settings: Settings = .{ .selected = selected, .caps = caps, .userdata = &clicks, .on_click = Clicks.take, .run = run, .available = available, .memory = .{ .rui = 38 * overview_view.mib, .tools = 120 * overview_view.mib } };
        const frame = try settings.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
        try std.testing.expectEqual(@min(height, 2), frame.size.height);
        if (width > 0 and height > 0) for (0..width) |column| {
            const rule = frame.readCell(@intCast(column), 0);
            try std.testing.expectEqualStrings(if (caps.unicode) "┄" else "-", rule.char.grapheme);
            try std.testing.expectEqual(widget_style.line(caps, .horizontal).style, rule.style);
        };
        const busy = if (run) |active| active.going() else false;
        const failed = if (run) |active| active == .ended and active.ended.how == .failed else false;
        const done = if (run) |active| active == .ended and active.ended.how == .upgraded else false;
        const wording = if (busy) (if (caps.unicode) "Updating…" else "Updating...") else if (failed) "Update failed" else if (!done and available != null) "Update to 0.76.0" else "38 MB";
        const label_width = @import("display_text.zig").width(wording, .terminal);
        if (height >= 2 and width >= label_width + 15) {
            const row = try cells(arena.allocator(), frame, 1);
            try std.testing.expect(std.mem.endsWith(u8, row, try std.fmt.allocPrint(arena.allocator(), "{s} ", .{wording})));
            try std.testing.expect(std.mem.indexOf(u8, row, "rui") == null);
            const colour: overview_view.Colour = if (failed) .attention else if (!busy and !done and available != null) .ink else .quiet;
            try std.testing.expectEqual(widget_style.of(caps, .{ .colour = colour, .background = if (selected) .selection else .ground }), frame.readCell(@intCast(width - label_width - 1), 1).style);
        }
        const expected_target: ?Hover.Rect = if (height >= 2 and width >= label_width + 15 and (failed or (!busy and !done and available != null))) .{ .row = 1, .col = @intCast(width - label_width - 1), .width = @intCast(label_width) } else null;
        try std.testing.expectEqual(expected_target, settings.update_target);
        const identity: status.Target = .{ .available = available, .run = run };
        settings.available = .{ .schema = 77, .patch = 0 };
        settings.run = .checking;
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        for (0..height + 1) |row| for (0..width + 1) |column| {
            clicks.got = null;
            try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(column), .row = @intCast(row), .button = .left, .type = .press, .mods = .{} } });
            const expected: ?overview_view.Click = if (row == 1 and height > 1 and column >= 5 and column < @min(13, width -| 2)) .settings else if (expected_target) |target| (if (target.contains(@intCast(column), @intCast(row))) .{ .update = identity } else null) else null;
            try std.testing.expectEqual(expected, clicks.got);
        };
    };
}

test "Session pin alternate gestures never activate New Session or Settings" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var clicks: Clicks = .{};
    var new_session: SessionControls = .{ .state = &state, .userdata = &clicks, .on_click = Clicks.take };
    var settings: Settings = .{ .selected = false, .caps = .{}, .userdata = &clicks, .on_click = Clicks.take };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 2 }, .cell_size = .{} };
    _ = try new_session.widget().draw(draw_ctx);
    _ = try settings.widget().draw(draw_ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    defer events.cmds.deinit(events.alloc);
    for ([_]vaxis.Mouse{
        .{ .col = 3, .row = 0, .button = .right, .type = .press, .mods = .{} },
        .{ .col = 3, .row = 0, .button = .left, .type = .press, .mods = .{ .alt = true } },
    }) |mouse| {
        try new_session.widget().handleEvent(&events, .{ .mouse = mouse });
        var second = mouse;
        second.row = 1;
        try settings.widget().handleEvent(&events, .{ .mouse = second });
        try std.testing.expectEqual(null, clicks.got);
    }
    for (events.cmds.items) |cmd| switch (cmd) {
        .set_mouse_shape => {},
        else => return error.TestUnexpectedCommand,
    };
}

test "session tab focus survives pointer hover without changing active filter" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var clicks: Clicks = .{};
    var controls: SessionControls = .{ .state = &state, .userdata = &clicks, .on_click = Clicks.take };
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 2 }, .cell_size = .{} };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]overview_view.ArchiveFilter{ .active, .archived }) |filter| for ([_]overview_view.Selection{ .sessions, .archived }) |focus| for ([_]i16{ 5, 15, 30 }) |pointer| {
        state.archive = filter;
        state.selected = focus;
        _ = try controls.widget().draw(draw);
        try controls.widget().handleEvent(&events, .{ .mouse = .{ .col = pointer, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
        const shown = try controls.widget().draw(draw);
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = 46, .rows = 2, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 46, .height = 2, .screen = &screen };
        try shown.render(window, controls.widget());
        try std.testing.expectEqual(widget_style.of(.{}, .{ .background = .selection }).bg, screen.readCell(if (focus == .sessions) 5 else 15, 1).?.style.bg);
        try std.testing.expectEqual(filter == .active, screen.readCell(5, 1).?.style.bold);
        try std.testing.expectEqual(filter == .archived, screen.readCell(15, 1).?.style.bold);
        try std.testing.expectEqual(focus, state.selected);
        try std.testing.expectEqual(filter, state.archive);
    };
}
