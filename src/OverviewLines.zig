//! The overview provider header and pinned New Session and Settings rows.
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

/// A one-line pinned control, using the list owner for row styles and presses.
pub const NewSession = struct {
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},
    userdata: *anyopaque,
    on_click: *const fn (*anyopaque, *vxfw.EventContext, overview_view.Click) anyerror!void,
    row: @import("GroupedList.zig") = .{},

    pub fn widget(self: *NewSession) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw, .eventHandler = event };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        const self: *NewSession = @ptrCast(@alignCast(raw));
        try self.row.widget().handleEvent(ctx, value);
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *NewSession = @ptrCast(@alignCast(raw));
        const GroupedList = @import("GroupedList.zig");
        const built = try overview_view.listSegments(ctx.arena, self.state, .new_session, ctx.max.width.?, self.caps, 0);
        const rows = try ctx.arena.create([]const GroupedList.Row);
        rows.* = try ctx.arena.dupe(GroupedList.Row, &.{.{ .segments = built.segments, .target = .new_session }});
        self.row.rows = .of(rows);
        self.row.selected = if (built.selected) 0 else null;
        self.row.caps = self.caps;
        self.row.on_press = .{ .userdata = self.userdata, .pressed = self.on_click };
        var surface = try self.row.widget().draw(ctx.withConstraints(.{}, .{ .width = ctx.max.width.?, .height = @min(1, ctx.max.height.?) }));
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
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 50, .height = 6 }, .cell_size = .{} };
    const plain = try header.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 0), plain.size.height);
    state.archive = .archived;
    state.list_stale = true;
    const stopped = try header.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 0), stopped.size.height);
}

/// Pinned list tail, with a click target only on the Settings row.
pub const Settings = struct {
    selected: bool,
    memory: ?overview_view.Memory = null,
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
        if (mouse.button != .left or mouse.type != .press or mouse.row != 1 or self.size.height < 2 or mouse.col < 0 or mouse.col >= self.size.width) return;
        try self.on_click(self.userdata, ctx, .settings);
        ctx.consumeAndRedraw();
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Settings = @ptrCast(@alignCast(raw));
        const size = ctx.max.size();
        const height = @min(2, size.height);
        self.size = .{ .width = size.width, .height = height };
        const target: Hover.Rect = .{ .row = 1, .width = size.width };
        self.hover.targets = if (height == 2 and size.width > 0) try ctx.arena.dupe(Hover.Rect, &.{target}) else &.{};
        const ground: overview_view.Background = if (self.selected) .selection else if (self.hover.targets.len != 0 and self.hover.contains(target)) .hover else .ground;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = height });
        @memset(surface.buffer, .{ .style = widget_style.of(self.caps, .{}) });
        if (height == 0 or size.width == 0) return surface;
        for (0..size.width) |x| surface.writeCell(@intCast(x), 0, .{ .char = .{ .grapheme = if (self.caps.unicode) "─" else "-", .width = 1 }, .style = widget_style.of(self.caps, .{ .colour = .quiet }) });
        if (height < 2) return surface;
        const style = widget_style.of(self.caps, .{ .colour = .quiet, .background = ground });
        const version = @import("transport_options").version ++ " ";
        const label_text = "  Settings";
        var right: []const u8 = version;
        for (try @import("memory_text.zig").choices(ctx.arena, self.memory, self.caps.unicode)) |memory| {
            if (memory.len == 0) break;
            // Settings and the version keep their space; memory drops first.
            if (label_text.len + 2 + ctx.stringWidth(memory) + 2 + version.len > size.width) continue;
            right = try std.fmt.allocPrint(ctx.arena, "{s}  {s}", .{ memory, version });
            break;
        }
        const footer: @import("widgets/Footer.zig") = .{ .left = "", .right = right, .style = style };
        const drawn = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
        @memcpy(surface.buffer[size.width..], drawn.buffer);
        const name: vxfw.RichText = .{ .text = &.{.{ .text = label_text, .style = widget_style.of(self.caps, .{ .colour = if (self.selected) .strong else .normal, .bold = self.selected, .background = ground }) }}, .softwrap = false };
        const label = try name.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width -| @as(u16, @intCast(@import("transport_options").version.len + 2)), .height = 1 }));
        if (label.size.height > 0) @memcpy(surface.buffer[size.width..][0..label.size.width], label.buffer[0..label.size.width]);
        return surface;
    }
};

test "overview Settings row is pinned selected and opens only on its second line" {
    var clicks: Clicks = .{};
    var settings: Settings = .{ .selected = true, .caps = .{}, .userdata = &clicks, .on_click = Clicks.take };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 40, 140 }) |width| {
        const surface = try settings.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 8 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(u16, 2), surface.size.height);
        try std.testing.expectEqualStrings("─", surface.readCell(0, 0).char.grapheme);
        const text = try cells(arena.allocator(), surface, 1);
        try std.testing.expect(std.mem.startsWith(u8, text, "  Settings"));
        try std.testing.expect(std.mem.endsWith(u8, text, @import("transport_options").version ++ " "));
        for ([_]u16{ 0, 3, width - 1 }) |column| try std.testing.expectEqual(widget_style.of(settings.caps, .{ .background = .selection }).bg, surface.readCell(column, 1).style.bg);
    }
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 0, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqual(null, clicks.got);
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 1, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqual(overview_view.Click.settings, clicks.got.?);
    try std.testing.expect(events.consume_event);
    for (0..4) |height| for (0..12) |width| {
        const tiny = try settings.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= width and tiny.size.height <= height);
    };
}

test "overview Settings hover follows only its drawn row without selecting or focusing" {
    var clicks: Clicks = .{};
    var settings: Settings = .{ .selected = false, .caps = .{}, .userdata = &clicks, .on_click = Clicks.take };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 2 }, .cell_size = .{} };
    const plain = try settings.widget().draw(draw_ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try settings.widget().handleEvent(&events, .mouse_enter);
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
    const separator = try settings.widget().draw(draw_ctx);
    try std.testing.expectEqual(plain.readCell(3, 1).style, separator.readCell(3, 1).style);
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    const hovered = try settings.widget().draw(draw_ctx);
    for (0..40) |col| try std.testing.expectEqual(widget_style.of(settings.caps, .{ .background = .hover }).bg, hovered.readCell(@intCast(col), 1).style.bg);
    try std.testing.expectEqual(plain.readCell(3, 1).style.fg, hovered.readCell(3, 1).style.fg);
    try std.testing.expect(!settings.selected);
    try std.testing.expectEqual(null, clicks.got);
    for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    try settings.widget().handleEvent(&events, .mouse_leave);
    const left = try settings.widget().draw(draw_ctx);
    try std.testing.expectEqual(plain.readCell(3, 1).style, left.readCell(3, 1).style);
    // A row clipped out of the frame is neither hoverable nor clickable.
    _ = try settings.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 40, .height = 1 }));
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 1, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqual(null, clicks.got);
    _ = try settings.widget().draw(draw_ctx);
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 1, .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expectEqual(overview_view.Click.settings, clicks.got.?);
    try std.testing.expect(!settings.selected);
    // Selection wins under the pointer.
    settings.selected = true;
    try settings.widget().handleEvent(&events, .{ .mouse = .{ .col = 3, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    const both = try settings.widget().draw(draw_ctx);
    try std.testing.expectEqual(widget_style.of(settings.caps, .{ .background = .selection }).bg, both.readCell(3, 1).style.bg);
}

test "overview Settings memory width domain preserves label and drops tools before rui" {
    var clicks: Clicks = .{};
    var settings: Settings = .{ .selected = false, .caps = .{}, .userdata = &clicks, .on_click = Clicks.take };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const version = @import("transport_options").version ++ " ";
    const full = "rui 38 MB · tools 120 MB";
    const rui = "rui 38 MB";
    for ([_]?overview_view.Memory{ null, .{ .rui = 38 * overview_view.mib, .tools = null }, .{ .rui = 38 * overview_view.mib, .tools = 120 * overview_view.mib } }) |memory| {
        settings.memory = memory;
        for (0..101) |width| {
            const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = 2 }, .cell_size = .{} };
            const surface = try settings.widget().draw(ctx);
            const text = try cells(arena.allocator(), surface, 1);
            const expected = if (memory) |live| (if (live.tools != null and width >= 14 + ctx.stringWidth(full) + version.len)
                full
            else if (width >= 14 + rui.len + version.len) rui else "") else "";
            if (width >= "  Settings".len + version.len + 1) try std.testing.expect(std.mem.startsWith(u8, text, "  Settings"));
            if (width >= version.len) try std.testing.expect(std.mem.endsWith(u8, text, version));
            if (expected.len > 0) {
                try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
                try std.testing.expectEqualStrings(expected, text[text.len - version.len - 2 - expected.len ..][0..expected.len]);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, text, "rui ") == null);
                try std.testing.expect(std.mem.indexOf(u8, text, "tools ") == null);
            }
            if (std.mem.eql(u8, expected, rui)) try std.testing.expect(std.mem.indexOf(u8, text, "tools ") == null);
            _ = arena.reset(.retain_capacity);
        }
    }
}
