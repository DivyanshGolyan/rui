const std = @import("std");
const binding = @import("binding.zig");

pub const max_records: u32 = 4096;

pub const EvidenceKind = binding.DescriptorKind;

pub const UnboundEnvelope = struct {
    kind: EvidenceKind,
    session_id: u64,
    ownership_epoch: u64,
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    result_ref: u64,
    result_digest: binding.Result,
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
    result_digest: binding.Result,
    completion_digest: binding.Completion,
};

pub fn bind(fields: UnboundEnvelope) Envelope {
    var canonical: [89]u8 = undefined;
    canonical[0] = @intFromEnum(fields.kind);
    write(u64, &canonical, 1, fields.session_id);
    write(u64, &canonical, 9, fields.ownership_epoch);
    write(u64, &canonical, 17, fields.agent_id);
    write(u32, &canonical, 25, fields.agent_generation);
    write(u64, &canonical, 29, fields.operation_id);
    write(u32, &canonical, 37, fields.operation_generation);
    write(u64, &canonical, 41, fields.attempt_id);
    write(u64, &canonical, 49, fields.result_ref);
    @memcpy(canonical[57..89], &fields.result_digest.bytes);
    return .{
        .kind = fields.kind,
        .session_id = fields.session_id,
        .ownership_epoch = fields.ownership_epoch,
        .agent_id = fields.agent_id,
        .agent_generation = fields.agent_generation,
        .operation_id = fields.operation_id,
        .operation_generation = fields.operation_generation,
        .attempt_id = fields.attempt_id,
        .result_ref = fields.result_ref,
        .result_digest = fields.result_digest,
        .completion_digest = binding.hash(binding.Completion, &canonical),
    };
}

fn rebound(envelope: Envelope) Envelope {
    return bind(.{
        .kind = envelope.kind,
        .session_id = envelope.session_id,
        .ownership_epoch = envelope.ownership_epoch,
        .agent_id = envelope.agent_id,
        .agent_generation = envelope.agent_generation,
        .operation_id = envelope.operation_id,
        .operation_generation = envelope.operation_generation,
        .attempt_id = envelope.attempt_id,
        .result_ref = envelope.result_ref,
        .result_digest = envelope.result_digest,
    });
}

pub fn validate(envelope: Envelope) !void {
    if (envelope.session_id == 0 or envelope.ownership_epoch == 0 or
        envelope.agent_id == 0 or envelope.agent_generation == 0 or
        envelope.operation_id == 0 or envelope.operation_generation == 0 or
        envelope.attempt_id == 0 or envelope.result_ref == 0)
    {
        return error.InvalidCompletionIdentity;
    }
    if (!binding.eql(
        binding.Completion,
        rebound(envelope).completion_digest,
        envelope.completion_digest,
    )) {
        return error.InvalidCompletionBinding;
    }
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

test "Completion identity requires every generation and evidence value" {
    const valid = bind(.{
        .kind = .model,
        .session_id = 3,
        .ownership_epoch = 5,
        .agent_id = 7,
        .agent_generation = 1,
        .operation_id = 11,
        .operation_generation = 2,
        .attempt_id = 13,
        .result_ref = 17,
        .result_digest = binding.hash(binding.Result, "result-19"),
    });
    try validate(valid);
    var invalid = valid;
    invalid.attempt_id = 0;
    try std.testing.expectError(error.InvalidCompletionIdentity, validate(invalid));
    var mismatched = valid;
    mismatched.completion_digest = binding.hash(binding.Completion, "different-envelope");
    try std.testing.expectError(error.InvalidCompletionBinding, validate(mismatched));
}
