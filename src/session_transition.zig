const std = @import("std");
const core_state = @import("core_state.zig");

pub const payload_version: u16 = 1;
pub const max_facts: usize = 8;
pub const max_transitions: u32 = 32_768;

const header_size: usize = 4;
const fact_size: usize = 72;
pub const max_payload_size: usize = header_size + max_facts * fact_size + core_state.encoded_size;

pub const Kind = enum(u8) {
    task_admitted = 1,
    operation_submitted = 2,
    operation_accepted = 3,
    attempt_admitted = 4,
    authorization = 5,
    result = 6,
    conversation_advanced = 7,
    outcome = 8,
    cancellation = 9,
    shutdown = 10,
    result_applied = 11,
    approval_required = 12,
};

pub const RecoveryClass = enum(u8) {
    none = 0,
    model = 1,
    consequential = 2,
};

pub const Disposition = enum(u8) {
    none = 0,
    definitely_unsent = 1,
    possibly_executed = 2,
    terminal = 3,
};

pub const Fact = struct {
    kind: Kind,
    recovery_class: RecoveryClass = .none,
    disposition: Disposition = .none,
    flags: u8 = 0,
    agent_id: u64 = 0,
    operation_id: u64 = 0,
    attempt_id: u64 = 0,
    subject: u64 = 0,
    reference: u64 = 0,
    digest: u64 = 0,
    ownership_epoch: u64 = 0,
    generation: u32 = 0,
    agent_generation: u32 = 0,
    evidence_kind: u8 = 0,
};

pub const Transaction = struct {
    sequence: u64,
    facts: [max_facts]Fact = undefined,
    fact_count: u8,
    core: ?[core_state.encoded_size]u8 = null,

    pub fn factSlice(self: *const Transaction) []const Fact {
        return self.facts[0..self.fact_count];
    }
};

pub fn encode(
    out: *[max_payload_size]u8,
    transaction: Transaction,
) ![]const u8 {
    if (transaction.sequence == 0 or transaction.fact_count == 0 or
        transaction.fact_count > max_facts)
    {
        return error.InvalidTransaction;
    }
    const core_length: usize = if (transaction.core != null) core_state.encoded_size else 0;
    const encoded_length = header_size + transaction.fact_count * fact_size + core_length;
    @memset(out, 0);
    write(u16, out, 0, payload_version);
    out[2] = transaction.fact_count;
    out[3] = @intFromBool(transaction.core != null);
    var cursor: usize = header_size;
    for (transaction.factSlice()) |fact| {
        try encodeFact(out[cursor..][0..fact_size], fact);
        cursor += fact_size;
    }
    if (transaction.core) |state| {
        _ = try core_state.decode(&state);
        @memcpy(out[cursor..][0..core_state.encoded_size], &state);
    }
    return out[0..encoded_length];
}

pub fn decode(sequence: u64, payload: []const u8) !Transaction {
    if (sequence == 0) return error.InvalidTransitionSequence;
    if (payload.len < header_size) return error.InvalidTransitionPayloadLength;
    if (read(u16, payload, 0) != payload_version) return error.UnsupportedTransitionPayloadVersion;
    const fact_count = payload[2];
    if (fact_count == 0 or fact_count > max_facts) return error.InvalidTransitionCount;
    const core_present = switch (payload[3]) {
        0 => false,
        1 => true,
        else => return error.InvalidCorePresence,
    };
    const expected_length = header_size + @as(usize, fact_count) * fact_size +
        (if (core_present) core_state.encoded_size else 0);
    if (payload.len != expected_length) return error.InvalidTransitionPayloadLength;
    var transaction: Transaction = .{
        .sequence = sequence,
        .fact_count = fact_count,
    };
    var cursor: usize = header_size;
    for (0..fact_count) |index| {
        transaction.facts[index] = try decodeFact(payload[cursor..][0..fact_size]);
        cursor += fact_size;
    }
    if (core_present) {
        var state: [core_state.encoded_size]u8 = undefined;
        @memcpy(&state, payload[cursor..][0..core_state.encoded_size]);
        _ = try core_state.decode(&state);
        transaction.core = state;
    }
    return transaction;
}

fn validateFact(fact: Fact) !void {
    if (fact.agent_id == 0 or fact.agent_generation == 0 or fact.ownership_epoch == 0) {
        return error.InvalidTransitionIdentity;
    }
    const operation_kind = switch (fact.kind) {
        .operation_submitted,
        .operation_accepted,
        .attempt_admitted,
        .authorization,
        .result,
        .result_applied,
        .approval_required,
        => true,
        else => false,
    };
    if (operation_kind != (fact.operation_id != 0 and fact.generation != 0)) {
        return error.InvalidOperationIdentity;
    }
    switch (fact.kind) {
        .task_admitted, .conversation_advanced, .outcome => {
            if (fact.subject == 0 or fact.reference == 0 or fact.operation_id != 0 or
                fact.attempt_id != 0 or fact.digest != 0 or fact.flags != 0 or
                fact.recovery_class != .none or fact.disposition != .none or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .cancellation, .shutdown => {
            if (fact.operation_id != 0 or fact.attempt_id != 0 or fact.subject != 0 or
                fact.reference != 0 or fact.digest != 0 or fact.flags != 0 or
                fact.recovery_class != .none or fact.disposition != .none or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .operation_submitted, .operation_accepted => {
            if (fact.attempt_id != 0 or fact.subject != 0 or fact.reference == 0 or
                fact.digest == 0 or fact.flags != 0 or fact.disposition != .none or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .attempt_admitted => {
            if (fact.attempt_id == 0 or fact.subject != 0 or fact.digest == 0 or fact.flags != 0 or
                fact.recovery_class == .none or fact.disposition != .possibly_executed or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .approval_required => {
            if (fact.reference == 0 or fact.digest == 0 or fact.flags != 0 or
                fact.attempt_id != 0 or fact.recovery_class != .none or fact.disposition != .none or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .authorization => {
            if (fact.digest == 0 or (fact.flags != 1 and fact.flags != 2) or
                fact.attempt_id != 0 or fact.subject != 0 or fact.recovery_class != .none or
                fact.disposition != .none or fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .result => {
            if (fact.reference == 0 or fact.digest == 0 or fact.subject != 0 or
                fact.recovery_class == .none or fact.disposition != .terminal or
                (fact.attempt_id == 0) != (fact.evidence_kind == 0) or fact.evidence_kind > 3)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .result_applied => {
            if (fact.reference == 0 or fact.subject != 0 or fact.flags != 0 or
                fact.disposition != .none or fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
    }
}

fn encodeFact(out: []u8, fact: Fact) !void {
    try validateFact(fact);
    @memset(out, 0);
    out[0] = @intFromEnum(fact.kind);
    out[1] = @intFromEnum(fact.recovery_class);
    out[2] = @intFromEnum(fact.disposition);
    out[3] = fact.flags;
    write(u32, out, 4, fact.generation);
    write(u32, out, 8, fact.agent_generation);
    write(u64, out, 12, fact.agent_id);
    write(u64, out, 20, fact.operation_id);
    write(u64, out, 28, fact.attempt_id);
    write(u64, out, 36, fact.subject);
    write(u64, out, 44, fact.reference);
    write(u64, out, 52, fact.digest);
    write(u64, out, 60, fact.ownership_epoch);
    out[68] = fact.evidence_kind;
}

fn decodeFact(input: []const u8) !Fact {
    if (input[69] != 0 or input[70] != 0 or input[71] != 0) {
        return error.NonzeroReservedByte;
    }
    const fact: Fact = .{
        .kind = std.enums.fromInt(Kind, input[0]) orelse return error.UnsupportedTransitionKind,
        .recovery_class = std.enums.fromInt(RecoveryClass, input[1]) orelse
            return error.InvalidRecoveryClass,
        .disposition = std.enums.fromInt(Disposition, input[2]) orelse
            return error.InvalidDisposition,
        .flags = input[3],
        .generation = read(u32, input, 4),
        .agent_generation = read(u32, input, 8),
        .agent_id = read(u64, input, 12),
        .operation_id = read(u64, input, 20),
        .attempt_id = read(u64, input, 28),
        .subject = read(u64, input, 36),
        .reference = read(u64, input, 44),
        .digest = read(u64, input, 52),
        .ownership_epoch = read(u64, input, 60),
        .evidence_kind = input[68],
    };
    try validateFact(fact);
    return fact;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}
