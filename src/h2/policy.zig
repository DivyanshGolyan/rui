const std = @import("std");

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
