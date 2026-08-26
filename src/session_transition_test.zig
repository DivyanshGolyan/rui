const std = @import("std");
const core_state = @import("core_state.zig");
const transition = @import("session_transition.zig");

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
    const approval = transition.approvalRequired(operation, 13, 17, 19);
    const authorization = transition.authorization(operation, 23, 19, true);
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

test "a kind-specific transition carries canonical Core State without native layout" {
    var state: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&state, .{
        .agent_id = 7,
        .agent_generation = 1,
        .accumulator = 29,
    });
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

    // The private flat record stores operation_id 20 bytes into its 72-byte
    // fact body, after the four-byte transaction header.
    buffer[4 + 20] = 1;
    try std.testing.expectError(
        error.InvalidKindSpecificPayload,
        transition.decode(1, encoded),
    );
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
            .result_digest = 17,
            .class = .ordinary,
            .evidence = .{ .immediate = .consequential },
        }),
        transition.result(.{
            .operation = operation,
            .result_ref = 19,
            .result_digest = 23,
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
    try std.testing.expectEqual(@as(?transition.EvidenceKind, null), decoded.facts[0].evidenceKind());
    try std.testing.expectEqual(transition.EvidenceKind.model, decoded.facts[1].evidenceKind().?);
}
