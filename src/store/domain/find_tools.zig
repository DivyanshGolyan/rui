//! Loading saved tools is one call-keyed command, revision and resolution.
const std = @import("std");
const protocol = @import("../../protocol.zig");
const core = @import("../../core_tools.zig");
const tools = @import("../../tools.zig");
const rsql = @import("../rsql.zig");
const action = @import("action.zig");
const command = @import("command.zig");
const configuration = @import("configuration.zig");
const content = @import("content.zig");
const tool_set = @import("tool_set.zig");
const Faults = @import("../Store.zig").Faults;

const settings = rsql.Read(.{
    .sql = "SELECT revision,tool_set_id,coalesce(loaded_tool_set_id,tool_set_id) AS loaded_set FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { revision: rsql.Positive, tool_set_id: rsql.Positive, loaded_set: rsql.Positive },
    .cardinality = .one,
});

const matching_sql = blk: {
    var sql: []const u8 = "";
    for (0..4) |i| {
        const word = std.fmt.comptimePrint("?{d}", .{i + 3});
        sql = sql ++ (if (i == 0) "" else " OR ") ++ "(" ++ word ++ "<>'' AND (@contains_ascii(tool.name," ++ word ++ ") OR @content_contains_ascii(description.content_id," ++ word ++ ")))";
    }
    break :blk sql;
};

/// Walk saved records, never the Host's potentially newer catalog. SQL does
/// the matching; the ordered visitor keeps the first eight unloaded matches.
const candidates = rsql.Read(.{
    .sql = "SELECT tool.name,description.content_id,description.byte_length,description.digest," ++
        "EXISTS(SELECT 1 FROM tool_set_member loaded WHERE loaded.tool_set_id=?2 AND loaded.tool_record_id=tool.tool_record_id) AS loaded," ++
        "(" ++ matching_sql ++ ") AS matched FROM tool_set_member member " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { set: u64, loaded: u64, word0: []const u8, word1: []const u8, word2: []const u8, word3: []const u8 },
    .Row = struct { name: protocol.Bounded(tools.max_name_bytes), content_id: rsql.Positive, byte_length: u64, digest: [32]u8, loaded: bool, matched: bool },
    .cardinality = .each,
});

const Matches = struct {
    names: protocol.ToolsField = .{ .state = .value },
    rows: [protocol.max_tools]candidates.Row = undefined,
    selected: [8]usize = undefined,
    count: usize = 0,
    total: usize = 0,
    cursor: usize = 0,
    remaining: usize = 0,
    invalid: bool = false,

    pub fn visit(self: *Matches, row: *const candidates.Row) bool {
        if (self.cursor == self.rows.len) {
            self.invalid = true;
            return false;
        }
        if (self.cursor < self.total) {
            const saved = &self.rows[self.cursor];
            if (!saved.name.eql(row.name.slice())) {
                self.invalid = true;
                return false;
            }
            saved.matched = saved.matched or row.matched;
        } else {
            self.rows[self.cursor] = row.*;
            self.total += 1;
        }
        self.cursor += 1;
        return true;
    }

    fn select(self: *Matches) !void {
        if (self.invalid or self.cursor != self.total) return error.CorruptStore;
        for (self.rows[0..self.total], 0..) |*row, index| {
            const load = !row.loaded and row.matched and self.count < self.selected.len;
            if (load) {
                self.selected[self.count] = index;
                self.count += 1;
            } else if (!row.loaded) self.remaining += 1;
            if (load or row.loaded) self.names.append(row.name.slice()) catch return error.CorruptStore;
        }
    }
};

const update_loaded = rsql.Write(.{
    .sql = "UPDATE session SET loaded_tool_set_id=?2,revision=?3 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, loaded: ?u64, revision: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const FirstLine = struct {
    writer: *std.Io.Writer,
    ended: bool = false,

    pub fn write(self: *FirstLine, bytes: []const u8) !void {
        if (self.ended) return;
        const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
        try self.writer.writeAll(bytes[0..end]);
        self.ended = end != bytes.len;
    }
};

/// All queued arguments live until the transaction's final round. The arena
/// belongs to this call's runner, keeping tool-name buffers off Host stacks.
pub fn run(a: anytype, binding: action.ActionAttemptBinding, arena: std.mem.Allocator, words: *const core.FindTools, refusal: ?[]const u8, faults: Faults) !bool {
    const key = try std.fmt.allocPrint(arena, "rui.core/find_tools/{d}", .{binding.action_id});
    var saved: command.saved_command.Result = undefined;
    command.lookupCommand(a, key, &saved);
    var facts: action.core_facts.Result = undefined;
    const names: action.CoreNames = .of();
    a.read(action.core_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id, .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools }, &facts);
    try a.run();
    if (saved != null) {
        try a.abandon(.{});
        return false;
    }
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.stopped) {
        try a.abandon(.{});
        return false;
    }
    var current: settings.Result = undefined;
    a.read(settings, .{ .session = &found.session.ref }, &current);
    try a.run();
    const matches = try arena.create(Matches);
    matches.* = .{};
    if (refusal == null) {
        // Access tracks at most four borrowed arguments per statement.
        // Union two SQL match batches before selecting the first eight names.
        var offset: usize = 0;
        while (offset < words.count) : (offset += 4) {
            const args: candidates.Args = .{ .set = current.tool_set_id.get(), .loaded = current.loaded_set.get(), .word0 = words.words[offset], .word1 = words.words[offset + 1], .word2 = words.words[offset + 2], .word3 = words.words[offset + 3] };
            matches.cursor = 0;
            a.readEachFrom(candidates, &args, protocol.max_tools + 1, matches);
            try a.run();
            if (matches.invalid) return error.CorruptStore;
        }
        try matches.select();
    }

    var output: std.Io.Writer.Allocating = .init(arena);
    const out = &output.writer;
    if (refusal) |reason| {
        try out.print("Rui could not find tools: {s}. Nothing was loaded.", .{reason});
    } else if (matches.count == 0) {
        try out.print("No tools matched. {d} tools are still not loaded.", .{matches.remaining});
    } else {
        try out.writeAll("Loaded these tools; they are available on your next request:\n");
        for (matches.selected[0..matches.count]) |index| {
            const row = &matches.rows[index];
            try out.print("- {s}: ", .{row.name.slice()});
            var first: FirstLine = .{ .writer = out };
            try content.streamVerified(a, row.content_id.get(), .{ .length = row.byte_length, .digest = row.digest }, &first);
            try out.writeAll("\n");
        }
    }
    const result = output.written();
    var outcome: content.Import = .ofBytes(result, false);
    content.lookup(a, &outcome);
    try a.run();
    if (faults.content_import) return error.InjectedContentImportFailure;
    const outcome_id = try content.importBytes(a, &outcome, result);
    const revision = current.revision.get() + @as(u64, if (matches.count > 0) 1 else 0);
    var answer: command.StoredAnswer = .{ .accepted = refusal == null, .revision = revision };
    if (refusal != null) try answer.code.set("invalid_arguments");
    // The call's binding uniquely identifies its saved arguments, even on retry.
    const digest = protocol.contentDigest(key);
    if (matches.count > 0) {
        var loaded: ?u64 = null;
        if (matches.names.count != matches.total) {
            var selected = try tool_set.Selection.ofSaved(a, current.tool_set_id.get(), &matches.names);
            tool_set.lookupSelection(a, &selected);
            try a.run();
            loaded = try tool_set.finishSelection(a, &selected, current.tool_set_id.get());
        }
        a.write(update_loaded, .{ .session = found.session, .loaded = loaded, .revision = revision });
        var applied: configuration.Applied = .{
            .session = .{},
            .head = found.session,
            .revision = revision,
            .instructions_id = null,
            .output_schema_id = null,
            .instructions_updated = false,
            .changes = .initOne(.loaded_tools),
        };
        try applied.session.set(&found.session.ref);
        try configuration.queueConfiguredCommand(a, &applied, key, .configure, &digest, null, null, &answer);
    } else {
        try command.queueCommand(a, key, .configure, &found.session.ref, &digest, null, null, &answer);
    }
    try action.queueCoreResolution(a, binding, found.session, if (refusal == null) .succeeded else .failed, outcome_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return true;
}
