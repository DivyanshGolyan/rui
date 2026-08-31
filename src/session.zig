const std = @import("std");
const binding = @import("binding.zig");
const blob_store = @import("blob_store.zig");
const conversation = @import("conversation.zig");
const model_contract = @import("model_contract.zig");
const completion_inbox = @import("completion_inbox.zig");
const core_state = @import("core_state.zig");
const host_store = @import("host_store.zig");
const session_transition = @import("session_transition.zig");

pub const workspace_path_capacity = 1024;
pub const model_name_capacity = host_store.max_model_bytes;
const lock_path = "owner.lock";
const blobs_path = "blobs";

pub const Identities = host_store.SessionIdentity;

pub const Config = struct {
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const CreateConfig = struct {
    identities: Identities,
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const OwnerToken = host_store.OwnerToken;

pub const EntryKind = session_transition.ConversationKind;

pub const ConversationEntry = struct {
    kind: EntryKind,
    session_id: u64,
    entry_id: u64,
    parent_id: u64,
    task_id: u64,
    content_ref: u64,
    sequence: u64,
};

pub const Restored = struct {
    session: Session,
};

pub const Projection = struct {
    session_id: u64,
    task_id: u64,
    active_leaf_id: u64,
    ownership_epoch: u64,
};

pub const LedgerView = struct {
    last_sequence: u64 = 0,
    last_core: ?[core_state.encoded_size]u8 = null,
    facts: [session_transition.max_facts]session_transition.Fact = undefined,
    fact_count: u8 = 0,

    pub fn factSlice(self: *const LedgerView) []const session_transition.Fact {
        return self.facts[0..self.fact_count];
    }
};

const OperationHistory = struct {
    const max_attempts = session_transition.max_operation_attempts;

    operation_id: u64 = 0,
    generation: u32 = 0,
    recovery_class: session_transition.RecoveryClass = .none,
    descriptor: ?session_transition.OperationRecord = null,
    attempt: ?session_transition.AttemptRecord = null,
    attempts: [max_attempts]?session_transition.AttemptRecord = @splat(null),
    attempt_count: u8 = 0,
    approval_required: ?session_transition.ApprovalRequiredRecord = null,
    authorization: ?session_transition.AuthorizationRecord = null,
    result: ?session_transition.ResultRecord = null,
    terminal_result_sequence: ?u64 = null,

    fn accepts(self: OperationHistory, operation: session_transition.OperationContext) bool {
        return self.operation_id == operation.operation_id and self.generation == operation.generation;
    }

    fn appendAttempt(self: *OperationHistory, attempt: session_transition.AttemptRecord) !void {
        for (self.attempts[0..self.attempt_count]) |maybe_existing| {
            const existing = maybe_existing.?;
            if (existing.attempt_id != attempt.attempt_id) continue;
            if (!std.meta.eql(existing, attempt)) return error.ConflictingLedgerFacts;
            self.attempt = existing;
            return;
        }
        if ((attempt.recovery_class == .model and
            attempt.possible_duplicate_attempts != self.attempt_count) or
            (attempt.recovery_class != .model and attempt.possible_duplicate_attempts != 0))
        {
            return error.InvalidAttemptDuplicateAccounting;
        }
        if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
        self.attempts[self.attempt_count] = attempt;
        self.attempt_count += 1;
        self.attempt = attempt;
    }

    fn findAttempt(self: OperationHistory, attempt_id: u64) ?session_transition.AttemptRecord {
        for (self.attempts[0..self.attempt_count]) |maybe_attempt| {
            const attempt = maybe_attempt.?;
            if (attempt.attempt_id == attempt_id) return attempt;
        }
        return null;
    }
};

const SemanticIndex = struct {
    last_sequence: u64 = 0,
    last_core: ?[core_state.encoded_size]u8 = null,
    model: OperationHistory = .{},
    consequential: OperationHistory = .{},
    open_operation: ?session_transition.OperationRecord = null,
    control: ?session_transition.Fact = null,
    indeterminate: ?session_transition.ResultRecord = null,

    fn apply(self: *SemanticIndex, transaction: session_transition.Transaction) !void {
        if (transaction.sequence != self.last_sequence + 1) return error.NonmonotonicSequence;
        for (transaction.factSlice()) |fact| {
            switch (fact) {
                .operation_submitted => |record| {
                    const history = historyFor(self, record.operation, record.recovery_class);
                    if (!history.accepts(record.operation)) history.* = .{
                        .operation_id = record.operation.operation_id,
                        .generation = record.operation.generation,
                        .recovery_class = record.recovery_class,
                    };
                    history.descriptor = try uniqueValue(
                        session_transition.OperationRecord,
                        history.descriptor,
                        record,
                    );
                },
                .operation_accepted => |record| self.open_operation = record,
                .attempt_admitted => |record| {
                    const history = historyFor(self, record.operation, record.recovery_class);
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    try history.appendAttempt(record);
                },
                .approval_required => |record| {
                    const history = historyFor(self, record.operation, .none);
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    history.approval_required = try uniqueValue(
                        session_transition.ApprovalRequiredRecord,
                        history.approval_required,
                        record,
                    );
                },
                .authorization => |record| {
                    const history = historyFor(self, record.operation, .none);
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    history.authorization = record;
                },
                .result => |record| {
                    const history = historyFor(self, record.operation, resultRecoveryClass(record));
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    const first_terminal = history.result == null;
                    history.result = try uniqueValue(
                        session_transition.ResultRecord,
                        history.result,
                        record,
                    );
                    if (first_terminal) {
                        history.terminal_result_sequence = transaction.sequence;
                    } else if (history.terminal_result_sequence == null) {
                        return error.MissingTerminalResultSequence;
                    }
                    if (self.open_operation) |open_fact| {
                        if (open_fact.operation.operation_id == record.operation.operation_id and
                            open_fact.operation.generation == record.operation.generation)
                        {
                            self.open_operation = null;
                        }
                    }
                    if (resultRecoveryClass(record) == .consequential and
                        record.class == .indeterminate)
                    {
                        self.indeterminate = record;
                    }
                },
                .cancellation, .shutdown => self.control = fact,
                .task_admitted, .conversation_advanced, .outcome, .result_applied => {},
            }
        }
        if (transaction.core) |state| self.last_core = state;
        self.last_sequence = transaction.sequence;
    }

    fn emitFacts(
        self: *const SemanticIndex,
        context: *anyopaque,
        apply_fn: *const fn (*anyopaque, session_transition.Fact) anyerror!void,
    ) !void {
        const histories = [_]OperationHistory{ self.model, self.consequential };
        for (histories) |history| {
            if (history.descriptor) |record| try apply_fn(context, .{ .operation_submitted = record });
            if (history.approval_required) |record| try apply_fn(context, .{ .approval_required = record });
            if (history.authorization) |record| try apply_fn(context, .{ .authorization = record });
            for (history.attempts[0..history.attempt_count]) |maybe_attempt| {
                try apply_fn(context, .{ .attempt_admitted = maybe_attempt.? });
            }
            if (history.result) |record| try apply_fn(context, .{ .result = record });
        }
        if (self.open_operation) |record| try apply_fn(context, .{ .operation_accepted = record });
        if (self.indeterminate) |record| try apply_fn(context, .{ .result = record });
        if (self.control) |fact| try apply_fn(context, fact);
    }
};

fn historyFor(
    index: *SemanticIndex,
    operation: session_transition.OperationContext,
    recovery_class: session_transition.RecoveryClass,
) *OperationHistory {
    return switch (recovery_class) {
        .model => &index.model,
        .consequential => &index.consequential,
        .none => if (operation.operation_id >> 63 == 0) &index.model else &index.consequential,
    };
}

fn resultRecoveryClass(result: session_transition.ResultRecord) session_transition.RecoveryClass {
    return switch (result.evidence) {
        .immediate => |recovery_class| recovery_class,
        .durable => |evidence| switch (evidence) {
            .model => .model,
            .bash, .apply_patch => .consequential,
        },
    };
}

fn uniqueValue(comptime T: type, existing: ?T, candidate: T) !T {
    if (existing) |value| {
        if (!std.meta.eql(value, candidate)) return error.ConflictingLedgerFacts;
        return value;
    }
    return candidate;
}

pub const RecoveryProgress = struct {
    processed: u8,
    more: bool,
};

const InboxIndex = struct {
    const capacity = OperationHistory.max_attempts * 2;
    entries: [capacity]?completion_inbox.Envelope = @splat(null),
    ambiguous: [capacity]?AttemptKey = @splat(null),

    const AttemptKey = struct {
        kind: completion_inbox.EvidenceKind,
        operation_id: u64,
        operation_generation: u32,
        attempt_id: u64,

        fn fromEnvelope(envelope: completion_inbox.Envelope) AttemptKey {
            return .{
                .kind = envelope.kind,
                .operation_id = envelope.operation_id,
                .operation_generation = envelope.operation_generation,
                .attempt_id = envelope.attempt_id,
            };
        }

        fn matches(self: AttemptKey, envelope: completion_inbox.Envelope) bool {
            return self.kind == envelope.kind and self.operation_id == envelope.operation_id and
                self.operation_generation == envelope.operation_generation and
                self.attempt_id == envelope.attempt_id;
        }
    };

    const Disposition = union(enum) {
        irrelevant,
        duplicate,
        audit: u64,
        persist,
    };

    fn apply(
        self: *InboxIndex,
        semantic: *const SemanticIndex,
        envelope: completion_inbox.Envelope,
        session_id: u64,
        agent_id: u64,
        ownership_epoch: u64,
    ) !Disposition {
        if (envelope.session_id != session_id or envelope.agent_id != agent_id or
            envelope.agent_generation != 1 or envelope.ownership_epoch > ownership_epoch)
        {
            return .irrelevant;
        }
        const history = historyForEnvelope(semantic, envelope);
        if (history.operation_id != envelope.operation_id or
            history.generation != envelope.operation_generation)
        {
            return .irrelevant;
        }
        const attempt = history.findAttempt(envelope.attempt_id) orelse return .irrelevant;
        if (envelope.ownership_epoch != attempt.operation.agent.ownership_epoch) {
            return error.CompletionAttemptEpochMismatch;
        }
        if (envelope.kind != std.meta.activeTag(attempt.descriptor_digest)) {
            return error.CompletionEvidenceKindMismatch;
        }
        if (history.result != null) return .{
            .audit = history.terminal_result_sequence orelse
                return error.MissingTerminalResultSequence,
        };
        var ambiguous_slot: ?*?AttemptKey = null;
        for (&self.ambiguous) |*slot| {
            const key = slot.* orelse {
                if (ambiguous_slot == null) ambiguous_slot = slot;
                continue;
            };
            if (!keyIsRelevant(semantic, key)) {
                if (ambiguous_slot == null) ambiguous_slot = slot;
                continue;
            }
            if (key.matches(envelope)) return .duplicate;
        }
        var available: ?*?completion_inbox.Envelope = null;
        for (&self.entries) |*slot| {
            const existing = slot.* orelse {
                if (available == null) available = slot;
                continue;
            };
            const existing_history = historyForEnvelope(semantic, existing);
            if (existing_history.operation_id != existing.operation_id or
                existing_history.generation != existing.operation_generation or
                !attemptMatchesKind(existing_history, existing.attempt_id, existing.kind))
            {
                if (available == null) available = slot;
                continue;
            }
            if (existing.operation_id == envelope.operation_id and
                existing.operation_generation == envelope.operation_generation and
                existing.attempt_id == envelope.attempt_id)
            {
                if (std.meta.eql(existing, envelope)) return .duplicate;
                slot.* = null;
                const destination = ambiguous_slot orelse
                    return error.InboxSemanticCapacityExceeded;
                destination.* = AttemptKey.fromEnvelope(envelope);
                return .persist;
            }
        }
        const slot = available orelse return error.InboxSemanticCapacityExceeded;
        slot.* = envelope;
        return .persist;
    }

    fn prune(self: *InboxIndex, semantic: *const SemanticIndex) void {
        for (&self.entries) |*slot| {
            const envelope = slot.* orelse continue;
            if (!envelopeIsPending(semantic, envelope)) slot.* = null;
        }
        for (&self.ambiguous) |*slot| {
            const key = slot.* orelse continue;
            if (!keyIsPending(semantic, key)) slot.* = null;
        }
    }

    fn historyForEnvelope(
        semantic: *const SemanticIndex,
        envelope: completion_inbox.Envelope,
    ) OperationHistory {
        return switch (envelope.kind) {
            .model => semantic.model,
            .bash, .apply_patch => semantic.consequential,
        };
    }

    fn keyIsRelevant(semantic: *const SemanticIndex, key: AttemptKey) bool {
        const history = switch (key.kind) {
            .model => semantic.model,
            .bash, .apply_patch => semantic.consequential,
        };
        return history.operation_id == key.operation_id and
            history.generation == key.operation_generation and
            attemptMatchesKind(history, key.attempt_id, key.kind);
    }

    fn envelopeIsPending(semantic: *const SemanticIndex, envelope: completion_inbox.Envelope) bool {
        const history = historyForEnvelope(semantic, envelope);
        return history.result == null and history.operation_id == envelope.operation_id and
            history.generation == envelope.operation_generation and
            attemptMatchesKind(history, envelope.attempt_id, envelope.kind);
    }

    fn keyIsPending(semantic: *const SemanticIndex, key: AttemptKey) bool {
        const history = switch (key.kind) {
            .model => semantic.model,
            .bash, .apply_patch => semantic.consequential,
        };
        return history.result == null and history.operation_id == key.operation_id and
            history.generation == key.operation_generation and
            attemptMatchesKind(history, key.attempt_id, key.kind);
    }

    fn attemptMatchesKind(
        history: OperationHistory,
        attempt_id: u64,
        kind: completion_inbox.EvidenceKind,
    ) bool {
        const attempt = history.findAttempt(attempt_id) orelse return false;
        return std.meta.activeTag(attempt.descriptor_digest) == kind;
    }
};

const ResidentState = struct {
    semantic: SemanticIndex = .{},
    inbox: InboxIndex = .{},
    conversation_head_id: u64 = 0,
    conversation_head_kind: ?EntryKind = null,

    fn applyingLedger(
        self: ResidentState,
        transaction: session_transition.Transaction,
        agent_id: u64,
        ownership_epoch: u64,
    ) !ResidentState {
        var next = self;
        for (transaction.factSlice()) |fact| {
            const agent = fact.agent();
            if (agent.agent_id != agent_id or agent.agent_generation != 1 or
                agent.ownership_epoch > ownership_epoch)
            {
                return error.InvalidSessionFactIdentity;
            }
        }
        try next.semantic.apply(transaction);
        for (transaction.factSlice()) |fact| switch (fact) {
            .conversation_advanced => |advanced| {
                if (next.conversation_head_id == std.math.maxInt(u64)) {
                    return error.EntryIdentityExhausted;
                }
                if (advanced.entry_id != next.conversation_head_id + 1 or
                    advanced.parent_id != next.conversation_head_id)
                {
                    return error.ConversationLedgerGap;
                }
                if (next.conversation_head_kind == null) {
                    if (advanced.entry_id != 1 or advanced.parent_id != 0 or
                        advanced.kind != .user_text) return error.InvalidConversationGrammar;
                } else {
                    const parent_kind = next.conversation_head_kind.?;
                    if ((parent_kind == .tool_call) != (advanced.kind == .tool_result) or
                        (advanced.kind == .tool_call and parent_kind == .tool_call))
                    {
                        return error.InvalidConversationGrammar;
                    }
                }
                next.conversation_head_id = advanced.entry_id;
                next.conversation_head_kind = advanced.kind;
            },
            .task_admitted,
            .operation_submitted,
            .operation_accepted,
            .attempt_admitted,
            .authorization,
            .result,
            .outcome,
            .cancellation,
            .shutdown,
            .result_applied,
            .approval_required,
            => {},
        };
        next.inbox.prune(&next.semantic);
        return next;
    }

    fn applyingCompletion(
        self: ResidentState,
        envelope: completion_inbox.Envelope,
        session_id: u64,
        agent_id: u64,
        ownership_epoch: u64,
    ) !struct { state: ResidentState, disposition: InboxIndex.Disposition } {
        var next = self;
        const disposition = try next.inbox.apply(
            &next.semantic,
            envelope,
            session_id,
            agent_id,
            ownership_epoch,
        );
        return .{ .state = next, .disposition = disposition };
    }
};

const Recovery = union(enum) {
    ready,
    pending,
    ledger: struct {
        next_sequence: u64,
        ledger_head: u64,
        inbox_watermark: u64,
    },
    inbox: struct {
        after_id: u64,
        watermark: u64,
        ledger_head: u64,
    },
    historical: struct {
        completion: host_store.StoredCompletion,
        watermark: u64,
        ledger_head: u64,
        scan: host_store.CompletedAttemptScan,
    },
};

pub const AppendBoundary = enum {
    after_entry_sync,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, AppendBoundary) anyerror!void,
};

pub const BlobWriter = struct {
    session: *Session,
    blobs: std.Io.Dir,
    writer: blob_store.Writer,
    open: bool = true,

    pub fn append(self: *BlobWriter, bytes: []const u8) !void {
        if (!self.open) return error.BlobWriterClosed;
        try self.session.ensureUsable();
        try self.writer.append(self.session.io, bytes);
    }

    pub fn finish(self: *BlobWriter) !void {
        if (!self.open) return error.BlobWriterClosed;
        try self.session.ensureUsable();
        try self.writer.finish(self.session.io);
        self.blobs.close(self.session.io);
        self.open = false;
    }

    pub fn abort(self: *BlobWriter) void {
        if (!self.open) return;
        self.writer.abort(self.session.io);
        self.blobs.close(self.session.io);
        self.open = false;
    }
};

pub const BlobReader = struct {
    io: std.Io,
    blobs: std.Io.Dir,
    reader: blob_store.Reader,
    open: bool = true,

    pub fn length(self: *const BlobReader) u64 {
        return self.reader.meta.length;
    }

    pub fn digest(self: *const BlobReader) binding.Blob {
        return self.reader.meta.digest;
    }

    pub fn readWindow(self: *BlobReader, offset: u64, out: []u8) ![]const u8 {
        if (!self.open) return error.BlobReaderClosed;
        return self.reader.readWindow(self.io, offset, out);
    }

    pub fn close(self: *BlobReader) void {
        if (!self.open) return;
        self.reader.close(self.io);
        self.blobs.close(self.io);
        self.open = false;
    }
};

fn readExactConversationWindow(reader: *BlobReader, offset: u64, out: []u8) !void {
    if ((try reader.readWindow(offset, out)).len != out.len) return error.InvalidConversationContent;
}

fn validateUtf8ConversationWindows(reader: *BlobReader, start: u64, length: u64) !void {
    var window: [4096]u8 = undefined;
    var sequence: [4]u8 = undefined;
    var sequence_length: u3 = 0;
    var sequence_size: u3 = 0;
    var consumed: u64 = 0;
    while (consumed < length) {
        const wanted: usize = @intCast(@min(length - consumed, window.len));
        const bytes = try reader.readWindow(start + consumed, window[0..wanted]);
        if (bytes.len != wanted) return error.InvalidConversationContent;
        for (bytes) |byte| {
            if (sequence_length == 0) {
                const size = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidConversationContent;
                if (size == 1) continue;
                sequence[0] = byte;
                sequence_length = 1;
                sequence_size = @intCast(size);
            } else {
                sequence[sequence_length] = byte;
                sequence_length += 1;
                if (sequence_length == sequence_size) {
                    if (!std.unicode.utf8ValidateSlice(sequence[0..sequence_size])) {
                        return error.InvalidConversationContent;
                    }
                    sequence_length = 0;
                    sequence_size = 0;
                }
            }
        }
        consumed += bytes.len;
    }
    if (sequence_length != 0) return error.InvalidConversationContent;
}

pub const Session = struct {
    io: std.Io,
    dir: std.Io.Dir,
    storage: *host_store.StorageOwner,
    lock_file: std.Io.File,
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    branch_id: u64,
    ownership_epoch: u64,
    pending_conversation: ?ConversationEntry = null,
    resident: ResidentState = .{},
    recovery: Recovery = .ready,
    workspace_path: [workspace_path_capacity]u8 = undefined,
    workspace_path_length: u16,
    model_name: [model_name_capacity]u8 = undefined,
    model_name_length: u8,
    open: bool = true,
    failed: bool = false,

    pub fn create(
        root: std.Io.Dir,
        storage: *host_store.StorageOwner,
        io: std.Io,
        config: Config,
    ) !Session {
        for (0..8) |_| {
            var identities: Identities = undefined;
            io.random(std.mem.asBytes(&identities));
            identities.validate() catch continue;
            return createExact(root, storage, io, .{
                .identities = identities,
                .workspace_path = config.workspace_path,
                .model = config.model,
                .task = config.task,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
        }
        return error.IdentityAllocationExhausted;
    }

    fn createExact(
        root: std.Io.Dir,
        storage: *host_store.StorageOwner,
        io: std.Io,
        config: CreateConfig,
    ) !Session {
        try config.identities.validate();
        if (config.workspace_path.len == 0 or config.workspace_path.len > workspace_path_capacity or
            config.model.len == 0 or config.model.len > model_name_capacity or
            !std.unicode.utf8ValidateSlice(config.model) or
            config.task.len == 0 or config.task.len > conversation.max_result_content_size or
            !std.unicode.utf8ValidateSlice(config.task))
        {
            return error.InvalidSessionMetadata;
        }
        try validateWorkspace(io, config.workspace_path);
        var canonical_workspace_buffer: [workspace_path_capacity]u8 = undefined;
        const canonical_workspace_length = try std.Io.Dir.cwd().realPathFile(
            io,
            config.workspace_path,
            &canonical_workspace_buffer,
        );
        if (canonical_workspace_length == 0 or canonical_workspace_length > workspace_path_capacity) {
            return error.InvalidSessionMetadata;
        }
        const canonical_workspace = canonical_workspace_buffer[0..canonical_workspace_length];

        var name_buffer: [16]u8 = undefined;
        const name = sessionName(config.identities.session_id, &name_buffer);
        try root.createDir(io, name, .fromMode(0o700));
        errdefer root.deleteTree(io, name) catch {
            // A leftover directory is non-authoritative and exclusive creation fails closed on reuse.
        };
        try syncDir(root, io);
        var dir = try root.openDir(io, name, .{});
        errdefer dir.close(io);

        var lock_file = try dir.createFile(io, lock_path, .{
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer {
            lock_file.unlock(io);
            lock_file.close(io);
        }

        try dir.createDir(io, blobs_path, .default_dir);
        try syncDir(dir, io);
        var blobs = try dir.openDir(io, blobs_path, .{});
        defer blobs.close(io);
        try blob_store.put(blobs, io, config.identities.task_id, config.task);
        try syncDir(dir, io);

        const agent: session_transition.AgentContext = .{
            .agent_id = config.identities.agent_id,
            .agent_generation = 1,
            .ownership_epoch = 1,
        };
        var initial: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
        initial.facts[0] = session_transition.conversationAdvanced(
            .{
                .agent = agent,
                .entry_id = 1,
                .parent_id = 0,
                .kind = .user_text,
                .content_ref = config.identities.task_id,
            },
        );

        var created: Session = .{
            .io = io,
            .dir = dir,
            .storage = storage,
            .lock_file = lock_file,
            .session_id = config.identities.session_id,
            .agent_id = config.identities.agent_id,
            .task_id = config.identities.task_id,
            .branch_id = config.identities.branch_id,
            .ownership_epoch = 1,
            .workspace_path_length = @intCast(canonical_workspace.len),
            .model_name_length = @intCast(config.model.len),
        };
        @memcpy(created.workspace_path[0..canonical_workspace.len], canonical_workspace);
        @memcpy(created.model_name[0..config.model.len], config.model);
        created.resident = try created.resident.applyingLedger(initial, created.agent_id, created.ownership_epoch);

        try storage.createSessionWithMetadata(.{
            .identities = .{
                .session_id = config.identities.session_id,
                .agent_id = config.identities.agent_id,
                .task_id = config.identities.task_id,
                .branch_id = config.identities.branch_id,
            },
            .workspace_path = canonical_workspace,
            .model = config.model,
        }, initial);
        return created;
    }

    pub fn openExisting(
        root: std.Io.Dir,
        storage: *host_store.StorageOwner,
        io: std.Io,
        session_id: u64,
    ) !Restored {
        if (session_id == 0) return error.InvalidIdentity;
        var name_buffer: [16]u8 = undefined;
        const name = sessionName(session_id, &name_buffer);
        var dir = try root.openDir(io, name, .{});
        errdefer dir.close(io);
        var lock_file = dir.openFile(io, lock_path, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.SessionBusy,
            else => return err,
        };
        errdefer {
            lock_file.unlock(io);
            lock_file.close(io);
        }

        var stored = try storage.readSession(session_id);
        try validateWorkspace(io, stored.workspacePath());
        stored.ownership_epoch = try storage.claimSession(session_id);

        // Provisional response drafts are scratch. Once this ownership epoch
        // holds the Session lock, no live writer from an earlier process can
        // exist, so crash-left drafts in the dedicated scratch namespace are
        // safe to discard. Sealed blobs remain available for the normal
        // recovery/admission path outside that namespace.
        var blobs = try dir.openDir(io, blobs_path, .{});
        defer blobs.close(io);
        _ = try blob_store.resetDrafts(blobs, io);
        return .{
            .session = fromStored(io, storage, dir, lock_file, stored, false),
        };
    }

    fn fromStored(
        io: std.Io,
        storage: *host_store.StorageOwner,
        dir: std.Io.Dir,
        lock_file: std.Io.File,
        stored: host_store.StoredSession,
        recovery_complete: bool,
    ) Session {
        std.debug.assert(stored.workspacePath().len <= workspace_path_capacity);
        var session: Session = .{
            .io = io,
            .dir = dir,
            .storage = storage,
            .lock_file = lock_file,
            .session_id = stored.identities.session_id,
            .agent_id = stored.identities.agent_id,
            .task_id = stored.identities.task_id,
            .branch_id = stored.identities.branch_id,
            .ownership_epoch = stored.ownership_epoch,
            .workspace_path_length = stored.workspace_path_length,
            .model_name_length = stored.model_length,
            .recovery = if (recovery_complete) .ready else .pending,
        };
        @memcpy(session.workspace_path[0..stored.workspace_path_length], stored.workspacePath());
        @memcpy(session.model_name[0..stored.model_length], stored.modelName());
        return session;
    }

    pub fn ownerToken(self: *const Session) OwnerToken {
        return .{ .session_id = self.session_id, .epoch = self.ownership_epoch };
    }

    pub fn workspacePath(self: *const Session) []const u8 {
        return self.workspace_path[0..self.workspace_path_length];
    }

    pub fn modelName(self: *const Session) []const u8 {
        return self.model_name[0..self.model_name_length];
    }

    pub fn recoveryIsEmpty(self: *Session) !bool {
        try self.ensureUsable();
        if (try self.storage.sessionHead(self.session_id) != 0) return false;
        return try self.storage.completionHead(self.session_id) == 0;
    }

    pub fn projection(self: *const Session) Projection {
        return .{
            .session_id = self.session_id,
            .task_id = self.task_id,
            .active_leaf_id = self.resident.conversation_head_id,
            .ownership_epoch = self.ownership_epoch,
        };
    }

    pub fn activeLeafId(self: *const Session) u64 {
        return self.resident.conversation_head_id;
    }

    pub fn entryCount(self: *const Session) u64 {
        return self.resident.conversation_head_id;
    }

    fn authorize(self: *Session, token: OwnerToken) !void {
        if (!self.open) return error.SessionClosed;
        if (self.failed) return error.SessionUnavailable;
        if (token.session_id != self.session_id or token.epoch != self.ownership_epoch) {
            return error.StaleOwner;
        }
    }

    fn ensureUsable(self: *Session) !void {
        try self.authorize(self.ownerToken());
    }

    pub fn appendConversation(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        if (content_ref == 0) return error.InvalidContentReference;
        try self.ensureUsable();
        return self.appendAuthorized(kind, content_ref, fault) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn appendAuthorized(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        const conversation_head = self.resident.conversation_head_id;
        if (conversation_head == std.math.maxInt(u64)) return error.EntryIdentityExhausted;

        const entry: ConversationEntry = .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = conversation_head + 1,
            .parent_id = conversation_head,
            .task_id = self.task_id,
            .content_ref = content_ref,
            .sequence = conversation_head + 1,
        };
        if (self.pending_conversation) |pending| {
            if (!std.meta.eql(pending, entry)) return error.UncommittedConversationConflict;
            return pending;
        }
        self.pending_conversation = entry;
        if (fault) |hook| try hook.reached(hook.context, .after_entry_sync);
        return entry;
    }

    fn validatePreparedConversationEntry(
        self: *Session,
        fact: session_transition.Fact,
    ) !void {
        const advanced = fact.conversation_advanced;
        const conversation_head = self.resident.conversation_head_id;
        if (advanced.entry_id != conversation_head + 1) return error.ConversationLedgerGap;
        const entry = self.pending_conversation orelse return error.MissingPreparedConversationEntry;
        if (entry.entry_id != advanced.entry_id or entry.sequence != advanced.entry_id or
            entry.parent_id != advanced.parent_id or entry.kind != advanced.kind or
            entry.parent_id != conversation_head or entry.content_ref != advanced.content_ref or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationLedgerMismatch;
        }
        try self.validateConversationBlob(entry.kind, entry.content_ref, entry.parent_id);
    }

    fn verifyConversationEntry(
        self: *Session,
        advanced: session_transition.ConversationRecord,
    ) !void {
        const entry = try self.loadEntry(advanced.entry_id);
        if (entry.entry_id != advanced.entry_id or entry.sequence != advanced.entry_id or
            entry.parent_id != advanced.parent_id or entry.kind != advanced.kind or
            entry.parent_id != self.resident.conversation_head_id or
            entry.content_ref != advanced.content_ref or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationLedgerMismatch;
        }
        try self.validateConversationBlob(entry.kind, entry.content_ref, entry.parent_id);
    }

    fn validateConversationBlob(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        parent_id: u64,
    ) !void {
        var reader = try self.openBlob(content_ref);
        defer reader.close();
        const maximum: usize = switch (kind) {
            .tool_call => conversation.call_header_size + model_contract.max_tool_key_size +
                model_contract.max_tool_arguments_envelope_size,
            .tool_result => conversation.result_header_size + conversation.max_result_content_size,
            .user_text, .assistant_text, .context_checkpoint => conversation.max_result_content_size,
        };
        if (reader.length() == 0 or reader.length() > maximum) return error.InvalidConversationContent;
        switch (kind) {
            .tool_call => {
                var header_bytes: [conversation.call_header_size]u8 = undefined;
                try readExactConversationWindow(&reader, 0, &header_bytes);
                const header = conversation.decodeToolCallHeader(&header_bytes, reader.length()) catch
                    return error.InvalidConversationContent;
                var key: [model_contract.max_tool_key_size]u8 = undefined;
                try readExactConversationWindow(
                    &reader,
                    conversation.call_header_size,
                    key[0..header.key_length],
                );
                model_contract.validateToolKey(key[0..header.key_length]) catch
                    return error.InvalidConversationContent;
                var hasher = binding.Hasher(binding.StrictToolJsonV1).init();
                var arguments_offset: u64 = conversation.call_header_size + header.key_length;
                var remaining: u64 = header.arguments_length;
                var window: [4096]u8 = undefined;
                while (remaining != 0) {
                    const wanted: usize = @intCast(@min(remaining, window.len));
                    const bytes = try reader.readWindow(arguments_offset, window[0..wanted]);
                    if (bytes.len != wanted) return error.InvalidConversationContent;
                    hasher.update(bytes);
                    arguments_offset += bytes.len;
                    remaining -= bytes.len;
                }
                if (!binding.eql(
                    binding.StrictToolJsonV1,
                    hasher.final(),
                    header.arguments_digest,
                )) return error.InvalidConversationContent;
            },
            .tool_result => {
                var header_bytes: [conversation.result_header_size]u8 = undefined;
                try readExactConversationWindow(&reader, 0, &header_bytes);
                const result = conversation.decodeToolResultHeader(&header_bytes, reader.length()) catch
                    return error.InvalidConversationContent;
                if (result.parent_id != parent_id) return error.InvalidConversationParent;
                try validateUtf8ConversationWindows(
                    &reader,
                    conversation.result_header_size,
                    result.content_length,
                );
            },
            .user_text, .assistant_text, .context_checkpoint => try validateUtf8ConversationWindows(&reader, 0, reader.length()),
        }
    }

    pub fn readEntry(self: *Session, sequence: u64) !ConversationEntry {
        if (!self.open) return error.SessionClosed;
        if (sequence == 0 or sequence > self.resident.conversation_head_id) {
            return error.InvalidEntrySequence;
        }
        return self.loadEntry(sequence);
    }

    fn loadEntry(self: *Session, sequence: u64) !ConversationEntry {
        const stored = try self.storage.readConversationEntry(self.session_id, sequence);
        const kind = std.enums.fromInt(EntryKind, stored.kind) orelse return error.UnsupportedConversationKind;
        return .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = stored.entry_id,
            .parent_id = stored.parent_id,
            .task_id = self.task_id,
            .content_ref = stored.content_ref,
            .sequence = stored.entry_id,
        };
    }

    pub fn storeBlob(
        self: *Session,
        reference: u64,
        bytes: []const u8,
    ) !void {
        try self.ensureUsable();
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        defer blobs.close(self.io);
        blob_store.put(blobs, self.io, reference, bytes) catch |err| {
            self.failed = true;
            return err;
        };
    }

    pub fn beginBlob(
        self: *Session,
        reference: u64,
    ) !BlobWriter {
        try self.ensureUsable();
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        errdefer blobs.close(self.io);
        const writer = try blob_store.Writer.begin(blobs, self.io, reference);
        return .{ .session = self, .blobs = blobs, .writer = writer };
    }

    pub fn readBlob(
        self: *Session,
        reference: u64,
        offset: u64,
        out: []u8,
    ) ![]const u8 {
        try self.ensureUsable();
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        defer blobs.close(self.io);
        return blob_store.readWindow(blobs, self.io, reference, offset, out);
    }

    pub fn openBlob(
        self: *Session,
        reference: u64,
    ) !BlobReader {
        try self.ensureUsable();
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        errdefer blobs.close(self.io);
        const reader = try blob_store.Reader.openIn(blobs, self.io, reference);
        return .{ .io = self.io, .blobs = blobs, .reader = reader };
    }

    pub fn commitSemantic(
        self: *Session,
        facts: []const session_transition.Fact,
        encoded_core: ?[]const u8,
    ) !u64 {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        if (facts.len == 0 or facts.len > session_transition.max_facts) {
            return error.InvalidSemanticFactCount;
        }
        if (self.resident.semantic.last_sequence == std.math.maxInt(u64)) {
            return error.SessionSequenceExhausted;
        }
        if (encoded_core) |bytes| {
            if (bytes.len != core_state.encoded_size) return error.InvalidCoreStateLength;
            _ = try core_state.decode(bytes);
        }
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        defer blobs.close(self.io);
        for (facts) |fact| {
            if (fact.kind() == .conversation_advanced) {
                try self.validatePreparedConversationEntry(fact);
            }
            try self.validatePreparedBlobReferences(blobs, fact);
        }

        var transaction: session_transition.Transaction = .{
            .sequence = self.resident.semantic.last_sequence + 1,
            .fact_count = @intCast(facts.len),
            .core = if (encoded_core) |bytes| bytes[0..core_state.encoded_size].* else null,
        };
        @memcpy(transaction.facts[0..facts.len], facts);
        const next = try self.resident.applyingLedger(
            transaction,
            self.agent_id,
            self.ownership_epoch,
        );

        const final_sequence = try self.storage.commit(self.ownerToken(), transaction);
        std.debug.assert(final_sequence == transaction.sequence);
        self.resident = next;
        for (facts) |fact| switch (fact) {
            .conversation_advanced => self.pending_conversation = null,
            .task_admitted,
            .operation_submitted,
            .operation_accepted,
            .attempt_admitted,
            .authorization,
            .result,
            .outcome,
            .cancellation,
            .shutdown,
            .result_applied,
            .approval_required,
            => {},
        };
        return final_sequence;
    }

    fn validatePreparedBlobReferences(
        self: *Session,
        blobs: std.Io.Dir,
        fact: session_transition.Fact,
    ) !void {
        switch (fact) {
            .task_admitted => |value| try validateBlob(blobs, self.io, value.content_ref),
            .operation_submitted, .operation_accepted => |value| try validateBlob(
                blobs,
                self.io,
                value.descriptor_ref,
            ),
            .attempt_admitted => |value| try validateBlob(blobs, self.io, value.descriptor_ref),
            .authorization => |value| try validateBlob(blobs, self.io, value.permission_ref),
            .result => |value| try validateBlob(blobs, self.io, value.result_ref),
            // validatePreparedConversationEntry opens the Conversation blob,
            // verifies its SHA-256 envelope, and validates its semantics.
            .conversation_advanced => {},
            .outcome => |value| try validateBlob(blobs, self.io, value.content_ref),
            .result_applied => |value| try validateBlob(blobs, self.io, value.result_ref),
            .approval_required => |value| {
                try validateBlob(blobs, self.io, value.binding_ref);
                try validateBlob(blobs, self.io, value.descriptor_ref);
            },
            .cancellation, .shutdown => {},
        }
    }

    pub fn inspectSemantic(
        self: *Session,
        context: *anyopaque,
        apply: *const fn (*anyopaque, session_transition.Fact) anyerror!void,
    ) !LedgerView {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        try self.resident.semantic.emitFacts(context, apply);
        const view: LedgerView = .{
            .last_sequence = self.resident.semantic.last_sequence,
            .last_core = self.resident.semantic.last_core,
        };
        return view;
    }

    pub fn recoverSemanticWindow(
        self: *Session,
        frame_budget: u8,
    ) !RecoveryProgress {
        try self.ensureUsable();
        if (frame_budget == 0) return error.InvalidRecoveryQuantum;
        if (self.recovery == .ready) return .{ .processed = 0, .more = false };
        if (self.recovery == .pending) {
            self.resident = .{};
            self.recovery = .{ .ledger = .{
                .next_sequence = 1,
                .ledger_head = try self.storage.sessionHead(self.session_id),
                .inbox_watermark = try self.storage.completionHead(self.session_id),
            } };
        }
        var processed: u8 = 0;
        while (processed < frame_budget) {
            switch (self.recovery) {
                .ready => return .{ .processed = processed, .more = false },
                .pending => unreachable,
                .ledger => |cursor| {
                    if (cursor.next_sequence > cursor.ledger_head) {
                        self.recovery = .{ .inbox = .{
                            .after_id = 0,
                            .watermark = cursor.inbox_watermark,
                            .ledger_head = cursor.ledger_head,
                        } };
                        continue;
                    }
                    var stored: host_store.StoredTransition = undefined;
                    try self.storage.readTransition(
                        self.session_id,
                        cursor.next_sequence,
                        &stored,
                    );
                    const transaction = stored.transaction;
                    for (transaction.factSlice()) |fact| switch (fact) {
                        .conversation_advanced => |advanced| try self.verifyConversationEntry(advanced),
                        .task_admitted,
                        .operation_submitted,
                        .operation_accepted,
                        .attempt_admitted,
                        .authorization,
                        .result,
                        .outcome,
                        .cancellation,
                        .shutdown,
                        .result_applied,
                        .approval_required,
                        => {},
                    };
                    self.resident = try self.resident.applyingLedger(
                        transaction,
                        self.agent_id,
                        self.ownership_epoch,
                    );
                    self.recovery = .{ .ledger = .{
                        .next_sequence = cursor.next_sequence + 1,
                        .ledger_head = cursor.ledger_head,
                        .inbox_watermark = cursor.inbox_watermark,
                    } };
                    processed += 1;
                },
                .inbox => |cursor| {
                    if (cursor.after_id >= cursor.watermark) {
                        self.recovery = .ready;
                        continue;
                    }
                    const stored = (try self.storage.readCompletionAfter(
                        self.session_id,
                        cursor.after_id,
                        cursor.watermark,
                    )) orelse {
                        self.recovery = .ready;
                        continue;
                    };
                    const prepared = try self.resident.applyingCompletion(
                        stored.envelope,
                        self.session_id,
                        self.agent_id,
                        self.ownership_epoch,
                    );
                    switch (prepared.disposition) {
                        .irrelevant => {
                            self.resident = prepared.state;
                            self.recovery = .{ .historical = .{
                                .completion = stored,
                                .watermark = cursor.watermark,
                                .ledger_head = cursor.ledger_head,
                                .scan = .{},
                            } };
                        },
                        .audit => |terminal_sequence| {
                            _ = try self.storage.publishAuditedCompletion(
                                stored.envelope,
                                terminal_sequence,
                            );
                            self.resident = prepared.state;
                            self.recovery = .{ .inbox = .{
                                .after_id = stored.inbox_id,
                                .watermark = cursor.watermark,
                                .ledger_head = cursor.ledger_head,
                            } };
                        },
                        .duplicate, .persist => {
                            self.resident = prepared.state;
                            self.recovery = .{ .inbox = .{
                                .after_id = stored.inbox_id,
                                .watermark = cursor.watermark,
                                .ledger_head = cursor.ledger_head,
                            } };
                        },
                    }
                    processed += 1;
                },
                .historical => |cursor| {
                    var scan = cursor.scan;
                    const scanned = try self.storage.scanCompletedAttemptWindow(
                        self.session_id,
                        cursor.completion.envelope.operation_id,
                        cursor.completion.envelope.operation_generation,
                        cursor.completion.envelope.attempt_id,
                        cursor.ledger_head,
                        frame_budget - processed,
                        &scan,
                    );
                    if (scanned == 0) return error.InvalidHistoricalScanProgress;
                    processed += scanned;
                    if (scan.done()) {
                        if (scan.result()) |completed| {
                            const terminal_sequence = try self.validateHistoricalCompletion(
                                cursor.completion.envelope,
                                completed,
                            );
                            _ = try self.storage.publishAuditedCompletion(
                                cursor.completion.envelope,
                                terminal_sequence,
                            );
                        }
                        self.recovery = .{ .inbox = .{
                            .after_id = cursor.completion.inbox_id,
                            .watermark = cursor.watermark,
                            .ledger_head = cursor.ledger_head,
                        } };
                    } else {
                        self.recovery = .{ .historical = .{
                            .completion = cursor.completion,
                            .watermark = cursor.watermark,
                            .ledger_head = cursor.ledger_head,
                            .scan = scan,
                        } };
                    }
                },
            }
        }
        switch (self.recovery) {
            .ledger => |cursor| if (cursor.next_sequence > cursor.ledger_head and
                cursor.inbox_watermark == 0)
            {
                self.recovery = .ready;
                return .{ .processed = processed, .more = false };
            },
            .inbox => |cursor| if (cursor.after_id >= cursor.watermark) {
                self.recovery = .ready;
                return .{ .processed = processed, .more = false };
            },
            .historical => {},
            .ready => return .{ .processed = processed, .more = false },
            .pending => unreachable,
        }
        return .{ .processed = processed, .more = true };
    }

    pub fn publishCompletionEvidence(
        self: *Session,
        envelope: completion_inbox.Envelope,
    ) !void {
        try self.ensureUsable();
        try completion_inbox.validate(envelope);
        if (envelope.session_id != self.session_id or envelope.agent_id != self.agent_id) {
            return error.CompletionIdentityMismatch;
        }
        if (envelope.ownership_epoch > self.ownership_epoch) return error.FutureCompletionEpoch;
        var result = try self.openBlob(envelope.result_ref);
        result.close();
        const prepared = try self.resident.applyingCompletion(
            envelope,
            self.session_id,
            self.agent_id,
            self.ownership_epoch,
        );
        switch (prepared.disposition) {
            .irrelevant => {
                const terminal_sequence = try self.historicalAuditSequence(envelope) orelse return;
                _ = try self.storage.publishAuditedCompletion(envelope, terminal_sequence);
            },
            .duplicate => return,
            .audit => |terminal_sequence| {
                _ = try self.storage.publishAuditedCompletion(
                    envelope,
                    terminal_sequence,
                );
            },
            .persist => {
                _ = try self.storage.publishCompletion(envelope);
                self.resident = prepared.state;
            },
        }
    }

    fn historicalAuditSequence(
        self: *Session,
        envelope: completion_inbox.Envelope,
    ) !?u64 {
        var scan: host_store.CompletedAttemptScan = .{};
        const ledger_head = try self.storage.sessionHead(self.session_id);
        while (!scan.done()) {
            const scanned = try self.storage.scanCompletedAttemptWindow(
                self.session_id,
                envelope.operation_id,
                envelope.operation_generation,
                envelope.attempt_id,
                ledger_head,
                std.math.maxInt(u8),
                &scan,
            );
            if (scanned == 0) return error.InvalidHistoricalScanProgress;
        }
        const completed = scan.result() orelse return null;
        return @as(?u64, try self.validateHistoricalCompletion(envelope, completed));
    }

    fn validateHistoricalCompletion(
        self: *Session,
        envelope: completion_inbox.Envelope,
        completed: host_store.CompletedAttempt,
    ) !u64 {
        _ = self;
        const attempt = completed.attempt;
        if (attempt.operation.agent.agent_id != envelope.agent_id or
            attempt.operation.agent.agent_generation != envelope.agent_generation)
        {
            return error.CompletionIdentityMismatch;
        }
        if (attempt.operation.agent.ownership_epoch != envelope.ownership_epoch) {
            return error.CompletionAttemptEpochMismatch;
        }
        if (std.meta.activeTag(attempt.descriptor_digest) != envelope.kind) {
            return error.CompletionEvidenceKindMismatch;
        }
        return completed.terminal_result_sequence;
    }

    pub fn scanCompletionEvidence(
        self: *Session,
        context: *anyopaque,
        apply: *const fn (*anyopaque, completion_inbox.Envelope) anyerror!void,
    ) !u32 {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        var count: u32 = 0;
        for (self.resident.inbox.entries) |maybe_envelope| {
            if (maybe_envelope) |envelope| try apply(context, envelope);
            if (maybe_envelope != null) count += 1;
        }
        return count;
    }

    pub fn close(self: *Session) void {
        if (!self.open) return;
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.dir.close(self.io);
        self.open = false;
    }
};

pub fn formatId(session_id: u64, buffer: *[16]u8) ![]const u8 {
    if (session_id == 0) return error.InvalidIdentity;
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{session_id});
}

fn sessionName(session_id: u64, buffer: *[16]u8) []const u8 {
    return formatId(session_id, buffer) catch unreachable;
}

fn syncDir(dir: std.Io.Dir, io: std.Io) !void {
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
}

fn validateBlob(blobs: std.Io.Dir, io: std.Io, reference: u64) !void {
    if (reference == 0) return;
    _ = blob_store.metadata(blobs, io, reference) catch |err| switch (err) {
        error.FileNotFound => return error.MissingBlobReference,
        else => return err,
    };
}

fn validateWorkspace(io: std.Io, path: []const u8) !void {
    var workspace = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch return error.WorkspaceUnavailable
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch return error.WorkspaceUnavailable;
    defer workspace.close(io);

    if (workspace.openDir(io, ".git", .{})) |git_dir_value| {
        var git_dir = git_dir_value;
        defer git_dir.close(io);
        try validateGitDir(git_dir, io, false);
        return;
    } else |_| {}

    var marker = workspace.openFile(io, ".git", .{}) catch return error.NotGitWorktree;
    defer marker.close(io);
    const stat = marker.stat(io) catch return error.NotGitWorktree;
    if (stat.size == 0 or stat.size > 1024) return error.NotGitWorktree;
    var marker_buffer: [1024]u8 = undefined;
    const length: usize = @intCast(stat.size);
    const actual = marker.readPositionalAll(io, marker_buffer[0..length], 0) catch
        return error.NotGitWorktree;
    if (actual != length) return error.NotGitWorktree;
    const value = std.mem.trim(u8, marker_buffer[0..length], " \t\r\n");
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) {
        return error.NotGitWorktree;
    }
    const git_path = value[prefix.len..];
    var git_dir = if (std.fs.path.isAbsolute(git_path))
        std.Io.Dir.openDirAbsolute(io, git_path, .{}) catch return error.NotGitWorktree
    else
        workspace.openDir(io, git_path, .{}) catch return error.NotGitWorktree;
    defer git_dir.close(io);
    try validateGitDir(git_dir, io, true);
}

fn validateGitDir(git_dir: std.Io.Dir, io: std.Io, linked: bool) !void {
    var buffer: [1024]u8 = undefined;
    const head = readSmallFile(git_dir, io, "HEAD", &buffer) catch return error.NotGitWorktree;
    const symbolic = std.mem.startsWith(u8, head, "ref: refs/") and head.len > "ref: refs/".len;
    var detached = head.len == 40 or head.len == 64;
    for (head) |byte| detached = detached and std.ascii.isHex(byte);
    if (!symbolic and !detached) return error.NotGitWorktree;
    if (linked) {
        const common_path = readSmallFile(git_dir, io, "commondir", &buffer) catch
            return error.NotGitWorktree;
        var common = if (std.fs.path.isAbsolute(common_path))
            std.Io.Dir.openDirAbsolute(io, common_path, .{}) catch return error.NotGitWorktree
        else
            git_dir.openDir(io, common_path, .{}) catch return error.NotGitWorktree;
        defer common.close(io);
        try validateGitCommon(common, io);
        return;
    }
    try validateGitCommon(git_dir, io);
}

fn validateGitCommon(git_dir: std.Io.Dir, io: std.Io) !void {
    git_dir.access(io, "config", .{}) catch return error.NotGitWorktree;
    var objects = git_dir.openDir(io, "objects", .{}) catch return error.NotGitWorktree;
    objects.close(io);
    var refs = git_dir.openDir(io, "refs", .{}) catch return error.NotGitWorktree;
    refs.close(io);
}

fn readSmallFile(dir: std.Io.Dir, io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > buffer.len) return error.InvalidControlFile;
    const length: usize = @intCast(stat.size);
    const actual = try file.readPositionalAll(io, buffer[0..length], 0);
    if (actual != length) return error.TruncatedControlFile;
    return std.mem.trim(u8, buffer[0..length], " \t\r\n");
}

fn testConfig(workspace_path: []const u8, session_id: u64) CreateConfig {
    return .{
        .identities = .{
            .session_id = session_id,
            .agent_id = session_id + 1,
            .task_id = session_id + 2,
            .branch_id = session_id + 3,
        },
        .workspace_path = workspace_path,
        .model = "fixture:repair",
        .task = "Fix the failing test",
    };
}

fn initTestGitWorktree(dir: std.Io.Dir, io: std.Io) !void {
    try dir.createDir(io, ".git", .default_dir);
    var git_dir = try dir.openDir(io, ".git", .{});
    defer git_dir.close(io);
    try git_dir.createDir(io, "objects", .default_dir);
    try git_dir.createDir(io, "refs", .default_dir);
    var config = try git_dir.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git_dir.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);
}

test "Session creation rejects a non-UTF-8 model identity" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var config = testConfig(layout.workspacePath(), 15);
    config.model = "fixture:\xff";
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(layout.sessions, &layout.storage, io, config),
    );
}

test "Session creation enforces recoverable root task content" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var exact_task: [conversation.max_result_content_size]u8 = @splat('x');
    var exact = testConfig(layout.workspacePath(), 20);
    exact.task = &exact_task;
    var created = try Session.createExact(layout.sessions, &layout.storage, io, exact);
    created.close();
    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 20);
    defer restored.session.close();
    const recovered = try restored.session.recoverSemanticWindow(8);
    try std.testing.expect(!recovered.more);
    try std.testing.expectEqual(@as(u64, 1), restored.session.entryCount());

    var oversized_task: [conversation.max_result_content_size + 1]u8 = @splat('x');
    var oversized = testConfig(layout.workspacePath(), 30);
    oversized.task = &oversized_task;
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(layout.sessions, &layout.storage, io, oversized),
    );
    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        layout.sessions.access(io, sessionName(30, &name_buffer), .{}),
    );

    var invalid_utf8 = testConfig(layout.workspacePath(), 40);
    invalid_utf8.task = "\xff";
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(layout.sessions, &layout.storage, io, invalid_utf8),
    );
    try std.testing.expectError(
        error.FileNotFound,
        layout.sessions.access(io, sessionName(40, &name_buffer), .{}),
    );
}

test "Session startup removes drafts and does not infer Completion from a sealed orphan" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 25),
    );
    var sealed = try created.beginBlob(90);
    try sealed.append("sealed before ledger admission");
    try sealed.finish();
    const Ignore = struct {
        fn apply(_: *anyopaque, _: completion_inbox.Envelope) !void {}
    };
    var context: u8 = 0;
    try std.testing.expectEqual(
        @as(u32, 0),
        try created.scanCompletionEvidence(&context, Ignore.apply),
    );

    var interrupted = try created.beginBlob(91);
    try interrupted.append("partial provisional bytes");
    interrupted.writer.file.close(io);
    interrupted.writer.open = false;
    interrupted.blobs.close(io);
    interrupted.open = false; // Simulate process loss before ProviderIo.close.
    created.close();

    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 25);
    defer restored.session.close();
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "sealed before ledger admission",
        try restored.session.readBlob(90, 0, &bytes),
    );
    try std.testing.expectError(error.FileNotFound, restored.session.readBlob(91, 0, &bytes));
}

test "failed blob seal remains unpublished" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 26),
    );
    defer created.close();

    var candidate = try created.beginBlob(92);
    try candidate.append("complete candidate bytes");
    candidate.writer.file.close(io);
    if (candidate.finish()) |_| {
        return error.ExpectedBlobSealFailure;
    } else |_| {}
    // The test closed the raw file to inject the write failure. Mark that
    // injected resource closed before the wrapper releases its directory.
    candidate.writer.open = false;
    candidate.abort();
    var bytes: [1]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, created.readBlob(92, 0, &bytes));
}

const TestLayout = struct {
    tmp: std.testing.TmpDir,
    storage: host_store.StorageOwner,
    sessions: std.Io.Dir,
    workspace: std.Io.Dir,
    workspace_path: [128]u8,
    workspace_path_len: u8,

    fn init(io: std.Io) !TestLayout {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "sessions", .default_dir);
        try tmp.dir.createDir(io, "repo", .default_dir);
        var workspace = try tmp.dir.openDir(io, "repo", .{});
        errdefer workspace.close(io);
        try initTestGitWorktree(workspace, io);
        const sessions = try tmp.dir.openDir(io, "sessions", .{});
        var database_path: [128]u8 = undefined;
        const rendered_database_path = try std.fmt.bufPrint(
            &database_path,
            ".zig-cache/tmp/{s}/host.sqlite3",
            .{tmp.sub_path},
        );
        const storage = try host_store.StorageOwner.open(io, rendered_database_path, .{});
        var workspace_path: [128]u8 = undefined;
        const rendered = try std.fmt.bufPrint(
            &workspace_path,
            ".zig-cache/tmp/{s}/repo",
            .{tmp.sub_path},
        );
        return .{
            .tmp = tmp,
            .storage = storage,
            .sessions = sessions,
            .workspace = workspace,
            .workspace_path = workspace_path,
            .workspace_path_len = @intCast(rendered.len),
        };
    }

    fn workspacePath(self: *const TestLayout) []const u8 {
        return self.workspace_path[0..self.workspace_path_len];
    }

    fn deinit(self: *TestLayout, io: std.Io) void {
        self.storage.close();
        self.sessions.close(io);
        self.workspace.close(io);
        self.tmp.cleanup();
    }
};

fn testDescriptor(label: []const u8) binding.Descriptor {
    return .{ .model = binding.hash(binding.ModelDescriptor, label) };
}

fn testResultDigest(label: []const u8) binding.Result {
    return binding.hash(binding.Result, label);
}

fn testReboundEnvelope(envelope: completion_inbox.Envelope) completion_inbox.Envelope {
    return completion_inbox.bind(.{
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

fn testEffectAttempt(
    kind: binding.DescriptorKind,
    operation: session_transition.OperationContext,
    attempt_id: u64,
    descriptor_ref: u64,
    descriptor: binding.Descriptor,
    possible_duplicate_attempts: u8,
) session_transition.Fact {
    return switch (kind) {
        .model => session_transition.modelAttemptAdmitted(
            operation,
            attempt_id,
            descriptor_ref,
            descriptor,
            possible_duplicate_attempts,
        ),
        .bash, .apply_patch => session_transition.consequentialAttemptAdmitted(
            operation,
            attempt_id,
            descriptor_ref,
            descriptor,
        ),
    };
}

fn testDurableEvidence(
    kind: binding.DescriptorKind,
    attempt_id: u64,
) session_transition.DurableResultEvidence {
    return switch (kind) {
        .model => .{ .model = attempt_id },
        .bash => .{ .bash = attempt_id },
        .apply_patch => .{ .apply_patch = attempt_id },
    };
}

const TestCurrentOperation = struct {
    operation_id: u64 = 0,
    attempt_id: u64 = 0,

    fn apply(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *TestCurrentOperation = @ptrCast(@alignCast(context));
        switch (fact) {
            .operation_submitted => |record| self.operation_id = record.operation.operation_id,
            .attempt_admitted => |record| self.attempt_id = record.attempt_id,
            else => {},
        }
    }
};

test "create and exact resume preserve distinct identities and one owner" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 10));
    const first_token = created.ownerToken();
    var id_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000000a", try formatId(created.session_id, &id_buffer));
    try std.testing.expectEqual(@as(u64, 1), first_token.epoch);
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
    try std.testing.expectEqual(@as(u64, 1), created.entryCount());

    try std.testing.expectError(
        error.SessionBusy,
        Session.openExisting(layout.sessions, &layout.storage, io, 10),
    );
    const live_resident = created.resident;
    created.close();

    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 10);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 2), restored.session.ownership_epoch);
    var expected_workspace: [workspace_path_capacity]u8 = undefined;
    const expected_workspace_length = try std.Io.Dir.cwd().realPathFile(
        io,
        layout.workspacePath(),
        &expected_workspace,
    );
    try std.testing.expectEqualStrings(
        expected_workspace[0..expected_workspace_length],
        restored.session.workspacePath(),
    );
    try std.testing.expectEqualDeep(Projection{
        .session_id = 10,
        .task_id = 12,
        .active_leaf_id = 0,
        .ownership_epoch = 2,
    }, restored.session.projection());
    try std.testing.expectError(error.StaleOwner, restored.session.authorize(first_token));
    try restored.session.authorize(restored.session.ownerToken());
    const recovered = try restored.session.recoverSemanticWindow(8);
    try std.testing.expect(!recovered.more);
    try std.testing.expectEqualDeep(live_resident, restored.session.resident);

    const root = try restored.session.readEntry(1);
    try std.testing.expectEqual(EntryKind.user_text, root.kind);
    try std.testing.expectEqual(@as(u64, 0), root.parent_id);
    try std.testing.expectEqual(restored.session.task_id, root.content_ref);
    var task_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Fix the failing test",
        try restored.session.readBlob(root.content_ref, 0, &task_buffer),
    );
}

test "future ownership epochs never enter the durable Completion Inbox" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 15));
    defer created.close();
    const token = created.ownerToken();
    try created.storeBlob(99, "future result");
    try std.testing.expectError(error.FutureCompletionEpoch, created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch + 1,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 101,
        .result_ref = 99,
        .result_digest = testResultDigest("102"),
    })));
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));

    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 101,
        .result_ref = 99,
        .result_digest = testResultDigest("102"),
    }));
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));
}

test "Completion evidence must match the admitted Attempt ownership epoch for every effect kind" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        kind: completion_inbox.EvidenceKind,
        operation_id: u64,
        descriptor: binding.Descriptor,
        recovery_class: session_transition.RecoveryClass,
    }{
        .{
            .kind = .model,
            .operation_id = 100,
            .descriptor = .{ .model = binding.hash(binding.ModelDescriptor, "epoch-model") },
            .recovery_class = .model,
        },
        .{
            .kind = .bash,
            .operation_id = (@as(u64, 1) << 63) | 101,
            .descriptor = .{ .bash = binding.hash(binding.BashDescriptor, "epoch-bash") },
            .recovery_class = .consequential,
        },
        .{
            .kind = .apply_patch,
            .operation_id = (@as(u64, 1) << 63) | 102,
            .descriptor = .{ .apply_patch = binding.hash(binding.PatchIntent, "epoch-patch") },
            .recovery_class = .consequential,
        },
    };

    for (cases, 0..) |case, index| {
        const session_id: u64 = 20 + @as(u64, @intCast(index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        const attempt_epoch = created.ownership_epoch;
        const operation: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = attempt_epoch,
            },
            .operation_id = case.operation_id,
            .generation = 1,
        };
        const descriptor_ref = 200 + index;
        const attempt_id = 210 + index;
        const first_result_ref = 220 + index;
        try created.storeBlob(descriptor_ref, "epoch descriptor");
        try created.storeBlob(first_result_ref, "first evidence");
        const admitted = if (case.recovery_class == .model)
            session_transition.modelAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
                0,
            )
        else
            session_transition.consequentialAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
            );
        _ = try created.commitSemantic(&.{
            session_transition.operationSubmitted(
                operation,
                descriptor_ref,
                case.descriptor,
                .none,
            ),
            admitted,
        }, null);
        const first = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = attempt_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = case.operation_id,
            .operation_generation = 1,
            .attempt_id = attempt_id,
            .result_ref = first_result_ref,
            .result_digest = testResultDigest("first epoch evidence"),
        });
        try created.publishCompletionEvidence(first);
        const first_inbox_id = try layout.storage.completionHead(created.session_id);
        if (first_inbox_id == 0) return error.CompletionNotPublished;
        created.close();

        var restored = (try Session.openExisting(
            layout.sessions,
            &layout.storage,
            io,
            session_id,
        )).session;
        while ((try restored.recoverSemanticWindow(32)).more) {}
        const conflicting_result_ref = 230 + index;
        try restored.storeBlob(conflicting_result_ref, "cross epoch evidence");
        const cross_epoch = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = restored.session_id,
            .ownership_epoch = restored.ownership_epoch,
            .agent_id = restored.agent_id,
            .agent_generation = 1,
            .operation_id = case.operation_id,
            .operation_generation = 1,
            .attempt_id = attempt_id,
            .result_ref = conflicting_result_ref,
            .result_digest = testResultDigest("cross epoch evidence"),
        });
        try std.testing.expectError(
            error.CompletionAttemptEpochMismatch,
            restored.publishCompletionEvidence(cross_epoch),
        );
        try std.testing.expectEqual(first_inbox_id, try layout.storage.completionHead(session_id));
        try std.testing.expectEqualDeep(
            first,
            (try layout.storage.readCompletion(session_id, first_inbox_id)).envelope,
        );
        restored.close();
    }
}

test "live Completion publication rejects Bash and Patch evidence kind swaps" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        descriptor: binding.Descriptor,
        result_evidence: session_transition.DurableResultEvidence,
        correct_kind: completion_inbox.EvidenceKind,
        wrong_kind: completion_inbox.EvidenceKind,
    }{
        .{
            .descriptor = .{ .bash = binding.hash(binding.BashDescriptor, "live-bash") },
            .result_evidence = .{ .bash = 320 },
            .correct_kind = .bash,
            .wrong_kind = .apply_patch,
        },
        .{
            .descriptor = .{ .apply_patch = binding.hash(binding.PatchIntent, "live-patch") },
            .result_evidence = .{ .apply_patch = 321 },
            .correct_kind = .apply_patch,
            .wrong_kind = .bash,
        },
    };

    for (cases, 0..) |case, index| {
        const session_id = 60 + @as(u64, @intCast(index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        defer created.close();
        const operation: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = (@as(u64, 1) << 63) | 300 + index,
            .generation = 1,
        };
        const descriptor_ref = 310 + index;
        const attempt_id = 320 + index;
        const result_ref = 330 + index;
        try created.storeBlob(descriptor_ref, "descriptor");
        try created.storeBlob(result_ref, "wrong-kind result");
        _ = try created.commitSemantic(&.{
            session_transition.operationSubmitted(
                operation,
                descriptor_ref,
                case.descriptor,
                .none,
            ),
            session_transition.consequentialAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
            ),
        }, null);
        try created.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = case.correct_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("wrong-kind result"),
        }));
        const correct_inbox_id = try layout.storage.completionHead(session_id);
        _ = try created.commitSemantic(&.{session_transition.result(.{
            .operation = operation,
            .result_ref = result_ref,
            .result_digest = testResultDigest("wrong-kind result"),
            .class = .ordinary,
            .evidence = .{ .durable = case.result_evidence },
        })}, null);
        const wrong = completion_inbox.bind(.{
            .kind = case.wrong_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("wrong-kind result"),
        });
        try std.testing.expectError(
            error.CompletionEvidenceKindMismatch,
            created.publishCompletionEvidence(wrong),
        );
        try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(session_id));
        try std.testing.expectError(
            error.CompletionNotFound,
            layout.storage.readCompletion(session_id, correct_inbox_id + 1),
        );
    }
}

test "lost Completion notification recovery rejects Bash and Patch evidence kind swaps" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        descriptor: binding.Descriptor,
        result_evidence: session_transition.DurableResultEvidence,
        correct_kind: completion_inbox.EvidenceKind,
        wrong_kind: completion_inbox.EvidenceKind,
    }{
        .{
            .descriptor = .{ .bash = binding.hash(binding.BashDescriptor, "recovery-bash") },
            .result_evidence = .{ .bash = 420 },
            .correct_kind = .bash,
            .wrong_kind = .apply_patch,
        },
        .{
            .descriptor = .{ .apply_patch = binding.hash(binding.PatchIntent, "recovery-patch") },
            .result_evidence = .{ .apply_patch = 421 },
            .correct_kind = .apply_patch,
            .wrong_kind = .bash,
        },
    };

    for (cases, 0..) |case, index| {
        const session_id = 80 + @as(u64, @intCast(index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        const operation: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = (@as(u64, 1) << 63) | 400 + index,
            .generation = 1,
        };
        const descriptor_ref = 410 + index;
        const attempt_id = 420 + index;
        const result_ref = 430 + index;
        try created.storeBlob(descriptor_ref, "descriptor");
        try created.storeBlob(result_ref, "lost wrong-kind result");
        _ = try created.commitSemantic(&.{
            session_transition.operationSubmitted(
                operation,
                descriptor_ref,
                case.descriptor,
                .none,
            ),
            session_transition.consequentialAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
            ),
        }, null);
        try created.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = case.correct_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("lost wrong-kind result"),
        }));
        _ = try created.commitSemantic(&.{session_transition.result(.{
            .operation = operation,
            .result_ref = result_ref,
            .result_digest = testResultDigest("lost wrong-kind result"),
            .class = .ordinary,
            .evidence = .{ .durable = case.result_evidence },
        })}, null);
        const wrong = completion_inbox.bind(.{
            .kind = case.wrong_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("lost wrong-kind result"),
        });
        const inbox_id = try layout.storage.publishCompletion(wrong);
        created.close();

        var restored = (try Session.openExisting(
            layout.sessions,
            &layout.storage,
            io,
            session_id,
        )).session;
        defer restored.close();
        try std.testing.expectError(
            error.CompletionEvidenceKindMismatch,
            restored.recoverSemanticWindow(32),
        );
        for (restored.resident.inbox.entries) |entry| try std.testing.expect(entry == null);
        const pending = try layout.storage.readCompletion(session_id, inbox_id);
        try std.testing.expect(pending.consumed_by_sequence == null);
        try std.testing.expectEqual(inbox_id, try layout.storage.completionHead(session_id));
    }
}

test "late evidence audits against the first terminal Result sequence" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 55));
    defer created.close();
    const operation: session_transition.OperationContext = .{
        .agent = .{
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
        },
        .operation_id = 100,
        .generation = 1,
    };
    const descriptor = testDescriptor("terminal sequence descriptor");
    try created.storeBlob(201, "descriptor");
    try created.storeBlob(202, "winning result");
    try created.storeBlob(203, "later outcome");
    try created.storeBlob(204, "late result");
    _ = try created.commitSemantic(&.{
        session_transition.operationSubmitted(operation, 201, descriptor, .none),
        session_transition.modelAttemptAdmitted(operation, 211, 201, descriptor, 0),
        session_transition.modelAttemptAdmitted(operation, 212, 201, descriptor, 1),
    }, null);
    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = operation.agent.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = operation.operation_id,
        .operation_generation = operation.generation,
        .attempt_id = 212,
        .result_ref = 202,
        .result_digest = testResultDigest("winning result"),
    }));
    const terminal_sequence = try created.commitSemantic(&.{session_transition.result(.{
        .operation = operation,
        .result_ref = 202,
        .result_digest = testResultDigest("winning result"),
        .class = .ordinary,
        .evidence = .{ .durable = .{ .model = 212 } },
    })}, null);
    _ = try created.commitSemantic(&.{session_transition.outcome(
        operation.agent,
        301,
        203,
    )}, null);

    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = operation.agent.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = operation.operation_id,
        .operation_generation = operation.generation,
        .attempt_id = 211,
        .result_ref = 204,
        .result_digest = testResultDigest("late result"),
    }));
    const audited = try layout.storage.readCompletion(created.session_id, 2);
    try std.testing.expectEqual(terminal_sequence, audited.consumed_by_sequence.?);
}

test "late evidence for a prior Operation audits through durable history" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        kind: binding.DescriptorKind,
        recovery_class: session_transition.RecoveryClass,
        descriptor_a: binding.Descriptor,
        descriptor_b: binding.Descriptor,
        wrong_kind: binding.DescriptorKind,
    }{
        .{
            .kind = .model,
            .recovery_class = .model,
            .descriptor_a = .{ .model = binding.hash(binding.ModelDescriptor, "prior-model-a") },
            .descriptor_b = .{ .model = binding.hash(binding.ModelDescriptor, "current-model-b") },
            .wrong_kind = .bash,
        },
        .{
            .kind = .bash,
            .recovery_class = .consequential,
            .descriptor_a = .{ .bash = binding.hash(binding.BashDescriptor, "prior-bash-a") },
            .descriptor_b = .{ .bash = binding.hash(binding.BashDescriptor, "current-bash-b") },
            .wrong_kind = .apply_patch,
        },
    };

    for (cases, 0..) |case, case_index| {
        const session_id = 110 + @as(u64, @intCast(case_index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        errdefer created.close();
        const operation_base: u64 = if (case.kind == .model) 500 else (@as(u64, 1) << 63) | 500;
        const operation_a: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = operation_base + @as(u64, @intCast(case_index)) * 10,
            .generation = 1,
        };
        const operation_b: session_transition.OperationContext = .{
            .agent = operation_a.agent,
            .operation_id = operation_a.operation_id + 1,
            .generation = 1,
        };
        const descriptor_a_ref: u64 = 510 + @as(u64, @intCast(case_index)) * 20;
        const descriptor_b_ref = descriptor_a_ref + 1;
        const winner_attempt = descriptor_a_ref + 2;
        const live_attempt = descriptor_a_ref + 3;
        const recovery_attempt = descriptor_a_ref + 4;
        const wrong_epoch_attempt = descriptor_a_ref + 5;
        const wrong_kind_attempt = descriptor_a_ref + 6;
        const current_attempt = descriptor_a_ref + 7;
        const winner_result_ref = descriptor_a_ref + 8;
        const live_result_ref = descriptor_a_ref + 9;
        const recovery_result_ref = descriptor_a_ref + 10;
        const conflict_result_ref = descriptor_a_ref + 11;
        try created.storeBlob(descriptor_a_ref, "prior descriptor");
        try created.storeBlob(descriptor_b_ref, "current descriptor");
        try created.storeBlob(winner_result_ref, "winning result");
        try created.storeBlob(live_result_ref, "live late result");
        try created.storeBlob(recovery_result_ref, "recovered late result");
        try created.storeBlob(conflict_result_ref, "conflicting late result");

        var admission: [6]session_transition.Fact = undefined;
        admission[0] = session_transition.operationSubmitted(
            operation_a,
            descriptor_a_ref,
            case.descriptor_a,
            case.recovery_class,
        );
        const attempt_ids = [_]u64{
            winner_attempt,
            live_attempt,
            recovery_attempt,
            wrong_epoch_attempt,
            wrong_kind_attempt,
        };
        for (attempt_ids, 0..) |attempt_id, index| admission[index + 1] = testEffectAttempt(
            case.kind,
            operation_a,
            attempt_id,
            descriptor_a_ref,
            case.descriptor_a,
            @intCast(index),
        );
        _ = try created.commitSemantic(&admission, null);
        try created.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = winner_attempt,
            .result_ref = winner_result_ref,
            .result_digest = testResultDigest("winning result"),
        }));
        const winner_inbox_id = try layout.storage.completionHead(session_id);
        const terminal_sequence = try created.commitSemantic(&.{session_transition.result(.{
            .operation = operation_a,
            .result_ref = winner_result_ref,
            .result_digest = testResultDigest("winning result"),
            .class = .ordinary,
            .evidence = .{ .durable = testDurableEvidence(case.kind, winner_attempt) },
        })}, null);
        _ = try created.commitSemantic(&.{
            session_transition.operationSubmitted(
                operation_b,
                descriptor_b_ref,
                case.descriptor_b,
                case.recovery_class,
            ),
            testEffectAttempt(
                case.kind,
                operation_b,
                current_attempt,
                descriptor_b_ref,
                case.descriptor_b,
                0,
            ),
        }, null);
        const sequence_before_late = try layout.storage.sessionHead(session_id);
        const projection_before_late = created.projection();

        const live_late = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = live_attempt,
            .result_ref = live_result_ref,
            .result_digest = testResultDigest("live late result"),
        });
        try created.publishCompletionEvidence(live_late);
        const live_audit = try layout.storage.readCompletion(session_id, winner_inbox_id + 1);
        try std.testing.expectEqual(terminal_sequence, live_audit.consumed_by_sequence.?);
        try std.testing.expectEqualDeep(live_late, live_audit.envelope);

        const wrong_kind = completion_inbox.bind(.{
            .kind = case.wrong_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = wrong_kind_attempt,
            .result_ref = live_result_ref,
            .result_digest = testResultDigest("live late result"),
        });
        try std.testing.expectError(
            error.CompletionEvidenceKindMismatch,
            created.publishCompletionEvidence(wrong_kind),
        );
        const conflicting = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = live_attempt,
            .result_ref = conflict_result_ref,
            .result_digest = testResultDigest("conflicting late result"),
        });
        try std.testing.expectError(
            error.ConflictingCompletionEvidence,
            created.publishCompletionEvidence(conflicting),
        );
        try std.testing.expectEqual(sequence_before_late, try layout.storage.sessionHead(session_id));
        try std.testing.expectEqualDeep(projection_before_late, created.projection());
        var current: TestCurrentOperation = .{};
        _ = try created.inspectSemantic(&current, TestCurrentOperation.apply);
        try std.testing.expectEqual(operation_b.operation_id, current.operation_id);
        try std.testing.expectEqual(current_attempt, current.attempt_id);

        const recovered_late = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = recovery_attempt,
            .result_ref = recovery_result_ref,
            .result_digest = testResultDigest("recovered late result"),
        });
        const recovered_inbox_id = try layout.storage.publishCompletion(recovered_late);
        try std.testing.expectEqual(winner_inbox_id + 2, recovered_inbox_id);
        created.close();

        var restored = (try Session.openExisting(
            layout.sessions,
            &layout.storage,
            io,
            session_id,
        )).session;
        defer restored.close();
        const ledger_recovery = try restored.recoverSemanticWindow(
            @intCast(sequence_before_late),
        );
        try std.testing.expectEqual(@as(u8, @intCast(sequence_before_late)), ledger_recovery.processed);
        try std.testing.expect(ledger_recovery.more);
        const first_history_window = try restored.recoverSemanticWindow(2);
        try std.testing.expectEqual(@as(u8, 2), first_history_window.processed);
        try std.testing.expect(first_history_window.more);
        try std.testing.expectEqual(
            @as(?u64, null),
            (try layout.storage.readCompletion(session_id, recovered_inbox_id)).consumed_by_sequence,
        );
        while ((try restored.recoverSemanticWindow(32)).more) {}
        const recovered_audit = try layout.storage.readCompletion(session_id, recovered_inbox_id);
        try std.testing.expectEqual(terminal_sequence, recovered_audit.consumed_by_sequence.?);
        try std.testing.expectEqualDeep(recovered_late, recovered_audit.envelope);
        try std.testing.expectEqual(sequence_before_late, try layout.storage.sessionHead(session_id));
        const wrong_epoch = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = restored.session_id,
            .ownership_epoch = restored.ownership_epoch,
            .agent_id = restored.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = wrong_epoch_attempt,
            .result_ref = live_result_ref,
            .result_digest = testResultDigest("live late result"),
        });
        try std.testing.expectError(
            error.CompletionAttemptEpochMismatch,
            restored.publishCompletionEvidence(wrong_epoch),
        );
        try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(session_id));
        var restored_current: TestCurrentOperation = .{};
        _ = try restored.inspectSemantic(&restored_current, TestCurrentOperation.apply);
        try std.testing.expectEqual(operation_b.operation_id, restored_current.operation_id);
        try std.testing.expectEqual(current_attempt, restored_current.attempt_id);
    }
}

test "fallible Inbox publication is prepared before durable Completion commit" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 16));
    defer created.close();
    const token = created.ownerToken();
    const agent: session_transition.AgentContext = .{
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .ownership_epoch = token.epoch,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 100,
        .generation = 1,
    };
    var semantic: session_transition.Transaction = .{ .sequence = 2, .fact_count = 3 };
    semantic.facts[0] = session_transition.operationSubmitted(operation, 101, testDescriptor("102"), .model);
    semantic.facts[1] = session_transition.modelAttemptAdmitted(operation, 103, 101, testDescriptor("102"), 0);
    semantic.facts[2] = session_transition.modelAttemptAdmitted(operation, 108, 101, testDescriptor("102"), 1);
    try created.resident.semantic.apply(semantic);

    const existing = completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 103,
        .result_ref = 104,
        .result_digest = testResultDigest("105"),
    });
    _ = try created.resident.inbox.apply(
        &created.resident.semantic,
        existing,
        created.session_id,
        created.agent_id,
        token.epoch,
    );
    var other_attempt = existing;
    other_attempt.attempt_id = 108;
    for (&created.resident.inbox.ambiguous) |*slot| {
        slot.* = InboxIndex.AttemptKey.fromEnvelope(other_attempt);
    }

    var conflicting = existing;
    conflicting.result_ref = 106;
    conflicting.result_digest = testResultDigest("107");
    conflicting = testReboundEnvelope(conflicting);
    try created.storeBlob(conflicting.result_ref, "conflicting result");
    try std.testing.expectError(
        error.InboxSemanticCapacityExceeded,
        created.publishCompletionEvidence(conflicting),
    );
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));
    try std.testing.expectEqualDeep(existing, created.resident.inbox.entries[0].?);
}

test "recovery advances only within the configured Session Ledger quantum" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 80));
    for (0..5) |index| {
        try created.storeBlob(index + 1, "ledger fixture");
        _ = try created.commitSemantic(&.{session_transition.taskAdmitted(.{
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
        }, index + 1, index + 1)}, null);
    }
    created.close();

    var restored = (try Session.openExisting(
        layout.sessions,
        &layout.storage,
        io,
        80,
    )).session;
    defer restored.close();
    const first = try restored.recoverSemanticWindow(2);
    try std.testing.expectEqual(@as(u8, 2), first.processed);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u64, 2), restored.resident.semantic.last_sequence);
    const second = try restored.recoverSemanticWindow(2);
    try std.testing.expectEqual(@as(u8, 2), second.processed);
    try std.testing.expect(second.more);
    const last = try restored.recoverSemanticWindow(2);
    try std.testing.expectEqual(@as(u8, 2), last.processed);
    try std.testing.expect(!last.more);
    try std.testing.expectEqual(@as(u64, 6), restored.resident.semantic.last_sequence);
}

test "semantic commits reject missing immutable blob references before advancing the Ledger" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 81));
    defer created.close();

    try std.testing.expectError(error.MissingBlobReference, created.commitSemantic(
        &.{session_transition.operationSubmitted(.{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = 100,
            .generation = 1,
        }, 999, testDescriptor("123"), .none)},
        null,
    ));
    try std.testing.expectEqual(@as(u64, 1), created.resident.semantic.last_sequence);
    try std.testing.expectEqual(@as(u64, 1), try layout.storage.sessionHead(created.session_id));
}

test "irrelevant inbox records cannot displace admitted Attempt evidence" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var semantic: SemanticIndex = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admission.facts[0] = session_transition.operationSubmitted(operation, 11, testDescriptor("12"), .none);
    admission.facts[1] = session_transition.modelAttemptAdmitted(
        operation,
        13,
        11,
        testDescriptor("12"),
        0,
    );
    try semantic.apply(admission);

    var inbox: InboxIndex = .{};
    const relevant = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 14,
        .result_digest = testResultDigest("15"),
    });
    var misrouted = relevant;
    misrouted.session_id = 99;
    misrouted.result_ref = 98;
    _ = try inbox.apply(&semantic, testReboundEnvelope(misrouted), 1, 1, 1);
    _ = try inbox.apply(&semantic, relevant, 1, 1, 1);
    for (0..16) |index| {
        var irrelevant = relevant;
        irrelevant.operation_id = 100 + index;
        irrelevant.attempt_id = 200 + index;
        _ = try inbox.apply(&semantic, testReboundEnvelope(irrelevant), 1, 1, 1);
    }
    var future = relevant;
    future.ownership_epoch = 2;
    future.result_ref = 99;
    _ = try inbox.apply(&semantic, testReboundEnvelope(future), 1, 1, 1);
    try std.testing.expectEqualDeep(relevant, inbox.entries[0].?);
}

test "late evidence for an earlier model Attempt survives a later admission" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var semantic: SemanticIndex = .{};
    var first: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    first.facts[0] = session_transition.operationSubmitted(operation, 11, testDescriptor("12"), .none);
    first.facts[1] = session_transition.modelAttemptAdmitted(operation, 13, 11, testDescriptor("12"), 0);
    try semantic.apply(first);
    var retry: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    retry.facts[0] = session_transition.modelAttemptAdmitted(operation, 14, 11, testDescriptor("12"), 1);
    try semantic.apply(retry);

    var inbox: InboxIndex = .{};
    const late = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 15,
        .result_digest = testResultDigest("16"),
    });
    _ = try inbox.apply(&semantic, late, 1, 1, 1);
    try std.testing.expectEqual(@as(u8, 2), semantic.model.attempt_count);
    try std.testing.expectEqualDeep(late, inbox.entries[0].?);
}

test "conflicting Inbox evidence becomes non-authoritative ambiguity" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var semantic: SemanticIndex = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admission.facts[0] = session_transition.operationSubmitted(operation, 11, testDescriptor("12"), .none);
    admission.facts[1] = session_transition.modelAttemptAdmitted(
        operation,
        13,
        11,
        testDescriptor("12"),
        0,
    );
    try semantic.apply(admission);
    var inbox: InboxIndex = .{};
    const first = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 14,
        .result_digest = testResultDigest("15"),
    });
    _ = try inbox.apply(&semantic, first, 1, 1, 1);
    var conflicting = first;
    conflicting.result_ref = 16;
    conflicting.result_digest = testResultDigest("17");
    _ = try inbox.apply(&semantic, testReboundEnvelope(conflicting), 1, 1, 1);
    try std.testing.expect(inbox.entries[0] == null);
    try std.testing.expect(inbox.ambiguous[0].?.matches(first));
}

test "failed recovered frame leaves the published semantic index unchanged" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var index: SemanticIndex = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    admission.facts[0] = session_transition.operationSubmitted(operation, 11, testDescriptor("12"), .none);
    try index.apply(admission);

    var invalid: session_transition.Transaction = .{ .sequence = 2, .fact_count = 2 };
    invalid.facts[0] = session_transition.authorization(.{
        .operation = operation,
        .permission_ref = 11,
        .descriptor_digest = testDescriptor("12"),
        .allowed = true,
    });
    invalid.facts[1] = session_transition.modelAttemptAdmitted(
        .{
            .agent = agent,
            .operation_id = 99,
            .generation = 1,
        },
        13,
        11,
        testDescriptor("12"),
        0,
    );
    var prepared = index;
    try std.testing.expectError(error.InvalidOperationHistory, prepared.apply(invalid));
    try std.testing.expectEqual(@as(u64, 1), index.last_sequence);
    try std.testing.expect(index.model.authorization == null);
}

test "conversation advances only after its Ledger fact commits" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 20));
    defer created.close();
    try created.storeBlob(900, "The test is fixed.");
    const assistant = try created.appendConversation(.assistant_text, 900, null);

    try std.testing.expectEqual(@as(u64, 2), assistant.entry_id);
    try std.testing.expectEqual(@as(u64, 1), assistant.parent_id);
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
    try std.testing.expectError(error.InvalidEntrySequence, created.readEntry(2));
    _ = try created.commitSemantic(&.{session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
        },
        .entry_id = assistant.entry_id,
        .parent_id = assistant.parent_id,
        .kind = assistant.kind,
        .content_ref = assistant.content_ref,
    })}, null);
    try std.testing.expectEqual(@as(u64, 2), created.activeLeafId());
    const stored = try created.readEntry(2);
    try std.testing.expectEqualDeep(assistant, stored);

    var response_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "The test is fixed.",
        try created.readBlob(900, 0, &response_buffer),
    );
}

test "prepared Conversation content is validated at commit" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 35));
    defer created.close();
    try created.storeBlob(900, &.{ 0xff, 0xfe });
    const assistant = try created.appendConversation(.assistant_text, 900, null);

    try std.testing.expectError(
        error.InvalidConversationContent,
        created.commitSemantic(&.{session_transition.conversationAdvanced(.{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .entry_id = assistant.entry_id,
            .parent_id = assistant.parent_id,
            .kind = assistant.kind,
            .content_ref = assistant.content_ref,
        })}, null),
    );
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
}

test "conversation grammar rejects orphaned and unpaired tool entries during recovery" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    var root: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    root.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 1,
        .parent_id = 0,
        .kind = .user_text,
        .content_ref = 10,
    });
    const resident = try (ResidentState{}).applyingLedger(root, 1, 1);

    var orphan: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    orphan.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 2,
        .parent_id = 1,
        .kind = .tool_result,
        .content_ref = 11,
    });
    try std.testing.expectError(error.InvalidConversationGrammar, resident.applyingLedger(orphan, 1, 1));

    var call: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    call.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 2,
        .parent_id = 1,
        .kind = .tool_call,
        .content_ref = 12,
    });
    const awaiting_result = try resident.applyingLedger(call, 1, 1);
    var non_result: session_transition.Transaction = .{ .sequence = 3, .fact_count = 1 };
    non_result.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 3,
        .parent_id = 2,
        .kind = .assistant_text,
        .content_ref = 13,
    });
    try std.testing.expectError(
        error.InvalidConversationGrammar,
        awaiting_result.applyingLedger(non_result, 1, 1),
    );
}

test "Conversation UTF-8 validation carries split sequences across bounded windows" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 25));
    defer created.close();
    var content: [4098]u8 = @splat('a');
    @memcpy(content[4095..], "€");
    try created.storeBlob(990, &content);
    var valid = try created.openBlob(990);
    defer valid.close();
    try validateUtf8ConversationWindows(&valid, 0, valid.length());

    content[4096] = 'x';
    try created.storeBlob(991, &content);
    var invalid = try created.openBlob(991);
    defer invalid.close();
    try std.testing.expectError(
        error.InvalidConversationContent,
        validateUtf8ConversationWindows(&invalid, 0, invalid.length()),
    );
}

test "tool-call recovery trusts admitted exact-byte identity without reparsing JSON" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 21),
    );
    defer created.close();

    const key = "fixture.inspect.v1";
    const admitted_arguments = "{ \"command\" : \"echo exact bytes\", \"timeout_ms\" : 1000 }";
    var call: [conversation.call_header_size + key.len + admitted_arguments.len]u8 = undefined;
    _ = try conversation.encodeToolCallHeader(
        &call,
        key.len,
        admitted_arguments.len,
        model_contract.strictToolJsonDigest(admitted_arguments),
    );
    @memcpy(call[conversation.call_header_size..][0..key.len], key);
    @memcpy(call[conversation.call_header_size + key.len ..], admitted_arguments);
    try created.storeBlob(901, &call);
    try created.validateConversationBlob(.tool_call, 901, 1);

    call[0] = 0;
    try created.storeBlob(902, &call);
    try std.testing.expectError(
        error.InvalidConversationContent,
        created.validateConversationBlob(.tool_call, 902, 1),
    );
}

const AppendCrash = struct {
    fn reached(_: *anyopaque, boundary: AppendBoundary) anyerror!void {
        if (boundary == .after_entry_sync) return error.InjectedCrash;
    }
};

test "resume leaves an uncommitted conversation record invisible" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var marker: u8 = 0;
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 30));
    try created.storeBlob(901, "uncommitted assistant text");
    try std.testing.expectError(
        error.InjectedCrash,
        created.appendConversation(.assistant_text, 901, .{
            .context = &marker,
            .reached = AppendCrash.reached,
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
    try std.testing.expectError(error.SessionUnavailable, created.authorize(created.ownerToken()));
    created.close();

    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 30);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 0), restored.session.activeLeafId());
    _ = try restored.session.recoverSemanticWindow(8);
    try std.testing.expectEqual(@as(u64, 1), restored.session.activeLeafId());
    try std.testing.expectEqual(@as(u64, 1), restored.session.entryCount());
    try std.testing.expectError(error.InvalidEntrySequence, restored.session.readEntry(2));
}

test "repeating task text creates a distinct session" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const config: Config = .{
        .workspace_path = layout.workspacePath(),
        .model = "fixture:repair",
        .task = "Fix the failing test",
    };
    var first = try Session.create(layout.sessions, &layout.storage, io, config);
    defer first.close();
    var second = try Session.create(layout.sessions, &layout.storage, io, config);
    defer second.close();

    try std.testing.expect(first.session_id != second.session_id);
    try std.testing.expect(first.agent_id != second.agent_id);
    try std.testing.expect(first.task_id != second.task_id);
    try std.testing.expect(first.branch_id != second.branch_id);
}

test "creation rejects non Git workspaces and aliased identities" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "plain", .default_dir);
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var plain = try tmp.dir.openDir(io, "plain", .{});
    defer plain.close(io);
    var database_path_buffer: [128]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();

    var plain_path_buffer: [128]u8 = undefined;
    const plain_path = try std.fmt.bufPrint(
        &plain_path_buffer,
        ".zig-cache/tmp/{s}/plain",
        .{tmp.sub_path},
    );
    try std.testing.expectError(
        error.NotGitWorktree,
        Session.createExact(sessions, &storage, io, testConfig(plain_path, 60)),
    );

    try initTestGitWorktree(plain, io);
    var invalid = testConfig(plain_path, 70);
    invalid.identities.agent_id = invalid.identities.session_id;
    try std.testing.expectError(
        error.InvalidIdentity,
        Session.createExact(sessions, &storage, io, invalid),
    );

    var oversized_bytes: [host_store.max_model_bytes + 1]u8 = undefined;
    @memset(&oversized_bytes, 'x');
    var oversized = testConfig(plain_path, 75);
    oversized.model = &oversized_bytes;
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(sessions, &storage, io, oversized),
    );
    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        sessions.access(io, sessionName(75, &name_buffer), .{}),
    );
}

test "session metadata has no per-session manifest projection" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 80));
    created.close();

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(80, &name_buffer), .{});
    defer session_dir.close(io);
    try std.testing.expectError(error.FileNotFound, session_dir.access(io, "manifest", .{}));
    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 80);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 2), restored.session.ownership_epoch);
}

test "resume rejects a missing recorded workspace before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 85));
    created.close();
    layout.workspace.close(io);
    try layout.tmp.dir.rename("repo", layout.tmp.dir, "moved", io);
    layout.workspace = try layout.tmp.dir.openDir(io, "moved", .{});

    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Session.openExisting(layout.sessions, &layout.storage, io, 85),
    );
    const stored = try layout.storage.readSession(85);
    try std.testing.expectEqual(@as(u64, 1), stored.ownership_epoch);
}
