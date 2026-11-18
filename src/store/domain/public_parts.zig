//! Bounded public traversal of the parts belonging to one Message or Action.
const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const content = @import("content.zig");
const parts = @import("content_parts.zig");
const action_read = @import("action_read.zig");
const sourced_input = @import("sourced_input.zig");
const Mapped = @import("../../os/pages.zig").Mapped;

pub const Target = union(enum) { message: u64, action: u64 };
pub const Part = struct { ordinal: u32, kind: @import("../../input_parts.zig").Kind, location: content.ContentLocation };
pub const Progress = union(enum) { pending, part: Part, done };

pub const Reader = struct {
    session: Bounded(session_id.max_reference_bytes),
    target: Target,
    phase: enum { resolve, text, parts, done } = .resolve,
    value: content.Value = undefined,
    cursor: ?Mapped(parts.Cursor) = null,

    pub fn init(session: Bounded(session_id.max_reference_bytes), target: Target) !Reader {
        return .{ .session = session, .target = target, .cursor = try Mapped(parts.Cursor).map() };
    }

    pub fn deinit(self: *Reader) void {
        if (self.cursor) |cursor| cursor.unmap();
        self.cursor = null;
        self.phase = .done;
    }
};

comptime {
    if (@sizeOf(Reader) > 512 or @sizeOf(Part) > 512) @compileError("public part traversal must keep Host stack storage bounded");
}

const message = rsql.Read(.{
    .sql = "SELECT m.content_id,c.byte_length,c.digest,c.private,c.form,CASE WHEN " ++
        sourced_input.consistentSql("m", "command") ++
        " AND (m.turn_id IS NULL OR (t.session_ref=m.session_ref AND EXISTS(SELECT 1 FROM conversation_entry e " ++
        "WHERE e.source_admission_id=m.admission_id AND e.session_ref=m.session_ref AND e.turn_id=m.turn_id AND e.content_id=m.content_id))) " ++
        "THEN 1 ELSE 0 END AS consistent FROM message_admission m LEFT JOIN content c ON c.content_id=m.content_id " ++
        "LEFT JOIN core_command command ON command.command_key=m.command_key LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
        "WHERE m.session_ref=?1 AND m.admission_id=?2",
    .Args = struct { session: []const u8, admission: u64 },
    .Row = struct { content_id: rsql.Positive, byte_length: ?u64, digest: ?[32]u8, private: ?bool, form: ?u8, consistent: bool },
    .cardinality = .optional,
});

pub fn step(a: anytype, reader: *Reader) !Progress {
    switch (reader.phase) {
        .resolve => {
            const id = switch (reader.target) {
                inline else => |id| id,
            };
            if (id == 0 or id > std.math.maxInt(i64)) return error.ContentNotFound;
            reader.value = switch (reader.target) {
                .message => |admission| blk: {
                    var row: message.Result = null;
                    a.read(message, .{ .session = reader.session.slice(), .admission = admission }, &row);
                    try access.runAs(a, error.CorruptStore);
                    const found = row orelse return error.ContentNotFound;
                    if (!found.consistent or (found.private orelse return error.CorruptStore)) return error.CorruptStore;
                    break :blk try content.Value.of(found.content_id.get(), found.form orelse return error.CorruptStore, found.byte_length orelse return error.CorruptStore, found.digest orelse return error.CorruptStore);
                },
                .action => |action| (try action_read.readPublicResolution(a, reader.session.slice(), action)).value,
            };
            if (reader.value.reference == .parts) {
                reader.cursor.?.value.init(reader.value);
                reader.phase = .parts;
            } else reader.phase = .text;
            return .pending;
        },
        .text => {
            reader.phase = .done;
            return .{ .part = .{ .ordinal = 0, .kind = .text, .location = .{ .store = a.store, .content_id = @intCast(reader.value.content_id), .reference = reader.value.reference.bytes } } };
        },
        .parts => return switch (try reader.cursor.?.value.step(a)) {
            .raw => .pending,
            .rows => blk: {
                try access.runAs(a, error.CorruptStore);
                break :blk .pending;
            },
            .done => blk: {
                reader.deinit();
                break :blk .done;
            },
            .part => |part| .{ .part = .{ .ordinal = part.ordinal, .kind = part.kind, .location = .{ .store = a.store, .content_id = @intCast(part.content_id), .reference = part.reference } } },
        },
        .done => return .done,
    }
}
