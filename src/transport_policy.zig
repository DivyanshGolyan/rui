//! Model transport policy over values: how a finished provider stream is
//! classified, which outcomes keep the response body, and how a provider's
//! Retry-After is read. `provider.zig` owns the h2 Client, the capture and
//! the clock reads, and passes their facts here.
const std = @import("std");

pub const Disposition = enum {
    success,
    permanent_http,
    temporary_http,
    temporary_connection,
    permanent_transport,
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

/// Recognized HTTP 429 refusals, not temporary rate limits. Only this closed
/// code and a valid reset timestamp may enter the saved diagnostic.
pub const Quota = struct {
    code: Code,
    resets_at: ?u64 = null,

    pub const Code = enum { usage_limit_reached, insufficient_quota, usage_not_included };

    pub fn failureCode(self: Quota) []const u8 {
        return switch (self.code) {
            .usage_limit_reached => "provider_usage_limit_reached",
            .insufficient_quota => "provider_insufficient_quota",
            .usage_not_included => "provider_usage_not_included",
        };
    }

    pub fn format(self: Quota, buffer: *[512]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{{\"provider_code\":\"{s}\",\"resets_at\":{?d}}}", .{
            @tagName(self.code), self.resets_at,
        }) catch unreachable;
    }
};

pub const CaptureFailure = enum { scratch_exhausted, write_failed, seal_failed };

pub const TransferOutcome = union(enum) {
    response_capture_failed: CaptureFailure,
    request_source_failed,
    transport_finished: Evidence,
};

/// How an h2 stream ended: `h2.Cause` tag for tag. This file stays free of
/// the transport build, so `provider.zig` converts by name and fails to
/// compile if either enum gains a tag the other lacks.
pub const Cause = enum {
    complete,
    sink_refused,
    sink_failed,
    body_failed,
    rejected_headers,
    h2_refused,
    untrusted_peer,
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

/// Facts about one finished h2 stream, gathered by `provider.zig`.
pub const Finished = struct {
    cause: Cause,
    /// The final response status, once a final header block arrived.
    status: ?u16,
    /// The receiver refused a header block for want of memory, not for its
    /// values.
    headers_local_failure: bool = false,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

/// The priority order is capture failure, then request source, then the
/// transport's evidence.
pub fn outcome(finished: Finished) error{InvalidHttpEvidence}!TransferOutcome {
    const disposition: Disposition = switch (finished.cause) {
        .sink_refused => return .{ .response_capture_failed = .scratch_exhausted },
        .sink_failed => return .{ .response_capture_failed = .write_failed },
        .body_failed => return .request_source_failed,
        .complete => return .{ .transport_finished = try answered(finished) },
        .rejected_headers => if (finished.headers_local_failure) .permanent_transport else .invalid_headers,
        .h2_refused => .unsupported_http_version,
        .untrusted_peer => .tls_verification_failure,
        .resolve_failed,
        .connect_failed,
        .connect_timeout,
        .tls_failed,
        .connection_lost,
        .protocol_error,
        .reset_by_peer,
        .refused,
        .peer_silent,
        .inactive,
        => .temporary_connection,
        .local_failure => .permanent_transport,
    };
    // A refused version carries no provider retry constraint.
    if (disposition == .unsupported_http_version) return .{ .transport_finished = .{ .disposition = disposition } };
    return .{ .transport_finished = .{
        .disposition = disposition,
        .retry_after_ms = finished.retry_after_ms,
        .retry_after_deadline_ms = finished.retry_after_deadline_ms,
    } };
}

fn answered(finished: Finished) error{InvalidHttpEvidence}!Evidence {
    const status = finished.status orelse return error.InvalidHttpEvidence;
    if (status < 100 or status > 599) return error.InvalidHttpEvidence;
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

pub const RetryAfter = union(enum) {
    delay_ms: u64,
    deadline_ms: i64,
};

/// Delta-seconds, or an HTTP-date in any of RFC 9110's three forms.
pub fn parseRetryAfter(value: []const u8, now_seconds: i64) ?RetryAfter {
    if (value.len == 0 or value.len > 128) return null;
    if (std.fmt.parseInt(u64, value, 10)) |seconds| {
        const delay_ms = std.math.mul(u64, seconds, 1000) catch return null;
        if (delay_ms > std.math.maxInt(i64)) return null;
        const now_ms = std.math.mul(i64, now_seconds, 1000) catch return null;
        _ = std.math.add(i64, now_ms, @intCast(delay_ms)) catch return null;
        return .{ .delay_ms = delay_ms };
    } else |_| {}
    const due_seconds = parseHttpDate(value) orelse return null;
    return .{ .deadline_ms = std.math.mul(i64, due_seconds, 1000) catch return null };
}

const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const long_day_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Seconds since the epoch for an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37
/// GMT`), an RFC 850 date (`Sunday, 06-Nov-94 08:49:37 GMT`) or an asctime
/// date (`Sun Nov  6 08:49:37 1994`). The weekday is checked against the
/// date, as RFC 9110 lets a recipient do.
pub fn parseHttpDate(value: []const u8) ?i64 {
    var day: u8 = undefined;
    var month: u4 = undefined;
    var year: u16 = undefined;
    var time: []const u8 = undefined;
    var weekday: usize = undefined;
    if (value.len == 29 and value[3] == ',' and std.mem.endsWith(u8, value, " GMT")) {
        // IMF-fixdate.
        weekday = indexOf(&day_names, value[0..3]) orelse return null;
        if (value[4] != ' ' or value[7] != ' ' or value[11] != ' ' or value[16] != ' ') return null;
        day = digits(u8, value[5..7]) orelse return null;
        month = monthOf(value[8..11]) orelse return null;
        year = digits(u16, value[12..16]) orelse return null;
        time = value[17..25];
    } else if (std.mem.indexOfScalar(u8, value, ',')) |comma| {
        // RFC 850: two-digit years within 50 years of now are not knowable
        // here, so they are read as 19xx when 50 or more, 20xx otherwise.
        weekday = indexOf(&long_day_names, value[0..comma]) orelse return null;
        const rest = value[comma + 1 ..];
        if (rest.len != 23 or rest[0] != ' ' or rest[3] != '-' or rest[7] != '-' or rest[10] != ' ' or !std.mem.endsWith(u8, rest, " GMT")) return null;
        day = digits(u8, rest[1..3]) orelse return null;
        month = monthOf(rest[4..7]) orelse return null;
        const short = digits(u16, rest[8..10]) orelse return null;
        year = if (short >= 50) 1900 + short else 2000 + short;
        time = rest[11..19];
    } else if (value.len == 24) {
        // asctime.
        weekday = indexOf(&day_names, value[0..3]) orelse return null;
        if (value[3] != ' ' or value[7] != ' ' or value[10] != ' ' or value[19] != ' ') return null;
        month = monthOf(value[4..7]) orelse return null;
        day = if (value[8] == ' ') digits(u8, value[9..10]) orelse return null else digits(u8, value[8..10]) orelse return null;
        time = value[11..19];
        year = digits(u16, value[20..24]) orelse return null;
    } else return null;
    if (time[2] != ':' or time[5] != ':') return null;
    const hour = digits(u8, time[0..2]) orelse return null;
    const minute = digits(u8, time[3..5]) orelse return null;
    const second = digits(u8, time[6..8]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    if (year < 1970 or day == 0 or day > daysInMonth(year, month)) return null;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += @as(u16, if (isLeap(y)) 366 else 365);
    var m: u4 = 1;
    while (m < month) : (m += 1) days += daysInMonth(year, m);
    days += day - 1;
    // 1970-01-01 was a Thursday.
    if (@as(usize, @intCast(@mod(days + 3, 7))) != weekday) return null;
    return days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn isLeap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u16, month: u4) u8 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn indexOf(names: []const []const u8, text: []const u8) ?usize {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, text)) return index;
    return null;
}

fn monthOf(text: []const u8) ?u4 {
    return @intCast((indexOf(&month_names, text) orelse return null) + 1);
}

fn digits(comptime T: type, text: []const u8) ?T {
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

test "h2 endings retry only temporary connection loss and keep their Retry-After" {
    const cases = [_]struct { cause: Cause, local: bool = false, expected: Disposition }{
        .{ .cause = .connect_failed, .expected = .temporary_connection },
        .{ .cause = .resolve_failed, .expected = .temporary_connection },
        .{ .cause = .connect_timeout, .expected = .temporary_connection },
        .{ .cause = .tls_failed, .expected = .temporary_connection },
        .{ .cause = .connection_lost, .expected = .temporary_connection },
        .{ .cause = .protocol_error, .expected = .temporary_connection },
        .{ .cause = .reset_by_peer, .expected = .temporary_connection },
        .{ .cause = .refused, .expected = .temporary_connection },
        .{ .cause = .peer_silent, .expected = .temporary_connection },
        .{ .cause = .inactive, .expected = .temporary_connection },
        .{ .cause = .untrusted_peer, .expected = .tls_verification_failure },
        .{ .cause = .rejected_headers, .expected = .invalid_headers },
        // A block refused for want of memory is a local failure, not the
        // provider's contradiction.
        .{ .cause = .rejected_headers, .local = true, .expected = .permanent_transport },
        .{ .cause = .local_failure, .expected = .permanent_transport },
    };
    for (cases) |case| {
        const result = try outcome(.{
            .cause = case.cause,
            .status = null,
            .headers_local_failure = case.local,
            .retry_after_ms = 7_000,
            .retry_after_deadline_ms = 1_700_000_001_000,
        });
        try std.testing.expectEqual(TransferOutcome{ .transport_finished = .{
            .disposition = case.expected,
            .retry_after_ms = 7_000,
            .retry_after_deadline_ms = 1_700_000_001_000,
        } }, result);
    }
}

test "local capture and request failures come before transport evidence" {
    try std.testing.expectEqual(TransferOutcome{ .response_capture_failed = .scratch_exhausted }, try outcome(.{ .cause = .sink_refused, .status = 200 }));
    try std.testing.expectEqual(TransferOutcome{ .response_capture_failed = .write_failed }, try outcome(.{ .cause = .sink_failed, .status = 200 }));
    try std.testing.expectEqual(TransferOutcome.request_source_failed, try outcome(.{ .cause = .body_failed, .status = null }));
}

test "a peer that does not speak HTTP/2 is refused without a retry constraint" {
    try std.testing.expectEqual(
        TransferOutcome{ .transport_finished = .{ .disposition = .unsupported_http_version } },
        try outcome(.{ .cause = .h2_refused, .status = null, .retry_after_ms = 3_000 }),
    );
}

test "HTTP status classes and their Retry-After constraints" {
    const cases = [_]struct { status: ?u16, expected: ?Disposition }{
        .{ .status = 200, .expected = .success },
        .{ .status = 299, .expected = .success },
        .{ .status = 300, .expected = .permanent_http },
        .{ .status = 400, .expected = .permanent_http },
        .{ .status = 407, .expected = .permanent_http },
        .{ .status = 408, .expected = .temporary_http },
        .{ .status = 429, .expected = .temporary_http },
        .{ .status = 499, .expected = .permanent_http },
        .{ .status = 500, .expected = .temporary_http },
        .{ .status = 599, .expected = .temporary_http },
        .{ .status = 99, .expected = null },
        .{ .status = 600, .expected = null },
        .{ .status = null, .expected = null },
    };
    for (cases) |case| {
        const finished: Finished = .{ .cause = .complete, .status = case.status, .retry_after_ms = 12_000 };
        const expected = case.expected orelse {
            try std.testing.expectError(error.InvalidHttpEvidence, outcome(finished));
            continue;
        };
        try std.testing.expectEqual(TransferOutcome{ .transport_finished = .{
            .disposition = expected,
            .http_status = case.status.?,
            .retry_after_ms = 12_000,
        } }, try outcome(finished));
    }
}

test "only HTTP responses keep their captured body" {
    for (std.enums.values(Disposition)) |disposition| {
        const is_answer = disposition == .permanent_http or disposition == .temporary_http;
        try std.testing.expectEqual(is_answer, disposition.answered());
        try std.testing.expectEqual(disposition == .success or is_answer, disposition.retainsResponse());
    }
}

test "Retry-After preserves dates and delays without unchecked arithmetic" {
    try std.testing.expectEqual(RetryAfter{ .delay_ms = 12_000 }, parseRetryAfter("12", 1_700_000_000).?);
    try std.testing.expectEqual(RetryAfter{ .deadline_ms = 1_700_000_001_000 }, parseRetryAfter("Tue, 14 Nov 2023 22:13:21 GMT", 1_700_000_000).?);
    try std.testing.expectEqual(RetryAfter{ .deadline_ms = 1_699_999_999_000 }, parseRetryAfter("Tue, 14 Nov 2023 22:13:19 GMT", 1_700_000_000).?);
    try std.testing.expect(parseRetryAfter("9223372036854775", 1_700_000_000) == null);
    try std.testing.expect(parseRetryAfter("invalid", 1_700_000_000) == null);
    try std.testing.expect(parseRetryAfter("18446744073709551615", 1_700_000_000) == null);
}

test "HTTP-dates in all three RFC 9110 forms, and nothing else" {
    // RFC 9110 section 5.6.7's example instant, 784111777.
    for ([_][]const u8{
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
    }) |date| try std.testing.expectEqual(@as(?i64, 784_111_777), parseHttpDate(date));
    try std.testing.expectEqual(@as(?i64, 0), parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 951_782_400), parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 1_700_000_001), parseHttpDate("Tuesday, 14-Nov-23 22:13:21 GMT"));
    try std.testing.expectEqual(@as(?i64, 1_700_000_001), parseHttpDate("Tue Nov 14 22:13:21 2023"));
    for ([_][]const u8{
        "Mon, 06 Nov 1994 08:49:37 GMT", // wrong weekday
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "Sun, 31 Nov 1994 08:49:37 GMT",
        "Thu, 29 Feb 2001 00:00:00 GMT",
        "Sun, 06 Nov 1994 24:00:00 GMT",
        "Sun, 06 Nov 1994 08:60:00 GMT",
        "Sun, 6 Nov 1994 08:49:37 GMT",
        "Sun, 06 Foo 1994 08:49:37 GMT",
        "Wed, 31 Dec 1969 23:59:59 GMT",
        "Sun, 06 Nov 1994 08:49:37 GMT ",
        "Sundae, 06-Nov-94 08:49:37 GMT",
        "Sun Nov 6 08:49:37 1994",
        "",
    }) |date| try std.testing.expectEqual(@as(?i64, null), parseHttpDate(date));
}
