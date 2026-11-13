//! Content Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const HistoricalReader = historical_domain.HistoricalReader;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const testingContent = shared_fixtures.testingContent;

test "content reader owns the bounded result-delivery window" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(@as(usize, 4096), protocol.content_window_bytes);
            try std.testing.expectEqual(
                @as(usize, 64 * 1024),
                ContentReader.content_window_bytes,
            );

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-window");
            var text: [ContentReader.content_window_bytes + 17]u8 = undefined;
            for (&text, 0..) |*byte, index| byte.* = @intCast(index % 251);
            try submitTestMessage(
                &storage,
                &tmp,
                "window-message-source",
                "window-message",
                session.slice(),
                &text,
            );
            const reference = (try store_testing.observeCommandForTesting(&storage, "window-message")).kind.message.?.content;
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(reference));
            defer reader.close();

            var window: [ContentReader.content_window_bytes]u8 = undefined;
            try std.testing.expectEqual(window.len, try reader.read(0, &window));
            try std.testing.expectEqualSlices(u8, text[0..window.len], &window);
            try std.testing.expectEqual(
                @as(usize, 17),
                try reader.read(window.len, &window),
            );
            try std.testing.expectEqualSlices(u8, text[window.len..], window[0..17]);
            try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &window));
            try std.testing.expectError(
                error.RangeOutOfBounds,
                reader.read(text.len + 1, &window),
            );
            try std.testing.expectError(error.WindowTooLarge, reader.read(0, &text));
        }
    }.run);
}

test "external content import follows sealed descriptor custody" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const captured = "captured instructions";
            const replacement = "pathname replacement";
            const file = try tmp.dir.createFile(std.testing.io, "ingress", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, captured);
            try file.sync(std.testing.io);
            try tmp.dir.deleteFile(std.testing.io, "ingress");
            var replacement_file = try tmp.dir.createFile(std.testing.io, "ingress", .{});
            try replacement_file.writeStreamingAll(std.testing.io, replacement);
            replacement_file.close(std.testing.io);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("sealed", "", workspace, "model-a");
            command.configuration.instructions = .{
                .state = .value,
                .file = file,
                .length = captured.len,
                .digest = protocol.contentDigest(captured),
            };
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const created_session_0_reply = try storage.configure(&command, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            const observation = try storage.inspectSessionForTesting(created_session_0.slice());
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(observation.instructions));
            defer reader.close();
            var bytes: [captured.len]u8 = undefined;
            try std.testing.expectEqual(captured.len, try reader.read(0, &bytes));
            try std.testing.expectEqualStrings(captured, &bytes);
        }
    }.run);
}

test "external content identity is verified before canonical commit" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const captured = "captured instructions";
            const file = try tmp.dir.createFile(std.testing.io, "changed", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, captured);
            try file.sync(std.testing.io);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("changed", "", workspace, "model-a");
            command.configuration.instructions = .{
                .state = .value,
                .file = file,
                .length = captured.len,
                .digest = protocol.contentDigest("different bytes"),
            };
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;

            try std.testing.expect(try storage.configure(&command, .{}) == .infrastructure_failure);
            try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "changed"));
        }
    }.run);
}

test "content verification failure rolls back new imports and deduplicated inputs" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            const Case = enum { digest, short, long, empty_digest, read_failure };
            inline for (.{ false, true }) |deduplicated| {
                inline for (std.meta.tags(Case)) |case| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                    const length: usize = if (case == .empty_digest) 0 else protocol.content_window_bytes * 2 + 17;

                    var initial = try completeConfiguration("initial", "", workspace, "model-a");
                    initial.configuration.instructions = try testingContent(&tmp, "original", 'a', length);
                    defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
                    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
                    if (deduplicated) {
                        const configured = try storage.configure(&initial, .{});
                        try std.testing.expect(configured == .accepted);
                        session = configured.accepted.session;
                    }
                    const content_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                    const command_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{});
                    const revision_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{});

                    var command = try completeConfiguration("invalid", session.slice(), workspace, "model-a");
                    command.configuration.instructions = try testingContent(&tmp, "invalid", 'b', length);
                    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                    const content = &command.configuration.instructions;
                    switch (case) {
                        .digest => {
                            // A dedup hit must check supplied bytes, not trust the claimed digest.
                            content.digest = initial.configuration.instructions.digest;
                        },
                        .short => content.length += 1,
                        .long => content.length -= 1,
                        .empty_digest => content.digest[0] ^= 1,
                        .read_failure => {
                            if (deduplicated) content.digest = initial.configuration.instructions.digest;
                        },
                    }
                    try std.testing.expect(try storage.configure(&command, .{ .content_read = case == .read_failure }) == .infrastructure_failure);
                    try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "invalid"));
                    try std.testing.expectEqual(content_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                    try std.testing.expectEqual(command_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                    try std.testing.expectEqual(revision_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
                    try std.testing.expectEqual(@as(u64, if (deduplicated) 1 else 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                }
            }
        }
    }.run);
}

test "content import reads once and rolls back sources that change during reading" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // A rerun reads its source again.
            if (case.rerun) return;
            const Probe = struct {
                const Change = enum { none, truncate, grow };
                var change: Change = .none;
                var bytes_read: usize = 0;

                fn read(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
                    const count = try std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
                    bytes_read += count;
                    if (offset == 0) switch (change) {
                        .none => {},
                        .truncate => file.setLength(std.testing.io, count) catch return error.Unexpected,
                        .grow => file.setLength(std.testing.io, protocol.content_window_bytes * 2 + 18) catch return error.Unexpected,
                    };
                    return count;
                }
            };
            for (std.meta.tags(Probe.Change)) |change| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var vtable = std.testing.io.vtable.*;
                vtable.fileReadPositional = Probe.read;
                storage.io.vtable = &vtable;
                Probe.change = change;
                Probe.bytes_read = 0;

                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var command = try completeConfiguration("read-probe", "", workspace, "model-a");
                const length = protocol.content_window_bytes * 2 + 17;
                command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
                defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                if (change == .none) {
                    const created_session_0_reply = try storage.configure(&command, .{});
                    try std.testing.expect(created_session_0_reply == .accepted);
                    const created_session_0 = created_session_0_reply.accepted.session;
                    try std.testing.expectEqual(length, Probe.bytes_read);
                    Probe.bytes_read = 0;
                    try command.key.set("deduplicated");
                    command.session = created_session_0;
                    try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
                    try std.testing.expectEqual(length, Probe.bytes_read);
                } else {
                    try std.testing.expect(try storage.configure(&command, .{}) == .infrastructure_failure);
                    try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "read-probe"));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                }
            }
        }
    }.run);
}

test "multiwindow content import and deduplication preserve all bytes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("first", "", workspace, "model-a");
            const length = protocol.content_window_bytes * 2 + 17;
            command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const created_session_0_reply = try storage.configure(&command, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            try command.key.set("second");
            command.session = created_session_0;
            try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
            const observation = try storage.inspectSessionForTesting(created_session_0.slice());
            try std.testing.expectEqual(@as(u64, 2), observation.revision);
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(observation.instructions));
            defer reader.close();
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            var offset: usize = 0;
            while (offset < length) {
                const count = try reader.read(offset, buffer[0..@min(buffer.len, length - offset)]);
                try std.testing.expect(count != 0);
                for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
                offset += count;
            }
            try std.testing.expectEqual(length, offset);
        }
    }.run);
}

test "large raw content opens without materializing its payload" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("large", "", workspace, "model-a");
            const length = 32 * 1024 * 1024 + 10;
            command.configuration.instructions = try testingContent(&tmp, "large-source", 'q', length);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const reference = ContentReference{
                .length = command.configuration.instructions.length,
                .digest = command.configuration.instructions.digest,
            };
            const created_session_0_reply = try storage.configure(&command, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(reference));
            defer reader.close();
            var first: [17]u8 = undefined;
            try std.testing.expectEqual(first.len, try reader.read(0, &first));
            for (first) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
            var last: [17]u8 = undefined;
            try std.testing.expectEqual(last.len, try reader.read(length - last.len, &last));
            for (last) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
        }
    }.run);
}

test "content readers hold no decode window" {
    try std.testing.expect(@sizeOf(ContentReader) <= 512);
    try std.testing.expect(@sizeOf(HistoricalReader) <= 1024);
}
