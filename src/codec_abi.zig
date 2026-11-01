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

// ---------------------------------------------------------------- encode
//
// The Host walks a request's neutral items in order and gives the codec one
// `ItemHeader` at a time. The codec answers each with `Pieces`, which the
// Host writes in place before it asks for the next item. Rui's bulk text
// never enters the codec: an item names its content by handle, and a
// `content` piece streams a handle into the request under a pinned escape.
//
// Append-only: the bytes of the history items, from the first history item
// to `history_end`, are the span a later request of the Session begins with.
// The codec's state at each history-element boundary is exactly its carry,
// a value of the codec's own type: the Host resumes the codec from the last
// carry before every element and before `history_end`, whether that carry
// came from the previous element or from a history memo, so a memo copy and
// a rebuild continue identically. Anything that depends on being last comes
// after `history_end`.

/// The neutral items of a request, in the order the Host yields them:
/// settings, instructions, the history items, history_end,
/// compaction_trigger (compaction requests only), tools_start, one tool per
/// enabled tool, text_format, request_end.
pub const ItemKind = enum(u8) {
    /// The frozen settings, the model included. Handle 0: that same model,
    /// which the codec writes by a content piece so the Host escapes it.
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

    /// The items the Host resumes the codec from its carry before.
    pub fn resumes(self: ItemKind) bool {
        return switch (self) {
            .message, .output_open, .tool_result, .history_end => true,
            else => false,
        };
    }

    /// The items that end a history element, after which the Host keeps
    /// the codec's carry.
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

/// Frozen request settings, carried by the settings item and read by a
/// codec's request headers.
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

/// One stretch of an item's encoding.
pub const Piece = union(enum) {
    /// The codec's constant bytes, at least one.
    literal: []const u8,
    /// One of the item's handles, whole, escaped.
    content: struct { handle: u8, escape: Escape },
};

/// The most pieces one item takes, across every codec this contract
/// serves.
pub const max_pieces = 8;

/// The pieces a codec writes for one item, in order.
pub const Pieces = struct {
    len: u8,
    items: [max_pieces]Piece = undefined,

    pub fn literal(self: *Pieces, bytes: []const u8) void {
        std.debug.assert(bytes.len != 0);
        self.push(.{ .literal = bytes });
    }

    pub fn content(self: *Pieces, handle: u8, escape: Escape) void {
        self.push(.{ .content = .{ .handle = handle, .escape = escape } });
    }

    fn push(self: *Pieces, piece: Piece) void {
        std.debug.assert(self.len < max_pieces);
        self.items[self.len] = piece;
        self.len += 1;
    }

    pub fn slice(self: *const Pieces) []const Piece {
        return self.items[0..self.len];
    }
};

pub const max_request_headers = 8;
/// The values together; the prepared request stores this many bytes.
pub const max_request_header_bytes = 192;

/// A codec's request headers, in the order it gives them, which the Host
/// sends ahead of its own fields. Each name is a tag of the codec's own
/// `RequestHeader` enum, whose tag names are lowercase tokens, and each
/// value is header-safe (`headerValue`); none names a field the Host or h2
/// writes itself.
pub const Headers = struct {
    count: u8,
    /// Each header's `RequestHeader` tag, as its integer.
    names: [max_request_headers]u8 = undefined,
    /// Where each value ends in `bytes`; each begins where the previous
    /// one ends.
    ends: [max_request_headers]u8 = undefined,
    bytes: [max_request_header_bytes]u8 = undefined,

    comptime {
        std.debug.assert(max_request_header_bytes <= std.math.maxInt(u8));
    }

    pub fn add(self: *Headers, name: anytype, text: []const u8) void {
        comptime std.debug.assert(@typeInfo(@TypeOf(name)) == .@"enum");
        std.debug.assert(self.count < max_request_headers);
        const start = self.valueBytes();
        std.debug.assert(text.len <= max_request_header_bytes - start);
        @memcpy(self.bytes[start..][0..text.len], text);
        self.names[self.count] = @backingInt(name);
        self.ends[self.count] = @intCast(start + text.len);
        self.count += 1;
    }

    pub fn value(self: *const Headers, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        return self.bytes[if (index == 0) 0 else self.ends[index - 1]..self.ends[index]];
    }

    /// The bytes the values take together.
    pub fn valueBytes(self: *const Headers) usize {
        return if (self.count == 0) 0 else self.ends[self.count - 1];
    }
};

// -------------------------------------------------------------- classify
//
// The Host gives the codec an HTTP error body whole, as one read-only slice,
// and the codec answers with an `ErrorBody`, naming the report's text by
// range of that slice. What it names can only narrow the failure the Host's
// status rules give, and every narrowing settles the Attempt as a failure no
// retry can fix, so a codec can never make a failure retryable. The Host
// keeps every status rule, decides which narrowing applies, and maps each
// code through its own closed sets, so a code it does not know narrows
// nothing.

/// The longest provider code an `ErrorBody` carries. Every code the Host
/// knows is shorter, so a codec leaves a longer one out.
pub const max_code_bytes = 64;

/// A provider code, at least one byte.
pub const Code = struct {
    len: u8,
    bytes: [max_code_bytes]u8 = undefined,

    pub fn of(text: []const u8) Code {
        std.debug.assert(text.len != 0 and text.len <= max_code_bytes);
        var code: Code = .{ .len = @intCast(text.len) };
        @memcpy(code.bytes[0..text.len], text);
        return code;
    }

    pub fn slice(self: *const Code) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Where one part of the report is, as a range of the body. With
/// `json_string_v1` the range holds the contents of a JSON string, without
/// its quotes, which the Host decodes; with `verbatim` it holds the text
/// itself.
pub const ReportRange = struct {
    escape: Escape,
    start: u64,
    length: u64,
};

/// What a codec read in an error body. A body it cannot read names nothing.
pub const ErrorBody = struct {
    /// The request exceeds the model's context.
    context_overflow: bool,
    /// Any other code the error names, which the Host reads as a quota or a
    /// refusal if it knows it as one.
    code: ?Code,
    /// The Unix second a quota resets, when the provider gives one.
    resets_at: ?u64,
    /// The two parts of the report, `code: message`.
    report: struct { code: ?ReportRange, message: ?ReportRange },
};

// ------------------------------------------------------------- interpret
//
// The Host frames a sealed response stream's server-sent events itself and
// gives the codec each event's data whole, as one read-only slice, with the
// codec's `Stream` state. The codec answers with an `Event`: its verdict and
// the ranges of that slice the Host decodes, hashes and records. For an
// accepted item, and for a completed response's output list, the Host walks
// the members in document order with `nextMember`, one `Member` at a time
// from a `Cursor`. The codec judges the provider's grammar; the Host keeps
// every rule across items, maps each `Reason` to its saved code and kind,
// and never lets a codec decide either.

/// What the response answers, which decides which items it may hold.
pub const Operation = enum(u8) { assistant_response = 0, compaction = 1 };

/// Where in the stream a verdict stands, for its diagnostic coordinates.
/// `stream` keeps the coordinates of the line the Host frames.
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
    /// The provider reported a failure; a refusal code the Host knows makes
    /// it permanent.
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

/// Rui's four token counts.
pub const Usage = struct { uncached: u64, cache_read: u64, cache_write: u64, output: u64 };

/// Bytes of the event data the call was given.
pub const Range = struct { start: u64, length: u64 };

/// Where an event's verdict stands.
pub const At = struct { stage: Stage, output_index: ?u64 };

/// Where a walk reads next, which the Host keeps between `nextMember` calls.
pub const Cursor = struct {
    /// The offset in the event data of the next byte the walk reads.
    offset: u64,
    scope: enum(u8) { item, array, part, output },
    /// The item's kind and the phase Rui's form holds of it, and the array
    /// and the text member of the part the scope is in, as far as it is.
    kind: OutputKind,
    phase: Phase,
    array: PartArray,
    text: Range,
};

/// An output item the codec accepted. (`Item` is a request's.)
pub const OutputItem = struct {
    kind: OutputKind,
    /// The phase Rui's form holds, and the one answer selection reads.
    phase: Phase,
    answer_phase: Phase,
    omit_reasoning_text: bool,
    whole: Range,
    /// The contents of the id string, and of a function call's name,
    /// call_id and arguments strings.
    id: Range,
    call: [3]Range,
    /// The walk over its members.
    members: Cursor,
};

/// A completed response, the stages after the Host's completion gate.
pub const Completed = struct {
    /// The verdict on the response's status, id, model and output list.
    check: ?Reason,
    /// The contents of the id string, and of the model string unless it is
    /// absent or null.
    response_id: Range,
    served_model: ?Range,
    /// The walk over the output list.
    output: Cursor,
    usage: union(enum) {
        absent,
        report: struct { whole: Range, counts: ?Usage },
        failed: Reason,
    },
};

pub const Failed = struct {
    reason: Reason,
    /// A reported failure's code, when it is at most `max_code_bytes`.
    refusal: ?Code,
    report: struct { code: ?ReportRange, message: ?ReportRange },
};

/// The codec's answer to one event.
pub const Event = struct {
    at: At,
    what: union(enum) {
        other,
        done_marker,
        /// The next item is announced; `id` holds its id string's contents.
        added: struct { kind: OutputKind, id: Range },
        item: OutputItem,
        completed: Completed,
        failed: Failed,
    },
};

/// One step of a walk, in document order.
pub const Member = union(enum) {
    /// A `"key":value` member of the open item's or part's provider bag.
    bag: Range,
    /// A part of the open item begins; its bag members follow. `text` holds
    /// its text string's contents.
    part: struct { array: PartArray, kind: PartKind, text: Range },
    part_end,
    /// One element of a completed response's output list, and its id
    /// string's contents.
    terminal: struct { kind: OutputKind, whole: Range, id: Range },
    /// One element of the output list that is not an item.
    terminal_failed: Reason,
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
