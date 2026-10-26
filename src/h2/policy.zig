//! Every decision the HTTP/2 client makes, as functions over plain values.
//! The engine gathers the facts (connection views, stream flags, the
//! provider clock), calls one of these and applies the answer. The tables
//! below are the unit tests; tests against a peer then only have to show
//! that the facts are gathered correctly.
//!
//! Times are provider time in nanoseconds: the engine's awake clock minus
//! the time it spent blocked in sink writes, so a local disk stall never
//! reads as an idle stream or a silent peer.
const std = @import("std");

const ns_per_s: u64 = 1_000_000_000;

/// How a stream ended. Closed: the caller maps every tag exhaustively, so
/// adding one fails its build instead of falling into a default.
pub const Cause = enum(u8) {
    /// END_STREAM after a final response head.
    complete,
    /// The receiver refused a body event (its budget is exhausted).
    sink_refused,
    /// Writing response bytes to the sink failed.
    sink_failed,
    /// Reading the request body failed or came up short.
    body_failed,
    /// The receiver refused a header block.
    rejected_headers,
    /// The final head named a content coding other than `identity`, which
    /// the request's `accept-encoding` excluded.
    encoded_response,
    /// The peer does not speak HTTP/2: ALPN chose something else, or an h2c
    /// peer answered in HTTP/1. Always before any request byte.
    h2_refused,
    /// Certificate verification failed.
    untrusted_peer,
    resolve_failed,
    connect_failed,
    /// Resolve, connect, TLS and the peer's first SETTINGS took longer than
    /// the connect timeout.
    connect_timeout,
    tls_failed,
    /// The connection died with the stream sent and no proof that the
    /// server left it unprocessed.
    connection_lost,
    protocol_error,
    reset_by_peer,
    /// The server refused the stream unprocessed more often than the replay
    /// bound allows.
    refused,
    /// A PING went unanswered.
    peer_silent,
    /// No response bytes for the inactivity interval.
    inactive,
    /// A local resource failure (allocation, descriptors).
    local_failure,
};

/// Whether a `content-encoding` value names no coding but `identity`, the
/// only one the request accepted. Empty list elements are ignored (RFC
/// 9110 section 5.6.1).
pub fn identityOnly(content_encoding: []const u8) bool {
    var codings = std.mem.tokenizeScalar(u8, content_encoding, ',');
    while (codings.next()) |element| {
        const coding = std.mem.trim(u8, element, " \t");
        if (coding.len > 0 and !std.ascii.eqlIgnoreCase(coding, "identity")) return false;
    }
    return true;
}

/// The only in-client resend: a stream the server proved it did not
/// process (REFUSED_STREAM, or above a GOAWAY's last stream id) is sent
/// again from byte 0, at most this many times.
pub const max_unprocessed_replays = 4;

// ----------------------------------------------------------------- routing

pub const ConnectionView = struct {
    ready: bool,
    draining: bool,
    streams: u32,
    /// The peer's SETTINGS_MAX_CONCURRENT_STREAMS; known once `ready`.
    peer_max_streams: u32,
};

/// The first ready, non-draining connection with room under the peer's
/// MAX_CONCURRENT_STREAMS. First fit in table order packs streams onto as
/// few connections as possible, so a second connection exists only while
/// the first is full.
pub fn route(connections: []const ConnectionView) ?usize {
    for (connections, 0..) |view, index| {
        if (view.ready and !view.draining and view.streams < view.peer_max_streams) return index;
    }
    return null;
}

/// How many connections to start for an origin whose pending streams found
/// no room. Before any SETTINGS is known, one at a time. After that, just
/// enough for the pending streams at the learned limit, less those already
/// being set up.
pub fn connectionsToOpen(pending: u32, setting_up: u32, learned_max_streams: ?u32) u32 {
    if (pending == 0) return 0;
    const per = learned_max_streams orelse return @intFromBool(setting_up == 0);
    // A peer allowing no streams for now opens nothing until its SETTINGS change.
    if (per == 0) return 0;
    const wanted = std.math.divCeil(u32, pending, per) catch unreachable;
    return wanted -| setting_up;
}

/// A connection failed before it was ready. Its origin's pending streams end
/// with the setup cause only when nothing else could carry them.
pub fn pendingAfterSetupFailure(other_setting_up: u32, other_ready_with_room: u32) enum { wait, end_all } {
    return if (other_setting_up == 0 and other_ready_with_room == 0) .end_all else .wait;
}

// -------------------------------------------------------------- settlement

/// Connect attempts one connection keeps in flight at once.
pub const max_attempts = 2;

/// How long an attempt runs before the next address's starts (RFC 8305
/// section 5).
pub const attempt_delay_ns = 250_000_000;

pub const AttemptFacts = struct {
    /// Attempts connecting now, after any that just failed were dropped.
    in_flight: u8,
    /// An address not yet tried remains.
    more_addresses: bool,
    /// An attempt failed since the last decision.
    failed: bool,
    /// The attempt delay passed since the newest attempt started.
    delay_passed: bool,
};

/// What a connecting connection does with its addresses. The next address
/// starts as soon as an attempt fails or the delay passed; with two in
/// flight the oldest gives way, so every address gets its turn and a
/// connection never holds more than two sockets.
pub fn nextAttempt(facts: AttemptFacts) enum { wait, start, replace_oldest, fail } {
    std.debug.assert(facts.in_flight <= max_attempts);
    if (!facts.more_addresses) return if (facts.in_flight == 0) .fail else .wait;
    if (facts.in_flight == 0 or facts.failed) return .start;
    if (!facts.delay_passed) return .wait;
    return if (facts.in_flight < max_attempts) .start else .replace_oldest;
}

pub const StreamFacts = struct {
    /// The stream's HEADERS frame was packed for sending on some connection.
    /// Sticky across replays: once true, "nothing was sent" is never claimed.
    request_sent: bool,
    /// Any response frame arrived, so the server processed the request.
    response_started: bool,
    final_seen: bool,
    end_stream_seen: bool,
    replays: u8,
    /// A cause the engine recorded locally before nghttp2 closed the stream.
    local: ?Cause,
};

pub const Settle = union(enum) {
    end: Cause,
    /// The server proved it did not process the stream: send it again.
    replay,
    /// Its HEADERS never left: send it elsewhere. Not a replay.
    reroute,
};

pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    _,
};

/// nghttp2 closed one stream (on_stream_close). It reports a stream above a
/// GOAWAY's last stream id, and request HEADERS it could not send, as
/// REFUSED_STREAM, so both proofs of non-processing arrive here as one.
pub fn streamClosed(code: ErrorCode, facts: StreamFacts) Settle {
    if (facts.local) |cause| return .{ .end = cause };
    // The whole response arrived; a reset after it loses nothing.
    if (facts.final_seen and facts.end_stream_seen) return .{ .end = .complete };
    if (!facts.request_sent) return .reroute;
    if (code == .refused_stream and !facts.response_started) return replayOrRefused(facts);
    if (code == .no_error) return .{ .end = .protocol_error };
    return .{ .end = .reset_by_peer };
}

/// The connection itself is gone, so nghttp2 ran no stream callbacks.
pub fn connectionLost(cause: Cause, stream_id: u32, goaway_last_stream_id: ?u32, facts: StreamFacts) Settle {
    if (facts.local) |local| return .{ .end = local };
    if (!facts.request_sent) return .reroute;
    if (goaway_last_stream_id) |last| {
        if (stream_id > last and !facts.response_started) return replayOrRefused(facts);
    }
    // Sent with no proof of non-processing: never resent, whether or not the
    // connection was reused.
    return .{ .end = cause };
}

fn replayOrRefused(facts: StreamFacts) Settle {
    return if (facts.replays < max_unprocessed_replays) .replay else .{ .end = .refused };
}

// ---------------------------------------------------------------- liveness

pub const Liveness = struct {
    /// A connection carrying streams with no inbound bytes for this long gets
    /// one PING, which covers all of its streams.
    ping_after_quiet_ns: u64 = 45 * ns_per_s,
    /// No inbound bytes for this long after that PING: the connection is dead.
    ping_timeout_ns: u64 = 15 * ns_per_s,
    /// A connection with no streams closes after this long: the earlier
    /// transport's default, so reuse behaviour is unchanged.
    idle_close_ns: u64 = 118 * ns_per_s,
};

pub const LivenessFacts = struct {
    now_ns: u64,
    last_inbound_ns: u64,
    ping_sent_ns: ?u64,
    streams: u32,
    /// When the connection last became empty; null while it carries streams.
    idle_since_ns: ?u64,
    /// No other connection of this origin is idle.
    is_only_idle: bool,
};

pub const LivenessAction = enum { none, ping, dead, close };

/// For a ready or draining connection only: one still in setup has no
/// liveness, and its connect timeout bounds it. One PING per quiet
/// connection carrying streams; an unanswered PING declares it dead; an
/// empty connection closes after `idle_close_ns`, or at once when its origin
/// already keeps another idle one.
pub fn liveness(facts: LivenessFacts, config: Liveness) LivenessAction {
    if (facts.streams == 0) {
        if (!facts.is_only_idle) return .close;
        const since = facts.idle_since_ns orelse return .none;
        return if (facts.now_ns -| since >= config.idle_close_ns) .close else .none;
    }
    // Anything inbound after the PING answers it; quiet time counts again from there.
    if (pingOutstanding(facts)) |sent| {
        return if (facts.now_ns -| sent >= config.ping_timeout_ns) .dead else .none;
    }
    return if (facts.now_ns -| facts.last_inbound_ns >= config.ping_after_quiet_ns) .ping else .none;
}

/// The deadline `liveness` acts on next for one connection, or null when it
/// has none.
pub fn livenessDeadline(facts: LivenessFacts, config: Liveness) ?u64 {
    if (facts.streams == 0) {
        if (!facts.is_only_idle) return facts.now_ns;
        const since = facts.idle_since_ns orelse return null;
        return since +| config.idle_close_ns;
    }
    if (pingOutstanding(facts)) |sent| return sent +| config.ping_timeout_ns;
    return facts.last_inbound_ns +| config.ping_after_quiet_ns;
}

fn pingOutstanding(facts: LivenessFacts) ?u64 {
    const sent = facts.ping_sent_ns orelse return null;
    return if (facts.last_inbound_ns > sent) null else sent;
}

// ------------------------------------------------------------------- tests

fn connection(ready: bool, draining: bool, streams: u32, peer_max_streams: u32) ConnectionView {
    return .{ .ready = ready, .draining = draining, .streams = streams, .peer_max_streams = peer_max_streams };
}

test "only identity, in any case or list shape, is an accepted coding" {
    for ([_]struct { value: []const u8, accepted: bool }{
        .{ .value = "identity", .accepted = true },
        .{ .value = "IDENTITY", .accepted = true },
        .{ .value = "", .accepted = true },
        .{ .value = "identity, ,\tidentity,", .accepted = true },
        .{ .value = "gzip", .accepted = false },
        .{ .value = "identity, br", .accepted = false },
        .{ .value = " , x-gzip", .accepted = false },
    }) |case| try std.testing.expectEqual(case.accepted, identityOnly(case.value));
}

test "route packs streams onto the first connection with room" {
    try std.testing.expectEqual(@as(?usize, null), route(&.{}));
    try std.testing.expectEqual(@as(?usize, 2), route(&.{
        connection(false, false, 0, 100), // still in setup
        connection(true, true, 3, 100), // draining after GOAWAY
        connection(true, false, 99, 100),
        connection(true, false, 0, 100),
    }));
    try std.testing.expectEqual(@as(?usize, 1), route(&.{ connection(true, false, 100, 100), connection(true, false, 0, 100) }));
    try std.testing.expectEqual(@as(?usize, null), route(&.{ connection(true, false, 1, 1), connection(true, false, 0, 0) }));
}

test "connections open one at a time until the peer's limit is known" {
    const rows = [_]struct { pending: u32, setting_up: u32, learned: ?u32, open: u32 }{
        .{ .pending = 0, .setting_up = 0, .learned = null, .open = 0 },
        .{ .pending = 5, .setting_up = 0, .learned = null, .open = 1 },
        .{ .pending = 5, .setting_up = 1, .learned = null, .open = 0 },
        .{ .pending = 3, .setting_up = 0, .learned = 1, .open = 3 },
        .{ .pending = 3, .setting_up = 2, .learned = 1, .open = 1 },
        .{ .pending = 101, .setting_up = 1, .learned = 100, .open = 1 },
        .{ .pending = 1, .setting_up = 0, .learned = 100, .open = 1 },
        .{ .pending = 1, .setting_up = 3, .learned = 100, .open = 0 },
        .{ .pending = 4, .setting_up = 0, .learned = 0, .open = 0 },
    };
    for (rows) |row| try std.testing.expectEqual(row.open, connectionsToOpen(row.pending, row.setting_up, row.learned));
}

test "pending streams end on setup failure only when nothing else can carry them" {
    try std.testing.expectEqual(.end_all, pendingAfterSetupFailure(0, 0));
    try std.testing.expectEqual(.wait, pendingAfterSetupFailure(1, 0));
    try std.testing.expectEqual(.wait, pendingAfterSetupFailure(0, 1));
}

const sent_stream: StreamFacts = .{
    .request_sent = true,
    .response_started = false,
    .final_seen = false,
    .end_stream_seen = false,
    .replays = 0,
    .local = null,
};

fn with(base: anytype, comptime field: []const u8, value: anytype) @TypeOf(base) {
    var facts = base;
    @field(facts, field) = value;
    return facts;
}

test "the next address starts on a failure or after the delay, the oldest of two giving way" {
    const Case = struct { in_flight: u8, more: bool, failed: bool, delay_passed: bool, step: @TypeOf(nextAttempt(undefined)) };
    const cases = [_]Case{
        // No address left: wait on what runs, or fail with nothing running.
        .{ .in_flight = 0, .more = false, .failed = true, .delay_passed = true, .step = .fail },
        .{ .in_flight = 1, .more = false, .failed = true, .delay_passed = true, .step = .wait },
        .{ .in_flight = 2, .more = false, .failed = false, .delay_passed = true, .step = .wait },
        // The first attempt, and the next one at once after a failure.
        .{ .in_flight = 0, .more = true, .failed = false, .delay_passed = false, .step = .start },
        .{ .in_flight = 1, .more = true, .failed = true, .delay_passed = false, .step = .start },
        // One running: the next only after the delay.
        .{ .in_flight = 1, .more = true, .failed = false, .delay_passed = false, .step = .wait },
        .{ .in_flight = 1, .more = true, .failed = false, .delay_passed = true, .step = .start },
        // Two running: the oldest gives way when the delay passed.
        .{ .in_flight = 2, .more = true, .failed = false, .delay_passed = false, .step = .wait },
        .{ .in_flight = 2, .more = true, .failed = false, .delay_passed = true, .step = .replace_oldest },
    };
    for (cases) |case| try std.testing.expectEqual(case.step, nextAttempt(.{
        .in_flight = case.in_flight,
        .more_addresses = case.more,
        .failed = case.failed,
        .delay_passed = case.delay_passed,
    }));
}

test "a stream closes as complete, a replay, a reroute or a failure" {
    const answered = with(with(with(sent_stream, "response_started", true), "final_seen", true), "end_stream_seen", true);
    const Row = struct { code: ErrorCode, facts: StreamFacts, settle: Settle };
    const rows = [_]Row{
        .{ .code = .no_error, .facts = answered, .settle = .{ .end = .complete } },
        // A complete answer stays complete whatever reset follows it.
        .{ .code = .no_error, .facts = with(answered, "replays", 2), .settle = .{ .end = .complete } },
        .{ .code = .cancel, .facts = answered, .settle = .{ .end = .complete } },
        // A local cause wins over whatever nghttp2 reports.
        .{ .code = .no_error, .facts = with(answered, "local", Cause.sink_failed), .settle = .{ .end = .sink_failed } },
        .{ .code = .cancel, .facts = with(sent_stream, "local", Cause.rejected_headers), .settle = .{ .end = .rejected_headers } },
        // HEADERS never packed: nghttp2 closes it REFUSED_STREAM; send it elsewhere.
        .{ .code = .refused_stream, .facts = with(sent_stream, "request_sent", false), .settle = .reroute },
        .{ .code = .refused_stream, .facts = with(with(sent_stream, "request_sent", false), "replays", 4), .settle = .reroute },
        // Proven unprocessed: replay up to the bound, then give up.
        .{ .code = .refused_stream, .facts = sent_stream, .settle = .replay },
        .{ .code = .refused_stream, .facts = with(sent_stream, "replays", 3), .settle = .replay },
        .{ .code = .refused_stream, .facts = with(sent_stream, "replays", 4), .settle = .{ .end = .refused } },
        // After any response frame the server processed it: never replayed.
        .{ .code = .refused_stream, .facts = with(sent_stream, "response_started", true), .settle = .{ .end = .reset_by_peer } },
        .{ .code = .no_error, .facts = with(sent_stream, "response_started", true), .settle = .{ .end = .protocol_error } },
        .{ .code = .cancel, .facts = sent_stream, .settle = .{ .end = .reset_by_peer } },
        .{ .code = .internal_error, .facts = with(sent_stream, "response_started", true), .settle = .{ .end = .reset_by_peer } },
        .{ .code = @fromBackingInt(@intCast(0xff)), .facts = sent_stream, .settle = .{ .end = .reset_by_peer } },
    };
    for (rows) |row| try std.testing.expectEqual(row.settle, streamClosed(row.code, row.facts));
}

test "a lost connection resends only streams it proved unprocessed" {
    const Row = struct { stream_id: u32, last: ?u32, facts: StreamFacts, settle: Settle };
    const rows = [_]Row{
        .{ .stream_id = 5, .last = null, .facts = with(sent_stream, "request_sent", false), .settle = .reroute },
        // Reused or not, a sent stream without proof is never resent.
        .{ .stream_id = 5, .last = null, .facts = sent_stream, .settle = .{ .end = .connection_lost } },
        .{ .stream_id = 5, .last = 3, .facts = sent_stream, .settle = .replay },
        .{ .stream_id = 5, .last = 3, .facts = with(sent_stream, "replays", 4), .settle = .{ .end = .refused } },
        .{ .stream_id = 5, .last = 3, .facts = with(sent_stream, "response_started", true), .settle = .{ .end = .connection_lost } },
        .{ .stream_id = 3, .last = 3, .facts = sent_stream, .settle = .{ .end = .connection_lost } },
        .{ .stream_id = 5, .last = 3, .facts = with(sent_stream, "local", Cause.body_failed), .settle = .{ .end = .body_failed } },
    };
    for (rows) |row| try std.testing.expectEqual(row.settle, connectionLost(.connection_lost, row.stream_id, row.last, row.facts));
}

test "one PING per quiet connection, a missed PING is fatal, idle connections close" {
    const s = ns_per_s;
    const config: Liveness = .{};
    const busy: LivenessFacts = .{
        .now_ns = 100 * s,
        .last_inbound_ns = 100 * s,
        .ping_sent_ns = null,
        .streams = 3,
        .idle_since_ns = null,
        .is_only_idle = true,
    };
    const Row = struct { facts: LivenessFacts, action: LivenessAction, deadline: ?u64 };
    const rows = [_]Row{
        .{ .facts = busy, .action = .none, .deadline = 145 * s },
        .{ .facts = with(busy, "last_inbound_ns", 56 * s), .action = .none, .deadline = 101 * s },
        .{ .facts = with(busy, "last_inbound_ns", 55 * s), .action = .ping, .deadline = 100 * s },
        // Waiting on the answer.
        .{ .facts = with(with(busy, "last_inbound_ns", 50 * s), "ping_sent_ns", 95 * s), .action = .none, .deadline = 110 * s },
        .{ .facts = with(with(busy, "last_inbound_ns", 50 * s), "ping_sent_ns", 85 * s), .action = .dead, .deadline = 100 * s },
        // Any inbound byte after the PING counts as the answer.
        .{ .facts = with(with(busy, "last_inbound_ns", 90 * s), "ping_sent_ns", 80 * s), .action = .none, .deadline = 135 * s },
        // ...and once it is quiet that long again, the next PING is due.
        .{ .facts = with(with(with(busy, "last_inbound_ns", 90 * s), "ping_sent_ns", 80 * s), "now_ns", 135 * s), .action = .ping, .deadline = 135 * s },
        // An empty connection: kept only while it is its origin's one idle connection.
        .{ .facts = with(with(busy, "streams", 0), "idle_since_ns", 0), .action = .none, .deadline = 118 * s },
        .{ .facts = with(with(busy, "streams", 0), "idle_since_ns", 100 * s), .action = .none, .deadline = 218 * s },
        .{ .facts = with(with(with(busy, "streams", 0), "idle_since_ns", 0), "now_ns", 118 * s), .action = .close, .deadline = 118 * s },
        .{ .facts = with(with(with(busy, "streams", 0), "idle_since_ns", 99 * s), "is_only_idle", false), .action = .close, .deadline = 100 * s },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row.action, liveness(row.facts, config));
        try std.testing.expectEqual(row.deadline, livenessDeadline(row.facts, config));
    }
}
