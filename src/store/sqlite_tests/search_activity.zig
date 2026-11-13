//! Search activity SQLite mechanism tests.
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const store_testing = @import("../testing.zig");
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const testingPublicProjection = store_testing.testingPublicProjection;
const testingStore = store_testing.testingSqliteStore;

test "searchActivity streams window edges filters kinds and pages newest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try configureTestSession(&storage, "search-config");
    try submitTestMessage(&storage, &tmp, "search-old", "search-old", session.slice(), "needle old");
    const text = try arena.alloc(u8, 64 * 1024 + 300);
    @memset(text, 'x');
    @memcpy(text[65534..][0..6], "NeEdLe");
    try submitTestMessage(&storage, &tmp, "search-edge", "search-edge", session.slice(), text);
    try submitTestMessage(&storage, &tmp, "search-new", "search-new", session.slice(), "needle new");
    // More than one candidate batch of nonmatching entries must not end
    // the search before its first match.
    for (0..18) |i| {
        const key = try std.fmt.allocPrint(arena, "search-miss-{d}", .{i});
        try submitTestMessage(&storage, &tmp, key, key, session.slice(), "unrelated");
    }
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission), .limit = 1 };
    try request.query.set("NEEDLE");
    var previous: u64 = std.math.maxInt(u64);
    for (0..3) |i| {
        try storage.searchActivity(&request, result);
        try std.testing.expectEqual(@as(usize, 1), result.count);
        const item = &result.items[0];
        try std.testing.expect(item.position < previous);
        previous = item.position;
        try std.testing.expectEqual(protocol.ActivityItem.Kind.admission, item.kind);
        try std.testing.expectEqual(@as(usize, 1), item.count);
        const hit = &item.hits[0];
        try std.testing.expect(hit.snippet.len <= 160);
        try std.testing.expect(std.unicode.utf8ValidateSlice(hit.snippet.slice()));
        try std.testing.expectEqualStrings(if (i == 1) "NeEdLe" else "needle", hit.snippet.slice()[hit.offset..][0..hit.length]);
        if (i != 2) {
            const next = result.next.?;
            try std.testing.expectEqual(item.position, next.position);
            request.before_position = next.position;
            request.before_ordinal = next.ordinal;
        } else try std.testing.expect(result.next == null);
    }
    request.before_position = null;
    request.before_ordinal = null;
    request.kinds = .initOne(.assistant);
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expect(result.next == null);
    try std.testing.expect(!storage.isFenced());
}

test "searchActivity budget returns an empty page with a usable next cursor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try configureTestSession(&storage, "search-budget");
    try submitTestMessage(&storage, &tmp, "budget-old", "budget-old", session.slice(), "needle");
    const text = try arena.alloc(u8, reads_domain.activity_search_budget + 32);
    @memset(text, 'x');
    @memcpy(text[text.len - 6 ..], "needle");
    try submitTestMessage(&storage, &tmp, "budget-large", "budget-large", session.slice(), text);
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission), .limit = 1 };
    try request.query.set("needle");
    const before = storage.testing_content_work.read.load(.monotonic);
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(u64, reads_domain.activity_search_budget), storage.testing_content_work.read.load(.monotonic) - before);
    request.before_position = result.next.?.position;
    request.before_ordinal = result.next.?.ordinal;
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(result.items[0].position < request.before_position.?);
    try std.testing.expect(result.next == null);
    try std.testing.expect(!storage.isFenced());
}

test "searchActivity never searches private provider extras" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try configureTestSession(&storage, "search-private");
    try submitTestMessage(&storage, &tmp, "search-task", "search-task", session.slice(), "public task");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleItemsForTesting(&storage, &tmp, binding, &.{"{\"type\":\"message\",\"id\":\"private-marker\",\"role\":\"assistant\",\"secret\":\"private-marker\",\"content\":[{\"type\":\"output_text\",\"text\":\"public answer\"}]}"}, "public answer");
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT bag.private FROM model_output_item item JOIN content bag ON bag.content_id=item.extras_content_id WHERE item.item_kind=2", .{}));
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session };
    try request.query.set("private-marker");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expect(result.next == null);
    try request.query.set("public answer");
    try storage.searchActivity(&request, result);
    try std.testing.expect(result.count >= 1);
    try std.testing.expect(!storage.isFenced());
}

test "searchActivity fences private content substituted into a public message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const session = try configureTestSession(&storage, "search-corruption");
    try submitTestMessage(&storage, &tmp, "search-corrupt-message", "search-corrupt-message", session.slice(), "secret");
    try store_testing.sqlite_only.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='search-corrupt-message')", .{});
    const result = try arena_state.allocator().create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session };
    try request.query.set("secret");
    try std.testing.expectError(error.CorruptStore, storage.searchActivity(&request, result));
    try std.testing.expect(storage.isFenced());
}

test "searchActivity verifies canonical content even when its text does not match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const session = try configureTestSession(&storage, "search-digest");
    try submitTestMessage(&storage, &tmp, "search-digest-message", "search-digest-message", session.slice(), "correct");
    try store_testing.sqlite_only.exec(&storage, "UPDATE content SET payload=CAST('damaged' AS BLOB) WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='search-digest-message')", .{});
    const result = try arena_state.allocator().create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session };
    try request.query.set("absent");
    try std.testing.expectError(error.CorruptStore, storage.searchActivity(&request, result));
    try std.testing.expect(storage.isFenced());
}

test "searchActivity exhausted exact-budget entry has no continuation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try configureTestSession(&storage, "search-exact-budget");
    const text = try arena.alloc(u8, reads_domain.activity_search_budget);
    @memset(text, 'x');
    try submitTestMessage(&storage, &tmp, "budget-exact", "budget-exact", session.slice(), text);
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission) };
    try request.query.set("absent");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expect(result.next == null);
    try std.testing.expect(!storage.isFenced());
}

test "searchActivity fences missing assistant entries only in its scanned range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const missing = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "lost answer", .decoded = "lost answer" }});
    try submitTestMessage(&storage, &tmp, "after-missing", "after-missing", missing.session.slice(), "later match");
    try store_testing.sqlite_only.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
    const result = try arena_state.allocator().create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = missing.session, .limit = 1 };
    try request.query.set("later match");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(!storage.isFenced());
    const next = result.next.?;
    request.before_position = next.position;
    request.before_ordinal = next.ordinal;
    try std.testing.expectError(error.CorruptStore, storage.searchActivity(&request, result));
    try std.testing.expect(storage.isFenced());
}
