//! The shell around a codec's reading of a sealed response. `classify`
//! feeds an HTTP error body through the codec's classifier and turns its
//! findings into the error response the execution owner decides on. The
//! codec reads the body only through the windows the shell feeds it; the
//! shell keeps every status rule, maps provider codes through
//! `transport_policy`'s closed sets, and bounds the report itself.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const codecs = @import("codecs.zig");
const execution = @import("execution.zig");
const output_format = @import("output_format.zig");
const protocol = @import("protocol.zig");
const transport_policy = @import("transport_policy.zig");

/// One response's decoding, in the execution Workspace; the Host decodes
/// one response at a time.
pub const Decode = struct {
    job: codecs.ClassifyJob,
    window: Window,
};

/// The read buffer for one body: the shell feeds the body through it, then
/// reads the report's ranges through it, so a range in the last window fed
/// costs no read. Most error bodies fit one window.
const Window = struct {
    start: u64,
    length: usize,
    bytes: [protocol.content_window_bytes]u8,

    /// The window's bytes from `position`, reading up to `end` when it does
    /// not hold them; never empty.
    fn at(self: *Window, io: std.Io, file: std.Io.File, position: u64, end: u64) ![]const u8 {
        std.debug.assert(position < end);
        if (position < self.start or position >= self.start + self.length) {
            self.length = 0;
            const wanted: usize = @intCast(@min(end - position, self.bytes.len));
            const count = try file.readPositionalAll(io, self.bytes[0..wanted], position);
            if (count != wanted) return error.ShortSealedRead;
            self.start = position;
            self.length = count;
        }
        const offset: usize = @intCast(position - self.start);
        return self.bytes[offset..][0..@intCast(@min(self.length - offset, end - position))];
    }
};

/// The provider's own words for a failure it reported, `code: message`,
/// for the person to read beside the saved failure code. It is display text
/// only: classification and retries never read it.
pub const Report = protocol.Bounded(protocol.max_report_bytes);
pub const max_part_bytes = 256;
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
    // A finding's code holds every code the Host knows.
    for (std.enums.values(transport_policy.Refusal)) |refusal| std.debug.assert(@tagName(refusal).len <= codec_abi.max_code_bytes);
}

/// What a codec found in one body, through the Host's closed sets.
const Found = struct {
    context_overflow: bool = false,
    quota: ?transport_policy.Quota = null,
    refusal: ?transport_policy.Refusal = null,
    report: std.EnumArray(codec_abi.ReportField, ?codec_abi.ReportRange) = .initFill(null),
};

/// Classify the sealed HTTP error body of `length` bytes in `body` with
/// `classifier`, and fill `failure` with its refusal and report, for every
/// answer. Only a 4xx or 5xx body is read. A codec can narrow the status
/// rule only by a code the Host knows: quota at HTTP 429, then context
/// overflow, then a refusal at any status. A codec failure or a bad finding
/// narrows nothing and leaves no report; a failed read is `.unreadable`.
/// Never inlined: the report's two parts stay in this rare frame.
pub noinline fn classify(decode: *Decode, classifier: *const codecs.Classifier, io: std.Io, body: std.Io.File, length: u64, status: u16, failure: *ProviderFailure) execution.ErrorResponse {
    failure.clear();
    if (status < 400 or status >= 600) return .ordinary;
    var found: Found = .{};
    feed(decode, classifier, io, body, length, &found) catch |err| switch (err) {
        error.CodecFailed, error.CodecBadOp => return .ordinary,
        else => return .{ .unreadable = err },
    };
    readReport(&decode.window, io, body, &found, &failure.report) catch |err| {
        failure.report.len = 0;
        return .{ .unreadable = err };
    };
    failure.refusal = found.refusal;
    if (status == 429) if (found.quota) |quota| return .{ .quota = quota };
    if (found.context_overflow) return .context_overflow;
    return if (found.refusal) |refusal| .{ .refusal = refusal } else .ordinary;
}

/// Feed the body to the codec window by window until it is done, and
/// collect what it finds. Nothing found counts unless the job ends well.
fn feed(decode: *Decode, classifier: *const codecs.Classifier, io: std.Io, body: std.Io.File, length: u64, found: *Found) !void {
    const job = &decode.job;
    const window = &decode.window;
    window.start = 0;
    window.length = 0;
    job.begin(classifier, length);
    var offset: u64 = 0;
    while (true) {
        const bytes: []const u8 = if (offset == length) &.{} else try window.at(io, body, offset, length);
        offset += bytes.len;
        const done = try job.step(&.{ .bytes = bytes, .end = offset == length });
        while (try job.next()) |finding| switch (finding) {
            .context_overflow => found.context_overflow = true,
            .quota => |quota| if (transport_policy.Quota.ofProviderCode(quota.code)) |code| {
                found.quota = .{ .code = code, .resets_at = quota.resets_at };
            },
            .refusal => |code| found.refusal = transport_policy.Refusal.ofProviderCode(code),
            .report => |range| found.report.set(range.field, range),
        };
        if (done) return;
    }
}

fn readReport(window: *Window, io: std.Io, body: std.Io.File, found: *const Found, report: *Report) !void {
    var code: ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    var message: ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    if (found.report.get(.code)) |range| try readPart(window, io, body, range, &code);
    if (found.report.get(.message)) |range| try readPart(window, io, body, range, &message);
    writeReport(report, &code, &message);
}

/// Decode a report range's first `max_part_bytes`. A range that does not
/// decode, which a codec that judged the body would not name, leaves the
/// part empty; only a failed read is an error.
fn readPart(window: *Window, io: std.Io, body: std.Io.File, range: codec_abi.ReportRange, part: *ReportPart) !void {
    var source: RangeSource = .{ .window = window, .io = io, .file = body, .position = range.start, .end = range.start + range.length, .escape = range.escape };
    const text = &part.text;
    while (source.position != source.end) {
        var scalar: [4]u8 = undefined;
        const count = source.scalar(&scalar) catch |err| switch (err) {
            error.InvalidEncodedString, error.InvalidJsonEscape, error.InvalidJsonSurrogate => {
                text.len = 0;
                return;
            },
            else => return err,
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

/// A report range read through the window.
const RangeSource = struct {
    window: *Window,
    io: std.Io,
    file: std.Io.File,
    position: u64,
    end: u64,
    escape: codec_abi.Escape,

    /// The next decoded scalar's bytes, or with `verbatim` the next byte.
    fn scalar(self: *RangeSource, out: *[4]u8) !usize {
        switch (self.escape) {
            .verbatim => {
                out[0] = try self.next();
                return 1;
            },
            .json_string_v1 => return output_format.decodeScalar(self, out),
        }
    }

    /// One byte of JSON string contents, which holds no raw control.
    pub fn take(self: *RangeSource) !u8 {
        const byte = try self.next();
        return if (byte < 0x20) error.InvalidEncodedString else byte;
    }

    fn next(self: *RangeSource) !u8 {
        if (self.position == self.end) return error.InvalidEncodedString;
        const byte = (try self.window.at(self.io, self.file, self.position, self.end))[0];
        self.position += 1;
        return byte;
    }
};

const pinned = codecs.classifier(.@"openai-responses/1");

var testing_decode: Decode = undefined;

const Classified = struct { response: execution.ErrorResponse, failure: ProviderFailure };

/// Classify `body` at `status`, written to a fresh file in `tmp`.
fn classifyForTesting(tmp: *std.testing.TmpDir, classifier: *const codecs.Classifier, body: []const u8, length: u64, status: u16, out: *Classified) !void {
    const file = try tmp.dir.createFile(std.testing.io, "error-body", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, body);
    out.response = classify(&testing_decode, classifier, std.testing.io, file, length, status, &out.failure);
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

/// The pinned classifier, with its answer to the last window replaced:
/// it fails, or it adds `ops` to its findings.
fn FaultyClassifier(comptime fault: union(enum) { failure, ops: []const u8 }) type {
    return struct {
        const classifier: codecs.Classifier = .{ .init = pinned.init, .step = step };

        fn step(state: *codecs.ClassifierState, fed: *const codec_abi.Fed, ops: *codec_abi.Ops) codec_abi.Status {
            const status = pinned.step(state, fed, ops);
            if (!fed.end) return status;
            switch (fault) {
                .failure => return .failed,
                .ops => |bytes| {
                    @memcpy(ops.bytes[ops.length..][0..bytes.len], bytes);
                    ops.length += @intCast(bytes.len);
                    return status;
                },
            }
        }
    };
}

test "a classifier failure narrows nothing and keeps the status rule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const quota = "{\"error\":{\"code\":\"usage_limit_reached\",\"resets_at\":1800000123,\"message\":\"Out.\"}}";
    const overflow = "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Too long.\"}}";
    const refusal = "{\"error\":{\"code\":\"cyber_policy\",\"message\":\"No.\"}}";
    var classified: Classified = undefined;
    // The pinned classifier narrows each body.
    try classifyForTesting(&tmp, pinned, quota, quota.len, 429, &classified);
    try std.testing.expectEqual(execution.ErrorResponse{ .quota = .{ .code = .usage_limit_reached, .resets_at = 1_800_000_123 } }, classified.response);
    try std.testing.expectEqualStrings("usage_limit_reached: Out.", classified.failure.report.slice());
    // Failing after it found them, it narrows nothing and leaves no report,
    // so each status keeps its own rule: a 429 stays a retryable rate limit.
    const failing = &FaultyClassifier(.failure).classifier;
    for ([_][]const u8{ quota, overflow, refusal }) |body| for ([_]u16{ 429, 400, 403, 503 }) |status| {
        try classifyForTesting(&tmp, failing, body, body.len, status, &classified);
        try std.testing.expectEqual(execution.ErrorResponse.ordinary, classified.response);
        try std.testing.expectEqual(@as(?transport_policy.Refusal, null), classified.failure.refusal);
        try std.testing.expectEqual(@as(usize, 0), classified.failure.report.len);
        const disposition: transport_policy.Disposition = if (status == 429 or status == 503) .temporary_http else .permanent_http;
        const failure = execution.transferDecision(.{ .transport_finished = .{ .disposition = disposition, .http_status = status, .retry_after_ms = 9_000 } }, classified.response).fail;
        try std.testing.expectEqual(if (disposition == .temporary_http) execution.FailureKind.temporary else .permanent, failure.kind);
        try std.testing.expect(failure.quota == null);
        const Code = @TypeOf(failure.code);
        const code: Code = if (disposition == .temporary_http) .{ .temporary_http = status } else .{ .http = status };
        try std.testing.expectEqual(code, failure.code);
    };
}

test "a bad classifier finding narrows nothing and leaves no report" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const quota = "{\"error\":{\"code\":\"usage_limit_reached\",\"message\":\"Out.\"}}";
    const past_end = comptime [_]u8{ 8, 1, 1 } ++ std.mem.toBytes(@as(u64, quota.len)) ++ std.mem.toBytes(@as(u64, 1));
    var classified: Classified = undefined;
    inline for (comptime [_][]const u8{
        // A second quota, a report past the body, an unknown tag, an encode
        // op, a cut finding.
        &([_]u8{ 6, 1, 0 } ++ std.mem.toBytes(@as(u64, 0)) ++ [_]u8{'x'}),
        &past_end,
        &.{0xff},
        &.{ 1, 1, 0, '{' },
        &.{ 7, 5, 'a' },
    }) |ops| {
        try classifyForTesting(&tmp, &FaultyClassifier(.{ .ops = ops }).classifier, quota, quota.len, 429, &classified);
        try std.testing.expectEqual(execution.ErrorResponse.ordinary, classified.response);
        try std.testing.expectEqual(@as(?transport_policy.Refusal, null), classified.failure.refusal);
        try std.testing.expectEqual(@as(usize, 0), classified.failure.report.len);
    }
    // A codec that wants more after the last window is a bad codec too.
    const Unfinished = struct {
        const classifier: codecs.Classifier = .{ .init = pinned.init, .step = step };
        fn step(state: *codecs.ClassifierState, fed: *const codec_abi.Fed, ops: *codec_abi.Ops) codec_abi.Status {
            _ = pinned.step(state, fed, ops);
            return .next;
        }
    };
    try classifyForTesting(&tmp, &Unfinished.classifier, quota, quota.len, 429, &classified);
    try std.testing.expectEqual(execution.ErrorResponse.ordinary, classified.response);
    try std.testing.expectEqual(@as(usize, 0), classified.failure.report.len);
}

test "a large error body is classified in bounded windows as a small one is" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The pinned classifier, counting the windows it is fed.
    const Counting = struct {
        var windows: usize = 0;
        var longest: usize = 0;
        const classifier: codecs.Classifier = .{ .init = pinned.init, .step = step };
        fn step(state: *codecs.ClassifierState, fed: *const codec_abi.Fed, ops: *codec_abi.Ops) codec_abi.Status {
            windows += 1;
            longest = @max(longest, fed.bytes.len);
            return pinned.step(state, fed, ops);
        }
    };
    const small = "{\"error\":{\"code\":\"usage_limit_reached\",\"resets_at\":1800000123,\"message\":\"Out.\"}}";
    var expected: Classified = undefined;
    try classifyForTesting(&tmp, pinned, small, small.len, 429, &expected);
    // The same envelope after some 850 KB of other members, with its message
    // in the first window and its code in the last.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "{\"error\":{\"message\":\"Out.\",\"padding\":[");
    for (0..64 * 1024) |index| try body.print(std.testing.allocator, "{s}\"pad\\u0041{d}\"", .{ if (index == 0) "" else ",", index % 10 });
    try body.appendSlice(std.testing.allocator, "],\"resets_at\":1800000123,\"code\":\"usage_limit_reached\"},\"more\":{\"code\":\"cyber_policy\"}}");
    try std.testing.expect(body.items.len > 64 * protocol.content_window_bytes);
    var large: Classified = undefined;
    try classifyForTesting(&tmp, &Counting.classifier, body.items, body.items.len, 429, &large);
    try std.testing.expectEqual(expected.response, large.response);
    try std.testing.expectEqual(expected.failure.refusal, large.failure.refusal);
    try std.testing.expectEqualStrings(expected.failure.report.slice(), large.failure.report.slice());
    try std.testing.expectEqual(std.math.divCeil(usize, body.items.len, protocol.content_window_bytes) catch unreachable, Counting.windows);
    try std.testing.expectEqual(protocol.content_window_bytes, Counting.longest);
    // The classifier's whole state is its fixed storage, whatever the body.
    try std.testing.expect(@sizeOf(@import("codecs/responses.zig").Classifier) <= codecs.max_classifier_state_bytes);
}
