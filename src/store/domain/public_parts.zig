//! Session-scoped reads of the parts of one Message or Action Resolution.
//! Owns the owner-resolution rule; the list certifies, part opens are indexed.
const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const content_value = @import("../../content_value.zig");
const access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const content = @import("content.zig");
const parts = @import("content_parts.zig");
const input_parts = @import("../../input_parts.zig");
const action_read = @import("action_read.zig");
const sourced_input = @import("sourced_input.zig");
const Mapped = @import("../../os/pages.zig").Mapped;

pub const Progress = union(enum) {
    pending,
    /// Manifest digest, decoding, count trailer, contiguous index and every part identity are certified.
    /// Emitted once, before the first part.
    certified: content_value.Value.Parts,
    part: content_value.Part,
    done,
};

pub const Reader = struct {
    session: Bounded(session_id.max_reference_bytes),
    owner: content_value.Owner,
    phase: enum { resolve, parts, done } = .resolve,
    value: content.Value = undefined,
    cursor: ?Mapped(parts.Cursor) = null,

    pub fn init(session: Bounded(session_id.max_reference_bytes), owner: content_value.Owner) !Reader {
        return .{ .session = session, .owner = owner, .cursor = try Mapped(parts.Cursor).map() };
    }

    pub fn deinit(self: *Reader) void {
        if (self.cursor) |cursor| cursor.unmap();
        self.cursor = null;
        self.phase = .done;
    }
};

comptime {
    if (@sizeOf(Reader) > 512 or @sizeOf(Progress) > 512) @compileError("public part traversal must keep Host stack storage bounded");
}

/// One bounded effect per call; Store.readPublicParts runs one call per queue entry.
pub fn step(a: anytype, reader: *Reader) !Progress {
    switch (reader.phase) {
        .resolve => {
            reader.value = try resolve(a, reader.session.slice(), reader.owner);
            reader.cursor.?.value.init(reader.value);
            reader.phase = .parts;
            return .pending;
        },
        .parts => return switch (try reader.cursor.?.value.step(a)) {
            .raw => .pending,
            .rows => blk: {
                try access.runAs(a, error.CorruptStore);
                break :blk .pending;
            },
            .certified => .{ .certified = .{ .identity = reader.value.reference.parts, .owner = reader.owner } },
            .part => |part| .{ .part = .{ .ordinal = part.ordinal, .kind = part.kind, .reference = part.reference } },
            .done => blk: {
                reader.deinit();
                break :blk .done;
            },
        },
        .done => return .done,
    }
}

/// O(1): owner, then its value, then `content_part(content_id, ordinal)`, then the part row.
/// The list certifies manifest-to-index agreement; whole reads of the returned
/// location authenticate the part's bytes against that part's own identity.
pub fn openPart(a: anytype, session: []const u8, owner: content_value.Owner, ordinal: u32, start: u64) !content.ContentLocation {
    const value = try resolve(a, session, owner);
    var selected: part_row.Result = null;
    a.read(part_row, .{ .content_id = value.content_id, .ordinal = ordinal }, &selected);
    try access.runAs(a, error.CorruptStore);
    const row = selected orelse return error.ContentNotFound;
    if (row.private or try input_parts.Form.decode(row.form) != .bytes) return error.CorruptStore;
    if (start > row.byte_length) return error.RangeOutOfBounds;
    return .{ .store = a.store, .content_id = @intCast(row.part_content_id.get()), .reference = .{ .length = row.byte_length, .digest = row.digest } };
}

/// The one owner rule, shared by `step` and `openPart`; Session scoping lives only here.
/// A Message belongs to its receiving and its sending Session; an Action to its own
/// Session through its saved public Resolution. Only a parts value has parts.
fn resolve(a: anytype, session: []const u8, owner: content_value.Owner) !content.Value {
    if (owner.id() == 0 or owner.id() > std.math.maxInt(i64)) return error.ContentNotFound;
    const value = switch (owner) {
        .message => |admission| blk: {
            var row: message.Result = null;
            a.read(message, .{ .session = session, .admission = admission }, &row);
            try access.runAs(a, error.CorruptStore);
            const found = row orelse return error.ContentNotFound;
            if (!found.consistent or (found.private orelse return error.CorruptStore)) return error.CorruptStore;
            break :blk try content.Value.of(found.content_id.get(), found.form orelse return error.CorruptStore, found.byte_length orelse return error.CorruptStore, found.digest orelse return error.CorruptStore);
        },
        .action => |action| (try action_read.readPublicResolution(a, session, action)).value,
    };
    if (value.reference == .bytes) return error.ContentIsText;
    return value;
}

const message = rsql.Read(.{
    .sql = "SELECT m.content_id,c.byte_length,c.digest,c.private,c.form,CASE WHEN " ++
        sourced_input.consistentSql("m", "command") ++
        " AND (m.turn_id IS NULL OR (t.session_ref=m.session_ref AND EXISTS(SELECT 1 FROM conversation_entry e " ++
        "WHERE e.source_admission_id=m.admission_id AND e.session_ref=m.session_ref AND e.turn_id=m.turn_id AND e.content_id=m.content_id))) " ++
        "THEN 1 ELSE 0 END AS consistent FROM message_admission m LEFT JOIN content c ON c.content_id=m.content_id " ++
        "LEFT JOIN core_command command ON command.command_key=m.command_key LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
        "WHERE m.admission_id=?2 AND (m.session_ref=?1 OR m.sender_session_ref=?1)",
    .Args = struct { session: []const u8, admission: u64 },
    .Row = struct { content_id: rsql.Positive, byte_length: ?u64, digest: ?[32]u8, private: ?bool, form: ?u8, consistent: bool },
    .cardinality = .optional,
});

const part_row = rsql.Read(.{
    .sql = "SELECT cp.part_content_id,p.byte_length,p.digest,p.private,p.form FROM content_part cp " ++
        "JOIN content p ON p.content_id=cp.part_content_id WHERE cp.content_id=?1 AND cp.ordinal=?2",
    .Args = struct { content_id: u64, ordinal: u32 },
    .Row = struct { part_content_id: rsql.Positive, byte_length: u64, digest: [32]u8, private: bool, form: u8 },
    .cardinality = .optional,
});
