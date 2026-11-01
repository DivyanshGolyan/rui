//! The shell around a codec's reading of a sealed response. `classify`
//! gives an HTTP error body, mapped read-only, to the codec's classifier and
//! turns what it names into the error response the execution owner decides
//! on. The shell keeps every status rule, maps provider codes through
//! `transport_policy`'s closed sets, and bounds the report itself.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const codecs = @import("codecs.zig");
const execution = @import("execution.zig");
const output_format = @import("output_format.zig");
const pages = @import("os/pages.zig");
const protocol = @import("protocol.zig");
const transport_policy = @import("transport_policy.zig");

/// One response's decoding, in the execution Workspace; the Host decodes
/// one response at a time.
pub const Decode = struct {
    classify: codecs.ClassifyScratch,
};

/// One read window over a file, shared by every reader of that file. A
/// field, a nested object and the digest of an event all read the same
/// bytes, so whichever reader needs them first loads them and the rest find
/// them in memory.
pub const Window = struct {
    io: std.Io,
    file: std.Io.File,
    start: u64 = 0,
    length: usize = 0,
    bytes: [protocol.content_window_bytes]u8 = undefined,

    /// Borrowed bytes from `position` up to at most `end`, never empty; valid
    /// until the next call on this window. A read reaches no further than
    /// `end`.
    pub fn bytesAt(self: *Window, position: u64, end: u64) ![]const u8 {
        std.debug.assert(position < end);
        if (position < self.start or position >= self.start + self.length) {
            self.length = 0;
            const wanted: usize = @intCast(@min(end - position, self.bytes.len));
            const count = try self.file.readPositionalAll(self.io, self.bytes[0..wanted], position);
            if (count != wanted) return error.ShortSealedRead;
            self.start = position;
            self.length = count;
        }
        const offset: usize = @intCast(position - self.start);
        return self.bytes[offset..][0..@intCast(@min(self.length - offset, end - position))];
    }

    /// Keep bytes just written at `position`. Contiguous writes extend the
    /// window; any other write starts it again, at the write.
    pub fn remember(self: *Window, position: u64, bytes: []const u8) void {
        if (self.start + self.length != position or bytes.len > self.bytes.len - self.length) {
            self.start = position;
            self.length = 0;
        }
        if (bytes.len > self.bytes.len) return;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
};

/// The provider's own words for a failure it reported, `code: message`,
/// for the person to read beside the saved failure code. It is display text
/// only: classification and retries never read it.
pub const Report = protocol.Bounded(protocol.max_report_bytes);
pub const max_part_bytes = 256;
/// The most bytes of a range one part's decoding reads: each decoded byte
/// takes at most six (`\u0041`), and the scalar that finds the part full at
/// most twelve (a surrogate pair).
const max_part_source_bytes = 6 * max_part_bytes + 12;
const shortened_mark = "…";
comptime {
    std.debug.assert(protocol.max_report_bytes == 2 * max_part_bytes + ": ".len + 2 * shortened_mark.len);
}

/// What a provider said of a failure: the refusal its exact code names, if
/// any, and its report. Callers clear it with `clear`, which leaves the
/// report's bytes unwritten.
pub const ProviderFailure = struct {
    refusal: ?transport_policy.Refusal,
    report: Report,

    pub fn clear(self: *ProviderFailure) void {
        self.refusal = null;
        self.report.len = 0;
    }
};

/// A decoded value's first `max_part_bytes`, for one part of a report.
pub const ReportPart = struct {
    text: protocol.Bounded(max_part_bytes),
    shortened: bool,

    /// `text` holds the start of a longer value: keep its whole scalars and
    /// mark it.
    pub fn shorten(self: *ReportPart) void {
        while (!std.unicode.utf8ValidateSlice(self.text.slice())) self.text.len -= 1;
        self.shortened = true;
    }
};

/// Writes `code: message` into `report`, each part marked `…` when
/// shortened; an empty part is left out with its separator. One line:
/// line breaks, tabs and other controls read as spaces.
pub fn writeReport(report: *Report, code: *const ReportPart, message: *const ReportPart) void {
    const mark = struct {
        fn of(part: *const ReportPart) []const u8 {
            return if (part.shortened) shortened_mark else "";
        }
    }.of;
    report.len = 0;
    const separator: []const u8 = if (code.text.len != 0 and message.text.len != 0) ": " else "";
    for ([_][]const u8{ code.text.slice(), mark(code), separator, message.text.slice(), mark(message) }) |part| {
        @memcpy(report.bytes[report.len..][0..part.len], part);
        report.len += part.len;
    }
    for (report.bytes[0..report.len]) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
        byte.* = ' ';
    };
}

comptime {
    // A codec's code holds every code the Host knows.
    for (std.enums.values(transport_policy.Refusal)) |refusal| std.debug.assert(@tagName(refusal).len <= codec_abi.max_code_bytes);
}

/// Classify the sealed HTTP error body, the first `length` bytes of `body`,
/// with `codec`'s classifier, and fill `failure` with its refusal and
/// report, for every answer. Only a 4xx or 5xx body is read. A codec can
/// narrow the status rule only by a code the Host knows: quota at HTTP 429,
/// then context overflow, then a refusal at any status. A failed read is
/// `.unreadable`. Never inlined: the report's two parts stay in this rare
/// frame.
pub noinline fn classify(decode: *Decode, codec: protocol.Codec, io: std.Io, body: std.Io.File, length: u64, status: u16, failure: *ProviderFailure) execution.ErrorResponse {
    failure.clear();
    if (status < 400 or status >= 600) return .ordinary;
    const bytes = pages.mapReadOnly(io, body, length) catch |err| return .{ .unreadable = err };
    defer pages.unmapReadOnly(bytes);
    const found = codecs.classify(codec, &decode.classify, bytes);
    var code: ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    var message: ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    if (found.report.code) |range| readPart(bytes[@intCast(range.start)..][0..@intCast(range.length)], range.escape, &code);
    if (found.report.message) |range| readPart(bytes[@intCast(range.start)..][0..@intCast(range.length)], range.escape, &message);
    writeReport(&failure.report, &code, &message);
    failure.refusal = if (found.refusal) |refusal| .ofProviderCode(refusal.slice()) else null;
    if (status == 429) if (found.quota) |quota| if (transport_policy.Quota.ofProviderCode(quota.code.slice())) |known| {
        return .{ .quota = .{ .code = known, .resets_at = quota.resets_at } };
    };
    if (found.context_overflow) return .context_overflow;
    return if (failure.refusal) |refusal| .{ .refusal = refusal } else .ordinary;
}

/// Decode the first `max_part_bytes` of `bytes` into the empty `part`. A
/// range that does not decode, which a codec that judged the body would not
/// name, leaves the part empty.
fn readPart(bytes: []const u8, escape: codec_abi.Escape, part: *ReportPart) void {
    var source: SliceSource = .{ .bytes = bytes };
    decodePart(&source, escape, part);
}

/// `readPart` over the `length` bytes at `start` of a window's file. A
/// failed read leaves the part empty too.
pub fn readWindowPart(window: *Window, start: u64, length: u64, escape: codec_abi.Escape, part: *ReportPart) void {
    const end = start + length;
    var source: RangeSource = .{ .window = window, .position = start, .end = end, .limit = @min(end, start + max_part_source_bytes) };
    decodePart(&source, escape, part);
}

fn decodePart(source: anytype, escape: codec_abi.Escape, part: *ReportPart) void {
    decodeInto(source, escape, part) catch {
        part.text.len = 0;
        part.shortened = false;
    };
}

fn decodeInto(source: anytype, escape: codec_abi.Escape, part: *ReportPart) !void {
    const text = &part.text;
    while (!source.done()) {
        var scalar: [4]u8 = undefined;
        const count = switch (escape) {
            .verbatim => verbatim: {
                scalar[0] = try source.next();
                break :verbatim 1;
            },
            .json_string_v1 => try output_format.decodeScalar(source, &scalar),
        };
        const kept = @min(count, text.bytes.len - text.len);
        @memcpy(text.bytes[text.len..][0..kept], scalar[0..kept]);
        text.len += kept;
        if (kept < count) {
            part.shorten();
            return;
        }
    }
    if (!std.unicode.utf8ValidateSlice(text.slice())) text.len = 0;
}

/// A report range in memory.
const SliceSource = struct {
    bytes: []const u8,
    position: usize = 0,

    fn done(self: *const SliceSource) bool {
        return self.position == self.bytes.len;
    }

    /// One byte of JSON string contents, which holds no raw control.
    pub fn take(self: *SliceSource) !u8 {
        const byte = try self.next();
        return if (byte < 0x20) error.InvalidEncodedString else byte;
    }

    fn next(self: *SliceSource) !u8 {
        if (self.done()) return error.InvalidEncodedString;
        defer self.position += 1;
        return self.bytes[self.position];
    }
};

/// A report range read through the window.
const RangeSource = struct {
    window: *Window,
    position: u64,
    end: u64,
    /// Where reads stop: a part is full before its decoding gets there.
    limit: u64,

    fn done(self: *const RangeSource) bool {
        return self.position == self.end;
    }

    /// One byte of JSON string contents, which holds no raw control.
    pub fn take(self: *RangeSource) !u8 {
        const byte = try self.next();
        return if (byte < 0x20) error.InvalidEncodedString else byte;
    }

    fn next(self: *RangeSource) !u8 {
        if (self.done()) return error.InvalidEncodedString;
        const byte = (try self.window.bytesAt(self.position, self.limit))[0];
        self.position += 1;
        return byte;
    }
};

const pinned: protocol.Codec = .@"openai-responses/1";

var testing_decode: Decode = undefined;

const Classified = struct { response: execution.ErrorResponse, failure: ProviderFailure };

/// Classify `body` at `status`, written to a fresh file in `tmp`.
fn classifyForTesting(tmp: *std.testing.TmpDir, codec: protocol.Codec, body: []const u8, length: u64, status: u16, out: *Classified) !void {
    const file = try tmp.dir.createFile(std.testing.io, "error-body", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, body);
    out.response = classify(&testing_decode, codec, std.testing.io, file, length, status, &out.failure);
}

fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..count) |_| out = out ++ text;
    return out;
}

test "an HTTP error body keeps its refusal and the provider's own words" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { body: []const u8, status: u16, refusal: ?transport_policy.Refusal, report: []const u8 }{
        .{ .body = "{\"error\":{\"message\":\"The model `gpt-x` does not exist.\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"model_not_found\"}}", .status = 404, .refusal = .model_not_found, .report = "model_not_found: The model `gpt-x` does not exist." },
        .{ .body = "{\"error\":{\"message\":\"Unsupported parameter.\",\"type\":\"invalid_request_error\",\"code\":null}}", .status = 400, .refusal = null, .report = "invalid_request_error: Unsupported parameter." },
        // The managed route's bare detail.
        .{ .body = "{\"detail\":\"Unsupported model\"}", .status = 400, .refusal = null, .report = "Unsupported model" },
        // A duplicate code names no refusal.
        .{ .body = "{\"error\":{\"code\":\"cyber_policy\",\"co\\u0064e\":\"x\"}}", .status = 403, .refusal = null, .report = "" },
        .{ .body = "{\"error\":{\"code\":\"cyber_policy\"},\"late\":[1,]}", .status = 403, .refusal = null, .report = "" },
        .{ .body = "not json", .status = 502, .refusal = null, .report = "" },
        .{ .body = "{\"error\":{\"code\":\"cyber_policy\"}}", .status = 200, .refusal = null, .report = "" },
        // A code too long to be a refusal is shortened, not dropped.
        .{ .body = "{\"error\":{\"code\":\"" ++ comptime repeat("c", 300) ++ "\",\"message\":\"m\"}}", .status = 400, .refusal = null, .report = comptime repeat("c", 256) ++ "…: m" },
    };
    var classified: Classified = undefined;
    for (cases) |case| {
        try classifyForTesting(&tmp, pinned, case.body, case.body.len, case.status, &classified);
        try std.testing.expectEqual(case.refusal, classified.failure.refusal);
        if (case.refusal) |refusal| try std.testing.expectEqual(execution.ErrorResponse{ .refusal = refusal }, classified.response);
        try std.testing.expectEqualStrings(case.report, classified.failure.report.slice());
    }
    // Quota, then overflow, then a refusal decide; each keeps its words.
    const ordered = [_]struct { body: []const u8, status: u16, kind: std.meta.Tag(execution.ErrorResponse), report: []const u8 }{
        .{ .body = "{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"Out.\"}}", .status = 429, .kind = .quota, .report = "insufficient_quota: Out." },
        .{ .body = "{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"Out.\"}}", .status = 403, .kind = .refusal, .report = "insufficient_quota: Out." },
        .{ .body = "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Too long.\"}}", .status = 400, .kind = .context_overflow, .report = "context_length_exceeded: Too long." },
        .{ .body = "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", .status = 429, .kind = .ordinary, .report = "rate_limit_exceeded" },
    };
    for (ordered) |case| {
        try classifyForTesting(&tmp, pinned, case.body, case.body.len, case.status, &classified);
        try std.testing.expectEqual(case.kind, std.meta.activeTag(classified.response));
        try std.testing.expectEqualStrings(case.report, classified.failure.report.slice());
    }
}

test "context overflow requires exact valid provider code over HTTP" {
    const cases = .{
        .{ "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"}}", true },
        .{ "{\"error\":{\"code\":\"context_length_exceeded_extra\"}}", false },
        .{ "{\"error\":{\"message\":\"context_length_exceeded\"}}", false },
        .{ "{\"error\":{\"code\":\"context_length_exceeded\"},\"late\":[1,]}", false },
        .{ "{\"error\":{\"code\":\"context_length_exceeded\",\"code\":\"other\"}}", false },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var classified: Classified = undefined;
    inline for (cases) |case| {
        try classifyForTesting(&tmp, pinned, case[0], case[0].len, 400, &classified);
        try std.testing.expectEqual(case[1], classified.response == .context_overflow);
        try classifyForTesting(&tmp, pinned, case[0], case[0].len, 200, &classified);
        try std.testing.expect(classified.response != .context_overflow);
    }
    // A missing sealed byte is capture failure, not a malformed remote body.
    try classifyForTesting(&tmp, pinned, "{}", 3, 503, &classified);
    try std.testing.expectEqual(execution.ErrorResponse{ .unreadable = error.ShortSealedRead }, classified.response);
}

test "a malformed number makes a body not JSON, which narrows nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { body: []const u8, status: u16 }{
        .{ .body = "{\"error\":{\"code\":\"context_length_exceeded\",\"param\":1.2.3}}", .status = 400 },
        .{ .body = "{\"error\":{\"code\":\"insufficient_quota\",\"n\":0.1.1}}", .status = 429 },
        .{ .body = "{\"error\":{\"code\":\"cyber_policy\",\"x\":1.2.3}}", .status = 403 },
    };
    var classified: Classified = undefined;
    for (cases) |case| {
        try classifyForTesting(&tmp, pinned, case.body, case.body.len, case.status, &classified);
        try std.testing.expectEqual(execution.ErrorResponse.ordinary, classified.response);
        try std.testing.expectEqual(@as(?transport_policy.Refusal, null), classified.failure.refusal);
        try std.testing.expectEqual(@as(usize, 0), classified.failure.report.len);
        const disposition: transport_policy.Disposition = if (case.status == 429) .temporary_http else .permanent_http;
        const failure = execution.transferDecision(.{ .transport_finished = .{ .disposition = disposition, .http_status = case.status, .retry_after_ms = 9_000 } }, classified.response).fail;
        try std.testing.expectEqual(if (case.status == 429) execution.FailureKind.temporary else .permanent, failure.kind);
        try std.testing.expect(failure.quota == null);
    }
}

test "a large error body classifies as its small twin does" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const small = "{\"error\":{\"code\":\"usage_limit_reached\",\"resets_at\":1800000123,\"message\":\"Out.\"}}";
    var expected: Classified = undefined;
    try classifyForTesting(&tmp, pinned, small, small.len, 429, &expected);
    // The same envelope after some 850 KB of other members, with its message
    // at the start and its code at the end.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "{\"error\":{\"message\":\"Out.\",\"padding\":[");
    for (0..64 * 1024) |index| try body.print(std.testing.allocator, "{s}\"pad\\u0041{d}\"", .{ if (index == 0) "" else ",", index % 10 });
    try body.appendSlice(std.testing.allocator, "],\"resets_at\":1800000123,\"code\":\"usage_limit_reached\"},\"more\":{\"code\":\"cyber_policy\"}}");
    try std.testing.expect(body.items.len > 64 * protocol.content_window_bytes);
    var large: Classified = undefined;
    try classifyForTesting(&tmp, pinned, body.items, body.items.len, 429, &large);
    try std.testing.expectEqual(expected.response, large.response);
    try std.testing.expectEqual(expected.failure.refusal, large.failure.refusal);
    try std.testing.expectEqualStrings(expected.failure.report.slice(), large.failure.report.slice());
}
