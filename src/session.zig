const std = @import("std");
const blob_store = @import("blob_store.zig");
const checkpoint = @import("checkpoint.zig");
const checkpoint_store = @import("checkpoint_store.zig");
const completion_inbox = @import("completion_inbox.zig");
const core_state = @import("core_state.zig");
const session_wal = @import("session_wal.zig");

pub const manifest_max_size = 2048;
pub const workspace_path_capacity = 1024;
pub const manifest_header_size = 128;
pub const conversation_record_size = 80;
pub const manifest_version: u16 = 2;
pub const conversation_version: u16 = 1;

const manifest_magic = "ONESESS\x00";
const conversation_magic = "ONECONV\x00";
const manifest_path = "manifest";
const manifest_temp_path = "manifest.tmp";
const conversation_path = "conversation.log";
const lock_path = "owner.lock";
const blobs_path = "blobs";
const wal_path = "session.wal";
const inbox_path = "completion.inbox";
const checkpoint_path = "core.state";
const checkpoint_temp_path = "core.state.tmp";

const manifest_crc_offset = 20;

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

pub const ManifestView = struct {
    identities: Identities,
    ownership_epoch: u64,
    active_leaf_id: u64,
    entry_count: u64,
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const Restored = struct {
    session: Session,
    manifest: ManifestView,
};

pub const Projection = struct {
    session_id: u64,
    task_id: u64,
    active_leaf_id: u64,
    ownership_epoch: u64,
};

pub const WalView = struct {
    last_sequence: u64 = 0,
    last_core: ?[core_state.encoded_size]u8 = null,
    facts: [session_wal.max_facts]session_wal.Fact = undefined,
    fact_count: u8 = 0,

    pub fn factSlice(self: *const WalView) []const session_wal.Fact {
        return self.facts[0..self.fact_count];
    }
};

const OperationHistory = struct {
    const max_attempts = 8;

    operation_id: u64 = 0,
    generation: u32 = 0,
    recovery_class: session_wal.RecoveryClass = .none,
    descriptor: ?session_wal.Fact = null,
    attempt: ?session_wal.Fact = null,
    attempts: [max_attempts]?session_wal.Fact = @splat(null),
    attempt_count: u8 = 0,
    authorization: ?session_wal.Fact = null,
    result: ?session_wal.Fact = null,

    fn accepts(self: OperationHistory, fact: session_wal.Fact) bool {
        return self.operation_id == fact.operation_id and self.generation == fact.generation;
    }

    fn appendAttempt(self: *OperationHistory, fact: session_wal.Fact) !void {
        for (self.attempts[0..self.attempt_count]) |maybe_existing| {
            const existing = maybe_existing.?;
            if (existing.attempt_id != fact.attempt_id) continue;
            if (!std.meta.eql(existing, fact)) return error.ConflictingWalFacts;
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
    open_operation: ?session_wal.Fact = null,
    control: ?session_wal.Fact = null,
    indeterminate: ?session_wal.Fact = null,

    fn apply(self: *SemanticIndex, transaction: session_wal.Transaction) !void {
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

    fn emit(
        self: *const SemanticIndex,
        context: *anyopaque,
        apply_fn: *const fn (*anyopaque, session_wal.Transaction) anyerror!void,
    ) !void {
        var sequence: u64 = 1;
        const histories = [_]OperationHistory{ self.model, self.consequential };
        for (histories) |history| {
            const facts = [_]?session_wal.Fact{ history.descriptor, history.authorization };
            for (facts) |maybe_fact| if (maybe_fact) |fact| {
                try applyOne(context, apply_fn, sequence, fact);
                sequence += 1;
            };
            for (history.attempts[0..history.attempt_count]) |maybe_attempt| {
                try applyOne(context, apply_fn, sequence, maybe_attempt.?);
                sequence += 1;
            }
            if (history.result) |fact| {
                try applyOne(context, apply_fn, sequence, fact);
                sequence += 1;
            }
        }
        if (self.open_operation) |fact| {
            try applyOne(context, apply_fn, sequence, fact);
            sequence += 1;
        }
        if (self.indeterminate) |fact| {
            try applyOne(context, apply_fn, sequence, fact);
            sequence += 1;
        }
        if (self.control) |fact| try applyOne(context, apply_fn, sequence, fact);
    }
};

fn uniqueIndexedFact(existing: ?session_wal.Fact, fact: session_wal.Fact) !session_wal.Fact {
    if (existing) |value| {
        if (!std.meta.eql(value, fact)) return error.ConflictingWalFacts;
        return value;
    }
    return fact;
}

fn applyOne(
    context: *anyopaque,
    apply_fn: *const fn (*anyopaque, session_wal.Transaction) anyerror!void,
    sequence: u64,
    fact: session_wal.Fact,
) !void {
    var transaction: session_wal.Transaction = .{ .sequence = sequence, .fact_count = 1 };
    transaction.facts[0] = fact;
    try apply_fn(context, transaction);
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
    lock_file: std.Io.File,
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    branch_id: u64,
    ownership_epoch: u64,
    active_leaf_id: u64,
    entry_count: u64,
    wal_sequence: u64 = 0,
    semantic_index: SemanticIndex = .{},
    recovery_reader: ?session_wal.Reader = null,
    recovery_inbox_reader: ?completion_inbox.Reader = null,
    recovery_complete: bool = true,
    wal_writer: ?session_wal.Writer = null,
    inbox_index: InboxIndex = .{},
    workspace_path: [workspace_path_capacity]u8 = undefined,
    workspace_path_length: u16,
    open: bool = true,
    failed: bool = false,

    pub fn create(root: std.Io.Dir, io: std.Io, config: Config) !Session {
        for (0..8) |_| {
            var identities: Identities = undefined;
            io.random(std.mem.asBytes(&identities));
            identities.validate() catch continue;
            return createExact(root, io, .{
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

    fn createExact(root: std.Io.Dir, io: std.Io, config: CreateConfig) !Session {
        try config.identities.validate();
        if (config.workspace_path.len == 0 or config.model.len == 0 or config.task.len == 0) {
            return error.InvalidSessionMetadata;
        }
        try validateWorkspace(io, config.workspace_path);

        const initial_view: ManifestView = .{
            .identities = config.identities,
            .ownership_epoch = 1,
            .active_leaf_id = 1,
            .entry_count = 1,
            .workspace_path = config.workspace_path,
            .model = config.model,
            .task = config.task,
        };
        var validation_buffer: [manifest_max_size]u8 = undefined;
        _ = try encodeManifest(&validation_buffer, initial_view);

        var name_buffer: [16]u8 = undefined;
        const name = sessionName(config.identities.session_id, &name_buffer);
        try root.createDir(io, name, .fromMode(0o700));
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
        var wal = try session_wal.Writer.createIn(dir, io, wal_path);
        wal.close(io);
        var inbox = try completion_inbox.Writer.createIn(dir, io, inbox_path);
        inbox.close(io);
        try syncDir(dir, io);

        var conversation = try dir.createFile(io, conversation_path, .{ .exclusive = true });
        defer conversation.close(io);
        try appendEntryFile(conversation, io, 0, .{
            .kind = .user,
            .session_id = config.identities.session_id,
            .entry_id = 1,
            .parent_id = 0,
            .task_id = config.identities.task_id,
            .content_ref = config.identities.task_id,
            .sequence = 1,
        });
        try publishManifest(dir, io, initial_view);

        return fromManifest(io, dir, lock_file, initial_view, true);
    }

    pub fn openExisting(
        root: std.Io.Dir,
        io: std.Io,
        session_id: u64,
        manifest_buffer: *[manifest_max_size]u8,
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

        var view = try readManifest(dir, io, manifest_buffer);
        if (view.identities.session_id != session_id) return error.SessionIdentityMismatch;
        try validateWorkspace(io, view.workspace_path);
        if (view.ownership_epoch == std.math.maxInt(u64)) return error.OwnershipEpochExhausted;
        view.ownership_epoch += 1;
        try publishManifest(dir, io, view);

        view = try reconcileConversation(dir, io, view);
        const restored_view = try readManifest(dir, io, manifest_buffer);
        return .{
            .session = fromManifest(io, dir, lock_file, view, false),
            .manifest = restored_view,
        };
    }

    fn fromManifest(
        io: std.Io,
        dir: std.Io.Dir,
        lock_file: std.Io.File,
        view: ManifestView,
        recovery_complete: bool,
    ) Session {
        std.debug.assert(view.workspace_path.len <= workspace_path_capacity);
        var session: Session = .{
            .io = io,
            .dir = dir,
            .lock_file = lock_file,
            .session_id = view.identities.session_id,
            .agent_id = view.identities.agent_id,
            .task_id = view.identities.task_id,
            .branch_id = view.identities.branch_id,
            .ownership_epoch = view.ownership_epoch,
            .active_leaf_id = view.active_leaf_id,
            .entry_count = view.entry_count,
            .workspace_path_length = @intCast(view.workspace_path.len),
            .recovery_complete = recovery_complete,
        };
        @memcpy(session.workspace_path[0..view.workspace_path.len], view.workspace_path);
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
        var wal = try self.dir.openFile(self.io, wal_path, .{});
        defer wal.close(self.io);
        if (try wal.length(self.io) != 0) return false;
        var inbox = try self.dir.openFile(self.io, inbox_path, .{});
        defer inbox.close(self.io);
        return try inbox.length(self.io) == 0;
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
        var manifest_buffer: [manifest_max_size]u8 = undefined;
        const view = try readManifest(self.dir, self.io, &manifest_buffer);
        if (view.identities.session_id != token.session_id or
            view.ownership_epoch != token.epoch)
        {
            return error.StaleOwner;
        }
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
        var manifest_buffer: [manifest_max_size]u8 = undefined;
        var view = try readManifest(self.dir, self.io, &manifest_buffer);
        view = try reconcileConversation(self.dir, self.io, view);
        if (view.entry_count == std.math.maxInt(u64)) return error.EntryIdentityExhausted;

        const entry: ConversationEntry = .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = view.entry_count + 1,
            .parent_id = view.active_leaf_id,
            .task_id = self.task_id,
            .content_ref = content_ref,
            .sequence = view.entry_count + 1,
        };
        var conversation = try self.dir.openFile(self.io, conversation_path, .{ .mode = .read_write });
        defer conversation.close(self.io);
        const actual_count = (try conversation.length(self.io)) / conversation_record_size;
        if (actual_count == view.entry_count + 1) {
            const prepared = try readEntryFile(conversation, self.io, view.entry_count);
            if (prepared.kind != kind or prepared.content_ref != content_ref or
                prepared.parent_id != view.active_leaf_id)
            {
                return error.UncommittedConversationConflict;
            }
            return prepared;
        }
        try appendEntryFile(conversation, self.io, view.entry_count, entry);
        if (fault) |hook| try hook.reached(hook.context, .after_entry_sync);
        return entry;
    }

    fn validatePreparedConversationEntry(self: *Session, fact: session_wal.Fact) !void {
        var manifest_buffer: [manifest_max_size]u8 = undefined;
        var view = try readManifest(self.dir, self.io, &manifest_buffer);
        view = try reconcileConversation(self.dir, self.io, view);
        if (fact.subject <= view.entry_count) {
            const existing = try self.readEntry(fact.subject);
            if (existing.content_ref != fact.reference) return error.ConversationWalMismatch;
            return;
        }
        if (fact.subject != view.entry_count + 1) return error.ConversationWalGap;
        var conversation = try self.dir.openFile(self.io, conversation_path, .{});
        defer conversation.close(self.io);
        const entry = try readEntryFile(conversation, self.io, view.entry_count);
        if (entry.entry_id != fact.subject or entry.sequence != fact.subject or
            entry.parent_id != view.active_leaf_id or entry.content_ref != fact.reference or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationWalMismatch;
        }
    }

    fn publishConversationEntry(self: *Session, fact: session_wal.Fact) !void {
        if (fact.subject <= self.entry_count) return;
        std.debug.assert(fact.subject == self.entry_count + 1);
        var manifest_buffer: [manifest_max_size]u8 = undefined;
        var view = try readManifest(self.dir, self.io, &manifest_buffer);
        if (fact.subject <= view.entry_count) {
            self.active_leaf_id = view.active_leaf_id;
            self.entry_count = view.entry_count;
            return;
        }
        view.active_leaf_id = fact.subject;
        view.entry_count = fact.subject;
        try publishManifest(self.dir, self.io, view);
        self.active_leaf_id = fact.subject;
        self.entry_count = fact.subject;
    }

    fn reconstructConversationEntry(self: *Session, fact: session_wal.Fact) !void {
        try self.validatePreparedConversationEntry(fact);
        try self.publishConversationEntry(fact);
    }

    pub fn readEntry(self: *Session, sequence: u64) !ConversationEntry {
        if (!self.open) return error.SessionClosed;
        if (sequence == 0 or sequence > self.entry_count) return error.InvalidEntrySequence;
        var conversation = try self.dir.openFile(self.io, conversation_path, .{});
        defer conversation.close(self.io);
        return readEntryFile(conversation, self.io, sequence - 1);
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
        facts: []const session_wal.Fact,
        encoded_core: ?[]const u8,
    ) !u64 {
        try self.authorize(token);
        if (!self.recovery_complete) return error.SessionRecoveryIncomplete;
        if (facts.len == 0 or facts.len > session_wal.max_facts) {
            return error.InvalidSemanticFactCount;
        }
        var transaction: session_wal.Transaction = .{
            .sequence = self.wal_sequence + 1,
            .fact_count = @intCast(facts.len),
        };
        @memcpy(transaction.facts[0..facts.len], facts);
        if (encoded_core) |bytes| {
            if (bytes.len != core_state.encoded_size) return error.InvalidCoreStateLength;
            _ = try core_state.decode(bytes);
            transaction.core = bytes[0..core_state.encoded_size].*;
        }
        for (transaction.factSlice()) |fact| {
            if (fact.kind == .conversation_advanced) try self.validatePreparedConversationEntry(fact);
        }
        var prepared_index = self.semantic_index;
        try prepared_index.apply(transaction);
        if (self.wal_writer == null) {
            self.wal_writer = try session_wal.Writer.openAppendIn(self.dir, self.io, wal_path);
        }
        const writer = &self.wal_writer.?;
        if (writer.last_sequence != self.wal_sequence) return error.WalSequenceMismatch;
        try writer.append(self.io, transaction);
        self.wal_sequence = transaction.sequence;
        self.semantic_index = prepared_index;
        for (transaction.factSlice()) |fact| {
            if (fact.kind == .conversation_advanced) {
                self.publishConversationEntry(fact) catch |err| {
                    self.failed = true;
                    return err;
                };
            }
        }
        return transaction.sequence;
    }

    pub fn replaySemantic(
        self: *Session,
        token: OwnerToken,
        context: *anyopaque,
        apply: *const fn (*anyopaque, session_wal.Transaction) anyerror!void,
    ) !WalView {
        try self.authorize(token);
        if (!self.recovery_complete) return error.SessionRecoveryIncomplete;
        try self.semantic_index.emit(context, apply);
        const view: WalView = .{
            .last_sequence = self.semantic_index.last_sequence,
            .last_core = self.semantic_index.last_core,
        };
        self.wal_sequence = view.last_sequence;
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
        if (self.recovery_reader == null and self.recovery_inbox_reader == null) {
            self.semantic_index = .{};
            self.inbox_index = .{};
            self.recovery_reader = try session_wal.Reader.openIn(self.dir, self.io, wal_path);
        }
        var processed: u8 = 0;
        while (processed < frame_budget) {
            if (self.recovery_reader) |*reader| {
                const transaction = (try reader.next(self.io)) orelse {
                    const last_sequence = reader.last_sequence;
                    const valid_length = reader.cursor;
                    const physical_length = reader.length;
                    reader.close(self.io);
                    self.recovery_reader = null;
                    var writer = try session_wal.Writer.openValidatedIn(
                        self.dir,
                        self.io,
                        wal_path,
                        last_sequence,
                        valid_length,
                        physical_length,
                    );
                    self.validateCheckpointSequence(last_sequence) catch |err| {
                        writer.close(self.io);
                        return err;
                    };
                    self.wal_writer = writer;
                    self.wal_sequence = last_sequence;
                    self.recovery_inbox_reader = try completion_inbox.Reader.openIn(
                        self.dir,
                        self.io,
                        inbox_path,
                    );
                    continue;
                };
                var prepared_index = self.semantic_index;
                try prepared_index.apply(transaction);
                for (transaction.factSlice()) |fact| {
                    if (fact.kind == .conversation_advanced) try self.reconstructConversationEntry(fact);
                }
                self.semantic_index = prepared_index;
                processed += 1;
                continue;
            }
            if (self.recovery_inbox_reader) |*reader| {
                const record = (try reader.step(self.io)) orelse {
                    reader.close(self.io);
                    self.recovery_inbox_reader = null;
                    self.recovery_complete = true;
                    return .{ .processed = processed, .more = false };
                };
                switch (record) {
                    .envelope => |envelope| try self.inbox_index.apply(
                        &self.semantic_index,
                        envelope,
                        self.session_id,
                        self.agent_id,
                        self.ownership_epoch,
                    ),
                    .corrupt => {},
                }
                processed += 1;
                continue;
            }
            return error.InvalidRecoveryState;
        }
        return .{ .processed = processed, .more = true };
    }

    fn validateCheckpointSequence(self: *Session, wal_last_sequence: u64) !void {
        var checkpoint_bytes: [checkpoint.encoded_size]u8 = undefined;
        var checkpoint_file = self.dir.openFile(self.io, checkpoint_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer checkpoint_file.close(self.io);
        const actual = try checkpoint_file.readPositionalAll(self.io, &checkpoint_bytes, 0);
        if (actual != checkpoint_bytes.len) return; // A checkpoint is a rebuildable cache.
        const decoded = checkpoint.decode(&checkpoint_bytes, self.agent_id, 1) catch |err| switch (err) {
            error.UnsupportedVersion => return err,
            else => return, // Corrupt cache bytes never override the WAL prefix.
        };
        if (decoded.wal_sequence > wal_last_sequence) return error.CheckpointAheadOfWal;
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
        var result = try self.openBlob(token, envelope.result_ref);
        result.close();
        var writer = try completion_inbox.Writer.openAppendIn(self.dir, self.io, inbox_path);
        defer writer.close(self.io);
        try writer.publish(self.io, envelope);
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

    pub fn publishCheckpoint(
        self: *Session,
        token: OwnerToken,
        generation: u32,
        encoded: []u8,
        state: []const u8,
    ) !void {
        try self.authorize(token);
        try checkpoint_store.publish(
            self.dir,
            self.io,
            checkpoint_path,
            checkpoint_temp_path,
            encoded,
            self.agent_id,
            generation,
            self.wal_sequence,
            state,
            null,
        );
    }

    pub fn restoreCheckpoint(
        self: *Session,
        token: OwnerToken,
        generation: u32,
        encoded: []u8,
        state: []u8,
    ) !void {
        try self.authorize(token);
        if (encoded.len != checkpoint.encoded_size or state.len != checkpoint.state_size) {
            return error.InvalidCheckpointBuffer;
        }
        var file = try self.dir.openFile(self.io, checkpoint_path, .{});
        defer file.close(self.io);
        const actual = try file.readPositionalAll(self.io, encoded, 0);
        if (actual != encoded.len) return error.TruncatedCheckpoint;
        const restored = try checkpoint.decode(encoded, self.agent_id, generation);
        @memcpy(state, restored.state);
    }

    pub fn close(self: *Session) void {
        if (!self.open) return;
        if (self.recovery_reader) |*reader| reader.close(self.io);
        self.recovery_reader = null;
        if (self.recovery_inbox_reader) |*reader| reader.close(self.io);
        self.recovery_inbox_reader = null;
        if (self.wal_writer) |*writer| writer.close(self.io);
        self.wal_writer = null;
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

fn publishManifest(dir: std.Io.Dir, io: std.Io, view: ManifestView) !void {
    var encoded: [manifest_max_size]u8 = undefined;
    const bytes = try encodeManifest(&encoded, view);
    var temp = try dir.createFile(io, manifest_temp_path, .{});
    var temp_open = true;
    defer if (temp_open) temp.close(io);
    try temp.writePositionalAll(io, bytes, 0);
    try temp.sync(io);
    temp.close(io);
    temp_open = false;
    try dir.rename(manifest_temp_path, dir, manifest_path, io);
    try syncDir(dir, io);
}

fn readManifest(
    dir: std.Io.Dir,
    io: std.Io,
    buffer: *[manifest_max_size]u8,
) !ManifestView {
    var file = try dir.openFile(io, manifest_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size < manifest_header_size) return error.TruncatedManifest;
    if (stat.size > manifest_max_size) return error.InvalidManifestLength;
    const expected_size: usize = @intCast(stat.size);
    const bytes_read = try file.readPositionalAll(io, buffer[0..expected_size], 0);
    if (bytes_read != expected_size) return error.TruncatedManifest;
    return decodeManifest(buffer[0..bytes_read]);
}

fn encodeManifest(out: *[manifest_max_size]u8, view: ManifestView) ![]const u8 {
    try view.identities.validate();
    if (view.ownership_epoch == 0) return error.InvalidOwnershipEpoch;
    if (view.entry_count == 0 or view.active_leaf_id != view.entry_count) {
        return error.InvalidActiveLeaf;
    }
    if (view.workspace_path.len == 0 or view.workspace_path.len > workspace_path_capacity or
        view.model.len == 0 or view.task.len == 0)
    {
        return error.InvalidSessionMetadata;
    }
    const total = manifest_header_size +
        view.workspace_path.len +
        view.model.len +
        view.task.len;
    if (total > out.len or
        view.workspace_path.len > std.math.maxInt(u16) or
        view.model.len > std.math.maxInt(u16) or
        view.task.len > std.math.maxInt(u16))
    {
        return error.SessionMetadataTooLarge;
    }

    @memset(out, 0);
    @memcpy(out[0..manifest_magic.len], manifest_magic);
    write(u16, out, 8, manifest_version);
    write(u16, out, 10, manifest_header_size);
    write(u32, out, 12, 0);
    write(u32, out, 16, @intCast(total));
    write(u64, out, 24, view.identities.session_id);
    write(u64, out, 32, view.identities.agent_id);
    write(u64, out, 40, view.identities.task_id);
    write(u64, out, 48, view.identities.branch_id);
    write(u64, out, 56, view.ownership_epoch);
    write(u64, out, 64, view.active_leaf_id);
    write(u64, out, 72, view.entry_count);
    write(u16, out, 80, @intCast(view.workspace_path.len));
    write(u16, out, 82, @intCast(view.model.len));
    write(u16, out, 84, @intCast(view.task.len));
    var cursor: usize = manifest_header_size;
    @memcpy(out[cursor..][0..view.workspace_path.len], view.workspace_path);
    cursor += view.workspace_path.len;
    @memcpy(out[cursor..][0..view.model.len], view.model);
    cursor += view.model.len;
    @memcpy(out[cursor..][0..view.task.len], view.task);
    const crc = manifestCrc(out[0..total]);
    write(u32, out, manifest_crc_offset, crc);
    return out[0..total];
}

fn decodeManifest(bytes: []const u8) !ManifestView {
    if (bytes.len < manifest_header_size) return error.TruncatedManifest;
    if (!std.mem.eql(u8, bytes[0..manifest_magic.len], manifest_magic)) {
        return error.InvalidManifestMagic;
    }
    if (read(u16, bytes, 8) != manifest_version) return error.UnsupportedManifestVersion;
    if (read(u16, bytes, 10) != manifest_header_size) return error.InvalidManifestHeader;
    if (read(u32, bytes, 12) != 0) return error.UnsupportedManifestFlags;
    const total: usize = read(u32, bytes, 16);
    if (total != bytes.len or total > manifest_max_size) return error.InvalidManifestLength;
    if (read(u32, bytes, manifest_crc_offset) != manifestCrc(bytes)) {
        return error.ManifestChecksumMismatch;
    }
    for (bytes[86..manifest_header_size]) |byte| {
        if (byte != 0) return error.NonzeroManifestReservedByte;
    }

    const workspace_len: usize = read(u16, bytes, 80);
    if (workspace_len == 0 or workspace_len > workspace_path_capacity) {
        return error.InvalidSessionMetadata;
    }
    const model_len: usize = read(u16, bytes, 82);
    const task_len: usize = read(u16, bytes, 84);
    if (manifest_header_size + workspace_len + model_len + task_len != total or
        workspace_len == 0 or model_len == 0 or task_len == 0)
    {
        return error.InvalidSessionMetadata;
    }
    var cursor: usize = manifest_header_size;
    const workspace = bytes[cursor..][0..workspace_len];
    cursor += workspace_len;
    const model = bytes[cursor..][0..model_len];
    cursor += model_len;
    const task = bytes[cursor..][0..task_len];
    const view: ManifestView = .{
        .identities = .{
            .session_id = read(u64, bytes, 24),
            .agent_id = read(u64, bytes, 32),
            .task_id = read(u64, bytes, 40),
            .branch_id = read(u64, bytes, 48),
        },
        .ownership_epoch = read(u64, bytes, 56),
        .active_leaf_id = read(u64, bytes, 64),
        .entry_count = read(u64, bytes, 72),
        .workspace_path = workspace,
        .model = model,
        .task = task,
    };
    try view.identities.validate();
    if (view.ownership_epoch == 0) return error.InvalidOwnershipEpoch;
    if (view.entry_count == 0 or view.active_leaf_id != view.entry_count) {
        return error.InvalidActiveLeaf;
    }
    return view;
}

fn manifestCrc(bytes: []const u8) u32 {
    var crc: std.hash.Crc32 = .init();
    crc.update(bytes[0..manifest_crc_offset]);
    crc.update(bytes[manifest_crc_offset + @sizeOf(u32) ..]);
    return crc.final();
}

fn encodeEntry(out: *[conversation_record_size]u8, entry: ConversationEntry) !void {
    if (entry.session_id == 0 or entry.entry_id == 0 or entry.task_id == 0 or
        entry.content_ref == 0 or entry.sequence == 0 or entry.entry_id != entry.sequence)
    {
        return error.InvalidConversationEntry;
    }
    if ((entry.sequence == 1 and entry.parent_id != 0) or
        (entry.sequence > 1 and
            (entry.parent_id == 0 or entry.parent_id >= entry.entry_id)))
    {
        return error.InvalidConversationParent;
    }
    @memset(out, 0);
    @memcpy(out[0..conversation_magic.len], conversation_magic);
    write(u16, out, 8, conversation_version);
    out[10] = @intFromEnum(entry.kind);
    out[11] = 0;
    write(u64, out, 12, entry.session_id);
    write(u64, out, 20, entry.entry_id);
    write(u64, out, 28, entry.parent_id);
    write(u64, out, 36, entry.task_id);
    write(u64, out, 44, entry.content_ref);
    write(u64, out, 52, entry.sequence);
    write(u32, out, 60, std.hash.Crc32.hash(out[0..60]));
}

fn decodeEntry(bytes: *const [conversation_record_size]u8) !ConversationEntry {
    if (!std.mem.eql(u8, bytes[0..conversation_magic.len], conversation_magic)) {
        return error.InvalidConversationMagic;
    }
    if (read(u16, bytes, 8) != conversation_version) return error.UnsupportedConversationVersion;
    if (bytes[11] != 0) return error.UnsupportedConversationFlags;
    for (bytes[64..]) |byte| {
        if (byte != 0) return error.NonzeroConversationReservedByte;
    }
    if (read(u32, bytes, 60) != std.hash.Crc32.hash(bytes[0..60])) {
        return error.ConversationChecksumMismatch;
    }
    const kind: EntryKind = switch (bytes[10]) {
        1 => .user,
        2 => .assistant,
        3 => .tool_result,
        4 => .context_checkpoint,
        else => return error.InvalidConversationKind,
    };
    const entry: ConversationEntry = .{
        .kind = kind,
        .session_id = read(u64, bytes, 12),
        .entry_id = read(u64, bytes, 20),
        .parent_id = read(u64, bytes, 28),
        .task_id = read(u64, bytes, 36),
        .content_ref = read(u64, bytes, 44),
        .sequence = read(u64, bytes, 52),
    };
    var canonical: [conversation_record_size]u8 = undefined;
    try encodeEntry(&canonical, entry);
    if (!std.mem.eql(u8, bytes, &canonical)) return error.NonCanonicalConversationEntry;
    return entry;
}

fn appendEntryFile(
    file: std.Io.File,
    io: std.Io,
    expected_count: u64,
    entry: ConversationEntry,
) !void {
    const stat = try file.stat(io);
    const expected_offset = std.math.mul(u64, expected_count, conversation_record_size) catch {
        return error.ConversationTooLarge;
    };
    if (stat.size != expected_offset) return error.ConversationLengthMismatch;
    var encoded: [conversation_record_size]u8 = undefined;
    try encodeEntry(&encoded, entry);
    try file.writePositionalAll(io, &encoded, expected_offset);
    try file.sync(io);
}

fn readEntryFile(file: std.Io.File, io: std.Io, zero_based_index: u64) !ConversationEntry {
    const offset = std.math.mul(u64, zero_based_index, conversation_record_size) catch {
        return error.ConversationTooLarge;
    };
    var encoded: [conversation_record_size]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &encoded, offset);
    if (bytes_read != conversation_record_size) return error.TruncatedConversationEntry;
    return decodeEntry(&encoded);
}

fn reconcileConversation(
    dir: std.Io.Dir,
    io: std.Io,
    view: ManifestView,
) !ManifestView {
    var conversation = try dir.openFile(io, conversation_path, .{});
    defer conversation.close(io);
    const stat = try conversation.stat(io);
    if (stat.size % conversation_record_size != 0) return error.TruncatedConversationEntry;
    const actual_count = stat.size / conversation_record_size;
    if (actual_count < view.entry_count or actual_count > view.entry_count + 1) {
        return error.ConversationLengthMismatch;
    }
    if (actual_count == 0) return error.MissingConversationRoot;
    const last = try readEntryFile(conversation, io, actual_count - 1);
    if (last.session_id != view.identities.session_id or
        last.task_id != view.identities.task_id or
        last.sequence != actual_count)
    {
        return error.ConversationIdentityMismatch;
    }
    if (actual_count == view.entry_count) {
        if (last.entry_id != view.active_leaf_id) return error.ActiveLeafMismatch;
        return view;
    }
    if (last.parent_id != view.active_leaf_id) return error.ActiveLeafMismatch;
    return view;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
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
        var workspace_path: [128]u8 = undefined;
        const rendered = try std.fmt.bufPrint(
            &workspace_path,
            ".zig-cache/tmp/{s}/repo",
            .{tmp.sub_path},
        );
        return .{
            .tmp = tmp,
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
        self.sessions.close(io);
        self.workspace.close(io);
        self.tmp.cleanup();
    }
};

test "create and exact resume preserve distinct identities and one owner" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 10));
    const first_token = created.ownerToken();
    var id_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000000a", try formatId(created.session_id, &id_buffer));
    try std.testing.expectEqual(@as(u64, 1), first_token.epoch);
    try std.testing.expectEqual(@as(u64, 1), created.active_leaf_id);
    try std.testing.expectEqual(@as(u64, 1), created.entry_count);

    var busy_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.SessionBusy,
        Session.openExisting(layout.sessions, io, 10, &busy_buffer),
    );
    created.close();

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    var restored = try Session.openExisting(layout.sessions, io, 10, &manifest_buffer);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 2), restored.manifest.ownership_epoch);
    try std.testing.expectEqualStrings(layout.workspacePath(), restored.manifest.workspace_path);
    try std.testing.expectEqualStrings("fixture:repair", restored.manifest.model);
    try std.testing.expectEqualStrings("Fix the failing test", restored.manifest.task);
    try std.testing.expectEqualDeep(testConfig(layout.workspacePath(), 10).identities, restored.manifest.identities);
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

test "recovery advances only within the configured WAL frame quantum" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 80));
    for (0..5) |index| {
        _ = try created.commitSemantic(created.ownerToken(), &.{.{
            .kind = .task_admitted,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
            .subject = index + 1,
        }}, null);
    }
    created.close();

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    var restored = (try Session.openExisting(
        layout.sessions,
        io,
        80,
        &manifest_buffer,
    )).session;
    defer restored.close();
    const token = restored.ownerToken();
    const first = try restored.recoverSemanticWindow(token, 2);
    try std.testing.expectEqual(@as(u8, 2), first.processed);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u64, 0), restored.wal_sequence);
    const second = try restored.recoverSemanticWindow(token, 2);
    try std.testing.expectEqual(@as(u8, 2), second.processed);
    try std.testing.expect(second.more);
    const last = try restored.recoverSemanticWindow(token, 2);
    try std.testing.expectEqual(@as(u8, 1), last.processed);
    try std.testing.expect(!last.more);
    try std.testing.expectEqual(@as(u64, 5), restored.wal_sequence);
}

test "irrelevant inbox records cannot displace admitted Attempt evidence" {
    var semantic: SemanticIndex = .{};
    var admission: session_wal.Transaction = .{ .sequence = 1, .fact_count = 2 };
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
    var first: session_wal.Transaction = .{ .sequence = 1, .fact_count = 2 };
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
    var retry: session_wal.Transaction = .{ .sequence = 2, .fact_count = 1 };
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
    var admission: session_wal.Transaction = .{ .sequence = 1, .fact_count = 2 };
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
    var admission: session_wal.Transaction = .{ .sequence = 1, .fact_count = 1 };
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

    var invalid: session_wal.Transaction = .{ .sequence = 2, .fact_count = 2 };
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

test "conversation advances only after its WAL fact commits" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 20));
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

test "conversation records preserve parent links needed by future forks" {
    const entry: ConversationEntry = .{
        .kind = .assistant,
        .session_id = 1,
        .entry_id = 3,
        .parent_id = 1,
        .task_id = 2,
        .content_ref = 4,
        .sequence = 3,
    };
    var encoded: [conversation_record_size]u8 = undefined;
    try encodeEntry(&encoded, entry);
    try std.testing.expectEqualDeep(entry, try decodeEntry(&encoded));
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
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 30));
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

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    var restored = try Session.openExisting(layout.sessions, io, 30, &manifest_buffer);
    defer restored.session.close();
    try std.testing.expectEqual(@as(u64, 1), restored.manifest.active_leaf_id);
    try std.testing.expectEqual(@as(u64, 1), restored.manifest.entry_count);
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
    var first = try Session.create(layout.sessions, io, config);
    defer first.close();
    var second = try Session.create(layout.sessions, io, config);
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

    var plain_path_buffer: [128]u8 = undefined;
    const plain_path = try std.fmt.bufPrint(
        &plain_path_buffer,
        ".zig-cache/tmp/{s}/plain",
        .{tmp.sub_path},
    );
    try std.testing.expectError(error.NotGitWorktree, Session.createExact(sessions, io, testConfig(plain_path, 60)));

    try initTestGitWorktree(plain, io);
    var invalid = testConfig(plain_path, 70);
    invalid.identities.agent_id = invalid.identities.session_id;
    try std.testing.expectError(error.InvalidIdentity, Session.createExact(sessions, io, invalid));

    var oversized_bytes: [manifest_max_size]u8 = undefined;
    @memset(&oversized_bytes, 'x');
    var oversized = testConfig(plain_path, 75);
    oversized.task = &oversized_bytes;
    try std.testing.expectError(
        error.SessionMetadataTooLarge,
        Session.createExact(sessions, io, oversized),
    );
    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        sessions.access(io, sessionName(75, &name_buffer), .{}),
    );
}

test "resume rejects a corrupted manifest before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 80));
    created.close();

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(80, &name_buffer), .{});
    defer session_dir.close(io);
    var manifest = try session_dir.openFile(io, manifest_path, .{ .mode = .read_write });
    defer manifest.close(io);
    var byte: [1]u8 = undefined;
    _ = try manifest.readPositionalAll(io, &byte, 24);
    byte[0] ^= 1;
    try manifest.writePositionalAll(io, &byte, 24);
    try manifest.sync(io);

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.ManifestChecksumMismatch,
        Session.openExisting(layout.sessions, io, 80, &manifest_buffer),
    );
}

test "resume rejects a legacy session format before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 82));
    created.close();

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(82, &name_buffer), .{});
    defer session_dir.close(io);
    var manifest = try session_dir.openFile(io, manifest_path, .{ .mode = .read_write });
    defer manifest.close(io);
    var bytes: [manifest_max_size]u8 = undefined;
    const actual = try manifest.readPositionalAll(io, &bytes, 0);
    write(u16, &bytes, 8, 1);
    write(u32, &bytes, manifest_crc_offset, manifestCrc(bytes[0..actual]));
    try manifest.writePositionalAll(io, bytes[0..actual], 0);
    try manifest.sync(io);

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        Session.openExisting(layout.sessions, io, 82, &manifest_buffer),
    );

    var epoch_bytes: [8]u8 = undefined;
    _ = try manifest.readPositionalAll(io, &epoch_bytes, 56);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, &epoch_bytes, .little));
}

test "resume rejects a missing recorded workspace before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 85));
    created.close();
    layout.workspace.close(io);
    try layout.tmp.dir.rename("repo", layout.tmp.dir, "moved", io);
    layout.workspace = try layout.tmp.dir.openDir(io, "moved", .{});

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Session.openExisting(layout.sessions, io, 85, &manifest_buffer),
    );

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(85, &name_buffer), .{});
    defer session_dir.close(io);
    const view = try readManifest(session_dir, io, &manifest_buffer);
    try std.testing.expectEqual(@as(u64, 1), view.ownership_epoch);
}

test "resume publishes the new epoch before conversation reconstruction" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, io, testConfig(layout.workspacePath(), 90));
    created.close();

    var name_buffer: [16]u8 = undefined;
    var session_dir = try layout.sessions.openDir(io, sessionName(90, &name_buffer), .{});
    defer session_dir.close(io);
    var conversation = try session_dir.openFile(io, conversation_path, .{ .mode = .read_write });
    defer conversation.close(io);
    var byte: [1]u8 = undefined;
    _ = try conversation.readPositionalAll(io, &byte, 20);
    byte[0] ^= 1;
    try conversation.writePositionalAll(io, &byte, 20);
    try conversation.sync(io);

    var manifest_buffer: [manifest_max_size]u8 = undefined;
    try std.testing.expectError(
        error.ConversationChecksumMismatch,
        Session.openExisting(layout.sessions, io, 90, &manifest_buffer),
    );
    const view = try readManifest(session_dir, io, &manifest_buffer);
    try std.testing.expectEqual(@as(u64, 2), view.ownership_epoch);
}
