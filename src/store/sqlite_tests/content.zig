//! Content SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const configuration_domain = @import("../domain/configuration.zig");
const content_domain = @import("../domain/content.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const testingPublicProjection = store_testing.testingPublicProjection;
const TestingAsk = tests.TestingAsk;
const TestingScript = tests.TestingScript;
const testingContent = tests.testingContent;
const testingStore = store_testing.testingSqliteStore;
const busyStatements = shared_fixtures.busyStatements;

/// Imports `bytes` as public content in a transaction of its own, as
/// identities are taken only inside one.
fn importCommittedForTesting(storage: *Store, bytes: []const u8) !void {
    const Import = struct {
        pub const Guards = error{};
        bytes: []const u8,
        value: content_domain.Import,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            if (ran == 0) {
                content_domain.lookup(r, &b.value);
                return .round;
            }
            _ = try content_domain.importBytes(r, &b.value, b.bytes);
            return .commit;
        }
    };
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var import: Import = .{ .bytes = bytes, .value = .ofBytes(bytes, false) };
    return TestingScript(Import).run(&entry, &import);
}

test "interleaved large content readers bound repeated SQLite page reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const length = 4 * 1024 * 1024;
    const first = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(second);
    for (first, second, 0..) |*a, *b, index| {
        a.* = @intCast(index % 251);
        b.* = @intCast((index * 17 + 37) % 253);
    }
    try importCommittedForTesting(&storage, first);
    try importCommittedForTesting(&storage, second);
    var readers: [2]ContentReader = undefined;
    readers[0].open(try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(first) }));
    readers[1].open(try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(second) }));
    defer for (&readers) |*reader| reader.close();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    readers[0].allocator = failing.allocator();
    var buffer: [4096]u8 = undefined;
    // EOF needs no read-ahead allocation. A real allocation failure preserves
    // the existing bounded reads and leaves this same Store usable.
    try std.testing.expectEqual(@as(usize, 0), try readers[0].read(length, &buffer));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(buffer.len, try readers[0].read(0, &buffer));
    try std.testing.expectEqualSlices(u8, first[0..buffer.len], &buffer);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    for (&readers) |*reader| reader.allocator = std.testing.allocator;
    var misses: c_int = 0;
    var ignored: c_int = 0;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_db_status(storage.sqliteDatabase(), c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &ignored, 1));
    var offset: usize = 0;
    while (offset < length) : (offset += buffer.len) {
        for (&readers, [_][]const u8{ first, second }) |*reader, expected| {
            try std.testing.expectEqual(buffer.len, try reader.read(offset, &buffer));
            try std.testing.expectEqualSlices(u8, expected[offset..][0..buffer.len], &buffer);
        }
        if (offset == 0) {
            _ = try configureTestSession(&storage, "interleaved-write");
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
    }
    for (&readers) |*reader| try std.testing.expectEqual(@as(usize, 0), try reader.read(length, &buffer));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_db_status(storage.sqliteDatabase(), c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &ignored, 0));
    // Two 4-MiB streams through a 1-MiB SQLite cache must not re-read their
    // entire overflow prefix for every 4-KiB delivery, including interleaving.
    const pages = 2 * length / 4096;
    try std.testing.expect(misses <= 16 * pages);
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    {
        const corrupt = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(corrupt);
        try sqlite.bindI64(corrupt, 1, readers[0].content_id);
        try sqlite.expectDone(corrupt);
    }
    // Copied bytes belong only to their original reader. A newly resolved
    // raw reader must see the changed row, not another reader's old window.
    var fresh: ContentReader = undefined;
    fresh.open(try storage.openContent(readers[0].reference));
    defer fresh.close();
    fresh.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(first[length - 1], buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), try fresh.read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
    {
        const remove = try sqlite.prepare(storage.sqliteDatabase(), "DELETE FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(remove);
        try sqlite.bindI64(remove, 1, readers[0].content_id);
        try sqlite.expectDone(remove);
    }
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectError(error.ContentReadFailed, readers[0].read(0, &buffer));
    try std.testing.expect(storage.isFenced());
}

test "retained readers allow checkpoints between committed windows" {
    var checkpoints: [2]c_int = undefined;
    for ([_]bool{ false, true }, 0..) |answer, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const text = @as([32768]u8, @splat('x')) ++ "asymmetric-é-tail";
        const location = if (answer) blk: {
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = text, .decoded = text }});
            break :blk try storage.openPublicConversationContent(&request);
        } else blk: {
            try importCommittedForTesting(&storage, text);
            break :blk try storage.openContent(.{ .length = text.len, .digest = protocol.contentDigest(text) });
        };
        var reader: ContentReader = undefined;
        reader.open(location);
        defer reader.close();
        var window: [4096]u8 = undefined;
        try std.testing.expectEqual(window.len, try reader.read(0, &window));
        try std.testing.expectEqualSlices(u8, text[0..window.len], &window);
        // Keep the reader alive across an unrelated ordinary commit, just as
        // slow Reply delivery or an allowance-limited preparation does.
        _ = try configureTestSession(&storage, "checkpoint-write");
        checkpoints[index] = c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        var offset: usize = window.len;
        while (offset < text.len) {
            const count = try reader.read(offset, &window);
            try std.testing.expectEqualSlices(u8, text[offset..][0..count], window[0..count]);
            offset += count;
        }
        try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &window));
    }
    try std.testing.expectEqualSlices(c_int, &.{ c.SQLITE_OK, c.SQLITE_OK }, &checkpoints);
}

test "real SQLite full during import publishes no canonical prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const page_count = try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA page_count");
    var limit_buffer: [64:0]u8 = undefined;
    const limit = try std.fmt.bufPrintSentinel(&limit_buffer, "PRAGMA max_page_count={d}", .{page_count}, 0);
    try sqlite.exec(storage.sqliteDatabase(), limit);
    try std.testing.expectEqual(page_count, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA max_page_count"));

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "full-import",
        "",
        workspace,
        "model-a",
    );
    command.configuration.instructions = try testingContent(
        &tmp,
        "full-import-content",
        'x',
        128 * 1024,
    );
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    // Drive the production transaction body directly so the test observes
    // the exact import-step result before the public wrapper maps it. SQLite
    // automatically rolls this FULL transaction back; the public wrapper's
    // `finishTransaction` then fences it as a non-ordinary error.
    try std.testing.expectError(
        error.CanonicalStorageFull,
        configure: {
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var reply: configuration_domain.ConfigureReply = undefined;
            var configuring: command_domain.Configure = .{ .input = .{
                .io = storage.io,
                .served = storage.served,
                .tools = storage.hostTools(),
                .command = &command,
                .preset = null,
                .initial_skills = null,
                .reload_capture = null,
                .allocator = std.heap.c_allocator,
                .committed = null,
                .reply = &reply,
            } };
            break :configure transition.run(&entry, command_domain.Configure, &configuring, .{});
        },
    );
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    store_core.fence(&storage, error.CanonicalStorageFull) catch {};
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "full-import"));
    try storage.close();
    storage_open = false;

    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try store_testing.observeCommandForTesting(&reopened, "full-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM session", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM content WHERE byte_length=131072", .{}));
}
