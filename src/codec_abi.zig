//! The provider codec contract: the values a codec and the Host exchange.
//! Std only, so every codec shares this one layout.
const std = @import("std");

/// Response headers a codec reads as input. The Host captures only these
/// (plus what it needs itself, such as Retry-After). An empty name is not
/// observed.
pub const ObservedHeaders = struct {
    /// Recorded as the Attempt's request id.
    request_id: []const u8 = "",
    /// The model the provider reports serving, and its alternate header.
    model: []const u8 = "",
    alternate_model: []const u8 = "",
    /// A per-Turn routing value echoed on the Turn's later requests.
    turn_state: []const u8 = "",
};

pub const max_carry_bytes = 16;

/// A codec's encoder state at a history-item boundary, opaque to the Host.
/// A request that reuses an earlier request's history span resumes from
/// the carry that span ended in, so the bytes after it match a rebuild.
pub const Carry = struct {
    len: u8 = 0,
    bytes: [max_carry_bytes]u8 = @splat(0),

    pub fn of(state: []const u8) Carry {
        std.debug.assert(state.len <= max_carry_bytes);
        var carry: Carry = .{ .len = @intCast(state.len) };
        @memcpy(carry.bytes[0..state.len], state);
        return carry;
    }

    pub fn slice(self: *const Carry) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Carry, other: *const Carry) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

// ---------------------------------------------------------------- encode
//
// The Host walks a request's neutral items in order and gives the codec one
// `ItemHeader` at a time. The codec answers each with ops in `Ops`, which the
// Host runs in place before it asks for the next item. Rui's bulk text never
// enters the codec: an item names its content by handle, and a `content` op
// streams a handle into the request under a pinned escape.
//
// Append-only: the bytes of the history items, from the first history item
// to `history_end`, are the span a later request of the Session begins with.
// The codec's state at each history-element boundary is exactly its carry:
// the Host reloads the state from the last carry before every element and
// before `history_end`, whether that carry came from the previous element or
// from a history memo, so a memo copy and a rebuild continue identically.
// Anything that depends on being last comes after `history_end`.

/// The neutral items of a request, in the order the Host yields them:
/// settings, instructions, the history items, history_end,
/// compaction_trigger (compaction requests only), tools_start, one tool per
/// enabled tool, text_format, request_end.
pub const ItemKind = enum(u8) {
    /// The frozen settings, the model included. Handle 0: that same model,
    /// which the codec writes by a content op so the Host escapes it. The
    /// only item whose ops may include request headers.
    settings,
    /// Handle 0: Rui's instruction text, Workspace, Session and baseline.
    instructions,
    /// Handle 0: the text; handle 1, when present: Rui's peer sender wording.
    message,
    /// One saved output item opens. A function call's handles 0-2: name,
    /// call_id, arguments.
    output_open,
    /// Handle 0, when present: the part's text; handle 1, when present: its
    /// provider bag.
    output_part,
    /// Handle 0, when present: the item's provider bag.
    output_close,
    /// Handle 0: the call_id; handle 1: the output.
    tool_result,
    /// After the last history item: the end of the append-only span.
    history_end,
    compaction_trigger,
    tools_start,
    /// Handles 0-2: name, description, parameter schema (JSON text).
    tool,
    /// Handle 0, when present: the output schema (JSON text).
    text_format,
    request_end,

    /// The items the Host reloads the codec's state from its carry before.
    pub fn resumes(self: ItemKind) bool {
        return switch (self) {
            .message, .output_open, .tool_result, .history_end => true,
            else => false,
        };
    }

    /// The items that end a history element, whose last op is the carry.
    pub fn endsElement(self: ItemKind) bool {
        return switch (self) {
            .message, .output_close, .tool_result => true,
            else => false,
        };
    }
};

/// Rui's closed effort grammar.
pub const Effort = enum(u8) { none, low, medium, high, xhigh, max };
pub const Author = enum(u8) { user, instruction };
pub const OutputKind = enum(u8) { reasoning = 1, message = 2, function_call = 3, compaction = 4 };
pub const Phase = enum(u8) { unphased = 0, commentary = 1, final_answer = 2 };
pub const PartKind = enum(u8) { opaque_block = 0, output_text = 1, refusal = 2, summary_text = 3, reasoning_text = 4 };
pub const PartArray = enum(u8) { none = 0, content = 1, summary = 2 };

pub const Item = union(ItemKind) {
    settings: Settings,
    instructions,
    message: Author,
    output_open: struct {
        kind: OutputKind,
        phase: Phase,
        /// The replay rule acceptance judged: leave reasoning_text parts out.
        omit_reasoning_text: bool,
    },
    output_part: struct { array: PartArray, kind: PartKind },
    output_close,
    tool_result,
    history_end,
    compaction_trigger,
    tools_start,
    tool,
    text_format,
    request_end,
};

pub const max_handles = 3;
pub const max_model_bytes = 256;

/// Frozen request settings, carried by the settings item only.
pub const Settings = struct {
    /// Null when the binding has no effort; the codec then sends none.
    effort: ?Effort,
    /// The Session's provider affinity: fixed for the Session's life and
    /// distinct across Sessions and Stores.
    session_affinity: [16]u8,
    model_length: u16,
    /// A literal that names the other fields leaves these bytes unwritten.
    model: [max_model_bytes]u8 = undefined,

    pub fn modelName(self: *const Settings) []const u8 {
        return self.model[0..self.model_length];
    }
};

/// One item, as the Host gives it to the codec.
pub const ItemHeader = struct {
    item: Item,
    /// Bit `i` is set when handle `i` exists.
    handles: u8,

    pub fn has(self: *const ItemHeader, handle: u8) bool {
        return handle < max_handles and self.handles >> @intCast(handle) & 1 == 1;
    }
};

/// How the Host writes a handle's bytes, or reads a report range. A pinned
/// codec version always gets the same bytes: a `_v1` mode never changes.
pub const Escape = enum(u8) {
    /// The bytes as stored (JSON a provider sent or a schema).
    verbatim = 0,
    /// The contents of a JSON string: quote, backslash and C0 controls
    /// escaped, everything else (UTF-8 included) as is.
    json_string_v1 = 1,
};

pub const OpTag = enum(u8) {
    /// u16 little-endian length, then that many (at least one) bytes,
    /// copied into the request.
    literal = 1,
    /// u8 handle, u8 escape: the whole handle, escaped.
    content = 2,
    /// u8 length (at most max_carry_bytes), then the bytes: the codec's
    /// state after this history element.
    carry = 3,
    /// u8 name length (at least 1), u16 little-endian value length, the
    /// name, the value: one request header (settings only).
    header = 4,
};

pub const Op = union(OpTag) {
    literal: []const u8,
    content: struct { handle: u8, escape: Escape },
    carry: Carry,
    header: Header,
};

/// A request header a codec asks for. The Host sends it ahead of its own
/// fields when the name is a lowercase token that no Host field uses and
/// the value is header-safe (`headerValue`), up to `max_request_headers`
/// headers of `max_request_header_bytes` names and values in all.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const max_request_headers = 8;
/// Names and values together. The settings item's ops hold its headers and
/// its body literals in `Ops.capacity` bytes, so a larger bound could never
/// be reached; the prepared request stores this many bytes.
pub const max_request_header_bytes = 192;

pub const Status = enum(u8) {
    /// The item is encoded, or the window read; its ops are ready.
    next = 0,
    /// The request is complete (request_end only), or the body classified.
    done = 1,
    /// The codec cannot encode this request or classify this body.
    failed = 2,
};

/// The ops a codec writes for one item, or the findings for one window.
pub const Ops = struct {
    pub const capacity = 256;

    length: u16 = 0,
    bytes: [capacity]u8 = undefined,

    pub fn literal(self: *Ops, bytes: []const u8) error{OpsOverflow}!void {
        std.debug.assert(bytes.len != 0);
        const head = try self.reserve(3 + bytes.len);
        head[0] = @backingInt(OpTag.literal);
        std.mem.writeInt(u16, head[1..3], @intCast(bytes.len), .little);
        @memcpy(head[3..], bytes);
    }

    pub fn content(self: *Ops, handle: u8, escape: Escape) error{OpsOverflow}!void {
        const head = try self.reserve(3);
        head[0..3].* = .{ @backingInt(OpTag.content), handle, @backingInt(escape) };
    }

    pub fn carry(self: *Ops, state: []const u8) error{OpsOverflow}!void {
        std.debug.assert(state.len <= max_carry_bytes);
        const head = try self.reserve(2 + state.len);
        head[0] = @backingInt(OpTag.carry);
        head[1] = @intCast(state.len);
        @memcpy(head[2..], state);
    }

    pub fn header(self: *Ops, name: []const u8, value: []const u8) error{OpsOverflow}!void {
        std.debug.assert(name.len != 0 and name.len <= std.math.maxInt(u8));
        const head = try self.reserve(4 + name.len + value.len);
        head[0] = @backingInt(OpTag.header);
        head[1] = @intCast(name.len);
        std.mem.writeInt(u16, head[2..4], @intCast(value.len), .little);
        @memcpy(head[4..][0..name.len], name);
        @memcpy(head[4 + name.len ..], value);
    }

    pub fn finding(self: *Ops, value: Finding) error{OpsOverflow}!void {
        switch (value) {
            .context_overflow => (try self.reserve(1))[0] = @backingInt(FindingTag.context_overflow),
            .quota => |quota| {
                std.debug.assert(quota.code.len != 0 and quota.code.len <= max_code_bytes);
                const head = try self.reserve(11 + quota.code.len);
                head[0..3].* = .{ @backingInt(FindingTag.quota), @intCast(quota.code.len), @intFromBool(quota.resets_at != null) };
                std.mem.writeInt(u64, head[3..11], quota.resets_at orelse 0, .little);
                @memcpy(head[11..], quota.code);
            },
            .refusal => |code| {
                std.debug.assert(code.len != 0 and code.len <= max_code_bytes);
                const head = try self.reserve(2 + code.len);
                head[0..2].* = .{ @backingInt(FindingTag.refusal), @intCast(code.len) };
                @memcpy(head[2..], code);
            },
            .report => |range| {
                const head = try self.reserve(19);
                head[0..3].* = .{ @backingInt(FindingTag.report), @backingInt(range.field), @backingInt(range.escape) };
                std.mem.writeInt(u64, head[3..11], range.start, .little);
                std.mem.writeInt(u64, head[11..19], range.length, .little);
            },
        }
    }

    pub fn record(self: *Ops, value: Record) error{OpsOverflow}!void {
        const tag: RecordTag = switch (value) {
            .refusal => |code| return self.finding(.{ .refusal = code }),
            .report => |range| return self.finding(.{ .report = range }),
            inline else => |_, name| @field(RecordTag, @tagName(name)),
        };
        const bytes = try self.reserve(recordSize(tag));
        bytes[0] = @backingInt(tag);
        switch (value) {
            .raw => |raw| {
                bytes[1] = @backingInt(raw.span);
                std.mem.writeInt(u64, bytes[2..10], raw.start, .little);
                std.mem.writeInt(u64, bytes[10..18], raw.length, .little);
            },
            .string => |string| {
                bytes[1..3].* = .{ @backingInt(string.field), @intFromBool(string.last) };
                std.mem.writeInt(u64, bytes[3..11], string.start, .little);
                std.mem.writeInt(u64, bytes[11..19], string.length, .little);
            },
            .item, .added, .terminal => |kind| bytes[1] = @backingInt(kind),
            .part => |part| bytes[1..3].* = .{ @backingInt(part.array), @backingInt(part.kind) },
            .terminal_failed, .failed => |reason| bytes[1] = @backingInt(reason),
            .member_end, .part_end, .completed, .terminal_end, .finish => {},
            .item_end => |item| bytes[1..4].* = .{ @backingInt(item.answer_phase), @backingInt(item.phase), @intFromBool(item.omit_reasoning_text) },
            .usage => |usage| {
                bytes[1] = @intFromBool(usage != null);
                const counts = usage orelse Usage{ .uncached = 0, .cache_read = 0, .cache_write = 0, .output = 0 };
                inline for (.{ counts.uncached, counts.cache_read, counts.cache_write, counts.output }, 0..) |count, index|
                    std.mem.writeInt(u64, bytes[2 + 8 * index ..][0..8], count, .little);
            },
            .at => |at| {
                bytes[1..3].* = .{ @backingInt(at.stage), @intFromBool(at.output_index != null) };
                std.mem.writeInt(u64, bytes[3..11], at.output_index orelse 0, .little);
            },
            .need => |offset| std.mem.writeInt(u64, bytes[1..9], offset, .little),
            .refusal, .report => unreachable,
        }
    }

    /// Reads these ops as an interpreter's records, from the first.
    pub fn records(self: *const Ops) RecordReader {
        return .{ .bytes = self.bytes[0..self.length] };
    }

    fn reserve(self: *Ops, count: usize) error{OpsOverflow}![]u8 {
        if (capacity - self.length < count) return error.OpsOverflow;
        defer self.length += @intCast(count);
        return self.bytes[self.length..][0..count];
    }

    /// Reads the ops from `offset`, which is 0 or an offset `Reader.next`
    /// returned.
    pub fn reader(self: *const Ops, offset: u16) Reader {
        return .{ .bytes = self.bytes[0..self.length], .offset = offset };
    }

    /// Reads these ops as findings, from the first op.
    pub fn findings(self: *const Ops) FindingReader {
        return .{ .bytes = self.bytes[0..self.length] };
    }
};

/// Decodes ops; anything malformed is `error.CodecBadOp`.
pub const Reader = struct {
    bytes: []const u8,
    offset: u16,

    pub fn next(self: *Reader) error{CodecBadOp}!?Op {
        const rest = self.bytes[self.offset..];
        if (rest.len == 0) return null;
        const tag = std.enums.fromInt(OpTag, rest[0]) orelse return error.CodecBadOp;
        // Lengths are widened to usize before any sum, so no op can wrap
        // the arithmetic that bounds it.
        switch (tag) {
            .literal => {
                if (rest.len < 3) return error.CodecBadOp;
                const count: usize = std.mem.readInt(u16, rest[1..3], .little);
                if (count == 0 or rest.len - 3 < count) return error.CodecBadOp;
                self.advance(3 + count);
                return .{ .literal = rest[3..][0..count] };
            },
            .content => {
                if (rest.len < 3) return error.CodecBadOp;
                const escape = std.enums.fromInt(Escape, rest[2]) orelse return error.CodecBadOp;
                self.advance(3);
                return .{ .content = .{ .handle = rest[1], .escape = escape } };
            },
            .carry => {
                if (rest.len < 2) return error.CodecBadOp;
                const length: usize = rest[1];
                if (length > max_carry_bytes or rest.len - 2 < length) return error.CodecBadOp;
                self.advance(2 + length);
                return .{ .carry = .of(rest[2..][0..length]) };
            },
            .header => {
                if (rest.len < 4 or rest[1] == 0) return error.CodecBadOp;
                const name_length: usize = rest[1];
                const value_length: usize = std.mem.readInt(u16, rest[2..4], .little);
                if (rest.len - 4 < name_length + value_length) return error.CodecBadOp;
                self.advance(4 + name_length + value_length);
                return .{ .header = .{ .name = rest[4..][0..name_length], .value = rest[4 + name_length ..][0..value_length] } };
            },
        }
    }

    /// `count` is at most the bytes left, so the offset stays within them.
    fn advance(self: *Reader, count: usize) void {
        self.offset = @intCast(self.offset + count);
    }
};

// -------------------------------------------------------------- classify
//
// The Host classifies an HTTP error response by feeding the codec the sealed
// body in order, one window at a time, from its first byte to its last. It
// never feeds a byte twice, and the codec cannot ask it to: a codec keeps
// what it needs of earlier windows in its own state, and names text by range.
// The codec answers each window with findings in `Ops`. A finding can only
// narrow the failure the Host's status rules give, and every narrowing
// settles the Attempt as a failure no retry can fix, so a codec can never
// make a failure retryable. The Host keeps every status rule, decides which
// narrowing applies, and maps each code through its own closed sets, so a
// code it does not know narrows nothing.

/// One window of the body. Windows are contiguous: the first starts at
/// offset 0 and each starts where the one before ended.
pub const Fed = struct {
    bytes: []const u8,
    /// No bytes follow these: the codec answers `done` or `failed`.
    end: bool,
};

/// The longest provider code a finding carries. Every code the Host knows is
/// shorter, so a codec leaves a longer one out.
pub const max_code_bytes = 64;

/// The two parts of a report, `code: message`.
pub const ReportField = enum(u8) { code = 0, message = 1 };

/// The tags continue `OpTag`'s numbering, so neither job's reader accepts
/// the other's ops.
pub const FindingTag = enum(u8) {
    /// No payload: the request exceeds the model's context.
    context_overflow = 5,
    /// u8 code length (1 to max_code_bytes), u8 1 when a reset time is
    /// given and 0 when not, u64 little-endian reset time (0 when not
    /// given), the code: a quota refusal, if the Host knows the code as one.
    quota = 6,
    /// u8 code length (1 to max_code_bytes), the code: a refusal, if the
    /// Host knows the code as one.
    refusal = 7,
    /// u8 field, u8 escape, u64 little-endian start, u64 little-endian
    /// length: one part of the report, as a range of the body.
    report = 8,
};

pub const Finding = union(FindingTag) {
    context_overflow,
    quota: Quota,
    refusal: []const u8,
    report: ReportRange,
};

pub const Quota = struct {
    code: []const u8,
    /// The Unix second the quota resets, when the provider gives one.
    resets_at: ?u64,
};

/// Where one part of the report is. With `json_string_v1` the range holds
/// the contents of a JSON string, without its quotes, which the Host
/// decodes; with `verbatim` it holds the text itself.
pub const ReportRange = struct {
    field: ReportField,
    escape: Escape,
    start: u64,
    length: u64,
};

/// Decodes findings; anything malformed is `error.CodecBadOp`.
pub const FindingReader = struct {
    bytes: []const u8,
    offset: u16 = 0,

    pub fn next(self: *FindingReader) error{CodecBadOp}!?Finding {
        const rest = self.bytes[self.offset..];
        if (rest.len == 0) return null;
        const tag = std.enums.fromInt(FindingTag, rest[0]) orelse return error.CodecBadOp;
        switch (tag) {
            .context_overflow => {
                self.offset += 1;
                return .context_overflow;
            },
            .quota => {
                if (rest.len < 11 or rest[2] > 1) return error.CodecBadOp;
                const code = try codeAt(rest[11..], rest[1]);
                const resets_at = std.mem.readInt(u64, rest[3..11], .little);
                if (rest[2] == 0 and resets_at != 0) return error.CodecBadOp;
                self.offset += @intCast(11 + code.len);
                return .{ .quota = .{ .code = code, .resets_at = if (rest[2] == 1) resets_at else null } };
            },
            .refusal => {
                if (rest.len < 2) return error.CodecBadOp;
                const code = try codeAt(rest[2..], rest[1]);
                self.offset += @intCast(2 + code.len);
                return .{ .refusal = code };
            },
            .report => {
                if (rest.len < 19) return error.CodecBadOp;
                const field = std.enums.fromInt(ReportField, rest[1]) orelse return error.CodecBadOp;
                const escape = std.enums.fromInt(Escape, rest[2]) orelse return error.CodecBadOp;
                self.offset += 19;
                return .{ .report = .{
                    .field = field,
                    .escape = escape,
                    .start = std.mem.readInt(u64, rest[3..11], .little),
                    .length = std.mem.readInt(u64, rest[11..19], .little),
                } };
            },
        }
    }

    fn codeAt(bytes: []const u8, length: u8) error{CodecBadOp}![]const u8 {
        if (length == 0 or length > max_code_bytes or bytes.len < length) return error.CodecBadOp;
        return bytes[0..length];
    }
};

// ------------------------------------------------------------- interpret
//
// The Host interprets a sealed response stream by framing its server-sent
// events itself and feeding the codec each event's data from memory as it
// writes it to the decoded event data, one window at a time. Every range a
// codec names is an offset into that event data. The codec judges the
// provider's grammar; it never hashes and never decides a failure's code.
// It answers each window with records in `Ops`: spans of bytes the Host
// hashes or decodes as they are fed, the structure those bytes form, and at
// an event's end its verdict. A codec that needs bytes again (a value whose
// meaning arrived after it) or has no room left in `Ops` ends its answer
// with `need`, and the Host feeds on from that offset.

/// One window of one event, or the stream's end.
pub const EventFed = struct {
    /// Where `bytes` begin in the decoded event data.
    offset: u64,
    bytes: []const u8,
    /// No bytes of this event follow (`bytes` is empty): the codec judges
    /// the event.
    event_end: bool,
    /// The stream ended between events (`bytes` is empty): the codec
    /// answers `done`, or `failed` with its verdict.
    end: bool,
};

/// What the response answers, which decides which items it may hold.
pub const Operation = enum(u8) { assistant_response = 0, compaction = 1 };

/// The bytes a `raw` record names, hashed as received.
pub const Span = enum(u8) {
    /// The item being read, from its opening brace to its closing one.
    item = 0,
    /// One member of the open item's or part's provider bag, `"key":value`.
    member = 1,
    /// One item of the completed response's output list.
    terminal = 2,
    /// The completed response's usage report.
    usage = 3,
};

/// The JSON string contents a `string` record names, decoded and hashed.
pub const Field = enum(u8) {
    item_id = 0,
    /// The id of an item a `response.output_item.added` event announces.
    added_id = 1,
    terminal_id = 2,
    part_text = 3,
    call_name = 4,
    call_id = 5,
    call_arguments = 6,
    response_id = 7,
    served_model = 8,
};

/// Where in the stream a failure stands, for its diagnostic coordinates.
pub const Stage = enum(u8) { stream = 0, event = 1, item = 2, response = 3 };

/// A codec's verdict, named as the Host names the rejection it becomes. The
/// Host maps each to its code and kind; a codec cannot choose either.
pub const Reason = enum(u8) {
    contradictory_provider_output = 0,
    late_provider_output,
    provider_connection_closed,
    missing_provider_field,
    duplicate_json_field,
    expected_json_string,
    provider_value_too_long,
    invalid_provider_index,
    trailing_json,
    overflow,
    unexpected_json_delimiter,
    unsupported_event_type,
    unsupported_item_type,
    empty_provider_identity,
    unfinished_provider_output_item,
    unsupported_response_status,
    incomplete_provider_output,
    temporary_provider_failure,
    context_overflow,
    /// The provider reported a failure; the refusal finding before it, if
    /// the Host knows its code, makes it permanent.
    reported_provider_failure,
    unsupported_item_status,
    continuation_unavailable,
    unsupported_content_block,
    unsupported_reasoning_block,
    unsupported_reasoning_text,
    unsupported_provider_output,
    unsupported_async_call,
    invalid_json_literal,
    unsupported_call_control,
    unsupported_message_role,
    unsupported_message_phase,
    malformed_provider_output,
    unsupported_annotation,
    unsupported_caller,
    unsupported_metadata_authority,
    // The event's data is not one JSON object, for the reason the JSON
    // reader names.
    unexpected_json_end,
    invalid_json_string,
    invalid_json_escape,
    invalid_json_surrogate,
    invalid_json_utf8,
    invalid_json_number,
    invalid_json_value,
    json_too_deep,
};

/// The Host's name for a reason: its words, capitalized and joined.
pub fn reasonName(comptime reason: Reason) []const u8 {
    comptime var out: []const u8 = "";
    comptime var upper = true;
    inline for (@tagName(reason)) |byte| {
        if (byte == '_') {
            upper = true;
            continue;
        }
        out = out ++ .{if (upper) std.ascii.toUpper(byte) else byte};
        upper = false;
    }
    return out;
}

/// The tags continue `FindingTag`'s numbering; an interpreter also gives
/// the `refusal` and `report` findings.
pub const RecordTag = enum(u8) {
    /// u8 Span, u64 start, u64 length: bytes of a span, contiguous with the
    /// span's earlier bytes. A member's first bytes open it.
    raw = 9,
    /// u8 Field, u8 1 when these are the string's last bytes and 0 when not,
    /// u64 start, u64 length: JSON string contents, contiguous with the
    /// string's earlier bytes; the first open it.
    string = 10,
    /// u8 OutputKind: an item begins; its `raw` item bytes follow.
    item = 11,
    /// No payload: the open member's bytes are complete.
    member_end = 12,
    /// u8 PartArray, u8 PartKind: a part of the open item begins.
    part = 13,
    /// No payload: the open part ends; its last `string` part_text is its
    /// text.
    part_end = 14,
    /// u8 Phase for answer selection, u8 Phase for Rui's form, u8 1 when
    /// replay leaves the item's reasoning text out: the open item is
    /// accepted.
    item_end = 15,
    /// u8 OutputKind: the event announces the next item, named by its last
    /// `string` added_id.
    added = 16,
    /// No payload: the response completes; the Host checks what it holds.
    completed = 17,
    /// u8 OutputKind: one output list item, of its `raw` terminal bytes and
    /// last `string` terminal_id, ends.
    terminal = 18,
    /// u8 Reason: one output list item ends and is not an item.
    terminal_failed = 19,
    /// No payload: the output list ends.
    terminal_end = 20,
    /// u8 1 when the counts are usable and 0 when not, u64 uncached input,
    /// u64 cache read, u64 cache write, u64 output tokens: the usage report
    /// whose `raw` usage bytes were given.
    usage = 21,
    /// No payload: the completion is whole.
    finish = 22,
    /// u8 Stage, u8 1 when an output index follows and 0 when not, u64
    /// index: where the event's verdict stands.
    at = 23,
    /// u8 Reason: the event's verdict.
    failed = 24,
    /// u64 offset: feed on from this offset of the event data. The last
    /// record of an answer.
    need = 25,
};

pub const Usage = struct { uncached: u64, cache_read: u64, cache_write: u64, output: u64 };

pub const Record = union(enum) {
    raw: struct { span: Span, start: u64, length: u64 },
    string: struct { field: Field, last: bool, start: u64, length: u64 },
    item: OutputKind,
    member_end,
    part: struct { array: PartArray, kind: PartKind },
    part_end,
    item_end: struct { answer_phase: Phase, phase: Phase, omit_reasoning_text: bool },
    added: OutputKind,
    completed,
    terminal: OutputKind,
    terminal_failed: Reason,
    terminal_end,
    usage: ?Usage,
    finish,
    at: struct { stage: Stage, output_index: ?u64 },
    failed: Reason,
    need: u64,
    refusal: []const u8,
    report: ReportRange,
};

/// The bytes a record of `tag` takes.
pub fn recordSize(tag: RecordTag) usize {
    return switch (tag) {
        .raw => 18,
        .string => 19,
        .item, .added, .terminal, .terminal_failed, .failed => 2,
        .part => 3,
        .member_end, .part_end, .completed, .terminal_end, .finish => 1,
        .item_end => 4,
        .usage => 34,
        .at => 11,
        .need => 9,
    };
}

/// Decodes records; anything malformed is `error.CodecBadOp`.
pub const RecordReader = struct {
    bytes: []const u8,
    offset: u16 = 0,

    pub fn next(self: *RecordReader) error{CodecBadOp}!?Record {
        const rest = self.bytes[self.offset..];
        if (rest.len == 0) return null;
        if (std.enums.fromInt(FindingTag, rest[0])) |tag| {
            var findings: FindingReader = .{ .bytes = rest };
            const finding = try findings.next() orelse unreachable;
            self.offset += findings.offset;
            return switch (tag) {
                .refusal => .{ .refusal = finding.refusal },
                .report => .{ .report = finding.report },
                .context_overflow, .quota => error.CodecBadOp,
            };
        }
        const tag = std.enums.fromInt(RecordTag, rest[0]) orelse return error.CodecBadOp;
        const size = recordSize(tag);
        if (rest.len < size) return error.CodecBadOp;
        self.offset += @intCast(size);
        return switch (tag) {
            .raw => .{ .raw = .{ .span = try value(Span, rest[1]), .start = int(rest[2..10]), .length = int(rest[10..18]) } },
            .string => .{ .string = .{ .field = try value(Field, rest[1]), .last = try flag(rest[2]), .start = int(rest[3..11]), .length = int(rest[11..19]) } },
            .item => .{ .item = try value(OutputKind, rest[1]) },
            .member_end => .member_end,
            .part => .{ .part = .{ .array = try value(PartArray, rest[1]), .kind = try value(PartKind, rest[2]) } },
            .part_end => .part_end,
            .item_end => .{ .item_end = .{ .answer_phase = try value(Phase, rest[1]), .phase = try value(Phase, rest[2]), .omit_reasoning_text = try flag(rest[3]) } },
            .added => .{ .added = try value(OutputKind, rest[1]) },
            .completed => .completed,
            .terminal => .{ .terminal = try value(OutputKind, rest[1]) },
            .terminal_failed => .{ .terminal_failed = try value(Reason, rest[1]) },
            .terminal_end => .terminal_end,
            .usage => .{ .usage = if (try flag(rest[1])) .{ .uncached = int(rest[2..10]), .cache_read = int(rest[10..18]), .cache_write = int(rest[18..26]), .output = int(rest[26..34]) } else if (std.mem.allEqual(u8, rest[2..34], 0)) null else return error.CodecBadOp },
            .finish => .finish,
            .at => .{ .at = .{ .stage = try value(Stage, rest[1]), .output_index = if (try flag(rest[2])) int(rest[3..11]) else if (std.mem.allEqual(u8, rest[3..11], 0)) null else return error.CodecBadOp } },
            .failed => .{ .failed = try value(Reason, rest[1]) },
            .need => .{ .need = int(rest[1..9]) },
        };
    }

    fn value(comptime T: type, byte: u8) error{CodecBadOp}!T {
        return std.enums.fromInt(T, byte) orelse error.CodecBadOp;
    }

    fn flag(byte: u8) error{CodecBadOp}!bool {
        return switch (byte) {
            0 => false,
            1 => true,
            else => error.CodecBadOp,
        };
    }

    fn int(bytes: *const [8]u8) u64 {
        return std.mem.readInt(u64, bytes, .little);
    }
};

/// A tool as the model is told about it; each codec writes its own envelope.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON Schema object, as JSON text.
    parameters_json: []const u8,
};

/// What a codec declares about itself, read without running it.
pub const Manifest = struct {
    observe: ObservedHeaders,

    /// HTTP/2 field names arrive lowercase (RFC 9113 8.2.1, enforced by
    /// nghttp2), so a name with an uppercase byte could never match.
    pub fn valid(self: *const Manifest) bool {
        inline for (@typeInfo(ObservedHeaders).@"struct".field_names) |name| {
            for (@field(self.observe, name)) |byte| if (!lowercaseTokenByte(byte)) return false;
        }
        return true;
    }
};

/// A name that HTTP/2 can carry: a nonempty RFC 9110 token, lowercase.
pub fn lowercaseToken(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!lowercaseTokenByte(byte)) return false;
    return true;
}

/// Printable ASCII (0x20-0x7e) that neither starts nor ends with a space.
/// Stricter than h2, which refuses only NUL, CR and LF: RFC 9113 8.2.1 also
/// forbids leading and trailing whitespace, and RFC 9110 5.5 excludes other
/// controls and keeps values to US-ASCII.
pub fn headerValue(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return value.len == 0 or (value[0] != ' ' and value[value.len - 1] != ' ');
}

fn lowercaseTokenByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', '0'...'9', '-', '_', '.', '!', '#', '$', '%', '&', '\'', '*', '+', '^', '`', '|', '~' => true,
        else => false,
    };
}

test "a manifest names its observed headers as lowercase tokens" {
    // RFC 9110 5.6.2: tchar is ALPHA, DIGIT and these marks; HTTP/2 drops the uppercase.
    const marks = "!#$%&'*+-.^_`|~";
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const tchar = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or std.mem.indexOfScalar(u8, marks, byte) != null;
        const name = [_]u8{ 'x', byte };
        const manifest: Manifest = .{ .observe = .{ .model = &name } };
        try std.testing.expectEqual(tchar, manifest.valid());
    }
    const unnamed: Manifest = .{ .observe = .{} };
    try std.testing.expect(unnamed.valid());
}

test "a header value is printable ASCII without edge spaces" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const inner = [_]u8{ 'a', byte, 'b' };
        try std.testing.expectEqual(byte >= 0x20 and byte <= 0x7e, headerValue(&inner));
    }
    try std.testing.expect(headerValue(""));
    try std.testing.expect(headerValue("text/event-stream"));
    for ([_][]const u8{ " rui", "rui ", " ", "a\tb", "a\r\nb", "a\x00", "\xc3\xa9" }) |value|
        try std.testing.expect(!headerValue(value));
    try std.testing.expect(lowercaseToken("session-id"));
    for ([_][]const u8{ "", "Accept", ":path", "a b", "a\x00" }) |name|
        try std.testing.expect(!lowercaseToken(name));
}

test "every record reads back as written, in the bytes its tag's size gives" {
    const records = [_]Record{
        .{ .raw = .{ .span = .member, .start = 7, .length = 9 } },
        .{ .string = .{ .field = .call_arguments, .last = true, .start = 1 << 40, .length = 3 } },
        .{ .item = .function_call },
        .member_end,
        .{ .part = .{ .array = .summary, .kind = .summary_text } },
        .part_end,
        .{ .item_end = .{ .answer_phase = .final_answer, .phase = .commentary, .omit_reasoning_text = true } },
        .{ .added = .message },
        .completed,
        .{ .terminal = .reasoning },
        .{ .terminal_failed = .json_too_deep },
        .terminal_end,
        .{ .usage = .{ .uncached = 1, .cache_read = 2, .cache_write = 3, .output = 4 } },
        .{ .usage = null },
        .finish,
        .{ .at = .{ .stage = .item, .output_index = 5 } },
        .{ .at = .{ .stage = .stream, .output_index = null } },
        .{ .failed = .unexpected_json_end },
        .{ .need = 11 },
    };
    for (records) |record| {
        var ops: Ops = .{};
        try ops.record(record);
        const tag = std.enums.fromInt(RecordTag, ops.bytes[0]).?;
        try std.testing.expectEqual(recordSize(tag), ops.length);
        var reader = ops.records();
        try std.testing.expectEqualDeep(record, (try reader.next()).?);
        try std.testing.expectEqual(@as(?Record, null), try reader.next());
        // A record cut short is malformed.
        var cut: RecordReader = .{ .bytes = ops.bytes[0 .. ops.length - 1] };
        if (ops.length > 1) try std.testing.expectError(error.CodecBadOp, cut.next());
    }
}
