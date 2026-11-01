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
    decodeInto(&source, escape, part) catch {
        part.text.len = 0;
        part.shortened = false;
    };
}

fn decodeInto(source: *SliceSource, escape: codec_abi.Escape, part: *ReportPart) !void {
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

// ------------------------------------------------------------- interpret

pub const max_evidence_bytes = 256;

pub const Evidence = struct {
    response_id: protocol.Bounded(max_evidence_bytes),
    served_model: protocol.Bounded(protocol.max_model_bytes),
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

/// One response's decoded event data, in an unlinked scratch file the
/// shell reads through a map. Keep raw capture immutable for diagnostics;
/// metadata addresses these bytes.
pub const EventData = struct {
    io: std.Io,
    file: std.Io.File,
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
        self.* = .{ .io = io, .file = file, .budget = budget };
    }

    /// Appends `bytes`, after a newline when `newline`, in one write.
    pub fn append(self: *EventData, newline: bool, bytes: []const u8) !void {
        const separator: []const u8 = if (newline) "\n" else "";
        const total = separator.len + bytes.len;
        if (!self.budget.allocate(total)) return error.EventDataScratchExhausted;
        // A partial write remains charged until disposal, just like capture.
        self.charged += total;
        var written: usize = 0;
        while (written < total) {
            const header = separator[@min(written, separator.len)..];
            const rest = bytes[written - (separator.len - header.len) ..];
            written += self.file.writeStreaming(self.io, header, &.{rest}, 1) catch return error.EventDataWriteFailed;
        }
        self.length += total;
    }

    pub fn seal(self: *EventData) !void {
        const length = self.file.length(self.io) catch return error.EventDataSealFailed;
        if (length != self.length) return error.EventDataSealFailed;
    }

    pub fn deinit(self: *EventData) void {
        self.file.close(self.io);
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

/// An interpreted response: its accepted output with the model evidence
/// certificate, or the local code and coordinates it was rejected with.
/// It grants no settlement authority.
pub const Interpretation = union(enum) {
    accepted: struct {
        output: Validated,
        model_evidence: protocol.Bounded(775),
    },
    rejected: Rejected,
};

/// Rejections contain only local codes and structural coordinates.
pub const Rejected = struct {
    reason: anyerror,
    code: []const u8,
    location: Rejection,
    kind: execution.FailureKind = .permanent,

    pub fn format(self: Rejected, buffer: *[512]u8) []const u8 {
        return self.location.format(self.reason, buffer);
    }
};

/// Borrowed observations already bounded and UTF-8 validated by transport.
pub const ModelObservations = struct {
    openai: []const u8 = "",
    alternate: []const u8 = "",
};

/// Interpret the sealed SSE capture, the first `source_length` bytes of
/// `source_file`, with `codec`, and fill `out` with its acceptance or
/// rejection. The Host frames the events: each event's data is written
/// whole to `event_data`, then given to the codec as a slice of the event
/// data's read-only map, so an event's data is charged to the scratch
/// budget before anything its judgement writes. The codec judges the
/// grammar and names ranges; the Host decodes and hashes them, writes
/// `metadata` from them, and keeps every rule that compares items with each
/// other, the answer selection and the completion gate. `provider_failure`
/// keeps what a provider error event said. Neither the capture, the
/// metadata nor the event data is closed or transferred. Never inlined: the
/// codec's interpreter, which inlines here, stays out of the engine's
/// frames.
pub noinline fn interpret(
    storage: *Interpret,
    codec: protocol.Codec,
    io: std.Io,
    source_file: std.Io.File,
    source_length: u64,
    metadata: *output_format.OutputMetadataWriter,
    event_data: *EventData,
    operation: output_format.ModelOperationKind,
    models: ModelObservations,
    provider_failure: *ProviderFailure,
    out: *Interpretation,
) void {
    out.* = .{ .accepted = .{
        .output = .{
            .source = event_data.file,
            .source_length = 0,
            .item_count = 0,
            .call_count = 0,
            .answer_item_ordinal = null,
            .answer_length = 0,
            .answer_digest = @splat(0),
            .evidence = .{ .response_id = .{ .len = 0 }, .served_model = .{ .len = 0 } },
        },
        .model_evidence = .{ .len = 0 },
    } };
    const accepted = &out.accepted;
    var rejection: Rejection = .{};
    read(storage, codec, io, source_file, source_length, metadata, event_data, operation, &rejection, provider_failure, &accepted.output) catch |err| {
        out.* = .{
            .rejected = .{
                .reason = err,
                // A refusal saves the code it names, whatever carried it.
                .code = if (provider_failure.refusal) |refusal| refusal.failureCode() else failureCode(err),
                .location = rejection,
                .kind = switch (err) {
                    error.ContextOverflow => .context_overflow,
                    error.TemporaryProviderFailure, error.ProviderConnectionClosed => .temporary,
                    else => .permanent,
                },
            },
        };
        return;
    };
    // Opaque certificate v1: body, OpenAI header, alternate header. Preserve
    // each source independently, including absence and disagreement. Never
    // substitute the requested model for reported evidence.
    const certificate = &accepted.model_evidence;
    certificate.bytes[0] = 1;
    certificate.len = 1;
    for ([_][]const u8{ accepted.output.evidence.served_model.slice(), models.openai, models.alternate }) |value| {
        std.debug.assert(value.len <= protocol.max_model_bytes);
        std.mem.writeInt(u16, certificate.bytes[certificate.len..][0..2], @intCast(value.len), .little);
        certificate.len += 2;
        @memcpy(certificate.bytes[certificate.len..][0..value.len], value);
        certificate.len += value.len;
    }
}

/// Frames the capture's events and gives each to the grammar, then fills
/// `validated`, whose evidence the grammar writes. A failure leaves
/// `rejection` at its coordinates.
fn read(
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
    const capture = pages.mapReadOnly(io, source_file, source_length) catch |err| return switch (err) {
        error.FileShorter => error.ShortSealedRead,
        else => err,
    };
    defer pages.unmapReadOnly(capture);
    // Decoded event data is never longer than the capture it comes from,
    // and a write to it shows through a map made before it.
    const events = pages.mapReadOnlyAhead(event_data.file, source_length) catch return error.EventDataMapFailed;
    defer pages.unmapReadOnly(events);
    const grammar = &storage.grammar;
    grammar.begin(codec, metadata, operation, rejection, provider_failure, &validated.evidence);
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
                try grammar.event(&stream, &storage.scratch, events[@intCast(start)..@intCast(event_data.length)], start, raw_start);
                data = null;
            }
            continue;
        }
        if (std.mem.eql(u8, line, "data") or std.mem.startsWith(u8, line, "data:")) {
            var skip: usize = @min(line.len, "data:".len);
            if (line.len > skip and line[skip] == ' ') skip += 1;
            const continued = data != null;
            if (!continued) {
                data = event_data.length;
                raw_start = line_start + skip;
            }
            if (continued or line.len > skip) try event_data.append(continued, line[skip..]);
        }
        // Comments and every other field, including colonless fields, carry
        // no provider output authority. Field names are case-sensitive.
    }
    if (data != null) return error.IncompleteSseEvent;
    if (codecs.finish(&stream)) |reason| return reasonError(reason);
    try event_data.seal();
    validated.source_length = event_data.length;
    validated.item_count = grammar.item_count;
    validated.call_count = grammar.call_count;
    validated.answer_item_ordinal = grammar.answer.ordinal;
    validated.answer_length = grammar.answer.length;
    validated.answer_digest = grammar.answer.digest;
}

/// The saved failure code of a rejected response.
pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ContextOverflow => "provider_context_overflow",
        error.TemporaryProviderFailure => "provider_temporary_error",
        error.ProviderConnectionClosed => "provider_transport_failure",
        error.EventDataScratchExhausted => "response_data_exhausted",
        error.EventDataWriteFailed, error.EventDataSealFailed, error.EventDataMapFailed => "response_data_failed",
        error.UnsupportedProviderOutput,
        error.UnsupportedItemStatus,
        error.UnsupportedAsyncCall,
        error.UnsupportedCallControl,
        error.UnsupportedCaller,
        error.UnsupportedMetadataAuthority,
        error.UnsupportedReasoningText,
        error.UnsupportedReasoningBlock,
        error.UnsupportedAnnotation,
        error.UnsupportedItemType,
        error.UnsupportedMessageRole,
        error.UnsupportedMessagePhase,
        error.UnsupportedContentBlock,
        error.UnsupportedResponseStatus,
        error.UnsupportedEventType,
        => "unsupported_provider_output",
        error.ContinuationUnavailable => "continuation_unavailable",
        error.MetadataScratchExhausted => "response_metadata_exhausted",
        error.InjectedMetadataFailure => "response_metadata_failed",
        else => "malformed_provider_output",
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

    noinline fn add(self: *Bag, metadata: *output_format.OutputMetadataWriter, data: []const u8, base: u64, member: codec_abi.Range, ordinal: u64, kind: output_format.OutputItemKind) !void {
        if (self.members != 0) {
            self.hash.update(",");
            self.length += 1;
        }
        self.hash.update(bytesOf(data, member));
        self.length = try std.math.add(u64, self.length, member.length);
        self.members += 1;
        try metadata.append(&.{ .tag = .member, .kind = kind, .ordinal = ordinal, .start = base + member.start, .length = member.length, .scope = self.scope });
    }

    /// Records the trailer, even for an empty bag: every item and part has
    /// one, so a missing bag is damage rather than an absence.
    noinline fn close(self: *Bag, metadata: *output_format.OutputMetadataWriter, ordinal: u64, kind: output_format.OutputItemKind) !void {
        try metadata.append(&.{ .tag = .extras, .kind = kind, .ordinal = ordinal, .start = 0, .length = 0, .decoded_length = self.length, .content_digest = self.hash.finalResult(), .scope = self.scope });
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
        // The codec's reader judged these bytes as this decoder does.
        json.decodeContents(bytesOf(data, range), &sink);
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
    /// The caller's, which the completed response fills.
    evidence: *Evidence,
    /// The announced item, until its done event.
    added: ?struct { kind: output_format.OutputItemKind, id_digest: [32]u8 },
    /// Where the current event's data begins in the event data.
    base: u64,
    /// The open item's bag, its open part's bag and a message's text: its
    /// text parts back to back, hashed as they are walked.
    bag: Bag,
    part_bag: Bag,
    text_hash: Sha256,
    /// A provider report's two parts.
    code: ReportPart,
    message: ReportPart,

    fn begin(self: *Grammar, codec: protocol.Codec, metadata: *output_format.OutputMetadataWriter, operation: output_format.ModelOperationKind, rejection: *Rejection, provider_failure: *ProviderFailure, evidence: *Evidence) void {
        self.codec = codec;
        self.metadata = metadata;
        self.operation = operation;
        self.rejection = rejection;
        self.provider_failure = provider_failure;
        self.item_count = 0;
        self.call_count = 0;
        self.compaction_count = 0;
        self.answer = .{ .digest = protocol.contentDigest("") };
        self.evidence = evidence;
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
    noinline fn closeItem(self: *Grammar, data: []const u8, item: *const codec_abi.OutputItem) !void {
        const metadata = self.metadata;
        const kind = outputKind(item.kind);
        const ordinal = self.item_count;
        const bag = &self.bag;
        bag.reset(.item);
        const part_bag = &self.part_bag;
        var in_part = false;
        const text_hash = &self.text_hash;
        text_hash.* = protocol.contentHasher();
        var text_length: u64 = 0;
        var non_whitespace = false;
        var record: output_format.OutputMetadataRecord = undefined;
        var cursor = item.members;
        while (codecs.nextMember(self.codec, data, &cursor)) |member| switch (member) {
            .bag => |range| try (if (in_part) part_bag else bag).add(metadata, data, self.base, range, ordinal, kind),
            .part => |part| {
                const text = Decoded.of(data, part.text, if (kind == .message) text_hash else null, null);
                if (kind == .message) {
                    text_length = try std.math.add(u64, text_length, text.length);
                    non_whitespace = non_whitespace or text.non_whitespace;
                }
                record = .{
                    .tag = .part,
                    .kind = kind,
                    .ordinal = ordinal,
                    .start = self.base + part.text.start,
                    .length = part.text.length,
                    .decoded_length = text.length,
                    .content_digest = text.digest,
                    .part_kind = @fromBackingInt(@backingInt(part.kind)),
                    .part_array = @fromBackingInt(@backingInt(part.array)),
                };
                try metadata.append(&record);
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
                record = .{ .tag = tag, .kind = .function_call, .ordinal = ordinal, .start = self.base + range.start, .length = range.length, .decoded_length = field.length, .content_digest = field.digest };
                try metadata.append(&record);
            },
            .message => {
                record = .{ .tag = .text, .kind = .message, .ordinal = ordinal, .start = 0, .length = 0, .decoded_length = text_length, .content_digest = text_digest };
                try metadata.append(&record);
            },
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
        record = .{
            .tag = .item,
            .kind = kind,
            .ordinal = ordinal,
            .start = self.base + item.whole.start,
            .length = item.whole.length,
            .id_digest = id_digest,
            .content_digest = digestOf(data, item.whole),
            .omit_reasoning_text = item.omit_reasoning_text,
            .phase = @fromBackingInt(@backingInt(item.phase)),
        };
        try metadata.append(&record);
        self.item_count += 1;
    }

    /// The completed response: the Host's gate, then the codec's check of
    /// the response, then the output list against the streamed items, then
    /// usage.
    noinline fn complete(self: *Grammar, data: []const u8, completed: *const codec_abi.Completed) !void {
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
        const written = try pages.mapReadOnly(metadata.io, metadata.file, metadata.charged);
        defer pages.unmapReadOnly(written);
        var records: output_format.OutputMetadataRecords = .{ .bytes = written };
        var cursor = completed.output;
        var index: u64 = 0;
        while (codecs.nextMember(self.codec, data, &cursor)) |member| switch (member) {
            // One item of the output list must be the streamed item at its
            // index, byte for byte.
            .terminal => |*terminal| {
                if (!try streamedAs(&records, data, terminal, index)) return error.ContradictoryProviderOutput;
                index += 1;
            },
            .terminal_failed => |reason| return reasonError(reason),
            .bag, .part, .part_end => unreachable,
        };
        // The managed stream can omit the repeated items from
        // response.completed. Any nonempty terminal list must still match
        // every streamed done item.
        if (index != 0 and (index != self.item_count or try records.nextItem() != null)) return error.ContradictoryProviderOutput;
        switch (completed.usage) {
            .absent => {},
            .failed => |reason| return reasonError(reason),
            .report => |report| try metadata.append(&.{
                .tag = .usage,
                .start = self.base + report.whole.start,
                .length = report.whole.length,
                .content_digest = digestOf(data, report.whole),
                .usage = if (report.counts) |usage| .{ .uncached = usage.uncached, .cache_read = usage.cache_read, .cache_write = usage.cache_write, .output = usage.output } else null,
            }),
        }
        try metadata.sealForRead();
    }

    /// Whether the next streamed item is the output list's item at `index`,
    /// byte for byte.
    fn streamedAs(records: *output_format.OutputMetadataRecords, data: []const u8, terminal: *const @FieldType(codec_abi.Member, "terminal"), index: u64) !bool {
        const record = try records.nextItem() orelse return false;
        return record.ordinal == index and record.kind == outputKind(terminal.kind) and
            std.mem.eql(u8, &record.id_digest, &Decoded.of(data, terminal.id, null, null).digest) and
            std.mem.eql(u8, &record.content_digest, &digestOf(data, terminal.whole));
    }

    /// The codec's verdict on the event, with the provider's report when it
    /// gave one. A reported failure is permanent when its code is a refusal
    /// the Host knows.
    noinline fn fail(self: *Grammar, data: []const u8, failed: *const codec_abi.Failed) anyerror {
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

// ----------------------------------------------------------------- tests

/// Tests' interpretation storage, off their stacks like the Host's. Tests
/// run one at a time and each use finishes before the next starts.
var testing_interpret: Interpret = undefined;
/// Tests' provider failure, the last interpretation's.
var testing_provider_failure: ProviderFailure = undefined;

pub fn testingInterpret() *Interpret {
    comptime std.debug.assert(@import("builtin").is_test);
    return &testing_interpret;
}

pub fn testingProviderFailure() *ProviderFailure {
    comptime std.debug.assert(@import("builtin").is_test);
    return &testing_provider_failure;
}

/// The prefix of an item's event in `recordItemForTesting`.
const testing_item_event = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":";

/// Record one complete item already in `source` at `start` the way
/// acceptance records it: its parts and bags, its call fields or text and
/// then the item record, whose ranges address `source`. Tests that save
/// output without a provider stream use it so their metadata is what
/// acceptance would write.
pub fn recordItemForTesting(metadata: *output_format.OutputMetadataWriter, source: std.Io.File, start: u64, length: u64, ordinal: u64, operation: output_format.ModelOperationKind) !output_format.OutputMetadataRecord {
    comptime std.debug.assert(@import("builtin").is_test);
    const io = metadata.io;
    const bytes = try pages.mapReadOnly(io, source, start + length);
    defer pages.unmapReadOnly(bytes);
    const data = try std.mem.concat(std.testing.allocator, u8, &.{ testing_item_event, bytes[@intCast(start)..], "}" });
    defer std.testing.allocator.free(data);
    // The grammar writes ranges of `data`; they move to `source` as they
    // are copied.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "item-records", .{ .read = true });
    defer file.close(io);
    var used: std.atomic.Value(u64) = .init(0);
    var records: output_format.OutputMetadataWriter = .{ .io = io, .file = file, .budget = .{ .used = &used, .limit = std.math.maxInt(u64) } };
    var rejection: Rejection = .{};
    const grammar = &testing_interpret.grammar;
    var evidence: Evidence = .{ .response_id = .{ .len = 0 }, .served_model = .{ .len = 0 } };
    grammar.begin(pinned, &records, operation, &rejection, testingProviderFailure(), &evidence);
    grammar.item_count = ordinal;
    var stream = codecs.begin(pinned, switch (operation) {
        .assistant_response => .assistant_response,
        .compaction => .compaction,
    });
    try grammar.event(&stream, &testing_interpret.scratch, data, 0, 0);
    if (grammar.item_count != ordinal + 1) return error.TestUnexpectedResult;
    var reader = try output_format.OutputMetadataReader.init(io, file, 1);
    while (try reader.next()) |record| {
        var moved = record;
        switch (record.tag) {
            .member, .part, .name, .call_id, .arguments, .item => moved.start = record.start - testing_item_event.len + start,
            else => {},
        }
        try metadata.append(&moved);
        if (record.tag == .item) return moved;
    }
    unreachable;
}

/// The counts acceptance takes from the usage report at `start` in `file`.
pub fn readUsageForTesting(io: std.Io, file: std.Io.File, start: u64, length: u64) !?output_format.Usage {
    comptime std.debug.assert(@import("builtin").is_test);
    const bytes = try pages.mapReadOnly(io, file, start + length);
    defer pages.unmapReadOnly(bytes);
    const data = try std.mem.concat(std.testing.allocator, u8, &.{ "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[],\"usage\":", bytes[@intCast(start)..], "}}" });
    defer std.testing.allocator.free(data);
    var stream = codecs.begin(pinned, .assistant_response);
    const answer = codecs.interpretEvent(&stream, &testing_interpret.scratch, data);
    return switch (answer.what) {
        .completed => |completed| switch (completed.usage) {
            .absent => null,
            .failed => |reason| reasonError(reason),
            .report => |report| if (report.counts) |usage| .{ .uncached = usage.uncached, .cache_read = usage.cache_read, .cache_write = usage.cache_write, .output = usage.output } else null,
        },
        .failed => |failed| reasonError(failed.reason),
        else => error.TestUnexpectedResult,
    };
}

/// Tests' interpretation, the last one's.
var testing_interpretation: Interpretation = undefined;

/// The accepted output, or the rejection's reason; `testing_interpretation`
/// keeps its coordinates.
fn validate(source: std.Io.File, source_length: u64, metadata: *output_format.OutputMetadataWriter, event_data: *EventData, operation: output_format.ModelOperationKind) anyerror!Validated {
    interpret(&testing_interpret, pinned, std.testing.io, source, source_length, metadata, event_data, operation, .{}, testingProviderFailure(), &testing_interpretation);
    return switch (testing_interpretation) {
        .accepted => |*accepted| accepted.output,
        .rejected => |*rejected| rejected.reason,
    };
}

fn testingObject(tmp: *std.testing.TmpDir, bytes: []const u8) !struct { file: std.Io.File } {
    const file = try tmp.dir.createFile(std.testing.io, "object", .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    return .{ .file = file };
}

const replay_cases = [_]struct { item: []const u8, operation: output_format.ModelOperationKind = .assistant_response, omits_reasoning_text: bool = false, import: ?anyerror = null }{
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"future\":{\"nested\":[null,true]}}" },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\"}", .import = error.ContinuationUnavailable },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":null}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":null}", .import = error.UnexpectedJsonDelimiter },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"not reasoning\"}]}", .import = error.UnsupportedReasoningBlock },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"refusal\",\"refusal\":\"not a summary\"}]}", .import = error.UnsupportedReasoningBlock },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"created_by\":\"canonical\"}", .operation = .compaction },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}", .operation = .compaction, .import = error.ContinuationUnavailable },
    .{ .item = "{\"type\":\"compaction_v2\",\"id\":\"c\",\"encrypted_content\":\"opaque\"}", .import = error.UnsupportedItemType },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}" },
    .{ .item = "{\"id\":\"msg_partial\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"First result.\"}],\"phase\":\"partial_answer\"}" },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"phase\":\"partial_answers\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .import = error.UnsupportedMessagePhase },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\",\"text\":\"ok\"}]}", .import = error.UnsupportedContentBlock },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\",\"caller\":{\"type\":\"future\"}}", .import = error.UnsupportedCaller },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\",\"async\":17}", .import = error.InvalidJsonLiteral },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"status\":\"in_progress\",\"encrypted_content\":\"opaque\"}", .import = error.UnsupportedItemStatus },
    .{ .item = "{\"content\":[{\"text\":\"ok\",\"annotations\":[{\"url\":\"https://example.com\",\"type\":\"url_citation\"}],\"type\":\"output_text\"}],\"role\":\"assistant\",\"phase\":\"final_answer\",\"id\":\"m\",\"type\":\"message\"}" },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"file_citation\"}]}]}", .import = error.UnsupportedAnnotation },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[]}", .import = error.MalformedProviderOutput },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"user\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .import = error.UnsupportedMessageRole },
    .{ .item = "{\"summary\":[{\"annotations\":false,\"text\":\"summary\",\"type\":\"summary_text\"}],\"content\":[{\"text\":\"private\",\"type\":\"reasoning_text\"}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .omits_reasoning_text = true },
    .{ .item = "{\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\",\"annotations\":[],\"annotations\":false}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .omits_reasoning_text = true },
    .{ .item = "{\"summary\":[{\"type\":\"summary_text\",\"text\":\"summary\",\"annotations\":[{\"type\":\"future\",\"type\":false}]}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}" },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"text\":null}", .import = error.UnsupportedReasoningText },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"cell_id\":null}}", .operation = .compaction, .import = error.UnsupportedMetadataAuthority },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"future\":{\"cell_id\":null}}}", .operation = .compaction },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"\",\"caller\":null,\"async\":null,\"namespace\":\"\",\"encrypted_function_args\":null}" },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"async\":true}", .import = error.UnsupportedAsyncCall },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"namespace\":\"program\"}", .import = error.UnsupportedCallControl },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"encrypted_function_args\":\"opaque\"}", .import = error.UnsupportedCallControl },
    // A duplicate the summary reading never consumes stays open.
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"}]}", .import = error.UnsupportedReasoningBlock },
};

test "the item grammar rejects unsupported meaning and preserves open fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ replay_cases, agreement_cases }) |cases| for (cases) |case| {
        if (importTestingItem(&tmp, case.item, case.operation)) |imported| {
            try std.testing.expectEqual(@as(?anyerror, null), case.import);
            try std.testing.expectEqual(case.omits_reasoning_text, imported.first_item.omit_reasoning_text);
        } else |err| try std.testing.expectEqual(case.import, @as(?anyerror, err));
    };
}

const replay_failure_cases = [_]struct { item: []const u8, operation: output_format.ModelOperationKind = .assistant_response, import: anyerror }{
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"id\":\"s\",\"encrypted_content\":\"opaque\"}", .import = error.DuplicateJsonField },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"text\":\"other\"}]}", .import = error.DuplicateJsonField },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"url_citation\",\"type\":\"url_citation\"}]}]}", .import = error.DuplicateJsonField },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"future\",\"type\":false}]}]}", .import = error.UnsupportedItemStatus },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"future_text\"},{\"type\":\"reasoning_text\",\"text\":\"a\",\"text\":\"b\"}]}", .import = error.UnsupportedReasoningBlock },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .import = error.DuplicateJsonField },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"future_text\"},{\"type\":\"summary_text\",\"text\":\"a\",\"text\":\"b\"}]}", .import = error.UnsupportedReasoningBlock },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .import = error.DuplicateJsonField },
    .{ .item = "{\"type\":\"future\",\"id\":\"r\",\"open\":[true,]}", .import = error.InvalidJsonValue },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"future\":\"\xff\"}", .import = error.InvalidJsonUtf8 },
};

test "the item grammar refuses consumed duplicates and syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A consumed duplicate fails the item; an earlier broken rule may be the
    // one named.
    for (replay_failure_cases) |case| try std.testing.expectError(case.import, importTestingItem(&tmp, case.item, case.operation));
}

/// Import one item inside a response that is otherwise acceptable: under
/// compaction the item stands alone, and under assistant_response a trailing
/// call means no answer rule applies.
fn importTestingItem(tmp: *std.testing.TmpDir, item: []const u8, operation: output_format.ModelOperationKind) !TestingValidation {
    const trailer = "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"t\",\"name\":\"bash\",\"call_id\":\"t\",\"arguments\":\"{}\"}}\n\n";
    const sse = try std.testing.allocator.print(
        "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n{s}" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n",
        .{ item, if (operation == .compaction) "" else trailer },
    );
    defer std.testing.allocator.free(sse);
    return validateTestingOperation(tmp, sse, 64 * 1024, operation);
}

const long_type_item = "{\"type\":\"" ++ @as([max_evidence_bytes + 1]u8, @splat('m')) ++ "\",\"id\":\"m\"}";

/// Shapes the replay table leaves out.
const agreement_cases = [_]struct { item: []const u8, operation: output_format.ModelOperationKind = .assistant_response, omits_reasoning_text: bool = false, import: ?anyerror = null }{
    // Another kind leaves `content` open, even duplicated.
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"content\":1,\"content\":2}" },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\"}]}", .omits_reasoning_text = true },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":\"direct\"}", .import = error.UnexpectedJsonDelimiter },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":{}}", .import = error.UnsupportedCaller },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":{\"type\":7}}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"async\":\"false\"}", .import = error.InvalidJsonLiteral },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"namespace\":17}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"\",\"call_id\":\"c\",\"arguments\":\"{}\"}", .import = error.EmptyProviderIdentity },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"arguments\":\"{}\"}", .import = error.MissingProviderField },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":null}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"message\",\"id\":\"\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .import = error.EmptyProviderIdentity },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":null,\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"phase\":42,\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":{}}", .import = error.UnexpectedJsonDelimiter },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\"}", .import = error.MissingProviderField },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[\"ok\"]}", .import = error.UnexpectedJsonDelimiter },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":{}}]}", .import = error.UnexpectedJsonDelimiter },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{}]}]}", .import = error.MissingProviderField },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\"}]}", .import = error.MissingProviderField },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":null}]}", .import = error.ExpectedJsonString },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\",\"text\":1,\"text\":2}]}" },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"text\":\"untyped\"}]}", .import = error.MissingProviderField },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":[]}", .operation = .compaction, .import = error.UnexpectedJsonDelimiter },
    .{ .item = long_type_item, .import = error.ProviderValueTooLong },
};

test "import names the first rule broken in lookup order" {
    const cases = [_]struct {
        item: []const u8,
        operation: output_format.ModelOperationKind,
        import: anyerror,
    }{
        // Status is looked up before content blocks.
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"text\":\"other\"}]}", .operation = .assistant_response, .import = error.UnsupportedItemStatus },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"status\":\"future\",\"encrypted_content\":\"a\",\"encrypted_content\":\"b\"}", .operation = .compaction, .import = error.UnsupportedItemStatus },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[],\"annotations\":false}]}", .operation = .assistant_response, .import = error.UnsupportedItemStatus },
        // Blocks are judged in order.
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\"},{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"}]}", .operation = .assistant_response, .import = error.UnsupportedContentBlock },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .operation = .assistant_response, .import = error.DuplicateJsonField },
        // Type, ID and metadata come before every other rule.
        .{ .item = "{\"type\":\"message\",\"type\":\"message\",\"id\":\"m\",\"status\":\"future\"}", .operation = .assistant_response, .import = error.DuplicateJsonField },
        // The Operation is checked after type, ID and metadata, before the
        // kind's own rules.
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\"}", .operation = .assistant_response, .import = error.UnsupportedProviderOutput },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"\",\"arguments\":\"{}\"}", .operation = .compaction, .import = error.UnsupportedProviderOutput },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":{\"type\":null}}", .operation = .compaction, .import = error.UnsupportedProviderOutput },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"internal_chat_message_metadata_passthrough\":{\"cell_id\":1}}", .operation = .assistant_response, .import = error.UnsupportedMetadataAuthority },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\"}", .operation = .compaction, .import = error.EmptyProviderIdentity },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"\",\"status\":\"future\",\"encrypted_content\":\"opaque\"}", .operation = .assistant_response, .import = error.EmptyProviderIdentity },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        try std.testing.expectError(case.import, importTestingItem(&tmp, case.item, case.operation));
    }
}

test "long escaped strings decode and locate exactly" {
    // Long plain runs broken by escapes, an escaped quote and multibyte text,
    // in a key, in the call's own strings and in an open field.
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    var decoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer decoded.deinit();
    for (0..40) |i| {
        const run: [100]u8 = @splat(@intCast('a' + i % 26));
        try encoded.writer.writeAll(run[0 .. 60 + i]);
        try decoded.writer.writeAll(run[0 .. 60 + i]);
        switch (i % 4) {
            0 => {
                try encoded.writer.writeAll("\\\"");
                try decoded.writer.writeAll("\"");
            },
            1 => {
                try encoded.writer.writeAll("\\u00e9\\n");
                try decoded.writer.writeAll("\u{e9}\n");
            },
            2 => {
                try encoded.writer.writeAll("\u{1f680}");
                try decoded.writer.writeAll("\u{1f680}");
            },
            else => {},
        }
    }
    const text = encoded.written();
    const item = try std.testing.allocator.print(
        "{{\"future_{s}\":\"{s}\",\"arguments\" : \"{s}\",\"call_id\":\"{s}\",\"name\":\"bash\",\"id\":\"{s}\",\"type\":\"function_call\"}}",
        .{ text[0..200], text, text, text, text },
    );
    defer std.testing.allocator.free(item);
    const prefix = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":";
    const sse = try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
        "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n", .{item});
    defer std.testing.allocator.free(sse);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(decoded.written()), &accepted.first_item.id_digest);
    var located: usize = 0;
    for (accepted.records[0..accepted.record_count]) |record| {
        const value = switch (record.tag) {
            .name => "bash",
            .call_id, .arguments => decoded.written(),
            else => continue,
        };
        try std.testing.expectEqual(value.len, record.decoded_length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest(value), &record.content_digest);
        // Each located value is exactly the encoded text after its key.
        if (record.tag != .name) try std.testing.expectEqualStrings(text, item[@intCast(record.start - prefix.len)..][0..@intCast(record.length)]);
        located += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), located);
    _ = try importTestingItem(&tmp, item, .assistant_response);
}

const TestingValidation = struct {
    output: Validated,
    metadata_bytes: u64,
    first_item: output_format.OutputMetadataRecord,
    first_part: ?output_format.OutputMetadataRecord,
    /// The first records, up to the end of the first item.
    records: [24]output_format.OutputMetadataRecord,
    record_count: usize,
};

fn validateTestingSse(tmp: *std.testing.TmpDir, bytes: []const u8, metadata_limit: u64) !TestingValidation {
    return validateTestingOperation(tmp, bytes, metadata_limit, .assistant_response);
}

fn validateTestingOperation(tmp: *std.testing.TmpDir, bytes: []const u8, metadata_limit: u64, operation: output_format.ModelOperationKind) !TestingValidation {
    const source = try tmp.dir.createFile(std.testing.io, "provider-sse", .{ .read = true });
    errdefer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, bytes);
    try source.sync(std.testing.io);
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try output_format.OutputMetadataWriter.init(
        std.testing.io,
        root[0..root_length],
        "provider-test-metadata",
        .{ .used = &used, .limit = metadata_limit },
        false,
        &retained,
    );
    errdefer metadata.deinit();
    // These existing cases vary metadata's ceiling independently of payload.
    // Shared overlap and disposal are exercised with one budget below.
    var data_used: std.atomic.Value(u64) = .init(0);
    var event_data: EventData = undefined;
    try event_data.init(std.testing.io, root[0..root_length], "provider-test-data", .{ .used = &data_used, .limit = bytes.len }, false, &retained);
    defer event_data.deinit();
    const validated = try validate(source, bytes.len, &metadata, &event_data, operation);
    const metadata_bytes = used.load(.acquire);
    var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, validated.item_count);
    var result: TestingValidation = undefined;
    result.output = validated;
    result.metadata_bytes = metadata_bytes;
    result.first_part = null;
    result.record_count = 0;
    result.first_item = while (try reader.next()) |record| {
        if (result.record_count < result.records.len) {
            result.records[result.record_count] = record;
            result.record_count += 1;
        }
        if (record.tag == .item) break record;
        if (record.tag == .part and result.first_part == null) result.first_part = record;
    } else unreachable;
    metadata.deinit();
    source.close(std.testing.io);
    return result;
}

test "a provider error event keeps its refusal and the provider's own words" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const long = comptime repeat("é", 200);
    const cases = [_]struct { event: []const u8, err: anyerror, refusal: ?transport_policy.Refusal, report: []const u8 }{
        // The refusal that ended the bug-swarm Sessions, as a stream event.
        .{ .event = "{\"type\":\"error\",\"code\":\"cyber_policy\",\"message\":\"This request has been flagged for potentially high-risk cyber activity.\",\"param\":null}", .err = error.PermanentProviderFailure, .refusal = .cyber_policy, .report = "cyber_policy: This request has been flagged for potentially high-risk cyber activity." },
        .{ .event = "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"model_not_found\",\"message\":\"No such model.\"}}}", .err = error.PermanentProviderFailure, .refusal = .model_not_found, .report = "model_not_found: No such model." },
        // A retryable failure keeps its words too; an object's type stands in
        // for a missing code, and line breaks read as spaces.
        .{ .event = "{\"type\":\"error\",\"error\":{\"type\":\"server_error\",\"message\":\"Overloaded,\\ntry\\tlater.\"}}", .err = error.TemporaryProviderFailure, .refusal = null, .report = "server_error: Overloaded, try later." },
        // An event's own type is only its name.
        .{ .event = "{\"type\":\"error\",\"code\":null,\"message\":\"Something failed.\"}", .err = error.TemporaryProviderFailure, .refusal = null, .report = "Something failed." },
        // A malformed message is left out; the code still decides.
        .{ .event = "{\"type\":\"error\",\"code\":\"insufficient_quota\",\"message\":7}", .err = error.PermanentProviderFailure, .refusal = .insufficient_quota, .report = "insufficient_quota" },
        // A long message keeps its first 256 bytes, cut at a whole scalar.
        .{ .event = "{\"type\":\"error\",\"code\":\"bio_policy\",\"message\":\"" ++ long ++ "\"}", .err = error.PermanentProviderFailure, .refusal = .bio_policy, .report = "bio_policy: " ++ comptime repeat("é", 128) ++ "…" },
        .{ .event = "{\"type\":\"error\",\"code\":\"bio_policy\",\"message\":\"x" ++ long ++ "\"}", .err = error.PermanentProviderFailure, .refusal = .bio_policy, .report = "bio_policy: x" ++ comptime repeat("é", 127) ++ "…" },
        .{ .event = "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":null}}", .err = error.TemporaryProviderFailure, .refusal = null, .report = "" },
        // An overflow keeps its words too; DEL reads as a space.
        .{ .event = "{\"type\":\"error\",\"code\":\"context_length_exceeded\",\"message\":\"Too\\u007flong.\"}", .err = error.ContextOverflow, .refusal = null, .report = "context_length_exceeded: Too long." },
    };
    for (cases) |case| {
        const sse = try std.mem.concat(std.testing.allocator, u8, &.{ "data: ", case.event, "\n\n" });
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case.err, validateTestingSse(&tmp, sse, 4096));
        try std.testing.expectEqual(case.refusal, testingProviderFailure().refusal);
        try std.testing.expectEqualStrings(case.report, testingProviderFailure().report.slice());
        try std.testing.expect(testingProviderFailure().report.len <= protocol.max_report_bytes);
    }
}

test "provider refusal preserves text and rejects malformed or incomplete candidates" {
    const refusal = "{\"type\":\"message\",\"id\":\"refused\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot help. é\\n\",\"text\":\"not the refusal\",\"annotations\":false,\"future\":true}]}";
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ refusal ++ "}\n\n";
    const completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try validateTestingSse(&tmp, done ++ completed, 4096);
    try std.testing.expectEqual(@as(u64, "Cannot help. é\n".len), result.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("Cannot help. é\n"), result.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(refusal), result.first_item.content_digest);
    try std.testing.expectError(error.ProviderConnectionClosed, validateTestingSse(&tmp, done, 4096));
    try std.testing.expectError(error.IncompleteProviderOutput, validateTestingSse(&tmp, done ++ "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n", 4096));
    const delta = "data: {\"type\":\"response.refusal.delta\",\"delta\":\"not an answer\"}\n\n";
    try std.testing.expectError(error.MissingProviderOutputItems, validateTestingSse(&tmp, delta ++ completed, 4096));
    const future = try validateTestingSse(&tmp, "data: {\"type\":\"response.refusal.future\",\"refusal\":\"not an answer\"}\n\n" ++ done ++ completed, 4096);
    try std.testing.expectEqual(protocol.contentDigest("Cannot help. é\n"), future.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(refusal), future.first_item.content_digest);
    const malformed = [_]struct { block: []const u8, failure: anyerror }{
        .{ .block = "{\"type\":\"refusal\"}", .failure = error.MissingProviderField },
        .{ .block = "{\"type\":\"refusal\",\"refusal\":null}", .failure = error.ExpectedJsonString },
        .{ .block = "{\"type\":\"refusal\",\"refusal\":\"a\",\"refusal\":\"b\"}", .failure = error.DuplicateJsonField },
        .{ .block = "{\"type\":\"future_refusal\",\"refusal\":\"no\"}", .failure = error.UnsupportedContentBlock },
    };
    for (malformed) |case| {
        const item = try std.testing.allocator.print("{{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{s}]}}", .{case.block});
        defer std.testing.allocator.free(item);
        const stream = try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n{s}", .{ item, completed });
        defer std.testing.allocator.free(stream);
        try std.testing.expectError(case.failure, validateTestingSse(&tmp, stream, 4096));
    }
}

test "explicit compaction requires one private anchor and rejects Actions" {
    const anchor = "{\"type\":\"compaction\",\"id\":\"c1\",\"encrypted_content\":\"opaque\",\"created_by\":\"retained\",\"future\":null}";
    const sse = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ anchor ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try validateTestingOperation(&tmp, sse, 4096, .compaction);
    try std.testing.expectEqual(@as(u64, 1), result.output.item_count);
    try std.testing.expectEqual(@as(u64, 0), result.output.call_count);
    try std.testing.expectEqual(output_format.OutputItemKind.compaction, result.first_item.kind);
    try std.testing.expectEqual(protocol.contentDigest(anchor), result.first_item.content_digest);
    const notification = "data: {\"type\":\"response.metadata\",\"metadata\":{}}\n\n";
    const with_metadata = try validateTestingOperation(&tmp, notification ++ sse, 4096, .compaction);
    try std.testing.expectEqual(@as(u64, 1), with_metadata.output.item_count);
    try std.testing.expectEqual(protocol.contentDigest(anchor), with_metadata.first_item.content_digest);
    try std.testing.expectError(error.UnsupportedProviderOutput, validateTestingSse(&tmp, sse, 4096));
    try std.testing.expectEqualStrings("unsupported_provider_output", failureCode(error.UnsupportedProviderOutput));
}

test "compaction validates opaque windows added identity and complete terminal agreement" {
    const encrypted_bytes = &@as([8193]u8, @splat('x'));
    const anchor = try std.testing.allocator.print("{{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"{s}\",\"future\":{{\"nested\":[true,null]}}}}", .{encrypted_bytes});
    defer std.testing.allocator.free(anchor);
    const tail = "{\"type\":\"message\",\"id\":\"tail\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"after anchor\"}]}";
    const sse = try std.testing.allocator.print(
        "data: {{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[{s},{s}]}}}}\n\n",
        .{ anchor, tail, anchor, tail },
    );
    defer std.testing.allocator.free(sse);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try validateTestingOperation(&tmp, sse, 4096, .compaction);
    try std.testing.expectEqual(@as(u64, 2), result.output.item_count);
    try std.testing.expectEqual(protocol.contentDigest(anchor), result.first_item.content_digest);
    try std.testing.expectEqual(@as(u64, "after anchor".len), result.output.answer_length);
}

test "compaction rejects missing double malformed unknown and Action candidates" {
    const cases = .{
        .{ "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}", error.ContinuationUnavailable },
        .{ "{\"type\":\"compaction\",\"id\":\"c\"}", error.ContinuationUnavailable },
        .{ "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":null}", error.ExpectedJsonString },
        .{ "{\"type\":\"compaction_summary\",\"id\":\"c\",\"encrypted_content\":\"x\"}", error.UnsupportedItemType },
        .{ "{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\"}", error.UnsupportedProviderOutput },
        .{ "{\"type\":\"message\",\"id\":\"c\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"not an anchor\"}]}", error.MissingCompactionItem },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (cases) |case| {
        const sse = try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n", .{case[0]});
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case[1], validateTestingOperation(&tmp, sse, 4096, .compaction));
    }
    const anchor = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"x\"}";
    const duplicate = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ anchor ++ "}\n\ndata: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ anchor ++ "}\n\n";
    try std.testing.expectError(error.UnsupportedProviderOutput, validateTestingOperation(&tmp, duplicate, 4096, .compaction));
    const disagreement = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ anchor ++ "}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"different\"}]}}\n\n";
    try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingOperation(&tmp, disagreement, 4096, .compaction));
}

test "SSE line framing accepts spec fields and line endings without losing validation" {
    const item = "{\"type\":\"message\",\"id\":\"a\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}";
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ item ++ "}";
    const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[" ++ item ++ "]}}";
    const accepted = [_][]const u8{
        "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n",
        "data: " ++ done ++ "\r\n\r\ndata: " ++ completed ++ "\r\n\r\n",
        "data:" ++ done ++ "\n\ndata:" ++ completed ++ "\n\n",
        ": comment\nevent: x\nid: 1\nretry: 5\ndata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\ndata: [DONE]\n\n",
        "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\r\n\r\ndata:[DONE]\r\n\r\n",
        // A final carriage return without a newline still ends the line.
        "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\r",
        "data: " ++ done ++ "\r\rdata: " ++ completed ++ "\r\r",
        "\xef\xbb\xbfdata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n",
        "bogus: x\nfield-without-colon\ndatax: ignored\nevent\nid\nretry\ndata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n",
        "data\ndata: " ++ done ++ "\ndata:\n\ndata: " ++ completed ++ "\n\n",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (accepted) |stream| {
        const result = try validateTestingSse(&tmp, stream, 4096);
        try std.testing.expectEqual(@as(u64, 2), result.output.answer_length);
        try std.testing.expectEqual(protocol.contentDigest("hi"), result.output.answer_digest);
        try std.testing.expectEqual(protocol.contentDigest(item), result.first_item.content_digest);
    }
    const rejected = [_]struct { anyerror, []const u8 }{
        .{ error.ProviderConnectionClosed, "dat: " ++ done ++ "\n\n" },
        .{ error.EmptySseData, "data:\n\n" },
        .{ error.EmptySseData, "data: \r\n\r\n" },
        .{ error.TrailingJson, "data: " ++ done ++ "\ndata: " ++ done ++ "\n\n" },
        .{ error.IncompleteSseEvent, "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n" },
        .{ error.IncompleteSseEvent, "data: " ++ done ++ "\n\ndata: " ++ completed },
        .{ error.ContradictoryProviderOutput, "data: " ++ done ++ "\n\ndata: [DONE]\n\n" },
        .{ error.LateProviderOutput, "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\ndata: [DONE]\n\ndata: " ++ done ++ "\n\n" },
    };
    for (rejected) |case| try std.testing.expectError(case[0], validateTestingSse(&tmp, case[1], 4096));
}

test "SSE multiline data inserts exact newlines into retained items" {
    const fields = "\"type\":\"message\",\"id\":\"a\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi é\"}]}";
    const item = "{\n" ++ fields;
    const stream = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\r\n" ++
        ": keepalive\r\nfuture: ignored\r\ndata: " ++ fields ++ "}\r\n\r\n" ++
        "data: {\"type\":\"response.completed\",\rdata: \"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}\r\r";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream, 4096);
    try std.testing.expectEqual(@as(u64, "hi é".len), accepted.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("hi é"), accepted.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(item), accepted.first_item.content_digest);
    try std.testing.expectError(error.InvalidJsonString, validateTestingSse(&tmp, "data: {\"type\":\"future.\ndata: notice\"}\n\n", 4096));
    try std.testing.expectError(error.UnexpectedJsonDelimiter, validateTestingSse(&tmp, "data: [DO\ndata: NE]\n\n", 4096));
    const prefix = ": raw-only prefix\nfuture: ignored\ndata: {\"type\":\"notice\"}\n\n";
    try std.testing.expectError(error.MissingProviderField, validateTestingSse(&tmp, prefix ++ "data: {\"type\":\"response.output_item.done\",\ndata: \"output_index\":0}\n\n", 4096));
    const rejection = testing_interpretation.rejected.location;
    try std.testing.expectEqual(prefix.len + "data: ".len, rejection.byte_offset);
    try std.testing.expectEqual(.item, rejection.stage);
}

test "SSE decoded data shares scratch charges and retains failed unlink ownership" {
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}";
    const terminal = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}";
    const raw = "data: " ++ done ++ "\n\ndata: " ++ terminal ++ "\n\n";
    const decoded = done ++ terminal;
    for ([_]u64{ 0, 1 }) |shortfall| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try tmp.dir.createFile(std.testing.io, "raw", .{ .read = true });
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, raw);
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(raw.len);
        const budget = protocol.ScratchBudget{ .used = &used, .limit = raw.len + decoded.len + 6 * output_format.output_metadata_record_bytes - shortfall };
        var retained: ?named_scratch.Owner = null;
        const descriptors = @import("os/descriptor_limit.zig");
        const baseline = (try descriptors.observe(std.testing.io)).open_descriptors;
        var metadata = try output_format.OutputMetadataWriter.init(std.testing.io, root, "metadata", budget, false, &retained);
        var data: EventData = undefined;
        try data.init(std.testing.io, root, "response-9-1.tmp", budget, false, &retained);
        try std.testing.expectEqual(baseline + 2, (try descriptors.observe(std.testing.io)).open_descriptors);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "response-9-1.tmp", .{}));
        if (shortfall == 0) {
            const result = try validate(source, raw.len, &metadata, &data, .assistant_response);
            var buffer: [raw.len]u8 = undefined;
            try std.testing.expectEqual(decoded.len, try result.source.readPositionalAll(std.testing.io, buffer[0..decoded.len], 0));
            try std.testing.expectEqualStrings(decoded, buffer[0..decoded.len]);
            try std.testing.expectEqual(budget.limit, used.load(.acquire));
        } else {
            try std.testing.expectError(error.EventDataScratchExhausted, validate(source, raw.len, &metadata, &data, .assistant_response));
            try std.testing.expectEqual(raw.len + done.len + 6 * output_format.output_metadata_record_bytes, used.load(.acquire));
        }
        var buffer: [raw.len]u8 = undefined;
        try std.testing.expectEqual(raw.len, try source.readPositionalAll(std.testing.io, &buffer, 0));
        try std.testing.expectEqualStrings(raw, &buffer);
        metadata.deinit();
        data.deinit();
        try std.testing.expectEqual(baseline, (try descriptors.observe(std.testing.io)).open_descriptors);
        try std.testing.expectEqual(@as(u64, raw.len), used.load(.acquire));
        try std.testing.expectError(error.InjectedEventDataUnlinkFailure, data.init(std.testing.io, root, "response-9-1.tmp", budget, true, &retained));
        try std.testing.expect(named_scratch.isOwned("response-9-1.tmp"));
        try std.testing.expectError(error.InjectedScratchRemovalFailure, retained.?.reclaim(root));
        try std.testing.expectEqual(baseline + 1, (try descriptors.observe(std.testing.io)).open_descriptors);
        retained.?.resources.?.removal = .native;
        try std.testing.expectEqual(named_scratch.Reclamation.removed, try retained.?.reclaim(root));
        try std.testing.expectEqual(baseline, (try descriptors.observe(std.testing.io)).open_descriptors);
        try std.testing.expectEqual(@as(u64, raw.len), used.load(.acquire));
        budget.release(raw.len);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}

test "an event's data is charged whole before its metadata from a shared budget" {
    // A message the grammar writes records for, then a field it ignores:
    // the event's data fits the shared budget, its metadata does not.
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]},\"padding\":\"p\"}";
    const raw = "data: " ++ done ++ "\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try tmp.dir.createFile(std.testing.io, "raw", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, raw);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = protocol.ScratchBudget{ .used = &used, .limit = done.len + output_format.output_metadata_record_bytes };
    var retained: ?named_scratch.Owner = null;
    var metadata = try output_format.OutputMetadataWriter.init(std.testing.io, root, "metadata", budget, false, &retained);
    defer metadata.deinit();
    var data: EventData = undefined;
    try data.init(std.testing.io, root, "data", budget, false, &retained);
    defer data.deinit();
    try std.testing.expectError(error.MetadataScratchExhausted, validate(source, raw.len, &metadata, &data, .assistant_response));
    try std.testing.expectEqual(@as(u64, done.len), data.length);
    try std.testing.expectEqual(.item, testing_interpretation.rejected.location.stage);
}

test "a 4 MiB reasoning item interprets whole as one event" {
    const summary = 4 * 1024 * 1024;
    const head = "{\"type\":\"reasoning\",\"id\":\"r\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"";
    const tail = "\"}],\"encrypted_content\":\"opaque\"}";
    const message = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}";
    const item = try std.testing.allocator.alloc(u8, head.len + summary + tail.len);
    defer std.testing.allocator.free(item);
    @memcpy(item[0..head.len], head);
    @memset(item[head.len..][0..summary], 'x');
    @memcpy(item[head.len + summary ..], tail);
    var stream: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stream.deinit();
    try stream.writer.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n", .{item});
    try stream.writer.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{s}}}\n\n", .{message});
    try stream.writer.print("data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[{s},{s}]}}}}\n\n", .{ item, message });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream.written(), 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, "done".len), accepted.output.answer_length);
    try std.testing.expectEqual(@as(u64, item.len), accepted.first_item.length);
    try std.testing.expectEqual(@as(u64, summary), accepted.first_part.?.decoded_length);
}

test "synthetic gpt-6-luna shaped commentary interleaves calls and selects final answer" {
    // Synthetic contract fixture, not a recovered live provider capture.
    const before = "{\"type\":\"message\",\"id\":\"before\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"Inspecting files\"}]}";
    const call = "{\"type\":\"function_call\",\"id\":\"call\",\"name\":\"bash\",\"call_id\":\"k\",\"arguments\":\"{}\"}";
    const between = "{\"type\":\"message\",\"id\":\"between\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"Checking results\"}]}";
    const final = "{\"type\":\"message\",\"id\":\"final\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Only this answer\"}]}";
    const stream = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ before ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ call ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":2,\"item\":" ++ between ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":3,\"item\":" ++ final ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic-luna\",\"model\":\"gpt-6-luna\",\"status\":\"completed\",\"output\":[" ++ before ++ "," ++ call ++ "," ++ between ++ "," ++ final ++ "]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 4), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
    try std.testing.expectEqual(@as(u64, "Only this answer".len), accepted.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("Only this answer"), accepted.output.answer_digest);
}

test "completed empty assistant answers are valid with or without a final phase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ",\"phase\":\"final_answer\"" }) |phase| {
        for ([_]struct { encoded: []const u8, answer: []const u8 }{
            .{ .encoded = "", .answer = "" },
            .{ .encoded = " \\t\\r\\n", .answer = "" },
            .{ .encoded = "\u{85}\u{a0}\u{1680}\u{2000}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}", .answer = "" },
            .{ .encoded = "\\u00a0\\u2003\\u000b\\u000c", .answer = "" },
            .{ .encoded = " \\té\\n ", .answer = " \té\n " },
            .{ .encoded = "\\u200b", .answer = "\u{200b}" },
            .{ .encoded = "\\u0000", .answer = "\x00" },
        }) |case| {
            const item = try std.testing.allocator.print(
                "{{\"type\":\"message\",\"id\":\"empty\",\"role\":\"assistant\"{s},\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\"}}]}}",
                .{ phase, case.encoded },
            );
            defer std.testing.allocator.free(item);
            const sse = try std.testing.allocator.print(
                "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                    "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n",
                .{ item, item },
            );
            defer std.testing.allocator.free(sse);
            const accepted = try validateTestingSse(&tmp, sse, 4096);
            try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
            try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
            try std.testing.expectEqual(@as(?u64, 0), accepted.output.answer_item_ordinal);
            try std.testing.expectEqual(@as(u64, case.answer.len), accepted.output.answer_length);
            try std.testing.expectEqual(protocol.contentDigest(case.answer), accepted.output.answer_digest);
        }
    }
}

test "partial answer fixture selects only the final answer" {
    // Synthetic first-party fixture, not a live capture or executed upstream test:
    // openai/codex 970111f6cb62cc02fe36a82ea7d71b37a2889c97,
    // codex-rs/codex-api/src/sse/responses.rs:759-798.
    // Keep its added/done message shape; Rui requires output_index and a
    // completed envelope. No end_turn:false sampling behavior is inferred.
    const partial = "{\"id\":\"msg_partial\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"First result.\"}],\"phase\":\"partial_answer\"}";
    const final = "{\"id\":\"msg_final\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Final result.\"}],\"phase\":\"final_answer\"}";
    const stream = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_partial\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"phase\":\"partial_answer\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"First result.\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ partial ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ final ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp1\",\"status\":\"completed\",\"output\":[" ++ partial ++ "," ++ final ++ "]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream, 4096);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(?u64, 1), accepted.output.answer_item_ordinal);
    try std.testing.expectEqual(@as(u64, "Final result.".len), accepted.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("Final result."), accepted.output.answer_digest);
}

test "message phases select one answer without dropping or concatenating text" {
    const cases = [_]struct { first: []const u8, second: []const u8, answer: ?[]const u8 = null, failure: ?anyerror = null }{
        .{ .first = "", .second = "", .answer = "second é" },
        .{ .first = ",\"phase\":null", .second = "", .answer = "second é" },
        .{ .first = ",\"phase\":\"commentary\"", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"partial_answer\"", .answer = "first" },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = "", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"partial_answer\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = ",\"phase\":\"commentary\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = ",\"phase\":\"partial_answer\"", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"commentary\"", .answer = "first" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = "", .answer = "first" },
        .{ .first = ",\"phase\":\"commentary\"", .second = "", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"commentary\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"final_answer\"", .failure = error.MultipleFinalAnswers },
        .{ .first = ",\"phase\":\"analysis\"", .second = "", .failure = error.UnsupportedMessagePhase },
        .{ .first = ",\"phase\":\"partial_answers\"", .second = ",\"phase\":\"final_answer\"", .failure = error.UnsupportedMessagePhase },
        .{ .first = ",\"phase\":42", .second = "", .failure = error.ExpectedJsonString },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const sse = try std.testing.allocator.print(
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{{\"type\":\"message\",\"id\":\"a\",\"role\":\"assistant\"{s},\"content\":[{{\"type\":\"output_text\",\"text\":\"first\"}}]}}}}\n\n" ++
                "data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{{\"type\":\"message\",\"id\":\"b\",\"role\":\"assistant\"{s},\"content\":[{{\"type\":\"output_text\",\"text\":\"second é\"}}]}}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n",
            .{ case.first, case.second },
        );
        defer std.testing.allocator.free(sse);
        if (case.failure) |failure| {
            try std.testing.expectError(failure, validateTestingSse(&tmp, sse, 64 * 1024));
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
            try std.testing.expectEqual(@as(u64, case.answer.?.len), accepted.output.answer_length);
            try std.testing.expectEqual(protocol.contentDigest(case.answer.?), accepted.output.answer_digest);
            try std.testing.expectEqual(@as(?u64, if (std.mem.eql(u8, case.answer.?, "first")) 0 else 1), accepted.output.answer_item_ordinal);
        }
    }
}

test "completion gate saves which requirement failed at the completed event" {
    const message = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"a\"}]}";
    const final = "{\"type\":\"message\",\"id\":\"f\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"b\"}]}";
    const reasoning = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"x\",\"summary\":[]}";
    const call = "{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"bash\",\"call_id\":\"k\",\"arguments\":\"{}\"}";
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":";
    const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}";
    const cases = [_]struct { anyerror, output_format.ModelOperationKind, []const u8 }{
        .{ error.UnfinishedProviderOutputItem, .assistant_response, done ++ "0,\"item\":" ++ message ++ "}\n\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":" ++ call ++ "}\n\n" },
        .{ error.MissingProviderOutputItems, .assistant_response, ": keepalive\r\n\r\n" },
        .{ error.MultipleFinalAnswers, .assistant_response, done ++ "0,\"item\":" ++ final ++ "}\r\n\r\n" ++ done ++ "1,\"item\":" ++ final ++ "}\r\n\r\n" },
        .{ error.MissingAssistantAnswer, .assistant_response, done ++ "0,\"item\":" ++ reasoning ++ "}\n\n" },
        .{ error.MissingCompactionItem, .compaction, done ++ "0,\"item\":" ++ final ++ "}\n\n" },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const sse = try std.testing.allocator.print("{s}data: {s}\n\n", .{ case[2], completed });
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case[0], validateTestingOperation(&tmp, sse, 4096, case[1]));
        const rejection = testing_interpretation.rejected.location;
        try std.testing.expectEqual(.response, rejection.stage);
        try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, sse, completed).?), rejection.byte_offset);
        try std.testing.expectEqual(@as(?u64, null), rejection.output_index);
        try std.testing.expectEqualStrings("malformed_provider_output", failureCode(case[0]));
        var buffer: [512]u8 = undefined;
        var expected: [512]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "{{\"reason\":\"{s}\",\"stage\":\"response\",\"byte_offset\":\"{d}\",\"output_index\":null}}", .{ @errorName(case[0]), rejection.byte_offset }),
            rejection.format(case[0], &buffer),
        );
    }
}

test "provider completion treats null usage as absent and rejects malformed optional evidence" {
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const absent = try validateTestingSse(&tmp, done ++ terminal ++ "}}\n\n", 4096);
    const nullable = try validateTestingSse(&tmp, done ++ terminal ++ ",\"usage\":null}}\n\n", 4096);
    try std.testing.expectEqual(absent.metadata_bytes, nullable.metadata_bytes);
    try std.testing.expectEqual(@as(u64, 2), nullable.output.answer_length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &nullable.output.answer_digest);
    inline for (.{ ",\"usage\":[]", ",\"usage\":123", ",\"model\":123", ",\"model\":null,\"model\":\"other\"", ",\"usage\":null,\"usage\":{}" }) |suffix| {
        const bytes = done ++ terminal ++ suffix ++ "}}\n\n";
        if (validateTestingSse(&tmp, bytes, 4096)) |_| {
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqualStrings("malformed_provider_output", failureCode(err));
        }
    }
}

test "responses usage maps onto Rui's four counts" {
    const Usage = output_format.Usage;
    const cases = [_]struct { []const u8, ?Usage }{
        .{ "{\"input_tokens\":7,\"output_tokens\":11,\"total_tokens\":18}", .{ .uncached = 7, .cache_read = 0, .cache_write = 0, .output = 11 } },
        .{ "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":64},\"output_tokens\":5}", .{ .uncached = 36, .cache_read = 64, .cache_write = 0, .output = 5 } },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":null,\"output_tokens\":0}", .{ .uncached = 9, .cache_read = 0, .cache_write = 0, .output = 0 } },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{},\"output_tokens\":1}", .{ .uncached = 9, .cache_read = 0, .cache_write = 0, .output = 1 } },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":9},\"output_tokens\":1}", .{ .uncached = 0, .cache_read = 9, .cache_write = 0, .output = 1 } },
        .{ "{\"total_tokens\":18}", null },
        .{ "{\"input_tokens\":7}", null },
        .{ "{\"input_tokens\":7,\"output_tokens\":1.5}", null },
        .{ "{\"input_tokens\":-7,\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":9223372036854775808,\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":1,\"input_tokens\":2,\"output_tokens\":0}", null },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":10},\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":[],\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":null},\"output_tokens\":1}", null },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const file = try tmp.dir.createFile(std.testing.io, "usage", .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, case[0]);
        try std.testing.expectEqual(case[1], try readUsageForTesting(std.testing.io, file, 0, case[0].len));
    }
}

test "context overflow requires exact valid provider code over SSE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const failures = [_][]const u8{
        "{\"type\":\"error\",\"code\":\"context_length_exceeded\"}",
        "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"context_length_exceeded\"}}}",
        "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"context_length_exceeded\"}}}",
    };
    for (failures) |failure| {
        const sse = try std.testing.allocator.print("data: {s}\n\n", .{failure});
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(error.ContextOverflow, validateTestingSse(&tmp, sse, 4096));
    }
    const lookalikes = [_]struct { anyerror, []const u8 }{
        .{ error.TemporaryProviderFailure, "{\"type\":\"error\",\"code\":\"context_length_exceeded_extra\"}" },
        .{ error.TemporaryProviderFailure, "{\"type\":\"error\",\"message\":\"context_length_exceeded\"}" },
        .{ error.TemporaryProviderFailure, "{\"type\":\"error\",\"code\":\"other\",\"error\":{\"code\":\"context_length_exceeded\"}}" },
        .{ error.IncompleteProviderOutput, "{\"type\":\"response.failed\",\"response\":{\"status\":\"completed\",\"error\":{\"code\":\"context_length_exceeded\"}}}" },
        .{ error.TemporaryProviderFailure, "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"context_length_exceeded\"}}}" },
        .{ error.IncompleteProviderOutput, "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}" },
        .{ error.DuplicateJsonField, "{\"type\":\"error\",\"code\":\"context_length_exceeded\",\"code\":\"other\"}" },
    };
    for (lookalikes) |case| {
        const sse = try std.testing.allocator.print("data: {s}\n\n", .{case[1]});
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case[0], validateTestingSse(&tmp, sse, 4096));
    }
}

fn testingReasoningSse(reasoning: []const u8, terminal_reasoning: []const u8) ![]u8 {
    const answer = "{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}";
    return std.testing.allocator.print(
        "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response\",\"status\":\"completed\",\"output\":[{s},{s}]}}}}\n\n",
        .{ reasoning, answer, terminal_reasoning, answer },
    );
}

test "provider proposal identity uses decoded content domain" {
    const sse = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"p-é\\n\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"p-\\u00e9\\n\",\"name\":\"bash\",\"call_id\":\"c1\",\"arguments\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, sse, 4096);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("p-é\n"), &accepted.first_item.id_digest);
}

test "provider reasoning strings preserve raw items" {
    const values = .{
        "plain",
        @as([64 * 6]u8, @bitCast(@as([64][6]u8, @splat("\\u0041".*)))) ++ "\\u00e9\\u4e2d\\uD83D\\uDE42",
    };
    inline for (values) |value| {
        const reasoning = try std.testing.allocator.print(
            "{{\"type\":\"reasoning\",\"id\":\"r1\",\"encrypted_content\":\"{s}\",\"summary\":[{{\"type\":\"summary_text\",\"text\":\"{s}\"}}]," ++
                "\"content\":[{{\"type\":\"reasoning_text\",\"text\":\"{s}\"}}],\"created_by\":\"kept\",\"future\":{{\"raw\":null}}}}",
            .{ value, value, value },
        );
        defer std.testing.allocator.free(reasoning);
        const sse = try testingReasoningSse(reasoning, reasoning);
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try testingObject(&tmp, sse);
        defer source.file.close(std.testing.io);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        const budget = protocol.ScratchBudget{ .used = &used, .limit = sse.len + 64 * 1024 };
        var metadata = try output_format.OutputMetadataWriter.init(std.testing.io, path, "metadata", budget, false, &retained);
        defer metadata.deinit();
        var data: EventData = undefined;
        try data.init(std.testing.io, path, "data", budget, false, &retained);
        defer data.deinit();
        const accepted = try validate(source.file, sse.len, &metadata, &data, .assistant_response);
        try std.testing.expectEqual(@as(u64, 2), accepted.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.call_count);
        try std.testing.expectEqual(@as(u64, 2), accepted.answer_length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &accepted.answer_digest);
        var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, accepted.item_count);
        const item = (try reader.nextItem()).?;
        try std.testing.expectEqual(output_format.OutputItemKind.reasoning, item.kind);
        try std.testing.expectEqual(@as(u64, 0), item.ordinal);
        try std.testing.expectEqual(reasoning.len, item.length);
        const retained_bytes = try std.testing.allocator.alloc(u8, reasoning.len);
        defer std.testing.allocator.free(retained_bytes);
        try std.testing.expectEqual(reasoning.len, try accepted.source.readPositionalAll(std.testing.io, retained_bytes, item.start));
        try std.testing.expectEqualStrings(reasoning, retained_bytes);
        // Expected complete raw bytes include response-only and unknown fields,
        // not a decoded or normalized spelling of the reasoning strings.
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest(reasoning), &item.content_digest);
    }
}

test "provider reasoning validation rejects wrong types duplicates and malformed suffixes" {
    const prefix = &@as([257]u8, @splat('a'));
    const cases = .{
        .{ "\"summary\":[]", error.ContinuationUnavailable },
        .{ "\"encrypted_content\":\"\"", error.ContinuationUnavailable },
        .{ "\"encrypted_content\":null", error.ExpectedJsonString },
        .{ "\"encrypted_content\":17", error.ExpectedJsonString },
        .{ "\"encrypted_content\":{}", error.ExpectedJsonString },
        .{ "\"encrypted_content\":\"opaque\",\"text\":null", error.UnsupportedReasoningText },
        .{ "\"encrypted_content\":\"opaque\",\"status\":\"in_progress\"", error.UnsupportedItemStatus },
        .{ "\"encrypted_content\":\"opaque\",\"encr\\u0079pted_content\":\"second\"", error.DuplicateJsonField },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":null}]", error.ExpectedJsonString },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":{}}]", error.ExpectedJsonString },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"reasoning_text\",\"text\":\"x\"}]", error.UnsupportedReasoningBlock },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"summary_text\",\"text\":\"x\"}]", error.UnsupportedReasoningBlock },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\"}]", error.MissingProviderField },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"a\",\"te\\u0078t\":\"b\"}]", error.DuplicateJsonField },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\\q\"", error.InvalidJsonEscape },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\xff\"", error.InvalidJsonUtf8 },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\xe2\"", error.InvalidJsonUtf8 },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\\uD800x\"", error.InvalidJsonSurrogate },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\\uDC00\"", error.InvalidJsonSurrogate },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"" ++ prefix ++ "\\uD800\\u0041\"}]", error.InvalidJsonSurrogate },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"" ++ prefix ++ "\\q\"}]", error.InvalidJsonEscape },
        .{ "\"encrypted_content\":\"opaque\",\"future\":[1,]", error.InvalidJsonValue },
    };
    inline for (cases) |case| {
        const reasoning = try std.testing.allocator.print("{{\"type\":\"reasoning\",\"id\":\"r1\",{s}}}", .{case[0]});
        defer std.testing.allocator.free(reasoning);
        const sse = try testingReasoningSse(reasoning, reasoning);
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expectError(case[1], validateTestingSse(&tmp, sse, 64 * 1024));
    }

    // Nonempty means decoded bytes, not visible characters; summary/content
    // text may be empty and escaped consequential keys keep their meaning.
    const valid = "{\"type\":\"reasoning\",\"id\":\"r1\",\"encr\\u0079pted_content\":\"\\u0000\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"\"}],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"\"}]}";
    const sse = try testingReasoningSse(valid, valid);
    defer std.testing.allocator.free(sse);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(u64, 2), (try validateTestingSse(&tmp, sse, 64 * 1024)).output.item_count);
}

test "provider added identity permits incomplete content but terminal agreement requires exact bytes" {
    const done = "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"opaque\",\"future\":\"one\"}";
    const added_items = .{
        .{ "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"in_progress\",\"encrypted_content\":\"\"}", false },
        .{ "{\"type\":\"reasoning\",\"id\":\"other\"}", true },
        .{ "{\"type\":\"message\",\"id\":\"r1\"}", true },
    };
    const tail = try testingReasoningSse(done, done);
    defer std.testing.allocator.free(tail);
    inline for (added_items) |case| {
        const sse = try std.testing.allocator.print(
            "data: {{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{s}}}\n\n{s}",
            .{ case[0], tail },
        );
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case[1]) {
            try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingSse(&tmp, sse, 64 * 1024));
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(done), &accepted.first_item.content_digest);
        }
    }

    const changed_terminal = .{
        "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"different\",\"future\":\"one\"}",
        "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"o\\u0070aque\",\"future\":\"one\"}",
        "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"opaque\",\"future\":\"two\"}",
    };
    inline for (changed_terminal) |terminal| {
        const sse = try testingReasoningSse(done, terminal);
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingSse(&tmp, sse, 64 * 1024));
    }
}

test "provider preserves ordered trustworthy function call envelopes" {
    const first = "{\"type\":\"function_call\",\"id\":\"item-1\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call\\nA\",\"arguments\":\"{\\\"cmd\\\":\\\"one\\\"}\"}";
    const second = "{\"type\":\"function_call\",\"id\":\"item-2\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-B\",\"arguments\":\"{\\\"cmd\\\":\\\"two\\\"}\"}";
    const valid = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ second ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[" ++ first ++ "," ++ second ++ "]}}\n\n";
    var valid_tmp = std.testing.tmpDir(.{});
    defer valid_tmp.cleanup();
    const accepted = try validateTestingSse(&valid_tmp, valid, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.call_count);
    try std.testing.expectEqual(@as(u64, 0), accepted.output.answer_length);
    // Per call: the item, three call fields, and an item bag of `id` and
    // `status` with its trailer.
    try std.testing.expectEqual(@as(u64, 2 * 7 * 104), accepted.metadata_bytes);

    const invalid_second = "{\"type\":\"function_call\",\"id\":\"item-2\",\"status\":\"completed\",\"name\":\"edit\",\"call_id\":\"call-B\",\"arguments\":\"{}\"}";
    const late_invalid = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ invalid_second ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-2\",\"status\":\"completed\",\"output\":[" ++ first ++ "," ++ invalid_second ++ "]}}\n\n";
    var invalid_tmp = std.testing.tmpDir(.{});
    defer invalid_tmp.cleanup();
    const mixed = try validateTestingSse(&invalid_tmp, late_invalid, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), mixed.output.call_count);

    const message = "{\"type\":\"message\",\"id\":\"message-1\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"late\",\"annotations\":[]}]}";
    const late_message = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ message ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"late\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var order_tmp = std.testing.tmpDir(.{});
    defer order_tmp.cleanup();
    const late = try validateTestingSse(&order_tmp, late_message, 64 * 1024);
    try std.testing.expectEqual(protocol.contentDigest("late"), late.output.answer_digest);
}

test "empty terminal output uses complete streamed items but partial terminal output contradicts them" {
    const first = "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\"}";
    const second = "{\"type\":\"function_call\",\"id\":\"item-2\",\"name\":\"bash\",\"call_id\":\"call-2\",\"arguments\":\"{}\"}";
    const items = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ second ++ "}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-1\",\"status\":\"completed\",\"output\":";
    var empty_tmp = std.testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    const accepted = try validateTestingSse(&empty_tmp, items ++ terminal ++ "[]}}\n\n", 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.call_count);

    var partial_tmp = std.testing.tmpDir(.{});
    defer partial_tmp.cleanup();
    try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingSse(&partial_tmp, items ++ terminal ++ "[" ++ first ++ "]}}\n\n", 64 * 1024));

    var missing_tmp = std.testing.tmpDir(.{});
    defer missing_tmp.cleanup();
    try std.testing.expectError(error.MissingProviderOutputItems, validateTestingSse(&missing_tmp, terminal ++ "[]}}\n\n", 64 * 1024));
}

test "function call argument stream events are scratch and completed items remain authority" {
    const complete = "{\"type\":\"function_call\",\"id\":\"item-1\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{\\\"cmd\\\":\\\"echo ok\\\"}\"}";
    const stream = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item-1\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"item-1\",\"delta\":\"ignored\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"item-1\",\"arguments\":\"ignored\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ complete ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[" ++ complete ++ "]}}\n\n";
    var valid_tmp = std.testing.tmpDir(.{});
    defer valid_tmp.cleanup();
    const accepted = try validateTestingSse(&valid_tmp, stream, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
    try std.testing.expectEqual(@as(u64, 7 * 104), accepted.metadata_bytes);

    const malformed = "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\"}";
    const malformed_stream = "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ malformed ++ "}\n\n";
    var malformed_tmp = std.testing.tmpDir(.{});
    defer malformed_tmp.cleanup();
    try std.testing.expectError(error.MissingProviderField, validateTestingSse(&malformed_tmp, malformed_stream, 64 * 1024));
}

test "provider rejects unsupported consequential function call controls" {
    const supported = "{\"type\":\"function_call\",\"id\":\"item-1\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"caller\":{\"type\":\"direct\",\"future\":1},\"async\":false,\"namespace\":\"\",\"encrypted_function_args\":null}";
    const cases = .{
        .{ supported, false },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"caller\":{\"type\":\"program\"}}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"caller\":{}}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"async\":true}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"namespace\":\"remote\"}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"encrypted_function_args\":\"opaque\"}", true },
    };
    inline for (cases) |case| {
        const sse = try std.testing.allocator.print(
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n",
            .{ case[0], case[0] },
        );
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case[1]) {
            if (validateTestingSse(&tmp, sse, 64 * 1024)) |_| {
                return error.ExpectedRejection;
            } else |err| {
                try std.testing.expectEqualStrings("unsupported_provider_output", failureCode(err));
            }
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
        }
    }
}

test "metadata notification is not output or completion authority" {
    // Minimized from the authorized 2026-10-17 Codex probe. Metadata arrived
    // before the completed message; only the done item supplied its answer.
    const notification = "data: {\"type\":\"response.metadata\",\"sequence_number\":5,\"response_id\":\"synthetic\",\"metadata\":{\"openai_chatgpt_moderation_metadata\":{\"prompt\":{},\"generation\":{},\"tool_call\":{},\"tool_response\":{}}}}\n\n";
    const item = "{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\",\"annotations\":[]}],\"phase\":\"final_answer\"}";
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ item ++ "}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"status\":\"completed\",\"output\":[" ++ item ++ "]}}\n\n";
    for ([_][]const u8{ notification ++ done ++ terminal, done ++ notification ++ terminal }) |sse| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const accepted = try validateTestingSse(&tmp, sse, 4096);
        try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(@as(u64, 2), accepted.output.answer_length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("OK"), &accepted.output.answer_digest);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.ProviderConnectionClosed, validateTestingSse(&tmp, notification, 4096));
    try std.testing.expectError(error.MissingProviderOutputItems, validateTestingSse(&tmp, notification ++ terminal, 4096));
    try std.testing.expectError(error.LateProviderOutput, validateTestingSse(&tmp, done ++ terminal ++ notification, 4096));
    for ([_][]const u8{
        "{\"type\":\"response.metadata.future\",\"item\":null,\"output_index\":\"unused\"}",
        "{\"type\":\"codex.response.metadata\",\"response\":{\"status\":\"failed\"}}",
        "{\"type\":\"future.notice\",\"future\":[null,true,{}]}",
        "{\"type\":\"response.output_item_future\"}",
    }) |event| {
        const unknown = try std.testing.allocator.print("data: {s}\n\n", .{event});
        defer std.testing.allocator.free(unknown);
        const sse = try std.testing.allocator.print("{s}{s}{s}", .{ done, unknown, terminal });
        defer std.testing.allocator.free(sse);
        const accepted = try validateTestingSse(&tmp, sse, 4096);
        try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(protocol.contentDigest("OK"), accepted.output.answer_digest);
        try std.testing.expectError(error.ProviderConnectionClosed, validateTestingSse(&tmp, unknown, 4096));
    }
    try std.testing.expectError(error.UnsupportedEventType, validateTestingSse(&tmp, "data: {\"type\":\"response.output_item.future\"}\n\n" ++ done ++ terminal, 4096));
    try std.testing.expectError(error.MissingProviderField, validateTestingSse(&tmp, "data: {\"type\":\"response.output_item.done\",\"output_index\":0}\n\n" ++ terminal, 4096));
    try std.testing.expectError(error.DuplicateJsonField, validateTestingSse(&tmp, "data: {\"type\":\"future.notice\",\"type\":\"response.completed\"}\n\n" ++ done ++ terminal, 4096));
    try std.testing.expectError(error.InvalidJsonValue, validateTestingSse(&tmp, "data: {\"type\":\"future.notice\",\"future\":!}\n\n" ++ done ++ terminal, 4096));
}

test "escaped envelope keys name their fields and repeated unknown keys stay unread" {
    const item = "{\"type\":\"message\",\"id\":\"m\",\"r\\u006fle\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"te\\u0078t\":\"ok\"}]}";
    const done = "data: {\"ty\\u0070e\":\"response.output_item.done\",\"output_\\u0069ndex\":0,\"it\\u0065m\":" ++ item ++ ",\"x\":1,\"x\":2}\n\n";
    const completed = "data: {\"type\":\"response.completed\",\"resp\\u006fnse\":{\"id\":\"r\",\"st\\u0061tus\":\"completed\",\"output\":[],\"x\":1,\"x\":2},\"x\":1,\"x\":2}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, done ++ completed, 4096);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
    try std.testing.expectEqual(protocol.contentDigest("ok"), accepted.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(item), accepted.first_item.content_digest);
    // Item, part text, part bag trailer, item bag `id` and its trailer,
    // message text: the escaped role is Rui's, not the bag's.
    try std.testing.expectEqual(@as(u64, 6 * 104), accepted.metadata_bytes);
    // An escaped spelling of a field the envelope reads is that field again.
    try std.testing.expectError(error.DuplicateJsonField, validateTestingSse(&tmp, done ++ "data: {\"type\":\"response.completed\",\"ty\\u0070e\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}\n\n", 4096));
}

test "Bash proposal metadata growth is linear and disk-backed" {
    const action_count = 1_000;
    var bytes: [1024 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var item_buffer: [256]u8 = undefined;
    for (0..action_count) |index| {
        const item = try std.fmt.bufPrint(
            &item_buffer,
            "{{\"type\":\"function_call\",\"id\":\"item-{d}\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-{d}\",\"arguments\":\"{{}}\"}}",
            .{ index, index },
        );
        var event_buffer: [512]u8 = undefined;
        try writer.writeAll(try std.fmt.bufPrint(
            &event_buffer,
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{s}}}\n\n",
            .{ index, item },
        ));
    }
    try writer.writeAll("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"growth\",\"status\":\"completed\",\"output\":[");
    for (0..action_count) |index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll(try std.fmt.bufPrint(
            &item_buffer,
            "{{\"type\":\"function_call\",\"id\":\"item-{d}\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-{d}\",\"arguments\":\"{{}}\"}}",
            .{ index, index },
        ));
    }
    try writer.writeAll("]}}\n\n");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const validated = try validateTestingSse(
        &tmp,
        writer.buffered(),
        action_count * 7 * 104,
    );
    try std.testing.expectEqual(@as(u64, action_count), validated.output.call_count);
    try std.testing.expectEqual(@as(u64, action_count * 7 * 104), validated.metadata_bytes);
    try std.testing.expect(@sizeOf(Validated) < protocol.content_window_bytes);
}

test "provider field collection cannot grant authority through escaped metadata keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"cell_\\u0069d\":null,\"unknown\":{\"nested\":[1,true]}}}";
    try std.testing.expectError(error.UnsupportedMetadataAuthority, importTestingItem(&tmp, item, .compaction));
}

test "provider authority metadata rejects every supported item" {
    const prefixes = .{
        "{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\"",
        "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]",
        "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\"",
        "{\"type\":\"compaction\",\"id\":\"b\",\"encrypted_content\":\"opaque\"",
    };
    inline for (prefixes, 0..) |prefix, index| {
        inline for (.{ "cell_id", "cell_\\u0069d", "executed_tool_calls", "executed_tool_\\u0063alls", "tool_calls_complete", "tool_calls_\\u0063omplete", "future" }) |key| {
            const item = try std.testing.allocator.print("{s},\"internal_chat_message_metadata_passthrough\":{{\"{s}\":null}}}}", .{ prefix, key });
            defer std.testing.allocator.free(item);
            const sse = if (index == 2) try testingReasoningSse(item, item) else try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n", .{ item, item });
            defer std.testing.allocator.free(sse);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const purpose: output_format.ModelOperationKind = if (index == 3) .compaction else .assistant_response;
            if (comptime std.mem.eql(u8, key, "future")) {
                _ = try validateTestingOperation(&tmp, sse, 4096, purpose);
            } else {
                try std.testing.expectError(error.UnsupportedMetadataAuthority, validateTestingOperation(&tmp, sse, 4096, purpose));
            }
        }
    }
}

test "fuzz provider decoded answers and rejection" {
    try std.testing.fuzz({}, fuzzAnswer, .{ .corpus = &.{
        "\x00\x00\x00\x00",
        "\x10\x41\x00\x00\x00\xe9\x00\x00\x00\x00\xd8\x00\x00",
    } });
}

fn fuzzAnswer(_: void, smith: *std.testing.Smith) !void {
    var text_buffer: [128]u8 = undefined;
    var text = std.Io.Writer.fixed(&text_buffer);
    // Always exercise controls, multibyte UTF-8 and surrogate-pair escaping
    // beside generated scalars.
    try text.writeAll("\x00\"\n\\€𐀀");
    const count = smith.valueRangeAtMost(u8, 0, 16);
    for (0..count) |_| {
        var scalar = smith.valueRangeAtMost(u21, 0, 0x10f7ff);
        if (scalar >= 0xd800) scalar += 0x800;
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(scalar, &encoded);
        try text.writeAll(encoded[0..length]);
    }
    const expected_digest = protocol.contentDigest(text.buffered());
    inline for (.{ false, true }) |escape_unicode| {
        var item_buffer: [512]u8 = undefined;
        var item = std.Io.Writer.fixed(&item_buffer);
        try item.writeAll("{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
        try std.json.Stringify.value(text.buffered(), .{ .escape_unicode = escape_unicode }, &item);
        try item.writeAll("}]}");

        var stream_buffer: [3 * 512]u8 = undefined;
        var stream = std.Io.Writer.fixed(&stream_buffer);
        try stream.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n", .{ item.buffered(), item.buffered() });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const accepted = try validateTestingSse(&tmp, stream.buffered(), 4096);
        try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(@as(u64, text.buffered().len), accepted.output.answer_length);
        try std.testing.expectEqualSlices(u8, &expected_digest, &accepted.output.answer_digest);
        // Syntax errors after valid content cannot become accepted prefixes.
        try std.testing.expectError(error.IncompleteSseEvent, validateTestingSse(&tmp, stream.buffered()[0 .. stream.buffered().len - 2], 4096));
        stream = .fixed(&stream_buffer);
        try stream.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s},\"late\":\"\xff\"}}\n\n", .{item.buffered()});
        try std.testing.expectError(error.InvalidJsonUtf8, validateTestingSse(&tmp, stream.buffered(), 4096));
    }
}
