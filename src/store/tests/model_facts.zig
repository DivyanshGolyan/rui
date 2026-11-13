//! Model facts Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_testing = @import("../testing.zig");
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const runtime_catalog = @import("../../model_catalog.zig");
const RoundMeter = shared_fixtures.RoundMeter;
const TwinRounds = shared_fixtures.TwinRounds;

test "model fact refresh reads existence once before batched writes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // A rerun repeats the rounds this counts.
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const count = 4100;
            const allocator = std.testing.allocator;
            const ids = try allocator.alloc([32]u8, count);
            defer allocator.free(ids);
            const entries = try allocator.alloc(@import("../../model_catalog.zig").Entry, count);
            defer allocator.free(entries);
            // First inserts, then a mix of old/new IDs, then only updates.
            // Input order is deliberately not sorted: existence is by ID.
            for (0..3) |refresh| {
                const offset: usize = if (refresh == 0) 0 else count / 2;
                for (entries, ids, 0..) |*entry, *id, index| entry.* = .{
                    .id = try std.fmt.bufPrint(id, "catalog-{d}", .{count - index + offset}),
                    .context_window = @intCast(100 + refresh),
                    .efforts = .{},
                    .openai_listed = true,
                };
                const rounds = TwinRounds.start(&storage);
                const before = RoundMeter.QueryShape.snapshot(&storage);
                try storage.saveModelFacts(entries, "\"batch\"");
                const shape = RoundMeter.QueryShape.snapshot(&storage).since(before);
                std.debug.print("model facts: {d} entries, {d} Access rounds\n", .{ count, rounds.taken() });
                try std.testing.expectEqual(@as(u16, 2), rounds.taken());
                if (case.engine == .mysql) {
                    // Both reads share one pass. Access queues twelve
                    // statements per pass: the writes, source last, then
                    // COMMIT in the last pass, so no control is sent.
                    const write_passes = (count + 2 + 11) / 12;
                    try std.testing.expectEqual(@as(u64, 1 + write_passes), shape.access_passes);
                    try std.testing.expectEqual(@as(u64, 0), shape.controls);
                    try std.testing.expectEqual(@as(u64, 1 + write_passes), shape.queries);
                    try std.testing.expectEqual(shape.expected(), shape.queries);
                }
                try std.testing.expectEqual(@as(u64, refresh + 1), (try storage.readModelCatalogSource()).?.generation);
                try std.testing.expectEqual(@as(?u32, @intCast(100 + refresh)), (try storage.modelFact(entries[0].id)).?.context_window);
                try std.testing.expectEqual(@as(u64, count), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_fact fact JOIN model_catalog_source source ON source.generation=fact.generation WHERE source.slot=1", .{}));
            }
        }
    }.run);
}

const runtime_catalog_facts: []const runtime_catalog.Entry = &.{
    .{ .id = "gpt-6.1-sol", .context_window = 100, .efforts = .init(.{ .none = true }), .openai_listed = true },
    .{ .id = "runtime-null", .context_window = null, .efforts = .{}, .openai_listed = true },
    .{ .id = "runtime-only", .context_window = 200, .efforts = .init(.{ .high = true }), .openai_listed = true },
    .{ .id = "runtime-private", .context_window = 300, .efforts = .{}, .openai_listed = false },
};

fn runtimeCatalogListing(storage: *Store, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rounds = TwinRounds.start(storage);
    const facts = try storage.readModelCatalog(arena.allocator());
    try std.testing.expect(rounds.taken() <= 1);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try @import("../../model_list.zig").writeProviders(&out.writer, facts, &.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\nruntime-only\nruntime-null\nruntime-private\n" } } },
    });
    try std.testing.expectEqualStrings(expected, out.written());
}

const runtime_catalog_listing = "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[" ++
    "{\"id\":\"gpt-6.1-sol\",\"known\":true},{\"id\":\"runtime-null\",\"known\":true},{\"id\":\"runtime-only\",\"known\":true}]}," ++
    "{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6.1-sol\",\"known\":true},{\"id\":\"gpt-6.1-terra\",\"known\":false}," ++
    "{\"id\":\"runtime-only\",\"known\":true},{\"id\":\"runtime-null\",\"known\":true},{\"id\":\"runtime-private\",\"known\":true}]}]";

const runtime_catalog_empty_listing = "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[]}," ++
    "{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6.1-sol\",\"known\":false},{\"id\":\"gpt-6.1-terra\",\"known\":false}," ++
    "{\"id\":\"runtime-only\",\"known\":false},{\"id\":\"runtime-null\",\"known\":false},{\"id\":\"runtime-private\",\"known\":false}]}]";

test "runtime catalog model list selects one owned generation and survives reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var open = true;
            defer if (open) storage.close() catch unreachable;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const rounds = TwinRounds.start(&storage);
            const fallback = try storage.readModelCatalog(arena.allocator());
            try std.testing.expect(rounds.taken() <= 1);
            try std.testing.expect(fallback.ptr == runtime_catalog.shipped.ptr);
            var expected: std.Io.Writer.Allocating = .init(arena.allocator());
            try @import("../../model_list.zig").writeProviders(&expected.writer, runtime_catalog.shipped, &.{
                .{ .provider = .codex, .list = .catalog },
                .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\ngpt-6.1-terra\nruntime-only\nruntime-null\nruntime-private\n" } } },
            });
            try runtimeCatalogListing(&storage, expected.written());
            try storage.saveModelFacts(runtime_catalog_facts, "\"runtime\"");
            const selected = try storage.readModelCatalog(arena.allocator());
            try std.testing.expectEqual(@as(usize, 4), selected.len);
            try std.testing.expectEqual(@as(?u32, 100), runtime_catalog.find(selected, "gpt-6.1-sol").?.context_window);
            try std.testing.expect(runtime_catalog.find(selected, "gpt-6.1-sol").?.efforts.contains(.none));
            try std.testing.expect(!runtime_catalog.find(selected, "gpt-6.1-sol").?.efforts.contains(.low));
            try std.testing.expectEqual(@as(?u32, null), runtime_catalog.find(selected, "runtime-null").?.context_window);
            try runtimeCatalogListing(&storage, runtime_catalog_listing);
            try storage.close();
            open = false;
            // Saved IDs and entries belong to the operation arena, not engine
            // row buffers or the connection. They remain usable after close.
            for (selected, runtime_catalog_facts) |actual, wanted| {
                try std.testing.expectEqualStrings(wanted.id, actual.id);
                try std.testing.expectEqual(wanted.context_window, actual.context_window);
                try std.testing.expectEqual(wanted.efforts, actual.efforts);
                try std.testing.expectEqual(wanted.openai_listed, actual.openai_listed);
            }
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            open = true;
            try runtimeCatalogListing(&storage, runtime_catalog_listing);
            try storage.saveModelFacts(&.{}, "\"empty\"");
            try runtimeCatalogListing(&storage, runtime_catalog_empty_listing);
            // A later publication cannot mutate an earlier operation's facts.
            try std.testing.expectEqualStrings("gpt-6.1-sol", selected[0].id);
            try std.testing.expectEqual(@as(?u32, 100), selected[0].context_window);
            try storage.close();
            open = false;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            open = true;
            try runtimeCatalogListing(&storage, runtime_catalog_empty_listing);
        }
    }.run);
}

fn runtimeCatalogCreation(storage: *Store, key: []const u8, model: []const u8, effort: ?[]const u8, trigger: []const u8, rejection: ?protocol.ConfigurationRejection) !void {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try completeConfiguration(key, "", try canonicalCwd(std.testing.io, &workspace_buffer), model);
    try command.configuration.compaction_trigger.value.set(trigger);
    command.configuration.reasoning_effort.state = if (effort != null) .value else .explicit_null;
    if (effort) |value| try command.configuration.reasoning_effort.value.set(value);
    const reply = try storage.configure(&command, .{});
    if (rejection) |expected| {
        try std.testing.expect(reply == .rejected);
        try std.testing.expectEqual(expected, reply.rejected.code);
    } else {
        try std.testing.expect(reply == .accepted);
        const current = (try store_core.readSessionForTesting(storage, reply.accepted.session.slice())).?;
        try std.testing.expectEqualStrings(model, current.model.slice());
        try std.testing.expectEqual(try std.fmt.parseInt(u64, trigger, 10), current.compaction_trigger.?);
    }
}

test "runtime catalog configuration admission accepts and refuses selected saved facts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try runtimeCatalogCreation(&storage, "runtime-fallback-yes", "gpt-6.1-sol", "low", "1000", null);
            try runtimeCatalogCreation(&storage, "runtime-fallback-no", "gpt-6.1-sol", "none", "1000", .unsupported_reasoning_effort);
            try storage.saveModelFacts(runtime_catalog_facts, null);
            try runtimeCatalogCreation(&storage, "runtime-changed-yes", "gpt-6.1-sol", "none", "100", null);
            try runtimeCatalogCreation(&storage, "runtime-changed-window", "gpt-6.1-sol", "none", "101", .compact_at_too_large);
            try runtimeCatalogCreation(&storage, "runtime-changed-effort", "gpt-6.1-sol", "low", "100", .unsupported_reasoning_effort);
            try runtimeCatalogCreation(&storage, "runtime-only-yes", "runtime-only", "high", "200", null);
            try runtimeCatalogCreation(&storage, "runtime-only-window", "runtime-only", "high", "201", .compact_at_too_large);
            try runtimeCatalogCreation(&storage, "runtime-only-effort", "runtime-only", "low", "200", .unsupported_reasoning_effort);
            try runtimeCatalogCreation(&storage, "runtime-null-window", "runtime-null", null, "2000000", null);
            try runtimeCatalogCreation(&storage, "runtime-null-effort", "runtime-null", "low", "2000000", .unsupported_reasoning_effort);
            // A removed shipped ID is unknown, not an invitation to resurrect
            // its window or effort restrictions from the offline snapshot.
            try runtimeCatalogCreation(&storage, "runtime-removed", "gpt-6.1-terra", "none", "2000000", null);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("runtime-retained-create", "", try canonicalCwd(std.testing.io, &workspace_buffer), "gpt-6.1-sol");
            try create.configuration.compaction_trigger.value.set("100");
            try create.configuration.reasoning_effort.value.set("none");
            const session = (try storage.configure(&create, .{})).accepted.session;
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try runtimeCatalogCreation(&storage, "runtime-reopen-yes", "gpt-6.1-sol", "none", "100", null);
            try runtimeCatalogCreation(&storage, "runtime-reopen-no", "gpt-6.1-sol", "low", "100", .unsupported_reasoning_effort);
            // An update with an omitted model must validate its retained
            // settings against this operation's newly selected generation.
            try storage.saveModelFacts(&.{.{ .id = "gpt-6.1-sol", .context_window = 50, .efforts = .init(.{ .low = true }), .openai_listed = true }}, null);
            var update: wire_request.ConfigureCommand = .{ .session = session };
            try update.key.set("runtime-retained-window");
            var reply = try storage.configure(&update, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, reply.rejected.code);
            try update.key.set("runtime-retained-effort");
            update.configuration.compaction_trigger.state = .value;
            try update.configuration.compaction_trigger.value.set("50");
            reply = try storage.configure(&update, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, reply.rejected.code);
            try update.key.set("runtime-retained-accept");
            update.configuration.reasoning_effort.state = .value;
            try update.configuration.reasoning_effort.value.set("low");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            const current = (try store_core.readSessionForTesting(&storage, session.slice())).?;
            try std.testing.expectEqual(@as(?u64, 50), current.compaction_trigger);
            try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), current.reasoning_effort);
            try storage.saveModelFacts(&.{.{ .id = "gpt-6.1-sol", .context_window = null, .efforts = .init(.{ .none = true }), .openai_listed = true }}, null);
            try runtimeCatalogCreation(&storage, "runtime-shipped-null-window", "gpt-6.1-sol", "none", "2000000", null);
            try storage.saveModelFacts(&.{}, null);
            try runtimeCatalogCreation(&storage, "runtime-empty", "gpt-6.1-sol", null, "2000000", null);
            try runtimeCatalogCreation(&storage, "runtime-empty-effort", "runtime-only", "low", "2000000", null);
        }
    }.run);
}

test "runtime catalog failed publication retains the selected generation for consumers" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            {
                defer storage.close() catch unreachable;
                try storage.saveModelFacts(&.{.{ .id = "kept", .context_window = 100, .efforts = .{}, .openai_listed = true }}, "\"old\"");
                // The first row is overwritten before the second row's
                // constraint fails. Neither overwrite nor source may stick.
                try std.testing.expectError(error.StatementFailed, storage.saveModelFacts(&.{
                    .{ .id = "kept", .context_window = 200, .efforts = .init(.{ .low = true }), .openai_listed = false },
                    .{ .id = "", .context_window = null, .efforts = .{}, .openai_listed = false },
                }, "\"new\""));
                try std.testing.expect(storage.isFenced());
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                try std.testing.expectError(error.StoreFenced, storage.readModelCatalog(arena.allocator()));
            }
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const source = (try storage.readModelCatalogSource()).?;
            try std.testing.expectEqual(@as(u64, 1), source.generation);
            try std.testing.expectEqualStrings("\"old\"", source.etag.?.slice());
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const rounds = TwinRounds.start(&storage);
            const facts = try storage.readModelCatalog(arena.allocator());
            try std.testing.expect(rounds.taken() <= 1);
            var out: std.Io.Writer.Allocating = .init(arena.allocator());
            try @import("../../model_list.zig").writeProviders(&out.writer, facts, &.{.{ .provider = .codex, .list = .catalog }});
            try std.testing.expectEqualStrings("[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[{\"id\":\"kept\",\"known\":true}]}]", out.written());
            try runtimeCatalogCreation(&storage, "runtime-rollback-accept", "kept", null, "100", null);
            try runtimeCatalogCreation(&storage, "runtime-rollback-refuse", "kept", null, "101", .compact_at_too_large);
            try runtimeCatalogCreation(&storage, "runtime-rollback-effort", "kept", "low", "100", .unsupported_reasoning_effort);
        }
    }.run);
}

test "saved model facts replace generations and hide removed ids" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocator = std.testing.allocator;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const first = try @import("../../models_dev.zig").parse(arena.allocator(),
                \\{"openai":{"models":{"a":{"limit":{"context":100},"reasoning_options":[{"type":"effort","values":["low","high"]}]},"b":{}}},"other":{"models":{"c":{}}}}
            );
            try std.testing.expect(try storage.readModelCatalogSource() == null);
            try storage.saveModelFacts(first, "\"one\"");
            const source = (try storage.readModelCatalogSource()).?;
            try std.testing.expectEqual(@as(u64, 1), source.generation);
            try std.testing.expectEqualStrings("\"one\"", source.etag.?.slice());
            try std.testing.expect(source.fetched_at > 0);
            const a = (try storage.modelFact("a")).?;
            try std.testing.expectEqual(@as(?u32, 100), a.context_window);
            try std.testing.expectEqual(@as(u8, @intCast(first[0].efforts.bits.mask)), a.efforts);
            try std.testing.expect(a.openai_listed);
            const ids = try storage.readOpenAiModelIds(allocator);
            defer {
                for (ids) |id| allocator.free(id);
                allocator.free(ids);
            }
            try std.testing.expectEqual(@as(usize, 2), ids.len);
            try std.testing.expectEqualStrings("a", ids[0]);
            try std.testing.expectEqualStrings("b", ids[1]);
            const second = try @import("../../models_dev.zig").parse(arena.allocator(),
                \\{"openai":{"models":{"b":{"limit":{"context":200}}}}}
            );
            try storage.saveModelFacts(second, null);
            try std.testing.expectEqual(@as(u64, 2), (try storage.readModelCatalogSource()).?.generation);
            try std.testing.expect(try storage.modelFact("a") == null);
            try std.testing.expect(try storage.modelFact("c") == null);
            try std.testing.expectEqual(@as(?u32, 200), (try storage.modelFact("b")).?.context_window);
            try std.testing.expect((try storage.readModelCatalogSource()).?.etag == null);
            const current_ids = try storage.readOpenAiModelIds(allocator);
            defer {
                for (current_ids) |id| allocator.free(id);
                allocator.free(current_ids);
            }
            try std.testing.expectEqual(@as(usize, 1), current_ids.len);
            try std.testing.expectEqualStrings("b", current_ids[0]);
            // Hidden IDs still occupy their keys. A later refresh must update
            // those older-generation rows, not mistake them for new IDs.
            try storage.saveModelFacts(first, "\"three\"");
            try std.testing.expectEqual(@as(u64, 3), (try storage.readModelCatalogSource()).?.generation);
            try std.testing.expectEqual(@as(?u32, 100), (try storage.modelFact("a")).?.context_window);
            try std.testing.expect((try storage.modelFact("c")) != null);
            try storage.saveModelFacts(&.{}, null);
            try std.testing.expectEqual(@as(u64, 4), (try storage.readModelCatalogSource()).?.generation);
            for ([_][]const u8{ "a", "b", "c" }) |id| try std.testing.expect(try storage.modelFact(id) == null);
        }
    }.run);
}

test "model fact effort masks are format-defined on every engine" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // These fixed bits, not a loop index or inferred enum value, are
            // part of the Store format. Reordering tags must fail this test.
            const cases = .{ .{ .none, 1 }, .{ .low, 2 }, .{ .medium, 4 }, .{ .high, 8 }, .{ .xhigh, 16 }, .{ .max, 32 } };
            inline for (cases) |effort| {
                try storage.saveModelFacts(&.{.{ .id = "effort", .context_window = null, .efforts = .initOne(effort[0]), .openai_listed = false }}, null);
                try std.testing.expectEqual(@as(u8, effort[1]), (try storage.modelFact("effort")).?.efforts);
            }
            const insert = "INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation) VALUES(?1,NULL,?2,0,1)";
            const constraint_error = if (case.engine == .mysql) error.MysqlFixtureFailed else error.StatementFailed;
            try std.testing.expectError(constraint_error, store_testing.exec(&storage, insert, .{ "below", @as(i64, -1) }));
            try std.testing.expectError(constraint_error, store_testing.exec(&storage, insert, .{ "above", @as(i64, 64) }));
            try store_testing.exec(&storage, insert, .{ "empty", @as(i64, 0) });
            try store_testing.exec(&storage, insert, .{ "full", @as(i64, 63) });
        }
    }.run);
}
