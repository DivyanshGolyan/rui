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

/// The Zig field of protocol_reply.Current.Settings that carries an entry. The
/// connection entry is named for its wire key there; every other entry keeps its field name.
fn settingsField(comptime entry: anytype) []const u8 {
    return if (comptime std.mem.eql(u8, entry.field, "provider")) "connection" else entry.field;
}

test "Session settings Current report and typed Settings round trip every setting" {
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
    const app_declaration = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}}]";
    command.configuration.app_tools = .{ .state = .value, .borrowed = app_declaration.ptr, .length = app_declaration.len, .digest = protocol.contentDigest(app_declaration) };
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
        if (comptime !@hasField(reply.Current.Settings, settingsField(entry)))
            try missing.print("{s}: protocol_reply.Current.Settings\n", .{entry.field});
        if (original.get(settingsField(entry))) |value| {
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
        const value = round.value.object.get(settingsField(entry));
        if (value == null) {
            try missing.print("{s}: protocol_reply.Current.Settings round trip\n", .{entry.field});
        } else {
            const before = try std.json.Stringify.valueAlloc(std.testing.allocator, original.get(settingsField(entry)).?, .{});
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
    try std.testing.expectEqualStrings("codex", current.connection.value.slice());
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
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(protocol.contentDigest("Every setting instructions."), .lower), &std.fmt.bytesToHex(current.instructions.value.text.digest, .lower));
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(protocol.contentDigest("{}"), .lower), &std.fmt.bytesToHex(current.output_schema.?.value.text.digest, .lower));
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

const PromotedAction = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    action: u64,
    receipt_position: u64,

    fn make(storage: *store.Store, tmp: *std.testing.TmpDir, mode: @import("cli_value.zig").PermissionMode) !PromotedAction {
        const io = std.testing.io;
        var workspace_buffer: [@import("workspace_path.zig").max_bytes]u8 = undefined;
        const workspace = try store.testingCanonicalCwd(io, &workspace_buffer);
        var configure = try store.testingCompleteConfiguration("configure", "", workspace, "model-a");
        try configure.configuration.permission_mode.value.set(@tagName(mode));
        const session = (try storage.configure(&configure, .{})).accepted.session;
        try store.testingSubmitMessage(storage, tmp, "input", "task", session.slice(), "Run the tool.");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const arguments = "{\"description\":\"Held tool\",\"cmd\":\"true\"}";
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
        defer std.testing.allocator.free(encoded);
        try store.settleCallsForTesting(storage, tmp, model, "calls", &.{.{
            .item_id = "call-item",
            .name = "bash",
            .encoded_call_id = "call-id",
            .decoded_call_id = "call-id",
            .encoded_arguments = encoded[1 .. encoded.len - 1],
            .decoded_arguments = arguments,
        }});
        const action = try store.testing.queryU64(storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});

        var promote: @import("command_input.zig").ActionBackgroundCommand = .{ .action_id = action, .session = session };
        try promote.key.set("promote");
        const promoted = storage.backgroundAction(.{ .command = &promote }, .{});
        try std.testing.expect(promoted == .accepted);
        return .{ .session = session, .action = action, .receipt_position = promoted.accepted.selection.position };
    }

    fn attempt(self: PromotedAction, storage: *store.Store) !store.ActionAttemptBinding {
        const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
        const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
        try std.testing.expectEqual(self.action, binding.action_id);
        return binding;
    }

    fn finish(storage: *store.Store, tmp: *std.testing.TmpDir, continuation: store.AttemptBinding) !void {
        try store.settleAnswerItemsForTesting(storage, tmp, continuation, &.{"{\"type\":\"message\",\"id\":\"answer-item\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
    }

    const Stage = enum { pending, resolved_open, resolved_closed };

    fn expectCurrent(self: PromotedAction, storage: *store.Store, tmp: *std.testing.TmpDir, stage: Stage) !void {
        const read = try std.testing.allocator.create(@import("action_read.zig").Read);
        defer std.testing.allocator.destroy(read);
        try storage.readAction(&.{ .session = self.session, .action_id = self.action }, read);
        if (stage == .pending) {
            try std.testing.expect(read.status == .pending);
        } else {
            try std.testing.expect(read.status == .resolved);
            try std.testing.expectEqualStrings("succeeded", read.status.resolved.resolution.code.slice());
            try std.testing.expect(read.status.resolved.resolution.position > self.receipt_position);
        }
        const bytes = try store.testingSessionReportWithProfile(storage, tmp, self.session.slice(), 1024 * 1024, .current);
        defer std.testing.allocator.free(bytes);
        const file = try tmp.dir.createFile(std.testing.io, "background-current", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, bytes, 0);
        const decoded = try protocol_reply.CurrentReply.decode(std.testing.io, file, self.session.slice(), .{ .report = .{ .bytes = bytes.len } });
        try std.testing.expect(decoded == .current);
        const Sink = struct {
            action: u64,
            final: ?@import("action_read.zig").Resolution,
            unresolved: usize = 0,
            resolved: usize = 0,
            pub fn visit(self_: *@This(), attention: protocol_reply.Current.Attention) !void {
                switch (attention) {
                    .unresolved => |row| {
                        try std.testing.expectEqual(self_.action, row.action.value);
                        try std.testing.expect(row.presentation.value.publication_position == null);
                        self_.unresolved += 1;
                    },
                    .resolved => |row| {
                        const final = self_.final orelse return error.TestUnexpectedResult;
                        try std.testing.expectEqual(self_.action, row.action.value);
                        try std.testing.expectEqualStrings(final.code.slice(), row.code.slice());
                        try std.testing.expectEqual(final.position, row.acceptance_position.value);
                        try std.testing.expectEqualDeep(final.content, row.result.value);
                        try std.testing.expect(row.presentation.value.publication_position == null);
                        self_.resolved += 1;
                    },
                    else => {},
                }
            }
        };
        var sink: Sink = .{ .action = self.action, .final = if (read.status == .resolved) read.status.resolved.resolution else null };
        try decoded.current.traverse(std.testing.io, file, &sink);
        try std.testing.expectEqual(@as(usize, if (stage == .pending) 1 else 0), sink.unresolved);
        try std.testing.expectEqual(@as(usize, if (stage == .resolved_open) 1 else 0), sink.resolved);
        try std.testing.expect(!storage.isFenced());
    }

    fn expectFinalInput(self: PromotedAction, storage: *store.Store, text: []const u8) !void {
        const page = try std.testing.allocator.create(protocol_reply.ActivityPage);
        defer std.testing.allocator.destroy(page);
        try readNativeActivity(storage, &.{ .session = self.session, .kinds = .initOne(.received) }, page);
        try std.testing.expectEqual(@as(usize, 1), page.facts.count);
        const message = page.facts.items[0].value.received;
        try std.testing.expectEqual(@as(?u64, self.action), message.source_action);
        try std.testing.expect(message.sender == null);
        try std.testing.expectEqual(@as(u64, text.len), message.content.text.length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &message.content.text.digest);
    }

    fn receipt(self: PromotedAction, storage: *store.Store) !@import("content_value.zig").Value {
        var request: protocol.ActivityPage = .{ .kinds = .initOne(.tool_result) };
        try request.session.set(self.session.slice());
        const page = try std.testing.allocator.create(protocol_reply.ActivityPage);
        defer std.testing.allocator.destroy(page);
        try readNativeActivity(storage, &request, page);
        try std.testing.expectEqual(@as(usize, 1), page.facts.count);
        const item = page.facts.items[0];
        try std.testing.expectEqual(self.receipt_position, item.position);
        try std.testing.expect(item.value == .tool_result);
        try std.testing.expectEqual(protocol.ToolPresentation.Code.background, item.value.tool_result.presentation.code);
        try std.testing.expectEqual(@as(?u64, self.receipt_position), item.value.tool_result.presentation.publication_position);
        return item.value.tool_result.content;
    }
};

fn readNativeActivity(storage: *store.Store, request: *const protocol.ActivityPage, decoded: *protocol_reply.ActivityPage) !void {
    const produced = try std.testing.allocator.create(@import("activity_facts.zig").Page);
    defer std.testing.allocator.destroy(produced);
    try storage.activityPage(request, produced);
    var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rendered.deinit();
    try @import("host_reply.zig").renderActivityPage(.{ .writer = &rendered.writer }, produced);
    decoded.* = try protocol_reply.ActivityPage.parse(rendered.written(), .{ .end = request.end, .position = request.position, .ordinal = request.ordinal, .direction = request.direction, .kinds = request.kinds, .limit = request.limit });
}

test "client Message decoder retains automatic denial wait after a new Message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store.testing.testingSqliteStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var configure = try store.testingCompleteConfiguration("decline-config", "", workspace, "model-a");
    try configure.configuration.permission_mode.value.set("ask");
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try store.testingSubmitMessage(&storage, &tmp, "decline-first-file", "decline-first", session.slice(), "Run the tool.");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const arguments = "{\"description\":\"Held tool\",\"cmd\":\"true\"}";
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
    defer std.testing.allocator.free(encoded);
    try store.settleCallsForTesting(&storage, &tmp, model, "decline-calls", &.{.{
        .item_id = "call-item",
        .name = "bash",
        .encoded_call_id = "call-id",
        .decoded_call_id = "call-id",
        .encoded_arguments = encoded[1 .. encoded.len - 1],
        .decoded_arguments = arguments,
    }});
    try store.testingSubmitMessage(&storage, &tmp, "decline-next-file", "decline-next", session.slice(), "Use new instructions.");
    for ([_][]const u8{ "decline-first", "decline-next" }) |key| {
        const observation = try store.testing.observeCommandForTesting(&storage, key);
        try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, observation.requestState().?);
        var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer rendered.deinit();
        try @import("host_reply.zig").renderFullCommandObservation(.{ .writer = &rendered.writer }, key, &observation, null);
        const decoded = try protocol_reply.CommandObservation.parse(.{ .status = 200, .body = rendered.written() }, key);
        try std.testing.expectEqual(.waiting_for_permission, decoded.state.?);
        try std.testing.expectEqual(observation.kind.message.?.work.?.first_action, decoded.work.?.first_action);
        try std.testing.expect(decoded.work.?.first_action == null and decoded.work.?.actions.decide == null);
        try std.testing.expect(decoded.work.?.actions.stop);
        try std.testing.expectEqual(.needs_you, protocol.session_work.standing(decoded.work.?.state));
    }
}

test "client decoders retain promoted old Turn approval before and after continuation" {
    for ([_]enum { allow, deny, stop }{ .allow, .deny, .stop }) |choice| {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store.testing.testingSqliteStore(&storage, &tmp, io);
        defer storage.close() catch unreachable;
        const promoted = try PromotedAction.make(&storage, &tmp, .ask);
        const session = promoted.session;
        const action = promoted.action;
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

        const refused = storage.backgroundAction(.{ .command = &command }, .{});
        try std.testing.expect(refused == .rejected and refused.rejected.code == .invalid_target and !refused.rejected.replayed);
        const observed = try store.testing.observeCommandForTesting(&storage, command.key.slice());
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try @import("host_reply.zig").renderFullCommandObservation(.{ .writer = &output.writer }, command.key.slice(), &observed, null);
        const decoded = try protocol_reply.CommandObservation.parse(.{ .status = 200, .body = output.written() }, command.key.slice());
        try std.testing.expectEqual(target, decoded.action_target.?);
        try std.testing.expectEqualStrings("invalid_target", decoded.failureCode().?);
        const replay = storage.backgroundAction(.{ .command = &command }, .{});
        try std.testing.expect(replay == .rejected and replay.rejected.code == .invalid_target and replay.rejected.replayed);
    }
}

test "native Current separates background fulfillment from final Resolution across continuation" {
    for ([_]enum { before, during, after }{ .before, .during, .after }) |settle| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store.testing.testingSqliteStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const promoted = try PromotedAction.make(&storage, &tmp, .bypass);
        const original = try promoted.receipt(&storage);
        try promoted.expectCurrent(&storage, &tmp, .pending);
        const binding = try promoted.attempt(&storage);
        try promoted.expectCurrent(&storage, &tmp, .pending);
        if (settle == .before) _ = try storage.settleActionAttempt(binding, .succeeded, "Sole final result", .{});
        try promoted.expectCurrent(&storage, &tmp, if (settle == .before) .resolved_open else .pending);
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try promoted.expectCurrent(&storage, &tmp, if (settle == .before) .resolved_open else .pending);
        if (settle == .during) _ = try storage.settleActionAttempt(binding, .succeeded, "Sole final result", .{});
        try promoted.expectCurrent(&storage, &tmp, if (settle == .after) .pending else .resolved_open);
        try PromotedAction.finish(&storage, &tmp, continuation);
        if (settle == .during) {
            try promoted.expectCurrent(&storage, &tmp, .resolved_open);
            const boundary = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(continuation.turn_id, boundary.turn_id);
            try PromotedAction.finish(&storage, &tmp, boundary);
        }
        try promoted.expectCurrent(&storage, &tmp, if (settle == .after) .pending else .resolved_closed);
        if (settle == .after) _ = try storage.settleActionAttempt(binding, .succeeded, "Sole final result", .{});
        try promoted.expectCurrent(&storage, &tmp, .resolved_closed);
        try std.testing.expectEqualDeep(original, try promoted.receipt(&storage));
        if (settle == .after) {
            const delivered = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try PromotedAction.finish(&storage, &tmp, delivered);
        }
        try promoted.expectFinalInput(&storage, "Sole final result");
    }
}

test "native Activity round trips selected and Action-only stops before and after settlement" {
    for ([_]bool{ false, true }) |close_turn| {
        for ([_]bool{ false, true }) |settle_before_stop| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: store.Store = undefined;
            try store.testing.testingSqliteStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const promoted = try PromotedAction.make(&storage, &tmp, .bypass);
            const binding = try promoted.attempt(&storage);
            if (close_turn) {
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try PromotedAction.finish(&storage, &tmp, continuation);
            }
            if (settle_before_stop) _ = try storage.settleActionAttempt(binding, .succeeded, "Before stop", .{});
            var stop = try store.testingCompleteSessionStop("stop-domain", promoted.session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: protocol.ActivityPage = .{ .kinds = .initOne(.stop) };
            try request.session.set(promoted.session.slice());
            const page = try std.testing.allocator.create(protocol_reply.ActivityPage);
            defer std.testing.allocator.destroy(page);
            try readNativeActivity(&storage, &request, page);
            try std.testing.expectEqual(@as(usize, 1), page.facts.count);
            const captured_end = page.facts.end;
            const original = page.facts.items[0].value.stop;
            try std.testing.expectEqual(!close_turn, original.turn != null);
            try std.testing.expectEqual(if (settle_before_stop) @import("mutation_answer.zig").SessionStopCompletion.completed else .pending, original.completion);
            if (!settle_before_stop) _ = try storage.settleActionAttempt(binding, .succeeded, "After stop", .{});
            try readNativeActivity(&storage, &request, page);
            try std.testing.expectEqual(@import("mutation_answer.zig").SessionStopCompletion.completed, page.facts.items[0].value.stop.completion);
            request.end = captured_end;
            try readNativeActivity(&storage, &request, page);
            try std.testing.expectEqualDeep(original, page.facts.items[0].value.stop);
            try std.testing.expect(!storage.isFenced());
        }
    }
}

test "derived work facts are served across all work replies" {
    try store.testing.forEachEngine(struct {
        fn checkField(expected: std.json.Value, actual: std.json.Value, name: []const u8) !void {
            var a: [1024]u8 = undefined;
            var b: [1024]u8 = undefined;
            var aw = std.Io.Writer.fixed(&a);
            var bw = std.Io.Writer.fixed(&b);
            try std.json.Stringify.value(expected.object.get(name).?, .{}, &aw);
            try std.json.Stringify.value(actual.object.get(name).?, .{}, &bw);
            try std.testing.expectEqualStrings(aw.buffered(), bw.buffered());
        }
        fn run(case: *store.testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: store.Store = undefined;
            try store.testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try store.testing.configureTestSession(&storage, "facts-config");
            try store.testingSubmitMessage(&storage, &tmp, "facts-file", "facts-message", session.slice(), "input");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const report = try store.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
            defer std.testing.allocator.free(report);
            const current = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
            defer current.deinit();
            const expected = current.value.object.get("work").?;
            try std.testing.expect(expected.object.get("actions").?.object.get("stop").?.bool);
            try std.testing.expectEqual(binding.turn_id, try std.fmt.parseInt(u64, expected.object.get("actions").?.object.get("interrupt").?.object.get("turn").?.string, 10));
            var used = std.atomic.Value(u64).init(0);
            const listing = try store.testingSessionList(&storage, &tmp, .{}, &used, 914);
            defer std.testing.allocator.free(listing);
            const list = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, listing, .{});
            defer list.deinit();
            const list_work = list.value.object.get("sessions").?.array.items[0].object.get("work").?;
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try std.testing.allocator.create(@import("activity_facts.zig").Page);
            defer std.testing.allocator.destroy(page);
            try storage.activityPage(&request, page);
            var activity_buffer: [@import("activity_reply.zig").max_page_bytes]u8 = undefined;
            var activity_writer = std.Io.Writer.fixed(&activity_buffer);
            try @import("activity_reply.zig").writePage(&activity_writer, page);
            const activity = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, activity_writer.buffered(), .{});
            defer activity.deinit();
            const observed = try store.testing.observeCommandForTesting(&storage, "facts-message");
            var observation_buffer: protocol.CommandObservationBuffer = .{};
            try observation_buffer.render(@import("host_reply.zig").renderFullCommandObservation, .{ "facts-message", &observed, @as(?[]const u8, null) });
            const observation = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, observation_buffer.bytes[0..observation_buffer.len], .{});
            defer observation.deinit();
            inline for (.{ "state", "first_action", "actions" }) |field| {
                try checkField(expected, list_work, field);
                try checkField(expected, activity.value.object.get("work").?, field);
                try checkField(expected, observation.value.object.get("observation").?.object.get("work").?, field);
            }
        }
    }.run);
}

test "client decodes approval observation while automatic denial is pending" {
    try store.testing.forEachEngine(struct {
        fn run(case: *store.testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: store.Store = undefined;
            try store.testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace: [protocol.max_workspace_bytes]u8 = undefined;
            var configure = try store.testingCompleteConfiguration("decode-denial-config", "", try store.testingCanonicalCwd(std.testing.io, &workspace), "model-a");
            configure.configuration.tools = try .of(&.{"bash"});
            configure.configuration.permission_mode.state = .value;
            try configure.configuration.permission_mode.value.set("ask");
            const configured = try storage.configure(&configure, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            try store.testingSubmitMessage(&storage, &tmp, "decode-denial-file", "decode-denial-first", session.slice(), "run");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store.settleCallsForTesting(&storage, &tmp, model, "decode-denial-calls", &.{.{
                .item_id = "denial-item",
                .name = "bash",
                .encoded_call_id = "denial-call",
                .decoded_call_id = "denial-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\"}",
                .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"true\"}",
            }});
            try store.testingSubmitMessage(&storage, &tmp, "decode-denial-next-file", "decode-denial-next", session.slice(), "new instructions");
            const observed = try store.testing.observeCommandForTesting(&storage, "decode-denial-first");
            try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, observed.requestState().?);
            var response: protocol.CommandObservationBuffer = .{};
            try response.render(@import("host_reply.zig").renderFullCommandObservation, .{ "decode-denial-first", &observed, @as(?[]const u8, null) });
            const decoded = try protocol_reply.CommandObservation.parse(.{ .status = 200, .body = response.bytes[0..response.len] }, "decode-denial-first");
            try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, decoded.state.?);
            try std.testing.expectEqual(@as(?u64, null), decoded.work.?.first_action);
        }
    }.run);
}
