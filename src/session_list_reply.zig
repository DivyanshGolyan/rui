const std = @import("std");
const protocol = @import("protocol.zig");
const session_list = @import("session_list.zig");
const tool_name = @import("tool_name.zig");
const appendShape = @import("session_report_reply.zig").appendShape;

pub fn Reply(comptime Capture: type) type {
    return struct {
        capture: *Capture,
        rows: usize = 0,
        tools_json: [protocol.max_tool_names_json_bytes]u8 = undefined,

        pub fn head(reply: *@This()) !void {
            try appendShape(reply.capture, protocol.session_list_reply.head, .{});
        }

        pub fn row(reply: *@This(), values: *const session_list.Row) !void {
            var tools = std.Io.Writer.fixed(&reply.tools_json);
            try tool_name.writeNamesJson(&tools, values.tools);
            const work: protocol.SessionWork = .fromCore(values.work);
            const peers: protocol.PeerFacts = .{ .from_person_at = values.peers.from_person_at };
            const fields: protocol.SessionRow.Fields = .{
                .read_version = values.read_version,
                .archive_state = values.archive_state,
                .pin_order = values.pin_order,
                .reference = values.reference,
                .archive_seq = values.archive_seq,
                .parent = values.parent,
                .creator = values.creator,
                .workspace = values.workspace,
                .provider = values.provider,
                .model = values.model,
                .tools = tools.buffered(),
                .permission_mode = values.permission_mode,
                .label = values.label,
                .created_at = values.created_at,
                .state_change_at = values.state_change_at,
                .subtree_state_change_at = values.subtree_state_change_at,
                .descendant_count = values.descendant_count,
                .descendant_needs_you_count = values.descendant_needs_you_count,
                .revision = values.revision,
                .end = values.end,
                .first_message = if (values.first_message) |first| .fromCore(first) else null,
                .last_line = if (values.last_line) |last| .{ .position = last.position, .text = last.text } else null,
                .work = &work,
                .peers = &peers,
            };
            if (reply.rows != 0) try reply.capture.append(",");
            try appendShape(reply.capture, .{protocol.Hole{ .json = protocol.SessionRow.Fields }}, .{&fields});
            reply.rows += 1;
        }

        pub fn archivedRow(reply: *@This(), values: *const session_list.ArchivedRow) !void {
            const first: ?protocol.ArchivedFirstFields = if (values.first) |first| .{ .position = first.position, .admission = first.admission, .content = first.content, .line = first.line } else null;
            const fields: protocol.ArchivedRow.Fields = .{
                .reference = values.reference,
                .archive_seq = values.archive_seq,
                .stopped_at = values.stopped_at,
                .label = values.label,
                .first = first,
            };
            if (reply.rows != 0) try reply.capture.append(",");
            try appendShape(reply.capture, .{protocol.Hole{ .json = protocol.ArchivedRow.Fields }}, .{&fields});
            reply.rows += 1;
        }

        pub fn tail(reply: *@This(), values: session_list.Tail) !void {
            const shapes = protocol.session_list_reply;
            switch (values) {
                .window => |window| try appendShape(reply.capture, shapes.window_tail, .{ session_list.ListDelta.window, window.since, window.first, window.last, window.more_above, window.more_below }),
                .full => |full| try appendShape(reply.capture, shapes.full_tail, .{ session_list.ListDelta.full, full.since, full.after, full.ceiling }),
                .changed => |changed| try appendShape(reply.capture, shapes.changed_tail, .{ session_list.ListDelta.changed, changed.since, changed.through, changed.after_reference }),
                .last => |last| try appendShape(reply.capture, shapes.last_tail, .{ last.delta, last.since }),
            }
            std.debug.assert(reply.capture.length + reply.capture.buffered <= shapes.max_bytes);
        }
    };
}
