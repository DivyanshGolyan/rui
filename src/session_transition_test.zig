const std = @import("std");
const binding = @import("binding.zig");
const completion_inbox = @import("completion_inbox.zig");
const transition = @import("session_transition.zig");

test "pre-release fact kinds use one contiguous current numbering" {
    const kinds = [_]transition.Kind{
        .task_admitted,
        .operation_admitted,
        .attempt_admitted,
        .authorization,
        .result,
        .conversation_advanced,
        .outcome,
        .cancellation,
        .shutdown,
        .result_applied,
        .approval_required,
    };
    for (kinds, 1..) |kind, expected| {
        try std.testing.expectEqual(@as(u8, @intCast(expected)), @intFromEnum(kind));
    }
}

test "descriptor kind is the stable tag for descriptors Completions and durable evidence" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(binding.DescriptorKind.model));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(binding.DescriptorKind.bash));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(binding.DescriptorKind.apply_patch));

    const descriptor: binding.Descriptor = .{
        .bash = binding.hash(binding.BashDescriptor, "descriptor"),
    };
    const evidence: transition.DurableResultEvidence = .{ .bash = 7 };
    const completion = completion_inbox.bind(.{
        .kind = .bash,
        .session_id = 11,
        .ownership_epoch = 13,
        .agent_id = 17,
        .agent_generation = 1,
        .operation_id = 19,
        .operation_generation = 1,
        .attempt_id = 23,
        .result_ref = 29,
        .result_digest = binding.hash(binding.Result, "result"),
    });
    const descriptor_kind: binding.DescriptorKind = std.meta.activeTag(descriptor);
    const evidence_kind: binding.DescriptorKind = std.meta.activeTag(evidence);
    const completion_kind: binding.DescriptorKind = completion.kind;
    try std.testing.expectEqual(binding.DescriptorKind.bash, descriptor_kind);
    try std.testing.expectEqual(descriptor_kind, evidence_kind);
    try std.testing.expectEqual(descriptor_kind, completion_kind);
}

test "Attempt constructors derive effect category from the descriptor tag" {
    const operation: transition.OperationContext = .{
        .agent = .{ .agent_id = 7, .agent_generation = 1, .ownership_epoch = 2 },
        .operation_id = 11,
        .generation = 3,
    };
    const consequential = transition.consequentialAttemptAdmitted(
        operation,
        13,
        17,
        .{ .bash = binding.hash(binding.BashDescriptor, "command") },
    ).attempt_admitted;
    try std.testing.expectEqual(binding.DescriptorKind.bash, std.meta.activeTag(consequential.descriptor_digest));
    try std.testing.expectEqual(@as(u8, 0), consequential.possible_duplicate_attempts);

    const model = transition.modelAttemptAdmitted(
        operation,
        19,
        23,
        .{ .model = binding.hash(binding.ModelDescriptor, "request") },
        1,
    ).attempt_admitted;
    try std.testing.expectEqual(binding.DescriptorKind.model, std.meta.activeTag(model.descriptor_digest));
    try std.testing.expectEqual(@as(u8, 1), model.possible_duplicate_attempts);
}

test "Operation admission requires explicit source identity only for Actions" {
    const operation: transition.OperationContext = .{
        .agent = .{ .agent_id = 7, .agent_generation = 1, .ownership_epoch = 2 },
        .operation_id = 13,
        .generation = 3,
    };
    const model = transition.operationAdmitted(
        operation,
        null,
        17,
        .{ .model = binding.hash(binding.ModelDescriptor, "model") },
    );
    const action = transition.operationAdmitted(
        operation,
        .{ .operation_id = 19, .generation = 2 },
        23,
        .{ .bash = binding.hash(binding.BashDescriptor, "action") },
    );
    var buffer: [transition.max_payload_size]u8 = undefined;
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    transaction.facts[0] = model;
    transaction.facts[1] = action;
    const decoded = try transition.decode(1, try transition.encode(&buffer, transaction));
    try std.testing.expectEqual(model, decoded.facts[0]);
    try std.testing.expectEqual(action, decoded.facts[1]);

    transaction.fact_count = 1;
    transaction.facts[0] = transition.operationAdmitted(
        operation,
        null,
        29,
        .{ .bash = binding.hash(binding.BashDescriptor, "missing source") },
    );
    try std.testing.expectError(
        error.InvalidKindSpecificPayload,
        transition.encode(&buffer, transaction),
    );
    transaction.facts[0] = transition.operationAdmitted(
        operation,
        .{ .operation_id = 31, .generation = 4 },
        37,
        .{ .model = binding.hash(binding.ModelDescriptor, "unexpected source") },
    );
    try std.testing.expectError(
        error.InvalidKindSpecificPayload,
        transition.encode(&buffer, transaction),
    );
}

test "Approval Required and Authorization have distinct canonical payloads" {
    const agent: transition.AgentContext = .{
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
    };
    const operation: transition.OperationContext = .{
        .agent = agent,
        .operation_id = 11,
        .generation = 3,
    };
    const approval = transition.approvalRequired(.{
        .operation = operation,
        .binding_ref = 13,
        .descriptor_ref = 17,
    });
    const authorization = transition.authorization(.{
        .operation = operation,
        .permission_ref = 23,
        .allowed = true,
    });
    var approval_buffer: [transition.max_payload_size]u8 = undefined;
    var authorization_buffer: [transition.max_payload_size]u8 = undefined;
    var approval_transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    approval_transaction.facts[0] = approval;
    var authorization_transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    authorization_transaction.facts[0] = authorization;
    const encoded_approval = try transition.encode(&approval_buffer, approval_transaction);
    const encoded_authorization = try transition.encode(&authorization_buffer, authorization_transaction);
    try std.testing.expect(!std.mem.eql(u8, encoded_approval, encoded_authorization));
    try std.testing.expectEqual(
        approval,
        (try transition.decode(1, encoded_approval)).facts[0],
    );
    try std.testing.expectEqual(
        authorization,
        (try transition.decode(1, encoded_authorization)).facts[0],
    );
}

test "a kind-specific transition carries opaque continuation bytes" {
    const state: [transition.continuation_size]u8 = @splat(0xa5);
    const fact = transition.taskAdmitted(.{
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
    }, 31, 31);
    var buffer: [transition.max_payload_size]u8 = undefined;
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1, .core = state };
    transaction.facts[0] = fact;
    const encoded = try transition.encode(&buffer, transaction);
    const decoded = try transition.decode(1, encoded);
    try std.testing.expectEqual(@as(u64, 1), decoded.sequence);
    try std.testing.expectEqual(fact, decoded.facts[0]);
    try std.testing.expectEqualSlices(u8, &state, &decoded.core.?);
}

test "a malformed flat wire record never becomes a typed fact" {
    const fact = transition.taskAdmitted(.{
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
    }, 31, 31);
    var buffer: [transition.max_payload_size]u8 = undefined;
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    transaction.facts[0] = fact;
    const encoded = try transition.encode(&buffer, transaction);

    // The private flat record stores operation_id 20 bytes into its 104-byte
    // fact body, after the four-byte transaction header.
    buffer[4 + 20] = 1;
    try std.testing.expectError(
        error.InvalidKindSpecificPayload,
        transition.decode(1, encoded),
    );
}

test "superseded transition payload versions are rejected" {
    const fact = transition.taskAdmitted(.{
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
    }, 31, 31);
    var first: [transition.max_payload_size]u8 = undefined;
    var second: [transition.max_payload_size]u8 = undefined;
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    transaction.facts[0] = fact;
    const encoded = try transition.encode(&first, transaction);
    const decoded = try transition.decode(1, encoded);
    try std.testing.expectEqualSlices(u8, encoded, try transition.encode(&second, decoded));
    std.mem.writeInt(u16, first[0..2], transition.payload_version - 1, .little);
    try std.testing.expectError(
        error.UnsupportedTransitionPayloadVersion,
        transition.decode(1, encoded),
    );
}

test "unused flags are rejected for task admission and Outcome" {
    const agent: transition.AgentContext = .{
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
    };
    const facts = [_]transition.Fact{
        transition.taskAdmitted(agent, 31, 37),
        transition.outcome(agent, 41, 43),
    };
    for (facts) |fact| {
        var buffer: [transition.max_payload_size]u8 = undefined;
        var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
        transaction.facts[0] = fact;
        const encoded = try transition.encode(&buffer, transaction);
        buffer[4 + 3] = 1;
        try std.testing.expectError(
            error.InvalidKindSpecificPayload,
            transition.decode(1, encoded),
        );
    }
}

test "Result evidence round trips as immediate or durable typed choices" {
    const operation: transition.OperationContext = .{
        .agent = .{ .agent_id = 7, .agent_generation = 1, .ownership_epoch = 2 },
        .operation_id = 11,
        .generation = 3,
    };
    const facts = [_]transition.Fact{
        transition.result(.{
            .operation = operation,
            .result_ref = 13,
            .result_digest = binding.hash(binding.Result, "result-17"),
            .class = .ordinary,
            .evidence = .{ .immediate = {} },
        }),
        transition.result(.{
            .operation = operation,
            .result_ref = 19,
            .result_digest = binding.hash(binding.Result, "result-23"),
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = 29 } },
        }),
    };
    var buffer: [transition.max_payload_size]u8 = undefined;
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = facts.len };
    @memcpy(transaction.facts[0..facts.len], &facts);
    const decoded = try transition.decode(1, try transition.encode(&buffer, transaction));
    try std.testing.expectEqual(facts[0], decoded.facts[0]);
    try std.testing.expectEqual(facts[1], decoded.facts[1]);
    try std.testing.expect(decoded.facts[0].result.evidence == .immediate);
    try std.testing.expect(decoded.facts[1].result.evidence == .durable);
    try std.testing.expect(decoded.facts[1].result.evidence.durable == .model);
}

test "model Attempt duplicate exposure is bounded and round trips" {
    const operation: transition.OperationContext = .{
        .agent = .{ .agent_id = 7, .agent_generation = 1, .ownership_epoch = 2 },
        .operation_id = 11,
        .generation = 3,
    };
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    transaction.facts[0] = transition.modelAttemptAdmitted(
        operation,
        13,
        17,
        .{ .model = binding.hash(binding.ModelDescriptor, "request") },
        3,
    );
    var buffer: [transition.max_payload_size]u8 = undefined;
    const encoded = try transition.encode(&buffer, transaction);
    const decoded = try transition.decode(1, encoded);
    try std.testing.expectEqual(@as(u8, 3), decoded.facts[0].attempt_admitted.possible_duplicate_attempts);

    buffer[4 + 3] = transition.max_operation_attempts;
    try std.testing.expectError(
        error.InvalidKindSpecificPayload,
        transition.decode(1, encoded),
    );
}

test "an all-zero authoritative binding is not decoded as absence" {
    const zero: binding.Result = .{ .bytes = @splat(0) };
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    transaction.facts[0] = transition.result(.{
        .operation = .{
            .agent = .{ .agent_id = 7, .agent_generation = 1, .ownership_epoch = 2 },
            .operation_id = 11,
            .generation = 3,
        },
        .result_ref = 13,
        .result_digest = zero,
        .class = .ordinary,
        .evidence = .{ .immediate = {} },
    });
    var buffer: [transition.max_payload_size]u8 = undefined;
    const decoded = try transition.decode(1, try transition.encode(&buffer, transaction));

    try std.testing.expect(binding.eql(binding.Result, zero, decoded.facts[0].result.result_digest));
}
