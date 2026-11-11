//! Contracts between Store replies and the client reply decoder.
const std = @import("std");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const store = @import("store.zig");

test "a Session with message_agent keeps it through its list row and report, as the client reads them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store.testing.testingSqliteStore(&storage, &tmp, io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [@import("workspace_path.zig").max_bytes]u8 = undefined;
    const workspace = try store.testingCanonicalCwd(io, &workspace_buffer);
    var command = try store.testingCompleteConfiguration("listed-messaging", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{"message_agent"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const session = reply.accepted.session;
    const file = try tmp.dir.createFile(io, "client-reply", .{ .read = true });
    defer file.close(io);

    var used = std.atomic.Value(u64).init(0);
    const listed = try store.testingSessionList(&storage, &tmp, .{}, &used, 1);
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"tools\":[\"message_agent\"]") != null);
    try file.writePositionalAll(io, listed, 0);
    const list = try protocol_reply.SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = listed.len } });
    try std.testing.expectEqual(@as(usize, 1), list.page.count);
    try std.testing.expect(std.mem.eql(u8, list.page.rows[0].tools.names.slice(), "message_agent"));

    try store.testingSubmitMessage(&storage, &tmp, "listed-task", "listed-task", session.slice(), "tell yourself");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [64]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hi\"}}", .{session.slice()});
    var encoded_buffer: [96]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hi\\\"}}", .{session.slice()});
    const calls = [_]store.TestingCall{.{ .item_id = "listed-item", .name = "message_agent", .encoded_call_id = "listed-call", .decoded_call_id = "listed-call", .encoded_arguments = encoded, .decoded_arguments = arguments }};
    try store.settleCallsForTesting(&storage, &tmp, model, "listed-metadata", &calls);

    const reported = try store.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
    defer std.testing.allocator.free(reported);
    try std.testing.expect(std.mem.indexOf(u8, reported, "\"tool\":\"message_agent\",\"permission_revision\":\"1\",\"authorization\":\"core\"") != null);
    try file.setLength(io, 0);
    try file.writePositionalAll(io, reported, 0);
    const current = try protocol_reply.CurrentReply.decode(io, file, session.slice(), .{ .report = .{ .bytes = reported.len } });
    try std.testing.expect(current.current.settings.tools.set.eql(.initOne(.message_agent)));
    const Sink = struct {
        core_calls: usize = 0,
        pub fn visit(self: *@This(), attention: protocol_reply.Current.Attention) !void {
            switch (attention) {
                .unresolved => |row| {
                    try std.testing.expectEqualStrings("message_agent", row.tool.slice());
                    try std.testing.expect(row.authorization.value == .core);
                    self.core_calls += 1;
                },
                else => {},
            }
        }
    };
    var sink: Sink = .{};
    try current.current.traverse(io, file, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.core_calls);
}

test "Session settings Current report and typed Settings round trip every setting" {
    // This is a codec contract, not an engine conformance test. Use the same
    // SQLite fixture as the other native decoder contracts so presentation
    // imports do not become dependencies of live-engine acceptance.
    const settings = @import("session_settings.zig");
    const reply = protocol_reply;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store.testing.testingSqliteStore(&storage, &tmp, io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store.testingCanonicalCwd(io, &workspace_buffer);
    var command = try store.testingCompleteConfiguration("settings-roundtrip", "", workspace, "gpt-5.5");
    command.configuration.instructions = try store.testingBytesContent(&tmp, "settings-instructions", "Every setting instructions.");
    command.configuration.output_schema = try store.testingBytesContent(&tmp, "settings-schema", "{}");
    defer command.removeTemporaryContent(io) catch unreachable;
    command.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
    command.configuration.loaded_tools = try .of(&.{ "bash", "find_tools" });
    try command.configuration.permission_mode.value.set("ask");
    try command.configuration.compaction_trigger.value.set("1000");
    command.configuration.output_reservation.state = .value;
    try command.configuration.output_reservation.value.set("20");
    command.configuration.label.state = .value;
    try command.configuration.label.value.set("Every setting");
    const result = try storage.configure(&command, .{});
    try std.testing.expect(result == .accepted);
    const session = result.accepted.session.slice();
    const report = try store.testingSessionReportWithProfile(&storage, &tmp, session, 128 * 1024, .current);
    defer std.testing.allocator.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
    defer parsed.deinit();
    const original = parsed.value.object.get("session").?.object;
    var missing_buffer: [8192]u8 = undefined;
    var missing: std.Io.Writer = .fixed(&missing_buffer);
    inline for (settings.entries) |entry| {
        if (comptime !@hasField(@import("session_report.zig").Current, entry.field))
            try missing.print("{s}: session_report.Current / Store session_report_read current producer\n", .{entry.field});
        if (comptime !@hasField(reply.Current.Settings, entry.field))
            try missing.print("{s}: protocol_reply.Current.Settings\n", .{entry.field});
        if (original.get(entry.field)) |value| {
            if (value == .null) try missing.print("{s}: all-settings configure fixture / Store report read\n", .{entry.field});
        } else try missing.print("{s}: Store report current producer / session_report_reply.CurrentJson.Settings\n", .{entry.field});
    }
    try std.testing.expectEqualStrings("", missing.buffered());
    const file = try tmp.dir.createFile(io, "settings-report", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, report);
    const decoded = try reply.CurrentReply.decode(io, file, session, .{ .report = .{ .bytes = report.len } });
    try std.testing.expect(decoded == .current);
    var round_buffer: [8192]u8 = undefined;
    var round_writer: std.Io.Writer = .fixed(&round_buffer);
    try std.json.Stringify.value(decoded.current.settings, .{}, &round_writer);
    var round = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, round_writer.buffered(), .{});
    defer round.deinit();
    inline for (settings.entries) |entry| {
        const value = round.value.object.get(entry.field);
        if (value == null) {
            try missing.print("{s}: protocol_reply.Current.Settings round trip\n", .{entry.field});
        } else {
            const before = try std.json.Stringify.valueAlloc(std.testing.allocator, original.get(entry.field).?, .{});
            defer std.testing.allocator.free(before);
            const after = try std.json.Stringify.valueAlloc(std.testing.allocator, value.?, .{});
            defer std.testing.allocator.free(after);
            if (!std.mem.eql(u8, before, after))
                try missing.print("{s}: Store report / protocol_reply.Current.Settings round trip value\n", .{entry.field});
        }
    }
    try std.testing.expectEqualStrings("", missing.buffered());
    const current = &decoded.current.settings;
    try std.testing.expectEqualStrings(workspace, current.workspace.slice());
    try std.testing.expectEqualStrings("codex", @tagName(current.provider.value));
    try std.testing.expectEqualStrings("gpt-5.5", current.model.slice());
    try std.testing.expectEqualStrings("bash find_tools web_search", current.tools.names.names.slice());
    try std.testing.expectEqualStrings("bash find_tools", current.loaded_tools.names.names.slice());
    try std.testing.expectEqualStrings("ask", @tagName(current.permission_mode.value));
    try std.testing.expectEqual(@as(u64, 1000), current.compaction_trigger.?.value);
    try std.testing.expectEqual(@as(u64, 1000), current.compaction_trigger_override.?.value);
    try std.testing.expectEqual(@as(u64, 20), current.output_reservation.value);
    try std.testing.expectEqual(@as(u64, 20), current.output_reservation_override.?.value);
    try std.testing.expectEqualStrings("low", @tagName(current.reasoning_effort.?.value));
    try std.testing.expectEqualStrings("low", @tagName(current.reasoning_effort_override.?.value));
    try std.testing.expectEqualStrings("Every setting", current.label.?.slice());
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(protocol.contentDigest("Every setting instructions."), .lower), current.instructions.sha256.slice());
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(protocol.contentDigest("{}"), .lower), current.output_schema.?.sha256.slice());
}
