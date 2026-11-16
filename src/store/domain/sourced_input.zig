//! Admission identities, positions and rows for Session input.

const rsql = @import("../rsql.zig");

/// The command that admits the input and, for a peer, its already-read sender.
pub const Source = union(enum) {
    person: []const u8,
    peer: struct { key: []const u8, sender: rsql.SessionHead },
};

/// A person's Message.
const admit_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) VALUES(?1,@session(?2),?3,?4,?5,@now)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
pub const admit_message_sql = admit_message.sql;

/// A peer's Message: the sender's own position orders the send among its
/// other facts.
const admit_sent_message = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
        "VALUES(?1,@session(?2),?3,?4,?5,@now,@session(?6),?7)",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, sender: rsql.SessionHead, sender_position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Heads were read or created in the caller's transaction. Queue one
/// admission without reading or running a round; the caller owns the commit.
pub fn admit(a: anytype, target: rsql.SessionHead, content_id: u64, source: Source) !u64 {
    const admission_id = try a.identity(.admission_id);
    const position = try (try a.positions(target)).take(1);
    switch (source) {
        .person => |key| a.write(admit_message, .{
            .admission_id = admission_id,
            .session = target,
            .key = key,
            .content_id = content_id,
            .position = position,
        }),
        .peer => |peer| a.write(admit_sent_message, .{
            .admission_id = admission_id,
            .session = target,
            .key = peer.key,
            .content_id = content_id,
            .position = position,
            .sender = peer.sender,
            .sender_position = try (try a.positions(peer.sender)).take(1),
        }),
    }
    return admission_id;
}
