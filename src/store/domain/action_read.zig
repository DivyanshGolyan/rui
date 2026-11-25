const std = @import("std");
const read = @import("../../action_read.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const outcome_code = @import("../../outcome_code.zig");
const rsql = @import("../rsql.zig");
const content = @import("content.zig");
const utf8 = @import("../../utf8_validation.zig");

const metadata = rsql.Read(.{
    .sql = "SELECT action.authorized,action.attempt_ordinal,action.acceptance_position,action.resolution_code,action.resolution_content_id,final_content.byte_length AS length,final_content.digest,final_content.private,final_content.form FROM action_operation action LEFT JOIN content final_content ON final_content.content_id=action.resolution_content_id WHERE action.session_ref=?1 AND action.action_id=?2",
    .Args = struct { session: []const u8, action_id: u64 },
    .Row = struct {
        authorized: bool,
        attempt_ordinal: u64,
        acceptance_position: ?rsql.Positive,
        resolution_code: ?Bounded(outcome_code.max_bytes),
        resolution_content_id: ?rsql.Positive,
        length: ?u64,
        digest: ?[32]u8,
        private: ?bool,
        form: ?u8,
    },
    .cardinality = .optional,
});

const next_value = rsql.Read(.{
    .sql = "SELECT v.ordinal,v.publication_key,v.content_id,c.byte_length,c.digest,c.private,c.form FROM action_value v JOIN content c ON c.content_id=v.content_id WHERE v.action_id=?1 AND v.ordinal>?2 ORDER BY v.ordinal" ++ std.fmt.comptimePrint(" LIMIT {d}", .{read.page_items + 1}),
    .Args = struct { action_id: u64, after: u64 },
    .Row = struct { ordinal: rsql.Positive, publication_key: Bounded(128), content_id: rsql.Positive, byte_length: u64, digest: [32]u8, private: bool, form: u8 },
    .cardinality = .each,
});

test "published value page queries limit rows in SQLite and MySQL" {
    const limit = std.fmt.comptimePrint(" LIMIT {d}", .{read.page_items + 1});
    try std.testing.expect(std.mem.endsWith(u8, next_value.sql, limit));
    try std.testing.expect(std.mem.endsWith(u8, comptime next_value.mysql.prepared(), limit));
}

const ValueRows = struct {
    rows: [read.page_items + 1]next_value.Row = undefined,
    count: usize = 0,

    pub fn visit(self: *ValueRows, row: *const next_value.Row) bool {
        self.rows[self.count] = row.*;
        self.count += 1;
        return self.count < self.rows.len;
    }
};

fn readValues(a: anytype, after: u64, rows: *const ValueRows, page: *read.Values) !void {
    page.count = 0;
    page.length = 0;
    page.next = after;
    page.more = false;
    for (rows.rows[0..rows.count]) |row| {
        if (row.private or row.form != 0 or row.byte_length > read.page_bytes) return error.CorruptStore;
        const len: usize = @intCast(row.byte_length);
        if (page.count == read.page_items or len > page.bytes.len - page.length) {
            page.more = true;
            return;
        }
        var reader: content.ContentReader = undefined;
        reader.open(.{ .store = a.store, .content_id = @intCast(row.content_id.get()), .reference = .{ .length = row.byte_length, .digest = row.digest } });
        defer reader.close();
        const bytes = page.bytes[page.length..][0..len];
        if (try reader.readWithAccess(a, 0, bytes) != len or !std.unicode.utf8ValidateSlice(bytes)) return error.CorruptStore;
        page.items[page.count] = .{ .ordinal = row.ordinal.get(), .key = row.publication_key, .start = page.length, .length = len };
        page.count += 1;
        page.length += len;
        page.next = row.ordinal.get();
    }
}

/// Native and model reads agree: a parts Resolution is its owned parts value with no window.
pub fn actionRead(a: anytype, request: *const read.Request, out: *read.Read) !void {
    if (request.action_id == 0 or request.action_id > std.math.maxInt(i64)) return error.ActionNotFound;
    var selected: metadata.Result = null;
    if (request.after > std.math.maxInt(i64)) return error.InvalidCursor;
    var values: ValueRows = .{};
    a.read(metadata, .{ .session = request.session.slice(), .action_id = request.action_id }, &selected);
    a.readEach(next_value, .{ .action_id = request.action_id, .after = request.after }, read.page_items + 1, &values);
    try a.run();
    const row = selected orelse return error.ActionNotFound;
    out.session = request.session;
    out.action_id = request.action_id;
    out.status = .{ .pending = if (row.attempt_ordinal != 0) .attempted else if (row.authorized) .queued else .waiting_approval };
    try readValues(a, request.after, &values, &out.values);
    const final = try resolution(a, row) orelse {
        if (request.offset != 0) return error.InvalidCursor;
        return;
    };
    if (final.value.reference == .parts) {
        if (request.offset != 0) return error.InvalidCursor;
        out.status = .{ .resolved_parts = final.resolution };
        out.status.resolved_parts.content = .{ .parts = .{ .identity = final.location.reference, .owner = .{ .action = request.action_id } } };
        return;
    }
    const reference = final.location.reference;
    if (request.offset > reference.length) return error.InvalidCursor;
    out.status = .{ .resolved = .{
        .resolution = final.resolution,
        .window = .{ .offset = request.offset, .next = request.offset, .more = false, .text = .{ .len = 0 } },
    } };
    var reader: content.ContentReader = undefined;
    reader.open(final.location);
    defer reader.close();
    const window = &out.status.resolved.window;
    const count = try reader.readWithAccess(a, request.offset, &window.text.bytes);
    if (count != 0 and window.text.bytes[0] & 0xc0 == 0x80) return error.InvalidCursor;
    const bytes = window.text.bytes[0..count];
    const kept = if (request.offset + count < reference.length) utf8.completePrefix(bytes) else bytes;
    if (!std.unicode.utf8ValidateSlice(kept) or (count != 0 and kept.len == 0)) return error.CorruptStore;
    window.text.len = kept.len;
    window.next = request.offset + kept.len;
    window.more = window.next < reference.length;
}

/// The sole immutable Resolution, shared by native `action read`, `stop_action` and
/// background final input rendering. Both stream its existing content.
pub const SavedResolution = struct {
    resolution: read.Resolution,
    value: content.Value,
    location: content.ContentLocation,
};

pub fn readResolution(a: anytype, session: []const u8, action_id: u64) !SavedResolution {
    var selected: metadata.Result = null;
    a.read(metadata, .{ .session = session, .action_id = action_id }, &selected);
    try a.run();
    return try resolution(a, selected orelse return error.CorruptStore) orelse error.CorruptStore;
}

pub fn readPublicResolution(a: anytype, session: []const u8, action_id: u64) !SavedResolution {
    var selected: metadata.Result = null;
    a.read(metadata, .{ .session = session, .action_id = action_id }, &selected);
    try a.run();
    return try resolution(a, selected orelse return error.ContentNotFound) orelse error.ContentNotFound;
}

fn resolution(a: anytype, row: metadata.Row) !?SavedResolution {
    const position = row.acceptance_position orelse {
        if (row.resolution_code != null or row.resolution_content_id != null or row.length != null or row.digest != null) return error.CorruptStore;
        return null;
    };
    const content_id = (row.resolution_content_id orelse return error.CorruptStore).get();
    const info: content.content_metadata.Row = .{ .byte_length = row.length orelse return error.CorruptStore, .digest = row.digest orelse return error.CorruptStore, .private = row.private orelse return error.CorruptStore, .form = row.form orelse return error.CorruptStore };
    if (info.private) return error.CorruptStore;
    const value = try content.Value.of(content_id, info.form, info.byte_length, info.digest);
    const reference: content.ContentReference = .{ .length = info.byte_length, .digest = info.digest };
    return .{
        .value = value,
        .resolution = .{ .position = position.get(), .code = row.resolution_code orelse return error.CorruptStore, .content = .{ .text = reference } },
        .location = .{ .store = a.store, .content_id = @intCast((row.resolution_content_id orelse return error.CorruptStore).get()), .reference = reference },
    };
}
