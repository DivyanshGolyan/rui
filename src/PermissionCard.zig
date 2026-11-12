//! A request on its own ground above the ruled input row. The Action
//! document owns the title; the screen applies the exact decision.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Consent = @import("ActionConsent.zig");
const Policy = @import("session_consent.zig");
const input_choice = @import("choice_row.zig");
const Hover = @import("widgets/Hover.zig");
const Self = @This();

consent: *Consent,
description: []const u8,
body: vxfw.Widget,
userdata: *anyopaque,
on_decision: *const fn (*anyopaque, *vxfw.EventContext, Policy.Decision) anyerror!void,
method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},
quiet: vaxis.Style = .{ .dim = true },
/// The pointer's choice: only its background, reverse and underline apply, and the
/// highlighted choice keeps its reverse under the pointer.
hover_style: vaxis.Style = .{ .ul_style = .single },
choice_row: ?u16 = null,
choice_column: u16 = 0,
choice_width: u16 = 0,
ready_pending: bool = false,
hover: Hover = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

/// The card's own events: the pointer and the tick. Its keys come from
/// the Session's core through `take`.
fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    const action: Consent.Input = switch (input) {
        .tick => {
            if (self.ready_pending) {
                try @import("TerminalEditor.zig").testChoiceReady(ctx.io);
                self.ready_pending = false;
            }
            return;
        },
        .mouse_leave => .cancel,
        .mouse => |mouse| mouse: {
            const choice: ?Policy.Choice = for (self.hover.targets, 0..) |rect, index| {
                if (rect.contains(mouse.col, mouse.row)) break if (index == 0) .allow_once else .deny;
            } else null;
            if (mouse.button == .left) switch (mouse.type) {
                .press => break :mouse .{ .press = choice },
                .release => break :mouse .{ .release = choice },
                else => {},
            };
            if (self.consent.pressed) |pressed| if (choice != pressed.choice) break :mouse .cancel;
            return;
        },
        else => return,
    };
    ctx.consumeEvent();
    // Root hands no click inside a paste to anything (`app_input`).
    try self.take(ctx, action, false);
}

/// One input at the choice: a key the Session's core handed it, with
/// whether it arrived inside a paste, or the pointer's.
pub fn take(self: *Self, ctx: *vxfw.EventContext, input: Consent.Input, pasted: bool) !void {
    const before = self.consent.highlight;
    if (self.consent.handle(input, pasted)) |decision| {
        ctx.redraw = true;
        try self.on_decision(self.userdata, ctx, decision);
    } else if (self.consent.highlight != before) ctx.redraw = true;
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.drawInput(ctx, null);
}

/// InputArea supplies the composer only when the consent owner selects it.
/// This is placement, not row/key policy: the request always stays above it.
fn choiceLook(self: *const Self, highlighted: bool, target: Hover.Rect) input_choice.Look {
    return if (highlighted) .selected else if (self.hover.contains(target)) .hovered else .plain;
}

pub fn drawInput(self: *Self, ctx: vxfw.DrawContext, composer: ?vxfw.Widget) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    self.choice_row = null;
    self.hover.targets = &.{};
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    const draft = if (composer) |widget_| try widget_.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = @min(size.height, @import("draft_layout.zig").cap(size.height) + 2) })) else null;
    // Reserve the input before the request: a choice survives even at 1×1.
    const input_height: u16 = if (draft) |drawn| drawn.size.height else @min(3, size.height);
    const rule: u16 = if (input_height >= 3) 1 else 0;
    const body_height = size.height - input_height;
    self.choice_column = if (size.width >= 6 and size.height >= 4) 2 else 0;
    self.choice_width = size.width - 2 * self.choice_column;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{ .width = size.width, .height = size.height, .width_method = self.method, .buf = surface.buffer };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = size.width, .height = size.height, .screen = &screen };
    const children = try ctx.arena.alloc(vxfw.SubSurface, @intFromBool(body_height != 0) + @as(usize, @intFromBool(draft != null)));
    var count: usize = 0;
    if (body_height != 0) {
        children[count] = .{ .origin = .{ .col = self.choice_column, .row = 0 }, .surface = try self.body.draw(ctx.withConstraints(.{}, .{ .width = self.choice_width, .height = body_height })) };
        count += 1;
    }
    if (draft) |drawn| {
        children[count] = .{ .origin = .{ .col = 0, .row = body_height }, .surface = drawn };
    } else {
        if (rule != 0) for (0..size.width) |col| {
            const cell: vaxis.Cell = .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.quiet };
            surface.writeCell(@intCast(col), body_height, cell);
            surface.writeCell(@intCast(col), size.height - 1, cell);
        };
        self.choice_row = size.height - 1 - rule;
        const targets = try ctx.arena.alloc(Hover.Rect, 2);
        targets[0] = .{ .row = self.choice_row.?, .col = self.choice_column, .width = @min(self.choice_width, " Allow once ".len) };
        const deny_column = @min(self.choice_width, " Allow once   ".len);
        targets[1] = .{ .row = self.choice_row.?, .col = self.choice_column + deny_column, .width = @min(self.choice_width - deny_column, " Deny ".len) };
        self.hover.targets = targets;
        const looks: [2]input_choice.Look = .{
            self.choiceLook(self.consent.highlight == .allow_once, targets[0]),
            self.choiceLook(self.consent.highlight == .deny, targets[1]),
        };
        const choices = input_choice.segments(.{ "Allow once", "Deny" }, looks, self.style, self.hover_style, self.choice_column != 0);
        _ = window.child(.{ .width = size.width - self.choice_column, .y_off = self.choice_row.?, .height = 1 }).print(&choices, .{ .wrap = .none });
        if (self.consent.draw()) self.ready_pending = true;
    }
    surface.children = children;
    return surface;
}

test "PermissionCard decides the drawn request at tiny sizes and ignores pasted keys" {
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
    try card.take(&events, .enter, false);
    try std.testing.expectEqual(null, owner.decision);
    for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 }, .{ .width = 1, .height = 1 }, .{ .width = 40, .height = 5 } }) |size| {
        const surface = try card.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(surface.size.width <= size.width and surface.size.height <= size.height);
        try std.testing.expectEqual(@as(?u64, 52), consent.request);
    }
    // Keys go to the Session's core first; the card takes none from vxfw.
    _ = try card.widget().draw(ctx);
    events.consume_event = false;
    try card.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(!events.consume_event);
    // A key handed inside a paste never authorizes.
    for ([_]Consent.Input{ .enter, .left, .right, .other, .invalid, .cancel }) |input| {
        try card.take(&events, input, true);
        try std.testing.expectEqual(null, owner.decision);
    }
    _ = try card.widget().draw(ctx.withConstraints(.{}, .{ .width = 1, .height = 1 }));
    try card.take(&events, .right, false);
    try card.take(&events, .enter, false);
    try std.testing.expectEqual(Policy.Decision{ .action = 52, .choice = .deny }, owner.decision.?);
    owner.decision = null;
    consent.adopt(63);
    const shown = try card.widget().draw(ctx);
    try std.testing.expectEqualStrings("─", shown.readCell(0, 2).char.grapheme);
    try std.testing.expectEqualStrings("─", shown.readCell(39, 4).char.grapheme);
    try std.testing.expect(shown.readCell(3, 3).style.reverse);
    try std.testing.expect(!shown.readCell(17, 3).style.reverse);
    // A prompt/margin click is not an approval; the exact Deny cells are.
    const click: vaxis.Mouse = .{ .col = 0, .row = 3, .button = .left, .type = .press, .mods = .{} };
    try card.widget().handleEvent(&events, .{ .mouse = click });
    try std.testing.expectEqual(null, owner.decision);
    var deny = click;
    deny.col = 17;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    try std.testing.expectEqual(null, owner.decision);
    try card.widget().handleEvent(&events, .mouse_leave);
    deny.type = .release;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    try std.testing.expectEqual(null, owner.decision);
    deny.type = .press;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    consent.adopt(74);
    _ = try card.widget().draw(ctx);
    deny.type = .release;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    try std.testing.expectEqual(null, owner.decision);
    consent.adopt(63);
    _ = try card.widget().draw(ctx);
    deny.type = .press;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    deny.type = .release;
    try card.widget().handleEvent(&events, .{ .mouse = deny });
    try std.testing.expectEqual(Policy.Decision{ .action = 63, .choice = .deny }, owner.decision.?);
}

test "PermissionCard takes no choice from a key handed inside a paste, across request replacement" {
    const Owner = struct {
        decision: ?Policy.Decision = null,
        fn decide(raw: *anyopaque, _: *vxfw.EventContext, decision: Policy.Decision) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.decision = decision;
        }
    };
    var owner: Owner = .{};
    var consent: Consent = .{};
    const text: vxfw.Text = .{ .text = "Kept draft" };
    var card: Self = .{ .consent = &consent, .description = "Run", .body = text.widget(), .userdata = &owner, .on_decision = Owner.decide };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    consent.adopt(17);
    _ = try card.widget().draw(ctx);
    try card.take(&events, .enter, true);
    consent.withdraw();
    consent.adopt(29);
    _ = try card.widget().draw(ctx);
    try card.take(&events, .enter, true);
    try std.testing.expectEqual(null, owner.decision);
    // Once the paste ends, Enter takes the highlighted choice.
    try card.take(&events, .enter, false);
    try std.testing.expectEqual(@as(?Policy.Decision, .{ .action = 29, .choice = .allow_once }), owner.decision);
}

test "PermissionCard hover is quieter than the choice selection and changes neither consent nor focus" {
    const Owner = struct {
        decision: ?Policy.Decision = null,
        fn decide(raw: *anyopaque, _: *vxfw.EventContext, decision: Policy.Decision) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.decision = decision;
        }
    };
    var owner: Owner = .{};
    var consent: Consent = .{};
    const text: vxfw.Text = .{ .text = "Run tests" };
    var card: Self = .{ .consent = &consent, .description = "Run", .body = text.widget(), .userdata = &owner, .on_decision = Owner.decide, .style = .{ .fg = .{ .index = 2 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    consent.adopt(41);
    _ = try card.widget().draw(ctx);
    // Both choices take the hover look, retaining foreground, while the other keeps its reverse.
    for ([_]Policy.Choice{ .deny, .allow_once }) |choice| {
        card.hover_style = .{ .ul_style = .single };
        consent.highlight = if (choice == .deny) .allow_once else .deny;
        const before = consent.highlight;
        const col: u16 = if (choice == .deny) 17 else 3;
        try card.widget().handleEvent(&events, .mouse_enter);
        try card.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(col), .row = 3, .button = .none, .type = .motion, .mods = .{} } });
        const hovered = try card.widget().draw(ctx);
        try std.testing.expect(!hovered.readCell(col, 3).style.reverse);
        try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.readCell(col, 3).style.ul_style);
        try std.testing.expectEqual(card.style.fg, hovered.readCell(col, 3).style.fg);
        try std.testing.expect(hovered.readCell(if (choice == .deny) 3 else 17, 3).style.reverse);
        card.hover_style = .{ .bg = .{ .index = 5 } };
        const coloured = try card.widget().draw(ctx);
        try std.testing.expectEqual(vaxis.Color{ .index = 5 }, coloured.readCell(col, 3).style.bg);
        // The highlighted choice keeps its reverse under the pointer.
        consent.highlight = if (choice == .deny) .deny else .allow_once;
        const both = try card.widget().draw(ctx);
        try std.testing.expect(both.readCell(col, 3).style.reverse);
        consent.highlight = before;
        try std.testing.expect(card.hover.pointing);
        try std.testing.expectEqual(before, consent.highlight);
        try std.testing.expectEqual(Policy.Row.selector, consent.row);
        try std.testing.expectEqual(null, owner.decision);
        for (events.cmds.items) |command| try std.testing.expect(command != .request_focus);
        try card.widget().handleEvent(&events, .mouse_leave);
        const left = try card.widget().draw(ctx);
        try std.testing.expect(!left.readCell(col, 3).style.reverse);
        try std.testing.expectEqual(card.style.bg, left.readCell(col, 3).style.bg);
        try std.testing.expect(!card.hover.pointing);
    }
    // Padding and a clipped-away choice have neither hover nor click authority.
    try card.widget().handleEvent(&events, .{ .mouse = .{ .col = 14, .row = 3, .button = .none, .type = .motion, .mods = .{} } });
    try std.testing.expect(!card.hover.pointing);
    _ = try card.widget().draw(ctx.withConstraints(.{}, .{ .width = 1, .height = 1 }));
    try card.widget().handleEvent(&events, .{ .mouse = .{ .col = 17, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
    try std.testing.expect(!card.hover.pointing);
    _ = try card.widget().draw(ctx);
    for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try card.widget().handleEvent(&events, .{ .mouse = .{ .col = 17, .row = 3, .button = .left, .type = kind, .mods = .{} } });
    try std.testing.expectEqual(@as(?Policy.Decision, .{ .action = 41, .choice = .deny }), owner.decision);
}
