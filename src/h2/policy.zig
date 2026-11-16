const std = @import("std");

const ns_per_s: u64 = 1_000_000_000;

pub const Cause = enum(u8) {
    complete,
    sink_refused,
    sink_failed,
    body_failed,
    rejected_headers,
    encoded_response,
    h2_refused,
    untrusted_peer,
    proxy_auth_required,
    proxy_refused,
    proxy_failed,
    resolve_failed,
    connect_failed,
    connect_timeout,
    tls_failed,
    connection_lost,
    protocol_error,
    reset_by_peer,
    refused,
    peer_silent,
    inactive,
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

pub const max_unprocessed_replays = 4;

pub const ConnectionView = struct {
    ready: bool,
    draining: bool,
    streams: u32,
    peer_max_streams: u32,
};

pub fn route(connections: []const ConnectionView) ?usize {
    for (connections, 0..) |view, index| {
        if (view.ready and !view.draining and view.streams < view.peer_max_streams) return index;
    }
    return null;
}

pub fn connectionsToOpen(pending: u32, setting_up: u32, learned_max_streams: ?u32) u32 {
    if (pending == 0) return 0;
    const per = learned_max_streams orelse return @intFromBool(setting_up == 0);
    if (per == 0) return 0;
    const wanted = std.math.divCeil(u32, pending, per) catch unreachable;
    return wanted -| setting_up;
}

pub fn pendingAfterSetupFailure(other_setting_up: u32, other_ready_with_room: u32) enum { wait, end_all } {
    return if (other_setting_up == 0 and other_ready_with_room == 0) .end_all else .wait;
}

/// How a proxy's answer to CONNECT ends the setup, or null when the tunnel
/// is open: any 2xx (RFC 9110 section 9.3.6).
pub fn tunnelRefusal(status: u16) ?Cause {
    return switch (status) {
        200...299 => null,
        407 => .proxy_auth_required,
        403 => .proxy_refused,
        else => .proxy_failed,
    };
}

pub const max_attempts = 2;

/// How long an attempt runs before the next address's starts (RFC 8305
/// section 5).
pub const attempt_delay_ns = 250_000_000;

pub const AttemptFacts = struct {
    in_flight: u8,
    more_addresses: bool,
    failed: bool,
    delay_passed: bool,
};

pub fn nextAttempt(facts: AttemptFacts) enum { wait, start, replace_oldest, fail } {
    std.debug.assert(facts.in_flight <= max_attempts);
    if (!facts.more_addresses) return if (facts.in_flight == 0) .fail else .wait;
    if (facts.in_flight == 0 or facts.failed) return .start;
    if (!facts.delay_passed) return .wait;
    return if (facts.in_flight < max_attempts) .start else .replace_oldest;
}

pub const StreamFacts = struct {
    request_sent: bool,
    response_started: bool,
    final_seen: bool,
    end_stream_seen: bool,
    replays: u8,
    local: ?Cause,
};

pub const Settle = union(enum) {
    end: Cause,
    replay,
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
    if (facts.final_seen and facts.end_stream_seen) return .{ .end = .complete };
    if (!facts.request_sent) return .reroute;
    if (code == .refused_stream and !facts.response_started) return replayOrRefused(facts);
    if (code == .no_error) return .{ .end = .protocol_error };
    return .{ .end = .reset_by_peer };
}

pub fn connectionLost(cause: Cause, stream_id: u32, goaway_last_stream_id: ?u32, facts: StreamFacts) Settle {
    if (facts.local) |local| return .{ .end = local };
    if (!facts.request_sent) return .reroute;
    if (goaway_last_stream_id) |last| {
        if (stream_id > last and !facts.response_started) return replayOrRefused(facts);
    }
    return .{ .end = cause };
}

fn replayOrRefused(facts: StreamFacts) Settle {
    return if (facts.replays < max_unprocessed_replays) .replay else .{ .end = .refused };
}

pub const Liveness = struct {
    ping_after_quiet_ns: u64 = 45 * ns_per_s,
    ping_timeout_ns: u64 = 15 * ns_per_s,
    idle_close_ns: u64 = 118 * ns_per_s,
};

pub const LivenessFacts = struct {
    now_ns: u64,
    last_inbound_ns: u64,
    ping_sent_ns: ?u64,
    streams: u32,
    idle_since_ns: ?u64,
    is_only_idle: bool,
};

pub const LivenessAction = enum { none, ping, dead, close };

pub fn liveness(facts: LivenessFacts, config: Liveness) LivenessAction {
    if (facts.streams == 0) {
        if (!facts.is_only_idle) return .close;
        const since = facts.idle_since_ns orelse return .none;
        return if (facts.now_ns -| since >= config.idle_close_ns) .close else .none;
    }
    if (pingOutstanding(facts)) |sent| {
        return if (facts.now_ns -| sent >= config.ping_timeout_ns) .dead else .none;
    }
    return if (facts.now_ns -| facts.last_inbound_ns >= config.ping_after_quiet_ns) .ping else .none;
}

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
        connection(false, false, 0, 100),
        connection(true, true, 3, 100),
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

test "any 2xx opens the tunnel; 407 and 403 are their own causes" {
    for ([_]u16{ 200, 204, 299 }) |status| try std.testing.expectEqual(@as(?Cause, null), tunnelRefusal(status));
    try std.testing.expectEqual(@as(?Cause, .proxy_auth_required), tunnelRefusal(407));
    try std.testing.expectEqual(@as(?Cause, .proxy_refused), tunnelRefusal(403));
    for ([_]u16{ 100, 301, 400, 404, 502, 503 }) |status| try std.testing.expectEqual(@as(?Cause, .proxy_failed), tunnelRefusal(status));
}

test "the next address starts on a failure or after the delay, the oldest of two giving way" {
    const Case = struct { in_flight: u8, more: bool, failed: bool, delay_passed: bool, step: @TypeOf(nextAttempt(undefined)) };
    const cases = [_]Case{
        .{ .in_flight = 0, .more = false, .failed = true, .delay_passed = true, .step = .fail },
        .{ .in_flight = 1, .more = false, .failed = true, .delay_passed = true, .step = .wait },
        .{ .in_flight = 2, .more = false, .failed = false, .delay_passed = true, .step = .wait },
        .{ .in_flight = 0, .more = true, .failed = false, .delay_passed = false, .step = .start },
        .{ .in_flight = 1, .more = true, .failed = true, .delay_passed = false, .step = .start },
        .{ .in_flight = 1, .more = true, .failed = false, .delay_passed = false, .step = .wait },
        .{ .in_flight = 1, .more = true, .failed = false, .delay_passed = true, .step = .start },
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
        .{ .code = .no_error, .facts = with(answered, "replays", 2), .settle = .{ .end = .complete } },
        .{ .code = .cancel, .facts = answered, .settle = .{ .end = .complete } },
        .{ .code = .no_error, .facts = with(answered, "local", Cause.sink_failed), .settle = .{ .end = .sink_failed } },
        .{ .code = .cancel, .facts = with(sent_stream, "local", Cause.rejected_headers), .settle = .{ .end = .rejected_headers } },
        .{ .code = .refused_stream, .facts = with(sent_stream, "request_sent", false), .settle = .reroute },
        .{ .code = .refused_stream, .facts = with(with(sent_stream, "request_sent", false), "replays", 4), .settle = .reroute },
        .{ .code = .refused_stream, .facts = sent_stream, .settle = .replay },
        .{ .code = .refused_stream, .facts = with(sent_stream, "replays", 3), .settle = .replay },
        .{ .code = .refused_stream, .facts = with(sent_stream, "replays", 4), .settle = .{ .end = .refused } },
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
        .{ .facts = with(with(busy, "last_inbound_ns", 50 * s), "ping_sent_ns", 95 * s), .action = .none, .deadline = 110 * s },
        .{ .facts = with(with(busy, "last_inbound_ns", 50 * s), "ping_sent_ns", 85 * s), .action = .dead, .deadline = 100 * s },
        .{ .facts = with(with(busy, "last_inbound_ns", 90 * s), "ping_sent_ns", 80 * s), .action = .none, .deadline = 135 * s },
        .{ .facts = with(with(with(busy, "last_inbound_ns", 90 * s), "ping_sent_ns", 80 * s), "now_ns", 135 * s), .action = .ping, .deadline = 135 * s },
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
