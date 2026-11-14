//! Configuration SQLite mechanism tests.

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
const c = sqlite.c;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const testSettings = tests.testSettings;
const testingBytesContent = tests.testingBytesContent;
const testingStore = store_testing.testingSqliteStore;
const expectModelRevisions = shared_fixtures.expectModelRevisions;

test "a fresh Store creates a Session with instructions, an output schema and the default tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // At open, each distinct built-in tool text is saved once (web search's
    // empty texts share one row); configure has imported nothing yet.
    var texts: std.StringHashMapUnmanaged(void) = .empty;
    defer texts.deinit(std.testing.allocator);
    for (tool_defs.built_in_tool_set.records) |record| for ([_][]const u8{ record.description, record.input_schema }) |text|
        try texts.put(std.testing.allocator, text, {});
    const tool_texts: u64 = texts.count();
    try std.testing.expectEqual(tool_texts, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try completeConfiguration("fresh-tool-texts", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    command.configuration.instructions = try testingBytesContent(&tmp, "fresh-instructions", "Be brief.");
    command.configuration.output_schema = try testingBytesContent(&tmp, "fresh-schema", "{\"type\":\"object\"}");
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    // The configure adds its two values.
    try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
    try std.testing.expectEqual(tool_texts + 2, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
}

test "a Session's tools are saved once and read back as saved, not as today's built-ins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Tools = struct {
        fn set(store: *Store, key: []const u8, session: protocol.Bounded(protocol.max_session_bytes), offered: []const []const u8) !void {
            var command: wire_request.ConfigureCommand = .{};
            try command.key.set(key);
            command.session = session;
            command.configuration.tools = try .of(offered);
            try std.testing.expect(try store.configure(&command, .{}) == .accepted);
        }
        fn counts(store: *Store) ![3]u64 {
            return .{
                try store_testing.queryU64(store, "SELECT count(*) FROM tool_set", .{}),
                try store_testing.queryU64(store, "SELECT count(*) FROM tool_record", .{}),
                try store_testing.queryU64(store, "SELECT count(*) FROM tool_set_member", .{}),
            };
        }
    };
    // The Host tool set: one set of every built-in, saved at open.
    const built_ins: u64 = tool_defs.built_in_tool_set.records.len;
    const all_names = comptime names: {
        var names: [tool_defs.built_in_tool_set.records.len][]const u8 = undefined;
        for (tool_defs.built_in_tool_set.records, &names) |record, *name| name.* = record.name;
        const final = names;
        break :names final;
    };
    try std.testing.expectEqual([3]u64{ 1, built_ins, built_ins }, try Tools.counts(&storage));
    // Two Sessions offering Bash share one set, of the tool set's record.
    const first = try configureTestSessionAsk(&storage, "saved-tools-first");
    const second = try configureTestSessionAsk(&storage, "saved-tools-second");
    try std.testing.expectEqual([3]u64{ 2, built_ins, built_ins + 1 }, try Tools.counts(&storage));
    // A set with the tool set's members is the Host tool set.
    try Tools.set(&storage, "saved-tools-all", first, &all_names);
    try std.testing.expectEqual([3]u64{ 2, built_ins, built_ins + 1 }, try Tools.counts(&storage));
    try Tools.set(&storage, "saved-tools-both", second, &.{ "bash", "web_search" });
    try std.testing.expectEqual([3]u64{ 3, built_ins, built_ins + 3 }, try Tools.counts(&storage));
    try Tools.set(&storage, "saved-tools-none", first, &.{});
    try std.testing.expectEqual([3]u64{ 4, built_ins, built_ins + 3 }, try Tools.counts(&storage));
    // Each revision keeps the set it was saved with.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(DISTINCT tool_set_id) FROM session_revision WHERE revision IN (1,2) AND " ++
        "session_ref=(SELECT session_ref FROM session_revision WHERE command_key='saved-tools-both')", .{}));

    // A reworded built-in changes no saved set: the saved text is what an
    // Operation offers.
    const reworded = "Reworded description.";
    try submitTestMessage(&storage, &tmp, "saved-tools-message", "saved-tools-message", second.slice(), reworded);
    try sqlite.exec(storage.sqliteDatabase(), "UPDATE tool_record SET description_content_id=(SELECT content_id FROM content WHERE CAST(payload AS TEXT)='Reworded description.') WHERE name='bash'");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    storage.openHistoricalView(binding, &view);
    defer view.close();
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(@as(u64, 2), settings.tool_count);
    var tool: historical_domain.HistoricalTool = .{};
    try std.testing.expect(try view.nextTool(&tool));
    try std.testing.expectEqualStrings("bash", tool.name.slice());
    try std.testing.expectEqual(tool_defs.Owner.rui, tool.owner);
    try std.testing.expectEqual(protocol.contentDigest(reworded), tool.description.digest);
    try std.testing.expectEqual(protocol.contentDigest(tool_defs.bash_record.input_schema), tool.input_schema.digest);
    try std.testing.expect(try view.nextTool(&tool));
    try std.testing.expectEqualStrings("web_search", tool.name.slice());
    try std.testing.expectEqual(tool_defs.Owner.provider, tool.owner);
    try std.testing.expect(!try view.nextTool(&tool));
}

test "persisted settings survive reopen and corrupt canonical provider fences current and historical reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("provider-reopen", "", workspace, "model-a");
    configuration.configuration.tools.state = .value;
    configuration.configuration.tools = try .of(&.{"bash"});
    configuration.configuration.permission_mode.state = .value;
    try configuration.configuration.permission_mode.value.set("ask");
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    const created_session_0_reply = try storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try expectModelRevisions(&storage, created_session_0.slice(), "before-reopen");
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const reopened = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(protocol.Provider.codex, reopened.provider.?);
    try tests.expectToolSetNames(&storage, reopened.tool_set_id, &.{"bash"});
    try std.testing.expectEqualStrings("ask", reopened.permission_mode.slice());
    try expectModelRevisions(&storage, created_session_0.slice(), "after-reopen");

    const file = try tmp.dir.createFile(std.testing.io, "provider-reopen-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("provider-reopen-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_testing.sqlite_only.exec(&storage, "UPDATE session_revision SET provider='other' WHERE session_ref=?1", .{created_session_0.slice()});
    var view: HistoricalView = undefined;
    storage.openHistoricalView(binding, &view);
    try std.testing.expectError(error.CorruptStore, testSettings(&view));
    view.close();
    try store_testing.sqlite_only.exec(&storage, "UPDATE session_revision SET provider='codex' WHERE session_ref=?1", .{created_session_0.slice()});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT codec='openai-responses/2' AND codec_options IS NULL FROM session", .{}));
    for ([_][:0]const u8{
        "UPDATE session SET provider='Codex' WHERE session_ref=?1",
        "UPDATE session_revision SET provider='9codex' WHERE session_ref=?1",
        "UPDATE session SET provider='codex.v2' WHERE session_ref=?1",
        "UPDATE session SET provider='' WHERE session_ref=?1",
        "UPDATE session SET provider='abcdefghijklmnopq' WHERE session_ref=?1",
        "UPDATE session SET codec_options=x'' WHERE session_ref=?1",
    }) |fault| try std.testing.expectError(error.StatementFailed, store_testing.sqliteExec(storage.sqliteDatabase(), fault, .{created_session_0.slice()}));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);

    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET provider='other' WHERE session_ref=?1", .{created_session_0.slice()});
    try std.testing.expectError(error.CorruptStore, storage.inspectSessionForTesting(created_session_0.slice()));
}

test "an Operation frozen to a codec this Host cannot build fences its settings" {
    for ([_]?[:0]const u8{
        null,
        "UPDATE model_operation SET request_codec='unknown-codec/1' WHERE session_ref=?1",
        "UPDATE model_operation SET request_codec_options=x'00' WHERE session_ref=?1",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT codec='openai-responses/2' AND codec_options IS NULL FROM session", .{}));
        try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "text");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        if (fault) |sql| try store_testing.sqliteExec(storage.sqliteDatabase(), sql, .{session.slice()});
        var view: HistoricalView = undefined;
        storage.openHistoricalView(binding, &view);
        defer view.close();
        if (fault == null) _ = try testSettings(&view) else try std.testing.expectError(error.CorruptStore, testSettings(&view));
    }
}

test "configuration rejections bypass content effects and replay committed answer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const instructions = "rejected instructions";
    const instructions_file = try tmp.dir.createFile(std.testing.io, "rejected-instructions", .{ .read = true });
    try instructions_file.writeStreamingAll(std.testing.io, instructions);
    try instructions_file.sync(std.testing.io);
    const schema = "{\"type\":\"object\"}";
    const schema_file = try tmp.dir.createFile(std.testing.io, "rejected-schema", .{ .read = true });
    try schema_file.writeStreamingAll(std.testing.io, schema);
    try schema_file.sync(std.testing.io);
    var command: wire_request.ConfigureCommand = .{};
    try command.key.set("rejected-content");
    try command.session.set("invalid/session");
    command.configuration.instructions = .{
        .state = .value,
        .file = instructions_file,
        .length = instructions.len,
        .digest = protocol.contentDigest(instructions),
    };
    command.configuration.output_schema = .{
        .state = .value,
        .file = schema_file,
        .length = schema.len,
        .digest = protocol.contentDigest(schema),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        try std.testing.expect(try storage.configure(&command, .{
            .content_import = true,
            .before_commit = true,
        }) == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "rejected-content")).status == .absent);
        const rolled_back_content = try sqlite.prepare(storage.sqliteDatabase(), "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)");
        defer _ = c.sqlite3_finalize(rolled_back_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(rolled_back_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(rolled_back_content, 0));

        const rejected = try storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
        const committed_content = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT COUNT(*) FROM core_command WHERE command_key='rejected-content' " ++
                "AND primary_content_id IS NULL AND secondary_content_id IS NULL",
        );
        defer _ = c.sqlite3_finalize(committed_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(committed_content));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(committed_content, 0));

        const replay = try storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(replay == .rejected);
        try std.testing.expect(replay.rejected.replayed);
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, replay.rejected.code);
        const retained_content = try sqlite.prepare(storage.sqliteDatabase(), "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)");
        defer _ = c.sqlite3_finalize(retained_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(retained_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(retained_content, 0));
    }
}
