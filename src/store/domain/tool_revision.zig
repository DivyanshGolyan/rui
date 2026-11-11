//! Core-made tool revisions: find_tools and startup-catalog reconciliation
//! share one writer, the same configured-command path as user configuration.
const std = @import("std");
const tools = @import("../../tool_record.zig");
const tool_name = @import("../../tool_name.zig");
const content_string = @import("../../content_string.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const command = @import("command.zig");
const configuration = @import("configuration.zig");
const tool_set = @import("tool_set.zig");

pub const Sets = struct { tools: u64, loaded: ?u64 };
const update = rsql.Write(.{
    .sql = "UPDATE session SET tool_set_id=?2,loaded_tool_set_id=?3,revision=?4 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, tools: u64, loaded: ?u64, revision: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Write one changed core offer and its command/revision/change rows. The
/// caller owns the transaction; this round consumes all borrowed arguments.
pub fn queue(a: anytype, head: rsql.SessionHead, revision: u64, before: Sets, after: Sets, key: []const u8, answer: *const command.StoredAnswer) !void {
    std.debug.assert(before.tools != after.tools or before.loaded != after.loaded);
    a.write(update, .{ .session = head, .tools = after.tools, .loaded = after.loaded, .revision = revision });
    var applied: configuration.Applied = .{
        .session = .{},
        .head = head,
        .revision = revision,
        .instructions_id = null,
        .output_schema_id = null,
        .instructions_updated = false,
        .changes = .empty,
    };
    if (before.tools != after.tools) applied.changes.insert(.tools);
    if (before.loaded != after.loaded) applied.changes.insert(.loaded_tools);
    try applied.session.set(&head.ref);
    const digest = content_string.digest(key);
    try configuration.queueConfiguredCommand(a, &applied, key, .configure, &digest, null, null, answer);
    // The command borrows the formatted Session and digest above.
    try a.run();
}

fn refreshKey(buffer: *[96]u8, session: []const u8, revision: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/mcp_tools/{s}/{d}", .{ session, revision });
}
// Availability revisions do not rewrite the caller's name/loaded intent.
// Read its last explicit changes, verifying core provenance by both the exact
// derived key and its digest. A caller-chosen key in this namespace is still
// a normal configuration command and must never bypass a narrowing.
const intent = rsql.Read(.{
    .sql = "SELECT revision,tool_set_id,loaded_tool_set_id FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { revision: rsql.Positive, tool_set_id: rsql.Positive, loaded_tool_set_id: ?rsql.Positive },
    .cardinality = .one,
});

const policy_revision = rsql.Read(.{
    .sql = "SELECT r.revision,r.tool_set_id," ++ tool_set.offeredSetSql("r") ++ " AS loaded,r.command_key,cmd.input_digest," ++
        "(r.revision=1 OR EXISTS(SELECT 1 FROM session_change c WHERE c.session_ref=r.session_ref AND c.revision=r.revision AND c.field='tools')) AS tools_changed " ++
        "FROM session_revision r JOIN core_command cmd ON cmd.command_key=r.command_key " ++
        "WHERE r.session_ref=?1 AND r.revision<=?2 AND (r.revision=1 OR EXISTS(SELECT 1 FROM session_change c WHERE c.session_ref=r.session_ref AND c.revision=r.revision AND c.field IN ('tools','loaded_tools'))) " ++
        "ORDER BY r.revision DESC LIMIT 1",
    .Args = struct { session: []const u8, through: u64 },
    .Row = struct { revision: rsql.Positive, tool_set_id: rsql.Positive, loaded: rsql.Positive, command_key: Bounded(128), input_digest: [32]u8, tools_changed: bool },
    .cardinality = .optional,
});

fn policy(a: anytype, session: []const u8, revision: u64) !struct { allowed: u64, loaded: u64 } {
    var through = revision;
    var allowed: ?u64 = null;
    var loaded: ?u64 = null;
    while (allowed == null or loaded == null) {
        var row: policy_revision.Result = null;
        a.read(policy_revision, .{ .session = session, .through = through }, &row);
        try a.run();
        const found = row orelse return error.CorruptStore;
        through = found.revision.get() - 1;
        var key_buffer: [96]u8 = undefined;
        const key = try refreshKey(&key_buffer, session, found.revision.get());
        if (found.revision.get() != 1 and found.command_key.eql(key) and std.mem.eql(u8, &found.input_digest, &content_string.digest(key))) continue;
        if (loaded == null) loaded = found.loaded.get();
        if (allowed == null and found.tools_changed) allowed = found.tool_set_id.get();
    }
    return .{ .allowed = allowed.?, .loaded = loaded.? };
}

const permitted = rsql.Read(.{
    .sql = "SELECT t.name,t.owner,t.server,t.read_only,d.digest AS description,i.digest AS input_schema," ++
        "EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?2 AND lt.name=t.name) AS loaded " ++
        "FROM tool_set_member m JOIN tool_record t ON t.tool_record_id=m.tool_record_id " ++
        "JOIN content d ON d.content_id=t.description_content_id JOIN content i ON i.content_id=t.input_schema_content_id " ++
        "WHERE m.tool_set_id=?1 ORDER BY t.name",
    .Args = struct { allowed: u64, loaded: u64 },
    .Row = struct { name: Bounded(tools.max_name_bytes), owner: tools.Owner, server: Bounded(tools.max_server_bytes), read_only: bool, description: [32]u8, input_schema: [32]u8, loaded: bool },
    .cardinality = .each,
});

const Refresh = struct {
    members: [tool_name.max_tools]tool_set.Member = undefined,
    count: usize = 0,
    loaded: usize = 0,
    invalid: bool = false,
    catalog: *const tools.Catalog,
    source: u64,
    allowed: u64,
    key: [96]u8 = undefined,
    answer: command.StoredAnswer = .{ .accepted = true },

    pub fn visit(self: *Refresh, row: *const permitted.Row) bool {
        var identity: tools.RecordIdentity = .{
            .name = row.name.slice(),
            .owner = row.owner,
            .server = row.server.slice(),
            .read_only = row.read_only,
            .description = row.description,
            .input_schema = row.input_schema,
        };
        var digest = identity.digest();
        var source = self.allowed;
        if (row.owner == .mcp) {
            const index = self.catalog.find(row.name.slice()) orelse return true;
            digest = self.catalog.digests[index];
            source = self.source;
        }
        if (self.count == self.members.len) {
            self.invalid = true;
            return false;
        }
        self.members[self.count] = .{ .name = row.name, .source = source, .digest = digest, .loaded = row.loaded };
        self.count += 1;
        if (row.loaded) self.loaded += 1;
        return true;
    }
};

/// Before freezing a new Operation, reconcile the Host's startup catalog with
/// the Session's saved name/loaded policy. No network work, mutable catalog or
/// per-Session sync flag: revisions are authority, including after restart.
/// Scratch is reused Store memory; every queued argument lives through run.
pub fn needed(has_saved_mcp: bool, catalog: *const tools.Catalog) bool {
    if (has_saved_mcp) return true;
    for (catalog.records) |record| if (record.owner == .mcp) return true;
    return false;
}

pub const Intent = intent.Result;

pub fn prepare(a: anytype, session: []const u8, out: *Intent) void {
    a.read(intent, .{ .session = session }, out);
}

/// Returns true only when the caller must reread its frozen settings.
pub fn refresh(a: anytype, head: rsql.SessionHead, current: *const Intent) !bool {
    const host = a.store.catalog();
    const scope = try policy(a, &head.ref, current.revision.get());
    const scratch = a.store.reportScratch(Refresh);
    scratch.* = .{ .catalog = host.catalog, .source = host.set_id, .allowed = scope.allowed };
    a.readEach(permitted, .{ .allowed = scope.allowed, .loaded = scope.loaded }, tool_name.max_tools + 1, scratch);
    try a.run();
    if (scratch.invalid) return error.CorruptStore;
    const members = scratch.members[0..scratch.count];
    const set = try tool_set.internMembers(a, members, false);
    const loaded: ?u64 = if (scratch.count == scratch.loaded) null else try tool_set.internMembers(a, members, true);
    const before: Sets = .{ .tools = current.tool_set_id.get(), .loaded = if (current.loaded_tool_set_id) |id| id.get() else null };
    const after: Sets = .{ .tools = set, .loaded = loaded };
    if (before.tools == after.tools and before.loaded == after.loaded) return false;
    const revision = current.revision.get() + 1;
    const key = try refreshKey(&scratch.key, &head.ref, revision);
    scratch.answer.revision = revision;
    try queue(a, head, revision, before, after, key, &scratch.answer);
    return true;
}
