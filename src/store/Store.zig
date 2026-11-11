//! The Store type and its public entry points, then what the domain files share
//! and nothing outside src/store/ reaches: the Store's queue and fencing, statement execution,
//! identities and traces. The facade re-exports only the Store type and its value types.

const std = @import("std");
const command_reply = @import("../command_reply.zig");
const store_schema = @import("schema.zig");
const attempt = @import("../attempt.zig");
const activity_facts = @import("../activity_facts.zig");
const conversation_read = @import("../conversation_read.zig");
const session_list = @import("../session_list.zig");
const activity_read = @import("../activity_read.zig");
const tool_proposal = @import("../tool_proposal.zig");
const workspace_path = @import("../workspace_path.zig");
const store_path = @import("../store_path.zig");
const provider_route = @import("../provider_route.zig");
const outcome_code = @import("../outcome_code.zig");
const content_string = @import("../content_string.zig");
const Bounded = @import("../bounded.zig").Bounded;
const model_capability = @import("../model_capability.zig");
const session_id = @import("../session_id.zig");
const cli_value = @import("../cli_value.zig");
const content_custody = @import("../content_custody.zig");
const command_input = @import("../command_input.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const action_domain = @import("domain/action.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const skills_domain = @import("domain/skills.zig");
const content_domain = @import("domain/content.zig");
const tool_set_domain = @import("domain/tool_set.zig");
const model_facts_domain = @import("domain/model_facts.zig");
const model_catalog = @import("../model_catalog.zig");
const tool_record = @import("../tool_record.zig");
const historical_domain = @import("domain/historical.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const session_list_read = @import("domain/session_list_read.zig");
const session_report_read = @import("domain/session_report_read.zig");
const rsql = @import("rsql.zig");
const store_access = @import("access.zig");
const Access = store_access.Access;
const ReadAccess = reads_domain.ReadAccess;
const Engine = @import("engine.zig").Engine;
const Sqlite = @import("engine/Sqlite.zig");
const Kind = @import("../store_target.zig").Kind;
const Mysql = @import("engine/Mysql.zig");
const mysql_connection = @import("wire/mysql_connection.zig");
const ActionAttemptAdmission = action_domain.ActionAttemptAdmission;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const AgentDelivery = command_domain.AgentDelivery;
const AgentStart = command_domain.AgentStart;
const CoreActionInput = action_domain.CoreActionInput;
const forward_domain = @import("domain/forward.zig");
const CoreWork = action_domain.CoreWork;
const ActionResolutionCode = action_domain.ActionResolutionCode;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptAdmission = model_admission_domain.AttemptAdmission;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ReadyAction = action_domain.ReadyAction;
const CommandObservation = command_domain.CommandObservation;
const ConfigureReply = configuration_domain.ConfigureReply;
const Found = @import("access.zig").Found;
const ContentLocation = content_domain.ContentLocation;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const HistoricalView = historical_domain.HistoricalView;
const MessageReply = command_domain.MessageReply;
const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
const DispatchWork = model_admission_domain.DispatchWork;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelFailureClass = model_settlement_domain.ModelFailureClass;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const ModelOperationKind = historical_domain.ModelOperationKind;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const PrefixSeal = historical_domain.PrefixSeal;
const PublicConversationPage = reads_domain.PublicConversationPage;
const SessionObservation = reads_domain.SessionObservation;
const SessionStopReply = command_domain.SessionStopReply;
const SessionArchiveReply = command_domain.SessionArchiveReply;
const SupersedingControl = action_domain.SupersedingControl;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const Queue = @import("queue.zig").Queue;

pub const Observed = command_reply.Observed;

pub const Store = struct {
    io: std.Io,
    /// The connection, its prepared statements and an Entry's content
    /// read handle.
    engine: Engine,
    selector: Bounded(store_path.max_bytes),
    fenced: std.atomic.Value(bool) = .init(false),
    /// Advances before `release` of any entry point that changed rows, so
    /// after every successful COMMIT. An unchanged value proves no canonical
    /// fact changed since it was read; a rolled-back change also advances it.
    commit_generation: std.atomic.Value(u64) = .init(0),
    /// The Sessions the current entry point changed. Every writer touches
    /// each Session whose rows it changes, and `release` records them under
    /// the generation the commit advances to.
    touched: change_ring.Touched = .{},
    /// Which Sessions changed at recent generations: Session listing's
    /// `since` hint, touched only by the Store's holder. Owned: `openTarget` maps it
    /// and `close` unmaps it.
    changes: *change_ring.Ring,
    /// This opening's identity: a `since` token from any other opening
    /// names generations this one never counted.
    instance: [16]u8 = undefined,
    /// The Host hands out every id and sequence value, and each
    /// transaction's second; see `HostValues`. Out of line beside the
    /// change ring, so a new identity does not grow the Store.
    /// The labels of the providers whose Sessions get model Attempts, each
    /// between commas, fixed at open.
    served: provider_route.Routes = provider_route.all(.unserved),
    /// Which use holds the out-of-line scratch in this entry point.
    scratch_use: ScratchUse = .none,
    /// The batch of writes the holder is running (`Queue.Batch`). `.ready`
    /// until a write opens the transaction; `.first` while that write runs,
    /// with no savepoint, so a lone write costs BEGIN and COMMIT as before;
    /// `.open` once it commits, each later write in a savepoint; `.lost`
    /// once a rollback failed, so the batch never commits. A write outside
    /// a batch (a test's own Entry) opens and commits its own.
    batch: enum(u8) { none, ready, first, open, saved, lost } = .none,
    /// Whether the current write's savepoint is open in the batch.
    savepoint: bool = false,
    /// Release a bulk writer's cache after the queue's outer commit, not
    /// merely after the writer's savepoint. Fits existing Store padding.
    release_bulk_memory: bool = false,
    // Source-level proof only: no counters/storage in the production Store.
    testing_content_work: if (@import("builtin").is_test) TestingContentWork else void = if (@import("builtin").is_test) .{} else {},

    /// The identity allocator already lives beside the change ring. Derive
    /// its address instead of retaining a redundant pointer in the Store;
    /// these eight bytes pay for the engine union's tag on both engines.
    pub inline fn identities(self: *const Store) *HostValues {
        return &@as(*OutOfLine, @fieldParentPtr("ring", self.changes)).ids;
    }

    /// Whether nothing changed since `since` on this opening: atomics only,
    /// no lock. Never while fenced, so a read reports the failure.
    pub fn notModified(self: *const Store, since: change_ring.Token) bool {
        return !self.isFenced() and std.mem.eql(u8, &since.instance, &self.instance) and
            since.generation == self.commit_generation.load(.acquire);
    }

    pub fn open(self: *Store, io: std.Io, database_path: []const u8, selector: []const u8) !void {
        return self.openWithOptions(io, database_path, selector, .{});
    }

    pub fn inspectSessionForTesting(self: *Store, session_ref: []const u8) !SessionObservation {
        var observation: SessionObservation = undefined;
        try self.inspectSession(session_ref, &observation);
        return observation;
    }

    /// Reads the seal applicable to this frozen Operation's model.
    pub fn prefixSealForTesting(self: *Store, binding: AttemptBinding) !?PrefixSeal {
        return self.queue().run(prefixSealForTestingHeld, .{ self, binding });
    }

    fn prefixSealForTestingHeld(self: *Store, binding: AttemptBinding) !?PrefixSeal {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, historical_domain.prefixSealOf(&access, binding));
    }

    /// Records `seal` for the current `binding` through the production
    /// write (`historical.recordPrefixSeal`), whatever the seal holds.
    pub fn setPrefixSealForTesting(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        return historical_domain.recordPrefixSeal(self, binding, seal);
    }

    pub fn setHistoricalModelForTesting(self: *Store, binding: AttemptBinding, model: []const u8) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        var bounded: Bounded(model_capability.max_model_bytes) = .{};
        try bounded.set(model);
        if (bounded.len == 0) return error.InvalidModel;
        try self.engine.sqlite.setHistoricalModelForTesting(binding.operation_id, model);
    }

    /// Flips the first byte of the provider bag of the `binding` Operation's
    /// first output item, keeping its recorded length and digest, as on-disk
    /// damage would.
    pub fn damageOutputBagForTesting(self: *Store, binding: AttemptBinding) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        try self.engine.sqlite.damageOutputBagForTesting(binding.operation_id);
    }

    /// Opens in final storage. Admission borrows `target` and `selector` only
    /// for this call; the Store owns its public selector and served routes.
    /// Startup scratch must not live on the resident Host frame.
    pub noinline fn openTarget(
        self: *Store,
        io: std.Io,
        target: Target,
        selector: []const u8,
        options: OpenOptions,
    ) !void {
        errdefer self.* = undefined;
        var opened: Engine = switch (target) {
            .sqlite => |path| .{ .sqlite = try Sqlite.open(io, path, selector, options) },
            .mysql => |connection| .{ .mysql = try Mysql.open(io, connection, selector, options) },
        };
        // Preserve the admission error. Closing here only releases the partly
        // opened connection and prepared statements; there is no caller to retry.
        var opening: *Engine = &opened;
        errdefer opening.close() catch {};

        var stored_selector: Bounded(store_path.max_bytes) = .{};
        try stored_selector.set(opened.publicSelector(selector));
        const changes = try createRing();
        errdefer destroyRing(changes);
        const ids: *HostValues = &@as(*OutOfLine, @fieldParentPtr("ring", changes)).ids;
        ids.* = .{ .next = undefined };
        self.* = .{ .io = io, .engine = opened, .selector = stored_selector, .changes = changes, .served = options.served };
        // Cleanup follows the final engine too: its statement cache is populated
        // below, after the admitted value has moved to its only stable address.
        opening = &self.engine;
        self.queue().* = .init(io, .{ .context = self, .start = startBatch, .finish = finishBatch, .closed = batchClosed, .arm = armRerun, .recover = recoverRerun });
        try self.engine.serve(&self.served);
        // This opening's since tokens grant nothing; Session IDs alone use
        // secure draws. Draw before identity and tool set initialization.
        io.random(&self.instance);
        try self.engine.prepareRollback();
        try loadIdentities(self, .full);
        self.queue().opened();
        if (options.host_tool_set) |offered| try self.saveHostToolSet(offered) else {
            const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
            owned.tools = .{ .host_tool_set = &tool_record.built_in_tool_set, .set_id = 0 };
        }
    }

    /// Compatibility convenience; all initialization belongs to openTarget.
    pub fn openWithOptions(self: *Store, io: std.Io, database_path: []const u8, selector: []const u8, options: OpenOptions) !void {
        return self.openTarget(io, .{ .sqlite = database_path }, selector, options);
    }

    /// Atomically replaces the saved models.dev generation. Access flushes
    /// bounded statement batches inside this one transaction: with model_id
    /// as the key, intermediate commits would destroy the previous copy.
    pub fn saveModelFacts(self: *Store, entries: []const model_catalog.Entry, etag: ?[]const u8) !void {
        if (etag) |value| if (value.len > 512) return error.InvalidCatalogEtag;
        return self.queue().write(saveModelFactsHeld, .{ self, entries, etag });
    }

    fn saveModelFactsHeld(self: *Store, entries: []const model_catalog.Entry, etag: ?[]const u8) !void {
        const entry = try enter(self, .none);
        defer {
            // Access has reset its statements and committed or rolled back.
            // Keep the maintenance hint inside this serialized queue entry.
            if (self.batch == .none) self.engine.releaseUnusedMemory(model_facts_domain.save_statements) else self.release_bulk_memory = true;
            entry.release();
        }
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, model_facts_domain.save(&access, entries, etag)));
    }

    /// The selected generation for one operation. Saved entries/IDs belong to
    /// the caller's arena; without a source this borrows the shipped snapshot.
    /// Store failures propagate through the normal read/fencing boundary.
    pub fn readModelCatalog(self: *Store, arena: std.mem.Allocator) ![]const model_catalog.Entry {
        return self.queue().run(readModelCatalogHeld, .{ self, arena });
    }

    fn readModelCatalogHeld(self: *Store, arena: std.mem.Allocator) ![]const model_catalog.Entry {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{OutOfMemory}) = .open(&entry);
        defer access.deinit();
        const facts = model_facts_domain.readSelected(&access, arena);
        return entry.finish(error{OutOfMemory}, facts);
    }

    pub fn readModelCatalogSource(self: *Store) !?model_facts_domain.Source {
        return self.queue().run(readModelCatalogSourceHeld, .{self});
    }

    fn readModelCatalogSourceHeld(self: *Store) !?model_facts_domain.Source {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        var result: ?model_facts_domain.Source = null;
        access.read(model_facts_domain.source, .{}, &result);
        try entry.finish(Ordinary.none, access.run());
        return result;
    }

    pub fn modelFact(self: *Store, id: []const u8) !?model_facts_domain.Fact {
        return self.queue().run(modelFactHeld, .{ self, id });
    }

    fn modelFactHeld(self: *Store, id: []const u8) !?model_facts_domain.Fact {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        var result: ?model_facts_domain.Fact = null;
        access.read(model_facts_domain.fact, .{ .id = id }, &result);
        try entry.finish(Ordinary.none, access.run());
        return result;
    }

    /// Caller owns the returned IDs and slice; free each ID and the slice.
    pub fn readOpenAiModelIds(self: *Store, allocator: std.mem.Allocator) ![][]const u8 {
        return self.queue().run(readOpenAiModelIdsHeld, .{ self, allocator });
    }

    fn readOpenAiModelIdsHeld(self: *Store, allocator: std.mem.Allocator) ![][]const u8 {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        var ids: ModelIds = .{ .allocator = allocator };
        errdefer {
            for (ids.items.items) |id| allocator.free(id);
            ids.items.deinit(allocator);
        }
        access.readEach(model_facts_domain.openai_ids, .{}, std.math.maxInt(u64), &ids);
        try entry.finish(Ordinary.none, access.run());
        if (ids.failed) return error.OutOfMemory;
        return ids.items.toOwnedSlice(allocator);
    }

    /// Compatibility convenience; all initialization belongs to openTarget.
    pub fn openMysql(self: *Store, io: std.Io, connection: mysql_connection.Options, selector: []const u8, options: OpenOptions) !void {
        return self.openTarget(io, .{ .mysql = connection }, selector, options);
    }

    pub fn kind(self: *const Store) Kind {
        return std.meta.activeTag(self.engine);
    }

    /// Borrowed until close: canonical path on SQLite, admitted opaque id on
    /// MySQL. SQLite's persisted random id is not its protocol selector.
    pub fn storeId(self: *const Store) []const u8 {
        return self.selector.slice();
    }

    /// Immutable admission facts only: safe on the nonblocking host-info path.
    pub fn admissionDiagnostic(self: *const Store) AdmissionDiagnostic {
        return .{ .doublewrite = self.engine.admissionDoublewrite() };
    }

    /// The tools the Host offers, and the id of their saved set.
    pub fn hostTools(self: *Store) *const HostTools {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.tools;
    }

    /// Saves `offered` as the Host tool set, if no set holds it yet: its
    /// records a few to a transaction, then the set in one more. It becomes
    /// the tool set `readHostToolSet` reads back. Once per open, before any
    /// request.
    pub fn saveHostToolSet(self: *Store, offered: *const tool_record.HostToolSet) !void {
        if (!offered.valid()) return error.InvalidHostToolSet;
        for (std.enums.values(tool_record.Tool)) |tool| {
            const index = offered.find(@tagName(tool)) orelse return error.InvalidHostToolSet;
            if (!std.mem.eql(u8, &offered.digests[index], &tool_record.built_in_tool_set.digests[@backingInt(tool)])) return error.InvalidHostToolSet;
        }
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        owned.tools = .{ .host_tool_set = offered, .set_id = 0 };
        const digest = tool_set_domain.toolSetDigest(offered);
        if (try self.queue().write(saveHostToolSetHeld, .{ self, offered, &digest, @as(?usize, null) })) |set_id| {
            owned.tools.set_id = set_id;
            return;
        }
        var start: usize = 0;
        while (start < offered.records.len) : (start += tool_set_domain.records_per_transaction)
            _ = try self.queue().write(saveHostToolSetHeld, .{ self, offered, &digest, start });
        owned.tools.set_id = (try self.queue().write(saveHostToolSetHeld, .{ self, offered, &digest, offered.records.len })).?;
    }

    /// One transaction of `saveHostToolSet`: with `start` null, the saved set's
    /// id, or null when none holds `offered`; below the record count, the
    /// records from `start`; at it, the set, whose id it returns.
    fn saveHostToolSetHeld(self: *Store, offered: *const tool_record.HostToolSet, digest: *const [32]u8, start: ?usize) !?u64 {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, saveHostToolSetStep(&access, offered, digest, start)));
    }

    /// The Host tool set the last `saveHostToolSet` saved, read back with every
    /// text, in `allocator`'s memory; null before the first. A Host reads
    /// it at start to keep the tools of a server it cannot reach. A saved
    /// tool set that fails its checks fences the Store.
    pub fn readHostToolSet(self: *Store, allocator: std.mem.Allocator) !?SavedHostToolSet {
        return self.readHostToolSetChecked(allocator) catch |err| switch (err) {
            error.CorruptStore => fence(self, error.CorruptStore),
            else => err,
        };
    }

    fn readHostToolSetChecked(self: *Store, allocator: std.mem.Allocator) !?SavedHostToolSet {
        const head = (try self.readHostToolSetSet()) orelse return null;
        const count = std.math.cast(usize, head.member_count) orelse return error.CorruptStore;
        if (count > tool_record.max_host_tool_records) return error.CorruptStore;
        const rows = try allocator.alloc(tool_set_domain.host_tool_records.Row, count);
        defer allocator.free(rows);
        var filled: usize = 0;
        while (filled < count) {
            const read = try self.readHostToolSetRecords(head.tool_set_id.get(), filled, rows[filled..]);
            if (read == 0) return error.CorruptStore;
            filled += read;
        }
        var text_bytes: usize = 0;
        for (rows, 0..) |*row, ordinal| {
            if (row.ordinal != ordinal or row.description_private or row.schema_private) return error.CorruptStore;
            text_bytes += row.name.slice().len + row.server.slice().len;
            text_bytes += std.math.cast(usize, row.description_length) orelse return error.CorruptStore;
            text_bytes += std.math.cast(usize, row.schema_length) orelse return error.CorruptStore;
        }
        var saved: SavedHostToolSet = .{
            .records = try allocator.alloc(tool_record.Record, count),
            .digests = &.{},
            .texts = &.{},
        };
        errdefer saved.deinit(allocator);
        saved.digests = try allocator.alloc([32]u8, count);
        saved.texts = try allocator.alloc(u8, text_bytes);
        var used: usize = 0;
        for (rows, saved.records, saved.digests) |*row, *out, *digest| {
            const name = take(saved.texts, &used, row.name.slice().len);
            @memcpy(name, row.name.slice());
            const server = take(saved.texts, &used, row.server.slice().len);
            @memcpy(server, row.server.slice());
            const description = take(saved.texts, &used, @intCast(row.description_length));
            const schema = take(saved.texts, &used, @intCast(row.schema_length));
            try self.readHostToolSetText(row.description_id.get(), description);
            try self.readHostToolSetText(row.schema_id.get(), schema);
            if (!std.mem.eql(u8, &content_string.digest(description), &row.description_digest) or
                !std.mem.eql(u8, &content_string.digest(schema), &row.schema_digest)) return error.CorruptStore;
            out.* = .{ .name = name, .owner = row.owner, .server = server, .read_only = row.read_only, .description = description, .input_schema = schema };
            digest.* = tool_record.recordDigest(out);
        }
        if (!saved.toolSet().valid()) return error.CorruptStore;
        return saved;
    }

    fn take(texts: []u8, used: *usize, length: usize) []u8 {
        defer used.* += length;
        return texts[used.*..][0..length];
    }

    /// The Host's Host tool set and its record count, in one round.
    pub fn readHostToolSetSet(self: *Store) !tool_set_domain.SavedHostToolSet {
        return self.queue().run(readHostToolSetSetHeld, .{self});
    }

    /// One round: the Host tool set's records from `ordinal`, at most one
    /// batch and `rows.len`; how many it read.
    pub fn readHostToolSetRecords(self: *Store, set: u64, ordinal: usize, rows: []tool_set_domain.host_tool_records.Row) !usize {
        return self.queue().run(readHostToolSetRecordsHeld, .{ self, set, ordinal, rows });
    }

    fn readHostToolSetSetHeld(self: *Store) !tool_set_domain.SavedHostToolSet {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, tool_set_domain.savedHostToolSetOf(&access));
    }

    fn readHostToolSetRecordsHeld(self: *Store, set: u64, ordinal: usize, rows: []tool_set_domain.host_tool_records.Row) !usize {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, tool_set_domain.hostToolRecordsOf(&access, set, ordinal, rows));
    }

    /// `destination` from the content row `content_id`, a window at a time.
    pub fn readHostToolSetText(self: *Store, content_id: u64, destination: []u8) !void {
        var start: usize = 0;
        while (start < destination.len) {
            const window = destination[start..][0..@min(destination.len - start, content_domain.ContentReader.content_window_bytes)];
            try self.queue().run(readHostToolSetTextHeld, .{ self, content_id, start, window });
            start += window.len;
        }
    }

    fn readHostToolSetTextHeld(self: *Store, content_id: u64, start: usize, window: []u8) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, access.readRaw(content_id, start, window));
    }

    pub fn diagnostic(self: *Store) Diagnostic {
        return self.queue().run(diagnosticHeld, .{self});
    }

    fn diagnosticHeld(self: *Store) Diagnostic {
        return self.engine.diagnostic();
    }

    /// The SQLite connection, for SQLite-only tests and fixtures.
    pub fn sqliteDatabase(self: *const Store) Sqlite.Database {
        return self.engine.sqlite.database;
    }

    pub fn close(self: *Store) !void {
        // Every caller has its answer, so the queue is empty.
        self.queue().closing();
        const closed = self.engine.close();
        // Freed even when the engine keeps its connection: nothing retries a close.
        destroyRing(self.changes);
        try closed;
        self.* = undefined;
    }

    /// Model settlement's batch table, in the Store's scratch beside its
    /// change ring (`OutOfLine`), so no frame on the engine thread holds
    /// it. Only `settleModelSuccess` uses it.
    pub fn settlementBatch(self: *Store) *model_settlement_domain.Batch {
        return @ptrCast(self.scratch(.settlement));
    }

    /// What a configure reads, over 4.6 KB, in the Store's scratch beside
    /// its change ring (`OutOfLine`), so no Host stack frame holds it. A
    /// configure or a creating Message uses it.
    pub fn configurationReads(self: *Store) *configuration_domain.ConfigurationReads {
        return @ptrCast(self.scratch(.configuration));
    }

    /// A report's large state, a `T` such as its tool names, in the
    /// Store's scratch so no Host stack frame holds it. A report takes it
    /// for one value at a time: the next take overwrites the last.
    pub fn reportScratch(self: *Store, comptime T: type) *T {
        comptime std.debug.assert(@sizeOf(T) <= scratch_bytes and @alignOf(T) <= scratch_align);
        return @ptrCast(@alignCast(self.scratch(.report)));
    }

    /// The one thread that touches `engine`, the scratch and `ids`,
    /// beside the change ring (`OutOfLine`).
    /// The event set after each commit, null while no dispatch loop waits.
    pub fn commitWake(self: *Store) *std.atomic.Value(?*std.Io.Event) {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.commit_wake;
    }

    pub fn queue(self: *Store) *Queue {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.queue;
    }

    /// The scratch for `use`. Safe builds check that the caller owns the
    /// connection (`Queue.owner`), and that no other use took the scratch in this entry point:
    /// the two share its bytes. `Entry.release` frees it.
    fn scratch(self: *Store, use: ScratchUse) *align(scratch_align) [scratch_bytes]u8 {
        std.debug.assert(self.queue().owned());
        std.debug.assert(self.scratch_use == .none or self.scratch_use == use);
        self.scratch_use = use;
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.scratch;
    }

    pub fn validateRetryWaits(self: *Store, waits_ms: retry_policy.Waits) !void {
        try retry_policy.validateWaits(waits_ms, try readUnixMilliseconds(self.io));
    }

    /// Admission preparation uses this only as a replay hint. The writer always
    /// checks the original key and digest again before applying captured effects.
    pub fn commandExists(self: *Store, key: []const u8) !bool {
        return self.queue().run(commandExistsHeld, .{ self, key, null, null });
    }

    fn commandExistsHeld(self: *Store, key: []const u8, parent: ?[]const u8, workspace: ?*Bounded(workspace_path.max_bytes)) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, Ordinary.none) = .open(&entry);
        defer access.deinit();
        if (parent) |reference| {
            var row: configuration_domain.creation_hint.Row = .{ .replay = false, .workspace = workspace.? };
            var found: @import("access.zig").Found = .missing;
            access.readInto(configuration_domain.creation_hint, .{ .key = key, .parent = reference }, &row, &found);
            return entry.finish(Ordinary.none, creationHintOn(&access, &row, &found));
        }
        return entry.finish(Ordinary.none, commandExistsOn(&access, key));
    }

    fn commandExistsOn(a: anytype, key: []const u8) !bool {
        var saved: command_domain.saved_command.Result = undefined;
        command_domain.lookupCommand(a, key, &saved);
        try a.run();
        return saved != null;
    }

    /// Replay hint plus the inherited Workspace in the same preflight round.
    pub fn creationHint(self: *Store, key: []const u8, parent: []const u8, workspace: *Bounded(workspace_path.max_bytes)) !bool {
        return self.queue().run(commandExistsHeld, .{ self, key, parent, workspace });
    }

    fn creationHintOn(a: anytype, row: *const configuration_domain.creation_hint.Row, found: *const @import("access.zig").Found) !bool {
        try a.run();
        if (!found.get()) return error.CorruptStore;
        return row.replay;
    }

    pub const SkillsState = struct {
        workspace: Bounded(workspace_path.max_bytes) = .{ .len = 0 },
        catalog: @import("../skills.zig").Catalog = .{ .entries = &.{} },
    };

    /// The immutable workspace and current metadata are copied before filesystem
    /// effects. No Store lock remains held while a skill is read or scanned.
    pub fn readSkills(self: *Store, allocator: std.mem.Allocator, session: []const u8) !*SkillsState {
        const out = try allocator.create(SkillsState);
        out.* = .{ .workspace = .{ .len = 0 } };
        try self.queue().run(readSkillsHeld, .{ self, allocator, session, out });
        return out;
    }

    fn readSkillsHeld(self: *Store, allocator: std.mem.Allocator, session: []const u8, out: *SkillsState) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        // Decoding the catalog allocates from the caller's memory; running
        // out of it is the caller's to answer, not canonical corruption.
        var access: Access(.read, error{ SessionNotFound, OutOfMemory }) = .open(&entry);
        defer access.deinit();
        return entry.finish(error{ SessionNotFound, OutOfMemory }, readSkillsOn(&access, allocator, session, out));
    }

    fn readSkillsOn(a: anytype, allocator: std.mem.Allocator, session: []const u8, out: *SkillsState) !void {
        var row: skills_domain.latest.Row = .{ .workspace = &out.workspace, .session = undefined, .catalog_content_id = null, .byte_length = null, .digest = null };
        var found: store_access.Found = .missing;
        a.readInto(skills_domain.latest, .{ .session = session }, &row, &found);
        try a.run();
        if (!found.get()) return error.SessionNotFound;
        out.catalog = try skills_domain.read(a, allocator, session);
    }

    /// A configuration that requires a model is rejected when the Host does
    /// not serve its Session's provider.
    pub fn configure(
        self: *Store,
        command: *const content_custody.ConfigureCommand,
        faults: Faults,
    ) error{OutOfMemory}!ConfigureReply {
        return self.configureWithInitialSkills(command, null, null, faults);
    }

    /// A Host-resolved preset or its refusal uses the same key lookup,
    /// rejection persistence and transaction as every other configure.
    /// Borrows `preset` until the synchronous queued write returns.
    pub fn configureWithPreset(
        self: *Store,
        command: *const content_custody.ConfigureCommand,
        preset: *const configuration_domain.PresetDecision,
        faults: Faults,
    ) error{OutOfMemory}!ConfigureReply {
        return self.configureWithInitialSkills(command, preset, null, faults);
    }

    pub fn configureWithInitialSkills(self: *Store, command: *const content_custody.ConfigureCommand, preset: ?*const configuration_domain.PresetDecision, initial_skills: ?*const skills_domain.Initial, faults: Faults) error{OutOfMemory}!ConfigureReply {
        return self.configureWithCapturedSkills(command, preset, initial_skills, null, std.heap.c_allocator, faults);
    }

    pub fn configureWithCapturedSkills(self: *Store, command: *const content_custody.ConfigureCommand, preset: ?*const configuration_domain.PresetDecision, initial_skills: ?*const skills_domain.Initial, reload_capture: ?*const skills_domain.Capture, allocator: std.mem.Allocator, faults: Faults) error{OutOfMemory}!ConfigureReply {
        return self.configureWithCreationCommitted(command, preset, initial_skills, reload_capture, allocator, null, faults);
    }

    /// Configure's creation callback follows the same real COMMIT boundary as
    /// MessageCommitted, including batch rollback/recovery and exact replay.
    pub const CreationCommitted = struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque, session: []const u8) void,
    };

    pub fn configureWithCreationCommitted(self: *Store, command: *const content_custody.ConfigureCommand, preset: ?*const configuration_domain.PresetDecision, initial_skills: ?*const skills_domain.Initial, reload_capture: ?*const skills_domain.Capture, allocator: std.mem.Allocator, committed: ?CreationCommitted, faults: Faults) error{OutOfMemory}!ConfigureReply {
        return self.queue().write(configureHeld, .{ self, command, preset, initial_skills, reload_capture, allocator, committed, faults });
    }

    fn configureHeld(
        self: *Store,
        command: *const content_custody.ConfigureCommand,
        preset: ?*const configuration_domain.PresetDecision,
        initial_skills: ?*const skills_domain.Initial,
        reload_capture: ?*const skills_domain.Capture,
        allocator: std.mem.Allocator,
        committed: ?CreationCommitted,
        faults: Faults,
    ) error{OutOfMemory}!ConfigureReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{SessionUpdateFailed}) = .open(&entry);
        defer access.deinit();
        // Running out of memory, the caller's for a reload or the engine's,
        // rolls the write back cleanly and is the caller's to answer.
        var reply = entry.finishTransaction(error{OutOfMemory}, faults, access.end(faults, configuration_domain.configure(&access, self.io, self.served, command, preset, initial_skills, reload_capture, allocator, committed, faults))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .infrastructure_failure,
        };
        if (reply == .rejected and reply.rejected.code == .mcp_server_unavailable)
            reply.rejected.message = configuration_domain.missingToolMessage(self.hostTools().host_tool_set, &command.configuration.tools);
        return reply;
    }

    /// A fresh Message admission, as `MessageCommitted` receives it.
    pub const MessageAdmission = struct {
        /// The admitted Session, borrowed for the call.
        session: []const u8,
        /// Store-wide, increasing with each admission.
        admission_id: u64,
        /// The sender was another Session's Action, not a person.
        from_peer: bool,
    };

    /// Called, on whichever thread holds the Store, once a fresh Message
    /// admission's write succeeds and before the Store runs another request, so whatever reads the Store next also sees its effect.
    /// In a batch it runs once the batch's COMMIT succeeds, before any of its writers hears an answer, so a batch that fails or runs again calls nothing for the attempt that saved nothing.
    /// A replayed or rejected Message calls nothing. It cannot fail.
    pub const MessageCommitted = struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque, admission: MessageAdmission) void,
    };

    /// A Message's `require_model` condition checks that the Host serves its
    /// Session's provider before creating anything.
    pub fn submitMessageWithModel(
        self: *Store,
        command: *const content_custody.MessageCommand,
        committed: ?MessageCommitted,
        faults: Faults,
    ) MessageReply {
        return self.submitMessageWithInitialSkills(command, committed, null, faults);
    }

    pub fn submitMessageWithInitialSkills(self: *Store, command: *const content_custody.MessageCommand, committed: ?MessageCommitted, initial_skills: ?*const skills_domain.Initial, faults: Faults) MessageReply {
        return self.submitMessageCapturedSkills(command, committed, initial_skills, null, faults);
    }

    pub fn submitMessageCapturedSkills(self: *Store, command: *const content_custody.MessageCommand, committed: ?MessageCommitted, initial_skills: ?*const skills_domain.Initial, captured_skill: ?*const skills_domain.MessageCapture, faults: Faults) MessageReply {
        return self.queue().write(submitMessageWithModelHeld, .{ self, command, committed, initial_skills, captured_skill, faults });
    }

    fn submitMessageWithModelHeld(
        self: *Store,
        command: *const content_custody.MessageCommand,
        committed: ?MessageCommitted,
        initial_skills: ?*const skills_domain.Initial,
        captured_skill: ?*const skills_domain.MessageCapture,
        faults: Faults,
    ) MessageReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{SessionUpdateFailed}) = .open(&entry);
        defer access.deinit();
        var reply = entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.submitMessage(&access, self.io, self.served, self.selector.slice(), command, committed, initial_skills, captured_skill, faults))) catch .infrastructure_failure;
        if (reply == .rejected and reply.rejected.code == .mcp_server_unavailable)
            reply.rejected.message = configuration_domain.missingToolMessage(self.hostTools().host_tool_set, &command.configuration.?.tools);
        return reply;
    }

    pub fn stopSession(
        self: *Store,
        command: *const command_input.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(stopSessionHeld, .{ self, command, faults });
    }

    fn stopSessionHeld(
        self: *Store,
        command: *const command_input.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ InterruptionTargetChanged, StopSelectionChanged }) = .open(&entry);
        defer access.deinit();
        return self.noteControl(entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.stopSession(&access, command, faults))) catch .infrastructure_failure);
    }

    pub fn archiveSession(self: *Store, command: *const command_input.SessionArchiveCommand, faults: Faults) SessionArchiveReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(archiveSessionHeld, .{ self, command, faults });
    }

    fn archiveSessionHeld(self: *Store, command: *const command_input.SessionArchiveCommand, faults: Faults) SessionArchiveReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ InterruptionTargetChanged, StopSelectionChanged }) = .open(&entry);
        defer access.deinit();
        return self.noteControl(entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.archiveSession(&access, command, faults))) catch .infrastructure_failure);
    }

    /// The stop an attached child owes (D38), as `nextCoreWork` names it.
    pub fn stopOwedSession(self: *Store, command: *const command_input.SessionStopCommand, faults: Faults) SessionStopReply {
        return self.queue().write(stopOwedSessionHeld, .{ self, command, faults });
    }

    fn stopOwedSessionHeld(self: *Store, command: *const command_input.SessionStopCommand, faults: Faults) SessionStopReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ InterruptionTargetChanged, StopSelectionChanged }) = .open(&entry);
        defer access.deinit();
        return self.noteControl(entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.stopOwedSession(&access, command, faults))) catch .infrastructure_failure);
    }

    pub fn interruptModel(
        self: *Store,
        command: *const command_input.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(interruptModelHeld, .{ self, command, faults });
    }

    fn interruptModelHeld(
        self: *Store,
        command: *const command_input.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{InterruptionTargetChanged}) = .open(&entry);
        defer access.deinit();
        return self.noteControl(entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.interruptModel(&access, command, faults))) catch .infrastructure_failure);
    }

    pub fn decidePermission(
        self: *Store,
        command: *const command_input.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(decidePermissionHeld, .{ self, command, faults });
    }

    fn decidePermissionHeld(
        self: *Store,
        command: *const command_input.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return self.noteControl(entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.decidePermission(&access, command, faults))) catch .infrastructure_failure);
    }

    /// Tier 1: atomics only, with no holder or connection access.
    fn unchangedSession(self: *const Store, since: ?change_ring.SessionToken) ?change_ring.SessionToken {
        const token = since orelse return null;
        return if (self.notModified(.{ .instance = token.instance, .generation = token.generation })) token else null;
    }

    /// Tier 2: called only under the holder, before opening read access.
    fn unchangedSessionHeld(self: *const Store, since: ?change_ring.SessionToken, generation: u64) ?change_ring.SessionToken {
        const token = since orelse return null;
        if (std.mem.eql(u8, &token.instance, &self.instance) and token.generation <= generation and
            !self.changes.mayHaveChanged(&token.session, token.generation, generation)) return token.at(generation);
        return null;
    }

    fn sessionSince(session: []const u8, since: ?change_ring.SessionToken) ?change_ring.SessionToken {
        const token = since orelse return null;
        return if (std.mem.eql(u8, session, &token.session)) token else null;
    }

    /// Tokens cover follow polling after the unpinned forward page is drained,
    /// not another slice of a bounded, backward or intra-position traversal.
    fn activitySince(request: *const activity_read.ActivityPage) ?change_ring.SessionToken {
        if (request.direction != .forward or request.end != null or request.ordinal != null) return null;
        return sessionSince(request.session.slice(), request.since);
    }

    pub fn observeCommand(self: *Store, key: []const u8, since: ?change_ring.SessionToken, out: *Observed) !void {
        if (self.unchangedSession(since)) |token| {
            out.* = .{ .not_modified = token };
            return;
        }
        return self.queue().run(observeCommandHeld, .{ self, key, since, out });
    }

    fn observeCommandHeld(self: *Store, key: []const u8, since: ?change_ring.SessionToken, out: *Observed) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        // Capture before any reads, just as for a Session listing. The ring
        // belongs to this holder; a sibling's commit needs no database read.
        const generation = self.commitGeneration();
        if (self.unchangedSessionHeld(since, generation)) |token| {
            out.* = .{ .not_modified = token };
            return;
        }
        out.* = .{ .full = .{ .token = null } };
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        try entry.finish(Ordinary.none, command_domain.observeCommand(&access, key, &out.full.observation));
        const observation = &out.full.observation;
        if (observation.status != .absent and session_id.valid(observation.target.slice())) {
            out.full.token = .{ .instance = self.instance, .generation = generation, .session = observation.target.slice()[0..session_id.bytes].* };
        }
    }

    pub fn commandResult(self: *Store, key: []const u8) !ContentReference {
        return self.queue().run(commandResultHeld, .{ self, key });
    }

    fn commandResultHeld(self: *Store, key: []const u8) !ContentReference {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.result, command_domain.commandResult(&access, key));
    }

    pub fn inspectSession(self: *Store, session_ref: []const u8, out: *SessionObservation) !void {
        return self.queue().run(inspectSessionHeld, .{ self, session_ref, out });
    }

    fn inspectSessionHeld(self: *Store, session_ref: []const u8, out: *SessionObservation) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, reads_domain.inspectSession(&access, session_ref, out));
    }

    // Reverse chronological, with call order breaking ties at a completed
    // group's final acceptance position. No transaction survives this call.
    // The fixed end is the last committed position at the first read, not a
    // count of visible rows; a private-only append cannot become public later.
    pub fn publicConversationPage(self: *Store, request: *const conversation_read.ConversationPage, out: *PublicConversationPage) !void {
        return self.queue().run(publicConversationPageHeld, .{ self, request, out });
    }

    fn publicConversationPageHeld(self: *Store, request: *const conversation_read.ConversationPage, out: *PublicConversationPage) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.publicConversationPage(&access, request, out));
    }

    // Resolve the public identity again, rather than accepting a global digest:
    // another Session's content or private provider material is not authority.
    pub fn openPublicConversationContent(self: *Store, request: *const conversation_read.ConversationContent) !ContentLocation {
        return self.queue().run(openPublicConversationContentHeld, .{ self, request });
    }

    fn openPublicConversationContentHeld(self: *Store, request: *const conversation_read.ConversationContent) !ContentLocation {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.public_content, reads_domain.openPublicConversationContent(&access, request));
    }

    pub fn activityPage(self: *Store, request: *const activity_read.ActivityPage, out: *activity_facts.Page) !void {
        try request.validate();
        if (self.unchangedSession(activitySince(request))) |token| {
            out.not_modified = true;
            out.token = token;
            return;
        }
        return self.queue().run(activityPageHeld, .{ self, request, out });
    }

    fn activityPageHeld(self: *Store, request: *const activity_read.ActivityPage, out: *activity_facts.Page) !void {
        try request.validate();
        const entry = try enter(self, .none);
        defer entry.release();
        const generation = self.commitGeneration();
        if (self.unchangedSessionHeld(activitySince(request), generation)) |token| {
            out.not_modified = true;
            out.token = token;
            return;
        }
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        try entry.finish(Ordinary.page, reads_domain.activityPage(&access, request, out));
        // Retry deadlines change the footer without a commit. Pending may be
        // an elapsed retry and become retrying again after a wall-clock step.
        // Exclude both states rather than retain another copy of retry facts.
        // Only a drained, unpinned forward page grants a follow token.
        if (request.direction == .forward and request.end == null and !out.more and
            out.work.work.state != .retrying and out.work.work.state != .pending) out.token = .{
            .instance = self.instance,
            .generation = generation,
            .session = request.session.slice()[0..session_id.bytes].*,
        };
    }

    pub fn searchActivity(self: *Store, request: *const activity_read.ActivitySearch, out: *activity_facts.Search) !void {
        return self.queue().run(searchActivityHeld, .{ self, request, out });
    }

    fn searchActivityHeld(self: *Store, request: *const activity_read.ActivitySearch, out: *activity_facts.Search) !void {
        try request.validate();
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.searchActivity(&access, request, out));
    }

    pub fn openActivityContent(self: *Store, request: *const activity_read.ReadActivityContent) !ContentLocation {
        return self.queue().run(openActivityContentHeld, .{ self, request });
    }

    fn openActivityContentHeld(self: *Store, request: *const activity_read.ReadActivityContent) !ContentLocation {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, reads_domain.openActivityContent(&access, request));
    }

    pub fn activityTool(self: *Store, request: *const activity_read.ReadActivityContent) !reads_domain.ActivityTool {
        return self.queue().run(activityToolHeld, .{ self, request });
    }

    fn activityToolHeld(self: *Store, request: *const activity_read.ReadActivityContent) !reads_domain.ActivityTool {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, reads_domain.activityTool(&access, request));
    }

    /// Authenticates the Session/Operation/Attempt before reading optional
    /// diagnostics. Diagnostic faults never fence canonical state.
    pub fn failedResponseBinding(self: *Store, session_ref: []const u8, operation: u64, attempt_ordinal: u64) !AttemptBinding {
        return self.queue().run(failedResponseBindingHeld, .{ self, session_ref, operation, attempt_ordinal });
    }

    fn failedResponseBindingHeld(self: *Store, session_ref: []const u8, operation: u64, attempt_ordinal: u64) !AttemptBinding {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, report_domain.failedResponseBinding(&access, session_ref, operation, attempt_ordinal));
    }

    /// Reads the report of `session_ref` under one Entry and hands it to
    /// `visitor` (`session_report_read.readSessionReport`). An error the
    /// visitor returns, or its capture's while the Store writes the Full
    /// profile into it, is its own and does not fence the Store.
    pub fn readSessionReport(self: *Store, session_ref: []const u8, profile: cli_value.ReportProfile, visitor: anytype) !void {
        var watched: session_report_read.Watched(@TypeOf(visitor)) = .{ .visitor = visitor };
        try self.queue().run(SessionReportHeld(@TypeOf(visitor)).readSessionReportHeld, .{ self, session_ref, profile, &watched });
    }

    fn SessionReportHeld(comptime Visitor: type) type {
        return struct {
            fn readSessionReportHeld(self: *Store, session_ref: []const u8, profile: cli_value.ReportProfile, watched: *session_report_read.Watched(Visitor)) !void {
                const entry = try enter(self, .none);
                defer entry.release();
                var access: ReadAccess = .open(&entry);
                defer access.deinit();
                const result = session_report_read.readSessionReport(&access, session_ref, profile, watched);
                return entry.finishCapture(watched.failed, result);
            }
        };
    }

    /// Reads one list page under one Entry and hands it to `visitor`
    /// (`session_list_read.readSessionList`). An error the visitor returns
    /// is its own and does not fence the Store.
    pub fn readSessionList(self: *Store, request: *const session_list.ListSessions, visitor: anytype) !void {
        try request.validate();
        var watched: session_list_read.Watched(@TypeOf(visitor)) = .{ .visitor = visitor };
        try self.queue().run(SessionListHeld(@TypeOf(visitor)).readSessionListHeld, .{ self, request, &watched });
    }

    fn SessionListHeld(comptime Visitor: type) type {
        return struct {
            fn readSessionListHeld(self: *Store, request: *const session_list.ListSessions, watched: *session_list_read.Watched(Visitor)) !void {
                const entry = try enter(self, .none);
                defer entry.release();
                var access: ReadAccess = .open(&entry);
                defer access.deinit();
                const result = session_list_read.readSessionList(&access, request, watched);
                return entry.finishCapture(watched.failed, result);
            }
        };
    }

    pub fn actionArguments(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, .arguments);
    }

    pub fn actionCallId(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, .call_id);
    }

    fn actionContent(self: *Store, session_ref: []const u8, action_id: u64, field: tool_proposal.Field) !ContentReference {
        return self.queue().run(actionContentHeld, .{ self, session_ref, action_id, field });
    }

    fn actionContentHeld(self: *Store, session_ref: []const u8, action_id: u64, field: tool_proposal.Field) !ContentReference {
        const entry = try enter(self, .none);
        defer entry.release();
        if (action_id == 0 or action_id > std.math.maxInt(i64)) return error.ActionNotFound;
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action, action_domain.actionContent(&access, session_ref, action_id, field));
    }

    pub fn admitNextModelAttempt(self: *Store, faults: Faults) !?AttemptAdmission {
        if (!@import("builtin").is_test) @compileError("Production admission must select an explicit work kind");
        return try self.admitModelAttempt(.message, faults) orelse
            self.admitModelAttempt(.tool_continuation, faults);
    }

    /// Never inlined: its two Accesses and admission's rows (about 4 KiB)
    /// stay off the frame of a caller that goes on to dispatch the Attempt.
    pub fn admitModelAttempt(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        return self.admitModelAttemptInto(admission_kind, faults, null);
    }

    /// `admitModelAttempt`, which also starts the admitted Attempt's
    /// request in `start`: its view opens there and its settings round
    /// rides the admission's commit. `request_started` says whether it did;
    /// when not, `start` is as it was and the caller opens the view.
    pub fn admitModelAttemptInto(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults, start: ?historical_domain.Start) !?AttemptAdmission {
        return self.queue().write(admitModelAttemptHeld, .{ self, admission_kind, faults, start });
    }

    noinline fn admitModelAttemptHeld(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults, start: ?historical_domain.Start) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        var reader: ReadAccess = .open(&entry);
        defer reader.deinit();
        // An admission whose purpose rests on its context's size writes as
        // an assistant response under a guard on that size, and so reads no
        // size. Only the guard's failure, rolled back, admits again as the
        // compaction it showed is due.
        const first = admitModelAttemptOnce(&entry, &reader, admission_kind, .weighed, faults, start);
        const due = if (first) |_| false else |err| err == error.CompactionDue;
        return entry.finishTransaction(Ordinary.none, faults, if (due) admitModelAttemptOnce(&entry, &reader, admission_kind, .over, faults, start) else first);
    }

    /// Never inlined: the second admission reuses the first's frame.
    noinline fn admitModelAttemptOnce(entry: *const Entry, reader: *ReadAccess, admission_kind: ModelAdmissionKind, pressure: model_admission_domain.Pressure, faults: Faults, start: ?historical_domain.Start) !?AttemptAdmission {
        var writer: Access(.write, error{ SelectionChanged, ProjectionFailed, InstructionSelectionFailed, CompactionDue }) = .open(entry);
        defer writer.deinit();
        return writer.end(faults, model_admission_domain.admitNextModelAttempt(reader, &writer, admission_kind, pressure, faults, start));
    }

    pub fn admitNextActionAttempt(
        self: *Store,
        timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        return self.queue().write(admitNextActionAttemptHeld, .{ self, timeout_ms, faults });
    }

    fn admitNextActionAttemptHeld(
        self: *Store,
        timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        if (timeout_ms == 0 or timeout_ms > std.math.maxInt(i64)) return error.InvalidActionTimeout;
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.admitNextActionAttempt(&candidate, &access, self.io, timeout_ms, faults)));
    }

    /// Admit a selected Rui-run Action; selection is rechecked under the writer.
    /// Bash's slot owner uses `admitNextActionAttempt` to fuse selection and
    /// admission at its existing one-read, one-write cost.
    pub fn admitActionAttempt(self: *Store, selected: ReadyAction, timeout_ms: u64, faults: Faults) !?ActionAttemptAdmission {
        return self.queue().write(admitActionAttemptHeld, .{ self, selected, timeout_ms, faults });
    }
    fn admitActionAttemptHeld(self: *Store, selected: ReadyAction, timeout_ms: u64, faults: Faults) !?ActionAttemptAdmission {
        if (timeout_ms == 0 or timeout_ms > std.math.maxInt(i64)) return error.InvalidActionTimeout;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        const binding = try entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.admitActionAttempt(&access, self.io, selected, timeout_ms, faults)));
        return if (binding) |value| .{ .permit = .{ .binding = value } } else null;
    }
    /// `out` is decoded in place and valid only on success. The compile-time
    /// runner selects the adapter's existing read plan, not persisted state.
    pub fn readActionExecutionInput(self: *Store, comptime runner: tool_record.Runner, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
        return switch (runner) {
            .bash => self.queue().run(readBashExecutionInputHeld, .{ self, binding, out }),
            .mcp => self.queue().run(readMcpExecutionInputHeld, .{ self, binding, out }),
            .core, .provider => @compileError("only Action runners have execution input"),
        };
    }

    fn readMcpExecutionInputHeld(self: *Store, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_attempt, action_domain.readMcpExecutionInput(&access, binding, out));
    }

    fn readBashExecutionInputHeld(self: *Store, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_attempt, action_domain.readBashExecutionInput(&access, binding, out));
    }

    pub fn revokeActionSender(self: *Store, binding: ActionAttemptBinding) !void {
        return self.queue().write(revokeActionSenderHeld, .{ self, binding });
    }

    fn revokeActionSenderHeld(self: *Store, binding: ActionAttemptBinding) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.single, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, action_domain.revokeActionSender(&access, binding)));
    }

    pub fn actionSupersededByStop(self: *Store, binding: ActionAttemptBinding) !?SupersedingControl {
        return self.queue().run(actionSupersededByStopHeld, .{ self, binding });
    }

    fn actionSupersededByStopHeld(self: *Store, binding: ActionAttemptBinding) !?SupersedingControl {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.actionSupersededByStop(&access, binding));
    }

    pub fn withActionDispatchHandoff(
        self: *Store,
        binding: ActionAttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        try self.queue().callHeld(withActionDispatchHandoffHeld, .{ self, binding });
        defer self.queue().release();
        // Launch failures are effect outcomes, not canonical faults; the
        // caller settles or fences them. The handoff runs on the caller's
        // thread while it still holds the Store, so no request runs between the
        // check and the launch.
        try handoff(context);
    }

    fn withActionDispatchHandoffHeld(self: *Store, binding: ActionAttemptBinding) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        try entry.finish(Ordinary.action_dispatch, action_domain.validateActionDispatch(&access, binding));
    }

    pub fn settleActionAttempt(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        return self.queue().write(settleActionAttemptHeld, .{ self, binding, code, result, faults });
    }

    fn settleActionAttemptHeld(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        if (result.len == 0) return error.InvalidActionResult;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, action_domain.settleActionAttempt(&access, binding, code, result, faults)));
    }

    /// Delivers the owed child ending (D39) `nextCoreWork` names, or only
    /// settles one its parent's stop caused (D139).
    pub fn deliverChildEnding(self: *Store, turn_id: u64, faults: Faults) !bool {
        return self.deliverChildEndingBound(turn_id, null, faults);
    }

    /// `captured` is what the Host's binding of the ending's text found.
    pub fn deliverChildEndingBound(self: *Store, turn_id: u64, captured: ?*const skills_domain.MessageCapture, faults: Faults) !bool {
        return self.queue().write(deliverChildEndingHeld, .{ self, turn_id, captured, faults });
    }

    fn deliverChildEndingHeld(self: *Store, turn_id: u64, captured: ?*const skills_domain.MessageCapture, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.deliverChildEnding(&access, turn_id, captured, faults)));
    }

    /// Positions one ancestor feed row and durably queues its next hop.
    pub fn deliverSessionForward(self: *Store, forward_id: u64, faults: Faults) !bool {
        return self.queue().write(deliverSessionForwardHeld, .{ self, forward_id, faults });
    }

    fn deliverSessionForwardHeld(self: *Store, forward_id: u64, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, forward_domain.deliver(&access, forward_id, faults)));
    }

    /// Owed stops, ending Messages and ancestor feed hops precede calls.
    pub fn nextCoreWork(self: *Store) !?CoreWork {
        return self.nextCoreWorkForHost(true);
    }

    /// Which of the dispatch loop's commit-driven scans would find work,
    /// in one round; `paused` is whether new Turns are held.
    pub fn dispatchWork(self: *Store, paused: bool) !DispatchWork {
        return self.queue().run(dispatchWorkHeld, .{ self, paused });
    }

    fn dispatchWorkHeld(self: *Store, paused: bool) !DispatchWork {
        const survey = self.identities().survey;
        const asked: @FieldType(Survey, "asked") = if (paused) .paused else .running;
        self.identities().survey.kept = .none;
        self.identities().survey.asked = asked;
        // Nothing committed since the survey ran, right after its COMMIT.
        if (survey.kept == .ready and survey.asked == asked and !self.isFenced())
            return .{ .core = survey.core, .mcp = survey.mcp, .bash = survey.bash, .message = survey.message, .tool_continuation = survey.tool_continuation, .retry = survey.retry };
        const entry = try enter(self, .none);
        defer entry.release();
        var access: store_access.Access(.survey, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, model_admission_domain.dispatchWork(&access, paused));
    }

    pub fn nextCoreWorkForHost(self: *Store, include_mcp: bool) !?CoreWork {
        return self.queue().run(nextCoreWorkHeld, .{ self, include_mcp });
    }

    fn nextCoreWorkHeld(self: *Store, include_mcp: bool) !?CoreWork {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.nextCoreWork(&access, include_mcp));
    }

    /// Runs the `message_agent` call `binding` names with its checked
    /// arguments, in one transaction.
    pub fn deliverAgentMessage(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, faults: Faults) !AgentDelivery {
        return self.deliverAgentMessageBound(binding, target, text, null, faults);
    }

    /// `captured` is what the Host's binding of `text` found.
    pub fn deliverAgentMessageBound(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentDelivery {
        return self.queue().write(deliverAgentMessageHeld, .{ self, binding, target, text, captured, faults });
    }

    fn deliverAgentMessageHeld(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentDelivery {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, command_domain.deliverAgentMessage(&access, binding, target, text, captured, faults)));
    }

    /// Runs the `start_agent` call `binding` names with its checked
    /// arguments, in one transaction; `configuration` is the agent's spec,
    /// which this completes. `committed` runs once the task is admitted.
    pub fn startAgent(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *content_custody.Configuration, committed: ?MessageCommitted, faults: Faults) !AgentStart {
        return self.startAgentWithInitialSkills(binding, caller, task, attached, configuration, committed, null, null, faults);
    }

    /// `captured` is what the Host's binding of `task` against
    /// `initial_skills`' catalog found.
    pub fn startAgentWithInitialSkills(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *content_custody.Configuration, committed: ?MessageCommitted, initial_skills: ?*const skills_domain.Initial, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentStart {
        return self.queue().write(startAgentHeld, .{ self, binding, caller, task, attached, configuration, committed, initial_skills, captured, faults });
    }

    fn startAgentHeld(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *content_custody.Configuration, committed: ?MessageCommitted, initial_skills: ?*const skills_domain.Initial, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentStart {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.agent_start) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.agent_start, faults, access.end(faults, command_domain.startAgent(&access, self.io, binding, caller, task, attached, configuration, committed, initial_skills, captured, faults)));
    }

    /// Loads matching saved tools and resolves the call in one transaction.
    pub fn findTools(self: *Store, binding: ActionAttemptBinding, arena: std.mem.Allocator, words: *const @import("../find_tools_words.zig").FindTools, refusal: ?[]const u8, faults: Faults) !bool {
        return self.queue().write(findToolsHeld, .{ self, binding, arena, words, refusal, faults });
    }

    fn findToolsHeld(self: *Store, binding: ActionAttemptBinding, arena: std.mem.Allocator, words: *const @import("../find_tools_words.zig").FindTools, refusal: ?[]const u8, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, @import("domain/find_tools.zig").run(&access, binding, arena, words, refusal, faults)));
    }

    pub fn settleSkillTool(self: *Store, binding: ActionAttemptBinding, allocator: std.mem.Allocator, captured: *const skills_domain.Capture, faults: Faults) !bool {
        return self.queue().write(settleSkillToolHeld, .{ self, binding, allocator, captured, faults });
    }

    fn settleSkillToolHeld(self: *Store, binding: ActionAttemptBinding, allocator: std.mem.Allocator, captured: *const skills_domain.Capture, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        // A reload allocates from `allocator` inside the write; running out
        // of it rolls back cleanly and is the caller's to retry.
        return entry.finishTransaction(Ordinary.action_attempt || error{OutOfMemory}, faults, access.end(faults, skills_domain.runTool(&access, allocator, binding, captured, faults)));
    }

    /// Fails the core tool call `binding` names with `result`, in one
    /// transaction; false when a stop selected its Turn first.
    pub fn failCoreCall(self: *Store, binding: ActionAttemptBinding, result: []const u8, faults: Faults) !bool {
        return self.queue().write(resolveCoreCallHeld, .{ self, binding, ActionResolutionCode.failed, result, faults });
    }

    /// Succeeds a core tool call; false when a stop selected its Turn first.
    pub fn succeedCoreCall(self: *Store, binding: ActionAttemptBinding, result: []const u8, faults: Faults) !bool {
        return self.queue().write(resolveCoreCallHeld, .{ self, binding, ActionResolutionCode.succeeded, result, faults });
    }

    fn resolveCoreCallHeld(self: *Store, binding: ActionAttemptBinding, code: ActionResolutionCode, result: []const u8, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, command_domain.resolveCoreCall(&access, binding, code, result, faults)));
    }

    pub fn nextAction(self: *Store, comptime runner: tool_record.Runner) !?ReadyAction {
        if (runner != .bash and runner != .mcp) @compileError("only Action runners can select Actions");
        return self.queue().run(nextActionHeld, .{ self, runner });
    }
    fn nextActionHeld(self: *Store, runner: tool_record.Runner) !?ReadyAction {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, switch (runner) {
            .bash => action_domain.nextAction(&access, .bash),
            .mcp => action_domain.nextAction(&access, .mcp),
            .core, .provider => unreachable,
        });
    }
    pub fn resolveAction(self: *Store, selected: ReadyAction, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
        return self.queue().write(resolveActionHeld, .{ self, selected, code, text, faults });
    }
    fn resolveActionHeld(self: *Store, selected: ReadyAction, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
        if (text.len == 0) return error.InvalidActionResult;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.resolveAction(&access, selected, code, text, faults)));
    }

    pub fn recoverOneUncertainAction(self: *Store, active: ActiveOperationFilter) !bool {
        return self.queue().write(recoverOneUncertainActionHeld, .{ self, active });
    }

    fn recoverOneUncertainActionHeld(self: *Store, active: ActiveOperationFilter) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, action_domain.recoverOneUncertainAction(&candidate, &access, active)));
    }

    /// Admits the oldest due retry no slot in `active` holds. `scheduled`,
    /// when given, is set in the same round to the Unix millisecond the
    /// earliest scheduled retry not yet due falls due, or null when none
    /// is scheduled: when the caller next needs to ask, absent a commit.
    pub fn tryAdmitNextModelRetry(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
        scheduled: ?*?u64,
    ) !?AttemptAdmission {
        return self.queue().write(tryAdmitNextModelRetryHeld, .{ self, active, faults, scheduled });
    }

    fn tryAdmitNextModelRetryHeld(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
        scheduled: ?*?u64,
    ) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{RetryNoLongerDue}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, model_admission_domain.tryAdmitNextModelRetry(&candidate, &access, self.io, active, faults, scheduled)));
    }

    /// Opens the view in `out`, where it stays until it closes: a view
    /// borrows its own buffers, so it never moves. Opening reads nothing:
    /// the view's `settings` round checks that the binding is current.
    pub fn openHistoricalView(self: *Store, binding: AttemptBinding, out: *HistoricalView) void {
        out.* = .{ .store = self, .binding = binding };
    }

    pub fn modelOperationKind(self: *Store, binding: AttemptBinding) !ModelOperationKind {
        return model_settlement_domain.checkAttempt(self, binding);
    }

    pub fn isFenced(self: *const Store) bool {
        return self.fenced.load(.acquire);
    }

    /// Read before the canonical reads it may let a caller skip.
    pub fn commitGeneration(self: *const Store) u64 {
        return self.commit_generation.load(.acquire);
    }

    /// Read before the control reads it may let the dispatch loop skip.
    pub fn controlGeneration(self: *const Store) u64 {
        return @as(*OutOfLine, @fieldParentPtr("ring", self.changes)).control_generation.load(.acquire);
    }

    /// Advances `OutOfLine.control_generation` after an accepted control's commit.
    fn noteControl(self: *Store, reply: anytype) @TypeOf(reply) {
        if (reply == .accepted) _ = @as(*OutOfLine, @fieldParentPtr("ring", self.changes)).control_generation.fetchAdd(1, .release);
        return reply;
    }

    pub fn operationSupersededByControl(self: *Store, binding: AttemptBinding) !?SupersedingControl {
        return self.queue().run(operationSupersededByControlHeld, .{ self, binding });
    }

    fn operationSupersededByControlHeld(self: *Store, binding: AttemptBinding) !?SupersedingControl {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, model_settlement_domain.operationSupersededByControl(&access, binding));
    }

    pub fn withDispatchHandoff(
        self: *Store,
        binding: AttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        try self.queue().callHeld(withDispatchHandoffHeld, .{ self, binding });
        defer self.queue().release();
        // As for Actions, dispatch failures belong to the caller.
        try handoff(context);
    }

    fn withDispatchHandoffHeld(self: *Store, binding: AttemptBinding) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        _ = try entry.finish(Ordinary.attempt_binding, model_settlement_domain.readAttemptKind(&entry, binding));
    }

    /// Durably claims this Operation's one forced credential refresh before
    /// any refresh exchange. The Attempt stays uncertain, so a crash before
    /// settlement falls back to ordinary uncertain recovery while the claim
    /// prevents a second refresh. Returns false when the Operation already
    /// claimed, or when no replacement allowance would remain.
    pub fn claimModelAuthRefresh(self: *Store, binding: AttemptBinding) !bool {
        return self.queue().write(claimModelAuthRefreshHeld, .{ self, binding });
    }

    fn claimModelAuthRefreshHeld(self: *Store, binding: AttemptBinding) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.attempt_binding || error{AuthRefreshUnclaimed}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.attempt_binding, .{}, access.end(.{}, model_settlement_domain.claimModelAuthRefresh(&access, binding)));
    }

    pub fn settleModelAttemptFailure(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
    ) !void {
        return self.queue().write(settleModelAttemptFailureHeld, .{ self, binding, failure, disposition, faults });
    }

    fn settleModelAttemptFailureHeld(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
    ) !void {
        const code = failure.code();
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        if (failure.diagnostic()) |detail| {
            std.debug.assert(detail.len <= 512 and std.unicode.utf8ValidateSlice(detail));
        }
        const report = failure.report();
        std.debug.assert(report.len <= outcome_code.max_report_bytes and std.unicode.utf8ValidateSlice(report));
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.attempt_binding) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.attempt_binding, faults, access.end(faults, model_settlement_domain.settleModelAttemptFailure(&access, self.io, binding, failure, disposition, faults)));
    }

    pub fn recoverOneExhaustedModelAttempt(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        return self.queue().write(recoverOneExhaustedModelAttemptHeld, .{ self, active });
    }

    fn recoverOneExhaustedModelAttemptHeld(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{SelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, model_settlement_domain.recoverOneExhaustedModelAttempt(&candidate, &access, active)));
    }

    pub fn settleModelSuccess(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        EntryTrace.fromSettlement(faults.settlement_trace).mark(.requested);
        return self.queue().write(settleModelSuccessHeld, .{ self, binding, output, faults });
    }

    fn settleModelSuccessHeld(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        const entry = try enter(self, .fromSettlement(faults.settlement_trace));
        defer entry.release();
        var access: Access(.write, Ordinary.model_success) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.model_success, faults, access.end(faults, model_settlement_domain.settleModelSuccess(&access, self.io, binding, output, faults)));
    }

    pub fn openContent(self: *Store, reference: ContentReference) !ContentLocation {
        return content_domain.openContentIdentity(self, reference, false);
    }

    /// Reads a core call's whole arguments into `bytes`, which holds exactly
    /// their length, one content window at a time.
    pub fn readCoreArguments(self: *Store, input: *const CoreActionInput, bytes: []u8) !void {
        var reader: content_domain.ContentReader = undefined;
        reader.open(try self.openContent(input.arguments));
        defer reader.close();
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + content_domain.ContentReader.content_window_bytes);
            const count = try reader.read(offset, bytes[offset..end]);
            if (count == 0) return error.ShortCanonicalRead;
            offset += count;
        }
    }
};

pub const Faults = struct {
    content_read: bool = false,
    content_import: bool = false,
    before_commit: bool = false,
    attempt_before_commit: bool = false,
    output_read: bool = false,
    output_import: bool = false,
    output_commit: bool = false,
    rollback_failure: bool = false,
    control_trace: ?ControlTrace = null,
    settlement_trace: ?SettlementTrace = null,
};

pub const ControlTracePhase = enum { lock_requested, lock_acquired, durable_acceptance, store_complete };

pub const ControlTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, ControlTracePhase) void,

    pub fn mark(self: ControlTrace, phase: ControlTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const SettlementTracePhase = enum {
    lock_requested,
    lock_acquired,
    transaction_active,
    settlement_complete,
};

pub const SettlementTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, SettlementTracePhase) void,

    pub fn mark(self: SettlementTrace, phase: SettlementTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const AttemptBinding = attempt.AttemptBinding;

pub const OpenOptions = struct {
    /// The providers whose Sessions get model Attempts.
    served: provider_route.Routes = provider_route.all(.endpoint),
    cache_spill: bool = true,
    cache_kib: u32 = 1024,
    found_schema_version: ?*u32 = null,
    /// Caller-owned evidence retained after a failed open destroys the Store.
    identity_mismatch: ?*store_schema.IdentityMismatch = null,
    /// Told when a SQLite Store's startup migration begins and commits.
    migration_notice: ?store_schema.MigrationNotice = null,
    /// The tools the Host offers, which it keeps for the Store's life.
    /// Null saves none: the Host reads the last one back (`readHostToolSet`)
    /// and saves its own (`saveHostToolSet`) before it serves.
    host_tool_set: ?*const tool_record.HostToolSet = &tool_record.built_in_tool_set,
};

pub const Target = union(Kind) {
    sqlite: []const u8,
    mysql: mysql_connection.Options,
};

pub const AdmissionDiagnostic = struct { doublewrite: ?[]const u8 };
pub const Diagnostic = union(Kind) { sqlite: SqliteDiagnostic, mysql: Mysql.Diagnostic };

pub const SqliteDiagnostic = struct {
    process_memory_current_bytes: ?u64 = null,
    process_memory_highwater_bytes: ?u64 = null,
    cache_used_bytes: ?u64 = null,
    cache_spills: ?u64 = null,
    hard_heap_limit_bytes: ?u64 = null,
    page_size_bytes: ?u64 = null,
    cache_size_setting: ?i64 = null,
    cache_spill_threshold: ?i64 = null,
    mmap_size_bytes: ?u64 = null,
    synchronous: ?i64 = null,
    temp_store: ?i64 = null,
    busy_timeout_ms: ?u64 = null,
    journal_mode: ?Bounded(16) = null,
};

/// Test builds' counters on a Store. `read` and `blob` count content bytes
/// read through readers and through `Access.readRaw`, and `closes` counts
/// reader closes. `rounds` counts `Access.run` and `commit`, and
/// `content_rounds` counts `readRaw` windows, for the round budgets.
/// `closes` is a u32 and the round counts u16 so the counters stay 24
/// bytes: no test closes 4 billion readers or runs 65,535 rounds on one
/// Store, and a round count past that traps in test builds.
const TestingContentWork = struct {
    read: std.atomic.Value(u64) = .init(0),
    blob: std.atomic.Value(u64) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    rounds: u16 = 0,
    content_rounds: u16 = 0,
};

// The frame that holds a Store keeps every byte of it resident, so a fixed
// buffer belongs in memory of its own, like the change ring's. The production
// Store remains 688 bytes: its engine tag replaces the redundant ids pointer.
// Test builds add 24 bytes of counters and sit exactly at
// 712, so a new field must come out of existing padding, or out of the Store.
comptime {
    if (@sizeOf(TestingContentWork) != 24) @compileError("TestingContentWork grew past 24 bytes; the test-build Store has no room");
    if (@sizeOf(Store) > 712) @compileError(std.fmt.comptimePrint("Store is {d} bytes; keep large state out of line", .{@sizeOf(Store)}));
}

/// The Store's state too large for the frame that holds it.
const OutOfLine = struct {
    ring: change_ring.Ring,
    queue: Queue,
    ids: HostValues,
    tools: HostTools,
    /// Advances after each accepted control (a stop, archive, model
    /// interruption, permission decision or owed stop), before its entry
    /// point releases the Store. The dispatch loop reads controls again
    /// only when it moved, so a lost control hint delays nothing.
    control_generation: std.atomic.Value(u64),
    /// Set after each advance of `commit_generation`, when given: the
    /// dispatch loop waits on it, so a commit from any thread ends that
    /// wait at once. Its owner outlives every entry point.
    commit_wake: std.atomic.Value(?*std.Io.Event),
    scratch: Scratch align(scratch_align),
};

const ScratchUse = enum(u8) { none, configuration, settlement, report };

/// One entry point's large state: a configure's reads, a settlement's
/// batch or a report's rows, which no entry point holds at once (`Store.scratch` checks that
/// in safe builds). Bytes, not a union, so it is no bigger than the larger
/// use and needs no tag of its own: `Store.scratch_use` is its tag.
const Scratch = [scratch_bytes]u8;
const scratch_bytes = @max(@sizeOf(configuration_domain.ConfigurationReads), @sizeOf(model_settlement_domain.Batch));
const scratch_align = @max(@alignOf(configuration_domain.ConfigurationReads), @alignOf(model_settlement_domain.Batch));

/// The resident bytes the owner accepted for a settlement batch of 64
/// items and 64 call-name lookups, beyond the configure reads' 4888.
const accepted_settlement_growth = 14352;

comptime {
    // The settlement batch keeps the request's offered names and borrows
    // existing content identities for withdrawn names. Binding transient
    // history arguments avoids retaining a second copy of every call name.
    // Its 19032 bytes are below the previous 19240-byte resident ceiling;
    // configuration reads reuse saved_tools for parent names and use 15032.
    // Exact, so a change to either size is a decision.
    if (@sizeOf(configuration_domain.ConfigurationReads) != 15032 or scratch_bytes != 19032)
        @compileError(std.fmt.comptimePrint("the Store's scratch is {d} bytes and the configure reads {d}; restate them here", .{ scratch_bytes, @sizeOf(configuration_domain.ConfigurationReads) }));
    if (scratch_bytes - 4888 > accepted_settlement_growth) @compileError("the settlement batch outgrew what the owner accepted");
}

/// The change ring, and the scratch beside it, in pages of their own,
/// which the kernel faults in only as they are written: an idle Host keeps
/// none of the ring's 88 KiB resident. A configure, a creating Message or
/// a success settlement writes the scratch's pages once, and they stay
/// resident for the Store's life: at most 19032 bytes, a settlement
/// batch's size; a configure uses 14968.
/// Not `Allocator.create`, whose ReleaseSafe 0xAA fill would write every
/// page now.
fn createRing() error{OutOfMemory}!*change_ring.Ring {
    const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(OutOfLine), .of(OutOfLine), @returnAddress()) orelse return error.OutOfMemory;
    const owned: *OutOfLine = @ptrCast(@alignCast(bytes));
    owned.control_generation = .init(0);
    owned.commit_wake = .init(null);
    const ring: *change_ring.Ring = &owned.ring;
    // Every scalar takes Ring's own default; the columns stay unwritten, since
    // only entries below `len` are read.
    const info = @typeInfo(change_ring.Ring).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        if (@typeInfo(Field) == .array) continue;
        @field(ring, name) = attrs.defaultValue(Field) orelse @compileError("Ring." ++ name ++ " needs a default");
    }
    return ring;
}

fn destroyRing(ring: *change_ring.Ring) void {
    const owned: *OutOfLine = @fieldParentPtr("ring", ring);
    std.heap.page_allocator.rawFree(@as([*]u8, @ptrCast(owned))[0..@sizeOf(OutOfLine)], .of(OutOfLine), @returnAddress());
}

/// Expected outcomes of entry points. A canonical read or save
/// fault fences the Host (ARCHITECTURE.md, "Commit boundaries and crash
/// recovery"), so every other error from an entry point has fenced the
/// Store before the caller sees it.
pub const Ordinary = struct {
    pub const none = error{};
    const page = error{ SessionNotFound, InvalidCursor };
    const content = error{ContentNotFound};
    const public_content = error{ ContentNotFound, RangeOutOfBounds };
    pub const action = error{ActionNotFound};
    const result = error{ ResultNotFound, ResultNotReady, ResultFailed };
    pub const attempt_binding = error{ StaleAttemptBinding, SupersededByControl };
    pub const historical_entry = error{HistoricalPending};
    const model_success = attempt_binding || error{InvalidProviderEnvelope};
    const action_attempt = error{StaleActionAttemptBinding};
    const action_dispatch = action_attempt || error{SupersededByControl};
    /// A creation updates no Session, but shares configure's error set.
    const agent_start = action_attempt || error{SessionUpdateFailed};

    /// Rejects a declared ordinary name the body cannot return, so a
    /// stale or misspelled name fails to compile instead of fencing.
    fn produced(comptime Set: type, comptime Result: type) void {
        const returned = @typeInfo(@typeInfo(Result).error_union.error_set).error_set.error_names orelse return;
        outer: inline for (@typeInfo(Set).error_set.error_names.?) |name| {
            inline for (returned) |candidate| {
                if (comptime std.mem.eql(u8, name, candidate)) continue :outer;
            }
            @compileError("ordinary error " ++ name ++ " is not returned by " ++ @typeName(Result));
        }
    }

    fn contains(comptime Set: type, err: anyerror) bool {
        inline for (@typeInfo(Set).error_set.error_names.?) |name| {
            if (err == @field(anyerror, name)) return true;
        }
        return false;
    }
};

const EntryTrace = union(enum) {
    none,
    control: ControlTrace,
    settlement: SettlementTrace,

    fn fromControl(trace: ?ControlTrace) EntryTrace {
        return if (trace) |value| .{ .control = value } else .none;
    }

    fn fromSettlement(trace: ?SettlementTrace) EntryTrace {
        return if (trace) |value| .{ .settlement = value } else .none;
    }

    fn mark(self: EntryTrace, phase: enum { requested, acquired, complete }) void {
        switch (self) {
            .none => {},
            .control => |trace| trace.mark(switch (phase) {
                .requested => .lock_requested,
                .acquired => .lock_acquired,
                .complete => .store_complete,
            }),
            .settlement => |trace| trace.mark(switch (phase) {
                .requested => .lock_requested,
                .acquired => .lock_acquired,
                .complete => .settlement_complete,
            }),
        }
    }
};

/// Exclusive canonical access for one entry point, from `enter` through
/// `release`. Errors leave through `finish` or `finishTransaction`, which
/// return the entry point's declared ordinary errors and fence the rest.
/// Runs while its thread holds the Store, which runs no other request meanwhile.
pub const Entry = struct {
    const max_result_bytes = 1024;

    store: *Store,
    trace: EntryTrace,
    changes: i64,
    /// A test's own Entry, which holds the Store until `release`.
    borrowed: if (@import("builtin").is_test) bool else void,

    pub fn finish(self: Entry, comptime Expected: type, result: anytype) @TypeOf(result) {
        comptime Ordinary.produced(Expected, @TypeOf(result));
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            if (Ordinary.contains(Expected, err)) return err;
            return fence(self.store, err);
        };
    }

    /// Rolls back any open transaction first; a failed rollback fences
    /// and replaces the original error, including an ordinary one.
    pub fn finishTransaction(self: Entry, comptime Expected: type, faults: Faults, result: anytype) Transaction(@TypeOf(result)) {
        comptime Ordinary.produced(Expected, @TypeOf(result));
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            rollbackAfterError(self.store, faults) catch |rollback_err| return fence(self.store, rollback_err);
            if (Ordinary.contains(Expected, err)) return err;
            return fence(self.store, err);
        };
    }

    /// A capture's own failure, such as exhausted scratch, is `ordinary`
    /// and does not fence the Store.
    fn finishCapture(self: Entry, ordinary: bool, result: anytype) @TypeOf(result) {
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            if (ordinary) return err;
            return fence(self.store, err);
        };
    }

    pub fn release(self: Entry) void {
        const store = self.store;
        store.engine.releaseEntry();
        store.scratch_use = .none;
        // Counts autocommit and explicit-transaction writes alike. A
        // rolled-back change touched everything: never a missed change.
        // An attempt that lost its connection with nothing saved, and runs
        // again, changed nothing yet: its second run records the change.
        const reruns = store.engine == .mysql and store.engine.mysql.defersFence();
        if (store.engine.totalChanges() != self.changes and !reruns) {
            if (@import("builtin").is_test) if (untouchedForTesting(store)) |id|
                std.debug.panic("rows of Session {s} changed, but the entry point that changed them did not touch it", .{&id});
            const generation = store.commit_generation.fetchAdd(1, .release) + 1;
            store.identities().survey.kept = if (store.identities().survey.kept == .fresh) .ready else .none;
            store.changes.record(generation, &store.touched);
            if (store.commitWake().load(.acquire)) |wake| wake.set(store.io);
        }
        self.trace.mark(.complete);
        if (@import("builtin").is_test) if (self.borrowed) store.queue().giveBack();
    }

    /// Rejects an entry point result over `max_result_bytes`. A Host
    /// thread keeps its deepest stack pages for life, and a result
    /// returned by value takes a slot in each frame it passes through;
    /// a big result is filled through the caller's `out: *T` instead.
    fn assertSmallResult(comptime Result: type) void {
        const Payload = @typeInfo(Result).error_union.payload;
        const Value = switch (@typeInfo(Payload)) {
            .optional => |optional| optional.child,
            else => Payload,
        };
        if (@sizeOf(Value) > max_result_bytes) @compileError(std.fmt.comptimePrint(
            "{s} is {d} bytes, over the {d}-byte result bound; fill it through out: *T",
            .{ @typeName(Value), @sizeOf(Value), max_result_bytes },
        ));
    }

    fn Transaction(comptime Result: type) type {
        const info = @typeInfo(Result).error_union;
        return (info.error_set || error{CanonicalRollbackFailed})!info.payload;
    }
};

/// While its thread holds the Store: the public entry point marked
/// `.requested` before it queued. A test may open an Entry without an entry
/// point, which holds the Store until `release`.
pub fn enter(self: *Store, trace: EntryTrace) error{StoreFenced}!Entry {
    // A batch that lost its connection runs nothing more: either it runs
    // again whole on a new one, or the Store fences.
    if (self.isFenced() or self.batch == .lost) return error.StoreFenced;
    const borrowed = if (@import("builtin").is_test) borrowed: {
        const off = !self.queue().owned();
        if (off) self.queue().borrow();
        break :borrowed off;
    } else std.debug.assert(self.queue().owned());
    self.touched = .{};
    // Rows a test changed outside any entry point belong to none.
    if (@import("builtin").is_test) clearTouchOracleForTesting(self);
    const entry: Entry = .{ .store = self, .trace = trace, .changes = self.engine.totalChanges(), .borrowed = borrowed };
    trace.mark(.acquired);
    if (self.isFenced()) {
        entry.release();
        return error.StoreFenced;
    }
    return entry;
}

/// Opens an entry point's write transaction. Every entry point begins
/// here; only opening the Store, in `schema.bootstrap`, issues a BEGIN of
/// its own, before any entry point can run.
pub fn begin(self: *Store) !void {
    switch (self.batch) {
        .none => {
            std.debug.assert(self.identities().taken.count() == 0 and self.identities().second == 0);
            try self.engine.control(.begin);
            return;
        },
        .ready => {
            std.debug.assert(self.identities().taken.count() == 0 and self.identities().second == 0);
            try self.engine.control(.begin);
            self.batch = .first;
            return;
        },
        .open => {},
        // The Queue ends a saved batch before its next write.
        .first, .saved, .lost => unreachable,
    }
    std.debug.assert(!self.savepoint);
    try self.engine.control(.savepoint);
    self.savepoint = true;
}

/// Commits the open transaction; the identities it took stay taken. In a
/// batch, releases the write's savepoint: the batch commits at its end,
/// with one second and one set of taken identities for all its writes.
pub fn commit(self: *Store) !void {
    switch (self.batch) {
        .first => {
            // Its COMMIT rode its last writes (`commitsWithWrites`).
            self.batch = if (self.engine.inTransaction()) .open else .saved;
            return;
        },
        .open => {
            try self.engine.control(.release);
            self.savepoint = false;
            return;
        },
        .none => {},
        .ready, .saved, .lost => unreachable,
    }
    try self.engine.control(.commit);
    self.identities().taken = .empty;
    self.identities().second = 0;
}

/// Whether a write Access that commits now sends COMMIT with its last
/// writes: on a network engine, when it is its batch's first write and no
/// other write waits to share the batch's COMMIT. The batch is then saved
/// and takes no more (`batchClosed`). A batch that runs again
/// (`recoverRerun`) is no longer armed and holds every write it held, so
/// it commits at its end.
pub fn commitsWithWrites(self: *Store) bool {
    return self.engine.commitArmed() and self.batch == .first and !self.queue().writeWaiting();
}

/// Sends `writer`'s last writes and COMMIT, which it bound, with the
/// dispatch survey's reads after them: the Host asks for that survey
/// after every commit (`dispatchWork`), and here it costs no round trip
/// of its own. The reads follow COMMIT, so they run in autocommit and see
/// what it saved. The writer sends the message; the survey is in it whole
/// or not at all, so one whose reads do not fit after COMMIT is dropped
/// before the send, as is one the Host has not asked for yet. Its answer
/// is kept only beside a writer that did not fail, and only when that one
/// round gave it: checks that need more rounds are left to the Host's own
/// `dispatchWork`. A read that fails after COMMIT fences, as it does when
/// the Host asks, and the commit stands.
pub noinline fn commitWithSurvey(self: *Store, writer: anytype) void {
    const kept = &self.identities().survey;
    const follow = self.identities().follow;
    self.identities().follow = null;
    const surveyed = kept.asked != .never;
    if (!surveyed and follow == null) return writer.passCommit(null);
    kept.kept = .none;
    var reads: store_access.Access(.survey, error{}) = .{ .store = self, .tail = true };
    defer reads.deinit();
    if (follow) |after| after.queue(after.context, &reads);
    var survey: model_admission_domain.DispatchSurvey = .{};
    if (surveyed) survey.queue(&reads, kept.asked == .paused);
    if (reads.failure != null) {
        self.engine.dropTail();
        return writer.passCommit(null);
    }
    writer.passCommit(reads.asTail());
    if (writer.failure != null) return;
    if (reads.failure) |err| {
        @as(anyerror!void, fence(self, err)) catch {};
        return;
    }
    if (follow) |after| after.settle(after.context);
    if (!surveyed) return;
    const found = (survey.work() catch |err| {
        @as(anyerror!void, fence(self, err)) catch {};
        return;
    }) orelse return;
    kept.core = found.core;
    kept.mcp = found.mcp;
    kept.bash = found.bash;
    kept.message = found.message;
    kept.tool_continuation = found.tool_continuation;
    kept.retry = found.retry;
    kept.kept = .fresh;
}

/// Reads a write asks to follow its COMMIT in the same message, ahead of
/// the dispatch survey: `queue` binds them, and `settle` takes their
/// answers once the message ran with no failure. They ride whole or not
/// at all, as the survey does, so their owner must be able to read them
/// in a round of its own.
pub const Follow = struct {
    context: *anyopaque,
    queue: *const fn (*anyopaque, *store_access.Access(.survey, error{})) void,
    settle: *const fn (*anyopaque) void,
};

/// Sets, or with null clears, the reads the holder's next commit carries
/// (`commitWithSurvey`). The write that set them clears them when it ends.
pub fn followCommit(self: *Store, follow: ?Follow) void {
    self.identities().follow = follow;
}

/// `Queue.Batch.closed`: the batch's COMMIT already ran.
fn batchClosed(context: *anyopaque) bool {
    const self: *Store = @ptrCast(@alignCast(context));
    return self.batch == .saved;
}

fn startBatch(context: *anyopaque) void {
    const self: *Store = @ptrCast(@alignCast(context));
    std.debug.assert(self.batch == .none and !self.savepoint);
    self.batch = .ready;
}

/// Commits the batch's transaction, if a write opened one, and answers
/// whether its writes are durable. A failed COMMIT, or a rollback that
/// failed inside the batch, fences the Store, and the batch's writers all
/// hear it; closing rolls back what was left open, as it does for a lone
/// write whose rollback failed.
fn finishBatch(context: *anyopaque) bool {
    const self: *Store = @ptrCast(@alignCast(context));
    std.debug.assert(!self.savepoint);
    defer {
        self.batch = .none;
        self.identities().taken = .empty;
        self.identities().second = 0;
        self.identities().admitted_len = 0;
        if (self.release_bulk_memory) {
            self.release_bulk_memory = false;
            self.engine.releaseUnusedMemory(model_facts_domain.save_statements);
        }
    }
    commitBatch(self) catch return false;
    const values = self.identities();
    for (values.admitted[0..values.admitted_len]) |*admission| admission.tell();
    return true;
}

/// Tells `callback` of a fresh admission its write saved: at once after a
/// lone write's COMMIT, or in a batch once the batch's COMMIT succeeds, so
/// a batch that runs again, or fails, tells nothing twice or wrongly.
pub fn admitted(self: *Store, callback: Store.MessageCommitted, admission: Store.MessageAdmission) void {
    if (self.batch == .none) return callback.call(callback.context, admission);
    const values = self.identities();
    values.admitted[values.admitted_len] = .{
        .callback = .{ .message = callback },
        .session = admission.session[0..session_id.bytes].*,
        .admission_id = admission.admission_id,
        .from_peer = admission.from_peer,
    };
    values.admitted_len += 1;
}

/// A fresh native creation has no Message admission, but its Host effect
/// still belongs to the batch's successful COMMIT, never a savepoint.
pub fn created(self: *Store, callback: Store.CreationCommitted, session: []const u8) void {
    if (self.batch == .none) return callback.call(callback.context, session);
    const values = self.identities();
    values.admitted[values.admitted_len] = .{
        .callback = .{ .creation = callback },
        .session = session[0..session_id.bytes].*,
        .admission_id = 0,
        .from_peer = false,
    };
    values.admitted_len += 1;
}

fn armRerun(context: *anyopaque, on: bool) void {
    const self: *Store = @ptrCast(@alignCast(context));
    if (self.engine == .mysql) self.engine.mysql.state.armed = on;
}

/// `Queue.Batch.recover`: after a batch, whether it lost its connection
/// with nothing saved and runs again on a new one. A loss that cannot be
/// recovered fences now.
fn recoverRerun(context: *anyopaque) bool {
    const self: *Store = @ptrCast(@alignCast(context));
    if (self.engine != .mysql) return false;
    const mysql = &self.engine.mysql;
    if (mysql.recover()) {
        // As after a rollback, the lost attempt gives back the ids it took.
        // A finished batch has already forgotten which, so all are reread.
        self.savepoint = false;
        self.identities().second = 0;
        loadIdentities(self, .full) catch |err| {
            _ = @errorName(fence(self, err));
            return false;
        };
        return true;
    }
    if (mysql.state.failure) |err| if (err == error.StoreConnectionLost or err == error.OwnershipLost or err == error.CommitOutcomeUnknown) {
        _ = @errorName(fence(self, err));
    };
    return false;
}

fn commitBatch(self: *Store) !void {
    switch (self.batch) {
        .ready, .saved => {},
        .open => self.engine.control(.commit) catch |err| return fence(self, err),
        .lost => return fence(self, error.CanonicalRollbackFailed),
        .none, .first => unreachable,
    }
}

/// The open transaction's second, bound to every `@now` in it: read from
/// the clock at its first use, and held until commit or rollback, so every
/// round of a write Access dates its rows with one second. Outside a
/// transaction (a read Access), each use reads the clock.
pub fn transactionSecond(self: *Store) error{ClockReadFailed}!i64 {
    if (self.identities().second != 0) return self.identities().second;
    const second = std.math.cast(u32, @divFloor(try readUnixMilliseconds(self.io), 1000)) orelse return error.ClockReadFailed;
    if (second == 0) return error.ClockReadFailed;
    if (self.engine.inTransaction()) self.identities().second = second;
    return second;
}

/// A Workspace's identity in the Store: SHA-256 of its canonical text.
/// Reads compare it, then the text, so a collision never merges two.
pub fn workspaceDigest(workspace: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(workspace, &digest, .{});
    return digest;
}

/// Test builds: a Session whose rows this entry point changed but did
/// not touch. The oracle is a temporary trigger on each table that
/// carries a Session, so a writer that skips its touch fails whichever
/// test drives it.
pub fn untouchedForTesting(self: *Store) ?change_ring.Id {
    if (!@import("builtin").is_test) @compileError("test-only check");
    if (self.touched.everything) return null;
    return switch (self.engine) {
        .sqlite => |*s| s.untouchedForTesting(&self.touched),
        .mysql => @import("mysql_testing.zig").untouchedForTesting(self, &self.touched),
    };
}

fn clearTouchOracleForTesting(self: *Store) void {
    if (!@import("builtin").is_test) @compileError("test-only oracle");
    switch (self.engine) {
        .sqlite => |*s| s.clearTouchOracleForTesting(),
        .mysql => @import("mysql_testing.zig").clearTouchOracleForTesting(self),
    }
}

/// The only fence setter. Returns `err` so callers can propagate it. A
/// connection lost in an attempt the Queue can still run again fences only
/// if `recoverRerun` cannot replace it.
pub fn fence(self: *Store, err: anytype) @TypeOf(err) {
    if (self.engine == .mysql and self.engine.mysql.defersFence()) return err;
    self.fenced.store(true, .release);
    return err;
}

/// The saved Session, as `configuration.readSaved` reads it, in a read
/// Access of its own, then checked by `configuration.checkSaved`.
pub fn readSessionForTesting(self: *Store, session_ref: []const u8) !?CurrentConfiguration {
    const entry = try enter(self, .none);
    defer entry.release();
    var a: ReadAccess = .open(&entry);
    defer a.deinit();
    var current: CurrentConfiguration = .{};
    var found: Found = undefined;
    configuration_domain.readSaved(&a, session_ref, &current, &found);
    try entry.finish(Ordinary.none, a.run());
    if (!found.get()) return null;
    try entry.finish(Ordinary.none, configuration_domain.checkSaved(&current));
    return current;
}

pub fn activityPageForTesting(self: *Store, request: activity_read.ActivityPage) !activity_facts.Page {
    var page: activity_facts.Page = undefined;
    try self.activityPage(&request, &page);
    return page;
}

pub fn publicConversationPageForTesting(self: *Store, request: conversation_read.ConversationPage) !PublicConversationPage {
    var page: PublicConversationPage = undefined;
    try self.publicConversationPage(&request, &page);
    return page;
}

/// A column whose values the Host hands out: a row's id, or its place in
/// a Store-wide order.
pub const Identity = enum { turn_id, operation_id, action_id, content_id, created_seq, command_seq, admission_id, tool_record_id, tool_set_id, forward_id };

/// What the Host hands to transactions. The next value of each `Identity`
/// is the Store's maximum plus one, read at open and again for each column
/// a rolled-back transaction took from. Correct because one Host owns the
/// Store; the primary or unique key still refuses a duplicate, and a
/// refused write fences.
fn saveHostToolSetStep(a: anytype, offered: *const tool_record.HostToolSet, digest: *const [32]u8, start: ?usize) !?u64 {
    const at = start orelse {
        var set: tool_set_domain.ToolSetLookup = null;
        tool_set_domain.lookupHostToolSet(a, digest, &set);
        try a.run();
        const row = set orelse {
            try a.abandon(.{});
            return null;
        };
        if (row.current) {
            try a.abandon(.{});
        } else {
            tool_set_domain.pointHostToolSet(a, row.tool_set_id.get());
            try a.commit();
        }
        return row.tool_set_id.get();
    };
    if (at < offered.records.len) {
        var reads: tool_set_domain.RecordReads = undefined;
        try tool_set_domain.ensureRecords(a, offered.records[at..@min(offered.records.len, at + tool_set_domain.records_per_transaction)], &reads);
        try a.commit();
        return null;
    }
    const set_id = try a.identity(.tool_set_id);
    tool_set_domain.insertHostToolSet(a, offered, digest, set_id);
    tool_set_domain.pointHostToolSet(a, set_id);
    try a.commit();
    return set_id;
}

/// A tool set `readHostToolSet` read back, in its caller's memory.
pub const SavedHostToolSet = struct {
    records: []tool_record.Record,
    digests: [][32]u8,
    /// Every name, server and text the records point into.
    texts: []u8,

    pub fn toolSet(self: *const SavedHostToolSet) tool_record.HostToolSet {
        return .{ .records = self.records, .digests = self.digests };
    }

    pub fn deinit(self: *SavedHostToolSet, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.digests);
        allocator.free(self.texts);
        self.* = undefined;
    }
};

/// The tools the Host offers and the id of their saved set, which
/// configure resolves a Session's tool names against.
const HostTools = struct {
    host_tool_set: *const tool_record.HostToolSet,
    set_id: u64,
};

const HostValues = struct {
    next: std.EnumArray(Identity, u64),
    /// The columns that handed out a value since `begin`.
    taken: std.EnumSet(Identity) = .empty,
    /// The open transaction's Unix second for `@now`, or 0 before its first
    /// use. A u32 holds seconds until 2106 and fits the padding after
    /// `taken`, so the Store does not grow.
    second: u32 = 0,
    /// The batch's fresh admissions, told once its COMMIT succeeds
    /// (`Store.admitted`): one per write at most.
    admitted: [Queue.drain_limit + 1]Admitted = undefined,
    admitted_len: u8 = 0,
    /// How the Host last asked `dispatchWork`, with new Turns held or not;
    /// until it asks, no commit carries the survey. With it, the dispatch
    /// survey a commit's message carried
    /// (`commitWithSurvey`), for the `dispatchWork` that asks before
    /// anything else commits: `fresh` until its writer's entry point ends
    /// and advances the generation, then `ready` until the next advance.
    /// It fits the padding after `admitted_len`.
    survey: Survey = .{},
    /// The reads the holder's next commit carries after it (`followCommit`).
    follow: ?Follow = null,
};

const Survey = packed struct(u16) {
    asked: enum(u2) { never, running, paused } = .never,
    kept: enum(u2) { none, fresh, ready } = .none,
    core: bool = false,
    mcp: bool = false,
    bash: bool = false,
    message: bool = false,
    tool_continuation: bool = false,
    retry: bool = false,
    _: u6 = 0,
};

const Admitted = struct {
    callback: union(enum) { message: Store.MessageCommitted, creation: Store.CreationCommitted },
    session: [session_id.bytes]u8,
    admission_id: u64,
    from_peer: bool,

    fn tell(self: *const Admitted) void {
        switch (self.callback) {
            .message => |callback| callback.call(callback.context, .{ .session = &self.session, .admission_id = self.admission_id, .from_peer = self.from_peer }),
            .creation => |callback| callback.call(callback.context, &self.session),
        }
    }
};

/// The next value of `column`, inside the open transaction. The one place
/// an identity is allocated, so a per-Host range can replace the counter.
pub fn takeIdentity(self: *Store, comptime column: Identity) error{ IdentityExhausted, IdentityOutsideTransaction }!u64 {
    // Rollback is what gives an id back; outside a transaction nothing would.
    if (!self.engine.inTransaction()) return error.IdentityOutsideTransaction;
    const value = self.identities().next.get(column);
    if (value > std.math.maxInt(i64)) return error.IdentityExhausted;
    self.identities().next.set(column, value + 1);
    self.identities().taken.insert(column);
    return value;
}

/// Re-reads every id after a test wrote rows past the Host, as reopening
/// would.
pub fn reloadIdentitiesForTesting(self: *Store) !void {
    try loadIdentities(self, .full);
}

/// Reads `columns`' next values from the committed rows: at open, and after
/// a rollback, which gives back every value its transaction took. Re-reading
/// max() rather than restoring a snapshot taken at BEGIN stays correct when
/// a COMMIT's outcome is unknown, because only committed rows count: a
/// value whose row committed is never handed out twice, and one whose row
/// did not is handed out again.
fn IdentityCeiling(comptime column: Identity) type {
    const table = switch (column) {
        .turn_id => "turn",
        .operation_id => "model_operation",
        .action_id => "action_operation",
        .content_id => "content",
        .created_seq => "session",
        .command_seq => "core_command",
        .admission_id => "message_admission",
        .tool_record_id => "tool_record",
        .tool_set_id => "tool_set",
        .forward_id => "session_forward",
    };
    return rsql.Read(.{
        .sql = "SELECT coalesce(max(" ++ @tagName(column) ++ "),0) AS ceiling FROM " ++ table,
        .Args = struct {},
        .Row = struct { ceiling: u64 },
        .cardinality = .one,
    });
}

fn loadIdentities(self: *Store, columns: std.EnumSet(Identity)) !void {
    if (self.engine.batches()) {
        inline for (comptime std.enums.values(Identity)) |column| if (columns.contains(column)) {
            const Ceiling = IdentityCeiling(column);
            try self.engine.bind(null, Ceiling, &.{}, 0);
        };
        if (columns.count() != 0) self.engine.notePass(.identity);
        try self.engine.startPass();
    }
    errdefer self.engine.finishPass() catch {};
    inline for (comptime std.enums.values(Identity)) |column| if (columns.contains(column)) {
        const Ceiling = IdentityCeiling(column);
        const statement = try self.engine.statementFor(Ceiling);
        defer self.engine.endStatement(statement);
        if (!(self.engine.nextRow(statement) catch false)) return error.IdentityReadFailed;
        var row: Ceiling.Row = undefined;
        try self.engine.decodeRow(Ceiling.Row, statement, &row);
        self.identities().next.set(column, row.ceiling + 1);
    };
    try self.engine.finishPass();
    self.identities().taken = .empty;
}

pub fn rollbackAfterError(self: *Store, faults: Faults) !void {
    // SQLite may already have rolled back what the entry point touched.
    self.touched.everything = true;
    switch (self.batch) {
        .open => {
            // Back to the write's savepoint; the batch's earlier writes
            // stay. A transaction SQLite rolled back whole took them with
            // it, so the batch is lost.
            const savepoint = self.savepoint;
            self.savepoint = false;
            errdefer self.batch = .lost;
            if (!self.engine.inTransaction()) return error.CanonicalRollbackFailed;
            if (savepoint) {
                if (faults.rollback_failure) return error.CanonicalRollbackFailed;
                self.engine.control(.rollback_to) catch return error.CanonicalRollbackFailed;
                self.engine.control(.release) catch return error.CanonicalRollbackFailed;
            }
            loadIdentities(self, self.identities().taken) catch return error.CanonicalRollbackFailed;
            return;
        },
        // The batch's first write rolls back as a lone write does, and the
        // batch is ready again for the next.
        .first => {
            errdefer self.batch = .lost;
            try rollbackTransaction(self, faults);
            self.batch = .ready;
            return;
        },
        .none, .ready, .saved => return rollbackTransaction(self, faults),
        // A rollback that failed once fails again: nothing undid the write.
        .lost => return error.CanonicalRollbackFailed,
    }
}

fn rollbackTransaction(self: *Store, faults: Faults) error{CanonicalRollbackFailed}!void {
    if (self.engine.inTransaction()) {
        if (faults.rollback_failure) return error.CanonicalRollbackFailed;
        self.engine.control(.rollback) catch return error.CanonicalRollbackFailed;
        if (self.engine.inTransaction()) return error.CanonicalRollbackFailed;
    }
    self.identities().second = 0;
    loadIdentities(self, self.identities().taken) catch return error.CanonicalRollbackFailed;
}

pub fn readUnixMilliseconds(io: std.Io) !i64 {
    const value = std.Io.Clock.real.now(io).toMilliseconds();
    if (value <= 0) return error.ClockReadFailed;
    return value;
}

const ModelIds = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,
    failed: bool = false,

    pub fn visit(self: *ModelIds, row: *const model_facts_domain.openai_ids.Row) bool {
        const id = self.allocator.dupe(u8, row.model_id.slice()) catch {
            self.failed = true;
            return false;
        };
        self.items.append(self.allocator, id) catch {
            self.allocator.free(id);
            self.failed = true;
            return false;
        };
        return true;
    }
};
