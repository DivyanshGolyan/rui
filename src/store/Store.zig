const std = @import("std");
const stderr = @import("../stderr.zig");
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
const action_control_domain = @import("domain/action_control.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const skills_domain = @import("domain/skills.zig");
const content_domain = @import("domain/content.zig");
const content_parts = @import("domain/content_parts.zig");
const tool_set_domain = @import("domain/tool_set.zig");
const model_facts_domain = @import("domain/model_facts.zig");
const model_catalog = @import("../model_catalog.zig");
const tool_record = @import("../tool_record.zig");
const historical_domain = @import("domain/historical.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const action_read_domain = @import("domain/action_read.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const session_list_read = @import("domain/session_list_read.zig");
const session_report_read = @import("domain/session_report_read.zig");
const rsql = @import("rsql.zig");
const store_access = @import("access.zig");
const transition = @import("transition.zig");
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
const RequestPage = historical_domain.RequestPage;
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
const SessionPinReply = command_domain.SessionPinReply;
const SupersedingControl = action_domain.SupersedingControl;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const Queue = @import("queue.zig").Queue;

pub const Observed = command_reply.Observed;

pub const Store = struct {
    io: std.Io,
    engine: Engine,
    selector: Bounded(store_path.max_bytes),
    fenced: std.atomic.Value(bool) = .init(false),
    commit_generation: std.atomic.Value(u64) = .init(0),
    touched: change_ring.Touched = .{},
    changes: *change_ring.Ring,
    instance: [16]u8 = undefined,
    served: provider_route.Routes = provider_route.all(.unserved),
    scratch_use: ScratchUse = .none,
    batch: enum(u8) { none, ready, first, open, saved, lost } = .none,
    savepoint: bool = false,
    release_bulk_memory: bool = false,
    testing_content_work: if (@import("builtin").is_test) TestingContentWork else void = if (@import("builtin").is_test) .{} else {},

    pub fn modelTimingSource(self: *Store) *@import("../model_timing.zig").Source {
        return &@as(*OutOfLine, @fieldParentPtr("ring", self.changes)).model_timings;
    }

    pub inline fn identities(self: *const Store) *HostValues {
        return &@as(*OutOfLine, @fieldParentPtr("ring", self.changes)).ids;
    }

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

    pub fn setPrefixSealForTesting(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        return self.recordPrefixSeal(binding, seal);
    }

    pub fn setHistoricalModelForTesting(self: *Store, binding: AttemptBinding, model: []const u8) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        var bounded: Bounded(model_capability.max_model_bytes) = .{};
        try bounded.set(model);
        if (bounded.len == 0) return error.InvalidModel;
        try self.engine.sqlite.setHistoricalModelForTesting(binding.operation_id, model);
    }

    pub fn damageOutputBagForTesting(self: *Store, binding: AttemptBinding) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        try self.engine.sqlite.damageOutputBagForTesting(binding.operation_id);
    }

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
        var opening: *Engine = &opened;
        errdefer opening.close() catch {};

        var stored_selector: Bounded(store_path.max_bytes) = .{};
        try stored_selector.set(opened.publicSelector(selector));
        const changes = try createRing();
        errdefer destroyRing(changes);
        const ids: *HostValues = &@as(*OutOfLine, @fieldParentPtr("ring", changes)).ids;
        ids.* = .{ .next = undefined };
        self.* = .{ .io = io, .engine = opened, .selector = stored_selector, .changes = changes, .served = options.served };
        opening = &self.engine;
        self.queue().* = .init(io, .{ .context = self, .start = startBatch, .finish = finishBatch, .closed = batchClosed, .arm = armRerun, .recover = recoverRerun });
        try self.engine.serve(&self.served);
        io.random(&self.instance);
        try self.engine.prepareRollback();
        try loadIdentities(self, .full);
        self.queue().opened();
        if (options.host_tool_set) |offered| try self.saveHostToolSet(offered) else {
            const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
            owned.tools = .{ .host_tool_set = &tool_record.built_in_tool_set, .set_id = 0 };
        }
    }

    pub fn openWithOptions(self: *Store, io: std.Io, database_path: []const u8, selector: []const u8, options: OpenOptions) !void {
        return self.openTarget(io, .{ .sqlite = database_path }, selector, options);
    }

    pub fn saveModelFacts(self: *Store, entries: []const model_catalog.Entry, etag: ?[]const u8) !void {
        if (etag) |value| if (value.len > 512) return error.InvalidCatalogEtag;
        return self.queue().write(saveModelFactsHeld, .{ self, entries, etag });
    }

    fn saveModelFactsHeld(self: *Store, entries: []const model_catalog.Entry, etag: ?[]const u8) !void {
        defer if (self.batch == .none) self.engine.releaseUnusedMemory(model_facts_domain.save_statements) else {
            self.release_bulk_memory = true;
        };
        return transition.apply(self, model_facts_domain.Save, .{ .entries = entries, .etag = etag }, .{});
    }

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

    pub fn kind(self: *const Store) Kind {
        return std.meta.activeTag(self.engine);
    }

    pub fn storeId(self: *const Store) []const u8 {
        return self.selector.slice();
    }

    pub fn admissionDiagnostic(self: *const Store) AdmissionDiagnostic {
        return .{ .doublewrite = self.engine.admissionDoublewrite() };
    }

    pub fn hostTools(self: *Store) *const HostTools {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.tools;
    }

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

    fn saveHostToolSetHeld(self: *Store, offered: *const tool_record.HostToolSet, digest: *const [32]u8, start: ?usize) !?u64 {
        return transition.apply(self, tool_set_domain.SaveHostToolSet, .{ .offered = offered, .digest = digest, .start = start }, .{});
    }

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

    pub fn readHostToolSetSet(self: *Store) !tool_set_domain.SavedHostToolSet {
        return self.queue().run(readHostToolSetSetHeld, .{self});
    }

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

    pub fn sqliteDatabase(self: *const Store) Sqlite.Database {
        return self.engine.sqlite.database;
    }

    pub fn close(self: *Store) !void {
        self.queue().closing();
        const closed = self.engine.close();
        destroyRing(self.changes);
        try closed;
        self.* = undefined;
    }

    pub fn settlementBatch(self: *Store) *model_settlement_domain.Batch {
        return @ptrCast(self.scratch(.settlement));
    }

    pub fn configurationReads(self: *Store) *configuration_domain.ConfigurationReads {
        return @ptrCast(self.scratch(.configuration));
    }

    pub fn reportScratch(self: *Store, comptime T: type) *T {
        comptime std.debug.assert(@sizeOf(T) <= scratch_bytes and @alignOf(T) <= scratch_align);
        return @ptrCast(@alignCast(self.scratch(.report)));
    }

    pub fn commitWake(self: *Store) *std.atomic.Value(?*std.Io.Event) {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.commit_wake;
    }

    pub fn queue(self: *Store) *Queue {
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.queue;
    }

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

    pub fn readSkills(self: *Store, allocator: std.mem.Allocator, session: []const u8) !*SkillsState {
        const out = try allocator.create(SkillsState);
        out.* = .{ .workspace = .{ .len = 0 } };
        try self.queue().run(readSkillsHeld, .{ self, allocator, session, out });
        return out;
    }

    fn readSkillsHeld(self: *Store, allocator: std.mem.Allocator, session: []const u8, out: *SkillsState) !void {
        const entry = try enter(self, .none);
        defer entry.release();
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

    pub fn configure(
        self: *Store,
        command: *const content_custody.ConfigureCommand,
        faults: Faults,
    ) error{OutOfMemory}!ConfigureReply {
        return self.configureWithInitialSkills(command, null, null, faults);
    }

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
        var reply: ConfigureReply = undefined;
        transition.apply(self, command_domain.Configure, .{
            .io = self.io,
            .served = self.served,
            .tools = self.hostTools(),
            .command = command,
            .preset = preset,
            .initial_skills = initial_skills,
            .reload_capture = reload_capture,
            .allocator = allocator,
            .committed = committed,
            .reply = &reply,
        }, faults) catch |err| {
            stderr.print("rui: Store configure transition failed: {s}\n", .{@errorName(err)});
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => reply = .infrastructure_failure,
            }
        };
        if (reply == .rejected)
            reply.rejected.message = configuration_domain.missingToolMessage(self.hostTools().host_tool_set, reply.rejected.code, &command.configuration.tools);
        return reply;
    }

    pub const MessageAdmission = struct {
        session: []const u8,
        admission_id: u64,
        from_peer: bool,
    };

    pub const MessageCommitted = struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque, admission: MessageAdmission) void,
    };

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
        return self.queue().write(submitMessageWithModelHeld, .{ self, command, committed, initial_skills, captured_skill, @as(?*content_parts.Saving, null), faults });
    }

    pub fn submitMessageParts(self: *Store, command: *const content_custody.MessageCommand, loan: @import("../InputCapture.zig").Loan, committed: ?MessageCommitted, faults: Faults) !MessageReply {
        return self.submitMessagePartsCapturedSkills(command, loan, committed, null, null, faults);
    }

    pub fn submitMessagePartsCapturedSkills(
        self: *Store,
        command: *const content_custody.MessageCommand,
        loan: @import("../InputCapture.zig").Loan,
        committed: ?MessageCommitted,
        initial_skills: ?*const skills_domain.Initial,
        captured_skill: ?*const skills_domain.MessageCapture,
        faults: Faults,
    ) !MessageReply {
        var saving = try content_parts.Saving.init(.{ .captured = loan });
        return self.queue().write(submitMessageWithModelHeld, .{ self, command, committed, initial_skills, captured_skill, @as(?*content_parts.Saving, &saving), faults });
    }

    /// Fixture adapter for a compound Message and its captured skills.
    pub fn submitMessagePartsCapturedSkillsForTesting(
        self: *Store,
        command: *const content_custody.MessageCommand,
        loan: @import("../InputCapture.zig").Loan,
        initial_skills: ?*const skills_domain.Initial,
        captured_skill: ?*const skills_domain.MessageCapture,
    ) !MessageReply {
        if (!@import("builtin").is_test) @compileError("test-only compound Message fixture");
        return self.submitMessagePartsCapturedSkills(command, loan, null, initial_skills, captured_skill, .{});
    }

    fn submitMessageWithModelHeld(
        self: *Store,
        command: *const content_custody.MessageCommand,
        committed: ?MessageCommitted,
        initial_skills: ?*const skills_domain.Initial,
        captured_skill: ?*const skills_domain.MessageCapture,
        saving: ?*content_parts.Saving,
        faults: Faults,
    ) MessageReply {
        var reply: MessageReply = undefined;
        transition.apply(self, command_domain.SubmitMessage, .{
            .io = self.io,
            .served = self.served,
            .tools = self.hostTools(),
            .selector = self.selector.slice(),
            .command = command,
            .committed = committed,
            .initial_skills = initial_skills,
            .captured = captured_skill,
            .parts_saving = saving,
            .reply = &reply,
        }, faults) catch {
            reply = .infrastructure_failure;
        };
        if (reply == .rejected) {
            if (command.configuration) |*configuration|
                reply.rejected.message = configuration_domain.missingToolMessage(self.hostTools().host_tool_set, reply.rejected.code, &configuration.tools);
        }
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
        return self.noteControl(transition.apply(self, command_domain.StopSession, .ofStop(command, false), faults) catch .infrastructure_failure);
    }

    pub fn pinSession(self: *Store, command: *const command_input.SessionPinCommand, faults: Faults) SessionPinReply {
        return self.queue().write(pinSessionHeld, .{ self, command, faults });
    }

    fn pinSessionHeld(self: *Store, command: *const command_input.SessionPinCommand, faults: Faults) SessionPinReply {
        return transition.apply(self, command_domain.PinSession, .{ .command = command }, faults) catch .infrastructure_failure;
    }

    pub fn archiveSession(self: *Store, command: *const command_input.SessionArchiveCommand, faults: Faults) SessionArchiveReply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(archiveSessionHeld, .{ self, command, faults });
    }

    fn archiveSessionHeld(self: *Store, command: *const command_input.SessionArchiveCommand, faults: Faults) SessionArchiveReply {
        return self.noteControl(transition.apply(self, command_domain.ArchiveSession, .{ .command = command }, faults) catch .infrastructure_failure);
    }

    pub fn stopOwedSession(self: *Store, command: *const command_input.SessionStopCommand, faults: Faults) SessionStopReply {
        return self.queue().write(stopOwedSessionHeld, .{ self, command, faults });
    }

    fn stopOwedSessionHeld(self: *Store, command: *const command_input.SessionStopCommand, faults: Faults) SessionStopReply {
        return self.noteControl(transition.apply(self, command_domain.StopSession, .ofStop(command, true), faults) catch .infrastructure_failure);
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
        return self.noteControl(transition.apply(self, command_domain.InterruptModel, .{ .command = command }, faults) catch .infrastructure_failure);
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
        return self.noteControl(transition.apply(self, command_domain.DecidePermission, .{ .command = command }, faults) catch .infrastructure_failure);
    }

    pub fn declineForMessage(self: *Store, command: *const command_input.PermissionDecisionCommand, faults: Faults) PermissionDecisionReply {
        return self.queue().write(declineForMessageHeld, .{ self, command, faults });
    }

    fn declineForMessageHeld(self: *Store, command: *const command_input.PermissionDecisionCommand, faults: Faults) PermissionDecisionReply {
        return self.noteControl(transition.apply(self, command_domain.DecidePermission, .{ .command = command, .denial_reason = "declined: a new message arrived; ask again if still needed" }, faults) catch .infrastructure_failure);
    }

    pub fn backgroundAction(self: *Store, source: action_control_domain.Control.Source, faults: Faults) @import("../action_control.zig").Reply {
        EntryTrace.fromControl(faults.control_trace).mark(.requested);
        return self.queue().write(backgroundActionHeld, .{ self, source, faults });
    }

    fn backgroundActionHeld(self: *Store, source: action_control_domain.Control.Source, faults: Faults) @import("../action_control.zig").Reply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        const Control = action_control_domain.Control;
        var control: Control = .{ .input = .{ .source = source, .scratch = self.reportScratch(Control.Scratch) } };
        const result = entry.finishTransaction(Control.Ordinary, faults, transition.run(&entry, Control, &control, faults)) catch @import("../action_control.zig").Reply.infrastructure_failure;
        return self.noteControl(result);
    }

    fn unchangedSession(self: *const Store, since: ?change_ring.SessionToken) ?change_ring.SessionToken {
        const token = since orelse return null;
        return if (self.notModified(.{ .instance = token.instance, .generation = token.generation })) token else null;
    }

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
        return entry.finish(Ordinary.activity_content, reads_domain.openActivityContent(&access, request));
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

    pub fn failedResponseBinding(self: *Store, session_ref: []const u8, operation: u64, attempt_ordinal: u64) !AttemptBinding {
        return self.queue().run(failedResponseBindingHeld, .{ self, session_ref, operation, attempt_ordinal });
    }

    fn failedResponseBindingHeld(self: *Store, session_ref: []const u8, operation: u64, attempt_ordinal: u64) !AttemptBinding {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(error{ContentNotFound}, report_domain.failedResponseBinding(&access, session_ref, operation, attempt_ordinal));
    }

    pub fn readSessionReport(self: *Store, session_ref: []const u8, profile: cli_value.ReportProfile, visitor: anytype) !void {
        const PressureRead = model_admission_domain.PartsPressure.Read;
        var mapped: ?@import("../os/pages.zig").Mapped(PressureRead) = null;
        defer if (mapped) |work| {
            work.value.deinit();
            work.unmap();
        };
        var pressure: session_report_read.Pressure = .{};
        var token: ?change_ring.SessionToken = null;
        while (!try self.readSessionReportStep(session_ref, profile, visitor, &pressure, &token)) {
            const coverage = pressure.needed orelse return error.CorruptStore;
            if (mapped == null) mapped = try @import("../os/pages.zig").Mapped(PressureRead).map();
            const read = mapped.?.value;
            read.deinit();
            read.init(coverage.session, coverage.covered, coverage.frontier, coverage.results, std.math.maxInt(i64));
            read.boundary = pressure.needed_boundary;
            read.rule = pressure.needed_rule;
            while (!try self.advancePartsPressure(read)) {}
            pressure.read = read;
        }
    }

    /// Returns before visitor output when canonical pressure needs preparation.
    /// The caller owns and may cancel the scanner between short Store entries.
    pub fn readSessionReportStep(self: *Store, session_ref: []const u8, profile: cli_value.ReportProfile, visitor: anytype, pressure: *session_report_read.Pressure, token: *?change_ring.SessionToken) !bool {
        var watched: session_report_read.Watched(@TypeOf(visitor)) = .{ .visitor = visitor };
        return self.queue().run(SessionReportHeld(@TypeOf(visitor)).readSessionReportHeld, .{ self, session_ref, profile, &watched, pressure, token });
    }

    fn SessionReportHeld(comptime Visitor: type) type {
        return struct {
            fn readSessionReportHeld(self: *Store, session_ref: []const u8, profile: cli_value.ReportProfile, watched: *session_report_read.Watched(Visitor), pressure: *session_report_read.Pressure, token: *?change_ring.SessionToken) !bool {
                const entry = try enter(self, .none);
                defer entry.release();
                const generation = self.commitGeneration();
                if (pressure.read != null and self.unchangedSessionHeld(token.*, generation) == null) pressure.read = null;
                var access: ReadAccess = .open(&entry);
                defer access.deinit();
                const result = session_report_read.readSessionReportWithPressure(&access, session_ref, profile, watched, pressure);
                if (result) |_| {} else |err| {
                    if (err == error.PartsPressureRequired) {
                        token.* = .{ .instance = self.instance, .generation = generation, .session = session_ref[0..session_id.bytes].* };
                        return false;
                    }
                }
                try entry.finishCapture(watched.failed, result);
                return true;
            }
        };
    }

    pub const RetryDeadlineRead = struct { generation: u64, next: ?u64 };

    pub fn publishRetryCrossings(self: *Store, from: u64, now: u64) !RetryDeadlineRead {
        return self.queue().run(publishRetryCrossingsHeld, .{ self, from, now });
    }

    fn publishRetryCrossingsHeld(self: *Store, from: u64, now: u64) !RetryDeadlineRead {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        var crossings: session_list_read.RetryCrossings = .{};
        const next = try entry.finish(Ordinary.none, session_list_read.retryCrossings(&access, from, now, &crossings));
        if (crossings.touched.count != 0 or crossings.touched.everything) {
            const generation = self.commit_generation.fetchAdd(1, .release) + 1;
            self.changes.record(generation, &crossings.touched);
            if (self.commitWake().load(.acquire)) |wake| wake.set(self.io);
        }
        return .{ .generation = self.commitGeneration(), .next = next };
    }

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

    pub fn readAction(self: *Store, request: *const @import("../action_read.zig").Request, out: *@import("../action_read.zig").Read) !void {
        return self.queue().run(readActionHeld, .{ self, request, out });
    }

    fn readActionHeld(self: *Store, request: *const @import("../action_read.zig").Request, out: *@import("../action_read.zig").Read) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_read, action_read_domain.actionRead(&access, request, out));
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

    pub fn admitModelAttempt(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        return self.admitModelAttemptInto(admission_kind, faults, null);
    }

    pub fn admitModelAttemptInto(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults, start: ?historical_domain.Start) !?AttemptAdmission {
        const mapped = try @import("../os/pages.zig").Mapped(model_admission_domain.AdmissionPreparation).map();
        defer mapped.unmap();
        mapped.value.init();
        defer mapped.value.deinit();
        while (true) switch (try self.admitModelAttemptStep(admission_kind, faults, start, mapped.value)) {
            .progress => {},
            .done => |selected_attempt| return selected_attempt,
        };
    }

    /// A compound preflight advances one canonical read per call. No Entry or
    /// transaction survives a progress result.
    pub fn admitModelAttemptStep(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults, start: ?historical_domain.Start, preparation: *model_admission_domain.AdmissionPreparation) !model_admission_domain.AdmissionProgress {
        std.debug.assert(preparation.kind == null or preparation.kind == admission_kind);
        errdefer preparation.deinit();
        if (preparation.phase == .weighing) {
            if (try self.advancePartsPressure(&preparation.read)) preparation.phase = .ready;
            return .progress;
        }
        if (preparation.floor) |mapped| if (!mapped.value.ready) {
            _ = try self.advanceHistoryFloor(mapped.value);
            return .progress;
        };
        const selected_attempt = try self.queue().write(admitModelAttemptHeld, .{ self, admission_kind, faults, start, preparation });
        if (selected_attempt != null) {
            preparation.deinit();
            return .{ .done = selected_attempt };
        }
        if (preparation.pending()) return .progress;
        return .{ .done = null };
    }

    pub fn advancePartsPressure(self: *Store, read: *model_admission_domain.PartsPressure.Read) !bool {
        return self.queue().run(advancePartsPressureHeld, .{ self, read });
    }

    fn advancePartsPressureHeld(self: *Store, read: *model_admission_domain.PartsPressure.Read) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(error{}, read.step(&access));
    }

    noinline fn admitModelAttemptHeld(self: *Store, admission_kind: ModelAdmissionKind, faults: Faults, start: ?historical_domain.Start, preparation: *model_admission_domain.AdmissionPreparation) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        const starting: ?model_admission_domain.AdmitModel.Starting = if (start) |into| if (self.engine.batches()) .{ .start = into, .selector = &self.selector } else null else null;
        const first = admitModelAttemptOnce(&entry, admission_kind, .weighed, faults, starting, preparation);
        const due = if (first) |_| false else |err| err == error.CompactionDue;
        if (due and preparation.phase == .candidate) {
            preparation.phase = .weighing;
            return null;
        }
        const outcome = if (due) admitModelAttemptOnce(&entry, admission_kind, .over, faults, starting, preparation) else first;
        return entry.finishTransaction(Ordinary.none || error{FloorPreparationRequired}, faults, if (preparation.pending()) outcome else idleUnlessAdmitted(&entry, outcome)) catch |err| {
            if (err != error.FloorPreparationRequired) return err;
            if (preparation.floor) |mapped| {
                mapped.value.deinit();
                mapped.value.init(preparation.floor_operation);
            } else {
                const mapped = try @import("../os/pages.zig").Mapped(@import("domain/history_floor.zig").Preparation).map();
                mapped.value.init(preparation.floor_operation);
                preparation.floor = mapped;
            }
            preparation.kind = admission_kind;
            return null;
        };
    }

    noinline fn idleUnlessAdmitted(entry: *const Entry, outcome: anytype) !?AttemptAdmission {
        if (try outcome) |selected| return selected;
        var checks: model_admission_domain.CheckIdle = .{};
        try transition.run(entry, model_admission_domain.CheckIdle, &checks, .{});
        return null;
    }

    noinline fn admitModelAttemptOnce(entry: *const Entry, admission_kind: ModelAdmissionKind, pressure: model_admission_domain.Pressure, faults: Faults, starting: ?model_admission_domain.AdmitModel.Starting, preparation: *model_admission_domain.AdmissionPreparation) !?AttemptAdmission {
        const Admit = model_admission_domain.AdmitModel;
        var admission: Admit = .{ .input = .{
            .entry = entry,
            .kind = admission_kind,
            .pressure = pressure,
            .preparation = preparation,
            .faults = faults,
            .start = starting,
            .scratch = entry.store.reportScratch(Admit.Scratch),
        } };
        return transition.run(entry, Admit, &admission, faults);
    }

    pub fn admitNextActionAttempt(
        self: *Store,
        capacity: action_domain.Capacity,
        timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        return self.queue().write(admitNextActionAttemptHeld, .{ self, capacity, timeout_ms, faults });
    }

    fn admitNextActionAttemptHeld(
        self: *Store,
        capacity: action_domain.Capacity,
        timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        if (timeout_ms == 0 or timeout_ms > std.math.maxInt(i64)) return error.InvalidActionTimeout;
        return transition.apply(self, action_domain.AdmitNextAttempt, .{ .io = self.io, .timeout_ms = timeout_ms, .capacity = capacity }, faults);
    }

    pub fn admitActionAttempt(self: *Store, selected: ReadyAction, timeout_ms: u64, faults: Faults) !?ActionAttemptAdmission {
        return self.queue().write(admitActionAttemptHeld, .{ self, selected, timeout_ms, faults });
    }
    fn admitActionAttemptHeld(self: *Store, selected: ReadyAction, timeout_ms: u64, faults: Faults) !?ActionAttemptAdmission {
        if (timeout_ms == 0 or timeout_ms > std.math.maxInt(i64)) return error.InvalidActionTimeout;
        return transition.apply(self, action_domain.AdmitSelected, .{ .io = self.io, .selected = selected, .timeout_ms = timeout_ms }, faults);
    }
    pub fn readActionExecutionInput(self: *Store, comptime runner: tool_record.Runner, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
        return switch (runner) {
            .bash => self.queue().run(readBashExecutionInputHeld, .{ self, binding, out }),
            .read_image => self.queue().run(readImageExecutionInputHeld, .{ self, binding, out }),
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

    fn readImageExecutionInputHeld(self: *Store, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_attempt, action_domain.readImageExecutionInput(&access, binding, out));
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
        return transition.apply(self, action_domain.RevokeSender, .{ .binding = binding }, .{});
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
        _ = try self.queue().callHeld(withActionDispatchHandoffHeld, .{ self, binding });
        defer self.queue().release();
        try handoff(context);
    }

    pub fn withActionLaunchHandoff(self: *Store, binding: ActionAttemptBinding, context: anytype, comptime handoff: anytype) !void {
        const cutoff = try self.queue().callHeld(withActionDispatchHandoffHeld, .{ self, binding });
        defer self.queue().release();
        try handoff(context, cutoff);
    }

    fn withActionDispatchHandoffHeld(self: *Store, binding: ActionAttemptBinding) !u64 {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_dispatch, action_domain.validateActionDispatch(&access, binding));
    }

    pub fn messageAfterActionLaunch(self: *Store, binding: ActionAttemptBinding, cutoff: u64) !bool {
        return self.queue().run(messageAfterActionLaunchHeld, .{ self, binding, cutoff });
    }

    fn messageAfterActionLaunchHeld(self: *Store, binding: ActionAttemptBinding, cutoff: u64) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.messageAfterLaunch(&access, binding, cutoff));
    }

    pub fn settleActionAttempt(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        return self.queue().write(settleActionAttemptHeld, .{ self, binding, code, result, null, faults });
    }

    fn settleActionAttemptHeld(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        parts: ?@import("../InputCapture.zig").Loan,
        faults: Faults,
    ) !ActionSettlement {
        // The serialized settlement lends the existing Store workspace to its
        // compound publisher, including failures before the first Entry.
        comptime std.debug.assert(@sizeOf(content_parts.Saving) <= scratch_bytes and @alignOf(content_parts.Saving) <= scratch_align);
        const saving: *content_parts.Saving = @ptrCast(@alignCast(self.scratch(.action)));
        defer self.scratch_use = .none;
        saving.* = try .init(if (parts) |captured| .{ .captured = captured } else .{ .text = .{ .slice = result } });
        if (saving.reference == .bytes and saving.reference.bytes.length == 0) return error.InvalidActionResult;
        return transition.apply(self, action_domain.SettleAttempt, .{ .binding = binding, .code = code, .result = result, .saving = saving, .io = self.io }, faults);
    }

    /// Publishes the ordered value at the Action's sole immutable Resolution.
    /// A single Text uses the same byte representation as settleActionAttempt.
    pub fn settleActionAttemptParts(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: @import("../InputCapture.zig").Loan,
        faults: Faults,
    ) !ActionSettlement {
        return self.queue().write(settleActionAttemptHeld, .{ self, binding, code, &.{}, result, faults });
    }

    pub fn deliverChildEnding(self: *Store, turn_id: u64, faults: Faults) !bool {
        return self.deliverChildEndingBound(turn_id, null, faults);
    }

    pub fn deliverChildEndingBound(self: *Store, turn_id: u64, captured: ?*const skills_domain.MessageCapture, faults: Faults) !bool {
        return self.queue().write(deliverChildEndingHeld, .{ self, turn_id, captured, faults });
    }

    fn deliverChildEndingHeld(self: *Store, turn_id: u64, captured: ?*const skills_domain.MessageCapture, faults: Faults) !bool {
        var ending: command_domain.DeliverChildEnding.Ending = undefined;
        return transition.apply(self, command_domain.DeliverChildEnding, .{ .turn_id = turn_id, .captured = captured, .ending = &ending }, faults);
    }

    pub fn deliverSessionForward(self: *Store, forward_id: u64, faults: Faults) !bool {
        return self.queue().write(deliverSessionForwardHeld, .{ self, forward_id, faults });
    }

    fn deliverSessionForwardHeld(self: *Store, forward_id: u64, faults: Faults) !bool {
        return transition.apply(self, forward_domain.Deliver, .{ .forward_id = forward_id }, faults);
    }

    pub fn dispatchWork(self: *Store, paused: bool, capacity: action_domain.Capacity) !DispatchWork {
        return self.queue().run(dispatchWorkHeld, .{ self, paused, capacity });
    }

    fn dispatchWorkHeld(self: *Store, paused: bool, capacity: action_domain.Capacity) !DispatchWork {
        const survey = self.identities().survey;
        const asked: @FieldType(Survey, "asked") = if (paused) .paused else .running;
        self.identities().survey.kept = .none;
        self.identities().survey.asked = asked;
        self.identities().survey.capacity = capacity;
        if (survey.kept == .ready and survey.asked == asked and std.meta.eql(survey.capacity.workInput(), capacity.workInput()) and !self.isFenced())
            return .{ .core = survey.core, .mcp = survey.mcp, .bash = survey.bash, .message = survey.message, .tool_continuation = survey.tool_continuation, .retry = survey.retry, .retry_waiting = survey.retry_waiting };
        const entry = try enter(self, .none);
        defer entry.release();
        var access: store_access.Access(.survey, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, model_admission_domain.dispatchWork(&access, paused, capacity));
    }

    pub fn nextCoreWork(self: *Store, capacity: action_domain.Capacity) !?CoreWork {
        return self.queue().run(nextCoreWorkHeld, .{ self, capacity });
    }

    fn nextCoreWorkHeld(self: *Store, capacity: action_domain.Capacity) !?CoreWork {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.nextCoreWork(&access, capacity));
    }

    pub fn deliverAgentMessage(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, faults: Faults) !AgentDelivery {
        return self.deliverAgentMessageBound(binding, target, text, null, faults);
    }

    pub fn deliverAgentMessageBound(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentDelivery {
        return self.queue().write(deliverAgentMessageHeld, .{ self, binding, target, text, captured, faults });
    }

    fn deliverAgentMessageHeld(self: *Store, binding: ActionAttemptBinding, target: []const u8, text: []const u8, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentDelivery {
        return transition.apply(self, command_domain.DeliverAgentMessage, .{ .binding = binding, .target = target, .text = text, .captured = captured }, faults);
    }

    pub fn startAgent(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *content_custody.Configuration, committed: ?MessageCommitted, faults: Faults) !AgentStart {
        return self.startAgentWithInitialSkills(binding, caller, task, attached, configuration, committed, null, null, faults);
    }

    pub fn startAgentWithInitialSkills(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *content_custody.Configuration, committed: ?MessageCommitted, initial_skills: ?*const skills_domain.Initial, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentStart {
        return self.queue().write(startAgentHeld, .{ self, binding, caller, task, attached, configuration, committed, initial_skills, captured, faults });
    }

    fn startAgentHeld(self: *Store, binding: ActionAttemptBinding, caller: []const u8, task: []const u8, attached: bool, configuration: *content_custody.Configuration, committed: ?MessageCommitted, initial_skills: ?*const skills_domain.Initial, captured: ?*const skills_domain.MessageCapture, faults: Faults) !AgentStart {
        var result_buffer: [tool_record.HostToolSet.max_refusal_message_bytes]u8 = undefined;
        return transition.apply(self, command_domain.StartAgent, .{
            .io = self.io,
            .served = self.served,
            .tools = self.hostTools(),
            .binding = binding,
            .caller = caller,
            .task = task,
            .attached = attached,
            .configuration = configuration,
            .committed = committed,
            .initial_skills = initial_skills,
            .captured = captured,
            .result_buffer = &result_buffer,
        }, faults);
    }

    pub fn findTools(self: *Store, binding: ActionAttemptBinding, arena: std.mem.Allocator, words: *const @import("../find_tools_words.zig").FindTools, refusal: ?[]const u8, faults: Faults) !bool {
        return self.queue().write(findToolsHeld, .{ self, binding, arena, words, refusal, faults });
    }

    fn findToolsHeld(self: *Store, binding: ActionAttemptBinding, arena: std.mem.Allocator, words: *const @import("../find_tools_words.zig").FindTools, refusal: ?[]const u8, faults: Faults) !bool {
        return transition.apply(self, @import("domain/find_tools.zig").FindTools, .{ .binding = binding, .arena = arena, .words = words, .refusal = refusal }, faults);
    }

    pub fn settleSkillTool(self: *Store, binding: ActionAttemptBinding, allocator: std.mem.Allocator, captured: *const skills_domain.Capture, faults: Faults) !bool {
        return self.queue().write(settleSkillToolHeld, .{ self, binding, allocator, captured, faults });
    }

    fn settleSkillToolHeld(self: *Store, binding: ActionAttemptBinding, allocator: std.mem.Allocator, captured: *const skills_domain.Capture, faults: Faults) !bool {
        return transition.apply(self, skills_domain.SettleTool, .{ .binding = binding, .allocator = allocator, .captured = captured }, faults);
    }

    pub fn stopAction(self: *Store, source: ActionAttemptBinding, target: u64, faults: Faults) !@import("domain/action_stop.zig").Outcome {
        const result = try self.queue().write(stopActionHeld, .{ self, @as(@import("domain/action_stop.zig").Source, .{ .model = .{ .binding = source, .target = target } }), faults });
        return result.model;
    }

    pub fn requestActionStop(self: *Store, request: *const @import("../command_input.zig").ActionStopCommand, faults: Faults) @import("domain/action_stop.zig").Reply {
        const result = self.queue().write(stopActionHeld, .{ self, @as(@import("domain/action_stop.zig").Source, .{ .command = request }), faults }) catch return .infrastructure_failure;
        return result.command;
    }

    fn stopActionHeld(self: *Store, source: @import("domain/action_stop.zig").Source, faults: Faults) !@import("domain/action_stop.zig").Stop.Result {
        const Stop = @import("domain/action_stop.zig").Stop;
        const result = try transition.apply(self, Stop, .{ .source = source, .scratch = self.reportScratch(Stop.Scratch) }, faults);
        const selected = switch (result) {
            .model => |outcome| outcome == .selected or outcome == .pending,
            .command => |reply| reply == .accepted,
        };
        if (selected) _ = @as(*OutOfLine, @fieldParentPtr("ring", self.changes)).control_generation.fetchAdd(1, .release);
        return result;
    }

    pub fn failCoreCall(self: *Store, binding: ActionAttemptBinding, result: []const u8, faults: Faults) !bool {
        return self.queue().write(resolveCoreCallHeld, .{ self, binding, ActionResolutionCode.failed, result, faults });
    }

    pub fn succeedCoreCall(self: *Store, binding: ActionAttemptBinding, result: []const u8, faults: Faults) !bool {
        return self.queue().write(resolveCoreCallHeld, .{ self, binding, ActionResolutionCode.succeeded, result, faults });
    }

    fn resolveCoreCallHeld(self: *Store, binding: ActionAttemptBinding, code: ActionResolutionCode, result: []const u8, faults: Faults) !bool {
        return transition.apply(self, command_domain.ResolveCoreCall, .{ .binding = binding, .code = code, .result = result }, faults);
    }

    pub fn nextAction(self: *Store, comptime runner: tool_record.Runner, capacity: action_domain.Capacity) !?ReadyAction {
        if (runner != .bash and runner != .mcp and runner != .read_image) @compileError("only Action runners can select Actions");
        return self.queue().run(nextActionHeld, .{ self, runner, capacity });
    }
    fn nextActionHeld(self: *Store, runner: tool_record.Runner, capacity: action_domain.Capacity) !?ReadyAction {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, switch (runner) {
            .bash => action_domain.nextAction(&access, .bash, capacity),
            .mcp => action_domain.nextAction(&access, .mcp, capacity),
            .read_image => action_domain.nextAction(&access, .read_image, capacity),
            .core, .provider => unreachable,
        });
    }
    pub fn resolveAction(self: *Store, selected: ReadyAction, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
        return self.queue().write(resolveActionHeld, .{ self, selected, code, text, faults });
    }
    fn resolveActionHeld(self: *Store, selected: ReadyAction, code: ActionResolutionCode, text: []const u8, faults: Faults) !void {
        if (text.len == 0) return error.InvalidActionResult;
        return transition.apply(self, action_domain.ResolveSelected, .{ .selected = selected, .code = code, .text = text }, faults);
    }

    pub fn recoverOneUncertainAction(self: *Store, active: ActiveOperationFilter) !bool {
        return self.queue().write(recoverOneUncertainActionHeld, .{ self, active });
    }

    fn recoverOneUncertainActionHeld(self: *Store, active: ActiveOperationFilter) !bool {
        return transition.apply(self, action_domain.RecoverUncertain, .{ .active = active }, .{});
    }

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
        return transition.apply(self, model_admission_domain.AdmitRetry, .{ .io = self.io, .active = active, .scheduled = scheduled }, faults);
    }

    pub fn readRequestPage(self: *Store, page: *RequestPage) !void {
        return historical_domain.readPage(self, page);
    }

    pub fn readHistoricalMessagePart(self: *Store, page: *RequestPage) !RequestPage.MessageProgress {
        return self.queue().run(readHistoricalMessagePartHeld, .{ self, page });
    }

    fn readHistoricalMessagePartHeld(self: *Store, page: *RequestPage) !RequestPage.MessageProgress {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, historical_domain.messagePartFrom(&access, page));
    }

    pub fn readPublicParts(self: *Store, reader: *@import("domain/public_parts.zig").Reader) !@import("domain/public_parts.zig").Progress {
        return self.queue().run(readPublicPartsHeld, .{ self, reader });
    }

    fn readPublicPartsHeld(self: *Store, reader: *@import("domain/public_parts.zig").Reader) !@import("domain/public_parts.zig").Progress {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.public_parts, @import("domain/public_parts.zig").step(&access, reader));
    }

    /// One indexed part of a Session-scoped owner's parts value, at `start`.
    pub fn openPublicPart(self: *Store, session: []const u8, owner: @import("../content_value.zig").Owner, part: u32, start: u64) !ContentLocation {
        return self.queue().run(openPublicPartHeld, .{ self, session, owner, part, start });
    }

    fn openPublicPartHeld(self: *Store, session: []const u8, owner: @import("../content_value.zig").Owner, part: u32, start: u64) !ContentLocation {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.public_part, @import("domain/public_parts.zig").openPart(&access, session, owner, part, start));
    }

    pub fn modelOperationKind(self: *Store, binding: AttemptBinding) !ModelOperationKind {
        return model_settlement_domain.checkAttempt(self, binding);
    }

    pub fn isFenced(self: *const Store) bool {
        return self.fenced.load(.acquire);
    }

    pub fn commitGeneration(self: *const Store) u64 {
        return self.commit_generation.load(.acquire);
    }

    pub fn controlGeneration(self: *const Store) u64 {
        return @as(*OutOfLine, @fieldParentPtr("ring", self.changes)).control_generation.load(.acquire);
    }

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
        try handoff(context);
    }

    fn withDispatchHandoffHeld(self: *Store, binding: AttemptBinding) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        _ = try entry.finish(Ordinary.attempt_binding, model_settlement_domain.readAttemptKind(&entry, binding));
    }

    pub fn claimModelAuthRefresh(self: *Store, binding: AttemptBinding) !bool {
        return self.queue().write(claimModelAuthRefreshHeld, .{ self, binding });
    }

    fn claimModelAuthRefreshHeld(self: *Store, binding: AttemptBinding) !bool {
        return transition.apply(self, model_settlement_domain.ClaimAuthRefresh, .{ .binding = binding }, .{});
    }

    pub fn settleModelAttemptFailure(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
    ) !void {
        if (try self.settleModelAttemptFailurePrepared(binding, failure, disposition, faults, null)) return;
        const FloorPreparation = @import("domain/history_floor.zig").Preparation;
        const mapped = try @import("../os/pages.zig").Mapped(FloorPreparation).map();
        defer mapped.unmap();
        const work = mapped.value;
        work.init(binding.operation_id);
        defer work.deinit();
        while (true) {
            while (!try self.advanceHistoryFloor(work)) {}
            if (try self.settleModelAttemptFailurePrepared(binding, failure, disposition, faults, &work.prepared.?)) return;
            work.deinit();
            work.init(binding.operation_id);
        }
    }

    pub fn advanceHistoryFloor(self: *Store, work: *@import("domain/history_floor.zig").Preparation) !bool {
        return self.queue().run(advanceHistoryFloorHeld, .{ self, work });
    }

    fn advanceHistoryFloorHeld(self: *Store, work: *@import("domain/history_floor.zig").Preparation) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, work.step(&access));
    }

    /// A missing or stale floor witness requests preparation without settling
    /// the Attempt. Its recipe is checked again inside the final transaction.
    pub fn settleModelAttemptFailurePrepared(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
        prepared: ?*const @import("domain/history_floor.zig").Prepared,
    ) !bool {
        return self.queue().write(settleModelAttemptFailurePreparedHeld, .{ self, binding, failure, disposition, faults, prepared });
    }

    fn settleModelAttemptFailurePreparedHeld(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
        prepared: ?*const @import("domain/history_floor.zig").Prepared,
    ) !bool {
        const code = failure.code();
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        if (failure.diagnostic()) |detail| {
            std.debug.assert(detail.len <= 512 and std.unicode.utf8ValidateSlice(detail));
        }
        const report = failure.report();
        std.debug.assert(report.len <= outcome_code.max_report_bytes and std.unicode.utf8ValidateSlice(report));
        const entry = try enter(self, .fromControl(faults.control_trace));
        defer entry.release();
        var settlement: model_settlement_domain.SettleFailure = .{ .input = .{ .entry = &entry, .floor = self.reportScratch(@import("domain/history_floor.zig").FloorSearch), .prepared = prepared, .io = self.io, .binding = binding, .failure = &failure, .disposition = &disposition } };
        entry.finishTransaction(model_settlement_domain.SettleFailure.Ordinary, faults, transition.run(&entry, model_settlement_domain.SettleFailure, &settlement, faults)) catch |err| {
            if (err == error.FloorPreparationRequired) return false;
            return err;
        };
        return true;
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
        return transition.apply(self, model_settlement_domain.RecoverExhausted, .{ .active = active }, .{});
    }

    pub fn recordPrefixSeal(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
        return self.queue().write(recordPrefixSealHeld, .{ self, binding, seal });
    }

    fn recordPrefixSealHeld(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
        return transition.apply(self, historical_domain.RecordSeal, .{ .binding = binding, .seal = seal }, .{});
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
        const Settle = model_settlement_domain.SettleSuccess;
        var settlement: Settle = .{ .input = .{ .io = self.io, .binding = binding, .output = output, .faults = faults, .batch = self.settlementBatch() } };
        return entry.finishTransaction(Ordinary.model_success, faults, transition.run(&entry, Settle, &settlement, faults));
    }

    pub fn openContent(self: *Store, reference: ContentReference) !ContentLocation {
        return content_domain.openContentIdentity(self, reference, false);
    }

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
    served: provider_route.Routes = provider_route.all(.endpoint),
    cache_spill: bool = true,
    cache_kib: u32 = 1024,
    found_schema_version: ?*u32 = null,
    identity_mismatch: ?*store_schema.IdentityMismatch = null,
    migration_notice: ?store_schema.MigrationNotice = null,
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

const TestingContentWork = struct {
    read: std.atomic.Value(u64) = .init(0),
    blob: std.atomic.Value(u64) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    rounds: u16 = 0,
    content_rounds: u16 = 0,
};

comptime {
    if (@sizeOf(TestingContentWork) != 24) @compileError("TestingContentWork grew past 24 bytes; the test-build Store has no room");
    if (@sizeOf(Store) > 712) @compileError(std.fmt.comptimePrint("Store is {d} bytes; keep large state out of line", .{@sizeOf(Store)}));
}

const OutOfLine = struct {
    model_timings: @import("../model_timing.zig").Source,
    ring: change_ring.Ring,
    queue: Queue,
    ids: HostValues,
    tools: HostTools,
    control_generation: std.atomic.Value(u64),
    commit_wake: std.atomic.Value(?*std.Io.Event),
    scratch: Scratch align(scratch_align),
};

const ScratchUse = enum(u8) { none, configuration, settlement, action, report };

const Scratch = [scratch_bytes]u8;
const scratch_bytes = @max(@sizeOf(configuration_domain.ConfigurationReads), @sizeOf(model_settlement_domain.Batch));
const scratch_align = @max(@alignOf(configuration_domain.ConfigurationReads), @alignOf(model_settlement_domain.Batch));

const accepted_settlement_growth = 14352;

comptime {
    if (@sizeOf(configuration_domain.ConfigurationReads) != 15624 or scratch_bytes != 19048)
        @compileError(std.fmt.comptimePrint("the Store's scratch is {d} bytes and the configure reads {d}; restate them here", .{ scratch_bytes, @sizeOf(configuration_domain.ConfigurationReads) }));
    if (scratch_bytes - 4888 > accepted_settlement_growth) @compileError("the settlement batch outgrew what the owner accepted");
}

/// The change ring, and the scratch beside it, in pages of their own,
/// which the kernel faults in only as they are written: an idle Host keeps
/// none of the ring's 88 KiB resident. A configure, a creating Message or
/// a success settlement writes the scratch's pages once, and they stay
/// resident for the Store's life: at most 19048 bytes, a settlement
/// batch's size; a configure uses 14968.
/// Not `Allocator.create`, whose ReleaseSafe 0xAA fill would write every
/// page now.
fn createRing() error{OutOfMemory}!*change_ring.Ring {
    const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(OutOfLine), .of(OutOfLine), @returnAddress()) orelse return error.OutOfMemory;
    const owned: *OutOfLine = @ptrCast(@alignCast(bytes));
    owned.model_timings = .{};
    owned.control_generation = .init(0);
    owned.commit_wake = .init(null);
    const ring: *change_ring.Ring = &owned.ring;
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

pub const Ordinary = struct {
    pub const none = error{};
    const page = error{ SessionNotFound, InvalidCursor };
    const content = error{ContentNotFound};
    const activity_content = content || error{ContentIsParts};
    /// A text route on a parts value refuses it as ordinary: the parts routes serve it.
    const public_content = error{ ContentNotFound, RangeOutOfBounds, ContentIsParts };
    const public_parts = error{ ContentNotFound, ContentIsText };
    const public_part = public_parts || error{RangeOutOfBounds};
    pub const action = error{ActionNotFound};
    pub const action_read = action || error{InvalidCursor};
    const result = error{ ResultNotFound, ResultNotReady, ResultFailed };
    pub const attempt_binding = error{ StaleAttemptBinding, SupersededByControl };
    pub const historical_entry = error{ HistoricalPending, InputPartsNotSupported };
    pub const model_success = attempt_binding || error{InvalidProviderEnvelope};
    pub const action_attempt = error{StaleActionAttemptBinding};
    const action_dispatch = action_attempt || error{SupersededByControl};
    pub const agent_start = action_attempt || error{SessionUpdateFailed};

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

    pub fn fromControl(trace: ?ControlTrace) EntryTrace {
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

pub const Entry = struct {
    const max_result_bytes = 1024;

    store: *Store,
    trace: EntryTrace,
    changes: i64,
    borrowed: if (@import("builtin").is_test) bool else void,

    pub fn finish(self: Entry, comptime Expected: type, result: anytype) @TypeOf(result) {
        comptime Ordinary.produced(Expected, @TypeOf(result));
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            if (Ordinary.contains(Expected, err)) return err;
            return fence(self.store, err);
        };
    }

    pub fn finishTransaction(self: Entry, comptime Expected: type, faults: Faults, result: anytype) Transaction(@TypeOf(result)) {
        comptime Ordinary.produced(Expected, @TypeOf(result));
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            rollbackAfterError(self.store, faults) catch |rollback_err| return fence(self.store, rollback_err);
            if (Ordinary.contains(Expected, err)) return err;
            return fence(self.store, err);
        };
    }

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

pub fn enter(self: *Store, trace: EntryTrace) error{StoreFenced}!Entry {
    if (self.isFenced() or self.batch == .lost) return error.StoreFenced;
    const borrowed = if (@import("builtin").is_test) borrowed: {
        const off = !self.queue().owned();
        if (off) self.queue().borrow();
        break :borrowed off;
    } else std.debug.assert(self.queue().owned());
    self.touched = .{};
    if (@import("builtin").is_test) clearTouchOracleForTesting(self);
    const entry: Entry = .{ .store = self, .trace = trace, .changes = self.engine.totalChanges(), .borrowed = borrowed };
    trace.mark(.acquired);
    if (self.isFenced()) {
        entry.release();
        return error.StoreFenced;
    }
    return entry;
}

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
        .first, .saved, .lost => unreachable,
    }
    std.debug.assert(!self.savepoint);
    try self.engine.control(.savepoint);
    self.savepoint = true;
}

pub fn commit(self: *Store) !void {
    switch (self.batch) {
        .first => {
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

pub fn commitsWithWrites(self: *Store) bool {
    return self.engine.commitArmed() and self.batch == .first and !self.queue().writeWaiting();
}

pub noinline fn commitWithSurvey(self: *Store, writer: anytype, follow: anytype) void {
    const kept = &self.identities().survey;
    const surveyed = kept.asked != .never;
    if (!surveyed and follow == null) return writer.passCommit(null);
    kept.kept = .none;
    var reads: store_access.Access(.survey, error{}) = .{ .store = self, .tail = true };
    defer reads.deinit();
    if (follow) |after| after.queue(&reads);
    var survey: model_admission_domain.DispatchSurvey = .{};
    if (surveyed) survey.queue(&reads, kept.asked == .paused, kept.capacity);
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
    if (follow) |after| after.followed();
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
    kept.retry_waiting = found.retry_waiting;
    kept.kept = .fresh;
}

fn batchClosed(context: *anyopaque) bool {
    const self: *Store = @ptrCast(@alignCast(context));
    return self.batch == .saved;
}

fn startBatch(context: *anyopaque) void {
    const self: *Store = @ptrCast(@alignCast(context));
    std.debug.assert(self.batch == .none and !self.savepoint);
    self.batch = .ready;
}

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
    commitBatch(self) catch |err| {
        stderr.print("rui: Store batch commit failed: {s}\n", .{@errorName(err)});
        return false;
    };
    const values = self.identities();
    for (values.admitted[0..values.admitted_len]) |*admission| admission.tell();
    return true;
}

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

pub const Announcement = union(enum) {
    message: struct { callback: Store.MessageCommitted, admission: Store.MessageAdmission },
    creation: struct { callback: Store.CreationCommitted, session: []const u8 },
};

pub fn announce(self: *Store, announcement: Announcement) void {
    switch (announcement) {
        .message => |message| admitted(self, message.callback, message.admission),
        .creation => |creation| created(self, creation.callback, creation.session),
    }
}

fn armRerun(context: *anyopaque, on: bool) void {
    const self: *Store = @ptrCast(@alignCast(context));
    if (self.engine == .mysql) self.engine.mysql.state.armed = on;
}

fn recoverRerun(context: *anyopaque) bool {
    const self: *Store = @ptrCast(@alignCast(context));
    if (self.engine != .mysql) return false;
    const mysql = &self.engine.mysql;
    if (mysql.recover()) {
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

pub fn transactionSecond(self: *Store) error{ClockReadFailed}!i64 {
    if (self.identities().second != 0) return self.identities().second;
    const second = std.math.cast(u32, @divFloor(try readUnixMilliseconds(self.io), 1000)) orelse return error.ClockReadFailed;
    if (second == 0) return error.ClockReadFailed;
    if (self.engine.inTransaction()) self.identities().second = second;
    return second;
}

pub fn workspaceDigest(workspace: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(workspace, &digest, .{});
    return digest;
}

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

pub fn fence(self: *Store, err: anytype) @TypeOf(err) {
    if (self.engine == .mysql and self.engine.mysql.defersFence()) return err;
    self.fenced.store(true, .release);
    return err;
}

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

pub const Identity = enum { turn_id, operation_id, action_id, content_id, created_seq, command_seq, admission_id, tool_record_id, tool_set_id, forward_id };

pub const SavedHostToolSet = struct {
    records: []tool_record.Record,
    digests: [][32]u8,
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

pub const HostTools = struct {
    host_tool_set: *const tool_record.HostToolSet,
    set_id: u64,
};

const HostValues = struct {
    next: std.EnumArray(Identity, u64),
    taken: std.EnumSet(Identity) = .empty,
    second: u32 = 0,
    admitted: [Queue.drain_limit + 1]Admitted = undefined,
    admitted_len: u8 = 0,
    survey: Survey = .{},
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
    retry_waiting: bool = false,
    capacity: action_domain.Capacity = .{ .free_credit = .none, .mcp_open = false },
    _: u2 = 0,
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

pub fn takeIdentity(self: *Store, comptime column: Identity) error{ IdentityExhausted, IdentityOutsideTransaction }!u64 {
    if (!self.engine.inTransaction()) return error.IdentityOutsideTransaction;
    const value = self.identities().next.get(column);
    if (value > std.math.maxInt(i64)) return error.IdentityExhausted;
    self.identities().next.set(column, value + 1);
    self.identities().taken.insert(column);
    return value;
}

pub fn reloadIdentitiesForTesting(self: *Store) !void {
    try loadIdentities(self, .full);
}

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
        .first => {
            errdefer self.batch = .lost;
            try rollbackTransaction(self, faults);
            self.batch = .ready;
            return;
        },
        .none, .ready, .saved => return rollbackTransaction(self, faults),
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

test "Store failure diagnostics retain stage and error without changing replies or cleanup" {
    const testing = @import("testing.zig");
    const FailedBatch = struct {
        fn run(storage: *Store, accepted: configuration_domain.AcceptedConfiguration) ConfigureReply {
            storage.batch = .lost;
            return .{ .accepted = accepted };
        }
    };
    for ([_]bool{ false, true }) |suppressed| {
        for ([_]enum { configure, batch }{ .configure, .batch }) |stage| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingSqliteStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [@import("../protocol.zig").max_workspace_bytes]u8 = undefined;
            const workspace = try testing.canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try testing.completeConfiguration("diagnostic-fixture", "", workspace, "model-a");
            const accepted = if (stage == .batch) (try storage.configure(&command, .{})).accepted else null;
            const output = try tmp.dir.createFile(std.testing.io, "diagnostic", .{ .read = true });
            defer output.close(std.testing.io);
            const saved = std.c.dup(2);
            if (saved < 0) return error.SystemResources;
            defer _ = std.c.close(saved);
            if (std.c.dup2(output.handle, 2) < 0) return error.SystemResources;
            defer std.debug.assert(std.c.dup2(saved, 2) >= 0);
            if (suppressed) try std.testing.expect(stderr.tryAcquire());
            defer if (suppressed) stderr.release();

            const reply = switch (stage) {
                .configure => try storage.configure(&command, .{ .before_commit = true }),
                .batch => storage.queue().write(FailedBatch.run, .{ &storage, accepted.? }),
            };
            try std.testing.expect(reply == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectEqual(.none, storage.batch);
            try std.testing.expect(!storage.savepoint);
            try std.testing.expectEqual(@as(usize, 0), storage.identities().admitted_len);
            try std.testing.expectEqual(@as(u64, 0), storage.identities().second);
            try std.testing.expect(!storage.engine.inTransaction());
            var bytes: [256]u8 = undefined;
            const count = try output.readPositional(std.testing.io, &.{&bytes}, 0);
            const expected = if (suppressed) "" else switch (stage) {
                .configure => "rui: Store configure transition failed: InjectedCommitFailure\n",
                .batch => "rui: Store batch commit failed: CanonicalRollbackFailed\n",
            };
            try std.testing.expectEqualStrings(expected, bytes[0..count]);
        }
    }
}
