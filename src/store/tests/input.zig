//! Original ordered Message bytes survive custody closure, replay and reopen.
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const InputCapture = @import("../../InputCapture.zig");
const ScratchBudget = @import("../../ScratchBudget.zig");
const input_parts = @import("../../input_parts.zig");
const input = @import("../domain/input.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const testing = @import("../testing.zig");
const content = @import("../domain/content.zig");

const jpeg = @embedFile("../../testing/fixtures/input-baseline.jpg");
const name = input_parts.displayName("original \"image\".jpg") catch unreachable;
const Segment = struct { kind: InputCapture.Incoming, bytes: []const u8 };
const mixed = [_]Segment{
    .{ .kind = .text, .bytes = "before\x00\xe9\x9b\xaa\n" },
    .{ .kind = .{ .image = .{ .assertion = .jpeg, .name = name } }, .bytes = jpeg },
    .{ .kind = .text, .bytes = "after /skill" },
};

fn initCapture(out: *InputCapture, dir: std.Io.Dir, budget: ScratchBudget) !void {
    const spool = try dir.createFile(std.testing.io, "input-spool", .{ .read = true });
    errdefer spool.close(std.testing.io);
    try dir.deleteFile(std.testing.io, "input-spool");
    const index = try dir.createFile(std.testing.io, "input-index", .{ .read = true });
    errdefer index.close(std.testing.io);
    try dir.deleteFile(std.testing.io, "input-index");
    out.init(std.testing.io, spool, index, budget);
}

fn captureInto(out: *InputCapture, dir: std.Io.Dir, budget: ScratchBudget, segments: []const Segment) !InputCapture.Loan {
    try initCapture(out, dir, budget);
    // After transfer this owner alone returns all byte and index charges.
    errdefer out.close();
    for (segments) |segment| {
        try out.begin(segment.kind, segment.bytes.len);
        var offset: usize = 0;
        while (offset < segment.bytes.len) {
            var allowance: usize = InputCapture.window_bytes;
            offset += try out.append(segment.bytes[offset..], &allowance, false);
        }
        try out.end();
    }
    return out.seal();
}

fn commandFor(key: []const u8, session: []const u8) !wire_request.MessageCommand {
    var command: wire_request.MessageCommand = .{};
    try command.key.set(key);
    try command.session.set(session);
    return command;
}

fn expectOriginals(storage: *Store, producer: input.Producer, segments: []const Segment) !void {
    var cursor: input.Cursor = undefined;
    const certificate = try storage.openInput(producer, &cursor);
    try std.testing.expect(certificate == .retained);
    try std.testing.expectEqual(@as(u32, @intCast(segments.len)), certificate.retained);
    for (segments, 0..) |segment, ordinal| {
        const part = (try storage.readInputPart(&cursor)).?;
        try std.testing.expectEqual(@as(u32, @intCast(ordinal)), part.ordinal);
        try std.testing.expectEqual(@as(u64, segment.bytes.len), part.reference.length);
        try std.testing.expectEqual(protocol.contentDigest(segment.bytes), part.reference.digest);
        switch (segment.kind) {
            .text => try std.testing.expect(part.kind == .text),
            .image => |image| {
                try std.testing.expect(part.kind == .image);
                try std.testing.expectEqual(.jpeg, part.kind.image.media.format);
                try std.testing.expectEqual(@as(u32, 3), part.kind.image.media.width);
                try std.testing.expectEqual(@as(u32, 2), part.kind.image.media.height);
                try std.testing.expectEqualStrings(image.name.?.slice(), part.kind.image.name.?.slice());
            },
        }
        var reader: content.ContentReader = undefined;
        reader.open(try storage.openContent(part.reference));
        defer reader.close();
        var window: [128]u8 = undefined;
        var offset: usize = 0;
        while (offset < segment.bytes.len) {
            const count = try reader.read(offset, window[0..@min(window.len, segment.bytes.len - offset)]);
            try std.testing.expect(count != 0);
            try std.testing.expectEqualSlices(u8, segment.bytes[offset..][0..count], window[0..count]);
            offset += count;
        }
        try std.testing.expectEqual(@as(usize, 0), try reader.read(offset, &window));
    }
    try std.testing.expect((try storage.readInputPart(&cursor)) == null);
    _ = try cursor.reference();
}

test "ordered input preserves image-only, repeated and interleaved original parts after reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            const image_only = mixed[1..2];
            const repeated = [_]Segment{ mixed[1], mixed[1] };
            const boundaries = [_]Segment{ mixed[0], .{ .kind = .text, .bytes = "" }, mixed[1], mixed[2] };
            inline for (.{ image_only, &repeated, &mixed, &boundaries }) |segments| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var used = std.atomic.Value(u64).init(11);
                var capture: InputCapture = undefined;
                const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, segments);
                defer capture.close();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                const session = try testing.configureTestSession(&storage, "ordered-config");
                const command = try commandFor("ordered-message", session.slice());
                const first = storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{});
                try std.testing.expect(first == .accepted);
                try std.testing.expect(first.accepted.content == .parts);
                try std.testing.expectEqual(@as(u32, segments.len), first.accepted.content.parts.count);
                try expectOriginals(&storage, .{ .message = command.key }, segments);
                const content_count = try testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                // Replay is a saved command decision. It cannot need a live spool.
                capture.close();
                try std.testing.expectEqual(@as(u64, 11), used.load(.acquire));
                try storage.close();
                opened = false;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                const replay = storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(first.accepted.admission_id, replay.accepted.admission_id);
                try std.testing.expectEqualDeep(first.accepted.content, replay.accepted.content);
                try std.testing.expectEqual(content_count, try testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                try expectOriginals(&storage, .{ .message = command.key }, segments);
            }
        }
    }.run);
}

test "ordered input compound identity detects reordering without another admission" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var used = std.atomic.Value(u64).init(0);
            var capture: InputCapture = undefined;
            const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, &mixed);
            defer capture.close();
            const reordered = [_]Segment{ mixed[2], mixed[1], mixed[0] };
            var changed: InputCapture = undefined;
            const changed_loan = try captureInto(&changed, tmp.dir, .{ .used = &used, .limit = 8192 }, &reordered);
            defer changed.close();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try testing.configureTestSession(&storage, "ordered-config");
            const command = try commandFor("ordered-message", session.slice());
            try std.testing.expect(storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{}) == .accepted);
            const count = try testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            try std.testing.expect(storage.submitMessageInput(&command, .{ .parts = changed_loan }, null, null, null, .{}) == .conflict);
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(count, try testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            try expectOriginals(&storage, .{ .message = command.key }, &mixed);
        }
    }.run);
}

test "ordered input new saved refusal retains originals and replays without custody" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var used = std.atomic.Value(u64).init(0);
            var capture: InputCapture = undefined;
            const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, &mixed);
            defer capture.close();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const command = try commandFor("ordered-refused", "aaaaaa");
            const refused = storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{});
            try std.testing.expect(refused == .rejected and !refused.rejected.replayed);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, refused.rejected.code);
            try expectOriginals(&storage, .{ .message = command.key }, &mixed);
            try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            capture.close();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            const replay = storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);
            try std.testing.expectEqual(refused.rejected.code, replay.rejected.code);
            try std.testing.expectEqualDeep(refused.rejected.content, replay.rejected.content);
            // New refusals cannot take the migrated old-refusal absence branch.
            try testing.exec(&storage, "DELETE FROM input_part WHERE command_key=?1 AND ordinal=1", .{command.key.slice()});
            var cursor: input.Cursor = undefined;
            try std.testing.expectError(error.CorruptStore, storage.openInput(.{ .message = command.key }, &cursor));
            try std.testing.expectError(error.StoreFenced, storage.openInput(.{ .message = command.key }, &cursor));
        }
    }.run);
}

test "ordered input partial custody failure rolls back certificate parts and raw imports" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            inline for (.{ false, true }) |commit_fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var used = std.atomic.Value(u64).init(0);
                var capture: InputCapture = undefined;
                const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, &mixed);
                defer capture.close();
                if (!commit_fault) try capture.resources.?.spool.writePositionalAll(std.testing.io, "x", mixed[0].bytes.len + 200);
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                const session = try testing.configureTestSession(&storage, "ordered-config");
                const command = try commandFor("ordered-failed", session.slice());
                const before = try testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                try std.testing.expect(storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{ .before_commit = commit_fault }) == .infrastructure_failure);
                try std.testing.expectEqual(before, try testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1", .{command.key.slice()}));
                try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM input_part", .{}));
                try std.testing.expectEqual(@as(u64, 0), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
                capture.close();
                try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
                try storage.close();
                opened = false;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try std.testing.expectEqual(.absent, (try testing.observeCommandForTesting(&storage, command.key.slice())).status);
                try std.testing.expectEqual(before, try testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            }
        }
    }.run);
}

test "ordered input rejects replaced valid public Content before its last part or saved replay" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            inline for (.{ false, true }) |replay| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var used = std.atomic.Value(u64).init(0);
                var capture: InputCapture = undefined;
                const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, &mixed);
                defer capture.close();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                const session = try testing.configureTestSession(&storage, "certificate-config");
                const command = try commandFor("certificate-message", session.slice());
                try std.testing.expect(storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{}) == .accepted);
                // Both Content rows are valid and public. Only the immutable
                // ordered certificate distinguishes this replacement.
                const replacement = try testing.queryU64(&storage, "SELECT content_id FROM input_part WHERE command_key=?1 AND ordinal=0", .{command.key.slice()});
                try testing.exec(&storage, "UPDATE input_part SET content_id=?1 WHERE command_key=?2 AND ordinal=2", .{ replacement, command.key.slice() });
                capture.close();
                try storage.close();
                opened = false;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                if (replay) {
                    const result = storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{});
                    try std.testing.expect(result == .infrastructure_failure);
                } else {
                    var cursor: input.Cursor = undefined;
                    const certificate = try storage.openInput(.{ .message = command.key }, &cursor);
                    try std.testing.expectEqual(@as(u32, 3), certificate.retained);
                    _ = (try storage.readInputPart(&cursor)).?;
                    _ = (try storage.readInputPart(&cursor)).?;
                    // No extra null drain: a count-bounded consumer must
                    // reject the last record before accepting its identity.
                    try std.testing.expectError(error.CorruptStore, storage.readInputPart(&cursor));
                }
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

const TextDoor = enum { activity, conversation, content_bytes, observation, report };

fn readTextDoor(storage: *Store, tmp: *std.testing.TmpDir, command: *const wire_request.MessageCommand, position: u64, door: TextDoor) !void {
    switch (door) {
        .activity => _ = try store_core.activityPageForTesting(storage, .{ .session = command.session }),
        .conversation => _ = try store_core.publicConversationPageForTesting(storage, .{ .session = command.session }),
        .content_bytes => {
            const request: protocol.ConversationContent = .{ .session = command.session, .position = position };
            var reader: content.ContentReader = undefined;
            reader.open(try storage.openPublicConversationContent(&request));
            reader.close();
        },
        .observation => _ = try testing.observeCommandForTesting(storage, command.key.slice()),
        .report => {
            const bytes = try @import("../tests.zig").testingSessionReport(storage, tmp, command.session.slice(), 1024 * 1024);
            std.testing.allocator.free(bytes);
        },
    }
}

test "ordered input incapable Text readers validate compound identity before ordinary refusal" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            inline for (std.enums.values(TextDoor)) |door| {
                inline for (.{ false, true }) |damaged| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var used = std.atomic.Value(u64).init(0);
                    var capture: InputCapture = undefined;
                    const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, &mixed);
                    defer capture.close();
                    var storage: Store = undefined;
                    try testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try testing.configureTestSession(&storage, "unsupported-config");
                    const command = try commandFor("unsupported-message", session.slice());
                    try std.testing.expect(storage.submitMessageInput(&command, .{ .parts = loan }, null, null, null, .{}) == .accepted);
                    _ = (try storage.admitNextModelAttempt(.{})).?;
                    const position = try testing.queryU64(&storage, "SELECT session_position FROM conversation_entry WHERE source_admission_id=(SELECT admission_id FROM message_admission WHERE command_key=?1)", .{command.key.slice()});
                    if (damaged) {
                        const replacement = try testing.queryU64(&storage, "SELECT content_id FROM input_part WHERE command_key=?1 AND ordinal=0", .{command.key.slice()});
                        try testing.exec(&storage, "UPDATE input_part SET content_id=?1 WHERE command_key=?2 AND ordinal=2", .{ replacement, command.key.slice() });
                    }
                    try std.testing.expectError(if (damaged) error.CorruptStore else error.InputPartsNotSupported, readTextDoor(&storage, &tmp, &command, position, door));
                    try std.testing.expectEqual(damaged, storage.isFenced());
                }
            }
        }
    }.run);
}

test "ordered input frozen history validates compound facts before floors and excludes later arrivals" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            const Damage = enum { none, frozen, later };
            inline for (std.enums.values(Damage)) |damage| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var used = std.atomic.Value(u64).init(0);
                var capture: InputCapture = undefined;
                const loan = try captureInto(&capture, tmp.dir, .{ .used = &used, .limit = 8192 }, &mixed);
                defer capture.close();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try testing.configureTestSession(&storage, "frozen-input-config");
                const first = try commandFor("frozen-input", session.slice());
                try std.testing.expect(storage.submitMessageInput(&first, .{ .parts = loan }, null, null, null, .{}) == .accepted);
                const response = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(response, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(@import("../domain/historical.zig").ModelOperationKind.compaction, try storage.modelOperationKind(binding));
                const later = try commandFor("later-input", session.slice());
                try std.testing.expect(storage.submitMessageInput(&later, .{ .parts = loan }, null, null, null, .{}) == .accepted);
                // Place the frozen floor beyond its User entry as a damaged
                // storage fixture. It must never hide damage to that source.
                try testing.exec(&storage, "UPDATE model_operation SET history_floor=admission_position-1 WHERE operation_id=?1", .{binding.operation_id});
                if (damage != .none) {
                    const key = if (damage == .frozen) first.key.slice() else later.key.slice();
                    try testing.exec(&storage, "DELETE FROM input_part WHERE command_key=?1 AND ordinal=1", .{key});
                }
                var view: @import("../domain/historical.zig").HistoricalView = undefined;
                storage.openHistoricalView(binding, &view);
                defer view.close();
                var settings: @import("../domain/historical.zig").HistoricalSettings = undefined;
                if (damage == .frozen) {
                    try std.testing.expectError(error.CorruptStore, view.settings(&settings));
                    try std.testing.expect(storage.isFenced());
                } else {
                    try view.settings(&settings);
                    try std.testing.expect(!storage.isFenced());
                }
            }
        }
    }.run);
}
