//! Tool-loading behaviour runs through the same engine seam as core commands.
const std = @import("std");
const protocol = @import("../protocol.zig");
const core = @import("../core_tools.zig");
const loader = @import("../find_tools.zig");
const tools = @import("../tools.zig");
const Store = @import("Store.zig").Store;
const action = @import("domain/action.zig");
const content = @import("domain/content.zig");
const historical = @import("domain/historical.zig");
const testing = @import("testing.zig");
const helpers = @import("tests.zig");

fn call(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, arguments: []const u8, id: []const u8, arena: std.mem.Allocator) !action.CoreActionInput {
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const encoded = try std.json.Stringify.valueAlloc(arena, arguments, .{});
    const calls = [_]helpers.TestingCall{.{ .item_id = id, .name = "find_tools", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments }};
    try helpers.settleCallsForTesting(storage, tmp, model, id, &calls);
    const input = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(input.tool == .find_tools);
    try std.testing.expectEqualStrings(session, input.session.slice());
    // A core call never becomes a process Attempt.
    try std.testing.expect(try storage.admitNextActionAttempt(30000, .{}) == null);
    return input;
}

fn configure(storage: *Store, key: []const u8, names: []const []const u8, initial_loaded: []const []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var path: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try testing.completeConfiguration(key, "", try testing.canonicalCwd(std.testing.io, &path), "model-a");
    command.configuration.tools = try .of(names);
    command.configuration.loaded_tools = try .of(initial_loaded);
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

fn count(storage: *Store, session: []const u8, comptime table: []const u8) !u64 {
    return testing.queryU64(storage, "SELECT count(*) FROM " ++ table ++ " WHERE session_ref=?1", .{session});
}

fn loaded(storage: *Store, session: []const u8, name: []const u8) !bool {
    return 1 == try testing.queryU64(storage, "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=coalesce(s.loaded_tool_set_id,s.tool_set_id) " ++
        "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name=?2", .{ session, name });
}

fn result(storage: *Store, session: protocol.Bounded(protocol.max_session_bytes), arena: std.mem.Allocator) ![]const u8 {
    const page = try arena.create(protocol.ActivityFacts);
    var request: protocol.ActivityPage = .{ .session = session, .direction = .backward, .limit = 16, .kinds = .initOne(.tool_result) };
    try storage.activityPage(&request, page);
    // The loader is the first call; grouped rejected calls can have a later ordinal.
    const reference = for (page.items[0..page.count]) |*item| {
        if (item.ordinal == 1) break item.value.tool_result.content;
    } else return error.MissingFindToolsResult;
    var reader: content.ContentReader = undefined;
    reader.open(try storage.openContent(.{ .length = reference.length, .digest = reference.digest }));
    defer reader.close();
    const bytes = try arena.alloc(u8, @intCast(reference.length));
    try std.testing.expectEqual(bytes.len, try reader.read(0, bytes));
    return bytes;
}

test "find_tools loads saved name and description matches once in one revision and settles newly loaded tools" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const session = try configure(&storage, "find-matches", &.{ "bash", "find_tools", "message_agent", "read_transcript" }, &.{"find_tools"});
            // Another Session with the resulting subset proves set interning.
            const donor = try configure(&storage, "find-donor", &.{ "bash", "find_tools", "message_agent", "read_transcript" }, &.{ "bash", "find_tools", "read_transcript" });
            try testing.submitTestMessage(&storage, &tmp, "find-message", "find-message", session.slice(), "find tools");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const args = "{\"words\":\"  BASH  PUBLIC \"}";
            const encoded = try std.json.Stringify.valueAlloc(alloc, args, .{});
            const calls = [_]helpers.TestingCall{
                .{ .item_id = "find", .name = "find_tools", .encoded_call_id = "find", .decoded_call_id = "find", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = args },
                .{ .item_id = "hidden", .name = "bash", .encoded_call_id = "hidden", .decoded_call_id = "hidden", .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"description\\\":\\\"Run\\\"}", .decoded_arguments = "{\"cmd\":\"true\",\"description\":\"Run\"}" },
            };
            try helpers.settleCallsForTesting(&storage, &tmp, model, "find-first", &calls);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE operation_id=?1 AND rejection_code='unknown_tool'", .{model.operation_id}));
            const input = (try storage.nextCoreWork()).?.action;
            try std.testing.expect(input.tool == .find_tools);
            const revisions = try count(&storage, session.slice(), "session_revision");
            const changes = try count(&storage, session.slice(), "session_change");
            try loader.run(&storage, alloc, &input, .{});
            try std.testing.expect(try loaded(&storage, session.slice(), "bash"));
            try std.testing.expect(try loaded(&storage, session.slice(), "read_transcript"));
            try std.testing.expect(!try loaded(&storage, session.slice(), "message_agent"));
            try std.testing.expectEqual(revisions + 1, try count(&storage, session.slice(), "session_revision"));
            try std.testing.expectEqual(changes + 1, try count(&storage, session.slice(), "session_change"));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE session_ref=?1 AND revision=2 AND field='loaded_tools'", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(DISTINCT loaded_tool_set_id) FROM session WHERE session_ref=?1 OR session_ref=?2", .{ session.slice(), donor.slice() }));
            const names = try result(&storage, session, alloc);
            try std.testing.expect(std.mem.indexOf(u8, names, "bash") != null and std.mem.indexOf(u8, names, "read_transcript") != null);
            // Replay is harmless even if the caller retained a stale input.
            try loader.run(&storage, alloc, &input, .{});
            try std.testing.expectEqual(revisions + 1, try count(&storage, session.slice(), "session_revision"));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1", .{try std.fmt.allocPrint(alloc, "rui.core/find_tools/{d}", .{input.binding.action_id})}));
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: historical.HistoricalView = undefined;
            try storage.openHistoricalView(next, &view);
            var settings: historical.HistoricalSettings = undefined;
            try view.settings(&settings);
            try std.testing.expectEqual(@as(u64, 3), settings.tool_count);
            view.close();
            const found = [_]helpers.TestingCall{.{ .item_id = "found", .name = "read_transcript", .encoded_call_id = "found", .decoded_call_id = "found", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try helpers.settleCallsForTesting(&storage, &tmp, next, "find-found", &found);
            const read = (try storage.nextCoreWork()).?.action;
            try std.testing.expect(read.tool == .read_transcript);
            try @import("../read_transcript.zig").run(&storage, alloc, &read, .{});
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "find_tools no match and bad words resolve without revisions then equality uses NULL" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const session = try configure(&storage, "find-empty", &.{ "bash", "find_tools" }, &.{"find_tools"});
            try testing.submitTestMessage(&storage, &tmp, "find-empty-input", "find-empty-input", session.slice(), "find tools");
            const cases = [_][]const u8{ "{\"words\":\"no-match-at-all\"}", "{}", "[]", "{", "{\"words\":null}", "{\"words\":\"  \"}", "{\"words\":\"1 2 3 4 5 6 7 8 9\"}", "{\"words\":\"bash\",\"extra\":1}", "{\"words\":\"" ++ @as([65]u8, @splat('x')) ++ "\"}" };
            for (cases, 0..) |args, index| {
                const id = try std.fmt.allocPrint(alloc, "find-empty-{d}", .{index});
                const input = try call(&storage, &tmp, session.slice(), args, id, alloc);
                try loader.run(&storage, alloc, &input, .{});
                try std.testing.expectEqual(@as(u64, 1), try count(&storage, session.slice(), "session_revision"));
                try std.testing.expectEqual(@as(u64, 0), try count(&storage, session.slice(), "session_change"));
                const code = if (index == 0) "succeeded" else "failed";
                try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ input.binding.action_id, code }));
                if (index != 0) try std.testing.expect(std.mem.indexOf(u8, try result(&storage, session, alloc), "words") != null);
            }
            // A huge argument is refused before it is read: a 16 KiB arena
            // cannot hold its 64 KiB, so success proves it was never copied.
            const huge = try alloc.alloc(u8, 64 * 1024);
            @memset(huge, 'x');
            @memcpy(huge[0..10], "{\"words\":\"");
            @memcpy(huge[huge.len - 2 ..], "\"}");
            const huge_input = try call(&storage, &tmp, session.slice(), huge, "find-huge", alloc);
            var small_buffer: [16 * 1024]u8 = undefined;
            var small: std.heap.FixedBufferAllocator = .init(&small_buffer);
            try loader.run(&storage, small.allocator(), &huge_input, .{});
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='failed'", .{huge_input.binding.action_id}));
            try std.testing.expect(std.mem.indexOf(u8, try result(&storage, session, alloc), "words") != null);
            const input = try call(&storage, &tmp, session.slice(), "{\"words\":\"bash\"}", "find-equality", alloc);
            try loader.run(&storage, alloc, &input, .{});
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL AND revision=2", .{session.slice()}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "find_tools caps eight sorted matches skips loaded and out of set and rolls back a crash" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var open = true;
            defer if (open) storage.close() catch unreachable;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const records = try alloc.alloc(tools.Record, tools.built_in.records.len + 12);
            @memcpy(records[0..tools.built_in.records.len], tools.built_in.records);
            var names: [12][]const u8 = undefined;
            names[0] = "find_tools";
            for (records[tools.built_in.records.len..], 0..) |*record, index| {
                const name = try std.fmt.allocPrint(alloc, "match_{d:0>2}", .{index});
                record.* = .{ .name = name, .owner = .mcp, .server = "test", .description = "MATCH first line\nNot part of the preview.", .input_schema = "{}" };
                if (index < 11) names[index + 1] = name;
            }
            std.mem.sort(tools.Record, records, {}, struct {
                fn less(_: void, a: tools.Record, b: tools.Record) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.less);
            const digests = try alloc.alloc([32]u8, records.len);
            for (records, digests) |*record, *digest| digest.* = tools.recordDigest(record);
            const catalog: tools.Catalog = .{ .records = records, .digests = digests };
            try storage.saveCatalog(&catalog);
            const session = try configure(&storage, "find-cap", &names, &.{ "find_tools", "match_00" });
            // Today's catalog no longer has the descriptions used by this Session.
            try storage.saveCatalog(&tools.built_in);
            try testing.submitTestMessage(&storage, &tmp, "find-cap-input", "find-cap-input", session.slice(), "find tools");
            const input = try call(&storage, &tmp, session.slice(), "{\"words\":\"match\"}", "find-cap-call", alloc);
            try std.testing.expectError(error.InjectedCommitFailure, loader.run(&storage, alloc, &input, .{ .before_commit = true }));
            try storage.close();
            open = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            open = true;
            try std.testing.expectEqual(@as(u64, 1), try count(&storage, session.slice(), "session_revision"));
            try std.testing.expectEqual(@as(u64, 0), try count(&storage, session.slice(), "session_change"));
            try std.testing.expect(!try loaded(&storage, session.slice(), "match_01"));
            const retry = (try storage.nextCoreWork()).?.action;
            try std.testing.expectEqual(input.binding.action_id, retry.binding.action_id);
            try loader.run(&storage, alloc, &retry, .{});
            for (1..9) |index| try std.testing.expect(try loaded(&storage, session.slice(), names[index + 1]));
            try std.testing.expect(!try loaded(&storage, session.slice(), "match_09"));
            try std.testing.expect(!try loaded(&storage, session.slice(), "match_11"));
            try std.testing.expectEqual(@as(u64, 2), try count(&storage, session.slice(), "session_revision"));
            try std.testing.expectEqual(@as(u64, 1), try count(&storage, session.slice(), "session_change"));
            try loader.run(&storage, alloc, &retry, .{});
            try std.testing.expectEqual(@as(u64, 2), try count(&storage, session.slice(), "session_revision"));
            const bytes = try result(&storage, session, alloc);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "Not part of the preview") == null);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "find_tools searches saved descriptions across MySQL chunk boundaries with literal words" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const chunk_bytes = @import("schema.zig").content_chunk_bytes;
            const description = try alloc.alloc(u8, 3 * chunk_bytes + 128);
            @memset(description, 'x');
            @memcpy(description[0..8], "Preview\n");
            @memcpy(description[chunk_bytes - 4 ..][0..8], "BoUnDaRy");
            @memcpy(description[3 * chunk_bytes + 5 ..][0..7], "Late%_Z");
            // Exercise carry at the actual Host read edge as well as the
            // durable MySQL chunk edge, including a maximum-length word.
            const read_bytes = content.ContentReader.content_window_bytes;
            @memset(description[read_bytes - 32 ..][0..64], 'Q');
            @memcpy(description[2 * chunk_bytes - 3 ..][0..7], "LiT%_Er");
            // A NUL and non-ASCII letters do not stop or broaden ASCII folding.
            description[chunk_bytes + 10] = 0;
            @memcpy(description[chunk_bytes + 11 ..][0..5], "CAFÉ");
            var records: [tools.built_in.records.len + 1]tools.Record = undefined;
            @memcpy(records[0..tools.built_in.records.len], tools.built_in.records);
            records[tools.built_in.records.len] = .{ .name = "probe", .owner = .mcp, .server = "test", .description = description, .input_schema = "{}" };
            std.mem.sort(tools.Record, &records, {}, struct {
                fn less(_: void, a: tools.Record, b: tools.Record) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.less);
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tools.recordDigest(record);
            const catalog: tools.Catalog = .{ .records = &records, .digests = &digests };
            try storage.saveCatalog(&catalog);
            const cases = [_]struct { words: []const u8, match: bool }{
                .{ .words = "boundary", .match = true },
                .{ .words = &@as([64]u8, @splat('x')), .match = true },
                .{ .words = "late%_z", .match = true },
                .{ .words = "lit%_er", .match = true },
                .{ .words = &@as([64]u8, @splat('q')), .match = true },
                .{ .words = "bePreview", .match = false },
                .{ .words = "cafÉ", .match = true },
                .{ .words = "café", .match = false },
                .{ .words = "%_no", .match = false },
                // Every checked word participates in the shared matcher search.
                .{ .words = "absent1 absent2 absent3 absent4 absent5 absent6 absent7 BOUNDARY", .match = true },
            };
            for (cases, 0..) |item, index| {
                errdefer std.debug.print("description search case {d}: {s}\n", .{ index, item.words });
                const key = try std.fmt.allocPrint(alloc, "find-chunk-{d}", .{index});
                const session = try configure(&storage, key, &.{ "find_tools", "probe" }, &.{"find_tools"});
                const input_key = try std.fmt.allocPrint(alloc, "{s}-input", .{key});
                try testing.submitTestMessage(&storage, &tmp, input_key, input_key, session.slice(), "find tools");
                const args = try std.fmt.allocPrint(alloc, "{{\"words\":\"{s}\"}}", .{item.words});
                const input = try call(&storage, &tmp, session.slice(), args, try std.fmt.allocPrint(alloc, "chunk-call-{d}", .{index}), alloc);
                try loader.run(&storage, alloc, &input, .{});
                try std.testing.expectEqual(item.match, try loaded(&storage, session.slice(), "probe"));
                if (item.match) {
                    const bytes = try result(&storage, session, alloc);
                    try std.testing.expect(std.mem.indexOf(u8, bytes, "Preview") != null);
                    try std.testing.expect(std.mem.indexOf(u8, bytes, "xxx") == null);
                }
                // This Session's continuation would otherwise run before the
                // next Session's initial call in the shared engine harness.
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try testing.settleItemsForTesting(&storage, &tmp, next, &.{"{\"type\":\"message\",\"id\":\"done\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"}, "done");
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}
