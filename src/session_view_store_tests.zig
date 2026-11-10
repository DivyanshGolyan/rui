const std = @import("std");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const protocol_reply = @import("protocol_reply.zig");
const tool_catalog = @import("tools.zig");
const store = @import("store.zig");

test "MCP ask approval uses the frozen server after its Session offer changes" {
    const Store = store.Store;
    const testingStoreCatalog = store.testing.testingStoreCatalog;
    const catalogRecordsWith = store.testing.catalogRecordsWith;
    const submitTestMessage = store.testingSubmitMessage;
    const settleCallsForTesting = store.settleCallsForTesting;
    const ContentReader = store.ContentReader;
    const testingSessionReportWithProfile = store.testingSessionReportWithProfile;
    const canonicalCwd = store.testingCanonicalCwd;
    const completeConfiguration = store.testingCompleteConfiguration;
    const View = @import("session_view.zig");
    const tools = tool_catalog;
    const records = comptime catalogRecordsWith(&.{.{
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
    const catalog: tools.Catalog = .{ .records = &records, .digests = &digests };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreCatalog(&storage, &tmp, std.testing.io, &catalog);
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
    const summary = try View.renderPermissionArguments(std.testing.io, scratch, &sink, false, &tool);
    try std.testing.expectEqualStrings("fetch_page", summary.description.slice());
    try std.testing.expectEqualStrings("\n? fetch_page\n  Tool: fetch_page\n  Server: docs\n  Arguments:\n  │ {}\n", sink.bytes[0..sink.len]);
    try std.testing.expect((try storage.nextCoreWork()) == null);
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action, .decision = .allow_once };
    try allow.key.set("approval-allow");
    allow.session = session;
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    try std.testing.expectEqual(action, (try storage.nextCoreWork()).?.mcp.action_id);
}
