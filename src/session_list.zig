//! Session listing requests and pagination.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_archive = @import("session_archive.zig");
const session_id = @import("session_id.zig");
const store_path = @import("store_path.zig");
const workspace_path = @import("workspace_path.zig");
const change_ring = @import("change_ring.zig");
const cli_value = @import("cli_value.zig");
const provider_name = @import("provider_name.zig");
const session_work = @import("session_work.zig");

pub const session_list_page_size: usize = 8;
pub const max_last_line_bytes = 200;
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

/// One list row as the Store read it. Its slices borrow the Store's read
/// scratch and are valid only during the visitor's `row` call.
pub const Row = struct {
    archive_state: session_archive.State,
    reference: []const u8,
    parent: ?[]const u8,
    workspace: []const u8,
    provider: provider_name.Provider,
    model: []const u8,
    /// Valid, distinct tool names in name order.
    tools: []const []const u8,
    permission_mode: cli_value.PermissionMode,
    label: ?[]const u8,
    created_at: u64,
    revision: u64,
    /// The last activity position.
    end: u64,
    first_message: ?FirstMessage,
    last_line: ?LastLine,
    work: session_work.Work,
    peers: Peers,
};

/// The later of an ended Turn's outcome and the oldest pending approval's
/// call. Text borrows the row visitor's scratch; failures, stops and private
/// answers have no text.
pub const LastLine = struct { position: u64, text: ?[]const u8 };

/// A Session's first admitted Message.
pub const FirstMessage = struct {
    position: u64,
    admission: u64,
    admitted_at: u64,
    /// The Session that sent it, or null for a person or a script.
    sender: ?Bounded(session_id.max_reference_bytes),
    length: u64,
    digest: [32]u8,
};

/// When the latest Message with no Session sender was admitted, if any was.
pub const Peers = struct { from_person_at: ?u64 };

/// What follows a page's rows: its token (`since`, a formatted
/// `change_ring.Token`) and where the next page continues. Its slices
/// are valid only during the visitor's `tail` call.
pub const Tail = union(enum) {
    /// A full traversal with more Sessions after `after`, up to `ceiling`.
    full: struct { since: []const u8, after: u64, ceiling: u64 },
    /// A changed listing with more changed Sessions after `after_reference`.
    changed: struct { since: []const u8, through: u64, after_reference: *const change_ring.Id },
    /// The last page of a full or changed listing.
    last: struct { delta: ListDelta, since: []const u8 },
};
