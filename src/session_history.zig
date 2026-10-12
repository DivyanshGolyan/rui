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

    pub fn render(self: *const Prepared, io: std.Io, scratch: std.Io.File, store: []const u8, session: []const u8, sink: anytype, columns: usize, colour: bool) !void {
        var window: [protocol.content_window_bytes]u8 = undefined;
        for (0..self.page.count) |reverse| {
            const index = self.page.count - 1 - reverse;
            const item = self.page.items[index];
            if (item.content.bytes > item_bytes) {
                var buffer: [192]u8 = undefined;
                try sink.feed(try std.fmt.bufPrint(&buffer, "Rui: Historical item omitted: position {d}, ordinal {d}, {d} raw bytes.\nRaw export: rui read-conversation --store-hex ", .{ item.position, item.ordinal, item.content.bytes }));
                try writeHex(sink, store);
                try sink.feed(" --session-hex ");
                try writeHex(sink, session);
                try sink.feed(try std.fmt.bufPrint(&buffer, " --position {d} --ordinal {d}\n", .{ item.position, item.ordinal }));
                continue;
            }
            if (item.kind == .user) {
                try sink.feed("\n");
                try sink.feed(View.Style.user.code(colour));
                try sink.feed("›");
                try sink.feed(View.Style.normal.code(colour));
                try sink.feed(" ");
            } else try sink.feed(if (item.kind == .assistant) "\n  " else "\n  Tool result:\n  ");
            var indented: View.Indented(@TypeOf(sink)) = .{ .sink = sink, .columns = columns };
            var answer: View.Answer(@TypeOf(&indented)) = undefined;
            answer.init(&indented);
            var escaped: View.Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .multiline } };
            var offset: u64 = 0;
            while (offset < item.content.bytes) {
                const wanted: usize = @intCast(@min(item.content.bytes - offset, window.len));
                if (try scratch.readPositionalAll(io, window[0..wanted], self.offsets[index] + offset) != wanted) return error.TruncatedHistoryScratch;
                if (item.kind == .assistant) try answer.feed(window[0..wanted]) else try escaped.feed(window[0..wanted]);
                offset += wanted;
            }
            if (item.kind == .assistant) try answer.finish() else try escaped.finish();
            try indented.finish();
            try sink.feed("\n");
        }
    }
};

pub fn prepare(requests: client.Requests, store: []const u8, session: []const u8, cursor: client.ConversationCursor, scratch: std.Io.File) !Prepared {
    const page = switch (try requests.conversationPage(store, session, cursor)) {
        .page => |value| value,
        .failure => |failure| return failure.err(),
    };
    var prepared: Prepared = .{ .page = page };
    try scratch.setLength(requests.io, 0);
    const Staging = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var staging: Staging = .{ .io = requests.io, .file = scratch };
    for (page.items[0..page.count], 0..) |item, index| {
        if (item.content.bytes > item_bytes) continue;
        prepared.offsets[index] = staging.offset;
        if (try requests.readConversationContent(store, session, item.position, item.ordinal, item.content, &staging)) |failure| return failure.err();
    }
    // Received-byte integrity does not prove that staging preserved those bytes.
    var window: [protocol.content_window_bytes]u8 = undefined;
    for (page.items[0..page.count], prepared.offsets[0..page.count]) |item, start| {
        if (item.content.bytes > item_bytes) continue;
        var hash = protocol.contentHasher();
        var offset: u64 = 0;
        while (offset < item.content.bytes) {
            const wanted: usize = @intCast(@min(item.content.bytes - offset, window.len));
            if (try scratch.readPositionalAll(requests.io, window[0..wanted], start + offset) != wanted) return error.TruncatedHistoryScratch;
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
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var prepared: Prepared = .{ .page = .{ .end = 2, .count = 1, .more = false } };
    prepared.page.items[0] = .{ .position = 2, .ordinal = 0, .kind = .user, .content = .{ .bytes = 8193, .digest = @splat(0) } };
    var sink: Sink = .{};
    try prepared.render(std.testing.io, std.Io.File.stdin(), "/tmp/a'$(false)", "team\x1b[2J\n\x00é\u{202e}", &sink, 0, false);
    // Independent UTF-8 byte-to-hex oracle, including NUL and directional text.
    try std.testing.expectEqualStrings("Rui: Historical item omitted: position 2, ordinal 0, 8193 raw bytes.\nRaw export: rui read-conversation --store-hex 2f746d702f6127242866616c736529 --session-hex 7465616d1b5b324a0a00c3a9e280ae --position 2 --ordinal 0\n", sink.bytes[0..sink.length]);
}

test "history preparation binds wire and staged bytes before exposure" {
    const Peer = struct {
        var clients: [3]std.posix.fd_t = undefined;
        var large: bool = false;
        var empty_second: bool = false;
        var fault_offset: u64 = 0;
        var fault_hits: usize = 0;
        const large_body = "a" ** 4096 ++ "Z";
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
            const metadata = "{\"version\":\"1\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"2\",\"items\":[{\"position\":\"2\",\"ordinal\":\"0\",\"kind\":\"user\",\"content\":{\"bytes\":\"5\",\"sha256\":\"2e37afae3fe85c8c30175c6f0a1b578b3cbe5f4482248f77cb55656781d2790b\",\"display\":\"omitted\"}}],\"more\":false}";
            // Independent hashlib oracles: a*4096 + Z, end, and empty.
            var metadata_buffer: [1024]u8 = undefined;
            const large_metadata = try std.fmt.bufPrint(&metadata_buffer, "{{\"version\":\"1\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"2\",\"items\":[{{\"position\":\"2\",\"ordinal\":\"0\",\"kind\":\"user\",\"content\":{{\"bytes\":\"4097\",\"sha256\":\"c4507c75ffffb20c21aad1b5eecab12e273533475e6d3204a866471d86c5a3cb\",\"display\":\"omitted\"}}}},{{\"position\":\"1\",\"ordinal\":\"0\",\"kind\":\"assistant\",\"content\":{{\"bytes\":\"{d}\",\"sha256\":\"{s}\",\"display\":\"omitted\"}}}}],\"more\":false}}", .{ @as(usize, if (empty_second) 0 else 3), if (empty_second) "11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528" else "743b6084710002f2040770ad1e35947dce27acfb1b5c6d3a1ddc28f74b462972" });
            const bodies: [3][]const u8 = if (large) .{ large_metadata, large_body, if (empty_second) "" else "end" } else .{ metadata, "first", "" };
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
        Peer.large = case.large;
        Peer.empty_second = case.empty_second;
        Peer.fault_offset = case.fault_offset;
        Peer.fault_hits = 0;
        Peer.connected = 0;
        Peer.failure = null;
        const exchanges: usize = if (case.large) 3 else 2;
        var servers: [3]std.posix.fd_t = undefined;
        for (Peer.clients[0..exchanges], servers[0..exchanges]) |*caller, *server| {
            var sockets: [2]std.posix.fd_t = undefined;
            if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) return error.SocketPairFailed;
            caller.* = sockets[0];
            server.* = sockets[1];
        }
        const peer = try std.Thread.spawn(.{}, Peer.serve, .{servers[0..exchanges]});
        const result = prepare(requests, root, "history/session", .{ .end = 2 }, scratch);
        // Release any request never reached after an earlier protocol failure.
        for (Peer.clients[Peer.connected..exchanges]) |fd| {
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            file.close(io);
        }
        peer.join();
        if (Peer.failure) |err| {
            _ = try result;
            return err;
        }
        if (mode == .corrupt or mode == .missing) try std.testing.expectEqual(@as(usize, 1), Peer.fault_hits);
        if (case.large) try std.testing.expectEqual(exchanges, Peer.connected);
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
