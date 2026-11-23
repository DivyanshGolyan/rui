const std = @import("std");
const tools = @import("../../tool_record.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const tool_set = @import("tool_set.zig");
const tool_offer = @This();

const projected = rsql.Read(.{
    .compound = true,
    .sql = "SELECT tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms,description.digest AS description,input_schema.digest AS input_schema," ++
        "description.content_id,description.byte_length,CASE WHEN intended.owner='mcp' THEN host.tool_set_id ELSE member.tool_set_id END AS source," ++
        "(tool.name='stop_action' OR EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?2 AND lt.name=tool.name)) AS loaded " ++
        "FROM tool_set_member member JOIN tool_record intended ON intended.tool_record_id=member.tool_record_id " ++
        "JOIN host_tool_set host ON host.slot=1 " ++
        "JOIN tool_record tool ON tool.tool_record_id=CASE WHEN intended.owner='mcp' THEN " ++
        "(SELECT hm.tool_record_id FROM tool_set_member hm JOIN tool_record ht ON ht.tool_record_id=hm.tool_record_id WHERE hm.tool_set_id=host.tool_set_id AND ht.name=intended.name) " ++
        "ELSE intended.tool_record_id END " ++
        "JOIN content description ON description.content_id=tool.description_content_id JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE member.tool_set_id=?1 AND (tool.name<>'stop_action' OR EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?2 AND lt.name='read_action')) " ++
        "UNION ALL SELECT tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms,description.digest AS description,input_schema.digest AS input_schema," ++
        "description.content_id,description.byte_length,host.tool_set_id AS source,1 AS loaded " ++
        "FROM host_tool_set host JOIN tool_set_member member ON member.tool_set_id=host.tool_set_id " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE host.slot=1 AND tool.name='stop_action' " ++
        "AND EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?2 AND lt.name='read_action') " ++
        "AND NOT EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?1 AND lt.name='stop_action') ORDER BY name",
    .Args = struct { allowed: u64, loaded: u64 },
    .Row = struct {
        name: Bounded(tools.max_name_bytes),
        remote_name: Bounded(tools.max_name_bytes),
        owner: tools.Owner,
        server: Bounded(tools.max_server_bytes),
        replay: Bounded(6),
        restart_limit: u64,
        wait_ms: u64,
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

pub fn project(a: anytype, allowed: u64, loaded: ?u64, sink: anytype) void {
    a.readEach(projected, .{ .allowed = allowed, .loaded = loaded orelse allowed }, tool_name.max_offered_tools + 1, sink);
}

const Projection = struct {
    members: [tool_name.max_offered_tools]tool_set.Member = undefined,
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
            .remote_name = row.remote_name.slice(),
            .owner = row.owner,
            .server = row.server.slice(),
            .description = row.description,
            .input_schema = row.input_schema,
            .app = tools.storedAppPolicy(row.owner, row.replay.slice(), row.restart_limit, row.wait_ms),
        };
        self.members[self.count] = .{ .name = row.name, .source = row.source.get(), .digest = identity.digest() };
        self.count += 1;
        return true;
    }
};

pub const stale_sql = "EXISTS(SELECT 1 FROM tool_set_member tm JOIN tool_record tool ON tool.tool_record_id=tm.tool_record_id " ++
    "WHERE tm.tool_set_id=" ++ tool_set.offeredSetSql("s") ++ " AND tool.owner='mcp' AND tm.tool_record_id NOT IN " ++
    "(SELECT hm.tool_record_id FROM host_tool_set host JOIN tool_set_member hm ON hm.tool_set_id=host.tool_set_id WHERE host.slot=1)) OR " ++
    "(EXISTS(SELECT 1 FROM tool_set_member rm JOIN tool_record rt ON rt.tool_record_id=rm.tool_record_id WHERE rm.tool_set_id=" ++ tool_set.offeredSetSql("s") ++ " AND rt.name='read_action') <> " ++
    "EXISTS(SELECT 1 FROM tool_set_member sm JOIN tool_record st ON st.tool_record_id=sm.tool_record_id WHERE sm.tool_set_id=" ++ tool_set.offeredSetSql("s") ++ " AND st.name='stop_action'))";

pub const Freeze = struct {
    projection: Projection = .{},
    interning: tool_set.Interning = .{},

    pub fn unchanged(allowed: u64, loaded: ?u64, stale: bool) ?u64 {
        return if (stale) null else loaded orelse allowed;
    }

    pub fn project(freeze: *Freeze, a: anytype, allowed: u64, loaded: ?u64) void {
        freeze.* = .{};
        tool_offer.project(a, allowed, loaded, &freeze.projection);
    }

    pub fn intern(freeze: *Freeze, a: anytype) !void {
        if (freeze.projection.invalid) return error.CorruptStore;
        freeze.interning.queue(a, freeze.members());
    }

    pub fn set(freeze: *Freeze, a: anytype) !u64 {
        return freeze.interning.finish(a, freeze.members());
    }

    fn members(freeze: *const Freeze) []const tool_set.Member {
        return freeze.projection.members[0..freeze.projection.count];
    }
};
