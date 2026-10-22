//! Atomic bounded Conversation preparation, distinct from one-pass opening.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const View = @import("session_view.zig");

pub const item_bytes = 8192;
pub const max_scratch_bytes = item_bytes * protocol.public_conversation_page_items;

/// Owns metadata; borrows unchanged scratch from successful prepare to render.
/// Preparation exposes no output or cursor; the caller commits after rendering.
pub const Prepared = struct {
    page: client.ConversationPage,
    offsets: [protocol.public_conversation_page_items]u64 = undefined,

    /// The transcript matches live presentation; details keep exact tool output.
    pub const Mode = enum { transcript, details };

    pub fn render(self: *const Prepared, io: std.Io, scratch: std.Io.File, store: []const u8, session: []const u8, sink: anytype, mode: Mode, colour: bool) !void {
        var window: [protocol.content_window_bytes]u8 = undefined;
        var compact = false;
        for (0..self.page.count) |reverse| {
            const index = self.page.count - 1 - reverse;
            const item = self.page.items[index];
            if (item.content.bytes > item_bytes) {
                compact = false;
                var buffer: [192]u8 = undefined;
                if (item.sender) |sender| {
                    // Its first line is not staged, so the line shows `…`
                    // alone and Ctrl-O opens it.
                    var line: View.PeerLine(@TypeOf(sink)) = undefined;
                    try line.init(sink, .inbound, sender, item.content.bytes);
                    line.received = item.content.bytes;
                    line.phase = .more;
                    if (try line.finish(item.admitted_at.?)) try View.noteCollapsed(sink, collapsed(item));
                    continue;
                }
                if (item.kind == .user) {
                    // Its line count is unknown without reading it.
                    try View.userPrefix(sink, colour, item.admitted_at.?);
                    try View.noteCollapsed(sink, collapsed(item));
                    try sink.feed(View.Mark.summary ++ "┄" ++ View.Mark.reset ++ "\n  " ++ View.Mark.summary);
                } else {
                    if (item.kind == .tool_result) try View.toolHeading(item.presentation.?, sink, colour, true) else try sink.feed("\n");
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
            const staged: Staged = .{ .io = io, .scratch = scratch, .start = self.offsets[index], .bytes = item.content.bytes, .window = &window };
            if (item.kind == .tool_result and mode == .transcript) {
                try View.toolResult(item.presentation.?, staged, sink, colour, &compact);
                continue;
            }
            compact = false;
            switch (item.kind) {
                .tool_result => {
                    try View.toolHeading(item.presentation.?, sink, colour, true);
                    try sink.feed("  ");
                    var indented: View.Indented(@TypeOf(sink)) = .{ .sink = sink };
                    var escaped: View.Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .multiline } };
                    try staged.read(&escaped);
                    try escaped.finish();
                    try indented.finish();
                },
                .user => if (item.sender) |sender| {
                    var line: View.PeerLine(@TypeOf(sink)) = undefined;
                    try line.init(sink, .inbound, sender, item.content.bytes);
                    try staged.read(&line);
                    if (try line.finish(item.admitted_at.?)) try View.noteCollapsed(sink, collapsed(item));
                    continue;
                } else {
                    try View.userPrefix(sink, colour, item.admitted_at.?);
                    var body: View.UserBody(@TypeOf(sink)) = undefined;
                    try body.init(sink, item.content.bytes, mode == .details);
                    try staged.read(&body);
                    if (try body.finish()) try View.noteCollapsed(sink, collapsed(item));
                },
                .assistant => {
                    try sink.feed("\n");
                    var answer: View.Answer(@TypeOf(sink)) = undefined;
                    answer.init(sink);
                    try staged.read(&answer);
                    try answer.finish();
                },
            }
            try sink.feed("\n");
        }
    }
};

fn collapsed(item: client.ConversationPage.Item) View.Collapsed {
    return .{ .source = .conversation, .position = item.position, .ordinal = item.ordinal, .content = .{ .length = item.content.bytes, .digest = item.content.digest }, .row = true };
}

/// The command that exports one conversation row's exact bytes.
pub fn writeExport(sink: anytype, store: []const u8, session: []const u8, position: u64, ordinal: u64) !void {
    var buffer: [64]u8 = undefined;
    try sink.feed("Raw export: rui session read-conversation --store-hex ");
    try writeHex(sink, store);
    try sink.feed(" --session-hex ");
    try writeHex(sink, session);
    try sink.feed(try std.fmt.bufPrint(&buffer, " --position {d} --ordinal {d}", .{ position, ordinal }));
}

pub fn prepare(requests: client.Requests, store: []const u8, session: []const u8, cursor: client.ConversationCursor, scratch: std.Io.File) !Prepared {
    const page = switch (try requests.conversationPage(store, session, cursor)) {
        .page => |value| value,
        .failure => |failure| return requests.failRead(failure),
    };
    const Source = struct {
        requests: client.Requests,
        store: []const u8,
        session: []const u8,
        fn read(self: @This(), item: client.ConversationPage.Item, _: usize, sink: anytype) !void {
            if (try self.requests.readConversationContent(self.store, self.session, item.position, item.ordinal, item.content, sink)) |failure| return self.requests.failRead(failure);
        }
    };
    return stagePage(requests.io, page, scratch, Source{ .requests = requests, .store = store, .session = session });
}

// The source owns received-byte validation; this owner independently verifies
// the actual scratch bytes before returning any presentation authority.
fn stagePage(io: std.Io, page: client.ConversationPage, scratch: std.Io.File, source: anytype) !Prepared {
    var prepared: Prepared = .{ .page = page };
    try scratch.setLength(io, 0);
    const Staging = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var staging: Staging = .{ .io = io, .file = scratch };
    for (page.items[0..page.count], 0..) |item, index| {
        if (item.content.bytes > item_bytes) continue;
        prepared.offsets[index] = staging.offset;
        try source.read(item, index, &staging);
    }
    // Received-byte integrity does not prove that staging preserved those bytes.
    var window: [protocol.content_window_bytes]u8 = undefined;
    for (page.items[0..page.count], prepared.offsets[0..page.count]) |item, start| {
        if (item.content.bytes > item_bytes) continue;
        var hash = protocol.contentHasher();
        var offset: u64 = 0;
        while (offset < item.content.bytes) {
            const wanted: usize = @intCast(@min(item.content.bytes - offset, window.len));
            if (try scratch.readPositionalAll(io, window[0..wanted], start + offset) != wanted) return error.TruncatedHistoryScratch;
            hash.update(window[0..wanted]);
            offset += wanted;
        }
        if (!std.mem.eql(u8, &hash.finalResult(), &item.content.digest)) return error.ContentBindingMismatch;
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

test "historical export preserves opaque identities without terminal or shell interpretation" {
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
    // A User item is a collapsed user block with nothing else known, and a
    // peer's a line ending in `…`; Ctrl-O opens either. Others keep their
    // notice.
    var prepared: Prepared = .{ .page = .{ .end = 4, .count = 3, .more = false } };
    var sender: protocol.Peer = .{ .session = .{} };
    try sender.session.set("reviewer");
    prepared.page.items[0] = .{ .position = 4, .ordinal = 0, .kind = .user, .content = .{ .bytes = 8200, .digest = @splat(0) }, .admitted_at = 1_800_000_000, .sender = sender };
    prepared.page.items[1] = .{ .position = 3, .ordinal = 0, .kind = .assistant, .content = .{ .bytes = 8193, .digest = @splat(0) } };
    prepared.page.items[2] = .{ .position = 2, .ordinal = 0, .kind = .user, .content = .{ .bytes = 9000, .digest = @splat(0) }, .admitted_at = 1_800_000_000 };
    var sink: Sink = .{};
    try prepared.render(std.testing.io, std.Io.File.stdin(), "/tmp/a'$(false)", "team\x1b[2J\n\x00é\u{202e}", &sink, .details, false);
    try std.testing.expectEqualSlices(u64, &.{ 2, 4 }, sink.positions[0..sink.notes]);
    // Independent UTF-8 byte-to-hex oracle, including NUL and directional text.
    const identity = " --store-hex 2f746d702f6127242866616c736529 --session-hex 7465616d1b5b324a0a00c3a9e280ae";
    var time: [5]u8 = undefined;
    var expected: [1024]u8 = undefined;
    const clock = View.clock(1_800_000_000, &time).?;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "\n› \x1b[8m{s}\x1b[0m\x1b[2;8m┄\x1b[0m\n  \x1b[2;8mRaw export: rui session read-conversation{s} --position 2 --ordinal 0\x1b[0m\n" ++
        "\nRui: Historical item omitted: position 3, ordinal 0, 8193 raw bytes.\nRaw export: rui session read-conversation{s} --position 3 --ordinal 0\n" ++
        "\n\x1b[2;8m← reviewer · …\x1b[8m{s}\x1b[0m\n", .{ clock, identity, identity, clock }), sink.bytes[0..sink.length]);
}

test "history body limit preserves contextual tool outcomes" {
    const Sink = struct {
        bytes: [16 * 1024]u8 = undefined,
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
    const body = &@as([8192]u8, @splat('x'));
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Compile package");
    const Case = struct { code: protocol.ToolPresentation.Code, heading: []const u8, fallback: bool = false };
    for ([_]Case{
        .{ .code = .failed, .heading = "\n! Compile package — Failed\n" },
        .{ .code = .succeeded, .heading = "\n✓ Compile package\n" },
        .{ .code = .indeterminate, .heading = "\n! Compile package — Outcome unknown; may have run\n" },
        .{ .code = .denied, .heading = "\n• Compile package — Denied\n" },
        .{ .code = .invalid_arguments, .heading = "\n• Tool call — Rejected: invalid arguments\n", .fallback = true },
    }) |case| {
        for ([_]u64{ 8192, 8193 }) |size| {
            var prepared: Prepared = .{ .page = .{ .end = 7, .count = 1, .more = false } };
            prepared.page.items[0] = .{ .position = 7, .ordinal = 2, .kind = .tool_result, .content = .{ .bytes = size, .digest = @splat(0) }, .presentation = .{ .description = if (case.fallback) null else description, .code = case.code, .publication_position = 7 } };
            // Oversized bodies have no staged bytes or valid scratch offset.
            try scratch.setLength(io, 0);
            if (size == 8192) try scratch.writePositionalAll(io, body, 0);
            prepared.offsets[0] = if (size == 8192) 0 else std.math.maxInt(u64);
            var sink: Sink = .{};
            try prepared.render(io, scratch, "store", "session", &sink, .details, false);
            const output = sink.bytes[0..sink.length];
            try std.testing.expect(std.mem.startsWith(u8, output, case.heading));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, case.heading));
            if (size == 8192) {
                try std.testing.expect(std.mem.endsWith(u8, output, body ++ "\n"));
                try std.testing.expect(std.mem.indexOf(u8, output, "Historical item omitted") == null);
            } else {
                try std.testing.expectEqualStrings("Rui: Historical item omitted: position 7, ordinal 2, 8193 raw bytes.\nRaw export: rui session read-conversation --store-hex 73746f7265 --session-hex 73657373696f6e --position 7 --ordinal 2\n", output[case.heading.len..]);
            }
        }
    }
}

test "reopened transcript keeps useful stdout when stderr is blank" {
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
    const result = "Bash failed. Exit code: 7.\nstdout tail:\nuseful diagnostic B\nstderr tail:\n\n";
    try scratch.writePositionalAll(io, result, 0);
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Run check");
    var prepared: Prepared = .{ .page = .{ .end = 7, .count = 1, .more = false } };
    prepared.page.items[0] = .{ .position = 7, .ordinal = 2, .kind = .tool_result, .content = .{ .bytes = result.len, .digest = @splat(0) }, .presentation = .{ .description = description, .code = .failed, .publication_position = 7 } };
    prepared.offsets[0] = 0;
    var sink: Sink = .{};
    try prepared.render(io, scratch, "store", "session", &sink, .transcript, false);
    try std.testing.expectEqualStrings("\n! Run check — Failed (exit 7)\n  useful diagnostic B\n", sink.bytes[0..sink.length]);
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
            const metadata = "{\"version\":\"1\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"2\",\"items\":[{\"position\":\"2\",\"ordinal\":\"0\",\"kind\":\"user\",\"admitted_at\":\"1\",\"content\":{\"bytes\":\"5\",\"sha256\":\"2e37afae3fe85c8c30175c6f0a1b578b3cbe5f4482248f77cb55656781d2790b\",\"display\":\"omitted\"}}],\"more\":false}";
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
                const response = try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nX-Rui-Wire-Version: 1\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\n\r\n", .{ content_type, body.len, body.len, body.len });
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
            fn read(self: @This(), _: client.ConversationPage.Item, index: usize, sink: anytype) !void {
                const body = self.bodies[index];
                var offset: usize = 0;
                while (offset < body.len) {
                    const end = @min(body.len, offset + protocol.content_window_bytes);
                    try sink.feed(body[offset..end]);
                    offset = end;
                }
            }
        };
        const bytes: Bytes = .{ .bodies = .{ if (case.large) Peer.large_body else "first", if (case.empty_second) "" else "end" } };
        var page: client.ConversationPage = .{ .end = 2, .count = if (case.large) 2 else 1, .more = false };
        for (page.items[0..page.count], 0..) |*item, index| {
            item.* = .{ .position = 2 - index, .ordinal = 0, .kind = if (index == 0) .user else .assistant, .content = .{ .bytes = bytes.bodies[index].len, .digest = undefined } };
            // Independent hashlib oracles, not the staging implementation.
            _ = try std.fmt.hexToBytes(&item.content.digest, if (index == 0)
                (if (case.large) "c4507c75ffffb20c21aad1b5eecab12e273533475e6d3204a866471d86c5a3cb" else "2e37afae3fe85c8c30175c6f0a1b578b3cbe5f4482248f77cb55656781d2790b")
            else if (case.empty_second) "11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528" else "743b6084710002f2040770ad1e35947dce27acfb1b5c6d3a1ddc28f74b462972");
        }
        const result = if (supplied) stagePage(requests.io, page, scratch, bytes) else prepare(requests, root, "history/session", .{ .end = 2 }, scratch);
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
            try std.testing.expectEqual(@as(u64, 0), prepared.offsets[0]);
            if (case.large) try std.testing.expectEqual(@as(u64, 4097), prepared.offsets[1]);
            var staged: [4100]u8 = undefined;
            const wanted: usize = if (case.large) (if (case.empty_second) 4097 else 4100) else 5;
            try std.testing.expectEqual(wanted, try scratch.readPositionalAll(io, staged[0..wanted], 0));
            var tail: [1]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 0), try scratch.readPositionalAll(io, &tail, wanted));
            try std.testing.expectEqualStrings(if (case.large) Peer.large_body else "first", staged[0..if (case.large) 4097 else 5]);
            if (case.large) try std.testing.expectEqualStrings(if (case.empty_second) "" else "end", staged[4097..wanted]);
            for (prepared.page.items[0..prepared.page.count], prepared.offsets[0..prepared.page.count]) |item, start| {
                try std.testing.expectEqualSlices(u8, &item.content.digest, &protocol.contentDigest(staged[@intCast(start)..][0..@intCast(item.content.bytes)]));
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
