const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const harness = @import("harness.zig");
const model_operation = @import("model_operation.zig");

const task = "Explain the fixture repository.";
const answer = "The fixture contains a durable one-page agent.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const raw_args = try init.minimal.args.toSlice(allocator);
    if (raw_args.len != 1) return error.InvalidArguments;
    var layout = try Layout.init(init.io, allocator);
    defer layout.deinit(init.io);
    var host: harness.Host = .{};

    var fixture: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = answer,
    };
    var owner = try harness.Harness.open(.{
        .host = &host,
        .sessions = layout.sessions,
        .io = init.io,
        .allocator = allocator,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:answer",
            .task = task,
            .provider = fixture.provider(),
        } },
    });
    const identity = try owner.drive();
    if (host.slots.occupiedBytes() != 0 or fixture.calls != 0) {
        return error.OpenRetainedActivationOrDispatched;
    }
    const session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    const finished = try owner.drive();
    try expectFinal(&finished, answer);
    const borrowed_final = finalProjection(&finished) orelse return error.FinalAnswerProjectionMissing;
    _ = try owner.drive();
    if (borrowed_final.openContent()) |reader_value| {
        var reader = reader_value;
        reader.close();
        return error.StaleProjectionRemainedUsable;
    } else |err| if (err != error.StaleProjection) return err;
    if (fixture.calls != 1) return error.ModelDispatchCountMismatch;
    owner.close();

    var restored = try harness.Harness.open(.{
        .host = &host,
        .sessions = layout.sessions,
        .io = init.io,
        .allocator = allocator,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    _ = try restored.drive();
    const regenerated = try restored.drive();
    try expectFinal(&regenerated, answer);
    restored.close();

    try lostCompletionNotificationRecovers(&host, &layout, init.io, allocator);
    try offeredPermissionDenialContinues(&host, &layout, init.io, allocator);
    try cancellationRegenerates(&host, &layout, init.io, allocator);
    try uncommittedTaskCanBeReadmitted(&host, &layout, init.io, allocator);
    try uncertainModelRetryUsesNewAttempt(&host, &layout, init.io, allocator);
    try uncertainBashNeverReplays(&host, &layout, init.io, allocator);
}

fn uncommittedTaskCanBeReadmitted(
    host: *harness.Host,
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var fixture: model_operation.Fixture = .{ .expected_task = task, .final_answer = answer };
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:task-readmission",
            .task = task,
            .provider = fixture.provider(),
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    owner.close();

    var restored = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .provider = fixture.provider(),
        } },
    });
    defer restored.close();
    const identity = try restored.drive();
    if (identity.state != .ready) return error.UncommittedTaskWasAcknowledged;
    if (restored.offer(.task) != .accepted) return error.TaskReadmissionRejected;
    _ = try restored.drive();
    const finished = try restored.drive();
    try expectFinal(&finished, answer);
}

fn cancellationRegenerates(
    host: *harness.Host,
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var fixture: model_operation.Fixture = .{ .expected_task = task, .final_answer = answer };
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:cancelled",
            .task = task,
            .provider = fixture.provider(),
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.cancel) != .accepted) return error.CancellationOfferRejected;
    const cancelled = try owner.drive();
    if (cancelled.state != .cancelled or cancelled.projectionSlice()[0].session_id != session_id or
        cancelled.committed != 1)
    {
        return error.CancellationNotCommitted;
    }
    owner.close();

    var restored = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    if (regenerated.state != .cancelled or regenerated.projectionSlice()[0].kind != .cancelled) {
        return error.CancellationNotRegenerated;
    }
}

fn offeredPermissionDenialContinues(
    host: *harness.Host,
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf forbidden >> denied.txt",
        .timeout_ms = 5000,
    });
    var fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = call,
        .final_answer = answer,
        .expected_tool_status = .denied,
    };
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:permission-denied",
            .task = task,
            .provider = fixture.provider(),
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    const waiting = try owner.drive();
    _ = approvalProjection(&waiting) orelse return error.ApprovalProjectionMissing;
    owner.close();

    var restored = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .provider = fixture.provider(),
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    const approval = approvalProjection(&regenerated) orelse return error.ApprovalProjectionMissingAfterRestore;
    if (approval.content_ref == 0 or approval.descriptor_digest == 0) {
        return error.ApprovalProjectionIncomplete;
    }
    if (restored.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = approval.descriptor_digest,
        .allow = false,
    } }) != .accepted) return error.PermissionOfferRejected;
    _ = try restored.drive();
    const finished = try restored.drive();
    try expectFinal(&finished, answer);
    const denied = layout.workspace.openFile(io, "denied.txt", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    denied.close(io);
    return error.DeniedBashExecuted;
}

fn approvalProjection(progress: *const harness.Progress) ?harness.Projection {
    for (progress.projectionSlice()) |projection| {
        if (projection.kind == .approval_required) return projection;
    }
    return null;
}

fn lostCompletionNotificationRecovers(
    host: *harness.Host,
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var fixture: model_operation.Fixture = .{ .expected_task = task, .final_answer = answer };
    var capture: Crash = .{ .target = .after_completion_inbox };
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:lost-notification",
            .task = task,
            .provider = fixture.provider(),
            .fault = capture.hook(),
        } },
    });
    const first = try owner.drive();
    const session_id = try sessionProjection(&first);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try expectInjectedCrash(&owner);
    owner.close();

    var restored = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    _ = try restored.drive();
    _ = try restored.drive();
    const recovered = try restored.drive();
    try expectFinal(&recovered, answer);
}

fn uncertainModelRetryUsesNewAttempt(
    host: *harness.Host,
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var fixture: model_operation.Fixture = .{ .expected_task = task, .final_answer = answer };
    var capture: Crash = .{ .target = .after_model_dispatch };
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:model-retry",
            .task = task,
            .provider = fixture.provider(),
            .fault = capture.hook(),
        } },
    });
    const first = try owner.drive();
    const session_id = try sessionProjection(&first);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try expectInjectedCrash(&owner);
    owner.close();

    var restored = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .mode = .{ .restore = .{ .session_id = session_id, .provider = fixture.provider() } },
    });
    defer restored.close();
    _ = try restored.drive();
    _ = try restored.drive();
    const recovered = try restored.drive();
    try expectFinal(&recovered, answer);
    if (fixture.calls != 2) return error.ModelRetryDidNotUseSecondAttempt;
}

fn uncertainBashNeverReplays(
    host: *harness.Host,
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf x >> uncertain.txt",
        .timeout_ms = 5000,
    });
    var fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = call,
        .final_answer = "must not be reached",
    };
    var capture: Crash = .{ .target = .after_bash_execution };
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = layout.sessions,
        .io = io,
        .allocator = allocator,
        .permission_mode = .bypass,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model = "fixture:uncertain-bash",
            .task = task,
            .provider = fixture.provider(),
            .fault = capture.hook(),
        } },
    });
    const first = try owner.drive();
    const session_id = try sessionProjection(&first);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    try expectInjectedCrash(&owner);
    owner.close();

    inline for (0..2) |_| {
        var restored = try harness.Harness.open(.{
            .host = host,
            .sessions = layout.sessions,
            .io = io,
            .allocator = allocator,
            .mode = .{ .restore = .{ .session_id = session_id } },
        });
        _ = try restored.drive();
        const progress = try restored.drive();
        if (progress.state != .waiting or progress.projection_count != 1 or
            progress.projections[0].kind != .indeterminate)
        {
            return error.IndeterminateProjectionMissing;
        }
        restored.close();
    }
    var file = try layout.workspace.openFile(io, "uncertain.txt", .{});
    defer file.close(io);
    var bytes: [2]u8 = undefined;
    const length = try file.readPositionalAll(io, &bytes, 0);
    if (length != 1 or bytes[0] != 'x') return error.UncertainBashReplayed;
}

fn sessionProjection(progress: *const harness.Progress) !u64 {
    if (progress.projection_count != 1 or progress.projections[0].kind != .session) {
        return error.SessionProjectionMissing;
    }
    return progress.projections[0].session_id;
}

fn expectFinal(progress: *const harness.Progress, expected: []const u8) !void {
    if (progress.state != .finished) return error.SessionDidNotFinish;
    for (progress.projectionSlice()) |projection| {
        if (projection.kind != .final_answer) continue;
        var reader = try projection.openContent();
        defer reader.close();
        var bytes: [256]u8 = undefined;
        if (reader.length() != expected.len) return error.FinalAnswerMismatch;
        const actual = try reader.readWindow(0, bytes[0..expected.len]);
        if (!std.mem.eql(u8, actual, expected)) return error.FinalAnswerMismatch;
        return;
    }
    return error.FinalAnswerProjectionMissing;
}

fn finalProjection(progress: *const harness.Progress) ?harness.Projection {
    for (progress.projectionSlice()) |projection| {
        if (projection.kind == .final_answer) return projection;
    }
    return null;
}

fn expectInjectedCrash(owner: *harness.Harness) !void {
    if (owner.drive()) |_| {
        return error.CrashBoundaryNotReached;
    } else |err| if (err != error.InjectedCrash) {
        return err;
    }
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

const Layout = struct {
    root: std.Io.Dir,
    root_path: []u8,
    sessions: std.Io.Dir,
    workspace: std.Io.Dir,
    workspace_path: []u8,
    allocator: std.mem.Allocator,

    fn init(io: std.Io, allocator: std.mem.Allocator) !Layout {
        var random: [8]u8 = undefined;
        io.random(&random);
        const root_path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/agent-integration-{x}",
            .{random},
        );
        errdefer allocator.free(root_path);
        var root = try std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{});
        errdefer {
            root.close(io);
            // Setup rollback is best effort; the original initialization error is authoritative.
            std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
        }
        try root.createDir(io, "sessions", .default_dir);
        try root.createDir(io, "repo", .default_dir);
        var sessions = try root.openDir(io, "sessions", .{});
        errdefer sessions.close(io);
        var workspace = try root.openDir(io, "repo", .{});
        errdefer workspace.close(io);
        const workspace_path = try std.fs.path.join(allocator, &.{ root_path, "repo" });
        errdefer allocator.free(workspace_path);
        const initialized = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "init", "--quiet", workspace_path },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        });
        defer allocator.free(initialized.stdout);
        defer allocator.free(initialized.stderr);
        switch (initialized.term) {
            .exited => |code| if (code != 0) return error.GitInitFailed,
            else => return error.GitInitFailed,
        }
        return .{
            .root = root,
            .root_path = root_path,
            .sessions = sessions,
            .workspace = workspace,
            .workspace_path = workspace_path,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Layout, io: std.Io) void {
        self.sessions.close(io);
        self.workspace.close(io);
        self.allocator.free(self.workspace_path);
        self.root.close(io);
        // Test cleanup must not hide the lifecycle result being verified.
        std.Io.Dir.cwd().deleteTree(io, self.root_path) catch {};
        self.allocator.free(self.root_path);
    }
};
