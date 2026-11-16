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
const tool_defs = @import("../../tool_record.zig");
const output_format = @import("../../output_format.zig");
const prefix_seal = @import("../../prefix_seal.zig");
const tool_proposal = @import("../../tool_proposal.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @This();
const operation_effort = @import("operation_effort.zig");
const action_read_domain = @import("action_read.zig");
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const skills_domain = @import("skills.zig");
const history_floor_domain = @import("history_floor.zig");
const reads_domain = @import("reads.zig");
const rsql = @import("../rsql.zig");
const tool_fulfillment = @import("tool_fulfillment.zig");
const tool_set = @import("tool_set.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
pub const ReadAccess = reads_domain.ReadAccess;
const content_metadata = content_domain.content_metadata;
const store_schema = @import("../schema.zig");
const AttemptBinding = store_core.AttemptBinding;
const ContentWindow = content_domain.ContentWindow;
const Ordinary = store_core.Ordinary;
const accepted_resolutions = store_schema.accepted_resolutions;

pub const PrefixSeal = prefix_seal.PrefixSeal;

const historical_content_columns_sql = "content.byte_length,content.digest,content.private,content.form";

pub const HistoricalContent = struct {
    view: *RequestPage,
    content_id: i64,
    length: u64,
    digest: [32]u8,
    verified: bool = false,
    text_start: ?u64 = null,

    pub fn belongsTo(self: HistoricalContent, view: *RequestPage) bool {
        return self.view == view and view.active;
    }
};

pub const ModelOperationKind = output_format.ModelOperationKind;

pub const HistoricalSettings = struct {
    operation: ModelOperationKind = .assistant_response,
    compaction_trigger: ?u64 = null,
    output_reservation: u64 = 0,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    effort_update: bool = false,
    starting_effort: ?model_capability.ReasoningEffort = null,
    codec: provider_name.Codec,
    provider: provider_name.Provider,
    model: Bounded(model_capability.max_model_bytes),
    workspace: Bounded(workspace_path.max_bytes),
    store: Bounded(store_path.max_bytes),
    session: Bounded(session_id.max_reference_bytes),
    parent: ?Bounded(session_id.max_reference_bytes),
    session_affinity: [16]u8,
    baseline_instructions: HistoricalContent,
    output_schema: ?HistoricalContent,
    tool_count: u64,
};

pub const HistoricalTool = struct {
    name: Bounded(tool_defs.max_name_bytes) = .{},
    owner: tool_defs.Owner = undefined,
    description: HistoricalContent = undefined,
    input_schema: HistoricalContent = undefined,
};

pub const HistoricalEntryKind = enum { user, instruction, provider_output, tool_results, operation, skill };

pub const HistoricalEntry = struct {
    position: u64,
    kind: HistoricalEntryKind,
    content: ?HistoricalContent = null,
    requested_model: ?Bounded(model_capability.max_model_bytes) = null,
    source_action: ?struct { id: u64, session: Bounded(session_id.bytes) } = null,
    sender: ?Bounded(session_id.max_reference_bytes) = null,
    effort: ?model_capability.ReasoningEffort = null,
    tool_set_id: u64 = 0,
    declares: bool = false,
};

pub const Declaration = struct {
    tool_set_id: u64,
    position: u64,
    next_ordinal: u64 = 0,
};

pub const HistoricalOutput = struct {
    kind: OutputItemKind,
    phase: output_format.NeutralPhase,
    omit_reasoning_text: bool,
    bag: ?HistoricalContent,
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

pub const RequestPage = struct {
    binding: AttemptBinding,
    read: ?*Read = null,
    active: bool = true,
    readers: usize = 0,
    tool_group_initialized: bool = false,
    read_ahead: enum(u8) {
        none,
        unclaimed,
        resumed,
    } = .none,
    tool_group_scan_after: u64 = 0,
    tool_group_source_cursor: u64 = 0,
    next_tool_group: ?HistoricalEntry = null,
    next_tool_group_source_id: ?u64 = null,
    active_tool_group_source_id: ?u64 = null,
    active_tool_group_count: u64 = 0,
    outputs_validated: bool = false,
    output_frontier: ?u64 = null,
    selected_base: u64 = 0,
    floor: Floor = .{},
    anchor: ?u64 = null,
    output_boundary: u64 = 0,
    output_cursor: u64 = 0,
    output_cursor_id: u64 = 0,
    group_scan: GroupScan = .{},
    next_tool_group_count: u64 = 0,
    active_tool_group_expected: u64 = 0,
    tool_set_id: u64 = 0,
    tool_count: u64 = 0,
    next_tool: u64 = 0,
    provider_tool_count: u64 = 0,
    provider_tools_read: u64 = 0,
    entries: [entry_batch]HistoricalEntry = undefined,
    entries_next: usize = 0,
    entries_end: usize = 0,
    entries_done_after: ?u64 = null,
    page: ?*Page = null,
    inline_readers: usize = 0,
    ahead: ToolsAhead = .none,
    output_parts: ?OutputPartCursor = null,

    const entry_batch = 16;

    pub const ToolsAhead = enum { none, declared, all };

    const OutputPartCursor = struct {
        position: u64,
        operation_id: u64,
        item_ordinal: u64,
        kind: OutputItemKind,
        count: u64,
        next: u64 = 0,
        closed: [2]bool = .{ false, false },
        array: output_format.PartArray = .none,
        text: ?MessageText = null,
    };

    const MessageText = struct {
        content_id: i64,
        length: u64,
        digest: [32]u8,
        next: u64 = 0,
        read: u64 = 0,
        hash: @TypeOf(content_string.hasher()) = content_string.hasher(),
    };

    pub const Coverage = struct {
        frontier: u64,
        anchor: ?u64,
        floor: Floor,
    };

    pub const Floor = struct {
        position: u64 = 0,
        first_message: u64 = 0,
        own: bool = false,
    };

    const GroupScan = struct {
        source: u64 = 0,
        calls: u64 = 0,
        position: u64 = 0,
        last_item: ?u64 = null,
        done: bool = false,
        passed: u64 = 0,
    };

    pub const EntryProgress = union(enum) { pending, ready: ?*const HistoricalEntry };

    pub const Question = union(enum) {
        settings: *HistoricalSettings,
        outputs_step,
        entry: u64,
        parts,
        tool_result,
        tools: struct { walk: Page.ToolWalk, ordinal: u64 },
        provider_tool: *HistoricalTool,
        prefix_seal,
        record_seal: PrefixSeal,
        content: struct { reader: *HistoricalReader, start: u64, destination: []u8 },
        corrupt,
    };

    pub const Answer = union(std.meta.Tag(Question)) {
        settings,
        outputs_step: bool,
        entry: EntryProgress,
        parts,
        tool_result: ?HistoricalToolResult,
        tools,
        provider_tool,
        prefix_seal: ?PrefixSeal,
        record_seal,
        content: usize,
        corrupt,
    };

    pub const Read = struct {
        question: Question,
        answer: ?Answer = null,
    };

    fn ask(self: *RequestPage, question: Question) !Answer {
        try self.allocatePage();
        if (self.read) |read| if (read.answer) |answer| {
            std.debug.assert(std.meta.eql(read.question, question));
            self.read = null;
            return answer;
        };
        self.keepRead(.{ .question = question });
        return error.PageRead;
    }

    fn keepRead(self: *RequestPage, read: Read) void {
        const exchange = self.page.?.exchange();
        exchange.* = read;
        self.read = exchange;
    }

    fn answered(self: *const RequestPage) bool {
        const read = self.read orelse return false;
        return read.answer != null;
    }

    fn corrupt(self: *RequestPage) error{PageRead} {
        self.keepRead(.{ .question = .corrupt });
        return error.PageRead;
    }

    pub fn open(self: *RequestPage, binding: AttemptBinding) void {
        self.* = .{ .binding = binding };
    }

    pub fn nextEntryStep(self: *RequestPage, after_position: u64, bytes_left: *usize, items_left: *usize) !EntryProgress {
        std.debug.assert(self.active and self.outputs_validated);
        if (bytes_left.* == 0 or items_left.* == 0) return .pending;
        items_left.* -= 1;
        try self.allocatePage();
        _ = try self.coverage();
        return (try self.ask(.{ .entry = after_position })).entry;
    }

    pub fn nextDeclaredTool(self: *RequestPage, declaration: *Declaration, out: *HistoricalTool) !bool {
        std.debug.assert(self.active and self.output_frontier != null);
        const walk: Page.ToolWalk = .{ .set = declaration.tool_set_id, .position = declaration.position };
        const row = try self.toolFrom(walk, declaration.next_ordinal) orelse return false;
        if (row.owner == .provider) return self.corrupt();
        declaration.next_ordinal = row.ordinal + 1;
        return self.serveTool(row, out);
    }

    pub fn expectTools(self: *RequestPage, ahead: ToolsAhead) void {
        std.debug.assert(self.active and self.tool_set_id != 0);
        self.ahead = ahead;
    }

    fn aheadWalk(self: *const RequestPage) ?Page.ToolWalk {
        return switch (self.ahead) {
            .none => null,
            .declared => if (self.output_frontier == null) null else .{ .set = self.tool_set_id, .position = self.output_boundary },
            .all => if (self.tool_count == 0) null else .{ .set = self.tool_set_id, .position = 0 },
        };
    }

    fn toolFrom(self: *RequestPage, walk: Page.ToolWalk, ordinal: u64) !?*const Page.Tool {
        try self.allocatePage();
        const page = self.page.?;
        if (!page.toolsReach(walk, ordinal)) {
            self.keepRead(.{ .question = .{ .tools = .{ .walk = walk, .ordinal = ordinal } } });
            return error.PageRead;
        }
        return page.toolAt(ordinal);
    }

    fn serveTool(self: *RequestPage, row: *const Page.Tool, out: *HistoricalTool) !bool {
        if (row.description_private or row.schema_private) return self.corrupt();
        out.name = row.name;
        out.owner = row.owner;
        out.description = .{ .view = self, .content_id = @intCast(row.description_content_id.get()), .length = row.description_length, .digest = row.description_digest };
        out.input_schema = .{ .view = self, .content_id = @intCast(row.schema_content_id.get()), .length = row.schema_length, .digest = row.schema_digest };
        return true;
    }

    pub fn currentDeclaration(self: *const RequestPage) Declaration {
        std.debug.assert(self.tool_set_id != 0 and self.output_boundary != 0);
        return .{ .tool_set_id = self.tool_set_id, .position = self.output_boundary };
    }

    pub fn nextProviderTool(self: *RequestPage, out: *HistoricalTool) !bool {
        std.debug.assert(self.active and self.tool_set_id != 0);
        if (self.provider_tools_read == self.provider_tool_count) return false;
        _ = try self.ask(.{ .provider_tool = out });
        self.provider_tools_read += 1;
        return true;
    }

    pub fn nextTool(self: *RequestPage, out: *HistoricalTool) !bool {
        std.debug.assert(self.active and self.tool_set_id != 0);
        if (self.next_tool == self.tool_count) return false;
        const row = try self.toolFrom(.{ .set = self.tool_set_id, .position = 0 }, self.next_tool) orelse
            return self.corrupt();
        if (row.ordinal != self.next_tool) return self.corrupt();
        self.next_tool += 1;
        return self.serveTool(row, out);
    }

    pub fn settings(self: *RequestPage, out: *HistoricalSettings) !void {
        std.debug.assert(self.active);
        try self.allocatePage();
        _ = try self.ask(.{ .settings = out });
    }

    pub fn validateOutputsStep(self: *RequestPage) !bool {
        std.debug.assert(self.active);
        if (self.outputs_validated and !self.answered()) return true;
        return (try self.ask(.outputs_step)).outputs_step;
    }

    pub fn coverage(self: *RequestPage) !Coverage {
        std.debug.assert(self.active and self.outputs_validated);
        if (self.selected_base != 0 and self.anchor == null) return self.corrupt();
        return .{ .frontier = self.output_frontier.?, .anchor = self.anchor, .floor = self.floor };
    }

    pub fn prefixSeal(self: *RequestPage) !?PrefixSeal {
        std.debug.assert(self.active);
        return (try self.ask(.prefix_seal)).prefix_seal;
    }

    pub fn recordPrefixSeal(self: *RequestPage, seal: *const PrefixSeal) !void {
        std.debug.assert(self.active);
        _ = try self.ask(.{ .record_seal = seal.* });
    }

    pub fn admissionPosition(self: *const RequestPage) u64 {
        std.debug.assert(self.active and self.outputs_validated);
        return self.output_boundary;
    }

    pub fn toolGroupCursor(self: *const RequestPage) u64 {
        std.debug.assert(self.active);
        return self.tool_group_source_cursor;
    }

    pub fn resumeToolGroups(self: *RequestPage, cursor: u64) void {
        std.debug.assert(self.active and self.outputs_validated and !self.tool_group_initialized);
        if (self.read_ahead == .unclaimed) {
            if (self.tool_group_source_cursor == cursor) {
                self.read_ahead = .resumed;
                return;
            }
            dropReadAhead(self);
        }
        self.tool_group_source_cursor = cursor;
    }

    pub fn resumeKeys(self: *const RequestPage) Keys {
        std.debug.assert(self.active and self.output_frontier != null);
        return keysOf(self);
    }

    pub fn openOutput(self: *RequestPage, position: u64) !HistoricalOutput {
        std.debug.assert(self.active and self.output_parts == null);
        return outputAt(self, position) catch self.corrupt();
    }

    pub fn replayOutput(self: *RequestPage, entry: *const HistoricalEntry, model: []const u8) !?HistoricalOutput {
        const output = try self.openOutput(entry.position);
        if (output.kind.replayableTo(entry.requested_model.?.slice(), model, if (self.anchor == entry.position) .selected_base else .history)) return output;
        self.output_parts = null;
        return null;
    }

    pub fn nextOutputPart(self: *RequestPage) !?HistoricalPart {
        std.debug.assert(self.active and self.output_parts != null);
        if (partsExhausted(self)) {
            self.keepRead(.{ .question = .parts });
            return error.PageRead;
        }
        return nextPart(self) catch self.corrupt();
    }

    pub fn nextToolResult(self: *RequestPage) !?HistoricalToolResult {
        std.debug.assert(self.active);
        return (try self.ask(.tool_result)).tool_result;
    }

    pub fn openContent(self: *RequestPage, reference: HistoricalContent, out: *HistoricalReader) !void {
        std.debug.assert(reference.belongsTo(self));
        const first = reference.text_start orelse 0;
        out.* = .{
            .view = self,
            .reference = reference,
            .window = .of(reference.content_id, .{ .length = first + reference.length, .digest = reference.digest }),
        };
        out.window.first = first;
        out.window.check.verified = reference.verified or reference.text_start != null;
        if (self.pageBytes(reference)) |bytes| {
            out.window.inline_bytes = bytes;
            self.inline_readers += 1;
        }
        self.readers += 1;
    }

    fn allocatePage(self: *RequestPage) error{OutOfMemory}!void {
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

    fn pageBytes(self: *RequestPage, reference: HistoricalContent) ?[]const u8 {
        const page = self.page orelse return null;
        const whole = if (reference.text_start != null) self.output_parts.?.text.?.length else reference.length;
        return page.find(@intCast(reference.content_id), whole);
    }

    pub fn close(self: *RequestPage) void {
        std.debug.assert(self.active and self.readers == 0);
        if (self.page) |page| std.heap.c_allocator.rawFree(std.mem.asBytes(page), .of(Page), @returnAddress());
        self.page = null;
        self.active = false;
    }

    pub fn outstandingReaders(self: *const RequestPage) usize {
        return self.readers;
    }

    pub fn isActive(self: *const RequestPage) bool {
        return self.active;
    }

    pub fn ownsContent(self: *RequestPage, content: HistoricalContent) bool {
        return content.belongsTo(self);
    }

    pub fn bindingMatches(self: *const RequestPage, expected: AttemptBinding) bool {
        return self.binding.turn_id == expected.turn_id and
            self.binding.operation_id == expected.operation_id and
            self.binding.attempt_ordinal == expected.attempt_ordinal;
    }

    pub fn ownsSettings(self: *RequestPage, frozen: *const HistoricalSettings) bool {
        if (!self.ownsContent(frozen.baseline_instructions)) return false;
        if (frozen.output_schema) |schema| {
            if (!self.ownsContent(schema)) return false;
        }
        return true;
    }
};

pub const HistoricalReader = struct {
    window: ContentWindow = undefined,
    view: *RequestPage,
    reference: HistoricalContent,
    active: bool = true,

    pub fn usable(self: *const HistoricalReader) bool {
        return self.active and self.reference.belongsTo(self.view);
    }

    pub fn ownedBy(self: *const HistoricalReader, view: *RequestPage) bool {
        return self.view == view and self.usable();
    }

    pub fn read(self: *HistoricalReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.usable() and (self.view.answered() or self.window.check.verified or start == self.window.check.position));
        const base = self.reference.text_start orelse return self.readWindow(start, destination);
        const text = &self.view.output_parts.?.text.?;
        std.debug.assert(start <= self.reference.length and base + start == text.read);
        const wanted: usize = @intCast(@min(destination.len, self.reference.length - start));
        const count = try self.readWindow(base + start, destination[0..wanted]);
        text.hash.update(destination[0..count]);
        text.read += count;
        if (count != 0 and text.read == text.length and !std.mem.eql(u8, &text.hash.finalResult(), &text.digest))
            return self.view.corrupt();
        return count;
    }

    fn readWindow(self: *HistoricalReader, start: u64, destination: []u8) !usize {
        const count = try self.window.fills(start, destination);
        if (!self.window.copyInline(start, destination, count))
            return (try self.view.ask(.{ .content = .{ .reader = self, .start = start, .destination = destination } })).content;
        if (!self.window.absorb(start, destination[0..count])) return self.view.corrupt();
        return count;
    }

    pub fn close(self: *HistoricalReader) void {
        std.debug.assert(self.usable());
        if (self.window.inline_bytes != null) self.view.inline_readers -= 1;
        self.window.release();
        self.view.readers -= 1;
        self.active = false;
    }
};

pub const OutputItemKind = output_format.OutputItemKind;

const tool_columns = "member.ordinal,tool.name,tool.owner,tool.description_content_id,description.byte_length AS description_length," ++
    "description.digest AS description_digest,description.private AS description_private," ++ pageBytesSql("description", "description_bytes") ++ "," ++
    "tool.input_schema_content_id AS schema_content_id,input_schema.byte_length AS schema_length,input_schema.digest AS schema_digest," ++
    "input_schema.private AS schema_private," ++ pageBytesSql("input_schema", "schema_bytes") ++ " ";

const tool_texts = "JOIN content description ON description.content_id=tool.description_content_id " ++
    "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id ";

const ToolRow = struct {
    ordinal: u64,
    name: Bounded(tool_defs.max_name_bytes),
    owner: tool_defs.Owner,
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

const set_tools = rsql.Read(.{
    .sql = "SELECT " ++ tool_columns ++ "FROM " ++ declared_members_from ++ " " ++ tool_texts ++
        "WHERE member.tool_set_id=?1 AND member.ordinal>=?2 ORDER BY member.ordinal " ++ std.fmt.comptimePrint("LIMIT {d}", .{Page.tool_batch}),
    .Args = struct { set: u64, ordinal: u64 },
    .Row = ToolRow,
    .cardinality = .each,
});

const declared_tools = rsql.Read(.{
    .sql = "SELECT " ++ tool_columns ++ "FROM model_operation current JOIN " ++ declared_members_from ++ " " ++ tool_texts ++
        "WHERE current.operation_id=?1 AND member.ordinal>=?3 AND " ++ declared_members_where("?2", "?4", "?5") ++ " ORDER BY member.ordinal " ++
        std.fmt.comptimePrint("LIMIT {d}", .{Page.tool_batch}),
    .Args = struct { operation: u64, set: u64, ordinal: u64, position: u64, anchor: u64 },
    .Row = ToolRow,
    .cardinality = .each,
});

fn readTools(self: *Store, view: *RequestPage, walk: Page.ToolWalk, ordinal: u64) !void {
    return self.queue().run(readToolsHeld, .{ self, view, walk, ordinal });
}

fn readToolsHeld(self: *Store, view: *RequestPage, walk: Page.ToolWalk, ordinal: u64) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, toolsFrom(&access, view, walk, ordinal));
}

fn toolsFrom(a: *ReadAccess, view: *RequestPage, walk: Page.ToolWalk, ordinal: u64) !void {
    const page = view.page.?;
    var tools: Page.Tools = undefined;
    page.queueTools(a, view, keysOf(view), &tools, walk, ordinal);
    store_access.runAs(a, error.CorruptStore) catch |err| {
        page.tools_walk = .{};
        return err;
    };
    page.tools_complete = page.tools_end < Page.tool_batch;
}

const historical_provider_tool = rsql.Read(.{
    .sql = "SELECT member.ordinal,tool.name FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE member.tool_set_id=?1 AND member.ordinal>=?2 AND tool.owner='provider' ORDER BY member.ordinal LIMIT 1",
    .Args = struct { set: u64, ordinal: u64 },
    .Row = struct { ordinal: u64, name: *Bounded(tool_defs.max_name_bytes) },
    .cardinality = .optional,
});

fn readProviderTool(self: *Store, view: *RequestPage, out: *HistoricalTool) !void {
    return self.queue().run(readProviderToolHeld, .{ self, view, out });
}

fn readProviderToolHeld(self: *Store, view: *RequestPage, out: *HistoricalTool) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, providerToolOf(&access, view, out));
}

fn providerToolOf(a: *ReadAccess, view: *RequestPage, out: *HistoricalTool) !void {
    var row: historical_provider_tool.Row = undefined;
    row.name = &out.name;
    var found: store_access.Found = undefined;
    a.readInto(historical_provider_tool, .{ .set = view.tool_set_id, .ordinal = view.next_tool }, &row, &found);
    try store_access.runAs(a, error.CorruptStore);
    if (!found.get()) return error.CorruptStore;
    view.next_tool = row.ordinal + 1;
    out.owner = .provider;
}

fn readHistoricalSettings(self: *Store, view: *RequestPage, out: *HistoricalSettings) !void {
    return self.queue().run(readHistoricalSettingsHeld, .{ self, view, out });
}

fn readHistoricalSettingsHeld(self: *Store, view: *RequestPage, out: *HistoricalSettings) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.attempt_binding, settingsOf(&access, view, out));
}

const historical_settings = rsql.Read(.{
    .sql = "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id,o.tool_set_id AS tool_set_id,tool_set.member_count," ++
        "(SELECT count(*) FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE member.tool_set_id=o.tool_set_id AND tool.owner='provider') AS provider_count,r.provider,o.session_ref,s.parent_ref,r.workspace,o.compaction_trigger,o.output_reservation," ++
        operation_effort.effectiveSql("o") ++ " AS reasoning_effort,(" ++ operation_effort.emittedSql("o") ++ ") AS effort_update,s.codec,s.codec_options IS NULL AS plain_codec,o.purpose," ++
        "(SELECT first.reasoning_effort FROM model_operation first JOIN session_revision first_revision ON first_revision.session_ref=first.session_ref AND first_revision.revision=first.settings_revision " ++
        "WHERE first.session_ref=o.session_ref AND first_revision.model=r.model ORDER BY first.admission_position LIMIT 1) AS starting_effort," ++ skills_domain.sourcesConsistentSql("o.session_ref", "catalog_required.position<o.admission_position") ++ " AS catalogs_consistent," ++
        "instructions.byte_length AS instructions_length,instructions.digest AS instructions_digest,instructions.private AS instructions_private," ++
        pageBytesSql("instructions", "instructions_bytes") ++ "," ++
        "output_schema.byte_length AS output_schema_length,output_schema.digest AS output_schema_digest,output_schema.private AS output_schema_private " ++
        "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref JOIN session_revision r ON r.session_ref=o.session_ref " ++
        "AND r.revision=o.settings_revision JOIN tool_set ON tool_set.tool_set_id=o.tool_set_id JOIN session_revision baseline ON baseline.session_ref=o.session_ref AND baseline.revision=1 " ++
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
        parent_ref: ?Bounded(session_id.max_reference_bytes),
        workspace: *Bounded(workspace_path.max_bytes),
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        effort_update: bool,
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
    .cardinality = .each,
});

fn settingsOf(a: *ReadAccess, view: *RequestPage, out: *HistoricalSettings) !void {
    var read: SettingsRead = .init(view, out, &a.store.selector);
    read.queue(a);
    try store_access.runNamed(a, .{.{ model_settlement_domain.attempt_standing, error.OperationReadFailed }}, error.CorruptStore);
    return read.settle();
}

pub const Start = struct {
    view: *RequestPage,
    settings: *HistoricalSettings,
    remembered: ?Remembered = null,

    pub const Remembered = struct {
        context: *anyopaque,
        of: *const fn (context: *anyopaque, session: []const u8) ?Resume,
    };

    pub fn open(start: Start, binding: AttemptBinding) bool {
        start.view.open(binding);
        start.view.allocatePage() catch return false;
        return true;
    }
};

pub const Resume = struct {
    after_position: u64,
    group_cursor: u64,
    keys: Keys,
    tool_set: u64,
    tools: RequestPage.ToolsAhead,
};

const ReadAhead = struct {
    from: Resume,
    groups: GroupRead = undefined,
    batch: BatchRead = undefined,

    fn queue(ahead: *ReadAhead, a: anytype, view: *RequestPage, admission_position: u64) void {
        const from = &ahead.from;
        view.tool_group_source_cursor = from.group_cursor;
        ahead.groups.queue(a, view, from.keys);
        const walk: ?Page.ToolWalk = switch (from.tools) {
            .none => null,
            .declared => .{ .set = from.tool_set, .position = admission_position },
            .all => .{ .set = from.tool_set, .position = 0 },
        };
        ahead.batch.queue(a, view, from.keys, walk, from.after_position);
    }

    fn settle(ahead: *const ReadAhead, view: *RequestPage) void {
        view.read_ahead = .unclaimed;
        const from = &ahead.from;
        const kept = std.meta.eql(from.keys, keysOf(view)) and kept: {
            ahead.groups.finish(view) catch break :kept false;
            ahead.batch.finish(null, view, from.after_position) catch break :kept false;
            break :kept true;
        };
        if (!kept) {
            ahead.batch.discard(view);
            return dropReadAhead(view);
        }
        view.tool_group_scan_after = from.after_position;
    }
};

pub const SettingsRead = struct {
    view: *RequestPage,
    out: *HistoricalSettings,
    selector: *const Bounded(store_path.max_bytes),
    standing: model_settlement_domain.attempt_standing.Result = undefined,
    decoded: *historical_settings.Row = undefined,
    count: reads_domain.RowCount = .{},
    first: bool,
    boundary: reads_domain.First(output_boundary.Row) = .{},
    sources: OutputSources,
    ahead: ?ReadAhead = null,
    admission_position: u64 = 0,

    pub fn init(view: *RequestPage, out: *HistoricalSettings, selector: *const Bounded(store_path.max_bytes)) SettingsRead {
        return .{ .view = view, .out = out, .selector = selector, .first = view.output_frontier == null, .sources = .{ .view = view } };
    }

    pub fn readAhead(read: *SettingsRead, start: Start, session: []const u8, admission_position: u64) void {
        std.debug.assert(read.first);
        const remembered = start.remembered orelse return;
        const from = remembered.of(remembered.context, session) orelse return;
        read.ahead = .{ .from = from };
        read.admission_position = admission_position;
    }

    pub fn queue(read: *SettingsRead, a: anytype) void {
        const view = read.view;
        const row = view.page.?.decoded(historical_settings.Row);
        row.model = &read.out.model;
        row.session_ref = &read.out.session;
        row.workspace = &read.out.workspace;
        read.decoded = row;
        model_settlement_domain.queueAttemptKind(a, view.binding, &read.standing);
        reads_domain.readRow(a, historical_settings, .{ .operation = view.binding.operation_id }, read);
        if (read.first) {
            a.readEach(output_boundary, .{ .operation = view.binding.operation_id }, 1, &read.boundary);
            a.readEach(first_output_sources, .{ .operation = view.binding.operation_id }, output_source_page, &read.sources);
        }
        if (read.ahead) |*ahead| ahead.queue(a, view, read.admission_position);
    }

    pub fn followed(read: *SettingsRead) void {
        read.settle() catch return;
        read.view.keepRead(.{ .question = .{ .settings = read.out }, .answer = .settings });
    }

    pub fn visit(read: *SettingsRead, row: *const historical_settings.Row) bool {
        return reads_domain.visitRow(read, row);
    }

    pub fn keep(read: *SettingsRead, row: *const historical_settings.Row) error{CorruptStore}!void {
        const view = read.view;
        const out = read.out;
        const page = view.page.?;
        if (!row.catalogs_consistent) return error.CorruptStore;
        page.keep(.batch, row.instructions_content_id, &row.instructions_bytes);
        if (row.member_count > tool_defs.max_tools or row.provider_count > row.member_count) return error.CorruptStore;
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
        out.store = read.selector.*;
        out.parent = row.parent_ref;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("rui/session-affinity/v1");
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, read.selector.len, .big);
        hash.update(&length);
        hash.update(read.selector.slice());
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
        out.effort_update = row.effort_update;
        out.starting_effort = row.starting_effort;
        out.provider = row.provider;
        out.codec = std.meta.stringToEnum(provider_name.Codec, row.codec.slice()) orelse return error.CorruptStore;
        if (!row.plain_codec) return error.CorruptStore;
        out.session_affinity = hash.finalResult()[0..16].*;
    }

    pub fn settle(read: *SettingsRead) !void {
        const view = read.view;
        _ = try model_settlement_domain.attemptKindOf(read.standing, view.binding);
        if (!try read.count.found()) return error.CorruptStore;
        if (read.first) {
            try read.sources.finish();
            try keepOutputBoundary(view, &(read.boundary.row orelse return error.CorruptStore));
        }
        if (read.ahead) |*ahead| ahead.settle(view);
    }
};

pub noinline fn readPage(self: *Store, page: *RequestPage) !void {
    const read = page.read.?;
    std.debug.assert(read.answer == null);
    const question = read.question;
    errdefer page.keepRead(.{ .question = question });
    const answer: RequestPage.Answer = switch (question) {
        .settings => |out| answer: {
            try readHistoricalSettings(self, page, out);
            break :answer .settings;
        },
        .outputs_step => .{ .outputs_step = try validateHistoricalOutputsStep(self, page) },
        .entry => |after_position| .{ .entry = readHistoricalEntry(self, page, after_position) catch |err| switch (err) {
            error.HistoricalPending => .pending,
            else => return err,
        } },
        .parts => {
            try readHistoricalParts(self, page);
            page.read = null;
            return;
        },
        .tool_result => .{ .tool_result = try readHistoricalToolResult(self, page) },
        .tools => |tools| {
            try readTools(self, page, tools.walk, tools.ordinal);
            page.read = null;
            return;
        },
        .provider_tool => |out| answer: {
            try readProviderTool(self, page, out);
            break :answer .provider_tool;
        },
        .prefix_seal => .{ .prefix_seal = try readPrefixSeal(self, page.binding) },
        .record_seal => |*seal| answer: {
            try self.recordPrefixSeal(page.binding, seal);
            break :answer .record_seal;
        },
        .content => |content| .{ .content = try content_domain.readContent(self, &content.reader.window, content.start, content.destination) },
        .corrupt => return store_core.fence(self, error.CorruptStore),
    };
    page.keepRead(.{ .question = question, .answer = answer });
}

fn readHistoricalEntry(self: *Store, view: *RequestPage, after_position: u64) !RequestPage.EntryProgress {
    return self.queue().run(readHistoricalEntryHeld, .{ self, view, after_position });
}

fn readHistoricalEntryHeld(self: *Store, view: *RequestPage, after_position: u64) !RequestPage.EntryProgress {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return .{ .ready = try entry.finish(Ordinary.historical_entry, entryAfter(&access, view, after_position)) };
}

fn validateHistoricalOutputsStep(self: *Store, view: *RequestPage) !bool {
    return self.queue().run(validateHistoricalOutputsStepHeld, .{ self, view });
}

fn validateHistoricalOutputsStepHeld(self: *Store, view: *RequestPage) !bool {
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

const session_prefix_seal = rsql.Read(.{
    .sql = "SELECT s.prefix_seal,o.admission_position FROM model_operation o JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { prefix_seal: ?[prefix_seal.encoded_bytes]u8, admission_position: rsql.Positive },
    .cardinality = .one,
});

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

pub fn prefixSealOf(a: *ReadAccess, binding: AttemptBinding) !?PrefixSeal {
    var row: session_prefix_seal.Row = undefined;
    a.read(session_prefix_seal, .{ .operation = binding.operation_id }, &row);
    try store_access.runAs(a, error.CorruptStore);
    const bytes = row.prefix_seal orelse return null;
    const seal = try PrefixSeal.decode(&bytes);
    if (seal.admission_position > row.admission_position.get()) return seal;
    var identity: seal_model.Row = undefined;
    a.read(seal_model, .{ .operation = binding.operation_id, .admission = seal.admission_position }, &identity);
    try store_access.runAs(a, error.CorruptStore);
    return if (identity.same_model) seal else null;
}

const record_prefix_seal = rsql.Write(.{
    .sql = "UPDATE session SET prefix_seal=?2 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, seal: [prefix_seal.encoded_bytes]u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const RecordSeal = struct {
    pub const rounds = transition.rounds(.{ .attempt = .{ .always, error.OperationReadFailed } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .attempt;
    pub const Input = struct { binding: AttemptBinding, seal: *const PrefixSeal };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.attempt_binding;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    attempt: model_settlement_domain.AttemptSession = .{},

    pub fn step(t: *RecordSeal, r: *transition.Round(RecordSeal), ran: ?rounds.At) !transition.Next(RecordSeal) {
        if (ran == null) {
            t.attempt.queue(r, t.input.binding);
            return .{ .round = .attempt };
        }
        const session = try t.attempt.session(t.input.binding);
        r.write(record_prefix_seal, .{ .session = session, .seal = t.input.seal.encode() });
        return .commit;
    }

    pub fn committed(_: *const RecordSeal) Result {}
};

pub fn newestBaseSql(comptime session: []const u8, comptime boundary: []const u8) []const u8 {
    return "(SELECT selected.operation_id FROM model_operation selected @index(model_operation_compaction_bases) " ++
        "WHERE selected.session_ref=" ++ session ++ " AND selected.purpose=1 AND " ++
        store_schema.resolutionIs("selected.resolution_code", .compacted) ++ " AND selected.admission_position<" ++ boundary ++
        " ORDER BY selected.admission_position DESC LIMIT 1)";
}
const selected_base_sql = newestBaseSql("current.session_ref", "current.admission_position");

pub fn effortBeforeSql(comptime session: []const u8, comptime boundary: []const u8, comptime model: []const u8, comptime own_floor: []const u8, comptime first_effort: []const u8) []const u8 {
    const floor = replay_recipe.Recipe.floorSql(model, "effort_base_model.model", "effort_base.history_floor", own_floor);
    const anchor = replay_recipe.Recipe.anchorSql(model, "effort_base_model.model", "(SELECT min(anchor.session_position) FROM model_output_item anchor WHERE anchor.operation_id=effort_base.operation_id AND anchor.session_ref=" ++ session ++ " AND anchor.item_kind=4)");
    return "(SELECT CASE WHEN retained.operation_id IS NOT NULL THEN " ++ operation_effort.effectiveSql("retained") ++ " WHEN first_effort.operation_id IS NOT NULL THEN first_effort.reasoning_effort ELSE " ++ first_effort ++ " END FROM session effort_seed " ++
        "LEFT JOIN model_operation effort_base ON effort_base.operation_id=" ++ newestBaseSql(session, boundary) ++ " AND effort_base.session_ref=" ++ session ++ " " ++
        "LEFT JOIN session_revision effort_base_model ON effort_base_model.session_ref=effort_base.session_ref AND effort_base_model.revision=effort_base.settings_revision " ++
        "LEFT JOIN model_operation retained ON retained.operation_id=(SELECT earlier.operation_id FROM model_operation earlier @index(model_operation_admission) JOIN session_revision earlier_model ON earlier_model.session_ref=earlier.session_ref AND earlier_model.revision=earlier.settings_revision WHERE earlier.session_ref=" ++ session ++ " AND earlier.admission_position<" ++ boundary ++ " AND earlier_model.model=" ++ model ++ " AND earlier.admission_position>" ++ floor ++ " AND earlier.admission_position>=" ++ anchor ++ " ORDER BY earlier.admission_position DESC LIMIT 1) AND retained.session_ref=" ++ session ++ " " ++
        "LEFT JOIN model_operation first_effort ON first_effort.operation_id=(SELECT first.operation_id FROM model_operation first @index(model_operation_admission) JOIN session_revision first_model ON first_model.session_ref=first.session_ref AND first_model.revision=first.settings_revision WHERE first.session_ref=" ++ session ++ " AND first_model.model=" ++ model ++ " AND first.admission_position<" ++ boundary ++ " ORDER BY first.admission_position LIMIT 1) AND first_effort.session_ref=" ++ session ++ " WHERE effort_seed.session_ref=" ++ session ++ ")";
}

const base_anchors_from = "FROM model_output_item anchor @index(model_output_compaction_anchor) ";
const base_anchors_where = "WHERE anchor.operation_id=base.operation_id AND anchor.item_kind=4";

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

const output_source = rsql.Read(.{
    .sql = "SELECT " ++ outputSourceColumns("?4") ++
        "FROM model_operation current JOIN model_operation source @index(model_operation_context_history) ON source.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND source.admission_position>=?2 AND (source.admission_position>?3 OR (source.admission_position=?3 AND source.operation_id>?5)) " ++
        "AND source.admission_position<?4 AND " ++ store_schema.oneOf("source.resolution_code", &accepted_resolutions) ++ " " ++ output_source_order,
    .Args = struct { operation: u64, from: u64, after_position: u64, boundary: u64, after_operation: u64 },
    .Row = OutputSourceRow,
    .cardinality = .each,
});

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

const output_source_page = 256;

const OutputSources = struct {
    view: *RequestPage,
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

    fn finish(page: *const OutputSources) error{CorruptStore}!void {
        if (page.corrupt) return error.CorruptStore;
        page.view.outputs_validated = page.rows < output_source_page;
    }
};

fn keepOutputBoundary(view: *RequestPage, row: *const output_boundary.Row) error{CorruptStore}!void {
    view.output_boundary = row.admission_position.get();
    view.selected_base = if (row.operation_id) |id| id.get() else 0;
    view.output_frontier = row.frontier;
    view.anchor = if (row.anchors == 1 and row.anchor_bags == 1) (row.anchor_position orelse return error.CorruptStore).get() else null;
    if (view.selected_base != 0 and view.anchor == null) return error.CorruptStore;
    const recipe = replay_recipe.Recipe.select(row.current_model.slice(), if (row.operation_id != null) .{
        .position = row.frontier,
        .floor = if (row.base_floor) |floor| floor.get() else 0,
        .model = (row.base_model orelse return error.CorruptStore).slice(),
    } else null, if (row.own_floor) |floor| floor.get() else 0);
    const compatible = (view.selected_base != 0) == (recipe.frontier != 0);
    if (!compatible) {
        view.selected_base = 0;
        view.output_frontier = 0;
        view.anchor = null;
        view.output_cursor = 0;
        view.output_cursor_id = 0;
        view.outputs_validated = false;
    }
    const base_floor: u64 = if (compatible) (if (row.base_floor) |floor| floor.get() else 0) else 0;
    const own_floor: u64 = if (row.own_floor) |floor| floor.get() else 0;
    if (own_floor != 0 and own_floor < base_floor) return error.CorruptStore;
    view.floor = .{
        .position = recipe.floor,
        .first_message = row.first_message,
        .own = own_floor > base_floor,
    };
}

fn checkOutputsStep(a: *ReadAccess, view: *RequestPage) !bool {
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

fn entryAfter(a: *ReadAccess, view: *RequestPage, after_position: u64) !?*const HistoricalEntry {
    std.debug.assert(view.outputs_validated and view.active_tool_group_source_id == null);
    if (view.read_ahead != .none) {
        const from_cursor = view.read_ahead == .resumed or view.tool_group_source_cursor == 0;
        if (from_cursor and view.tool_group_scan_after == after_position) view.read_ahead = .none else dropReadAhead(view);
    }
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
    if (ordinary.source_action) |source| {
        const final = try action_read_domain.readResolution(a, source.session.slice(), source.id);
        const reference = if (ordinary.content) |*value| value else return error.CorruptStore;
        if (reference.content_id != final.location.content_id or reference.length != final.location.reference.length or
            !std.mem.eql(u8, &reference.digest, &final.location.reference.digest)) return error.CorruptStore;
    }
    return ordinary;
}

const historical_entries = rsql.Read(.{
    .sql = "SELECT e.session_position,CASE WHEN e.entry_kind=4 THEN 5 ELSE e.entry_kind END AS entry_kind,e.content_id," ++ historical_content_columns_sql ++ ",NULL AS model,NULL AS provider,NULL AS item_kind,NULL AS item_id_digest,(e.source_catalog_position IS NULL OR " ++ skills_domain.instructionConsistentSql("e") ++ ") AS consistent," ++
        "(SELECT m.sender_session_ref FROM message_admission m WHERE e.entry_kind=1 AND m.admission_id=e.source_admission_id) AS sender,(SELECT m.source_action_id FROM message_admission m WHERE e.entry_kind=1 AND m.admission_id=e.source_admission_id) AS source_action,e.session_ref AS source_session,NULL AS effort," ++
        "NULL AS tool_set_id,NULL AS declares," ++ pageBytesSql("content", "bytes") ++ " " ++
        "FROM model_operation current JOIN conversation_entry e ON e.session_ref=current.session_ref " ++
        "LEFT JOIN content ON content.content_id=e.content_id " ++
        "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<current.admission_position " ++
        "AND e.entry_kind IN (1,2,4) AND (e.entry_kind=2 OR e.session_position>?3 OR e.session_position=?4" ++
        " OR " ++ history_floor_domain.firstMessageSkillSql("e", "?4") ++ ") UNION ALL " ++
        "SELECT item.session_position,3,NULL,NULL,NULL,NULL,NULL,r.model,r.provider,item.item_kind,item.item_id_digest," ++
        store_schema.oneOf("owner.resolution_code", &accepted_resolutions) ++ " AND owner.session_ref=item.session_ref " ++
        "AND owner_turn.session_ref=item.session_ref " ++
        "AND owner.attempt_ordinal=item.attempt_ordinal AND owner.admission_position<item.session_position " ++
        "AND owner.admission_position<current.admission_position AND " ++
        "(item.item_kind!=3 OR " ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ") AND " ++
        "((" ++ store_schema.resolutionIs("owner.resolution_code", .tool_proposals) ++ ")=EXISTS(SELECT 1 FROM model_tool_call tool_call WHERE tool_call.operation_id=owner.operation_id)),NULL,NULL,NULL,NULL,NULL,NULL,NULL " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
        "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
        "LEFT JOIN turn owner_turn ON owner_turn.turn_id=owner.turn_id " ++
        "LEFT JOIN session_revision r ON r.session_ref=owner.session_ref AND r.revision=owner.settings_revision " ++
        "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position " ++
        "AND " ++ servedItemSql("?3", "?5") ++ " UNION ALL " ++
        "SELECT earlier.admission_position,4,NULL,NULL,NULL,NULL,NULL,revision.model,NULL,NULL,NULL,NULL,NULL,NULL,NULL," ++ operation_effort.effectiveSql("earlier") ++ ",earlier.tool_set_id," ++
        "EXISTS(SELECT 1 FROM " ++ declared_members_from ++ " WHERE " ++ declared_members_where("earlier.tool_set_id", "earlier.admission_position", "?6") ++ "),NULL " ++
        "FROM model_operation current JOIN model_operation earlier ON earlier.session_ref=current.session_ref " ++
        "JOIN session_revision revision ON revision.session_ref=earlier.session_ref AND revision.revision=earlier.settings_revision " ++
        "WHERE current.operation_id=?1 AND earlier.admission_position>?2 AND earlier.admission_position<current.admission_position " ++
        "AND (earlier.admission_position>?3 OR earlier.operation_id=?5) " ++
        std.fmt.comptimePrint("ORDER BY 1 LIMIT {d}", .{RequestPage.entry_batch}),
    .Args = struct { operation: u64, after: u64, floor: u64, first_message: u64, base: u64, anchor: u64 },
    .Row = struct {
        session_position: rsql.Positive,
        entry_kind: u8,
        content_id: ?rsql.Positive,
        byte_length: ?u64,
        digest: ?[32]u8,
        private: ?bool,
        form: ?u8,
        model: ?Bounded(model_capability.max_model_bytes),
        provider: ?provider_name.Provider,
        item_kind: ?u8,
        item_id_digest: ?[32]u8,
        consistent: ?bool,
        sender: ?Bounded(session_id.max_reference_bytes),
        source_action: ?rsql.Positive,
        source_session: ?Bounded(session_id.bytes),
        effort: ?model_capability.ReasoningEffort,
        tool_set_id: ?rsql.Positive,
        declares: ?bool,
        bytes: ?Page.Bytes,
    },
    .cardinality = .each,
    .compound = true,
});

fn declarationAnchor(keys: Keys) u64 {
    const anchor = keys.anchor orelse 0;
    return if (keys.floor == 0) anchor else @max(anchor, keys.floor + 1);
}

pub const Keys = struct {
    floor: u64 = 0,
    first_message: u64 = 0,
    base: u64 = 0,
    anchor: ?u64 = null,
};

fn keysOf(view: *const RequestPage) Keys {
    return .{ .floor = view.floor.position, .first_message = view.floor.first_message, .base = view.selected_base, .anchor = view.anchor };
}

fn dropReadAhead(view: *RequestPage) void {
    if (view.read_ahead == .unclaimed) view.tool_group_source_cursor = 0;
    view.read_ahead = .none;
    view.group_scan = .{};
    view.entries_end = 0;
    view.entries_done_after = null;
    GroupRead.discard(view);
}

const declared_members_from = "tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id";

fn declared_members_where(comptime set: []const u8, comptime position: []const u8, comptime anchor: []const u8) []const u8 {
    return "member.tool_set_id=" ++ set ++ " AND tool.owner!='provider' AND member.tool_record_id NOT IN (" ++
        "SELECT previous_member.tool_record_id FROM tool_set_member previous_member WHERE previous_member.tool_set_id=coalesce((" ++
        "SELECT previous.tool_set_id FROM model_operation previous " ++
        "WHERE previous.session_ref=current.session_ref AND previous.admission_position<" ++ position ++
        " AND previous.admission_position>=" ++ anchor ++ " ORDER BY previous.admission_position DESC LIMIT 1),0))";
}

const EntryBatch = struct {
    view: *RequestPage,
    decoded: *historical_entries.Row,
    failure: ?error{CorruptStore} = null,
    unsupported: ?content_domain.Value = null,

    pub fn visit(batch: *EntryBatch, row: *const historical_entries.Row) bool {
        const view = batch.view;
        if (row.form) |form| {
            if (form == 1) {
                if (row.private != false or row.content_id == null or row.byte_length == null or row.digest == null) {
                    batch.failure = error.CorruptStore;
                } else {
                    batch.unsupported = content_domain.Value.of(row.content_id.?.get(), form, row.byte_length.?, row.digest.?) catch {
                        batch.failure = error.CorruptStore;
                        return false;
                    };
                }
                return false;
            }
            if (form != 0) {
                batch.failure = error.CorruptStore;
                return false;
            }
        }
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

fn bufferedEntry(view: *RequestPage, after_position: u64) ?*const HistoricalEntry {
    while (view.entries_next < view.entries_end) : (view.entries_next += 1) {
        if (view.entries[view.entries_next].position > after_position) return &view.entries[view.entries_next];
    }
    return null;
}

fn needsBatch(view: *RequestPage, after_position: u64) bool {
    if (bufferedEntry(view, after_position) != null) return false;
    return if (view.entries_done_after) |last| after_position < last else true;
}

fn batchLast(view: *const RequestPage) u64 {
    return if (view.entries_end == RequestPage.entry_batch) view.entries[view.entries_end - 1].position else std.math.maxInt(u64);
}

const BatchRead = struct {
    entries: EntryBatch,
    sources: historical_catalog_sources.Row,
    items: Page.Items,
    parts: Page.Parts,
    tools: Page.Tools,
    ahead: bool,

    const corrupt = .{
        .{ page_items, error.CorruptStore },
        .{ page_parts, error.CorruptStore },
        .{ declared_tools, error.CorruptStore },
        .{ set_tools, error.CorruptStore },
    };

    fn queue(read: *BatchRead, a: anytype, view: *RequestPage, keys: Keys, walk: ?Page.ToolWalk, after_position: u64) void {
        const page = view.page.?;
        view.entries_next = 0;
        view.entries_end = 0;
        view.entries_done_after = null;
        if (view.inline_readers == 0) page.batch.count = 0;
        page.items_end = 0;
        const operation = view.binding.operation_id;
        read.entries = .{ .view = view, .decoded = page.decoded(historical_entries.Row) };
        a.read(historical_catalog_sources, .{ .operation = operation }, &read.sources);
        a.readEach(historical_entries, .{
            .operation = operation,
            .after = after_position,
            .floor = keys.floor,
            .first_message = keys.first_message,
            .base = keys.base,
            .anchor = declarationAnchor(keys),
        }, RequestPage.entry_batch, &read.entries);
        read.items = .{ .view = view, .decoded = page.decoded(page_items.Row) };
        a.readEach(page_items, .{ .operation = operation, .after = after_position, .floor = keys.floor, .base = keys.base }, RequestPage.entry_batch, &read.items);
        page.queueParts(a, view, keys, &read.parts, after_position + 1, 0);
        read.ahead = if (walk) |wanted| !page.toolsReach(wanted, 0) else false;
        if (read.ahead) page.queueTools(a, view, keys, &read.tools, walk.?, 0);
    }

    fn discard(read: *const BatchRead, view: *RequestPage) void {
        view.entries_end = 0;
        if (read.ahead) view.page.?.tools_walk = .{};
    }

    fn finish(read: *const BatchRead, a: ?*ReadAccess, view: *RequestPage, after_position: u64) !void {
        errdefer read.discard(view);
        const page = view.page.?;
        if (!read.sources.consistent) return error.CorruptStore;
        if (read.entries.failure) |err| return err;
        if (read.entries.unsupported) |value| {
            const access = a orelse return error.CorruptStore;
            try @import("content_parts.zig").verify(access, value);
            return error.InputPartsNotSupported;
        }
        if (view.entries_end < RequestPage.entry_batch)
            view.entries_done_after = if (view.entries_end == 0) after_position else view.entries[view.entries_end - 1].position;
        page.parts_complete = read.parts.past or page.parts_end < Page.part_batch;
        if (read.ahead) page.tools_complete = page.tools_end < Page.tool_batch;
    }
};

fn nextOrdinaryHistoricalEntry(a: *ReadAccess, view: *RequestPage, after_position: u64) !?*const HistoricalEntry {
    if (!needsBatch(view, after_position)) return bufferedEntry(view, after_position);
    var read: BatchRead = undefined;
    read.queue(a, view, keysOf(view), view.aheadWalk(), after_position);
    store_access.runNamed(a, BatchRead.corrupt, error.HistoricalEntryReadFailed) catch |err| {
        read.discard(view);
        return err;
    };
    try read.finish(a, view, after_position);
    return if (view.entries_end == 0) null else &view.entries[0];
}

fn pageContentSql(comptime table: []const u8, comptime name: []const u8) []const u8 {
    return table ++ ".byte_length AS " ++ name ++ "_length," ++ table ++ ".digest AS " ++ name ++ "_digest," ++ table ++ ".private AS " ++ name ++ "_private," ++
        pageBytesSql(table, name ++ "_bytes");
}

fn pageBytesSql(comptime table: []const u8, comptime name: []const u8) []const u8 {
    return "CASE WHEN " ++ table ++ ".byte_length BETWEEN 1 AND " ++ std.fmt.comptimePrint("{d}", .{Page.inline_bytes}) ++ " THEN @payload(" ++ table ++ ") END AS " ++ name;
}

fn servedItemSql(comptime floor: []const u8, comptime base: []const u8) []const u8 {
    return "(owner.admission_position IS NULL OR owner.admission_position>" ++ floor ++ " OR owner.operation_id=" ++ base ++ ")";
}

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
        servedItemSql("?3", "?4") ++ " ORDER BY item.session_position " ++ std.fmt.comptimePrint("LIMIT {d}", .{RequestPage.entry_batch}),
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

const page_parts = rsql.Read(.{
    .sql = "WITH batch AS (SELECT item.operation_id,item.item_ordinal,item.session_position " ++
        "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
        "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
        "WHERE current.operation_id=?1 AND item.session_position>=?2 AND item.session_position<current.admission_position AND " ++
        servedItemSql("?4", "?5") ++ " ORDER BY item.session_position " ++ std.fmt.comptimePrint("LIMIT {d}", .{RequestPage.entry_batch}) ++ ") " ++
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

const Page = struct {
    row: [row_bytes]u8 align(row_align),
    items: [RequestPage.entry_batch]Item,
    items_end: usize,
    parts: [part_batch]Part,
    parts_next: usize,
    parts_end: usize,
    parts_complete: bool,
    tools: [tool_batch]Tool,
    tools_end: usize,
    tools_walk: ToolWalk,
    tools_from: u64,
    tools_complete: bool,
    groups: [group_batch]Group,
    groups_end: usize,
    groups_next: usize,
    results: [result_batch]Result,
    results_end: usize,
    results_next: usize,
    results_complete: bool,
    batch: Shelf(RequestPage.entry_batch * 6 + part_batch * 2 + 1),
    held: Shelf(tool_batch * 2),
    bytes: [arena_bytes]u8,

    const inline_bytes = 16 * 1024;
    const Bytes = rsql.Blob(inline_bytes);
    const part_batch = 32;
    const tool_batch = 16;
    const group_batch = 16;
    const call_batch = 64;
    const result_batch = 16;

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

    fn exchange(page: *Page) *RequestPage.Read {
        comptime std.debug.assert(@sizeOf(RequestPage.Read) <= row_bytes and @alignOf(RequestPage.Read) <= row_align);
        return @ptrCast(&page.row);
    }

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

    const ToolWalk = struct {
        set: u64 = 0,
        position: u64 = 0,
    };

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

    const Tool = struct {
        ordinal: u64,
        name: Bounded(tool_defs.max_name_bytes),
        owner: tool_defs.Owner,
        description_content_id: rsql.Positive,
        description_length: u64,
        description_digest: [32]u8,
        description_private: bool,
        schema_content_id: rsql.Positive,
        schema_length: u64,
        schema_digest: [32]u8,
        schema_private: bool,
    };

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
        output_form: ?u8,
    };

    fn store(page: *Page, comptime side: Side, row: anytype, out: anytype) void {
        const columns = @typeInfo(@TypeOf(row.*)).@"struct";
        const kept = @typeInfo(@TypeOf(out.*)).@"struct";
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

    fn free(page: *const Page) struct { start: usize, end: usize } {
        return .{
            .start = if (page.batch.count == 0) 0 else page.batch.stops[page.batch.count - 1],
            .end = if (page.held.count == 0) arena_bytes else page.held.stops[page.held.count - 1],
        };
    }

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
        view: *RequestPage,
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
        view: *RequestPage,
        decoded: *page_parts.Row,
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
            page.store(.batch, row, &page.results[page.results_end]);
            page.results_end += 1;
            return true;
        }
    };

    fn queueResults(page: *Page, a: *ReadAccess, view: *RequestPage, visitor: *Results) void {
        page.results_end = 0;
        page.results_next = 0;
        visitor.* = .{ .page = page, .decoded = page.decoded(group_results.Row) };
        a.readEach(group_results, .{
            .operation = view.binding.operation_id,
            .source = view.active_tool_group_source_id.?,
            .from = view.active_tool_group_count,
        }, result_batch, visitor);
    }

    fn queueParts(page: *Page, a: anytype, view: *RequestPage, keys: Keys, visitor: *Parts, first: u64, part: u64) void {
        page.parts_next = 0;
        page.parts_end = 0;
        page.parts_complete = false;
        visitor.* = .{ .view = view, .decoded = page.decoded(page_parts.Row) };
        a.readEach(page_parts, .{ .operation = view.binding.operation_id, .first = first, .part = part, .floor = keys.floor, .base = keys.base }, part_batch, visitor);
    }

    fn queueTools(page: *Page, a: anytype, view: *RequestPage, keys: Keys, visitor: *Tools, walk: ToolWalk, ordinal: u64) void {
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
                .anchor = declarationAnchor(keys),
            }, tool_batch, visitor);
    }

    fn toolsReach(page: *const Page, walk: ToolWalk, ordinal: u64) bool {
        if (page.tools_walk.set != walk.set or page.tools_walk.position != walk.position or ordinal < page.tools_from) return false;
        return page.tools_complete or page.toolAt(ordinal) != null;
    }

    fn toolAt(page: *const Page, ordinal: u64) ?*const Tool {
        for (page.tools[0..page.tools_end]) |*tool| {
            if (tool.ordinal >= ordinal) return tool;
        }
        return null;
    }
};

fn historicalEntry(view: *RequestPage, row: *const historical_entries.Row) error{CorruptStore}!HistoricalEntry {
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
        if (row.consistent != true) return error.CorruptStore;
        const model = row.model orelse return error.CorruptStore;
        if (model.len == 0 or row.provider == null or row.item_id_digest == null) return error.CorruptStore;
        _ = std.enums.fromInt(OutputItemKind, row.item_kind orelse return error.CorruptStore) orelse return error.CorruptStore;
        requested_model = model;
    } else {
        if (row.consistent != true) return error.CorruptStore;
        const content_id = row.content_id orelse return error.CorruptStore;
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
        .source_action = if (row.source_action) |action| .{ .id = action.get(), .session = row.source_session orelse return error.CorruptStore } else null,
        .content = content,
    };
}

fn activateHistoricalToolGroup(view: *RequestPage) !?*const HistoricalEntry {
    const entry = if (view.next_tool_group) |*value| value else return null;
    view.active_tool_group_source_id = view.next_tool_group_source_id orelse return error.CorruptStore;
    view.active_tool_group_count = 0;
    view.active_tool_group_expected = view.next_tool_group_count;
    view.page.?.results_end = 0;
    view.page.?.results_next = 0;
    view.page.?.results_complete = false;
    return entry;
}

const HistoricalToolGroup = struct {
    position: u64,
    source_operation_id: u64,
};

const group_sources_from = "FROM model_operation current JOIN model_operation source @index(model_operation_session_history) " ++
    "ON source.session_ref=current.session_ref WHERE current.operation_id=?1 AND source.operation_id>=?2 " ++
    "AND source.operation_id<current.operation_id AND source.admission_position>?3 AND " ++
    store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " ORDER BY source.operation_id LIMIT " ++
    std.fmt.comptimePrint("{d}", .{Page.group_batch});

const group_sources = rsql.Read(.{
    .sql = "SELECT " ++ outputSourceColumns("current.admission_position") ++ "," ++ reads_domain.expectedCallsSql("source.operation_id") ++ "," ++
        "(SELECT count(*) FROM model_tool_call called WHERE called.operation_id=source.operation_id) AS called " ++ group_sources_from,
    .Args = struct { operation: u64, from: u64, floor: u64 },
    .Row = struct { operation_id: rsql.Positive, admission_position: rsql.Positive, output_item_count: u64, purpose: u8, complete: bool, expected: u64, called: u64 },
    .cardinality = .each,
});

const group_calls = rsql.Read(.{
    .sql = "WITH sources AS (SELECT source.operation_id " ++ group_sources_from ++ ") " ++
        "SELECT sources.operation_id AS source,proposed.call_ordinal AS ordinal,item.item_ordinal,item.item_kind," ++
        "" ++ tool_fulfillment.positionSql("tool_call", "action") ++ " AS accepted_position," ++
        "CASE WHEN tool_call.rejection_code IS NOT NULL OR (" ++ tool_fulfillment.actionCompleteSql("action") ++ " AND " ++
        "action.session_ref=op.session_ref AND action.tool_kind=tool_call.action_kind) THEN 1 ELSE 0 END AS outcome_consistent," ++
        "result.private AS result_private," ++ reads_domain.proposal_columns ++ " " ++
        "FROM sources JOIN model_tool_call proposed ON proposed.operation_id=sources.operation_id " ++
        "LEFT JOIN model_output_item item ON item.operation_id=proposed.operation_id AND item.item_ordinal=proposed.item_ordinal " ++
        reads_domain.proposal_joins ++
        "LEFT JOIN content result ON result.content_id=" ++ tool_fulfillment.contentSql("tool_call", "action") ++ " " ++
        "WHERE sources.operation_id>?2 OR proposed.call_ordinal>=?4 " ++
        // Ordered by the page's sources, so MySQL reads the calls from
        // them and never walks every Session's calls in key order.
        "ORDER BY sources.operation_id,proposed.call_ordinal LIMIT " ++ std.fmt.comptimePrint("{d}", .{Page.call_batch}),
    .Args = struct { operation: u64, from: u64, floor: u64, call: u64 },
    .Row = GroupCallRow,
    .cardinality = .each,
});

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
    field_metadata: ?activity_read.FieldCertificate.Bytes,
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

const group_bounds = rsql.Read(.{
    .sql = "SELECT current.admission_position AS boundary," ++
        "(SELECT max(last.operation_id) FROM model_operation last @index(model_operation_session_history) " ++
        "WHERE last.session_ref=current.session_ref AND last.operation_id<current.operation_id) AS last_source " ++
        "FROM model_operation current WHERE current.operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct { boundary: rsql.Positive, last_source: ?rsql.Positive },
    .cardinality = .optional,
});

const GroupRead = struct {
    bounds: group_bounds.Result,
    sources: Sources,
    calls: Calls,

    const Sources = struct {
        view: *RequestPage,
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
        view: *RequestPage,
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

    const corrupt = .{
        .{ group_sources, error.CorruptStore },
        .{ group_calls, error.CorruptStore },
    };

    fn queue(read: *GroupRead, a: anytype, view: *RequestPage, keys: Keys) void {
        const page = view.page.?;
        const scan = &view.group_scan;
        page.groups_end = 0;
        page.groups_next = 0;
        const operation = view.binding.operation_id;
        const from = if (scan.source != 0) scan.source else view.tool_group_source_cursor + 1;
        read.sources = .{ .view = view };
        read.calls = .{ .view = view, .decoded = page.decoded(GroupCallRow) };
        a.read(group_bounds, .{ .operation = operation }, &read.bounds);
        a.readEach(group_sources, .{ .operation = operation, .from = from, .floor = keys.floor }, Page.group_batch, &read.sources);
        a.readEach(group_calls, .{ .operation = operation, .from = from, .floor = keys.floor, .call = scan.calls }, Page.call_batch, &read.calls);
    }

    fn discard(view: *RequestPage) void {
        view.page.?.groups_end = 0;
    }

    fn finish(read: *const GroupRead, view: *RequestPage) error{CorruptStore}!void {
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

fn readNextHistoricalToolGroup(a: *ReadAccess, view: *RequestPage, after_position: u64) !?HistoricalToolGroup {
    const page = view.page.?;
    const scan = &view.group_scan;
    if (page.groups_next == page.groups_end and !scan.done) {
        var groups: GroupRead = undefined;
        groups.queue(a, view, keysOf(view));
        var read: BatchRead = undefined;
        const rides = needsBatch(view, after_position);
        if (rides) read.queue(a, view, keysOf(view), view.aheadWalk(), after_position);
        store_access.runNamed(a, BatchRead.corrupt ++ GroupRead.corrupt, error.HistoricalEntryReadFailed) catch |err| {
            GroupRead.discard(view);
            if (rides) read.discard(view);
            return err;
        };
        const batch: anyerror!void = if (rides) read.finish(a, view, after_position) else {};
        try groups.finish(view);
        try batch;
        if (page.groups_end == 0 and !scan.done) return error.HistoricalPending;
    }
    if (page.groups_next == page.groups_end) {
        view.tool_group_source_cursor = @max(view.tool_group_source_cursor, scan.passed);
        return null;
    }
    const group = &page.groups[page.groups_next];
    page.groups_next += 1;
    view.next_tool_group_count = group.expected;
    return .{ .position = group.position, .source_operation_id = group.source };
}

fn pageMetadata(length: ?u64, digest: ?[32]u8, private: ?bool) error{CorruptStore}!content_metadata.Row {
    return .{
        .byte_length = length orelse return error.CorruptStore,
        .digest = digest orelse return error.CorruptStore,
        .private = private orelse return error.CorruptStore,
    };
}

fn outputAt(view: *RequestPage, position: u64) error{CorruptStore}!HistoricalOutput {
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
    var text: ?RequestPage.MessageText = null;
    if (row.message_content_id) |id| {
        const content = try viewContent(view, id.get(), &try pageMetadata(row.message_length, row.message_digest, row.message_private), false);
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

fn partsExhausted(view: *RequestPage) bool {
    const position = view.output_parts.?.position;
    const page = view.page.?;
    while (page.parts_next < page.parts_end and page.parts[page.parts_next].session_position.get() < position) page.parts_next += 1;
    return page.parts_next == page.parts_end and !page.parts_complete;
}

fn readHistoricalParts(self: *Store, view: *RequestPage) !void {
    return self.queue().run(readHistoricalPartsHeld, .{ self, view });
}

fn readHistoricalPartsHeld(self: *Store, view: *RequestPage) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(Ordinary.none, partsFrom(&access, view));
}

fn partsFrom(a: *ReadAccess, view: *RequestPage) !void {
    const cursor = &view.output_parts.?;
    const page = view.page.?;
    var parts: Page.Parts = undefined;
    page.queueParts(a, view, keysOf(view), &parts, cursor.position, cursor.next);
    try store_access.runAs(a, error.HistoricalEntryReadFailed);
    page.parts_complete = parts.past or page.parts_end < Page.part_batch;
}

fn nextPart(view: *RequestPage) error{CorruptStore}!?HistoricalPart {
    const cursor = &view.output_parts.?;
    const page = view.page.?;
    const row = if (page.parts_next < page.parts_end and page.parts[page.parts_next].session_position.get() == cursor.position)
        &page.parts[page.parts_next]
    else {
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
        .summary_text, .reasoning_text => if (row.text_length != null) return error.CorruptStore else try viewContent(
            view,
            (row.text_content_id orelse return error.CorruptStore).get(),
            &try pageMetadata(row.own_length, row.own_digest, row.own_private),
            true,
        ),
    };
    const bag = try viewBag(view, row.extras_content_id.get(), &try pageMetadata(row.bag_length, row.bag_digest, row.bag_private));
    if (kind == .opaque_block and bag == null) return error.CorruptStore;
    if (array != cursor.array) {
        if (cursor.closed[@backingInt(array) - 1]) return error.CorruptStore;
        if (cursor.array != .none) cursor.closed[@backingInt(cursor.array) - 1] = true;
        cursor.array = array;
    }
    cursor.next += 1;
    page.parts_next += 1;
    return .{ .array = array, .kind = kind, .text = text, .bag = bag };
}

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

fn viewBag(view: *RequestPage, content_id: u64, row: *const content_metadata.Row) !?HistoricalContent {
    const bag = try viewContent(view, content_id, row, true);
    return if (bag.length == 0) null else bag;
}

fn readHistoricalToolResult(
    self: *Store,
    view: *RequestPage,
) !?HistoricalToolResult {
    return self.queue().run(readHistoricalToolResultHeld, .{ self, view });
}

fn readHistoricalToolResultHeld(
    self: *Store,
    view: *RequestPage,
) !?HistoricalToolResult {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var access: ReadAccess = .open(&entry);
    defer access.deinit();
    return entry.finish(error{InputPartsNotSupported}, nextGroupResult(&access, view));
}

const group_results = rsql.Read(.{
    .sql = "SELECT tool_call.call_ordinal,tool_call.call_id_content_id,call_id.byte_length AS call_id_length,call_id.digest AS call_id_digest," ++
        "call_id.private AS call_id_private," ++ pageBytesSql("call_id", "call_id_bytes") ++ "," ++
        "output.content_id AS output_content_id,output.byte_length AS output_length,output.digest AS output_digest," ++
        "output.private AS output_private,output.form AS output_form," ++ pageBytesSql("output", "output_bytes") ++ " " ++
        "FROM model_operation current " ++
        "CROSS JOIN model_operation source ON source.operation_id=?2 AND source.session_ref=current.session_ref " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=source.operation_id LEFT JOIN action_operation action " ++
        "ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "LEFT JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "LEFT JOIN content output ON output.content_id=" ++ tool_fulfillment.contentSql("tool_call", "action") ++ " " ++
        "WHERE current.operation_id=?1 AND " ++ store_schema.resolutionIs("source.resolution_code", .tool_proposals) ++ " " ++
        "AND " ++ tool_fulfillment.positionSql("tool_call", "action") ++ "<current.admission_position " ++
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
        output_form: ?u8,
        output_bytes: ?Page.Bytes,
    },
    .cardinality = .each,
});

fn nextGroupResult(a: *ReadAccess, view: *RequestPage) !?HistoricalToolResult {
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
    const output_id = (row.output_content_id orelse return error.CorruptStore).get();
    var output_metadata = try pageMetadata(row.output_length, row.output_digest, row.output_private);
    output_metadata.form = row.output_form orelse return error.CorruptStore;
    _ = try @import("content_parts.zig").publicMetadata(a, output_id, &output_metadata);
    const output = try viewContent(view, output_id, &output_metadata, false);
    page.results_next += 1;
    view.active_tool_group_count += 1;
    return .{ .call_id = call_id, .output = output };
}

fn viewContent(view: *RequestPage, content_id: u64, row: *const content_metadata.Row, private: bool) error{CorruptStore}!HistoricalContent {
    if (row.private != private) return error.CorruptStore;
    return .{ .view = view, .content_id = @intCast(content_id), .length = row.byte_length, .digest = row.digest };
}
