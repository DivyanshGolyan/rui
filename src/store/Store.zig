//! The Store type and its public entry points, then what the domain files share
//! and nothing outside src/store/ reaches: the Store's queue and fencing, statement execution,
//! identities and traces. The facade re-exports only the Store type and its value types.

const std = @import("std");
const attempt = @import("../attempt.zig");
const protocol = @import("../protocol.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const action_domain = @import("domain/action.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const content_domain = @import("domain/content.zig");
const tool_set_domain = @import("domain/tool_set.zig");
const tool_catalog = @import("../tools.zig");
const historical_domain = @import("domain/historical.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const rsql = @import("rsql.zig");
const Access = @import("access.zig").Access;
const ReadAccess = reads_domain.ReadAccess;
const Engine = @import("engine.zig").Engine;
const Sqlite = @import("engine/Sqlite.zig");
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
const McpExecutionInput = action_domain.McpExecutionInput;
const BashExecutionInput = action_domain.BashExecutionInput;
const CommandObservation = command_domain.CommandObservation;
const ConfigureReply = configuration_domain.ConfigureReply;
const Found = @import("access.zig").Found;
const ContentLocation = content_domain.ContentLocation;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const HistoricalView = historical_domain.HistoricalView;
const MessageReply = command_domain.MessageReply;
const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelFailureClass = model_settlement_domain.ModelFailureClass;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const ModelOperationKind = historical_domain.ModelOperationKind;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const PrefixSeal = historical_domain.PrefixSeal;
const PublicConversationPage = reads_domain.PublicConversationPage;
const SessionListOptions = report_domain.SessionListOptions;
const SessionObservation = reads_domain.SessionObservation;
const SessionReport = report_domain.SessionReport;
const SessionReportCapture = report_domain.SessionReportCapture;
const SessionReportOptions = report_domain.SessionReportOptions;
const SessionStopReply = command_domain.SessionStopReply;
const SupersedingControl = action_domain.SupersedingControl;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const Queue = @import("queue.zig").Queue;

pub const Store = struct {
    io: std.Io,
    /// The connection, its prepared statements and an Entry's content
    /// read handle.
    engine: Engine,
    selector: protocol.Bounded(protocol.max_store_bytes),
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
    /// `since` hint, touched only by the Store's holder. Owned: `openWithOptions` maps it
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
    served: protocol.Routes = protocol.routesAll(.unserved),
    /// Which use holds the out-of-line scratch in this entry point.
    scratch_use: ScratchUse = .none,
    /// The batch of writes the holder is running (`Queue.Batch`). `.ready`
    /// until a write opens the transaction; `.first` while that write runs,
    /// with no savepoint, so a lone write costs BEGIN and COMMIT as before;
    /// `.open` once it commits, each later write in a savepoint; `.lost`
    /// once a rollback failed, so the batch never commits. A write outside
    /// a batch (a test's own Entry) opens and commits its own.
    batch: enum(u8) { none, ready, first, open, lost } = .none,
    /// Whether the current write's savepoint is open in the batch.
    savepoint: bool = false,
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

    /// Test fixture for a historical producing binding unavailable through
    /// today's immutable Session configuration admission. Requires a newer
    /// current revision, leaving that revision and its frozen inputs intact.
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
        var bounded: protocol.Bounded(protocol.max_model_bytes) = .{};
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

    /// Opens in place: the Host holds exactly one Store, never a copy. It
    /// runs once per process; noinline keeps its work off the caller's
    /// frame, which lives as long as the Host.
    pub noinline fn openWithOptions(
        self: *Store,
        io: std.Io,
        database_path: []const u8,
        selector: []const u8,
        options: OpenOptions,
    ) !void {
        errdefer self.* = undefined;
        const opened = try Sqlite.open(io, database_path, selector, options);
        errdefer opened.abandon();

        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try stored_selector.set(selector);
        const changes = try createRing();
        errdefer destroyRing(changes);
        const ids: *HostValues = &@as(*OutOfLine, @fieldParentPtr("ring", changes)).ids;
        ids.* = .{ .next = undefined };
        self.* = .{ .io = io, .engine = .{ .sqlite = opened }, .selector = stored_selector, .changes = changes };
        self.served = options.served;
        self.queue().* = .init(io, .{ .context = self, .start = startBatch, .finish = finishBatch });
        // The Store is in final storage, so the function may keep its address.
        try self.engine.sqlite.serve(&self.served);
        // Tells this opening's `since` tokens from another's. It grants
        // nothing, so the process CSPRNG serves, and Session IDs keep sole
        // use of secure draws.
        io.random(&self.instance);
        errdefer self.engine.sqlite.statements.deinit();
        try self.engine.sqlite.prepareRollback();
        try loadIdentities(self, .full);
        self.queue().opened();
        if (options.catalog) |offered| try self.saveCatalog(offered) else {
            const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
            owned.tools = .{ .catalog = &tool_catalog.built_in, .set_id = 0 };
        }
    }

    /// Opens the network engine in place. Its buffers live out of line;
    /// SQLite never allocates them. The existing holder remains the sole owner.
    pub noinline fn openMysql(
        self: *Store,
        io: std.Io,
        connection: mysql_connection.Options,
        selector: []const u8,
        options: OpenOptions,
    ) !void {
        errdefer self.* = undefined;
        var opened = try Mysql.open(io, connection, selector, options);
        errdefer opened.close() catch {};
        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try stored_selector.set(selector);
        const changes = try createRing();
        errdefer destroyRing(changes);
        const ids: *HostValues = &@as(*OutOfLine, @fieldParentPtr("ring", changes)).ids;
        ids.* = .{ .next = undefined };
        self.* = .{ .io = io, .engine = .{ .mysql = opened }, .selector = stored_selector, .changes = changes };
        self.served = options.served;
        self.engine.mysql.state.served = &self.served;
        if (@import("builtin").is_test) {
            if (connection.database.len >= self.engine.mysql.state.testing_database.len) return error.MysqlConfigTooLong;
            @memcpy(self.engine.mysql.state.testing_database[0..connection.database.len], connection.database);
        }
        self.queue().* = .init(io, .{ .context = self, .start = startBatch, .finish = finishBatch });
        io.random(&self.instance);
        try loadIdentities(self, .full);
        self.queue().opened();
        if (options.catalog) |offered| try self.saveCatalog(offered) else {
            const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
            owned.tools = .{ .catalog = &tool_catalog.built_in, .set_id = 0 };
        }
    }

    /// The tools the Host offers, and the id of their saved set.
    pub fn catalog(self: *Store) *const HostTools {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.tools;
    }

    /// Saves `offered` as the catalog set, if no set holds it yet: its
    /// records a few to a transaction, then the set in one more. It becomes
    /// the catalog `readCatalog` reads back. Once per open, before any
    /// request.
    pub fn saveCatalog(self: *Store, offered: *const tool_catalog.Catalog) !void {
        if (!offered.valid()) return error.InvalidToolCatalog;
        for (std.enums.values(tool_catalog.Tool)) |tool| {
            const index = offered.find(@tagName(tool)) orelse return error.InvalidToolCatalog;
            if (!std.mem.eql(u8, &offered.digests[index], &tool_catalog.built_in.digests[@backingInt(tool)])) return error.InvalidToolCatalog;
        }
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        owned.tools = .{ .catalog = offered, .set_id = 0 };
        const digest = tool_set_domain.catalogDigest(offered);
        if (try self.queue().write(saveCatalogHeld, .{ self, offered, &digest, @as(?usize, null) })) |set_id| {
            owned.tools.set_id = set_id;
            return;
        }
        var start: usize = 0;
        while (start < offered.records.len) : (start += tool_set_domain.records_per_transaction)
            _ = try self.queue().write(saveCatalogHeld, .{ self, offered, &digest, start });
        owned.tools.set_id = (try self.queue().write(saveCatalogHeld, .{ self, offered, &digest, offered.records.len })).?;
    }

    /// One transaction of `saveCatalog`: with `start` null, the saved set's
    /// id, or null when none holds `offered`; below the record count, the
    /// records from `start`; at it, the set, whose id it returns.
    fn saveCatalogHeld(self: *Store, offered: *const tool_catalog.Catalog, digest: *const [32]u8, start: ?usize) !?u64 {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, saveCatalogStep(&access, offered, digest, start)));
    }

    /// The catalog the last `saveCatalog` saved, read back with every
    /// text, in `allocator`'s memory; null before the first. A Host reads
    /// it at start to keep the tools of a server it cannot reach. A saved
    /// catalog that fails its checks fences the Store.
    pub fn readCatalog(self: *Store, allocator: std.mem.Allocator) !?SavedCatalog {
        return self.readCatalogChecked(allocator) catch |err| switch (err) {
            error.CorruptStore => fence(self, error.CorruptStore),
            else => err,
        };
    }

    fn readCatalogChecked(self: *Store, allocator: std.mem.Allocator) !?SavedCatalog {
        const head = (try self.readCatalogSet()) orelse return null;
        const count = std.math.cast(usize, head.member_count) orelse return error.CorruptStore;
        if (count > tool_catalog.max_catalog_records) return error.CorruptStore;
        const rows = try allocator.alloc(tool_set_domain.catalog_records.Row, count);
        defer allocator.free(rows);
        var filled: usize = 0;
        while (filled < count) {
            const read = try self.readCatalogRecords(head.tool_set_id.get(), filled, rows[filled..]);
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
        var saved: SavedCatalog = .{
            .records = try allocator.alloc(tool_catalog.Record, count),
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
            try self.readCatalogText(row.description_id.get(), description);
            try self.readCatalogText(row.schema_id.get(), schema);
            if (!std.mem.eql(u8, &protocol.contentDigest(description), &row.description_digest) or
                !std.mem.eql(u8, &protocol.contentDigest(schema), &row.schema_digest)) return error.CorruptStore;
            out.* = .{ .name = name, .owner = row.owner, .server = server, .description = description, .input_schema = schema };
            digest.* = tool_catalog.recordDigest(out);
        }
        if (!saved.catalog().valid()) return error.CorruptStore;
        return saved;
    }

    fn take(texts: []u8, used: *usize, length: usize) []u8 {
        defer used.* += length;
        return texts[used.*..][0..length];
    }

    /// The Host's catalog set and its record count, in one round.
    pub fn readCatalogSet(self: *Store) !tool_set_domain.SavedCatalog {
        return self.queue().run(readCatalogSetHeld, .{self});
    }

    /// One round: the catalog set's records from `ordinal`, at most one
    /// batch and `rows.len`; how many it read.
    pub fn readCatalogRecords(self: *Store, set: u64, ordinal: usize, rows: []tool_set_domain.catalog_records.Row) !usize {
        return self.queue().run(readCatalogRecordsHeld, .{ self, set, ordinal, rows });
    }

    fn readCatalogSetHeld(self: *Store) !tool_set_domain.SavedCatalog {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, tool_set_domain.savedCatalogOf(&access));
    }

    fn readCatalogRecordsHeld(self: *Store, set: u64, ordinal: usize, rows: []tool_set_domain.catalog_records.Row) !usize {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, tool_set_domain.catalogRecordsOf(&access, set, ordinal, rows));
    }

    /// `destination` from the content row `content_id`, a window at a time.
    pub fn readCatalogText(self: *Store, content_id: u64, destination: []u8) !void {
        var start: usize = 0;
        while (start < destination.len) {
            const window = destination[start..][0..@min(destination.len - start, content_domain.ContentReader.content_window_bytes)];
            try self.queue().run(readCatalogTextHeld, .{ self, content_id, start, window });
            start += window.len;
        }
    }

    fn readCatalogTextHeld(self: *Store, content_id: u64, start: usize, window: []u8) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.read, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, access.readRaw(content_id, start, window));
    }

    pub fn sqliteDiagnostic(self: *Store) SqliteDiagnostic {
        return self.queue().run(sqliteDiagnosticHeld, .{self});
    }

    fn sqliteDiagnosticHeld(self: *Store) SqliteDiagnostic {
        return self.engine.sqlite.diagnostic();
    }

    pub fn mysqlDiagnostic(self: *Store) Mysql.Diagnostic {
        return self.queue().run(mysqlDiagnosticHeld, .{self});
    }

    fn mysqlDiagnosticHeld(self: *Store) Mysql.Diagnostic {
        return self.engine.mysql.diagnostic();
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

    /// A configuration that requires a model is rejected when the Host does
    /// not serve its Session's provider.
    pub fn configure(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) ConfigureReply {
        return self.queue().write(configureHeld, .{ self, command, @as(?*const configuration_domain.PresetDecision, null), faults });
    }

    /// A Host-resolved preset or its refusal uses the same key lookup,
    /// rejection persistence and transaction as every other configure.
    /// Borrows `preset` until the synchronous queued write returns.
    pub fn configureWithPreset(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        preset: *const configuration_domain.PresetDecision,
        faults: Faults,
    ) ConfigureReply {
        return self.queue().write(configureHeld, .{ self, command, @as(?*const configuration_domain.PresetDecision, preset), faults });
    }

    fn configureHeld(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        preset: ?*const configuration_domain.PresetDecision,
        faults: Faults,
    ) ConfigureReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{SessionUpdateFailed}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, configuration_domain.configure(&access, self.io, self.served, command, preset, faults))) catch .infrastructure_failure;
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
    /// In a batch it runs before the batch's COMMIT; a COMMIT that fails fences the Store, so no Turn reads the admission.
    /// A replayed or rejected Message calls nothing. It cannot fail.
    pub const MessageCommitted = struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque, admission: MessageAdmission) void,
    };

    /// A Message's `require_model` condition checks that the Host serves its
    /// Session's provider before creating anything.
    pub fn submitMessageWithModel(
        self: *Store,
        command: *const protocol.MessageCommand,
        committed: ?MessageCommitted,
        faults: Faults,
    ) MessageReply {
        return self.queue().write(submitMessageWithModelHeld, .{ self, command, committed, faults });
    }

    fn submitMessageWithModelHeld(
        self: *Store,
        command: *const protocol.MessageCommand,
        committed: ?MessageCommitted,
        faults: Faults,
    ) MessageReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{SessionUpdateFailed}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.submitMessage(&access, self.io, self.served, self.selector.slice(), command, committed, faults))) catch .infrastructure_failure;
    }

    pub fn stopSession(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(stopSessionHeld, .{ self, command, faults });
    }

    fn stopSessionHeld(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ InterruptionTargetChanged, StopSelectionChanged }) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.stopSession(&access, command, faults))) catch .infrastructure_failure;
    }

    /// The stop an attached child owes (D38), as `nextCoreWork` names it.
    pub fn stopOwedSession(self: *Store, command: *const protocol.SessionStopCommand, faults: Faults) SessionStopReply {
        return self.queue().write(stopOwedSessionHeld, .{ self, command, faults });
    }

    fn stopOwedSessionHeld(self: *Store, command: *const protocol.SessionStopCommand, faults: Faults) SessionStopReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ InterruptionTargetChanged, StopSelectionChanged }) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.stopOwedSession(&access, command, faults))) catch .infrastructure_failure;
    }

    pub fn interruptModel(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(interruptModelHeld, .{ self, command, faults });
    }

    fn interruptModelHeld(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{InterruptionTargetChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.interruptModel(&access, command, faults))) catch .infrastructure_failure;
    }

    pub fn decidePermission(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(decidePermissionHeld, .{ self, command, faults });
    }

    fn decidePermissionHeld(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.decidePermission(&access, command, faults))) catch .infrastructure_failure;
    }

    pub fn observeCommand(self: *Store, key: []const u8) !CommandObservation {
        return self.queue().run(observeCommandHeld, .{ self, key });
    }

    fn observeCommandHeld(self: *Store, key: []const u8) !CommandObservation {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, command_domain.observeCommand(&access, key));
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
    pub fn publicConversationPage(self: *Store, request: *const protocol.ConversationPage, out: *PublicConversationPage) !void {
        return self.queue().run(publicConversationPageHeld, .{ self, request, out });
    }

    fn publicConversationPageHeld(self: *Store, request: *const protocol.ConversationPage, out: *PublicConversationPage) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.publicConversationPage(&access, request, out));
    }

    // Resolve the public identity again, rather than accepting a global digest:
    // another Session's content or private provider material is not authority.
    pub fn openPublicConversationContent(self: *Store, request: *const protocol.ConversationContent) !ContentLocation {
        return self.queue().run(openPublicConversationContentHeld, .{ self, request });
    }

    fn openPublicConversationContentHeld(self: *Store, request: *const protocol.ConversationContent) !ContentLocation {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.public_content, reads_domain.openPublicConversationContent(&access, request));
    }

    pub fn activityPage(self: *Store, request: *const protocol.ActivityPage, out: *protocol.ActivityFacts) !void {
        return self.queue().run(activityPageHeld, .{ self, request, out });
    }

    fn activityPageHeld(self: *Store, request: *const protocol.ActivityPage, out: *protocol.ActivityFacts) !void {
        try request.validate();
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.activityPage(&access, request, out));
    }

    pub fn searchActivity(self: *Store, request: *const protocol.ActivitySearch, out: *protocol.ActivitySearchFacts) !void {
        return self.queue().run(searchActivityHeld, .{ self, request, out });
    }

    fn searchActivityHeld(self: *Store, request: *const protocol.ActivitySearch, out: *protocol.ActivitySearchFacts) !void {
        try request.validate();
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.searchActivity(&access, request, out));
    }

    pub fn openActivityContent(self: *Store, request: *const protocol.ReadActivityContent) !ContentLocation {
        return self.queue().run(openActivityContentHeld, .{ self, request });
    }

    fn openActivityContentHeld(self: *Store, request: *const protocol.ReadActivityContent) !ContentLocation {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, reads_domain.openActivityContent(&access, request));
    }

    pub fn activityTool(self: *Store, request: *const protocol.ReadActivityContent) !reads_domain.ActivityTool {
        return self.queue().run(activityToolHeld, .{ self, request });
    }

    fn activityToolHeld(self: *Store, request: *const protocol.ReadActivityContent) !reads_domain.ActivityTool {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, reads_domain.activityTool(&access, request));
    }

    /// Authenticates the Session/Operation/Attempt before reading optional
    /// diagnostics. Diagnostic faults never fence canonical state.
    pub fn captureFailedResponse(self: *Store, request: *const protocol.InspectSession, store_dir: std.Io.Dir, options: SessionListOptions) !SessionReport {
        const selection = request.failed_response.?;
        const binding = try self.queue().run(captureFailedResponseHeld, .{ self, request.session.slice(), selection });
        var capture: SessionReportCapture = .{ .io = self.io, .writer = null, .budget = options.scratch_budget };
        try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        try @import("../failed_responses.zig").exportRecord(self.io, store_dir, binding, selection.part, &capture);
        return capture.seal();
    }

    fn captureFailedResponseHeld(self: *Store, session_ref: []const u8, selection: protocol.FailedResponseExport) !AttemptBinding {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, report_domain.failedResponseBinding(&access, session_ref, selection));
    }

    pub fn captureSessionReport(
        self: *Store,
        session_ref: []const u8,
        options: SessionReportOptions,
    ) !SessionReport {
        var capture: SessionReportCapture = .{ .io = self.io, .writer = null, .budget = options.scratch_budget };
        try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        try self.queue().run(captureSessionReportHeld, .{ self, session_ref, options, &capture });
        return capture.seal();
    }

    fn captureSessionReportHeld(self: *Store, session_ref: []const u8, options: SessionReportOptions, capture: *SessionReportCapture) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        try entry.finishCapture(capture, report_domain.renderSessionReport(&access, session_ref, options.profile, options.execution, capture));
    }

    /// Returns an owned, unlinked page; no SQLite cursor survives capture.
    /// The caller releases its scratch charge by deinitializing the report.
    pub fn captureSessionList(self: *Store, request: *const protocol.ListSessions, options: SessionListOptions) !SessionReport {
        try request.validate();
        var capture: SessionReportCapture = .{ .io = self.io, .writer = null, .budget = options.scratch_budget };
        try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        try self.queue().run(captureSessionListHeld, .{ self, request, &capture });
        return capture.seal();
    }

    fn captureSessionListHeld(self: *Store, request: *const protocol.ListSessions, capture: *SessionReportCapture) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        try entry.finishCapture(capture, report_domain.renderSessionList(&access, request, capture));
    }

    pub fn actionArguments(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, .arguments);
    }

    pub fn actionCallId(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, .call_id);
    }

    fn actionContent(self: *Store, session_ref: []const u8, action_id: u64, field: protocol.ProposalField) !ContentReference {
        return self.queue().run(actionContentHeld, .{ self, session_ref, action_id, field });
    }

    fn actionContentHeld(self: *Store, session_ref: []const u8, action_id: u64, field: protocol.ProposalField) !ContentReference {
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
    pub fn admitModelAttempt(self: *Store, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        return self.queue().write(admitModelAttemptHeld, .{ self, kind, faults });
    }

    noinline fn admitModelAttemptHeld(self: *Store, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        var reader: ReadAccess = .open(&entry);
        defer reader.deinit();
        var writer: Access(.write, error{ SelectionChanged, ProjectionFailed, InstructionSelectionFailed }) = .open(&entry);
        defer writer.deinit();
        return entry.finishTransaction(Ordinary.none, faults, writer.end(faults, model_admission_domain.admitNextModelAttempt(&reader, &writer, kind, faults)));
    }

    pub fn admitNextActionAttempt(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        return self.queue().write(admitNextActionAttemptHeld, .{ self, bash_timeout_ms, faults });
    }

    fn admitNextActionAttemptHeld(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.admitNextActionAttempt(&candidate, &access, self.io, bash_timeout_ms, faults)));
    }

    pub fn admitMcpActionAttempt(self: *Store, action_id: u64, timeout_ms: u64, faults: Faults) !?ActionAttemptBinding {
        return self.queue().write(admitMcpActionAttemptHeld, .{ self, action_id, timeout_ms, faults });
    }
    fn admitMcpActionAttemptHeld(self: *Store, action_id: u64, timeout_ms: u64, faults: Faults) !?ActionAttemptBinding {
        if (timeout_ms == 0 or timeout_ms > std.math.maxInt(i64)) return error.InvalidMcpTimeout;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.admitMcpActionAttempt(&access, self.io, action_id, timeout_ms, faults)));
    }
    pub fn readMcpExecutionInput(self: *Store, binding: ActionAttemptBinding, out: *McpExecutionInput) !void {
        return self.queue().run(readMcpExecutionInputHeld, .{ self, binding, out });
    }
    fn readMcpExecutionInputHeld(self: *Store, binding: ActionAttemptBinding, out: *McpExecutionInput) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_attempt, action_domain.readMcpExecutionInput(&access, binding, out));
    }

    /// `out` is valid only when this returns without error.
    pub fn readBashExecutionInput(self: *Store, binding: ActionAttemptBinding, out: *BashExecutionInput) !void {
        return self.queue().run(readBashExecutionInputHeld, .{ self, binding, out });
    }

    fn readBashExecutionInputHeld(self: *Store, binding: ActionAttemptBinding, out: *BashExecutionInput) !void {
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
        // SQLite's one-statement autocommit is already atomic. Network
        // writes must include the ownership fence in the same transaction.
        if (self.engine == .mysql) {
            var access: Access(.write, error{}) = .open(&entry);
            defer access.deinit();
            return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, action_domain.revokeActionSender(&access, binding)));
        }
        var access: Access(.single, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.revokeActionSender(&access, binding));
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
        return self.queue().write(deliverChildEndingHeld, .{ self, turn_id, faults });
    }

    fn deliverChildEndingHeld(self: *Store, turn_id: u64, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.deliverChildEnding(&access, turn_id, faults)));
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
        return self.queue().write(deliverAgentMessageHeld, .{ self, binding, target, text, faults });
    }

    fn deliverAgentMessageHeld(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, faults: Faults) !AgentDelivery {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, command_domain.deliverAgentMessage(&access, binding, target, text, faults)));
    }

    /// Runs the `start_agent` call `binding` names with its checked
    /// arguments, in one transaction; `configuration` is the agent's spec,
    /// which this completes. `committed` runs once the task is admitted.
    pub fn startAgent(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *protocol.Configuration, committed: ?MessageCommitted, faults: Faults) !AgentStart {
        return self.queue().write(startAgentHeld, .{ self, binding, caller, task, attached, configuration, committed, faults });
    }

    fn startAgentHeld(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *protocol.Configuration, committed: ?MessageCommitted, faults: Faults) !AgentStart {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.agent_start) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.agent_start, faults, access.end(faults, command_domain.startAgent(&access, self.io, binding, caller, task, attached, configuration, committed, faults)));
    }

    /// Loads matching saved tools and resolves the call in one transaction.
    pub fn findTools(self: *Store, binding: ActionAttemptBinding, arena: std.mem.Allocator, words: *const @import("../core_tools.zig").FindTools, refusal: ?[]const u8, faults: Faults) !bool {
        return self.queue().write(findToolsHeld, .{ self, binding, arena, words, refusal, faults });
    }

    fn findToolsHeld(self: *Store, binding: ActionAttemptBinding, arena: std.mem.Allocator, words: *const @import("../core_tools.zig").FindTools, refusal: ?[]const u8, faults: Faults) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, @import("domain/find_tools.zig").run(&access, binding, arena, words, refusal, faults)));
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

    pub fn nextMcpAction(self: *Store) !?action_domain.McpAction {
        return self.queue().run(nextMcpActionHeld, .{self});
    }
    fn nextMcpActionHeld(self: *Store) !?action_domain.McpAction {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.nextMcpAction(&access));
    }
    pub fn resolveMcpAction(self: *Store, action_id: u64, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
        return self.queue().write(resolveMcpActionHeld, .{ self, action_id, code, text, faults });
    }
    fn resolveMcpActionHeld(self: *Store, action_id: u64, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
        if (text.len == 0) return error.InvalidActionResult;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.resolveMcpAction(&access, action_id, code, text, faults)));
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

    pub fn tryAdmitNextModelRetry(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        return self.queue().write(tryAdmitNextModelRetryHeld, .{ self, active, faults });
    }

    fn tryAdmitNextModelRetryHeld(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{RetryNoLongerDue}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, model_admission_domain.tryAdmitNextModelRetry(&candidate, &access, self.io, active, faults)));
    }

    /// Opens the view in `out`, where it stays until it closes: a view
    /// borrows its own buffers, so it never moves.
    pub fn openHistoricalView(self: *Store, binding: AttemptBinding, out: *HistoricalView) !void {
        _ = try model_settlement_domain.checkAttempt(self, binding);
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
        std.debug.assert(report.len <= protocol.max_report_bytes and std.unicode.utf8ValidateSlice(report));
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
    served: protocol.Routes = protocol.routesAll(.endpoint),
    cache_spill: bool = true,
    cache_kib: u32 = 1024,
    found_schema_version: ?*u32 = null,
    /// The tools the Host offers, which it keeps for the Store's life.
    /// Null saves none: the Host reads the last one back (`readCatalog`)
    /// and saves its own (`saveCatalog`) before it serves.
    catalog: ?*const tool_catalog.Catalog = &tool_catalog.built_in,
};

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
    journal_mode: ?protocol.Bounded(16) = null,
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
    // The settlement batch is the larger use: 19240 bytes, the original
    // 14480 plus 4760 for per-batch call names, membership flags and their
    // lookup visitor. The configure reads use 13552, including the saved
    // parent reference and the saved tool and loaded names a subset update
    // reads. Exact, so a change to either size is a decision.
    if (@sizeOf(configuration_domain.ConfigurationReads) != 13552 or scratch_bytes != 19240)
        @compileError(std.fmt.comptimePrint("the Store's scratch is {d} bytes and the configure reads {d}; restate them here", .{ scratch_bytes, @sizeOf(configuration_domain.ConfigurationReads) }));
    if (scratch_bytes - 4888 > accepted_settlement_growth) @compileError("the settlement batch outgrew what the owner accepted");
}

/// The change ring, and the scratch beside it, in pages of their own,
/// which the kernel faults in only as they are written: an idle Host keeps
/// none of the ring's 88 KiB resident. A configure, a creating Message or
/// a success settlement writes the scratch's pages once, and they stay
/// resident for the Store's life: at most 19240 bytes, a settlement
/// batch's size; a configure uses 13552.
/// Not `Allocator.create`, whose ReleaseSafe 0xAA fill would write every
/// page now.
fn createRing() error{OutOfMemory}!*change_ring.Ring {
    const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(OutOfLine), .of(OutOfLine), @returnAddress()) orelse return error.OutOfMemory;
    const ring: *change_ring.Ring = &@as(*OutOfLine, @ptrCast(@alignCast(bytes))).ring;
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

    /// Report capture marks its own scratch failures ordinary.
    fn finishCapture(self: Entry, capture: *const SessionReportCapture, result: anytype) @TypeOf(result) {
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            if (capture.ordinary_failure) return err;
            return fence(self.store, err);
        };
    }

    pub fn release(self: Entry) void {
        const store = self.store;
        store.engine.releaseEntry();
        store.scratch_use = .none;
        // Counts autocommit and explicit-transaction writes alike. A
        // rolled-back change touched everything: never a missed change.
        if (store.engine.totalChanges() != self.changes) {
            if (@import("builtin").is_test) if (untouchedForTesting(store)) |id|
                std.debug.panic("rows of Session {s} changed, but the entry point that changed them did not touch it", .{&id});
            const generation = store.commit_generation.fetchAdd(1, .release) + 1;
            store.changes.record(generation, &store.touched);
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
    if (self.isFenced()) return error.StoreFenced;
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
        .first, .lost => unreachable,
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
            self.batch = .open;
            return;
        },
        .open => {
            try self.engine.control(.release);
            self.savepoint = false;
            return;
        },
        .none => {},
        .ready, .lost => unreachable,
    }
    try self.engine.control(.commit);
    self.identities().taken = .empty;
    self.identities().second = 0;
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
    }
    commitBatch(self) catch return false;
    return true;
}

fn commitBatch(self: *Store) !void {
    switch (self.batch) {
        .ready => {},
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

/// The only fence setter. Returns `err` so callers can propagate it.
pub fn fence(self: *Store, err: anytype) @TypeOf(err) {
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

pub fn activityPageForTesting(self: *Store, request: protocol.ActivityPage) !protocol.ActivityFacts {
    var page: protocol.ActivityFacts = undefined;
    try self.activityPage(&request, &page);
    return page;
}

pub fn publicConversationPageForTesting(self: *Store, request: protocol.ConversationPage) !PublicConversationPage {
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
fn saveCatalogStep(a: anytype, offered: *const tool_catalog.Catalog, digest: *const [32]u8, start: ?usize) !?u64 {
    const at = start orelse {
        var set: tool_set_domain.CatalogSet = null;
        tool_set_domain.lookupCatalog(a, digest, &set);
        try a.run();
        const row = set orelse {
            try a.abandon(.{});
            return null;
        };
        if (row.current) {
            try a.abandon(.{});
        } else {
            tool_set_domain.pointCatalog(a, row.tool_set_id.get());
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
    tool_set_domain.insertCatalog(a, offered, digest, set_id);
    tool_set_domain.pointCatalog(a, set_id);
    try a.commit();
    return set_id;
}

/// A catalog `readCatalog` read back, in its caller's memory.
pub const SavedCatalog = struct {
    records: []tool_catalog.Record,
    digests: [][32]u8,
    /// Every name, server and text the records point into.
    texts: []u8,

    pub fn catalog(self: *const SavedCatalog) tool_catalog.Catalog {
        return .{ .records = self.records, .digests = self.digests };
    }

    pub fn deinit(self: *SavedCatalog, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.digests);
        allocator.free(self.texts);
        self.* = undefined;
    }
};

/// The tools the Host offers and the id of their saved set, which
/// configure resolves a Session's tool names against.
const HostTools = struct {
    catalog: *const tool_catalog.Catalog,
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
    if (self.engine == .mysql) {
        inline for (comptime std.enums.values(Identity)) |column| if (columns.contains(column)) {
            const Ceiling = IdentityCeiling(column);
            try self.engine.bind(null, Ceiling, &.{}, 0);
        };
        if (@import("builtin").is_test) {
            if (columns.count() != 0) self.engine.mysql.state.testing_shape.identity_passes += 1;
        }
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
        .none, .ready => return rollbackTransaction(self, faults),
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
