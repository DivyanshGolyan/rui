//! Durable, one-hop delivery of child facts to ancestor Activity feeds.
//! Queuing claims no position; each delivery positions one row and queues
//! the next hop atomically, so tree depth never grows a transaction.
const protocol = @import("../../protocol.zig");
const rsql = @import("../rsql.zig");
const Faults = @import("../Store.zig").Faults;

pub const Kind = enum(u8) { approval = 1, ending = 2 };

const insert = rsql.Write(.{
    .sql = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at) " ++
        "SELECT ?1,s.parent_ref,?2,?3,?4,NULL,0,NULL FROM session s WHERE s.session_ref=?5 AND s.parent_ref IS NOT NULL " ++
        "AND NOT EXISTS(SELECT 1 FROM session_forward f WHERE f.target_ref=s.parent_ref AND f.kind=?3 AND f.source_id=?4)",
    // rsql binds enum tags as text; the Store format saves numeric kinds.
    .Args = struct { forward_id: u64, child: []const u8, kind: u8, source_id: u64, from: []const u8 },
    .expect = .{ .at_most = 1 },
});

/// Queues `child`'s fact for `from`'s parent, if attached. Forward rows are
/// owed work, like session_ending_owed, not positioned Session facts yet.
pub fn queue(a: anytype, from: []const u8, child: []const u8, kind: Kind, source_id: u64) !void {
    a.write(insert, .{ .forward_id = try a.identity(.forward_id), .child = child, .kind = @backingInt(kind), .source_id = source_id, .from = from });
}

pub const next = rsql.Read(.{
    .sql = "SELECT forward_id FROM session_forward @index(session_forward_open) WHERE position IS NULL ORDER BY forward_id LIMIT 1",
    .Args = struct {},
    .Row = struct { forward_id: rsql.Positive },
    .cardinality = .optional,
});

const pending = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,f.child_ref,f.kind,f.source_id " ++
        "FROM session_forward f JOIN session s ON s.session_ref=f.target_ref WHERE f.forward_id=?1 AND f.position IS NULL",
    .Args = struct { forward_id: u64 },
    .Row = struct { session: rsql.SessionHead, child_ref: protocol.Bounded(protocol.session_id_bytes), kind: u8, source_id: rsql.Positive },
    .cardinality = .optional,
});

const position = rsql.Write(.{
    .sql = "UPDATE session_forward SET position=?2,delivered_at=@now WHERE forward_id=?1 AND position IS NULL",
    .Args = struct { forward_id: u64, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Delivers once, retaining both the delivered row and the next obligation.
/// Repeating an already delivered id is a no-op, including after recovery.
pub fn deliver(a: anytype, forward_id: u64, faults: Faults) !bool {
    var facts: pending.Result = undefined;
    a.read(pending, .{ .forward_id = forward_id }, &facts);
    try a.run();
    const found = facts orelse {
        try a.abandon(.{});
        return false;
    };
    const positions = try a.positions(found.session);
    a.write(position, .{ .forward_id = forward_id, .position = try positions.take(1) });
    const kind: Kind = switch (found.kind) {
        1 => .approval,
        2 => .ending,
        else => return error.CorruptStore,
    };
    try queue(a, &found.session.ref, found.child_ref.slice(), kind, found.source_id.get());
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return true;
}
