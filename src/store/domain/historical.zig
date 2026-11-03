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
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
pub const ReadAccess = reads_domain.ReadAccess;
const content_metadata = content_domain.content_metadata;
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

/// The content row columns a view handle needs, named as
/// `content_metadata.Row` names them so typed rows decode them.
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
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, settingsOf(&access, view, out));
}

/// The settings an Operation's request froze, with its Session's binding.
/// The texts decode straight into the caller's settings.
const historical_settings = rsql.Read(.{
    .sql = "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id,r.tools_mask,r.provider,o.session_ref,r.workspace,o.compaction_trigger,o.output_reservation," ++
        "o.reasoning_effort,s.codec,s.codec_options IS NULL AS plain_codec,o.purpose " ++
        "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref JOIN session_revision r ON r.session_ref=o.session_ref " ++
        "AND r.revision=o.settings_revision JOIN session_revision baseline ON baseline.session_ref=o.session_ref AND baseline.revision=1 WHERE o.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct {
        model: *protocol.Bounded(protocol.max_model_bytes),
        instructions_content_id: rsql.Positive,
        output_schema_content_id: ?rsql.Positive,
        tools_mask: u8,
        provider: protocol.Provider,
        session_ref: *protocol.Bounded(protocol.max_session_bytes),
        workspace: *protocol.Bounded(protocol.max_workspace_bytes),
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?protocol.ReasoningEffort,
        codec: protocol.Bounded(40),
        plain_codec: bool,
        purpose: u8,
    },
    .cardinality = .optional,
});

/// Round 1 reads the settings, the Operation's purpose with them; round 2
/// the instructions' and output schema's metadata. A failed step is
/// `CorruptStore`, main's answer for both.
fn settingsOf(a: *ReadAccess, view: *HistoricalView, out: *HistoricalSettings) !void {
    var row: historical_settings.Row = undefined;
    row.model = &out.model;
    row.session_ref = &out.session;
    row.workspace = &out.workspace;
    var found: store_access.Found = undefined;
    a.readInto(historical_settings, .{ .operation = view.binding.operation_id }, &row, &found);
    try store_access.runAs(a, error.CorruptStore);
    if (!found.get()) return error.CorruptStore;
    if (row.tools_mask > tool_catalog.all_tools_mask) return error.CorruptStore;
    out.tools_mask = row.tools_mask;
    var instructions: content_metadata.Row = undefined;
    var output_schema: content_metadata.Row = undefined;
    a.read(content_metadata, .{ .content_id = row.instructions_content_id.get() }, &instructions);
    if (row.output_schema_content_id) |id| a.read(content_metadata, .{ .content_id = id.get() }, &output_schema);
    try store_access.runAs(a, error.CorruptStore);
    out.baseline_instructions = try viewContent(view, row.instructions_content_id.get(), &instructions, false);
    out.output_schema = if (row.output_schema_content_id) |id| try viewContent(view, id.get(), &output_schema, false) else null;
    out.store = a.store.selector;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("rui/session-affinity/v1");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, a.store.selector.len, .big);
    hash.update(&length);
    hash.update(a.store.selector.slice());
    std.mem.writeInt(u64, &length, out.session.len, .big);
    hash.update(&length);
    hash.update(out.session.slice());
    out.operation = switch (row.purpose) {
        0 => .assistant_response,
        1 => .compaction,
        else => return error.CorruptStore,
    };
    if (row.compaction_trigger == @as(?u64, 0)) return error.CorruptStore;
    out.compaction_trigger = row.compaction_trigger;
    out.output_reservation = row.output_reservation orelse return error.CorruptStore;
    out.reasoning_effort = row.reasoning_effort;
    out.provider = row.provider;
    // Requests are built by the provider's one codec, which takes no
    // options; a Session pinned to anything else cannot be served.
    if (!row.codec.eql(@tagName(out.provider.codec())) or !row.plain_codec) return error.CorruptStore;
    out.session_affinity = hash.finalResult()[0..16].*;
}

fn readHistoricalEntry(self: *Store, view: *HistoricalView, after_position: u64) !HistoricalView.EntryProgress {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return .{ .ready = try entry.finish(Ordinary.historical_entry, entryAfter(&access, view, after_position)) };
}

fn validateHistoricalOutputsStep(self: *Store, view: *HistoricalView) !bool {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, checkOutputsStep(&access, view));
}

fn readPrefixSeal(self: *Store, binding: AttemptBinding) !?PrefixSeal {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, prefixSealOf(&access, binding));
}

/// The prefix seal of an Operation's Session.
const session_prefix_seal = rsql.Read(.{
    .sql = "SELECT s.prefix_seal FROM model_operation o JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { prefix_seal: ?[prefix_seal.encoded_bytes]u8 },
    .cardinality = .one,
});

/// The Session's recorded seal, in a round of its own. A failed step is
/// `CorruptStore`, main's answer for it.
pub fn prefixSealOf(a: *ReadAccess, binding: AttemptBinding) !?PrefixSeal {
    var row: session_prefix_seal.Row = undefined;
    a.read(session_prefix_seal, .{ .operation = binding.operation_id }, &row);
    try store_access.runAs(a, error.CorruptStore);
    const bytes = row.prefix_seal orelse return null;
    return try PrefixSeal.decode(&bytes);
}

fn recordPrefixSeal(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    return entry.finishTransaction(Ordinary.attempt_binding, .{}, recordPrefixSealLocked(self, binding, seal));
}

fn recordPrefixSealLocked(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    try store_core.begin(self);
    _ = try model_settlement_domain.validateCurrentAttempt(self, binding);
    const update = try store_core.cached(self, "UPDATE session SET prefix_seal=?2 WHERE session_ref=(SELECT session_ref FROM model_operation WHERE operation_id=?1)");
    defer sqlite.resetCached(update);
    try sqlite.bindU64(update, 1, binding.operation_id);
    const bytes = seal.encode();
    try sqlite.bindBlob(update, 2, &bytes);
    try sqlite.expectDone(update);
    if (c.sqlite3_changes(self.database) != 1) return error.CorruptStore;
    try store_core.commit(self);
}

fn readCompactionAnchor(self: *Store, base_id: u64) !u64 {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, compactionAnchorOf(&access, base_id));
}

/// A compaction base's compaction item: its provider bag is the opaque
/// continuation. A base has exactly one.
const compaction_anchor = rsql.Read(.{
    .sql = "SELECT session_position,extras_content_id FROM model_output_item @index(model_output_compaction_anchor) WHERE operation_id=?1 AND item_kind=4 ORDER BY item_ordinal",
    .Args = struct { base: u64 },
    .Row = struct { session_position: rsql.Positive, extras_content_id: rsql.Positive },
    .cardinality = .one,
});

/// The position of the base's one compaction item. Round 1 reads the
/// item, round 2 that its bag's row exists. A failed step is
/// `CorruptStore`, main's answer for both.
fn compactionAnchorOf(a: *ReadAccess, base_id: u64) !u64 {
    var anchor: compaction_anchor.Row = undefined;
    a.read(compaction_anchor, .{ .base = base_id }, &anchor);
    try store_access.runAs(a, error.CorruptStore);
    var bag: content_metadata.Row = undefined;
    a.read(content_metadata, .{ .content_id = anchor.extras_content_id.get() }, &bag);
    try store_access.runAs(a, error.CorruptStore);
    return anchor.session_position.get();
}

/// The Operation's admission position and its selected Compaction Base:
/// the latest compacted Operation admitted before it.
const output_boundary = rsql.Read(.{
    .sql = "SELECT current.admission_position,base.operation_id,coalesce(base.admission_position,0) AS frontier " ++
        "FROM model_operation current LEFT JOIN model_operation base ON base.operation_id=(SELECT selected.operation_id " ++
        "FROM model_operation selected @index(model_operation_compaction_bases) WHERE selected.session_ref=current.session_ref AND selected.purpose=1 " ++
        "AND " ++ store_schema.resolutionIs("selected.resolution_code", .compacted) ++ " AND selected.admission_position<current.admission_position ORDER BY selected.admission_position DESC LIMIT 1) " ++
        "WHERE current.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { admission_position: rsql.Positive, operation_id: ?rsql.Positive, frontier: u64 },
    .cardinality = .each,
});

// The primary key makes ordinals unique, so the count, the first and last
// ordinal and one position offset prove ordinals 0..count-1 at consecutive
// positions, all after admission and below the boundary.
/// The next accepted producing Operation after cursor (?3, ?5), from the
/// frontier ?2 to the boundary ?4, with whether its items are complete.
const output_source = rsql.Read(.{
    .sql = "SELECT source.operation_id,source.admission_position,source.output_item_count,source.purpose," ++
        "(SELECT count(*)=source.output_item_count AND coalesce(min(item.item_ordinal)=0 AND max(item.item_ordinal)=count(*)-1 " ++
        "AND min(item.session_position-item.item_ordinal)=max(item.session_position-item.item_ordinal) " ++
        "AND min(item.session_position)>source.admission_position AND max(item.session_position)<?4 " ++
        "AND min(item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal),1) " ++
        "FROM model_output_item item WHERE item.operation_id=source.operation_id) AS complete " ++
        "FROM model_operation current JOIN model_operation source @index(model_operation_context_history) ON source.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND source.admission_position>=?2 AND (source.admission_position>?3 OR (source.admission_position=?3 AND source.operation_id>?5)) " ++
        "AND source.admission_position<?4 AND " ++ store_schema.oneOf("source.resolution_code", &accepted_resolutions) ++ " " ++
        "ORDER BY source.admission_position,source.operation_id LIMIT 1",
    .Args = struct { operation: u64, from: u64, after_position: u64, boundary: u64, after_operation: u64 },
    .Row = struct { operation_id: rsql.Positive, admission_position: rsql.Positive, output_item_count: u64, purpose: u8, complete: bool },
    .cardinality = .optional,
});

// Each step checks one producing Operation and its items in one
// statement. Its own item count detects even a completely missing output.
// No statement or lock survives this one step. A failed step is
// `CorruptStore`, main's answer for it.
fn checkOutputsStep(a: *ReadAccess, view: *HistoricalView) !bool {
    if (view.outputs_validated) return true;
    if (view.output_frontier == null) {
        var first: reads_domain.First(output_boundary.Row) = .{};
        a.readEach(output_boundary, .{ .operation = view.binding.operation_id }, 1, &first);
        try store_access.runAs(a, error.CorruptStore);
        const row = first.row orelse return error.CorruptStore;
        view.output_boundary = row.admission_position.get();
        view.selected_base = if (row.operation_id) |id| id.get() else 0;
        view.output_frontier = row.frontier;
        return false;
    }
    var found: output_source.Result = undefined;
    a.read(output_source, .{
        .operation = view.binding.operation_id,
        // SQLite seeks the index only on this bound, never on the
        // cursor's OR, so it carries the cursor; each step then starts at
        // the next Operation instead of rescanning from the frontier.
        .from = @max(view.output_frontier.?, view.output_cursor),
        .after_position = view.output_cursor,
        .boundary = view.output_boundary,
        .after_operation = view.output_cursor_id,
    }, &found);
    try store_access.runAs(a, error.CorruptStore);
    const source = found orelse {
        view.outputs_validated = true;
        return true;
    };
    view.output_cursor_id = source.operation_id.get();
    view.output_cursor = source.admission_position.get();
    if (source.purpose == 1 and source.output_item_count == 0) return error.CorruptStore;
    if (!source.complete) return error.CorruptStore;
    return false;
}

/// The served entry lives in the view: in its read-ahead, its next tool
/// group or its output check.
fn entryAfter(a: *ReadAccess, view: *HistoricalView, after_position: u64) !?*const HistoricalEntry {
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
        if (try readNextHistoricalToolGroup(a, view)) |group| {
            view.tool_group_source_cursor = group.source_operation_id;
            if (group.position > after_position) {
                view.next_tool_group = .{ .position = group.position, .kind = .tool_results };
                view.next_tool_group_source_id = group.source_operation_id;
            } else return error.HistoricalPending;
        }
        view.tool_group_initialized = true;
    }
    view.tool_group_scan_after = after_position;
    const ordinary = try nextOrdinaryHistoricalEntry(a, view, after_position) orelse return activateHistoricalToolGroup(view);
    if (view.next_tool_group) |*group| {
        if (group.position < ordinary.position) return activateHistoricalToolGroup(view);
    }
    return ordinary;
}

/// The host inputs and output items after ?2 below the Operation's
/// admission, the first `HistoricalView.entry_batch` of them in position
/// order.
const historical_entries = rsql.Read(.{
    .sql = "SELECT e.session_position,e.entry_kind,e.content_id," ++ historical_content_columns_sql ++ ",NULL AS model,NULL AS provider,NULL AS item_kind,NULL AS item_id_digest,NULL AS consistent," ++
        "(SELECT m.sender_session_ref FROM message_admission m WHERE e.entry_kind=1 AND m.admission_id=e.source_admission_id) AS sender " ++
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
        "((" ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ")=EXISTS(SELECT 1 FROM model_tool_call tool_call WHERE tool_call.operation_id=owner.operation_id)),NULL " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
        "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
        "LEFT JOIN turn owner_turn ON owner_turn.turn_id=owner.turn_id " ++
        "LEFT JOIN session_revision r ON r.session_ref=owner.session_ref AND r.revision=owner.settings_revision " ++
        "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position " ++
        std.fmt.comptimePrint("ORDER BY 1 LIMIT {d}", .{HistoricalView.entry_batch}),
    .Args = struct { operation: u64, after: u64 },
    .Row = struct {
        session_position: rsql.Positive,
        entry_kind: u8,
        content_id: ?rsql.Positive,
        byte_length: ?u64,
        digest: ?[32]u8,
        private: ?bool,
        model: ?protocol.Bounded(protocol.max_model_bytes),
        provider: ?protocol.Provider,
        item_kind: ?u8,
        item_id_digest: ?[32]u8,
        consistent: ?bool,
        sender: ?protocol.Bounded(protocol.max_session_bytes),
    },
    .cardinality = .each,
    .compound = true,
});

/// Fills the view's read-ahead with each row a `historical_entries` read
/// steps, as its entry. The first row that is not one stops the read, and
/// its failure is the round's answer.
const EntryBatch = struct {
    view: *HistoricalView,
    failure: ?error{CorruptStore} = null,

    pub fn visit(batch: *EntryBatch, row: *const historical_entries.Row) bool {
        const view = batch.view;
        view.entries[view.entries_end] = historicalEntry(view, row) catch |err| {
            batch.failure = err;
            return false;
        };
        view.entries_end += 1;
        return true;
    }
};

/// The next host input or output item after `after_position`, served from
/// the view's read-ahead and refilled by one ranged read in a round of its
/// own. A failed step is `HistoricalEntryReadFailed`, main's name.
fn nextOrdinaryHistoricalEntry(a: *ReadAccess, view: *HistoricalView, after_position: u64) !?*const HistoricalEntry {
    while (view.entries_next < view.entries_end) : (view.entries_next += 1) {
        if (view.entries[view.entries_next].position > after_position) return &view.entries[view.entries_next];
    }
    view.entries_next = 0;
    view.entries_end = 0;
    errdefer view.entries_end = 0;
    var batch: EntryBatch = .{ .view = view };
    a.readEach(historical_entries, .{ .operation = view.binding.operation_id, .after = after_position }, HistoricalView.entry_batch, &batch);
    try store_access.runAs(a, error.HistoricalEntryReadFailed);
    if (batch.failure) |err| return err;
    return if (view.entries_end == 0) null else &view.entries[0];
}

fn historicalEntry(view: *HistoricalView, row: *const historical_entries.Row) error{CorruptStore}!HistoricalEntry {
    const kind: HistoricalEntryKind = switch (row.entry_kind) {
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
        if (row.consistent != true) return error.CorruptStore;
        const model = row.model orelse return error.CorruptStore;
        if (model.len == 0 or row.provider == null or row.item_id_digest == null) return error.CorruptStore;
        _ = std.enums.fromInt(OutputItemKind, row.item_kind orelse return error.CorruptStore) orelse return error.CorruptStore;
        requested_model = model;
    } else {
        const content_id = row.content_id orelse return error.CorruptStore;
        // A missing content row leaves its columns NULL.
        content = .{
            .view = view,
            .content_id = @intCast(content_id.get()),
            .length = row.byte_length orelse return error.CorruptStore,
            .digest = row.digest orelse return error.CorruptStore,
        };
        if (row.private orelse return error.CorruptStore) return error.CorruptStore;
    }
    return .{
        .position = row.session_position.get(),
        .kind = kind,
        .requested_model = requested_model,
        .sender = row.sender,
        .content = content,
    };
}

fn activateHistoricalToolGroup(view: *HistoricalView) !?*const HistoricalEntry {
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

// Walk the immutable item population, not just surviving call rows. One
// item/classification per step also detects wholly missing calls.
/// The scanned Operation's item at or after ordinal ?2.
const group_item = rsql.Read(.{
    .sql = "SELECT item.item_ordinal,item.item_kind,item.session_ref,item.session_position," ++
        "item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal AS consistent " ++
        "FROM model_output_item item JOIN model_operation source ON source.operation_id=item.operation_id " ++
        "WHERE item.operation_id=?1 AND item.item_ordinal>=?2 ORDER BY item.item_ordinal LIMIT 1",
    .Args = struct { operation: u64, ordinal: u64 },
    .Row = struct { item_ordinal: u64, item_kind: u8, session_ref: protocol.Bounded(protocol.max_session_bytes), session_position: rsql.Positive, consistent: bool },
    .cardinality = .optional,
});

/// A call past the scanned Operation's call items: there must be none.
const extra_call = rsql.Read(.{
    .sql = "SELECT call_ordinal FROM model_tool_call WHERE operation_id=?1 AND call_ordinal>=?2 ORDER BY call_ordinal LIMIT 1",
    .Args = struct { operation: u64, ordinal: u64 },
    .Row = struct { call_ordinal: u64 },
    .cardinality = .optional,
});

/// A call's accepted result, and whether its rejection or Action agrees.
/// It shares its round with the call's Proposal, which main read first,
/// so a missing row or column is checked after the Proposal is.
pub const call_outcome = rsql.Read(.{
    .sql = "SELECT coalesce(tool_call.acceptance_position,action.acceptance_position) AS accepted_position," ++
        "coalesce(tool_call.rejection_content_id,action.resolution_content_id) AS content_id," ++
        "CASE WHEN tool_call.rejection_code IS NOT NULL OR (action.resolution_code IS NOT NULL AND " ++
        "action.session_ref=source.session_ref AND action.tool_kind=tool_call.action_kind) THEN 1 ELSE 0 END AS consistent " ++
        "FROM model_tool_call tool_call JOIN model_operation source ON source.operation_id=tool_call.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "WHERE tool_call.operation_id=?1 AND tool_call.call_ordinal=?2",
    .Args = struct { operation: u64, ordinal: u64 },
    .Row = struct { accepted_position: ?rsql.Positive, content_id: ?rsql.Positive, consistent: bool },
    .cardinality = .optional,
});

/// The scanned call `call` of Operation `source`, from the Proposal and
/// outcome its round read together, decided in main's order: the
/// Proposal first, so a missing one is `ContentNotFound` whatever the
/// outcome holds. Returns where the call was accepted and its result.
pub fn scannedCall(proposal: reads_domain.proposal_row.Result, found_outcome: call_outcome.Result, position: u64, source: u64, call: u64) error{ ContentNotFound, CorruptStore }!struct { accepted_position: u64, content_id: u64 } {
    const identity = try reads_domain.proposalIdentity(proposal, position);
    if (identity.metadata.operation != source or identity.metadata.call_ordinal != call) return error.CorruptStore;
    const outcome = found_outcome orelse return error.CorruptStore;
    if (!outcome.consistent) return error.CorruptStore;
    return .{
        .accepted_position = (outcome.accepted_position orelse return error.CorruptStore).get(),
        .content_id = (outcome.content_id orelse return error.CorruptStore).get(),
    };
}

/// The Session's next Operation after the scan cursor ?2 and before the
/// view's own, and whether it proposed tools.
const next_group_source = rsql.Read(.{
    .sql = "SELECT source.operation_id,current.admission_position AS boundary," ++ store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " AS proposes," ++
        "source.admission_position,source.output_item_count FROM model_operation current " ++
        "JOIN model_operation source @index(model_operation_session_history) " ++
        "ON source.session_ref=current.session_ref WHERE current.operation_id=?1 " ++
        "AND source.operation_id>?2 AND source.operation_id<current.operation_id " ++
        "ORDER BY source.operation_id LIMIT 1",
    .Args = struct { operation: u64, after: u64 },
    .Row = struct { operation_id: rsql.Positive, boundary: rsql.Positive, proposes: ?bool, admission_position: ?u64, output_item_count: ?u64 },
    .cardinality = .optional,
});

/// One step of the tool-group scan, each read in rounds that depend on
/// the one before: an item, then its Proposal and call outcome together,
/// then the result's metadata; or, past the last item, the extra call
/// check; or the next source Operation. A failed step is main's name:
/// `CorruptStore` for the item, call and metadata reads, the Proposal
/// read's own, and `HistoricalEntryReadFailed` for the source.
fn readNextHistoricalToolGroup(a: *ReadAccess, view: *HistoricalView) !?HistoricalToolGroup {
    const scan = &view.group_scan;
    if (scan.source != 0) {
        var found: group_item.Result = undefined;
        a.read(group_item, .{ .operation = scan.source, .ordinal = scan.item }, &found);
        try store_access.runAs(a, error.CorruptStore);
        const item = found orelse {
            var extra: extra_call.Result = undefined;
            a.read(extra_call, .{ .operation = scan.source, .ordinal = scan.calls }, &extra);
            try store_access.runAs(a, error.CorruptStore);
            if (scan.item != scan.expected_items or scan.calls == 0 or scan.position == 0 or scan.position >= scan.boundary or extra != null)
                return error.CorruptStore;
            const group = HistoricalToolGroup{ .position = scan.position, .source_operation_id = scan.source };
            view.next_tool_group_count = scan.calls;
            scan.source = 0;
            return group;
        };
        if (item.item_ordinal != scan.item) return error.CorruptStore;
        const position = item.session_position.get();
        if (scan.item >= scan.expected_items or !item.consistent or
            position <= scan.admission or position >= scan.boundary or
            (scan.item != 0 and position != scan.previous_position + 1)) return error.CorruptStore;
        scan.previous_position = position;
        scan.item += 1;
        if (item.item_kind != 3) return error.HistoricalPending;
        var proposal: reads_domain.proposal_row.Result = undefined;
        var found_outcome: call_outcome.Result = undefined;
        reads_domain.readProposal(a, item.session_ref.slice(), position, &proposal);
        a.read(call_outcome, .{ .operation = scan.source, .ordinal = scan.calls }, &found_outcome);
        a.run() catch |err| return if (err == error.StatementFailed and a.failedOn(call_outcome)) error.CorruptStore else err;
        const call = try scannedCall(proposal, found_outcome, position, scan.source, scan.calls);
        var result: content_metadata.Row = undefined;
        a.read(content_metadata, .{ .content_id = call.content_id }, &result);
        try store_access.runAs(a, error.CorruptStore);
        _ = try content_domain.publicMetadata(&result);
        scan.position = @max(scan.position, call.accepted_position);
        // The call's bytes are authenticated when its entry is served.
        scan.calls += 1;
        return error.HistoricalPending;
    }
    var found: next_group_source.Result = undefined;
    a.read(next_group_source, .{ .operation = view.binding.operation_id, .after = view.tool_group_source_cursor }, &found);
    try store_access.runAs(a, error.HistoricalEntryReadFailed);
    const source = found orelse return null;
    if (source.proposes != true) {
        view.tool_group_source_cursor = source.operation_id.get();
        return error.HistoricalPending;
    }
    scan.source = source.operation_id.get();
    scan.boundary = source.boundary.get();
    scan.admission = source.admission_position orelse return error.CorruptStore;
    scan.expected_items = source.output_item_count orelse return error.CorruptStore;
    if (scan.admission == 0 or scan.expected_items == 0) return error.CorruptStore;
    scan.previous_position = 0;
    scan.item = 0;
    scan.calls = 0;
    scan.position = 0;
    return error.HistoricalPending;
}

fn readHistoricalOutput(self: *Store, view: *HistoricalView, position: u64) !HistoricalOutput {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, outputAt(&access, view, position));
}

/// The output item at ?2 in the Operation's Session, with its call's
/// fields.
const historical_output = rsql.Read(.{
    .sql = "SELECT item.operation_id,item.item_ordinal,item.item_kind,item.phase,item.replay_omits_reasoning_text,item.extras_content_id," ++
        "tool_call.name_content_id,tool_call.call_id_content_id,tool_call.arguments_content_id,item.part_count,item.message_content_id " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref AND item.session_position=?2 " ++
        "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
        "WHERE current.operation_id=?1",
    .Args = struct { operation: u64, position: u64 },
    .Row = struct {
        operation_id: rsql.Positive,
        item_ordinal: u64,
        item_kind: u8,
        phase: u8,
        replay_omits_reasoning_text: bool,
        extras_content_id: rsql.Positive,
        name_content_id: ?rsql.Positive,
        call_id_content_id: ?rsql.Positive,
        arguments_content_id: ?rsql.Positive,
        part_count: u64,
        message_content_id: ?rsql.Positive,
    },
    .cardinality = .one,
});

/// Round 1 reads the item; round 2 the metadata of its message text, its
/// call's three fields and its bag together. A failed step is
/// `CorruptStore`, main's answer for both.
fn outputAt(a: *ReadAccess, view: *HistoricalView, position: u64) !HistoricalOutput {
    var row: historical_output.Row = undefined;
    a.read(historical_output, .{ .operation = view.binding.operation_id, .position = position }, &row);
    try store_access.runAs(a, error.CorruptStore);
    const kind = std.enums.fromInt(OutputItemKind, row.item_kind) orelse return error.CorruptStore;
    const phase = std.enums.fromInt(output_format.NeutralPhase, row.phase) orelse return error.CorruptStore;
    if (row.part_count != 0 and kind != .reasoning and kind != .message) return error.CorruptStore;
    const has_call = row.name_content_id != null;
    if (has_call != (kind == .function_call)) return error.CorruptStore;
    var call_ids: [3]u64 = undefined;
    for (&call_ids, [3]?rsql.Positive{ row.name_content_id, row.call_id_content_id, row.arguments_content_id }) |*id, column| id.* = if (column) |value| value.get() else if (has_call) return error.CorruptStore else 0;
    if ((row.message_content_id != null) != (kind == .message)) return error.CorruptStore;
    var text_row: content_metadata.Row = undefined;
    var call_rows: [3]content_metadata.Row = undefined;
    var bag_row: content_metadata.Row = undefined;
    if (row.message_content_id) |id| a.read(content_metadata, .{ .content_id = id.get() }, &text_row);
    if (has_call) for (&call_rows, call_ids) |*call_row, id| a.read(content_metadata, .{ .content_id = id }, call_row);
    a.read(content_metadata, .{ .content_id = row.extras_content_id.get() }, &bag_row);
    try store_access.runAs(a, error.CorruptStore);
    var text: ?HistoricalView.MessageText = null;
    if (row.message_content_id) |id| {
        const content = try viewContent(view, id.get(), &text_row, false);
        // Its parts' reads check a nonempty text; an empty one is
        // checked here.
        if (content.length == 0 and !std.mem.eql(u8, &content.digest, &protocol.contentDigest(""))) return error.CorruptStore;
        text = .{ .content_id = content.content_id, .length = content.length, .digest = content.digest };
    }
    var call: ?[3]HistoricalContent = null;
    if (has_call) {
        var fields: [3]HistoricalContent = undefined;
        for (&fields, call_ids, &call_rows) |*content, id, *call_row| content.* = try viewContent(view, id, call_row, false);
        call = fields;
    }
    view.output_parts = .{ .operation_id = row.operation_id.get(), .item_ordinal = row.item_ordinal, .kind = kind, .count = row.part_count, .text = text };
    return .{
        .kind = kind,
        .phase = phase,
        .omit_reasoning_text = row.replay_omits_reasoning_text,
        .bag = try viewBag(view, row.extras_content_id.get(), &bag_row),
        .call = call,
    };
}

fn readHistoricalPart(self: *Store, view: *HistoricalView) !?HistoricalPart {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, nextPart(&access, view));
}

/// The open item's part at or after ordinal ?3.
const historical_part = rsql.Read(.{
    .sql = "SELECT part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id FROM model_output_part " ++
        "WHERE operation_id=?1 AND item_ordinal=?2 AND part_ordinal>=?3 ORDER BY part_ordinal LIMIT 1",
    .Args = struct { operation: u64, item: u64, part: u64 },
    .Row = struct { part_ordinal: u64, part_array: u8, part_kind: u8, text_length: ?u64, text_content_id: ?rsql.Positive, extras_content_id: rsql.Positive },
    .cardinality = .optional,
});

/// Round 1 reads the part; round 2 the metadata of its own text and its
/// bag together. A failed step is main's name: `HistoricalEntryReadFailed`
/// for the part, `CorruptStore` for the metadata.
fn nextPart(a: *ReadAccess, view: *HistoricalView) !?HistoricalPart {
    const cursor = &view.output_parts.?;
    var found: historical_part.Result = undefined;
    a.read(historical_part, .{ .operation = cursor.operation_id, .item = cursor.item_ordinal, .part = cursor.next }, &found);
    try store_access.runAs(a, error.HistoricalEntryReadFailed);
    const row = found orelse {
        // A part missing from the end changes what the model saw,
        // and the text parts cover the whole message text.
        if (cursor.next != cursor.count) return error.CorruptStore;
        if (cursor.text) |text| if (text.next != text.length) return error.CorruptStore;
        view.output_parts = null;
        return null;
    };
    if (cursor.next == cursor.count or row.part_ordinal != cursor.next) return error.CorruptStore;
    const array = std.enums.fromInt(output_format.PartArray, row.part_array) orelse return error.CorruptStore;
    const kind = std.enums.fromInt(output_format.PartKind, row.part_kind) orelse return error.CorruptStore;
    if (!partFits(cursor.kind, array, kind)) return error.CorruptStore;
    // Only a summary or reasoning text has a row of its own.
    const own_text = kind == .summary_text or kind == .reasoning_text;
    var text_row: content_metadata.Row = undefined;
    var bag_row: content_metadata.Row = undefined;
    if (own_text and row.text_length == null) if (row.text_content_id) |id| a.read(content_metadata, .{ .content_id = id.get() }, &text_row);
    a.read(content_metadata, .{ .content_id = row.extras_content_id.get() }, &bag_row);
    try store_access.runAs(a, error.CorruptStore);
    const text: ?HistoricalContent = switch (kind) {
        .opaque_block => if (row.text_length != null or row.text_content_id != null) return error.CorruptStore else null,
        .output_text, .refusal => ranged: {
            const length = row.text_length orelse return error.CorruptStore;
            const whole = &cursor.text.?;
            if (row.text_content_id != null or length > whole.length - whole.next) return error.CorruptStore;
            defer whole.next += length;
            break :ranged .{ .view = view, .content_id = whole.content_id, .length = length, .digest = whole.digest, .text_start = whole.next };
        },
        .summary_text, .reasoning_text => if (row.text_length != null) return error.CorruptStore else try viewContent(view, (row.text_content_id orelse return error.CorruptStore).get(), &text_row, true),
    };
    const bag = try viewBag(view, row.extras_content_id.get(), &bag_row);
    // An opaque block is all bag: at least its type.
    if (kind == .opaque_block and bag == null) return error.CorruptStore;
    // Each array's parts are contiguous, so the writer opens it once.
    if (array != cursor.array) {
        if (cursor.closed[@backingInt(array) - 1]) return error.CorruptStore;
        if (cursor.array != .none) cursor.closed[@backingInt(cursor.array) - 1] = true;
        cursor.array = array;
    }
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
fn viewBag(view: *HistoricalView, content_id: u64, row: *const content_metadata.Row) !?HistoricalContent {
    const bag = try viewContent(view, content_id, row, true);
    return if (bag.length == 0) null else bag;
}

fn readHistoricalToolResult(
    self: *Store,
    view: *HistoricalView,
) !?HistoricalToolResult {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, nextGroupResult(&access, view));
}

/// The active group's next call accepted before the Operation's admission:
/// its first, or the one after ordinal ?3 when `after`.
fn NextCall(comptime after: bool) type {
    return rsql.Read(.{
        .sql = "SELECT tool_call.call_ordinal,tool_call.call_id_content_id," ++
            "coalesce(tool_call.rejection_content_id,action.resolution_content_id) AS output_content_id,current.admission_position " ++
            "FROM model_operation current " ++
            "CROSS JOIN model_operation source ON source.operation_id=?2 AND source.session_ref=current.session_ref " ++
            "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=source.operation_id LEFT JOIN action_operation action " ++
            "ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
            "WHERE current.operation_id=?1 AND " ++ store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " " ++
            "AND coalesce(tool_call.acceptance_position,action.acceptance_position)<current.admission_position " ++
            (if (after) "AND tool_call.call_ordinal>?3 " else "AND tool_call.call_ordinal>=0 ") ++ "ORDER BY tool_call.call_ordinal LIMIT 1",
        .Args = if (after) struct { operation: u64, source: u64, after: u64 } else struct { operation: u64, source: u64 },
        .Row = NextCallRow,
        .cardinality = .optional,
    });
}
const NextCallRow = struct { call_ordinal: u64, call_id_content_id: rsql.Positive, output_content_id: rsql.Positive, admission_position: rsql.Positive };
const first_call = NextCall(false);
const later_call = NextCall(true);

/// Round 1 reads the next call; round 2 its call id's and output's
/// metadata together. A failed step is main's name:
/// `HistoricalEntryReadFailed` for the call, `CorruptStore` for the
/// metadata.
fn nextGroupResult(a: *ReadAccess, view: *HistoricalView) !?HistoricalToolResult {
    const source_operation_id = view.active_tool_group_source_id orelse unreachable;
    var found: ?NextCallRow = undefined;
    if (view.active_tool_group_after_ordinal) |ordinal|
        a.read(later_call, .{ .operation = view.binding.operation_id, .source = source_operation_id, .after = ordinal }, &found)
    else
        a.read(first_call, .{ .operation = view.binding.operation_id, .source = source_operation_id }, &found);
    try store_access.runAs(a, error.HistoricalEntryReadFailed);
    const row = found orelse {
        if (view.active_tool_group_count != view.active_tool_group_expected) return error.CorruptStore;
        view.active_tool_group_source_id = null;
        view.active_tool_group_after_ordinal = null;
        view.active_tool_group_count = 0;
        return null;
    };
    if (row.call_ordinal != view.active_tool_group_count or view.active_tool_group_count >= view.active_tool_group_expected)
        return error.CorruptStore;
    var call_id_row: content_metadata.Row = undefined;
    var output_row: content_metadata.Row = undefined;
    a.read(content_metadata, .{ .content_id = row.call_id_content_id.get() }, &call_id_row);
    a.read(content_metadata, .{ .content_id = row.output_content_id.get() }, &output_row);
    try store_access.runAs(a, error.CorruptStore);
    const call_id = try viewContent(view, row.call_id_content_id.get(), &call_id_row, false);
    const output = try viewContent(view, row.output_content_id.get(), &output_row, false);
    view.active_tool_group_after_ordinal = row.call_ordinal;
    view.active_tool_group_count += 1;
    return .{ .call_id = call_id, .output = output };
}

/// Content as a view handle, only when its privacy is `private`: like a
/// digest lookup of public content, a private row cannot stand in.
fn viewContent(view: *HistoricalView, content_id: u64, row: *const content_metadata.Row, private: bool) error{CorruptStore}!HistoricalContent {
    if (row.private != private) return error.CorruptStore;
    return .{ .view = view, .content_id = @intCast(content_id), .length = row.byte_length, .digest = row.digest };
}
