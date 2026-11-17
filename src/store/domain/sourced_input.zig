//! Admission of sourced Messages to a Session's input queue.

const rsql = @import("../rsql.zig");

pub const Source = union(enum) {
    person: []const u8,
    peer: struct {
        key: []const u8,
        sender: *const rsql.SessionHead,
    },
};

/// Queue one admission in the caller's transaction and return its identity.
/// The caller has already queued the Command and read or created the Session
/// heads in this transaction. A peer claims the target position first, even
/// when both heads name the same Session.
pub fn admit(a: anytype, target: *const rsql.SessionHead, source: Source, content_id: u64) !u64 {
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
            .sender = peer.sender.*,
            .sender_position = try (try a.positions(peer.sender.*)).take(1),
        }),
    }
    return admission_id;
}

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
