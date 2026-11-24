const std = @import("std");
const rsql = @import("../rsql.zig");
const action = @import("action.zig");
const content = @import("content.zig");
const command = @import("command.zig");
const sourced_input = @import("sourced_input.zig");
const content_string = @import("../../content_string.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const transition = @import("../transition.zig");
const access = @import("../access.zig");
const Bounded = @import("../../bounded.zig").Bounded;

pub const max_value_bytes = @import("../../action_value_limits.zig").max_value_bytes;
pub const max_pending = 32;
pub const Receipt = struct { action_id: u64, ordinal: u64, admission_id: ?u64, replayed: bool };
pub const Refusal = enum { unknown_handle, stopped, resolved, not_background, conflict, too_large, backlog_full };
pub const Result = union(enum) { accepted: Receipt, refused: Refusal };

const replay = rsql.Read(.{
    .sql = "SELECT v.action_id,v.ordinal,v.admission_id,c.digest,c.form FROM action_value v JOIN content c ON c.content_id=v.content_id WHERE v.handle=?1 AND v.publication_key=?2",
    .Args = struct { handle: []const u8, key: []const u8 },
    .Row = struct { action_id: rsql.Positive, ordinal: rsql.Positive, admission_id: ?rsql.Positive, digest: [32]u8, form: u64 },
    .cardinality = .optional,
});
const host_live = rsql.Read(.{
    .sql = "SELECT action.action_id,s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background,action.resolution_code IS NOT NULL AS resolved," ++ action.actionStoppedSql("action", "operation") ++ " AS stopped,coalesce(action.sender_handle,'') AS handle FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id JOIN session s ON s.session_ref=action.session_ref WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action.attempt_ordinal=1 AND action.authorized=1",
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64 },
    .Row = struct { action_id: rsql.Positive, session: rsql.SessionHead, background: bool, resolved: bool, stopped: bool, handle: *Bounded(32) },
    .cardinality = .optional,
});
const host_replay = rsql.Read(.{
    .sql = "SELECT v.action_id,v.ordinal,v.admission_id,c.digest,c.form FROM action_value v JOIN content c ON c.content_id=v.content_id JOIN action_operation action ON action.action_id=v.action_id JOIN model_operation operation ON operation.operation_id=action.parent_operation_id WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action.attempt_ordinal=1 AND action.authorized=1 AND v.publication_key=?4",
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64, key: []const u8 },
    .Row = replay.Row,
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
    pub const Input = struct { source: union(enum) { handle: []const u8, host: action.ActionAttemptBinding }, key: []const u8, bytes: []const u8 };
    pub const Result = PublishResult;
    pub const Ordinary = error{InjectedCommitFailure};
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    old: replay.Result = null,
    facts: facts.Result = undefined,
    live: action.live_by_handle.Result = null,
    host_handle: Bounded(32) = .{ .len = 0 },
    host_row: host_live.Row = undefined,
    host_found: access.Found = .pending,
    imported: content.Import = undefined,
    key_buffer: [idempotency_key.max_bytes]u8 = undefined,
    reply: PublishResult = undefined,

    pub fn step(t: *Publish, r: *transition.Round(Publish), ran: ?rounds.At) !transition.Next(Publish) {
        const at = ran orelse {
            t.imported = .ofBytes(t.input.bytes, false);
            switch (t.input.source) {
                .handle => |handle| {
                    r.read(replay, .{ .handle = handle, .key = t.input.key }, &t.old);
                    action.liveByHandle(r, handle, &t.live);
                },
                .host => |binding| {
                    t.host_row = .{ .action_id = undefined, .session = undefined, .background = undefined, .resolved = undefined, .stopped = undefined, .handle = &t.host_handle };
                    r.readInto(host_live, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }, &t.host_row, &t.host_found);
                    r.read(host_replay, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id, .key = t.input.key }, &t.old);
                },
            }
            content.lookup(r, &t.imported);
            return .{ .round = .facts };
        };
        if (at == .fault) return error.InjectedCommitFailure;
        if (at == .facts) {
            if (t.old) |saved| {
                if (try @import("../../input_parts.zig").Form.decode(saved.form) != .bytes) return error.CorruptStore;
                if (!std.mem.eql(u8, &saved.digest, &t.imported.digest)) return .{ .done = .{ .refused = .conflict } };
                return .{ .done = .{ .accepted = .{ .action_id = saved.action_id.get(), .ordinal = saved.ordinal.get(), .admission_id = if (saved.admission_id) |id| id.get() else null, .replayed = true } } };
            }
            if (t.input.source == .host and t.host_found.get()) {
                const host = t.host_row;
                t.live = .{ .action_id = host.action_id, .session = host.session, .background = host.background, .resolved = host.resolved, .stopped = host.stopped };
            }
            const found = t.live orelse return .{ .done = .{ .refused = .unknown_handle } };
            if (found.stopped) return .{ .done = .{ .refused = .stopped } };
            if (found.resolved) return .{ .done = .{ .refused = .resolved } };
            if (t.input.source == .host and !found.background) return .{ .done = .{ .refused = .not_background } };
            if (t.input.source == .host and t.host_handle.len == 0) return .{ .done = .{ .refused = .unknown_handle } };
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
        r.write(insert, .{ .action_id = found.action_id.get(), .ordinal = ordinal, .handle = switch (t.input.source) {
            .handle => |handle| handle,
            .host => t.host_handle.slice(),
        }, .key = t.input.key, .content_id = content_id, .admission_id = admission_id });
        t.reply = .{ .accepted = .{ .action_id = found.action_id.get(), .ordinal = ordinal, .admission_id = admission_id, .replayed = false } };
        if (r.faults().before_commit) return .{ .round = .fault };
        return .commit;
    }

    pub fn committed(t: *const Publish) PublishResult {
        return t.reply;
    }
};
