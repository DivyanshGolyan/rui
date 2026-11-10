//! Contracts between Store replies and the client reply decoder.
const std = @import("std");
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
