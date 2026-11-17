const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Root = @import("Root.zig");
const app_input = @import("app_input.zig");
const targets = std.enums.values(app_input.Target);

const Control = struct {
    activations: usize = 0,

    fn widget(self: *Control) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Control = @ptrCast(@alignCast(raw));
        return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
    }

    fn activate(raw: *anyopaque, _: *vxfw.EventContext) !void {
        const self: *Control = @ptrCast(@alignCast(raw));
        self.activations += 1;
    }
};

const Owner = struct {
    controls: [targets.len]Control = @splat(.{}),
    deliveries: usize = 0,

    fn widget(self: *Owner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Owner = @ptrCast(@alignCast(raw));
        const children = try ctx.arena.alloc(vxfw.SubSurface, targets.len);
        for (&self.controls, children, 0..) |*control, *child, i| {
            child.* = .{ .origin = .{ .row = @intCast(i), .col = 0 }, .surface = .{
                .widget = control.widget(),
                .size = .{ .width = 2, .height = 1 },
                .buffer = &.{},
                .children = &.{},
            } };
        }
        return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = children };
    }

    fn changed(_: *anyopaque) void {}

    fn candidates(raw: *anyopaque, out: *[targets.len]Root.Candidate) Root.Projection {
        const self: *Owner = @ptrCast(@alignCast(raw));
        for (targets, &self.controls, out) |target, *control, *candidate| {
            candidate.* = .{ .target = target, .widget = control.widget(), .activate = Control.activate };
        }
        return .{ .len = targets.len };
    }

    fn keys(raw: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event, _: app_input.Effects.Delivery) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        self.deliveries += 1;
    }

    fn total(self: *const Owner) usize {
        var count: usize = 0;
        for (self.controls) |control| count += control.activations;
        return count;
    }

    fn bind(self: *Owner, root: *Root, ctx: *vxfw.EventContext) !void {
        root.session_focus = .{ .context = self, .changed = changed, .candidates = candidates };
        try root.openSession(ctx, self.widget(), .{ .context = self, .take = keys });
    }
};

const Switcher = struct {
    root: *Root,
    next: *Owner,
    deliveries: usize = 0,
    switches: usize = 0,

    fn keys(raw: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event, _: app_input.Effects.Delivery) !void {
        const self: *Switcher = @ptrCast(@alignCast(raw));
        self.deliveries += 1;
        if (event == .key_press and (event.key_press.matches(vaxis.Key.up, .{ .alt = true }) or event.key_press.matches(vaxis.Key.down, .{ .alt = true }))) {
            try self.replace(ctx);
        }
    }

    fn replace(self: *Switcher, ctx: *vxfw.EventContext) !void {
        try self.root.closeSession(ctx);
        try self.next.bind(self.root, ctx);
        self.switches += 1;
    }
};

fn press(root: *Root, ctx: *vxfw.EventContext, codepoint: u21, alt: bool) !void {
    try root.widget().captureEvent(ctx, .{ .key_press = .{ .codepoint = codepoint, .mods = .{ .alt = alt } } });
}

fn focus(root: *Root, ctx: *vxfw.EventContext, target: app_input.Target) !void {
    for (0..targets.len + 1) |_| {
        if (app_input.currentFocus(root.input) == target) return;
        try press(root, ctx, vaxis.Key.tab, false);
    }
    return error.FocusTargetNotReached;
}

fn activates(target: app_input.Target) bool {
    return switch (target) {
        .list, .input, .model, .effort => false,
        else => true,
    };
}

test "Root focus owner domain routes keys and retires callbacks across replacement before repaint" {
    const Action = enum { tab, enter, alt_up, alt_down, switch_before_repaint };
    for ([_]u16{ 46, 140 }) |width| for (targets) |target| for (std.enums.values(Action)) |action| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var old: Owner = .{};
        var new: Owner = .{};
        var sidebar: Control = .{};
        var root: Root = .{ .overview = sidebar.widget(), .list = sidebar.widget() };
        var switcher: Switcher = .{ .root = &root, .next = &new };
        root.overview_keys = .{ .context = &switcher, .take = Switcher.keys };
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 30 }, .cell_size = .{} };
        try old.bind(&root, &ctx);
        _ = try root.widget().draw(draw_ctx);
        try focus(&root, &ctx, target);
        switch (action) {
            .tab => {
                try press(&root, &ctx, vaxis.Key.tab, false);
                try std.testing.expect(app_input.currentFocus(root.input) != target);
                try std.testing.expectEqual(@as(usize, 0), old.total());
            },
            .enter => {
                try press(&root, &ctx, vaxis.Key.enter, false);
                try std.testing.expectEqual(@as(usize, @intFromBool(activates(target))), old.controls[@backingInt(target)].activations);
                try std.testing.expectEqual(@as(usize, @intFromBool(target == .list)), switcher.deliveries);
                try std.testing.expectEqual(@as(usize, @intFromBool(target == .input or target == .model or target == .effort)), old.deliveries);
            },
            .alt_up, .alt_down => {
                try press(&root, &ctx, if (action == .alt_up) vaxis.Key.up else vaxis.Key.down, true);
                try std.testing.expectEqual(@as(usize, 1), switcher.switches);
                try std.testing.expectEqual(@as(usize, 1), switcher.deliveries);
                try std.testing.expectEqual(@as(usize, 0), old.deliveries);
                try std.testing.expectEqual(@as(usize, 0), old.total());
            },
            .switch_before_repaint => try switcher.replace(&ctx),
        }
        if (action == .tab or action == .enter) try switcher.replace(&ctx);
        const retired_activations = old.total();
        const retired_deliveries = old.deliveries;
        try press(&root, &ctx, vaxis.Key.tab, false);
        try press(&root, &ctx, vaxis.Key.enter, false);
        try std.testing.expectEqual(@as(usize, 2), new.deliveries);
        try std.testing.expectEqual(@as(usize, 0), new.total());
        try std.testing.expectEqual(retired_activations, old.total());
        try std.testing.expectEqual(retired_deliveries, old.deliveries);
        _ = try root.widget().draw(draw_ctx);
        try focus(&root, &ctx, target);
        try press(&root, &ctx, vaxis.Key.enter, false);
        try std.testing.expectEqual(@as(usize, @intFromBool(activates(target))), new.controls[@backingInt(target)].activations);
        try std.testing.expectEqual(retired_activations, old.total());
        try std.testing.expectEqual(retired_deliveries, old.deliveries);
    };
}
