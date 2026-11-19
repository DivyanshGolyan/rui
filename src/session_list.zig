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
const content_value = @import("content_value.zig");
const session_line = @import("session_line.zig");

pub const session_list_page_size: usize = 8;
/// Archived rows per window page: one tall overview screen (about 40 rows at 24+ lines). A slim row is
/// at most `ArchivedRow.max_json_bytes`, so a full page is `archived_window_size * max_json_bytes` bytes
/// (about 88 KiB), inside the list reply bound that a live page already allows (8 full rows at 36 KiB
/// each, 288 KiB).
pub const archived_window_size: usize = 40;
pub const max_last_line_bytes = 200;
/// The longest first Message line an Archived row carries: the overview's display cut (session_line).
pub const max_first_line_bytes = session_line.max_line_bytes;
pub const ListDelta = enum { not_modified, changed, full, window };

pub const ListSessions = struct {
    archive: session_archive.Filter = .active,
    store: Bounded(store_path.max_bytes) = .{},
    workspace: ?Bounded(workspace_path.max_bytes) = null,
    after: u64 = 0,
    ceiling: u64 = 0,
    since: ?change_ring.Token = null,
    changed: ?ChangedCursor = null,
    /// Archived display window. Valid only with archive=.archived, no workspace, no since and after=0.
    window: ?ArchivedCursor = null,

    pub const ChangedCursor = struct { through: u64, after_reference: change_ring.Id };

    pub fn validate(self: *const ListSessions) error{InvalidCursor}!void {
        if (self.after > std.math.maxInt(i64) or self.ceiling > std.math.maxInt(i64) or
            (self.after == 0 and self.ceiling != 0) or
            (self.after != 0 and self.after > self.ceiling)) return error.InvalidCursor;
        if (self.since != null and self.after != 0) return error.InvalidCursor;
        if (self.window) |window| {
            if (self.archive != .archived or self.workspace != null or self.since != null or self.changed != null or self.after != 0 or self.ceiling != 0) return error.InvalidCursor;
            switch (window) {
                .head, .tail => {},
                .below, .above => |key| if (key == 0 or key > std.math.maxInt(i64)) return error.InvalidCursor,
            }
            return;
        }
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
    /// The Host key of an Archived Session (`session.archive_seq`); null while live.
    archive_seq: ?ArchiveSeq = null,
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
    subtree_state_change_at: u64,
    descendant_count: u64,
    descendant_needs_you_count: u64,
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
    content: content_value.Value,
};

pub const Peers = struct { from_person_at: ?u64 };

/// The Host key of an archive request: its `core_command.command_seq`. Unique, and monotonic in archive order.
pub const ArchiveSeq = u64;

/// Which Archived window page to read. `below(k)` and `above(k)` are exclusive keys. Pages are always
/// returned newest first.
pub const ArchivedCursor = union(enum) {
    /// The newest Archived Sessions.
    head,
    /// The oldest Archived Sessions.
    tail,
    /// The Archived Sessions whose key is below `k`, the newest first.
    below: ArchiveSeq,
    /// The Archived Sessions whose key is above `k`, the nearest to `k` first.
    above: ArchiveSeq,
};

/// The request text of an ArchivedCursor: `head`, `tail`, `below:<key>` or `above:<key>`.
pub const archived_cursor_text_bytes = "above:".len + std.fmt.count("{d}", .{std.math.maxInt(i64)});

pub fn formatArchivedCursor(cursor: ArchivedCursor, buffer: *[archived_cursor_text_bytes]u8) []const u8 {
    return switch (cursor) {
        .head => "head",
        .tail => "tail",
        .below => |key| std.fmt.bufPrint(buffer, "below:{d}", .{key}) catch unreachable,
        .above => |key| std.fmt.bufPrint(buffer, "above:{d}", .{key}) catch unreachable,
    };
}

/// Parses the request text of an ArchivedCursor. Keys are canonical decimals in 1..maxInt(i64).
pub fn parseArchivedCursor(text: []const u8) error{InvalidCursor}!ArchivedCursor {
    if (std.mem.eql(u8, text, "head")) return .head;
    if (std.mem.eql(u8, text, "tail")) return .tail;
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidCursor;
    const digits = text[colon + 1 ..];
    if (digits.len == 0 or digits.len > 19 or (digits.len > 1 and digits[0] == '0')) return error.InvalidCursor;
    for (digits) |byte| if (byte < '0' or byte > '9') return error.InvalidCursor;
    const key = std.fmt.parseUnsigned(u64, digits, 10) catch return error.InvalidCursor;
    if (key == 0 or key > std.math.maxInt(i64)) return error.InvalidCursor;
    if (std.mem.eql(u8, text[0..colon], "below")) return .{ .below = key };
    if (std.mem.eql(u8, text[0..colon], "above")) return .{ .above = key };
    return error.InvalidCursor;
}

/// A slim Archived row: only what the Archived tab draws. `name` is `session_line.name(label, first
/// line, reference)`, and the age is `stopped_at`.
pub const ArchivedRow = struct {
    reference: []const u8,
    archive_seq: ArchiveSeq,
    stopped_at: u64,
    label: ?[]const u8,
    /// Null when the Session has no first Message (the name is the new-Session name).
    first: ?ArchivedFirst,

    /// Bytes of JSON for one slim row at its worst case: the protocol shape computes 2538 (reference, label,
    /// position and admission ids, the parts content reference with its owner, the line at
    /// `max_first_line_bytes`, the fixed fields). protocol.zig asserts it.
    pub const max_json_bytes: usize = 2538;
};

/// The first Message of an Archived Session: what the overview's first-line read needs (position, admission
/// and content reference, as the live row's FirstMessage gives it), and the line when it is inline Text.
pub const ArchivedFirst = struct {
    admission: u64,
    position: u64,
    content: content_value.Value,
    /// The first display line (session_line.firstLine), cut to `max_first_line_bytes`: the same line the
    /// overview's first-line read gives. Null when the first Message is parts-form (its line comes from the
    /// overview's own first-line read) or its first line is blank.
    line: ?[]const u8,
};

pub const Tail = union(enum) {
    full: struct { since: []const u8, after: u64, ceiling: u64 },
    changed: struct { since: []const u8, through: u64, after_reference: *const change_ring.Id },
    last: struct { delta: ListDelta, since: []const u8 },
    /// `first` and `last` are the archive keys of the page's first (newest) and last (oldest) rows.
    /// `more_below` is exact for `head` and `below`, `more_above` for `tail` and `above`. The other flag is a
    /// hint: true when a page was there when the cursor was made. A page with no rows has null `first` and
    /// `last`, and its client re-reads from `head`. docs/contracts/inspection.md states the contract.
    window: struct { since: []const u8, first: ?ArchiveSeq, last: ?ArchiveSeq, more_above: bool, more_below: bool },
};
