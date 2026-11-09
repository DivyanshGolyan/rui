//! A submission's original as values: what it is, how far its Admission
//! got, and what an exit tells the person about it. `SessionSubmission`
//! owns the worker, capture and reply that move it.
const std = @import("std");

pub const Kind = enum { message, decision };
pub const State = enum { not_started, submitting, unconfirmed, rejected };
/// Whether the original's capture reached the Store: `unknown` once a
/// capture began and until it is known to be published.
pub const Publication = enum { not_sent, unknown, published };
pub const Accepted = struct { kind: Kind, key: [36]u8 };
pub const Recovery = union(enum) {
    none,
    not_sent: Kind,
    uncertain: [36]u8,
    saved: struct { original: Accepted, rejected: bool },
    accepted: Accepted,
};

/// The original a submission holds until it is accepted or discarded.
pub const Original = struct { kind: Kind, state: State, publication: Publication, key: [36]u8 };

/// What an exit tells the person: the held original, else the last one
/// accepted. An original never begun was not sent; one whose capture may
/// not be published is uncertain; a published one is saved under its key.
pub fn recovery(original: ?Original, accepted: ?Accepted) Recovery {
    const held = original orelse return if (accepted) |last| .{ .accepted = last } else .none;
    if (held.state == .not_started) return .{ .not_sent = held.kind };
    if (held.publication != .published) return .{ .uncertain = held.key };
    return .{ .saved = .{ .original = .{ .kind = held.kind, .key = held.key }, .rejected = held.state == .rejected } };
}

/// Where a failed Admission leaves its original: not started while nothing
/// was captured, else unconfirmed, since the Store may hold it.
pub fn failed(publication: Publication) State {
    return if (publication == .not_sent) .not_started else .unconfirmed;
}

test "an exit names the held original by how far it got, else the last accepted one" {
    const a: [36]u8 = @splat('A');
    const b: [36]u8 = @splat('B');
    const accepted: Accepted = .{ .kind = .message, .key = a };
    try std.testing.expectEqual(Recovery.none, recovery(null, null));
    try std.testing.expectEqual(Recovery{ .accepted = accepted }, recovery(null, accepted));
    // A held original speaks for itself, whatever was accepted before it.
    for (std.enums.values(Publication)) |publication| {
        try std.testing.expectEqual(Recovery{ .not_sent = .decision }, recovery(.{ .kind = .decision, .state = .not_started, .publication = publication, .key = b }, accepted));
    }
    for ([_]State{ .submitting, .unconfirmed, .rejected }) |state| {
        for ([_]Publication{ .not_sent, .unknown }) |publication| {
            try std.testing.expectEqual(Recovery{ .uncertain = b }, recovery(.{ .kind = .message, .state = state, .publication = publication, .key = b }, accepted));
        }
        const saved = recovery(.{ .kind = .message, .state = state, .publication = .published, .key = b }, accepted);
        try std.testing.expectEqual(Accepted{ .kind = .message, .key = b }, saved.saved.original);
        try std.testing.expectEqual(state == .rejected, saved.saved.rejected);
    }
}

test "a failed Admission retries only an original whose capture may have been published" {
    try std.testing.expectEqual(State.not_started, failed(.not_sent));
    try std.testing.expectEqual(State.unconfirmed, failed(.unknown));
    try std.testing.expectEqual(State.unconfirmed, failed(.published));
}
