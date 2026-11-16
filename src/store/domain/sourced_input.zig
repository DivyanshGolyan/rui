const rsql = @import("../rsql.zig");

pub const Source = union(enum) {
    person: []const u8,
    peer: struct { key: []const u8, session: rsql.SessionHead },
};

pub fn consistentSql(comptime message: []const u8, comptime command: []const u8) []const u8 {
    return command ++ ".kind=2 AND " ++ command ++ ".accepted=1 AND " ++
        command ++ ".target=" ++ message ++ ".session_ref AND " ++
        command ++ ".primary_content_id=" ++ message ++ ".content_id";
}

const admit_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) VALUES(?1,@session(?2),?3,?4,?5,@now)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
pub const person_sql = admit_message.sql;

const admit_sent_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
        "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?6),?7)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, sender: rsql.SessionHead, sender_position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn queue(a: anytype, target: *const rsql.SessionHead, source: Source, content_id: u64) !u64 {
    const admission_id = try a.identity(.admission_id);
    const position = try (try a.positions(target.*)).take(1);
    switch (source) {
        .person => |key| a.write(admit_message, .{
            .admission_id = admission_id,
            .session = target.*,
            .key = key,
            .content_id = content_id,
            .position = position,
        }),
        .peer => |peer| a.write(admit_sent_message, .{
            .admission_id = admission_id,
            .session = target.*,
            .key = peer.key,
            .content_id = content_id,
            .position = position,
            .sender = peer.session,
            .sender_position = try (try a.positions(peer.session)).take(1),
        }),
    }
    return admission_id;
}
