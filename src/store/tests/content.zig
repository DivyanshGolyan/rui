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

/// Tests use the production transaction runner and raw Content sink. The
/// range borrows its descriptor; importing never assumes its cleanup.
const ImportRange = struct {
    const transition = @import("../transition.zig");
    const custody = @import("../../content_custody.zig");
    pub const rounds = transition.rounds(.{ .lookup = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .lookup;
    pub const Input = struct { range: custody.Range, faults: store_core.Faults = .{} };
    pub const Result = u64;
    pub const Ordinary = error{};
    pub const Declined = error{};
    pub const Guards = error{};

    input: Input,
    value: content_domain.Import = undefined,
    id: u64 = 0,

    pub fn step(self: *ImportRange, r: *transition.Round(ImportRange), ran: ?rounds.At) !transition.Next(ImportRange) {
        if (ran == null) {
            self.value = .{ .length = self.input.range.length, .digest = self.input.range.digest, .private = false };
            content_domain.lookup(r, &self.value);
            return .{ .round = .lookup };
        }
        self.id = try content_domain.importRange(r, std.testing.io, self.input.range, &self.value, self.input.faults);
        return .commit;
    }

    pub fn committed(self: *const ImportRange) Result {
        return self.id;
    }
};

test "sealed Content ranges import original binary bytes once without taking capture custody" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Capture = @import("../../InputCapture.zig");
            const jpeg = @embedFile("../../testing/fixtures/input-baseline.jpg");
            const transition = @import("../transition.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var open = true;
            defer if (open) storage.close() catch unreachable;
            var used = std.atomic.Value(u64).init(29);
            var capture: Capture = undefined;
            {
                const spool = try tmp.dir.createFile(std.testing.io, "range-spool", .{ .read = true });
                errdefer spool.close(std.testing.io);
                try tmp.dir.deleteFile(std.testing.io, "range-spool");
                const index = try tmp.dir.createFile(std.testing.io, "range-index", .{ .read = true });
                errdefer index.close(std.testing.io);
                try tmp.dir.deleteFile(std.testing.io, "range-index");
                capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 8192 });
            }
            defer capture.close();
            for ([_][]const u8{ "prefix\x00", jpeg, jpeg, "suffix" }) |bytes| {
                const image = bytes[0] == 0xff;
                try capture.begin(if (image) .{ .image = .{ .assertion = .jpeg } } else .text, bytes.len);
                var allowance: usize = bytes.len;
                try std.testing.expectEqual(bytes.len, try capture.append(bytes, &allowance, false));
                try capture.end();
            }
            var cursor = (try capture.seal()).cursor();
            _ = try cursor.next();
            const first = (try cursor.next()).?;
            const second = (try cursor.next()).?;
            try std.testing.expect(first.range.offset != 0 and first.range.offset != second.range.offset);
            const before = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const charged = used.load(.acquire);
            const id = try transition.apply(&storage, ImportRange, .{ .range = first.range }, .{});
            try std.testing.expectEqual(id, try transition.apply(&storage, ImportRange, .{ .range = second.range }, .{}));
            try std.testing.expectEqual(before + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(charged, used.load(.acquire));
            _ = try cursor.next();
            try std.testing.expect((try cursor.next()) == null);
            capture.close();
            try std.testing.expectEqual(@as(u64, 29), used.load(.acquire));
            open = false;
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            open = true;
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(.{ .length = jpeg.len, .digest = protocol.contentDigest(jpeg) }));
            defer reader.close();
            var actual: [jpeg.len]u8 = undefined;
            try std.testing.expectEqual(jpeg.len, try reader.read(0, &actual));
            try std.testing.expectEqualSlices(u8, jpeg, &actual);
        }
    }.run);
}

test "sealed Content range failures roll back raw rows and leave descriptor custody with the caller" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const custody = @import("../../content_custody.zig");
            const transition = @import("../transition.zig");
            const Damage = enum { offset, overflow, sealed_length, changed_bytes, read_failure, write_failure };
            for ([_]bool{ false, true }) |existing| {
                for (std.enums.values(Damage)) |damage| {
                    // Deduplication verifies the input but writes no payload.
                    if (existing and damage == .write_failure) continue;
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const original = "prefix\x00raw\xffbytes!suffix";
                    const selected = original[7..17];
                    const file = try tmp.dir.createFile(std.testing.io, "range", .{ .read = true });
                    defer file.close(std.testing.io);
                    try tmp.dir.deleteFile(std.testing.io, "range");
                    try file.writePositionalAll(std.testing.io, original, 0);
                    var range: custody.Range = .{ .file = file, .offset = 7, .length = selected.len, .digest = protocol.contentDigest(selected), .sealed_length = original.len };
                    if (existing) _ = try transition.apply(&storage, ImportRange, .{ .range = range }, .{});
                    var faults: store_core.Faults = .{};
                    switch (damage) {
                        .offset => range.offset += 1,
                        .overflow => range.offset = std.math.maxInt(u64),
                        .sealed_length => range.sealed_length -= 1,
                        .changed_bytes => try file.writePositionalAll(std.testing.io, "?", range.offset),
                        .read_failure => faults.content_read = true,
                        .write_failure => faults.content_import = true,
                    }
                    const before = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                    const expected = switch (damage) {
                        .read_failure => error.InjectedContentReadFailure,
                        .write_failure => error.InjectedContentImportFailure,
                        else => error.ContentChanged,
                    };
                    try std.testing.expectError(expected, transition.apply(&storage, ImportRange, .{ .range = range, .faults = faults }, .{}));
                    try std.testing.expectEqual(before, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                    try std.testing.expect(storage.isFenced());
                    // The same live borrowed descriptor still belongs to this scope.
                    try std.testing.expectEqual(@as(u64, original.len), try file.length(std.testing.io));
                }
            }
        }
    }.run);
}

/// Each lookup follows the preceding insert in the same transaction, like
/// ordered input saving. The fixture retains only its current borrowed range.
const ImportSequence = struct {
    const transition = @import("../transition.zig");
    const capture = @import("../../InputCapture.zig");
    pub const rounds = transition.rounds(.{ .lookup = .{.paged} });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .lookup;
    pub const Input = capture.Loan;
    pub const Result = u64;
    pub const Ordinary = error{};
    pub const Declined = error{};
    pub const Guards = error{};

    input: Input,
    cursor: ?capture.Cursor = null,
    part: capture.Part = undefined,
    value: content_domain.Import = undefined,
    imported: u64 = 0,

    pub fn step(self: *ImportSequence, r: *transition.Round(ImportSequence), ran: ?rounds.At) !transition.Next(ImportSequence) {
        if (ran != null) {
            _ = try content_domain.importRange(r, std.testing.io, self.part.range, &self.value, .{});
            self.imported += 1;
        } else self.cursor = self.input.cursor();
        self.part = (try self.cursor.?.next()) orelse return .commit;
        self.value = .{ .length = self.part.range.length, .digest = self.part.range.digest, .private = false };
        content_domain.lookup(r, &self.value);
        return .{ .round = .lookup };
    }

    pub fn committed(self: *const ImportSequence) Result {
        return self.imported;
    }
};

test "sequential Content ranges exceed the small import memo and deduplicate within one transaction" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const capture_type = @import("../../InputCapture.zig");
            const transition = @import("../transition.zig");
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var used: std.atomic.Value(u64) = .init(0);
            var capture: capture_type = undefined;
            {
                const spool = try tmp.dir.createFile(std.testing.io, "sequence-spool", .{ .read = true });
                errdefer spool.close(std.testing.io);
                const index = try tmp.dir.createFile(std.testing.io, "sequence-index", .{ .read = true });
                errdefer index.close(std.testing.io);
                try tmp.dir.deleteFile(std.testing.io, "sequence-spool");
                try tmp.dir.deleteFile(std.testing.io, "sequence-index");
                capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 8192 });
            }
            defer capture.close();
            const bytes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 0, 7 };
            for (bytes) |byte| {
                try capture.begin(.text, 1);
                var allowance: usize = 1;
                try std.testing.expectEqual(@as(usize, 1), try capture.append(&.{byte}, &allowance, false));
                try capture.end();
            }
            const loan = try capture.seal();
            const before = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const charged = used.load(.acquire);
            try std.testing.expectEqual(@as(u64, bytes.len), try transition.apply(&storage, ImportSequence, loan, .{}));
            try std.testing.expectEqual(before + 8, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(charged, used.load(.acquire));
            capture.close();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            for (0..8) |index| {
                const expected = [_]u8{@intCast(index)};
                var reader: ContentReader = undefined;
                reader.open(try storage.openContent(.{ .length = 1, .digest = protocol.contentDigest(&expected) }));
                defer reader.close();
                var actual: [1]u8 = undefined;
                try std.testing.expectEqual(@as(usize, 1), try reader.read(0, &actual));
                try std.testing.expectEqualSlices(u8, &expected, &actual);
            }
        }
    }.run);
}
