const std = @import("std");
const binding = @import("binding.zig");
const core_state = @import("core_state.zig");

pub const payload_version: u16 = 7;
pub const max_facts: usize = 8;
pub const max_transitions: u32 = 32_768;
pub const max_operation_attempts: usize = 8;

const header_size: usize = 4;
const fact_size: usize = 104;
pub const max_payload_size: usize = header_size + max_facts * fact_size + core_state.encoded_size;
const result_digest_kind: u8 = 4;

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

pub const EvidenceKind = binding.DescriptorKind;

pub const ResultClass = enum(u8) {
    ordinary = 0,
    indeterminate = 1,
};

pub const ConversationKind = enum(u8) {
    user_text = 1,
    assistant_text = 2,
    tool_call = 3,
    tool_result = 4,
    context_checkpoint = 5,
};

pub const DurableResultEvidence = union(binding.DescriptorKind) {
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
    descriptor_digest: binding.Descriptor,
    recovery_class: RecoveryClass,
};

pub const TaskRecord = struct {
    agent: AgentContext,
    task_id: u64,
    content_ref: u64,
};

pub const AttemptRecord = struct {
    operation: OperationContext,
    attempt_id: u64,
    descriptor_ref: u64,
    descriptor_digest: binding.Descriptor,
    recovery_class: RecoveryClass,
    /// Number of earlier model Attempts that may also have reached the
    /// provider. Non-model Attempts are always zero.
    possible_duplicate_attempts: u8,
};

pub const AuthorizationRecord = struct {
    operation: OperationContext,
    permission_ref: u64,
    descriptor_digest: binding.Descriptor,
    allowed: bool,
};

pub const ResultRecord = struct {
    operation: OperationContext,
    result_ref: u64,
    result_digest: binding.Result,
    class: ResultClass,
    evidence: ResultEvidence,
};

pub const ConversationRecord = struct {
    agent: AgentContext,
    entry_id: u64,
    parent_id: u64,
    kind: ConversationKind,
    content_ref: u64,
};

pub const OutcomeRecord = struct {
    agent: AgentContext,
    outcome_id: u64,
    content_ref: u64,
};

pub const ResultAppliedRecord = struct {
    operation: OperationContext,
    attempt_id: u64,
    result_ref: u64,
    result_digest: binding.Result,
    recovery_class: RecoveryClass,
};

pub const ApprovalRequiredRecord = struct {
    operation: OperationContext,
    binding_ref: u64,
    descriptor_ref: u64,
    descriptor_digest: binding.Descriptor,
};

pub const ContentReferenceRole = enum {
    direct,
    patch_intent,
};

pub const ContentReference = struct {
    reference: u64,
    role: ContentReferenceRole,
};

pub const max_content_references_per_fact: usize = 2;

pub const ContentReferences = struct {
    values: [max_content_references_per_fact]ContentReference = undefined,
    count: u2 = 0,

    pub fn slice(self: *const ContentReferences) []const ContentReference {
        return self.values[0..self.count];
    }

    fn append(self: *ContentReferences, reference: u64, role: ContentReferenceRole) void {
        if (reference == 0) return;
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = .{ .reference = reference, .role = role };
        self.count += 1;
    }
};

pub const Fact = union(Kind) {
    task_admitted: TaskRecord,
    operation_submitted: OperationRecord,
    operation_accepted: OperationRecord,
    attempt_admitted: AttemptRecord,
    authorization: AuthorizationRecord,
    result: ResultRecord,
    conversation_advanced: ConversationRecord,
    outcome: OutcomeRecord,
    cancellation: AgentContext,
    shutdown: AgentContext,
    result_applied: ResultAppliedRecord,
    approval_required: ApprovalRequiredRecord,

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

    /// Returns every durable content reference carried by this Fact. This is
    /// the sole Fact-to-content relationship definition; validation and
    /// persistence may apply different policies to the same bounded mapping.
    pub fn contentReferences(self: Fact) ContentReferences {
        var references: ContentReferences = .{};
        switch (self) {
            .task_admitted => |value| references.append(value.content_ref, .direct),
            .operation_submitted, .operation_accepted => |value| references.append(
                value.descriptor_ref,
                if (std.meta.activeTag(value.descriptor_digest) == .apply_patch)
                    .patch_intent
                else
                    .direct,
            ),
            .attempt_admitted => |value| references.append(value.descriptor_ref, .direct),
            .authorization => |value| references.append(value.permission_ref, .direct),
            .result => |value| references.append(value.result_ref, .direct),
            .conversation_advanced => |value| references.append(value.content_ref, .direct),
            .outcome => |value| references.append(value.content_ref, .direct),
            .result_applied => |value| references.append(value.result_ref, .direct),
            .approval_required => |value| {
                references.append(value.binding_ref, .direct);
                references.append(value.descriptor_ref, .direct);
            },
            .cancellation, .shutdown => {},
        }
        return references;
    }
};

const RawFact = struct {
    kind: Kind,
    recovery_class: RecoveryClass,
    flags: u8,
    agent_id: u64,
    operation_id: u64,
    attempt_id: u64,
    subject: u64,
    reference: u64,
    auxiliary: u64,
    digest: binding.Sha256,
    digest_kind: u8,
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
    descriptor_digest: binding.Descriptor,
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
    descriptor_digest: binding.Descriptor,
    recovery_class: RecoveryClass,
) Fact {
    return .{ .operation_accepted = .{
        .operation = operation,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
        .recovery_class = recovery_class,
    } };
}

pub fn consequentialAttemptAdmitted(
    operation: OperationContext,
    attempt_id: u64,
    descriptor_ref: u64,
    descriptor_digest: binding.Descriptor,
) Fact {
    return .{ .attempt_admitted = .{
        .operation = operation,
        .attempt_id = attempt_id,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
        .recovery_class = .consequential,
        .possible_duplicate_attempts = 0,
    } };
}

pub fn modelAttemptAdmitted(
    operation: OperationContext,
    attempt_id: u64,
    descriptor_ref: u64,
    descriptor_digest: binding.Descriptor,
    possible_duplicate_attempts: u8,
) Fact {
    return .{ .attempt_admitted = .{
        .operation = operation,
        .attempt_id = attempt_id,
        .descriptor_ref = descriptor_ref,
        .descriptor_digest = descriptor_digest,
        .recovery_class = .model,
        .possible_duplicate_attempts = possible_duplicate_attempts,
    } };
}

pub fn authorization(record: AuthorizationRecord) Fact {
    return .{ .authorization = record };
}

pub fn result(record: ResultRecord) Fact {
    return .{ .result = record };
}

pub fn conversationAdvanced(record: ConversationRecord) Fact {
    return .{ .conversation_advanced = record };
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

pub fn resultApplied(record: ResultAppliedRecord) Fact {
    return .{ .result_applied = record };
}

pub fn approvalRequired(record: ApprovalRequiredRecord) Fact {
    return .{ .approval_required = record };
}

pub const Transaction = struct {
    sequence: u64,
    facts: [max_facts]Fact = undefined,
    fact_count: u8,
    core: ?[core_state.encoded_size]u8 = null,

    pub fn factSlice(self: *const Transaction) []const Fact {
        return self.facts[0..self.fact_count];
    }

    pub fn referencesContent(self: *const Transaction, reference: u64) bool {
        for (self.factSlice()) |fact| {
            const references = fact.contentReferences();
            for (references.slice()) |candidate| {
                if (candidate.reference == reference) return true;
            }
        }
        return false;
    }

    pub fn referencesPatchIntent(self: *const Transaction, reference: u64) bool {
        for (self.factSlice()) |fact| {
            const references = fact.contentReferences();
            for (references.slice()) |candidate| {
                if (candidate.reference == reference and candidate.role == .patch_intent) {
                    return true;
                }
            }
        }
        return false;
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
    if (fact.digest_kind == 0 and !std.mem.allEqual(u8, &fact.digest, 0)) {
        return error.NoncanonicalAbsentBinding;
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
        .task_admitted, .outcome => {
            if (fact.subject == 0 or fact.reference == 0 or fact.operation_id != 0 or
                fact.attempt_id != 0 or fact.auxiliary != 0 or fact.digest_kind != 0 or
                fact.recovery_class != .none or fact.flags != 0 or fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .conversation_advanced => {
            if (fact.subject == 0 or fact.reference == 0 or fact.operation_id != 0 or
                fact.attempt_id != 0 or fact.recovery_class != .none or fact.evidence_kind != 0 or
                std.enums.fromInt(ConversationKind, fact.flags) == null or
                fact.digest_kind != 0 or (fact.subject == 1) != (fact.auxiliary == 0))
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .cancellation, .shutdown => {
            if (fact.operation_id != 0 or fact.attempt_id != 0 or fact.subject != 0 or
                fact.reference != 0 or fact.auxiliary != 0 or fact.digest_kind != 0 or fact.flags != 0 or
                fact.recovery_class != .none or fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .operation_submitted, .operation_accepted => {
            if (fact.attempt_id != 0 or fact.subject != 0 or fact.reference == 0 or
                fact.auxiliary != 0 or !validDescriptorKind(fact.digest_kind) or
                fact.flags != 0 or fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .attempt_admitted => {
            if (fact.attempt_id == 0 or fact.subject != 0 or fact.auxiliary != 0 or
                !validDescriptorKind(fact.digest_kind) or
                (fact.recovery_class != .model and fact.flags != 0) or
                fact.flags >= max_operation_attempts or
                !descriptorMatchesRecovery(fact.digest_kind, fact.recovery_class) or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .approval_required => {
            if (fact.reference == 0 or fact.auxiliary != 0 or
                !validDescriptorKind(fact.digest_kind) or fact.flags != 0 or
                fact.attempt_id != 0 or fact.recovery_class != .none or fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .authorization => {
            if (fact.auxiliary != 0 or !validDescriptorKind(fact.digest_kind) or
                (fact.flags != 1 and fact.flags != 2) or
                fact.attempt_id != 0 or fact.subject != 0 or fact.recovery_class != .none or
                fact.evidence_kind != 0)
            {
                return error.InvalidKindSpecificPayload;
            }
        },
        .result => {
            if (fact.reference == 0 or fact.auxiliary != 0 or
                fact.digest_kind != result_digest_kind or fact.subject != 0 or
                fact.recovery_class == .none or
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
                fact.auxiliary != 0 or fact.digest_kind != result_digest_kind or
                fact.evidence_kind != 0)
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
    out[2] = raw.digest_kind;
    out[3] = raw.flags;
    write(u32, out, 4, raw.generation);
    write(u32, out, 8, raw.agent_generation);
    write(u64, out, 12, raw.agent_id);
    write(u64, out, 20, raw.operation_id);
    write(u64, out, 28, raw.attempt_id);
    write(u64, out, 36, raw.subject);
    write(u64, out, 44, raw.reference);
    write(u64, out, 52, raw.auxiliary);
    write(u64, out, 60, raw.ownership_epoch);
    out[68] = raw.evidence_kind;
    @memcpy(out[72..104], &raw.digest);
}

fn decodeFact(input: []const u8) !Fact {
    if (input[69] != 0 or input[70] != 0 or input[71] != 0) {
        return error.NonzeroReservedByte;
    }
    const raw: RawFact = .{
        .kind = std.enums.fromInt(Kind, input[0]) orelse return error.UnsupportedTransitionKind,
        .recovery_class = std.enums.fromInt(RecoveryClass, input[1]) orelse
            return error.InvalidRecoveryClass,
        .flags = input[3],
        .generation = read(u32, input, 4),
        .agent_generation = read(u32, input, 8),
        .agent_id = read(u64, input, 12),
        .operation_id = read(u64, input, 20),
        .attempt_id = read(u64, input, 28),
        .subject = read(u64, input, 36),
        .reference = read(u64, input, 44),
        .auxiliary = read(u64, input, 52),
        .digest = input[72..104].*,
        .digest_kind = input[2],
        .ownership_epoch = read(u64, input, 60),
        .evidence_kind = input[68],
    };
    try validateRawFact(raw);
    return factFromRaw(raw);
}

fn rawFact(fact: Fact) RawFact {
    var raw = emptyRaw(fact.kind(), fact.agent());
    switch (fact) {
        .task_admitted => |value| {
            raw.subject = value.task_id;
            raw.reference = value.content_ref;
        },
        .operation_submitted, .operation_accepted => |value| {
            setOperation(&raw, value.operation);
            raw.reference = value.descriptor_ref;
            setDescriptor(&raw, value.descriptor_digest);
            raw.recovery_class = value.recovery_class;
        },
        .attempt_admitted => |value| {
            setOperation(&raw, value.operation);
            raw.attempt_id = value.attempt_id;
            raw.reference = value.descriptor_ref;
            setDescriptor(&raw, value.descriptor_digest);
            raw.recovery_class = value.recovery_class;
            raw.flags = value.possible_duplicate_attempts;
        },
        .authorization => |value| {
            setOperation(&raw, value.operation);
            raw.reference = value.permission_ref;
            setDescriptor(&raw, value.descriptor_digest);
            raw.flags = if (value.allowed) 1 else 2;
        },
        .result => |value| {
            setOperation(&raw, value.operation);
            raw.reference = value.result_ref;
            raw.digest = value.result_digest.bytes;
            raw.digest_kind = result_digest_kind;
            raw.flags = @intFromEnum(value.class);
            switch (value.evidence) {
                .immediate => |recovery_class| raw.recovery_class = recovery_class,
                .durable => |evidence| {
                    raw.evidence_kind = @intFromEnum(std.meta.activeTag(evidence));
                    raw.attempt_id = switch (evidence) {
                        inline else => |attempt_id| attempt_id,
                    };
                    raw.recovery_class = switch (evidence) {
                        .model => .model,
                        .bash, .apply_patch => .consequential,
                    };
                },
            }
        },
        .conversation_advanced => |value| {
            raw.subject = value.entry_id;
            raw.reference = value.content_ref;
            raw.auxiliary = value.parent_id;
            raw.flags = @intFromEnum(value.kind);
        },
        .outcome => |value| {
            raw.subject = value.outcome_id;
            raw.reference = value.content_ref;
        },
        .cancellation, .shutdown => {},
        .result_applied => |value| {
            setOperation(&raw, value.operation);
            raw.attempt_id = value.attempt_id;
            raw.reference = value.result_ref;
            raw.digest = value.result_digest.bytes;
            raw.digest_kind = result_digest_kind;
            raw.recovery_class = value.recovery_class;
        },
        .approval_required => |value| {
            setOperation(&raw, value.operation);
            raw.subject = value.binding_ref;
            raw.reference = value.descriptor_ref;
            setDescriptor(&raw, value.descriptor_digest);
        },
    }
    return raw;
}

fn emptyRaw(kind: Kind, agent: AgentContext) RawFact {
    return .{
        .kind = kind,
        .recovery_class = .none,
        .flags = 0,
        .agent_id = agent.agent_id,
        .operation_id = 0,
        .attempt_id = 0,
        .subject = 0,
        .reference = 0,
        .auxiliary = 0,
        .digest = @splat(0),
        .digest_kind = 0,
        .ownership_epoch = agent.ownership_epoch,
        .generation = 0,
        .agent_generation = agent.agent_generation,
        .evidence_kind = 0,
    };
}

fn setOperation(raw: *RawFact, operation: OperationContext) void {
    raw.operation_id = operation.operation_id;
    raw.generation = operation.generation;
}

fn setDescriptor(raw: *RawFact, descriptor: binding.Descriptor) void {
    raw.digest = descriptor.bytes();
    raw.digest_kind = @intFromEnum(std.meta.activeTag(descriptor));
}

fn validDescriptorKind(value: u8) bool {
    return std.enums.fromInt(binding.DescriptorKind, value) != null;
}

fn descriptorMatchesRecovery(value: u8, recovery: RecoveryClass) bool {
    const kind = std.enums.fromInt(binding.DescriptorKind, value) orelse return false;
    return switch (kind) {
        .model => recovery == .model,
        .bash, .apply_patch => recovery == .consequential,
    };
}

fn descriptorFromRaw(raw: RawFact) binding.Descriptor {
    return binding.Descriptor.fromBytes(
        std.enums.fromInt(binding.DescriptorKind, raw.digest_kind) orelse unreachable,
        raw.digest,
    );
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
            .descriptor_digest = descriptorFromRaw(raw),
            .recovery_class = raw.recovery_class,
        } },
        .operation_accepted => .{ .operation_accepted = .{
            .operation = operation,
            .descriptor_ref = raw.reference,
            .descriptor_digest = descriptorFromRaw(raw),
            .recovery_class = raw.recovery_class,
        } },
        .attempt_admitted => .{ .attempt_admitted = .{
            .operation = operation,
            .attempt_id = raw.attempt_id,
            .descriptor_ref = raw.reference,
            .descriptor_digest = descriptorFromRaw(raw),
            .recovery_class = raw.recovery_class,
            .possible_duplicate_attempts = raw.flags,
        } },
        .authorization => .{ .authorization = .{
            .operation = operation,
            .permission_ref = raw.reference,
            .descriptor_digest = descriptorFromRaw(raw),
            .allowed = raw.flags == 1,
        } },
        .result => .{ .result = .{
            .operation = operation,
            .result_ref = raw.reference,
            .result_digest = .{ .bytes = raw.digest },
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
            .parent_id = raw.auxiliary,
            .kind = std.enums.fromInt(ConversationKind, raw.flags) orelse unreachable,
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
            .result_digest = .{ .bytes = raw.digest },
            .recovery_class = raw.recovery_class,
        } },
        .approval_required => .{ .approval_required = .{
            .operation = operation,
            .binding_ref = raw.subject,
            .descriptor_ref = raw.reference,
            .descriptor_digest = descriptorFromRaw(raw),
        } },
    };
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}
