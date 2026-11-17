const std = @import("std");
const protocol = @import("../../protocol.zig");
const action_read = @import("../../action_read.zig");
const tools = @import("../../tools.zig");
const core = @import("../Store.zig");
const action = @import("../domain/action.zig");
const historical = @import("../domain/historical.zig");
const testing = @import("../testing.zig");
const shared = @import("../tests.zig");

const png = @embedFile("../../codecs/fixtures/image-input/pixel.png");
const jpeg = @embedFile("../../testing/fixtures/input-baseline.jpg");
const mixed = [_]testing.MessagePart{
    .{ .bytes = "before \"quoted\"\n雪\x00" },
    .{ .bytes = png, .kind = .{ .image = .{ .assertion = .png } } },
    .{ .bytes = "between" },
    .{ .bytes = jpeg, .kind = .{ .image = .{ .assertion = .jpeg } } },
    .{ .bytes = "" },
};
const images = [_]testing.MessagePart{.{ .bytes = png, .kind = .{ .image = .{} } }};
const text = [_]testing.MessagePart{.{ .bytes = "one Text remains bytes 雪" }};
const records = shared.testingHostToolRecords(&.{.{
    .name = "fetch_page",
    .owner = .mcp,
    .server = "docs",
    .description = "Fetch a page.",
    .input_schema = "{\"type\":\"object\"}",
}});
fn hostToolSet(digests: *[records.len][32]u8) tools.HostToolSet {
    for (records, digests) |record, *digest| digest.* = tools.recordDigest(&record);
    return .{ .records = &records, .digests = digests };
}

fn propose(storage: *core.Store, tmp: *std.testing.TmpDir, comptime runner: tools.Runner) !@import("../../bounded.zig").Bounded(@import("../../session_id.zig").max_reference_bytes) {
    var workspace: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try testing.completeConfiguration("action-parts-config", "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
    const name = if (runner == .bash) "bash" else "fetch_page";
    configure.configuration.tools = try .of(&.{name});
    configure.configuration.permission_mode.state = .value;
    try configure.configuration.permission_mode.value.set("bypass");
    const configured = try storage.configure(&configure, .{});
    const session = configured.accepted.session;
    try testing.submitTestMessage(storage, tmp, "action-parts-input", "action-parts-message", session.slice(), "Run the tool.");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const arguments = if (runner == .bash) "{\"description\":\"Return parts\",\"cmd\":\"true\"}" else "{}";
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
    defer std.testing.allocator.free(encoded);
    try shared.settleCallsForTesting(storage, tmp, model, "action-parts-call", &.{.{
        .item_id = "parts-item",
        .name = name,
        .encoded_call_id = "parts-call",
        .decoded_call_id = "parts-call",
        .encoded_arguments = encoded[1 .. encoded.len - 1],
        .decoded_arguments = arguments,
    }});
    return session;
}

fn expectBytes(view: *testing.TestingPage, content: historical.HistoricalContent, expected: []const u8) !void {
    try std.testing.expectEqual(@as(u64, expected.len), content.length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(expected), &content.digest);
    var reader: testing.TestingReader = undefined;
    try view.openContent(content, &reader);
    defer reader.close();
    var offset: usize = 0;
    var bytes: [257]u8 = undefined;
    while (offset < expected.len) {
        const count = try reader.read(offset, &bytes);
        try std.testing.expect(count > 0);
        try std.testing.expectEqualSlices(u8, expected[offset..][0..count], bytes[0..count]);
        offset += count;
    }
    try std.testing.expectEqual(@as(usize, 0), try reader.read(offset, &bytes));
}

fn expectParts(view: *testing.TestingPage, input: historical.HistoricalInput, parts: []const testing.MessagePart) !void {
    try std.testing.expect(input.value.reference == .parts);
    try view.page.openMessage(input);
    for (parts) |expected| {
        const part = (try view.nextMessagePart()).?;
        switch (expected.kind) {
            .text => try std.testing.expect(part.kind == .text),
            .image => |image| {
                try std.testing.expect(part.kind == .image);
                if (image.assertion) |format| try std.testing.expectEqual(format, part.kind.image.media.format);
            },
        }
        try expectBytes(view, part.content, expected.bytes);
    }
    try std.testing.expect((try view.nextMessagePart()) == null);
}

fn expectHistory(storage: *core.Store, binding: core.AttemptBinding, parts: []const testing.MessagePart, background: bool, action_id: u64, content_id: u64) !void {
    var view: testing.TestingPage = undefined;
    view.open(storage, binding);
    defer view.close();
    var settings: historical.HistoricalSettings = undefined;
    try view.settings(&settings);
    const compound = parts.len != 1 or parts[0].kind != .text;
    try std.testing.expectEqual(compound, view.page.compound_inputs);
    var position: u64 = 0;
    var results: usize = 0;
    var finals: usize = 0;
    while (try view.nextEntry(position)) |entry| {
        position = entry.position;
        if (entry.kind == .tool_results) {
            while (try view.nextToolResult()) |result| {
                results += 1;
                try expectBytes(&view, result.call_id, "parts-call");
                if (background) {
                    try std.testing.expect(result.input == null);
                    var bytes: [160]u8 = undefined;
                    const receipt = try std.fmt.bufPrint(&bytes, "{{\"action\":\"{d}\",\"execution\":\"background\",\"accepted\":true}}", .{action_id});
                    try expectBytes(&view, result.output.?, receipt);
                } else if (compound) {
                    try std.testing.expect(result.input != null);
                    try std.testing.expect(result.output == null);
                    try std.testing.expectEqual(content_id, result.input.?.value.content_id);
                    try expectParts(&view, result.input.?, parts);
                } else try expectBytes(&view, result.output.?, parts[0].bytes);
            }
        }
        if (entry.source_action) |source| {
            finals += 1;
            try std.testing.expectEqual(action_id, source.id);
            if (compound) {
                try std.testing.expect(entry.input != null);
                try std.testing.expectEqual(content_id, entry.input.?.value.content_id);
                try expectParts(&view, entry.input.?, parts);
            } else try expectBytes(&view, entry.content.?, parts[0].bytes);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), results);
    try std.testing.expectEqual(@as(usize, if (background) 1 else 0), finals);
}

fn exercise(case: *testing.Case, background: bool) !void {
    var digests: [records.len][32]u8 = undefined;
    const tool_set = hostToolSet(&digests);
    inline for ([_]tools.Runner{ .bash, .mcp }) |runner| {
        for ([_][]const testing.MessagePart{ &mixed, &images, &text }) |parts| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: core.Store = undefined;
            try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
            var open = true;
            defer if (open) storage.close() catch unreachable;
            const session = try propose(&storage, &tmp, runner);
            const selected = (try storage.nextAction(runner, .fromFree(2, true))).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            var promotion: @import("../../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = selected.action_id };
            try promotion.key.set("action-parts-promote");
            var receipt_position: u64 = 0;
            if (background) {
                const promoted = storage.backgroundAction(.{ .command = &promotion }, .{});
                try std.testing.expect(promoted == .accepted and !promoted.accepted.replayed);
                receipt_position = promoted.accepted.selection.position;
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try testing.settleItemsForTesting(&storage, &tmp, continuation, &.{"{\"type\":\"message\",\"id\":\"parts-answer\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
            }
            // The helper closes the capture before any persisted reads.
            try testing.settleTestActionParts(&storage, &tmp, binding, parts);
            const content = try testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{selected.action_id});
            const compound = parts.len != 1 or parts[0].kind != .text;
            try std.testing.expectEqual(@as(u64, if (compound) 1 else 0), try testing.queryU64(&storage, "SELECT form FROM content WHERE content_id=?1", .{content}));
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            for (0..2) |pass| {
                if (pass == 1) {
                    try storage.close();
                    open = false;
                    try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
                    open = true;
                }
                try expectHistory(&storage, next, parts, background, selected.action_id, content);
                var read: action_read.Read = undefined;
                const request: action_read.Request = .{ .session = session, .action_id = selected.action_id };
                if (compound) {
                    try std.testing.expectError(error.InputPartsNotSupported, storage.readAction(&request, &read));
                } else {
                    try storage.readAction(&request, &read);
                    try std.testing.expectEqualStrings(parts[0].bytes, read.status.resolved.window.text.slice());
                }
                try std.testing.expect(!storage.isFenced());
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding, .failed, "replacement", .{}));
                try std.testing.expectEqual(content, try testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{selected.action_id}));
                if (background) {
                    const replay = storage.backgroundAction(.{ .command = &promotion }, .{});
                    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                    try std.testing.expectEqual(receipt_position, replay.accepted.selection.position);
                    try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1 AND content_id=?2", .{ selected.action_id, content }));
                    try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_admission_id IN (SELECT admission_id FROM message_admission WHERE source_action_id=?1) AND content_id=?2", .{ selected.action_id, content }));
                }
            }
        }
    }
}

test "compound Action Resolution retains ordered bytes across replay and Store reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            try exercise(case, false);
        }
    }.run);
}

test "compound Action Resolution survives background final delivery and Store reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            try exercise(case, true);
        }
    }.run);
}

fn readBounded(storage: *core.Store, view: *historical.RequestPage, comptime entry: bool) !void {
    const work = shared.ViewRounds.start(storage);
    const result = storage.readRequestPage(view);
    const taken = work.taken();
    if (entry) {
        // The shared entry/group batch and source Resolution metadata each
        // take one round. Manifest bytes belong to the resumable part cursor.
        try std.testing.expectEqual(@as(u16, 0), taken.content_rounds);
        try std.testing.expect(taken.rounds <= 2);
    } else try std.testing.expect(taken.rounds + taken.content_rounds <= 1);
    return result;
}

test "compound Action Resolution background final yields and certifies maximum parts before its first part" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var digests: [records.len][32]u8 = undefined;
            const tool_set = hostToolSet(&digests);
            for ([_]bool{ false, true }) |damage_last| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: core.Store = undefined;
                try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
                defer storage.close() catch unreachable;
                _ = try propose(&storage, &tmp, .bash);
                const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
                const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
                try std.testing.expect(storage.backgroundAction(.{ .live_action = selected.action_id }, .{}) == .accepted);
                const parts: [@import("../../input_parts.zig").max_parts]testing.MessagePart = @splat(.{ .bytes = "x" });
                try testing.settleTestActionParts(&storage, &tmp, binding, &parts);
                const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var view: testing.TestingPage = undefined;
                view.open(&storage, current);
                defer view.close();
                var settings: historical.HistoricalSettings = undefined;
                try view.settings(&settings);
                while (!try view.validateOutputsStep()) {}
                var position: u64 = 0;
                var entry_reads: usize = 0;
                const input = find_final: while (true) {
                    var bytes: usize = 64 * 1024;
                    var items: usize = 1024;
                    const progress = view.page.nextEntryStep(position, &bytes, &items) catch |err| {
                        try std.testing.expectEqual(error.PageRead, err);
                        try readBounded(&storage, &view.page, true);
                        entry_reads += 1;
                        continue;
                    };
                    switch (progress) {
                        .pending => continue,
                        .ready => |ready| {
                            const entry = ready orelse return error.MissingBackgroundFinal;
                            position = entry.position;
                            if (entry.kind == .tool_results) while (try view.nextToolResult()) |_| {};
                            if (entry.source_action) |source| {
                                try std.testing.expectEqual(selected.action_id, source.id);
                                break :find_final entry.input.?;
                            }
                        },
                    }
                };
                try std.testing.expect(entry_reads > 0);
                try std.testing.expect(input.value.reference.parts.length > 2048);
                if (damage_last) try testing.exec(&storage, "DELETE FROM content_part WHERE content_id=?1 AND ordinal=?2", .{ input.value.content_id, parts.len - 1 });
                try view.page.openMessage(input);
                var emitted: usize = 0;
                var part_reads: usize = 0;
                const corrupt = consume: while (true) {
                    const part = view.page.nextMessagePart() catch |err| {
                        try std.testing.expectEqual(error.PageRead, err);
                        readBounded(&storage, &view.page, false) catch |read_error| {
                            try std.testing.expectEqual(error.CorruptStore, read_error);
                            break :consume true;
                        };
                        part_reads += 1;
                        continue;
                    } orelse break :consume false;
                    try std.testing.expect(part.kind == .text);
                    try expectBytes(&view, part.content, "x");
                    emitted += 1;
                };
                try std.testing.expectEqual(damage_last, corrupt);
                try std.testing.expectEqual(@as(usize, if (damage_last) 0 else parts.len), emitted);
                try std.testing.expect(part_reads > 1);
                try std.testing.expectEqual(damage_last, storage.isFenced());
            }
        }
    }.run);
}
