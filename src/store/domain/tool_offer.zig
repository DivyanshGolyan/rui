//! A Session's current offer: its tool intent projected onto the Host's saved
//! tool set. Derived on every read, frozen only by Operation admission.
const std = @import("std");
const tools = @import("../../tool_record.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const tool_set = @import("tool_set.zig");

/// One relational projection for current offers. Intent supplies membership;
/// the Host supplies MCP identities, while built-in identities remain frozen.
const projected = rsql.Read(.{
    .sql = "SELECT tool.name,tool.owner,tool.server,tool.read_only,description.digest AS description,input_schema.digest AS input_schema," ++
        "description.content_id,description.byte_length,CASE WHEN intended.owner='mcp' THEN host.tool_set_id ELSE member.tool_set_id END AS source," ++
        "EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?2 AND lt.name=tool.name) AS loaded " ++
        "FROM tool_set_member member JOIN tool_record intended ON intended.tool_record_id=member.tool_record_id " ++
        "JOIN host_tool_set host ON host.slot=1 " ++
        "JOIN tool_record tool ON tool.tool_record_id=CASE WHEN intended.owner='mcp' THEN " ++
        "(SELECT hm.tool_record_id FROM tool_set_member hm JOIN tool_record ht ON ht.tool_record_id=hm.tool_record_id WHERE hm.tool_set_id=host.tool_set_id AND ht.name=intended.name) " ++
        "ELSE intended.tool_record_id END " ++
        "JOIN content description ON description.content_id=tool.description_content_id JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { allowed: u64, loaded: u64 },
    .Row = struct {
        name: Bounded(tools.max_name_bytes),
        owner: tools.Owner,
        server: Bounded(tools.max_server_bytes),
        read_only: bool,
        description: [32]u8,
        input_schema: [32]u8,
        content_id: rsql.Positive,
        byte_length: u64,
        source: rsql.Positive,
        loaded: bool,
    },
    .cardinality = .each,
});
pub const OfferedRecord = projected.Row;

/// Read a current offer without saving any derived state. The caller owns the
/// bounded sink; both admission and find_tools consume this same projection.
pub fn project(a: anytype, allowed: u64, loaded: ?u64, sink: anytype) !void {
    a.readEach(projected, .{ .allowed = allowed, .loaded = loaded orelse allowed }, tool_name.max_tools + 1, sink);
    try a.run();
}

const Projection = struct {
    members: [tool_name.max_tools]tool_set.Member = undefined,
    count: usize = 0,
    invalid: bool = false,

    pub fn visit(self: *Projection, row: *const OfferedRecord) bool {
        if (!row.loaded) return true;
        if (self.count == self.members.len) {
            self.invalid = true;
            return false;
        }
        const identity: tools.RecordIdentity = .{
            .name = row.name.slice(),
            .owner = row.owner,
            .server = row.server.slice(),
            .read_only = row.read_only,
            .description = row.description,
            .input_schema = row.input_schema,
        };
        self.members[self.count] = .{ .name = row.name, .source = row.source.get(), .digest = identity.digest() };
        self.count += 1;
        return true;
    }
};

/// True when the loaded intent of Session alias `s` names an MCP record the
/// Host's saved tool set no longer holds. Records are saved once per identity,
/// so otherwise the projection is the loaded intent set itself.
pub const stale_sql = "EXISTS(SELECT 1 FROM tool_set_member tm JOIN tool_record tool ON tool.tool_record_id=tm.tool_record_id " ++
    "WHERE tm.tool_set_id=" ++ tool_set.offeredSetSql("s") ++ " AND tool.owner='mcp' AND tm.tool_record_id NOT IN " ++
    "(SELECT hm.tool_record_id FROM host_tool_set host JOIN tool_set_member hm ON hm.tool_set_id=host.tool_set_id WHERE host.slot=1))";

/// Only Operation admission saves the effective offer. Intent that is not
/// `stale` (see `stale_sql`) already names it, requiring no additional round.
/// Scratch is reused Store memory; callers cannot hold another scratch lease.
pub fn freeze(a: anytype, allowed: u64, loaded: ?u64, stale: bool) !u64 {
    if (!stale) return loaded orelse allowed;
    const scratch = a.store.reportScratch(Projection);
    scratch.* = .{};
    try project(a, allowed, loaded, scratch);
    if (scratch.invalid) return error.CorruptStore;
    const set = try tool_set.internMembers(a, scratch.members[0..scratch.count]);
    // Consume queued borrowed member names before the scratch can be reused.
    try a.run();
    return set;
}
