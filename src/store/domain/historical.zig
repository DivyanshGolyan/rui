//! The historical view a model request reads: settings, conversation entries,
//! outputs, parts, tool results and prefix seals.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_catalog = @import("../../tools.zig");
const output_format = @import("../../output_format.zig");
const prefix_seal = @import("../../prefix_seal.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @This();
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const reads_domain = @import("reads.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const c = sqlite.c;
const AttemptBinding = store_core.AttemptBinding;
const ContentLocation = content_domain.ContentLocation;
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const Ordinary = store_core.Ordinary;
const accepted_resolutions = store_schema.accepted_resolutions;

pub const PrefixSeal = prefix_seal.PrefixSeal;

/// The content row columns a view handle needs, decoded by
/// `readHistoricalContent` in this order.
const historical_content_columns_sql = "content.byte_length,content.digest,content.private";

/// Borrowed from one pointer-stable preparation view. Invalid after it closes.
pub const HistoricalContent = struct {
    view: *HistoricalView,
    // Resolved once with the metadata, so opening needs no digest lookup.
    content_id: i64,
    length: u64,
    digest: [32]u8,
    /// The Store read the whole content and matched its digest.
    verified: bool = false,
    /// A message part's text: `length` bytes at this offset of the message
    /// text of the view's open output item (`content_id` and `digest` are
    /// that text's). Its parts are read in order, and the view checks the
    /// text's digest when the last of them reaches its end.
    text_start: ?u64 = null,

    pub fn belongsTo(self: HistoricalContent, view: *HistoricalView) bool {
        return self.view == view and view.active;
    }
};

pub const ModelOperationKind = output_format.ModelOperationKind;

pub const HistoricalSettings = struct {
    operation: ModelOperationKind = .assistant_response,
    compaction_trigger: ?u64 = null,
    output_reservation: u64 = 0,
    /// Effective effort frozen at admission; null when the binding has no
    /// catalog default and no override.
    reasoning_effort: ?protocol.ReasoningEffort = null,
    provider: protocol.Provider,
    model: protocol.Bounded(protocol.max_model_bytes),
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    /// The originating Operation's own address: canonical Store selector and
    /// exact Session reference, for the Rui-owned request context.
    store: protocol.Bounded(protocol.max_store_bytes),
    session: protocol.Bounded(protocol.max_session_bytes),
    session_affinity: [16]u8,
    baseline_instructions: HistoricalContent,
    output_schema: ?HistoricalContent,
    tools_mask: u8,
};

pub const HistoricalEntryKind = enum { user, instruction, provider_output, tool_results };

pub const HistoricalEntry = struct {
    position: u64,
    kind: HistoricalEntryKind,
    content: ?HistoricalContent = null,
    requested_model: ?protocol.Bounded(protocol.max_model_bytes) = null,
    // A User entry's peer sender, in this view's Store.
    sender: ?protocol.Bounded(protocol.max_session_bytes) = null,
};

/// One saved output item in Rui's own form, as a request writer reads it:
/// what Rui knows, plus the provider bag of the rest. Its parts follow
/// through `HistoricalView.nextOutputPart`.
pub const HistoricalOutput = struct {
    kind: OutputItemKind,
    phase: output_format.NeutralPhase,
    /// The replay rule acceptance judged: leave reasoning_text parts out.
    omit_reasoning_text: bool,
    bag: ?HistoricalContent,
    /// A call's name, call_id and arguments.
    call: ?[3]HistoricalContent,
};

pub const HistoricalPart = struct {
    array: output_format.PartArray,
    kind: output_format.PartKind,
    text: ?HistoricalContent,
    bag: ?HistoricalContent,
};

pub const HistoricalToolResult = struct {
    call_id: HistoricalContent,
    output: HistoricalContent,
};

/// The preparation owner keeps this value at one address until every borrowed
/// handle/reader is discarded. Readers must close before the view closes.
pub const HistoricalView = struct {
    store: *Store,
    binding: AttemptBinding,
    active: bool = true,
    readers: usize = 0,
    tool_group_initialized: bool = false,
    tool_group_scan_after: u64 = 0,
    tool_group_source_cursor: u64 = 0,
    next_tool_group: ?HistoricalEntry = null,
    next_tool_group_source_id: ?u64 = null,
    active_tool_group_source_id: ?u64 = null,
    active_tool_group_after_ordinal: ?u64 = null,
    active_tool_group_count: u64 = 0,
    outputs_validated: bool = false,
    output_frontier: ?u64 = null,
    // The selected base's Operation, found with the frontier; zero for none.
    selected_base: u64 = 0,
    selected_coverage: ?Coverage = null,
    output_boundary: u64 = 0,
    output_cursor: u64 = 0,
    output_cursor_id: u64 = 0,
    group_scan: GroupScan = .{},
    next_tool_group_count: u64 = 0,
    active_tool_group_expected: u64 = 0,
    // Ordinary entries copied from one ranged read. Plain values, never a
    // statement: history below the admission boundary is immutable.
    entries: [entry_batch]HistoricalEntry = undefined,
    entries_next: usize = 0,
    entries_end: usize = 0,
    /// The output item whose parts `nextOutputPart` serves.
    output_parts: ?OutputPartCursor = null,

    const entry_batch = 16;

    const OutputPartCursor = struct {
        operation_id: u64,
        item_ordinal: u64,
        kind: OutputItemKind,
        /// The item's saved part count; the walk must end exactly there.
        count: u64,
        next: u64 = 0,
        /// Arrays already closed: each array's parts are contiguous.
        closed: [2]bool = .{ false, false },
        array: output_format.PartArray = .none,
        /// A message's text, which its text parts cover in order.
        text: ?MessageText = null,
    };

    const MessageText = struct {
        content_id: i64,
        length: u64,
        digest: [32]u8,
        /// Where the next text part starts.
        next: u64 = 0,
        /// Bytes of the text read so far, all in order from its start.
        read: u64 = 0,
        hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
    };

    /// The view's selected Compaction Base: its admission position, from
    /// which accepted output is validated, and the position of its
    /// compaction item. Interpretation belongs to the caller.
    pub const Coverage = struct {
        frontier: u64,
        anchor: ?u64,
    };

    // One population cursor, independent of group/call counts. No
    // statement, blob handle or transaction survives a step.
    const GroupScan = struct {
        source: u64 = 0,
        boundary: u64 = 0,
        admission: u64 = 0,
        expected_items: u64 = 0,
        previous_position: u64 = 0,
        item: u64 = 0,
        calls: u64 = 0,
        position: u64 = 0,
    };

    /// A ready entry lives in the view until its next step.
    pub const EntryProgress = union(enum) { pending, ready: ?*const HistoricalEntry };

    /// Charge discovery/classification items and private authentication bytes
    /// to the same caller allowance. Pending exposes no storage-level state.
    pub fn nextEntryStep(self: *HistoricalView, after_position: u64, bytes_left: *usize, items_left: *usize) !EntryProgress {
        std.debug.assert(self.active and self.outputs_validated and self.active_tool_group_source_id == null);
        if (bytes_left.* == 0 or items_left.* == 0) return .pending;
        items_left.* -= 1;
        return readHistoricalEntry(self.store, self, after_position) catch |err| switch (err) {
            error.HistoricalPending => .pending,
            else => return err,
        };
    }

    /// Each preparation advance checks the Attempt once. Its steps read only
    /// history below the admission boundary, and the handoff checks again.
    pub fn checkAttempt(self: *HistoricalView) !void {
        std.debug.assert(self.active);
        return model_settlement_domain.checkAttempt(self.store, self.binding);
    }

    /// Fills `out`; on error its bytes mean nothing.
    pub fn settings(self: *HistoricalView, out: *HistoricalSettings) !void {
        std.debug.assert(self.active);
        return readHistoricalSettings(self.store, self, out);
    }

    /// Validate at most one producing Operation and its output items,
    /// releasing Store custody between steps. Returns true after the
    /// complete population.
    pub fn validateOutputsStep(self: *HistoricalView) !bool {
        std.debug.assert(self.active);
        return validateHistoricalOutputsStep(self.store, self);
    }

    pub fn nextEntry(self: *HistoricalView, after_position: u64) !?HistoricalEntry {
        std.debug.assert(self.active);
        std.debug.assert(self.active_tool_group_source_id == null);
        while (!try self.validateOutputsStep()) {}
        while (true) {
            var bytes: usize = 64 * 1024;
            var items: usize = 1024;
            switch (try self.nextEntryStep(after_position, &bytes, &items)) {
                .pending => {},
                .ready => |entry| return if (entry) |value| value.* else null,
            }
        }
    }

    /// The validated selected base. The first validation step finds it;
    /// its anchor is read once, on the first call.
    pub fn coverage(self: *HistoricalView) !Coverage {
        std.debug.assert(self.active);
        while (!try self.validateOutputsStep()) {}
        if (self.selected_coverage) |value| return value;
        const value: Coverage = .{
            .frontier = self.output_frontier.?,
            .anchor = if (self.selected_base == 0) null else try readCompactionAnchor(self.store, self.selected_base),
        };
        self.selected_coverage = value;
        return value;
    }

    /// The Session's prefix seal, if a full rebuild has recorded one.
    pub fn prefixSeal(self: *HistoricalView) !?PrefixSeal {
        std.debug.assert(self.active);
        return readPrefixSeal(self.store, self.binding);
    }

    /// Record this view's fully rebuilt span as the Session's seal, while
    /// the Attempt is still current.
    pub fn recordPrefixSeal(self: *HistoricalView, seal: *const PrefixSeal) !void {
        std.debug.assert(self.active);
        return historical_domain.recordPrefixSeal(self.store, self.binding, seal);
    }

    /// The Operation's admission position, the exclusive upper bound of this
    /// view's history. Known once output validation completes.
    pub fn admissionPosition(self: *const HistoricalView) u64 {
        std.debug.assert(self.active and self.outputs_validated);
        return self.output_boundary;
    }

    /// The last producing Operation the tool-group scan has examined. After
    /// the final entry, every earlier Operation of this view is examined.
    pub fn toolGroupCursor(self: *const HistoricalView) u64 {
        std.debug.assert(self.active);
        return self.tool_group_source_cursor;
    }

    /// Start the tool-group scan after `cursor`, before the first entry
    /// read. The caller resumes after the last position that an earlier view
    /// of the same Session covered, with that view's final cursor. Every
    /// Operation at or below that cursor precedes the earlier view's
    /// Operation, whose admission required each of them resolved and each
    /// tool group complete (`runnable_eligibility_sql`); that view checked
    /// each group's position below its admission position and emitted it.
    /// Resolutions and acceptance positions never change, so those groups
    /// all lie at or before the covered position and the scan would only skip
    /// them. The earlier view's own Operation, whose results land after its
    /// admission position, is above the cursor and is scanned.
    pub fn resumeToolGroups(self: *HistoricalView, cursor: u64) void {
        std.debug.assert(self.active and self.outputs_validated and !self.tool_group_initialized);
        self.tool_group_source_cursor = cursor;
    }

    /// A tool-results entry activates one canonical group. Consume it fully
    /// before requesting the next historical entry.
    /// The output item served at `position`, in Rui's own form. Its parts
    /// follow from `nextOutputPart` until it returns null.
    pub fn openOutput(self: *HistoricalView, position: u64) !HistoricalOutput {
        std.debug.assert(self.active and self.output_parts == null);
        return readHistoricalOutput(self.store, self, position);
    }

    pub fn nextOutputPart(self: *HistoricalView) !?HistoricalPart {
        std.debug.assert(self.active and self.output_parts != null);
        return readHistoricalPart(self.store, self);
    }

    pub fn nextToolResult(self: *HistoricalView) !?HistoricalToolResult {
        std.debug.assert(self.active and self.active_tool_group_source_id != null);
        return readHistoricalToolResult(self.store, self);
    }

    /// Opens `out` where it lives. `out` is valid only when this returns
    /// without error.
    pub fn openContent(self: *HistoricalView, reference: HistoricalContent, out: *HistoricalReader) !void {
        std.debug.assert(reference.belongsTo(self));
        // A part's reader reads the message text row only within its range,
        // and the view, not this reader, checks the text's digest.
        const first = reference.text_start orelse 0;
        const identity: ContentReference = .{ .length = first + reference.length, .digest = reference.digest };
        const location: ContentLocation = .{ .store = self.store, .reference = identity, .content_id = reference.content_id };
        out.* = .{ .view = self, .reference = reference };
        out.reader.open(location);
        out.reader.first = first;
        out.reader.verified = reference.verified or reference.text_start != null;
        self.readers += 1;
    }

    pub fn close(self: *HistoricalView) void {
        std.debug.assert(self.active and self.readers == 0);
        self.active = false;
    }

    /// Test/slow-check aid: outstanding borrowed readers owned by this view.
    /// Legal checkpoint is between synchronous preparation advances, while
    /// the preparation owner remains in final storage under the existing
    /// single-owner discipline. No new state is maintained.
    pub fn outstandingReaders(self: *const HistoricalView) usize {
        return self.readers;
    }

    /// Test/slow-check aid: the view has not been closed. Reader closure
    /// before view closure is enforced by the close-path asserts; this
    /// exposes the committed fact for integrity checks.
    pub fn isActive(self: *const HistoricalView) bool {
        return self.active;
    }

    /// Test/slow-check aid: borrowed content belongs to this live view.
    /// References are validated at open; this re-checks the committed fact
    /// without treating notifications or hints as authority.
    pub fn ownsContent(self: *HistoricalView, content: HistoricalContent) bool {
        return content.belongsTo(self);
    }

    /// Test/slow-check aid: this view owns the admitted Attempt binding.
    /// Lets preparation checks verify owner correspondence without exposing
    /// storage rows or a generic query language.
    pub fn bindingMatches(self: *const HistoricalView, expected: AttemptBinding) bool {
        return self.binding.turn_id == expected.turn_id and
            self.binding.operation_id == expected.operation_id and
            self.binding.attempt_ordinal == expected.attempt_ordinal;
    }

    /// Test/slow-check aid: frozen settings references belong to this view.
    pub fn ownsSettings(self: *HistoricalView, frozen: *const HistoricalSettings) bool {
        if (!self.ownsContent(frozen.baseline_instructions)) return false;
        if (frozen.output_schema) |schema| {
            if (!self.ownsContent(schema)) return false;
        }
        return true;
    }
};

pub const HistoricalReader = struct {
    reader: ContentReader = undefined,
    view: *HistoricalView,
    reference: HistoricalContent,
    active: bool = true,

    pub fn usable(self: *const HistoricalReader) bool {
        return self.active and self.reference.belongsTo(self.view);
    }

    /// Test/slow-check aid: this live reader is owned by the given view.
    /// Reuses the same active/borrowed-view facts as the production read
    /// path; introduces no registry or additional state.
    pub fn ownedBy(self: *const HistoricalReader, view: *HistoricalView) bool {
        return self.view == view and self.usable();
    }

    /// Replay reads in order, so its content reader checks every value's
    /// digest at its end.
    pub fn read(self: *HistoricalReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.usable() and (self.reader.verified or start == self.reader.verified_position));
        const base = self.reference.text_start orelse return self.reader.read(start, destination);
        const text = &self.view.output_parts.?.text.?;
        std.debug.assert(start <= self.reference.length and base + start == text.read);
        const wanted: usize = @intCast(@min(destination.len, self.reference.length - start));
        const count = try self.reader.read(base + start, destination[0..wanted]);
        text.hash.update(destination[0..count]);
        text.read += count;
        if (count != 0 and text.read == text.length and !std.mem.eql(u8, &text.hash.finalResult(), &text.digest))
            return store_core.fence(self.view.store, error.CorruptStore);
        return count;
    }

    pub fn close(self: *HistoricalReader) void {
        std.debug.assert(self.usable());
        self.reader.close();
        self.view.readers -= 1;
        self.active = false;
    }
};

pub const OutputItemKind = output_format.OutputItemKind;

fn readHistoricalSettings(self: *Store, view: *HistoricalView, out: *HistoricalSettings) !void {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, readHistoricalSettingsLocked(self, view, out));
}

fn readHistoricalSettingsLocked(self: *Store, view: *HistoricalView, out: *HistoricalSettings) !void {
    const statement = try store_core.cached(
        self,
        "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id,r.tools_mask,r.provider,o.session_ref,r.workspace,o.compaction_trigger,o.output_reservation,o.reasoning_effort,s.codec,s.codec_options IS NULL " ++
            "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref JOIN session_revision r ON r.session_ref=o.session_ref " ++
            "AND r.revision=o.settings_revision JOIN session_revision baseline ON baseline.session_ref=o.session_ref AND baseline.revision=1 WHERE o.operation_id=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, view.binding.operation_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    try sqlite.readText(statement, 0, &out.model);
    const instructions_id = try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
    const output_schema_id = try sqlite.readNullablePositiveI64(statement, 2);
    const tools = c.sqlite3_column_int(statement, 3);
    if (tools < 0 or tools > tool_catalog.all_tools_mask) return error.CorruptStore;
    out.tools_mask = @intCast(tools);
    out.baseline_instructions = try historicalContent(self, view, instructions_id);
    out.output_schema = if (output_schema_id) |content_id| try historicalContent(self, view, content_id) else null;
    try sqlite.readText(statement, 5, &out.session);
    try sqlite.readText(statement, 6, &out.workspace);
    out.store = self.selector;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("rui/session-affinity/v1");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, self.selector.len, .big);
    hash.update(&length);
    hash.update(self.selector.slice());
    std.mem.writeInt(u64, &length, out.session.len, .big);
    hash.update(&length);
    hash.update(out.session.slice());
    out.operation = try model_settlement_domain.readModelOperationKind(self, view.binding.operation_id);
    out.compaction_trigger = try sqlite.readNullableTokens(statement, 7, false);
    out.output_reservation = try sqlite.readNullableTokens(statement, 8, true) orelse return error.CorruptStore;
    out.reasoning_effort = try sqlite.readNullableEffort(statement, 9);
    out.provider = try sqlite.readProvider(statement, 4);
    // Requests are built by the provider's one codec, which takes no
    // options; a Session pinned to anything else cannot be served.
    var codec: protocol.Bounded(40) = .{};
    try sqlite.readText(statement, 10, &codec);
    if (!codec.eql(@tagName(out.provider.codec())) or c.sqlite3_column_int(statement, 11) != 1) return error.CorruptStore;
    out.session_affinity = hash.finalResult()[0..16].*;
}

fn readHistoricalEntry(self: *Store, view: *HistoricalView, after_position: u64) !HistoricalView.EntryProgress {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return .{ .ready = try access.finish(Ordinary.historical_entry, readHistoricalEntryLocked(self, view, after_position)) };
}

fn validateHistoricalOutputsStep(self: *Store, view: *HistoricalView) !bool {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, validateHistoricalOutputsStepLocked(self, view));
}

fn readPrefixSeal(self: *Store, binding: AttemptBinding) !?PrefixSeal {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, readPrefixSealLocked(self, binding));
}

pub fn readPrefixSealLocked(self: *Store, binding: AttemptBinding) !?PrefixSeal {
    const statement = try store_core.cached(self, "SELECT s.prefix_seal FROM model_operation o JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.operation_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return null;
    if (c.sqlite3_column_type(statement, 0) != c.SQLITE_BLOB) return error.CorruptStore;
    return try PrefixSeal.decode(sqlite.columnBytes(statement, 0));
}

fn recordPrefixSeal(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finishTransaction(Ordinary.attempt_binding, .{}, recordPrefixSealLocked(self, binding, seal));
}

fn recordPrefixSealLocked(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    try store_core.execute(self, "BEGIN IMMEDIATE");
    try model_settlement_domain.validateCurrentAttempt(self, binding);
    const update = try store_core.cached(self, "UPDATE session SET prefix_seal=?2 WHERE session_ref=(SELECT session_ref FROM model_operation WHERE operation_id=?1)");
    defer sqlite.resetCached(update);
    try sqlite.bindU64(update, 1, binding.operation_id);
    const bytes = seal.encode();
    try sqlite.bindBlob(update, 2, &bytes);
    try sqlite.expectDone(update);
    if (c.sqlite3_changes(self.database) != 1) return error.CorruptStore;
    try store_core.execute(self, "COMMIT");
}

fn readCompactionAnchor(self: *Store, base_id: u64) !u64 {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, readCompactionAnchorLocked(self, base_id));
}

/// The position of the base's one compaction item.
fn readCompactionAnchorLocked(self: *Store, base_id: u64) !u64 {
    // A compaction item is its provider bag: the opaque continuation.
    const anchor = try store_core.cached(self, "SELECT session_position,extras_content_id FROM model_output_item INDEXED BY model_output_compaction_anchor WHERE operation_id=?1 AND item_kind=4 ORDER BY item_ordinal");
    defer sqlite.resetCached(anchor);
    try sqlite.bindU64(anchor, 1, base_id);
    if (c.sqlite3_step(anchor) != c.SQLITE_ROW) return error.CorruptStore;
    const position = c.sqlite3_column_int64(anchor, 0);
    const content_id = sqlite.optionalColumnId(anchor, 1) orelse return error.CorruptStore;
    if (position <= 0 or content_id <= 0) return error.CorruptStore;
    _ = try content_domain.readContentMetadata(self, content_id);
    if (c.sqlite3_step(anchor) != c.SQLITE_DONE) return error.CorruptStore;
    return @intCast(position);
}

// Each step checks one producing Operation and its items in one
// statement. Its own item count detects even a completely missing output.
// No statement or lock survives this one step.
fn validateHistoricalOutputsStepLocked(self: *Store, view: *HistoricalView) !bool {
    if (view.outputs_validated) return true;
    if (view.output_frontier == null) {
        const boundary = try store_core.cached(self, "SELECT current.admission_position,base.operation_id,coalesce(base.admission_position,0) " ++
            "FROM model_operation current LEFT JOIN model_operation base ON base.operation_id=(SELECT selected.operation_id " ++
            "FROM model_operation selected INDEXED BY model_operation_compaction_bases WHERE selected.session_ref=current.session_ref AND selected.purpose=1 " ++
            "AND " ++ store_schema.resolutionIs("selected.resolution_code", .compacted) ++ " AND selected.admission_position<current.admission_position ORDER BY selected.admission_position DESC LIMIT 1) " ++
            "WHERE current.operation_id=?1");
        defer sqlite.resetCached(boundary);
        try sqlite.bindU64(boundary, 1, view.binding.operation_id);
        if (c.sqlite3_step(boundary) != c.SQLITE_ROW) return error.CorruptStore;
        view.output_boundary = try sqlite.readNullableTokens(boundary, 0, false) orelse return error.CorruptStore;
        view.selected_base = try sqlite.readNullableTokens(boundary, 1, false) orelse 0;
        view.output_frontier = try sqlite.readNullableTokens(boundary, 2, true) orelse return error.CorruptStore;
        return false;
    }
    // The primary key makes ordinals unique, so the count, the first and
    // last ordinal and one position offset prove ordinals 0..count-1 at
    // consecutive positions, all after admission and below the boundary.
    const source = try store_core.cached(self, "SELECT source.operation_id,source.admission_position,source.output_item_count,source.purpose," ++
        "(SELECT count(*)=source.output_item_count AND coalesce(min(item.item_ordinal)=0 AND max(item.item_ordinal)=count(*)-1 " ++
        "AND min(item.session_position-item.item_ordinal)=max(item.session_position-item.item_ordinal) " ++
        "AND min(item.session_position)>source.admission_position AND max(item.session_position)<?4 " ++
        "AND min(item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal),1) " ++
        "FROM model_output_item item WHERE item.operation_id=source.operation_id) " ++
        "FROM model_operation current JOIN model_operation source INDEXED BY model_operation_context_history ON source.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND source.admission_position>=?2 AND (source.admission_position,source.operation_id)>(?3,?5) " ++
        "AND source.admission_position<?4 AND " ++ store_schema.oneOf("source.resolution_code", &accepted_resolutions) ++ " " ++
        "ORDER BY source.admission_position,source.operation_id LIMIT 1");
    defer sqlite.resetCached(source);
    try sqlite.bindU64(source, 1, view.binding.operation_id);
    // SQLite seeks the index only on this bound, never on the row value,
    // so it carries the cursor; each step then starts at the next
    // Operation instead of rescanning from the frontier.
    try sqlite.bindU64(source, 2, @max(view.output_frontier.?, view.output_cursor));
    try sqlite.bindU64(source, 3, view.output_cursor);
    try sqlite.bindU64(source, 4, view.output_boundary);
    try sqlite.bindU64(source, 5, view.output_cursor_id);
    const result = c.sqlite3_step(source);
    if (result == c.SQLITE_DONE) {
        view.outputs_validated = true;
        return true;
    }
    if (result != c.SQLITE_ROW) return error.CorruptStore;
    view.output_cursor_id = try sqlite.readNullableTokens(source, 0, false) orelse return error.CorruptStore;
    view.output_cursor = try sqlite.readNullableTokens(source, 1, false) orelse return error.CorruptStore;
    const expected = try sqlite.readNullableTokens(source, 2, true) orelse return error.CorruptStore;
    if (c.sqlite3_column_int(source, 3) == 1 and expected == 0) return error.CorruptStore;
    if (c.sqlite3_column_int(source, 4) != 1) return error.CorruptStore;
    return false;
}

/// The served entry lives in the view: in its read-ahead, its next tool
/// group or its output check.
fn readHistoricalEntryLocked(self: *Store, view: *HistoricalView, after_position: u64) !?*const HistoricalEntry {
    std.debug.assert(view.outputs_validated);
    var scan_tool_groups = !view.tool_group_initialized;
    if (view.tool_group_initialized and after_position < view.tool_group_scan_after) {
        view.entries_end = 0;
        view.tool_group_source_cursor = 0;
        view.next_tool_group = null;
        view.next_tool_group_source_id = null;
        scan_tool_groups = true;
    } else if (view.next_tool_group) |*group| {
        if (group.position <= after_position) {
            view.next_tool_group = null;
            view.next_tool_group_source_id = null;
            scan_tool_groups = true;
        }
    }
    if (scan_tool_groups) {
        view.tool_group_initialized = false;
        if (try readNextHistoricalToolGroup(self, view)) |group| {
            view.tool_group_source_cursor = group.source_operation_id;
            if (group.position > after_position) {
                view.next_tool_group = .{ .position = group.position, .kind = .tool_results };
                view.next_tool_group_source_id = group.source_operation_id;
            } else return error.HistoricalPending;
        }
        view.tool_group_initialized = true;
    }
    view.tool_group_scan_after = after_position;
    const ordinary = try nextOrdinaryHistoricalEntry(self, view, after_position) orelse return activateHistoricalToolGroup(self, view);
    if (view.next_tool_group) |*group| {
        if (group.position < ordinary.position) return activateHistoricalToolGroup(self, view);
    }
    return ordinary;
}

/// The next host input or output item after `after_position`, served from
/// the view's read-ahead and refilled by one ranged query.
fn nextOrdinaryHistoricalEntry(self: *Store, view: *HistoricalView, after_position: u64) !?*const HistoricalEntry {
    while (view.entries_next < view.entries_end) : (view.entries_next += 1) {
        if (view.entries[view.entries_next].position > after_position) return &view.entries[view.entries_next];
    }
    view.entries_next = 0;
    view.entries_end = 0;
    errdefer view.entries_end = 0;
    const statement = try store_core.cached(
        self,
        "SELECT e.session_position,e.entry_kind,e.content_id," ++ historical_content_columns_sql ++ ",NULL,NULL,NULL,NULL,NULL," ++
            "(SELECT m.sender_session_ref FROM message_admission m WHERE e.entry_kind=1 AND m.admission_id=e.source_admission_id),NULL " ++
            "FROM model_operation current JOIN conversation_entry e ON e.session_ref=current.session_ref " ++
            "LEFT JOIN content ON content.content_id=e.content_id " ++
            "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<current.admission_position " ++
            "AND e.entry_kind IN (1,2) UNION ALL " ++
            "SELECT item.session_position,3,NULL,NULL,NULL,NULL,r.model,r.provider,item.item_kind,item.item_id_digest," ++
            store_schema.oneOf("owner.resolution_code", &accepted_resolutions) ++ " AND owner.session_ref=item.session_ref " ++
            "AND owner_turn.session_ref=item.session_ref " ++
            "AND owner.attempt_ordinal=item.attempt_ordinal AND owner.admission_position<item.session_position " ++
            "AND owner.admission_position<current.admission_position AND " ++
            "(item.item_kind!=3 OR " ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ") AND " ++
            "((" ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ")=EXISTS(SELECT 1 FROM model_tool_call tool_call WHERE tool_call.operation_id=owner.operation_id)),NULL," ++
            "item.replay_omits_reasoning_text " ++
            "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
            "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
            "LEFT JOIN turn owner_turn ON owner_turn.turn_id=owner.turn_id " ++
            "LEFT JOIN session_revision r ON r.session_ref=owner.session_ref AND r.revision=owner.settings_revision " ++
            "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position " ++
            std.fmt.comptimePrint("ORDER BY 1 LIMIT {d}", .{HistoricalView.entry_batch}),
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, view.binding.operation_id);
    try sqlite.bindU64(statement, 2, after_position);
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            view.entries[view.entries_end] = try readHistoricalEntryRow(view, statement);
            view.entries_end += 1;
        },
        c.SQLITE_DONE => break,
        else => return error.HistoricalEntryReadFailed,
    };
    return if (view.entries_end == 0) null else &view.entries[0];
}

fn readHistoricalEntryRow(view: *HistoricalView, statement: *c.sqlite3_stmt) !HistoricalEntry {
    const position = c.sqlite3_column_int64(statement, 0);
    const kind_value = c.sqlite3_column_int(statement, 1);
    if (position <= 0) return error.CorruptStore;
    const kind: HistoricalEntryKind = switch (kind_value) {
        1 => .user,
        2 => .instruction,
        3 => .provider_output,
        else => return error.CorruptStore,
    };
    var content: ?HistoricalContent = null;
    var requested_model: ?protocol.Bounded(protocol.max_model_bytes) = null;
    if (kind == .provider_output) {
        // Keep contradictory owners visible instead of filtering their
        // output away. Accepted-population validation cannot see failed
        // owners; every selected item must independently certify one.
        // The item itself is read in Rui's form through `openOutput`.
        if (c.sqlite3_column_int(statement, 10) != 1) return error.CorruptStore;
        var model: protocol.Bounded(protocol.max_model_bytes) = .{};
        try sqlite.readText(statement, 6, &model);
        if (model.len == 0) return error.CorruptStore;
        _ = try sqlite.readProvider(statement, 7);
        requested_model = model;
        _ = std.enums.fromInt(OutputItemKind, c.sqlite3_column_int(statement, 8)) orelse return error.CorruptStore;
        _ = try sqlite.readDigest(statement, 9);
    } else {
        const content_id = c.sqlite3_column_int64(statement, 2);
        if (content_id <= 0) return error.CorruptStore;
        content = try readHistoricalContent(view, statement, 3, content_id, false);
    }
    var sender: ?protocol.Bounded(protocol.max_session_bytes) = null;
    if (c.sqlite3_column_type(statement, 11) != c.SQLITE_NULL) {
        sender = .{};
        try sqlite.readText(statement, 11, &sender.?);
    }
    return .{
        .position = @intCast(position),
        .kind = kind,
        .requested_model = requested_model,
        .sender = sender,
        .content = content,
    };
}

fn activateHistoricalToolGroup(self: *Store, view: *HistoricalView) !?*const HistoricalEntry {
    _ = self;
    const entry = if (view.next_tool_group) |*value| value else return null;
    view.active_tool_group_source_id = view.next_tool_group_source_id orelse return error.CorruptStore;
    view.active_tool_group_after_ordinal = null;
    view.active_tool_group_count = 0;
    view.active_tool_group_expected = view.next_tool_group_count;
    return entry;
}

/// A Tool Results group: its entry is only a position.
const HistoricalToolGroup = struct {
    position: u64,
    source_operation_id: u64,
};

fn readNextHistoricalToolGroup(self: *Store, view: *HistoricalView) !?HistoricalToolGroup {
    const scan = &view.group_scan;
    if (scan.source != 0) {
        // Walk the immutable item population, not just surviving call rows.
        // One item/classification per step also detects wholly missing calls.
        const item = try store_core.cached(self, "SELECT item.item_ordinal,item.item_kind,item.session_ref,item.session_position," ++
            "item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal " ++
            "FROM model_output_item item JOIN model_operation source ON source.operation_id=item.operation_id " ++
            "WHERE item.operation_id=?1 AND item.item_ordinal>=?2 ORDER BY item.item_ordinal LIMIT 1");
        defer sqlite.resetCached(item);
        try sqlite.bindU64(item, 1, scan.source);
        try sqlite.bindU64(item, 2, scan.item);
        const result = c.sqlite3_step(item);
        if (result == c.SQLITE_DONE) {
            const extra = try store_core.cached(self, "SELECT call_ordinal FROM model_tool_call WHERE operation_id=?1 AND call_ordinal>=?2 ORDER BY call_ordinal LIMIT 1");
            defer sqlite.resetCached(extra);
            try sqlite.bindU64(extra, 1, scan.source);
            try sqlite.bindU64(extra, 2, scan.calls);
            if (scan.item != scan.expected_items or scan.calls == 0 or scan.position == 0 or scan.position >= scan.boundary or c.sqlite3_step(extra) != c.SQLITE_DONE)
                return error.CorruptStore;
            const group = HistoricalToolGroup{ .position = scan.position, .source_operation_id = scan.source };
            view.next_tool_group_count = scan.calls;
            scan.source = 0;
            return group;
        }
        if (result != c.SQLITE_ROW or c.sqlite3_column_int64(item, 0) != scan.item) return error.CorruptStore;
        const position = try sqlite.readNullableTokens(item, 3, false) orelse return error.CorruptStore;
        if (scan.item >= scan.expected_items or c.sqlite3_column_int(item, 4) != 1 or
            position <= scan.admission or position >= scan.boundary or
            (scan.item != 0 and position != scan.previous_position + 1)) return error.CorruptStore;
        scan.previous_position = position;
        scan.item += 1;
        if (c.sqlite3_column_int(item, 1) != 3) return error.HistoricalPending;
        var session: protocol.Bounded(protocol.max_session_bytes) = .{};
        try sqlite.readText(item, 2, &session);
        const proposal = try reads_domain.proposalLocked(self, session.slice(), position);
        if (proposal.metadata.operation != scan.source or proposal.metadata.call_ordinal != scan.calls) return error.CorruptStore;
        const outcome = try store_core.cached(self, "SELECT coalesce(tool_call.acceptance_position,action.acceptance_position)," ++
            "coalesce(tool_call.rejection_content_id,action.resolution_content_id)," ++
            "CASE WHEN tool_call.rejection_code IS NOT NULL OR (action.resolution_code IS NOT NULL AND " ++
            "action.session_ref=source.session_ref AND action.tool_kind=tool_call.action_kind) THEN 1 ELSE 0 END " ++
            "FROM model_tool_call tool_call JOIN model_operation source ON source.operation_id=tool_call.operation_id " ++
            "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
            "WHERE tool_call.operation_id=?1 AND tool_call.call_ordinal=?2");
        defer sqlite.resetCached(outcome);
        try sqlite.bindU64(outcome, 1, scan.source);
        try sqlite.bindU64(outcome, 2, scan.calls);
        if (c.sqlite3_step(outcome) != c.SQLITE_ROW or c.sqlite3_column_int(outcome, 2) != 1) return error.CorruptStore;
        const accepted = try sqlite.readNullablePositiveI64(outcome, 0) orelse return error.CorruptStore;
        _ = try content_domain.readPublicContentMetadata(self, try sqlite.readNullablePositiveI64(outcome, 1) orelse return error.CorruptStore);
        scan.position = @max(scan.position, @as(u64, @intCast(accepted)));
        // The call's bytes are authenticated when its entry is served.
        scan.calls += 1;
        return error.HistoricalPending;
    }
    const statement = try store_core.cached(
        self,
        "SELECT source.operation_id,current.admission_position," ++ store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ ",source.admission_position,source.output_item_count FROM model_operation current " ++
            "JOIN model_operation source INDEXED BY model_operation_session_history " ++
            "ON source.session_ref=current.session_ref WHERE current.operation_id=?1 " ++
            "AND source.operation_id>?2 AND source.operation_id<current.operation_id " ++
            "ORDER BY source.operation_id LIMIT 1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, view.binding.operation_id);
    try sqlite.bindU64(statement, 2, view.tool_group_source_cursor);
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return null;
    if (result != c.SQLITE_ROW) return error.HistoricalEntryReadFailed;
    const source_operation_id = c.sqlite3_column_int64(statement, 0);
    const admission_position = c.sqlite3_column_int64(statement, 1);
    if (source_operation_id <= 0 or admission_position <= 0) return error.CorruptStore;
    if (c.sqlite3_column_int(statement, 2) != 1) {
        view.tool_group_source_cursor = @intCast(source_operation_id);
        return error.HistoricalPending;
    }
    scan.source = @intCast(source_operation_id);
    scan.boundary = @intCast(admission_position);
    scan.admission = try sqlite.readNullableTokens(statement, 3, false) orelse return error.CorruptStore;
    scan.expected_items = try sqlite.readNullableTokens(statement, 4, false) orelse return error.CorruptStore;
    scan.previous_position = 0;
    scan.item = 0;
    scan.calls = 0;
    scan.position = 0;
    return error.HistoricalPending;
}

fn readHistoricalOutput(self: *Store, view: *HistoricalView, position: u64) !HistoricalOutput {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, readHistoricalOutputLocked(self, view, position));
}

fn readHistoricalOutputLocked(self: *Store, view: *HistoricalView, position: u64) !HistoricalOutput {
    const statement = try store_core.cached(
        self,
        "SELECT item.operation_id,item.item_ordinal,item.item_kind,item.phase,item.replay_omits_reasoning_text,item.extras_content_id," ++
            "tool_call.name_content_id,tool_call.call_id_content_id,tool_call.arguments_content_id,item.part_count,item.message_content_id " ++
            "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref AND item.session_position=?2 " ++
            "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
            "WHERE current.operation_id=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, view.binding.operation_id);
    try sqlite.bindU64(statement, 2, position);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    const operation_id = c.sqlite3_column_int64(statement, 0);
    const item_ordinal = c.sqlite3_column_int64(statement, 1);
    if (operation_id <= 0 or item_ordinal < 0) return error.CorruptStore;
    const kind = std.enums.fromInt(OutputItemKind, c.sqlite3_column_int(statement, 2)) orelse return error.CorruptStore;
    const phase = std.enums.fromInt(output_format.NeutralPhase, c.sqlite3_column_int(statement, 3)) orelse return error.CorruptStore;
    const omit = c.sqlite3_column_int(statement, 4);
    if (omit != 0 and omit != 1) return error.CorruptStore;
    const bag_id = sqlite.optionalColumnId(statement, 5) orelse return error.CorruptStore;
    const part_count = c.sqlite3_column_int64(statement, 9);
    if (part_count < 0 or (part_count != 0 and kind != .reasoning and kind != .message)) return error.CorruptStore;
    const has_call = c.sqlite3_column_type(statement, 6) != c.SQLITE_NULL;
    if (has_call != (kind == .function_call)) return error.CorruptStore;
    var call_ids: [3]i64 = undefined;
    for (&call_ids, 6..) |*id, column| id.* = sqlite.optionalColumnId(statement, @intCast(column)) orelse if (has_call) return error.CorruptStore else 0;
    const text_id = sqlite.optionalColumnId(statement, 10);
    if ((text_id != null) != (kind == .message)) return error.CorruptStore;
    sqlite.resetCached(statement);
    var text: ?HistoricalView.MessageText = null;
    if (text_id) |id| {
        const content = try historicalContentAs(self, view, id, false);
        // Its parts' reads check a nonempty text; an empty one is
        // checked here.
        if (content.length == 0 and !std.mem.eql(u8, &content.digest, &protocol.contentDigest(""))) return error.CorruptStore;
        text = .{ .content_id = id, .length = content.length, .digest = content.digest };
    }
    var call: ?[3]HistoricalContent = null;
    if (has_call) {
        var fields: [3]HistoricalContent = undefined;
        for (&fields, call_ids) |*content, id| content.* = try historicalContentAs(self, view, id, false);
        call = fields;
    }
    view.output_parts = .{ .operation_id = @intCast(operation_id), .item_ordinal = @intCast(item_ordinal), .kind = kind, .count = @intCast(part_count), .text = text };
    return .{
        .kind = kind,
        .phase = phase,
        .omit_reasoning_text = omit == 1,
        .bag = try historicalBag(self, view, bag_id),
        .call = call,
    };
}

fn readHistoricalPart(self: *Store, view: *HistoricalView) !?HistoricalPart {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, readHistoricalPartLocked(self, view));
}

fn readHistoricalPartLocked(self: *Store, view: *HistoricalView) !?HistoricalPart {
    const cursor = &view.output_parts.?;
    const statement = try store_core.cached(
        self,
        "SELECT part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id FROM model_output_part " ++
            "WHERE operation_id=?1 AND item_ordinal=?2 AND part_ordinal>=?3 ORDER BY part_ordinal LIMIT 1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, cursor.operation_id);
    try sqlite.bindU64(statement, 2, cursor.item_ordinal);
    try sqlite.bindU64(statement, 3, cursor.next);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => {
            // A part missing from the end changes what the model saw,
            // and the text parts cover the whole message text.
            if (cursor.next != cursor.count) return error.CorruptStore;
            if (cursor.text) |text| if (text.next != text.length) return error.CorruptStore;
            view.output_parts = null;
            return null;
        },
        c.SQLITE_ROW => if (cursor.next == cursor.count) return error.CorruptStore,
        else => return error.HistoricalEntryReadFailed,
    }
    if (c.sqlite3_column_int64(statement, 0) != cursor.next) return error.CorruptStore;
    const array = std.enums.fromInt(output_format.PartArray, c.sqlite3_column_int(statement, 1)) orelse return error.CorruptStore;
    const kind = std.enums.fromInt(output_format.PartKind, c.sqlite3_column_int(statement, 2)) orelse return error.CorruptStore;
    const text_length = try sqlite.readNullableTokens(statement, 3, true);
    const text_id = sqlite.optionalColumnId(statement, 4);
    const bag_id = sqlite.optionalColumnId(statement, 5) orelse return error.CorruptStore;
    if (!partFits(cursor.kind, array, kind)) return error.CorruptStore;
    const text: ?HistoricalContent = switch (kind) {
        .opaque_block => if (text_length != null or text_id != null) return error.CorruptStore else null,
        .output_text, .refusal => ranged: {
            const length = text_length orelse return error.CorruptStore;
            const whole = &cursor.text.?;
            if (text_id != null or length > whole.length - whole.next) return error.CorruptStore;
            defer whole.next += length;
            break :ranged .{ .view = view, .content_id = whole.content_id, .length = length, .digest = whole.digest, .text_start = whole.next };
        },
        .summary_text, .reasoning_text => if (text_length != null) return error.CorruptStore else try historicalContentAs(self, view, text_id orelse return error.CorruptStore, true),
    };
    const bag = try historicalBag(self, view, bag_id);
    // An opaque block is all bag: at least its type.
    if (kind == .opaque_block and bag == null) return error.CorruptStore;
    // Each array's parts are contiguous, so the writer opens it once.
    if (array != cursor.array) {
        if (cursor.closed[@backingInt(array) - 1]) return error.CorruptStore;
        if (cursor.array != .none) cursor.closed[@backingInt(cursor.array) - 1] = true;
        cursor.array = array;
    }
    sqlite.resetCached(statement);
    cursor.next += 1;
    return .{ .array = array, .kind = kind, .text = text, .bag = bag };
}

/// Whether a part of this array and kind belongs in an item of `item`
/// kind, as acceptance splits them.
fn partFits(item: OutputItemKind, array: output_format.PartArray, kind: output_format.PartKind) bool {
    return switch (item) {
        .message => array == .content and (kind == .opaque_block or kind == .output_text or kind == .refusal),
        .reasoning => switch (array) {
            .summary => kind == .opaque_block or kind == .summary_text,
            .content => kind == .opaque_block or kind == .reasoning_text,
            .none => false,
        },
        .function_call, .compaction, .web_search_call => false,
    };
}

/// A saved bag, or null when it is empty: the writer adds nothing for it.
fn historicalBag(self: *Store, view: *HistoricalView, id: i64) !?HistoricalContent {
    const bag = try historicalContentAs(self, view, id, true);
    return if (bag.length == 0) null else bag;
}

fn readHistoricalToolResult(
    self: *Store,
    view: *HistoricalView,
) !?HistoricalToolResult {
    const access = try store_core.enter(self, .none);
    defer access.release();
    return access.finish(Ordinary.none, readHistoricalToolResultLocked(self, view));
}

fn readHistoricalToolResultLocked(
    self: *Store,
    view: *HistoricalView,
) !?HistoricalToolResult {
    const source_operation_id = view.active_tool_group_source_id orelse unreachable;
    const after_call_ordinal = view.active_tool_group_after_ordinal;
    const next_call = "SELECT tool_call.call_ordinal,tool_call.call_id_content_id," ++
        "coalesce(tool_call.rejection_content_id,action.resolution_content_id),current.admission_position " ++
        "FROM model_operation current " ++
        "CROSS JOIN model_operation source ON source.operation_id=?2 AND source.session_ref=current.session_ref " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=source.operation_id LEFT JOIN action_operation action " ++
        "ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE current.operation_id=?1 AND " ++ store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " " ++
        "AND coalesce(tool_call.acceptance_position,action.acceptance_position)<current.admission_position ";
    const statement = if (after_call_ordinal == null)
        try store_core.cached(self, next_call ++ "AND tool_call.call_ordinal>=0 ORDER BY tool_call.call_ordinal LIMIT 1")
    else
        try store_core.cached(self, next_call ++ "AND tool_call.call_ordinal>?3 ORDER BY tool_call.call_ordinal LIMIT 1");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, view.binding.operation_id);
    try sqlite.bindU64(statement, 2, source_operation_id);
    if (after_call_ordinal) |ordinal| try sqlite.bindU64(statement, 3, ordinal);
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) {
        if (view.active_tool_group_count != view.active_tool_group_expected) return error.CorruptStore;
        view.active_tool_group_source_id = null;
        view.active_tool_group_after_ordinal = null;
        view.active_tool_group_count = 0;
        return null;
    }
    if (result != c.SQLITE_ROW) return error.HistoricalEntryReadFailed;
    const call_ordinal = c.sqlite3_column_int64(statement, 0);
    const call_id_content_id = c.sqlite3_column_int64(statement, 1);
    const output_content_id = c.sqlite3_column_int64(statement, 2);
    const admission_position = c.sqlite3_column_int64(statement, 3);
    if (call_ordinal < 0 or call_id_content_id <= 0 or output_content_id <= 0 or admission_position <= 0)
        return error.CorruptStore;
    if (call_ordinal != view.active_tool_group_count or view.active_tool_group_count >= view.active_tool_group_expected)
        return error.CorruptStore;
    const call_id = try historicalContent(self, view, call_id_content_id);
    const output = try historicalContent(self, view, output_content_id);
    view.active_tool_group_after_ordinal = @intCast(call_ordinal);
    view.active_tool_group_count += 1;
    return .{ .call_id = call_id, .output = output };
}

/// Public content as a view handle. Like a digest lookup of public
/// content, a private row cannot stand in.
fn historicalContent(self: *Store, view: *HistoricalView, content_id: i64) !HistoricalContent {
    return historicalContentAs(self, view, content_id, false);
}

/// Content as a view handle, only when its privacy is `private`.
fn historicalContentAs(self: *Store, view: *HistoricalView, content_id: i64, private: bool) !HistoricalContent {
    const statement = try store_core.cached(self, "SELECT " ++ historical_content_columns_sql ++ " FROM content WHERE content.content_id=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindI64(statement, 1, content_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    return readHistoricalContent(view, statement, 0, content_id, private);
}

/// Decodes `historical_content_columns_sql` starting at column `first`. A
/// row whose privacy differs from `private` cannot stand in.
fn readHistoricalContent(view: *HistoricalView, statement: *c.sqlite3_stmt, first: c_int, content_id: i64, private: bool) !HistoricalContent {
    if (c.sqlite3_column_type(statement, first) == c.SQLITE_NULL) return error.CorruptStore;
    const length = c.sqlite3_column_int64(statement, first);
    if (length < 0 or (c.sqlite3_column_int(statement, first + 2) != 0) != private) return error.CorruptStore;
    return .{
        .view = view,
        .content_id = content_id,
        .length = @intCast(length),
        .digest = try sqlite.readDigest(statement, first + 1),
    };
}
