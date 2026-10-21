//! Model transport policy over values: how a finished provider transfer is
//! classified, which outcomes keep the response body, and when an Attempt's
//! inactivity interval expires. `provider.zig` owns the curl handles,
//! callbacks, capture writer and clock reads, and passes their facts here.
const std = @import("std");

pub const Timestamp = std.Io.Clock.Timestamp;

pub const Disposition = enum {
    success,
    permanent_http,
    temporary_http,
    temporary_connection,
    permanent_transport,
    authentication_failure,
    tls_verification_failure,
    invalid_headers,
    unsupported_http_version,

    /// The provider answered with an HTTP error status.
    pub fn answered(self: Disposition) bool {
        return switch (self) {
            .permanent_http, .temporary_http => true,
            else => false,
        };
    }

    /// An HTTP response is the evidence, so its body is sealed before
    /// settlement. Every other outcome discards the partial capture.
    pub fn retainsResponse(self: Disposition) bool {
        return self == .success or self.answered();
    }
};

pub const Evidence = struct {
    disposition: Disposition,
    http_status: u16 = 0,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

pub const CaptureFailure = enum { scratch_exhausted, write_failed, seal_failed };

pub const TransferOutcome = union(enum) {
    response_capture_failed: CaptureFailure,
    request_source_failed,
    transport_finished: Evidence,
};

/// The curl results classification distinguishes. The shell maps each tag
/// to the `CURLE_` constant with its upper-cased name and any other code to
/// `other`.
pub const CurlResult = enum {
    ok,
    aborted_by_callback,
    couldnt_resolve_proxy,
    couldnt_resolve_host,
    couldnt_connect,
    send_error,
    recv_error,
    got_nothing,
    partial_file,
    operation_timedout,
    http2,
    http2_stream,
    http3,
    quic_connect_error,
    ssl_connect_error,
    login_denied,
    peer_failed_verification,
    other,
};

pub const HttpVersion = enum { http1_1, http2, other };

/// Facts about one finished transfer, read by the shell after curl reports it.
pub const Finished = struct {
    result: CurlResult,
    /// curl's error message; the patched TLS ALPN guard marks refused H2 here.
    error_message: []const u8 = "",
    requires_h2: bool,
    headers_invalid: bool = false,
    inactivity_expired: bool = false,
    version: HttpVersion,
    /// Null when curl cannot report a status.
    response_code: ?i64,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

pub const alpn_refused_marker = "RUI_ALPN_H2_REQUIRED:";

pub fn classify(finished: Finished) error{InvalidHttpEvidence}!Evidence {
    // Only the ALPN guard emits the marker. A negotiated H2 stream can also
    // fail with `http2` before any response version.
    if (finished.requires_h2 and finished.result == .http2 and
        std.mem.startsWith(u8, finished.error_message, alpn_refused_marker))
        return .{ .disposition = .unsupported_http_version };
    const required: HttpVersion = if (finished.requires_h2) .http2 else .http1_1;
    if (finished.result == .ok and finished.version != required)
        return .{ .disposition = .unsupported_http_version };
    if (finished.headers_invalid or finished.result != .ok) return .{
        .disposition = if (finished.headers_invalid) .invalid_headers else curlFailure(finished.result, finished.inactivity_expired),
        .retry_after_ms = finished.retry_after_ms,
        .retry_after_deadline_ms = finished.retry_after_deadline_ms,
    };
    const code = finished.response_code orelse return error.InvalidHttpEvidence;
    if (code < 100 or code > 599) return error.InvalidHttpEvidence;
    const status: u16 = @intCast(code);
    return .{
        .disposition = if (status >= 200 and status < 300)
            .success
        else if (status == 408 or status == 429 or status >= 500)
            .temporary_http
        else
            .permanent_http,
        .http_status = status,
        .retry_after_ms = finished.retry_after_ms,
        .retry_after_deadline_ms = finished.retry_after_deadline_ms,
    };
}

fn curlFailure(result: CurlResult, inactivity_expired: bool) Disposition {
    return switch (result) {
        .ok => unreachable,
        .aborted_by_callback => if (inactivity_expired) .temporary_connection else .permanent_transport,
        .couldnt_resolve_proxy,
        .couldnt_resolve_host,
        .couldnt_connect,
        .send_error,
        .recv_error,
        .got_nothing,
        .partial_file,
        .operation_timedout,
        .http2,
        .http2_stream,
        .http3,
        .quic_connect_error,
        .ssl_connect_error,
        => .temporary_connection,
        .login_denied => .authentication_failure,
        .peer_failed_verification => .tls_verification_failure,
        .other => .permanent_transport,
    };
}

/// One Attempt's inactivity interval over awake-clock timestamps. Download
/// progress renews it. A local capture pause excludes only its own duration,
/// because the provider is not the party that went quiet.
pub const Inactivity = struct {
    limit_ns: i64,
    last_download: i64 = 0,
    last_progress: Timestamp = undefined,
    paused_at: ?Timestamp = null,
    armed: bool = false,
    expired: bool = false,

    pub fn arm(self: *Inactivity, now: Timestamp) void {
        self.last_progress = now;
        self.paused_at = null;
        self.armed = true;
        self.expired = false;
    }

    pub fn isPaused(self: *const Inactivity) bool {
        return self.paused_at != null;
    }

    pub fn pause(self: *Inactivity, now: Timestamp) void {
        if (self.paused_at == null) self.paused_at = now;
    }

    pub fn resumeAfterPause(self: *Inactivity, now: Timestamp) void {
        const paused_at = self.paused_at orelse unreachable;
        self.last_progress = self.last_progress.addDuration(paused_at.durationTo(now));
        self.paused_at = null;
    }

    /// curl's progress report: renews on new download bytes and returns
    /// whether the transfer should abort.
    pub fn progress(self: *Inactivity, now: Timestamp, downloaded: i64) bool {
        if (!self.armed or self.isPaused()) return false;
        if (downloaded != self.last_download) {
            self.last_download = downloaded;
            self.last_progress = now;
        }
        return self.expiredAt(now);
    }

    pub fn expiredAt(self: *Inactivity, now: Timestamp) bool {
        if (!self.armed or self.isPaused()) return false;
        if (self.last_progress.durationTo(now).raw.nanoseconds < self.limit_ns) return false;
        self.expired = true;
        return true;
    }
};

test "curl failures retry only temporary connection loss and explicit inactivity" {
    const cases = [_]struct { result: CurlResult, expired: bool, expected: Disposition }{
        .{ .result = .couldnt_connect, .expired = false, .expected = .temporary_connection },
        .{ .result = .couldnt_resolve_host, .expired = false, .expected = .temporary_connection },
        .{ .result = .http2_stream, .expired = false, .expected = .temporary_connection },
        .{ .result = .operation_timedout, .expired = false, .expected = .temporary_connection },
        .{ .result = .ssl_connect_error, .expired = false, .expected = .temporary_connection },
        .{ .result = .aborted_by_callback, .expired = true, .expected = .temporary_connection },
        // A callback abort without expiry is a local refusal, not provider silence.
        .{ .result = .aborted_by_callback, .expired = false, .expected = .permanent_transport },
        // Expiry does not turn an unrelated failure temporary.
        .{ .result = .other, .expired = true, .expected = .permanent_transport },
        .{ .result = .login_denied, .expired = false, .expected = .authentication_failure },
        .{ .result = .peer_failed_verification, .expired = false, .expected = .tls_verification_failure },
    };
    for (cases) |case| {
        const evidence = try classify(.{
            .result = case.result,
            .inactivity_expired = case.expired,
            .requires_h2 = true,
            .version = .other,
            .response_code = 0,
            .retry_after_ms = 7_000,
            .retry_after_deadline_ms = 1_700_000_001_000,
        });
        try std.testing.expectEqual(case.expected, evidence.disposition);
        try std.testing.expectEqual(@as(u16, 0), evidence.http_status);
        try std.testing.expectEqual(@as(?u64, 7_000), evidence.retry_after_ms);
        try std.testing.expectEqual(@as(?i64, 1_700_000_001_000), evidence.retry_after_deadline_ms);
    }
}

test "HTTP status classes and their Retry-After constraints" {
    const cases = [_]struct { code: ?i64, expected: ?Disposition }{
        .{ .code = 200, .expected = .success },
        .{ .code = 299, .expected = .success },
        .{ .code = 199, .expected = .permanent_http },
        .{ .code = 300, .expected = .permanent_http },
        .{ .code = 400, .expected = .permanent_http },
        .{ .code = 407, .expected = .permanent_http },
        .{ .code = 408, .expected = .temporary_http },
        .{ .code = 429, .expected = .temporary_http },
        .{ .code = 499, .expected = .permanent_http },
        .{ .code = 500, .expected = .temporary_http },
        .{ .code = 599, .expected = .temporary_http },
        .{ .code = 100, .expected = .permanent_http },
        .{ .code = 99, .expected = null },
        .{ .code = 600, .expected = null },
        .{ .code = null, .expected = null },
    };
    for (cases) |case| {
        const finished: Finished = .{
            .result = .ok,
            .requires_h2 = false,
            .version = .http1_1,
            .response_code = case.code,
            .retry_after_ms = 12_000,
        };
        const expected = case.expected orelse {
            try std.testing.expectError(error.InvalidHttpEvidence, classify(finished));
            continue;
        };
        const evidence = try classify(finished);
        try std.testing.expectEqual(expected, evidence.disposition);
        try std.testing.expectEqual(@as(u16, @intCast(case.code.?)), evidence.http_status);
        try std.testing.expectEqual(@as(?u64, 12_000), evidence.retry_after_ms);
        try std.testing.expectEqual(@as(?i64, null), evidence.retry_after_deadline_ms);
    }
}

test "TLS requires negotiated H2 and loopback HTTP requires HTTP/1.1" {
    const cases = [_]struct { requires_h2: bool, result: CurlResult, message: []const u8, version: HttpVersion, expected: Disposition }{
        // The ALPN guard's refusal precedes the connection-failure class of `http2`.
        .{ .requires_h2 = true, .result = .http2, .message = "RUI_ALPN_H2_REQUIRED: server did not negotiate h2", .version = .other, .expected = .unsupported_http_version },
        .{ .requires_h2 = true, .result = .http2, .message = "stream reset", .version = .http2, .expected = .temporary_connection },
        .{ .requires_h2 = false, .result = .http2, .message = "RUI_ALPN_H2_REQUIRED:", .version = .other, .expected = .temporary_connection },
        .{ .requires_h2 = true, .result = .ok, .message = "", .version = .http1_1, .expected = .unsupported_http_version },
        .{ .requires_h2 = true, .result = .ok, .message = "", .version = .http2, .expected = .success },
        .{ .requires_h2 = false, .result = .ok, .message = "", .version = .http2, .expected = .unsupported_http_version },
        .{ .requires_h2 = false, .result = .ok, .message = "", .version = .other, .expected = .unsupported_http_version },
        .{ .requires_h2 = false, .result = .ok, .message = "", .version = .http1_1, .expected = .success },
        // A failed transfer has no negotiated version to check.
        .{ .requires_h2 = true, .result = .recv_error, .message = "", .version = .http1_1, .expected = .temporary_connection },
    };
    for (cases) |case| {
        const evidence = try classify(.{
            .result = case.result,
            .error_message = case.message,
            .requires_h2 = case.requires_h2,
            .version = case.version,
            .response_code = 204,
            .retry_after_ms = 3_000,
        });
        try std.testing.expectEqual(case.expected, evidence.disposition);
        // Version refusals carry no status or provider retry constraint.
        if (case.expected == .unsupported_http_version) try std.testing.expectEqual(Evidence{ .disposition = .unsupported_http_version }, evidence);
    }
}

test "contradictory response headers fail the transfer unless its version is refused" {
    const invalid = try classify(.{
        .result = .ok,
        .headers_invalid = true,
        .requires_h2 = true,
        .version = .http2,
        .response_code = 200,
        .retry_after_deadline_ms = 9,
    });
    try std.testing.expectEqual(Evidence{ .disposition = .invalid_headers, .retry_after_deadline_ms = 9 }, invalid);
    // The header callback refuses the line, so curl normally reports a write error.
    try std.testing.expectEqual(Disposition.invalid_headers, (try classify(.{
        .result = .other,
        .headers_invalid = true,
        .requires_h2 = true,
        .version = .http2,
        .response_code = null,
    })).disposition);
    try std.testing.expectEqual(Disposition.unsupported_http_version, (try classify(.{
        .result = .ok,
        .headers_invalid = true,
        .requires_h2 = true,
        .version = .http1_1,
        .response_code = 200,
    })).disposition);
}

test "only HTTP responses keep their captured body" {
    for (std.enums.values(Disposition)) |disposition| {
        const answered = disposition == .permanent_http or disposition == .temporary_http;
        try std.testing.expectEqual(answered, disposition.answered());
        try std.testing.expectEqual(disposition == .success or answered, disposition.retainsResponse());
    }
}

const ns_per_ms = 1_000_000;
const ns_per_s = 1_000 * ns_per_ms;

fn at(start: Timestamp, milliseconds: i64) Timestamp {
    return start.addDuration(.{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
}

test "inactivity renews on download progress and expires at its limit" {
    const start: Timestamp = .{ .raw = .{ .nanoseconds = 100 * ns_per_s }, .clock = .awake };
    var inactivity: Inactivity = .{ .limit_ns = ns_per_s };
    // An unarmed interval belongs to a transfer that has not been added yet.
    try std.testing.expect(!inactivity.expiredAt(at(start, 5_000)));
    try std.testing.expect(!inactivity.progress(at(start, 5_000), 0));
    inactivity.arm(start);
    try std.testing.expect(!inactivity.progress(at(start, 999), 0));
    try std.testing.expect(!inactivity.expired);
    // Upload-only reports carry an unchanged download count and do not renew.
    try std.testing.expect(inactivity.progress(at(start, 1_000), 0));
    try std.testing.expect(inactivity.expired);

    inactivity.arm(start);
    try std.testing.expect(!inactivity.expired);
    try std.testing.expect(!inactivity.progress(at(start, 600), 12));
    try std.testing.expect(!inactivity.progress(at(start, 1_599), 12));
    try std.testing.expect(inactivity.expiredAt(at(start, 1_600)));
}

test "a local capture pause excludes only its own duration from inactivity" {
    const now: Timestamp = .{ .raw = .{ .nanoseconds = 100 * ns_per_s }, .clock = .awake };
    var inactivity: Inactivity = .{ .limit_ns = ns_per_s };
    inactivity.arm(at(now, -250));
    inactivity.pause(now);
    try std.testing.expect(!inactivity.expiredAt(at(now, 10_000)));
    try std.testing.expect(!inactivity.progress(at(now, 10_000), 0));
    try std.testing.expect(!inactivity.expired);
    // A synchronous callback during resume can pause again before resume returns.
    inactivity.pause(at(now, 1_000));
    try std.testing.expectEqual(now, inactivity.paused_at.?);

    const resume_at = at(now, 5_000);
    inactivity.resumeAfterPause(resume_at);
    try std.testing.expectEqual(@as(i96, 250 * ns_per_ms), inactivity.last_progress.durationTo(resume_at).raw.nanoseconds);
    var boundary = inactivity;
    try std.testing.expect(!boundary.expiredAt(at(resume_at, 749)));
    try std.testing.expect(boundary.expiredAt(at(resume_at, 750)));

    const second_pause = at(resume_at, 100);
    inactivity.pause(second_pause);
    try std.testing.expect(!inactivity.expiredAt(at(second_pause, 2_000)));
    const second_resume = at(second_pause, 2_000);
    inactivity.resumeAfterPause(second_resume);
    boundary = inactivity;
    try std.testing.expect(!boundary.expiredAt(at(second_resume, 649)));
    try std.testing.expect(boundary.expiredAt(at(second_resume, 650)));
}
