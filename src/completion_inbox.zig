const std = @import("std");

pub const max_records: u32 = 4096;

pub const EvidenceKind = enum(u8) {
    model = 1,
    bash = 2,
    apply_patch = 3,
};

pub const Envelope = struct {
    kind: EvidenceKind,
    session_id: u64,
    ownership_epoch: u64,
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    result_ref: u64,
    result_digest: u64,
};

pub fn validate(envelope: Envelope) !void {
    if (envelope.session_id == 0 or envelope.ownership_epoch == 0 or
        envelope.agent_id == 0 or envelope.agent_generation == 0 or
        envelope.operation_id == 0 or envelope.operation_generation == 0 or
        envelope.attempt_id == 0 or envelope.result_ref == 0 or
        envelope.result_digest == 0)
    {
        return error.InvalidCompletionIdentity;
    }
}

test "Completion identity requires every generation and evidence value" {
    const valid: Envelope = .{
        .kind = .model,
        .session_id = 3,
        .ownership_epoch = 5,
        .agent_id = 7,
        .agent_generation = 1,
        .operation_id = 11,
        .operation_generation = 2,
        .attempt_id = 13,
        .result_ref = 17,
        .result_digest = 19,
    };
    try validate(valid);
    var invalid = valid;
    invalid.attempt_id = 0;
    try std.testing.expectError(error.InvalidCompletionIdentity, validate(invalid));
}
