//! Tool set SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const settleCallsForTesting = tests.settleCallsForTesting;
const testingSessionList = tests.testingSessionList;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const sortHostToolRecords = store_testing.sortHostToolRecords;
const testingStoreToolSet = store_testing.testingStoreToolSet;
const testingStore = store_testing.testingSqliteStore;
const mcp_record = shared_fixtures.mcp_record;
const mcp_tool_set = shared_fixtures.mcp_tool_set;
const testing_tool_set = shared_fixtures.testing_tool_set;

test "loaded tools hide configured tools from frozen requests reports and call settlement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var empty = try completeConfiguration("loaded-empty", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    empty.configuration.tools = try .of(&.{});
    const empty_reply = try storage.configure(&empty, .{});
    try std.testing.expect(empty_reply == .accepted);
    const session = try configureTestSessionAsk(&storage, "loaded-hidden");
    // An empty loaded set is deliberately unreachable through configure. Seed
    // its durable representation to exercise frozen settlement defensively.
    try store_testing.setLoadedToolsForTesting(&storage, session.slice(), empty_reply.accepted.session.slice());
    for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
        const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
        defer std.testing.allocator.free(bytes);
        const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        const settings = report.value.object.get("session").?.object;
        try std.testing.expectEqualStrings("bash", settings.get("tools").?.array.items[0].string);
        try std.testing.expectEqual(@as(usize, 0), settings.get("loaded_tools").?.array.items.len);
        if (profile == .full) {
            const revision = report.value.object.get("full").?.object.get("session_revisions").?.array.items[0].object;
            try std.testing.expectEqualStrings("bash", revision.get("tools").?.array.items[0].string);
            try std.testing.expectEqual(@as(usize, 0), revision.get("loaded_tools").?.array.items.len);
        }
    }
    try submitTestMessage(&storage, &tmp, "loaded-hidden-message", "loaded-hidden-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    {
        var view: HistoricalView = undefined;
        storage.openHistoricalView(binding, &view);
        defer view.close();
        var settings: HistoricalSettings = undefined;
        try view.settings(&settings);
        try std.testing.expectEqual(@as(u64, 0), settings.tool_count);
        var tool: historical_domain.HistoricalTool = .{};
        try std.testing.expect(!try view.nextTool(&tool));
    }
    // Loading Bash after admission does not widen that frozen Operation.
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("loaded-hidden-grow");
    update.session = session;
    update.configuration.loaded_tools = try .of(&.{"bash"});
    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "loaded-hidden-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=0 AND rejection_code='unknown_tool' AND description='Run'", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
}

test "a tool set at its bound saves and opens again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Reserve all required built-ins (including skill), then fill the rest
    // with independent synthetic records up to the tool set's declared bound.
    const count = tool_defs.max_host_tool_records - tool_defs.built_in_tool_set.records.len;
    var names: [count][9]u8 = undefined;
    var records: [tool_defs.max_host_tool_records]tool_defs.Record = undefined;
    var digests: [tool_defs.max_host_tool_records][32]u8 = undefined;
    @memcpy(records[0..tool_defs.built_in_tool_set.records.len], tool_defs.built_in_tool_set.records);
    for (&names, records[tool_defs.built_in_tool_set.records.len..], 0..) |*name, *record, index| {
        _ = try std.fmt.bufPrint(name, "tool_{d:0>4}", .{index});
        record.* = .{ .name = name, .owner = .rui, .description = "A tool among many.", .input_schema = "{\"type\":\"object\"}" };
    }
    sortHostToolRecords(&records);
    for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
    const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &host_tool_set);
    try storage.close();
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &host_tool_set);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, tool_defs.max_host_tool_records), try store_testing.queryU64(&storage, "SELECT max(member_count) FROM tool_set", .{}));
}

fn expectHostToolSet(expected: *const tool_defs.HostToolSet, saved: *const store_core.SavedHostToolSet) !void {
    try std.testing.expectEqual(expected.records.len, saved.records.len);
    for (expected.records, saved.records, expected.digests, saved.digests) |want, got, want_digest, got_digest| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.owner, got.owner);
        try std.testing.expectEqualStrings(want.server, got.server);
        try std.testing.expectEqualStrings(want.description, got.description);
        try std.testing.expectEqualStrings(want.input_schema, got.input_schema);
        try std.testing.expectEqualSlices(u8, &want_digest, &got_digest);
    }
}

test "a Store opened without a tool set reads back the last one saved, an MCP server's tools included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    try std.testing.expect(try storage.readHostToolSet(std.testing.allocator) == null);
    try storage.saveHostToolSet(&mcp_tool_set);
    try storage.close();

    try testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    {
        var saved = (try storage.readHostToolSet(std.testing.allocator)).?;
        defer saved.deinit(std.testing.allocator);
        try expectHostToolSet(&mcp_tool_set, &saved);
        // The Host saves what it read when it reaches no server.
        const read = saved.toolSet();
        try storage.saveHostToolSet(&read);
    }
    // A later tool set without the server's tool replaces it, and saving
    // the earlier one again finds its set.
    try storage.saveHostToolSet(&testing_tool_set);
    {
        var saved = (try storage.readHostToolSet(std.testing.allocator)).?;
        defer saved.deinit(std.testing.allocator);
        try expectHostToolSet(&testing_tool_set, &saved);
    }
    const sets = try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{});
    try storage.saveHostToolSet(&mcp_tool_set);
    try std.testing.expectEqual(sets, try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{}));
    var saved = (try storage.readHostToolSet(std.testing.allocator)).?;
    defer saved.deinit(std.testing.allocator);
    try expectHostToolSet(&mcp_tool_set, &saved);
    try storage.close();
}

test "a saved tool set whose text no longer matches its digest fences the Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;
    try storage.saveHostToolSet(&mcp_tool_set);
    try sqlite.exec(storage.sqliteDatabase(), "UPDATE content SET payload=CAST(upper(CAST(payload AS TEXT)) AS BLOB) WHERE content_id=(SELECT description_content_id FROM tool_record WHERE owner='mcp')");
    try std.testing.expectError(error.CorruptStore, storage.readHostToolSet(std.testing.allocator));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.readHostToolSet(std.testing.allocator));
}

test "find_tools fences a description whose bytes no longer match its digest, searched or listed" {
    // "fetch" matches the tool's name, so only its listing reads the
    // description; "absent" matches nothing, so the search reads it whole.
    for ([_][]const u8{ "fetch", "absent" }) |word| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        var command = try completeConfiguration("find-corrupt", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
        command.configuration.tools = try .of(&.{ "fetch_page", "find_tools" });
        command.configuration.loaded_tools = try .of(&.{"find_tools"});
        const session = (try storage.configure(&command, .{})).accepted.session;
        try submitTestMessage(&storage, &tmp, "find-corrupt-input", "find-corrupt-key", session.slice(), "find tools");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{.{ .item_id = "find", .name = "find_tools", .encoded_call_id = "find", .decoded_call_id = "find", .encoded_arguments = "{\\\"words\\\":\\\"fetch\\\"}", .decoded_arguments = "{\"words\":\"fetch\"}" }};
        try settleCallsForTesting(&storage, &tmp, model, "find-corrupt", &calls);
        const input = (try storage.nextCoreWork()).?.action;
        try std.testing.expect(input.tool == .find_tools);
        try sqlite.exec(storage.sqliteDatabase(), "UPDATE content SET payload=CAST(upper(CAST(payload AS TEXT)) AS BLOB) WHERE content_id=(SELECT description_content_id FROM tool_record WHERE owner='mcp')");
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var words: @import("../../find_tools_words.zig").FindTools = .{ .count = 1 };
        words.words[0] = word;
        try std.testing.expectError(error.CorruptStore, storage.findTools(input.binding, arena.allocator(), &words, null, .{}));
        try std.testing.expect(storage.isFenced());
    }
}

test "a Session offering an MCP server's tool is listed, reported and settled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("mcp-config", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{ "bash", "fetch_page" });
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const session = reply.accepted.session;
    // Reading and reconfiguring it neither refuses nor fences.
    _ = try storage.inspectSessionForTesting(session.slice());
    var reworded: wire_request.ConfigureCommand = .{};
    try reworded.key.set("mcp-reconfigure");
    reworded.session = session;
    reworded.configuration.tools = try .of(&.{ "bash", "fetch_page", "test_tool" });
    try std.testing.expect(try storage.configure(&reworded, .{}) == .accepted);
    reworded = .{};
    try reworded.key.set("mcp-reconfigure-back");
    reworded.session = session;
    reworded.configuration.tools = try .of(&.{ "bash", "fetch_page" });
    try std.testing.expect(try storage.configure(&reworded, .{}) == .accepted);
    try std.testing.expect(!storage.isFenced());

    try submitTestMessage(&storage, &tmp, "mcp-message", "mcp-message", session.slice(), "fetch");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // MCP calls settle as Actions beside Bash, even before the runner lands.
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
        .{ .item_id = "item-2", .name = "fetch_page", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "mcp-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE call_ordinal=0", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=1 AND rejection_code IS NULL AND action_kind=1", .{}));

    const offered = "\"tools\":[\"bash\",\"fetch_page\"]";
    for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
        const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
        defer std.testing.allocator.free(report);
        try std.testing.expect(std.mem.indexOf(u8, report, offered) != null);
        // The full profile's revision lists them too.
        if (profile == .full) try std.testing.expect(std.mem.indexOf(u8, report[std.mem.indexOf(u8, report, offered).? + 1 ..], offered) != null);
    }
    var used = std.atomic.Value(u64).init(0);
    const list = try testingSessionList(&storage, &tmp, .{}, &used, 1);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, session.slice()) != null);
    try std.testing.expect(std.mem.indexOf(u8, list, offered) != null);
}

test "a record names a server exactly when an MCP server owns it" {
    try std.testing.expect(tool_defs.validServer(&mcp_record));
    try std.testing.expect(!tool_defs.validServer(&.{ .name = "fetch_page", .owner = .mcp }));
    try std.testing.expect(!tool_defs.validServer(&.{ .name = "fetch_page", .owner = .mcp, .server = "docs server" }));
    try std.testing.expect(!tool_defs.validServer(&.{ .name = "bash", .owner = .rui, .server = "docs" }));
    // Moving servers makes another record.
    var moved = mcp_record;
    moved.server = "wiki";
    try std.testing.expect(!std.mem.eql(u8, &tool_defs.recordDigest(&mcp_record), &tool_defs.recordDigest(&moved)));
}
