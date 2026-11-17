const std = @import("std");
const rsql = @import("../rsql.zig");
const action = @import("action.zig");
const content = @import("content.zig");
const command = @import("command.zig");
const sourced_input = @import("sourced_input.zig");
const content_string = @import("../../content_string.zig");
const idempotency_key = @import("../../idempotency_key.zig");

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

pub fn publish(a: anytype, handle: []const u8, key: []const u8, bytes: []const u8, faults: @import("../Store.zig").Faults) !Result {
    var old: replay.Result = null;
    var row: facts.Result = undefined;
    var live: action.live_by_handle.Result = null;
    var imported = content.Import.ofBytes(bytes, false);
    a.read(replay, .{ .handle = handle, .key = key }, &old);
    action.liveByHandle(a, handle, &live);
    content.lookup(a, &imported);
    try a.run();
    if (old) |saved| {
        if (!std.mem.eql(u8, &saved.digest, &imported.digest)) return .{ .refused = .conflict };
        return .{ .accepted = .{ .action_id = saved.action_id.get(), .ordinal = saved.ordinal.get(), .admission_id = if (saved.admission_id) |id| id.get() else null, .replayed = true } };
    }
    const found = live orelse return .{ .refused = .unknown_handle };
    if (found.stopped) return .{ .refused = .stopped };
    if (found.resolved) return .{ .refused = .resolved };
    if (bytes.len > max_value_bytes) return .{ .refused = .too_large };
    a.read(facts, .{ .action_id = found.action_id.get() }, &row);
    try a.run();
    if (found.background and row.pending >= max_pending) return .{ .refused = .backlog_full };
    const ordinal = row.last_ordinal + 1;
    const content_id = try content.importBytes(a, &imported, bytes);
    var key_buffer: [idempotency_key.max_bytes]u8 = undefined;
    var admission_id: ?u64 = null;
    if (found.background) {
        const command_key = std.fmt.bufPrint(&key_buffer, "rui.core/action-value/{d}/{d}", .{ found.action_id.get(), ordinal }) catch unreachable;
        const digest = content_string.digest(command_key);
        try command.queueCommand(a, command_key, .message, &found.session.ref, &digest, content_id, null, &.{ .accepted = true });
        admission_id = try sourced_input.queue(a, &found.session, .{ .action_value = .{ .key = command_key, .action_id = found.action_id.get(), .ordinal = ordinal } }, content_id);
    }
    a.write(insert, .{ .action_id = found.action_id.get(), .ordinal = ordinal, .handle = handle, .key = key, .content_id = content_id, .admission_id = admission_id });
    if (faults.before_commit) {
        try a.run();
        return error.InjectedCommitFailure;
    }
    try a.commit();
    return .{ .accepted = .{ .action_id = found.action_id.get(), .ordinal = ordinal, .admission_id = admission_id, .replayed = false } };
}
