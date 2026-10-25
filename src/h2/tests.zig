//! The client against the in-process peer over loopback h2c and TLS. Each
//! test pumps the client and the peer on one thread, so every exchange is
//! deterministic.
const std = @import("std");
const h2 = @import("h2.zig");
const Peer = @import("testing/Peer.zig");
const c = @import("h2_c");

const ns_per_ms = std.time.ns_per_ms;

const Receiver = struct {
    heads: u32 = 0,
    interims: u32 = 0,
    trailers: u32 = 0,
    bodies: u32 = 0,
    retired: u32 = 0,
    content_type_seen: bool = false,
    refuse_heads: bool = false,

    pub fn observe(self: *Receiver, _: *h2.Stream, event: h2.Event) h2.Verdict {
        switch (event) {
            .head => |head| {
                switch (head.kind) {
                    .interim => self.interims += 1,
                    .final => self.heads += 1,
                    .trailers => self.trailers += 1,
                }
                for (head.fields) |field| {
                    if (std.mem.eql(u8, field.name, "content-type")) self.content_type_seen = true;
                }
                if (self.refuse_heads) return .refuse;
            },
            .body => self.bodies += 1,
            .body_retired => self.retired += 1,
        }
        return .accept;
    }
};

const Harness = struct {
    client: h2.Client,
    peer: *Peer,
    receiver: Receiver,
    endpoint: h2.Endpoint,

    const Config = struct {
        peer: Peer.Options = .{},
        capacity: u32 = 8,
        inactivity_ns: u64 = 10 * std.time.ns_per_s,
        liveness: h2.Liveness = .{},
        connect_timeout_ns: u64 = 5 * std.time.ns_per_s,
        /// Overrides the peer's URL.
        url: ?[]const u8 = null,
    };

    fn create(config: Config) !*Harness {
        const allocator = std.testing.allocator;
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        self.peer = try Peer.start(allocator, config.peer);
        errdefer self.peer.stop();
        self.receiver = .{};
        try self.client.init(allocator, std.testing.io, .{
            .stream_capacity = config.capacity,
            .inactivity_ns = config.inactivity_ns,
            .connect_timeout_ns = config.connect_timeout_ns,
            .liveness = config.liveness,
            .trust = if (config.peer.tls == .none) .system else .{ .ca_file = self.peer.caPath() },
        });
        errdefer self.client.deinit();
        self.endpoint = try self.client.addEndpoint(config.url orelse self.peer.url());
        return self;
    }

    fn destroy(self: *Harness) void {
        self.client.deinit();
        self.peer.stop();
        std.testing.allocator.destroy(self);
    }

    fn launch(self: *Harness, stream: *h2.Stream, request: h2.Request) !void {
        try self.client.prepare(stream, request);
        self.client.launch(stream);
    }

    fn step(self: *Harness) !void {
        try self.client.drive(&self.receiver);
        try self.peer.pump();
        try self.client.drive(&self.receiver);
        try self.client.wait(1);
    }

    /// Steps until `done` holds, failing after five seconds.
    fn runUntil(self: *Harness, context: anytype, comptime done: fn (*Harness, @TypeOf(context)) bool) !void {
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        while (!done(self, context)) {
            if (std.Io.Clock.awake.now(std.testing.io).nanoseconds - start > 5 * std.time.ns_per_s) {
                std.debug.print("timed out: finished={d} peer_streams={d} peer_conns={d}\n", .{ self.client.finishedCount(), self.peer.streams.items.len, self.peer.seen.connections });
                return error.Timeout;
            }
            try self.step();
        }
    }

    fn runUntilFinished(self: *Harness, count: usize) !void {
        try self.runUntil(count, struct {
            fn done(harness: *Harness, wanted: usize) bool {
                return harness.client.finishedCount() >= wanted;
            }
        }.done);
    }

    fn runUntilPeerStreams(self: *Harness, count: usize) !void {
        try self.runUntil(count, struct {
            fn done(harness: *Harness, wanted: usize) bool {
                return harness.peer.streams.items.len >= wanted;
            }
        }.done);
    }

    fn runFor(self: *Harness, ns: u64) !void {
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        while (std.Io.Clock.awake.now(std.testing.io).nanoseconds - start < ns) try self.step();
    }

    fn collect(self: *Harness, stream: *h2.Stream) !h2.End {
        try std.testing.expectEqual(stream, self.client.nextFinished().?);
        return stream.end().?;
    }
};

fn bytesRequest(endpoint: h2.Endpoint, body: []const u8, sink: []u8) h2.Request {
    return .{ .endpoint = endpoint, .fields = &.{}, .body = .{ .bytes = body }, .sink = .{ .buffer = sink } };
}

fn hold(_: *Peer, _: *Peer.Stream) void {}

test "a request and its response round trip" {
    const harness = try Harness.create(.{});
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [64]u8 = undefined;
    try harness.launch(&stream, .{
        .endpoint = harness.endpoint,
        .fields = &.{
            .{ .name = "authorization", .value = "Bearer secret", .sensitive = true },
            .{ .name = "accept", .value = "text/event-stream" },
        },
        .body = .{ .bytes = "{\"input\":1}" },
        .sink = .{ .buffer = &sink },
    });
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqual(@as(?u16, 200), stream.status());
    try std.testing.expectEqualStrings("ok", sink[0..@intCast(stream.responseLength())]);
    try std.testing.expect(stream.openedConnection());
    try std.testing.expectEqual(@as(u32, 1), harness.receiver.heads);
    try std.testing.expect(harness.receiver.content_type_seen);
    try std.testing.expectEqual(@as(u32, 1), harness.receiver.retired);
    const seen = harness.peer.streams.items[0];
    try std.testing.expectEqualStrings("/v1/responses", seen.path.items);
    try std.testing.expectEqualStrings("Bearer secret", seen.authorization.items);
    try std.testing.expectEqualStrings("{\"input\":1}", seen.body.items);
    try std.testing.expectEqual(@as(?*h2.Stream, null), harness.client.nextFinished());
    stream.deinit();
}

test "request bodies come from a file and responses go to one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body_file = try tmp.dir.createFile(io, "body", .{ .read = true });
    defer body_file.close(io);
    const sink_file = try tmp.dir.createFile(io, "sink", .{ .read = true });
    defer sink_file.close(io);
    var body: [40 * 1024]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @truncate(index * 7);
    try body_file.writePositionalAll(io, &body, 0);

    var response: [256 * 1024]u8 = undefined;
    for (&response, 0..) |*byte, index| byte.* = @truncate(index * 13);
    const Respond = struct {
        var bytes: []const u8 = &.{};
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.respond(stream, 200, bytes);
        }
    };
    Respond.bytes = &response;
    const harness = try Harness.create(.{ .peer = .{ .on_request = Respond.handle } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    try harness.launch(&stream, .{
        .endpoint = harness.endpoint,
        .fields = &.{},
        .body = .{ .file = .{ .handle = body_file.handle, .length = body.len } },
        .sink = .{ .file = sink_file.handle },
    });
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqualSlices(u8, &body, harness.peer.streams.items[0].body.items);
    try std.testing.expectEqual(@as(u64, response.len), stream.responseLength());
    var written: [256 * 1024]u8 = undefined;
    try std.testing.expectEqual(written.len, try sink_file.readPositionalAll(io, &written, 0));
    try std.testing.expectEqualSlices(u8, &response, &written);
    // Credit reopens only for written bytes: never more than one stream
    // window outstanding.
    try std.testing.expect(harness.peer.seen.max_stream_window <= h2.stream_window_bytes);
    stream.deinit();
}

test "a peer allowing one stream gets one connection per stream" {
    const harness = try Harness.create(.{ .peer = .{ .max_concurrent_streams = 1, .on_request = hold } });
    defer harness.destroy();
    var streams: [3]h2.Stream = @splat(.idle);
    var sinks: [3][8]u8 = undefined;
    for (&streams, &sinks) |*stream, *sink| try harness.launch(stream, bytesRequest(harness.endpoint, "x", sink));
    try harness.runUntilPeerStreams(3);
    try std.testing.expectEqual(@as(u32, 3), harness.peer.seen.connections);
    for (harness.peer.streams.items) |seen| harness.peer.respond(seen, 200, "ok");
    try harness.runUntilFinished(3);
    for (0..3) |_| {
        const stream = harness.client.nextFinished().?;
        try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, stream.end().?);
        try std.testing.expect(stream.openedConnection());
        stream.deinit();
    }
}

test "a stream above GOAWAY's last stream id is sent again elsewhere" {
    const Script = struct {
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            switch (stream.index) {
                0 => {},
                1 => {
                    peer.goaway(stream.connection, peer.streams.items[0].id, 0);
                    peer.respond(peer.streams.items[0], 200, "first");
                },
                else => peer.respond(stream, 200, "again"),
            }
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .on_request = Script.handle } });
    defer harness.destroy();
    var first: h2.Stream = .idle;
    var second: h2.Stream = .idle;
    var first_sink: [8]u8 = undefined;
    var second_sink: [8]u8 = undefined;
    try harness.launch(&first, bytesRequest(harness.endpoint, "1", &first_sink));
    try harness.launch(&second, bytesRequest(harness.endpoint, "2", &second_sink));
    try harness.runUntilFinished(2);
    for (0..2) |_| {
        const stream = harness.client.nextFinished().?;
        try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, stream.end().?);
    }
    try std.testing.expectEqualStrings("first", first_sink[0..5]);
    try std.testing.expectEqualStrings("again", second_sink[0..5]);
    try std.testing.expectEqual(@as(u8, 0), first.replays());
    try std.testing.expectEqual(@as(u8, 1), second.replays());
    try std.testing.expectEqual(@as(u32, 2), harness.peer.seen.connections);
    try std.testing.expectEqualStrings("2", harness.peer.streams.items[2].body.items);
    first.deinit();
    second.deinit();
}

test "REFUSED_STREAM is sent again at most four times" {
    const Refuse = struct {
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.reset(stream, 0x7);
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .on_request = Refuse.handle } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .refused, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqual(@as(u8, 4), stream.replays());
    try std.testing.expectEqual(@as(usize, 5), harness.peer.streams.items.len);
    try std.testing.expectEqual(@as(u32, 1), harness.peer.seen.connections);
    stream.deinit();
}

test "a reset after a response began is not sent again" {
    const Respond = struct {
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.respondHeadOnly(stream, 200);
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .on_request = Respond.handle } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntil({}, struct {
        fn done(h: *Harness, _: void) bool {
            return h.receiver.heads == 1;
        }
    }.done);
    // The response began, so REFUSED_STREAM no longer proves the server
    // left the request unprocessed.
    harness.peer.reset(harness.peer.streams.items[0], 0x7);
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .reset_by_peer, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqual(@as(usize, 1), harness.peer.streams.items.len);
    stream.deinit();
}

test "cancel resets one stream and keeps its connection and siblings" {
    const harness = try Harness.create(.{ .peer = .{ .on_request = hold } });
    defer harness.destroy();
    var first: h2.Stream = .idle;
    var second: h2.Stream = .idle;
    var first_sink: [8]u8 = undefined;
    var second_sink: [8]u8 = undefined;
    try harness.launch(&first, bytesRequest(harness.endpoint, "1", &first_sink));
    try harness.launch(&second, bytesRequest(harness.endpoint, "2", &second_sink));
    try harness.runUntilPeerStreams(2);
    harness.client.cancel(&first);
    harness.client.cancel(&first);
    try harness.runUntil({}, struct {
        fn done(h: *Harness, _: void) bool {
            return h.peer.seen.rst_received == 1;
        }
    }.done);
    harness.peer.respond(harness.peer.streams.items[1], 200, "ok");
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&second));
    try std.testing.expectEqual(@as(u32, 1), harness.peer.seen.connections);
    try std.testing.expectEqual(@as(u32, 1), harness.peer.seen.rst_received);
    try std.testing.expectEqual(@as(u32, 1), harness.receiver.retired);
    first.deinit();
    second.deinit();
}

test "small DATA frames decoded from one read reach the sink in one write" {
    const Chunked = struct {
        const body: [200]u8 = blk: {
            var bytes: [200]u8 = undefined;
            for (&bytes, 0..) |*byte, index| byte.* = 'a' + index % 10;
            break :blk bytes;
        };
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.respond(stream, 200, &body);
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .data_chunk_bytes = 10, .on_request = Chunked.handle } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [256]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqualStrings(&Chunked.body, sink[0..200]);
    try std.testing.expectEqual(@as(u32, 1), harness.receiver.bodies);
    stream.deinit();
}

test "a stream that closes mid-read leaves its siblings one write each" {
    const Both = struct {
        const long: [200]u8 = @splat('l');
        const short: [20]u8 = @splat('s');
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            if (stream.index != 1) return;
            // Both bodies go out in one flush, their DATA frames interleaved,
            // so the short stream ends inside the read that carries the long.
            peer.respond(peer.streams.items[0], 200, &long);
            peer.respond(stream, 200, &short);
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .data_chunk_bytes = 10, .interleave = true, .on_request = Both.handle } });
    defer harness.destroy();
    var long: h2.Stream = .idle;
    var short: h2.Stream = .idle;
    var long_sink: [256]u8 = undefined;
    var short_sink: [32]u8 = undefined;
    try harness.launch(&long, bytesRequest(harness.endpoint, "x", &long_sink));
    try harness.launch(&short, bytesRequest(harness.endpoint, "x", &short_sink));
    try harness.runUntilFinished(2);
    while (harness.client.nextFinished()) |stream| {
        try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, stream.end().?);
    }
    try std.testing.expectEqualSlices(u8, &Both.long, long_sink[0..@intCast(long.responseLength())]);
    try std.testing.expectEqualSlices(u8, &Both.short, short_sink[0..@intCast(short.responseLength())]);
    try std.testing.expectEqual(@as(u32, 2), harness.receiver.bodies);
}

test "a refused sink returns connection credit, so siblings keep flowing" {
    const Both = struct {
        var big: [64 * 1024]u8 = @splat('b');
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.respond(stream, 200, &big);
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .on_request = Both.handle } });
    defer harness.destroy();
    var small: h2.Stream = .idle;
    var large: h2.Stream = .idle;
    var small_sink: [8]u8 = undefined;
    var large_sink: [64 * 1024]u8 = undefined;
    try harness.launch(&small, bytesRequest(harness.endpoint, "x", &small_sink));
    try harness.launch(&large, bytesRequest(harness.endpoint, "x", &large_sink));
    try harness.runUntilFinished(2);
    try std.testing.expectEqual(h2.End{ .cause = .sink_refused, .request_sent = true }, try harness.collect(&small));
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&large));
    try std.testing.expectEqual(@as(u64, Both.big.len), large.responseLength());
}

test "a peer allowing 100 streams gets a second connection for the 101st" {
    const harness = try Harness.create(.{ .peer = .{ .on_request = hold }, .capacity = 101 });
    defer harness.destroy();
    var streams: [101]h2.Stream = @splat(.idle);
    var sinks: [101][8]u8 = undefined;
    for (&streams, &sinks) |*stream, *sink| try harness.launch(stream, bytesRequest(harness.endpoint, "x", sink));
    try harness.runUntilPeerStreams(101);
    try std.testing.expectEqual(@as(u32, 2), harness.peer.seen.connections);
    for (harness.peer.streams.items) |stream| harness.peer.respond(stream, 200, "ok");
    try harness.runUntilFinished(101);
    while (harness.client.nextFinished()) |stream| {
        try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, stream.end().?);
    }
}

test "trailers arrive as their own block" {
    const Trailed = struct {
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.respondWith(stream, 200, "body", true);
        }
    };
    const harness = try Harness.create(.{ .peer = .{ .on_request = Trailed.handle } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqual(@as(u32, 1), harness.receiver.heads);
    try std.testing.expectEqual(@as(u32, 1), harness.receiver.trailers);
    stream.deinit();
}

test "local refusals end the stream and reset it" {
    {
        const harness = try Harness.create(.{});
        defer harness.destroy();
        harness.receiver.refuse_heads = true;
        var stream: h2.Stream = .idle;
        var sink: [8]u8 = undefined;
        try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
        try harness.runUntilFinished(1);
        try std.testing.expectEqual(h2.End{ .cause = .rejected_headers, .request_sent = true }, try harness.collect(&stream));
        stream.deinit();
    }
    {
        const harness = try Harness.create(.{});
        defer harness.destroy();
        var stream: h2.Stream = .idle;
        var sink: [1]u8 = undefined;
        try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
        try harness.runUntilFinished(1);
        try std.testing.expectEqual(h2.End{ .cause = .sink_refused, .request_sent = true }, try harness.collect(&stream));
        try std.testing.expectEqual(@as(u64, 0), stream.responseLength());
        stream.deinit();
    }
}

test "a short request body file ends the stream" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body_file = try tmp.dir.createFile(io, "body", .{ .read = true });
    defer body_file.close(io);
    try body_file.writePositionalAll(io, "only ten b", 0);
    const harness = try Harness.create(.{ .peer = .{ .on_request = hold } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.launch(&stream, .{
        .endpoint = harness.endpoint,
        .fields = &.{},
        .body = .{ .file = .{ .handle = body_file.handle, .length = 100 } },
        .sink = .{ .buffer = &sink },
    });
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .body_failed, .request_sent = true }, try harness.collect(&stream));
    stream.deinit();
}

test "an inactive stream ends and is reset" {
    const harness = try Harness.create(.{ .peer = .{ .on_request = hold }, .inactivity_ns = 100 * ns_per_ms });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .inactive, .request_sent = true }, try harness.collect(&stream));
    try harness.runUntil({}, struct {
        fn done(h: *Harness, _: void) bool {
            return h.peer.seen.rst_received == 1;
        }
    }.done);
    stream.deinit();
}

fn sleepMs(ms: c_int) void {
    _ = std.c.poll(&[_]std.c.pollfd{}, 0, ms);
}

test "an overdue pending stream ends before it is sent, even with room on a warm connection" {
    const harness = try Harness.create(.{ .inactivity_ns = 100 * ns_per_ms });
    defer harness.destroy();
    var warm: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.launch(&warm, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&warm));

    var late: h2.Stream = .idle;
    try harness.launch(&late, bytesRequest(harness.endpoint, "x", &sink));
    sleepMs(150);
    try harness.client.drive(&harness.receiver);
    try std.testing.expectEqual(h2.End{ .cause = .inactive, .request_sent = false }, try harness.collect(&late));
    try harness.runFor(20 * ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), harness.peer.streams.items.len);
}

test "a read cap defers expiry only for streams on that connection" {
    const harness = try Harness.create(.{ .peer = .{ .on_request = hold }, .inactivity_ns = 100 * ns_per_ms });
    defer harness.destroy();
    const quiet = try Peer.start(std.testing.allocator, .{ .on_request = hold });
    defer quiet.stop();
    const quiet_endpoint = try harness.client.addEndpoint(quiet.url());

    // Five streams' windows hold more than one drive's read allowance.
    var busy: [5]h2.Stream = @splat(.idle);
    var sinks: [5][32 * 1024]u8 = undefined;
    for (&busy, &sinks) |*stream, *sink| try harness.launch(stream, bytesRequest(harness.endpoint, "x", sink));
    var silent: h2.Stream = .idle;
    var silent_sink: [8]u8 = undefined;
    try harness.launch(&silent, bytesRequest(quiet_endpoint, "x", &silent_sink));
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    while (harness.peer.streams.items.len < 5 or quiet.streams.items.len < 1) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds - start > 5 * std.time.ns_per_s) return error.Timeout;
        try harness.step();
        try quiet.pump();
    }

    sleepMs(150);
    var response: [32 * 1024]u8 = undefined;
    @memset(&response, 'r');
    for (harness.peer.streams.items) |stream| harness.peer.respond(stream, 200, &response);
    try harness.peer.pump();
    try harness.client.drive(&harness.receiver);
    // The silent stream's connection was drained, so it expires; the busy
    // connection stopped at its allowance, so none of its streams do.
    try std.testing.expectEqual(@as(usize, 1), harness.client.finishedCount());
    try std.testing.expectEqual(h2.End{ .cause = .inactive, .request_sent = true }, try harness.collect(&silent));

    try harness.runUntilFinished(5);
    while (harness.client.nextFinished()) |stream| {
        try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, stream.end().?);
        try std.testing.expectEqual(@as(u64, response.len), stream.responseLength());
    }
}

test "a quiet connection is pinged, and one that never answers is dead" {
    const liveness: h2.Liveness = .{ .ping_after_quiet_ns = 50 * ns_per_ms, .ping_timeout_ns = 100 * ns_per_ms };
    {
        const harness = try Harness.create(.{ .peer = .{ .on_request = hold }, .liveness = liveness });
        defer harness.destroy();
        var stream: h2.Stream = .idle;
        var sink: [8]u8 = undefined;
        try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
        try harness.runFor(400 * ns_per_ms);
        try std.testing.expectEqual(@as(usize, 0), harness.client.finishedCount());
        try std.testing.expect(harness.peer.seen.pings_received >= 2);
        harness.peer.respond(harness.peer.streams.items[0], 200, "ok");
        try harness.runUntilFinished(1);
        try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
        stream.deinit();
    }
    {
        const harness = try Harness.create(.{ .peer = .{ .on_request = hold, .ignore_ping = true }, .liveness = liveness });
        defer harness.destroy();
        var stream: h2.Stream = .idle;
        var sink: [8]u8 = undefined;
        try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
        try harness.runUntilFinished(1);
        try std.testing.expectEqual(h2.End{ .cause = .peer_silent, .request_sent = true }, try harness.collect(&stream));
        try std.testing.expectEqual(@as(u32, 1), harness.peer.seen.pings_received);
        stream.deinit();
    }
}

test "a request that never left is settled once, as never sent" {
    const harness = try Harness.create(.{ .peer = .{ .speak_http11 = true } });
    defer harness.destroy();
    var streams: [2]h2.Stream = @splat(.idle);
    var sinks: [2][8]u8 = undefined;
    for (&streams, &sinks) |*stream, *sink| try harness.launch(stream, bytesRequest(harness.endpoint, "x", sink));
    try harness.runUntilFinished(2);
    for (&streams) |*stream| {
        try std.testing.expectEqual(h2.End{ .cause = .h2_refused, .request_sent = false }, try harness.collect(stream));
        stream.deinit();
    }
    try std.testing.expectEqual(@as(u32, 2), harness.receiver.retired);
    try harness.runFor(20 * ns_per_ms);
    try std.testing.expectEqual(@as(?*h2.Stream, null), harness.client.nextFinished());
}

test "a refused connection fails its streams as never sent" {
    var client: h2.Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .{
        .stream_capacity = 2,
        .inactivity_ns = std.time.ns_per_s,
        .connect_timeout_ns = std.time.ns_per_s,
    });
    defer client.deinit();
    // A port that was free a moment ago and has no listener now. A bound
    // socket that never listens would hold the port, but Darwin drops SYNs
    // to it instead of refusing them, so the connect would time out.
    const peer = try Peer.start(std.testing.allocator, .{});
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}", .{peer.url()});
    peer.stop();
    const endpoint = try client.addEndpoint(url);
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try client.prepare(&stream, bytesRequest(endpoint, "x", &sink));
    client.launch(&stream);
    var receiver: Receiver = .{};
    var steps: u32 = 0;
    while (client.finishedCount() == 0) : (steps += 1) {
        if (steps > 2000) return error.Timeout;
        try client.drive(&receiver);
        try client.wait(1);
    }
    try std.testing.expectEqual(&stream, client.nextFinished().?);
    try std.testing.expectEqual(h2.End{ .cause = .connect_failed, .request_sent = false }, stream.end().?);
    stream.deinit();
}

test "a prepared stream that is never launched opens nothing" {
    const harness = try Harness.create(.{});
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    try harness.client.prepare(&stream, .{
        .endpoint = harness.endpoint,
        .fields = &.{.{ .name = "authorization", .value = "Bearer secret", .sensitive = true }},
        .body = .{ .bytes = "x" },
        .sink = .{ .buffer = &sink },
    });
    try harness.runFor(20 * ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), harness.peer.seen.connections);
    harness.client.cancel(&stream);
    stream.deinit();
}

test "requests the client cannot send are refused before anything opens" {
    const harness = try Harness.create(.{});
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [8]u8 = undefined;
    for ([_]h2.Field{
        .{ .name = "Authorization", .value = "x" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "content-length", .value = "1" },
        .{ .name = "x-value", .value = "a\r\nb" },
    }) |field| {
        try std.testing.expectError(error.InvalidRequest, harness.client.prepare(&stream, .{
            .endpoint = harness.endpoint,
            .fields = &.{field},
            .body = .{ .bytes = "" },
            .sink = .{ .buffer = &sink },
        }));
    }
    // Never dereferenced: prepare refuses a sink its record cannot describe.
    const huge = @as([*]u8, &sink)[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try std.testing.expectError(error.InvalidRequest, harness.client.prepare(&stream, bytesRequest(harness.endpoint, "", huge)));
    try std.testing.expectError(error.CleartextNotLoopback, harness.client.addEndpoint("http://example.com/"));
}

test "a wait with the largest timeout still returns on wake" {
    const harness = try Harness.create(.{});
    defer harness.destroy();
    harness.client.wake();
    try harness.client.wait(std.math.maxInt(u32));
}

// ---------------------------------------------------------------------- TLS

test "https: a request completes over TLS with ALPN h2" {
    const harness = try Harness.create(.{ .peer = .{ .tls = .h2 } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [64]u8 = undefined;
    try harness.launch(&stream, .{
        .endpoint = harness.endpoint,
        .fields = &.{.{ .name = "authorization", .value = "Bearer secret", .sensitive = true }},
        .body = .{ .bytes = "{\"input\":1}" },
        .sink = .{ .buffer = &sink },
    });
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqualStrings("ok", sink[0..@intCast(stream.responseLength())]);
    try std.testing.expectEqualStrings("Bearer secret", harness.peer.streams.items[0].authorization.items);
    try std.testing.expectEqualStrings("{\"input\":1}", harness.peer.streams.items[0].body.items);
}

test "https: large bodies both ways stay within the stream window" {
    var body: [100 * 1024]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var response: [300 * 1024]u8 = undefined;
    for (&response, 0..) |*byte, index| byte.* = @truncate(index * 13);
    const Respond = struct {
        var bytes: []const u8 = &.{};
        fn handle(peer: *Peer, stream: *Peer.Stream) void {
            peer.respond(stream, 200, bytes);
        }
    };
    Respond.bytes = &response;
    const harness = try Harness.create(.{ .peer = .{ .tls = .h2, .on_request = Respond.handle } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [300 * 1024]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, &body, &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
    try std.testing.expectEqualSlices(u8, &body, harness.peer.streams.items[0].body.items);
    try std.testing.expectEqualSlices(u8, &response, sink[0..@intCast(stream.responseLength())]);
    try std.testing.expect(harness.peer.seen.max_stream_window <= h2.stream_window_bytes);
}

test "https by name: the lookup runs, every address is tried, and the name is verified" {
    // localhost may resolve to ::1 first; the peer listens on 127.0.0.1 only.
    const harness = try Harness.create(.{ .peer = .{ .tls = .h2, .url_host = "localhost" } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [64]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = .complete, .request_sent = true }, try harness.collect(&stream));
}

test "https: a partial TLS record waits for the socket instead of spinning" {
    const harness = try Harness.create(.{ .peer = .{ .tls = .h2, .on_request = hold } });
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [64]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilPeerStreams(1);
    try harness.runFor(20 * ns_per_ms);

    // The peer's next record goes to memory, and only its first bytes reach
    // the socket: the client reads them and needs the rest.
    const connection = harness.peer.connections.items[0];
    const ssl = connection.ssl.?;
    const memory = c.BIO_new(c.BIO_s_mem()) orelse return error.OutOfMemory;
    c.SSL_set0_wbio(ssl, memory);
    var written: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), c.SSL_write_ex(ssl, "a whole record of plaintext", 27, &written));
    var record: [128]u8 = undefined;
    const record_len = c.BIO_read(memory, &record, record.len);
    try std.testing.expect(record_len > 10);
    try std.testing.expectEqual(@as(isize, 10), std.c.send(connection.socket, &record, 10, 0));
    try harness.client.wait(100);
    try harness.client.drive(&harness.receiver);

    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try harness.client.wait(200);
    const waited = std.Io.Clock.awake.now(std.testing.io).nanoseconds - start;
    try std.testing.expect(waited >= 150 * ns_per_ms);
    harness.client.cancel(&stream);
}

fn expectSetupFailure(config: Harness.Config, cause: h2.Cause) !void {
    const harness = try Harness.create(config);
    defer harness.destroy();
    var stream: h2.Stream = .idle;
    var sink: [64]u8 = undefined;
    try harness.launch(&stream, bytesRequest(harness.endpoint, "x", &sink));
    try harness.runUntilFinished(1);
    try std.testing.expectEqual(h2.End{ .cause = cause, .request_sent = false }, try harness.collect(&stream));
    try std.testing.expectEqual(@as(usize, 0), harness.peer.streams.items.len);
}

test "https: a leaf from another issuer is untrusted, before any request byte" {
    try expectSetupFailure(.{ .peer = .{ .tls = .h2, .untrusted_issuer = true } }, .untrusted_peer);
}

test "https: a leaf for another name is untrusted" {
    try expectSetupFailure(.{ .peer = .{ .tls = .h2, .leaf_names = "DNS:other.example" } }, .untrusted_peer);
    try expectSetupFailure(.{ .peer = .{ .tls = .h2, .leaf_names = "DNS:localhost" } }, .untrusted_peer);
}

test "https: a peer that does not choose h2 is refused" {
    try expectSetupFailure(.{ .peer = .{ .tls = .no_alpn } }, .h2_refused);
}

test "https: a name that does not resolve fails the setup" {
    try expectSetupFailure(.{
        .peer = .{ .tls = .h2 },
        .url = "https://h2-test.invalid/v1/responses",
        .connect_timeout_ns = 30 * std.time.ns_per_s,
    }, .resolve_failed);
}

test "https: trust is loaded by the first https endpoint, and a missing CA file fails it" {
    var client: h2.Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .{
        .stream_capacity = 1,
        .inactivity_ns = std.time.ns_per_s,
        .connect_timeout_ns = std.time.ns_per_s,
        .trust = .{ .ca_file = "/nonexistent/h2-ca.pem" },
    });
    defer client.deinit();
    _ = try client.addEndpoint("http://127.0.0.1:9/v1");
    try std.testing.expectError(error.InvalidCaFile, client.addEndpoint("https://127.0.0.1:9/v1"));
}
