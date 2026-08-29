const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const binding = @import("binding.zig");
const completion_inbox = @import("completion_inbox.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");
const host_runtime = @import("host_runtime.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const task = "Recover one deterministic external effect.";
const answer = "Recovered with a new model Attempt.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;
    const mode = args[1];
    const runtime = try harness.HostRuntime.open(init.io, allocator, args[2], .{});
    defer runtime.close() catch unreachable;

    if (std.mem.eql(u8, mode, "start-model")) {
        try startModel(init.io, runtime, args[3]);
    } else if (std.mem.eql(u8, mode, "retry-model")) {
        try retryModel(init.io, runtime, try parseSessionId(args[3]));
    } else if (std.mem.eql(u8, mode, "finish-model")) {
        try finishModel(init.io, runtime, try parseSessionId(args[3]));
    } else if (std.mem.eql(u8, mode, "late-model")) {
        try lateModel(init.io, runtime, try parseSessionId(args[3]));
    } else if (std.mem.eql(u8, mode, "exhaust-model")) {
        try exhaustModel(init.io, runtime, try parseSessionId(args[3]));
    } else if (std.mem.eql(u8, mode, "start-bash")) {
        try startBash(init.io, runtime, args[3]);
    } else if (std.mem.eql(u8, mode, "resume-bash")) {
        try resumeBash(init.io, runtime, try parseSessionId(args[3]));
    } else return error.InvalidMode;
}

fn startModel(io: std.Io, runtime: *harness.HostRuntime, workspace: []const u8) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var crash: Crash = .{ .target = .after_model_dispatch };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model = "fixture:model-recovery",
            .task = task,
            .provider = fixture.provider(),
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    const identity = try owner.drive();
    const session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try driveUntilCrash(owner);
    owner.close();
    try expectModelAttempts(runtime, session_id, 1);
    try writeSessionId(io, session_id);
}

fn retryModel(io: std.Io, runtime: *harness.HostRuntime, session_id: u64) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var crash: Crash = .{ .target = .after_model_dispatch };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .provider = fixture.provider(),
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    try driveUntilCrash(owner);
    if (fixture.calls != 1) return error.ModelAttemptNotDispatched;
    try std.Io.File.stdout().writeStreamingAll(io, "dispatched\n");
}

fn finishModel(io: std.Io, runtime: *harness.HostRuntime, session_id: u64) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id, .provider = fixture.provider() } },
    });
    defer owner.close();
    for (0..48) |_| {
        const progress = try owner.drive();
        if (progress.state != .finished) continue;
        if (fixture.calls != 1) return error.ModelAttemptNotDispatched;
        owner.close();
        try expectModelAttempts(runtime, session_id, 2);
        try std.Io.File.stdout().writeStreamingAll(io, "finished\n");
        return;
    }
    return error.SessionDidNotFinish;
}

fn lateModel(io: std.Io, runtime: *harness.HostRuntime, session_id: u64) !void {
    var lease = try host_runtime.Lease.acquire(runtime);
    var restored = try lease.restoreSession(session_id);
    while ((try lease.recoverSemanticWindow(&restored.session, 32)).more) {}
    var audit: ModelAttemptAudit = .{};
    const before = try restored.session.inspectSemantic(&audit, ModelAttemptAudit.apply);
    if (audit.count != 2) return error.ModelAttemptCountMismatch;

    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try model_protocol.encodeText(&response_buffer, "late original response");
    const result_ref = (@as(u64, 1) << 54) | (audit.ids[0] & ((@as(u64, 1) << 54) - 1));
    try restored.session.storeBlob(result_ref, response);
    const envelope = completion_inbox.bind(.{
        .kind = .model,
        .session_id = session_id,
        .ownership_epoch = audit.ownership_epoch,
        .agent_id = restored.session.agent_id,
        .agent_generation = 1,
        .operation_id = audit.operation_id,
        .operation_generation = audit.operation_generation,
        .attempt_id = audit.ids[0],
        .result_ref = result_ref,
        .result_digest = binding.hash(binding.Result, response),
    });
    try restored.session.publishCompletionEvidence(envelope);
    if (try restored.session.scanCompletionEvidence(undefined, rejectPendingCompletion) != 0) {
        return error.LateEvidenceRemainedPending;
    }
    restored.session.close();
    lease.release();

    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer owner.close();
    if (owner.offer(.{ .completion = envelope }) != .accepted) return error.LateEvidenceOfferRejected;
    for (0..24) |_| {
        const progress = try owner.drive();
        for (progress.projectionSlice()) |projection| {
            if (projection.kind == .failure) return error.LateEvidenceProjectedFailure;
        }
        if (progress.state != .finished) continue;
        owner.close();

        var verification_lease = try host_runtime.Lease.acquire(runtime);
        defer verification_lease.release();
        var verified = try verification_lease.restoreSession(session_id);
        defer verified.session.close();
        while ((try verification_lease.recoverSemanticWindow(&verified.session, 32)).more) {}
        var after_audit: ModelAttemptAudit = .{};
        const after = try verified.session.inspectSemantic(&after_audit, ModelAttemptAudit.apply);
        if (after.last_sequence != before.last_sequence or after_audit.count != audit.count) {
            return error.LateEvidenceAdvancedSession;
        }
        try std.Io.File.stdout().writeStreamingAll(io, "audited\n");
        return;
    }
    return error.LateEvidenceDidNotSettle;
}

fn rejectPendingCompletion(_: *anyopaque, _: completion_inbox.Envelope) anyerror!void {
    return error.LateEvidenceRemainedPending;
}

fn exhaustModel(io: std.Io, runtime: *harness.HostRuntime, session_id: u64) !void {
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer owner.close();
    for (0..24) |_| {
        const progress = try owner.drive();
        if (progress.state != .failed) continue;
        if (progress.projection_count != 1 or progress.projections[0].kind != .failure) {
            return error.ModelFailureProjectionMissing;
        }
        owner.close();
        try expectModelAttempts(runtime, session_id, 8);
        try std.Io.File.stdout().writeStreamingAll(io, "failed\n");
        return;
    }
    return error.ModelRetryLimitNotTerminal;
}

fn startBash(io: std.Io, runtime: *harness.HostRuntime, workspace: []const u8) !void {
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf x >> uncertain.txt",
        .timeout_ms = 5000,
    });
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = call,
        .final_answer = "must not be reached",
    };
    var crash: Crash = .{ .target = .after_bash_execution };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .permission_mode = .bypass,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model = "fixture:bash-recovery",
            .task = task,
            .provider = fixture.provider(),
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    const identity = try owner.drive();
    const session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try driveUntilCrash(owner);
    try writeSessionId(io, session_id);
}

fn resumeBash(io: std.Io, runtime: *harness.HostRuntime, session_id: u64) !void {
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer owner.close();
    for (0..24) |_| {
        const progress = try owner.drive();
        for (progress.projectionSlice()) |projection| {
            if (projection.kind != .indeterminate) continue;
            try std.Io.File.stdout().writeStreamingAll(io, "indeterminate\n");
            return;
        }
    }
    return error.IndeterminateProjectionMissing;
}

fn driveUntilCrash(owner: *harness.Harness) !void {
    for (0..48) |_| {
        if (owner.drive()) |_| continue else |err| {
            if (err != error.InjectedCrash) return err;
            return;
        }
    }
    return error.CrashBoundaryNotReached;
}

fn sessionProjection(progress: *const harness.Progress) !u64 {
    if (progress.projection_count != 1 or progress.projections[0].kind != .session) {
        return error.SessionProjectionMissing;
    }
    return progress.projections[0].session_id;
}

fn writeSessionId(io: std.Io, session_id: u64) !void {
    var buffer: [16]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try session_store.formatId(session_id, &buffer));
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn parseSessionId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 16);
}

fn expectModelAttempts(runtime: *harness.HostRuntime, session_id: u64, expected: u8) !void {
    var lease = try host_runtime.Lease.acquire(runtime);
    defer lease.release();
    var restored = try lease.restoreSession(session_id);
    defer restored.session.close();
    while ((try lease.recoverSemanticWindow(&restored.session, 32)).more) {}
    var audit: ModelAttemptAudit = .{};
    _ = try restored.session.inspectSemantic(&audit, ModelAttemptAudit.apply);
    if (audit.count != expected) return error.ModelAttemptCountMismatch;
}

const ModelAttemptAudit = struct {
    ids: [session_transition.max_operation_attempts]u64 = @splat(0),
    count: u8 = 0,
    operation_id: u64 = 0,
    operation_generation: u32 = 0,
    ownership_epoch: u64 = 0,

    fn apply(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *ModelAttemptAudit = @ptrCast(@alignCast(context));
        const attempt = switch (fact) {
            .attempt_admitted => |value| value,
            else => return,
        };
        if (attempt.recovery_class != .model) return;
        if (self.count == self.ids.len) return error.ModelAttemptCapacityExceeded;
        if (attempt.possible_duplicate_attempts != self.count) {
            return error.ModelDuplicateExposureMismatch;
        }
        if (self.count == 0) {
            self.operation_id = attempt.operation.operation_id;
            self.operation_generation = attempt.operation.generation;
            self.ownership_epoch = attempt.operation.agent.ownership_epoch;
        } else if (attempt.operation.operation_id != self.operation_id or
            attempt.operation.generation != self.operation_generation)
        {
            return error.ModelOperationChangedAcrossRetry;
        }
        for (self.ids[0..self.count]) |id| {
            if (id == attempt.attempt_id) return error.ModelAttemptReused;
        }
        self.ids[self.count] = attempt.attempt_id;
        self.count += 1;
    }
};

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
