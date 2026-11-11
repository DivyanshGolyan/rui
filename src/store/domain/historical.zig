//! The historical view a model request reads: settings, conversation entries,
//! outputs, parts, tool results and prefix seals.

const replay_recipe = @import("../../replay_recipe.zig");
const std = @import("std");
const activity_read = @import("../../activity_read.zig");
const workspace_path = @import("../../workspace_path.zig");
const store_path = @import("../../store_path.zig");
const content_string = @import("../../content_string.zig");
const session_id = @import("../../session_id.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const model_capability = @import("../../model_capability.zig");
const provider_name = @import("../../provider_name.zig");
const tool_catalog = @import("../../tool_record.zig");
const output_format = @import("../../output_format.zig");
const prefix_seal = @import("../../prefix_seal.zig");
const tool_proposal = @import("../../tool_proposal.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @This();
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const skills_domain = @import("skills.zig");
const history_floor_domain = @import("history_floor.zig");
const reads_domain = @import("reads.zig");
const rsql = @import("../rsql.zig");
const tool_set = @import("tool_set.zig");
const store_access = @import("../access.zig");
pub const ReadAccess = reads_domain.ReadAccess;
const content_metadata = content_domain.content_metadata;
const store_schema = @import("../schema.zig");
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
    /// inferred default and no override.
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    /// The effort the Session's first Operation for this model froze.
    starting_effort: ?model_capability.ReasoningEffort = null,
    /// The codec the Session pinned at creation.
    codec: provider_name.Codec,
    provider: provider_name.Provider,
    model: Bounded(model_capability.max_model_bytes),
    workspace: Bounded(workspace_path.max_bytes),
    /// The originating Operation's own address: canonical Store selector and
    /// exact Session reference, for the Rui-owned request context.
    store: Bounded(store_path.max_bytes),
    session: Bounded(session_id.max_reference_bytes),
    session_affinity: [16]u8,
    baseline_instructions: HistoricalContent,
    output_schema: ?HistoricalContent,
    /// How many tools the frozen settings offer; `nextTool` reads them.
    tool_count: u64,
};

/// One tool record the frozen settings offer, as saved: its texts are
/// rendered from the Store, never from the Host's built-ins.
pub const HistoricalTool = struct {
    name: Bounded(tool_catalog.max_name_bytes) = .{},
    owner: tool_catalog.Owner = undefined,
    description: HistoricalContent = undefined,
    input_schema: HistoricalContent = undefined,
};

/// `operation` is an earlier Operation's admission, with the effort it froze.
/// `skill` is a skill a Message's `/name` word bound, right after it.
pub const HistoricalEntryKind = enum { user, instruction, provider_output, tool_results, operation, skill };

pub const HistoricalEntry = struct {
    position: u64,
    kind: HistoricalEntryKind,
    content: ?HistoricalContent = null,
    requested_model: ?Bounded(model_capability.max_model_bytes) = null,
    // A User entry's peer sender, in this view's Store.
    sender: ?Bounded(session_id.max_reference_bytes) = null,
    /// An Operation entry's frozen effort.
    effort: ?model_capability.ReasoningEffort = null,
    /// An Operation entry's frozen tool set, and whether its boundary
    /// declares any function tool (`HistoricalView.nextDeclaredTool`).
    tool_set_id: u64 = 0,
    declares: bool = false,
};

/// An Operation boundary's declaration being read: the set it declares
/// from, its boundary's position, and the member ordinal to read from.
pub const Declaration = struct {
    tool_set_id: u64,
    position: u64,
    next_ordinal: u64 = 0,
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
    active_tool_group_count: u64 = 0,
    outputs_validated: bool = false,
    output_frontier: ?u64 = null,
    // The selected base's Operation, found with the frontier; zero for none.
    selected_base: u64 = 0,
    /// The floor the view omits history at or below (D217), zero for none,
    /// read with the base; and the Session's first user Message, which
    /// no floor drops.
    floor: Floor = .{},
    /// The selected base's one compaction item's position, read with the
    /// base; null when there is no base, or when the base lacks exactly
    /// one such item with its bag, which `coverage` refuses.
    anchor: ?u64 = null,
    output_boundary: u64 = 0,
    output_cursor: u64 = 0,
    output_cursor_id: u64 = 0,
    group_scan: GroupScan = .{},
    next_tool_group_count: u64 = 0,
    active_tool_group_expected: u64 = 0,
    /// The frozen tool set, which `settings` reads, and the ordinal of the
    /// member `nextTool` reads next.
    tool_set_id: u64 = 0,
    tool_count: u64 = 0,
    next_tool: u64 = 0,
    /// The set's provider-run members, which `nextProviderTool` reads, and
    /// how many it has read, past the ordinal `next_tool`.
    provider_tool_count: u64 = 0,
    provider_tools_read: u64 = 0,
    // Ordinary entries copied from one ranged read. Plain values, never a
    // statement: history below the admission boundary is immutable.
    entries: [entry_batch]HistoricalEntry = undefined,
    entries_next: usize = 0,
    entries_end: usize = 0,
    /// After this position the Session has no further ordinary entry
    /// below the admission: a ranged read came back short. History there
    /// never changes, so the walk's end costs no round.
    entries_done_after: ?u64 = null,
    /// What the entry batch holds beyond its entries, on the heap for the
    /// view's life; its first read allocates it.
    page: ?*Page = null,
    /// Open readers that borrow the page's bytes, which are then only
    /// added to.
    inline_readers: usize = 0,
    /// The tool walk the request ends with, whose first page rides the
    /// first history round.
    ahead: ToolsAhead = .none,
    /// The output item whose parts `nextOutputPart` serves.
    output_parts: ?OutputPartCursor = null,

    const entry_batch = 16;

    /// The tools a request carries after its history: the function tools
    /// its own boundary declares, or its frozen set's every member.
    pub const ToolsAhead = enum { none, declared, all };

    const OutputPartCursor = struct {
        position: u64,
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
        hash: @TypeOf(content_string.hasher()) = content_string.hasher(),
    };

    /// The view's selected Compaction Base: its admission position, from
    /// which accepted output is validated, and the position of its
    /// compaction item. Interpretation belongs to the caller.
    pub const Coverage = struct {
        frontier: u64,
        anchor: ?u64,
        floor: Floor,
    };

    /// The drop floor a view applies (D217): every host Message after the
    /// Session's first and every model Operation, with its tool results,
    /// that begins at or below `position` is left out; instruction entries
    /// and the selected base are kept. A Message begins at its position and
    /// an Operation at its admission position.
    pub const Floor = struct {
        /// Zero for none.
        position: u64 = 0,
        first_message: u64 = 0,
        /// The floor is the view's own Operation's, deeper than its base's.
        /// No memo or seal built on the base describes such a span.
        own: bool = false,
    };

    // One population cursor, independent of group/call counts. No
    // statement, blob handle or transaction survives a step.
    /// The tool-group scan between its rounds: the source Operation whose
    /// calls a full page cut short, with what the page saw of it; and
    /// whether the scan has passed the last source.
    const GroupScan = struct {
        source: u64 = 0,
        calls: u64 = 0,
        position: u64 = 0,
        last_item: ?u64 = null,
        done: bool = false,
        /// Once done, the last Operation before the view's own.
        passed: u64 = 0,
    };

    /// A ready entry lives in the view until its next step.
    pub const EntryProgress = union(enum) { pending, ready: ?*const HistoricalEntry };

    /// Charge discovery/classification items and private authentication bytes
    /// to the same caller allowance. Pending exposes no storage-level state.
    pub fn nextEntryStep(self: *HistoricalView, after_position: u64, bytes_left: *usize, items_left: *usize) !EntryProgress {
        std.debug.assert(self.active and self.outputs_validated and self.active_tool_group_source_id == null);
        if (bytes_left.* == 0 or items_left.* == 0) return .pending;
        items_left.* -= 1;
        try self.allocatePage();
        // An Operation entry's declaration depends on the selected base.
        _ = try self.coverage();
        return readHistoricalEntry(self.store, self, after_position) catch |err| switch (err) {
            error.HistoricalPending => .pending,
            else => return err,
        };
    }

    /// Fills `out` with the next function tool `declaration` declares, in
    /// set order, and says whether there was one. `coverage` must have run.
    pub fn nextDeclaredTool(self: *HistoricalView, declaration: *Declaration, out: *HistoricalTool) !bool {
        std.debug.assert(self.active and self.output_frontier != null);
        const walk: Page.ToolWalk = .{ .set = declaration.tool_set_id, .position = declaration.position };
        const row = try self.toolFrom(walk, declaration.next_ordinal) orelse return false;
        if (row.owner == .provider) return store_core.fence(self.store, error.CorruptStore);
        declaration.next_ordinal = row.ordinal + 1;
        return self.serveTool(row, out);
    }

    /// Says which tools the request ends with, so their first page rides
    /// the first history round. `settings` must have run.
    pub fn expectTools(self: *HistoricalView, ahead: ToolsAhead) void {
        std.debug.assert(self.active and self.tool_set_id != 0);
        self.ahead = ahead;
    }

    /// The walk `ahead` names, once its arguments are known.
    fn aheadWalk(self: *const HistoricalView) ?Page.ToolWalk {
        return switch (self.ahead) {
            .none => null,
            .declared => if (self.output_frontier == null) null else .{ .set = self.tool_set_id, .position = self.output_boundary },
            .all => if (self.tool_count == 0) null else .{ .set = self.tool_set_id, .position = 0 },
        };
    }

    /// The walk's member at or after `ordinal`, from the page; a page
    /// that does not reach it is read in a round of its own.
    fn toolFrom(self: *HistoricalView, walk: Page.ToolWalk, ordinal: u64) !?*const Page.Tool {
        try self.allocatePage();
        const page = self.page.?;
        if (!page.toolsReach(walk, ordinal)) try readTools(self.store, self, walk, ordinal);
        return page.toolAt(ordinal);
    }

    /// Fills `out` from a page row; private text is `CorruptStore`.
    fn serveTool(self: *HistoricalView, row: *const Page.Tool, out: *HistoricalTool) !bool {
        if (row.description_private or row.schema_private) return store_core.fence(self.store, error.CorruptStore);
        out.name = row.name;
        out.owner = row.owner;
        out.description = .{ .view = self, .content_id = @intCast(row.description_content_id.get()), .length = row.description_length, .digest = row.description_digest };
        out.input_schema = .{ .view = self, .content_id = @intCast(row.schema_content_id.get()), .length = row.schema_length, .digest = row.schema_digest };
        return true;
    }

    /// The current Operation's declaration: its frozen set at its
    /// admission. `settings` and `coverage` must have run.
    pub fn currentDeclaration(self: *const HistoricalView) Declaration {
        std.debug.assert(self.tool_set_id != 0 and self.output_boundary != 0);
        return .{ .tool_set_id = self.tool_set_id, .position = self.output_boundary };
    }

    /// Fills `out` with the frozen settings' next provider-run tool, in set
    /// order, and says whether there was one: the tools stage of a codec
    /// that declares function tools in the history. `settings` must have
    /// run, and `nextTool` not.
    pub fn nextProviderTool(self: *HistoricalView, out: *HistoricalTool) !bool {
        std.debug.assert(self.active and self.tool_set_id != 0);
        if (self.provider_tools_read == self.provider_tool_count) return false;
        try readProviderTool(self.store, self, out);
        self.provider_tools_read += 1;
        return true;
    }

    /// Fills `out` with the frozen settings' next tool, in set order, and
    /// says whether there was one. `settings` must have run.
    pub fn nextTool(self: *HistoricalView, out: *HistoricalTool) !bool {
        std.debug.assert(self.active and self.tool_set_id != 0);
        if (self.next_tool == self.tool_count) return false;
        // The settings counted this member: a missing one is `CorruptStore`.
        const row = try self.toolFrom(.{ .set = self.tool_set_id, .position = 0 }, self.next_tool) orelse
            return store_core.fence(self.store, error.CorruptStore);
        if (row.ordinal != self.next_tool) return store_core.fence(self.store, error.CorruptStore);
        self.next_tool += 1;
        return self.serveTool(row, out);
    }

    /// Fills `out`; on error its bytes mean nothing.
    /// The round also checks that the binding is current, as opening the
    /// view once did, and reads the first page of the output check.
    pub fn settings(self: *HistoricalView, out: *HistoricalSettings) !void {
        std.debug.assert(self.active);
        try self.allocatePage();
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

    /// The validated selected base, which the first validation step
    /// found with its anchor. A base has exactly one compaction item, with
    /// its bag: any other is `CorruptStore`.
    pub fn coverage(self: *HistoricalView) !Coverage {
        std.debug.assert(self.active);
        while (!try self.validateOutputsStep()) {}
        if (self.selected_base != 0 and self.anchor == null) return store_core.fence(self.store, error.CorruptStore);
        return .{ .frontier = self.output_frontier.?, .anchor = self.anchor, .floor = self.floor };
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
        return outputAt(self, position) catch |err| store_core.fence(self.store, err);
    }

    /// Open only the items replayable to this request's model. A skipped
    /// opaque item owns no content reader or message digest to finish.
    pub fn replayOutput(self: *HistoricalView, entry: *const HistoricalEntry, model: []const u8) !?HistoricalOutput {
        const output = try self.openOutput(entry.position);
        if (output.kind.replayableTo(entry.requested_model.?.slice(), model, if (self.anchor == entry.position) .selected_base else .history)) return output;
        self.output_parts = null;
        return null;
    }

    pub fn nextOutputPart(self: *HistoricalView) !?HistoricalPart {
        std.debug.assert(self.active and self.output_parts != null);
        if (partsExhausted(self)) try readHistoricalParts(self.store, self);
        return nextPart(self) catch |err| store_core.fence(self.store, err);
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
        out.reader.check.verified = reference.verified or reference.text_start != null;
        if (self.pageBytes(reference)) |bytes| {
            out.reader.inline_bytes = bytes;
            self.inline_readers += 1;
        }
        self.readers += 1;
    }

    /// Once, outside Store access. Raw: a read fills what it serves
    /// before any of it is used; create would first write 0xAA over all
    /// of it in ReleaseSafe.
    fn allocatePage(self: *HistoricalView) error{OutOfMemory}!void {
        if (self.page != null) return;
        const bytes = std.heap.c_allocator.rawAlloc(@sizeOf(Page), .of(Page), @returnAddress()) orelse return error.OutOfMemory;
        const page: *Page = @ptrCast(@alignCast(bytes));
        page.items_end = 0;
        page.parts_next = 0;
        page.parts_end = 0;
        page.parts_complete = true;
        page.tools_end = 0;
        page.tools_walk = .{};
        page.tools_from = 0;
        page.tools_complete = false;
        page.groups_end = 0;
        page.groups_next = 0;
        page.results_end = 0;
        page.results_next = 0;
        page.results_complete = true;
        page.batch.count = 0;
        page.held.count = 0;
        self.page = page;
    }

    /// The whole bytes of `reference`'s content when the page holds them.
    fn pageBytes(self: *HistoricalView, reference: HistoricalContent) ?[]const u8 {
        const page = self.page orelse return null;
        const whole = if (reference.text_start != null) self.output_parts.?.text.?.length else reference.length;
        return page.find(@intCast(reference.content_id), whole);
    }

    pub fn close(self: *HistoricalView) void {
        std.debug.assert(self.active and self.readers == 0);
        if (self.page) |page| std.heap.c_allocator.rawFree(std.mem.asBytes(page), .of(Page), @returnAddress());
        self.page = null;
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
        std.debug.assert(self.usable() and (self.reader.check.verified or start == self.reader.check.position));
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
        if (self.reader.inline_bytes != null) self.view.inline_readers -= 1;
        self.reader.close();
        self.view.readers -= 1;
        self.active = false;
    }
};

pub const OutputItemKind = output_format.OutputItemKind;

/// The columns of a tool page's row: a set's member, its record and
/// both texts' metadata, each with the bytes of a small text.
const tool_columns = "member.ordinal,tool.name,tool.owner,tool.description_content_id,description.byte_length AS description_length," ++
    "description.digest AS description_digest,description.private AS description_private," ++ pageBytesSql("description", "description_bytes") ++ "," ++
    "tool.input_schema_content_id AS schema_content_id,input_schema.byte_length AS schema_length,input_schema.digest AS schema_digest," ++
    "input_schema.private AS schema_private," ++ pageBytesSql("input_schema", "schema_bytes") ++ " ";

const tool_texts = "JOIN content description ON description.content_id=tool.description_content_id " ++
    "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id ";

const ToolRow = struct {
    ordinal: u64,
    name: Bounded(tool_catalog.max_name_bytes),
    owner: tool_catalog.Owner,
    description_content_id: rsql.Positive,
    description_length: u64,
    description_digest: [32]u8,
    description_private: bool,
    description_bytes: ?Page.Bytes,
    schema_content_id: rsql.Positive,
    schema_length: u64,
    schema_digest: [32]u8,
    schema_private: bool,
    schema_bytes: ?Page.Bytes,
};

/// A tool set's members from ordinal ?2 on, a page of them in order.
const set_tools = rsql.Read(.{
    .sql = "SELECT " ++ tool_columns ++ "FROM " ++ declared_members_from ++ " " ++ tool_texts ++
        "WHERE member.tool_set_id=?1 AND member.ordinal>=?2 ORDER BY member.ordinal " ++ std.fmt.comptimePrint("LIMIT {d}", .{Page.tool_batch}),
    .Args = struct { set: u64, ordinal: u64 },
    .Row = ToolRow,
    .cardinality = .each,
});

/// The function tools a boundary declares from ordinal ?3 on, a page of
/// them in order.
const declared_tools = rsql.Read(.{
    .sql = "SELECT " ++ tool_columns ++ "FROM model_operation current JOIN " ++ declared_members_from ++ " " ++ tool_texts ++
        "WHERE current.operation_id=?1 AND member.ordinal>=?3 AND " ++ declared_members_where("?2", "?4", "?5") ++ " ORDER BY member.ordinal " ++
        std.fmt.comptimePrint("LIMIT {d}", .{Page.tool_batch}),
    .Args = struct { operation: u64, set: u64, ordinal: u64, position: u64, anchor: u64 },
    .Row = ToolRow,
    .cardinality = .each,
});

fn readTools(self: *Store, view: *HistoricalView, walk: Page.ToolWalk, ordinal: u64) !void {
    return self.queue().run(readToolsHeld, .{ self, view, walk, ordinal });
}

fn readToolsHeld(self: *Store, view: *HistoricalView, walk: Page.ToolWalk, ordinal: u64) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, toolsFrom(&access, view, walk, ordinal));
}

/// One round reads a page of the walk's members from `ordinal`. A failed
/// step is `CorruptStore`, main's answer for a tool's read.
fn toolsFrom(a: *ReadAccess, view: *HistoricalView, walk: Page.ToolWalk, ordinal: u64) !void {
    const page = view.page.?;
    var tools: Page.Tools = undefined;
    page.queueTools(a, view, &tools, walk, ordinal);
    store_access.runAs(a, error.CorruptStore) catch |err| {
        page.tools_walk = .{};
        return err;
    };
    page.tools_complete = page.tools_end < Page.tool_batch;
}

/// The set's next provider-run member at or after ordinal ?2. Its record
/// carries no text: the codec names the tool.
const historical_provider_tool = rsql.Read(.{
    .sql = "SELECT member.ordinal,tool.name FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE member.tool_set_id=?1 AND member.ordinal>=?2 AND tool.owner='provider' ORDER BY member.ordinal LIMIT 1",
    .Args = struct { set: u64, ordinal: u64 },
    .Row = struct { ordinal: u64, name: *Bounded(tool_catalog.max_name_bytes) },
    .cardinality = .optional,
});

fn readProviderTool(self: *Store, view: *HistoricalView, out: *HistoricalTool) !void {
    return self.queue().run(readProviderToolHeld, .{ self, view, out });
}

fn readProviderToolHeld(self: *Store, view: *HistoricalView, out: *HistoricalTool) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, providerToolOf(&access, view, out));
}

/// One round reads the next provider-run member; a missing one is
/// `CorruptStore`, since the settings counted it.
fn providerToolOf(a: *ReadAccess, view: *HistoricalView, out: *HistoricalTool) !void {
    var row: historical_provider_tool.Row = undefined;
    row.name = &out.name;
    var found: store_access.Found = undefined;
    a.readInto(historical_provider_tool, .{ .set = view.tool_set_id, .ordinal = view.next_tool }, &row, &found);
    try store_access.runAs(a, error.CorruptStore);
    if (!found.get()) return error.CorruptStore;
    view.next_tool = row.ordinal + 1;
    out.owner = .provider;
}

fn readHistoricalSettings(self: *Store, view: *HistoricalView, out: *HistoricalSettings) !void {
    return self.queue().run(readHistoricalSettingsHeld, .{ self, view, out });
}

fn readHistoricalSettingsHeld(self: *Store, view: *HistoricalView, out: *HistoricalSettings) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.attempt_binding, settingsOf(&access, view, out));
}

/// The settings an Operation's request froze, with its Session's binding.
/// The texts decode straight into the caller's settings.
const historical_settings = rsql.Read(.{
    .sql = "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id," ++ tool_set.offeredSetSql("r") ++ " AS tool_set_id,tool_set.member_count," ++
        "(SELECT count(*) FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE member.tool_set_id=" ++ tool_set.offeredSetSql("r") ++ " AND tool.owner='provider') AS provider_count,r.provider,o.session_ref,r.workspace,o.compaction_trigger,o.output_reservation," ++
        "o.reasoning_effort,s.codec,s.codec_options IS NULL AS plain_codec,o.purpose," ++
        "(SELECT first.reasoning_effort FROM model_operation first JOIN session_revision first_revision ON first_revision.session_ref=first.session_ref AND first_revision.revision=first.settings_revision " ++
        "WHERE first.session_ref=o.session_ref AND first_revision.model=r.model ORDER BY first.admission_position LIMIT 1) AS starting_effort," ++ skills_domain.sourcesConsistentSql("o.session_ref", "catalog_required.position<o.admission_position") ++ " AS catalogs_consistent," ++
        "instructions.byte_length AS instructions_length,instructions.digest AS instructions_digest,instructions.private AS instructions_private," ++
        pageBytesSql("instructions", "instructions_bytes") ++ "," ++
        "output_schema.byte_length AS output_schema_length,output_schema.digest AS output_schema_digest,output_schema.private AS output_schema_private " ++
        "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref JOIN session_revision r ON r.session_ref=o.session_ref " ++
        "AND r.revision=o.settings_revision JOIN tool_set ON tool_set.tool_set_id=" ++ tool_set.offeredSetSql("r") ++ " JOIN session_revision baseline ON baseline.session_ref=o.session_ref AND baseline.revision=1 " ++
        "JOIN content instructions ON instructions.content_id=baseline.instructions_content_id " ++
        "LEFT JOIN content output_schema ON output_schema.content_id=r.output_schema_content_id WHERE o.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct {
        model: *Bounded(model_capability.max_model_bytes),
        instructions_content_id: rsql.Positive,
        output_schema_content_id: ?rsql.Positive,
        tool_set_id: rsql.Positive,
        member_count: u64,
        provider_count: u64,
        provider: provider_name.Provider,
        session_ref: *Bounded(session_id.max_reference_bytes),
        workspace: *Bounded(workspace_path.max_bytes),
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        codec: Bounded(40),
        plain_codec: bool,
        purpose: u8,
        starting_effort: ?model_capability.ReasoningEffort,
        catalogs_consistent: bool,
        instructions_length: u64,
        instructions_digest: [32]u8,
        instructions_private: bool,
        instructions_bytes: ?Page.Bytes,
        output_schema_length: ?u64,
        output_schema_digest: ?[32]u8,
        output_schema_private: ?bool,
    },
    .cardinality = .optional,
});

/// One round reads whether the binding is current, the settings, the
/// Operation's purpose, the instructions' and output schema's metadata
/// and, the first time, the output check's boundary and first page. A
/// failed step is `OperationReadFailed` for the binding and
/// `CorruptStore` for the rest, main's answer for each; so is a content
/// row the settings name and the Store lacks.
fn settingsOf(a: *ReadAccess, view: *HistoricalView, out: *HistoricalSettings) !void {
    const page = view.page.?;
    const row = page.decoded(historical_settings.Row);
    row.model = &out.model;
    row.session_ref = &out.session;
    row.workspace = &out.workspace;
    var standing: model_settlement_domain.attempt_standing.Result = undefined;
    model_settlement_domain.queueAttemptKind(a, view.binding, &standing);
    var found: store_access.Found = undefined;
    a.readInto(historical_settings, .{ .operation = view.binding.operation_id }, row, &found);
    const first = view.output_frontier == null;
    var boundary: reads_domain.First(output_boundary.Row) = .{};
    var sources: OutputSources = .{ .view = view };
    if (first) {
        a.readEach(output_boundary, .{ .operation = view.binding.operation_id }, 1, &boundary);
        a.readEach(first_output_sources, .{ .operation = view.binding.operation_id }, output_source_page, &sources);
    }
    try store_access.runNamed(a, .{.{ model_settlement_domain.attempt_standing, error.OperationReadFailed }}, error.CorruptStore);
    _ = try model_settlement_domain.attemptKindOf(standing, view.binding);
    if (!found.get() or !row.catalogs_consistent) return error.CorruptStore;
    if (first) {
        try sources.finish();
        try keepOutputBoundary(view, &(boundary.row orelse return error.CorruptStore));
    }
    page.keep(.batch, row.instructions_content_id, &row.instructions_bytes);
    if (row.member_count > tool_catalog.max_tools or row.provider_count > row.member_count) return error.CorruptStore;
    view.tool_set_id = row.tool_set_id.get();
    view.tool_count = row.member_count;
    view.provider_tool_count = row.provider_count;
    view.next_tool = 0;
    out.tool_count = row.member_count;
    const instructions: content_metadata.Row = .{ .byte_length = row.instructions_length, .digest = row.instructions_digest, .private = row.instructions_private };
    out.baseline_instructions = try viewContent(view, row.instructions_content_id.get(), &instructions, false);
    out.output_schema = if (row.output_schema_content_id) |id| schema: {
        const output_schema: content_metadata.Row = .{
            .byte_length = row.output_schema_length orelse return error.CorruptStore,
            .digest = row.output_schema_digest orelse return error.CorruptStore,
            .private = row.output_schema_private orelse return error.CorruptStore,
        };
        break :schema try viewContent(view, id.get(), &output_schema, false);
    } else null;
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
    out.starting_effort = row.starting_effort;
    out.provider = row.provider;
    // Requests are built by the codec the Session pinned, which takes no
    // options; a Session pinned to one this Host does not serve cannot be.
    out.codec = std.meta.stringToEnum(provider_name.Codec, row.codec.slice()) orelse return error.CorruptStore;
    if (!row.plain_codec) return error.CorruptStore;
    out.session_affinity = hash.finalResult()[0..16].*;
}

fn readHistoricalEntry(self: *Store, view: *HistoricalView, after_position: u64) !HistoricalView.EntryProgress {
    return self.queue().run(readHistoricalEntryHeld, .{ self, view, after_position });
}

fn readHistoricalEntryHeld(self: *Store, view: *HistoricalView, after_position: u64) !HistoricalView.EntryProgress {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return .{ .ready = try entry.finish(Ordinary.historical_entry, entryAfter(&access, view, after_position)) };
}

fn validateHistoricalOutputsStep(self: *Store, view: *HistoricalView) !bool {
    return self.queue().run(validateHistoricalOutputsStepHeld, .{ self, view });
}

fn validateHistoricalOutputsStepHeld(self: *Store, view: *HistoricalView) !bool {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, checkOutputsStep(&access, view));
}

fn readPrefixSeal(self: *Store, binding: AttemptBinding) !?PrefixSeal {
    return self.queue().run(readPrefixSealHeld, .{ self, binding });
}

fn readPrefixSealHeld(self: *Store, binding: AttemptBinding) !?PrefixSeal {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, prefixSealOf(&access, binding));
}

/// The prefix seal of an Operation's Session.
const session_prefix_seal = rsql.Read(.{
    .sql = "SELECT s.prefix_seal,o.admission_position FROM model_operation o JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { prefix_seal: ?[prefix_seal.encoded_bytes]u8, admission_position: rsql.Positive },
    .cardinality = .one,
});

/// Model identity for a seal is derived from its existing Operation
/// admission position, so neither the seal nor the Store format grows.
const seal_model = rsql.Read(.{
    .sql = "SELECT sealed_revision.model=current_revision.model AS same_model " ++
        "FROM model_operation current JOIN session_revision current_revision ON current_revision.session_ref=current.session_ref AND current_revision.revision=current.settings_revision " ++
        "JOIN model_operation sealed ON sealed.session_ref=current.session_ref AND sealed.admission_position=?2 " ++
        "JOIN session_revision sealed_revision ON sealed_revision.session_ref=sealed.session_ref AND sealed_revision.revision=sealed.settings_revision " ++
        "WHERE current.operation_id=?1",
    .Args = struct { operation: u64, admission: u64 },
    .Row = struct { same_model: bool },
    .cardinality = .one,
});

/// A recorded span binds only requests for its model. A failed read or
/// a seal whose producing Operation is missing is canonical corruption.
pub fn prefixSealOf(a: *ReadAccess, binding: AttemptBinding) !?PrefixSeal {
    var row: session_prefix_seal.Row = undefined;
    a.read(session_prefix_seal, .{ .operation = binding.operation_id }, &row);
    try store_access.runAs(a, error.CorruptStore);
    const bytes = row.prefix_seal orelse return null;
    const seal = try PrefixSeal.decode(&bytes);
    // A later view neither binds nor is replaced; its model is irrelevant.
    if (seal.admission_position > row.admission_position.get()) return seal;
    var identity: seal_model.Row = undefined;
    a.read(seal_model, .{ .operation = binding.operation_id, .admission = seal.admission_position }, &identity);
    try store_access.runAs(a, error.CorruptStore);
    return if (identity.same_model) seal else null;
}

pub fn recordPrefixSeal(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    return self.queue().write(recordPrefixSealHeld, .{ self, binding, seal });
}

fn recordPrefixSealHeld(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{}) = .open(&entry);
    defer a.deinit();
    return entry.finishTransaction(Ordinary.attempt_binding, .{}, a.end(.{}, sealOn(&a, binding, seal)));
}

/// Records an Operation's Session's prefix seal.
const record_prefix_seal = rsql.Write(.{
    .sql = "UPDATE session SET prefix_seal=?2 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, seal: [prefix_seal.encoded_bytes]u8 },
    // The Session was read in this transaction under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Round 1 reads the Attempt and its Session; the seal is written, in
/// round 2 with the commit, only while the binding is current. Public so a
/// test counts its rounds.
pub fn sealOn(a: anytype, binding: AttemptBinding, seal: *const PrefixSeal) !void {
    const session = try model_settlement_domain.currentAttemptSession(a, binding);
    a.write(record_prefix_seal, .{ .session = session, .seal = seal.encode() });
    try a.commit();
}

/// The newest accepted compaction before this boundary, without a model
/// filter or fallback to an older base. Recipe.select owns replay selection.
pub fn newestBaseSql(comptime session: []const u8, comptime boundary: []const u8) []const u8 {
    return "(SELECT selected.operation_id FROM model_operation selected @index(model_operation_compaction_bases) " ++
        "WHERE selected.session_ref=" ++ session ++ " AND selected.purpose=1 AND " ++
        store_schema.resolutionIs("selected.resolution_code", .compacted) ++ " AND selected.admission_position<" ++ boundary ++
        " ORDER BY selected.admission_position DESC LIMIT 1)";
}
const selected_base_sql = newestBaseSql("current.session_ref", "current.admission_position");

/// The base's compaction items, whose provider bag is the opaque
/// continuation: a base has exactly one.
const base_anchors_from = "FROM model_output_item anchor @index(model_output_compaction_anchor) ";
const base_anchors_where = "WHERE anchor.operation_id=base.operation_id AND anchor.item_kind=4";

/// The Operation's admission position and its selected Compaction Base;
/// the floor each has, and, only under a floor, the Session's first user
/// Message; and the base's compaction items: how many, the first one's
/// position, and how many have their bag's row.
const output_boundary = rsql.Read(.{
    .sql = "SELECT current.admission_position,base.operation_id,coalesce(base.admission_position,0) AS frontier," ++
        "current.history_floor AS own_floor,base.history_floor AS base_floor,current_revision.model AS current_model,base_revision.model AS base_model," ++
        "(SELECT count(*) " ++ base_anchors_from ++ base_anchors_where ++ ") AS anchors," ++
        "(SELECT min(anchor.session_position) " ++ base_anchors_from ++ base_anchors_where ++ ") AS anchor_position," ++
        "(SELECT count(*) " ++ base_anchors_from ++ "JOIN content bag ON bag.content_id=anchor.extras_content_id " ++ base_anchors_where ++ ") AS anchor_bags," ++
        "CASE WHEN coalesce(current.history_floor,base.history_floor) IS NULL THEN 0 ELSE coalesce((SELECT min(first.session_position) " ++
        "FROM conversation_entry first @index(conversation_entry_history) WHERE first.session_ref=current.session_ref AND first.entry_kind=1),0) END AS first_message " ++
        "FROM model_operation current LEFT JOIN model_operation base ON base.operation_id=" ++ selected_base_sql ++ " " ++
        "JOIN session_revision current_revision ON current_revision.session_ref=current.session_ref AND current_revision.revision=current.settings_revision " ++
        "LEFT JOIN session_revision base_revision ON base_revision.session_ref=base.session_ref AND base_revision.revision=base.settings_revision " ++
        "WHERE current.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct {
        admission_position: rsql.Positive,
        operation_id: ?rsql.Positive,
        frontier: u64,
        own_floor: ?rsql.Positive,
        base_floor: ?rsql.Positive,
        current_model: Bounded(model_capability.max_model_bytes),
        base_model: ?Bounded(model_capability.max_model_bytes),
        anchors: u64,
        anchor_position: ?rsql.Positive,
        anchor_bags: u64,
        first_message: u64,
    },
    .cardinality = .each,
});

// The primary key makes ordinals unique, so the count, the first and last
// ordinal and one position offset prove ordinals 0..count-1 at consecutive
// positions, all after admission and below the boundary.
/// What an output check row reads of producing Operation `source`:
/// whether its items are complete below `boundary`.
fn outputSourceColumns(comptime boundary: []const u8) []const u8 {
    return "source.operation_id,source.admission_position,source.output_item_count,source.purpose," ++
        "(SELECT count(*)=source.output_item_count AND coalesce(min(item.item_ordinal)=0 AND max(item.item_ordinal)=count(*)-1 " ++
        "AND min(item.session_position-item.item_ordinal)=max(item.session_position-item.item_ordinal) " ++
        "AND min(item.session_position)>source.admission_position AND max(item.session_position)<" ++ boundary ++ " " ++
        "AND min(item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal),1) " ++
        "FROM model_output_item item WHERE item.operation_id=source.operation_id) AS complete ";
}

const output_source_order = "ORDER BY source.admission_position,source.operation_id LIMIT " ++ std.fmt.comptimePrint("{d}", .{output_source_page});

const OutputSourceRow = struct { operation_id: rsql.Positive, admission_position: rsql.Positive, output_item_count: u64, purpose: u8, complete: bool };

/// The next accepted producing Operations after cursor (?3, ?5), from the
/// frontier ?2 to the boundary ?4, each with whether its items are
/// complete: one page of them, so a step's work stays bounded.
const output_source = rsql.Read(.{
    .sql = "SELECT " ++ outputSourceColumns("?4") ++
        "FROM model_operation current JOIN model_operation source @index(model_operation_context_history) ON source.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND source.admission_position>=?2 AND (source.admission_position>?3 OR (source.admission_position=?3 AND source.operation_id>?5)) " ++
        "AND source.admission_position<?4 AND " ++ store_schema.oneOf("source.resolution_code", &accepted_resolutions) ++ " " ++ output_source_order,
    .Args = struct { operation: u64, from: u64, after_position: u64, boundary: u64, after_operation: u64 },
    .Row = OutputSourceRow,
    .cardinality = .each,
});

/// The first page of them, from the Operation alone: the frontier and
/// the boundary are read in the statement, so it shares the round that
/// reads them (`output_boundary`).
const first_output_sources = rsql.Read(.{
    .sql = "WITH bounds AS (SELECT current.session_ref,current.admission_position AS boundary," ++
        "coalesce((SELECT base.admission_position FROM model_operation base WHERE base.operation_id=" ++ selected_base_sql ++ "),0) AS frontier " ++
        "FROM model_operation current WHERE current.operation_id=?1) " ++
        "SELECT " ++ outputSourceColumns("bounds.boundary") ++
        "FROM bounds JOIN model_operation source @index(model_operation_context_history) ON source.session_ref=bounds.session_ref " ++
        "WHERE source.admission_position>=bounds.frontier AND source.admission_position<bounds.boundary AND " ++
        store_schema.oneOf("source.resolution_code", &accepted_resolutions) ++ " " ++ output_source_order,
    .Args = struct { operation: u64 },
    .Row = OutputSourceRow,
    .cardinality = .each,
});

/// The producing Operations one output check step reads.
const output_source_page = 256;

/// Checks a page of producing Operations and keeps the last as the cursor.
const OutputSources = struct {
    view: *HistoricalView,
    rows: u16 = 0,
    corrupt: bool = false,

    pub fn visit(page: *OutputSources, source: *const OutputSourceRow) bool {
        page.rows += 1;
        page.view.output_cursor_id = source.operation_id.get();
        page.view.output_cursor = source.admission_position.get();
        if ((source.purpose == 1 and source.output_item_count == 0) or !source.complete) {
            page.corrupt = true;
            return false;
        }
        return true;
    }

    /// After the page's round: a short page was the last, and nothing
    /// accepted lies past it.
    fn finish(page: *const OutputSources) error{CorruptStore}!void {
        if (page.corrupt) return error.CorruptStore;
        page.view.outputs_validated = page.rows < output_source_page;
    }
};

fn keepOutputBoundary(view: *HistoricalView, row: *const output_boundary.Row) error{CorruptStore}!void {
    view.output_boundary = row.admission_position.get();
    view.selected_base = if (row.operation_id) |id| id.get() else 0;
    view.output_frontier = row.frontier;
    view.anchor = if (row.anchors == 1 and row.anchor_bags == 1) (row.anchor_position orelse return error.CorruptStore).get() else null;
    // Validate the selected base even when its opaque state cannot be sent.
    if (view.selected_base != 0 and view.anchor == null) return error.CorruptStore;
    const recipe = replay_recipe.Recipe.select(row.current_model.slice(), if (row.operation_id != null) .{
        .position = row.frontier,
        .floor = if (row.base_floor) |floor| floor.get() else 0,
        .model = (row.base_model orelse return error.CorruptStore).slice(),
    } else null, if (row.own_floor) |floor| floor.get() else 0);
    const compatible = (view.selected_base != 0) == (recipe.frontier != 0);
    if (!compatible) {
        // Rebuild the visible exchanges the old base (and its floor) covered.
        // The settings round's speculative first output page began at that
        // old frontier: restart its validation from the beginning as well.
        view.selected_base = 0;
        view.output_frontier = 0;
        view.anchor = null;
        view.output_cursor = 0;
        view.output_cursor_id = 0;
        view.outputs_validated = false;
    }
    const base_floor: u64 = if (compatible) (if (row.base_floor) |floor| floor.get() else 0) else 0;
    const own_floor: u64 = if (row.own_floor) |floor| floor.get() else 0;
    // A compaction keeps its base's floor or goes deeper.
    if (own_floor != 0 and own_floor < base_floor) return error.CorruptStore;
    view.floor = .{
        .position = recipe.floor,
        .first_message = row.first_message,
        .own = own_floor > base_floor,
    };
}

// The settings round reads the boundary and the first page, so a step
// here is a later page; a view whose settings were never read reads
// the boundary in a step of its own.
// Each step checks a page of producing Operations and their items in one
// statement. Its own item count detects even a completely missing output.
// No statement or lock survives this one step. A failed step is
// `CorruptStore`, main's answer for it.
fn checkOutputsStep(a: *ReadAccess, view: *HistoricalView) !bool {
    if (view.outputs_validated) return true;
    if (view.output_frontier == null) {
        var first: reads_domain.First(output_boundary.Row) = .{};
        a.readEach(output_boundary, .{ .operation = view.binding.operation_id }, 1, &first);
        try store_access.runAs(a, error.CorruptStore);
        try keepOutputBoundary(view, &(first.row orelse return error.CorruptStore));
        return false;
    }
    var page: OutputSources = .{ .view = view };
    a.readEach(output_source, .{
        .operation = view.binding.operation_id,
        // SQLite seeks the index only on this bound, never on the
        // cursor's OR, so it carries the cursor; each step then starts at
        // the next Operation instead of rescanning from the frontier.
        .from = @max(view.output_frontier.?, view.output_cursor),
        .after_position = view.output_cursor,
        .boundary = view.output_boundary,
        .after_operation = view.output_cursor_id,
    }, output_source_page, &page);
    try store_access.runAs(a, error.CorruptStore);
    try page.finish();
    return view.outputs_validated;
}

/// The served entry lives in the view: in its read-ahead, its next tool
/// group or its output check.
fn entryAfter(a: *ReadAccess, view: *HistoricalView, after_position: u64) !?*const HistoricalEntry {
    std.debug.assert(view.outputs_validated);
    var scan_tool_groups = !view.tool_group_initialized;
    if (view.tool_group_initialized and after_position < view.tool_group_scan_after) {
        view.entries_end = 0;
        view.tool_group_source_cursor = 0;
        view.group_scan = .{};
        view.page.?.groups_end = 0;
        view.page.?.groups_next = 0;
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
        if (try readNextHistoricalToolGroup(a, view, after_position)) |group| {
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
    .sql = "SELECT e.session_position,CASE WHEN e.entry_kind=4 THEN 5 ELSE e.entry_kind END AS entry_kind,e.content_id," ++ historical_content_columns_sql ++ ",NULL AS model,NULL AS provider,NULL AS item_kind,NULL AS item_id_digest,(e.source_catalog_position IS NULL OR " ++ skills_domain.instructionConsistentSql("e") ++ ") AS consistent," ++
        "(SELECT m.sender_session_ref FROM message_admission m WHERE e.entry_kind=1 AND m.admission_id=e.source_admission_id) AS sender,NULL AS effort," ++
        "NULL AS tool_set_id,NULL AS declares," ++ pageBytesSql("content", "bytes") ++ " " ++
        "FROM model_operation current JOIN conversation_entry e ON e.session_ref=current.session_ref " ++
        "LEFT JOIN content ON content.content_id=e.content_id " ++
        "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<current.admission_position " ++
        "AND e.entry_kind IN (1,2,4) AND (e.entry_kind=2 OR e.session_position>?3 OR e.session_position=?4" ++
        " OR " ++ history_floor_domain.firstMessageSkillSql("e", "?4") ++ ") UNION ALL " ++
        "SELECT item.session_position,3,NULL,NULL,NULL,NULL,r.model,r.provider,item.item_kind,item.item_id_digest," ++
        store_schema.oneOf("owner.resolution_code", &accepted_resolutions) ++ " AND owner.session_ref=item.session_ref " ++
        "AND owner_turn.session_ref=item.session_ref " ++
        "AND owner.attempt_ordinal=item.attempt_ordinal AND owner.admission_position<item.session_position " ++
        "AND owner.admission_position<current.admission_position AND " ++
        "(item.item_kind!=3 OR " ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ") AND " ++
        "((" ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ")=EXISTS(SELECT 1 FROM model_tool_call tool_call WHERE tool_call.operation_id=owner.operation_id)),NULL,NULL,NULL,NULL,NULL " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
        "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
        "LEFT JOIN turn owner_turn ON owner_turn.turn_id=owner.turn_id " ++
        "LEFT JOIN session_revision r ON r.session_ref=owner.session_ref AND r.revision=owner.settings_revision " ++
        "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position " ++
        "AND " ++ servedItemSql("?3", "?5") ++ " UNION ALL " ++
        // Every earlier Operation of the Session above the floor, whatever
        // its outcome: its request carried its own boundary, so later ones do too.
        // With each, its tool set and whether it declares any tool.
        "SELECT earlier.admission_position,4,NULL,NULL,NULL,NULL,revision.model,NULL,NULL,NULL,NULL,NULL,earlier.reasoning_effort," ++ tool_set.offeredSetSql("revision") ++ "," ++
        "EXISTS(SELECT 1 FROM " ++ declared_members_from ++ " WHERE " ++ declared_members_where(tool_set.offeredSetSql("revision"), "earlier.admission_position", "?6") ++ "),NULL " ++
        "FROM model_operation current JOIN model_operation earlier ON earlier.session_ref=current.session_ref " ++
        "JOIN session_revision revision ON revision.session_ref=earlier.session_ref AND revision.revision=earlier.settings_revision " ++
        "WHERE current.operation_id=?1 AND earlier.admission_position>?2 AND earlier.admission_position<current.admission_position " ++
        "AND (earlier.admission_position>?3 OR earlier.operation_id=?5) " ++
        std.fmt.comptimePrint("ORDER BY 1 LIMIT {d}", .{HistoricalView.entry_batch}),
    .Args = struct { operation: u64, after: u64, floor: u64, first_message: u64, base: u64, anchor: u64 },
    .Row = struct {
        session_position: rsql.Positive,
        entry_kind: u8,
        content_id: ?rsql.Positive,
        byte_length: ?u64,
        digest: ?[32]u8,
        private: ?bool,
        model: ?Bounded(model_capability.max_model_bytes),
        provider: ?provider_name.Provider,
        item_kind: ?u8,
        item_id_digest: ?[32]u8,
        consistent: ?bool,
        sender: ?Bounded(session_id.max_reference_bytes),
        effort: ?model_capability.ReasoningEffort,
        tool_set_id: ?rsql.Positive,
        declares: ?bool,
        bytes: ?Page.Bytes,
    },
    .cardinality = .each,
    .compound = true,
});

/// The first position whose Operation's declarations the request still
/// carries: the base's compaction item, or past the drop floor when that
/// is deeper. Earlier Operations' tools are folded or dropped.
fn declarationAnchor(view: *const HistoricalView) u64 {
    const anchor = view.anchor orelse 0;
    return if (view.floor.position == 0) anchor else @max(anchor, view.floor.position + 1);
}

/// The function tools `set` declares at the Operation boundary at
/// `position`: its function-tool members that the set of the last earlier
/// Operation at or after `anchor` lacks, or all of them when there is
/// none. `member` and `tool` name the member and its record, and the
/// Operation `current` names gives the Session.
const declared_members_from = "tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id";

fn declared_members_where(comptime set: []const u8, comptime position: []const u8, comptime anchor: []const u8) []const u8 {
    return "member.tool_set_id=" ++ set ++ " AND tool.owner!='provider' AND member.tool_record_id NOT IN (" ++
        "SELECT previous_member.tool_record_id FROM tool_set_member previous_member WHERE previous_member.tool_set_id=coalesce((" ++
        "SELECT " ++ tool_set.offeredSetSql("previous_revision") ++ " FROM model_operation previous JOIN session_revision previous_revision " ++
        "ON previous_revision.session_ref=previous.session_ref AND previous_revision.revision=previous.settings_revision " ++
        "WHERE previous.session_ref=current.session_ref AND previous.admission_position<" ++ position ++
        " AND previous.admission_position>=" ++ anchor ++ " ORDER BY previous.admission_position DESC LIMIT 1),0))";
}

/// Fills the view's read-ahead with each row a `historical_entries` read
/// steps, as its entry. The first row that is not one stops the read, and
/// its failure is the round's answer.
const EntryBatch = struct {
    view: *HistoricalView,
    /// The page's row, which the read decodes into.
    decoded: *historical_entries.Row,
    failure: ?error{CorruptStore} = null,

    pub fn visit(batch: *EntryBatch, row: *const historical_entries.Row) bool {
        const view = batch.view;
        view.entries[view.entries_end] = historicalEntry(view, row) catch |err| {
            batch.failure = err;
            return false;
        };
        view.entries_end += 1;
        view.page.?.keep(.batch, row.content_id, &row.bytes);
        return true;
    }
};

const historical_catalog_sources = rsql.Read(.{
    .sql = "SELECT " ++ skills_domain.sourcesConsistentSql("current.session_ref", "catalog_required.position<current.admission_position") ++
        " AS consistent FROM model_operation current WHERE current.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { consistent: bool },
    .cardinality = .one,
});

/// The buffered entry after `after_position`, if the read-ahead holds one.
fn bufferedEntry(view: *HistoricalView, after_position: u64) ?*const HistoricalEntry {
    while (view.entries_next < view.entries_end) : (view.entries_next += 1) {
        if (view.entries[view.entries_next].position > after_position) return &view.entries[view.entries_next];
    }
    return null;
}

/// Whether the entry after `after_position` needs a read: the read-ahead
/// holds none, and the walk has not ended at or before it.
fn needsBatch(view: *HistoricalView, after_position: u64) bool {
    if (bufferedEntry(view, after_position) != null) return false;
    return if (view.entries_done_after) |last| after_position < last else true;
}

/// The batch's last position when the batch is full, past which a row
/// belongs to a later batch; a short batch reaches the walk's end.
fn batchLast(view: *const HistoricalView) u64 {
    return if (view.entries_end == HistoricalView.entry_batch) view.entries[view.entries_end - 1].position else std.math.maxInt(u64);
}

/// One history round's reads: the entries after a position, a batch of
/// them, with their output items, those items' parts and every small
/// content they name; and the first page of the tools the request ends
/// with, until the page holds it. The items and parts are read by the
/// same bound as the entries, so they are the batch's and a few past it.
const BatchRead = struct {
    entries: EntryBatch,
    sources: historical_catalog_sources.Row,
    items: Page.Items,
    parts: Page.Parts,
    tools: Page.Tools,
    ahead: bool,

    /// The statements a failed step of which is `CorruptStore`, main's
    /// answer for an item's and a tool's reads; the rest are the entry
    /// read's `HistoricalEntryReadFailed`.
    const corrupt = .{
        .{ page_items, error.CorruptStore },
        .{ page_parts, error.CorruptStore },
        .{ declared_tools, error.CorruptStore },
        .{ set_tools, error.CorruptStore },
    };

    /// Queues the round's reads. `read` stays where it is until `finish`.
    fn queue(read: *BatchRead, a: *ReadAccess, view: *HistoricalView, after_position: u64) void {
        const page = view.page.?;
        view.entries_next = 0;
        view.entries_end = 0;
        view.entries_done_after = null;
        // A reader that borrows the page's bytes keeps them where they are.
        if (view.inline_readers == 0) page.batch.count = 0;
        page.items_end = 0;
        const operation = view.binding.operation_id;
        read.entries = .{ .view = view, .decoded = page.decoded(historical_entries.Row) };
        a.read(historical_catalog_sources, .{ .operation = operation }, &read.sources);
        a.readEach(historical_entries, .{
            .operation = operation,
            .after = after_position,
            .floor = view.floor.position,
            .first_message = view.floor.first_message,
            .base = view.selected_base,
            .anchor = declarationAnchor(view),
        }, HistoricalView.entry_batch, &read.entries);
        read.items = .{ .view = view, .decoded = page.decoded(page_items.Row) };
        a.readEach(page_items, .{ .operation = operation, .after = after_position, .floor = view.floor.position, .base = view.selected_base }, HistoricalView.entry_batch, &read.items);
        page.queueParts(a, view, &read.parts, after_position + 1, 0);
        const walk = view.aheadWalk();
        read.ahead = if (walk) |wanted| !page.toolsReach(wanted, 0) else false;
        if (read.ahead) page.queueTools(a, view, &read.tools, walk.?, 0);
    }

    /// The round failed: the page holds nothing of it.
    fn discard(read: *const BatchRead, view: *HistoricalView) void {
        view.entries_end = 0;
        if (read.ahead) view.page.?.tools_walk = .{};
    }

    /// After the round: the batch is the view's, or its failure.
    fn finish(read: *const BatchRead, view: *HistoricalView, after_position: u64) error{CorruptStore}!void {
        errdefer read.discard(view);
        const page = view.page.?;
        if (!read.sources.consistent) return error.CorruptStore;
        if (read.entries.failure) |err| return err;
        if (view.entries_end < HistoricalView.entry_batch)
            view.entries_done_after = if (view.entries_end == 0) after_position else view.entries[view.entries_end - 1].position;
        page.parts_complete = read.parts.past or page.parts_end < Page.part_batch;
        if (read.ahead) page.tools_complete = page.tools_end < Page.tool_batch;
    }
};

/// The next host input or output item after `after_position`, served from
/// the view's read-ahead and refilled by one round (`BatchRead`).
fn nextOrdinaryHistoricalEntry(a: *ReadAccess, view: *HistoricalView, after_position: u64) !?*const HistoricalEntry {
    if (!needsBatch(view, after_position)) return bufferedEntry(view, after_position);
    var read: BatchRead = undefined;
    read.queue(a, view, after_position);
    store_access.runNamed(a, BatchRead.corrupt, error.HistoricalEntryReadFailed) catch |err| {
        read.discard(view);
        return err;
    };
    try read.finish(view, after_position);
    return if (view.entries_end == 0) null else &view.entries[0];
}

/// The content row columns a page row carries for one of its contents,
/// NULL when the row is missing, and after them the content's bytes when
/// it is small.
fn pageContentSql(comptime table: []const u8, comptime name: []const u8) []const u8 {
    return table ++ ".byte_length AS " ++ name ++ "_length," ++ table ++ ".digest AS " ++ name ++ "_digest," ++ table ++ ".private AS " ++ name ++ "_private," ++
        pageBytesSql(table, name ++ "_bytes");
}

/// The bytes of content row `table` when it is small enough for the page
/// to hold whole, else NULL: a larger content is read through its reader.
fn pageBytesSql(comptime table: []const u8, comptime name: []const u8) []const u8 {
    return "CASE WHEN " ++ table ++ ".byte_length BETWEEN 1 AND " ++ std.fmt.comptimePrint("{d}", .{Page.inline_bytes}) ++ " THEN @payload(" ++ table ++ ") END AS " ++ name;
}

/// The output items a view serves: `item`'s Operation `owner` is unknown,
/// above the floor, or the selected base. Every read of a view's items
/// selects by it, so a page holds what the entries name.
fn servedItemSql(comptime floor: []const u8, comptime base: []const u8) []const u8 {
    return "(owner.admission_position IS NULL OR owner.admission_position>" ++ floor ++ " OR owner.operation_id=" ++ base ++ ")";
}

/// The Session's first output items after position ?2 that the view
/// serves, a batch of them in order: the batch's entries are among them.
/// Each has its call's fields and, for every content it names, the
/// metadata and the bytes of a small one.
const page_items = rsql.Read(.{
    .sql = "SELECT item.session_position,item.operation_id,item.item_ordinal,item.item_kind,item.phase,item.replay_omits_reasoning_text,item.part_count," ++
        "item.extras_content_id," ++ pageContentSql("bag", "bag") ++ ",item.message_content_id," ++ pageContentSql("message", "message") ++ "," ++
        "tool_call.name_content_id," ++ pageContentSql("name", "name") ++ ",tool_call.call_id_content_id," ++ pageContentSql("call_id", "call_id") ++ "," ++
        "tool_call.arguments_content_id," ++ pageContentSql("arguments", "arguments") ++ " " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
        "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
        "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
        "LEFT JOIN content bag ON bag.content_id=item.extras_content_id " ++
        "LEFT JOIN content message ON message.content_id=item.message_content_id " ++
        "LEFT JOIN content name ON name.content_id=tool_call.name_content_id " ++
        "LEFT JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "LEFT JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
        "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position AND " ++
        servedItemSql("?3", "?4") ++ " ORDER BY item.session_position " ++ std.fmt.comptimePrint("LIMIT {d}", .{HistoricalView.entry_batch}),
    .Args = struct { operation: u64, after: u64, floor: u64, base: u64 },
    .Row = struct {
        session_position: rsql.Positive,
        operation_id: rsql.Positive,
        item_ordinal: u64,
        item_kind: u8,
        phase: u8,
        replay_omits_reasoning_text: bool,
        part_count: u64,
        extras_content_id: rsql.Positive,
        bag_length: ?u64,
        bag_digest: ?[32]u8,
        bag_private: ?bool,
        bag_bytes: ?Page.Bytes,
        message_content_id: ?rsql.Positive,
        message_length: ?u64,
        message_digest: ?[32]u8,
        message_private: ?bool,
        message_bytes: ?Page.Bytes,
        name_content_id: ?rsql.Positive,
        name_length: ?u64,
        name_digest: ?[32]u8,
        name_private: ?bool,
        name_bytes: ?Page.Bytes,
        call_id_content_id: ?rsql.Positive,
        call_id_length: ?u64,
        call_id_digest: ?[32]u8,
        call_id_private: ?bool,
        call_id_bytes: ?Page.Bytes,
        arguments_content_id: ?rsql.Positive,
        arguments_length: ?u64,
        arguments_digest: ?[32]u8,
        arguments_private: ?bool,
        arguments_bytes: ?Page.Bytes,
    },
    .cardinality = .each,
});

/// The parts of the served items from part ?3 of the item at ?2 on, in
/// item then part order, a page of them: the parts of the first batch of
/// such items, so the sort is over one batch. Each has the metadata of
/// its own text and its bag and the bytes of a small one.
const page_parts = rsql.Read(.{
    .sql = "WITH batch AS (SELECT item.operation_id,item.item_ordinal,item.session_position " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
        "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
        "WHERE current.operation_id=?1 AND item.session_position>=?2 AND item.session_position<current.admission_position AND " ++
        servedItemSql("?4", "?5") ++ " ORDER BY item.session_position " ++ std.fmt.comptimePrint("LIMIT {d}", .{HistoricalView.entry_batch}) ++ ") " ++
        "SELECT batch.session_position,part.part_ordinal,part.part_array,part.part_kind,part.text_length,part.text_content_id," ++
        pageContentSql("own", "own") ++ ",part.extras_content_id," ++ pageContentSql("bag", "bag") ++ " " ++
        "FROM batch JOIN model_output_part part ON part.operation_id=batch.operation_id AND part.item_ordinal=batch.item_ordinal " ++
        "LEFT JOIN content own ON own.content_id=part.text_content_id " ++
        "LEFT JOIN content bag ON bag.content_id=part.extras_content_id " ++
        "WHERE batch.session_position>?2 OR part.part_ordinal>=?3 ORDER BY batch.session_position,part.part_ordinal " ++
        std.fmt.comptimePrint("LIMIT {d}", .{Page.part_batch}),
    .Args = struct { operation: u64, first: u64, part: u64, floor: u64, base: u64 },
    .Row = struct {
        session_position: rsql.Positive,
        part_ordinal: u64,
        part_array: u8,
        part_kind: u8,
        text_length: ?u64,
        text_content_id: ?rsql.Positive,
        own_length: ?u64,
        own_digest: ?[32]u8,
        own_private: ?bool,
        own_bytes: ?Page.Bytes,
        extras_content_id: rsql.Positive,
        bag_length: ?u64,
        bag_digest: ?[32]u8,
        bag_private: ?bool,
        bag_bytes: ?Page.Bytes,
    },
    .cardinality = .each,
});

/// What a view holds between its reads, on the heap: an entry batch's
/// output items and their parts in order, a page of tools, and the whole
/// bytes of every small content those rows name, each read with the row
/// that names it. History below the admission never changes, so the page
/// is plain values; content rows never change either, so bytes kept under
/// an id are that content's whichever row brought them.
const Page = struct {
    /// Where every read decodes its row, bytes and all
    /// (`Access.readEach`): one row at a time, each copied out by its
    /// visitor before the next.
    row: [row_bytes]u8 align(row_align),
    items: [HistoricalView.entry_batch]Item,
    items_end: usize,
    parts: [part_batch]Part,
    parts_next: usize,
    parts_end: usize,
    /// Whether `parts` reaches the batch's last part.
    parts_complete: bool,
    /// The members of `tools_walk` from ordinal `tools_from`, in order.
    tools: [tool_batch]Tool,
    tools_end: usize,
    tools_walk: ToolWalk,
    tools_from: u64,
    /// Whether `tools` reaches the walk's last member.
    tools_complete: bool,
    /// The tool groups the scan's last round read whole, in source
    /// order, and the next one it serves.
    groups: [group_batch]Group,
    groups_end: usize,
    groups_next: usize,
    /// The active group's results from the one after the last page's, in
    /// call order, and the next one it serves.
    results: [result_batch]Result,
    results_end: usize,
    results_next: usize,
    /// Whether `results` reaches the group's last result.
    results_complete: bool,
    /// The contents an entry batch names, kept from the start of `bytes`
    /// until the next batch; and the contents the tools page names, kept
    /// from its end until the next tools page. Each lists its contents'
    /// ids and where each one's bytes stop, toward the other.
    batch: Shelf(HistoricalView.entry_batch * 6 + part_batch * 2 + 1),
    held: Shelf(tool_batch * 2),
    bytes: [arena_bytes]u8,

    /// A content at most this long rides the row that names it.
    const inline_bytes = 16 * 1024;
    const Bytes = rsql.Blob(inline_bytes);
    const part_batch = 32;
    const tool_batch = 16;
    const group_batch = 16;
    const call_batch = 64;
    const result_batch = 16;

    /// A source Operation's tool group as the scan's rounds build it:
    /// how many of its `expected` calls they have `seen`, the latest
    /// position one was accepted at, and the last one's item.
    const Group = struct { source: u64, expected: u64, called: u64, whole: bool, seen: u64, position: u64, last_item: ?u64 };
    const arena_bytes = 128 * 1024;

    const rows = .{ historical_settings.Row, historical_entries.Row, page_items.Row, page_parts.Row, ToolRow, GroupCallRow, group_results.Row };
    const row_align = 16;
    const row_bytes = bytes: {
        var most: usize = 0;
        for (rows) |Row| {
            std.debug.assert(@alignOf(Row) <= row_align);
            most = @max(most, @sizeOf(Row));
        }
        break :bytes most;
    };

    /// The memory a read of `Row` decodes into.
    fn decoded(page: *Page, comptime Row: type) *Row {
        comptime {
            var listed = false;
            for (rows) |Listed| listed = listed or Listed == Row;
            std.debug.assert(listed);
        }
        return @ptrCast(&page.row);
    }

    fn Shelf(comptime capacity: usize) type {
        return struct {
            ids: [capacity]u64,
            stops: [capacity]u32,
            count: usize,
        };
    }

    const Side = enum { batch, held };

    /// Which members a tools page holds: a set's function tools declared
    /// at `position`, or its every member when `position` is zero. No set
    /// is zero.
    const ToolWalk = struct {
        set: u64 = 0,
        position: u64 = 0,
    };

    /// An item row without its contents' bytes.
    const Item = struct {
        session_position: rsql.Positive,
        operation_id: rsql.Positive,
        item_ordinal: u64,
        item_kind: u8,
        phase: u8,
        replay_omits_reasoning_text: bool,
        part_count: u64,
        extras_content_id: rsql.Positive,
        bag_length: ?u64,
        bag_digest: ?[32]u8,
        bag_private: ?bool,
        message_content_id: ?rsql.Positive,
        message_length: ?u64,
        message_digest: ?[32]u8,
        message_private: ?bool,
        name_content_id: ?rsql.Positive,
        name_length: ?u64,
        name_digest: ?[32]u8,
        name_private: ?bool,
        call_id_content_id: ?rsql.Positive,
        call_id_length: ?u64,
        call_id_digest: ?[32]u8,
        call_id_private: ?bool,
        arguments_content_id: ?rsql.Positive,
        arguments_length: ?u64,
        arguments_digest: ?[32]u8,
        arguments_private: ?bool,
    };

    /// A part row without its contents' bytes.
    const Part = struct {
        session_position: rsql.Positive,
        part_ordinal: u64,
        part_array: u8,
        part_kind: u8,
        text_length: ?u64,
        text_content_id: ?rsql.Positive,
        own_length: ?u64,
        own_digest: ?[32]u8,
        own_private: ?bool,
        extras_content_id: rsql.Positive,
        bag_length: ?u64,
        bag_digest: ?[32]u8,
        bag_private: ?bool,
    };

    /// A tool row without its texts' bytes.
    const Tool = struct {
        ordinal: u64,
        name: Bounded(tool_catalog.max_name_bytes),
        owner: tool_catalog.Owner,
        description_content_id: rsql.Positive,
        description_length: u64,
        description_digest: [32]u8,
        description_private: bool,
        schema_content_id: rsql.Positive,
        schema_length: u64,
        schema_digest: [32]u8,
        schema_private: bool,
    };

    /// A result row without its contents' bytes.
    const Result = struct {
        call_ordinal: u64,
        call_id_content_id: ?rsql.Positive,
        call_id_length: ?u64,
        call_id_digest: ?[32]u8,
        call_id_private: ?bool,
        output_content_id: ?rsql.Positive,
        output_length: ?u64,
        output_digest: ?[32]u8,
        output_private: ?bool,
    };

    /// Copies `row` without its bytes, which it keeps on `side`.
    fn store(page: *Page, comptime side: Side, row: anytype, out: anytype) void {
        const columns = @typeInfo(@TypeOf(row.*)).@"struct";
        const kept = @typeInfo(@TypeOf(out.*)).@"struct";
        // Every column but the bytes has its field in `out`.
        comptime {
            var bytes: usize = 0;
            for (columns.field_types) |Field| bytes += @intFromBool(Field == ?Bytes);
            std.debug.assert(kept.field_names.len + bytes == columns.field_names.len);
        }
        inline for (kept.field_names) |name| @field(out, name) = @field(row, name);
        inline for (columns.field_names, columns.field_types) |name, Field| if (Field == ?Bytes) {
            const id = comptime if (std.mem.eql(u8, name, "bag_bytes")) "extras_content_id" else if (std.mem.eql(u8, name, "own_bytes")) "text_content_id" else name[0 .. name.len - "_bytes".len] ++ "_content_id";
            page.keep(side, @field(row, id), &@field(row, name));
        };
    }

    /// The free bytes between the two shelves.
    fn free(page: *const Page) struct { start: usize, end: usize } {
        return .{
            .start = if (page.batch.count == 0) 0 else page.batch.stops[page.batch.count - 1],
            .end = if (page.held.count == 0) arena_bytes else page.held.stops[page.held.count - 1],
        };
    }

    /// Keeps content `id`'s whole `bytes` on `side`, when the row brought
    /// them and there is room: a content not kept is read through its
    /// reader.
    fn keep(page: *Page, comptime side: Side, id: anytype, bytes: *const ?Bytes) void {
        const content = (@as(?rsql.Positive, id) orelse return).get();
        const whole = if (bytes.*) |*value| value.slice() else return;
        const room = page.free();
        const shelf = &@field(page, @tagName(side));
        if (shelf.count == shelf.ids.len or whole.len > room.end - room.start) return;
        if (std.mem.findScalar(u64, shelf.ids[0..shelf.count], content) != null) return;
        const start = if (side == .batch) room.start else room.end - whole.len;
        @memcpy(page.bytes[start..][0..whole.len], whole);
        shelf.ids[shelf.count] = content;
        shelf.stops[shelf.count] = @intCast(if (side == .batch) start + whole.len else start);
        shelf.count += 1;
    }

    /// The bytes of content `id`, `length` long, if kept.
    fn find(page: *const Page, id: u64, length: u64) ?[]const u8 {
        const whole = if (std.mem.findScalar(u64, page.batch.ids[0..page.batch.count], id)) |index|
            page.bytes[if (index == 0) 0 else page.batch.stops[index - 1]..page.batch.stops[index]]
        else if (std.mem.findScalar(u64, page.held.ids[0..page.held.count], id)) |index|
            page.bytes[page.held.stops[index]..if (index == 0) arena_bytes else page.held.stops[index - 1]]
        else
            return null;
        return if (whole.len == length) whole else null;
    }

    pub const Items = struct {
        view: *HistoricalView,
        decoded: *page_items.Row,
        pub fn visit(items: *Items, row: *const page_items.Row) bool {
            const page = items.view.page.?;
            if (row.session_position.get() > batchLast(items.view)) return false;
            page.store(.batch, row, &page.items[page.items_end]);
            page.items_end += 1;
            return true;
        }
    };

    pub const Parts = struct {
        view: *HistoricalView,
        decoded: *page_parts.Row,
        /// The read reached a part past the batch.
        past: bool = false,
        pub fn visit(parts: *Parts, row: *const page_parts.Row) bool {
            const page = parts.view.page.?;
            if (row.session_position.get() > batchLast(parts.view)) {
                parts.past = true;
                return false;
            }
            page.store(.batch, row, &page.parts[page.parts_end]);
            page.parts_end += 1;
            return true;
        }
    };

    pub const Tools = struct {
        page: *Page,
        decoded: *ToolRow,
        pub fn visit(tools: *Tools, row: *const ToolRow) bool {
            const page = tools.page;
            page.store(.held, row, &page.tools[page.tools_end]);
            page.tools_end += 1;
            return true;
        }
    };

    pub const Results = struct {
        page: *Page,
        decoded: *group_results.Row,
        pub fn visit(results: *Results, row: *const group_results.Row) bool {
            const page = results.page;
            // Beside the batch's contents, until its next batch.
            page.store(.batch, row, &page.results[page.results_end]);
            page.results_end += 1;
            return true;
        }
    };

    /// Queues the read of the active group's results after the page's
    /// last; `results_complete` follows its round.
    fn queueResults(page: *Page, a: *ReadAccess, view: *HistoricalView, visitor: *Results) void {
        page.results_end = 0;
        page.results_next = 0;
        visitor.* = .{ .page = page, .decoded = page.decoded(group_results.Row) };
        a.readEach(group_results, .{
            .operation = view.binding.operation_id,
            .source = view.active_tool_group_source_id.?,
            .from = view.active_tool_group_count,
        }, result_batch, visitor);
    }

    /// Queues the parts read from part `part` of the item at `first`;
    /// `parts_complete` follows its round.
    fn queueParts(page: *Page, a: *ReadAccess, view: *HistoricalView, visitor: *Parts, first: u64, part: u64) void {
        page.parts_next = 0;
        page.parts_end = 0;
        page.parts_complete = false;
        visitor.* = .{ .view = view, .decoded = page.decoded(page_parts.Row) };
        a.readEach(page_parts, .{ .operation = view.binding.operation_id, .first = first, .part = part, .floor = view.floor.position, .base = view.selected_base }, part_batch, visitor);
    }

    /// Queues the read of `walk`'s members from `ordinal`;
    /// `tools_complete` follows its round.
    fn queueTools(page: *Page, a: *ReadAccess, view: *HistoricalView, visitor: *Tools, walk: ToolWalk, ordinal: u64) void {
        // A reader that borrows the page's bytes keeps them where they are.
        if (view.inline_readers == 0) page.held.count = 0;
        page.tools_end = 0;
        page.tools_walk = walk;
        page.tools_from = ordinal;
        page.tools_complete = false;
        visitor.* = .{ .page = page, .decoded = page.decoded(ToolRow) };
        if (walk.position == 0)
            a.readEach(set_tools, .{ .set = walk.set, .ordinal = ordinal }, tool_batch, visitor)
        else
            a.readEach(declared_tools, .{
                .operation = view.binding.operation_id,
                .set = walk.set,
                .ordinal = ordinal,
                .position = walk.position,
                .anchor = declarationAnchor(view),
            }, tool_batch, visitor);
    }

    /// Whether the page answers for `walk`'s member at or after `ordinal`.
    fn toolsReach(page: *const Page, walk: ToolWalk, ordinal: u64) bool {
        if (page.tools_walk.set != walk.set or page.tools_walk.position != walk.position or ordinal < page.tools_from) return false;
        return page.tools_complete or page.toolAt(ordinal) != null;
    }

    /// The page's member at or after `ordinal`.
    fn toolAt(page: *const Page, ordinal: u64) ?*const Tool {
        for (page.tools[0..page.tools_end]) |*tool| {
            if (tool.ordinal >= ordinal) return tool;
        }
        return null;
    }
};

fn historicalEntry(view: *HistoricalView, row: *const historical_entries.Row) error{CorruptStore}!HistoricalEntry {
    const kind: HistoricalEntryKind = switch (row.entry_kind) {
        1 => .user,
        2 => .instruction,
        3 => .provider_output,
        4 => .operation,
        5 => .skill,
        else => return error.CorruptStore,
    };
    if (kind == .operation) return .{
        .position = row.session_position.get(),
        .kind = .operation,
        .requested_model = row.model orelse return error.CorruptStore,
        .effort = row.effort,
        .tool_set_id = (row.tool_set_id orelse return error.CorruptStore).get(),
        .declares = row.declares orelse return error.CorruptStore,
    };
    var content: ?HistoricalContent = null;
    var requested_model: ?Bounded(model_capability.max_model_bytes) = null;
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
        if (row.consistent != true) return error.CorruptStore;
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
    view.active_tool_group_count = 0;
    view.active_tool_group_expected = view.next_tool_group_count;
    view.page.?.results_end = 0;
    view.page.?.results_next = 0;
    view.page.?.results_complete = false;
    return entry;
}

/// A Tool Results group: its entry is only a position.
const HistoricalToolGroup = struct {
    position: u64,
    source_operation_id: u64,
};

/// The Session's source Operations a page of the tool-group scan reads:
/// those from ?2 and before the view's own that proposed tools, the first
/// `Page.group_batch` of them. An Operation the floor ?3 drops brings no
/// tool group.
const group_sources_from = "FROM model_operation current JOIN model_operation source @index(model_operation_session_history) " ++
    "ON source.session_ref=current.session_ref WHERE current.operation_id=?1 AND source.operation_id>=?2 " ++
    "AND source.operation_id<current.operation_id AND source.admission_position>?3 AND " ++
    store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " ORDER BY source.operation_id LIMIT " ++
    std.fmt.comptimePrint("{d}", .{Page.group_batch});

/// Each of those sources, in order, with whether its items are the whole
/// immutable population its Operation counted, between its admission and
/// the view's (`outputSourceColumns`), how many of them are calls, and how
/// many calls the Operation has.
const group_sources = rsql.Read(.{
    .sql = "SELECT " ++ outputSourceColumns("current.admission_position") ++ "," ++ reads_domain.expectedCallsSql("source.operation_id") ++ "," ++
        "(SELECT count(*) FROM model_tool_call called WHERE called.operation_id=source.operation_id) AS called " ++ group_sources_from,
    .Args = struct { operation: u64, from: u64, floor: u64 },
    .Row = struct { operation_id: rsql.Positive, admission_position: rsql.Positive, output_item_count: u64, purpose: u8, complete: bool, expected: u64, called: u64 },
    .cardinality = .each,
});

/// Those sources' calls in source and call order, the first
/// `Page.call_batch` of them from call ?4 of source ?2: each with its
/// item, its Proposal as `reads.proposal_row` reads it, where it was
/// accepted, and whether its result is there, public and its rejection's
/// or its Action's own.
const group_calls = rsql.Read(.{
    .sql = "WITH sources AS (SELECT source.operation_id " ++ group_sources_from ++ ") " ++
        "SELECT sources.operation_id AS source,proposed.call_ordinal AS ordinal,item.item_ordinal,item.item_kind," ++
        "coalesce(tool_call.acceptance_position,action.acceptance_position) AS accepted_position," ++
        "CASE WHEN tool_call.rejection_code IS NOT NULL OR (action.resolution_code IS NOT NULL AND " ++
        "action.session_ref=op.session_ref AND action.tool_kind=tool_call.action_kind) THEN 1 ELSE 0 END AS outcome_consistent," ++
        "result.private AS result_private," ++ reads_domain.proposal_columns ++ " " ++
        "FROM sources JOIN model_tool_call proposed ON proposed.operation_id=sources.operation_id " ++
        "LEFT JOIN model_output_item item ON item.operation_id=proposed.operation_id AND item.item_ordinal=proposed.item_ordinal " ++
        reads_domain.proposal_joins ++
        "LEFT JOIN content result ON result.content_id=coalesce(tool_call.rejection_content_id,action.resolution_content_id) " ++
        "WHERE sources.operation_id>?2 OR proposed.call_ordinal>=?4 " ++
        // Ordered by the page's sources, so MySQL reads the calls from
        // them and never walks every Session's calls in key order.
        "ORDER BY sources.operation_id,proposed.call_ordinal LIMIT " ++ std.fmt.comptimePrint("{d}", .{Page.call_batch}),
    .Args = struct { operation: u64, from: u64, floor: u64, call: u64 },
    .Row = GroupCallRow,
    .cardinality = .each,
});

/// A `group_calls` row. Past `result_private` it is `proposal_row`'s, each
/// column NULL where a missing item, call or row leaves it so.
const GroupCallRow = struct {
    source: rsql.Positive,
    ordinal: u64,
    item_ordinal: ?u64,
    item_kind: ?u64,
    accepted_position: ?rsql.Positive,
    outcome_consistent: bool,
    result_private: ?bool,
    operation_id: ?rsql.Positive,
    turn_id: ?rsql.Positive,
    call_ordinal: ?u64,
    action_id: ?rsql.Positive,
    rejection_code: ?tool_proposal.Rejection,
    name_content_id: ?rsql.Positive,
    call_id_content_id: ?rsql.Positive,
    arguments_content_id: ?rsql.Positive,
    consistent: bool,
    field_metadata: ?[120]u8,
    length0: ?u64,
    digest0: ?[32]u8,
    private0: ?bool,
    length1: ?u64,
    digest1: ?[32]u8,
    private1: ?bool,
    length2: ?u64,
    digest2: ?[32]u8,
    private2: ?bool,
};

/// The view's own admission position, the bound of every group, and the
/// last Operation before the view's own, which a scan that reaches its
/// end has passed.
const group_bounds = rsql.Read(.{
    .sql = "SELECT current.admission_position AS boundary," ++
        "(SELECT max(last.operation_id) FROM model_operation last @index(model_operation_session_history) " ++
        "WHERE last.session_ref=current.session_ref AND last.operation_id<current.operation_id) AS last_source " ++
        "FROM model_operation current WHERE current.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { boundary: rsql.Positive, last_source: ?rsql.Positive },
    .cardinality = .optional,
});

/// One round of the tool-group scan: a page of source Operations and a
/// page of their calls, judged as main judged each item and call in
/// rounds of their own. A source's items are its whole population
/// (`group_sources`). It has as many calls as call items, and the calls
/// read run from ordinal zero with none missing, each on a call item later
/// than the one before, up to that count: so every call item has its
/// call, in order, and no call lies past them, whichever page ends it. Each call's Proposal is consistent and its
/// fields certified; its result is accepted, public and its own. The
/// group lies where its last result was accepted, below the view's
/// admission. Every failure is `CorruptStore`.
const GroupRead = struct {
    bounds: group_bounds.Result,
    sources: Sources,
    calls: Calls,

    const Sources = struct {
        view: *HistoricalView,
        rows: usize = 0,

        pub fn visit(sources: *Sources, row: *const group_sources.Row) bool {
            const page = sources.view.page.?;
            const scan = &sources.view.group_scan;
            const source = row.operation_id.get();
            const resumed = source == scan.source;
            page.groups[page.groups_end] = .{
                .source = source,
                .expected = row.expected,
                .called = row.called,
                .whole = row.complete and row.output_item_count != 0,
                .seen = if (resumed) scan.calls else 0,
                .position = if (resumed) scan.position else 0,
                .last_item = if (resumed) scan.last_item else null,
            };
            page.groups_end += 1;
            sources.rows += 1;
            return true;
        }
    };

    const Calls = struct {
        view: *HistoricalView,
        decoded: *GroupCallRow,
        index: usize = 0,
        rows: usize = 0,
        failed: bool = false,

        pub fn visit(calls: *Calls, row: *const GroupCallRow) bool {
            calls.take(row) catch {
                calls.failed = true;
                return false;
            };
            return true;
        }

        fn take(calls: *Calls, row: *const GroupCallRow) error{CorruptStore}!void {
            const page = calls.view.page.?;
            calls.rows += 1;
            const source = row.source.get();
            // A source's calls end before the next one's begin.
            while (calls.index < page.groups_end and page.groups[calls.index].source != source) {
                if (page.groups[calls.index].seen != page.groups[calls.index].expected) return error.CorruptStore;
                calls.index += 1;
            }
            if (calls.index == page.groups_end) return error.CorruptStore;
            const group = &page.groups[calls.index];
            const item = row.item_ordinal orelse return error.CorruptStore;
            if (row.ordinal != group.seen or group.seen == group.expected or row.item_kind != 3) return error.CorruptStore;
            if (group.last_item) |last| if (item <= last) return error.CorruptStore;
            try reads_domain.certifyCall(row);
            if ((row.operation_id orelse return error.CorruptStore).get() != source or row.call_ordinal != row.ordinal) return error.CorruptStore;
            if (!row.outcome_consistent or (row.result_private orelse return error.CorruptStore)) return error.CorruptStore;
            group.position = @max(group.position, (row.accepted_position orelse return error.CorruptStore).get());
            group.last_item = item;
            group.seen += 1;
        }
    };

    /// The statements a failed step of which is `CorruptStore`, main's
    /// answer for an item's and a call's reads; the bounds' is the entry
    /// read's `HistoricalEntryReadFailed`.
    const corrupt = .{
        .{ group_sources, error.CorruptStore },
        .{ group_calls, error.CorruptStore },
    };

    /// Queues the round's reads. `read` stays where it is until `finish`.
    fn queue(read: *GroupRead, a: *ReadAccess, view: *HistoricalView) void {
        const page = view.page.?;
        const scan = &view.group_scan;
        page.groups_end = 0;
        page.groups_next = 0;
        const operation = view.binding.operation_id;
        // Every group the page held was served, so the cursor is its last.
        const from = if (scan.source != 0) scan.source else view.tool_group_source_cursor + 1;
        read.sources = .{ .view = view };
        read.calls = .{ .view = view, .decoded = page.decoded(GroupCallRow) };
        a.read(group_bounds, .{ .operation = operation }, &read.bounds);
        a.readEach(group_sources, .{ .operation = operation, .from = from, .floor = view.floor.position }, Page.group_batch, &read.sources);
        a.readEach(group_calls, .{ .operation = operation, .from = from, .floor = view.floor.position, .call = scan.calls }, Page.call_batch, &read.calls);
    }

    /// The round failed: the page holds no group of it.
    fn discard(view: *HistoricalView) void {
        view.page.?.groups_end = 0;
    }

    /// After the round: the page holds the sources whose calls it read
    /// whole, in order; the scan holds the one a full page cut short, or
    /// that the sources ended.
    fn finish(read: *const GroupRead, view: *HistoricalView) error{CorruptStore}!void {
        errdefer discard(view);
        const page = view.page.?;
        const scan = &view.group_scan;
        scan.* = .{};
        const bounds = read.bounds orelse {
            if (page.groups_end != 0) return error.CorruptStore;
            scan.done = true;
            return;
        };
        if (read.calls.failed) return error.CorruptStore;
        const cut = read.calls.rows == Page.call_batch;
        for (page.groups[0..page.groups_end], 0..) |*group, index| {
            if (group.called != group.expected) return error.CorruptStore;
            if (group.seen != group.expected) {
                // Only the source the page's last call belongs to, or the
                // one after it, can lack calls the page had no room for.
                if (!cut or index < read.calls.index) return error.CorruptStore;
                scan.* = .{ .source = group.source, .calls = group.seen, .position = group.position, .last_item = group.last_item };
                page.groups_end = index;
                return;
            }
            if (!group.whole or group.expected == 0 or group.position == 0 or group.position >= bounds.boundary.get()) return error.CorruptStore;
        }
        if (read.sources.rows < Page.group_batch) {
            scan.done = true;
            scan.passed = if (bounds.last_source) |last| last.get() else 0;
        }
    }
};

/// The next tool group of the scan, from the page; a page that holds no
/// more is read in one round (`GroupRead`), which also reads the entry
/// batch after `after_position` when the view lacks it. A round that
/// completes no group, its first source's calls outrunning the page, is
/// `HistoricalPending`. A failed step is main's name: `CorruptStore` for
/// the sources' and calls' reads and `HistoricalEntryReadFailed` for the
/// bounds'.
fn readNextHistoricalToolGroup(a: *ReadAccess, view: *HistoricalView, after_position: u64) !?HistoricalToolGroup {
    const page = view.page.?;
    const scan = &view.group_scan;
    if (page.groups_next == page.groups_end and !scan.done) {
        var groups: GroupRead = undefined;
        groups.queue(a, view);
        var read: BatchRead = undefined;
        const rides = needsBatch(view, after_position);
        if (rides) read.queue(a, view, after_position);
        store_access.runNamed(a, BatchRead.corrupt ++ GroupRead.corrupt, error.HistoricalEntryReadFailed) catch |err| {
            GroupRead.discard(view);
            if (rides) read.discard(view);
            return err;
        };
        // The scan's answer comes first, as its round once did; a batch that
        // failed is discarded, and its next read fails again.
        const batch: error{CorruptStore}!void = if (rides) read.finish(view, after_position) else {};
        try groups.finish(view);
        try batch;
        if (page.groups_end == 0 and !scan.done) return error.HistoricalPending;
    }
    if (page.groups_next == page.groups_end) {
        // The scan has passed every earlier Operation.
        view.tool_group_source_cursor = @max(view.tool_group_source_cursor, scan.passed);
        return null;
    }
    const group = &page.groups[page.groups_next];
    page.groups_next += 1;
    view.next_tool_group_count = group.expected;
    return .{ .position = group.position, .source_operation_id = group.source };
}

/// A page row's content metadata; a missing content row left it NULL.
fn pageMetadata(length: ?u64, digest: ?[32]u8, private: ?bool) error{CorruptStore}!content_metadata.Row {
    return .{
        .byte_length = length orelse return error.CorruptStore,
        .digest = digest orelse return error.CorruptStore,
        .private = private orelse return error.CorruptStore,
    };
}

/// The output item at `position`, from the batch's page: its entry came
/// from the same batch, so a missing row is `CorruptStore`.
fn outputAt(view: *HistoricalView, position: u64) error{CorruptStore}!HistoricalOutput {
    const page = view.page orelse return error.CorruptStore;
    const row = for (page.items[0..page.items_end]) |*item| {
        if (item.session_position.get() == position) break item;
    } else return error.CorruptStore;
    const kind = std.enums.fromInt(OutputItemKind, row.item_kind) orelse return error.CorruptStore;
    const phase = std.enums.fromInt(output_format.NeutralPhase, row.phase) orelse return error.CorruptStore;
    if (row.part_count != 0 and kind != .reasoning and kind != .message) return error.CorruptStore;
    const has_call = row.name_content_id != null;
    if (has_call != (kind == .function_call)) return error.CorruptStore;
    if ((row.message_content_id != null) != (kind == .message)) return error.CorruptStore;
    var text: ?HistoricalView.MessageText = null;
    if (row.message_content_id) |id| {
        const content = try viewContent(view, id.get(), &try pageMetadata(row.message_length, row.message_digest, row.message_private), false);
        // Its parts' reads check a nonempty text; an empty one is
        // checked here.
        if (content.length == 0 and !std.mem.eql(u8, &content.digest, &content_string.digest(""))) return error.CorruptStore;
        text = .{ .content_id = content.content_id, .length = content.length, .digest = content.digest };
    }
    var call: ?[3]HistoricalContent = null;
    if (has_call) call = .{
        try viewContent(view, row.name_content_id.?.get(), &try pageMetadata(row.name_length, row.name_digest, row.name_private), false),
        try viewContent(view, (row.call_id_content_id orelse return error.CorruptStore).get(), &try pageMetadata(row.call_id_length, row.call_id_digest, row.call_id_private), false),
        try viewContent(view, (row.arguments_content_id orelse return error.CorruptStore).get(), &try pageMetadata(row.arguments_length, row.arguments_digest, row.arguments_private), false),
    };
    const bag = try viewBag(view, row.extras_content_id.get(), &try pageMetadata(row.bag_length, row.bag_digest, row.bag_private));
    view.output_parts = .{ .position = position, .operation_id = row.operation_id.get(), .item_ordinal = row.item_ordinal, .kind = kind, .count = row.part_count, .text = text };
    return .{
        .kind = kind,
        .phase = phase,
        .omit_reasoning_text = row.replay_omits_reasoning_text,
        .bag = bag,
        .call = call,
    };
}

/// Whether the open item's next part may lie past what `parts` holds:
/// the page's parts are in item order, and items the request leaves out
/// are passed over here.
fn partsExhausted(view: *HistoricalView) bool {
    const position = view.output_parts.?.position;
    const page = view.page.?;
    while (page.parts_next < page.parts_end and page.parts[page.parts_next].session_position.get() < position) page.parts_next += 1;
    return page.parts_next == page.parts_end and !page.parts_complete;
}

fn readHistoricalParts(self: *Store, view: *HistoricalView) !void {
    return self.queue().run(readHistoricalPartsHeld, .{ self, view });
}

fn readHistoricalPartsHeld(self: *Store, view: *HistoricalView) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, partsFrom(&access, view));
}

/// Refills `parts` from the open item's next part, in a round of its
/// own. A failed step is `HistoricalEntryReadFailed`, main's name.
fn partsFrom(a: *ReadAccess, view: *HistoricalView) !void {
    const cursor = &view.output_parts.?;
    const page = view.page.?;
    var parts: Page.Parts = undefined;
    page.queueParts(a, view, &parts, cursor.position, cursor.next);
    try store_access.runAs(a, error.HistoricalEntryReadFailed);
    page.parts_complete = parts.past or page.parts_end < Page.part_batch;
}

/// The open item's next part, from the page (`partsExhausted` is false).
fn nextPart(view: *HistoricalView) error{CorruptStore}!?HistoricalPart {
    const cursor = &view.output_parts.?;
    const page = view.page.?;
    const row = if (page.parts_next < page.parts_end and page.parts[page.parts_next].session_position.get() == cursor.position)
        &page.parts[page.parts_next]
    else {
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
    const text: ?HistoricalContent = switch (kind) {
        .opaque_block => if (row.text_length != null or row.text_content_id != null) return error.CorruptStore else null,
        .output_text, .refusal => ranged: {
            const length = row.text_length orelse return error.CorruptStore;
            const whole = &cursor.text.?;
            if (row.text_content_id != null or length > whole.length - whole.next) return error.CorruptStore;
            defer whole.next += length;
            break :ranged .{ .view = view, .content_id = whole.content_id, .length = length, .digest = whole.digest, .text_start = whole.next };
        },
        // Only a summary or reasoning text has a row of its own.
        .summary_text, .reasoning_text => if (row.text_length != null) return error.CorruptStore else try viewContent(
            view,
            (row.text_content_id orelse return error.CorruptStore).get(),
            &try pageMetadata(row.own_length, row.own_digest, row.own_private),
            true,
        ),
    };
    const bag = try viewBag(view, row.extras_content_id.get(), &try pageMetadata(row.bag_length, row.bag_digest, row.bag_private));
    // An opaque block is all bag: at least its type.
    if (kind == .opaque_block and bag == null) return error.CorruptStore;
    // Each array's parts are contiguous, so the writer opens it once.
    if (array != cursor.array) {
        if (cursor.closed[@backingInt(array) - 1]) return error.CorruptStore;
        if (cursor.array != .none) cursor.closed[@backingInt(cursor.array) - 1] = true;
        cursor.array = array;
    }
    cursor.next += 1;
    page.parts_next += 1;
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
    return self.queue().run(readHistoricalToolResultHeld, .{ self, view });
}

fn readHistoricalToolResultHeld(
    self: *Store,
    view: *HistoricalView,
) !?HistoricalToolResult {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, nextGroupResult(&access, view));
}

/// The active group's calls accepted before the Operation's admission,
/// from ordinal ?3, a page of them in order: each with its call id's and
/// output's content rows, and the bytes of a small one.
const group_results = rsql.Read(.{
    .sql = "SELECT tool_call.call_ordinal,tool_call.call_id_content_id,call_id.byte_length AS call_id_length,call_id.digest AS call_id_digest," ++
        "call_id.private AS call_id_private," ++ pageBytesSql("call_id", "call_id_bytes") ++ "," ++
        "output.content_id AS output_content_id,output.byte_length AS output_length,output.digest AS output_digest," ++
        "output.private AS output_private," ++ pageBytesSql("output", "output_bytes") ++ " " ++
        "FROM model_operation current " ++
        "CROSS JOIN model_operation source ON source.operation_id=?2 AND source.session_ref=current.session_ref " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=source.operation_id LEFT JOIN action_operation action " ++
        "ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "LEFT JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "LEFT JOIN content output ON output.content_id=coalesce(tool_call.rejection_content_id,action.resolution_content_id) " ++
        "WHERE current.operation_id=?1 AND " ++ store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " " ++
        "AND coalesce(tool_call.acceptance_position,action.acceptance_position)<current.admission_position " ++
        "AND tool_call.call_ordinal>=?3 ORDER BY tool_call.call_ordinal LIMIT " ++ std.fmt.comptimePrint("{d}", .{Page.result_batch}),
    .Args = struct { operation: u64, source: u64, from: u64 },
    .Row = struct {
        call_ordinal: u64,
        call_id_content_id: ?rsql.Positive,
        call_id_length: ?u64,
        call_id_digest: ?[32]u8,
        call_id_private: ?bool,
        call_id_bytes: ?Page.Bytes,
        output_content_id: ?rsql.Positive,
        output_length: ?u64,
        output_digest: ?[32]u8,
        output_private: ?bool,
        output_bytes: ?Page.Bytes,
    },
    .cardinality = .each,
});

/// The active group's next result, from the page; a page that holds no
/// more is read in one round, from the call after the last one served. A
/// failed step is `HistoricalEntryReadFailed`, main's name for the call's
/// read; a result that lacks a content row is `CorruptStore`.
fn nextGroupResult(a: *ReadAccess, view: *HistoricalView) !?HistoricalToolResult {
    std.debug.assert(view.active_tool_group_source_id != null);
    const page = view.page.?;
    if (page.results_next == page.results_end and !page.results_complete) {
        var results: Page.Results = undefined;
        page.queueResults(a, view, &results);
        try store_access.runAs(a, error.HistoricalEntryReadFailed);
        page.results_complete = page.results_end < Page.result_batch;
    }
    if (page.results_next == page.results_end) {
        if (view.active_tool_group_count != view.active_tool_group_expected) return error.CorruptStore;
        view.active_tool_group_source_id = null;
        view.active_tool_group_count = 0;
        return null;
    }
    const row = &page.results[page.results_next];
    if (row.call_ordinal != view.active_tool_group_count or view.active_tool_group_count >= view.active_tool_group_expected)
        return error.CorruptStore;
    const call_id = try viewContent(view, (row.call_id_content_id orelse return error.CorruptStore).get(), &try pageMetadata(row.call_id_length, row.call_id_digest, row.call_id_private), false);
    const output = try viewContent(view, (row.output_content_id orelse return error.CorruptStore).get(), &try pageMetadata(row.output_length, row.output_digest, row.output_private), false);
    page.results_next += 1;
    view.active_tool_group_count += 1;
    return .{ .call_id = call_id, .output = output };
}

/// Content as a view handle, only when its privacy is `private`: like a
/// digest lookup of public content, a private row cannot stand in.
fn viewContent(view: *HistoricalView, content_id: u64, row: *const content_metadata.Row, private: bool) error{CorruptStore}!HistoricalContent {
    if (row.private != private) return error.CorruptStore;
    return .{ .view = view, .content_id = @intCast(content_id), .length = row.byte_length, .digest = row.digest };
}
