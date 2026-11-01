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

pub const Status = enum(u8) {
    /// The window is read; its findings are ready.
    next = 0,
    /// The body is classified.
    done = 1,
    /// The codec cannot classify this body.
    failed = 2,
};

/// The findings a codec writes for one window.
pub const Ops = struct {
    pub const capacity = 256;

    length: u16 = 0,
    bytes: [capacity]u8 = undefined,

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

    fn reserve(self: *Ops, count: usize) error{OpsOverflow}![]u8 {
        if (capacity - self.length < count) return error.OpsOverflow;
        defer self.length += @intCast(count);
        return self.bytes[self.length..][0..count];
    }

    /// Reads these ops as findings, from the first op.
    pub fn findings(self: *const Ops) FindingReader {
        return .{ .bytes = self.bytes[0..self.length] };
    }
};

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
