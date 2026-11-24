const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Root = @import("Root.zig");
const Input = @import("SessionInput.zig");
const app_input = @import("app_input.zig");
const clipboard = @import("clipboard_paste.zig");

const Clock = struct {
    var nanoseconds: i96 = 0;

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        if (clock != .awake) return std.testing.io.vtable.now(userdata, clock);
        return .fromNanoseconds(nanoseconds);
    }
};

const Owner = struct {
    input: Input = undefined,
    failure: ?clipboard.Failure = null,
    failures: usize = 0,
    got_text: bool = false,

    fn changed(_: *anyopaque) void {}

    fn candidates(_: *anyopaque, _: *[std.enums.values(app_input.Target).len]Root.Candidate) Root.Projection {
        return .{ .len = 0 };
    }

    fn target(raw: *anyopaque) ?Input.Insertion {
        const self: *Owner = @ptrCast(@alignCast(raw));
        return self.input.insertionTarget();
    }

    fn paste(raw: *anyopaque, _: *vxfw.EventContext, data: Root.ClipboardData) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        switch (data) {
            .failure => |reason| {
                self.failure = reason;
                self.failures += 1;
            },
            .text => |bytes| self.got_text = std.mem.eql(u8, bytes, "x"),
            .image => |bytes| {
                std.heap.page_allocator.free(bytes);
                return error.UnexpectedClipboardImage;
            },
            .local_image => return error.UnexpectedLocalClipboard,
        }
    }
};

test "SUI-147 clipboard expiry follows the latest frame deadline" {
    for ([_]i96{ -1, 0, 1 }) |offset| {
        var owner: Owner = .{};
        owner.input.init();
        defer owner.input.deinit();
        const text: vxfw.Text = .{ .text = "" };
        const widget = text.widget();
        var root: Root = .{ .overview = widget, .list = widget, .session = widget };
        defer root.deinitClipboard();
        root.session_focus = .{
            .context = &owner,
            .changed = Owner.changed,
            .candidates = Owner.candidates,
            .clipboard = .{ .target = Owner.target, .paste = Owner.paste },
        };
        var vtable = std.testing.io.vtable.*;
        vtable.now = Clock.now;
        var io = std.testing.io;
        io.vtable = &vtable;
        var ctx: vxfw.EventContext = .{ .io = io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        Clock.nanoseconds = 100 * std.time.ns_per_s;
        try root.widget().handleEvent(&ctx, .{ .clipboard_protocol = true });
        for ([_][]const u8{
            "type=read:status=OK:pw=dG9rZW4=",
            "type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbg==",
            "type=read:status=DONE",
            "type=read:status=OK:id=1",
        }) |frame| {
            Clock.nanoseconds += 100 * std.time.ns_per_ms;
            try root.widget().handleEvent(&ctx, .{ .osc_5522 = frame });
        }
        const deadline = root.clipboard_deadline orelse return error.MissingClipboardDeadline;
        try std.testing.expectEqual(Clock.nanoseconds + 5 * std.time.ns_per_s, deadline);
        Clock.nanoseconds = deadline + offset;
        try root.widget().handleEvent(&ctx, .tick);
        if (offset < 0) {
            try std.testing.expectEqual(@as(?clipboard.Failure, null), owner.failure);
        } else {
            try std.testing.expectEqual(@as(?clipboard.Failure, .timed_out), owner.failure);
        }
        try root.widget().handleEvent(&ctx, .{ .osc_5522 = "type=read:status=DATA:id=1:mime=dGV4dC9wbGFpbg==;eA==" });
        try root.widget().handleEvent(&ctx, .{ .osc_5522 = "type=read:status=DONE:id=1" });
        try std.testing.expectEqual(offset < 0, owner.got_text);
        try std.testing.expectEqual(@as(?i96, null), root.clipboard_deadline);
        Clock.nanoseconds = deadline + 6 * std.time.ns_per_s;
        try root.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(usize, if (offset < 0) 0 else 1), owner.failures);
    }
}
