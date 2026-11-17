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
    after: u64 = 0,
    ceiling: u64 = 0,
    since: ?change_ring.Token = null,
    changed: ?ChangedCursor = null,

    pub const ChangedCursor = struct { through: u64, after_reference: change_ring.Id };

    pub fn validate(self: *const ListSessions) error{InvalidCursor}!void {
        if (self.after > std.math.maxInt(i64) or self.ceiling > std.math.maxInt(i64) or
            (self.after == 0 and self.ceiling != 0) or
            (self.after != 0 and self.after > self.ceiling)) return error.InvalidCursor;
        if (self.since != null and self.after != 0) return error.InvalidCursor;
        if (self.changed) |changed| {
            const since = self.since orelse return error.InvalidCursor;
            if (changed.through < since.generation or !session_id.valid(&changed.after_reference)) return error.InvalidCursor;
        }
    }
};

pub const Row = struct {
    read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
    archive_state: session_archive.State,
    pin_order: ?@import("session_pin.zig").PinOrder = null,
    reference: []const u8,
    parent: ?[]const u8,
    creator: ?[]const u8 = null,
    workspace: []const u8,
    provider: provider_name.Provider,
    model: []const u8,
    tools: []const []const u8,
    permission_mode: cli_value.PermissionMode,
    label: ?[]const u8,
    created_at: u64,
    state_change_at: u64,
    revision: u64,
    end: u64,
    first_message: ?FirstMessage,
    last_line: ?LastLine,
    work: session_work.Work,
    peers: Peers,
};

pub const LastLine = struct { position: u64, text: ?[]const u8 };

pub const SavedLastLine = struct {
    position: u64,
    text: ?Bounded(max_last_line_bytes) = null,
};

pub const Snapshot = struct {
    read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
    work: session_work.Work,
    last_line: ?SavedLastLine = null,
};

pub const FirstMessage = struct {
    position: u64,
    admission: u64,
    admitted_at: u64,
    sender: ?Bounded(session_id.max_reference_bytes),
    length: u64,
    digest: [32]u8,
};

pub const Peers = struct { from_person_at: ?u64 };

pub const Tail = union(enum) {
    full: struct { since: []const u8, after: u64, ceiling: u64 },
    changed: struct { since: []const u8, through: u64, after_reference: *const change_ring.Id },
    last: struct { delta: ListDelta, since: []const u8 },
};
