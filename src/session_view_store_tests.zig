const std = @import("std");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const protocol_reply = @import("protocol_reply.zig");
const tool_defs = @import("tools.zig");
const store = @import("store.zig");

test "MCP ask approval uses the frozen server after its Session offer changes" {
    const Store = store.Store;
    const testingStoreToolSet = store.testing.testingStoreToolSet;
    const hostToolRecordsWith = store.testing.hostToolRecordsWith;
    const submitTestMessage = store.testingSubmitMessage;
    const settleCallsForTesting = store.settleCallsForTesting;
    const ContentReader = store.ContentReader;
    const testingSessionReportWithProfile = store.testingSessionReportWithProfile;
    const canonicalCwd = store.testingCanonicalCwd;
    const completeConfiguration = store.testingCompleteConfiguration;
    const View = @import("session_view.zig");
    const tools = tool_defs;
    const records = comptime hostToolRecordsWith(&.{.{
        .name = "fetch_page",
        .owner = .mcp,
        .server = "docs",
        .description = "Fetch a page.",
        .input_schema = "{\"type\":\"object\"}",
    }});
    const digests = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var out: [records.len][32]u8 = undefined;
        for (&records, &out) |*record, *digest| digest.* = tools.recordDigest(record);
        break :blk out;
    };
    const host_tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &host_tool_set);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try completeConfiguration("approval-mcp", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    command.configuration.tools = try .of(&.{"fetch_page"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const configured = try storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    try submitTestMessage(&storage, &tmp, "approval-input", "approval-input", session.slice(), "fetch");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, model, "approval-calls", &.{
        .{ .item_id = "item", .name = "fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    });
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("approval-remove");
    update.session = session;
    update.configuration.tools = try .of(&.{"bash"});
    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
    defer std.testing.allocator.free(report);
    const scratch = try tmp.dir.createFile(std.testing.io, "approval-scratch", .{ .read = true });
    defer scratch.close(std.testing.io);
    try scratch.writePositionalAll(std.testing.io, report, 0);
    const decoded = try protocol_reply.CurrentReply.decode(std.testing.io, scratch, session.slice(), .{ .report = .{ .bytes = report.len } });
    const observed = &decoded.current;
    const action = observed.first_action.?;
    const tool = (try View.actionToolFromCapture(observed, std.testing.io, scratch, action)).?;
    try std.testing.expect(try tool.runner() == .mcp);
    try std.testing.expectEqualStrings("fetch_page", tool.name.slice());
    try std.testing.expectEqualStrings("docs", tool.server.?.slice());
    const reference = try storage.actionArguments(session.slice(), action);
    var saved_arguments: ContentReader = undefined;
    saved_arguments.open(try storage.openContent(reference));
    defer saved_arguments.close();
    var arguments: [16]u8 = undefined;
    const count = try saved_arguments.read(0, &arguments);
    try std.testing.expectEqualStrings("{}", arguments[0..count]);
    try scratch.setLength(std.testing.io, 0);
    try scratch.writePositionalAll(std.testing.io, arguments[0..count], 0);
    const Sink = struct {
        bytes: [512]u8 = undefined,
        len: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    var sink: Sink = .{};
    try View.renderPermissionArguments(std.testing.io, scratch, &sink, false, true, &tool);
    try std.testing.expectEqualStrings("\n● fetch_page\n  Tool: fetch_page\n  Server: docs\n  Arguments:\n  │ {}\n", @import("testing/row_text.zig").visible(sink.bytes[0..sink.len]));
    try std.testing.expect((try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
    try std.testing.expect(!(try storage.dispatchWork(false, .{ .free_credit = .one, .mcp_open = true })).mcp);
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .allow_once };
    try allow.key.set("approval-allow");
    allow.session = session;
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    try std.testing.expectEqual(action, (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.mcp.action_id);
    const work = try storage.dispatchWork(false, .{ .free_credit = .one, .mcp_open = true });
    try std.testing.expect(work.mcp and !work.core);
}

test "Current facts traverse every attention row and preserve metadata with fixed scratch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const rendered = try tmp.dir.createFile(io, "rendered", .{ .read = true });
    defer rendered.close(io);
    const reference = "{\"type\":\"text\",\"bytes\":\"13\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"}";
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\"current\",\"archive_state\":\"active\",\"session\":{\"reference\":\"k7m2qx\",\"parent\":null,\"workspace\":\"/w\",\"connection\":\"codex\",\"model\":\"m\",\"revision\":\"17\",\"tools\":[\"bash\"],\"loaded_tools\":[\"bash\"],\"app_tools\":[],\"permission_mode\":\"ask\",\"instructions\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"output_schema\":null,\"reasoning_effort\":null,\"reasoning_effort_override\":null,\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null,\"label\":null,\"created_at\":\"1\"},\"pending_messages\":\"0\",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1792925300\"},\"turn\":\"7\",\"operation\":\"19\",\"first_action\":\"31\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null},\"latest_outcome\":null},\"peers\":{\"from_person_at\":null},\"selected_message\":\"k\\n\",\"recent_messages\":[],\"actions\":{\"count\":\"515\",\"unresolved\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"parent_operation\":\"19\",\"call_ordinal\":\"{d}\",\"tool\":\"{s}\",{s}\"permission_revision\":\"23\",\"authorization\":\"pending\",\"call_id\":", .{ i + 31, i, if (i == 0) "fetch_page" else "bash", if (i == 0) "\"server\":\"docs\"," else "" });
        try writer.writeAll(reference ++ ",\"arguments\":" ++ reference ++ ",\"presentation\":{\"line\":{\"before\":\"");
        try writer.writeAll(if (i == 0) &@as([200]u8, @splat('a')) else "Run parser tests");
        try writer.writeAll("\",\"peer\":null,\"after\":null},\"code\":\"pending_permission\",\"sign\":\"needs_you\",\"publication_position\":null}}");
    }
    try writer.writeAll("],\"resolved\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"parent_operation\":\"11\",\"call_ordinal\":\"{d}\",\"code\":\"indeterminate\",\"acceptance_position\":\"{d}\",\"result\":", .{ i + 1001, i, i + 71 });
        try writer.writeAll(reference ++ ",\"presentation\":{\"line\":{\"before\":\"Run parser tests\",\"peer\":null,\"after\":null},\"code\":\"indeterminate\",\"sign\":\"failed\",\"publication_position\":null}}");
    }
    try writer.writeAll("]},\"rejected_calls\":{\"count\":\"257\",\"items\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"parent_operation\":\"11\",\"call_ordinal\":\"{d}\",\"code\":\"unknown_tool\",\"acceptance_position\":\"{d}\",\"result\":", .{ i + 1000, i + 5001 });
        try writer.writeAll(reference ++ ",\"name\":" ++ reference ++ ",\"call_id\":" ++ reference ++ ",\"arguments\":" ++ reference ++ ",\"presentation\":{\"line\":null,\"code\":\"unknown_tool\",\"sign\":\"failed\",\"publication_position\":null}}");
    }
    try writer.writeAll("]},\"actionable_permissions\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"permission_revision\":\"23\"}}", .{i + 31});
    }
    try writer.writeAll("],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"3\",\"scratch_used_bytes\":\"987\",\"unavailable\":[\"structured_output\"]},\"extension\":\"");
    try writer.splatByteAll('x', 20000);
    try writer.writeAll("\"}");
    try output.flush();
    const bytes = try file.length(io);
    const reply = try protocol_reply.CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes } });
    const facts = &reply.current;
    try std.testing.expectEqual(@as(u64, 257), facts.actionable_count);
    try std.testing.expectEqual(@as(u64, 257), facts.indeterminate_count);
    try std.testing.expectEqual(@as(u64, 1001), facts.first_indeterminate.?);
    try std.testing.expect(facts.settings.reasoning_effort == null and facts.settings.reasoning_effort_override == null);
    const Sink = struct {
        counts: [4]usize = @splat(0),
        pub fn visit(self: *@This(), attention: protocol_reply.Current.Attention) !void {
            const kind = @backingInt(attention);
            const i = self.counts[kind];
            switch (attention) {
                .unresolved => |row| {
                    if (i == 0) {
                        try std.testing.expectEqualStrings("fetch_page", row.tool.slice());
                        try std.testing.expectEqualStrings("docs", row.server.value.?.slice());
                    } else try std.testing.expect(row.server.value == null);
                    try std.testing.expectEqual(@as(u64, 31 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 19), row.parent_operation.value);
                    try std.testing.expectEqual(@as(u64, i), row.call_ordinal.value);
                    try std.testing.expectEqual(@as(u64, 13), row.arguments.value.text.length);
                    try std.testing.expectEqualStrings(&@as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))), &std.fmt.bytesToHex(row.call_id.value.text.digest, .lower));
                    try std.testing.expectEqualStrings(if (i == 0) &@as([200]u8, @splat('a')) else "Run parser tests", row.presentation.value.line.?.words.slice());
                    try std.testing.expectEqual(protocol.ToolPresentation.Code.pending_permission, row.presentation.value.code);
                },
                .resolved => |row| {
                    try std.testing.expectEqual(@as(u64, 1001 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 71 + i), row.acceptance_position.value);
                    try std.testing.expectEqualStrings("indeterminate", row.code.slice());
                    try std.testing.expect(row.presentation.value.publication_position == null);
                },
                .rejected => |row| {
                    try std.testing.expectEqual(@as(u64, 1000 + i), row.call_ordinal.value);
                    try std.testing.expectEqual(@as(u64, 5001 + i), row.acceptance_position.value);
                    try std.testing.expectEqualStrings("unknown_tool", row.code.slice());
                    try std.testing.expectEqual(@as(u64, 13), row.name.value.text.length);
                    try std.testing.expect(row.presentation.value.line == null);
                },
                .actionable => |row| {
                    try std.testing.expectEqual(@as(u64, 31 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 23), row.permission_revision.value);
                },
            }
            self.counts[kind] += 1;
        }
    };
    var sink: Sink = .{};
    try facts.traverse(io, file, &sink);
    try std.testing.expectEqual([4]usize{ 257, 257, 257, 257 }, sink.counts);
    var json = rendered.writerStreaming(io, &buffer);
    try reply.writeJson(io, file, &json.interface);
    try json.flush();
    const roundtrip = try protocol_reply.CurrentReply.decode(io, rendered, "k7m2qx", .{ .report = .{ .bytes = try rendered.length(io) } });
    var again: Sink = .{};
    try roundtrip.current.traverse(io, rendered, &again);
    try std.testing.expectEqual(sink.counts, again.counts);
    const view = @import("session_view.zig");
    const mcp = (try view.actionToolFromCapture(&roundtrip.current, io, rendered, 31)).?;
    try std.testing.expectEqualStrings("fetch_page", mcp.name.slice());
    try std.testing.expectEqualStrings("docs", mcp.server.?.slice());
    try std.testing.expectEqualStrings(&@as([200]u8, @splat('a')), mcp.description.slice());
    const bash = (try view.actionToolFromCapture(&roundtrip.current, io, rendered, 32)).?;
    try std.testing.expectEqualStrings("Run parser tests", bash.description.slice());
    try std.testing.expectEqual(null, try view.actionToolFromCapture(&roundtrip.current, io, rendered, 1001));
    const Failing = struct {
        pub fn visit(_: @This(), _: protocol_reply.Current.Attention) !void {
            return error.SinkFailed;
        }
    };
    try std.testing.expectError(error.SinkFailed, facts.traverse(io, file, Failing{}));
    try std.testing.expectError(error.InvalidObservation, protocol_reply.CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes + 1 } }));
    var prefix: [2048]u8 = undefined;
    try std.testing.expectEqual(prefix.len, try file.readPositionalAll(io, &prefix, 0));
    inline for (.{
        .{ "\"version\":\"" ++ protocol.wire_version ++ "\"", "\"version\":\"" ++ protocol.next_wire_version ++ "\"" },
        .{ "\"tools\":[\"bash\"]", "\"tools\":[\"ba.h\"]" },
        .{ "\"tool\":\"bash\"", "\"tool\":\"ba.h\"" },
        .{ "\"loaded_tools\":[\"bash\"]", "\"loaded_tools\":[\"ba.h\"]" },
        .{ "\"turn\":\"7\"", "\"turn\":\"0\"" },
        .{ "\"operation\":\"19\"", "\"operation\":\"00\"" },
        .{ "\"selected_message\"", "\"ignored__message\"" },
        .{ "\"type\":\"text\"", "\"meta\":\"text\"" },
        .{ &@as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))), &@as([64]u8, @bitCast(@as([32][2]u8, @splat("xz".*)))) },
    }) |case| {
        const offset = std.mem.indexOf(u8, &prefix, case[0]).?;
        try file.writePositionalAll(io, case[1], offset);
        try std.testing.expectError(error.InvalidObservation, protocol_reply.CurrentReply.decode(io, file, "k7m2qx", .{ .report = .{ .bytes = bytes } }));
        try file.writePositionalAll(io, case[0], offset);
    }
    try std.testing.expectEqual(bytes, try file.length(io));
    std.debug.print("Current facts={d}B, fixed scanner/token/input=16384B, capture={d}B; 4x257 rows, no population allocation\n", .{ @sizeOf(protocol_reply.Current), bytes });
}

test "SUI-61 Action-sourced inputs draw nothing in the conversation" {
    const View = @import("session_view.zig");
    const Sink = struct {
        pub fn feed(_: *@This(), _: []const u8) !void {
            return error.UnexpectedOutput;
        }
        pub fn excluding(_: *@This(), _: u64) void {}
    };
    var sink: Sink = .{};
    const content_ref: @FieldType(protocol.ActivityItem.Message, "content") = .{ .text = .{ .length = 5, .digest = @splat(0) } };
    for (std.enums.values(@FieldType(protocol.ActivityItem.Message, "state"))) |state| {
        const value: protocol.ActivityItem.Message = .{
            .admission = 1,
            .key = .{},
            .turn = null,
            .state = state,
            .content = content_ref,
            .admitted_at = 1,
            .source_action = 42,
        };
        for ([_]protocol.ActivityItem.Value{ .{ .received = value }, .{ .user = value }, .{ .admission = value } }) |row| {
            const item: protocol.ActivityItem = .{ .position = 1, .at = 1, .value = row };
            try std.testing.expect(!try View.render(undefined, "unused", "k7m2qx", undefined, null, item, false, &sink, false, "", .{ .viewport = .wcwidth }, .none));
        }
    }
}
