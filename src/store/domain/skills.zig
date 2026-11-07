//! Catalog snapshots are metadata. Bodies live only in ordinary message/tool
//! content. Catalog instructions append at the Session's next position.
const std = @import("std");
const catalog = @import("../../skills.zig");
const protocol = @import("../../protocol.zig");
const content = @import("content.zig");
const rsql = @import("../rsql.zig");
const store_core = @import("../Store.zig");

/// Captured outside the Store writer. Borrowed until the synchronous mutation
/// finishes. A failed scan is explicit rather than an empty catalog.
/// ready.encoded may alias ready.instruction's suffix; neither is freed here.
pub const Initial = union(enum) {
    ready: struct { encoded: []const u8, instruction: ?[]const u8 },
    unavailable,
};

/// A catalog instruction certifies the immutable snapshot at its own position.
/// Reused by model history and reports; a detached/private source is corruption,
/// not a reason to silently rebuild or repair conversation history.
pub fn instructionConsistentSql(comptime e: []const u8) []const u8 {
    return "(" ++ e ++ ".entry_kind=2 AND " ++ e ++ ".turn_id IS NULL AND " ++
        e ++ ".source_revision IS NULL AND " ++ e ++ ".source_admission_id IS NULL AND " ++
        e ++ ".source_operation_id IS NULL AND " ++ e ++ ".source_catalog_position=" ++ e ++ ".session_position AND " ++
        "EXISTS(SELECT 1 FROM session_skill_catalog catalog_source JOIN content catalog_metadata " ++
        "ON catalog_metadata.content_id=catalog_source.catalog_content_id JOIN content catalog_text " ++
        "ON catalog_text.content_id=" ++ e ++ ".content_id WHERE catalog_source.session_ref=" ++ e ++ ".session_ref " ++
        "AND catalog_source.position=" ++ e ++ ".source_catalog_position AND catalog_metadata.private=0 AND catalog_text.private=0))";
}

/// A source-side proof catches required instructions which were deleted, so
/// entry-driven consumers cannot silently omit an advertised snapshot.
/// `scope` limits history to the frozen Operation boundary, never live state.
pub fn sourcesConsistentSql(comptime session: []const u8, comptime scope: []const u8) []const u8 {
    return "NOT EXISTS(SELECT 1 FROM session_skill_catalog catalog_required WHERE catalog_required.session_ref=" ++ session ++
        " AND catalog_required.position>0 AND (" ++ scope ++ ") AND NOT EXISTS(SELECT 1 FROM conversation_entry catalog_entry " ++
        "WHERE catalog_entry.session_ref=catalog_required.session_ref AND catalog_entry.source_catalog_position=catalog_required.position " ++
        "AND " ++ instructionConsistentSql("catalog_entry") ++ "))";
}

pub const latest = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,s.workspace,c.catalog_content_id,c.position AS catalog_position,content.byte_length,content.digest,content.private," ++
        "CASE WHEN c.position=0 OR EXISTS(SELECT 1 FROM conversation_entry source_entry WHERE source_entry.session_ref=c.session_ref " ++
        "AND source_entry.source_catalog_position=c.position AND " ++ instructionConsistentSql("source_entry") ++ ") THEN 1 ELSE 0 END AS source_consistent " ++
        "FROM session s LEFT JOIN session_skill_catalog c ON c.session_ref=s.session_ref AND c.position=(SELECT max(last.position) FROM session_skill_catalog last WHERE last.session_ref=s.session_ref) " ++
        "LEFT JOIN content ON content.content_id=c.catalog_content_id WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        session: rsql.SessionHead,
        workspace: *protocol.Bounded(protocol.max_workspace_bytes),
        catalog_content_id: ?rsql.Positive,
        catalog_position: ?u64 = null,
        byte_length: ?u64,
        digest: ?[32]u8,
        private: ?bool = null,
        source_consistent: bool = false,
    },
    .cardinality = .optional,
});

const ordinal = rsql.Read(.{
    .sql = "SELECT coalesce(max(entry_ordinal),0) AS ordinal FROM conversation_entry WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { ordinal: u64 },
    .cardinality = .one,
});

const insert_snapshot = rsql.Write(.{
    .sql = "INSERT INTO session_skill_catalog(session_ref,position,catalog_content_id) VALUES(@session(?1),?2,?3)",
    .Args = struct { session: rsql.SessionHead, position: u64, catalog_content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_instruction = rsql.Write(.{
    .sql = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_catalog_position,content_id,recorded_at) " ++
        "VALUES(@session(?1),?2,?3,2,NULL,?3,?4,@now)",
    .Args = struct { session: rsql.SessionHead, ordinal: u64, position: u64, content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Initializes even an empty catalog. Empty initial catalogs have no instruction
/// and consume no conversation position. Existing authored instructions stay intact.
pub fn initialize(a: anytype, session: rsql.SessionHead, initial: ?*const Initial, faults: store_core.Faults) !void {
    const value = initial orelse return;
    const ready = switch (value.*) {
        .ready => |prepared| prepared,
        .unavailable => return error.SkillCatalogUnavailable,
    };
    try append(a, session, ready.encoded, ready.instruction, faults);
}

/// Appends both immutable metadata and ordinary instruction bytes in the caller's
/// transaction. The caller settles its command/tool result in that transaction.
pub fn append(a: anytype, session: rsql.SessionHead, encoded: []const u8, instruction: ?[]const u8, faults: store_core.Faults) !void {
    var metadata: content.Import = .ofBytes(encoded, false);
    var text: content.Import = .ofBytes(instruction orelse "", false);
    var rows: content.Pair = .{ .first = null, .second = null };
    var last: ordinal.Row = undefined;
    content.lookupPair(a, &metadata, &text, &rows);
    if (instruction != null) a.read(ordinal, .{ .session = &session.ref }, &last);
    try a.run();
    content.foundPair(&rows, &metadata, &text);
    if (faults.content_import) return error.InjectedContentImportFailure;
    const metadata_id = try content.importBytes(a, &metadata, encoded);
    const position = if (instruction != null) try (try a.positions(session)).take(1) else 0;
    a.write(insert_snapshot, .{ .session = session, .position = position, .catalog_content_id = metadata_id });
    if (instruction) |bytes| {
        const text_id = try content.importBytes(a, &text, bytes);
        a.write(insert_instruction, .{ .session = session, .ordinal = last.ordinal + 1, .position = position, .content_id = text_id });
    }
}

/// A writer reads its actual current catalog, not the shell's earlier guess.
/// Concurrent same-candidate reloads therefore append at most one delta.
pub fn reload(a: anytype, allocator: std.mem.Allocator, session: rsql.SessionHead, candidate: catalog.Catalog, faults: store_core.Faults) !Result {
    const previous = try read(a, allocator, &session.ref);
    const delta = try catalog.diff(allocator, previous, candidate);
    if (delta.isEmpty()) return .{ .bytes = "Skills are unchanged.", .succeeded = true, .reload_status = .unchanged };
    const encoded = try catalog.encodeCatalog(allocator, candidate);
    const instruction = try catalog.deltaInstruction(allocator, delta);
    try append(a, session, encoded, instruction, faults);
    return .{ .bytes = "Skills catalog reloaded.", .succeeded = true, .reload_status = .reloaded };
}

pub fn read(a: anytype, allocator: std.mem.Allocator, session: []const u8) !catalog.Catalog {
    const workspace = try allocator.create(protocol.Bounded(protocol.max_workspace_bytes));
    var row: latest.Row = .{ .workspace = workspace, .session = undefined, .catalog_content_id = null, .byte_length = null, .digest = null };
    const access = @import("../access.zig");
    var found: access.Found = .missing;
    a.readInto(latest, .{ .session = session }, &row, &found);
    try a.run();
    if (!found.get()) return error.SessionNotFound;
    const id = row.catalog_content_id orelse return .{ .entries = &.{} };
    if (row.private != false or !row.source_consistent) return error.CorruptStore;
    const position = row.catalog_position orelse return error.CorruptStore;
    const length = row.byte_length orelse return error.CorruptStore;
    const digest = row.digest orelse return error.CorruptStore;
    if (length > catalog.max_catalog_bytes) return error.CorruptStore;
    // Encoded JSON is parse scratch, not another request-arena catalog.
    const bytes = try std.heap.c_allocator.alloc(u8, @intCast(length));
    defer std.heap.c_allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + content.verified_window_bytes, bytes.len);
        try a.readRaw(id.get(), offset, bytes[offset..end]);
        offset = end;
    }
    if (!std.mem.eql(u8, &protocol.contentDigest(bytes), &digest)) return error.CorruptStore;
    const decoded = catalog.decodeCatalog(allocator, bytes) catch return error.CorruptStore;
    if (position == 0 and decoded.entries.len != 0) return error.CorruptStore;
    return decoded;
}

pub const Failure = struct {
    code: enum { unknown_session, unknown_skill, skill_file_unavailable, skill_file_too_large, skill_text_invalid, skills_unavailable },
    bytes: []const u8,

    pub fn rejection(self: Failure, comptime Rejection: type) Rejection {
        return switch (self.code) {
            inline else => |code| @field(Rejection, @tagName(code)),
        };
    }
};

/// Ordinary immutable rejected-command outcome; its typed code, not wording,
/// controls the native caller's repair guidance and survives keyed replay.
pub fn importFailure(a: anytype, failure: Failure, faults: store_core.Faults) !u64 {
    var outcome: content.Import = .ofBytes(failure.bytes, false);
    content.lookup(a, &outcome);
    try a.run();
    if (faults.content_import) return error.InjectedContentImportFailure;
    return content.importBytes(a, &outcome, failure.bytes);
}

pub const Capture = union(enum) {
    invocation: []const u8,
    reload: catalog.Catalog,
    failed: Failure,
};

pub const Result = struct { bytes: []const u8, succeeded: bool, reload_status: ?protocol.SkillsReloadStatus = null };

pub fn apply(a: anytype, allocator: std.mem.Allocator, session: rsql.SessionHead, captured: *const Capture, faults: store_core.Faults) !Result {
    return switch (captured.*) {
        .invocation => |bytes| .{ .bytes = bytes, .succeeded = true },
        .failed => |failure| .{ .bytes = failure.bytes, .succeeded = false },
        .reload => |candidate| try reload(a, allocator, session, candidate, faults),
    };
}

pub fn runTool(a: anytype, allocator: std.mem.Allocator, binding: @import("action.zig").ActionAttemptBinding, captured: *const Capture, faults: store_core.Faults) !bool {
    const action = @import("action.zig");
    var facts: action.core_facts.Result = undefined;
    const names: action.CoreNames = .of();
    a.read(action.core_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id, .message_agent_name = names.message_agent, .read_transcript_name = names.read_transcript, .start_agent_name = names.start_agent, .find_tools_name = names.find_tools, .skill_name = names.skill }, &facts);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.stopped) {
        try a.abandon(.{});
        return false;
    }
    const result = try apply(a, allocator, found.session, captured, faults);
    var outcome: content.Import = .ofBytes(result.bytes, false);
    content.lookup(a, &outcome);
    try a.run();
    if (faults.content_import) return error.InjectedContentImportFailure;
    const outcome_id = try content.importBytes(a, &outcome, result.bytes);
    try action.queueCoreResolution(a, binding, found.session, if (result.succeeded) .succeeded else .failed, outcome_id);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return true;
}
