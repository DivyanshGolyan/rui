const std = @import("std");
const binding = @import("binding.zig");
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
    const approval = transition.approvalRequired(.{
        .operation = operation,
        .binding_ref = 13,
        .descriptor_ref = 17,
        .descriptor_digest = .{ .bash = binding.hash(binding.BashDescriptor, "descriptor-19") },
    });
    const authorization = transition.authorization(.{
        .operation = operation,
        .permission_ref = 23,
        .descriptor_digest = .{ .bash = binding.hash(binding.BashDescriptor, "descriptor-19") },
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

    // The private flat record stores operation_id 20 bytes into its 104-byte
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
            .result_digest = binding.hash(binding.Result, "result-17"),
            .class = .ordinary,
            .evidence = .{ .immediate = .consequential },
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
        .evidence = .{ .immediate = .consequential },
    });
    var buffer: [transition.max_payload_size]u8 = undefined;
    const decoded = try transition.decode(1, try transition.encode(&buffer, transaction));

    try std.testing.expect(binding.eql(binding.Result, zero, decoded.facts[0].result.result_digest));
}
