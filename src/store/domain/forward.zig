//! Durable, one-hop delivery of child facts to ancestor Activity feeds.
//! Queuing claims no position; each delivery positions one row and queues
//! the next hop atomically, so tree depth never grows a transaction.
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const rsql = @import("../rsql.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");

pub const Kind = enum(u8) { approval = 1, ending = 2 };

const insert = rsql.Write(.{
    .sql = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) " ++
        "SELECT ?1,s.parent_ref,?2,?3,?4,NULL,0,NULL," ++
        "CASE WHEN ?3=2 AND s.session_ref=?2 AND NOT EXISTS(SELECT 1 FROM session_stop_owed WHERE child_ref=?2 AND settled=0) THEN 0 ELSE NULL END," ++
        "CASE WHEN ?3=2 AND s.session_ref=?2 AND EXISTS(SELECT 1 FROM session_archive archived WHERE archived.session_ref=s.parent_ref AND archived.command_key IS NOT NULL) THEN 1 ELSE 0 END FROM session s WHERE s.session_ref=?5 AND s.parent_ref IS NOT NULL " ++
        "AND NOT EXISTS(SELECT 1 FROM session_forward f WHERE f.target_ref=s.parent_ref AND f.kind=?3 AND f.source_id=?4)",
    // rsql binds enum tags as text; the Store format saves numeric kinds.
    .Args = struct { forward_id: u64, child: []const u8, kind: u8, source_id: u64, from: []const u8 },
    .expect = .{ .at_most = 1 },
});

/// Queues `child`'s fact for `from`'s parent, if attached. Forward rows are
/// owed work, not positioned Session facts yet. Only the first ending hop
/// also owes a Message; later hops and approvals have no Message duty.
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
    .Row = struct { session: rsql.SessionHead, child_ref: Bounded(session_id.bytes), kind: u8, source_id: rsql.Positive },
    .cardinality = .optional,
});

const position = rsql.Write(.{
    .sql = "UPDATE session_forward SET position=?2,delivered_at=@now WHERE forward_id=?1 AND position IS NULL",
    .Args = struct { forward_id: u64, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Delivers forward row `forward_id` once, retaining both the delivered
/// row and the next obligation, in one transaction. Round `.pending` reads
/// the row and its target Session; the commit round positions it and
/// queues the next hop. Repeating an already delivered id is a no-op,
/// including after recovery: it answers false.
pub const Deliver = struct {
    pub const rounds = transition.rounds(.{ .pending = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .pending;
    pub const Input = struct { forward_id: u64 };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    /// The next hop's insert reads the Session's reference in place.
    facts: pending.Result = undefined,

    pub fn step(t: *Deliver, r: *transition.Round(Deliver), ran: ?rounds.At) !transition.Next(Deliver) {
        const forward_id = t.input.forward_id;
        if (ran == null) {
            r.read(pending, .{ .forward_id = forward_id }, &t.facts);
            return .{ .round = .pending };
        }
        const found = if (t.facts) |*row| row else return .{ .done = false };
        const positions = try r.positions(found.session);
        r.write(position, .{ .forward_id = forward_id, .position = try positions.take(1) });
        const kind: Kind = switch (found.kind) {
            1 => .approval,
            2 => .ending,
            else => return error.CorruptStore,
        };
        try queue(r, &found.session.ref, found.child_ref.slice(), kind, found.source_id.get());
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(_: *const Deliver) Result {
        return true;
    }
};
