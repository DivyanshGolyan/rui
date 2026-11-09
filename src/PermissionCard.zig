//! A focused permission choice replaces the composer without borrowing its
//! draft. The screen owns the proposal text and applies the exact decision.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Consent = @import("ActionConsent.zig");
const Policy = @import("session_consent.zig");
const Self = @This();

consent: *Consent,
description: []const u8,
body: vxfw.Widget,
userdata: *anyopaque,
on_decision: *const fn (*anyopaque, *vxfw.EventContext, Policy.Decision) anyerror!void,
method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},
quiet: vaxis.Style = .{ .dim = true },
choice_row: ?u16 = null,
choice_column: u16 = 0,
choice_width: u16 = 0,
ready_pending: bool = false,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const action: Consent.Input = switch (input) {
        .tick => {
            if (self.ready_pending) {
                try @import("TerminalEditor.zig").testChoiceReady(ctx.io);
                self.ready_pending = false;
            }
            return;
        },
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .invalid_key => .invalid,
        .key_release => return ctx.consumeEvent(),
        .key_press => |key| key: {
            // These keep the screen's meaning; every other typed key belongs
            // to this card, never the hidden composer.
            if (!self.consent.pasting and (key.matchExact(vaxis.Key.escape, .{}) or
                key.matchExact('c', .{ .ctrl = true }) or key.matchExact('x', .{ .ctrl = true }))) return;
            if (key.matchExact(vaxis.Key.enter, .{})) break :key .enter;
            if (key.matchExact(vaxis.Key.left, .{})) break :key .left;
            if (key.matchExact(vaxis.Key.right, .{})) break :key .right;
            return ctx.consumeEvent();
        },
        .mouse => |mouse| mouse: {
            const row = self.choice_row orelse return;
            if (mouse.type != .press or mouse.button != .left or mouse.row != row or
                mouse.col < self.choice_column) return;
            const col = @as(u16, @intCast(mouse.col)) - self.choice_column;
            if (col >= self.choice_width) return;
            if (col < " Allow once ".len) break :mouse .{ .click = .allow_once };
            if (col >= " Allow once   ".len and col < " Allow once    Deny ".len)
                break :mouse .{ .click = .deny };
            return;
        },
        else => return,
    };
    ctx.consumeEvent();
    const before = self.consent.highlight;
    if (self.consent.handle(action)) |decision| {
        ctx.redraw = true;
        try self.on_decision(self.userdata, ctx, decision);
    } else if (self.consent.highlight != before) ctx.redraw = true;
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    self.choice_row = null;
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    // The choice survives even at 1×1. More room adds the heading and body;
    // it never changes whether the person may decide the drawn request.
    const border: u16 = if (size.width >= 6 and size.height >= 4) 1 else 0;
    self.choice_column = 2 * border;
    self.choice_width = size.width - 2 * self.choice_column;
    const heading: u16 = if (size.height >= 2) 1 else 0;
    const body_height = size.height - heading - 1 - border;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{ .width = size.width, .height = size.height, .width_method = self.method, .buf = surface.buffer };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = size.width, .height = size.height, .screen = &screen };
    if (border != 0) {
        for (0..size.width) |col| {
            surface.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = if (col == 0) "┌" else if (col == size.width - 1) "┐" else "─", .width = 1 }, .style = self.quiet });
            surface.writeCell(@intCast(col), size.height - 1, .{ .char = .{ .grapheme = if (col == 0) "└" else if (col == size.width - 1) "┘" else "─", .width = 1 }, .style = self.quiet });
        }
        for (1..size.height - 1) |row| {
            const edge: vaxis.Cell = .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.quiet };
            surface.writeCell(0, @intCast(row), edge);
            surface.writeCell(size.width - 1, @intCast(row), edge);
        }
    }
    if (heading != 0) {
        _ = window.child(.{ .x_off = self.choice_column, .width = self.choice_width, .height = 1 }).print(&.{ .{ .text = "? ", .style = self.quiet }, .{ .text = self.description, .style = self.style } }, .{ .wrap = .none });
    }
    if (body_height != 0) {
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .col = self.choice_column, .row = heading }, .surface = try self.body.draw(ctx.withConstraints(.{}, .{ .width = self.choice_width, .height = body_height })) };
        surface.children = children;
    }
    var allow = self.style;
    var deny = self.style;
    allow.reverse = self.consent.highlight == .allow_once;
    deny.reverse = self.consent.highlight == .deny;
    self.choice_row = size.height - 1 - border;
    _ = window.child(.{ .x_off = self.choice_column, .width = self.choice_width, .y_off = self.choice_row.?, .height = 1 }).print(&.{
        .{ .text = " Allow once ", .style = allow },
        .{ .text = "  ", .style = self.style },
        .{ .text = " Deny ", .style = deny },
    }, .{ .wrap = .none });
    if (self.consent.draw()) self.ready_pending = true;
    return surface;
}

test "PermissionCard decides the drawn request at tiny sizes and ignores text and paste" {
    const Owner = struct {
        decision: ?Policy.Decision = null,
        fn decide(raw: *anyopaque, _: *vxfw.EventContext, decision: Policy.Decision) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.decision = decision;
        }
    };
    var owner: Owner = .{};
    var consent: Consent = .{};
    const body: vxfw.Text = .{ .text = "$ zig build test\nsecond line\nthird line" };
    var card: Self = .{ .consent = &consent, .description = "Run the tests", .body = body.widget(), .userdata = &owner, .on_decision = Owner.decide };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .redraw = false };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    consent.adopt(41);
    _ = try card.widget().draw(ctx);
    consent.adopt(52);
    try card.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(null, owner.decision);
    for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 }, .{ .width = 1, .height = 1 }, .{ .width = 40, .height = 5 } }) |size| {
        const surface = try card.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(surface.size.width <= size.width and surface.size.height <= size.height);
        try std.testing.expectEqual(@as(?u64, 52), consent.request);
    }
    for ([_]vxfw.Event{ .{ .key_press = .{ .codepoint = 'y' } }, .invalid_key, .paste_start, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, .paste_end, .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } } }) |input| {
        events.consume_event = false;
        try card.widget().handleEvent(&events, input);
        try std.testing.expect(events.consume_event);
        try std.testing.expectEqual(null, owner.decision);
    }
    _ = try card.widget().draw(ctx.withConstraints(.{}, .{ .width = 1, .height = 1 }));
    try card.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try card.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(Policy.Decision{ .action = 52, .choice = .deny }, owner.decision.?);
    owner.decision = null;
    consent.adopt(63);
    const shown = try card.widget().draw(ctx);
    try std.testing.expectEqualStrings("┌", shown.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("┘", shown.readCell(39, 4).char.grapheme);
    try std.testing.expect(shown.readCell(3, 3).style.reverse);
    try std.testing.expect(!shown.readCell(17, 3).style.reverse);
    // A border click is not an approval; the actual Deny cells are.
    const click: vaxis.Mouse = .{ .col = 0, .row = 3, .button = .left, .type = .press, .mods = .{} };
    try card.widget().handleEvent(&events, .{ .mouse = click });
    try std.testing.expectEqual(null, owner.decision);
    var deny = click;
    deny.col = 17;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    try std.testing.expectEqual(Policy.Decision{ .action = 63, .choice = .deny }, owner.decision.?);
}
