const std = @import("std");
const read = @import("../../action_read.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const outcome_code = @import("../../outcome_code.zig");
const rsql = @import("../rsql.zig");
const content = @import("content.zig");
const source = @import("sourced_input.zig");
const utf8 = @import("../../utf8_validation.zig");

const metadata = rsql.Read(.{
    .sql = "SELECT action.authorized,action.attempt_ordinal,action.background_position,action.acceptance_position,action.resolution_code,action.resolution_content_id,final_content.byte_length AS length,final_content.digest," ++ source.actionStoppedSql("action", "operation") ++ " AS stopped FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id LEFT JOIN content final_content ON final_content.content_id=action.resolution_content_id WHERE action.session_ref=?1 AND action.action_id=?2",
    .Args = struct { session: []const u8, action_id: u64 },
    .Row = struct {
        authorized: bool,
        attempt_ordinal: u64,
        background_position: ?rsql.Positive,
        acceptance_position: ?rsql.Positive,
        resolution_code: ?Bounded(outcome_code.max_bytes),
        resolution_content_id: ?rsql.Positive,
        length: ?u64,
        digest: ?[32]u8,
        stopped: bool,
    },
    .cardinality = .optional,
});

pub fn actionRead(a: anytype, request: *const read.Request, out: *read.Read) !void {
    if (request.action_id == 0 or request.action_id > std.math.maxInt(i64)) return error.ActionNotFound;
    var selected: metadata.Result = null;
    a.read(metadata, .{ .session = request.session.slice(), .action_id = request.action_id }, &selected);
    try a.run();
    const row = selected orelse return error.ActionNotFound;
    out.* = .{
        .session = request.session,
        .action_id = request.action_id,
        .state = if (row.acceptance_position != null) .resolved else if (row.attempt_ordinal != 0) .attempted else if (row.authorized) .queued else .waiting_approval,
        .background_position = if (row.background_position) |position| position.get() else null,
        .stop_selected = row.stopped,
        .final = null,
    };
    const position = row.acceptance_position orelse {
        if (row.resolution_code != null or row.resolution_content_id != null or row.length != null or row.digest != null) return error.CorruptStore;
        if (request.offset != 0) return error.InvalidCursor;
        return;
    };
    const reference: content.ContentReference = .{ .length = row.length orelse return error.CorruptStore, .digest = row.digest orelse return error.CorruptStore };
    if (request.offset > reference.length) return error.InvalidCursor;
    out.final = .{
        .resolution = .{ .position = position.get(), .code = row.resolution_code orelse return error.CorruptStore, .content = .{ .length = reference.length, .digest = reference.digest } },
        .window = .{ .offset = request.offset, .next = request.offset, .more = false, .text = .{ .len = 0 } },
    };
    var reader: content.ContentReader = undefined;
    reader.open(.{ .store = a.store, .content_id = @intCast((row.resolution_content_id orelse return error.CorruptStore).get()), .reference = reference });
    defer reader.close();
    const window = &out.final.?.window;
    const count = try reader.readWithAccess(a, request.offset, &window.text.bytes);
    if (count != 0 and window.text.bytes[0] & 0xc0 == 0x80) return error.InvalidCursor;
    const bytes = window.text.bytes[0..count];
    const kept = if (request.offset + count < reference.length) utf8.completePrefix(bytes) else bytes;
    if (!std.unicode.utf8ValidateSlice(kept) or (count != 0 and kept.len == 0)) return error.CorruptStore;
    window.text.len = kept.len;
    window.next = request.offset + kept.len;
    window.more = window.next < reference.length;
}
