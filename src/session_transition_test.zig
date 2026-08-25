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
    const encoded_approval = try transition.encode(&approval_buffer, 1, approval, null);
    const encoded_authorization = try transition.encode(
        &authorization_buffer,
        1,
        authorization,
        null,
    );
    try std.testing.expect(!std.mem.eql(u8, encoded_approval, encoded_authorization));
    try std.testing.expectEqual(
        approval,
        (try transition.decode(encoded_approval)).fact,
    );
    try std.testing.expectEqual(
        authorization,
        (try transition.decode(encoded_authorization)).fact,
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
    const encoded = try transition.encode(&buffer, 1, fact, &state);
    const decoded = try transition.decode(encoded);
    try std.testing.expectEqual(@as(u64, 1), decoded.sequence);
    try std.testing.expectEqual(fact, decoded.fact);
    try std.testing.expectEqualSlices(u8, &state, &decoded.core.?);
}
