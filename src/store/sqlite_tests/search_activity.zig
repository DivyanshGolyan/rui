const std = @import("std");
const failure_report = @import("../../failure_report.zig");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const skills_domain = @import("../domain/skills.zig");
const store_testing = @import("../testing.zig");
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const testingPublicProjection = store_testing.testingPublicProjection;
const testingStore = store_testing.testingSqliteStore;

fn windowEdgesKindsAndPaging() !void {
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

fn budgetEmptyPageKeepsUsableCursor() !void {
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

fn privateProviderExtrasAreNotSearched() !void {
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

/// Content the search reads is verified against the Store's own facts even when its text does not match: private content under a
/// public message and damaged bytes fence the Store instead of being skipped.
fn corruptContentFences() !void {
    const Case = struct { config: []const u8, key: []const u8, text: []const u8, query: []const u8, damage: [:0]const u8 };
    const cases = [_]Case{
        .{ .config = "search-corruption", .key = "search-corrupt-message", .text = "secret", .query = "secret", .damage = "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='search-corrupt-message')" },
        .{ .config = "search-digest", .key = "search-digest-message", .text = "correct", .query = "absent", .damage = "UPDATE content SET payload=CAST('damaged' AS BLOB) WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='search-digest-message')" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const session = try configureTestSession(&storage, case.config);
        try submitTestMessage(&storage, &tmp, case.key, case.key, session.slice(), case.text);
        try store_testing.sqlite_only.exec(&storage, case.damage, .{});
        const result = try arena_state.allocator().create(protocol.ActivitySearchFacts);
        var request: protocol.ActivitySearch = .{ .session = session };
        try request.query.set(case.query);
        try std.testing.expectError(error.CorruptStore, storage.searchActivity(&request, result));
        try std.testing.expect(storage.isFenced());
    }
}

fn exactBudgetEntryHasNoContinuation() !void {
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

fn missingAssistantFencesOnlyInScannedRange() !void {
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

fn textPartsAreSearchedEachAlone() !void {
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

fn instructionSkillAndHostedText() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = skills_domain.Initial{ .ready = .{
        .encoded = "{\"entries\":[{\"name\":\"audit\",\"description\":\"Audit a change\",\"path\":\"/skills/audit/SKILL.md\"}]}",
        .instruction = "Available skills: audit with instrword at /skills/audit/SKILL.md",
    } };
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var create = try completeConfiguration("search-kinds-config", "", workspace, "model-a");
    const session = (try storage.configureWithInitialSkills(&create, null, &catalog, .{})).accepted.session;
    try store_testing.submitTestMessageWithSkills(&storage, &tmp, "search-kinds-input", "search-kinds-input", session.slice(), "use the skill", &.{
        .{ .name = "audit", .bytes = "Check every change for skillword first." },
    });
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleItemsForTesting(&storage, &tmp, binding, &.{
        "{\"type\":\"web_search_call\",\"id\":\"ws1\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"queries\":[\"alphatarget\",\"betatarget\"]}}",
        "{\"type\":\"web_search_call\",\"id\":\"ws2\",\"status\":\"completed\",\"action\":{\"type\":\"find_in_page\",\"url\":\"gammahost.example\",\"pattern\":\"deltapattern\"}}",
        "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}",
    }, "done");

    // Each row's position, read from the Activity page that serves it.
    const page = try arena.create(protocol.ActivityFacts);
    try storage.activityPage(&.{ .session = session }, page);
    var instruction: ?u64 = null;
    var skill: ?u64 = null;
    var hosted: [2]u64 = undefined;
    var hosted_count: usize = 0;
    for (page.items[0..page.count]) |item| switch (item.value) {
        .instruction => instruction = item.position,
        .skill => skill = item.position,
        .hosted_call => {
            hosted[hosted_count] = item.position;
            hosted_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), hosted_count);
    // The page is oldest first: the search settled before the find-in-page.
    const Case = struct { query: []const u8, kind: protocol.ActivityItem.Kind, position: u64 };
    const cases = [_]Case{
        .{ .query = "INSTRWORD", .kind = .instruction, .position = instruction.? },
        .{ .query = "skillword", .kind = .skill, .position = skill.? },
        .{ .query = "alphatarget", .kind = .hosted_call, .position = hosted[0] },
        .{ .query = "BetaTarget", .kind = .hosted_call, .position = hosted[0] },
        .{ .query = "gammahost", .kind = .hosted_call, .position = hosted[1] },
        .{ .query = "deltapattern", .kind = .hosted_call, .position = hosted[1] },
    };
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session };
    for (cases) |case| {
        try request.query.set(case.query);
        try storage.searchActivity(&request, result);
        try std.testing.expectEqual(@as(usize, 1), result.count);
        const item = &result.items[0];
        try std.testing.expectEqual(case.kind, item.kind);
        try std.testing.expectEqual(case.position, item.position);
        try std.testing.expectEqual(@as(usize, 1), item.count);
        const hit = &item.hits[0];
        try std.testing.expectEqual(@as(?u32, null), hit.part);
        try std.testing.expect(std.ascii.eqlIgnoreCase(case.query, hit.snippet.slice()[hit.offset..][0..hit.length]));
        try std.testing.expect(result.next == null);
    }

    // A hosted row's fields are one stream with a newline between them: a space does not span two targets, a newline does, as for a call's name and arguments.
    try request.query.set("alphatarget betatarget");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try request.query.set("alphatarget\nbetatarget");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("alphatarget\nbetatarget", result.items[0].hits[0].snippet.slice());
    try request.query.set("gammahost.example\ndeltapattern");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);

    // The budget is charged each field's bytes: two targets, a target and a pattern.
    request.kinds = .initOne(.hosted_call);
    try request.query.set("absent");
    const before = storage.testing_content_work.read.load(.monotonic);
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(u64, "alphatarget".len + "betatarget".len + "gammahost.example".len + "deltapattern".len), storage.testing_content_work.read.load(.monotonic) - before);
    request.kinds = .initOne(.instruction);
    const instruction_before = storage.testing_content_work.read.load(.monotonic);
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(u64, catalog.ready.instruction.?.len), storage.testing_content_work.read.load(.monotonic) - instruction_before);

    // A filter without the kind finds none of its text.
    for (cases) |case| {
        request.kinds = .initOne(.assistant);
        try request.query.set(case.query);
        try storage.searchActivity(&request, result);
        try std.testing.expectEqual(@as(usize, 0), result.count);
    }
    // Only the named kind is found when two words share a filter.
    request.kinds = .initMany(&.{ .instruction, .skill });
    try request.query.set("alphatarget");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try request.query.set("skillword");
    try storage.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(!storage.isFenced());
}

/// A failed Turn's text is the provider's words, saved inline as its report: found by the code or the message, with the cut mark
/// the one-line rendering shows, and a Turn with no report has no text.
fn failureReportText() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session = try configureTestSession(&storage, "search-report-config");
    var long: [300]u8 = undefined;
    @memset(&long, 'y');
    @memcpy(long[0..9], "longstart");
    // Code only, message only, both, a message cut at its bound, and none.
    const reports = [_]failure_report.Report{
        report("codeonlyword", ""),
        report("", "messageonlyword"),
        report("bothcode", "bothmessage"),
        report("", &long),
        failure_report.Report.empty,
    };
    for (reports, 0..) |failure, index| {
        const key = try std.fmt.allocPrint(arena, "search-report-{d}", .{index});
        try submitTestMessage(&storage, &tmp, key, key, session.slice(), "work");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = failure } }, .ordinary, .{});
    }
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.turn_ended) };
    const cases = [_]struct { query: []const u8, hits: usize }{
        .{ .query = "CODEONLYWORD", .hits = 1 },
        .{ .query = "messageonlyword", .hits = 1 },
        .{ .query = "bothcode: bothmessage", .hits = 1 },
        .{ .query = "longstart", .hits = 1 },
        // The cut mark is part of the rendering, so a search can find where a part was cut.
        .{ .query = "yy…", .hits = 1 },
        // The outcome code is not the provider's words.
        .{ .query = "provider_http_400", .hits = 0 },
    };
    for (cases) |case| {
        try request.query.set(case.query);
        try storage.searchActivity(&request, result);
        try std.testing.expectEqual(case.hits, result.count);
        if (case.hits != 0) {
            try std.testing.expectEqual(activity_kind_turn_ended, result.items[0].kind);
            try std.testing.expectEqual(@as(usize, 1), result.items[0].count);
        }
    }
}

const activity_kind_turn_ended = @import("../../activity_facts.zig").Item.Kind.turn_ended;

fn report(code: []const u8, message: []const u8) failure_report.Report {
    var read: failure_report.Report = .{};
    for ([_]*failure_report.Part{ &read.code, &read.message }, [_][]const u8{ code, message }) |part, bytes| {
        _ = part.append(bytes);
        part.finish();
    }
    return read;
}

test "INS-8 searchActivity matches only documented public text with bounded snippets, budget and continuation" {
    // Kinds, newest-first paging, window edges and ASCII case folding.
    try windowEdgesKindsAndPaging();
    // Text parts alone, each naming its part, Image bytes never, and the manifest charged to the budget.
    try textPartsAreSearchedEachAlone();
    // Instruction text, skill text and a hosted search's targets and pattern, and the filters that exclude them.
    try instructionSkillAndHostedText();
    // A failed Turn's provider words, saved inline as its report.
    try failureReportText();
    // The budget: an empty page keeps a usable cursor, and an entry that exactly exhausts it has none.
    try budgetEmptyPageKeepsUsableCursor();
    try exactBudgetEntryHasNoContinuation();
    // Private provider material is never searched; private or damaged content under a public entry fences.
    try privateProviderExtrasAreNotSearched();
    try corruptContentFences();
    // Fencing a missing assistant entry only in the range the scan covered.
    try missingAssistantFencesOnlyInScannedRange();
}
