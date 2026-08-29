const std = @import("std");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");

const task = "Apply the durable fixture patch.";
const answer = "The durable patch Result reached the Conversation.";
const patch =
    "diff --git a/note.txt b/note.txt\n" ++
    "--- a/note.txt\n" ++
    "+++ b/note.txt\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4 and args.len != 5) return error.InvalidArguments;
    const runtime = try harness.HostRuntime.open(init.io, allocator, args[2], .{});
    defer runtime.close() catch unreachable;
    if (std.mem.startsWith(u8, args[1], "start-")) {
        try start(init.io, runtime, args[1], args[3]);
    } else if (std.mem.startsWith(u8, args[1], "resume-")) {
        if (args.len != 5) return error.InvalidArguments;
        try resumeSession(init.io, runtime, args[1], try std.fmt.parseInt(u64, args[4], 16));
    } else return error.InvalidMode;
}

fn start(io: std.Io, runtime: *harness.HostRuntime, mode: []const u8, workspace: []const u8) !void {
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = answer,
        .expected_patch_status = .applied,
    };
    var crash: Crash = .{ .target = if (std.mem.eql(u8, mode, "start-authorization"))
        .after_patch_authorization
    else if (std.mem.eql(u8, mode, "start-attempt"))
        .after_patch_attempt
    else if (std.mem.eql(u8, mode, "start-mutation"))
        .after_patch_mutation
    else
        return error.InvalidMode };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .permission_mode = .bypass,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model_binding = .{ .model = "fixture:patch-crash", .provider = fixture.provider() },
            .task = task,
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    const identity = try owner.drive();
    const session_id = identity.projections[0].session_id;
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    for (0..16) |_| {
        if (owner.drive()) |_| {} else |err| {
            if (err != error.InjectedCrash) return err;
            var id_buffer: [16]u8 = undefined;
            try std.Io.File.stdout().writeStreamingAll(
                io,
                try session_store.formatId(session_id, &id_buffer),
            );
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
            return;
        }
    }
    return error.CrashBoundaryNotReached;
}

fn resumeSession(
    io: std.Io,
    runtime: *harness.HostRuntime,
    mode: []const u8,
    session_id: u64,
) !void {
    const finished_only = std.mem.eql(u8, mode, "resume-finished");
    const expected: patch_tool.ResultStatus = if (finished_only or std.mem.eql(u8, mode, "resume-applied"))
        .applied
    else if (std.mem.eql(u8, mode, "resume-stale"))
        .stale
    else if (std.mem.eql(u8, mode, "resume-indeterminate"))
        .indeterminate
    else
        return error.InvalidMode;
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = answer,
        .expected_patch_status = expected,
        .calls = if (finished_only) 0 else 1,
    };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id, .model_binding = .{
            .model = "fixture:patch-crash",
            .provider = fixture.provider(),
        } } },
    });
    defer owner.close();
    for (0..24) |_| {
        const progress = try owner.drive();
        if (progress.state != .finished) continue;
        const expected_calls: usize = if (finished_only) 0 else 2;
        if (fixture.calls != expected_calls) {
            return error.ModelDispatchCountMismatch;
        }
        try std.Io.File.stdout().writeStreamingAll(io, "finished\n");
        return;
    }
    return error.SessionDidNotFinish;
}

const Crash = struct {
    target: harness.FaultBoundary,

    fn reached(context: *anyopaque, boundary: harness.FaultBoundary) anyerror!void {
        const self: *Crash = @ptrCast(@alignCast(context));
        if (boundary == self.target) return error.InjectedCrash;
    }

    fn hook(self: *Crash) harness.FaultHook {
        return .{ .context = self, .reached = reached };
    }
};
