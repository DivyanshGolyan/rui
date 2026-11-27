//! What the Host answers when the row a stored reference names is gone.
//!
//! The Store carries no FOREIGN KEY in its v1 form, so a database team may delete any row directly and the database
//! will not object. The Host's rule is that a gone target has a typed outcome and is never `CorruptStore`.
//! This file owns the table of those outcomes, one per reference of the schema value, so the generated test that
//! deletes each target in turn is driven by the same list `rui store check` reads. A reference not yet decided is
//! `.undecided`; the count of those only shrinks (design: #2371).
const std = @import("std");
const schema = @import("schema.zig");

pub const Outcome = enum {
    /// The Session is gone: reads and commands answer `SessionNotFound`; a Turn running on it ends with a typed error.
    session_not_found,
    /// A link from one Session to another (a forward, a stop owed) whose other end is gone: the link is treated as
    /// absent, and a stop owed to a gone child counts as settled.
    link_absent,
    /// Shared content whose row is gone: the read carries a typed "content unavailable" part, and a Turn that needed it
    /// fails with a typed error.
    content_unavailable,
    /// Not decided yet; the Host may still read this as `CorruptStore`.
    undecided,
};

/// The outcome for a reference of `table`, named by the key's own columns and parent.
pub fn outcome(comptime table: []const u8, comptime key: schema.ForeignKey) Outcome {
    if (std.mem.eql(u8, key.references, "content")) return .content_unavailable;
    if (std.mem.eql(u8, key.references, "session")) {
        const links = std.mem.eql(u8, table, "session_forward") or std.mem.eql(u8, table, "session_stop_owed");
        return if (links) .link_absent else .session_not_found;
    }
    return .undecided;
}

/// The references of the schema value still `.undecided`, as `table(columns)->parent`.
pub fn undecided() []const []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (schema.tables) |table| for (table.foreign_keys) |key| {
            if (outcome(table.name, key) != .undecided) continue;
            var columns: []const u8 = "";
            for (key.columns, 0..) |column, position| columns = columns ++ (if (position == 0) "" else ",") ++ column;
            names = names ++ .{table.name ++ "(" ++ columns ++ ")->" ++ key.references};
        };
        break :blk names;
    };
}

test "SH-188 every reference of the schema has an outcome for a gone target and the undecided ones only shrink" {
    var decided: [3]usize = @splat(0);
    comptime var total: usize = 0;
    inline for (schema.tables) |table| inline for (table.foreign_keys) |key| {
        total += 1;
        switch (comptime outcome(table.name, key)) {
            .session_not_found => decided[0] += 1,
            .link_absent => decided[1] += 1,
            .content_unavailable => decided[2] += 1,
            .undecided => {},
        }
    };
    try std.testing.expectEqual(total, decided[0] + decided[1] + decided[2] + undecided().len);
    // Links: session_forward names two Sessions and session_stop_owed names one.
    try std.testing.expectEqual(@as(usize, 3), decided[1]);
    // Lower this number when a reference is decided; raising it is a new undecided reference.
    try std.testing.expect(undecided().len <= undecided_ceiling);
}

const undecided_ceiling = 54;
