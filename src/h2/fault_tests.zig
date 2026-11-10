//! The client under seeded faults: short reads and writes, EAGAIN and a
//! cut at a random byte on its socket (`testing/Faults.zig`), and GOAWAY,
//! RST_STREAM and REFUSED_STREAM from the peer at random points. One seed
//! decides everything, so a failure replays from the seed it prints.
//!
//! The checks take their facts from the peer, not from the client's own
//! flags:
//! - each stream settles exactly once, its body retired once;
//! - a request the peer saw ends with `request_sent`;
//! - only an attempt the peer proved unprocessed (REFUSED_STREAM, or above
//!   its GOAWAY's last stream id) is ever followed by another;
//! - a complete stream carries the peer's whole answer to that request;
//! - a cancelled stream sees no event after its cancel and never finishes;
//! - no stream or connection window opens past what the client grants;
//! - nothing spins: a ready socket is used within a few drives, and every
//!   stream settles within the round limit once the chaos stops.
//!
//! `RUI_H2_FAULT_SEED=<n>` runs one seed; `RUI_H2_FAULT_SEEDS=<count>` runs
//! that many from 1; `RUI_H2_FAULT_TRACE=1` names each seed as it starts,
//! for a crash, which prints none.
const std = @import("std");
const test_poll = @import("test_poll");
const h2 = @import("h2.zig");
const c = @import("h2_c");
const Peer = @import("testing/Peer.zig");
const Faults = @import("testing/Faults.zig");
const Engine = @import("Engine.zig");
const policy = @import("policy.zig");
const Record = @import("Stream.zig");

const default_seeds = 300;
const max_requests = 12;
const capacity = 16;
/// Peer closes, GOAWAYs, refusals mid-upload, outages, cancels and drains
/// happen only in these first rounds. After them nothing ends a stream
/// that stopped making progress, so a stall fails at `max_rounds`.
const chaos_rounds = 150;
const max_rounds = 3000;
/// Drives in a row that find a socket ready and move nothing.
const max_idle_ready_drives = 40;

const Request = struct {
    stream: h2.Stream = .idle,
    id_text: [4]u8 = undefined,
    id_len: usize = 0,
    body: []u8 = &.{},
    response: []u8 = &.{},
    sink: []u8 = &.{},
    /// The receiver refuses the body event that would pass this many bytes.
    refuse_body_past: ?u64 = null,
    body_seen: u64 = 0,
    cancelled: bool = false,
    events_after_cancel: u32 = 0,
    finals: u32 = 0,
    retired: u32 = 0,
    collected: u32 = 0,

    fn whole(self: *const Request) bool {
        return self.sink.len >= self.response.len and self.refuse_body_past == null;
    }

    fn id(self: *const Request) []const u8 {
        return self.id_text[0..self.id_len];
    }
};

/// What the peer did with one stream it saw.
const Fate = enum {
    /// Seen, no answer yet.
    open,
    /// Complete, answer held back for a later round.
    deferred,
    answered,
    /// The head went out; a reset follows in a later round.
    head_only,
    /// Reset with a code other than REFUSED_STREAM: processed.
    reset,
    /// REFUSED_STREAM before any answer: proven unprocessed.
    refused,
};

const Goaway = struct { connection: *Peer.Connection, last: i32 };

const Run = struct {
    random: std.Random.DefaultPrng,
    requests: []Request,
    max_streams: u32,
    /// Parallel to `peer.streams`.
    fates: std.ArrayList(Fate) = .empty,
    goaways: std.ArrayList(Goaway) = .empty,
    round: u32 = 0,
    /// The peer refuses connections until this round.
    down_until: u32 = 0,
    counts: struct { goaway: u32 = 0, refused: u32 = 0, reset: u32 = 0, peer_close: u32 = 0, outage: u32 = 0 } = .{},

    fn requestOf(self: *Run, stream: *const Peer.Stream) *Request {
        const index = std.fmt.parseInt(usize, stream.test_id.items, 10) catch unreachable;
        return &self.requests[index];
    }

    fn fate(self: *Run, stream: *const Peer.Stream) *Fate {
        while (self.fates.items.len <= stream.index) self.fates.append(std.testing.allocator, .open) catch @panic("OOM");
        return &self.fates.items[stream.index];
    }

    /// REFUSED_STREAM, or a stream id above its connection's GOAWAY. Taken
    /// from the GOAWAY itself, since the peer may read a stream's HEADERS
    /// after it queued the GOAWAY and before it sent it.
    fn provenUnprocessed(self: *Run, stream: *const Peer.Stream) bool {
        if (self.fate(stream).* == .refused) return true;
        const last = self.goawayLast(stream.connection) orelse return false;
        return stream.id > last;
    }

    fn goawayLast(self: *Run, connection: *const Peer.Connection) ?i32 {
        for (self.goaways.items) |sent| if (sent.connection == connection) return sent.last;
        return null;
    }

    fn live(stream: *const Peer.Stream) bool {
        return !stream.connection.closed and !stream.closed;
    }

    fn chance(self: *Run, percent: u8) bool {
        return self.random.random().uintLessThan(u8, 100) < percent;
    }

    fn chaos(self: *Run, percent: u8) bool {
        return self.round < chaos_rounds and self.chance(percent);
    }

    /// The peer's `on_request`: the request arrived whole.
    fn onRequest(peer: *Peer, stream: *Peer.Stream) void {
        const self: *Run = @ptrCast(@alignCast(peer.options.context.?));
        const state = self.fate(stream);
        if (state.* != .open) return;
        // Above a GOAWAY's last stream id: never processed.
        if (self.goawayLast(stream.connection)) |last| if (stream.id > last) return;
        const roll = self.random.random().uintLessThan(u8, 100);
        if (roll < 55) {
            peer.respond(stream, 200, self.requestOf(stream).response);
            state.* = .answered;
        } else if (roll < 72) {
            state.* = .deferred;
        } else if (roll < 84) {
            peer.reset(stream, c.NGHTTP2_REFUSED_STREAM);
            state.* = .refused;
            self.counts.refused += 1;
        } else if (roll < 92) {
            peer.reset(stream, c.NGHTTP2_INTERNAL_ERROR);
            state.* = .reset;
            self.counts.reset += 1;
        } else {
            peer.respondHeadOnly(stream, 200);
            state.* = .head_only;
        }
    }

    /// Between pumps: held answers go out, mid-upload refusals, GOAWAYs,
    /// abrupt closes and outages.
    fn act(self: *Run, peer: *Peer) void {
        if (self.chaos(1)) {
            self.down_until = self.round + self.random.random().intRangeAtMost(u32, 1, 30);
            self.counts.outage += 1;
        }
        peer.refuse_connections = self.round < self.down_until;
        for (peer.streams.items) |stream| {
            const state = self.fate(stream);
            if (!live(stream)) continue;
            switch (state.*) {
                .deferred => if (self.chance(50)) {
                    peer.respond(stream, 200, self.requestOf(stream).response);
                    state.* = .answered;
                },
                .head_only => if (self.chance(30)) {
                    peer.reset(stream, c.NGHTTP2_CANCEL);
                    state.* = .reset;
                    self.counts.reset += 1;
                },
                .open => if (!stream.complete and self.chaos(3)) {
                    peer.reset(stream, c.NGHTTP2_REFUSED_STREAM);
                    state.* = .refused;
                    self.counts.refused += 1;
                },
                .answered, .reset, .refused => {},
            }
        }
        for (peer.connections.items) |connection| {
            if (connection.closed or connection.session == null) continue;
            if (self.goawayLast(connection) == null and self.chaos(2)) self.goaway(peer, connection);
            if (self.chaos(1)) {
                peer.closeConnection(connection);
                self.counts.peer_close += 1;
            }
        }
    }

    /// GOAWAY whose last stream id covers every stream this connection
    /// processed, so each stream above it is one the peer never processes.
    fn goaway(self: *Run, peer: *Peer, connection: *Peer.Connection) void {
        var last: i32 = 0;
        for (peer.streams.items) |stream| {
            if (stream.connection != connection) continue;
            switch (self.fate(stream).*) {
                .answered, .head_only, .reset, .deferred => last = @max(last, stream.id),
                .open, .refused => {},
            }
        }
        // Sometimes also keep an unanswered stream below it, to be answered.
        if (self.chance(30)) for (peer.streams.items) |stream| {
            if (stream.connection == connection and stream.id > last and self.fate(stream).* == .open) {
                last = stream.id;
                break;
            }
        };
        const code: u32 = if (self.chance(80)) c.NGHTTP2_NO_ERROR else c.NGHTTP2_INTERNAL_ERROR;
        peer.goaway(connection, last, code);
        self.goaways.append(std.testing.allocator, .{ .connection = connection, .last = last }) catch @panic("OOM");
        self.counts.goaway += 1;
    }

    pub fn observe(self: *Run, stream: *h2.Stream, event: h2.Event) h2.Verdict {
        const request: *Request = @fieldParentPtr("stream", stream);
        _ = self;
        if (request.cancelled) request.events_after_cancel += 1;
        switch (event) {
            .head => |head| if (head.kind == .final) {
                request.finals += 1;
            },
            .body => |bytes| {
                request.body_seen += bytes;
                if (request.refuse_body_past) |limit| if (request.body_seen > limit) return .refuse;
            },
            .body_retired => request.retired += 1,
        }
        return .accept;
    }
};

const Totals = struct {
    faults: Faults.Counts = .{},
    goaway: u32 = 0,
    refused: u32 = 0,
    reset: u32 = 0,
    peer_close: u32 = 0,
    resent: u32 = 0,
    cancelled: u32 = 0,
    retired: u32 = 0,
    outage: u32 = 0,
    causes: std.EnumArray(policy.Cause, u32) = .initFill(0),
};

fn fill(bytes: []u8, salt: usize) void {
    for (bytes, 0..) |*byte, index| byte.* = @truncate((salt *% 131 +% index *% 7) % 251);
}

/// One seed: a peer, a client with faults, and requests run to settlement.
fn runSeed(seed: u64, totals: *Totals) !void {
    const allocator = std.testing.allocator;
    var setup = std.Random.DefaultPrng.init(seed);
    const random = setup.random();

    var requests: [max_requests]Request = @splat(Request{});
    const count = random.intRangeAtMost(usize, 1, max_requests);
    defer for (requests[0..count]) |*request| {
        allocator.free(request.body);
        allocator.free(request.response);
        allocator.free(request.sink);
    };
    const body_sizes = [_]usize{ 0, 1, 900, 20_000, 90_000 };
    const response_sizes = [_]usize{ 0, 2, 3_000, 40_000 };
    for (requests[0..count], 0..) |*request, index| {
        request.id_len = (std.fmt.bufPrint(&request.id_text, "{d}", .{index}) catch unreachable).len;
        request.body = try allocator.alloc(u8, body_sizes[random.uintLessThan(usize, body_sizes.len)]);
        fill(request.body, index);
        request.response = try allocator.alloc(u8, response_sizes[random.uintLessThan(usize, response_sizes.len)]);
        fill(request.response, index + 1000);
        // Some answers do not fit, or are refused partway: the stream ends
        // early and its credit must still return to the connection.
        const shrink = request.response.len > 0 and random.uintLessThan(u8, 100) < 10;
        request.sink = try allocator.alloc(u8, if (shrink) random.uintLessThan(usize, request.response.len) else request.response.len + 1);
        if (request.response.len > 0 and random.uintLessThan(u8, 100) < 10)
            request.refuse_body_past = random.uintLessThan(u64, request.response.len);
    }

    var run: Run = .{ .random = .init(seed ^ 0x5eed_0f_9ee5), .requests = requests[0..count], .max_streams = undefined };
    defer run.fates.deinit(allocator);
    defer run.goaways.deinit(allocator);
    const tls = random.uintLessThan(u8, 100) < 30;
    const stream_limits = [_]u32{ 1, 2, 3, 100 };
    const chunk_sizes = [_]usize{ 0, 1_000, 5_000 };
    const max_streams = stream_limits[random.uintLessThan(usize, stream_limits.len)];
    run.max_streams = max_streams;
    const peer = try Peer.start(allocator, .{
        .tls = if (tls) .h2 else .none,
        .max_concurrent_streams = max_streams,
        .data_chunk_bytes = chunk_sizes[random.uintLessThan(usize, chunk_sizes.len)],
        .on_request = Run.onRequest,
        .context = &run,
    });
    defer peer.stop();

    var client: h2.Client = undefined;
    try client.init(allocator, std.testing.io, .{
        .stream_capacity = capacity,
        // Far past the round limit: a stream that ends inactive stalled.
        .inactivity_ns = 60 * std.time.ns_per_s,
        .connect_timeout_ns = 30 * std.time.ns_per_s,
        .trust = if (tls) .{ .ca_file = peer.caPath() } else .system,
    });
    defer client.deinit();
    // Each seed draws its own rates, so some cut early and often.
    const percents = [_]u8{ 0, 10, 30, 60 };
    const spans = [_]u32{ 200, 4_000, 64_000 };
    var faults: Faults = .init(seed, .{
        .short = percents[random.uintLessThan(usize, percents.len)],
        .again = percents[random.uintLessThan(usize, percents.len)],
        .cut = percents[random.uintLessThan(usize, percents.len)],
        .cut_span = spans[random.uintLessThan(usize, spans.len)],
    });
    Engine.of(&client).faults = &faults;
    // A failed check leaves streams unsettled; Client.deinit asserts none are.
    defer for (requests[0..count]) |*request| {
        if (Record.of(&request.stream).state != .idle) client.cancel(&request.stream);
        request.stream.deinit();
    };
    const endpoint = try client.addEndpoint(peer.url());

    for (requests[0..count]) |*request| {
        try client.prepare(&request.stream, .{
            .endpoint = endpoint,
            .fields = &.{.{ .name = "x-test-id", .value = request.id() }},
            .body = .{ .bytes = request.body },
            .sink = .{ .buffer = request.sink },
        });
        client.launch(&request.stream);
    }

    var idle_ready: u32 = 0;
    var rounds: u32 = 0;
    var settled: usize = 0;
    while (settled < count) : (rounds += 1) {
        run.round = rounds;
        if (rounds == max_rounds) return fail(seed, "stalled: {d} of {d} streams settled after {d} rounds", .{ settled, count, rounds });
        for (0..2) |half| {
            const ready = readyNow(&client);
            const before = progress(&client, &faults);
            try client.drive(&run);
            const moved = progress(&client, &faults) != before;
            idle_ready = if (ready and !moved) idle_ready + 1 else 0;
            if (idle_ready > max_idle_ready_drives) return fail(seed, "spinning: {d} drives in a row found a socket ready and moved nothing", .{idle_ready});
            if (half == 0) {
                try peer.pump();
                run.act(peer);
                try peer.pump();
            }
        }
        while (client.nextFinished()) |stream| {
            const request: *Request = @fieldParentPtr("stream", stream);
            request.collected += 1;
            settled += 1;
        }
        for (requests[0..count]) |*request| {
            if (request.collected > 0 or request.cancelled or !run.chaos(1) or !run.chance(30)) continue;
            client.cancel(&request.stream);
            request.cancelled = true;
            settled += 1;
            totals.cancelled += 1;
        }
        // Draining with streams in flight, as a caller retiring an endpoint does.
        if (run.chaos(1)) {
            client.retireConnections(endpoint);
            totals.retired += 1;
        }
        try client.wait(1);
    }

    // Exactly once: nothing more ever finishes.
    for (0..3) |_| {
        try client.drive(&run);
        try peer.pump();
    }
    if (client.nextFinished() != null) return fail(seed, "a stream finished twice", .{});
    try check(seed, &run, peer);

    totals.faults.short += faults.counts.short;
    totals.faults.again += faults.counts.again;
    totals.faults.cut += faults.counts.cut;
    totals.goaway += run.counts.goaway;
    totals.refused += run.counts.refused;
    totals.reset += run.counts.reset;
    totals.peer_close += run.counts.peer_close;
    totals.outage += run.counts.outage;
    for (requests[0..count]) |*request| {
        if (request.stream.end()) |end| totals.causes.getPtr(end.cause).* += 1;
    }
    for (peer.streams.items, 0..) |stream, index| {
        if (index > 0 and attemptsBefore(peer, stream) > 0) totals.resent += 1;
    }
}

fn attemptsBefore(peer: *const Peer, stream: *const Peer.Stream) usize {
    var count: usize = 0;
    for (peer.streams.items[0..stream.index]) |earlier| {
        if (std.mem.eql(u8, earlier.test_id.items, stream.test_id.items)) count += 1;
    }
    return count;
}

/// Grows whenever the client moves a byte, ends a stream or starts a
/// connection. A new connection is work, not a spin: retrying an origin
/// whose setups fail is `policy.connectionsToOpen`'s decision.
fn progress(client: *h2.Client, faults: *const Faults) u64 {
    return faults.counts.moved +% client.finishedCount() +% Engine.of(client).connection_serial;
}

/// Whether the client's next wait would return at once.
fn readyNow(client: *h2.Client) bool {
    const armed = client.armWait(1);
    if (armed.timeout_ms == 0) return true;
    return std.c.poll(armed.pollfds.ptr, @intCast(armed.pollfds.len), 0) > 0;
}

/// The first attempt of request `id` that was followed by another though
/// the peer never proved it unprocessed.
fn unprovenResend(run: *Run, peer: *const Peer, id: []const u8) ?*Peer.Stream {
    var last: ?*Peer.Stream = null;
    for (peer.streams.items) |stream| {
        if (!std.mem.eql(u8, stream.test_id.items, id)) continue;
        if (last) |earlier| if (!run.provenUnprocessed(earlier)) return earlier;
        last = stream;
    }
    return null;
}

fn check(seed: u64, run: *Run, peer: *Peer) !void {
    for (run.requests, 0..) |*request, index| {
        if (request.finals > 1) return fail(seed, "request {d} saw {d} final heads", .{ index, request.finals });
        if (request.cancelled) {
            if (request.collected != 0) return fail(seed, "request {d} was collected after its cancel", .{index});
            if (request.events_after_cancel != 0) return fail(seed, "request {d} saw {d} events after its cancel", .{ index, request.events_after_cancel });
            if (request.retired > 1) return fail(seed, "request {d} retired its body {d} times", .{ index, request.retired });
            continue;
        }
        if (request.collected != 1) return fail(seed, "request {d} collected {d} times", .{ index, request.collected });
        if (request.retired != 1) return fail(seed, "request {d} retired its body {d} times", .{ index, request.retired });
        const end = request.stream.end().?;

        if (unprovenResend(run, peer, request.id())) |earlier|
            return fail(seed, "request {d} was sent again after stream {d}, which the peer left {s}", .{ index, earlier.id, @tagName(run.fate(earlier).*) });
        var attempts: usize = 0;
        var last: ?*Peer.Stream = null;
        for (peer.streams.items) |stream| {
            if (!std.mem.eql(u8, stream.test_id.items, request.id())) continue;
            attempts += 1;
            last = stream;
        }
        if (attempts > 1 + policy.max_unprocessed_replays)
            return fail(seed, "request {d} reached the peer {d} times", .{ index, attempts });
        if (attempts > 0 and !end.request_sent)
            return fail(seed, "request {d} reached the peer but ended {s} with request_sent false", .{ index, @tagName(end.cause) });
        if (end.cause == .complete and !request.whole())
            return fail(seed, "request {d} completed though its sink or receiver refused the answer", .{index});
        if (end.cause == .complete) {
            const answered = last orelse return fail(seed, "request {d} completed without reaching the peer", .{index});
            if (run.fate(answered).* != .answered)
                return fail(seed, "request {d} completed but the peer left it {s}", .{ index, @tagName(run.fate(answered).*) });
            if (!std.mem.eql(u8, answered.body.items, request.body))
                return fail(seed, "request {d} completed but the peer got {d} of {d} body bytes", .{ index, answered.body.items.len, request.body.len });
            const length: usize = @intCast(request.stream.responseLength());
            if (request.stream.status() != 200 or !std.mem.eql(u8, request.sink[0..length], request.response))
                return fail(seed, "request {d} completed with {d} of {d} response bytes", .{ index, length, request.response.len });
        }
        switch (end.cause) {
            .inactive, .peer_silent, .connect_timeout => return fail(seed, "request {d} ended {s}: a stall", .{ index, @tagName(end.cause) }),
            else => {},
        }
    }
    if (peer.seen.max_stream_window > h2.stream_window_bytes)
        return fail(seed, "a stream window opened to {d}", .{peer.seen.max_stream_window});
    // The connection window is sized for every stream the peer allows, up
    // to the client's capacity; it never starts below RFC 9113's 65,535.
    const carried: i32 = @intCast(@max(@min(run.max_streams, capacity), 1));
    const connection_limit = @max(65_535, h2.stream_window_bytes * carried);
    if (peer.seen.max_connection_window > connection_limit)
        return fail(seed, "a connection window opened to {d}, past {d}", .{ peer.seen.max_connection_window, connection_limit });
}

fn fail(seed: u64, comptime format: []const u8, arguments: anytype) error{FaultInvariant} {
    std.debug.print("seed {d}: " ++ format ++ "\nReplay with RUI_H2_FAULT_SEED={d}.\n", .{seed} ++ arguments ++ .{seed});
    return error.FaultInvariant;
}

fn environmentNumber(name: [*:0]const u8) ?u64 {
    const text = std.mem.span(std.c.getenv(name) orelse return null);
    return std.fmt.parseInt(u64, text, 10) catch null;
}

test "seeded faults: every stream settles once, with true send evidence and no resend of a processed request" {
    var totals: Totals = .{};
    if (environmentNumber("RUI_H2_FAULT_SEED")) |seed| return runSeed(seed, &totals);
    const seeds = environmentNumber("RUI_H2_FAULT_SEEDS") orelse default_seeds;
    // A crash prints no seed; RUI_H2_FAULT_TRACE=1 names each as it starts.
    const trace = environmentNumber("RUI_H2_FAULT_TRACE") != null;
    for (1..seeds + 1) |seed| {
        if (trace) std.debug.print("seed {d}\n", .{seed});
        try runSeed(seed, &totals);
    }
    // The faults ran, and the outcomes they force happened.
    const ran = [_]u64{ totals.faults.short, totals.faults.again, totals.faults.cut, totals.goaway, totals.refused, totals.reset, totals.peer_close, totals.outage, totals.resent, totals.cancelled, totals.retired };
    for (ran) |value| try std.testing.expect(value > 0);
    for ([_]policy.Cause{ .complete, .connection_lost, .reset_by_peer, .connect_failed, .sink_refused }) |cause| try std.testing.expect(totals.causes.get(cause) > 0);
}

test "seeded faults: a stream the peer reads after queueing GOAWAY above its last id counts as unprocessed" {
    // macOS delivers loopback segments late, so a pump after `act` queued a
    // GOAWAY can read a new stream's HEADERS before the GOAWAY goes out.
    // Scripted here in that order, with a body larger than the stream
    // window so the request never completes at the peer.
    const allocator = std.testing.allocator;
    var requests: [1]Request = .{.{}};
    requests[0].id_len = 1;
    requests[0].id_text[0] = '0';
    requests[0].body = try allocator.alloc(u8, 90_000);
    defer allocator.free(requests[0].body);
    fill(requests[0].body, 0);
    var sink: [8]u8 = undefined;
    var run: Run = .{ .random = .init(1), .requests = &requests, .max_streams = 100 };
    defer run.fates.deinit(allocator);
    defer run.goaways.deinit(allocator);
    const peer = try Peer.start(allocator, .{ .on_request = Run.onRequest, .context = &run });
    defer peer.stop();
    var client: h2.Client = undefined;
    try client.init(allocator, std.testing.io, .{ .stream_capacity = 4, .inactivity_ns = 60 * std.time.ns_per_s, .connect_timeout_ns = 30 * std.time.ns_per_s });
    defer client.deinit();
    defer if (Record.of(&requests[0].stream).state != .idle) {
        client.cancel(&requests[0].stream);
        requests[0].stream.deinit();
    };
    const endpoint = try client.addEndpoint(peer.url());
    try client.prepare(&requests[0].stream, .{
        .endpoint = endpoint,
        .fields = &.{.{ .name = "x-test-id", .value = requests[0].id() }},
        .body = .{ .bytes = requests[0].body },
        .sink = .{ .buffer = &sink },
    });
    client.launch(&requests[0].stream);

    // Until the client is ready and has sent HEADERS the peer has not read.
    var steps: u32 = 0;
    while (Engine.of(&client).connections_len == 0 or Engine.of(&client).connections[0].streams == 0) : (steps += 1) {
        if (steps > 2000) return error.Timeout;
        try client.drive(&run);
        if (Engine.of(&client).connections_len > 0 and Engine.of(&client).connections[0].streams > 0) break;
        try peer.pump();
        try client.wait(1);
    }
    // The HEADERS are in the peer's socket, unread, before the GOAWAY is queued.
    const Socket = struct {
        fn readable(socket: std.posix.fd_t) !bool {
            var poll = [_]std.c.pollfd{.{ .fd = socket, .events = std.c.POLL.IN, .revents = 0 }};
            return std.c.poll(&poll, 1, 0) > 0;
        }
    };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(3)), peer.connections.items[0].socket, Socket.readable);
    try std.testing.expectEqual(@as(usize, 0), peer.streams.items.len);
    run.goaway(peer, peer.connections.items[0]);
    try std.testing.expectEqual(@as(i32, 0), run.goaways.items[0].last);
    // Reads stream 1's HEADERS, then sends the GOAWAY.
    try peer.pump();
    try std.testing.expectEqual(@as(usize, 1), peer.streams.items.len);

    // The client replays stream 1 on a new connection, as GOAWAY proves it may.
    steps = 0;
    while (peer.streams.items.len < 2) : (steps += 1) {
        if (steps > 2000) return error.Timeout;
        try client.drive(&run);
        try peer.pump();
        try client.wait(1);
    }
    try std.testing.expectEqual(peer.streams.items[0].test_id.items.len, 1);
    try std.testing.expectEqual(@as(?*Peer.Stream, null), unprovenResend(&run, peer, requests[0].id()));
}
