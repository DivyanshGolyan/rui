const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const binding = @import("binding.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");

const task = "Explain the fixture repository.";
const answer = "The fixture contains a durable one-page agent.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const raw_args = try init.minimal.args.toSlice(allocator);
    if (raw_args.len != 1) return error.InvalidArguments;
    var layout = try Layout.init(init.io, allocator);
    defer layout.deinit(init.io);

    var fixture: deterministic_provider.Fixture = .{
        .expected_task = task,
        .final_answer = answer,
    };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:answer", .provider = fixture.provider() },
            .task = task,
        } },
    });
    const identity = try owner.drive();
    if (layout.runtime.occupiedActivationBytes() != 0 or fixture.calls != 0) {
        return error.OpenRetainedActivationOrDispatched;
    }
    const session_id = try sessionProjection(&identity);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    const finished = try owner.drive();
    try expectFinal(owner, &finished, answer);
    const borrowed_final = finalProjection(&finished) orelse return error.FinalAnswerProjectionMissing;
    _ = try owner.drive();
    if (owner.openProjectionContent(borrowed_final)) |reader_value| {
        var reader = reader_value;
        reader.close();
        return error.StaleProjectionRemainedUsable;
    } else |err| if (err != error.StaleProjection) return err;
    if (fixture.calls != 1) return error.ModelDispatchCountMismatch;
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    try expectFinal(restored, &regenerated, answer);

    try lostCompletionNotificationRecovers(&layout, init.io, allocator);
    try offeredPermissionDenialContinues(&layout, init.io, allocator);
    try restoredBashApprovalDispatchesExactDescriptor(&layout, init.io, allocator);
    try restoredPatchApprovalUsesExactDescriptor(&layout, init.io, allocator);
    try approvedPatchCompletesOnce(&layout, init.io, allocator);
    try cancellationRegenerates(&layout, init.io, allocator);
    try uncommittedTaskCanBeReadmitted(&layout, init.io, allocator);
    try uncertainModelRetryUsesNewAttempt(&layout, init.io, allocator);
    try exhaustedModelRetriesBecomeFailure(&layout, init.io, allocator);
    try uncertainBashNeverReplays(&layout, init.io, allocator);
}

fn uncommittedTaskCanBeReadmitted(
    layout: *Layout,
    _: std.Io,
    _: std.mem.Allocator,
) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:task-readmission", .provider = fixture.provider() },
            .task = task,
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:task-readmission", .provider = fixture.provider() },
        } },
    });
    defer restored.close();
    const identity = try restored.drive();
    if (identity.state != .restoring) return error.SessionRecoveryNotStarted;
    const ready = try restored.drive();
    if (ready.state != .ready) return error.UncommittedTaskWasAcknowledged;
    if (restored.offer(.task) != .accepted) return error.TaskReadmissionRejected;
    _ = try restored.drive();
    const finished = try restored.drive();
    try expectFinal(restored, &finished, answer);
}

fn cancellationRegenerates(
    layout: *Layout,
    _: std.Io,
    _: std.mem.Allocator,
) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:cancelled", .provider = fixture.provider() },
            .task = task,
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
        .runtime = layout.runtime,
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
    layout: *Layout,
    io: std.Io,
    _: std.mem.Allocator,
) !void {
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf forbidden >> denied.txt",
        .timeout_ms = 5000,
    });
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = call,
        .final_answer = answer,
        .expected_tool_status = .denied,
    };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:permission-denied", .provider = fixture.provider() },
            .task = task,
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    _ = try owner.drive();
    const waiting = try owner.drive();
    const original_approval = approvalProjection(&waiting) orelse return error.ApprovalProjectionMissing;
    const original_digest = original_approval.descriptor_digest orelse
        return error.ApprovalProjectionIncomplete;
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:permission-denied", .provider = fixture.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    const approval = approvalProjection(&regenerated) orelse return error.ApprovalProjectionMissingAfterRestore;
    if (approval.content_ref == 0 or approval.descriptor_digest == null) {
        return error.ApprovalProjectionIncomplete;
    }
    if (approval.content_ref != original_approval.content_ref or
        !binding.descriptorEql(approval.descriptor_digest.?, original_digest))
    {
        return error.RestoredBashDescriptorMismatch;
    }
    if (restored.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = .{ .bash = binding.hash(binding.BashDescriptor, "wrong-authority") },
        .allow = false,
    } }) != .invalid) return error.MismatchedPermissionAccepted;
    if (restored.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = approval.descriptor_digest orelse return error.ApprovalProjectionIncomplete,
        .allow = false,
    } }) != .accepted) return error.PermissionOfferRejected;
    _ = try restored.drive();
    const finished = try restored.drive();
    try expectFinal(restored, &finished, answer);
    const denied = layout.workspace.openFile(io, "denied.txt", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    denied.close(io);
    return error.DeniedBashExecuted;
}

fn restoredBashApprovalDispatchesExactDescriptor(
    layout: *Layout,
    io: std.Io,
    _: std.mem.Allocator,
) !void {
    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf bound > approved.txt",
        .timeout_ms = 5000,
    });
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = call,
        .final_answer = answer,
    };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:restored-bash-authority", .provider = fixture.provider() },
            .task = task,
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    _ = try owner.drive();
    const waiting = try owner.drive();
    const initial = approvalProjection(&waiting) orelse return error.ApprovalProjectionMissing;
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:restored-bash-authority", .provider = fixture.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    const approval = approvalProjection(&regenerated) orelse
        return error.ApprovalProjectionMissingAfterRestore;
    const initial_digest = initial.descriptor_digest orelse return error.ApprovalProjectionIncomplete;
    const approval_digest = approval.descriptor_digest orelse return error.ApprovalProjectionIncomplete;
    if (approval.content_ref != initial.content_ref or
        approval.operation_id != initial.operation_id or
        approval.operation_generation != initial.operation_generation or
        !binding.descriptorEql(approval_digest, initial_digest))
    {
        return error.RestoredBashDescriptorMismatch;
    }
    var reader = try restored.openProjectionContent(approval);
    defer reader.close();
    var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const descriptor_length: usize = @intCast(reader.length());
    if (descriptor_length > descriptor_buffer.len) return error.InvalidBashDescriptor;
    const descriptor_bytes = try reader.readWindow(0, descriptor_buffer[0..descriptor_length]);
    const descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
    var canonical_workspace: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_workspace_length = try std.Io.Dir.cwd().realPathFile(
        io,
        layout.workspace_path,
        &canonical_workspace,
    );
    const expected_workspace = canonical_workspace[0..canonical_workspace_length];
    if (descriptor.operation_id != approval.operation_id or
        descriptor.operation_generation != approval.operation_generation or
        !std.mem.eql(u8, descriptor.workspace_path, expected_workspace) or
        !std.mem.eql(u8, descriptor.working_directory, expected_workspace) or
        !std.mem.eql(u8, descriptor.call.command, "printf bound > approved.txt") or
        descriptor.call.timeout_ms != 5000)
    {
        return error.RestoredBashDescriptorMismatch;
    }
    if (restored.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = approval_digest,
        .allow = true,
    } }) != .accepted) return error.PermissionOfferRejected;
    var progress = try restored.drive();
    for (0..4) |_| {
        if (progress.state == .finished) break;
        progress = try restored.drive();
    }
    try expectFinal(restored, &progress, answer);
    var approved = try layout.workspace.openFile(io, "approved.txt", .{});
    defer approved.close(io);
    var content: [5]u8 = undefined;
    if (try approved.readPositionalAll(io, &content, 0) != content.len or
        !std.mem.eql(u8, &content, "bound"))
    {
        return error.ApprovedBashDidNotExecute;
    }
}

fn restoredPatchApprovalUsesExactDescriptor(
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const patch =
        "diff --git a/approval.txt b/approval.txt\n" ++
        "--- a/approval.txt\n" ++
        "+++ b/approval.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    var file = try layout.workspace.createFile(io, "approval.txt", .{});
    try file.writeStreamingAll(io, "old\n");
    file.close(io);
    const added = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", layout.workspace_path, "add", "approval.txt" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(added.stdout);
    defer allocator.free(added.stderr);
    switch (added.term) {
        .exited => |code| if (code != 0) return error.GitAddFailed,
        else => return error.GitAddFailed,
    }

    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = answer,
    };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:restored-patch-approval", .provider = fixture.provider() },
            .task = task,
        } },
    });
    const identified = try owner.drive();
    const session_id = try sessionProjection(&identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    _ = try owner.drive();
    const waiting = try owner.drive();
    _ = approvalProjection(&waiting) orelse return error.ApprovalProjectionMissing;
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
            .model_binding = .{ .model = "fixture:restored-patch-approval", .provider = fixture.provider() },
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const regenerated = try restored.drive();
    const approval = approvalProjection(&regenerated) orelse
        return error.ApprovalProjectionMissingAfterRestore;
    var descriptor = try restored.openProjectionContent(approval);
    errdefer descriptor.close();
    var descriptor_bytes: [256]u8 = undefined;
    const actual = try descriptor.readWindow(0, descriptor_bytes[0..patch.len]);
    descriptor.close();
    if (!std.mem.eql(u8, actual, patch)) return error.RestoredPatchDescriptorMismatch;
    if (restored.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = .{ .apply_patch = binding.hash(binding.PatchIntent, "stale-intent") },
        .allow = true,
    } }) != .invalid) return error.StalePatchAuthorizationAccepted;
    if (restored.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = approval.descriptor_digest orelse return error.ApprovalProjectionIncomplete,
        .allow = false,
    } }) != .accepted) return error.PermissionOfferRejected;
    _ = try restored.drive();
    const finished = try restored.drive();
    try expectFinal(restored, &finished, answer);
}

fn approvedPatchCompletesOnce(
    layout: *Layout,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const patch =
        "diff --git a/shutdown-approval.txt b/shutdown-approval.txt\n" ++
        "--- a/shutdown-approval.txt\n" ++
        "+++ b/shutdown-approval.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    var file = try layout.workspace.createFile(io, "shutdown-approval.txt", .{});
    try file.writeStreamingAll(io, "old\n");
    file.close(io);
    const added = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", layout.workspace_path, "add", "shutdown-approval.txt" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(added.stdout);
    defer allocator.free(added.stderr);
    switch (added.term) {
        .exited => |code| if (code != 0) return error.GitAddFailed,
        else => return error.GitAddFailed,
    }

    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = answer,
        .expected_patch_status = .applied,
    };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:approved-patch", .provider = fixture.provider() },
            .task = task,
        } },
    });
    defer owner.close();
    _ = try owner.drive();
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    _ = try owner.drive();
    const waiting = try owner.drive();
    const approval = approvalProjection(&waiting) orelse return error.ApprovalProjectionMissing;
    if (owner.offer(.{ .permission = .{
        .operation_id = approval.operation_id,
        .operation_generation = approval.operation_generation,
        .descriptor_digest = approval.descriptor_digest orelse return error.ApprovalProjectionIncomplete,
        .allow = true,
    } }) != .accepted) return error.PermissionOfferRejected;
    const deferred = try owner.drive();
    if (deferred.state != .waiting) return error.ApprovedPatchDidNotDefer;
    var progress = try owner.drive();
    for (0..5) |_| {
        if (progress.state == .finished) break;
        progress = try owner.drive();
    }
    try expectFinal(owner, &progress, answer);
    var changed = try layout.workspace.openFile(io, "shutdown-approval.txt", .{});
    defer changed.close(io);
    var bytes: [4]u8 = undefined;
    if (try changed.readPositionalAll(io, &bytes, 0) != bytes.len or
        !std.mem.eql(u8, &bytes, "new\n"))
    {
        return error.ApprovedPatchDidNotApply;
    }
}

fn approvalProjection(progress: *const harness.Progress) ?harness.Projection {
    for (progress.projectionSlice()) |projection| {
        if (projection.kind == .approval_required) return projection;
    }
    return null;
}

fn lostCompletionNotificationRecovers(
    layout: *Layout,
    _: std.Io,
    _: std.mem.Allocator,
) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var capture: Crash = .{ .target = .after_completion_inbox };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:lost-notification", .provider = fixture.provider() },
            .task = task,
            .fault = capture.hook(),
        } },
    });
    const first = try owner.drive();
    const session_id = try sessionProjection(&first);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try expectInjectedCrash(owner);
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{ .session_id = session_id } },
    });
    defer restored.close();
    _ = try restored.drive();
    _ = try restored.drive();
    const recovered = try restored.drive();
    try expectFinal(restored, &recovered, answer);
}

fn uncertainModelRetryUsesNewAttempt(
    layout: *Layout,
    _: std.Io,
    _: std.mem.Allocator,
) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var capture: Crash = .{ .target = .after_model_dispatch };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:model-retry", .provider = fixture.provider() },
            .task = task,
            .fault = capture.hook(),
        } },
    });
    const first = try owner.drive();
    const session_id = try sessionProjection(&first);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try expectInjectedCrash(owner);
    owner.close();

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{ .session_id = session_id, .model_binding = .{
            .model = "fixture:model-retry",
            .provider = fixture.provider(),
        } } },
    });
    defer restored.close();
    _ = try restored.drive();
    _ = try restored.drive();
    const recovered = try restored.drive();
    try expectFinal(restored, &recovered, answer);
    if (fixture.calls != 2) return error.ModelRetryDidNotUseSecondAttempt;
}

fn exhaustedModelRetriesBecomeFailure(
    layout: *Layout,
    _: std.Io,
    _: std.mem.Allocator,
) !void {
    var fixture: deterministic_provider.Fixture = .{ .expected_task = task, .final_answer = answer };
    var capture: Crash = .{ .target = .after_model_dispatch };
    const session_id = initial: {
        var owner = try harness.Harness.open(.{
            .runtime = layout.runtime,
            .mode = .{ .create = .{
                .workspace_path = layout.workspace_path,
                .model_binding = .{ .model = "fixture:model-retry-exhaustion", .provider = fixture.provider() },
                .task = task,
                .fault = capture.hook(),
            } },
        });
        defer owner.close();
        const first = try owner.drive();
        const id = try sessionProjection(&first);
        if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
        try expectInjectedCrash(owner);
        break :initial id;
    };

    for (0..7) |_| {
        var retry = try harness.Harness.open(.{
            .runtime = layout.runtime,
            .mode = .{ .restore = .{
                .session_id = session_id,
                .model_binding = .{ .model = "fixture:model-retry-exhaustion", .provider = fixture.provider() },
                .fault = capture.hook(),
            } },
        });
        defer retry.close();
        _ = try retry.drive();
        try expectInjectedCrash(retry);
    }

    var restored = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .mode = .{ .restore = .{
            .session_id = session_id,
        } },
    });
    defer restored.close();
    _ = try restored.drive();
    const waiting = try restored.drive();
    if (waiting.state != .waiting) return error.ModelRetryExhaustionNotPublished;
    const failed = try restored.drive();
    if (failed.state != .failed or failed.projectionSlice()[0].kind != .failure) {
        return error.ModelRetryExhaustionNotTerminal;
    }
    if (fixture.calls != 8) return error.ModelRetryExceededCapacity;
}

fn uncertainBashNeverReplays(
    layout: *Layout,
    io: std.Io,
    _: std.mem.Allocator,
) !void {
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
    var capture: Crash = .{ .target = .after_bash_execution };
    var owner = try harness.Harness.open(.{
        .runtime = layout.runtime,
        .permission_mode = .bypass,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{ .model = "fixture:uncertain-bash", .provider = fixture.provider() },
            .task = task,
            .fault = capture.hook(),
        } },
    });
    const first = try owner.drive();
    const session_id = try sessionProjection(&first);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    _ = try owner.drive();
    try expectInjectedCrash(owner);
    owner.close();

    inline for (0..2) |_| {
        var restored = try harness.Harness.open(.{
            .runtime = layout.runtime,
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

fn expectFinal(
    owner: *harness.Harness,
    progress: *const harness.Progress,
    expected: []const u8,
) !void {
    if (progress.state != .finished) return error.SessionDidNotFinish;
    for (progress.projectionSlice()) |projection| {
        if (projection.kind != .final_answer) continue;
        var reader = try owner.openProjectionContent(projection);
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
    for (0..8) |_| {
        if (owner.drive()) |_| continue else |err| {
            if (err != error.InjectedCrash) return err;
            return;
        }
    }
    return error.CrashBoundaryNotReached;
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
    runtime: *harness.HostRuntime,
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
        try root.createDir(io, "repo", .default_dir);
        var workspace = try root.openDir(io, "repo", .{});
        errdefer workspace.close(io);
        const runtime = try harness.HostRuntime.open(io, allocator, root_path, .{});
        errdefer runtime.close() catch unreachable;
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
            .runtime = runtime,
            .workspace = workspace,
            .workspace_path = workspace_path,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Layout, io: std.Io) void {
        self.runtime.close() catch unreachable;
        self.workspace.close(io);
        self.allocator.free(self.workspace_path);
        self.root.close(io);
        // Test cleanup must not hide the lifecycle result being verified.
        std.Io.Dir.cwd().deleteTree(io, self.root_path) catch {};
        self.allocator.free(self.root_path);
    }
};
