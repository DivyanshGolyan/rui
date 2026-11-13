//! Historical Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const HistoricalEntry = historical_domain.HistoricalEntry;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const ModelOperationKind = historical_domain.ModelOperationKind;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingAttempt = shared_fixtures.TestingAttempt;
const TestingCall = shared_fixtures.TestingCall;
const TestingHistoryCursor = shared_fixtures.TestingHistoryCursor;
const TwinRounds = shared_fixtures.TwinRounds;
const ViewRounds = shared_fixtures.ViewRounds;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const failed_purpose_operations_sql = shared_fixtures.failed_purpose_operations_sql;
const nextTestingItem = shared_fixtures.nextTestingItem;
const readTestingContent = shared_fixtures.readTestingContent;
const renderTestingEntry = shared_fixtures.renderTestingEntry;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingSessionReport = shared_fixtures.testingSessionReport;

test "missing canonical call outcome rows fence history and inspection" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { action, call, result_content }{ .action, .call, .result_content };
            const config_keys = [_][]const u8{ "missing-config-action", "missing-config-call", "missing-config-content" };
            const message_keys = [_][]const u8{ "missing-message-action", "missing-message-call", "missing-message-content" };
            const message_files = [_][]const u8{ "missing-file-action", "missing-file-call", "missing-file-content" };
            const metadata_files = [_][]const u8{ "missing-metadata-action", "missing-metadata-call", "missing-metadata-content" };
            const denial_keys = [_][]const u8{ "missing-denial-action", "missing-denial-call", "missing-denial-content" };
            for (corruptions, 0..) |corruption, index| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, config_keys[index]);
                const session_ref = session.slice();
                try submitTestMessage(
                    &storage,
                    &tmp,
                    message_files[index],
                    message_keys[index],
                    session_ref,
                    "call",
                );
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const calls = [_]TestingCall{.{
                    .item_id = "missing-item",
                    .name = "bash",
                    .encoded_call_id = "missing-call",
                    .decoded_call_id = "missing-call",
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                }};
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    source,
                    metadata_files[index],
                    &calls,
                );
                var denial: protocol.PermissionDecisionCommand = .{
                    .action_id = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{}),
                };
                try denial.key.set(denial_keys[index]);
                try denial.session.set(session_ref);
                try std.testing.expect(storage.decidePermission(&denial, .{}) == .accepted);
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

                switch (corruption) {
                    .action => try store_testing.withoutForeignKeys(&storage, "DELETE FROM action_operation", .{}),
                    .call => try store_testing.withoutForeignKeys(&storage, "DELETE FROM action_operation; DELETE FROM model_tool_call", .{}),
                    .result_content => try store_testing.withoutForeignKeys(&storage, "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation LIMIT 1)", .{}),
                }

                if (corruption == .action) {
                    var view: HistoricalView = undefined;
                    storage.openHistoricalView(continuation, &view);
                    defer view.close();
                    var position: u64 = 0;
                    while (true) {
                        const entry = view.nextEntry(position) catch |err| {
                            try std.testing.expectEqual(error.CorruptStore, err);
                            break;
                        } orelse return error.MissingCorruptionFailure;
                        position = entry.position;
                    }
                } else {
                    try std.testing.expectError(
                        error.CorruptStore,
                        testingSessionReport(&storage, &tmp, session_ref, 1024 * 1024),
                    );
                }
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "historical tool-result EOF revalidates complete canonical coverage" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "eof-coverage-config");
            try submitTestMessage(
                &storage,
                &tmp,
                "eof-coverage-file",
                "eof-coverage-message",
                session.slice(),
                "call",
            );
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "eof-item-0", .name = "unknown", .encoded_call_id = "eof-call-0", .decoded_call_id = "eof-call-0", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "eof-item-1", .name = "unknown", .encoded_call_id = "eof-call-1", .decoded_call_id = "eof-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, source, "eof-coverage-metadata", &calls);
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(continuation, &view);
            defer view.close();
            var position: u64 = 0;
            while (true) {
                const entry = (try nextTestingItem(&view, position)) orelse return error.MissingToolResultGroup;
                position = entry.position;
                if (entry.kind == .tool_results) break;
            }
            // The group's results are read a page at a time, so the call
            // goes missing before its page is read.
            try store_testing.withoutForeignKeys(&storage, "DELETE FROM model_tool_call WHERE call_ordinal=1", .{});
            try std.testing.expect((try view.nextToolResult()) != null);
            try std.testing.expectError(error.CorruptStore, view.nextToolResult());
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

/// A message item whose text is `count` output_text parts, part `index`
/// reading `p<index>;`, written into `buffer`; `answer` gets the text.
fn manyPartMessage(buffer: []u8, answer: []u8, comptime count: usize) !struct { item: []const u8, answer: []const u8 } {
    var item = std.Io.Writer.fixed(buffer);
    var text = std.Io.Writer.fixed(answer);
    try item.writeAll("{\"type\":\"message\",\"id\":\"many\",\"role\":\"assistant\",\"content\":[");
    for (0..count) |index| {
        if (index != 0) try item.writeByte(',');
        try item.print("{{\"type\":\"output_text\",\"text\":\"p{d};\"}}", .{index});
        try text.print("p{d};", .{index});
    }
    try item.writeAll("]}");
    return .{ .item = item.buffered(), .answer = text.buffered() };
}

test "a view's page holds the outputs its entries name under no floor, a deeper floor and an inherited one" {
    try store_testing.forEachEngine(struct {
        /// The view's entries in order, each rendered and joined by `;`.
        fn walk(storage: *Store, binding: AttemptBinding, buffer: []u8) ![]const u8 {
            var view: HistoricalView = undefined;
            storage.openHistoricalView(binding, &view);
            defer view.close();
            var out = std.Io.Writer.fixed(buffer);
            var cursor: TestingHistoryCursor = .{};
            var rendered: [256]u8 = undefined;
            while (try cursor.next(&view)) |entry| {
                if (entry.kind == .tool_results) continue;
                try out.print("{s};", .{try renderTestingEntry(&view, entry, &rendered)});
            }
            return out.buffered();
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "floor-page-config");
            try submitTestMessage(&storage, &tmp, "floor-page-one", "floor-page-one", session.slice(), "first");
            const overflowed = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(overflowed, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
            // More outputs than a page holds, from one Operation the floor
            // will drop, between the base and a newer output it keeps.
            const many = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var texts: [20][160]u8 = undefined;
            var items: [20][]const u8 = undefined;
            for (&items, &texts, 0..) |*item, *text, index|
                item.* = try std.fmt.bufPrint(text, "{{\"type\":\"message\",\"id\":\"d{d}\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"dropped\"}}]}}", .{index});
            try settleItemsForTesting(&storage, &tmp, many, &items, "dropped");
            try submitTestMessage(&storage, &tmp, "floor-page-two", "floor-page-two", session.slice(), "second");
            const kept = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, kept, &.{"{\"type\":\"message\",\"id\":\"k\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"kept\"}]}"}, "kept");
            try submitTestMessage(&storage, &tmp, "floor-page-three", "floor-page-three", session.slice(), "third");
            const full = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var buffer: [4096]u8 = undefined;
            const kept_output = "message{\"id\":\"k\"}|content.output_text=kept;";

            // No floor: every output, across more than one batch.
            const all = try walk(&storage, full, &buffer);
            try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, all, "content.output_text=dropped;"));
            try std.testing.expect(std.mem.endsWith(u8, all, "second;" ++ kept_output ++ "third;"));

            // A floor deeper than the base's keeps the base and the newer
            // output, with the dropped ones between them.
            try storage.settleModelAttemptFailure(full, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const deeper = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(deeper));
            try store_testing.setHistoryFloorForTesting(&storage, deeper.operation_id, "second", 1);
            const floored = try walk(&storage, deeper, &buffer);
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, floored, "dropped"));
            try std.testing.expect(std.mem.startsWith(u8, floored, "first;compaction{"));
            try std.testing.expect(std.mem.endsWith(u8, floored, kept_output ++ "third;"));

            // A request on that compaction inherits its floor.
            try settleCompactionForTesting(&storage, &tmp, deeper, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const inherited = try walk(&storage, successor, &buffer);
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, inherited, "dropped"));
            try std.testing.expect(std.mem.indexOf(u8, inherited, kept_output ++ "third;compaction{") != null);
        }
    }.run);
}

test "a compaction that makes no room is admitted with its base's floor" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "inherited-floor-config");
            try submitTestMessage(&storage, &tmp, "inherited-floor-one", "inherited-floor-one", session.slice(), "first");
            const overflowed = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(overflowed));
            try storage.settleModelAttemptFailure(overflowed, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            // A base whose floor drops the first input.
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(base));
            try store_testing.setHistoryFloorForTesting(&storage, base.operation_id, "first", 1);
            const floor = try store_testing.queryU64(&storage, "SELECT history_floor FROM model_operation WHERE operation_id=?1", .{base.operation_id});
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
            const answered = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, answered, &.{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"}, "answer");
            // The next Turn's request overflows: the compaction after it
            // follows a request, not a compaction that overflowed, so it
            // walks no deeper and keeps the base's floor.
            try submitTestMessage(&storage, &tmp, "inherited-floor-two", "inherited-floor-two", session.slice(), "second");
            const request = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(request));
            try storage.settleModelAttemptFailure(request, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(next));
            try std.testing.expectEqual(floor, try store_testing.queryU64(&storage, "SELECT history_floor FROM model_operation WHERE operation_id=?1", .{next.operation_id}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND history_level IS NULL", .{next.operation_id}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "an admission closes the request's view it opened when its commit fails or its settings do not settle" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Only a network engine's commit carries the request's reads.
            if (case.engine != .mysql or case.rerun) return;
            const mysql_testing = @import("mysql_testing.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "closed-view-config");
            try submitTestMessage(&storage, &tmp, "closed-view-one", "closed-view-one", session.slice(), "one");
            var view: HistoricalView = undefined;
            var settings: HistoricalSettings = undefined;

            // Every answer of the commit's message is lost, its settings
            // round's with them: the admission stands, its request unread.
            storage.engine.mysql.state.testing_drop = .after_commit;
            const unread = (try storage.admitModelAttemptInto(.message, .{}, .{ .view = &view, .settings = &settings })).?;
            try std.testing.expect(!unread.request_started);
            try std.testing.expect(!view.isActive());
            try settleItemsForTesting(&storage, &tmp, unread.permit.binding, &.{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"}, "answer");

            // The server refuses the Operation the commit inserts.
            try submitTestMessage(&storage, &tmp, "closed-view-two", "closed-view-two", session.slice(), "two");
            try mysql_testing.rawExec(&storage, "CREATE TRIGGER refuse_operation BEFORE INSERT ON model_operation FOR EACH ROW SIGNAL SQLSTATE '45000'");
            defer mysql_testing.rawExec(&storage, "DROP TRIGGER refuse_operation") catch @panic("cannot restore Operation inserts");
            if (storage.admitModelAttemptInto(.message, .{}, .{ .view = &view, .settings = &settings })) |_| return error.TestUnexpectedResult else |_| {}
            try std.testing.expect(!view.isActive());
        }
    }.run);
}

test "a request reads its settings in one round and its history and tools in one more" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "request-config");
            try submitTestMessage(&storage, &tmp, "request-one", "request-one", session.slice(), "question");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"};

            // Each Operation's request, as a codec that declares tools in
            // the history (`declared`) or after it (`all`) reads it.
            for ([_]HistoricalView.ToolsAhead{ .declared, .all }, [_]AttemptBinding{ first, undefined }) |ahead, binding| {
                const attempt = if (ahead == .declared) binding else later: {
                    try settleItemsForTesting(&storage, &tmp, first, &items, "answer");
                    try submitTestMessage(&storage, &tmp, "request-two", "request-two", session.slice(), "follow-up");
                    break :later (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                };
                var view: HistoricalView = undefined;
                storage.openHistoricalView(attempt, &view);
                defer view.close();
                const rounds = ViewRounds.start(&storage);
                var settings: HistoricalSettings = undefined;
                try view.settings(&settings);
                // The settings round checked the outputs and found the base.
                try std.testing.expectEqual(@as(u16, 1), rounds.taken().rounds);
                try std.testing.expect(try view.validateOutputsStep());
                _ = try view.coverage();
                view.expectTools(ahead);
                var rendered: [16 * 1024]u8 = undefined;
                var out = std.Io.Writer.fixed(&rendered);
                try readTestingContent(&view, settings.baseline_instructions, &out);
                try std.testing.expectEqual(settings.baseline_instructions.length, out.buffered().len);
                var cursor: TestingHistoryCursor = .{};
                const expected: []const []const u8 = if (ahead == .declared) &.{"question"} else &.{ "question", "message{\"id\":\"m0\"}|content.output_text=answer", "follow-up" };
                for (expected) |entry| try std.testing.expectEqualStrings(entry, try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered));
                try std.testing.expect((try cursor.next(&view)) == null);
                // The tools the request ends with came with the history.
                var tool: historical_domain.HistoricalTool = .{};
                var declaration = view.currentDeclaration();
                var tools: usize = 0;
                while (if (ahead == .declared) try view.nextDeclaredTool(&declaration, &tool) else try view.nextTool(&tool)) : (tools += 1) {
                    out = std.Io.Writer.fixed(&rendered);
                    try readTestingContent(&view, tool.description, &out);
                    try std.testing.expectEqual(tool.description.length, out.buffered().len);
                    out = std.Io.Writer.fixed(&rendered);
                    try readTestingContent(&view, tool.input_schema, &out);
                    try std.testing.expectEqual(tool.input_schema.length, out.buffered().len);
                }
                // A boundary declares only function tools.
                if (ahead == .all) try std.testing.expectEqual(settings.tool_count, tools);
                try std.testing.expect(tools != 0);
                try std.testing.expectEqual(@as(u16, 2), rounds.taken().rounds);
                try std.testing.expectEqual(@as(u16, 0), rounds.taken().content_rounds);
            }
        }
    }.run);
}

test "the tool-group scan refuses a source with a call past its call items or one missing, wherever a page ends" {
    try store_testing.forEachEngine(struct {
        fn walk(storage: *Store, binding: AttemptBinding) !usize {
            var view: HistoricalView = undefined;
            storage.openHistoricalView(binding, &view);
            defer view.close();
            var settings: HistoricalSettings = undefined;
            try view.settings(&settings);
            while (!try view.validateOutputsStep()) {}
            var groups: usize = 0;
            var after: u64 = 0;
            while (true) {
                var bytes: usize = 1 << 20;
                var items: usize = 1 << 20;
                const entry = switch (try view.nextEntryStep(after, &bytes, &items)) {
                    .pending => continue,
                    .ready => |served| served orelse return groups,
                };
                after = entry.position;
                if (entry.kind != .tool_results) continue;
                while (try view.nextToolResult()) |_| {}
                groups += 1;
            }
        }

        fn run(case: *store_testing.Case) !void {
            var calls: [65]TestingCall = undefined;
            var ids: [65][16]u8 = undefined;
            for (&calls, 0..) |*call, i| {
                const id = try std.fmt.bufPrint(&ids[i], "call-{d}", .{i});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            // The source's calls end one short of a page of calls, on its
            // last row and one past it; a source before and after share
            // its pages.
            for ([_]usize{ 60, 61, 62 }) |size| for ([_]bool{ true, false }) |extra| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "group-bounds");
                try submitTestMessage(&storage, &tmp, "group-bounds-input", "group-bounds-key", session.slice(), "tools");
                var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var tampered: u64 = 0;
                for ([_]usize{ 3, size, 3 }, 0..) |count, i| {
                    if (i == 1) tampered = binding.operation_id;
                    var prefix: [32]u8 = undefined;
                    try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "group-bounds-{d}", .{i}), calls[0..count]);
                    binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                try std.testing.expectEqual(@as(usize, 3), try walk(&storage, binding));
                if (extra) {
                    // A call no call item has, past the last.
                    try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,action_kind) " ++
                        "SELECT operation_id,session_ref,?2,item_ordinal+100000,name_content_id,rejection_content_id,arguments_content_id,field_metadata,1 FROM model_tool_call WHERE operation_id=?1 AND call_ordinal=0", .{ tampered, size });
                } else {
                    // Its last call item's call missing.
                    try store_testing.withoutForeignKeys(&storage, "DELETE FROM model_tool_call WHERE operation_id=?1 AND call_ordinal=?2", .{ tampered, size - 1 });
                }
                try std.testing.expectError(error.CorruptStore, walk(&storage, binding));
            };
        }
    }.run);
}

test "the tool-group scan reads sixteen sources and sixty-four of their calls a round" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "group-pages");
            try submitTestMessage(&storage, &tmp, "group-pages-input", "group-pages-key", session.slice(), "tools");
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [70]TestingCall = undefined;
            var ids: [70][16]u8 = undefined;
            for (&calls, 0..) |*call, i| {
                const id = try std.fmt.bufPrint(&ids[i], "call-{d}", .{i});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            // A full page of sources, then one whose calls outrun a page
            // alone, and one whose calls a page it shares cuts short.
            const sizes = @as([16]usize, @splat(3)) ++ [_]usize{ 70, 3, 70 };
            for (sizes, 0..) |size, i| {
                var prefix: [32]u8 = undefined;
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "group-pages-{d}", .{i}), calls[0..size]);
                binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            var view: HistoricalView = undefined;
            storage.openHistoricalView(binding, &view);
            defer view.close();
            var settings: HistoricalSettings = undefined;
            try view.settings(&settings);
            while (!try view.validateOutputsStep()) {}
            var group: usize = 0;
            var pending: usize = 0;
            var rounds: u16 = 0;
            var after: u64 = 0;
            while (true) {
                var bytes: usize = 1 << 20;
                var items: usize = 1 << 20;
                const before = ViewRounds.start(&storage);
                const step = try view.nextEntryStep(after, &bytes, &items);
                rounds += before.taken().rounds;
                const entry = switch (step) {
                    .pending => {
                        pending += 1;
                        continue;
                    },
                    .ready => |served| served orelse break,
                };
                try std.testing.expect(entry.position > after);
                after = entry.position;
                if (entry.kind != .tool_results) continue;
                var results: usize = 0;
                const reading = ViewRounds.start(&storage);
                while (try view.nextToolResult()) |result| {
                    // A small result's bytes came with its row.
                    var text: [256]u8 = undefined;
                    var out = std.Io.Writer.fixed(&text);
                    try readTestingContent(&view, result.call_id, &out);
                    try std.testing.expectEqualStrings(calls[results].decoded_call_id, out.buffered());
                    results += 1;
                }
                try std.testing.expectEqual(sizes[group], results);
                // Sixteen results a round, and one more when the last is full.
                try std.testing.expectEqual(@as(u16, @intCast(results / 16 + 1)), reading.taken().rounds);
                try std.testing.expectEqual(@as(u16, 0), reading.taken().content_rounds);
                group += 1;
            }
            try std.testing.expectEqual(sizes.len, group);
            // The first seventy calls fill a page with no group whole, so
            // one step ends with none.
            try std.testing.expectEqual(@as(usize, 1), pending);
            // The entry batches' rounds and the scan's four, the first of
            // which an entry batch shares; no round per item or call.
            try std.testing.expectEqual(@as(u16, 17), rounds);
        }
    }.run);
}

test "a tool walk longer than a page reads the rest from its next member, in order" {
    try store_testing.forEachEngine(struct {
        const count = 40;
        const records = testingHostToolRecords(&extras: {
            @setEvalBranchQuota(400_000);
            var tools: [count]tool_defs.Record = undefined;
            for (&tools, 0..) |*tool, index| tool.* = .{
                .name = std.fmt.comptimePrint("tool_{d:0>2}", .{index}),
                .owner = .mcp,
                .server = "many",
                .description = std.fmt.comptimePrint("Tool {d}.", .{index}),
                .input_schema = "{\"type\":\"object\"}",
            };
            break :extras tools;
        });
        const digests = blk: {
            @setEvalBranchQuota(4_000_000);
            var out: [records.len][32]u8 = undefined;
            for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            break :blk out;
        };

        fn run(case: *store_testing.Case) !void {
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var command = try completeConfiguration("many-tools", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            var names: [count][]const u8 = undefined;
            var named: usize = 0;
            for (&records) |*record| if (record.owner == .mcp) {
                names[named] = record.name;
                named += 1;
            };
            try std.testing.expectEqual(@as(usize, count), named);
            command.configuration.tools = try .of(&names);
            const configured = try storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            try submitTestMessage(&storage, &tmp, "many-tools-input", "many-tools-key", configured.accepted.session.slice(), "work");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            for ([_]HistoricalView.ToolsAhead{ .declared, .all }) |ahead| {
                var view: HistoricalView = undefined;
                storage.openHistoricalView(binding, &view);
                defer view.close();
                var settings: HistoricalSettings = undefined;
                try view.settings(&settings);
                try std.testing.expectEqual(@as(u64, count), settings.tool_count);
                view.expectTools(ahead);
                _ = try view.coverage();
                // The first page of tools rides the history round.
                _ = (try view.nextEntry(0)).?;
                const rounds = ViewRounds.start(&storage);
                var tool: historical_domain.HistoricalTool = .{};
                var declaration = view.currentDeclaration();
                var text: [64]u8 = undefined;
                for (0..count) |index| {
                    try std.testing.expect(if (ahead == .declared) try view.nextDeclaredTool(&declaration, &tool) else try view.nextTool(&tool));
                    try std.testing.expectEqualStrings(names[index], tool.name.slice());
                    var out = std.Io.Writer.fixed(&text);
                    try readTestingContent(&view, tool.description, &out);
                    var expected: [64]u8 = undefined;
                    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Tool {d}.", .{index}), out.buffered());
                }
                try std.testing.expect(!(if (ahead == .declared) try view.nextDeclaredTool(&declaration, &tool) else try view.nextTool(&tool)));
                // Two more pages of 16 hold the other 24, texts and all.
                try std.testing.expectEqual(@as(u16, 2), rounds.taken().rounds);
                try std.testing.expectEqual(@as(u16, 0), rounds.taken().content_rounds);
                if (ahead == .declared) {
                    // A walk begun again reads its first page again.
                    var again = view.currentDeclaration();
                    try std.testing.expect(try view.nextDeclaredTool(&again, &tool));
                    try std.testing.expectEqualStrings(names[0], tool.name.slice());
                    try std.testing.expectEqual(@as(u16, 3), rounds.taken().rounds);
                }
            }
        }
    }.run);
}

test "a history batch's items, parts and small contents cost no round after its first entry" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "page-config");
            try submitTestMessage(&storage, &tmp, "page-one", "page-one", session.slice(), "question");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const items = [_][]const u8{
                "{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"one \"},{\"type\":\"output_text\",\"text\":\"two \"},{\"type\":\"output_text\",\"text\":\"three\"}]}",
                "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}",
            };
            try settleItemsForTesting(&storage, &tmp, first, &items, "answer");
            try submitTestMessage(&storage, &tmp, "page-two", "page-two", session.slice(), "follow-up");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            var rendered: [256]u8 = undefined;
            // The first entry's step reads the batch and its page.
            try std.testing.expectEqualStrings("question", try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered));
            const rounds = ViewRounds.start(&storage);
            for ([_][]const u8{ "message{\"id\":\"m0\"}|content.output_text=one |content.output_text=two |content.output_text=three", "message{\"id\":\"m1\"}|content.output_text=answer", "follow-up" }) |expected|
                try std.testing.expectEqualStrings(expected, try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered));
            // A short batch is the Session's last: its end costs no round either.
            try std.testing.expect((try cursor.next(&view)) == null);
            try std.testing.expectEqual(@as(u16, 0), rounds.taken().rounds);
            try std.testing.expectEqual(@as(u16, 0), rounds.taken().content_rounds);
        }
    }.run);
}

test "an output item with more parts than a page holds reads the rest from its next part" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "parts-config");
            try submitTestMessage(&storage, &tmp, "parts-one", "parts-one", session.slice(), "question");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // 70 parts: three reads of 32.
            var item_buffer: [4096]u8 = undefined;
            var answer_buffer: [512]u8 = undefined;
            const many = try manyPartMessage(&item_buffer, &answer_buffer, 70);
            try settleItemsForTesting(&storage, &tmp, first, &.{many.item}, many.answer);
            try submitTestMessage(&storage, &tmp, "parts-two", "parts-two", session.slice(), "follow-up");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            var rendered: [4096]u8 = undefined;
            _ = (try cursor.next(&view)).?;
            const rounds = ViewRounds.start(&storage);
            const output = try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered);
            var expected_buffer: [4096]u8 = undefined;
            var expected = std.Io.Writer.fixed(&expected_buffer);
            try expected.writeAll("message{\"id\":\"many\"}");
            for (0..70) |index| try expected.print("|content.output_text=p{d};", .{index});
            try std.testing.expectEqualStrings(expected.buffered(), output);
            try std.testing.expectEqual(@as(u16, 2), rounds.taken().rounds);
            try std.testing.expectEqual(@as(u16, 0), rounds.taken().content_rounds);
            try std.testing.expectEqualStrings("follow-up", try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered));
        }
    }.run);
}

test "a content the page's rows cannot carry reads through its reader, and both read the same bytes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "inline-config");
            // The largest content a row carries, the smallest it does not,
            // then ten that together outgrow the page's bytes.
            const sizes = [_]usize{ 16 * 1024, 16 * 1024 + 1 } ++ @as([10]usize, @splat(16 * 1024 - 7));
            const text = try std.testing.allocator.alloc(u8, 16 * 1024 + 1);
            defer std.testing.allocator.free(text);
            for (sizes, 0..) |size, index| {
                for (text[0..size], 0..) |*byte, offset| byte.* = 'a' + @as(u8, @intCast((offset * 7 + index) % 26));
                var name: [24]u8 = undefined;
                const key = try std.fmt.bufPrint(&name, "inline-{d}", .{index});
                try submitTestMessage(&storage, &tmp, key, key, session.slice(), text[0..size]);
            }
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            const rendered = try std.testing.allocator.alloc(u8, 16 * 1024 + 1);
            defer std.testing.allocator.free(rendered);
            var cursor: TestingHistoryCursor = .{};
            var content_rounds: [sizes.len]u16 = undefined;
            for (sizes, 0..) |size, index| {
                const entry = (try cursor.next(&view)).?;
                const rounds = ViewRounds.start(&storage);
                const bytes = try renderTestingEntry(&view, entry, rendered);
                content_rounds[index] = rounds.taken().content_rounds;
                for (text[0..size], 0..) |*byte, offset| byte.* = 'a' + @as(u8, @intCast((offset * 7 + index) % 26));
                try std.testing.expectEqualStrings(text[0..size], bytes);
            }
            try std.testing.expectEqual(@as(u16, 0), content_rounds[0]);
            try std.testing.expect(content_rounds[1] != 0);
            // 128 KiB of page: the first of the ten shares it with the
            // 16 KiB one, so seven fit and the last three do not.
            for (content_rounds[2..9]) |taken| try std.testing.expectEqual(@as(u16, 0), taken);
            for (content_rounds[9..]) |taken| try std.testing.expect(taken != 0);
        }
    }.run);
}

test "a reader that borrows the page's bytes keeps them when the next batch is read" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "borrow-config");
            // Sixteen short Messages fill the first batch; the four after
            // are long enough to cover where the sixteenth's bytes lie.
            var texts: [20][400]u8 = undefined;
            var lengths: [20]usize = undefined;
            for (&texts, &lengths, 0..) |*text, *length, index| {
                length.* = if (index < 16) 40 else 400;
                for (text[0..length.*], 0..) |*byte, offset| byte.* = 'a' + @as(u8, @intCast((offset + index) % 26));
                var name: [24]u8 = undefined;
                const key = try std.fmt.bufPrint(&name, "borrow-{d}", .{index});
                try submitTestMessage(&storage, &tmp, key, key, session.slice(), text[0..length.*]);
            }
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            var sixteenth: HistoricalEntry = undefined;
            for (0..16) |_| sixteenth = (try cursor.next(&view)).?;
            var reader: HistoricalReader = undefined;
            try view.openContent(sixteenth.content.?, &reader);
            var rendered: [400]u8 = undefined;
            // The next batch is read while the reader is open.
            try std.testing.expectEqualStrings(texts[16][0..400], try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered));
            var borrowed: [40]u8 = undefined;
            const rounds = ViewRounds.start(&storage);
            try std.testing.expectEqual(@as(usize, 40), try reader.read(0, &borrowed));
            try std.testing.expectEqual(@as(u16, 0), rounds.taken().content_rounds);
            reader.close();
            try std.testing.expectEqualStrings(texts[15][0..40], &borrowed);
            for (17..20) |index|
                try std.testing.expectEqualStrings(texts[index][0..400], try renderTestingEntry(&view, (try cursor.next(&view)).?, &rendered));
        }
    }.run);
}

test "a prefix seal is recorded only while its Attempt is current" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const attempt = try TestingAttempt.admit(&storage, &tmp);
            var view: HistoricalView = undefined;
            storage.openHistoricalView(attempt.binding, &view);
            defer view.close();
            var seal = TestingAttempt.seal;
            seal.admission_position = try store_testing.queryU64(&storage, "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{attempt.binding.operation_id});
            try view.recordPrefixSeal(&seal);
            try std.testing.expectEqualDeep(seal, (try storage.prefixSealForTesting(attempt.binding)).?);
            try storage.settleModelAttemptFailure(attempt.binding, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
            var later = seal;
            later.span_length = 1;
            try std.testing.expectError(error.StaleAttemptBinding, view.recordPrefixSeal(&later));
            try std.testing.expectEqualDeep(seal, (try storage.prefixSealForTesting(attempt.binding)).?);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "an Attempt check reads no Session, and a prefix seal's Session read answers OperationReadFailed" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const attempt = try TestingAttempt.admit(&storage, &tmp);
            var view: HistoricalView = undefined;
            storage.openHistoricalView(attempt.binding, &view);
            defer view.close();
            // Main touched the Session in each check, so a faulted session row
            // answered SessionReadFailed there; only the seal's write reads it now.
            try store_testing.failReadsOf(&storage, "session");
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(attempt.binding));
            try storage.withDispatchHandoff(attempt.binding, {}, TestingAttempt.handoff);
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.OperationReadFailed, view.recordPrefixSeal(&TestingAttempt.seal));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "a content lookup's failed step answers CorruptStore, as on main" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const attempt = try TestingAttempt.admit(&storage, &tmp);
            try store_testing.failReadsOf(&storage, "content");
            try std.testing.expectError(error.CorruptStore, storage.openContent(attempt.content));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "complete historical tool-result traversal scales with groups and calls, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const baseline = try measure(case, 4, 1);
            const more_groups = try measure(case, 16, 1);
            const call_baseline = try measure(case, 4, 8);
            const more_calls = try measure(case, 4, 32);
            std.testing.expect(more_groups > baseline and more_calls >= call_baseline) catch |err| {
                std.debug.print("rounds: {d} {d} {d} {d}\n", .{ baseline, more_groups, call_baseline, more_calls });
                return err;
            };
        }

        fn measure(engine: *store_testing.Case, group_count: usize, calls_per_group: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "scale-config");
            try submitTestMessage(&storage, &tmp, "scale-input", "scale-input", session.slice(), "call");
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [32]TestingCall = undefined;
            var item_ids: [32][32]u8 = undefined;
            var call_ids: [32][32]u8 = undefined;
            for (calls[0..calls_per_group], 0..) |*call, index| {
                const item_id = try std.fmt.bufPrint(&item_ids[index], "scale-item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&call_ids[index], "scale-call-{d}", .{index});
                call.* = .{ .item_id = item_id, .name = "unknown", .encoded_call_id = call_id, .decoded_call_id = call_id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            for (0..group_count) |index| {
                var prefix_buffer: [64]u8 = undefined;
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix_buffer, "scale-metadata-{d}", .{index}), calls[0..calls_per_group]);
                binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            const counter = TwinRounds.start(&storage);
            var view: HistoricalView = undefined;
            storage.openHistoricalView(binding, &view);
            defer view.close();
            var position: u64 = 0;
            var groups_seen: usize = 0;
            var results_seen: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.kind != .tool_results) continue;
                groups_seen += 1;
                while (try view.nextToolResult()) |_| results_seen += 1;
            }
            try std.testing.expectEqual(group_count, groups_seen);
            try std.testing.expectEqual(group_count * calls_per_group, results_seen);
            return counter.taken();
        }
    }.run);
}

/// A bound fixture statement that adds `?1` failed Operations after
/// Operation `?2`, in its Turn.
const failed_operations_sql = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position," ++
    "attempt_ordinal,output_reservation,resolution_code,resolved_at,tool_set_id,context_window) " ++
    "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) " ++
    "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value," ++
    "1,0,'failed',1,current.tool_set_id,current.context_window FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2";

test "historical accepted output selection work excludes failed Operation population, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 8), try measure(case, 1024));
        }

        fn measure(engine: *store_testing.Case, population: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "selection-config");
            try submitTestMessage(&storage, &tmp, "selection-input", "selection-input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            try store_testing.exec(&storage, failed_operations_sql, .{ population, current.operation_id });
            var view: HistoricalView = undefined;
            storage.openHistoricalView(current, &view);
            defer view.close();
            const counter = TwinRounds.start(&storage);
            while (!try view.validateOutputsStep()) {}
            return counter.taken();
        }
    }.run);
}

test "historical context selection work excludes nonmatching Operation population, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |with_base| {
                try std.testing.expectEqual(try measure(case, 8, with_base), try measure(case, 1024, with_base));
            }
        }

        fn measure(engine: *store_testing.Case, population: usize, with_base: bool) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (with_base) {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, current, &.{ .reasoning, .compaction, .message });
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            try store_testing.exec(&storage, failed_purpose_operations_sql, .{ population, current.operation_id });
            var view: HistoricalView = undefined;
            storage.openHistoricalView(current, &view);
            defer view.close();
            const counter = TwinRounds.start(&storage);
            while (!try view.validateOutputsStep()) {}
            const taken = counter.taken();
            try std.testing.expectEqual(with_base, (try view.coverage()).anchor != null);
            return taken;
        }
    }.run);
}
