const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const binding = @import("binding.zig");
const completion_inbox = @import("completion_inbox.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");
const host_runtime = @import("host_runtime.zig");
const host_store = @import("host_store.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const task = "Recover one deterministic external effect.";
const answer = "Recovered with a new model Attempt.";
const crash_exit_status: u8 = 86;
const completion_crash_exit_status: u8 = 87;
const transaction_crash_exit_status: u8 = 88;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;
    const mode = args[1];
    var transaction_crash: TransactionProcessCrash = .{ .io = init.io };
    var runtime_config: harness.HostRuntimeConfig = .{};
    if (std.mem.eql(u8, mode, "crash-transaction-model")) {
        runtime_config.storage.fault = transaction_crash.storageHook();
    }
    const runtime = try harness.HostRuntime.open(init.io, allocator, args[2], runtime_config);
    defer runtime.close() catch unreachable;

    if (std.mem.eql(u8, mode, "start-model")) {
        try startModel(init.io, runtime, args[3]);
    } else if (std.mem.eql(u8, mode, "crash-prepublication-model")) {
        try crashPrepublicationModel(init.io, runtime, args[3]);
    } else if (std.mem.eql(u8, mode, "crash-transaction-model")) {
        try crashTransactionModel(runtime, args[3], &transaction_crash);
    } else if (std.mem.eql(u8, mode, "recover-prepublication-model")) {
        try recoverPrepublicationModel(init.io, runtime, try parseCrashIdentity(args[3]));
    } else if (std.mem.eql(u8, mode, "crash-published-model")) {
        try crashPublishedModel(init.io, runtime, args[3]);
    } else if (std.mem.eql(u8, mode, "recover-published-model")) {
        try recoverPublishedModel(init.io, runtime, try parseSessionId(args[3]));
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

fn crashTransactionModel(
    runtime: *harness.HostRuntime,
    workspace: []const u8,
    crash: *TransactionProcessCrash,
) !void {
    const TransactionProvider = struct {
        response_ref: u64 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            const provider_io: *model_operation.ProviderIo = @ptrCast(@alignCast(response.context));
            self.response_ref = provider_io.response_ref;
            try model_protocol.writeText(response, "transaction candidate");
            return .candidate;
        }
    };
    var provider: TransactionProvider = .{};
    crash.response_ref = &provider.response_ref;
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model_binding = .{ .model = "fixture:prepublication", .provider = provider.provider() },
            .task = task,
            .fault = crash.lifecycleHook(),
        } },
    });
    defer owner.close();
    const identity = try owner.drive();
    crash.session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    for (0..48) |_| _ = try owner.drive();
    return error.CrashBoundaryNotReached;
}

fn crashPrepublicationModel(io: std.Io, runtime: *harness.HostRuntime, workspace: []const u8) !void {
    const PrepublicationProvider = struct {
        response_ref: u64 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            const provider_io: *model_operation.ProviderIo = @ptrCast(@alignCast(response.context));
            self.response_ref = provider_io.response_ref;
            try model_protocol.writeText(response, "pre-publication candidate");
            return .candidate;
        }
    };
    var provider: PrepublicationProvider = .{};
    var crash: ProcessCrash = .{ .io = io, .response_ref = &provider.response_ref };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model_binding = .{ .model = "fixture:prepublication", .provider = provider.provider() },
            .task = task,
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    const identity = try owner.drive();
    crash.session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    for (0..48) |_| _ = try owner.drive();
    return error.CrashBoundaryNotReached;
}

fn recoverPrepublicationModel(io: std.Io, runtime: *harness.HostRuntime, identity: CrashIdentity) !void {
    const session_id = identity.session_id;
    {
        var lease = try host_runtime.Lease.acquire(runtime);
        defer lease.release();
        const scratch = try session_store.allocateTransientScratch(lease.allocator);
        defer session_store.destroyTransientScratch(lease.allocator, lease.io, scratch);
        var restored = try lease.restoreSession(scratch, session_id);
        defer restored.close();
        while ((try lease.recoverSemanticWindow(&restored, 32)).more) {}

        var audit: ModelAttemptAudit = .{};
        const ledger = try restored.inspectSemantic(&audit, ModelAttemptAudit.apply);
        if (audit.count != 1) return error.ModelAttemptCountMismatch;
        if (try restored.scanCompletionEvidence(undefined, ignoreCompletion) != 0) {
            return error.PrepublicationCrashGainedCompletionAuthority;
        }
        _ = ledger.last_core orelse return error.MissingLedgerCoreState;
        var bytes: [1]u8 = undefined;
        if (restored.readContent(identity.response_ref, 0, &bytes)) |_| {
            return error.TransientCandidateBecameDurable;
        } else |err| if (err != error.FileNotFound) return err;
    }

    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:prepublication", .provider = fixture.provider() },
        } },
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

fn crashPublishedModel(io: std.Io, runtime: *harness.HostRuntime, workspace: []const u8) !void {
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = task,
        .final_answer = "published exact answer",
    };
    var crash: CompletionProcessCrash = .{ .io = io };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model_binding = .{ .model = "fixture:published-capture", .provider = fixture.provider() },
            .task = task,
            .fault = crash.hook(),
        } },
    });
    defer owner.close();
    const identity = try owner.drive();
    crash.session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    for (0..48) |_| _ = try owner.drive();
    return error.CrashBoundaryNotReached;
}

fn recoverPublishedModel(io: std.Io, runtime: *harness.HostRuntime, session_id: u64) !void {
    const RejectingProvider = struct {
        calls: u8 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            _: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.UnexpectedProviderRedispatch;
        }
    };
    {
        const CapturedCompletion = struct {
            envelope: ?completion_inbox.Envelope = null,

            fn apply(context: *anyopaque, envelope: completion_inbox.Envelope) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                if (self.envelope != null) return error.UnexpectedCompletionCount;
                self.envelope = envelope;
            }
        };
        var lease = try host_runtime.Lease.acquire(runtime);
        defer lease.release();
        const scratch = try session_store.allocateTransientScratch(lease.allocator);
        defer session_store.destroyTransientScratch(lease.allocator, lease.io, scratch);
        var restored = try lease.restoreSession(scratch, session_id);
        defer restored.close();
        while ((try lease.recoverSemanticWindow(&restored, 32)).more) {}
        var capture: CapturedCompletion = .{};
        if (try restored.scanCompletionEvidence(&capture, CapturedCompletion.apply) != 1) {
            return error.CommittedCompletionMissing;
        }
        const envelope = capture.envelope orelse return error.CommittedCompletionMissing;
        var bytes: [model_protocol.max_response_size]u8 = undefined;
        var expected_bytes: [model_protocol.max_response_size]u8 = undefined;
        if (!std.mem.eql(
            u8,
            try restored.readContent(envelope.result_ref, 0, &bytes),
            try model_protocol.encodeText(&expected_bytes, "published exact answer"),
        )) return error.PublishedCaptureChanged;
    }
    var provider: RejectingProvider = .{};
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{
                .model = "fixture:published-capture",
                .provider = provider.provider(),
            },
        } },
    });
    defer owner.close();
    for (0..48) |_| {
        const progress = try owner.drive();
        if (progress.state != .finished) continue;
        if (provider.calls != 0) return error.ProviderRedispatched;
        var found = false;
        for (progress.projectionSlice()) |projection| {
            if (projection.kind != .final_answer) continue;
            var reader = try owner.openProjectionContent(projection);
            var bytes: [64]u8 = undefined;
            const content = try reader.readWindow(0, &bytes);
            if (!std.mem.eql(
                u8,
                content,
                "published exact answer",
            )) return error.PublishedAnswerChanged;
            found = true;
        }
        if (!found) return error.FinalAnswerProjectionMissing;
        owner.close();
        try expectModelAttempts(runtime, session_id, 1);
        try std.Io.File.stdout().writeStreamingAll(io, "finished\n");
        return;
    }
    return error.SessionDidNotFinish;
}

fn startModel(io: std.Io, runtime: *harness.HostRuntime, workspace: []const u8) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var crash: Crash = .{ .target = .after_model_dispatch };
    var owner = try harness.Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = workspace,
            .model_binding = .{ .model = "fixture:model-recovery", .provider = fixture.provider() },
            .task = task,
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
            .model_binding = .{ .model = "fixture:model-recovery", .provider = fixture.provider() },
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
        .mode = .{ .restore = .{ .session_id = session_id, .model_binding = .{
            .model = "fixture:model-recovery",
            .provider = fixture.provider(),
        } } },
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
    const before, const audit, const envelope = initial: {
        var lease = try host_runtime.Lease.acquire(runtime);
        defer lease.release();
        const scratch = try session_store.allocateTransientScratch(lease.allocator);
        defer session_store.destroyTransientScratch(lease.allocator, lease.io, scratch);
        var restored = try lease.restoreSession(scratch, session_id);
        defer restored.close();
        while ((try lease.recoverSemanticWindow(&restored, 32)).more) {}
        var audit: ModelAttemptAudit = .{};
        const before = try restored.inspectSemantic(&audit, ModelAttemptAudit.apply);
        if (audit.count != 2) return error.ModelAttemptCountMismatch;

        var response_buffer: [model_protocol.max_response_size]u8 = undefined;
        const response = try model_protocol.encodeText(&response_buffer, "late original response");
        const result_ref = (@as(u64, 1) << 54) | (audit.ids[0] & ((@as(u64, 1) << 54) - 1));
        try restored.storeContent(result_ref, response);
        const envelope = completion_inbox.bind(.{
            .kind = .model,
            .session_id = session_id,
            .ownership_epoch = audit.ownership_epoch,
            .agent_id = restored.agent_id,
            .agent_generation = 1,
            .operation_id = audit.operation_id,
            .operation_generation = audit.operation_generation,
            .attempt_id = audit.ids[0],
            .result_ref = result_ref,
            .result_digest = binding.hash(binding.Result, response),
        });
        try restored.publishCompletionEvidence(envelope);
        if (try restored.scanCompletionEvidence(undefined, rejectPendingCompletion) != 0) {
            return error.LateEvidenceRemainedPending;
        }
        break :initial .{ before, audit, envelope };
    };

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
        const verification_scratch = try session_store.allocateTransientScratch(verification_lease.allocator);
        defer session_store.destroyTransientScratch(verification_lease.allocator, verification_lease.io, verification_scratch);
        var verified = try verification_lease.restoreSession(verification_scratch, session_id);
        defer verified.close();
        while ((try verification_lease.recoverSemanticWindow(&verified, 32)).more) {}
        var after_audit: ModelAttemptAudit = .{};
        const after = try verified.inspectSemantic(&after_audit, ModelAttemptAudit.apply);
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

fn ignoreCompletion(_: *anyopaque, _: completion_inbox.Envelope) anyerror!void {}

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
            .model_binding = .{ .model = "fixture:bash-recovery", .provider = fixture.provider() },
            .task = task,
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

const CrashIdentity = struct {
    session_id: u64,
    response_ref: u64,
};

fn writeCrashIdentity(io: std.Io, identity: CrashIdentity) !void {
    var buffer: [34]u8 = undefined;
    const encoded = try std.fmt.bufPrint(
        &buffer,
        "{x:0>16}:{x:0>16}\n",
        .{ identity.session_id, identity.response_ref },
    );
    try std.Io.File.stdout().writeStreamingAll(io, encoded);
}

fn parseCrashIdentity(text: []const u8) !CrashIdentity {
    if (text.len != 33 or text[16] != ':') return error.InvalidCrashIdentity;
    return .{
        .session_id = try parseSessionId(text[0..16]),
        .response_ref = try parseSessionId(text[17..33]),
    };
}

fn expectModelAttempts(runtime: *harness.HostRuntime, session_id: u64, expected: u8) !void {
    var lease = try host_runtime.Lease.acquire(runtime);
    defer lease.release();
    const scratch = try session_store.allocateTransientScratch(lease.allocator);
    defer session_store.destroyTransientScratch(lease.allocator, lease.io, scratch);
    var restored = try lease.restoreSession(scratch, session_id);
    defer restored.close();
    while ((try lease.recoverSemanticWindow(&restored, 32)).more) {}
    var audit: ModelAttemptAudit = .{};
    _ = try restored.inspectSemantic(&audit, ModelAttemptAudit.apply);
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

const ProcessCrash = struct {
    io: std.Io,
    session_id: u64 = 0,
    response_ref: *const u64,

    fn reached(context: *anyopaque, boundary: harness.FaultBoundary) anyerror!void {
        if (boundary != .after_model_dispatch) return;
        const self: *ProcessCrash = @ptrCast(@alignCast(context));
        writeCrashIdentity(self.io, .{
            .session_id = self.session_id,
            .response_ref = self.response_ref.*,
        }) catch std.process.exit(crash_exit_status + 1);
        std.process.exit(crash_exit_status);
    }

    fn hook(self: *ProcessCrash) harness.FaultHook {
        return .{ .context = self, .reached = reached };
    }
};

const CompletionProcessCrash = struct {
    io: std.Io,
    session_id: u64 = 0,

    fn reached(context: *anyopaque, boundary: harness.FaultBoundary) anyerror!void {
        if (boundary != .after_completion_inbox) return;
        const self: *CompletionProcessCrash = @ptrCast(@alignCast(context));
        writeSessionId(self.io, self.session_id) catch std.process.exit(completion_crash_exit_status + 1);
        std.process.exit(completion_crash_exit_status);
    }

    fn hook(self: *CompletionProcessCrash) harness.FaultHook {
        return .{ .context = self, .reached = reached };
    }
};

const TransactionProcessCrash = struct {
    io: std.Io,
    session_id: u64 = 0,
    response_ref: ?*const u64 = null,
    armed: bool = false,

    fn lifecycleReached(context: *anyopaque, boundary: harness.FaultBoundary) anyerror!void {
        if (boundary != .after_model_dispatch) return;
        const self: *TransactionProcessCrash = @ptrCast(@alignCast(context));
        self.armed = true;
    }

    fn storageReached(context: *anyopaque, boundary: host_store.FaultBoundary) anyerror!void {
        const self: *TransactionProcessCrash = @ptrCast(@alignCast(context));
        if (!self.armed or boundary != .before_commit) return;
        const response_ref = self.response_ref orelse std.process.exit(transaction_crash_exit_status + 1);
        writeCrashIdentity(self.io, .{
            .session_id = self.session_id,
            .response_ref = response_ref.*,
        }) catch std.process.exit(transaction_crash_exit_status + 1);
        std.process.exit(transaction_crash_exit_status);
    }

    fn lifecycleHook(self: *TransactionProcessCrash) harness.FaultHook {
        return .{ .context = self, .reached = lifecycleReached };
    }

    fn storageHook(self: *TransactionProcessCrash) host_store.FaultHook {
        return .{ .context = self, .reached = storageReached };
    }
};
