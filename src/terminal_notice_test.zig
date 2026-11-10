//! Native adapter actor: no Host, frontend or syscall interposition.
const std = @import("std");
pub const panic = @import("vaxis").Panic;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "app-resize")) {
        var runtime: @import("TerminalApp.zig") = .{};
        try runtime.init(init.io, init.environ_map);
        defer runtime.deinit();
        var probe: ResizeProbe = .{};
        var root: @import("Root.zig") = .{ .overview = probe.widget() };
        try runtime.run(root.widget());
        return;
    }
    if (args.len == 2 and (std.mem.eql(u8, args[1], "consent-replaced") or std.mem.eql(u8, args[1], "consent-live"))) {
        var runtime: @import("TerminalApp.zig") = .{};
        try runtime.init(init.io, init.environ_map);
        defer runtime.deinit();
        var probe: ConsentProbe = .{ .replace_request = std.mem.eql(u8, args[1], "consent-replaced") };
        var root: @import("Root.zig") = .{ .overview = probe.widget() };
        probe.pasting = &root.pasting;
        try runtime.run(root.widget());
        if (probe.decision) |decision|
            std.debug.print("decision={d}:{s}\n", .{ decision.action, @tagName(decision.choice) })
        else
            std.debug.print("decision=none\n", .{});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "app-signal")) {
        var runtime: @import("TerminalApp.zig") = .{};
        try runtime.init(init.io, init.environ_map);
        defer runtime.deinit();
        const text: @import("vaxis").vxfw.Text = .{ .text = "App signal fixture" };
        var screen = text.widget();
        screen.eventHandler = struct {
            fn event(_: *anyopaque, _: *@import("vaxis").vxfw.EventContext, _: @import("vaxis").vxfw.Event) !void {}
        }.event;
        var root: @import("Root.zig") = .{ .overview = screen };
        try runtime.run(root.widget());
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "app-init-oom")) {
        var memory: std.testing.FailingAllocator = .init(std.heap.page_allocator, .{ .fail_index = 0 });
        var output: [4096]u8 = undefined;
        var app = @import("vaxis").vxfw.App.init(init.io, memory.allocator(), init.environ_map, &output) catch |err| {
            if (err != error.OutOfMemory) return err;
            try std.Io.File.stderr().writeStreamingAll(init.io, "App.init: OutOfMemory\n");
            return;
        };
        app.deinit();
        return error.ExpectedAllocationFailure;
    }
    return error.InvalidArguments;
}

const ResizeProbe = struct {
    const vxfw = @import("vaxis").vxfw;
    empty_drawn: bool = false,
    text: vxfw.Text = .{ .text = "App resize restored" },

    fn widget(self: *ResizeProbe) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(_: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
        if (input == .key_press and input.key_press.matchExact(@import("vaxis").Key.enter, .{})) ctx.quit = true;
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ResizeProbe = @ptrCast(@alignCast(raw));
        const size = ctx.max.size();
        if (size.width == 0 or size.height == 0) {
            if (!self.empty_drawn) std.debug.print("empty={d}x{d}\n", .{ size.width, size.height });
            self.empty_drawn = true;
            return .empty(self.widget());
        }
        var surface = try self.text.widget().draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};

const ConsentProbe = struct {
    const vxfw = @import("vaxis").vxfw;
    consent: @import("ActionConsent.zig") = .{},
    card: @import("PermissionCard.zig") = undefined,
    pasting: *const bool = undefined,
    replace_request: bool,
    decision: ?@import("session_consent.zig").Decision = null,
    text: vxfw.Text = .{ .text = "$ true" },

    fn widget(self: *ConsentProbe) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
        const self: *ConsentProbe = @ptrCast(@alignCast(raw));
        switch (input) {
            .init => {
                self.consent.adopt(17);
                self.card = .{ .consent = &self.consent, .pasting = self.pasting, .description = "Run the probe", .body = self.text.widget(), .userdata = self, .on_decision = decided };
            },
            .key_press, .invalid_key => {
                if (self.replace_request) self.consent.adopt(29);
                try self.card.widget().handleEvent(ctx, input);
                ctx.quit = true;
            },
            .tick => try self.card.widget().handleEvent(ctx, input),
            else => {},
        }
    }

    fn decided(raw: *anyopaque, _: *vxfw.EventContext, decision: @import("session_consent.zig").Decision) !void {
        const self: *ConsentProbe = @ptrCast(@alignCast(raw));
        self.decision = decision;
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ConsentProbe = @ptrCast(@alignCast(raw));
        var surface = try self.card.widget().draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};
