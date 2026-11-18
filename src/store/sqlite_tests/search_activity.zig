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

test "INS-8 searchActivity matches Text parts, names each part and skips Image bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try configureTestSession(&storage, "search-parts-config");
    const png = @embedFile("../../codecs/fixtures/image-input/pixel.png");
    const first_text = "a nee";
    const second_text = "dle é needle";
    const image_marker = "IHDR";
    try std.testing.expect(std.mem.indexOf(u8, png, image_marker) != null);
    // NEEDLE would also match across the first two Text parts if they were joined.
    try store_testing.submitTestMessageParts(&storage, &tmp, "search-parts", session.slice(), &.{
        .{ .bytes = first_text },
        .{ .bytes = second_text },
        .{ .bytes = png, .kind = .{ .image = .{} } },
        .{ .bytes = image_marker ++ " needle" },
    });
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission) };
    try request.query.set("NEEDLE");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    const item = &result.items[0];
    try std.testing.expectEqual(@as(usize, 2), item.count);
    for (item.hits[0..item.count], [_]u32{ 1, 3 }, [_][]const u8{ second_text, image_marker ++ " needle" }) |*hit, part, snippet| {
        try std.testing.expectEqual(@as(?u32, part), hit.part);
        try std.testing.expectEqualStrings(snippet, hit.snippet.slice());
        try std.testing.expectEqualStrings("needle", hit.snippet.slice()[hit.offset..][0..hit.length]);
    }
    try request.query.set(image_marker);
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(?u32, 3), result.items[0].hits[0].part);
    try std.testing.expectEqual(@as(usize, 1), result.items[0].count);

    const page = try arena.create(protocol.ActivityFacts);
    const page_request: protocol.ActivityPage = .{ .session = session, .kinds = request.kinds };
    try storage.activityPage(&page_request, page);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    const parts_position = page.items[0].position;
    const value = page.items[0].value.admission.content;
    try std.testing.expect(value == .parts);
    const manifest_bytes: usize = @intCast(value.parts.identity.length);

    // Leave just enough budget to cover the manifest and scan through IHDR.
    const through_match = first_text.len + second_text.len + image_marker.len;
    const filler = try arena.alloc(u8, reads_domain.activity_search_budget - manifest_bytes - through_match);
    @memset(filler, 'x');
    try submitTestMessage(&storage, &tmp, "parts-budget-filler", "parts-budget-filler", session.slice(), filler);
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(parts_position, result.items[0].position);
    try std.testing.expectEqual(@as(usize, 1), result.items[0].count);
    try std.testing.expectEqual(@as(?u32, 3), result.items[0].hits[0].part);
    try std.testing.expectEqualStrings(image_marker, result.items[0].hits[0].snippet.slice());
    try std.testing.expect(result.next == null);

    // One more admission leaves the budget one byte short of the manifest.
    try submitTestMessage(&storage, &tmp, "parts-budget-boundary", "parts-budget-boundary", session.slice(), filler[0 .. through_match + 1]);
    try storage.activityPage(&page_request, page);
    try std.testing.expectEqual(@as(usize, 3), page.count);
    const last_scanned = &page.items[1];
    try std.testing.expectEqualStrings("parts-budget-filler", last_scanned.value.admission.key.slice());
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    const cursor = result.next orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(last_scanned.position, cursor.position);
    try std.testing.expectEqual(last_scanned.ordinal, cursor.ordinal);

    request.before_position = cursor.position;
    request.before_ordinal = cursor.ordinal;
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(parts_position, result.items[0].position);
    try std.testing.expectEqual(@as(usize, 1), result.items[0].count);
    try std.testing.expectEqual(@as(?u32, 3), result.items[0].hits[0].part);
    try std.testing.expectEqualStrings(image_marker ++ " needle", result.items[0].hits[0].snippet.slice());
    try std.testing.expect(result.next == null);
    try std.testing.expect(!storage.isFenced());
}
