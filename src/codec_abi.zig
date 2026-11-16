const std = @import("std");

pub const ObservedHeaders = struct {
    request_id: []const u8 = "",
    model: []const u8 = "",
    alternate_model: []const u8 = "",
    turn_state: []const u8 = "",
};

pub const ItemKind = enum(u8) {
    settings,
    instructions,
    message,
    output_open,
    output_part,
    output_close,
    tool_result,
    operation,
    effort_update,
    declare_open,
    declared_tool,
    declare_close,
    history_end,
    compaction_trigger,
    tools_start,
    tool,
    web_search,
    text_format,
    request_end,

    image_message_open,
    input_text,
    input_image,
    image_message_close,
    image_tool_open,
    image_tool_close,

    pub fn resumes(self: ItemKind) bool {
        return switch (self) {
            .image_message_open, .image_tool_open, .message, .output_open, .tool_result, .operation, .effort_update, .declare_open, .history_end => true,
            else => false,
        };
    }

    pub fn endsElement(self: ItemKind) bool {
        return switch (self) {
            .image_message_close, .image_tool_close, .message, .output_close, .tool_result, .operation, .effort_update, .declare_close => true,
            else => false,
        };
    }
};

pub const Effort = enum(u8) { none, low, medium, high, xhigh, max };
pub const Author = enum(u8) { user, instruction };
pub const OutputKind = enum(u8) { reasoning = 1, message = 2, function_call = 3, compaction = 4, web_search_call = 5 };
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
        omit_reasoning_text: bool,
    },
    output_part: struct { array: PartArray, kind: PartKind },
    output_close,
    tool_result,
    operation: ?Effort,
    effort_update: Effort,
    declare_open,
    declared_tool,
    declare_close,
    history_end,
    compaction_trigger,
    tools_start,
    tool,
    web_search,
    text_format,
    request_end,
    image_message_open: Author,
    input_text,
    input_image: ImageMime,
    image_message_close,
    image_tool_open,
    image_tool_close,
};

pub const ImageMime = enum(u8) { png, jpeg };

pub const max_handles = 3;
pub const max_model_bytes = 256;

pub const Settings = struct {
    effort: ?Effort,
    starting_effort: ?Effort = null,
    session_affinity: [16]u8,
    model_length: u16,
    model: [max_model_bytes]u8 = undefined,

    pub fn modelName(self: *const Settings) []const u8 {
        return self.model[0..self.model_length];
    }
};

pub const ItemHeader = struct {
    item: Item,
    handles: u8,

    pub fn has(self: *const ItemHeader, handle: u8) bool {
        return handle < max_handles and self.handles >> @intCast(handle) & 1 == 1;
    }
};

pub const Escape = enum(u8) {
    verbatim = 0,
    json_string_v1 = 1,
};

pub const Piece = union(enum) {
    literal: []const u8,
    content: struct { handle: u8, escape: Escape },
    base64: u8,
};

pub const max_pieces = 8;

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

    pub fn base64(self: *Pieces, handle: u8) void {
        self.push(.{ .base64 = handle });
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
pub const max_request_header_bytes = 192;

pub const Headers = struct {
    count: u8,
    names: [max_request_headers]u8 = undefined,
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

    pub fn valueBytes(self: *const Headers) usize {
        return if (self.count == 0) 0 else self.ends[self.count - 1];
    }
};

pub const Refusal = enum(u8) {
    quota = 0,
    plan = 1,
    policy = 2,
    model_unavailable = 3,
};

pub const ReportRange = struct {
    escape: Escape,
    start: u64,
    length: u64,
};

pub const ErrorBody = struct {
    context_overflow: bool,
    refusal: ?Refusal,
    resets_at: ?u64,
    report: struct { code: ?ReportRange, message: ?ReportRange },
};

pub const Operation = enum(u8) { assistant_response = 0, compaction = 1 };

pub const Stage = enum(u8) { stream = 0, event = 1, item = 2, response = 3 };

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
    unexpected_json_end,
    invalid_json_string,
    invalid_json_escape,
    invalid_json_surrogate,
    invalid_json_utf8,
    invalid_json_number,
    invalid_json_value,
    json_too_deep,
};

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

pub const Usage = struct { uncached: u64, cache_read: u64, cache_write: u64, output: u64 };

pub const Range = struct { start: u64, length: u64 };

pub const At = struct { stage: Stage, output_index: ?u64 };

pub const Cursor = struct {
    offset: u64,
    scope: enum(u8) { item, array, part, output },
    kind: OutputKind,
    phase: Phase,
    array: PartArray,
    text: Range,
};

pub const OutputItem = struct {
    kind: OutputKind,
    phase: Phase,
    answer_phase: Phase,
    omit_reasoning_text: bool,
    whole: Range,
    id: Range,
    call: [3]Range,
    members: Cursor,
};

pub const HostedAction = enum(u8) { none = 0, search = 1, open_page = 2, find_in_page = 3 };
pub const HostedCall = struct {
    action: HostedAction = .none,
    target: ?Range = null,
    pattern: ?Range = null,
    failed: bool = false,
};

pub const Completed = struct {
    check: ?Reason,
    response_id: Range,
    served_model: ?Range,
    output: Cursor,
    usage: union(enum) {
        absent,
        report: struct { whole: Range, counts: ?Usage },
        failed: Reason,
    },
};

pub const Failed = struct {
    reason: Reason,
    refusal: ?Refusal,
    report: struct { code: ?ReportRange, message: ?ReportRange },
};

pub const Event = struct {
    at: At,
    what: union(enum) {
        other,
        done_marker,
        added: struct { kind: OutputKind, id: Range },
        item: OutputItem,
        completed: Completed,
        failed: Failed,
    },
};

pub const Member = union(enum) {
    bag: Range,
    part: struct { array: PartArray, kind: PartKind, text: Range },
    part_end,
    terminal: struct { kind: OutputKind, whole: Range, id: Range },
    terminal_failed: Reason,
};

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

pub fn lowercaseToken(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!lowercaseTokenByte(byte)) return false;
    return true;
}

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
