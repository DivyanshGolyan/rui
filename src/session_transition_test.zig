const std = @import("std");
const core_state = @import("core_state.zig");
const transition = @import("session_transition.zig");

test "Approval Required and Authorization have distinct canonical payloads" {
    const approval: transition.Fact = .{
        .kind = .approval_required,
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
        .operation_id = 11,
        .generation = 3,
        .subject = 13,
        .reference = 17,
        .digest = 19,
    };
    const authorization: transition.Fact = .{
        .kind = .authorization,
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
        .operation_id = 11,
        .generation = 3,
        .reference = 23,
        .digest = 19,
        .flags = 1,
    };
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
    const fact: transition.Fact = .{
        .kind = .task_admitted,
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 2,
        .subject = 31,
        .reference = 31,
    };
    var buffer: [transition.max_payload_size]u8 = undefined;
    var transaction: transition.Transaction = .{ .sequence = 1, .fact_count = 1, .core = state };
    transaction.facts[0] = fact;
    const encoded = try transition.encode(&buffer, transaction);
    const decoded = try transition.decode(1, encoded);
    try std.testing.expectEqual(@as(u64, 1), decoded.sequence);
    try std.testing.expectEqual(fact, decoded.facts[0]);
    try std.testing.expectEqualSlices(u8, &state, &decoded.core.?);
}
