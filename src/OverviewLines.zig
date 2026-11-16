const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const Hover = @import("widgets/Hover.zig");

pub const Header = struct {
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},
    pub fn widget(self: *Header) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Header = @ptrCast(@alignCast(raw));
        const width = ctx.max.width orelse 0;
        const lines = try overview_view.headerSegments(ctx.arena, self.state, width, self.caps);
        const spans = try ctx.arena.alloc(vaxis.Segment, lines.len);
        for (lines, spans) |segment, *span| span.* = .{ .text = segment.text, .style = widget_style.of(self.caps, segment.style) };
        const text: vxfw.RichText = .{ .text = spans, .softwrap = false, .width_basis = .parent };
        var surface = try text.draw(ctx.withConstraints(.{ .width = width }, ctx.max));
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
        const width = ctx.max.width.?;
        const built = try overview_view.listSegments(ctx.arena, self.state, .new_session, width, self.caps, 0);
        const tabs = try overview_view.listSegments(ctx.arena, self.state, .views, width, self.caps, 0);
        var regions: std.ArrayList(GroupedList.Region) = .empty;
        if (tabs.sessions) |at| try regions.append(ctx.arena, .{ .start = at.start, .end = at.end, .target = .sessions, .selected = self.state.selected == .sessions });
        if (tabs.archived) |at| try regions.append(ctx.arena, .{ .start = at.start, .end = at.end, .target = .archived, .selected = self.state.selected == .archived });
        const rows = try ctx.arena.create([]const GroupedList.Row);
        rows.* = try ctx.arena.dupe(GroupedList.Row, &.{
            .{ .segments = built.segments, .target = .new_session },
            .{ .segments = tabs.segments, .regions = regions.items },
        });
        self.row.rows = .of(rows);
        self.row.selected = if (built.selected) 0 else null;
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

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
        const self: *Settings = @ptrCast(@alignCast(raw));
        try self.hover.handleEvent(ctx, input);
        if (input != .mouse) return;
        const mouse = input.mouse;
        if (mouse.button != .left or mouse.mods.alt or mouse.type != .press or mouse.col < 0 or mouse.col >= self.size.width) return;
        const click: overview_view.Click = if (mouse.row == 0 and self.size.height > 0) .settings else if (self.update_target) |target| (if (target.contains(mouse.col, mouse.row)) .{ .update = self.update_identity } else return) else return;
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
        const target: Hover.Rect = .{ .row = 0, .width = size.width };
        const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), self.size);
        @memset(surface.buffer, .{ .style = widget_style.of(self.caps, .{ .colour = .quiet }) });
        self.hover.targets = &.{};
        if (height == 0 or size.width == 0) return surface;
        const ground: overview_view.Background = if (self.selected) .selection else if (self.hover.contains(target)) .hover else .ground;
        const name: vxfw.RichText = .{ .text = &.{.{ .text = "  Settings", .style = widget_style.of(self.caps, .{ .colour = if (self.selected) .strong else .normal, .bold = self.selected, .background = ground }) }}, .softwrap = false };
        const label = try name.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
        @memset(surface.buffer[0..size.width], .{ .style = widget_style.of(self.caps, .{ .background = ground }) });
        if (label.size.height > 0) @memcpy(surface.buffer[0..label.size.width], label.buffer[0..label.size.width]);
        self.hover.targets = try ctx.arena.dupe(Hover.Rect, &.{target});
        if (height < 2) return surface;
        const status = @import("upgrade_status.zig");
        var buffer: [status.max_line_bytes]u8 = undefined;
        const update = status.control(@import("transport_options").version, self.available, self.run, &buffer, if (self.caps.unicode) .unicode else .ascii);
        const text_width = @import("display_text.zig").width(update.text, .terminal);
        const fits = text_width + 1 <= size.width;
        const right = if (fits) try std.fmt.allocPrint(ctx.arena, "{s} ", .{update.text}) else "";
        const memory = try @import("memory_text.zig").sidebar(ctx.arena, self.memory, size.width -| @as(u16, @intCast((if (fits) text_width + 1 else 0) + 4)));
        const footer: @import("widgets/Footer.zig") = .{ .left = if (memory.len > 0) try std.fmt.allocPrint(ctx.arena, "  {s}", .{memory}) else "", .right = right, .style = widget_style.of(self.caps, .{ .colour = .quiet }) };
        const drawn = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
        @memcpy(surface.buffer[size.width..], drawn.buffer);
        if (fits) {
            const start: u16 = size.width - @as(u16, @intCast(text_width)) - 1;
            const style = widget_style.of(self.caps, .{ .colour = switch (update.tone) {
                .quiet => .quiet,
                .link => .ink,
                .warning => .attention,
            } });
            for (start..size.width - 1) |column| surface.buffer[size.width + column].style = style;
            if (update.enabled) {
                const hit: Hover.Rect = .{ .row = 1, .col = start, .width = @intCast(text_width) };
                self.update_target = hit;
                self.hover.targets = try ctx.arena.dupe(Hover.Rect, &.{ target, hit });
            }
        }
        return surface;
    }
};

test "session tabs press only separate drawn destinations and clear clipped targets" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |sidebar| for ([_]u16{ 0, 1, 9, 20, 46, 140 }) |width| for ([_]u16{ 0, 1, 2 }) |height| {
        state.conversing = if (sidebar) "aaaaaa".* else null;
        var clicks: Clicks = .{};
        var controls: SessionControls = .{ .state = &state, .userdata = &clicks, .on_click = Clicks.take };
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 2 }, .cell_size = .{} };
        _ = try controls.widget().draw(draw);
        const shown = try controls.widget().draw(draw.withConstraints(.{}, .{ .width = width, .height = height }));
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        if (width >= 20 and height >= 1) {
            var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
            const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
            try shown.render(window, controls.widget());
            var line: std.ArrayList(u8) = .empty;
            for (0..width) |col| try line.appendSlice(arena.allocator(), screen.readCell(@intCast(col), 0).?.char.grapheme);
            try std.testing.expect(std.mem.startsWith(u8, line.items, "  + New Session"));
        }
        for (0..3) |row| for (0..@max(1, width)) |col| {
            clicks.got = null;
            events.consume_event = false;
            try controls.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(col), .row = @intCast(row), .button = .left, .type = .press, .mods = .{} } });
            const expected: ?overview_view.Click = if (col >= width or row >= height) null else if (row == 0) .new_session else if (col >= 2 and col < @min(10, width -| 1)) .sessions else if (col >= 12 and col < @min(20, width -| 1)) .archived else null;
            try std.testing.expectEqual(expected, clicks.got);
        };
    };
}

test "sidebar bottom separates Settings memory and update targets across geometry and states" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const status = @import("upgrade_status.zig");
    for ([_]?status.Run{ null, .checking, .cancelling, .{ .installing = .{ .found = .{ .host = .none } } }, .{ .ended = .{ .how = .{ .failed = .download }, .outcome = .unchanged } }, .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 76, .patch = 0 }, .restarted = true } }, .outcome = .compatible } } }) |run| {
        for ([_]?status.Version{ null, .{ .schema = 76, .patch = 0 } }) |available| for ([_]overview_view.Caps{ .{}, .{ .unicode = false }, .{ .background = .{ 255, 255, 255 } }, .{ .unicode = false, .background = .{ 255, 255, 255 } } }) |caps| for ([_]bool{ false, true }) |selected| for ([_]u16{ 0, 1, 8, 9, 10, 12, 13, 14, 15, 16, 17, 20, 21, 22, 23, 24, 25, 26, 46, 140 }) |width| for ([_]u16{ 0, 1, 2, 4 }) |height| {
            defer _ = arena.reset(.retain_capacity);
            var clicks: Clicks = .{};
            var settings: Settings = .{ .selected = selected, .caps = caps, .userdata = &clicks, .on_click = Clicks.take, .run = run, .available = available, .memory = .{ .rui = 38 * overview_view.mib, .tools = 120 * overview_view.mib } };
            const frame = try settings.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
            try std.testing.expectEqual(@min(height, 2), frame.size.height);
            if (width >= 20 and height >= 2) {
                try std.testing.expect(std.mem.startsWith(u8, try cells(arena.allocator(), frame, 0), "  Settings"));
                const bottom = try cells(arena.allocator(), frame, 1);
                try std.testing.expect(std.mem.indexOf(u8, bottom, "Settings") == null);
                try std.testing.expect(std.mem.indexOf(u8, bottom, "rui") == null);
                try std.testing.expect(std.mem.indexOf(u8, bottom, "tools") == null);
                if (width >= 46) try std.testing.expect(std.mem.startsWith(u8, bottom, "  38 MB"));
            }
            const busy = if (run) |active| active.going() else false;
            const failed = if (run) |active| active == .ended and active.ended.how == .failed else false;
            const success = if (run) |active| active == .ended and active.ended.how == .upgraded else false;
            const wording = if (busy) (if (caps.unicode) "Updating…" else "Updating...") else if (failed) "Update failed" else if (success) "0.76.0" else if (available != null) "Update to 0.76.0" else @import("transport_options").version;
            const label_width: usize = if (busy and caps.unicode) 9 else wording.len;
            if (height >= 2 and width >= label_width + 1) {
                const bottom = try cells(arena.allocator(), frame, 1);
                try std.testing.expect(std.mem.endsWith(u8, bottom, try std.fmt.allocPrint(arena.allocator(), "{s} ", .{wording})));
                const tone: overview_view.Colour = if (failed) .attention else if (!busy and !success and available != null) .ink else .quiet;
                const style = widget_style.of(caps, .{ .colour = tone });
                for (width - label_width - 1..width - 1) |column| try std.testing.expectEqual(style, frame.readCell(@intCast(column), 1).style);
                try std.testing.expectEqual(width >= label_width + 10, std.mem.startsWith(u8, bottom, "  38 MB"));
            }
            const expected_target: ?Hover.Rect = if (height >= 2 and width >= label_width + 1 and !busy) .{ .row = 1, .col = @intCast(width - label_width - 1), .width = @intCast(label_width) } else null;
            try std.testing.expectEqual(expected_target, settings.update_target);
            const drawn_identity: @import("upgrade_status.zig").Target = .{ .available = settings.available, .run = run };
            settings.available = .{ .schema = 77, .patch = 0 };
            settings.run = .checking;
            var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            for (0..height + 1) |row| for (0..width + 1) |column| {
                clicks.got = null;
                try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(column), .row = @intCast(row), .button = .left, .type = .press, .mods = .{} } });
                const expected: ?overview_view.Click = if (row == 0 and height > 0 and column < width) .settings else if (expected_target) |target| (if (target.contains(@intCast(column), @intCast(row))) .{ .update = drawn_identity } else null) else null;
                try std.testing.expectEqual(expected, clicks.got);
            };
            _ = try settings.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 0, .height = 0 }, .cell_size = .{} });
            try std.testing.expect(settings.update_target == null);
            clicks.got = null;
            try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = .left, .type = .press, .mods = .{} } });
            try std.testing.expectEqual(null, clicks.got);
        };
    }
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
        second.row = 0;
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
    for ([_]overview_view.ArchiveFilter{ .active, .archived }) |filter| for ([_]overview_view.Selection{ .sessions, .archived }) |focus| for ([_]i16{ 3, 13, 30 }) |pointer| {
        state.archive = filter;
        state.selected = focus;
        _ = try controls.widget().draw(draw);
        try controls.widget().handleEvent(&events, .{ .mouse = .{ .col = pointer, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
        const shown = try controls.widget().draw(draw);
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = 46, .rows = 2, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 46, .height = 2, .screen = &screen };
        try shown.render(window, controls.widget());
        try std.testing.expectEqual(widget_style.of(.{}, .{ .background = .selection }).bg, screen.readCell(if (focus == .sessions) 2 else 12, 1).?.style.bg);
        try std.testing.expectEqual(filter == .active, screen.readCell(2, 1).?.style.bold);
        try std.testing.expectEqual(filter == .archived, screen.readCell(12, 1).?.style.bold);
        try std.testing.expectEqual(focus, state.selected);
        try std.testing.expectEqual(filter, state.archive);
    };
}
