//! Loading saved tools is one call-keyed command, revision and resolution.
const std = @import("std");
const command_input = @import("../../command_input.zig");
const content_string = @import("../../content_string.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const core = @import("../../find_tools_words.zig");
const tools = @import("../../tool_record.zig");
const word_search = @import("../../word_search.zig");
const rsql = @import("../rsql.zig");
const action = @import("action.zig");
const command = @import("command.zig");
const content = @import("content.zig");
const tool_set = @import("tool_set.zig");
const tool_revision = @import("tool_revision.zig");
const Faults = @import("../Store.zig").Faults;

const settings = rsql.Read(.{
    .sql = "SELECT revision,tool_set_id," ++ tool_set.offeredSetSql("session") ++ " AS loaded_set,loaded_tool_set_id FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { revision: rsql.Positive, tool_set_id: rsql.Positive, loaded_set: rsql.Positive, loaded_tool_set_id: ?rsql.Positive },
    .cardinality = .one,
});

/// The shared current projection supplies available identities; only unloaded
/// records enter matching. Description text is streamed below, never copied.
const Candidate = struct { name: Bounded(tools.max_name_bytes), content_id: rsql.Positive, byte_length: u64, digest: [32]u8 };

const Candidates = struct {
    rows: [tool_name.max_tools]Candidate = undefined,
    count: usize = 0,
    invalid: bool = false,

    pub fn visit(self: *Candidates, row: *const tool_revision.OfferedRecord) bool {
        if (row.loaded) return true;
        if (self.count == self.rows.len) {
            self.invalid = true;
            return false;
        }
        self.rows[self.count] = .{ .name = row.name, .content_id = row.content_id, .byte_length = row.byte_length, .digest = row.description };
        self.count += 1;
        return true;
    }
};

const loaded_names = rsql.Read(.{
    .sql = "SELECT tool.name FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { set: u64 },
    .Row = struct { name: Bounded(tools.max_name_bytes) },
    .cardinality = .each,
});

const LoadedNames = struct {
    names: command_input.ToolsField = .{ .state = .value },
    invalid: bool = false,

    pub fn visit(self: *LoadedNames, row: *const loaded_names.Row) bool {
        self.names.append(row.name.slice()) catch {
            self.invalid = true;
            return false;
        };
        return true;
    }
};

const Matches = struct {
    names: command_input.ToolsField = .{ .state = .value },
    rows: [8]Candidate = undefined,
    count: usize = 0,
    remaining: usize = 0,
};

/// Per-call, fixed-size heap scratch, never a description-sized allocation or
/// a Host stack window. Matcher's n-1 byte carry spans successive reads.
const SearchScratch = struct {
    window: [content.ContentReader.content_window_bytes]u8 = undefined,
    matchers: [8]word_search.Matcher = undefined,
};

fn matchesCandidate(a: anytype, scratch: *SearchScratch, words: *const core.FindTools, row: *const Candidate) !bool {
    for (words.words[0..words.count], 0..) |word, index| {
        const matcher = &scratch.matchers[index];
        matcher.init(word);
        matcher.feed(row.name.slice());
        if (matcher.count != 0) return true;
    }
    // A word must match one field, never the end of a name plus the start of
    // its description. init also owns query folding, just as in feed search.
    for (words.words[0..words.count], 0..) |word, index| scratch.matchers[index].init(word);
    var reader: content.ContentReader = undefined;
    reader.open(.{ .store = a.store, .content_id = @intCast(row.content_id.get()), .reference = .{ .length = row.byte_length, .digest = row.digest } });
    defer reader.close();
    var offset: u64 = 0;
    while (offset < row.byte_length) {
        const count = try reader.readWithAccess(a, offset, &scratch.window);
        for (scratch.matchers[0..words.count]) |*matcher| {
            matcher.feed(scratch.window[0..count]);
            if (matcher.count != 0) return true;
        }
        offset += count;
    }
    return false;
}

/// Merge disjoint, ordered loaded intent and new available hits. Preserve
/// unavailable intended names even when the hits cover all available tools.
fn includeLoadedNames(a: anytype, arena: std.mem.Allocator, loaded_set: u64, matches: *Matches) !void {
    const loaded = try arena.create(LoadedNames);
    loaded.* = .{};
    a.readEach(loaded_names, .{ .set = loaded_set }, tool_name.max_tools + 1, loaded);
    try a.run();
    if (loaded.invalid) return error.CorruptStore;
    var names = loaded.names.iterator();
    var saved = names.next();
    var index: usize = 0;
    while (saved != null or index < matches.count) {
        if (index < matches.count and (saved == null or std.mem.lessThan(u8, matches.rows[index].name.slice(), saved.?))) {
            matches.names.append(matches.rows[index].name.slice()) catch return error.CorruptStore;
            index += 1;
        } else {
            matches.names.append(saved.?) catch return error.CorruptStore;
            saved = names.next();
        }
    }
}

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
    a.read(action.core_facts, names.args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &facts);
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
        const pending = try arena.create(Candidates);
        pending.* = .{};
        try tool_revision.project(a, current.tool_set_id.get(), if (current.loaded_tool_set_id) |id| id.get() else null, pending);
        if (pending.invalid) return error.CorruptStore;
        matches.remaining = pending.count;
        if (pending.count > 0) {
            const scratch = try arena.create(SearchScratch);
            for (pending.rows[0..pending.count]) |*row| {
                if (!try matchesCandidate(a, scratch, words, row)) continue;
                matches.rows[matches.count] = row.*;
                matches.count += 1;
                matches.remaining -= 1;
                if (matches.count == matches.rows.len) break;
            }
        }
        if (matches.count > 0)
            try includeLoadedNames(a, arena, current.loaded_set.get(), matches);
    }

    var output: std.Io.Writer.Allocating = .init(arena);
    const out = &output.writer;
    if (refusal) |reason| {
        try out.print("Rui could not find tools: {s}. Nothing was loaded.", .{reason});
    } else if (matches.count == 0) {
        try out.print("No tools matched. {d} tools are still not loaded.", .{matches.remaining});
    } else {
        try out.writeAll("Loaded these tools; they are available on your next request:\n");
        for (matches.rows[0..matches.count]) |*row| {
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
    const digest = content_string.digest(key);
    if (matches.count > 0) {
        var selected = try tool_set.Selection.ofSaved(a, current.tool_set_id.get(), &matches.names);
        tool_set.lookupSelection(a, &selected);
        try a.run();
        const selected_set = try tool_set.finishSelection(a, &selected, current.tool_set_id.get());
        const loaded: ?u64 = if (selected_set == current.tool_set_id.get()) null else selected_set;
        try tool_revision.queue(a, found.session, revision, .{
            .tools = current.tool_set_id.get(),
            .loaded = if (current.loaded_tool_set_id) |id| id.get() else null,
        }, .{ .tools = current.tool_set_id.get(), .loaded = loaded }, key, &answer);
    } else {
        try command.queueCommand(a, key, .configure, &found.session.ref, &digest, null, null, &answer);
    }
    try action.queueResolution(a, binding, found.session, if (refusal == null) .succeeded else .failed, outcome_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return true;
}
