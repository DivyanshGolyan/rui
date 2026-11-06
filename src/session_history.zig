//! Atomic bounded Conversation preparation, distinct from one-pass opening.
const std = @import("std");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const protocol = @import("protocol.zig");
const View = @import("session_view.zig");

pub const item_bytes = 8192;
pub const max_scratch_bytes = item_bytes * protocol.public_conversation_page_items;

const Span = struct { offset: u64, length: u64 };
const Body = union(enum) {
    none,
    omitted,
    whole: Span,
    tool: struct { tail: Span, facts: View.ToolHeaderFacts },
};

/// Owns metadata; borrows unchanged scratch from successful prepare to render.
/// Preparation exposes no output or cursor; the caller commits after rendering.
pub const Prepared = struct {
    page: protocol_reply.ConversationPage,
    bodies: [protocol.public_conversation_page_items]Body = @splat(.none),

    /// The transcript matches live presentation; details show bounded raw tails.
    pub const Mode = enum { transcript, details };

    pub fn render(self: *const Prepared, io: std.Io, scratch: std.Io.File, store: []const u8, session: []const u8, sink: anytype, mode: Mode, colour: bool, home: []const u8) !void {
        var window: [protocol.content_window_bytes]u8 = undefined;
        var compact = false;
        for (0..self.page.count) |reverse| {
            const index = self.page.count - 1 - reverse;
            const item = self.page.items[index];
            if (item.sender) |sender| {
                try View.peerLine(sink, .inbound, sender, item.admitted_at.?, &compact);
                continue;
            }
            const prepared_body = self.bodies[index];
            if (prepared_body == .omitted) {
                var buffer: [192]u8 = undefined;
                compact = false;
                if (item.kind == .user) {
                    // Its line count is unknown without reading it.
                    try View.userPrefix(sink, colour, item.admitted_at.?);
                    try View.noteCollapsed(sink, collapsed(item));
                    try sink.feed(View.Mark.summary ++ "┄" ++ View.Mark.reset ++ "\n  " ++ View.Mark.summary);
                } else {
                    try sink.feed("\n");
                    try sink.feed(try std.fmt.bufPrint(&buffer, "Rui: Historical item omitted: position {d}, ordinal {d}, {d} raw bytes.\n", .{ item.position, item.ordinal, item.content.bytes }));
                }
                try writeExport(sink, store, session, item.position, item.ordinal);
                if (item.kind == .user) try sink.feed(View.Mark.reset);
                try sink.feed("\n");
                continue;
            }
            const Staged = struct {
                io: std.Io,
                scratch: std.Io.File,
                start: u64,
                bytes: u64,
                window: *[protocol.content_window_bytes]u8,
                pub fn read(staged: @This(), target: anytype) !void {
                    var offset: u64 = 0;
                    while (offset < staged.bytes) {
                        const wanted: usize = @intCast(@min(staged.bytes - offset, staged.window.len));
                        if (try staged.scratch.readPositionalAll(staged.io, staged.window[0..wanted], staged.start + offset) != wanted) return error.TruncatedHistoryScratch;
                        try target.feed(staged.window[0..wanted]);
                        offset += wanted;
                    }
                }
            };
            const span: Span = switch (prepared_body) {
                .whole => |span| span,
                .tool => |tool| tool.tail,
                .none => .{ .offset = 0, .length = 0 },
                .omitted => unreachable,
            };
            const staged: Staged = .{ .io = io, .scratch = scratch, .start = span.offset, .bytes = span.length, .window = &window };
            if ((item.kind == .tool_result or item.kind == .hosted_call) and mode == .transcript) {
                try View.toolResult(item.presentation.?, if (prepared_body == .tool) prepared_body.tool.facts else .{}, sink, colour, &compact);
                continue;
            }
            compact = false;
            switch (item.kind) {
                .hosted_call => try View.toolHeading(item.presentation.?, sink, colour, true),
                .tool_result => {
                    try View.toolResult(item.presentation.?, prepared_body.tool.facts, sink, colour, &compact);
                    compact = false;
                    if (item.content.bytes > span.length) try sink.feed("  Earlier output omitted\n");
                    try sink.feed("  ");
                    var indented: View.Indented(@TypeOf(sink)) = .{ .sink = sink };
                    var escaped: View.Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .multiline } };
                    try staged.read(&escaped);
                    try escaped.finish();
                    try indented.finish();
                    try sink.feed("\n  ");
                    try writeExport(sink, store, session, item.position, item.ordinal);
                },
                .user => {
                    try View.userPrefix(sink, colour, item.admitted_at.?);
                    var body: View.UserBody(@TypeOf(sink)) = undefined;
                    try body.init(sink, item.content.bytes, mode == .details);
                    try staged.read(&body);
                    if (try body.finish()) try View.noteCollapsed(sink, collapsed(item));
                },
                .assistant => {
                    try sink.feed("\n");
                    var answer: View.Answer(@TypeOf(sink)) = undefined;
                    answer.init(sink, home);
                    try staged.read(&answer);
                    try answer.finish();
                },
            }
            try sink.feed("\n");
        }
    }
};

fn collapsed(item: protocol_reply.ConversationPage.Item) View.Collapsed {
    return .{ .source = .conversation, .position = item.position, .ordinal = item.ordinal, .content = .{ .length = item.content.bytes, .digest = item.content.digest }, .row = true };
}

/// The command that exports one conversation row's exact bytes.
pub fn writeExport(sink: anytype, store: []const u8, session: []const u8, position: u64, ordinal: u64) !void {
    var buffer: [64]u8 = undefined;
    try sink.feed("Raw export: rui session read-conversation --store-hex ");
    try writeHex(sink, store);
    try sink.feed(" --session ");
    try sink.feed(session);
    try sink.feed(try std.fmt.bufPrint(&buffer, " --position {d} --ordinal {d}", .{ position, ordinal }));
}

pub fn prepare(requests: client.Requests, store: []const u8, session: []const u8, cursor: protocol_reply.ConversationCursor, scratch: std.Io.File) !Prepared {
    const page = switch (try requests.conversationPage(store, session, cursor)) {
        .page => |value| value,
        .failure => |failure| return requests.failRead(failure),
    };
    const Source = struct {
        requests: client.Requests,
        store: []const u8,
        session: []const u8,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, _: usize, sink: anytype) !void {
            if (try self.requests.readConversationContent(self.store, self.session, item.position, item.ordinal, item.content, sink)) |failure| return self.requests.failRead(failure);
        }
    };
    return stagePage(requests.io, page, scratch, Source{ .requests = requests, .store = store, .session = session });
}

// The source authenticates the complete result, including discarded prefixes.
// After all writes, scratch is checked against independently received retained bytes.
fn stagePage(io: std.Io, page: protocol_reply.ConversationPage, scratch: std.Io.File, source: anytype) !Prepared {
    var prepared: Prepared = .{ .page = page };
    try scratch.setLength(io, 0);
    const Staging = struct {
        io: std.Io,
        file: std.Io.File,
        start: u64,
        total: u64,
        skip: u64,
        received: u64 = 0,
        retained: u64 = 0,
        hash: std.crypto.hash.sha2.Sha256 = protocol.contentHasher(),
        header: View.ToolHeaderScan = .{},

        pub fn feed(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.total - self.received) return error.ContentBindingMismatch;
            try self.header.feed(bytes);
            const discard: usize = @intCast(@min(bytes.len, self.skip -| self.received));
            const tail = bytes[discard..];
            self.hash.update(tail);
            if (tail.len != 0) try self.file.writePositionalAll(self.io, tail, self.start + self.retained);
            self.received += bytes.len;
            self.retained += tail.len;
        }
    };
    var end: u64 = 0;
    var expected_digests: [protocol.public_conversation_page_items][32]u8 = undefined;
    for (page.items[0..page.count], 0..) |item, index| {
        if (item.kind == .hosted_call or item.sender != null) continue;
        const tool = item.kind == .tool_result;
        if (!tool and item.content.bytes > item_bytes) {
            prepared.bodies[index] = .omitted;
            continue;
        }
        const length = @min(item.content.bytes, item_bytes);
        var staging: Staging = .{ .io = io, .file = scratch, .start = end, .total = item.content.bytes, .skip = item.content.bytes - length };
        try source.read(item, index, &staging);
        if (staging.received != item.content.bytes) return error.ContentBindingMismatch;
        std.debug.assert(staging.retained == length);
        expected_digests[index] = if (tool) staging.hash.finalResult() else item.content.digest;
        const span: Span = .{ .offset = end, .length = length };
        prepared.bodies[index] = if (tool) .{ .tool = .{ .tail = span, .facts = staging.header.facts(item.presentation.?.code) } } else .{ .whole = span };
        end += length;
        std.debug.assert(end <= max_scratch_bytes);
    }
    var window: [protocol.content_window_bytes]u8 = undefined;
    for (prepared.bodies[0..page.count], 0..) |body, index| {
        const span = switch (body) {
            .whole => |span| span,
            .tool => |tool| tool.tail,
            .none, .omitted => continue,
        };
        var hash = protocol.contentHasher();
        var offset: u64 = 0;
        while (offset < span.length) {
            const wanted: usize = @intCast(@min(span.length - offset, window.len));
            if (try scratch.readPositionalAll(io, window[0..wanted], span.offset + offset) != wanted) return error.TruncatedHistoryScratch;
            hash.update(window[0..wanted]);
            offset += wanted;
        }
        if (!std.mem.eql(u8, &hash.finalResult(), &expected_digests[index])) return error.ContentBindingMismatch;
    }
    return prepared;
}

fn writeHex(sink: anytype, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var used: usize = 0;
    for (bytes) |byte| {
        const encoded = std.fmt.bytesToHex([1]u8{byte}, .lower);
        @memcpy(buffer[used..][0..2], &encoded);
        used += 2;
        if (used == buffer.len) {
            try sink.feed(&buffer);
            used = 0;
        }
    }
    if (used != 0) try sink.feed(buffer[0..used]);
}

test "historical export preserves hex Store escaping and canonical Session IDs" {
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        length: usize = 0,
        positions: [4]u64 = undefined,
        notes: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
        pub fn collapsed(self: *@This(), value: View.Collapsed) !void {
            try std.testing.expect(value.source == .conversation and value.row);
            self.positions[self.notes] = value.position;
            self.notes += 1;
        }
    };
    // A User item is a collapsed user block with nothing else known, which
    // Ctrl-O opens; a peer's is its line alone. Others keep their notice.
    var prepared: Prepared = .{ .page = .{ .end = 4, .count = 3, .more = false } };
    var sender: protocol.NamedPeer = .{ .session = .{} };
    try sender.session.set("k7m2qx");
    prepared.page.items[0] = .{ .position = 4, .ordinal = 0, .kind = .user, .content = .{ .bytes = 8200, .digest = @splat(0) }, .admitted_at = 1_800_000_000, .sender = sender };
    prepared.page.items[1] = .{ .position = 3, .ordinal = 0, .kind = .assistant, .content = .{ .bytes = 8193, .digest = @splat(0) } };
    prepared.page.items[2] = .{ .position = 2, .ordinal = 0, .kind = .user, .content = .{ .bytes = 9000, .digest = @splat(0) }, .admitted_at = 1_800_000_000 };
    prepared.bodies[1] = .omitted;
    prepared.bodies[2] = .omitted;
    var sink: Sink = .{};
    try prepared.render(std.testing.io, std.Io.File.stdin(), "/tmp/a'$(false)\x1b[2J\né\u{202e}", "09azvw", &sink, .details, false, "");
    try std.testing.expectEqualSlices(u64, &.{2}, sink.positions[0..sink.notes]);
    // Independent UTF-8 byte-to-hex oracle for Store controls and directional text.
    const identity = " --store-hex 2f746d702f6127242866616c7365291b5b324a0ac3a9e280ae --session 09azvw";
    var time: [5]u8 = undefined;
    var expected: [1024]u8 = undefined;
    const clock = View.clock(1_800_000_000, &time).?;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "\n› \x1b[8m{s}\x1b[0m\x1b[2;8m┄\x1b[0m\n  \x1b[2;8mRaw export: rui session read-conversation{s} --position 2 --ordinal 0\x1b[0m\n" ++
        "\nRui: Historical item omitted: position 3, ordinal 0, 8193 raw bytes.\nRaw export: rui session read-conversation{s} --position 3 --ordinal 0\n" ++
        "\n\x1b[2;8m← Received message from k7m2qx\x1b[8m{s}\x1b[0m\n", .{ clock, identity, identity, clock }), sink.bytes[0..sink.length]);
}

test "history tool tails are exact bounded suffixes and transcript headers only" {
    const Sink = struct {
        bytes: [32 * 1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const Bytes = struct {
        body: []const u8,
        chunk: usize,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, _: usize, sink: anytype) !void {
            var hash = protocol.contentHasher();
            var offset: usize = 0;
            while (offset < self.body.len) {
                const end = @min(self.body.len, offset + self.chunk);
                hash.update(self.body[offset..end]);
                try sink.feed(self.body[offset..end]);
                offset = end;
            }
            if (self.body.len != item.content.bytes or !std.mem.eql(u8, &hash.finalResult(), &item.content.digest)) return error.ContentBindingMismatch;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    var bytes: [25_000]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    const first = "Bash failed. Exit code: 7.\nProcess-group signaling reported a failure.\nstdout tail:\n";
    @memcpy(bytes[0..first.len], first);
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Compile package");
    for (std.enums.values(protocol.ToolPresentation.Code)) |code| {
        for ([_]usize{ 0, 1, 8191, 8192, 8193, 16384, bytes.len }) |size| {
            for ([_]usize{ 1, 4095, 4096, 8191, 8192, 20_000 }) |chunk| {
                var page: protocol_reply.ConversationPage = .{ .end = 7, .count = 1, .more = false };
                page.items[0] = .{ .position = 7, .ordinal = 2, .kind = .tool_result, .content = .{ .bytes = size, .digest = protocol.contentDigest(bytes[0..size]) }, .presentation = .{ .description = description, .code = code, .publication_position = 7 } };
                const prepared = try stagePage(io, page, scratch, Bytes{ .body = bytes[0..size], .chunk = chunk });
                const retained = @min(size, item_bytes);
                const span = prepared.bodies[0].tool.tail;
                try std.testing.expectEqual(retained, span.length);
                var staged: [8192]u8 = undefined;
                try std.testing.expectEqual(retained, try scratch.readPositionalAll(io, staged[0..retained], span.offset));
                try std.testing.expectEqualSlices(u8, bytes[size - retained .. size], staged[0..retained]);
                var extra: [1]u8 = undefined;
                try std.testing.expectEqual(@as(usize, 0), try scratch.readPositionalAll(io, &extra, retained));
                var sink: Sink = .{};
                try prepared.render(io, scratch, "store", "09azvw", &sink, .transcript, false, "");
                var heading: Sink = .{};
                var compact = false;
                try View.toolResult(page.items[0].presentation.?, .{ .exit = if (code == .failed and size >= first.len) 7 else null }, &heading, false, &compact);
                try std.testing.expectEqualStrings(heading.bytes[0..heading.length], sink.bytes[0..sink.length]);
                sink.length = 0;
                try prepared.render(io, scratch, "store", "09azvw", &sink, .details, false, "");
                const output = sink.bytes[0..sink.length];
                try std.testing.expect(std.mem.startsWith(u8, output, heading.bytes[0..heading.length]));
                try std.testing.expectEqual(size > item_bytes, std.mem.indexOf(u8, output, "Earlier output omitted") != null);
                try std.testing.expect(std.mem.indexOf(u8, output, "Historical item omitted") == null);
                try std.testing.expect(std.mem.endsWith(u8, output, "Raw export: rui session read-conversation --store-hex 73746f7265 --session 09azvw --position 7 --ordinal 2\n"));
                var expected: Sink = .{};
                try expected.feed(heading.bytes[0..heading.length]);
                if (size > item_bytes) try expected.feed("  Earlier output omitted\n");
                try expected.feed("  ");
                var line_start = false;
                for (bytes[size - retained .. size]) |byte| {
                    if (line_start and byte != '\n') try expected.feed("  ");
                    line_start = byte == '\n';
                    try expected.feed(&.{byte});
                }
                try expected.feed("\n  Raw export: rui session read-conversation --store-hex 73746f7265 --session 09azvw --position 7 --ordinal 2\n");
                try std.testing.expectEqualStrings(expected.bytes[0..expected.length], output);
            }
        }
    }
}

test "history mixed retained spans respect the page scratch ceiling" {
    const Bytes = struct {
        bodies: [protocol.public_conversation_page_items][]const u8,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, index: usize, sink: anytype) !void {
            const body = self.bodies[index];
            try sink.feed(body);
            if (body.len != item.content.bytes or !std.mem.eql(u8, &protocol.contentDigest(body), &item.content.digest)) return error.ContentBindingMismatch;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    const large = &@as([20_000]u8, @splat('x'));
    for ([_]bool{ false, true }) |mixed| {
        var page: protocol_reply.ConversationPage = .{ .end = 16, .count = 16, .more = false };
        var source: Bytes = undefined;
        var expected: u64 = 0;
        for (page.items[0..page.count], &source.bodies, 0..) |*item, *body, index| {
            const kind: @FieldType(protocol_reply.ConversationPage.Item, "kind") = if (!mixed or index % 4 == 0) .tool_result else if (index % 4 == 1) .user else .assistant;
            body.* = if (!mixed or index % 4 < 2) large else if (index % 4 == 2) "" else "answer";
            item.* = .{ .position = 16 - index, .ordinal = 0, .kind = kind, .content = .{ .bytes = body.len, .digest = protocol.contentDigest(body.*) }, .admitted_at = if (kind == .user) 1_800_000_000 else null, .presentation = if (kind == .tool_result) .{ .description = null, .code = .succeeded, .publication_position = 16 - index } else null };
        }
        const prepared = try stagePage(io, page, scratch, source);
        for (prepared.bodies, source.bodies) |body, raw| {
            const span = switch (body) {
                .tool => |tool| tool.tail,
                .whole => |span| span,
                .omitted => continue,
                .none => return error.MissingPreparedBody,
            };
            try std.testing.expectEqual(expected, span.offset);
            expected += span.length;
            var staged: [8192]u8 = undefined;
            const length: usize = @intCast(span.length);
            try std.testing.expectEqual(length, try scratch.readPositionalAll(io, staged[0..length], span.offset));
            try std.testing.expectEqualSlices(u8, raw[raw.len - length ..], staged[0..length]);
        }
        try std.testing.expectEqual(if (mixed) @as(u64, 4 * (8192 + 6)) else max_scratch_bytes, expected);
        var extra: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try scratch.readPositionalAll(io, &extra, expected));
    }
}

test "history reopened transcript keeps only the failed numeric header" {
    const Sink = struct {
        bytes: [1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const Bytes = struct {
        fn read(_: @This(), item: protocol_reply.ConversationPage.Item, _: usize, sink: anytype) !void {
            const body = "Bash failed. Exit code: 7.\nstdout tail:\nuseful diagnostic B\nstderr tail:\n\n";
            if (body.len != item.content.bytes or !std.mem.eql(u8, &protocol.contentDigest(body), &item.content.digest)) return error.ContentBindingMismatch;
            try sink.feed(body);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    const result = "Bash failed. Exit code: 7.\nstdout tail:\nuseful diagnostic B\nstderr tail:\n\n";
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Run check");
    var page: protocol_reply.ConversationPage = .{ .end = 7, .count = 1, .more = false };
    page.items[0] = .{ .position = 7, .ordinal = 2, .kind = .tool_result, .content = .{ .bytes = result.len, .digest = protocol.contentDigest(result) }, .presentation = .{ .description = description, .code = .failed, .publication_position = 7 } };
    const prepared = try stagePage(io, page, scratch, Bytes{});
    var sink: Sink = .{};
    try prepared.render(io, scratch, "store", "09azvw", &sink, .transcript, false, "");
    try std.testing.expectEqualStrings("\n  ! Run check — Failed (exit 7)\n", sink.bytes[0..sink.length]);
}

test "history preparation binds wire and staged bytes before exposure" {
    const Peer = struct {
        var clients: [2]std.posix.fd_t = undefined;
        var fault_offset: u64 = 0;
        var fault_hits: usize = 0;
        const large_body = @as([4096]u8, @splat('a')) ++ "Z";
        var connected: usize = 0;
        var mode: enum { intact, corrupt, missing, short_wire, wrong_domain, extra_wire } = .intact;
        var failure: ?anyerror = null;
        fn connect(_: ?*anyopaque, _: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
            defer connected += 1;
            return clients[connected];
        }
        fn stage(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            if (mode == .missing and offset == fault_offset) {
                fault_hits += 1;
                var count = header.len;
                for (data[0 .. data.len - 1]) |bytes| count += bytes.len;
                return count + data[data.len - 1].len * splat;
            }
            const count = try std.testing.io.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
            if (mode == .corrupt and offset == fault_offset) {
                fault_hits += 1;
                _ = try std.testing.io.vtable.fileWritePositional(userdata, file, "", &.{"X"}, 1, offset);
            }
            return count;
        }
        fn serve(fds: []const std.posix.fd_t) void {
            exchange(fds) catch |err| {
                failure = err;
            };
        }
        fn exchange(fds: []const std.posix.fd_t) !void {
            // Independent Python hashlib oracle for domain-prefixed "first".
            const metadata = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"2\",\"items\":[{\"position\":\"2\",\"ordinal\":\"0\",\"kind\":\"user\",\"admitted_at\":\"1\",\"content\":{\"bytes\":\"5\",\"sha256\":\"2e37afae3fe85c8c30175c6f0a1b578b3cbe5f4482248f77cb55656781d2790b\",\"display\":\"omitted\"}}],\"more\":false}";
            const bodies = [_][]const u8{ metadata, "first" };
            for (fds, 0..) |fd, index| {
                const normal_body = bodies[index];
                const content_type = if (index == 0) "application/json" else "application/octet-stream";
                const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
                defer file.close(std.testing.io);
                var head: [512]u8 = undefined;
                var used: usize = 0;
                while (!std.mem.endsWith(u8, head[0..used], "\r\n\r\n")) {
                    if (used == head.len or std.posix.system.read(fd, head[used..].ptr, 1) != 1) return error.TestRequestTruncated;
                    used += 1;
                }
                const marker = "Content-Length: ";
                const start = (std.mem.indexOf(u8, head[0..used], marker) orelse return error.TestRequestTruncated) + marker.len;
                const end = start + (std.mem.indexOf(u8, head[start..used], "\r\n") orelse return error.TestRequestTruncated);
                var remaining = try std.fmt.parseInt(usize, head[start..end], 10);
                var buffer: [4608]u8 = undefined;
                while (remaining != 0) {
                    const count = std.posix.system.read(fd, &buffer, @min(buffer.len, remaining));
                    if (count <= 0) return error.TestRequestTruncated;
                    remaining -= @intCast(count);
                }
                var wrong_metadata = metadata.*;
                if (mode == .wrong_domain) {
                    const digest_start = (std.mem.indexOf(u8, &wrong_metadata, "2e37afae") orelse unreachable);
                    @memcpy(wrong_metadata[digest_start..][0..64], "a7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e");
                }
                const body = if (index == 0 and mode == .wrong_domain) &wrong_metadata else if (index == 1 and mode == .short_wire) "firs" else normal_body;
                const response = try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\n\r\n", .{ content_type, body.len, body.len, body.len });
                @memcpy(buffer[response.len..][0..body.len], body);
                var length = response.len + body.len;
                if (index == 1 and mode == .extra_wire) {
                    buffer[length] = '!';
                    length += 1;
                }
                try file.writeStreamingAll(std.testing.io, buffer[0..length]);
            }
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    vtable.fileWritePositional = Peer.stage;
    const requests: client.Requests = .{ .io = .{ .userdata = io.userdata, .vtable = &vtable } };
    const Case = struct { mode: @TypeOf(Peer.mode), large: bool = false, empty_second: bool = false, fault_offset: u64 = 0 };
    for ([_]Case{
        .{ .mode = .intact },
        .{ .mode = .corrupt },
        .{ .mode = .missing },
        .{ .mode = .short_wire },
        .{ .mode = .wrong_domain },
        .{ .mode = .extra_wire },
        .{ .mode = .intact, .large = true },
        .{ .mode = .corrupt, .large = true, .fault_offset = 4096 },
        .{ .mode = .corrupt, .large = true, .fault_offset = 4097 },
        .{ .mode = .missing, .large = true, .fault_offset = 4097 },
        // Empty item cannot extend the file and mask the dropped boundary byte.
        .{ .mode = .missing, .large = true, .empty_second = true, .fault_offset = 4096 },
        .{ .mode = .intact, .large = true, .empty_second = true },
    }) |case| {
        const mode = case.mode;
        Peer.mode = mode;
        Peer.fault_offset = case.fault_offset;
        Peer.fault_hits = 0;
        Peer.connected = 0;
        Peer.failure = null;
        const supplied = case.large or mode == .corrupt or mode == .missing;
        const exchanges: usize = if (supplied) 0 else 2;
        var servers: [2]std.posix.fd_t = undefined;
        for (Peer.clients[0..exchanges], servers[0..exchanges]) |*caller, *server| {
            var sockets: [2]std.posix.fd_t = undefined;
            if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) return error.SocketPairFailed;
            caller.* = sockets[0];
            server.* = sockets[1];
        }
        const peer = if (supplied) null else try std.Thread.spawn(.{}, Peer.serve, .{servers[0..exchanges]});
        const Bytes = struct {
            bodies: [2][]const u8,
            fn read(self: @This(), item: protocol_reply.ConversationPage.Item, index: usize, sink: anytype) !void {
                const body = self.bodies[index];
                var offset: usize = 0;
                while (offset < body.len) {
                    const end = @min(body.len, offset + protocol.content_window_bytes);
                    try sink.feed(body[offset..end]);
                    offset = end;
                }
                if (body.len != item.content.bytes or !std.mem.eql(u8, &protocol.contentDigest(body), &item.content.digest)) return error.ContentBindingMismatch;
            }
        };
        const bytes: Bytes = .{ .bodies = .{ if (case.large) Peer.large_body else "first", if (case.empty_second) "" else "end" } };
        var page: protocol_reply.ConversationPage = .{ .end = 2, .count = if (case.large) 2 else 1, .more = false };
        for (page.items[0..page.count], 0..) |*item, index| {
            item.* = .{ .position = 2 - index, .ordinal = 0, .kind = if (index == 0) .user else .assistant, .content = .{ .bytes = bytes.bodies[index].len, .digest = undefined } };
            // Independent hashlib oracles, not the staging implementation.
            _ = try std.fmt.hexToBytes(&item.content.digest, if (index == 0)
                (if (case.large) "c4507c75ffffb20c21aad1b5eecab12e273533475e6d3204a866471d86c5a3cb" else "2e37afae3fe85c8c30175c6f0a1b578b3cbe5f4482248f77cb55656781d2790b")
            else if (case.empty_second) "11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528" else "743b6084710002f2040770ad1e35947dce27acfb1b5c6d3a1ddc28f74b462972");
        }
        const result = if (supplied) stagePage(requests.io, page, scratch, bytes) else prepare(requests, root, "09azvw", .{ .end = 2 }, scratch);
        // Release any request never reached after an earlier protocol failure.
        for (Peer.clients[Peer.connected..exchanges]) |fd| {
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            file.close(io);
        }
        if (peer) |thread| thread.join();
        if (Peer.failure) |err| {
            _ = try result;
            return err;
        }
        if (mode == .corrupt or mode == .missing) try std.testing.expectEqual(@as(usize, 1), Peer.fault_hits);
        try std.testing.expectEqual(exchanges, Peer.connected);
        if (mode == .intact) {
            const prepared = try result;
            try std.testing.expectEqual(@as(usize, if (case.large) 2 else 1), prepared.page.count);
            try std.testing.expectEqual(@as(u64, 0), prepared.bodies[0].whole.offset);
            if (case.large) try std.testing.expectEqual(@as(u64, 4097), prepared.bodies[1].whole.offset);
            var staged: [4100]u8 = undefined;
            const wanted: usize = if (case.large) (if (case.empty_second) 4097 else 4100) else 5;
            try std.testing.expectEqual(wanted, try scratch.readPositionalAll(io, staged[0..wanted], 0));
            var tail: [1]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 0), try scratch.readPositionalAll(io, &tail, wanted));
            try std.testing.expectEqualStrings(if (case.large) Peer.large_body else "first", staged[0..if (case.large) 4097 else 5]);
            if (case.large) try std.testing.expectEqualStrings(if (case.empty_second) "" else "end", staged[4097..wanted]);
            for (prepared.page.items[0..prepared.page.count], prepared.bodies[0..prepared.page.count]) |item, body| {
                try std.testing.expectEqualSlices(u8, &item.content.digest, &protocol.contentDigest(staged[@intCast(body.whole.offset)..][0..@intCast(item.content.bytes)]));
            }
        } else {
            const err = if (result) |_| return error.UnverifiedHistoryExposed else |err| err;
            try std.testing.expectEqual(@as(anyerror, switch (mode) {
                .corrupt, .short_wire, .wrong_domain => error.ContentBindingMismatch,
                .missing => error.TruncatedHistoryScratch,
                .extra_wire => error.InvalidResponse,
                .intact => unreachable,
            }), err);
        }
    }
}

test "history tool suffix authenticates discarded prefixes through the production reader" {
    const Peer = struct {
        var client_fd: std.posix.fd_t = undefined;
        var failure: ?anyerror = null;
        fn connect(_: ?*anyopaque, _: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
            return client_fd;
        }
        fn serve(fd: std.posix.fd_t, body: []const u8, declared: usize, extra: bool) void {
            exchange(fd, body, declared, extra) catch |err| {
                failure = err;
            };
        }
        fn exchange(fd: std.posix.fd_t, body: []const u8, declared: usize, extra: bool) !void {
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            defer file.close(std.testing.io);
            var head: [512]u8 = undefined;
            var used: usize = 0;
            while (!std.mem.endsWith(u8, head[0..used], "\r\n\r\n")) {
                if (used == head.len or std.posix.system.read(fd, head[used..].ptr, 1) != 1) return error.TestRequestTruncated;
                used += 1;
            }
            const marker = "Content-Length: ";
            const start = (std.mem.indexOf(u8, head[0..used], marker) orelse return error.TestRequestTruncated) + marker.len;
            const end = start + (std.mem.indexOf(u8, head[start..used], "\r\n") orelse return error.TestRequestTruncated);
            var remaining = try std.fmt.parseInt(usize, head[start..end], 10);
            var buffer: [512]u8 = undefined;
            while (remaining != 0) {
                const count = std.posix.system.read(fd, &buffer, @min(buffer.len, remaining));
                if (count <= 0) return error.TestRequestTruncated;
                remaining -= @intCast(count);
            }
            const response = try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\n\r\n", .{ declared, declared, declared });
            try file.writeStreamingAll(std.testing.io, response);
            try file.writeStreamingAll(std.testing.io, body);
            if (extra) try file.writeStreamingAll(std.testing.io, "!");
        }
    };
    const Sink = struct {
        bytes: [256]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
        pub fn item(_: *@This(), _: protocol.ActivityItem) void {}
        pub fn drew(_: *@This(), _: u64) void {}
        pub fn excluding(_: *@This(), _: u64) void {}
    };
    const Source = struct {
        requests: client.Requests,
        root: []const u8,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, _: usize, sink: anytype) !void {
            if (try self.requests.readConversationContent(self.root, "09azvw", item.position, item.ordinal, item.content, sink)) |failure| return self.requests.failRead(failure);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    const requests: client.Requests = .{ .io = .{ .userdata = io.userdata, .vtable = &vtable } };
    const Mode = enum { intact, prefix_corrupt, suffix_corrupt, short_length, truncated_prefix, truncated_suffix, extra_wire, wrong_domain };
    for (std.enums.values(Mode)) |mode| {
        for ([_]enum { history, opening, live }{ .history, .opening, .live }) |surface| {
            var body: [20000]u8 = undefined;
            for (&body, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
            var page: protocol_reply.ConversationPage = .{ .end = 1, .count = 1, .more = false };
            var digest: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&digest, "3454d6c62d0382f332ea5ad1beb91dbdb4afc500f4f3fcadc364d393b890e711");
            if (mode == .wrong_domain) std.crypto.hash.sha2.Sha256.hash(&body, &digest, .{});
            page.items[0] = .{ .position = 1, .ordinal = 0, .kind = .tool_result, .content = .{ .bytes = body.len, .digest = digest }, .presentation = .{ .description = null, .code = .failed, .publication_position = 1 } };
            if (mode == .prefix_corrupt) body[0] = '!';
            if (mode == .suffix_corrupt) body[body.len - 1] = '!';
            var sockets: [2]std.posix.fd_t = undefined;
            if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) return error.SocketPairFailed;
            Peer.client_fd = sockets[0];
            Peer.failure = null;
            const length: usize = switch (mode) {
                .short_length => 0,
                .truncated_prefix => 100,
                .truncated_suffix => body.len - 1,
                else => body.len,
            };
            const peer = try std.Thread.spawn(.{}, Peer.serve, .{ sockets[1], body[0..length], if (mode == .short_length) body.len - 1 else body.len, mode == .extra_wire });
            var sink: Sink = .{};
            var compact = false;
            var activity: protocol_reply.ActivityPage = .{ .facts = .{ .end = 1, .count = 1, .direction = if (surface == .opening) .backward else .forward } };
            activity.facts.items[0] = .{ .position = 1, .at = 1, .value = .{ .tool_result = .{ .content = .{ .length = body.len, .digest = digest }, .presentation = page.items[0].presentation.? } } };
            const result: anyerror!void = if (surface == .history) blk: {
                _ = stagePage(requests.io, page, scratch, Source{ .requests = requests, .root = root }) catch |err| break :blk err;
                break :blk {};
            } else blk: {
                _ = View.render(requests, root, "09azvw", &activity, null, &sink, false, &compact, .{ .drawn = .{}, .from = null }, "") catch |err| break :blk err;
                break :blk {};
            };
            peer.join();
            if (Peer.failure) |err| return err;
            if (mode == .intact) {
                try result;
                if (surface == .history) {
                    var retained: [8192]u8 = undefined;
                    try std.testing.expectEqual(item_bytes, try scratch.readPositionalAll(io, &retained, 0));
                    try std.testing.expectEqualSlices(u8, body[body.len - item_bytes ..], &retained);
                } else try std.testing.expectEqualStrings("\n  ! Tool call — Failed\n", sink.bytes[0..sink.length]);
            } else {
                try std.testing.expectEqual(@as(usize, 0), sink.length);
                try std.testing.expectError(switch (mode) {
                    .extra_wire => error.InvalidResponse,
                    .truncated_prefix, .truncated_suffix => error.TruncatedResponse,
                    else => error.ContentBindingMismatch,
                }, result);
            }
        }
    }
}

test "history tool suffix rejects scratch corruption and dropped writes at every retained window" {
    const Fault = struct {
        var at: u64 = 0;
        var drop: bool = false;
        var hits: usize = 0;
        fn stage(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            if (drop and offset == at) {
                hits += 1;
                var count = header.len;
                for (data[0 .. data.len - 1]) |bytes| count += bytes.len;
                return count + data[data.len - 1].len * splat;
            }
            const count = try std.testing.io.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
            if (!drop and offset == at) {
                hits += 1;
                _ = try std.testing.io.vtable.fileWritePositional(userdata, file, "", &.{"!"}, 1, offset);
            }
            return count;
        }
    };
    const Source = struct {
        body: []const u8,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, index: usize, sink: anytype) !void {
            const body = if (index == 0) self.body else "";
            var hash = protocol.contentHasher();
            var offset: usize = 0;
            while (offset < body.len) {
                const end = @min(body.len, offset + protocol.content_window_bytes);
                hash.update(body[offset..end]);
                try sink.feed(body[offset..end]);
                offset = end;
            }
            if (body.len != item.content.bytes or !std.mem.eql(u8, &hash.finalResult(), &item.content.digest)) return error.ContentBindingMismatch;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    var vtable = io.vtable.*;
    vtable.fileWritePositional = Fault.stage;
    const faulty_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const body = &@as([16385]u8, @splat('x'));
    var page: protocol_reply.ConversationPage = .{ .end = 2, .count = 2, .more = false };
    for (page.items[0..2], 0..) |*item, index| {
        const text = if (index == 0) body else "";
        item.* = .{ .position = 2 - index, .ordinal = 0, .kind = .tool_result, .content = .{ .bytes = text.len, .digest = protocol.contentDigest(text) }, .presentation = .{ .description = null, .code = .succeeded, .publication_position = 2 - index } };
    }
    for ([_]u64{ 0, 4095, 8191 }) |offset| {
        for ([_]bool{ false, true }) |drop| {
            Fault.at = offset;
            Fault.drop = drop;
            Fault.hits = 0;
            const result = stagePage(faulty_io, page, scratch, Source{ .body = body });
            try std.testing.expectEqual(@as(usize, 1), Fault.hits);
            if (drop and offset == 8191) {
                try std.testing.expectError(error.TruncatedHistoryScratch, result);
            } else try std.testing.expectError(error.ContentBindingMismatch, result);
        }
    }
}

test "history tool suffix rejects later writes corrupting earlier spans" {
    const Fault = struct {
        var hits: usize = 0;
        fn stage(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            const count = try std.testing.io.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
            if (offset == item_bytes) {
                hits += 1;
                _ = try std.testing.io.vtable.fileWritePositional(userdata, file, "", &.{"!"}, 1, 0);
            }
            return count;
        }
    };
    const Source = struct {
        bodies: [2][]const u8,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, index: usize, sink: anytype) !void {
            const body = self.bodies[index];
            var hash = protocol.contentHasher();
            var offset: usize = 0;
            while (offset < body.len) {
                const end = @min(body.len, offset + protocol.content_window_bytes);
                hash.update(body[offset..end]);
                try sink.feed(body[offset..end]);
                offset = end;
            }
            if (body.len != item.content.bytes or !std.mem.eql(u8, &hash.finalResult(), &item.content.digest)) return error.ContentBindingMismatch;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    var vtable = io.vtable.*;
    vtable.fileWritePositional = Fault.stage;
    const faulty_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const first = &@as([8193]u8, @splat('x'));
    const second = &@as([8194]u8, @splat('y'));
    const source: Source = .{ .bodies = .{ first, second } };
    var page: protocol_reply.ConversationPage = .{ .end = 2, .count = 2, .more = false };
    for (page.items[0..2], source.bodies, 0..) |*item, body, index| {
        item.* = .{ .position = 2 - index, .ordinal = 0, .kind = .tool_result, .content = .{ .bytes = body.len, .digest = protocol.contentDigest(body) }, .presentation = .{ .description = null, .code = .succeeded, .publication_position = 2 - index } };
    }
    Fault.hits = 0;
    const result = stagePage(faulty_io, page, scratch, source);
    try std.testing.expectEqual(@as(usize, 1), Fault.hits);
    var retained: [item_bytes]u8 = undefined;
    try std.testing.expectEqual(retained.len, try scratch.readPositionalAll(io, &retained, item_bytes));
    try std.testing.expectEqualSlices(u8, second[2..], &retained);
    try std.testing.expectError(error.ContentBindingMismatch, result);
}

test "history tool raw suffix boundary stays exact while details escape controls" {
    const Sink = struct {
        bytes: [16 * 1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const Source = struct {
        body: []const u8,
        fn read(self: @This(), item: protocol_reply.ConversationPage.Item, _: usize, sink: anytype) !void {
            for (self.body) |byte| try sink.feed(&.{byte});
            if (self.body.len != item.content.bytes or !std.mem.eql(u8, &protocol.contentDigest(self.body), &item.content.digest)) return error.ContentBindingMismatch;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    var body: [8200]u8 = @splat('z');
    @memcpy(body[7..14], "é\x00\x1b\u{202e}");
    var page: protocol_reply.ConversationPage = .{ .end = 1, .count = 1, .more = false };
    page.items[0] = .{ .position = 1, .ordinal = 0, .kind = .tool_result, .content = .{ .bytes = body.len, .digest = protocol.contentDigest(&body) }, .presentation = .{ .description = null, .code = .succeeded, .publication_position = 1 } };
    const prepared = try stagePage(io, page, scratch, Source{ .body = &body });
    var raw: [8192]u8 = undefined;
    try std.testing.expectEqual(raw.len, try scratch.readPositionalAll(io, &raw, 0));
    try std.testing.expectEqualSlices(u8, body[8..], &raw);
    var sink: Sink = .{};
    try prepared.render(io, scratch, "store", "09azvw", &sink, .details, false, "");
    const output = sink.bytes[0..sink.length];
    const prefix = "\n  ✓ Tool call\n  Earlier output omitted\n  \\xa9\\x00\\x1b\\u202e";
    try std.testing.expect(std.mem.startsWith(u8, output, prefix));
    try std.testing.expectEqualStrings(body[14..], output[prefix.len..][0 .. body.len - 14]);
    try std.testing.expectEqualStrings("\n  Raw export: rui session read-conversation --store-hex 73746f7265 --session 09azvw --position 1 --ordinal 0\n", output[prefix.len + body.len - 14 ..]);
}

test "history assistant local paths use the borrowed HOME and leave punctuation outside the link" {
    const Sink = struct {
        bytes: [1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.createFile(io, "history", .{ .read = true });
    defer scratch.close(io);
    const text = "The report is at ~/report.md;";
    try scratch.writePositionalAll(io, text, 0);
    var prepared: Prepared = .{ .page = .{ .end = 1, .count = 1, .more = false } };
    prepared.page.items[0] = .{ .position = 1, .ordinal = 0, .kind = .assistant, .content = .{ .bytes = text.len, .digest = protocol.contentDigest(text) } };
    prepared.bodies[0] = .{ .whole = .{ .offset = 0, .length = text.len } };
    var sink: Sink = .{};
    try prepared.render(io, scratch, "store", "09azvw", &sink, .transcript, false, "/home/a b");
    try std.testing.expectEqualStrings("\nThe report is at \x1b]8;;file:///home/a%20b/report.md\x1b\\\x1b[4m~/report.md\x1b[0m\x1b]8;;\x1b\\;\n", sink.bytes[0..sink.length]);
}
