const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const conversation = @import("conversation.zig");
const execution_cells = @import("execution_cells.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const model_request = @import("relational_model_request.zig");
const patch_tool = @import("patch_tool.zig");
const store_module = @import("host_store.zig");

pub const IdentitySource = struct {
    next_value: u64 = 0,
    random_io: ?std.Io = null,

    pub fn random(io: std.Io) IdentitySource {
        return .{ .random_io = io };
    }

    pub fn take(self: *IdentitySource) !u64 {
        if (self.random_io) |io| {
            var value: u64 = 0;
            while (value == 0) {
                io.random(std.mem.asBytes(&value));
                value &= std.math.maxInt(i64);
            }
            return value;
        }
        if (self.next_value == 0 or self.next_value == std.math.maxInt(u64)) {
            return error.IdentityExhausted;
        }
        const value = self.next_value;
        self.next_value += 1;
        return value;
    }
};

pub const ModelAdvance = union(enum) {
    completed: struct { content_id: u64 },
    action: Action,
    failed,
};

pub const Action = struct {
    turn_id: u64,
    parent_model_operation_id: u64,
    operation_id: u64,
    call_entry_id: u64,
    kind: store_module.OperationKind,
};

pub const ModelBuffers = struct {
    request: []u8,
    candidate: []u8,
    tool_call: []u8,
    descriptor: []u8,
};

pub const ActionBuffers = struct {
    descriptor: []u8,
    completion: []u8,
    visible_result: []u8,
};

pub const max_patch_descriptor_size: usize = 16 + patch_tool.max_intent_size + patch_tool.max_patch_size;
const patch_descriptor_magic = "ONEPDS1\x00";

pub fn publishPendingToolResults(
    store: *store_module.Store,
    ids: *IdentitySource,
    turn_id: u64,
) !bool {
    var pending: [8]store_module.PendingToolResult = undefined;
    const count = try store.readPendingToolResults(turn_id, &pending);
    if (count == 0) return false;
    var results: [8]store_module.ToolResultCandidate = undefined;
    for (pending[0..count], 0..) |value, index| {
        results[index] = .{
            .action_operation_id = value.action_operation_id,
            .entry_id = try ids.take(),
        };
    }
    const snapshot = try store.loadDecisionSnapshot(turn_id);
    _ = try store.appendToolResults(.{
        .turn_id = turn_id,
        .parent_model_operation_id = pending[0].parent_model_operation_id,
        .expected_conversation_revision = snapshot.conversation_revision,
        .results = results[0..count],
    });
    return true;
}

pub fn advanceModel(
    store: *store_module.Store,
    ids: *IdentitySource,
    turn_id: u64,
    model: []const u8,
    workspace_path: []const u8,
    io: std.Io,
    provider: model_operation.Provider,
    cell: *execution_cells.Lease,
    buffers: ModelBuffers,
) !ModelAdvance {
    const snapshot = try store.loadDecisionSnapshot(turn_id);
    if (store_module.classify(snapshot) != .runnable) return error.TurnNotRunnable;
    var frontier: [8]store_module.OperationView = undefined;
    const frontier_count = try store.readUnresolvedOperations(turn_id, &frontier);
    var unpublished: [8]store_module.PendingToolResult = undefined;
    if (try store.readPendingToolResults(turn_id, &unpublished) != 0) {
        return error.UnpublishedToolResults;
    }
    if (frontier_count == 1 and frontier[0].kind == .model) {
        if (try store.readUnresolvedCompletion(frontier[0].operation_id)) |completion| {
            const operation = try store.readOperation(frontier[0].operation_id);
            const length = try store.contentLength(completion.content_id);
            if (length > buffers.candidate.len) return error.CapturedModelOutputTooLarge;
            const captured_output = try store.readContent(
                completion.content_id,
                buffers.candidate[0..length],
            );
            if (!std.mem.eql(
                u8,
                &completion.digest,
                &store_module.semanticDigest(.completion, captured_output),
            )) return error.CompletionDigestMismatch;
            return settleCapturedModel(
                store,
                ids,
                turn_id,
                operation.operation_id,
                operation.operation_ordinal,
                completion.attempt_id,
                completion.completion_id,
                completion.content_id,
                snapshot.conversation_revision,
                workspace_path,
                io,
                captured_output,
                buffers,
            );
        }
    }
    var operation_id: u64 = undefined;
    var request_content_id: u64 = undefined;
    var operation_ordinal: u32 = undefined;
    var request_bytes: []const u8 = undefined;
    if (frontier_count == 0) {
        const request = try model_request.encode(store, snapshot.session_id, model, buffers.request);
        operation_id = try ids.take();
        request_content_id = try ids.take();
        operation_ordinal = try store.nextOperationOrdinalForTurn(turn_id);
        request_bytes = request.bytes;
        _ = try store.admitOperation(.{
            .turn_id = turn_id,
            .operation_id = operation_id,
            .operation_ordinal = operation_ordinal,
            .kind = .model,
            .descriptor_content_id = request_content_id,
            .descriptor = request_bytes,
            .descriptor_digest = store_module.semanticDigest(.operation, request_bytes),
        });
    } else if (frontier_count == 1 and frontier[0].kind == .model and
        try store.nextAttemptOrdinalForOperation(frontier[0].operation_id) == 1)
    {
        const operation = try store.readOperation(frontier[0].operation_id);
        const request_length = try store.contentLength(operation.descriptor_content_id);
        if (request_length > buffers.request.len) return error.ModelRequestBufferTooSmall;
        request_bytes = try store.readContent(
            operation.descriptor_content_id,
            buffers.request[0..request_length],
        );
        if (!std.mem.eql(
            u8,
            &operation.descriptor_digest,
            &store_module.semanticDigest(.operation, request_bytes),
        )) return error.ModelRequestDigestMismatch;
        operation_id = operation.operation_id;
        request_content_id = operation.descriptor_content_id;
        operation_ordinal = operation.operation_ordinal;
    } else {
        return error.UnresolvedOperationRequiresRecovery;
    }
    var request_owner: model_operation.BufferedRequest = .{ .bytes = request_bytes };
    const request_cursor = try request_owner.cursor();
    const bound_model = request_cursor.modelName();
    if (!std.mem.eql(u8, bound_model, model)) return error.ModelBindingConflict;
    const attempt_id = try ids.take();
    const parameters_content_id = try ids.take();
    const attempt = try cell.admitAttempt(store, .{
        .operation_id = operation_id,
        .attempt_id = attempt_id,
        .attempt_ordinal = 1,
        .dispatch_content_id = request_content_id,
        .dispatch_request = request_bytes,
        .dispatch_digest = store_module.semanticDigest(.dispatch, request_bytes),
        .parameters_content_id = parameters_content_id,
        .parameters = bound_model,
        .context_cutoff_revision = snapshot.conversation_revision,
        .workspace_digest = store_module.semanticDigest(.workspace, workspace_path),
        .external_idempotency_key = null,
    });
    if (attempt == .replay) return error.UnexpectedAttemptReplay;
    try cell.consume(attempt_id);

    var candidate: model_operation.BufferedCandidate = .{ .bytes = buffers.candidate };
    const outcome = try provider.dispatch(
        provider.context,
        request_cursor,
        candidate.writer(),
    );
    switch (outcome) {
        .candidate => {},
        .failure => |failure| {
            const encoded = try model_protocol.encodeFailure(buffers.candidate, failure.failure);
            candidate.length = @intCast(encoded.len);
        },
    }
    if (candidate.length == 0) return error.EmptyProviderCandidate;

    var validation: model_protocol.ValidationScratch = .{};
    const captured = model_protocol.admit(&validation, candidate.slice());
    const parsed = captured.admission.parsed_value;
    const completion_id = try ids.take();
    const completion_content_id = try ids.take();
    _ = try store.recordCompletion(.{
        .operation_id = operation_id,
        .attempt_id = attempt_id,
        .completion_id = completion_id,
        .completion_ordinal = 1,
        .evidence_kind = if (parsed.disposition == .failure or parsed.disposition == .input_request)
            .failure
        else
            .success,
        .content_id = completion_content_id,
        .content = candidate.slice(),
        .completion_digest = store_module.semanticDigest(.completion, candidate.slice()),
    });
    try cell.completionCommitted(attempt_id);
    return settleCapturedModel(
        store,
        ids,
        turn_id,
        operation_id,
        operation_ordinal,
        attempt_id,
        completion_id,
        completion_content_id,
        snapshot.conversation_revision,
        workspace_path,
        io,
        candidate.slice(),
        buffers,
    );
}

fn settleCapturedModel(
    store: *store_module.Store,
    ids: *IdentitySource,
    turn_id: u64,
    operation_id: u64,
    operation_ordinal: u32,
    attempt_id: u64,
    completion_id: u64,
    completion_content_id: u64,
    conversation_revision: u64,
    workspace_path: []const u8,
    io: std.Io,
    captured_output: []const u8,
    buffers: ModelBuffers,
) !ModelAdvance {
    var validation: model_protocol.ValidationScratch = .{};
    const parsed = model_protocol.admit(&validation, captured_output).admission.parsed_value;
    return switch (parsed.disposition) {
        .final_answer => blk: {
            const answer = captured_output[parsed.text_offset..][0..parsed.text_length];
            const final_entry_id = try ids.take();
            const final_content_id = try ids.take();
            _ = try store.completeTurn(.{
                .turn_id = turn_id,
                .model_operation_id = operation_id,
                .attempt_id = attempt_id,
                .completion_id = completion_id,
                .completion_content_id = completion_content_id,
                .final_entry_id = final_entry_id,
                .final_content_id = final_content_id,
                .captured_output = captured_output,
                .final_answer = answer,
                .completion_digest = store_module.semanticDigest(.completion, captured_output),
                .expected_conversation_revision = conversation_revision,
            });
            break :blk .{ .completed = .{ .content_id = final_content_id } };
        },
        .tool_calls => blk: {
            const call_stride = conversation.call_header_size + model_contract.max_tool_key_size +
                model_contract.max_tool_arguments_envelope_size;
            if (buffers.tool_call.len < parsed.tool_call_count * call_stride or
                buffers.descriptor.len < parsed.tool_call_count)
            {
                return error.ModelBuffersTooSmall;
            }
            const descriptor_stride = buffers.descriptor.len / parsed.tool_call_count;
            var calls: [model_contract.max_tool_count]store_module.ToolCallCandidate = undefined;
            for (0..parsed.tool_call_count) |call_index| {
                const span = parsed.tool_calls[call_index];
                const admitted = try model_protocol.admitToolCallArguments(
                    &validation,
                    captured_output,
                    parsed,
                    call_index,
                );
                const key = captured_output[span.key_offset..][0..span.key_length];
                const kind = try executableKind(key);
                const call_buffer = buffers.tool_call[call_index * call_stride ..][0..call_stride];
                const call_bytes = try conversation.encodeToolCall(call_buffer, .{
                    .key = key,
                    .arguments = admitted.json,
                });
                const descriptor_content_id = try ids.take();
                const descriptor_buffer = buffers.descriptor[call_index * descriptor_stride ..][0..descriptor_stride];
                const descriptor_bytes = switch (kind) {
                    .bash => blk_descriptor: {
                        const bash = try admittedBashArguments(admitted.parsed);
                        break :blk_descriptor try bash_tool.encodeDescriptor(descriptor_buffer, .{
                            .workspace_path = workspace_path,
                            .working_directory = workspace_path,
                            .call = .{ .command = bash.command, .timeout_ms = bash.timeout_ms },
                        });
                    },
                    .apply_patch => blk_descriptor: {
                        const patch = try admittedPatchArguments(admitted.parsed);
                        break :blk_descriptor try encodePatchDescriptor(
                            descriptor_buffer,
                            io,
                            workspace_path,
                            descriptor_content_id,
                            patch,
                        );
                    },
                    .model => unreachable,
                };
                calls[call_index] = .{
                    .entry_id = try ids.take(),
                    .content_id = try ids.take(),
                    .content = call_bytes,
                    .action_operation_id = try ids.take(),
                    .action_operation_ordinal = operation_ordinal + 1 + @as(u32, @intCast(call_index)),
                    .action_kind = kind,
                    .descriptor_content_id = descriptor_content_id,
                    .descriptor = descriptor_bytes,
                    .descriptor_digest = store_module.semanticDigest(.operation, descriptor_bytes),
                };
            }
            _ = try store.admitModelToolCalls(.{
                .turn_id = turn_id,
                .model_operation_id = operation_id,
                .attempt_id = attempt_id,
                .completion_id = completion_id,
                .completion_content_id = completion_content_id,
                .captured_output = captured_output,
                .completion_digest = store_module.semanticDigest(.completion, captured_output),
                .expected_conversation_revision = conversation_revision,
                .calls = calls[0..parsed.tool_call_count],
            });
            break :blk .{ .action = .{
                .turn_id = turn_id,
                .parent_model_operation_id = operation_id,
                .operation_id = calls[0].action_operation_id,
                .call_entry_id = calls[0].entry_id,
                .kind = calls[0].action_kind,
            } };
        },
        .failure, .input_request => blk: {
            const result_content_id = try ids.take();
            const message = if (parsed.disposition == .input_request)
                "input requests require issue #38"
            else
                "model operation failed";
            _ = try store.failTurnFromCompletion(.{
                .turn_id = turn_id,
                .completion = .{
                    .operation_id = operation_id,
                    .attempt_id = attempt_id,
                    .completion_id = completion_id,
                    .completion_ordinal = 1,
                    .evidence_kind = .failure,
                    .completion_content_id = completion_content_id,
                    .completion_content = captured_output,
                    .completion_digest = store_module.semanticDigest(.completion, captured_output),
                    .resolution_kind = .failure,
                    .result_content_id = result_content_id,
                    .result_content = message,
                    .resolution_digest = store_module.semanticDigest(.resolution, message),
                },
                .failure_code = if (parsed.failure == .none) 1 else @intFromEnum(parsed.failure),
            });
            break :blk .failed;
        },
    };
}

pub fn executeBashAction(
    store: *store_module.Store,
    ids: *IdentitySource,
    io: std.Io,
    allocator: std.mem.Allocator,
    action: Action,
    cell: *execution_cells.Lease,
    buffers: ActionBuffers,
) !void {
    if (action.kind != .bash) return error.ExpectedBashAction;
    const operation = try store.readOperation(action.operation_id);
    if (operation.turn_id != action.turn_id or
        operation.caused_by_operation_id != action.parent_model_operation_id or
        operation.caused_by_entry_id != action.call_entry_id)
    {
        return error.InvalidActionProvenance;
    }
    if (try store.readUnresolvedCompletion(action.operation_id)) |recorded| {
        const length = try store.contentLength(recorded.content_id);
        if (length > buffers.completion.len) return error.CompletionBufferTooSmall;
        const completion = try store.readContent(recorded.content_id, buffers.completion[0..length]);
        const result = try bash_tool.decodeResult(completion);
        const visible = try encodeVisibleBashEvidence(
            buffers.visible_result,
            action.call_entry_id,
            result.status,
            result.exit_code,
            result.stdout,
            result.stderr,
        );
        _ = try store.completeAndResolve(.{
            .operation_id = action.operation_id,
            .attempt_id = recorded.attempt_id,
            .completion_id = recorded.completion_id,
            .completion_ordinal = recorded.completion_ordinal,
            .evidence_kind = recorded.evidence_kind,
            .completion_content_id = recorded.content_id,
            .completion_content = completion,
            .completion_digest = recorded.digest,
            .resolution_kind = .success,
            .result_content_id = try ids.take(),
            .result_content = visible,
            .resolution_digest = store_module.semanticDigest(.resolution, visible),
        });
        _ = try publishPendingToolResults(store, ids, action.turn_id);
        return;
    }
    const descriptor_length = try store.contentLength(operation.descriptor_content_id);
    if (descriptor_length > buffers.descriptor.len) return error.ActionDescriptorTooLarge;
    const descriptor_bytes = try store.readContent(
        operation.descriptor_content_id,
        buffers.descriptor[0..descriptor_length],
    );
    if (!std.mem.eql(
        u8,
        &operation.descriptor_digest,
        &store_module.semanticDigest(.operation, descriptor_bytes),
    )) return error.ActionDescriptorDigestMismatch;
    const descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
    const snapshot = try store.loadDecisionSnapshot(action.turn_id);
    const attempt_id = try ids.take();
    const parameters_content_id = try ids.take();
    const attempt = try cell.admitAttempt(store, .{
        .operation_id = action.operation_id,
        .attempt_id = attempt_id,
        .attempt_ordinal = 1,
        .dispatch_content_id = operation.descriptor_content_id,
        .dispatch_request = descriptor_bytes,
        .dispatch_digest = store_module.semanticDigest(.dispatch, descriptor_bytes),
        .parameters_content_id = parameters_content_id,
        .parameters = "local-bash-v1",
        .context_cutoff_revision = snapshot.conversation_revision,
        .workspace_digest = store_module.semanticDigest(.workspace, descriptor.workspace_path),
        .external_idempotency_key = null,
    });
    if (attempt == .replay) return error.UnexpectedAttemptReplay;
    try cell.consume(attempt_id);
    var execution = try bash_tool.executeDescriptor(allocator, io, descriptor, .{});
    defer execution.deinit();
    const completion = try bash_tool.encodeResult(buffers.completion, execution);
    const visible = try encodeVisibleBashResult(buffers.visible_result, action.call_entry_id, execution);
    const completion_id = try ids.take();
    const completion_content_id = try ids.take();
    _ = try store.recordCompletion(.{
        .operation_id = action.operation_id,
        .attempt_id = attempt_id,
        .completion_id = completion_id,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .content_id = completion_content_id,
        .content = completion,
        .completion_digest = store_module.semanticDigest(.completion, completion),
    });
    try cell.completionCommitted(attempt_id);
    _ = try store.completeAndResolve(.{
        .operation_id = action.operation_id,
        .attempt_id = attempt_id,
        .completion_id = completion_id,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .completion_content_id = completion_content_id,
        .completion_content = completion,
        .completion_digest = store_module.semanticDigest(.completion, completion),
        .resolution_kind = .success,
        .result_content_id = try ids.take(),
        .result_content = visible,
        .resolution_digest = store_module.semanticDigest(.resolution, visible),
    });
    _ = try publishPendingToolResults(store, ids, action.turn_id);
}

pub fn executePatchAction(
    store: *store_module.Store,
    ids: *IdentitySource,
    io: std.Io,
    action: Action,
    cell: *execution_cells.Lease,
    buffers: ActionBuffers,
) !void {
    if (action.kind != .apply_patch) return error.ExpectedPatchAction;
    const operation = try store.readOperation(action.operation_id);
    if (operation.turn_id != action.turn_id or
        operation.caused_by_operation_id != action.parent_model_operation_id or
        operation.caused_by_entry_id != action.call_entry_id)
    {
        return error.InvalidActionProvenance;
    }
    if (try store.readUnresolvedCompletion(action.operation_id)) |recorded| {
        if (buffers.completion.len < patch_tool.result_size) return error.CompletionBufferTooSmall;
        const completion = try store.readContent(
            recorded.content_id,
            buffers.completion[0..patch_tool.result_size],
        );
        if (completion.len != patch_tool.result_size) return error.InvalidPatchResult;
        const result = try patch_tool.decodeResult(completion[0..patch_tool.result_size]);
        var text_buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "status={s}", .{@tagName(result.status)});
        const visible = try conversation.encodeToolResult(buffers.visible_result, .{
            .parent_id = action.call_entry_id,
            .is_error = result.status != .applied,
            .content = text,
        });
        _ = try store.completeAndResolve(.{
            .operation_id = action.operation_id,
            .attempt_id = recorded.attempt_id,
            .completion_id = recorded.completion_id,
            .completion_ordinal = recorded.completion_ordinal,
            .evidence_kind = recorded.evidence_kind,
            .completion_content_id = recorded.content_id,
            .completion_content = completion,
            .completion_digest = recorded.digest,
            .resolution_kind = if (result.status == .indeterminate) .indeterminate else .success,
            .result_content_id = try ids.take(),
            .result_content = visible,
            .resolution_digest = store_module.semanticDigest(.resolution, visible),
        });
        _ = try publishPendingToolResults(store, ids, action.turn_id);
        return;
    }
    const descriptor_length = try store.contentLength(operation.descriptor_content_id);
    if (descriptor_length > buffers.descriptor.len) return error.ActionDescriptorTooLarge;
    const descriptor_bytes = try store.readContent(
        operation.descriptor_content_id,
        buffers.descriptor[0..descriptor_length],
    );
    if (!std.mem.eql(
        u8,
        &operation.descriptor_digest,
        &store_module.semanticDigest(.operation, descriptor_bytes),
    )) return error.ActionDescriptorDigestMismatch;
    const descriptor = try decodePatchDescriptor(descriptor_bytes);
    const snapshot = try store.loadDecisionSnapshot(action.turn_id);
    const attempt_ordinal = try store.nextAttemptOrdinalForOperation(action.operation_id);
    const attempt_id = try ids.take();
    const parameters_content_id = try ids.take();
    const attempt = try cell.admitAttempt(store, .{
        .operation_id = action.operation_id,
        .attempt_id = attempt_id,
        .attempt_ordinal = attempt_ordinal,
        .dispatch_content_id = operation.descriptor_content_id,
        .dispatch_request = descriptor_bytes,
        .dispatch_digest = store_module.semanticDigest(.dispatch, descriptor_bytes),
        .parameters_content_id = parameters_content_id,
        .parameters = "local-patch-v1",
        .context_cutoff_revision = snapshot.conversation_revision,
        .workspace_digest = store_module.semanticDigest(.workspace, descriptor.intent.workspace_path),
        .external_idempotency_key = null,
        .possible_duplicate = attempt_ordinal > 1,
    });
    if (attempt == .replay) return error.UnexpectedAttemptReplay;
    try cell.consume(attempt_id);
    const reconciled = try patch_tool.reconcile(io, descriptor.intent, descriptor.patch);
    if (buffers.completion.len < patch_tool.result_size) return error.CompletionBufferTooSmall;
    const completion = buffers.completion[0..patch_tool.result_size];
    try patch_tool.encodeResult(completion[0..patch_tool.result_size], .{
        .status = reconciled.status,
        .intent_ref = descriptor.intent.patch_ref,
        .intent_digest = patch_tool.intentDigest(descriptor.intent),
    });
    var text_buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buffer, "status={s}", .{@tagName(reconciled.status)});
    const visible = try conversation.encodeToolResult(buffers.visible_result, .{
        .parent_id = action.call_entry_id,
        .is_error = reconciled.status != .applied,
        .content = text,
    });
    const completion_id = try ids.take();
    const completion_content_id = try ids.take();
    _ = try store.recordCompletion(.{
        .operation_id = action.operation_id,
        .attempt_id = attempt_id,
        .completion_id = completion_id,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .content_id = completion_content_id,
        .content = completion,
        .completion_digest = store_module.semanticDigest(.completion, completion),
    });
    try cell.completionCommitted(attempt_id);
    _ = try store.completeAndResolve(.{
        .operation_id = action.operation_id,
        .attempt_id = attempt_id,
        .completion_id = completion_id,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .completion_content_id = completion_content_id,
        .completion_content = completion,
        .completion_digest = store_module.semanticDigest(.completion, completion),
        .resolution_kind = if (reconciled.status == .indeterminate) .indeterminate else .success,
        .result_content_id = try ids.take(),
        .result_content = visible,
        .resolution_digest = store_module.semanticDigest(.resolution, visible),
    });
    _ = try publishPendingToolResults(store, ids, action.turn_id);
}

pub fn denyAction(
    store: *store_module.Store,
    ids: *IdentitySource,
    action: Action,
    visible_result: []u8,
) !void {
    if (action.kind == .model) return error.ExpectedActionOperation;
    const operation = try store.readOperation(action.operation_id);
    if (operation.turn_id != action.turn_id or
        operation.caused_by_operation_id != action.parent_model_operation_id or
        operation.caused_by_entry_id != action.call_entry_id or
        operation.kind != action.kind)
    {
        return error.InvalidActionProvenance;
    }
    const visible = try conversation.encodeToolResult(visible_result, .{
        .parent_id = action.call_entry_id,
        .is_error = true,
        .content = "status=denied",
    });
    _ = try store.resolveWithoutCompletion(.{
        .operation_id = action.operation_id,
        .resolution_kind = .denied,
        .content_id = try ids.take(),
        .content = visible,
        .resolution_digest = store_module.semanticDigest(.resolution, visible),
    });
    _ = try publishPendingToolResults(store, ids, action.turn_id);
}

/// Resolve a dispatch whose volatile Host-cell custody was lost. Bash cannot
/// be retried safely without an effect-specific idempotency key, so its exact
/// Tool Call receives an indeterminate result.
pub fn resolveLostAction(
    store: *store_module.Store,
    ids: *IdentitySource,
    action: Action,
    visible_result: []u8,
) !void {
    if (action.kind != .bash) return error.ExpectedBashAction;
    const operation = try store.readOperation(action.operation_id);
    if (operation.turn_id != action.turn_id or
        operation.caused_by_operation_id != action.parent_model_operation_id or
        operation.caused_by_entry_id != action.call_entry_id or
        operation.kind != action.kind)
    {
        return error.InvalidActionProvenance;
    }
    const visible = try conversation.encodeToolResult(visible_result, .{
        .parent_id = action.call_entry_id,
        .is_error = true,
        .content = "status=indeterminate; reason=lost_host_custody",
    });
    _ = try store.resolveWithoutCompletion(.{
        .operation_id = action.operation_id,
        .resolution_kind = .indeterminate,
        .content_id = try ids.take(),
        .content = visible,
        .resolution_digest = store_module.semanticDigest(.resolution, visible),
    });
    _ = try publishPendingToolResults(store, ids, action.turn_id);
}

/// Model dispatch cannot be generically retried after custody is lost. Record
/// indeterminacy without inventing Completion evidence, then fail the Turn.
pub fn failLostModel(
    store: *store_module.Store,
    ids: *IdentitySource,
    turn_id: u64,
    operation_id: u64,
) !void {
    const operation = try store.readOperation(operation_id);
    if (operation.turn_id != turn_id or operation.kind != .model) {
        return error.InvalidModelOperation;
    }
    const message = "model dispatch lost Host custody before Completion";
    _ = try store.failTurnWithoutCompletion(.{
        .turn_id = turn_id,
        .operation_id = operation_id,
        .result_content_id = try ids.take(),
        .message = message,
        .failure_code = 1,
    });
}

const PatchDescriptor = struct {
    intent: patch_tool.Intent,
    patch: []const u8,
};

fn encodePatchDescriptor(
    out: []u8,
    io: std.Io,
    workspace_path: []const u8,
    content_id: u64,
    patch: []const u8,
) ![]const u8 {
    if (out.len < 16 or patch.len == 0 or patch.len > patch_tool.max_patch_size) {
        return error.PatchDescriptorBufferTooSmall;
    }
    const intent = try patch_tool.prepare(io, workspace_path, patch, .{ .patch_ref = content_id });
    const intent_bytes = try patch_tool.encodeIntent(out[16..], intent);
    const total = 16 + intent_bytes.len + patch.len;
    if (total > out.len) return error.PatchDescriptorBufferTooSmall;
    @memset(out[0..16], 0);
    @memcpy(out[0..patch_descriptor_magic.len], patch_descriptor_magic);
    std.mem.writeInt(u32, out[8..12], @intCast(intent_bytes.len), .little);
    std.mem.writeInt(u32, out[12..16], @intCast(patch.len), .little);
    @memcpy(out[16 + intent_bytes.len .. total], patch);
    return out[0..total];
}

fn decodePatchDescriptor(bytes: []const u8) !PatchDescriptor {
    if (bytes.len < 16 or bytes.len > max_patch_descriptor_size or
        !std.mem.eql(u8, bytes[0..patch_descriptor_magic.len], patch_descriptor_magic))
    {
        return error.InvalidPatchDescriptor;
    }
    const intent_length: usize = std.mem.readInt(u32, bytes[8..12], .little);
    const patch_length: usize = std.mem.readInt(u32, bytes[12..16], .little);
    if (intent_length == 0 or intent_length > patch_tool.max_intent_size or
        patch_length == 0 or patch_length > patch_tool.max_patch_size or
        16 + intent_length + patch_length != bytes.len)
    {
        return error.InvalidPatchDescriptor;
    }
    const intent = try patch_tool.decodeIntent(bytes[16..][0..intent_length]);
    const patch = bytes[16 + intent_length ..];
    if (!std.mem.eql(u8, &intent.patch_digest.bytes, &patch_tool.patchDigest(patch).bytes)) {
        return error.InvalidPatchDescriptor;
    }
    return .{ .intent = intent, .patch = patch };
}

const AdmittedBash = struct { command: []const u8, timeout_ms: u32 };

fn admittedBashArguments(value: std.json.Value) !AdmittedBash {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidAdmittedBashArguments,
    };
    const command = switch (object.get("command") orelse return error.InvalidAdmittedBashArguments) {
        .string => |item| item,
        else => return error.InvalidAdmittedBashArguments,
    };
    const timeout = switch (object.get("timeout_ms") orelse return error.InvalidAdmittedBashArguments) {
        .integer => |item| std.math.cast(u32, item) orelse return error.InvalidAdmittedBashArguments,
        .float => |item| if (std.math.isFinite(item) and item >= 0 and
            item <= std.math.maxInt(u32) and @trunc(item) == item)
            @as(u32, @intFromFloat(item))
        else
            return error.InvalidAdmittedBashArguments,
        else => return error.InvalidAdmittedBashArguments,
    };
    try model_contract.validateBashCommand(command);
    if (timeout < bash_tool.min_timeout_ms or timeout > bash_tool.max_timeout_ms) {
        return error.InvalidAdmittedBashArguments;
    }
    return .{ .command = command, .timeout_ms = timeout };
}

fn admittedPatchArguments(value: std.json.Value) ![]const u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidAdmittedPatchArguments,
    };
    const patch = switch (object.get("patch") orelse return error.InvalidAdmittedPatchArguments) {
        .string => |item| item,
        else => return error.InvalidAdmittedPatchArguments,
    };
    try model_contract.validatePatchInput(patch);
    return patch;
}

fn executableKind(key: []const u8) !store_module.OperationKind {
    if (std.mem.eql(u8, key, model_contract.bash_key)) return .bash;
    if (std.mem.eql(u8, key, model_contract.apply_patch_key)) return .apply_patch;
    return error.UnboundToolKey;
}

fn encodeVisibleBashResult(
    out: []u8,
    call_entry_id: u64,
    execution: bash_tool.Execution,
) ![]const u8 {
    return encodeVisibleBashEvidence(
        out,
        call_entry_id,
        execution.status,
        execution.exit_code,
        execution.stdout,
        execution.stderr,
    );
}

fn encodeVisibleBashEvidence(
    out: []u8,
    call_entry_id: u64,
    status: bash_tool.Status,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
) ![]const u8 {
    var content_buffer: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&content_buffer, "status={s}\nexit_code={d}\nstdout_base64=", .{
        @tagName(status),
        exit_code,
    });
    const separator = "\nstderr_base64=";
    const stdout_length = std.base64.standard.Encoder.calcSize(stdout.len);
    const stderr_length = std.base64.standard.Encoder.calcSize(stderr.len);
    const content_length = prefix.len + stdout_length + separator.len + stderr_length;
    if (conversation.result_header_size + content_length > out.len) {
        return error.VisibleToolResultTooLarge;
    }
    _ = try conversation.encodeToolResultHeader(
        out[0..conversation.result_header_size],
        call_entry_id,
        status != .success,
        content_length,
    );
    var cursor: usize = conversation.result_header_size;
    @memcpy(out[cursor..][0..prefix.len], prefix);
    cursor += prefix.len;
    _ = std.base64.standard.Encoder.encode(out[cursor..][0..stdout_length], stdout);
    cursor += stdout_length;
    @memcpy(out[cursor..][0..separator.len], separator);
    cursor += separator.len;
    _ = std.base64.standard.Encoder.encode(out[cursor..][0..stderr_length], stderr);
    cursor += stderr_length;
    return out[0..cursor];
}
