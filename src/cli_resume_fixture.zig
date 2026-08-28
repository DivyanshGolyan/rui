const std = @import("std");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");
const session_store = @import("session.zig");

const task = "Resume this interrupted fixture Session.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    const runtime = try harness.HostRuntime.open(init.io, allocator, args[1], .{});
    defer runtime.close() catch unreachable;
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = task,
        .final_answer = "must be retried",
    };
    var crash: Crash = .{};
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model = "fixture:interrupted",
            .task = task,
            .provider = fixture.provider(),
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    const identified = try owner.drive();
    if (identified.projection_count != 1 or identified.projections[0].kind != .session) {
        return error.SessionProjectionMissing;
    }
    const session_id = identified.projections[0].session_id;
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    if (owner.drive()) |_| return error.CrashBoundaryNotReached else |err| {
        if (err != error.InjectedCrash) return err;
    }
    var id_buffer: [16]u8 = undefined;
    const id = try session_store.formatId(session_id, &id_buffer);
    try std.Io.File.stdout().writeStreamingAll(init.io, id);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

const Crash = struct {
    fn reached(_: *anyopaque, boundary: harness.FaultBoundary) anyerror!void {
        if (boundary == .after_model_dispatch) return error.InjectedCrash;
    }

    fn hook(self: *Crash) harness.FaultHook {
        return .{ .context = self, .reached = reached };
    }
};
