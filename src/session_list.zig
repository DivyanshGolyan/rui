//! Session listing requests and pagination.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_archive = @import("session_archive.zig");
const session_id = @import("session_id.zig");
const store_path = @import("store_path.zig");
const workspace_path = @import("workspace_path.zig");
const change_ring = @import("change_ring.zig");

pub const session_list_page_size: usize = 8;
pub const ListDelta = enum { not_modified, changed, full };

pub const ListSessions = struct {
    archive: session_archive.Filter = .active,
    store: Bounded(store_path.max_bytes) = .{},
    workspace: ?Bounded(workspace_path.max_bytes) = null,
    // Zero/zero begins a traversal. A continuation carries both values.
    after: u64 = 0,
    ceiling: u64 = 0,
    /// A token from an earlier reply: answer only what changed since it.
    since: ?change_ring.Token = null,
    /// A changed continuation: the first page's generation, and the last
    /// Session the previous page gave.
    changed: ?ChangedCursor = null,

    pub const ChangedCursor = struct { through: u64, after_reference: change_ring.Id };

    pub fn validate(self: *const ListSessions) error{InvalidCursor}!void {
        if (self.after > std.math.maxInt(i64) or self.ceiling > std.math.maxInt(i64) or
            (self.after == 0 and self.ceiling != 0) or
            (self.after != 0 and self.after > self.ceiling)) return error.InvalidCursor;
        // A full continuation needs no token; a changed one needs its own.
        if (self.since != null and self.after != 0) return error.InvalidCursor;
        if (self.changed) |changed| {
            const since = self.since orelse return error.InvalidCursor;
            if (changed.through < since.generation or !session_id.valid(&changed.after_reference)) return error.InvalidCursor;
        }
    }
};
