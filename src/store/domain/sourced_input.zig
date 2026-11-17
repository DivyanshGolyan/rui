const std = @import("std");
const command_domain = @import("command.zig");
const content_string = @import("../../content_string.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const rsql = @import("../rsql.zig");

pub const SourceKind = enum(u8) { person = 1, peer = 2, action_final = 3, action_value = 4, server_event = 5 };

pub const Source = union(enum) {
    person: []const u8,
    peer: struct { key: []const u8, session: rsql.SessionHead },
    action_final: struct { key: []const u8, action_id: u64 },
    action_value: struct { key: []const u8, action_id: u64, ordinal: u64 },

    pub fn kind(source: Source) SourceKind {
        return switch (source) {
            .person => .person,
            .peer => .peer,
            .action_final => .action_final,
            .action_value => .action_value,
        };
    }
};

pub fn personSql(comptime m: []const u8) []const u8 {
    return m ++ ".source_kind=1";
}

pub fn messageSql(comptime m: []const u8) []const u8 {
    return m ++ ".source_kind IN (1,2)";
}

pub fn consistentSql(comptime message: []const u8, comptime command: []const u8) []const u8 {
    return command ++ ".kind=2 AND " ++ command ++ ".accepted=1 AND " ++
        command ++ ".target=" ++ message ++ ".session_ref AND " ++
        command ++ ".primary_content_id=" ++ message ++ ".content_id AND (" ++ message ++ ".source_action_id IS NULL OR EXISTS(" ++
        "SELECT 1 FROM action_operation source WHERE source.action_id=" ++ message ++ ".source_action_id AND source.session_ref=" ++ message ++
        ".session_ref AND source.background_position IS NOT NULL AND source.resolution_code IS NOT NULL AND source.resolution_content_id=" ++ message ++ ".content_id)) AND ((" ++ message ++ ".source_kind<>4 AND NOT EXISTS(SELECT 1 FROM action_value v WHERE v.admission_id=" ++ message ++ ".admission_id)) OR (" ++ message ++ ".source_kind=4 AND EXISTS(SELECT 1 FROM action_value v JOIN action_operation source ON source.action_id=v.action_id WHERE v.admission_id=" ++ message ++ ".admission_id AND v.content_id=" ++ message ++ ".content_id AND source.session_ref=" ++ message ++ ".session_ref AND source.background_position IS NOT NULL)))";
}

const admit_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,source_kind) VALUES(?1,@session(?2),?3,?4,?5,@now,?6)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, source_kind: u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
pub const person_sql = admit_message.sql;

const admit_sent_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position,source_kind) " ++
        "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?6),?7,?8)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, sender: rsql.SessionHead, sender_position: u64, source_kind: u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The source is the sole Resolution; content_id references its existing bytes.
const admit_action_final = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,source_action_id,source_kind) VALUES(?1,@session(?2),?3,?4,?5,@now,?6,?7)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, action_id: u64, source_kind: u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Storage for the internal command key until its settlement round commits.
/// Like attached child endings, these inputs use the reserved core key domain.
/// The caller's Resolution transaction is the only admission authority: no
/// Resolution can commit without its input, and replay cannot resolve it again.
pub const Final = struct {
    pub const State = struct { background: bool, stopped: bool };
    key_buffer: [idempotency_key.max_bytes]u8 = undefined,

    pub fn admit(final: *Final, a: anytype, session: *const rsql.SessionHead, action_id: u64, content_id: u64, state: State) !void {
        if (!state.background or state.stopped) return;
        const key = std.fmt.bufPrint(&final.key_buffer, "rui.core/action-final/{d}", .{action_id}) catch unreachable;
        const digest = content_string.digest(key);
        try command_domain.queueCommand(a, key, .message, &session.ref, &digest, content_id, null, &.{ .accepted = true });
        _ = try queue(a, session, .{ .action_final = .{ .key = key, .action_id = action_id } }, content_id);
    }
};

pub fn queue(a: anytype, target: *const rsql.SessionHead, source: Source, content_id: u64) !u64 {
    const admission_id = try a.identity(.admission_id);
    const position = try (try a.positions(target.*)).take(1);
    const source_kind = @backingInt(source.kind());
    switch (source) {
        .action_final => |final| a.write(admit_action_final, .{
            .admission_id = admission_id,
            .session = target.*,
            .key = final.key,
            .content_id = content_id,
            .position = position,
            .source_kind = source_kind,
            .action_id = final.action_id,
        }),
        .action_value => |value| a.write(admit_message, .{
            .admission_id = admission_id,
            .session = target.*,
            .key = value.key,
            .content_id = content_id,
            .position = position,
            .source_kind = source_kind,
        }),
        .person => |key| a.write(admit_message, .{
            .admission_id = admission_id,
            .session = target.*,
            .key = key,
            .content_id = content_id,
            .position = position,
            .source_kind = source_kind,
        }),
        .peer => |peer| a.write(admit_sent_message, .{
            .admission_id = admission_id,
            .session = target.*,
            .key = peer.key,
            .content_id = content_id,
            .position = position,
            .source_kind = source_kind,
            .sender = peer.session,
            .sender_position = try (try a.positions(peer.session)).take(1),
        }),
    }
    return admission_id;
}
