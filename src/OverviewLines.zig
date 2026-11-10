//! The overview's two one-line widgets: the counts line its screen puts in
//! `header`, and the status bar its InputArea shows. Each only draws what
//! `overview_view` decides, read from the core's state each frame; the
//! counts line also names a click on its view name as the core's `Click`.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");

/// The status bar: `overview_view.statusLine`, or blank ground.
pub const Status = struct {
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},

    pub fn widget(self: *Status) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawStatus };
    }

    fn drawStatus(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Status = @ptrCast(@alignCast(raw));
        var buffer: overview_view.StatusBuffer = undefined;
        const spans: []const vaxis.Segment = if (overview_view.statusLine(self.state, self.caps, &buffer)) |line| try ctx.arena.dupe(vaxis.Segment, &.{.{
            .text = try ctx.arena.dupe(u8, line.text),
            .style = widget_style.of(self.caps, .{ .colour = line.colour }),
        }}) else &.{};
        return oneRow(ctx, spans, widget_style.of(self.caps, .{}), self.widget());
    }
};

/// The counts line. A left press on its view name, which shows only off
/// the default view, calls `on_click` with `.view`.
pub const Counts = struct {
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},
    userdata: *anyopaque,
    on_click: *const fn (*anyopaque, *vxfw.EventContext, overview_view.Click) anyerror!void,
    /// Where the last frame drew the view name: plain data, kept for the
    /// press that frame's hit test sends here.
    view: ?struct { start: u16, end: u16 } = null,

    pub fn widget(self: *Counts) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = drawCounts };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
        const self: *Counts = @ptrCast(@alignCast(raw));
        const mouse = switch (input) {
            .mouse => |mouse| mouse,
            else => return,
        };
        if (mouse.button != .left or mouse.type != .press or mouse.row != 0) return;
        const view = self.view orelse return;
        if (mouse.col < view.start or mouse.col >= view.end) return;
        try self.on_click(self.userdata, ctx, .view);
        ctx.consumeAndRedraw();
    }

    fn drawCounts(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Counts = @ptrCast(@alignCast(raw));
        const counts = try overview_view.countsLine(ctx.arena, self.state, ctx.max.width orelse 0, self.caps);
        self.view = if (counts.view) |view| .{ .start = view.start, .end = view.end } else null;
        const spans = try ctx.arena.alloc(vaxis.Segment, counts.segments.len);
        for (counts.segments, spans) |segment, *span| span.* = .{ .text = segment.text, .style = widget_style.of(self.caps, segment.style) };
        return oneRow(ctx, spans, widget_style.of(self.caps, .{ .background = .bar }), self.widget());
    }
};

/// One row of `spans` on `base`, the parent's width, owned by `owner`.
fn oneRow(ctx: vxfw.DrawContext, spans: []const vaxis.Segment, base: vaxis.Style, owner: vxfw.Widget) std.mem.Allocator.Error!vxfw.Surface {
    const text: vxfw.RichText = .{ .text = spans, .base_style = base, .softwrap = false, .width_basis = .parent };
    const width = ctx.max.width orelse 0;
    var surface = try text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    surface.widget = owner;
    return surface;
}

fn cells(arena: std.mem.Allocator, surface: vxfw.Surface) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..surface.size.width) |column| try text.appendSlice(arena, surface.readCell(@intCast(column), 0).char.grapheme);
    return text.items;
}

test "the status bar draws the core's line in its colour, and blank ground when quiet" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var status: Status = .{ .state = &state };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 3 }, .cell_size = .{} };
    const quiet = try status.widget().draw(ctx);
    try std.testing.expectEqual(vxfw.Size{ .width = 40, .height = 1 }, quiet.size);
    try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, try cells(arena.allocator(), quiet), " "));
    try std.testing.expectEqual(widget_style.of(.{}, .{}).bg, quiet.readCell(39, 0).style.bg);

    _ = try overview_view.step(&state, .{ .composed = .{ .input = .{ .composer = .submit }, .draft = .{ .bytes = "/upgrade", .cursor = 8 } } });
    const checking = try status.widget().draw(ctx);
    try std.testing.expect(std.mem.startsWith(u8, try cells(arena.allocator(), checking), "Checking for updates…"));
    try std.testing.expectEqual(widget_style.of(.{}, .{ .colour = .normal }).fg, checking.readCell(0, 0).style.fg);
    try std.testing.expect(checking.widget.eql(status.widget()));

    // A long line is cut to the bar, never wrapped onto another row.
    _ = try overview_view.step(&state, .{ .upgrade = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .{ .running = 2 } } } });
    const narrow = try status.widget().draw(ctx.withConstraints(.{}, .{ .width = 12, .height = 3 }));
    try std.testing.expectEqual(vxfw.Size{ .width = 12, .height = 1 }, narrow.size);
    try std.testing.expect(std.mem.startsWith(u8, try cells(arena.allocator(), narrow), "Upgrading"));
}

const Clicks = struct {
    got: ?overview_view.Click = null,
    fn take(raw: *anyopaque, _: *vxfw.EventContext, click: overview_view.Click) anyerror!void {
        const self: *Clicks = @ptrCast(@alignCast(raw));
        self.got = click;
    }
};

test "the counts line draws the core's segments, and a press on its view name is the view click" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var clicks: Clicks = .{};
    const caps: overview_view.Caps = .{ .unicode = false };
    var counts: Counts = .{ .state = &state, .caps = caps, .userdata = &clicks, .on_click = Clicks.take };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 50, .height = 4 }, .cell_size = .{} };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const press = struct {
        fn at(column: i16) vxfw.Event {
            return .{ .mouse = .{ .col = column, .row = 0, .button = .left, .type = .press, .mods = .{} } };
        }
    }.at;

    // The default view names nothing, so no press is a click.
    const plain = try counts.widget().draw(ctx);
    try std.testing.expectEqual(vxfw.Size{ .width = 50, .height = 1 }, plain.size);
    try std.testing.expect(std.mem.startsWith(u8, try cells(arena.allocator(), plain), " rui"));
    try std.testing.expectEqual(widget_style.of(caps, .{ .background = .bar }).bg, plain.readCell(49, 0).style.bg);
    try counts.widget().handleEvent(&events, press(45));
    try std.testing.expectEqual(null, clicks.got);

    state.archive = .archived;
    const archived = try counts.widget().draw(ctx);
    const text = try cells(arena.allocator(), archived);
    try std.testing.expectEqualStrings("Archived ", text[41..]);
    // Just left of the name, and on the cell after it, are not the name.
    try counts.widget().handleEvent(&events, press(40));
    try counts.widget().handleEvent(&events, press(49));
    try std.testing.expectEqual(null, clicks.got);
    try std.testing.expect(!events.consume_event);
    try counts.widget().handleEvent(&events, press(44));
    try std.testing.expectEqual(overview_view.Click.view, clicks.got.?);
    try std.testing.expect(events.consume_event);
}
