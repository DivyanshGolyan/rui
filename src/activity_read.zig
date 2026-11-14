//! Activity read identities and certified proposal facts.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const store_path = @import("store_path.zig");
const session_id = @import("session_id.zig");
const tool_proposal = @import("tool_proposal.zig");
const change_ring = @import("change_ring.zig");

pub const Kind = enum { admission, user, assistant, call, tool_result, hosted_call, turn_ended, stop, sent, send_failed, received, approval_requested, session_changed, compacted, model_call };

pub const ActivityPage = struct {
    since: ?change_ring.SessionToken = null,
    store: Bounded(store_path.max_bytes) = .{},
    session: Bounded(session_id.max_reference_bytes) = .{},
    end: ?u64 = null,
    position: u64 = 0,
    // Null is a sequence boundary; a value identifies an actual public row.
    ordinal: ?u64 = null,
    direction: enum { forward, backward } = .forward,
    /// The row kinds the page lists; the cursor may name a row of any kind.
    kinds: Kinds = .full,
    /// At most this many rows, from 1 to `items`.
    limit: u8 = items,

    pub const Kinds = std.enums.EnumSet(Kind);
    pub const items = 16;

    /// By pointer: a by-value copy sat in the Store read frame on every
    /// engine chain that reads a page.
    pub fn validate(self: *const ActivityPage) !void {
        if (self.position > std.math.maxInt(i64) or (self.ordinal != null and
            (self.position == 0 or self.ordinal.? > std.math.maxInt(i64)))) return error.InvalidCursor;
        if (self.end) |end| if (end > std.math.maxInt(i64) or self.position > end) return error.InvalidCursor;
        if (self.kinds.count() == 0 or self.limit == 0 or self.limit > items) return error.InvalidCursor;
    }
};

pub const ActivitySearch = struct {
    store: Bounded(store_path.max_bytes) = .{},
    session: Bounded(session_id.max_reference_bytes) = .{},
    query: Bounded(256) = .{},
    kinds: ActivityPage.Kinds = .full,
    before_position: ?u64 = null,
    before_ordinal: ?u64 = null,
    limit: u8 = ActivityPage.items,

    pub fn validate(self: *const ActivitySearch) !void {
        if (self.query.len == 0 or !std.unicode.utf8ValidateSlice(self.query.slice())) return error.InvalidCursor;
        if (self.before_position) |position| {
            if (position == 0 or position > std.math.maxInt(i64)) return error.InvalidCursor;
        }
        if (self.before_ordinal) |ordinal| {
            if (self.before_position == null or ordinal > std.math.maxInt(i64)) return error.InvalidCursor;
        }
        if (self.kinds.count() == 0 or self.limit == 0 or self.limit > ActivityPage.items) return error.InvalidCursor;
    }
};

pub const ReadActivityContent = struct {
    store: Bounded(store_path.max_bytes) = .{},
    session: Bounded(session_id.max_reference_bytes) = .{},
    position: u64 = 0,
    ordinal: u64 = 0,
};

pub const ProposalFieldReference = struct { length: u64, digest: [32]u8 };
/// The certificate admission saves for a call's fields: for each, in
/// ProposalField order, its length (u64, little-endian) then its SHA-256.
pub const FieldCertificate = struct {
    const entry_bytes = 8 + 32;
    pub const Bytes = [3 * entry_bytes]u8;

    pub fn write(certificate: *Bytes, index: usize, field: ProposalFieldReference) void {
        const entry = certificate[index * entry_bytes ..][0..entry_bytes];
        std.mem.writeInt(u64, entry[0..8], field.length, .little);
        entry[8..].* = field.digest;
    }

    pub fn read(certificate: *const Bytes, index: usize) ProposalFieldReference {
        const entry = certificate[index * entry_bytes ..][0..entry_bytes];
        return .{ .length = std.mem.readInt(u64, entry[0..8], .little), .digest = entry[8..].* };
    }
};

test "a field certificate reads back what was written, in its saved layout" {
    var certificate: FieldCertificate.Bytes = undefined;
    for (0..3) |index| FieldCertificate.write(&certificate, index, .{ .length = 0x0102 + index, .digest = @splat(@intCast(index + 1)) });
    for (0..3) |index| {
        const field = FieldCertificate.read(&certificate, index);
        try std.testing.expectEqual(@as(u64, 0x0102 + index), field.length);
        try std.testing.expectEqual(@as([32]u8, @splat(@intCast(index + 1))), field.digest);
        // Independent of the helpers: 8 little-endian length bytes, then the digest.
        try std.testing.expectEqual(@as(u8, @intCast(0x02 + index)), certificate[index * 40]);
        try std.testing.expectEqual(@as(u8, 0x01), certificate[index * 40 + 1]);
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), certificate[index * 40 + 8]);
    }
}
/// The text a call's proposal and its approval carry beside their fields,
/// and the one place their bounds are named.
pub const CallText = struct {
    pub const max_description_bytes = @import("tool_presentation.zig").max_description_bytes;
    pub const max_tool_bytes = @import("tool_name.zig").max_bytes;
    /// tool_record.max_server_bytes names the same bound; importing it here
    /// would cycle, so both take it from tool_name.
    pub const max_server_bytes = @import("tool_name.zig").max_bytes;
    pub const Description = Bounded(max_description_bytes);
    pub const Tool = Bounded(max_tool_bytes);
    pub const Server = Bounded(max_server_bytes);
};
pub const ProposalMetadata = struct {
    position: u64,
    operation: u64,
    turn: u64,
    call_ordinal: u64,
    action: ?u64,
    rejection: ?tool_proposal.Rejection,
    fields: [3]ProposalFieldReference, // ProposalField order.
    description: ?CallText.Description = null,
    tool: ?CallText.Tool = null,
    server: ?CallText.Server = null,
};
