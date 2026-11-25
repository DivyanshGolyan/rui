const std = @import("std");

/// Where an admitted input came from. The numbers are the saved `message_admission.source_kind` column and never change.
pub const SourceKind = enum(u8) {
    person = 1,
    peer = 2,
    action_final = 3,
    action_value = 4,
    server_event = 5,

    pub const Admission = enum { admission, received };

    /// Does input from this source have a row a person reading the conversation is shown?
    /// A background Action's final input and published values are stored and served but draw none.
    pub fn personFacing(self: SourceKind) bool {
        return switch (self) {
            .person, .peer, .server_event => true,
            .action_final, .action_value => false,
        };
    }

    /// The Activity row kind that admits input from this source (the Activity kind of the same name): a person's
    /// words as `admission` (their applied `user` entry speaks later), every other source as `received`.
    /// A published Action value is a `received` row once the Activity feed lists values (#2286), and nothing writes
    /// `server_event` yet, so its row shape (no sender, no action) is not exercised by any reader.
    /// This module is a leaf so the Store and Activity can both import it without joining a cycle.
    pub fn admitsAs(self: SourceKind) Admission {
        return switch (self) {
            .person => .admission,
            .peer, .action_final, .action_value, .server_event => .received,
        };
    }
};

test "ADM-34 a source kind says whether its input has a person-facing row and where Activity admits it" {
    const Case = struct { kind: SourceKind, person_facing: bool, admits: SourceKind.Admission };
    const cases = [_]Case{
        .{ .kind = .person, .person_facing = true, .admits = .admission },
        .{ .kind = .peer, .person_facing = true, .admits = .received },
        .{ .kind = .action_final, .person_facing = false, .admits = .received },
        .{ .kind = .action_value, .person_facing = false, .admits = .received },
        .{ .kind = .server_event, .person_facing = true, .admits = .received },
    };
    try std.testing.expectEqual(cases.len, std.enums.values(SourceKind).len);
    for (cases, 0..) |case, at| {
        try std.testing.expectEqual(@as(u8, @intCast(at + 1)), @backingInt(case.kind));
        try std.testing.expectEqual(case.person_facing, case.kind.personFacing());
        try std.testing.expectEqual(case.admits, case.kind.admitsAs());
    }
}
