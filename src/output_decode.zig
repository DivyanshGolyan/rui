//! The shell around a codec's reading of a sealed response. `classify`
//! gives an HTTP error body, mapped read-only, to the codec's classifier and
//! turns what it names into the error response the execution owner decides
//! on. The shell keeps every status rule, maps provider codes through
//! `transport_policy`'s closed sets, and bounds the report itself.
//! `interpret` frames a response stream's events and gives each event's
//! data whole to the codec's interpreter, then decodes, hashes and records
//! what it names and keeps every rule across items.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const codecs = @import("codecs.zig");
const execution = @import("execution.zig");
const json = @import("codecs/json.zig");
const named_scratch = @import("named_scratch.zig");
const output_format = @import("output_format.zig");
const pages = @import("os/pages.zig");
const protocol = @import("protocol.zig");
const transport_policy = @import("transport_policy.zig");

/// One response's decoding, in the execution Workspace; the Host decodes
/// one response at a time.
pub const Decode = struct {
    classify: codecs.ClassifyScratch,
    found: codec_abi.ErrorBody,
    code: ReportPart,
    message: ReportPart,
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
/// `.unreadable`. Never inlined: the codec's classifier, which inlines here,
/// stays out of the engine's frames.
pub noinline fn classify(decode: *Decode, codec: protocol.Codec, io: std.Io, body: std.Io.File, length: u64, status: u16, failure: *ProviderFailure) execution.ErrorResponse {
    failure.clear();
    if (status < 400 or status >= 600) return .ordinary;
    // The capture is unlinked and its only writer closed at seal, so no Rui
    // code can truncate it after the length check.
    const bytes = pages.mapReadOnly(io, body, length) catch |err| return .{ .unreadable = switch (err) {
        error.FileShorter => error.ShortSealedRead,
        else => err,
    } };
    defer pages.unmapReadOnly(bytes);
    const found = &decode.found;
    codecs.classify(codec, &decode.classify, bytes, found);
    for ([_]*ReportPart{ &decode.code, &decode.message }, [_]?codec_abi.ReportRange{ found.report.code, found.report.message }) |part, report| {
        part.text.len = 0;
        part.shortened = false;
        if (report) |range| readPart(bytes[@intCast(range.start)..][0..@intCast(range.length)], range.escape, part);
    }
    writeReport(&failure.report, &decode.code, &decode.message);
    const code = if (found.code) |*code| code.slice() else null;
    failure.refusal = if (code) |text| .ofProviderCode(text) else null;
    if (status == 429) if (code) |text| if (transport_policy.Quota.ofProviderCode(text)) |known| {
        return .{ .quota = .{ .code = known, .resets_at = found.resets_at } };
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

    /// Writes `bytes` without keeping them in the window, for a reader
    /// that reads them through a map.
    pub fn append(self: *EventData, bytes: []const u8) !void {
        if (!self.budget.allocate(bytes.len)) return error.EventDataScratchExhausted;
        // A partial write remains charged until disposal, just like capture.
        self.charged += bytes.len;
        self.window.file.writeStreamingAll(self.window.io, bytes) catch return error.EventDataWriteFailed;
        self.length += bytes.len;
    }

    /// Writes `bytes` and keeps them in the window, so the event they
    /// complete parses from memory.
    pub fn appendRemembered(self: *EventData, bytes: []const u8) !void {
        const position = self.length;
        try self.append(bytes);
        self.window.remember(position, bytes);
    }

    pub fn copy(self: *EventData, source: *Window, start: u64, length: u64) !void {
        // Appending moves this window, so it cannot also be the source.
        std.debug.assert(source != &self.window);
        var offset = start;
        const end = try std.math.add(u64, start, length);
        while (offset < end) {
            const bytes = try source.bytesAt(offset, end);
            try self.appendRemembered(bytes);
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

/// One response's interpretation, in its caller's storage: the codec's
/// scratch and what the Host keeps of the stream.
pub const Interpret = struct {
    scratch: codecs.InterpretScratch,
    grammar: Grammar,
};

/// The most event data one response's map reaches: the Host's scratch
/// ceiling (`server_host.scratch_limit_bytes`), which no request budget
/// exceeds. Mapping it reserves address space only.
pub const max_event_data_bytes: u64 = 8 * 1024 * 1024 * 1024;

/// Interpret the sealed SSE capture, the first `source_length` bytes of
/// `source_file`, with `codec`. The Host frames the events: each event's
/// data is written whole to `event_data`, then given to the codec as a
/// slice of the event data's read-only map, so that, as provider_output has
/// always judged, an event's data is charged to the scratch budget before
/// anything its judgement writes. The codec judges the grammar and names
/// ranges; the Host decodes and hashes them, writes `metadata` from them,
/// and keeps every rule that compares items with each other, the answer
/// selection and the completion gate. A failure leaves `rejection` at its
/// coordinates and `provider_failure` with what a provider error event
/// said.
pub fn interpret(
    storage: *Interpret,
    codec: protocol.Codec,
    io: std.Io,
    source_file: std.Io.File,
    source_length: u64,
    metadata: *output_format.OutputMetadataWriter,
    event_data: *EventData,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    provider_failure: *ProviderFailure,
    validated: *Validated,
) !void {
    provider_failure.clear();
    rejection.* = .{};
    const capture = pages.mapReadOnly(io, source_file, source_length) catch |err| return switch (err) {
        error.FileShorter => error.ShortSealedRead,
        else => err,
    };
    defer pages.unmapReadOnly(capture);
    // A write to the event data shows through a map made before it.
    const events = try pages.mapReadOnlyAhead(event_data.window.file, @min(event_data.budget.limit, max_event_data_bytes));
    defer pages.unmapReadOnly(events);
    const grammar = &storage.grammar;
    grammar.begin(codec, metadata, operation, rejection, provider_failure);
    var stream = codecs.begin(codec, switch (operation) {
        .assistant_response => .assistant_response,
        .compaction => .compaction,
    });
    var position: usize = if (std.mem.startsWith(u8, capture, "\xef\xbb\xbf")) 3 else 0;
    // Where the open event's data begins in `event_data`, and its first
    // byte in the capture.
    var data: ?u64 = null;
    var raw_start: u64 = 0;
    while (position < capture.len) {
        rejection.* = .{ .byte_offset = position };
        // SSE has three line endings.
        const line_start = position;
        const line_end = std.mem.indexOfAnyPos(u8, capture, position, "\r\n") orelse capture.len;
        position = line_end;
        if (position < capture.len) {
            position += 1;
            if (capture[line_end] == '\r' and position < capture.len and capture[position] == '\n') position += 1;
        }
        const line = capture[line_start..line_end];
        if (line.len == 0) {
            if (data) |start| {
                if (event_data.length == start) return error.EmptySseData;
                if (event_data.length > events.len) return error.EventDataScratchExhausted;
                try grammar.event(&stream, &storage.scratch, events[@intCast(start)..@intCast(event_data.length)], start, raw_start);
                data = null;
            }
            continue;
        }
        if (std.mem.eql(u8, line, "data") or std.mem.startsWith(u8, line, "data:")) {
            var skip: usize = @min(line.len, "data:".len);
            if (line.len > skip and line[skip] == ' ') skip += 1;
            if (data == null) {
                data = event_data.length;
                raw_start = line_start + skip;
            } else try event_data.append("\n");
            if (line.len > skip) try event_data.append(line[skip..]);
        }
        // Comments and every other field, including colonless fields, carry
        // no provider output authority. Field names are case-sensitive.
    }
    if (data != null) return error.IncompleteSseEvent;
    if (codecs.finish(&stream)) |reason| return reasonError(reason);
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

const Sha256 = std.crypto.hash.sha2.Sha256;

/// One provider bag: its members' raw bytes joined by commas, `m1,m2,...`,
/// hashed as they are added.
const Bag = struct {
    scope: output_format.BagScope,
    hash: Sha256,
    length: u64,
    members: u64,

    fn reset(self: *Bag, scope: output_format.BagScope) void {
        self.* = .{ .scope = scope, .hash = protocol.contentHasher(), .length = 0, .members = 0 };
    }

    fn add(self: *Bag, metadata: *output_format.OutputMetadataWriter, data: []const u8, base: u64, member: codec_abi.Range, ordinal: u64, kind: output_format.OutputItemKind) !void {
        if (self.members != 0) {
            self.hash.update(",");
            self.length += 1;
        }
        self.hash.update(bytesOf(data, member));
        self.length = try std.math.add(u64, self.length, member.length);
        self.members += 1;
        try metadata.append(.{ .tag = .member, .kind = kind, .ordinal = ordinal, .start = base + member.start, .length = member.length, .scope = self.scope });
    }

    /// Records the trailer, even for an empty bag: every item and part has
    /// one, so a missing bag is damage rather than an absence.
    fn close(self: *Bag, metadata: *output_format.OutputMetadataWriter, ordinal: u64, kind: output_format.OutputItemKind) !void {
        try metadata.append(.{ .tag = .extras, .kind = kind, .ordinal = ordinal, .start = 0, .length = 0, .decoded_length = self.length, .content_digest = self.hash.finalResult(), .scope = self.scope });
    }
};

fn bytesOf(data: []const u8, range: codec_abi.Range) []const u8 {
    return data[@intCast(range.start)..][0..@intCast(range.length)];
}

fn digestOf(data: []const u8, range: codec_abi.Range) [32]u8 {
    var hash = protocol.contentHasher();
    hash.update(bytesOf(data, range));
    return hash.finalResult();
}

/// A JSON string's contents the codec named, decoded: its length, digest
/// and whether it holds anything but whitespace.
const Decoded = struct {
    length: u64,
    digest: [32]u8,
    non_whitespace: bool,

    /// Decode the contents `range` of `data`, its bytes also hashed into
    /// `also` and kept in `kept` when given.
    fn of(data: []const u8, range: codec_abi.Range, also: ?*Sha256, kept: ?*protocol.Bounded(max_evidence_bytes)) Decoded {
        var sink: Sink = .{ .hash = protocol.contentHasher(), .also = also, .kept = kept, .length = 0, .non_whitespace = false };
        if (kept) |bounded| bounded.len = 0;
        var decoder: json.StringDecoder = undefined;
        decoder.reset();
        // The codec's reader judged these bytes as this decoder does.
        decoder.pushSlice(bytesOf(data, range), &sink) catch unreachable;
        std.debug.assert(!decoder.pending());
        return .{ .length = sink.length, .digest = sink.hash.finalResult(), .non_whitespace = sink.non_whitespace };
    }

    const Sink = struct {
        hash: Sha256,
        also: ?*Sha256,
        kept: ?*protocol.Bounded(max_evidence_bytes),
        length: u64,
        non_whitespace: bool,

        /// One decoded scalar, or a run of plain ASCII.
        pub fn append(self: *Sink, bytes: []const u8, scalar: ?u21) void {
            self.hash.update(bytes);
            if (self.also) |hash| hash.update(bytes);
            self.length += bytes.len;
            if (!self.non_whitespace) {
                if (scalar) |value| {
                    self.non_whitespace = !isWhitespace(value);
                } else for (bytes) |byte| if (!isWhitespace(byte)) {
                    self.non_whitespace = true;
                    break;
                };
            }
            if (self.kept) |bounded| {
                // The codec bounds an identity to the evidence's size.
                @memcpy(bounded.bytes[bounded.len..][0..bytes.len], bytes);
                bounded.len += bytes.len;
            }
        }
    };
};

/// What the Host keeps of the stream between the codec's answers.
const Grammar = struct {
    codec: protocol.Codec,
    metadata: *output_format.OutputMetadataWriter,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    provider_failure: *ProviderFailure,
    item_count: u64,
    call_count: u64,
    compaction_count: u64,
    answer: AnswerSelection,
    evidence: Evidence,
    /// The announced item, until its done event.
    added: ?struct { kind: output_format.OutputItemKind, id_digest: [32]u8 },
    /// Where the current event's data begins in the event data.
    base: u64,
    /// A provider report's two parts.
    code: ReportPart,
    message: ReportPart,

    fn begin(self: *Grammar, codec: protocol.Codec, metadata: *output_format.OutputMetadataWriter, operation: output_format.ModelOperationKind, rejection: *Rejection, provider_failure: *ProviderFailure) void {
        self.codec = codec;
        self.metadata = metadata;
        self.operation = operation;
        self.rejection = rejection;
        self.provider_failure = provider_failure;
        self.item_count = 0;
        self.call_count = 0;
        self.compaction_count = 0;
        self.answer = .{ .digest = protocol.contentDigest("") };
        self.evidence.response_id.len = 0;
        self.evidence.served_model.len = 0;
        self.added = null;
        self.base = 0;
    }

    /// The codec's answer to one event's data, `data`, which begins at
    /// `base` in the event data and whose first byte is at `raw_start` in
    /// the capture.
    fn event(self: *Grammar, stream: *codecs.Stream, scratch: *codecs.InterpretScratch, data: []const u8, base: u64, raw_start: u64) !void {
        self.base = base;
        const answer = codecs.interpretEvent(stream, scratch, data);
        if (answer.at.stage != .stream) self.rejection.* = .{ .stage = answer.at.stage, .byte_offset = raw_start, .output_index = answer.at.output_index };
        switch (answer.what) {
            .other, .done_marker => {},
            .added => |added| self.added = .{ .kind = outputKind(added.kind), .id_digest = Decoded.of(data, added.id, null, null).digest },
            .item => |*item| try self.closeItem(data, item),
            .completed => |*completed| try self.complete(data, completed),
            .failed => |*failed| return self.fail(data, failed),
        }
    }

    /// The codec accepted an item: its parts and bags, then the Host's own
    /// rules on it, in the order acceptance has always applied them, and
    /// then its record.
    fn closeItem(self: *Grammar, data: []const u8, item: *const codec_abi.OutputItem) !void {
        const metadata = self.metadata;
        const kind = outputKind(item.kind);
        const ordinal = self.item_count;
        var bag: Bag = undefined;
        bag.reset(.item);
        var part_bag: Bag = undefined;
        var in_part = false;
        // A message's text: its text parts back to back.
        var text_hash = protocol.contentHasher();
        var text_length: u64 = 0;
        var non_whitespace = false;
        var cursor = item.members;
        while (codecs.nextMember(self.codec, data, &cursor)) |member| switch (member) {
            .bag => |range| try (if (in_part) &part_bag else &bag).add(metadata, data, self.base, range, ordinal, kind),
            .part => |part| {
                const text = Decoded.of(data, part.text, if (kind == .message) &text_hash else null, null);
                if (kind == .message) {
                    text_length = try std.math.add(u64, text_length, text.length);
                    non_whitespace = non_whitespace or text.non_whitespace;
                }
                try metadata.append(.{
                    .tag = .part,
                    .kind = kind,
                    .ordinal = ordinal,
                    .start = self.base + part.text.start,
                    .length = part.text.length,
                    .decoded_length = text.length,
                    .content_digest = text.digest,
                    .part_kind = @fromBackingInt(@backingInt(part.kind)),
                    .part_array = @fromBackingInt(@backingInt(part.array)),
                });
                part_bag.reset(.part);
                in_part = true;
            },
            .part_end => {
                try part_bag.close(metadata, ordinal, kind);
                in_part = false;
            },
            .terminal, .terminal_failed => unreachable,
        };
        try bag.close(metadata, ordinal, kind);
        const text_digest = text_hash.finalResult();
        switch (kind) {
            .function_call => for ([_]output_format.OutputRecordTag{ .name, .call_id, .arguments }, item.call) |tag, range| {
                const field = Decoded.of(data, range, null, null);
                try metadata.append(.{ .tag = tag, .kind = .function_call, .ordinal = ordinal, .start = self.base + range.start, .length = range.length, .decoded_length = field.length, .content_digest = field.digest });
            },
            .message => try metadata.append(.{ .tag = .text, .kind = .message, .ordinal = ordinal, .start = 0, .length = 0, .decoded_length = text_length, .content_digest = text_digest }),
            .reasoning, .compaction => {},
        }
        const id_digest = Decoded.of(data, item.id, null, null).digest;
        if (self.added) |added| if (added.kind != kind or !std.mem.eql(u8, &added.id_digest, &id_digest)) return error.ContradictoryProviderOutput;
        self.added = null;
        switch (kind) {
            .compaction => {
                self.compaction_count += 1;
                if (self.compaction_count > 1) return error.UnsupportedProviderOutput;
            },
            .message => self.answer.accept(&.{ .ordinal = ordinal, .phase = item.answer_phase, .length = text_length, .digest = text_digest, .non_whitespace = non_whitespace }),
            .function_call => self.call_count += 1,
            .reasoning => {},
        }
        try metadata.append(.{
            .tag = .item,
            .kind = kind,
            .ordinal = ordinal,
            .start = self.base + item.whole.start,
            .length = item.whole.length,
            .id_digest = id_digest,
            .content_digest = digestOf(data, item.whole),
            .omit_reasoning_text = item.omit_reasoning_text,
            .phase = @fromBackingInt(@backingInt(item.phase)),
        });
        self.item_count += 1;
    }

    /// The completed response: the Host's gate, then the codec's check of
    /// the response, then the output list against the streamed items, then
    /// usage.
    fn complete(self: *Grammar, data: []const u8, completed: *const codec_abi.Completed) !void {
        // Each unmet completion requirement keeps its own reason so a saved
        // rejection says which one failed; all share the malformed code.
        if (self.item_count == 0) return error.MissingProviderOutputItems;
        if (self.answer.finals > 1) return error.MultipleFinalAnswers;
        if (self.operation == .assistant_response and self.answer.ordinal == null and self.call_count == 0) return error.MissingAssistantAnswer;
        if (self.operation == .compaction and self.compaction_count != 1) return error.MissingCompactionItem;
        if (completed.check) |reason| return reasonError(reason);
        _ = Decoded.of(data, completed.response_id, null, &self.evidence.response_id);
        if (completed.served_model) |model| _ = Decoded.of(data, model, null, &self.evidence.served_model);
        const metadata = self.metadata;
        var reader = try output_format.OutputMetadataReader.init(metadata.io, metadata.file, self.item_count);
        var cursor = completed.output;
        var index: u64 = 0;
        while (codecs.nextMember(self.codec, data, &cursor)) |member| switch (member) {
            // One item of the output list must be the streamed item at its
            // index, byte for byte.
            .terminal => |terminal| {
                const id_digest = Decoded.of(data, terminal.id, null, null).digest;
                const content_digest = digestOf(data, terminal.whole);
                const record = try reader.nextItem() orelse return error.ContradictoryProviderOutput;
                if (record.ordinal != index or record.kind != outputKind(terminal.kind) or
                    !std.mem.eql(u8, &record.id_digest, &id_digest) or
                    !std.mem.eql(u8, &record.content_digest, &content_digest)) return error.ContradictoryProviderOutput;
                index += 1;
            },
            .terminal_failed => |reason| return reasonError(reason),
            .bag, .part, .part_end => unreachable,
        };
        // The managed stream can omit the repeated items from
        // response.completed. Any nonempty terminal list must still match
        // every streamed done item.
        if (index != 0 and (index != self.item_count or try reader.nextItem() != null)) return error.ContradictoryProviderOutput;
        switch (completed.usage) {
            .absent => {},
            .failed => |reason| return reasonError(reason),
            .report => |report| try metadata.append(.{
                .tag = .usage,
                .start = self.base + report.whole.start,
                .length = report.whole.length,
                .content_digest = digestOf(data, report.whole),
                .usage = if (report.counts) |usage| .{ .uncached = usage.uncached, .cache_read = usage.cache_read, .cache_write = usage.cache_write, .output = usage.output } else null,
            }),
        }
        try metadata.sealForRead();
    }

    /// The codec's verdict on the event, with the provider's report when it
    /// gave one. A reported failure is permanent when its code is a refusal
    /// the Host knows.
    fn fail(self: *Grammar, data: []const u8, failed: *const codec_abi.Failed) anyerror {
        if (failed.report.code != null or failed.report.message != null) {
            for ([_]*ReportPart{ &self.code, &self.message }, [_]?codec_abi.ReportRange{ failed.report.code, failed.report.message }) |part, report| {
                part.text.len = 0;
                part.shortened = false;
                if (report) |range| readPart(data[@intCast(range.start)..][0..@intCast(range.length)], range.escape, part);
            }
            writeReport(&self.provider_failure.report, &self.code, &self.message);
        }
        if (failed.reason != .reported_provider_failure) return reasonError(failed.reason);
        self.provider_failure.refusal = if (failed.refusal) |*code| .ofProviderCode(code.slice()) else null;
        return if (self.provider_failure.refusal != null) error.PermanentProviderFailure else error.TemporaryProviderFailure;
    }

    fn outputKind(kind: codec_abi.OutputKind) output_format.OutputItemKind {
        return @fromBackingInt(@backingInt(kind));
    }
};

/// The error a reason names.
fn reasonError(reason: codec_abi.Reason) anyerror {
    @setEvalBranchQuota(100_000);
    return switch (reason) {
        inline else => |known| @field(anyerror, codec_abi.reasonName(known)),
    };
}

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
    try std.testing.expect(body.items.len > 850_000);
    var large: Classified = undefined;
    try classifyForTesting(&tmp, pinned, body.items, body.items.len, 429, &large);
    try std.testing.expectEqual(expected.response, large.response);
    try std.testing.expectEqual(expected.failure.refusal, large.failure.refusal);
    try std.testing.expectEqualStrings(expected.failure.report.slice(), large.failure.report.slice());
}
