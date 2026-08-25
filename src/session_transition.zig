const std = @import("std");
const core_state = @import("core_state.zig");

pub const payload_version: u16 = 1;
pub const max_facts: usize = 8;
pub const max_transitions: u32 = 32_768;

const magic = "ONETRAN\x00";
const envelope_size: usize = 56;
const digest_offset: usize = 24;
const common_size: usize = 24;
const maximum_specific_size: usize = 37;
pub const max_payload_size: usize = envelope_size + common_size + maximum_specific_size + core_state.encoded_size;

pub const Kind = enum(u16) {
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

pub const Decoded = struct {
    sequence: u64,
    fact: Fact,
    core: ?[core_state.encoded_size]u8 = null,
};

pub fn encode(
    out: *[max_payload_size]u8,
    sequence: u64,
    fact: Fact,
    encoded_core: ?[]const u8,
) ![]const u8 {
    if (sequence == 0) return error.InvalidTransitionSequence;
    try validateFact(fact);
    const specific_size = kindSpecificSize(fact.kind);
    const core_length: usize = if (encoded_core != null) core_state.encoded_size else 0;
    const body_length = common_size + specific_size + core_length;
    const encoded_length = envelope_size + body_length;
    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, payload_version);
    write(u16, out, 10, @intFromEnum(fact.kind));
    write(u32, out, 12, @intCast(encoded_length));
    write(u64, out, 16, sequence);
    const body = out[envelope_size..];
    write(u64, body, 0, fact.agent_id);
    write(u64, body, 8, fact.ownership_epoch);
    write(u32, body, 16, fact.agent_generation);
    body[20] = fact.flags;
    body[21] = @intFromEnum(fact.recovery_class);
    body[22] = @intFromEnum(fact.disposition);
    body[23] = if (encoded_core != null) 1 else 0;
    encodeSpecific(body[common_size..], fact);
    if (encoded_core) |bytes| {
        if (bytes.len != core_state.encoded_size) return error.InvalidCoreStateLength;
        _ = try core_state.decode(bytes);
        @memcpy(body[common_size + specific_size ..][0..core_state.encoded_size], bytes);
    }
    var canonical_digest: [32]u8 = undefined;
    hashCanonical(out[0..encoded_length], &canonical_digest);
    @memcpy(out[digest_offset..][0..canonical_digest.len], &canonical_digest);
    return out[0..encoded_length];
}

pub fn decode(payload: []const u8) !Decoded {
    if (payload.len < envelope_size or !std.mem.eql(u8, payload[0..magic.len], magic)) {
        return error.InvalidTransitionEnvelope;
    }
    if (read(u16, payload, 8) != payload_version) return error.UnsupportedTransitionPayloadVersion;
    const kind = std.enums.fromInt(Kind, read(u16, payload, 10)) orelse
        return error.UnsupportedTransitionKind;
    if (read(u32, payload, 12) != payload.len) return error.InvalidTransitionPayloadLength;
    const sequence = read(u64, payload, 16);
    if (sequence == 0) return error.InvalidTransitionSequence;
    var actual_digest: [32]u8 = undefined;
    hashCanonical(payload, &actual_digest);
    if (!std.mem.eql(u8, &actual_digest, payload[digest_offset..][0..32])) {
        return error.PayloadDigestMismatch;
    }
    const specific_size = kindSpecificSize(kind);
    const base_length = common_size + specific_size;
    const body = payload[envelope_size..];
    if (body.len != base_length and body.len != base_length + core_state.encoded_size) {
        return error.InvalidTransitionPayloadLength;
    }
    const core_present = switch (body[23]) {
        0 => false,
        1 => true,
        else => return error.InvalidCorePresence,
    };
    if (core_present != (body.len != base_length)) return error.InvalidCorePresence;
    var fact: Fact = .{
        .kind = kind,
        .agent_id = read(u64, body, 0),
        .ownership_epoch = read(u64, body, 8),
        .agent_generation = read(u32, body, 16),
        .flags = body[20],
        .recovery_class = std.enums.fromInt(RecoveryClass, body[21]) orelse
            return error.InvalidRecoveryClass,
        .disposition = std.enums.fromInt(Disposition, body[22]) orelse
            return error.InvalidDisposition,
    };
    decodeSpecific(body[common_size..base_length], &fact);
    try validateFact(fact);
    var decoded: Decoded = .{ .sequence = sequence, .fact = fact };
    if (core_present) {
        var state: [core_state.encoded_size]u8 = undefined;
        @memcpy(&state, body[base_length..]);
        _ = try core_state.decode(&state);
        decoded.core = state;
    }
    return decoded;
}

pub fn digest(payload: []const u8) ![32]u8 {
    _ = try decode(payload);
    var result: [32]u8 = undefined;
    @memcpy(&result, payload[digest_offset..][0..32]);
    return result;
}

fn hashCanonical(payload: []const u8, out: *[32]u8) void {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    hash.update(payload[0..digest_offset]);
    hash.update(payload[digest_offset + 32 ..]);
    hash.final(out);
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

fn kindSpecificSize(kind: Kind) usize {
    return switch (kind) {
        .cancellation, .shutdown => 0,
        .task_admitted, .conversation_advanced, .outcome => 16,
        .operation_submitted, .operation_accepted, .authorization => 28,
        .attempt_admitted, .result_applied, .approval_required => 36,
        .result => 37,
    };
}

fn encodeSpecific(out: []u8, fact: Fact) void {
    switch (fact.kind) {
        .cancellation, .shutdown => {},
        .task_admitted, .conversation_advanced, .outcome => {
            write(u64, out, 0, fact.subject);
            write(u64, out, 8, fact.reference);
        },
        .operation_submitted, .operation_accepted, .authorization => {
            write(u64, out, 0, fact.operation_id);
            write(u32, out, 8, fact.generation);
            write(u64, out, 12, fact.reference);
            write(u64, out, 20, fact.digest);
        },
        .attempt_admitted, .result_applied => {
            write(u64, out, 0, fact.operation_id);
            write(u32, out, 8, fact.generation);
            write(u64, out, 12, fact.attempt_id);
            write(u64, out, 20, fact.reference);
            write(u64, out, 28, fact.digest);
        },
        .result => {
            write(u64, out, 0, fact.operation_id);
            write(u32, out, 8, fact.generation);
            write(u64, out, 12, fact.attempt_id);
            write(u64, out, 20, fact.reference);
            write(u64, out, 28, fact.digest);
            out[36] = fact.evidence_kind;
        },
        .approval_required => {
            write(u64, out, 0, fact.operation_id);
            write(u32, out, 8, fact.generation);
            write(u64, out, 12, fact.subject);
            write(u64, out, 20, fact.reference);
            write(u64, out, 28, fact.digest);
        },
    }
}

fn decodeSpecific(input: []const u8, fact: *Fact) void {
    switch (fact.kind) {
        .cancellation, .shutdown => {},
        .task_admitted, .conversation_advanced, .outcome => {
            fact.subject = read(u64, input, 0);
            fact.reference = read(u64, input, 8);
        },
        .operation_submitted, .operation_accepted, .authorization => {
            fact.operation_id = read(u64, input, 0);
            fact.generation = read(u32, input, 8);
            fact.reference = read(u64, input, 12);
            fact.digest = read(u64, input, 20);
        },
        .attempt_admitted, .result_applied => {
            fact.operation_id = read(u64, input, 0);
            fact.generation = read(u32, input, 8);
            fact.attempt_id = read(u64, input, 12);
            fact.reference = read(u64, input, 20);
            fact.digest = read(u64, input, 28);
        },
        .result => {
            fact.operation_id = read(u64, input, 0);
            fact.generation = read(u32, input, 8);
            fact.attempt_id = read(u64, input, 12);
            fact.reference = read(u64, input, 20);
            fact.digest = read(u64, input, 28);
            fact.evidence_kind = input[36];
        },
        .approval_required => {
            fact.operation_id = read(u64, input, 0);
            fact.generation = read(u32, input, 8);
            fact.subject = read(u64, input, 12);
            fact.reference = read(u64, input, 20);
            fact.digest = read(u64, input, 28);
        },
    }
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}
