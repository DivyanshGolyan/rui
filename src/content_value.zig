//! The public projection of one stored Content value. Shared by Store readers,
//! protocol shapes, host replies and every Zig client.
const std = @import("std");
const input_parts = @import("input_parts.zig");

/// `rui/content/v1` identity of exact bytes, or `rui/input-parts/v1` identity of a manifest.
pub const Reference = input_parts.ContentReference;

/// The Session-scoped row that holds a parts value. The Host resolves it inside the
/// request's Session; a caller never names content directly.
pub const Owner = union(enum) {
    /// A Message admission, readable from its receiving Session and its sending Session.
    message: u64,
    /// An Action, through its saved public Resolution.
    action: u64,

    pub const Kind = std.meta.Tag(Owner);

    pub fn of(kind: Kind, value: u64) Owner {
        return switch (kind) {
            .message => .{ .message = value },
            .action => .{ .action = value },
        };
    }

    pub fn id(self: Owner) u64 {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

pub const Value = union(enum) {
    /// Form bytes: the identity of the exact bytes.
    text: Reference,
    /// Form parts: the manifest identity and the owner that addresses its parts.
    parts: Parts,

    pub const Parts = struct { identity: Reference, owner: Owner };

    pub fn identity(self: Value) Reference {
        return switch (self) {
            .text => |reference| reference,
            .parts => |parts| parts.identity,
        };
    }
};

/// One certified part, as the list reply carries it. `reference` is the part's own Store content identity.
pub const Part = struct {
    ordinal: u32,
    kind: input_parts.Kind,
    reference: Reference,
};

comptime {
    if (@sizeOf(Part) > 512) @compileError("a decoded part must stay stack-sized");
}
