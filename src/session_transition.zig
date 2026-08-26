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

pub const EvidenceKind = enum(u8) {
    model = 1,
    bash = 2,
    apply_patch = 3,
};

pub const ResultClass = enum(u8) {
    ordinary = 0,
    indeterminate = 1,
};

pub const DurableResultEvidence = union(EvidenceKind) {
    model: u64,
    bash: u64,
    apply_patch: u64,
};

pub const ResultEvidence = union(enum) {
    immediate: RecoveryClass,
    durable: DurableResultEvidence,
};

pub const AgentContext = struct {
    agent_id: u64 = 0,
    agent_generation: u32 = 0,
    ownership_epoch: u64 = 0,
};

pub const OperationContext = struct {
    agent: AgentContext,
    operation_id: u64 = 0,
    generation: u32 = 0,
};

pub const OperationRecord = struct {
    operation: OperationContext,
    descriptor_ref: u64,
    descriptor_digest: u64,
    recovery_class: RecoveryClass,
};

pub const ResultRecord = struct {
    operation: OperationContext,
    result_ref: u64,
    result_digest: u64,
    class: ResultClass,
    evidence: ResultEvidence,
};

pub const Fact = union(Kind) {
    task_admitted: struct { agent: AgentContext, task_id: u64, content_ref: u64 },
    operation_submitted: OperationRecord,
    operation_accepted: OperationRecord,
    attempt_admitted: struct {
        operation: OperationContext,
        attempt_id: u64,
        descriptor_ref: u64,
        descriptor_digest: u64,
        recovery_class: RecoveryClass,
    },
    authorization: struct {
        operation: OperationContext,
        permission_ref: u64,
        descriptor_digest: u64,
        allowed: bool,
    },
    result: ResultRecord,
    conversation_advanced: struct { agent: AgentContext, entry_id: u64, content_ref: u64 },
    outcome: struct { agent: AgentContext, outcome_id: u64, content_ref: u64 },
    cancellation: AgentContext,
    shutdown: AgentContext,
    result_applied: struct {
        operation: OperationContext,
        attempt_id: u64,
        result_ref: u64,
        result_digest: u64,
        recovery_class: RecoveryClass,
    },
    approval_required: struct {
        operation: OperationContext,
        binding_ref: u64,
        descriptor_ref: u64,
        descriptor_digest: u64,
    },

    pub fn kind(self: Fact) Kind {
        return std.meta.activeTag(self);
    }

    pub fn agent(self: Fact) AgentContext {
        return switch (self) {
            .task_admitted => |value| value.agent,
            .operation_submitted, .operation_accepted => |value| value.operation.agent,
            .attempt_admitted => |value| value.operation.agent,
            .authorization => |value| value.operation.agent,
            .result => |value| value.operation.agent,
            .conversation_advanced => |value| value.agent,
            .outcome => |value| value.agent,
            .cancellation, .shutdown => |value| value,
            .result_applied => |value| value.operation.agent,
            .approval_required => |value| value.operation.agent,
        };
    }

    pub fn operation(self: Fact) ?OperationContext {
        return switch (self) {
            .operation_submitted, .operation_accepted => |value| value.operation,
            .attempt_admitted => |value| value.operation,
            .authorization => |value| value.operation,
            .result => |value| value.operation,
            .result_applied => |value| value.operation,
            .approval_required => |value| value.operation,
            else => null,
        };
    }

    pub fn agentId(self: Fact) u64 {
        return self.agent().agent_id;
    }

    pub fn agentGeneration(self: Fact) u32 {
        return self.agent().agent_generation;
    }

    pub fn ownershipEpoch(self: Fact) u64 {
        return self.agent().ownership_epoch;
    }

    pub fn operationId(self: Fact) u64 {
        return if (self.operation()) |value| value.operation_id else 0;
    }

    pub fn generation(self: Fact) u32 {
        return if (self.operation()) |value| value.generation else 0;
    }

    pub fn recoveryClass(self: Fact) RecoveryClass {
        return switch (self) {
            .operation_submitted, .operation_accepted => |value| value.recovery_class,
            .attempt_admitted => |value| value.recovery_class,
            .result => |value| switch (value.evidence) {
                .immediate => |recovery_class| recovery_class,
                .durable => |evidence| switch (evidence) {
                    .model => .model,
                    .bash, .apply_patch => .consequential,
                },
            },
            .result_applied => |value| value.recovery_class,
            else => .none,
        };
    }

    pub fn disposition(self: Fact) Disposition {
        return switch (self) {
            .attempt_admitted => .possibly_executed,
            .result => .terminal,
            else => .none,
        };
    }

    pub fn attemptId(self: Fact) u64 {
        return switch (self) {
            .attempt_admitted => |value| value.attempt_id,
            .result => |value| switch (value.evidence) {
                .immediate => 0,
                .durable => |evidence| switch (evidence) {
                    inline else => |attempt_id| attempt_id,
                },
            },
            .result_applied => |value| value.attempt_id,
            else => 0,
        };
    }

    pub fn subject(self: Fact) u64 {
        return switch (self) {
            .task_admitted => |value| value.task_id,
            .conversation_advanced => |value| value.entry_id,
            .outcome => |value| value.outcome_id,
            .approval_required => |value| value.binding_ref,
            else => 0,
        };
    }

    pub fn reference(self: Fact) u64 {
        return switch (self) {
            .task_admitted => |value| value.content_ref,
            .operation_submitted, .operation_accepted => |value| value.descriptor_ref,
            .attempt_admitted => |value| value.descriptor_ref,
            .authorization => |value| value.permission_ref,
            .result => |value| value.result_ref,
            .conversation_advanced => |value| value.content_ref,
            .outcome => |value| value.content_ref,
            .result_applied => |value| value.result_ref,
            .approval_required => |value| value.descriptor_ref,
            else => 0,
        };
    }

    pub fn digest(self: Fact) u64 {
        return switch (self) {
            .operation_submitted, .operation_accepted => |value| value.descriptor_digest,
            .attempt_admitted => |value| value.descriptor_digest,
            .authorization => |value| value.descriptor_digest,
            .result => |value| value.result_digest,
            .result_applied => |value| value.result_digest,
            .approval_required => |value| value.descriptor_digest,
            else => 0,
        };
    }

    pub fn flags(self: Fact) u8 {
        return switch (self) {
            .authorization => |value| if (value.allowed) 1 else 2,
            .result => |value| @intFromEnum(value.class),
            else => 0,
        };
    }

    pub fn evidenceKind(self: Fact) ?EvidenceKind {
        return switch (self) {
            .result => |value| switch (value.evidence) {
                .immediate => null,
                .durable => |evidence| std.meta.activeTag(evidence),
            },
            else => null,
        };
    }

    pub fn isIndeterminate(self: Fact) bool {
        return switch (self) {
            .result => |value| value.class == .indeterminate,
            else => false,
        };
    }
};

const RawFact = struct {
    kind: Kind,
    recovery_class: RecoveryClass,
    disposition: Disposition,
    flags: u8,
    agent_id: u64,
    operation_id: u64,
    attempt_id: u64,
    subject: u64,
    reference: u64,
    digest: u64,
    ownership_epoch: u64,
    generation: u32,
    agent_generation: u32,
    evidence_kind: u8,
};

pub fn taskAdmitted(agent: AgentContext, task_id: u64, content_ref: u64) Fact {
    return .{ .task_admitted = .{ .agent = agent, .task_id = task_id, .content_ref = content_ref } };
}

pub fn operationSubmitted(
    operation: OperationContext,
    descriptor_ref: u64,
    descriptor_digest: u64,
    recovery_class: RecoveryClass,
) Fact {
    return .{ .operation_submitted = .{
        .operation = operation,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
        .recovery_class = recovery_class,
    } };
}

pub fn operationAccepted(
    operation: OperationContext,
    descriptor_ref: u64,
    descriptor_digest: u64,
    recovery_class: RecoveryClass,
) Fact {
    return .{ .operation_accepted = .{
        .operation = operation,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
        .recovery_class = recovery_class,
    } };
}

pub fn attemptAdmitted(
    operation: OperationContext,
    attempt_id: u64,
    descriptor_ref: u64,
    descriptor_digest: u64,
    recovery_class: RecoveryClass,
) Fact {
    return .{ .attempt_admitted = .{
        .operation = operation,
        .attempt_id = attempt_id,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
        .recovery_class = recovery_class,
    } };
}

pub fn authorization(
    operation: OperationContext,
    permission_ref: u64,
    descriptor_digest: u64,
    allowed: bool,
) Fact {
    return .{ .authorization = .{
        .operation = operation,
        .permission_ref = permission_ref,
        .descriptor_digest = descriptor_digest,
        .allowed = allowed,
    } };
}

pub fn result(record: ResultRecord) Fact {
    return .{ .result = record };
}

pub fn conversationAdvanced(agent: AgentContext, entry_id: u64, content_ref: u64) Fact {
    return .{ .conversation_advanced = .{
        .agent = agent,
        .entry_id = entry_id,
        .content_ref = content_ref,
    } };
}

pub fn outcome(agent: AgentContext, outcome_id: u64, content_ref: u64) Fact {
    return .{ .outcome = .{ .agent = agent, .outcome_id = outcome_id, .content_ref = content_ref } };
}

pub fn cancellation(agent: AgentContext) Fact {
    return .{ .cancellation = agent };
}

pub fn shutdown(agent: AgentContext) Fact {
    return .{ .shutdown = agent };
}

pub fn resultApplied(
    operation: OperationContext,
    attempt_id: u64,
    result_ref: u64,
    result_digest: u64,
    recovery_class: RecoveryClass,
) Fact {
    return .{ .result_applied = .{
        .operation = operation,
        .attempt_id = attempt_id,
        .result_ref = result_ref,
        .result_digest = result_digest,
        .recovery_class = recovery_class,
    } };
}

pub fn approvalRequired(
    operation: OperationContext,
    binding_ref: u64,
    descriptor_ref: u64,
    descriptor_digest: u64,
) Fact {
    return .{ .approval_required = .{
        .operation = operation,
        .binding_ref = binding_ref,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
    } };
}

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

fn validateRawFact(fact: RawFact) !void {
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
                fact.flags > @intFromEnum(ResultClass.indeterminate) or
                (fact.attempt_id == 0) != (fact.evidence_kind == 0) or
                fact.evidence_kind > @intFromEnum(EvidenceKind.apply_patch) or
                (fact.attempt_id != 0 and
                    ((fact.evidence_kind == @intFromEnum(EvidenceKind.model) and
                        fact.recovery_class != .model) or
                        (fact.evidence_kind != @intFromEnum(EvidenceKind.model) and
                            fact.recovery_class != .consequential))))
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
    const raw = rawFact(fact);
    try validateRawFact(raw);
    @memset(out, 0);
    out[0] = @intFromEnum(raw.kind);
    out[1] = @intFromEnum(raw.recovery_class);
    out[2] = @intFromEnum(raw.disposition);
    out[3] = raw.flags;
    write(u32, out, 4, raw.generation);
    write(u32, out, 8, raw.agent_generation);
    write(u64, out, 12, raw.agent_id);
    write(u64, out, 20, raw.operation_id);
    write(u64, out, 28, raw.attempt_id);
    write(u64, out, 36, raw.subject);
    write(u64, out, 44, raw.reference);
    write(u64, out, 52, raw.digest);
    write(u64, out, 60, raw.ownership_epoch);
    out[68] = raw.evidence_kind;
}

fn decodeFact(input: []const u8) !Fact {
    if (input[69] != 0 or input[70] != 0 or input[71] != 0) {
        return error.NonzeroReservedByte;
    }
    const raw: RawFact = .{
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
    try validateRawFact(raw);
    return factFromRaw(raw);
}

fn rawFact(fact: Fact) RawFact {
    const agent = fact.agent();
    const operation = fact.operation();
    return .{
        .kind = fact.kind(),
        .recovery_class = fact.recoveryClass(),
        .disposition = fact.disposition(),
        .flags = fact.flags(),
        .agent_id = agent.agent_id,
        .operation_id = if (operation) |value| value.operation_id else 0,
        .attempt_id = fact.attemptId(),
        .subject = fact.subject(),
        .reference = fact.reference(),
        .digest = fact.digest(),
        .ownership_epoch = agent.ownership_epoch,
        .generation = if (operation) |value| value.generation else 0,
        .agent_generation = agent.agent_generation,
        .evidence_kind = if (fact.evidenceKind()) |kind| @intFromEnum(kind) else 0,
    };
}

fn factFromRaw(raw: RawFact) Fact {
    const agent: AgentContext = .{
        .agent_id = raw.agent_id,
        .agent_generation = raw.agent_generation,
        .ownership_epoch = raw.ownership_epoch,
    };
    const operation: OperationContext = .{
        .agent = agent,
        .operation_id = raw.operation_id,
        .generation = raw.generation,
    };
    return switch (raw.kind) {
        .task_admitted => .{ .task_admitted = .{
            .agent = agent,
            .task_id = raw.subject,
            .content_ref = raw.reference,
        } },
        .operation_submitted => .{ .operation_submitted = .{
            .operation = operation,
            .descriptor_ref = raw.reference,
            .descriptor_digest = raw.digest,
            .recovery_class = raw.recovery_class,
        } },
        .operation_accepted => .{ .operation_accepted = .{
            .operation = operation,
            .descriptor_ref = raw.reference,
            .descriptor_digest = raw.digest,
            .recovery_class = raw.recovery_class,
        } },
        .attempt_admitted => .{ .attempt_admitted = .{
            .operation = operation,
            .attempt_id = raw.attempt_id,
            .descriptor_ref = raw.reference,
            .descriptor_digest = raw.digest,
            .recovery_class = raw.recovery_class,
        } },
        .authorization => .{ .authorization = .{
            .operation = operation,
            .permission_ref = raw.reference,
            .descriptor_digest = raw.digest,
            .allowed = raw.flags == 1,
        } },
        .result => .{ .result = .{
            .operation = operation,
            .result_ref = raw.reference,
            .result_digest = raw.digest,
            .class = std.enums.fromInt(ResultClass, raw.flags) orelse unreachable,
            .evidence = if (raw.attempt_id == 0)
                .{ .immediate = raw.recovery_class }
            else
                .{ .durable = switch (std.enums.fromInt(EvidenceKind, raw.evidence_kind) orelse unreachable) {
                    .model => .{ .model = raw.attempt_id },
                    .bash => .{ .bash = raw.attempt_id },
                    .apply_patch => .{ .apply_patch = raw.attempt_id },
                } },
        } },
        .conversation_advanced => .{ .conversation_advanced = .{
            .agent = agent,
            .entry_id = raw.subject,
            .content_ref = raw.reference,
        } },
        .outcome => .{ .outcome = .{
            .agent = agent,
            .outcome_id = raw.subject,
            .content_ref = raw.reference,
        } },
        .cancellation => .{ .cancellation = agent },
        .shutdown => .{ .shutdown = agent },
        .result_applied => .{ .result_applied = .{
            .operation = operation,
            .attempt_id = raw.attempt_id,
            .result_ref = raw.reference,
            .result_digest = raw.digest,
            .recovery_class = raw.recovery_class,
        } },
        .approval_required => .{ .approval_required = .{
            .operation = operation,
            .binding_ref = raw.subject,
            .descriptor_ref = raw.reference,
            .descriptor_digest = raw.digest,
        } },
    };
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}
