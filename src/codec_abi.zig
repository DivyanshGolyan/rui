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
    /// which the codec writes by a content op so the Host escapes it.
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

/// How the Host writes a handle's bytes. A pinned codec version always gets
/// the same bytes: a `_v1` mode never changes.
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
};

pub const Op = union(OpTag) {
    literal: []const u8,
    content: struct { handle: u8, escape: Escape },
    carry: Carry,
};

pub const Status = enum(u8) {
    /// The item is encoded; its ops are ready.
    next = 0,
    /// The request is complete (request_end only).
    done = 1,
    /// The codec cannot encode this request.
    failed = 2,
};

/// The ops a codec writes for one item.
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
};

/// Decodes ops; anything malformed is `error.CodecBadOp`.
pub const Reader = struct {
    bytes: []const u8,
    offset: u16,

    pub fn next(self: *Reader) error{CodecBadOp}!?Op {
        const rest = self.bytes[self.offset..];
        if (rest.len == 0) return null;
        const tag = std.enums.fromInt(OpTag, rest[0]) orelse return error.CodecBadOp;
        switch (tag) {
            .literal => {
                if (rest.len < 3) return error.CodecBadOp;
                const count = std.mem.readInt(u16, rest[1..3], .little);
                if (count == 0 or rest.len - 3 < count) return error.CodecBadOp;
                self.offset += 3 + count;
                return .{ .literal = rest[3..][0..count] };
            },
            .content => {
                if (rest.len < 3) return error.CodecBadOp;
                const escape = std.enums.fromInt(Escape, rest[2]) orelse return error.CodecBadOp;
                self.offset += 3;
                return .{ .content = .{ .handle = rest[1], .escape = escape } };
            },
            .carry => {
                if (rest.len < 2 or rest[1] > max_carry_bytes or rest.len - 2 < rest[1]) return error.CodecBadOp;
                self.offset += 2 + rest[1];
                return .{ .carry = .of(rest[2..][0..rest[1]]) };
            },
        }
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
