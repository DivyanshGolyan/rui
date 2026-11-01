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
const json = @import("codecs/json.zig");
const named_scratch = @import("named_scratch.zig");
const output_format = @import("output_format.zig");
const protocol = @import("protocol.zig");
const transport_policy = @import("transport_policy.zig");

/// One response's decoding, in the execution Workspace; the Host decodes
/// one response at a time.
pub const Decode = struct {
    job: codecs.ClassifyJob,
    window: Window,
};

/// One read window over a file, shared by every reader of that file. A
/// field, a nested object and the digest of an event all read the same
/// bytes, so whichever reader needs them first loads them and the rest find
/// them in memory. `classify` feeds a body through it, then reads the
/// report's ranges through it, so a range in the last window fed costs no
/// read.
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
    const window = &decode.window;
    window.io = io;
    window.file = body;
    window.start = 0;
    window.length = 0;
    var found: Found = .{};
    feed(decode, classifier, length, &found) catch |err| switch (err) {
        error.CodecFailed, error.CodecBadOp => return .ordinary,
        else => return .{ .unreadable = err },
    };
    readReport(window, &found, &failure.report) catch |err| {
        failure.report.len = 0;
        return .{ .unreadable = err };
    };
    failure.refusal = found.refusal;
    if (status == 429) if (found.quota) |quota| return .{ .quota = quota };
    if (found.context_overflow) return .context_overflow;
    return if (found.refusal) |refusal| .{ .refusal = refusal } else .ordinary;
}

/// Feed the window's body of `length` bytes to the codec window by window
/// until it is done, and collect what it finds. Nothing found counts unless
/// the job ends well.
fn feed(decode: *Decode, classifier: *const codecs.Classifier, length: u64, found: *Found) !void {
    const job = &decode.job;
    job.begin(classifier, length);
    var offset: u64 = 0;
    while (true) {
        const bytes: []const u8 = if (offset == length) &.{} else try decode.window.bytesAt(offset, length);
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

fn readReport(window: *Window, found: *const Found, report: *Report) !void {
    var code: ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    var message: ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    if (found.report.get(.code)) |range| try readPart(window, range.start, range.length, range.escape, &code);
    if (found.report.get(.message)) |range| try readPart(window, range.start, range.length, range.escape, &message);
    writeReport(report, &code, &message);
}

/// Decode the first `max_part_bytes` of the `length` bytes at `start` into
/// the empty `part`. A range that does not decode, which a codec that judged
/// the body would not name, leaves the part empty; only a failed read is an
/// error.
pub fn readPart(window: *Window, start: u64, length: u64, escape: codec_abi.Escape, part: *ReportPart) !void {
    const end = start + length;
    var source: RangeSource = .{ .window = window, .position = start, .end = end, .limit = @min(end, start + max_part_source_bytes), .escape = escape };
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
    position: u64,
    end: u64,
    /// Where reads stop: a part is full before its decoding gets there.
    limit: u64,
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
        const byte = (try self.window.bytesAt(self.position, self.limit))[0];
        self.position += 1;
        return byte;
    }
};

// ------------------------------------------------------------- interpret

pub const max_evidence_bytes = 256;

pub const Evidence = struct {
    response_id: protocol.Bounded(max_evidence_bytes) = .{},
    served_model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

pub const Rejection = struct {
    stage: codec_abi.Stage = .stream,
    byte_offset: u64 = 0,
    output_index: ?u64 = null,

    // Only local error names and structural coordinates. Never copy provider
    // strings, IDs, text, arguments or private continuation into this detail.
    pub fn format(self: Rejection, err: anyerror, buffer: *[512]u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "{{\"reason\":\"{s}\",\"stage\":\"{s}\",\"byte_offset\":\"{d}\",\"output_index\":{?d}}}",
            .{ @errorName(err), @tagName(self.stage), self.byte_offset, self.output_index },
        ) catch unreachable;
    }
};

pub const Validated = struct {
    /// Borrowed decoded SSE bytes, valid until EventData.deinit().
    source: std.Io.File,
    source_length: u64,
    item_count: u64,
    call_count: u64,
    answer_item_ordinal: ?u64,
    answer_length: u64,
    answer_digest: [32]u8,
    evidence: Evidence,
};

/// One validation workspace, not one buffer per event or live transport.
/// Keep raw capture immutable for diagnostics; metadata addresses these bytes.
pub const EventData = struct {
    /// Owns the file and keeps the newest bytes written, so the event they
    /// complete parses from memory.
    window: Window,
    budget: protocol.ScratchBudget,
    length: u64 = 0,
    charged: u64 = 0,

    /// Fills `self` with an empty unlinked scratch file. On error `self`
    /// owns nothing and `retained` holds any name left to reclaim.
    pub fn init(self: *EventData, io: std.Io, scratch_path: []const u8, name: []const u8, budget: protocol.ScratchBudget, fail_unlink: bool, retained: *?named_scratch.Owner) !void {
        retained.* = null;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        const file = try scratch.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        if (fail_unlink) {
            retained.* = .init(io, file, null, name, budget, 0, .injected_failure);
            return error.InjectedEventDataUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = .init(io, file, null, name, budget, 0, .native);
            return err;
        };
        self.* = .{ .window = .{ .io = io, .file = file }, .budget = budget };
    }

    pub fn append(self: *EventData, bytes: []const u8) !void {
        if (!self.budget.allocate(bytes.len)) return error.EventDataScratchExhausted;
        // A partial write remains charged until disposal, just like capture.
        self.charged += bytes.len;
        self.window.file.writeStreamingAll(self.window.io, bytes) catch return error.EventDataWriteFailed;
        self.window.remember(self.length, bytes);
        self.length += bytes.len;
    }

    pub fn copy(self: *EventData, source: *Window, start: u64, length: u64) !void {
        // Appending moves this window, so it cannot also be the source.
        std.debug.assert(source != &self.window);
        var offset = start;
        const end = try std.math.add(u64, start, length);
        while (offset < end) {
            const bytes = try source.bytesAt(offset, end);
            try self.append(bytes);
            offset += bytes.len;
        }
    }

    pub fn seal(self: *EventData) !void {
        const length = self.window.file.length(self.window.io) catch return error.EventDataSealFailed;
        if (length != self.length) return error.EventDataSealFailed;
    }

    pub fn deinit(self: *EventData) void {
        self.window.file.close(self.window.io);
        self.budget.release(self.charged);
    }
};

pub fn isWhitespace(scalar: u21) bool {
    // Unicode White_Space, matching the provider client's empty-answer test.
    return switch (scalar) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// Which message is the response's answer, as its messages are accepted.
pub const AnswerSelection = struct {
    ordinal: ?u64 = null,
    length: u64 = 0,
    digest: [32]u8,
    phased: bool = false,
    finals: u64 = 0,

    /// An accepted message, as answer selection reads it.
    pub const Message = struct {
        ordinal: u64,
        phase: codec_abi.Phase,
        /// Its text's decoded length and digest.
        length: u64,
        digest: [32]u8,
        non_whitespace: bool,
    };

    pub fn accept(self: *AnswerSelection, message: *const Message) void {
        const phase = message.phase;
        if (phase != .unphased) self.phased = true;
        if (phase == .final_answer) self.finals += 1;
        if (phase == .final_answer or (!self.phased and phase == .unphased)) {
            self.ordinal = message.ordinal;
            self.length = if (message.non_whitespace) message.length else 0;
            self.digest = if (message.non_whitespace) message.digest else protocol.contentDigest("");
        } else if (self.phased and self.finals == 0) {
            // Mixed phased/unphased text is visible, but only an explicit
            // final can terminate a phased response without Tool Calls.
            self.ordinal = null;
            self.length = 0;
            self.digest = protocol.contentDigest("");
        }
    }
};

/// One response's interpretation, in its caller's storage: the codec's job,
/// the read window over the capture, and what the Host keeps of the stream.
pub const Interpret = struct {
    job: codecs.InterpretJob,
    capture: Window,
    grammar: Grammar,
};

/// The most bytes one window the codec is fed may hold.
pub const Feed = struct { most: usize = protocol.content_window_bytes };

/// Interpret the sealed SSE capture of `source_length` bytes in
/// `source_file` with `interpreter`. The Host frames the events: each
/// event's data is written to `event_data` and fed to the codec from memory
/// as it is written. The codec judges the grammar and names spans; the Host
/// hashes and decodes them, writes `metadata` from them, and keeps every
/// rule that compares items with each other, the answer selection and the
/// completion gate. A failure leaves `rejection` at its coordinates and
/// `provider_failure` with what a provider error event said. A codec that
/// names bytes outside the event it is fed, or asks to be fed outside it,
/// fails `error.CodecBadOp`.
pub fn interpret(
    storage: *Interpret,
    interpreter: *const codecs.Interpreter,
    io: std.Io,
    source_file: std.Io.File,
    source_length: u64,
    metadata: *output_format.OutputMetadataWriter,
    event_data: *EventData,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    provider_failure: *ProviderFailure,
    cut: Feed,
    validated: *Validated,
) !void {
    std.debug.assert(cut.most != 0);
    provider_failure.clear();
    rejection.* = .{};
    const grammar = &storage.grammar;
    grammar.begin(metadata, &event_data.window, operation, rejection, provider_failure);
    storage.job.begin(interpreter, switch (operation) {
        .assistant_response => .assistant_response,
        .compaction => .compaction,
    });
    var stream: Stream = .{ .job = &storage.job, .grammar = grammar, .event_data = event_data, .most = cut.most, .fed = event_data.length, .event_start = event_data.length, .high = event_data.length, .again = null };
    const capture = &storage.capture;
    capture.io = io;
    capture.file = source_file;
    capture.start = 0;
    capture.length = 0;
    var position: u64 = 0;
    if (source_length >= 3 and std.mem.startsWith(u8, try capture.bytesAt(0, source_length), "\xef\xbb\xbf")) position = 3;
    // Where the open event's data begins in `event_data`.
    var data: ?u64 = null;
    while (position < source_length) {
        rejection.* = .{ .byte_offset = position };
        // SSE has three line endings. Retain only the field prefix; payload
        // writes use fixed windows, never line buffers.
        const line_start = position;
        var head: [16]u8 = undefined;
        while (position < source_length) {
            const bytes = try capture.bytesAt(position, source_length);
            const length = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
            const index = position - line_start;
            if (index < head.len) {
                const kept = @min(length, head.len - @as(usize, @intCast(index)));
                @memcpy(head[@intCast(index)..][0..kept], bytes[0..kept]);
            }
            position += length;
            if (length < bytes.len) break;
        }
        const line_end = position;
        if (position < source_length) {
            const ending = (try capture.bytesAt(position, source_length))[0];
            position += 1;
            if (ending == '\r' and position < source_length and (try capture.bytesAt(position, source_length))[0] == '\n') position += 1;
        }
        const line_length = line_end - line_start;
        const shown = head[0..@intCast(@min(line_length, head.len))];
        if (line_length == 0) {
            if (data) |start| {
                if (event_data.length == start) return error.EmptySseData;
                try stream.endEvent();
                data = null;
            }
            continue;
        }
        if (std.mem.eql(u8, shown, "data") or std.mem.startsWith(u8, shown, "data:")) {
            var skip: usize = @intCast(@min(line_length, "data:".len));
            if (shown.len > skip and shown[skip] == ' ') skip += 1;
            if (data == null) {
                data = event_data.length;
                stream.beginEvent();
                grammar.raw_start = line_start + skip;
            } else try stream.append("\n");
            var offset = line_start + skip;
            while (offset < line_end) {
                const bytes = try capture.bytesAt(offset, line_end);
                offset += bytes.len;
                try stream.append(bytes);
            }
        }
        // Comments and every other field, including colonless fields, carry
        // no provider output authority. Field names are case-sensitive.
    }
    if (data != null) return error.IncompleteSseEvent;
    try stream.end();
    try event_data.seal();
    validated.* = .{
        .source = event_data.window.file,
        .source_length = event_data.length,
        .item_count = grammar.item_count,
        .call_count = grammar.call_count,
        .answer_item_ordinal = grammar.answer.ordinal,
        .answer_length = grammar.answer.length,
        .answer_digest = grammar.answer.digest,
        .evidence = grammar.evidence,
    };
}

/// Feeds the codec the event data as it is written, and hands each record
/// it answers to the grammar. A codec reads only the open event: every span
/// it names lies in the event's bytes fed so far, and it asks to be fed on
/// from within them. A `need` that does not move past the start of the
/// window it answers names a later offset than the last such `need`, and
/// any other moves the next window's start on, so the Host feeds each event
/// a bounded number of times.
const Stream = struct {
    job: *codecs.InterpretJob,
    grammar: *Grammar,
    event_data: *EventData,
    most: usize,
    /// Where the codec reads next.
    fed: u64,
    /// Where the open event's data begins, and the end of its bytes fed so
    /// far.
    event_start: u64,
    high: u64,
    /// The last `need` in the event that did not move past its window's
    /// start.
    again: ?u64,

    fn beginEvent(self: *Stream) void {
        self.event_start = self.event_data.length;
        self.high = self.event_start;
        self.again = null;
    }

    fn append(self: *Stream, bytes: []const u8) !void {
        try self.event_data.append(bytes);
        try self.pump();
    }

    /// Feed every byte written from where the codec reads next. The bytes
    /// just written are in the event data's window; only a codec reading a
    /// value again reads the file.
    fn pump(self: *Stream) !void {
        const length = self.event_data.length;
        while (self.fed < length) {
            const bytes = try self.event_data.window.bytesAt(self.fed, @min(length, self.fed + self.most));
            _ = try self.step(&.{ .offset = self.fed, .bytes = bytes, .event_end = false, .end = false });
        }
    }

    /// The open event's data is whole: the codec judges it, and may read it
    /// again first. Nothing it names afterwards lies in the event.
    fn endEvent(self: *Stream) !void {
        while (true) {
            try self.pump();
            _ = try self.step(&.{ .offset = self.event_data.length, .bytes = &.{}, .event_end = true, .end = false });
            if (!self.job.needed) break;
        }
        self.beginEvent();
    }

    fn end(self: *Stream) !void {
        // A codec that is not done at the end has failed the stream.
        if (!try self.step(&.{ .offset = self.event_data.length, .bytes = &.{}, .event_end = false, .end = true }) or self.job.needed) return error.CodecBadOp;
    }

    fn step(self: *Stream, fed: *const codec_abi.EventFed) !bool {
        const done = try self.job.step(fed);
        const fed_end = fed.offset + fed.bytes.len;
        self.high = @max(self.high, fed_end);
        var next = fed_end;
        while (try self.job.next()) |record| switch (record) {
            .need => |offset| {
                if (offset < self.event_start or offset > fed_end) return error.CodecBadOp;
                if (offset <= fed.offset) {
                    if (self.again) |previous| if (offset <= previous) return error.CodecBadOp;
                    self.again = offset;
                }
                next = offset;
            },
            else => {
                switch (record) {
                    .raw => |raw| try self.within(raw.start, raw.length),
                    .string => |text| try self.within(text.start, text.length),
                    .report => |range| try self.within(range.start, range.length),
                    else => {},
                }
                try self.grammar.take(record);
            },
        };
        self.fed = next;
        if (done) try self.grammar.drained();
        return done;
    }

    /// The `length` bytes at `start` are in the open event and were fed.
    fn within(self: *const Stream, start: u64, length: u64) error{CodecBadOp}!void {
        if (start < self.event_start or start > self.high or length > self.high - start) return error.CodecBadOp;
    }
};

/// Where the bytes of one span are, as they are given: each piece follows
/// the one before it.
const Run = struct {
    open: bool,
    start: u64,
    length: u64,

    /// Take the `length` bytes at `start`, which the Host bounded to the
    /// open event; true when they open the run.
    fn extend(self: *Run, start: u64, length: u64) error{CodecBadOp}!bool {
        if (!self.open) {
            self.* = .{ .open = true, .start = start, .length = length };
            return true;
        }
        if (start != self.start + self.length) return error.CodecBadOp;
        self.length += length;
        return false;
    }
};

/// Bytes of one span, hashed as they are given.
const Spanned = struct {
    run: Run,
    hash: Sha256 = undefined,

    fn extend(self: *Spanned, window: *Window, start: u64, length: u64) !void {
        if (try self.run.extend(start, length)) self.hash = protocol.contentHasher();
        try hashRange(window, start, length, &self.hash);
    }
};

/// Hash the `length` bytes at `start`, which lie in the event data.
fn hashRange(window: *Window, start: u64, length: u64, hash: *Sha256) !void {
    const end = start + length;
    var offset = start;
    while (offset < end) {
        const bytes = try window.bytesAt(offset, end);
        hash.update(bytes);
        offset += bytes.len;
    }
}

/// A sum of lengths a codec names: one that cannot be held is its fault.
fn sum(a: u64, b: u64) error{CodecBadOp}!u64 {
    return std.math.add(u64, a, b) catch error.CodecBadOp;
}

const Sha256 = std.crypto.hash.sha2.Sha256;

/// One provider bag: its members' raw bytes joined by commas, `m1,m2,...`,
/// hashed as they are given.
const Bag = struct {
    scope: output_format.BagScope,
    hash: Sha256,
    length: u64,
    members: u64,

    fn reset(self: *Bag, scope: output_format.BagScope) void {
        self.* = .{ .scope = scope, .hash = protocol.contentHasher(), .length = 0, .members = 0 };
    }

    fn separate(self: *Bag) !void {
        if (self.members == 0) return;
        self.hash.update(",");
        self.length = try sum(self.length, 1);
    }

    /// Records the trailer, even for an empty bag: every item and part has
    /// one, so a missing bag is damage rather than an absence.
    fn close(self: *Bag, metadata: *output_format.OutputMetadataWriter, ordinal: u64, kind: output_format.OutputItemKind) !void {
        try metadata.append(.{ .tag = .extras, .kind = kind, .ordinal = ordinal, .start = 0, .length = 0, .decoded_length = self.length, .content_digest = self.hash.finalResult(), .scope = self.scope });
    }
};

/// A decoded string the metadata addresses by its encoded contents.
const Encoded = struct { start: u64, length: u64, decoded_length: u64, digest: [32]u8 };

/// The JSON string being given, decoded and hashed as it arrives.
const Text = struct {
    open: bool,
    field: codec_abi.Field,
    start: u64,
    length: u64,
    decoder: json.StringDecoder,
    hash: Sha256,
    decoded_length: u64,
    non_whitespace: bool,
    /// The first bytes of an identity the evidence keeps.
    kept: protocol.Bounded(max_evidence_bytes),
    /// Whether the message's answer hash also takes these bytes.
    answer: bool,
};

/// What the Host keeps of the stream between the codec's records.
const Grammar = struct {
    metadata: *output_format.OutputMetadataWriter,
    window: *Window,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    provider_failure: *ProviderFailure,
    /// Where the open event's data begins in the capture.
    raw_start: u64,
    item_count: u64,
    call_count: u64,
    compaction_count: u64,
    answer: AnswerSelection,
    evidence: Evidence,
    completed: bool,
    /// The first failure of the Host's own work on spans, reported once the
    /// codec's verdict on what holds them is acceptance: the codec's
    /// verdict, given first, wins.
    latched: ?anyerror,
    added: ?struct { kind: output_format.OutputItemKind, id_digest: [32]u8 },
    added_id: ?[32]u8,
    item: Item,
    text: Text,
    terminal: Terminal,
    usage: Spanned,
    refusal: ?transport_policy.Refusal,
    report: std.EnumArray(codec_abi.ReportField, ?codec_abi.ReportRange),

    const Item = struct {
        open: bool,
        kind: output_format.OutputItemKind,
        ordinal: u64,
        content: Spanned,
        id_digest: ?[32]u8,
        bag: Bag,
        part_bag: Bag,
        member: Run,
        part_open: bool,
        part: Part,
        /// A call's name, call id and arguments, each given once.
        calls: [3]Encoded,
        calls_given: std.bit_set.IntegerBitSet(3),
        text_hash: Sha256,
        text_length: u64,
        non_whitespace: bool,
    };

    /// The open part. Its record comes before its bag's members, and its
    /// text may follow them, so the record is written once the first member
    /// or the part's end comes, and a record written before its text is
    /// completed at the part's end.
    const Part = struct {
        array: output_format.PartArray,
        kind: output_format.PartKind,
        has_text: bool,
        text: Encoded = undefined,
        /// Where the record was written, if it was.
        written: ?u64,
        /// The record was written without its text.
        held: bool,
    };

    const Terminal = struct {
        index: u64,
        reader: ?output_format.OutputMetadataReader,
        content: Spanned,
        id_digest: ?[32]u8,
    };

    fn begin(self: *Grammar, metadata: *output_format.OutputMetadataWriter, window: *Window, operation: output_format.ModelOperationKind, rejection: *Rejection, provider_failure: *ProviderFailure) void {
        self.metadata = metadata;
        self.window = window;
        self.operation = operation;
        self.rejection = rejection;
        self.provider_failure = provider_failure;
        self.raw_start = 0;
        self.item_count = 0;
        self.call_count = 0;
        self.compaction_count = 0;
        self.answer = .{ .digest = protocol.contentDigest("") };
        self.evidence.response_id.len = 0;
        self.evidence.served_model.len = 0;
        self.completed = false;
        self.latched = null;
        self.added = null;
        self.added_id = null;
        self.item.open = false;
        self.text.open = false;
        self.terminal.index = 0;
        self.terminal.reader = null;
        self.terminal.content.run.open = false;
        self.terminal.id_digest = null;
        self.usage.run.open = false;
        self.refusal = null;
        self.report = .initFill(null);
    }

    fn latch(self: *Grammar, err: anyerror) void {
        if (self.latched == null) self.latched = err;
    }

    fn take(self: *Grammar, record: codec_abi.Record) !void {
        // Output after completion is read only to be refused.
        if (self.completed) switch (record) {
            .raw, .string, .item, .member_end, .part, .part_end, .terminal, .terminal_failed => return,
            .item_end, .added, .completed, .terminal_end, .usage, .finish => return error.CodecBadOp,
            .at, .failed, .refusal, .report, .need => {},
        };
        // After its first failure the Host writes nothing more of the
        // spans; the failure stands unless the codec's verdict comes first.
        if (self.latched != null) switch (record) {
            .raw, .string, .member_end, .part, .part_end, .terminal => return,
            else => {},
        };
        switch (record) {
            .raw => |span| self.takeRaw(span.span, span.start, span.length) catch |err| self.latch(err),
            .string => |text| self.takeString(text.field, text.last, text.start, text.length) catch |err| self.latch(err),
            .item => |kind| self.openItem(outputKind(kind)),
            .member_end => self.memberEnd() catch |err| self.latch(err),
            .part => |part| self.openPart(@fromBackingInt(@intCast(@backingInt(part.array))), @fromBackingInt(@intCast(@backingInt(part.kind)))) catch |err| self.latch(err),
            .part_end => self.closePart() catch |err| self.latch(err),
            .item_end => |end| try self.closeItem(end.answer_phase, end.phase, end.omit_reasoning_text),
            .added => |kind| {
                if (self.latched) |err| return err;
                self.added = .{ .kind = outputKind(kind), .id_digest = self.added_id orelse return error.CodecBadOp };
                self.added_id = null;
            },
            .completed => try self.gate(),
            .terminal => |kind| self.terminalItem(outputKind(kind)) catch |err| self.latch(err),
            .terminal_failed => |reason| self.latch(reasonError(reason)),
            .terminal_end => try self.terminalEnd(),
            .usage => |counts| try self.recordUsage(counts),
            .finish => {
                if (self.latched) |err| return err;
                try self.metadata.sealForRead();
                self.completed = true;
            },
            .at => |at| self.rejection.* = .{ .stage = at.stage, .byte_offset = self.raw_start, .output_index = at.output_index },
            .failed => |reason| return self.fail(reason),
            .refusal => |code| self.refusal = transport_policy.Refusal.ofProviderCode(code),
            .report => |range| self.report.set(range.field, range),
            .need => unreachable,
        }
    }

    /// The codec is done with the stream.
    fn drained(self: *const Grammar) !void {
        if (!self.completed) return error.CodecBadOp;
        if (self.latched) |err| return err;
    }

    fn outputKind(kind: codec_abi.OutputKind) output_format.OutputItemKind {
        return @fromBackingInt(@intCast(@backingInt(kind)));
    }

    fn takeRaw(self: *Grammar, span: codec_abi.Span, start: u64, length: u64) !void {
        switch (span) {
            .item => {
                if (!self.item.open) return error.CodecBadOp;
                try self.item.content.extend(self.window, start, length);
            },
            .member => {
                const item = &self.item;
                if (!item.open) return error.CodecBadOp;
                const bag = if (item.part_open) &item.part_bag else &item.bag;
                if (try item.member.extend(start, length)) {
                    if (item.part_open) try self.writePart();
                    try bag.separate();
                }
                try hashRange(self.window, start, length, &bag.hash);
                bag.length = try sum(bag.length, length);
            },
            .terminal => try self.terminal.content.extend(self.window, start, length),
            .usage => try self.usage.extend(self.window, start, length),
        }
    }

    fn takeString(self: *Grammar, field: codec_abi.Field, last: bool, start: u64, length: u64) !void {
        const text = &self.text;
        if (!text.open) {
            text.open = true;
            text.field = field;
            text.start = start;
            text.length = 0;
            text.decoder.reset();
            text.hash = protocol.contentHasher();
            text.decoded_length = 0;
            text.non_whitespace = false;
            text.kept.len = 0;
            text.answer = field == .part_text and self.item.open and self.item.kind == .message;
        } else if (field != text.field or start != text.start + text.length) return error.CodecBadOp;
        const end = start + length;
        var offset = start;
        while (offset < end) {
            const bytes = try self.window.bytesAt(offset, end);
            offset += bytes.len;
            // The codec's reader judged these bytes as this decoder does.
            text.decoder.pushSlice(bytes, self) catch return error.CodecBadOp;
        }
        text.length += length;
        if (!last) return;
        text.open = false;
        if (text.decoder.pending()) return error.CodecBadOp;
        const encoded: Encoded = .{ .start = text.start, .length = text.length, .decoded_length = text.decoded_length, .digest = text.hash.finalResult() };
        const item = &self.item;
        switch (field) {
            .item_id => item.id_digest = encoded.digest,
            .added_id => self.added_id = encoded.digest,
            .terminal_id => self.terminal.id_digest = encoded.digest,
            .part_text => {
                if (!item.open or !item.part_open) return error.CodecBadOp;
                const part = &item.part;
                // A part has one text, which a record written whole holds.
                if (part.has_text or (part.written != null and !part.held)) return error.CodecBadOp;
                part.has_text = true;
                part.text = encoded;
                if (text.answer) {
                    item.text_length = try sum(item.text_length, encoded.decoded_length);
                    item.non_whitespace = item.non_whitespace or text.non_whitespace;
                }
            },
            .call_name, .call_id, .call_arguments => {
                if (!item.open) return error.CodecBadOp;
                const index = @backingInt(field) - @backingInt(codec_abi.Field.call_name);
                item.calls[index] = encoded;
                item.calls_given.set(index);
            },
            .response_id => try self.evidence.response_id.set(text.kept.slice()),
            .served_model => try self.evidence.served_model.set(text.kept.slice()),
        }
    }

    /// One decoded scalar of the open string, or a run of plain ASCII.
    pub fn append(self: *Grammar, bytes: []const u8, scalar: ?u21) void {
        const text = &self.text;
        text.hash.update(bytes);
        if (text.answer) self.item.text_hash.update(bytes);
        text.decoded_length += bytes.len;
        if (!text.non_whitespace) {
            if (scalar) |value| {
                text.non_whitespace = !isWhitespace(value);
            } else for (bytes) |byte| if (!isWhitespace(byte)) {
                text.non_whitespace = true;
                break;
            };
        }
        if (text.field == .response_id or text.field == .served_model) {
            // An identity longer than any the codec accepts fails to set.
            const kept = @min(bytes.len, text.kept.bytes.len - text.kept.len);
            @memcpy(text.kept.bytes[text.kept.len..][0..kept], bytes[0..kept]);
            text.kept.len += kept;
        }
    }

    fn openItem(self: *Grammar, kind: output_format.OutputItemKind) void {
        const item = &self.item;
        item.open = true;
        item.kind = kind;
        item.ordinal = self.item_count;
        item.content.run.open = false;
        item.id_digest = null;
        item.bag.reset(.item);
        item.member.open = false;
        item.part_open = false;
        item.calls_given = .empty;
        item.text_hash = protocol.contentHasher();
        item.text_length = 0;
        item.non_whitespace = false;
    }

    fn memberEnd(self: *Grammar) !void {
        const item = &self.item;
        if (!item.open or !item.member.open) return error.CodecBadOp;
        item.member.open = false;
        const bag = if (item.part_open) &item.part_bag else &item.bag;
        bag.members += 1;
        try self.metadata.append(.{ .tag = .member, .kind = item.kind, .ordinal = item.ordinal, .start = item.member.start, .length = item.member.length, .scope = bag.scope });
    }

    fn openPart(self: *Grammar, array: output_format.PartArray, kind: output_format.PartKind) !void {
        const item = &self.item;
        // Only an item the grammar rejects holds an opaque block.
        if (!item.open or item.part_open or item.member.open or array == .none or kind == .opaque_block) return error.CodecBadOp;
        item.part_open = true;
        item.part = .{ .array = array, .kind = kind, .has_text = false, .written = null, .held = false };
        item.part_bag.reset(.part);
    }

    /// The open part's record, once its text has come.
    fn partRecord(self: *const Grammar) output_format.OutputMetadataRecord {
        const item = &self.item;
        const part = &item.part;
        std.debug.assert(part.has_text);
        return .{
            .tag = .part,
            .kind = item.kind,
            .ordinal = item.ordinal,
            .start = part.text.start,
            .length = part.text.length,
            .decoded_length = part.text.decoded_length,
            .content_digest = part.text.digest,
            .part_kind = part.kind,
            .part_array = part.array,
        };
    }

    /// The part's first member comes: its record goes first.
    fn writePart(self: *Grammar) !void {
        const part = &self.item.part;
        if (part.written != null) return;
        if (part.has_text) {
            part.written = self.metadata.records;
            try self.metadata.append(self.partRecord());
        } else {
            part.written = try self.metadata.hold();
            part.held = true;
        }
    }

    fn closePart(self: *Grammar) !void {
        const item = &self.item;
        if (!item.open or !item.part_open or item.member.open or !item.part.has_text) return error.CodecBadOp;
        const part = &item.part;
        if (part.written) |index| {
            if (part.held) try self.metadata.fill(index, self.partRecord());
        } else try self.metadata.append(self.partRecord());
        try item.part_bag.close(self.metadata, item.ordinal, item.kind);
        item.part_open = false;
    }

    /// The codec accepted the open item: the Host's own rules on it, in the
    /// order acceptance has always applied them, and then its record.
    fn closeItem(self: *Grammar, answer_phase: codec_abi.Phase, phase: codec_abi.Phase, omit_reasoning_text: bool) !void {
        const item = &self.item;
        if (!item.open) return error.CodecBadOp;
        item.open = false;
        if (self.latched) |err| return err;
        if (!item.content.run.open or item.member.open or item.part_open) return error.CodecBadOp;
        if (item.kind != .message and phase != .unphased) return error.CodecBadOp;
        const id_digest = item.id_digest orelse return error.CodecBadOp;
        const text_digest = item.text_hash.finalResult();
        try item.bag.close(self.metadata, item.ordinal, item.kind);
        switch (item.kind) {
            .function_call => {
                if (item.calls_given.count() != item.calls.len) return error.CodecBadOp;
                const tags = [_]output_format.OutputRecordTag{ .name, .call_id, .arguments };
                for (tags, &item.calls) |tag, *field| {
                    try self.metadata.append(.{ .tag = tag, .kind = .function_call, .ordinal = item.ordinal, .start = field.start, .length = field.length, .decoded_length = field.decoded_length, .content_digest = field.digest });
                }
            },
            .message => try self.metadata.append(.{ .tag = .text, .kind = .message, .ordinal = item.ordinal, .start = 0, .length = 0, .decoded_length = item.text_length, .content_digest = text_digest }),
            .reasoning, .compaction => {},
        }
        if (self.added) |added| if (added.kind != item.kind or !std.mem.eql(u8, &added.id_digest, &id_digest)) return error.ContradictoryProviderOutput;
        self.added = null;
        switch (item.kind) {
            .compaction => {
                self.compaction_count += 1;
                if (self.compaction_count > 1) return error.UnsupportedProviderOutput;
            },
            .message => self.answer.accept(&.{ .ordinal = item.ordinal, .phase = answer_phase, .length = item.text_length, .digest = text_digest, .non_whitespace = item.non_whitespace }),
            .function_call => self.call_count += 1,
            .reasoning => {},
        }
        try self.metadata.append(.{
            .tag = .item,
            .kind = item.kind,
            .ordinal = item.ordinal,
            .start = item.content.run.start,
            .length = item.content.run.length,
            .id_digest = id_digest,
            .content_digest = item.content.hash.finalResult(),
            .omit_reasoning_text = omit_reasoning_text,
            .phase = @fromBackingInt(@intCast(@backingInt(phase))),
        });
        self.item_count += 1;
    }

    /// Each unmet completion requirement keeps its own reason so a saved
    /// rejection says which one failed; all share the malformed code.
    fn gate(self: *const Grammar) !void {
        if (self.item_count == 0) return error.MissingProviderOutputItems;
        if (self.answer.finals > 1) return error.MultipleFinalAnswers;
        if (self.operation == .assistant_response and self.answer.ordinal == null and self.call_count == 0) return error.MissingAssistantAnswer;
        if (self.operation == .compaction and self.compaction_count != 1) return error.MissingCompactionItem;
    }

    /// One item of the completed response's output list must be the
    /// streamed item at its index, byte for byte.
    fn terminalItem(self: *Grammar, kind: output_format.OutputItemKind) !void {
        const terminal = &self.terminal;
        defer {
            terminal.content.run.open = false;
            terminal.id_digest = null;
        }
        if (self.latched != null) return;
        if (!terminal.content.run.open) return error.CodecBadOp;
        const id_digest = terminal.id_digest orelse return error.CodecBadOp;
        if (terminal.reader == null) terminal.reader = try output_format.OutputMetadataReader.init(self.metadata.io, self.metadata.file, self.item_count);
        const record = try terminal.reader.?.nextItem() orelse return error.ContradictoryProviderOutput;
        const content_digest = terminal.content.hash.finalResult();
        if (record.ordinal != terminal.index or record.kind != kind or
            !std.mem.eql(u8, &record.id_digest, &id_digest) or
            !std.mem.eql(u8, &record.content_digest, &content_digest)) return error.ContradictoryProviderOutput;
        terminal.index += 1;
    }

    fn terminalEnd(self: *Grammar) !void {
        if (self.latched) |err| return err;
        const terminal = &self.terminal;
        // The managed stream can omit the repeated items from
        // response.completed. Any nonempty terminal list must still match
        // every streamed done item.
        if (terminal.index != 0 and (terminal.index != self.item_count or try terminal.reader.?.nextItem() != null))
            return error.ContradictoryProviderOutput;
    }

    fn recordUsage(self: *Grammar, counts: ?codec_abi.Usage) !void {
        if (self.latched) |err| return err;
        if (!self.usage.run.open) return error.CodecBadOp;
        try self.metadata.append(.{
            .tag = .usage,
            .start = self.usage.run.start,
            .length = self.usage.run.length,
            .content_digest = self.usage.hash.finalResult(),
            .usage = if (counts) |usage| .{ .uncached = usage.uncached, .cache_read = usage.cache_read, .cache_write = usage.cache_write, .output = usage.output } else null,
        });
    }

    /// The codec's verdict on the event, with the provider's report when it
    /// gave one. A reported failure is permanent when its code is a refusal
    /// the Host knows.
    fn fail(self: *Grammar, reason: codec_abi.Reason) anyerror {
        if (self.report.get(.code) != null or self.report.get(.message) != null) self.writeProviderReport();
        if (reason != .reported_provider_failure) return reasonError(reason);
        self.provider_failure.refusal = self.refusal;
        return if (self.refusal != null) error.PermanentProviderFailure else error.TemporaryProviderFailure;
    }

    /// Never inlined: the report's two parts stay in this rare frame.
    noinline fn writeProviderReport(self: *Grammar) void {
        var parts: [2]ReportPart = @splat(.{ .text = .{ .len = 0 }, .shortened = false });
        for (&parts, [_]codec_abi.ReportField{ .code, .message }) |*part, field| if (self.report.get(field)) |range| {
            readPart(self.window, range.start, range.length, range.escape, part) catch {
                part.text.len = 0;
                part.shortened = false;
            };
        };
        writeReport(&self.provider_failure.report, &parts[0], &parts[1]);
    }
};

/// The error a reason names.
fn reasonError(reason: codec_abi.Reason) anyerror {
    @setEvalBranchQuota(100_000);
    return switch (reason) {
        inline else => |known| @field(anyerror, codec_abi.reasonName(known)),
    };
}

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
}

const pinned_interpreter = codecs.interpreter(.@"openai-responses/1");

var testing_interpret: Interpret = undefined;
var testing_events: EventData = undefined;

/// The pinned interpreter, counting the bytes it is fed.
const CountingInterpreter = struct {
    var bytes: u64 = 0;
    var longest: usize = 0;
    const interpreter: codecs.Interpreter = .{ .init = pinned_interpreter.init, .step = step };

    fn step(state: *codecs.InterpreterState, fed: *const codec_abi.EventFed, ops: *codec_abi.Ops) codec_abi.Status {
        bytes += fed.bytes.len;
        longest = @max(longest, fed.bytes.len);
        return pinned_interpreter.step(state, fed, ops);
    }
};

/// Interpret `sse` through `interpreter` into fresh event data and
/// `metadata`, which the caller closes with `testing_events`.
fn interpretForTesting(tmp: *std.testing.TmpDir, interpreter: *const codecs.Interpreter, sse: []const u8, cut: Feed, used: *std.atomic.Value(u64), metadata: *output_format.OutputMetadataWriter, validated: *Validated) !void {
    const io = std.testing.io;
    const source = try tmp.dir.createFile(io, "capture", .{ .read = true, .truncate = true });
    defer source.close(io);
    try source.writeStreamingAll(io, sse);
    const budget: protocol.ScratchBudget = .{ .used = used, .limit = std.math.maxInt(u64) };
    testing_events.window.io = io;
    testing_events.window.file = try tmp.dir.createFile(io, "events", .{ .read = true, .truncate = true });
    testing_events.window.start = 0;
    testing_events.window.length = 0;
    testing_events.budget = budget;
    testing_events.length = 0;
    testing_events.charged = 0;
    metadata.* = .{ .io = io, .file = try tmp.dir.createFile(io, "metadata", .{ .read = true, .truncate = true }), .budget = budget };
    CountingInterpreter.bytes = 0;
    CountingInterpreter.longest = 0;
    var rejection: Rejection = .{};
    var failure: ProviderFailure = undefined;
    try interpret(&testing_interpret, interpreter, io, source, sse.len, metadata, &testing_events, .assistant_response, &rejection, &failure, cut, validated);
}

const completed_event = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}\n\n";

test "an event whose type follows its item is judged after a seek" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const head = "{\"output_index\":0,\"item\":";
    const done = head ++ "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]},\"type\":\"response.output_item.done\"}";
    var used: std.atomic.Value(u64) = .init(0);
    var metadata: output_format.OutputMetadataWriter = undefined;
    var validated: Validated = undefined;
    defer testing_events.window.file.close(std.testing.io);
    defer metadata.file.close(std.testing.io);
    try interpretForTesting(&tmp, &CountingInterpreter.interpreter, "data: " ++ done ++ "\n\n" ++ completed_event, .{}, &used, &metadata, &validated);
    try std.testing.expectEqual(@as(u64, 1), validated.item_count);
    try std.testing.expectEqual(@as(?u64, 0), validated.answer_item_ordinal);
    try std.testing.expectEqual(@as(u64, 2), validated.answer_length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &validated.answer_digest);
    // The done event is read once to find its type and once to judge it.
    try std.testing.expectEqual(validated.source_length + done.len, CountingInterpreter.bytes);
    var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, 1);
    const item = (try reader.nextItem()).?;
    try std.testing.expectEqual(output_format.OutputItemKind.message, item.kind);
    try std.testing.expectEqual(@as(u64, head.len), item.start);
}

test "an event, item and block whose types follow what they decide are read twice and the block once more" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const block = "{\"text\":\"ok\",\"type\":\"output_text\"}";
    const done = "{\"output_index\":0,\"item\":{\"content\":[" ++ block ++ "],\"id\":\"m\",\"role\":\"assistant\",\"type\":\"message\"},\"type\":\"response.output_item.done\"}";
    var used: std.atomic.Value(u64) = .init(0);
    var metadata: output_format.OutputMetadataWriter = undefined;
    var validated: Validated = undefined;
    defer testing_events.window.file.close(std.testing.io);
    defer metadata.file.close(std.testing.io);
    try interpretForTesting(&tmp, &CountingInterpreter.interpreter, "data: " ++ done ++ "\n\n" ++ completed_event, .{}, &used, &metadata, &validated);
    try std.testing.expectEqual(@as(u64, 1), validated.item_count);
    try std.testing.expectEqual(@as(u64, 2), validated.answer_length);
    // The first pass finds the event's type and the item's; the second
    // reads the block again once its type follows its text. The window in
    // which the block ends runs on to the event's end, so those bytes are
    // fed once more after the block.
    const tail = done.len - (std.mem.indexOf(u8, done, block).? + block.len);
    try std.testing.expectEqual(validated.source_length + done.len + block.len + tail, CountingInterpreter.bytes);
}

test "a part whose text follows a bag member is completed in place and counted once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"annotations\":[],\"text\":\"ok\"}]}}";
    var used: std.atomic.Value(u64) = .init(0);
    var metadata: output_format.OutputMetadataWriter = undefined;
    var validated: Validated = undefined;
    defer testing_events.window.file.close(std.testing.io);
    defer metadata.file.close(std.testing.io);
    try interpretForTesting(&tmp, pinned_interpreter, "data: " ++ done ++ "\n\n" ++ completed_event, .{}, &used, &metadata, &validated);
    try std.testing.expectEqual(@as(u64, 2), validated.answer_length);
    try std.testing.expectEqual(@as(u64, 2), metadata.decoded_length);
    var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, 1);
    const part = while (try reader.next()) |record| {
        if (record.tag == .part) break record;
    } else return error.TestExpectedPart;
    try std.testing.expectEqual(output_format.PartKind.output_text, part.part_kind);
    try std.testing.expectEqual(@as(u64, 2), part.decoded_length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &part.content_digest);
    try std.testing.expectEqual(output_format.OutputRecordTag.member, (try reader.next()).?.tag);
}

test "a 4 MiB reasoning item interprets in bounded windows with no text byte read twice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const text = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    const sse = try std.mem.concat(allocator, u8, &.{
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"",
        text,
        "\"}]}}\n\ndata: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}\n\n" ++ completed_event,
    });
    defer allocator.free(sse);
    var used: std.atomic.Value(u64) = .init(0);
    var metadata: output_format.OutputMetadataWriter = undefined;
    var validated: Validated = undefined;
    defer testing_events.window.file.close(std.testing.io);
    defer metadata.file.close(std.testing.io);
    try interpretForTesting(&tmp, &CountingInterpreter.interpreter, sse, .{}, &used, &metadata, &validated);
    try std.testing.expectEqual(@as(u64, 2), validated.item_count);
    try std.testing.expectEqual(validated.source_length, CountingInterpreter.bytes);
    try std.testing.expectEqual(protocol.content_window_bytes, CountingInterpreter.longest);
    var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, 2);
    const part = while (try reader.next()) |record| {
        if (record.tag == .part) break record;
    } else return error.TestExpectedPart;
    try std.testing.expectEqual(output_format.PartKind.summary_text, part.part_kind);
    try std.testing.expectEqual(@as(u64, text.len), part.decoded_length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &part.content_digest);
}

/// The pinned interpreter, except for its answers to the windows that
/// begin at `offset`: it adds `ops` to them, or answers with `ops` alone.
fn FaultyInterpreter(comptime offset: u64, comptime fault: enum { add, replace }, comptime ops: []const u8) type {
    return struct {
        const interpreter: codecs.Interpreter = .{ .init = pinned_interpreter.init, .step = step };

        fn step(state: *codecs.InterpreterState, fed: *const codec_abi.EventFed, out: *codec_abi.Ops) codec_abi.Status {
            const hit = fed.offset == offset and fed.bytes.len != 0;
            if (hit and fault == .replace) {
                @memcpy(out.bytes[0..ops.len], ops);
                out.length = ops.len;
                return .next;
            }
            const status = pinned_interpreter.step(state, fed, out);
            if (hit) {
                @memcpy(out.bytes[out.length..][0..ops.len], ops);
                out.length += ops.len;
            }
            return status;
        }
    };
}

test "a codec naming bytes outside its event or asking to be fed outside it fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}";
    const sse = "data: " ++ done ++ "\n\n" ++ completed_event;
    // Each event is fed in windows of 16 bytes; the second event's data
    // follows the first's in the event data.
    const window = 16;
    const second = done.len;
    const int = struct {
        fn of(value: u64) [8]u8 {
            return std.mem.toBytes(std.mem.nativeToLittle(u64, value));
        }
    }.of;
    const usage_span = [_]u8{ @backingInt(codec_abi.RecordTag.raw), @backingInt(codec_abi.Span.usage) };
    const code_report = [_]u8{ @backingInt(codec_abi.FindingTag.report), @backingInt(codec_abi.ReportField.code), @backingInt(codec_abi.Escape.json_string_v1) };
    const need = [_]u8{@backingInt(codec_abi.RecordTag.need)};
    const cases = .{
        // A span past the bytes fed, one whose end cannot be held, one in
        // the event before, and a report range in the event before.
        FaultyInterpreter(0, .add, &(usage_span ++ int(0) ++ int(window + 1))),
        FaultyInterpreter(0, .add, &(usage_span ++ int(std.math.maxInt(u64)) ++ int(1))),
        FaultyInterpreter(second, .add, &(usage_span ++ int(0) ++ int(1))),
        FaultyInterpreter(second, .add, &(code_report ++ int(0) ++ int(2))),
        // A need past the bytes fed, one before the event, and one that
        // asks for the same window again and again.
        FaultyInterpreter(0, .replace, &(need ++ int(window + 4))),
        FaultyInterpreter(second, .replace, &(need ++ int(second - 1))),
        FaultyInterpreter(0, .replace, &(need ++ int(0))),
    };
    inline for (cases) |Case| {
        var used: std.atomic.Value(u64) = .init(0);
        var metadata: output_format.OutputMetadataWriter = undefined;
        var validated: Validated = undefined;
        defer testing_events.window.file.close(std.testing.io);
        defer metadata.file.close(std.testing.io);
        try std.testing.expectError(error.CodecBadOp, interpretForTesting(&tmp, &Case.interpreter, sse, .{ .most = window }, &used, &metadata, &validated));
    }
    // The pinned interpreter accepts the stream.
    var used: std.atomic.Value(u64) = .init(0);
    var metadata: output_format.OutputMetadataWriter = undefined;
    var validated: Validated = undefined;
    defer testing_events.window.file.close(std.testing.io);
    defer metadata.file.close(std.testing.io);
    try interpretForTesting(&tmp, pinned_interpreter, sse, .{ .most = window }, &used, &metadata, &validated);
    try std.testing.expectEqual(@as(u64, 1), validated.item_count);
}
