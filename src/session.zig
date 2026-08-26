const std = @import("std");
const blob_store = @import("blob_store.zig");
const completion_inbox = @import("completion_inbox.zig");
const core_state = @import("core_state.zig");
const host_store = @import("host_store.zig");
const session_transition = @import("session_transition.zig");

pub const workspace_path_capacity = 1024;
const lock_path = "owner.lock";
const blobs_path = "blobs";

pub const Identities = struct {
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    branch_id: u64,

    fn validate(self: Identities) !void {
        const values = [_]u64{
            self.session_id,
            self.agent_id,
            self.task_id,
            self.branch_id,
        };
        for (values, 0..) |value, index| {
            if (value == 0) return error.InvalidIdentity;
            for (values[index + 1 ..]) |other| {
                if (value == other) return error.InvalidIdentity;
            }
        }
    }
};

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

pub const OwnerToken = struct {
    session_id: u64,
    epoch: u64,
};

pub const EntryKind = enum(u8) {
    user = 1,
    assistant = 2,
    tool_result = 3,
    context_checkpoint = 4,
};

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
    const max_attempts = 8;

    operation_id: u64 = 0,
    generation: u32 = 0,
    recovery_class: session_transition.RecoveryClass = .none,
    descriptor: ?session_transition.Fact = null,
    attempt: ?session_transition.Fact = null,
    attempts: [max_attempts]?session_transition.Fact = @splat(null),
    attempt_count: u8 = 0,
    approval_required: ?session_transition.Fact = null,
    authorization: ?session_transition.Fact = null,
    result: ?session_transition.Fact = null,

    fn accepts(self: OperationHistory, fact: session_transition.Fact) bool {
        return self.operation_id == fact.operation_id and self.generation == fact.generation;
    }

    fn appendAttempt(self: *OperationHistory, fact: session_transition.Fact) !void {
        for (self.attempts[0..self.attempt_count]) |maybe_existing| {
            const existing = maybe_existing.?;
            if (existing.attempt_id != fact.attempt_id) continue;
            if (!std.meta.eql(existing, fact)) return error.ConflictingLedgerFacts;
            self.attempt = existing;
            return;
        }
        if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
        self.attempts[self.attempt_count] = fact;
        self.attempt_count += 1;
        self.attempt = fact;
    }

    fn containsAttempt(self: OperationHistory, attempt_id: u64) bool {
        for (self.attempts[0..self.attempt_count]) |maybe_attempt| {
            if (maybe_attempt.?.attempt_id == attempt_id) return true;
        }
        return false;
    }
};

const SemanticIndex = struct {
    last_sequence: u64 = 0,
    last_core: ?[core_state.encoded_size]u8 = null,
    model: OperationHistory = .{},
    consequential: OperationHistory = .{},
    open_operation: ?session_transition.Fact = null,
    control: ?session_transition.Fact = null,
    indeterminate: ?session_transition.Fact = null,

    fn apply(self: *SemanticIndex, transaction: session_transition.Transaction) !void {
        if (transaction.sequence != self.last_sequence + 1) return error.NonmonotonicSequence;
        for (transaction.factSlice()) |fact| {
            const history: ?*OperationHistory = switch (fact.recovery_class) {
                .model => &self.model,
                .consequential => &self.consequential,
                .none => if (fact.operation_id == 0)
                    null
                else if (fact.operation_id >> 63 == 0)
                    &self.model
                else
                    &self.consequential,
            };
            switch (fact.kind) {
                .operation_submitted => if (history) |value| {
                    if (!value.accepts(fact)) value.* = .{
                        .operation_id = fact.operation_id,
                        .generation = fact.generation,
                        .recovery_class = fact.recovery_class,
                    };
                    value.descriptor = try uniqueIndexedFact(value.descriptor, fact);
                },
                .operation_accepted => self.open_operation = fact,
                .attempt_admitted => if (history) |value| {
                    if (!value.accepts(fact)) return error.InvalidOperationHistory;
                    try value.appendAttempt(fact);
                },
                .approval_required => if (history) |value| {
                    if (!value.accepts(fact)) return error.InvalidOperationHistory;
                    value.approval_required = try uniqueIndexedFact(value.approval_required, fact);
                },
                .authorization => if (history) |value| {
                    if (!value.accepts(fact)) return error.InvalidOperationHistory;
                    value.authorization = fact;
                },
                .result => {
                    if (history) |value| {
                        if (!value.accepts(fact)) return error.InvalidOperationHistory;
                        value.result = try uniqueIndexedFact(value.result, fact);
                    }
                    if (self.open_operation) |open_fact| {
                        if (open_fact.operation_id == fact.operation_id and
                            open_fact.generation == fact.generation)
                        {
                            self.open_operation = null;
                        }
                    }
                    // Bash status 8 is the durable indeterminate disposition.
                    if (fact.recovery_class == .consequential and fact.flags == 8) {
                        self.indeterminate = fact;
                    }
                },
                .cancellation, .shutdown => self.control = fact,
                else => {},
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
            const facts = [_]?session_transition.Fact{
                history.descriptor,
                history.approval_required,
                history.authorization,
            };
            for (facts) |maybe_fact| if (maybe_fact) |fact| {
                try apply_fn(context, fact);
            };
            for (history.attempts[0..history.attempt_count]) |maybe_attempt| {
                try apply_fn(context, maybe_attempt.?);
            }
            if (history.result) |fact| {
                try apply_fn(context, fact);
            }
        }
        if (self.open_operation) |fact| {
            try apply_fn(context, fact);
        }
        if (self.indeterminate) |fact| {
            try apply_fn(context, fact);
        }
        if (self.control) |fact| try apply_fn(context, fact);
    }
};

fn uniqueIndexedFact(existing: ?session_transition.Fact, fact: session_transition.Fact) !session_transition.Fact {
    if (existing) |value| {
        if (!std.meta.eql(value, fact)) return error.ConflictingLedgerFacts;
        return value;
    }
    return fact;
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

    fn apply(
        self: *InboxIndex,
        semantic: *const SemanticIndex,
        envelope: completion_inbox.Envelope,
        session_id: u64,
        agent_id: u64,
        ownership_epoch: u64,
    ) !void {
        if (envelope.session_id != session_id or envelope.agent_id != agent_id or
            envelope.agent_generation != 1 or envelope.ownership_epoch > ownership_epoch)
        {
            return;
        }
        const history = historyForEnvelope(semantic, envelope);
        if (history.operation_id != envelope.operation_id or
            history.generation != envelope.operation_generation or
            !history.containsAttempt(envelope.attempt_id))
        {
            return;
        }
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
            if (key.matches(envelope)) return;
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
                !existing_history.containsAttempt(existing.attempt_id))
            {
                if (available == null) available = slot;
                continue;
            }
            if (existing.operation_id == envelope.operation_id and
                existing.operation_generation == envelope.operation_generation and
                existing.attempt_id == envelope.attempt_id)
            {
                if (std.meta.eql(existing, envelope)) return;
                slot.* = null;
                const destination = ambiguous_slot orelse
                    return error.InboxSemanticCapacityExceeded;
                destination.* = AttemptKey.fromEnvelope(envelope);
                return;
            }
        }
        const slot = available orelse return error.InboxSemanticCapacityExceeded;
        slot.* = envelope;
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
            history.containsAttempt(key.attempt_id);
    }
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
    token: OwnerToken,
    blobs: std.Io.Dir,
    writer: blob_store.Writer,
    open: bool = true,

    pub fn append(self: *BlobWriter, bytes: []const u8) !void {
        if (!self.open) return error.BlobWriterClosed;
        try self.session.authorize(self.token);
        try self.writer.append(self.session.io, bytes);
    }

    pub fn finish(self: *BlobWriter) !void {
        if (!self.open) return error.BlobWriterClosed;
        try self.session.authorize(self.token);
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
    session: *Session,
    token: OwnerToken,
    blobs: std.Io.Dir,
    reader: blob_store.Reader,
    open: bool = true,

    pub fn length(self: *const BlobReader) u64 {
        return self.reader.meta.length;
    }

    pub fn readWindow(self: *BlobReader, offset: u64, out: []u8) ![]const u8 {
        if (!self.open) return error.BlobReaderClosed;
        try self.session.authorize(self.token);
        return self.reader.readWindow(self.session.io, offset, out);
    }

    pub fn close(self: *BlobReader) void {
        if (!self.open) return;
        self.reader.close(self.session.io);
        self.blobs.close(self.session.io);
        self.open = false;
    }
};

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
    active_leaf_id: u64,
    entry_count: u64,
    pending_conversation: ?ConversationEntry = null,
    ledger_sequence: u64 = 0,
    semantic_index: SemanticIndex = .{},
    recovery_sequence: u64 = 1,
    recovery_ledger_head: u64 = 0,
    recovery_inbox_sequence: u64 = 1,
    recovery_inbox_head: u64 = 0,
    recovery_started: bool = false,
    recovery_complete: bool = true,
    inbox_index: InboxIndex = .{},
    workspace_path: [workspace_path_capacity]u8 = undefined,
    workspace_path_length: u16,
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
        if (config.workspace_path.len == 0 or config.model.len == 0 or config.task.len == 0) {
            return error.InvalidSessionMetadata;
        }
        try validateWorkspace(io, config.workspace_path);

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

        try storage.createSessionWithMetadata(.{
            .identities = .{
                .session_id = config.identities.session_id,
                .agent_id = config.identities.agent_id,
                .task_id = config.identities.task_id,
                .branch_id = config.identities.branch_id,
            },
            .workspace_path = config.workspace_path,
            .model = config.model,
        });

        return fromStored(io, storage, dir, lock_file, try storage.readSession(config.identities.session_id), true);
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
            .active_leaf_id = stored.active_leaf_id,
            .entry_count = stored.entry_count,
            .workspace_path_length = stored.workspace_path_length,
            .recovery_complete = recovery_complete,
        };
        @memcpy(session.workspace_path[0..stored.workspace_path_length], stored.workspacePath());
        return session;
    }

    pub fn ownerToken(self: *const Session) OwnerToken {
        return .{ .session_id = self.session_id, .epoch = self.ownership_epoch };
    }

    pub fn workspacePath(self: *const Session) []const u8 {
        return self.workspace_path[0..self.workspace_path_length];
    }

    pub fn recoveryIsEmpty(self: *Session, token: OwnerToken) !bool {
        try self.authorize(token);
        if (try self.storage.sessionHead(self.session_id) != 0) return false;
        return try self.storage.completionHead(self.session_id) == 0;
    }

    pub fn projection(self: *const Session) Projection {
        return .{
            .session_id = self.session_id,
            .task_id = self.task_id,
            .active_leaf_id = self.active_leaf_id,
            .ownership_epoch = self.ownership_epoch,
        };
    }

    pub fn authorize(self: *Session, token: OwnerToken) !void {
        if (!self.open) return error.SessionClosed;
        if (self.failed) return error.SessionUnavailable;
        if (token.session_id != self.session_id or token.epoch != self.ownership_epoch) {
            return error.StaleOwner;
        }
        try self.storage.authorizeSession(.{
            .session_id = token.session_id,
            .epoch = token.epoch,
        });
    }

    pub fn appendConversation(
        self: *Session,
        token: OwnerToken,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        if (content_ref == 0) return error.InvalidContentReference;
        try self.authorize(token);
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
        if (self.entry_count == std.math.maxInt(u64)) return error.EntryIdentityExhausted;

        const entry: ConversationEntry = .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = self.entry_count + 1,
            .parent_id = self.active_leaf_id,
            .task_id = self.task_id,
            .content_ref = content_ref,
            .sequence = self.entry_count + 1,
        };
        if (self.pending_conversation) |pending| {
            if (!std.meta.eql(pending, entry)) return error.UncommittedConversationConflict;
            return pending;
        }
        self.pending_conversation = entry;
        if (fault) |hook| try hook.reached(hook.context, .after_entry_sync);
        return entry;
    }

    fn validatePreparedConversationEntry(self: *Session, fact: session_transition.Fact) !void {
        if (fact.subject <= self.entry_count) {
            const existing = try self.readEntry(fact.subject);
            if (existing.content_ref != fact.reference) return error.ConversationLedgerMismatch;
            return;
        }
        if (fact.subject != self.entry_count + 1) return error.ConversationLedgerGap;
        const entry = self.pending_conversation orelse return error.MissingPreparedConversationEntry;
        if (entry.entry_id != fact.subject or entry.sequence != fact.subject or
            entry.parent_id != self.active_leaf_id or entry.content_ref != fact.reference or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationLedgerMismatch;
        }
    }

    fn publishConversationEntry(self: *Session, fact: session_transition.Fact) void {
        if (fact.subject <= self.entry_count) return;
        std.debug.assert(fact.subject == self.entry_count + 1);
        self.active_leaf_id = fact.subject;
        self.entry_count = fact.subject;
        self.pending_conversation = null;
    }

    fn reconstructConversationEntry(self: *Session, fact: session_transition.Fact) !void {
        if (fact.subject <= self.entry_count) {
            const existing = try self.readEntry(fact.subject);
            if (existing.content_ref != fact.reference) return error.ConversationLedgerMismatch;
            return;
        }
        if (fact.subject != self.entry_count + 1) return error.ConversationLedgerGap;
        const entry = try self.loadEntry(fact.subject);
        if (entry.entry_id != fact.subject or entry.sequence != fact.subject or
            entry.parent_id != self.active_leaf_id or entry.content_ref != fact.reference or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationLedgerMismatch;
        }
        self.active_leaf_id = fact.subject;
        self.entry_count = fact.subject;
    }

    pub fn readEntry(self: *Session, sequence: u64) !ConversationEntry {
        if (!self.open) return error.SessionClosed;
        if (sequence == 0 or sequence > self.entry_count) return error.InvalidEntrySequence;
        return self.loadEntry(sequence);
    }

    fn loadEntry(self: *Session, sequence: u64) !ConversationEntry {
        const stored = try self.storage.readConversationEntry(self.session_id, sequence);
        if (stored.committed_by_sequence == null and self.ledger_sequence != 0) {
            return error.InvalidEntrySequence;
        }
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
        token: OwnerToken,
        reference: u64,
        bytes: []const u8,
    ) !void {
        try self.authorize(token);
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        defer blobs.close(self.io);
        blob_store.put(blobs, self.io, reference, bytes) catch |err| {
            self.failed = true;
            return err;
        };
    }

    pub fn beginBlob(
        self: *Session,
        token: OwnerToken,
        reference: u64,
    ) !BlobWriter {
        try self.authorize(token);
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        errdefer blobs.close(self.io);
        const writer = try blob_store.Writer.begin(blobs, self.io, reference);
        return .{ .session = self, .token = token, .blobs = blobs, .writer = writer };
    }

    pub fn readBlob(
        self: *Session,
        token: OwnerToken,
        reference: u64,
        offset: u64,
        out: []u8,
    ) ![]const u8 {
        try self.authorize(token);
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        defer blobs.close(self.io);
        return blob_store.readWindow(blobs, self.io, reference, offset, out);
    }

    pub fn openBlob(
        self: *Session,
        token: OwnerToken,
        reference: u64,
    ) !BlobReader {
        try self.authorize(token);
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        errdefer blobs.close(self.io);
        const reader = try blob_store.Reader.openIn(blobs, self.io, reference);
        return .{ .session = self, .token = token, .blobs = blobs, .reader = reader };
    }

    pub fn commitSemantic(
        self: *Session,
        token: OwnerToken,
        facts: []const session_transition.Fact,
        encoded_core: ?[]const u8,
    ) !u64 {
        try self.authorize(token);
        if (!self.recovery_complete) return error.SessionRecoveryIncomplete;
        if (facts.len == 0 or facts.len > session_transition.max_facts) {
            return error.InvalidSemanticFactCount;
        }
        if (self.ledger_sequence == std.math.maxInt(u64)) {
            return error.SessionSequenceExhausted;
        }
        if (encoded_core) |bytes| {
            if (bytes.len != core_state.encoded_size) return error.InvalidCoreStateLength;
            _ = try core_state.decode(bytes);
        }
        for (facts) |fact| {
            if (fact.kind == .conversation_advanced) try self.validatePreparedConversationEntry(fact);
            try self.validatePreparedBlobReferences(fact);
        }

        var transaction: session_transition.Transaction = .{
            .sequence = self.ledger_sequence + 1,
            .fact_count = @intCast(facts.len),
            .core = if (encoded_core) |bytes| bytes[0..core_state.encoded_size].* else null,
        };
        @memcpy(transaction.facts[0..facts.len], facts);
        var prepared_index = self.semantic_index;
        try prepared_index.apply(transaction);

        var conversations: [session_transition.max_facts]host_store.ConversationInsert = undefined;
        var conversation_count: usize = 0;
        var completions: [session_transition.max_facts]host_store.CompletionAssociation = undefined;
        var completion_count: usize = 0;
        var capacity_class: host_store.CapacityClass = .closure;
        for (facts) |fact| {
            if (fact.kind == .task_admitted or fact.kind == .operation_submitted or
                fact.kind == .attempt_admitted) capacity_class = .admission;
            if (fact.kind == .conversation_advanced) {
                const entry = if (fact.subject == 1) ConversationEntry{
                    .kind = .user,
                    .session_id = self.session_id,
                    .entry_id = 1,
                    .parent_id = 0,
                    .task_id = self.task_id,
                    .content_ref = self.task_id,
                    .sequence = 1,
                } else self.pending_conversation orelse return error.MissingPreparedConversationEntry;
                conversations[conversation_count] = .{
                    .entry_id = entry.entry_id,
                    .parent_id = entry.parent_id,
                    .kind = @intFromEnum(entry.kind),
                    .content_ref = entry.content_ref,
                };
                conversation_count += 1;
            }
            if (fact.kind == .result and fact.attempt_id != 0) {
                completions[completion_count] = .{
                    .ownership_epoch = fact.ownership_epoch,
                    .agent_id = fact.agent_id,
                    .agent_generation = fact.agent_generation,
                    .operation_id = fact.operation_id,
                    .operation_generation = fact.generation,
                    .attempt_id = fact.attempt_id,
                    .evidence_kind = fact.evidence_kind,
                    .result_reference = fact.reference,
                    .result_digest = fact.digest,
                };
                completion_count += 1;
            }
        }
        var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
        const payload = try session_transition.encode(&payload_buffer, transaction);
        const final_sequence = try self.storage.commit(.{
            .token = .{ .session_id = self.session_id, .epoch = self.ownership_epoch },
            .expected_sequence = self.ledger_sequence,
            .payload = payload,
            .conversations = conversations[0..conversation_count],
            .completions = completions[0..completion_count],
            .capacity_class = capacity_class,
        });
        std.debug.assert(final_sequence == transaction.sequence);
        self.ledger_sequence = final_sequence;
        self.semantic_index = prepared_index;
        for (facts) |fact| {
            if (fact.kind == .conversation_advanced) self.publishConversationEntry(fact);
        }
        return final_sequence;
    }

    fn validatePreparedBlobReferences(
        self: *Session,
        fact: session_transition.Fact,
    ) !void {
        var blobs = try self.dir.openDir(self.io, blobs_path, .{});
        defer blobs.close(self.io);
        if (fact.reference != 0) {
            _ = blob_store.metadata(blobs, self.io, fact.reference) catch |err| switch (err) {
                error.FileNotFound => return error.MissingBlobReference,
                else => return err,
            };
        }
        if (fact.kind == .approval_required and fact.subject != 0) {
            _ = blob_store.metadata(blobs, self.io, fact.subject) catch |err| switch (err) {
                error.FileNotFound => return error.MissingBlobReference,
                else => return err,
            };
        }
    }

    pub fn inspectSemantic(
        self: *Session,
        token: OwnerToken,
        context: *anyopaque,
        apply: *const fn (*anyopaque, session_transition.Fact) anyerror!void,
    ) !LedgerView {
        try self.authorize(token);
        if (!self.recovery_complete) return error.SessionRecoveryIncomplete;
        try self.semantic_index.emitFacts(context, apply);
        const view: LedgerView = .{
            .last_sequence = self.semantic_index.last_sequence,
            .last_core = self.semantic_index.last_core,
        };
        self.ledger_sequence = view.last_sequence;
        return view;
    }

    pub fn recoverSemanticWindow(
        self: *Session,
        token: OwnerToken,
        frame_budget: u8,
    ) !RecoveryProgress {
        try self.authorize(token);
        if (frame_budget == 0) return error.InvalidRecoveryQuantum;
        if (self.recovery_complete) return .{ .processed = 0, .more = false };
        if (!self.recovery_started) {
            self.semantic_index = .{};
            self.inbox_index = .{};
            self.recovery_sequence = 1;
            self.recovery_ledger_head = try self.storage.sessionHead(self.session_id);
            self.recovery_inbox_sequence = 1;
            self.recovery_inbox_head = try self.storage.completionHead(self.session_id);
            self.recovery_started = true;
        }
        var processed: u8 = 0;
        while (processed < frame_budget) {
            if (self.recovery_sequence <= self.recovery_ledger_head) {
                var stored: host_store.StoredTransition = undefined;
                try self.storage.readTransition(
                    self.session_id,
                    self.recovery_sequence,
                    &stored,
                );
                const transaction = try session_transition.decode(
                    stored.sequence,
                    stored.payloadSlice(),
                );
                var prepared_index = self.semantic_index;
                try prepared_index.apply(transaction);
                for (transaction.factSlice()) |fact| {
                    if (fact.kind == .conversation_advanced) try self.reconstructConversationEntry(fact);
                }
                self.semantic_index = prepared_index;
                self.recovery_sequence += 1;
                processed += 1;
                continue;
            }
            if (self.recovery_inbox_sequence == 1) {
                self.ledger_sequence = self.recovery_ledger_head;
            }
            if (self.recovery_inbox_sequence <= self.recovery_inbox_head) {
                const stored_completion = try self.storage.readCompletion(
                    self.session_id,
                    self.recovery_inbox_sequence,
                );
                try self.inbox_index.apply(
                    &self.semantic_index,
                    stored_completion.envelope,
                    self.session_id,
                    self.agent_id,
                    self.ownership_epoch,
                );
                self.recovery_inbox_sequence += 1;
                processed += 1;
                continue;
            }
            self.recovery_complete = true;
            self.recovery_started = false;
            return .{ .processed = processed, .more = false };
        }
        return .{ .processed = processed, .more = true };
    }

    pub fn publishCompletionEvidence(
        self: *Session,
        token: OwnerToken,
        envelope: completion_inbox.Envelope,
    ) !void {
        try self.authorize(token);
        if (envelope.session_id != self.session_id or envelope.agent_id != self.agent_id) {
            return error.CompletionIdentityMismatch;
        }
        if (envelope.ownership_epoch > token.epoch) return error.FutureCompletionEpoch;
        var result = try self.openBlob(token, envelope.result_ref);
        result.close();
        _ = try self.storage.publishCompletion(envelope);
        try self.inbox_index.apply(
            &self.semantic_index,
            envelope,
            self.session_id,
            self.agent_id,
            self.ownership_epoch,
        );
    }

    pub fn scanCompletionEvidence(
        self: *Session,
        token: OwnerToken,
        context: *anyopaque,
        apply: *const fn (*anyopaque, completion_inbox.Envelope) anyerror!void,
    ) !u32 {
        try self.authorize(token);
        if (!self.recovery_complete) return error.SessionRecoveryIncomplete;
        for (self.inbox_index.entries) |maybe_envelope| {
            if (maybe_envelope) |envelope| try apply(context, envelope);
        }
        return 0;
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

test "create and exact resume preserve distinct identities and one owner" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 10));
    const first_token = created.ownerToken();
    var id_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000000a", try formatId(created.session_id, &id_buffer));
    try std.testing.expectEqual(@as(u64, 1), first_token.epoch);
    try std.testing.expectEqual(@as(u64, 1), created.active_leaf_id);
    try std.testing.expectEqual(@as(u64, 1), created.entry_count);

    try std.testing.expectError(
        error.SessionBusy,
        Session.openExisting(layout.sessions, &layout.storage, io, 10),
    );
    created.close();

    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 10);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 2), restored.session.ownership_epoch);
    try std.testing.expectEqualStrings(layout.workspacePath(), restored.session.workspacePath());
    try std.testing.expectEqualDeep(Projection{
        .session_id = 10,
        .task_id = 12,
        .active_leaf_id = 1,
        .ownership_epoch = 2,
    }, restored.session.projection());
    try std.testing.expectError(error.StaleOwner, restored.session.authorize(first_token));
    try restored.session.authorize(restored.session.ownerToken());

    const root = try restored.session.readEntry(1);
    try std.testing.expectEqual(EntryKind.user, root.kind);
    try std.testing.expectEqual(@as(u64, 0), root.parent_id);
    try std.testing.expectEqual(restored.session.task_id, root.content_ref);
    var task_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Fix the failing test",
        try restored.session.readBlob(
            restored.session.ownerToken(),
            root.content_ref,
            0,
            &task_buffer,
        ),
    );
}

test "future ownership epochs never enter the durable Completion Inbox" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 15));
    defer created.close();
    const token = created.ownerToken();
    try created.storeBlob(token, 99, "future result");
    try std.testing.expectError(error.FutureCompletionEpoch, created.publishCompletionEvidence(token, .{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch + 1,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 101,
        .result_ref = 99,
        .result_digest = 102,
    }));
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));
}

test "recovery advances only within the configured Session Ledger quantum" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 80));
    for (0..5) |index| {
        try created.storeBlob(created.ownerToken(), index + 1, "ledger fixture");
        _ = try created.commitSemantic(created.ownerToken(), &.{.{
            .kind = .task_admitted,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
            .subject = index + 1,
            .reference = index + 1,
        }}, null);
    }
    created.close();

    var restored = (try Session.openExisting(
        layout.sessions,
        &layout.storage,
        io,
        80,
    )).session;
    defer restored.close();
    const token = restored.ownerToken();
    const first = try restored.recoverSemanticWindow(token, 2);
    try std.testing.expectEqual(@as(u8, 2), first.processed);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u64, 0), restored.ledger_sequence);
    const second = try restored.recoverSemanticWindow(token, 2);
    try std.testing.expectEqual(@as(u8, 2), second.processed);
    try std.testing.expect(second.more);
    const last = try restored.recoverSemanticWindow(token, 2);
    try std.testing.expectEqual(@as(u8, 1), last.processed);
    try std.testing.expect(!last.more);
    try std.testing.expectEqual(@as(u64, 5), restored.ledger_sequence);
}

test "semantic commits reject missing immutable blob references before advancing the Ledger" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, &layout.storage, io, testConfig(layout.workspacePath(), 81));
    defer created.close();

    try std.testing.expectError(error.MissingBlobReference, created.commitSemantic(
        created.ownerToken(),
        &.{.{
            .kind = .operation_submitted,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
            .operation_id = 100,
            .generation = 1,
            .reference = 999,
            .digest = 123,
        }},
        null,
    ));
    try std.testing.expectEqual(@as(u64, 0), created.ledger_sequence);
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.sessionHead(created.session_id));
}

test "irrelevant inbox records cannot displace admitted Attempt evidence" {
    var semantic: SemanticIndex = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admission.facts[0] = .{
        .kind = .operation_submitted,
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .operation_id = 10,
        .generation = 1,
        .reference = 11,
        .digest = 12,
    };
    admission.facts[1] = admission.facts[0];
    admission.facts[1].kind = .attempt_admitted;
    admission.facts[1].attempt_id = 13;
    admission.facts[1].recovery_class = .model;
    try semantic.apply(admission);

    var inbox: InboxIndex = .{};
    const relevant: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 14,
        .result_digest = 15,
    };
    var misrouted = relevant;
    misrouted.session_id = 99;
    misrouted.result_ref = 98;
    try inbox.apply(&semantic, misrouted, 1, 1, 1);
    try inbox.apply(&semantic, relevant, 1, 1, 1);
    for (0..16) |index| {
        var irrelevant = relevant;
        irrelevant.operation_id = 100 + index;
        irrelevant.attempt_id = 200 + index;
        try inbox.apply(&semantic, irrelevant, 1, 1, 1);
    }
    var future = relevant;
    future.ownership_epoch = 2;
    future.result_ref = 99;
    try inbox.apply(&semantic, future, 1, 1, 1);
    try std.testing.expectEqualDeep(relevant, inbox.entries[0].?);
}

test "late evidence for an earlier model Attempt survives a later admission" {
    var semantic: SemanticIndex = .{};
    var first: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    first.facts[0] = .{
        .kind = .operation_submitted,
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .operation_id = 10,
        .generation = 1,
        .reference = 11,
        .digest = 12,
    };
    first.facts[1] = first.facts[0];
    first.facts[1].kind = .attempt_admitted;
    first.facts[1].attempt_id = 13;
    first.facts[1].recovery_class = .model;
    try semantic.apply(first);
    var retry: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    retry.facts[0] = first.facts[1];
    retry.facts[0].attempt_id = 14;
    try semantic.apply(retry);

    var inbox: InboxIndex = .{};
    const late: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 15,
        .result_digest = 16,
    };
    try inbox.apply(&semantic, late, 1, 1, 1);
    try std.testing.expectEqual(@as(u8, 2), semantic.model.attempt_count);
    try std.testing.expectEqualDeep(late, inbox.entries[0].?);
}

test "conflicting Inbox evidence becomes non-authoritative ambiguity" {
    var semantic: SemanticIndex = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admission.facts[0] = .{
        .kind = .operation_submitted,
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .operation_id = 10,
        .generation = 1,
        .reference = 11,
        .digest = 12,
    };
    admission.facts[1] = admission.facts[0];
    admission.facts[1].kind = .attempt_admitted;
    admission.facts[1].attempt_id = 13;
    admission.facts[1].recovery_class = .model;
    try semantic.apply(admission);
    var inbox: InboxIndex = .{};
    const first: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 14,
        .result_digest = 15,
    };
    try inbox.apply(&semantic, first, 1, 1, 1);
    var conflicting = first;
    conflicting.result_ref = 16;
    conflicting.result_digest = 17;
    try inbox.apply(&semantic, conflicting, 1, 1, 1);
    try std.testing.expect(inbox.entries[0] == null);
    try std.testing.expect(inbox.ambiguous[0].?.matches(first));
}

test "failed recovered frame leaves the published semantic index unchanged" {
    var index: SemanticIndex = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    admission.facts[0] = .{
        .kind = .operation_submitted,
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .operation_id = 10,
        .generation = 1,
        .reference = 11,
        .digest = 12,
    };
    try index.apply(admission);

    var invalid: session_transition.Transaction = .{ .sequence = 2, .fact_count = 2 };
    invalid.facts[0] = admission.facts[0];
    invalid.facts[0].kind = .authorization;
    invalid.facts[1] = admission.facts[0];
    invalid.facts[1].kind = .attempt_admitted;
    invalid.facts[1].operation_id = 99;
    invalid.facts[1].attempt_id = 13;
    invalid.facts[1].recovery_class = .model;
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
    const token = created.ownerToken();

    try created.storeBlob(token, 900, "The test is fixed.");
    const assistant = try created.appendConversation(token, .assistant, 900, null);

    try std.testing.expectEqual(@as(u64, 2), assistant.entry_id);
    try std.testing.expectEqual(@as(u64, 1), assistant.parent_id);
    try std.testing.expectEqual(@as(u64, 1), created.active_leaf_id);
    try std.testing.expectError(error.InvalidEntrySequence, created.readEntry(2));
    _ = try created.commitSemantic(token, &.{.{
        .kind = .conversation_advanced,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .ownership_epoch = created.ownership_epoch,
        .subject = assistant.entry_id,
        .reference = assistant.content_ref,
    }}, null);
    try std.testing.expectEqual(@as(u64, 2), created.active_leaf_id);
    const stored = try created.readEntry(2);
    try std.testing.expectEqualDeep(assistant, stored);

    var response_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "The test is fixed.",
        try created.readBlob(token, 900, 0, &response_buffer),
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
    try std.testing.expectError(
        error.InjectedCrash,
        created.appendConversation(created.ownerToken(), .tool_result, 901, .{
            .context = &marker,
            .reached = AppendCrash.reached,
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), created.active_leaf_id);
    try std.testing.expectError(error.SessionUnavailable, created.authorize(created.ownerToken()));
    created.close();

    var restored = try Session.openExisting(layout.sessions, &layout.storage, io, 30);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 1), restored.session.active_leaf_id);
    try std.testing.expectEqual(@as(u64, 1), restored.session.entry_count);
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
