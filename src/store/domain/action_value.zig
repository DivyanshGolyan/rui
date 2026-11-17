const std = @import("std");
const rsql = @import("../rsql.zig");
const action = @import("action.zig");
const content = @import("content.zig");
const command = @import("command.zig");
const sourced_input = @import("sourced_input.zig");
const content_string = @import("../../content_string.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const transition = @import("../transition.zig");

pub const max_value_bytes = @import("../../action_value_limits.zig").max_value_bytes;
pub const max_pending = 32;
pub const Receipt = struct { action_id: u64, ordinal: u64, admission_id: ?u64, replayed: bool };
pub const Refusal = enum { unknown_handle, stopped, resolved, conflict, too_large, backlog_full };
pub const Result = union(enum) { accepted: Receipt, refused: Refusal };

const replay = rsql.Read(.{
    .sql = "SELECT v.action_id,v.ordinal,v.admission_id,c.digest FROM action_value v JOIN content c ON c.content_id=v.content_id WHERE v.handle=?1 AND v.publication_key=?2",
    .Args = struct { handle: []const u8, key: []const u8 },
    .Row = struct { action_id: rsql.Positive, ordinal: rsql.Positive, admission_id: ?rsql.Positive, digest: [32]u8 },
    .cardinality = .optional,
});
const facts = rsql.Read(.{
    .sql = "SELECT coalesce((SELECT max(v.ordinal) FROM action_value v WHERE v.action_id=?1),0) AS last_ordinal,(SELECT count(*) FROM action_value v JOIN message_admission m ON m.admission_id=v.admission_id WHERE v.action_id=?1 AND m.turn_id IS NULL) AS pending",
    .Args = struct { action_id: u64 },
    .Row = struct { last_ordinal: u64, pending: u64 },
    .cardinality = .one,
});
const insert = rsql.Write(.{
    .sql = "INSERT INTO action_value(action_id,ordinal,handle,publication_key,content_id,admission_id,published_at) VALUES(?1,?2,?3,?4,?5,?6,@now)",
    .Args = struct { action_id: u64, ordinal: u64, handle: []const u8, key: []const u8, content_id: u64, admission_id: ?u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const PublishResult = Result;

pub const Publish = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .backlog = .{.always}, .fault = .{.branch} });
    pub const round_budget = 3;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { handle: []const u8, key: []const u8, bytes: []const u8 };
    pub const Result = PublishResult;
    pub const Ordinary = error{InjectedCommitFailure};
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    old: replay.Result = null,
    facts: facts.Result = undefined,
    live: action.live_by_handle.Result = null,
    imported: content.Import = undefined,
    key_buffer: [idempotency_key.max_bytes]u8 = undefined,
    reply: PublishResult = undefined,

    pub fn step(t: *Publish, r: *transition.Round(Publish), ran: ?rounds.At) !transition.Next(Publish) {
        const at = ran orelse {
            t.imported = .ofBytes(t.input.bytes, false);
            r.read(replay, .{ .handle = t.input.handle, .key = t.input.key }, &t.old);
            action.liveByHandle(r, t.input.handle, &t.live);
            content.lookup(r, &t.imported);
            return .{ .round = .facts };
        };
        if (at == .fault) return error.InjectedCommitFailure;
        if (at == .facts) {
            if (t.old) |saved| {
                if (!std.mem.eql(u8, &saved.digest, &t.imported.digest)) return .{ .done = .{ .refused = .conflict } };
                return .{ .done = .{ .accepted = .{ .action_id = saved.action_id.get(), .ordinal = saved.ordinal.get(), .admission_id = if (saved.admission_id) |id| id.get() else null, .replayed = true } } };
            }
            const found = t.live orelse return .{ .done = .{ .refused = .unknown_handle } };
            if (found.stopped) return .{ .done = .{ .refused = .stopped } };
            if (found.resolved) return .{ .done = .{ .refused = .resolved } };
            if (t.input.bytes.len > max_value_bytes) return .{ .done = .{ .refused = .too_large } };
            r.read(facts, .{ .action_id = found.action_id.get() }, &t.facts);
            return .{ .round = .backlog };
        }
        const found = if (t.live) |*live| live else unreachable;
        if (found.background and t.facts.pending >= max_pending) return .{ .done = .{ .refused = .backlog_full } };
        const ordinal = t.facts.last_ordinal + 1;
        const content_id = try content.importBytes(r, &t.imported, t.input.bytes);
        var admission_id: ?u64 = null;
        if (found.background) {
            const command_key = std.fmt.bufPrint(&t.key_buffer, "rui.core/action-value/{d}/{d}", .{ found.action_id.get(), ordinal }) catch unreachable;
            const digest = content_string.digest(command_key);
            try command.queueCommand(r, command_key, .message, &found.session.ref, &digest, content_id, null, &.{ .accepted = true });
            admission_id = try sourced_input.queue(r, &found.session, .{ .action_value = .{ .key = command_key, .action_id = found.action_id.get(), .ordinal = ordinal } }, content_id);
        }
        r.write(insert, .{ .action_id = found.action_id.get(), .ordinal = ordinal, .handle = t.input.handle, .key = t.input.key, .content_id = content_id, .admission_id = admission_id });
        t.reply = .{ .accepted = .{ .action_id = found.action_id.get(), .ordinal = ordinal, .admission_id = admission_id, .replayed = false } };
        if (r.faults().before_commit) return .{ .round = .fault };
        return .commit;
    }

    pub fn committed(t: *const Publish) PublishResult {
        return t.reply;
    }
};
