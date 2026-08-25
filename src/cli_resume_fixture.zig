const std = @import("std");
const harness = @import("harness.zig");
const host_store = @import("host_store.zig");
const model_operation = @import("model_operation.zig");
const session_store = @import("session.zig");

const task = "Resume this interrupted fixture Session.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    var sessions = try std.Io.Dir.cwd().createDirPathOpen(
        init.io,
        args[1],
        .{ .permissions = .fromMode(0o700) },
    );
    defer sessions.close(init.io);
    const database_path = try std.fs.path.join(allocator, &.{ args[1], "host.sqlite3" });
    defer allocator.free(database_path);
    var storage = try host_store.StorageOwner.open(init.io, database_path, .{});
    defer storage.close();
    var host: harness.Host = .{};
    var fixture: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = "must be retried",
    };
    var crash: Crash = .{};
    var owner = try harness.Harness.open(.{
        .host = &host,
        .storage = &storage,
        .sessions = sessions,
        .io = init.io,
        .allocator = allocator,
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
