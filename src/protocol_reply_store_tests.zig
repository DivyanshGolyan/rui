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

const PromotedApproval = struct {
    fn expect(storage: *store.Store, tmp: *std.testing.TmpDir, session: []const u8, action: u64, present: bool) !void {
        const bytes = try store.testingSessionReportWithProfile(storage, tmp, session, 1024 * 1024, .current);
        defer std.testing.allocator.free(bytes);
        const expected: ?u64 = if (present) action else null;
        var request: protocol.ActivityPage = .{};
        try request.session.set(session);
        var page: @import("activity_facts.zig").Page = undefined;
        try storage.activityPage(&request, &page);
        const report_file = try tmp.dir.createFile(std.testing.io, "native-promotion-report", .{ .read = true });
        defer report_file.close(std.testing.io);
        try report_file.writePositionalAll(std.testing.io, bytes, 0);
        const report_read = protocol_reply.CurrentReply.decode(std.testing.io, report_file, session, .{ .report = .{ .bytes = bytes.len } }) catch |err| {
            std.debug.print("native promotion Current decode: {s} present={any}\n", .{ @errorName(err), present });
            return err;
        };
        try std.testing.expect(report_read == .current);
        try std.testing.expectEqual(expected, report_read.current.first_action);
        var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer rendered.deinit();
        try @import("host_reply.zig").renderActivityPage(.{ .writer = &rendered.writer }, &page);
        const parsed = try std.testing.allocator.create(protocol_reply.ActivityPage);
        defer std.testing.allocator.destroy(parsed);
        parsed.* = protocol_reply.ActivityPage.parse(rendered.written(), .{}) catch |err| {
            std.debug.print("native promotion Activity decode: {s} present={any}\n", .{ @errorName(err), present });
            return err;
        };
        try std.testing.expectEqual(expected, parsed.facts.work.work.first_action);
    }
};

test "client decoders retain promoted old Turn approval before and after continuation" {
    for ([_]enum { allow, deny, stop }{ .allow, .deny, .stop }) |choice| {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store.testing.testingSqliteStore(&storage, &tmp, io);
        defer storage.close() catch unreachable;
        var workspace_buffer: [@import("workspace_path.zig").max_bytes]u8 = undefined;
        const workspace = try store.testingCanonicalCwd(io, &workspace_buffer);
        var configure = try store.testingCompleteConfiguration("configure", "", workspace, "model-a");
        try configure.configuration.permission_mode.value.set("ask");
        const session = (try storage.configure(&configure, .{})).accepted.session;
        try store.testingSubmitMessage(&storage, &tmp, "input", "task", session.slice(), "Run the tool.");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const arguments = "{\"description\":\"Held tool\",\"cmd\":\"true\"}";
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
        defer std.testing.allocator.free(encoded);
        try store.settleCallsForTesting(&storage, &tmp, model, "calls", &.{.{
            .item_id = "call-item",
            .name = "bash",
            .encoded_call_id = "call-id",
            .decoded_call_id = "call-id",
            .encoded_arguments = encoded[1 .. encoded.len - 1],
            .decoded_arguments = arguments,
        }});
        const action = try store.testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
        const free: usize = 2;
        var promote: @import("command_input.zig").ActionBackgroundCommand = .{ .action_id = action, .session = session };
        try promote.key.set("promote");
        try std.testing.expect(storage.backgroundAction(&promote, .{ .total = 2, .context = &free, .freeFn = struct {
            fn read(context: *const anyopaque) usize {
                return @as(*const usize, @ptrCast(@alignCast(context))).*;
            }
        }.read }, .{}) == .accepted);
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try PromotedApproval.expect(&storage, &tmp, session.slice(), action, true);
        try store.settleAnswerItemsForTesting(&storage, &tmp, continuation, &.{"{\"type\":\"message\",\"id\":\"answer-item\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
        try PromotedApproval.expect(&storage, &tmp, session.slice(), action, true);
        if (choice == .stop) {
            var stop = try store.testingCompleteSessionStop("stop-pending", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
        } else {
            var decision: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = if (choice == .allow) .allow_once else .deny };
            try decision.key.set("decide-old-turn");
            try std.testing.expect(storage.decidePermission(&decision, .{}) == .accepted);
            if (choice == .allow) {
                const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
                const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
                _ = try storage.settleActionAttempt(binding, .succeeded, "Approved after Turn ended", .{});
            }
        }
        try PromotedApproval.expect(&storage, &tmp, session.slice(), action, false);
    }
}

test "saved invalid Action targets round trip through Store observation and exact replay" {
    inline for (.{ @as(u64, 0), std.math.maxInt(u64) }) |target| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store.testing.testingSqliteStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var command: @import("command_input.zig").ActionBackgroundCommand = .{ .action_id = target };
        try command.key.set("invalid-action-target");
        try command.session.set("k7m2qx");
        const free: usize = 2;
        const capacity: @import("store/domain/action_control.zig").CapacityView = .{ .total = 2, .context = &free, .freeFn = struct {
            fn read(context: *const anyopaque) usize {
                return @as(*const usize, @ptrCast(@alignCast(context))).*;
            }
        }.read };
        const refused = storage.backgroundAction(&command, capacity, .{});
        try std.testing.expect(refused == .rejected and refused.rejected.code == .invalid_target and !refused.rejected.replayed);
        const observed = try store.testing.observeCommandForTesting(&storage, command.key.slice());
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try @import("host_reply.zig").renderFullCommandObservation(.{ .writer = &output.writer }, command.key.slice(), &observed, null);
        const decoded = try protocol_reply.CommandObservation.parse(.{ .status = 200, .body = output.written() }, command.key.slice());
        try std.testing.expectEqual(target, decoded.action_target.?);
        try std.testing.expectEqualStrings("invalid_target", decoded.failureCode().?);
        const replay = storage.backgroundAction(&command, capacity, .{});
        try std.testing.expect(replay == .rejected and replay.rejected.code == .invalid_target and replay.rejected.replayed);
    }
}
