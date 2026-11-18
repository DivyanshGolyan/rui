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
const json_text = [_]testing.MessagePart{.{ .bytes = "{\"text\":\"line\\nquote\\\"slash\\\\雪\",\"unicode\":\"\\u96ea\"}" }};
const legacy_mcp_image_json = [_]testing.MessagePart{.{ .bytes = "{\"content\":[{\"type\":\"image\",\"data\":\"iVBORw0KGgo=\",\"mimeType\":\"image/png\"}],\"isError\":false}" }};
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
        for ([_][]const testing.MessagePart{ &mixed, &images, &text, &json_text, &legacy_mcp_image_json }) |parts| {
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
            var public = try @import("../domain/public_parts.zig").Reader.init(session, .{ .action = selected.action_id });
            defer public.deinit();
            var ordinal: usize = 0;
            while (true) switch (try storage.readPublicParts(&public)) {
                .pending => {},
                .done => break,
                .part => |part| {
                    const expected = parts[ordinal];
                    try std.testing.expectEqual(@as(u32, @intCast(ordinal)), part.ordinal);
                    try std.testing.expectEqual(expected.kind == .image, part.kind == .image);
                    if (expected.kind == .image) if (expected.kind.image.assertion) |format| try std.testing.expectEqual(format, part.kind.image.media.format);
                    try std.testing.expectEqual(@as(u64, expected.bytes.len), part.location.reference.length);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(expected.bytes), &part.location.reference.digest);
                    var reader: @import("../domain/content.zig").ContentReader = undefined;
                    reader.open(part.location);
                    defer reader.close();
                    var offset: usize = 0;
                    var buffer: [257]u8 = undefined;
                    while (offset < expected.bytes.len) {
                        const count = try reader.read(offset, &buffer);
                        try std.testing.expect(count > 0);
                        try std.testing.expectEqualSlices(u8, expected.bytes[offset..][0..count], buffer[0..count]);
                        offset += count;
                    }
                    ordinal += 1;
                },
            };
            try std.testing.expectEqual(parts.len, ordinal);
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

test "Action settlement reports whether stop replaced text and parts" {
    try testing.forEachEngine(struct {
        fn run(engine: *testing.Case) !void {
            var digests: [records.len][32]u8 = undefined;
            const tool_set = hostToolSet(&digests);
            inline for ([_]tools.Runner{ .bash, .mcp }) |runner| {
                for ([_]u8{ 0, 1, 2, 3 }) |stop| {
                    for ([_]bool{ false, true }) |parts| {
                        var tmp = std.testing.tmpDir(.{});
                        defer tmp.cleanup();
                        var storage: core.Store = undefined;
                        try testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
                        defer storage.close() catch unreachable;
                        var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                        var configure = try testing.completeConfiguration("kept-config", "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
                        const name = if (runner == .bash) "bash" else "fetch_page";
                        configure.configuration.tools = try .of(&.{ name, "read_action", "stop_action" });
                        configure.configuration.permission_mode.state = .value;
                        try configure.configuration.permission_mode.value.set("bypass");
                        const session = (try storage.configure(&configure, .{})).accepted.session;
                        try testing.submitTestMessage(&storage, &tmp, "kept-input", "kept-message", session.slice(), "Run the tool.");
                        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        const arguments = if (runner == .bash) "{\"description\":\"Return parts\",\"cmd\":\"true\"}" else "{}";
                        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
                        defer std.testing.allocator.free(encoded);
                        try shared.settleCallsForTesting(&storage, &tmp, model, "kept-calls", &.{
                            .{ .item_id = "target-item", .name = name, .encoded_call_id = "target-call", .decoded_call_id = "target-call", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments },
                            .{ .item_id = "stop-item", .name = "stop_action", .encoded_call_id = "stop-call", .decoded_call_id = "stop-call", .encoded_arguments = "{\\\"action\\\":\\\"1\\\"}", .decoded_arguments = "{\"action\":\"1\"}" },
                        });
                        const selected = (try storage.nextAction(runner, .fromFree(2, true))).?;
                        const binding = (try storage.admitActionAttempt(selected, 300_000, .{})).?.permit.binding;
                        const direct = stop == 2 or stop == 3;
                        const session_stop = stop == 1 or stop == 3;
                        if (direct) {
                            const source = (try storage.nextCoreWork(.fromFree(2, true))).?.action;
                            const stopped = try storage.stopAction(source.binding, binding.action_id, .{});
                            try std.testing.expect(stopped == .selected);
                        }
                        if (session_stop) {
                            var command = try shared.completeSessionStop("kept-stop", session.slice());
                            try std.testing.expect(storage.stopSession(&command, .{}) == .accepted);
                        }
                        const settlement = if (parts)
                            try settlePartsForKept(&storage, &tmp, binding)
                        else
                            try storage.settleActionAttempt(binding, .succeeded, "original result", .{});
                        const expected_kept = !direct and (!session_stop or runner == .mcp);
                        try std.testing.expectEqual(expected_kept, settlement.kept);
                        try std.testing.expectEqual(if (stop != 0) action.ActionSettlement.Outcome.session_stop else .effect, settlement.outcome);
                        const content_id = try testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{binding.action_id});
                        const expected_code = if (expected_kept) "succeeded" else "cancelled";
                        try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ binding.action_id, expected_code }));
                        if (parts and expected_kept) {
                            try std.testing.expectEqual(@as(u64, mixed.len), try testing.queryU64(&storage, "SELECT count(*) FROM content_part WHERE content_id=?1", .{content_id}));
                            for (mixed, 0..) |part, ordinal| {
                                const part_id = try testing.queryU64(&storage, "SELECT part_content_id FROM content_part WHERE content_id=?1 AND ordinal=?2", .{ content_id, ordinal });
                                const reference = try shared.testingContentReference(&storage, part_id);
                                try std.testing.expectEqual(@as(u64, part.bytes.len), reference.length);
                                try std.testing.expectEqualSlices(u8, &protocol.contentDigest(part.bytes), &reference.digest);
                            }
                        } else {
                            const content = try shared.testingContentReference(&storage, content_id);
                            const expected = if (expected_kept) "original result" else if (direct) "Action was stopped." else "Cancelled by Session stop.";
                            try shared.expectContent(&storage, content, expected);
                        }
                    }
                }
            }
        }
    }.run);
}

fn settlePartsForKept(storage: *core.Store, tmp: *std.testing.TmpDir, binding: action.ActionAttemptBinding) !action.ActionSettlement {
    const Capture = @import("../../InputCapture.zig");
    var used: std.atomic.Value(u64) = .init(0);
    var capture: Capture = undefined;
    {
        const spool = try tmp.dir.createFile(std.testing.io, "kept-spool", .{ .read = true });
        errdefer spool.close(std.testing.io);
        const index = try tmp.dir.createFile(std.testing.io, "kept-index", .{ .read = true });
        errdefer index.close(std.testing.io);
        try tmp.dir.deleteFile(std.testing.io, "kept-spool");
        try tmp.dir.deleteFile(std.testing.io, "kept-index");
        capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 4 * 1024 * 1024 });
    }
    defer capture.close();
    for (mixed) |part| {
        try capture.begin(part.kind, part.bytes.len);
        var at: usize = 0;
        while (at < part.bytes.len) {
            var allowance = part.bytes.len - at;
            at += try capture.append(part.bytes[at..], &allowance, false);
        }
        try capture.end();
    }
    return storage.settleActionAttemptParts(binding, .succeeded, try capture.seal(), .{});
}

test "image floor retains whole inputs and tool group until overflow exhaustion" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: core.Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared.configureTestSessionWithMode(&storage, "image-floor-config", "bypass");
            try testing.submitTestMessageParts(&storage, &tmp, "image-floor-message", session.slice(), &.{
                .{ .bytes = "keep image" },
                .{ .bytes = png, .kind = .{ .image = .{} } },
            });
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]shared.TestingCall{.{
                .item_id = "floor-item",
                .name = "bash",
                .encoded_call_id = "floor-call",
                .decoded_call_id = "floor-call",
                .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"description\\\":\\\"Run command\\\"}",
                .decoded_arguments = "{\"cmd\":\"true\",\"description\":\"Run command\"}",
            }};
            try shared.settleCallsForTesting(&storage, &tmp, first, "floor-output", &calls);
            const selected = (try storage.nextAction(.bash, .fromFree(1, true))).?;
            const floor_action = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            try testing.settleTestActionParts(&storage, &tmp, floor_action, &.{
                .{ .bytes = "tool image" },
                .{ .bytes = png, .kind = .{ .image = .{} } },
            });
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            for (0..1) |_| {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(historical.ModelOperationKind.compaction, try storage.modelOperationKind(compact));
                {
                    var view: testing.TestingPage = undefined;
                    view.open(&storage, compact);
                    defer view.close();
                    var cursor: shared.TestingHistoryCursor = .{};
                    const message = (try cursor.next(&view)).?;
                    try std.testing.expectEqual(historical.HistoricalEntryKind.user, message.kind);
                    try view.page.openMessage(message.input.?);
                    try std.testing.expect((try view.nextMessagePart()).?.kind == .text);
                    const image = (try view.nextMessagePart()).?;
                    try std.testing.expect(image.kind == .image);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(png), &image.content.digest);
                    try std.testing.expect((try view.nextMessagePart()) == null);
                    try std.testing.expectEqual(historical.HistoricalEntryKind.provider_output, (try cursor.next(&view)).?.kind);
                    try std.testing.expectEqual(historical.HistoricalEntryKind.tool_results, (try cursor.next(&view)).?.kind);
                    const result = (try view.nextToolResult()).?;
                    try view.page.openMessage(result.input.?);
                    try std.testing.expect((try view.nextMessagePart()).?.kind == .text);
                    const tool_image = (try view.nextMessagePart()).?;
                    try std.testing.expect(tool_image.kind == .image);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(png), &tool_image.content.digest);
                    try std.testing.expect((try view.nextMessagePart()) == null);
                    try std.testing.expect((try view.nextToolResult()) == null);
                }
                try testing.settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try std.testing.expectEqual(@as(u64, 2), try testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='context_overflow'", .{}));
        }
    }.run);
}

fn expectOldTextView(storage: *core.Store, binding: core.AttemptBinding) !void {
    var view: testing.TestingPage = undefined;
    view.open(storage, binding);
    defer view.close();
    var settings: historical.HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expect(!view.page.compound_inputs);
    var position: u64 = 0;
    var users: usize = 0;
    var results: usize = 0;
    while (try view.nextEntry(position)) |entry| {
        position = entry.position;
        try std.testing.expect(entry.source_action == null);
        if (entry.kind == .user) {
            users += 1;
            try expectBytes(&view, entry.content.?, "Run the tool.");
        }
        if (entry.kind == .tool_results) {
            while (try view.nextToolResult()) |result| {
                results += 1;
                try expectBytes(&view, result.call_id, "parts-call");
                try std.testing.expect(result.input == null);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), users);
    try std.testing.expectEqual(@as(usize, 1), results);
}

test "old text operation retry excludes later image message and background final after reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var digests: [records.len][32]u8 = undefined;
            const tool_set = hostToolSet(&digests);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: core.Store = undefined;
            try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
            defer storage.close() catch unreachable;
            const session = try propose(&storage, &tmp, .mcp);
            const selected = (try storage.nextAction(.mcp, .fromFree(2, true))).?;
            const action_binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            var promotion: @import("../../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = selected.action_id };
            try promotion.key.set("old-text-promote");
            try std.testing.expect(storage.backgroundAction(.{ .command = &promotion }, .{}) == .accepted);
            const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try expectOldTextView(&storage, original);
            try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
            try testing.submitTestMessageParts(&storage, &tmp, "later-image", session.slice(), &images);
            try testing.settleTestActionParts(&storage, &tmp, action_binding, &mixed);
            try expectOldTextView(&storage, original);
            try storage.close();
            try testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
            try expectOldTextView(&storage, original);
            const retry = (try shared.admitRetryForTesting(&storage)).?.permit.binding;
            try std.testing.expectEqual(original.operation_id, retry.operation_id);
            try expectOldTextView(&storage, retry);
        }
    }.run);
}

test "public Message parts preserve ordered metadata and bytes" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: core.Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try testing.configureTestSession(&storage, "public-part-config");
            try testing.submitTestMessageParts(&storage, &tmp, "public-part-message", session.slice(), &mixed);
            const admission = try testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE session_ref=?1", .{session.slice()});
            var public = try @import("../domain/public_parts.zig").Reader.init(session, .{ .message = admission });
            defer public.deinit();
            var ordinal: usize = 0;
            while (true) switch (try storage.readPublicParts(&public)) {
                .pending => {},
                .done => break,
                .part => |part| {
                    const expected = mixed[ordinal];
                    try std.testing.expectEqual(@as(u32, @intCast(ordinal)), part.ordinal);
                    try std.testing.expectEqual(expected.kind == .image, part.kind == .image);
                    if (expected.kind == .image) try std.testing.expectEqual(expected.kind.image.assertion.?, part.kind.image.media.format);
                    try std.testing.expectEqual(@as(u64, expected.bytes.len), part.location.reference.length);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(expected.bytes), &part.location.reference.digest);
                    var reader: @import("../domain/content.zig").ContentReader = undefined;
                    reader.open(part.location);
                    defer reader.close();
                    var offset: usize = 0;
                    var buffer: [257]u8 = undefined;
                    while (offset < expected.bytes.len) {
                        const count = try reader.read(offset, &buffer);
                        try std.testing.expect(count > 0);
                        try std.testing.expectEqualSlices(u8, expected.bytes[offset..][0..count], buffer[0..count]);
                        offset += count;
                    }
                    ordinal += 1;
                },
            };
            try std.testing.expectEqual(mixed.len, ordinal);
        }
    }.run);
}

test "seed CLI mixed parts fixture" {
    const path = std.c.getenv("RUI_PARTS_SEED_DIR") orelse return;
    const directory = try std.Io.Dir.openDirAbsolute(std.testing.io, std.mem.span(path), .{});
    defer directory.close(std.testing.io);
    var tmp: std.testing.TmpDir = .{ .dir = directory, .parent_dir = .cwd(), .sub_path = @splat(0) };
    var storage: core.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, std.testing.io, &tools.built_in_tool_set);
    const session = try propose(&storage, &tmp, .bash);
    const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
    const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
    try testing.settleTestActionParts(&storage, &tmp, binding, &mixed);
    try testing.submitTestMessageParts(&storage, &tmp, "cli-mixed-message", session.slice(), &mixed);
    const admission = try testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"cli-mixed-message"});
    var output: [256]u8 = undefined;
    const receipt = try std.fmt.bufPrint(&output, "{{\"session\":\"{s}\",\"admission\":\"{d}\",\"action\":\"{d}\"}}\n", .{ session.slice(), admission, selected.action_id });
    try storage.close();
    try directory.writeFile(std.testing.io, .{ .sub_path = "parts-seed.json", .data = receipt });
}

test "public parts certify the complete manifest before the first part" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: core.Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try testing.configureTestSession(&storage, "public-corrupt-config");
            try testing.submitTestMessageParts(&storage, &tmp, "public-corrupt-message", session.slice(), &mixed);
            const admission = try testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"public-corrupt-message"});
            const content = try testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE admission_id=?1", .{admission});
            try testing.exec(&storage, "DELETE FROM content_part WHERE content_id=?1 AND ordinal=?2", .{ content, mixed.len - 1 });
            var reader = try @import("../domain/public_parts.zig").Reader.init(session, .{ .message = admission });
            defer reader.deinit();
            while (true) {
                const progress = storage.readPublicParts(&reader) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    try std.testing.expect(storage.isFenced());
                    return;
                };
                try std.testing.expect(progress == .pending);
            }
        }
    }.run);
}
