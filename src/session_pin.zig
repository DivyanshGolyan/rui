//! Session pin organization, independent of work and configuration.
const std = @import("std");
const session_archive = @import("session_archive.zig");

/// The globally ordered command that first changed an unpinned Session to pinned.
pub const PinOrder = u64;
pub const Change = enum { keep, pin, unpin };

pub fn decide(archive: session_archive.State, current: ?PinOrder, pinned: bool) error{ SessionArchiving, SessionArchived }!Change {
    if (pinned) switch (archive) {
        .active => {},
        .archiving => return error.SessionArchiving,
        .archived => return error.SessionArchived,
    };
    return if (pinned == (current != null)) .keep else if (pinned) .pin else .unpin;
}

test "pin admission covers archive state current pin and desired value" {
    for (std.enums.values(session_archive.State)) |archive| for ([_]?PinOrder{ null, 1, std.math.maxInt(i64) }) |current| for ([_]bool{ false, true }) |pinned| {
        if (pinned and archive == .archiving) {
            try std.testing.expectError(error.SessionArchiving, decide(archive, current, pinned));
        } else if (pinned and archive == .archived) {
            try std.testing.expectError(error.SessionArchived, decide(archive, current, pinned));
        } else {
            const expected: Change = if (pinned) (if (current == null) .pin else .keep) else (if (current == null) .keep else .unpin);
            try std.testing.expectEqual(expected, try decide(archive, current, pinned));
        }
    };
}
