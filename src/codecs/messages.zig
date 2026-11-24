//! The `anthropic-messages/1` codec: Anthropic's Messages API, streamed.
//!
//! A functional core: imports only std, codec_abi and codecs/json.zig, and names
//! no model and no provider. It is served by codecs.zig, but no provider pins it yet.
//! `compacts` is false for it: this wire has no provider compaction, so a compaction
//! Operation is never admitted to it (see docs/contracts/model-io.md).
//!
//! Stream interpretation has two steps, using Unit 1's `normalize` hook:
//!   normalize:      raw SSE events -> fragments that assemble whole events. A
//!                   content block arrives as many deltas; its fragments build one
//!                   block object, and `content_block_stop` makes it one whole event.
//!                   `message_stop` is one whole `rui.completed` event built from
//!                   the Stream. `error` is one whole event copied verbatim. A
//!                   violation is one whole `rui.invalid` event. Either one that
//!                   arrives inside an open block discards that block first (the
//!                   normalized `discard`), so it is classified as it is between
//!                   blocks. `message_start`, `message_delta`, `ping` and unknown
//!                   types add nothing.
//!   interpretEvent: reads only whole events and answers the grammar. An open block
//!                   at the end of the stream is the codec's `finish` to name.
//!
//! Document shapes assembled by normalize. Concatenating the escaped bodies of
//! JSON strings yields the escaped body of the concatenated string, so every
//! assembled string is a sequence of spans with no decoding:
//!   {"type":"thinking","thinking":"<Σ thinking_delta>","signature":"<Σ signature_delta>"}
//!   {"type":"redacted_thinking","data":"…"}            (copied whole from content_block_start)
//!   {"type":"text","text":"<Σ text_delta>"}
//!   {"type":"tool_use","id":"…","name":"…","input_json":"<Σ partial_json>"}
//!   {"type":"rui.completed","id":"…","model":"…","stop_reason":"…"[,"refusal":{…}],"usage":{…}}
//!   {"type":"rui.invalid","reason":"<Reason tag>"}
//!
//! `input_json` is a JSON string whose decoded value is the arguments' JSON text,
//! exactly what Responses stores for `arguments`: one neutral form for both families.

const std = @import("std");
const codec_abi = @import("../codec_abi.zig");
const json = @import("json.zig");

const Range = codec_abi.Range;
const Reason = codec_abi.Reason;

pub const dialect: codec_abi.Dialect = .anthropic_messages;

pub const manifest: codec_abi.Manifest = .{
    .observe = .{
        // Anthropic's correlation header. No served-model header (the served
        // model is `message.model` in `message_start`) and no turn routing.
        .request_id = "request-id",
    },
};

/// Protocol headers only. The credential header is not the codec's: it is
/// `Authorization: Bearer` on a gateway and `x-api-key` on
/// Anthropic's own API, a fact of the connection (#1862, connection_needs.zig).
pub const RequestHeader = enum(u8) { accept, @"anthropic-version" };

pub fn requestHeaders(settings: *const codec_abi.Settings, out: *codec_abi.Headers) void {
    _ = settings;
    out.count = 0;
    out.add(RequestHeader.accept, "text/event-stream");
    out.add(RequestHeader.@"anthropic-version", "2023-06-01");
}

/// Bounds of the copies a Stream keeps. A longer value is a provider fault, not truncated.
const max_id_bytes = 128;
const max_category_bytes = 128;
const max_explanation_bytes = 512;
/// Room for the whole `rui.completed` event, rendered in the Stream.
const max_completed_bytes = 1536;

/// A bounded copy of escaped JSON string contents.
fn Buffer(comptime capacity_bytes: usize) type {
    return struct {
        const capacity = capacity_bytes;
        bytes: [capacity_bytes]u8 = undefined,
        len: u16 = 0,

        fn set(self: *@This(), source: []const u8) void {
            @memcpy(self.bytes[0..source.len], source);
            self.len = @intCast(source.len);
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Stop = enum(u8) { none, end_turn, tool_use, refusal, max_tokens, model_context_window_exceeded, pause_turn, other };

pub const Stream = struct {
    operation: codec_abi.Operation,
    phase: enum(u8) { before_start, started, in_block, between_blocks, stopping, stopped } = .before_start,
    /// Bytes appended since the last whole event: the offsets a whole block's ranges use.
    document: u64 = 0,
    next_index: u64 = 0,
    block: enum(u8) { none, text, thinking, redacted, tool_use } = .none,
    block_index: u64 = 0,
    signature: bool = false,
    /// Bytes of the open tool_use's `input_json` body so far.
    arguments: u64 = 0,
    id: Buffer(max_id_bytes) = .{},
    model: Buffer(codec_abi.max_model_bytes) = .{},
    input: ?u64 = null,
    cache_write: ?u64 = null,
    cache_read: ?u64 = null,
    output: ?u64 = null,
    stop: Stop = .none,
    /// A refusal's `stop_details`: category and explanation, each null when the provider sent null.
    details: struct {
        category: ?Buffer(max_category_bytes) = null,
        explanation: ?Buffer(max_explanation_bytes) = null,
    } = .{},
    scan: Scan = .{},
    reader: json.Reader = undefined,
    tail: [max_completed_bytes]u8 = undefined,
};

pub fn begin(operation: codec_abi.Operation) Stream {
    // A compaction Operation never reaches this codec (`compacts` is false).
    std.debug.assert(operation == .assistant_response);
    return .{ .operation = operation };
}

/// The reason a stream that ends without a whole completion names, or null when it stopped.
pub fn finish(stream: *const Stream) ?Reason {
    return switch (stream.phase) {
        .stopped => null,
        .in_block => .provider_connection_closed,
        else => .incomplete_provider_output,
    };
}

/// This wire has no provider compaction: `compaction_trigger` declines and no Operation is compaction.
pub const compacts = false;

/// This wire declares no tools for a compaction request: `declare_open` declines.
pub fn declaresTools() bool {
    return false;
}

/// Effort is written on each request as top-level `output_config`, not as a history item, so no
/// effort change is ever refused as an item; an invalid effort fails the request like any other 400.
pub fn effortChangeRefused(scratch: *const ClassifyScratch, status: u16, body: []const u8) bool {
    _ = scratch;
    _ = status;
    _ = body;
    return false;
}

// ---------------------------------------------------------------------------
// Request encoding
// ---------------------------------------------------------------------------

/// Resumable state at every history-element boundary (the history memo's carry).
/// The Messages wire groups blocks into alternating role messages, so the carry is
/// "which role message is open and what separator comes next". A memo copy ends
/// inside an open message; the next request resumes there and appends, byte-identical
/// to a rebuild. Closing the open message "depends on being last" and happens at
/// `tools_start`, after `history_end`.
pub const Carry = struct {
    messages: enum(u8) { unopened, first, comma } = .unopened,
    open: Open = .none,
    /// Whether the open message's content array already holds a block.
    block: enum(u8) { first, comma } = .first,
    /// Whether the tools array is open: `tools_start` closes the messages, then `tool` items open it.
    tools_open: bool = false,
    /// Inside an image group, whether a part was written, so the next one needs a comma.
    /// An image group spans several elements, so this is carry, not a fact of one element.
    part_comma: bool = false,
};

const Open = enum(u8) { none, user, assistant };

pub fn initial(starting_effort: ?codec_abi.Effort) Carry {
    _ = starting_effort; // effort is top-level per request on this wire
    return .{};
}

pub const Encoder = struct {
    carry: Carry,
    /// The current Operation's effort, from the last `operation` or `effort_update`
    /// item. It is not carry: it is a fact of this request, not of the span.
    effort: ?codec_abi.Effort = null,
    effort_seen: bool = false,
    item: enum(u8) { none, reasoning, message, call } = .none,
    /// Inside an output item: whether a block was written (message) or a member (reasoning).
    member: bool = false,
    digits: [10]u8 = undefined,

    pub fn encodeItem(self: *Encoder, header: *const codec_abi.ItemHeader, out: *codec_abi.Pieces) error{Declined}!void {
        out.len = 0;
        switch (header.item) {
            .settings => |*settings| {
                // The Messages wire requires max_tokens; an unset limit cannot be sent.
                if (settings.output_limit == 0) return error.Declined;
                out.literal("{\"model\":\"");
                out.content(0, .json_string_v1);
                const digits = std.fmt.bufPrint(&self.digits, "{d}", .{settings.output_limit}) catch unreachable;
                out.literal("\",\"max_tokens\":");
                out.literal(digits);
                out.literal(",\"stream\":true,\"cache_control\":{\"type\":\"ephemeral\"}");
            },
            .message => |author| {
                // The Session's instructions arrive before history_start: they are the top-level system prompt.
                if (author == .instruction and self.carry.messages == .unopened) {
                    out.literal(",\"system\":\"");
                    out.content(0, .json_string_v1);
                    out.literal("\"");
                    return;
                }
                // Mid-history instructions are user text: mid-conversation `role:"system"` messages are refused by some models.
                self.ensure(.user, out);
                out.literal("{\"type\":\"text\",\"text\":\"");
                if (header.has(1)) {
                    out.content(1, .json_string_v1);
                    out.literal("\"},{\"type\":\"text\",\"text\":\"");
                }
                out.content(0, .json_string_v1);
                out.literal("\"}");
            },
            .output_open => |output| {
                self.member = false;
                switch (output.kind) {
                    // A thinking or redacted block: `type` lives in the bag and is written at close.
                    .reasoning => {
                        self.ensure(.assistant, out);
                        out.literal("{");
                        self.item = .reasoning;
                    },
                    // A message's block opens at its first part, so an empty message writes nothing.
                    .message => self.item = .message,
                    .function_call => {
                        self.ensure(.assistant, out);
                        out.literal("{\"type\":\"tool_use\",\"id\":\"");
                        out.content(1, .json_string_v1);
                        out.literal("\",\"name\":\"");
                        out.content(0, .json_string_v1);
                        out.literal("\",\"input\":");
                        out.content(2, .verbatim);
                        self.item = .call;
                    },
                    // Neither is produced by this family, and replay omits them across families.
                    .compaction, .web_search_call => return error.Declined,
                }
            },
            .output_part => |part| switch (self.item) {
                .reasoning => {
                    if (part.kind != .reasoning_text or !header.has(0)) return error.Declined;
                    out.literal("\"thinking\":\"");
                    out.content(0, .json_string_v1);
                    out.literal("\"");
                    self.member = true;
                },
                .message => {
                    if (part.kind != .output_text and part.kind != .refusal) return error.Declined;
                    if (!header.has(0)) return error.Declined; // opaque parts never reach a foreign family
                    if (self.member) {
                        out.literal("},{\"type\":\"text\",\"text\":\"");
                    } else {
                        self.ensure(.assistant, out);
                        out.literal("{\"type\":\"text\",\"text\":\"");
                    }
                    out.content(0, .json_string_v1);
                    out.literal("\"");
                    self.member = true;
                },
                .call, .none => return error.Declined,
            },
            .output_close => {
                switch (self.item) {
                    // thinking: `"thinking":…` then the bag (`"type":"thinking","signature":…`);
                    // redacted: the bag alone, which carries the whole block.
                    .reasoning => {
                        if (!self.member and !header.has(0)) return error.Declined;
                        if (header.has(0)) {
                            if (self.member) out.literal(",");
                            out.content(0, .verbatim);
                        }
                        out.literal("}");
                    },
                    // A message with no block wrote nothing, so closing it writes nothing.
                    .message => if (self.member) {
                        if (header.has(0)) {
                            out.literal(",");
                            out.content(0, .verbatim);
                        }
                        out.literal("}");
                    },
                    .call => {
                        if (header.has(0)) {
                            out.literal(",");
                            out.content(0, .verbatim);
                        }
                        out.literal("}");
                    },
                    .none => return error.Declined,
                }
                self.item = .none;
                self.member = false;
            },
            .tool_result => {
                self.ensure(.user, out);
                out.literal("{\"type\":\"tool_result\",\"tool_use_id\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"content\":\"");
                out.content(1, .json_string_v1);
                out.literal("\"}");
            },
            .image_message_open => |author| {
                _ = author; // both authors are user content on this wire
                // ensure() already wrote the separator for the first part.
                self.ensure(.user, out);
                self.carry.part_comma = false;
            },
            .image_message_close => {},
            .image_tool_open => {
                self.ensure(.user, out);
                self.carry.part_comma = false;
                out.literal("{\"type\":\"tool_result\",\"tool_use_id\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"content\":[");
            },
            .image_tool_close => {
                out.literal("]}");
            },
            .input_text => {
                self.partSeparator(out);
                out.literal("{\"type\":\"text\",\"text\":\"");
                out.content(0, .json_string_v1);
                out.literal("\"}");
            },
            .input_image => |mime| {
                self.partSeparator(out);
                out.literal(switch (mime) {
                    .png => "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"",
                    .jpeg => "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"",
                });
                out.base64(0);
                out.literal("\"}}");
            },
            // Effort is top-level on this wire, so an effort change costs the cache, as on `openai-responses/3`.
            .operation => |effort| {
                self.effort = effort;
                self.effort_seen = true;
            },
            .effort_update => |effort| {
                self.effort = effort;
                self.effort_seen = true;
            },
            .declare_open, .declared_tool, .declare_close => return error.Declined,
            .history_start => if (self.carry.messages == .unopened) {
                out.literal(",\"messages\":[");
                self.carry.messages = .first;
            },
            .history_end => {},
            // No provider compaction on this wire (`compacts` is false).
            .compaction_trigger => return error.Declined,
            .tools_start => {
                // The history needs a message; the open message closes here, then the array.
                if (self.carry.messages != .comma) return error.Declined;
                out.literal(if (self.carry.open != .none) "]}]" else "]");
                self.carry.open = .none;
                self.carry.tools_open = false;
            },
            .tool => {
                out.literal(if (self.carry.tools_open) "," else ",\"tools\":[");
                self.carry.tools_open = true;
                out.literal("{\"name\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"description\":\"");
                out.content(1, .json_string_v1);
                out.literal("\",\"input_schema\":");
                out.content(2, .verbatim);
                out.literal("}");
            },
            // Hosted web search is a connection fact; no Messages connection runs it.
            .web_search => return error.Declined,
            .text_format => {
                // Decline before writing anything: a declined item must leave no partial output.
                if (!self.effort_seen) return error.Declined;
                if (self.carry.tools_open) {
                    out.literal("]");
                    self.carry.tools_open = false;
                }
                const schema = header.has(0);
                if (self.effort) |effort| out.literal(if (effort == .none) ",\"thinking\":{\"type\":\"disabled\"}" else ",\"thinking\":{\"type\":\"adaptive\"}");
                const effort_config: ?codec_abi.Effort = if (self.effort) |effort| if (effort == .none) null else effort else null;
                if (effort_config) |effort| {
                    if (schema) {
                        out.literal(effortWithSchema(effort));
                        out.content(0, .verbatim);
                        out.literal("}}");
                    } else out.literal(effortOnly(effort));
                } else if (schema) {
                    out.literal(",\"output_config\":{\"format\":{\"type\":\"json_schema\",\"schema\":");
                    out.content(0, .verbatim);
                    out.literal("}}");
                }
            },
            .request_end => out.literal("}"),
        }
    }

    /// Makes `role` the open message and writes the separator its next block needs.
    /// Consecutive same-role elements (tool results then a user message, or a
    /// reasoning item then a call) share one message, which also keeps all of one
    /// response's tool results in one user message, as the wire requires, and a
    /// thinking block ahead of its tool_use.
    fn ensure(self: *Encoder, role: Open, out: *codec_abi.Pieces) void {
        if (self.carry.open == role) {
            if (self.carry.block == .comma) out.literal(",");
            self.carry.block = .comma;
            return;
        }
        if (self.carry.open != .none) {
            out.literal("]},");
        } else if (self.carry.messages == .comma) {
            out.literal(",");
        }
        out.literal(switch (role) {
            .user => "{\"role\":\"user\",\"content\":[",
            .assistant => "{\"role\":\"assistant\",\"content\":[",
            .none => unreachable,
        });
        self.carry.open = role;
        self.carry.messages = .comma;
        self.carry.block = .comma;
    }

    /// Separates the parts of one image group (a user message's or a tool result's content).
    fn partSeparator(self: *Encoder, out: *codec_abi.Pieces) void {
        if (self.carry.part_comma) out.literal(",");
        self.carry.part_comma = true;
    }
};

fn effortOnly(effort: codec_abi.Effort) []const u8 {
    return switch (effort) {
        inline else => |value| comptime ",\"output_config\":{\"effort\":\"" ++ @tagName(value) ++ "\"}",
    };
}

fn effortWithSchema(effort: codec_abi.Effort) []const u8 {
    return switch (effort) {
        inline else => |value| comptime ",\"output_config\":{\"effort\":\"" ++ @tagName(value) ++ "\",\"format\":{\"type\":\"json_schema\",\"schema\":",
    };
}

// ---------------------------------------------------------------------------
// Scanning one raw or whole event
// ---------------------------------------------------------------------------

/// A named position in an event: one object path, at most three keys deep. Raw
/// stream events and whole events share the table; a path is matched only where it occurs.
const Slot = enum {
    type,
    index,
    content_block,
    block_type,
    block_id,
    block_name,
    block_text,
    block_thinking,
    block_data,
    delta_type,
    delta_text,
    delta_thinking,
    delta_signature,
    delta_partial_json,
    delta_stop_reason,
    delta_stop_details,
    stop_details_category,
    stop_details_explanation,
    message_id,
    message_model,
    message_input,
    message_cache_write,
    message_cache_read,
    usage,
    usage_input,
    usage_cache_write,
    usage_cache_read,
    usage_output,
    error_type,
    error_message,
    error_code,
    id,
    name,
    input_json,
    text,
    thinking,
    signature,
    data,
    model,
    stop_reason,
    refusal,
    refusal_category,
    refusal_explanation,
    reason,
};

fn pathOf(slot: Slot) []const []const u8 {
    return switch (slot) {
        .type => &.{"type"},
        .index => &.{"index"},
        .content_block => &.{"content_block"},
        .block_type => &.{ "content_block", "type" },
        .block_id => &.{ "content_block", "id" },
        .block_name => &.{ "content_block", "name" },
        .block_text => &.{ "content_block", "text" },
        .block_thinking => &.{ "content_block", "thinking" },
        .block_data => &.{ "content_block", "data" },
        .delta_type => &.{ "delta", "type" },
        .delta_text => &.{ "delta", "text" },
        .delta_thinking => &.{ "delta", "thinking" },
        .delta_signature => &.{ "delta", "signature" },
        .delta_partial_json => &.{ "delta", "partial_json" },
        .delta_stop_reason => &.{ "delta", "stop_reason" },
        .delta_stop_details => &.{ "delta", "stop_details" },
        .stop_details_category => &.{ "delta", "stop_details", "category" },
        .stop_details_explanation => &.{ "delta", "stop_details", "explanation" },
        .message_id => &.{ "message", "id" },
        .message_model => &.{ "message", "model" },
        .message_input => &.{ "message", "usage", "input_tokens" },
        .message_cache_write => &.{ "message", "usage", "cache_creation_input_tokens" },
        .message_cache_read => &.{ "message", "usage", "cache_read_input_tokens" },
        .usage => &.{"usage"},
        .usage_input => &.{ "usage", "input_tokens" },
        .usage_cache_write => &.{ "usage", "cache_creation_input_tokens" },
        .usage_cache_read => &.{ "usage", "cache_read_input_tokens" },
        .usage_output => &.{ "usage", "output_tokens" },
        .error_type => &.{ "error", "type" },
        .error_message => &.{ "error", "message" },
        .error_code => &.{ "error", "details", "error_code" },
        .id => &.{"id"},
        .name => &.{"name"},
        .input_json => &.{"input_json"},
        .text => &.{"text"},
        .thinking => &.{"thinking"},
        .signature => &.{"signature"},
        .data => &.{"data"},
        .model => &.{"model"},
        .stop_reason => &.{"stop_reason"},
        .refusal => &.{"refusal"},
        .refusal_category => &.{ "refusal", "category" },
        .refusal_explanation => &.{ "refusal", "explanation" },
        .reason => &.{"reason"},
    };
}

const max_path = 3;
const max_key_bytes = 32;

/// What one slot's value was: how often it occurred, its shape and its place.
const Member = struct {
    count: u8 = 0,
    kind: json.Kind = .literal,
    literal: ?json.Literal = null,
    /// Where the value began (its opening byte).
    start: u64 = 0,
    /// Strings: the escaped contents. Other values: the whole value.
    range: Range = .{ .start = 0, .length = 0 },
    digits: json.Digits = .plain,
    integer: ?u64 = null,
    /// The decoded text of a string, kept when it is short enough.
    text: [json.max_text_bytes]u8 = undefined,
    text_len: ?u8 = null,

    /// The decoded text of a string member, or null when it is not a short string.
    fn decoded(self: *const Member) ?[]const u8 {
        if (self.kind != .string) return null;
        return self.text[0..(self.text_len orelse return null)];
    }

    /// The value of a plain, non-negative integer that fits the counts Rui keeps, else null.
    fn plainCount(self: *const Member) ?u64 {
        if (self.count != 1 or self.kind != .number or self.digits != .plain) return null;
        const value = self.integer orelse return null;
        return if (value > std.math.maxInt(i64)) null else value;
    }
};

/// Walks one event: the keys at each depth, which slot each open value belongs to,
/// and every slot's value.
const Scan = struct {
    const unmatched: u8 = 0xff;

    /// Decoded key text at each depth. `unmatched` where the key is too long or
    /// the value sits inside an array.
    keys: [max_path + 1][max_key_bytes]u8 = undefined,
    key_len: [max_path + 1]u8 = @splat(unmatched),
    current: [max_path + 1]?Slot = @splat(null),
    values: std.enums.EnumArray(Slot, Member) = .initFill(.{}),

    pub fn key(self: *Scan, reader: *const json.Reader, depth: u8) void {
        if (depth == 0 or depth > max_path) return;
        const text = reader.text() orelse {
            self.key_len[depth] = unmatched;
            return;
        };
        if (text.len > max_key_bytes) {
            self.key_len[depth] = unmatched;
            return;
        }
        @memcpy(self.keys[depth][0..text.len], text);
        self.key_len[depth] = @intCast(text.len);
    }

    pub fn begin(self: *Scan, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth == 0 or depth > max_path) return;
        // An element of an array has no key of its own: a stale key must not match it.
        if (reader.arrays.isSet(depth - 1)) self.key_len[depth] = unmatched;
        const slot = self.slotAt(depth) orelse {
            self.current[depth] = null;
            return;
        };
        self.current[depth] = slot;
        const member = self.values.getPtr(slot);
        member.count +|= 1;
        member.kind = kind;
        member.start = reader.offset;
        member.literal = null;
    }

    pub fn end(self: *Scan, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth == 0 or depth > max_path) return;
        const slot = self.current[depth] orelse return;
        self.current[depth] = null;
        const member = self.values.getPtr(slot);
        member.kind = kind;
        switch (kind) {
            .string => {
                member.range = reader.string();
                member.text_len = null;
                if (reader.text()) |text| {
                    @memcpy(member.text[0..text.len], text);
                    member.text_len = @intCast(text.len);
                }
            },
            .number => {
                member.range = .{ .start = member.start, .length = reader.offset - member.start };
                member.digits = reader.digits;
                member.integer = reader.integer;
            },
            .literal => {
                member.range = .{ .start = member.start, .length = reader.offset + 1 - member.start };
                member.literal = reader.literalValue();
            },
            .object, .array => member.range = .{ .start = member.start, .length = reader.offset + 1 - member.start },
        }
    }

    fn slotAt(self: *const Scan, depth: u8) ?Slot {
        inline for (@typeInfo(Slot).@"enum".field_names) |name| {
            const slot: Slot = @field(Slot, name);
            const path = comptime pathOf(slot);
            if (path.len == depth and self.matches(path)) return slot;
        }
        return null;
    }

    fn matches(self: *const Scan, path: []const []const u8) bool {
        for (path, 1..) |name, depth| {
            const length = self.key_len[depth];
            if (length == unmatched or length != name.len) return false;
            if (!std.mem.eql(u8, self.keys[depth][0..length], name)) return false;
        }
        return true;
    }
};

fn scanEvent(stream: *Stream, data: []const u8) anyerror!void {
    stream.scan = .{};
    try stream.reader.read(data, &stream.scan);
}

fn reasonError(reason: Reason) anyerror {
    @setEvalBranchQuota(100_000);
    return switch (reason) {
        inline else => |known| blk: {
            const name = comptime codec_abi.reasonName(known);
            break :blk @field(anyerror, name);
        },
    };
}

/// The reason an error names: a Reason this codec returns, or the JSON reader's own
/// error names, which are Reason tags too. Anything else is a malformed output.
fn reasonOf(err: anyerror) Reason {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Reason).@"enum".field_names) |name| {
        const reason = @field(Reason, name);
        if (err == reasonError(reason)) return reason;
    }
    return .malformed_provider_output;
}

/// A required member: present exactly once, or the reason it is not.
fn required(scan: *const Scan, slot: Slot) anyerror!*const Member {
    const member = scan.values.getPtrConst(slot);
    return switch (member.count) {
        0 => reasonError(.missing_provider_field),
        1 => member,
        else => reasonError(.duplicate_json_field),
    };
}

/// An optional member: null when absent, the member when present once.
fn optional(scan: *const Scan, slot: Slot) anyerror!?*const Member {
    const member = scan.values.getPtrConst(slot);
    return switch (member.count) {
        0 => null,
        1 => member,
        else => reasonError(.duplicate_json_field),
    };
}

/// A required string's escaped contents.
fn contents(scan: *const Scan, slot: Slot) anyerror!Range {
    const member = try required(scan, slot);
    if (member.kind != .string) return reasonError(.expected_json_string);
    return member.range;
}

/// A required member's plain integer, which must equal `expected`.
fn expectIndex(scan: *const Scan, slot: Slot, expected: u64) anyerror!void {
    const member = try required(scan, slot);
    if (member.plainCount() != expected) return reasonError(.invalid_provider_index);
}

fn rangeBytes(data: []const u8, range: Range) []const u8 {
    return data[@intCast(range.start)..][0..@intCast(range.length)];
}

// ---------------------------------------------------------------------------
// Normalize: raw SSE events into fragments and whole events
// ---------------------------------------------------------------------------

const EventType = enum { message_start, content_block_start, content_block_delta, content_block_stop, message_delta, message_stop, @"error", ping };
const BlockType = enum { text, thinking, redacted_thinking, tool_use };

/// The rui.invalid whole event for a violation: one comptime literal per reason.
fn invalidText(reason: Reason) []const u8 {
    @setEvalBranchQuota(100_000);
    return switch (reason) {
        inline else => |known| std.fmt.comptimePrint("{{\"type\":\"rui.invalid\",\"reason\":\"{s}\"}}", .{@tagName(known)}),
    };
}

/// What a violation does: one whole rui.invalid event, which interpretEvent fails with that
/// reason. Inside an open block it discards the block's partial fragments first.
fn violation(stream: *Stream, out: *codec_abi.Normalized, reason: Reason) void {
    out.* = .{ .discard = stream.phase == .in_block };
    if (out.discard) stream.document = 0;
    out.literal(invalidText(reason));
    out.whole = true;
}

fn emitLiteral(stream: *Stream, out: *codec_abi.Normalized, bytes: []const u8) void {
    out.literal(bytes);
    stream.document += bytes.len;
}

fn emitCopy(stream: *Stream, out: *codec_abi.Normalized, range: Range) void {
    if (range.length == 0) return;
    out.copy(range);
    stream.document += range.length;
}

/// The phase error an out-of-order event names: late after the message stopped, otherwise contradictory.
fn orderError(stream: *const Stream) anyerror {
    return reasonError(if (stream.phase == .stopped) .late_provider_output else .contradictory_provider_output);
}

pub fn normalize(stream: *Stream, data: []const u8, out: *codec_abi.Normalized) void {
    out.* = .{};
    normalizeEvent(stream, data, out) catch |err| violation(stream, out, reasonOf(err));
}

fn normalizeEvent(stream: *Stream, data: []const u8, out: *codec_abi.Normalized) anyerror!void {
    try scanEvent(stream, data);
    const type_member = try required(&stream.scan, .type);
    if (type_member.kind != .string) return reasonError(.expected_json_string);
    // An event type this codec does not name is dropped: the wire documents new event types.
    const event = std.meta.stringToEnum(EventType, type_member.decoded() orelse return) orelse return;
    switch (event) {
        .ping => {},
        .message_start => try messageStart(stream, data),
        .content_block_start => try blockStart(stream, data, out),
        .content_block_delta => try blockDelta(stream, data, out),
        .content_block_stop => try blockStop(stream, out),
        .message_delta => try messageDelta(stream, data),
        .message_stop => try messageStop(stream, out),
        .@"error" => {
            // An error is one whole event, copied verbatim. Inside an open block it discards that block first.
            out.discard = stream.phase == .in_block;
            if (out.discard) stream.document = 0;
            out.copy(.{ .start = 0, .length = data.len });
            out.whole = true;
        },
    }
}

fn messageStart(stream: *Stream, data: []const u8) anyerror!void {
    const scan = &stream.scan;
    if (stream.phase != .before_start) return orderError(stream);
    const id = try contents(scan, .message_id);
    if (id.length == 0) return reasonError(.empty_provider_identity);
    if (id.length > max_id_bytes) return reasonError(.provider_value_too_long);
    const model = try contents(scan, .message_model);
    if (model.length == 0) return reasonError(.empty_provider_identity);
    if (model.length > codec_abi.max_model_bytes) return reasonError(.provider_value_too_long);
    stream.id.set(rangeBytes(data, id));
    stream.model.set(rangeBytes(data, model));
    stream.input = (try optionalCount(scan, .message_input));
    stream.cache_write = try optionalCount(scan, .message_cache_write);
    stream.cache_read = try optionalCount(scan, .message_cache_read);
    stream.phase = .started;
}

/// A count member, or null when the member is absent or not a plain integer. The count
/// is then absent from the output, never an error: Rui's usage is a report, not a failure.
fn optionalCount(scan: *const Scan, slot: Slot) anyerror!?u64 {
    const member = (try optional(scan, slot)) orelse return null;
    return member.plainCount();
}

fn blockStart(stream: *Stream, data: []const u8, out: *codec_abi.Normalized) anyerror!void {
    const scan = &stream.scan;
    if (stream.phase != .started and stream.phase != .between_blocks) return orderError(stream);
    try expectIndex(scan, .index, stream.next_index);
    const block_member = try required(scan, .block_type);
    if (block_member.kind != .string) return reasonError(.expected_json_string);
    const kind = std.meta.stringToEnum(BlockType, block_member.decoded() orelse return reasonError(.unsupported_content_block)) orelse return reasonError(.unsupported_content_block);
    switch (kind) {
        .text => {
            const body = try contents(scan, .block_text);
            emitLiteral(stream, out, "{\"type\":\"text\",\"text\":\"");
            emitCopy(stream, out, body);
            stream.block = .text;
        },
        .thinking => {
            const body = try contents(scan, .block_thinking);
            emitLiteral(stream, out, "{\"type\":\"thinking\",\"thinking\":\"");
            emitCopy(stream, out, body);
            stream.block = .thinking;
        },
        .redacted_thinking => {
            _ = try contents(scan, .block_data);
            const block = scan.values.getPtrConst(.content_block);
            emitCopy(stream, out, block.range);
            stream.block = .redacted;
        },
        .tool_use => {
            const id = try contents(scan, .block_id);
            const name = try contents(scan, .block_name);
            if (id.length == 0 or name.length == 0) return reasonError(.empty_provider_identity);
            emitLiteral(stream, out, "{\"type\":\"tool_use\",\"id\":\"");
            emitCopy(stream, out, id);
            emitLiteral(stream, out, "\",\"name\":\"");
            emitCopy(stream, out, name);
            emitLiteral(stream, out, "\",\"input_json\":\"");
            stream.block = .tool_use;
        },
    }
    stream.block_index = stream.next_index;
    stream.signature = false;
    stream.arguments = 0;
    stream.phase = .in_block;
    _ = data;
}

fn blockDelta(stream: *Stream, data: []const u8, out: *codec_abi.Normalized) anyerror!void {
    const scan = &stream.scan;
    if (stream.phase != .in_block) return orderError(stream);
    try expectIndex(scan, .index, stream.block_index);
    const type_member = try required(scan, .delta_type);
    if (type_member.kind != .string) return reasonError(.expected_json_string);
    const delta = type_member.decoded() orelse return reasonError(.unsupported_content_block);
    if (std.mem.eql(u8, delta, "citations_delta")) return reasonError(.unsupported_annotation);
    switch (stream.block) {
        .text => {
            if (!std.mem.eql(u8, delta, "text_delta")) return reasonError(.unsupported_content_block);
            emitCopy(stream, out, try contents(scan, .delta_text));
        },
        .thinking => {
            if (std.mem.eql(u8, delta, "thinking_delta")) {
                emitCopy(stream, out, try contents(scan, .delta_thinking));
            } else if (std.mem.eql(u8, delta, "signature_delta")) {
                const body = try contents(scan, .delta_signature);
                if (!stream.signature) emitLiteral(stream, out, "\",\"signature\":\"");
                emitCopy(stream, out, body);
                stream.signature = true;
            } else return reasonError(.unsupported_content_block);
        },
        .tool_use => {
            if (!std.mem.eql(u8, delta, "input_json_delta")) return reasonError(.unsupported_content_block);
            const body = try contents(scan, .delta_partial_json);
            emitCopy(stream, out, body);
            stream.arguments += body.length;
        },
        .redacted, .none => return reasonError(.unsupported_content_block),
    }
    _ = data;
}

fn blockStop(stream: *Stream, out: *codec_abi.Normalized) anyerror!void {
    if (stream.phase != .in_block) return orderError(stream);
    try expectIndex(&stream.scan, .index, stream.block_index);
    switch (stream.block) {
        .text => emitLiteral(stream, out, "\"}"),
        .thinking => {
            if (!stream.signature) return reasonError(.missing_provider_field);
            emitLiteral(stream, out, "\"}");
        },
        .redacted => {},
        // A call with no argument bytes is the empty object, as Responses reads it.
        .tool_use => emitLiteral(stream, out, if (stream.arguments == 0) "{}\"}" else "\"}"),
        .none => return orderError(stream),
    }
    out.whole = true;
    stream.document = 0;
    stream.next_index += 1;
    stream.block = .none;
    stream.phase = .between_blocks;
}

fn messageDelta(stream: *Stream, data: []const u8) anyerror!void {
    const scan = &stream.scan;
    if (stream.phase != .started and stream.phase != .between_blocks) return orderError(stream);
    const stop_member = try required(scan, .delta_stop_reason);
    if (stop_member.kind != .string) return reasonError(.expected_json_string);
    const word = stop_member.decoded() orelse "";
    const stop: Stop = if (std.mem.eql(u8, word, "end_turn"))
        .end_turn
    else if (std.mem.eql(u8, word, "tool_use"))
        .tool_use
    else if (std.mem.eql(u8, word, "refusal"))
        .refusal
    else if (std.mem.eql(u8, word, "max_tokens"))
        .max_tokens
    else if (std.mem.eql(u8, word, "model_context_window_exceeded"))
        .model_context_window_exceeded
    else if (std.mem.eql(u8, word, "pause_turn"))
        .pause_turn
    else
        .other;
    var details: @FieldType(Stream, "details") = .{};
    if (stop == .refusal) {
        details.category = try detailCopy(Buffer(max_category_bytes), data, scan, .stop_details_category);
        details.explanation = try detailCopy(Buffer(max_explanation_bytes), data, scan, .stop_details_explanation);
    }
    stream.stop = stop;
    stream.output = try optionalCount(scan, .usage_output);
    stream.details = details;
    stream.phase = .stopping;
}

/// A refusal detail: null when absent or JSON null; a bounded copy otherwise.
fn detailCopy(comptime Buf: type, data: []const u8, scan: *const Scan, slot: Slot) anyerror!?Buf {
    const member = (try optional(scan, slot)) orelse return null;
    if (member.kind == .literal and member.literal == .null_value) return null;
    if (member.kind != .string) return reasonError(.expected_json_string);
    if (member.range.length > Buf.capacity) return reasonError(.provider_value_too_long);
    var copy: Buf = .{};
    copy.set(rangeBytes(data, member.range));
    return copy;
}

fn messageStop(stream: *Stream, out: *codec_abi.Normalized) anyerror!void {
    if (stream.phase != .stopping) return orderError(stream);
    var writer: std.Io.Writer = .fixed(&stream.tail);
    writeCompleted(stream, &writer) catch return reasonError(.provider_value_too_long);
    out.literal(writer.buffered());
    out.whole = true;
    stream.document = 0;
    stream.phase = .stopped;
}

fn writeCompleted(stream: *const Stream, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("{\"type\":\"rui.completed\",\"id\":\"");
    try writer.writeAll(stream.id.slice());
    try writer.writeAll("\",\"model\":\"");
    try writer.writeAll(stream.model.slice());
    try writer.print("\",\"stop_reason\":\"{t}\"", .{stream.stop});
    if (stream.stop == .refusal) {
        try writer.writeAll(",\"refusal\":{\"category\":");
        try writeDetail(writer, stream.details.category);
        try writer.writeAll(",\"explanation\":");
        try writeDetail(writer, stream.details.explanation);
        try writer.writeAll("}");
    }
    try writer.writeAll(",\"usage\":{\"input_tokens\":");
    try writeCount(writer, stream.input);
    try writer.writeAll(",\"cache_creation_input_tokens\":");
    try writeCount(writer, stream.cache_write);
    try writer.writeAll(",\"cache_read_input_tokens\":");
    try writeCount(writer, stream.cache_read);
    try writer.writeAll(",\"output_tokens\":");
    try writeCount(writer, stream.output);
    try writer.writeAll("}}");
}

fn writeDetail(writer: *std.Io.Writer, detail: anytype) std.Io.Writer.Error!void {
    if (detail) |copy| {
        try writer.writeAll("\"");
        try writer.writeAll(copy.slice());
        try writer.writeAll("\"");
    } else try writer.writeAll("null");
}

fn writeCount(writer: *std.Io.Writer, count: ?u64) std.Io.Writer.Error!void {
    if (count) |value| try writer.print("{d}", .{value}) else try writer.writeAll("null");
}

// ---------------------------------------------------------------------------
// Interpret: whole events into grammar answers
// ---------------------------------------------------------------------------

pub const InterpretScratch = struct {
    reader: json.Reader = undefined,
    scan: Scan = .{},
};

const Verdict = @FieldType(codec_abi.Event, "what");

pub fn interpretEvent(stream: *Stream, scratch: *InterpretScratch, data: []const u8) codec_abi.Event {
    _ = stream;
    var at: codec_abi.At = .{ .stage = .event, .output_index = null };
    const what = verdict(scratch, data, &at) catch |err| return .{ .at = at, .what = .{ .failed = .{
        .reason = reasonOf(err),
        .refusal = null,
        .report = .{ .code = null, .message = null },
    } } };
    return .{ .at = at, .what = what };
}

fn verdict(scratch: *InterpretScratch, data: []const u8, at: *codec_abi.At) anyerror!Verdict {
    scratch.scan = .{};
    try scratch.reader.read(data, &scratch.scan);
    const scan = &scratch.scan;
    const type_member = try required(scan, .type);
    if (type_member.kind != .string) return reasonError(.expected_json_string);
    const type_text = type_member.decoded() orelse return reasonError(.unsupported_event_type);
    if (std.mem.eql(u8, type_text, "rui.completed")) return completed(data, scan, at);
    if (std.mem.eql(u8, type_text, "rui.invalid")) {
        const member = try required(scan, .reason);
        const tag = member.decoded() orelse return reasonError(.malformed_provider_output);
        return reasonError(std.meta.stringToEnum(Reason, tag) orelse return reasonError(.malformed_provider_output));
    }
    if (std.mem.eql(u8, type_text, "error")) return streamError(data, scan, at);
    const block = std.meta.stringToEnum(BlockType, type_text) orelse return reasonError(.unsupported_event_type);
    at.stage = .item;
    return switch (block) {
        .text => item(data, .message, @splat(zero_range)),
        .thinking, .redacted_thinking => item(data, .reasoning, @splat(zero_range)),
        .tool_use => blk: {
            const name = try contents(scan, .name);
            const id = try contents(scan, .id);
            const arguments = try contents(scan, .input_json);
            break :blk item(data, .function_call, .{ name, id, arguments });
        },
    };
}

/// A block as one item. Blocks have no provider id, so `added` is never sent: the whole
/// block is the item, and its identity is its ordinal.
fn item(data: []const u8, kind: codec_abi.OutputKind, call: [3]Range) Verdict {
    return .{ .item = .{
        .kind = kind,
        .phase = .unphased,
        .answer_phase = .unphased,
        .omit_reasoning_text = false,
        .whole = .{ .start = 0, .length = data.len },
        .id = .{ .start = 0, .length = 0 },
        .call = call,
        .members = .{ .offset = 0, .scope = .item, .kind = kind, .phase = .unphased, .array = .none, .text = .{ .start = 0, .length = 0 } },
    } };
}

fn completed(data: []const u8, scan: *const Scan, at: *codec_abi.At) anyerror!Verdict {
    at.* = .{ .stage = .response, .output_index = null };
    const stop = try required(scan, .stop_reason);
    if (stop.kind != .string) return reasonError(.expected_json_string);
    const word = stop.decoded() orelse "";
    if (std.mem.eql(u8, word, "refusal")) {
        return .{ .failed = .{
            .reason = .reported_provider_failure,
            .refusal = .policy,
            .report = .{ .code = report(try optionalRange(scan, .refusal_category)), .message = report(try optionalRange(scan, .refusal_explanation)) },
        } };
    }
    if (std.mem.eql(u8, word, "max_tokens")) return failure(.incomplete_provider_output);
    if (std.mem.eql(u8, word, "model_context_window_exceeded")) return failure(.context_overflow);
    if (!std.mem.eql(u8, word, "end_turn") and !std.mem.eql(u8, word, "tool_use")) return failure(.unsupported_response_status);
    const id = try contents(scan, .id);
    if (id.length == 0) return reasonError(.empty_provider_identity);
    const model = try contents(scan, .model);
    const usage = try required(scan, .usage);
    if (usage.kind != .object) return reasonError(.unexpected_json_delimiter);
    _ = data;
    return .{ .completed = .{
        .check = null,
        .response_id = id,
        .served_model = if (model.length == 0) null else model,
        .output = .{ .offset = 0, .scope = .output, .kind = .message, .phase = .unphased, .array = .none, .text = .{ .start = 0, .length = 0 } },
        .usage = .{ .report = .{ .whole = usage.range, .counts = usageCounts(scan) } },
    } };
}

fn failure(reason: Reason) Verdict {
    return .{ .failed = .{ .reason = reason, .refusal = null, .report = .{ .code = null, .message = null } } };
}

fn usageCounts(scan: *const Scan) ?codec_abi.Usage {
    const input = scan.values.getPtrConst(.usage_input).plainCount() orelse return null;
    const cache_write = scan.values.getPtrConst(.usage_cache_write).plainCount() orelse return null;
    const cache_read = scan.values.getPtrConst(.usage_cache_read).plainCount() orelse return null;
    const output = scan.values.getPtrConst(.usage_output).plainCount() orelse return null;
    return .{ .uncached = input, .cache_read = cache_read, .cache_write = cache_write, .output = output };
}

/// A string member's escaped contents, or null when the member is absent or JSON null.
fn optionalRange(scan: *const Scan, slot: Slot) anyerror!?Range {
    const member = (try optional(scan, slot)) orelse return null;
    if (member.kind == .literal and member.literal == .null_value) return null;
    if (member.kind != .string) return reasonError(.expected_json_string);
    return member.range;
}

fn report(range: ?Range) ?codec_abi.ReportRange {
    const value = range orelse return null;
    return .{ .escape = .json_string_v1, .start = value.start, .length = value.length };
}

/// The provider's error event, classified by the table `classify` shares (see errorOutcome).
fn streamError(data: []const u8, scan: *const Scan, at: *codec_abi.At) anyerror!Verdict {
    at.* = .{ .stage = .event, .output_index = null };
    const kind = try contents(scan, .error_type);
    const message = try optionalRange(scan, .error_message);
    const code: ?[]const u8 = if (scan.values.getPtrConst(.error_code).decoded()) |text| text else null;
    const outcome = errorOutcome(rangeBytes(data, kind), code, if (message) |range| rangeBytes(data, range) else "");
    return .{ .failed = .{
        .reason = if (outcome.overflow) .context_overflow else .reported_provider_failure,
        .refusal = outcome.refusal,
        .report = .{ .code = report(kind), .message = report(message) },
    } };
}

/// What an error object means, shared by the stream's error event and HTTP error bodies.
/// Raw byte compares: the names involved carry no escapes.
const Outcome = struct { overflow: bool = false, refusal: ?codec_abi.Refusal = null };

fn errorOutcome(kind: []const u8, code: ?[]const u8, message: []const u8) Outcome {
    if (std.mem.eql(u8, kind, "rate_limit_error")) {
        if (code) |text| if (std.mem.eql(u8, text, "enforced_spend_limit_reached")) return .{ .refusal = .quota };
        return .{};
    }
    if (std.mem.eql(u8, kind, "billing_error")) return .{ .refusal = .quota };
    if (std.mem.eql(u8, kind, "not_found_error") and std.mem.startsWith(u8, message, "model: ")) return .{ .refusal = .model_unavailable };
    if (std.mem.eql(u8, kind, "invalid_request_error") and std.mem.startsWith(u8, message, "prompt is too long")) return .{ .overflow = true };
    return .{};
}

/// Walks one assembled block (or nothing else): the members in document order, as the
/// grammar reads them. Neutral members are written from the call or the item and are
/// not returned; everything else is the bag, and the text is the part.
pub fn nextMember(document: []const u8, cursor: *codec_abi.Cursor) ?codec_abi.Member {
    switch (cursor.scope) {
        .output => return null,
        .part => {
            cursor.scope = .item;
            return .part_end;
        },
        .item, .array => {},
    }
    const variant = blockType(document) orelse return null;
    while (nextKey(document, cursor.offset)) |found| {
        cursor.offset = found.end;
        const name = rangeBytes(document, found.key);
        switch (variant) {
            .text => {
                if (std.mem.eql(u8, name, "type")) continue;
                if (std.mem.eql(u8, name, "text")) return partOf(cursor, document, found, .output_text);
            },
            .thinking => if (std.mem.eql(u8, name, "thinking")) return partOf(cursor, document, found, .reasoning_text),
            .tool_use => if (std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "input_json")) continue,
            .redacted_thinking => {},
        }
        return .{ .bag = .{ .start = found.start, .length = found.end - found.start } };
    }
    return null;
}

fn partOf(cursor: *codec_abi.Cursor, document: []const u8, found: Found, kind: codec_abi.PartKind) codec_abi.Member {
    cursor.scope = .part;
    return .{ .part = .{ .array = .content, .kind = kind, .text = json.stringAt(document, @intCast(found.value)).contents } };
}

const BlockVariant = enum { text, thinking, redacted_thinking, tool_use };

/// The block's `type`, found among its members (the shapes the codec writes put it first, a copied redacted block need not).
fn blockType(document: []const u8) ?BlockVariant {
    var offset: u64 = 0;
    while (nextKey(document, offset)) |found| {
        offset = found.end;
        if (!std.mem.eql(u8, rangeBytes(document, found.key), "type")) continue;
        const value = json.stringAt(document, @intCast(found.value)).contents;
        return std.meta.stringToEnum(BlockVariant, rangeBytes(document, value));
    }
    return null;
}

const Found = struct { start: u64, key: Range, value: u64, end: u64 };

const zero_range: Range = .{ .start = 0, .length = 0 };

/// The next member of the object at `from`, or null at its close. The document is a
/// codec-built, already validated object: every key is a string, every value complete.
fn nextKey(document: []const u8, from: u64) ?Found {
    var at: usize = @intCast(from);
    while (at < document.len and document[at] != '"' and document[at] != '}') at += 1;
    if (at >= document.len or document[at] == '}') return null;
    const key = json.stringAt(document, at);
    var value = json.skipSpace(document, key.end);
    value = json.skipSpace(document, value + 1);
    const end = json.valueEnd(document, value);
    return .{ .start = at, .key = key.contents, .value = value, .end = end };
}

/// This family offers no hosted tools, so no item is a hosted call.
pub fn hostedCall(document: []const u8, item_value: *const codec_abi.OutputItem) codec_abi.HostedCall {
    _ = .{ document, item_value };
    unreachable;
}

// ---------------------------------------------------------------------------
// HTTP error bodies
// ---------------------------------------------------------------------------

/// The scratch an HTTP error body is read into: the stream's Scan, so both share one table.
pub const ClassifyScratch = struct {
    reader: json.Reader = undefined,
    scan: Scan = .{},
};

/// Classifies an error body `{"type":"error","error":{"type":…,"message":…}}` by the table the stream's
/// error event uses. A body that is not that shape reports nothing and classifies as no outcome.
pub fn classify(scratch: *ClassifyScratch, body: []const u8, out: *codec_abi.ErrorBody) void {
    out.* = .{ .context_overflow = false, .refusal = null, .resets_at = null, .report = .{ .code = null, .message = null } };
    scratch.scan = .{};
    scratch.reader.read(body, &scratch.scan) catch return;
    const kind = contents(&scratch.scan, .error_type) catch return;
    const message = optionalRange(&scratch.scan, .error_message) catch return;
    const code: ?[]const u8 = if (scratch.scan.values.getPtrConst(.error_code).decoded()) |text| text else null;
    const outcome = errorOutcome(rangeBytes(body, kind), code, if (message) |range| rangeBytes(body, range) else "");
    out.context_overflow = outcome.overflow;
    out.refusal = outcome.refusal;
    out.report = .{ .code = report(kind), .message = report(message) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const start_message = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-x\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":2,\"cache_read_input_tokens\":3,\"output_tokens\":1}}}";

test "MSG-10 a block's fragments never exceed the raw events it came from" {
    const events = [_][]const u8{
        start_message,
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}",
        "{\"type\":\"content_block_stop\",\"index\":0}",
    };
    var raw_bytes: usize = 0;
    var fragment_bytes: usize = 0;
    var stream = begin(.assistant_response);
    for (events) |raw| {
        var normalized: codec_abi.Normalized = .{};
        normalize(&stream, raw, &normalized);
        raw_bytes += raw.len;
        for (normalized.slice()) |fragment| fragment_bytes += switch (fragment) {
            .literal => |literal| literal.len,
            .copy => |range| range.length,
        };
    }
    try std.testing.expect(fragment_bytes <= raw_bytes);
}

// ---------------------------------------------------------------------------
// Request encoding tests
// ---------------------------------------------------------------------------

/// One history element for the encoder: its header and the bytes of its handles, as
/// the shell supplies them (escaped bodies for json_string_v1, raw for verbatim).
const Step = struct {
    header: codec_abi.ItemHeader,
    strings: [codec_abi.max_handles][]const u8,
};

const no_strings: [codec_abi.max_handles][]const u8 = .{ "", "", "" };

fn step(value: codec_abi.Item, handles: u8, strings: [codec_abi.max_handles][]const u8) Step {
    return .{ .header = .{ .item = value, .handles = handles }, .strings = strings };
}

fn settingsItem(output_limit: u32) codec_abi.Item {
    return .{ .settings = .{ .effort = null, .session_affinity = @splat(0), .output_limit = output_limit, .model_length = 0 } };
}

/// Writes each element's pieces, resolving handles from the step's strings.
fn encodeSteps(encoder: *Encoder, steps: []const Step, out: *std.Io.Writer) !void {
    for (steps) |*one| {
        var pieces: codec_abi.Pieces = .{ .len = 0 };
        try encoder.encodeItem(&one.header, &pieces);
        for (pieces.slice()) |piece| switch (piece) {
            .literal => |bytes| try out.writeAll(bytes),
            .content => |content| try out.writeAll(one.strings[content.handle]),
            .base64 => |handle| {
                var buffer: [64]u8 = undefined;
                try out.writeAll(std.base64.standard.Encoder.encode(&buffer, one.strings[handle]));
            },
        };
    }
}

fn expectEncoding(steps: []const Step, expected: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var encoder: Encoder = .{ .carry = initial(null) };
    try encodeSteps(&encoder, steps, &out);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

/// A whole request: instructions, a user turn, a thinking block and a tool call, the
/// tool's result, a final answer, one tool, a schema at high effort, and an image.
const request_steps = [_]Step{
    step(settingsItem(4096), 0b1, .{ "claude-x", "", "" }),
    step(.{ .operation = .high }, 0, no_strings),
    step(.{ .message = .instruction }, 0b1, .{ "be brief", "", "" }),
    step(.history_start, 0, no_strings),
    step(.{ .message = .user }, 0b1, .{ "hi", "", "" }),
    step(.{ .output_open = .{ .kind = .reasoning, .phase = .unphased, .omit_reasoning_text = false } }, 0, no_strings),
    step(.{ .output_part = .{ .array = .content, .kind = .reasoning_text } }, 0b1, .{ "think", "", "" }),
    step(.output_close, 0b1, .{ "\"type\":\"thinking\",\"signature\":\"sig\"", "", "" }),
    step(.{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, 0b111, .{ "lookup", "toolu_1", "{\"q\":1}" }),
    step(.output_close, 0, no_strings),
    step(.tool_result, 0b11, .{ "toolu_1", "42", "" }),
    step(.{ .output_open = .{ .kind = .message, .phase = .final_answer, .omit_reasoning_text = false } }, 0, no_strings),
    step(.{ .output_part = .{ .array = .content, .kind = .output_text } }, 0b1, .{ "done", "", "" }),
    step(.output_close, 0, no_strings),
    step(.tools_start, 0, no_strings),
    step(.tool, 0b111, .{ "lookup", "Look up", "{\"type\":\"object\"}" }),
    step(.text_format, 0b1, .{ "{\"type\":\"object\"}", "", "" }),
    step(.request_end, 0, no_strings),
};

test "MSG-11 the widest elements fit the piece budget, and each writes its expected pieces" {
    var encoder: Encoder = .{ .carry = initial(null) };
    var pieces: codec_abi.Pieces = .{ .len = 0 };
    try encoder.encodeItem(&.{ .item = settingsItem(1), .handles = 0b1 }, &pieces);
    try encoder.encodeItem(&.{ .item = .history_start, .handles = 0 }, &pieces);
    try encoder.encodeItem(&.{ .item = .{ .message = .user }, .handles = 0b1 }, &pieces);
    // A tool call after an assistant role switch: two separator pieces, then the block's six.
    try encoder.encodeItem(&.{ .item = .{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, .handles = 0b111 }, &pieces);
    try std.testing.expectEqual(@as(u8, 8), pieces.len);
    try encoder.encodeItem(&.{ .item = .output_close, .handles = 0 }, &pieces);
    // A user message with two text parts after an assistant role switch: the separator, then five.
    try encoder.encodeItem(&.{ .item = .{ .message = .user }, .handles = 0b11 }, &pieces);
    try std.testing.expectEqual(@as(u8, 7), pieces.len);
}

/// An image group spans several elements: its parts' separator is carry.
const image_steps = [_]Step{
    step(settingsItem(1), 0b1, .{ "m", "", "" }),
    step(.history_start, 0, no_strings),
    step(.{ .image_message_open = .user }, 0, no_strings),
    step(.input_text, 0b1, .{ "look", "", "" }),
    step(.{ .input_image = .png }, 0b1, .{ "ab", "", "" }),
    step(.input_text, 0b1, .{ "again", "", "" }),
    step(.image_message_close, 0, no_strings),
    step(.tools_start, 0, no_strings),
    step(.request_end, 0, no_strings),
};

/// Every element boundary that is a memo boundary resumes byte-identically.
fn expectResumes(steps: []const Step) !void {
    var full_buffer: [4096]u8 = undefined;
    var full: std.Io.Writer = .fixed(&full_buffer);
    var whole: Encoder = .{ .carry = initial(null) };
    try encodeSteps(&whole, steps, &full);

    var checked: usize = 0;
    for (0..steps.len + 1) |cut| {
        var first_buffer: [4096]u8 = undefined;
        var first_out: std.Io.Writer = .fixed(&first_buffer);
        var first: Encoder = .{ .carry = initial(null) };
        try encodeSteps(&first, steps[0..cut], &first_out);
        // A cut inside an output item is not a memo boundary: its open state is not carry.
        if (first.item != .none) continue;
        checked += 1;

        var second: Encoder = .{ .carry = first.carry, .effort = first.effort, .effort_seen = first.effort_seen };
        var rest_buffer: [4096]u8 = undefined;
        var rest: std.Io.Writer = .fixed(&rest_buffer);
        try encodeSteps(&second, steps[cut..], &rest);

        var joined: [4096]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&joined, "{s}{s}", .{ first_out.buffered(), rest.buffered() });
        try std.testing.expectEqualStrings(full.buffered(), bytes);
    }
    try std.testing.expect(checked > 4);
}

test "MSG-12 resuming at an element boundary writes what an uninterrupted encoding writes" {
    try expectResumes(&request_steps);
    try expectResumes(&image_steps);
}

test "MSG-13 a whole request encodes to its exact Messages body" {
    try expectEncoding(&request_steps, "{\"model\":\"claude-x\",\"max_tokens\":4096,\"stream\":true,\"cache_control\":{\"type\":\"ephemeral\"}," ++
        "\"system\":\"be brief\",\"messages\":[" ++
        "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}," ++
        "{\"role\":\"assistant\",\"content\":[{\"thinking\":\"think\",\"type\":\"thinking\",\"signature\":\"sig\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",\"input\":{\"q\":1}}]}," ++
        "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"42\"}]}," ++
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}]," ++
        "\"tools\":[{\"name\":\"lookup\",\"description\":\"Look up\",\"input_schema\":{\"type\":\"object\"}}]," ++
        "\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\",\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\"}}}}");
}

test "MSG-14 a redacted thinking block replays whole, ahead of its tool call in one assistant message" {
    try expectEncoding(&.{
        step(settingsItem(1), 0b1, .{ "m", "", "" }),
        step(.history_start, 0, no_strings),
        step(.{ .output_open = .{ .kind = .reasoning, .phase = .unphased, .omit_reasoning_text = false } }, 0, no_strings),
        step(.output_close, 0b1, .{ "\"type\":\"redacted_thinking\",\"data\":\"X\"", "", "" }),
        step(.{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, 0b111, .{ "f", "t", "{}" }),
        step(.output_close, 0, no_strings),
        step(.tools_start, 0, no_strings),
        step(.request_end, 0, no_strings),
    }, "{\"model\":\"m\",\"max_tokens\":1,\"stream\":true,\"cache_control\":{\"type\":\"ephemeral\"}," ++
        "\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"redacted_thinking\",\"data\":\"X\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"f\",\"input\":{}}]}]}");
}

test "MSG-15 an empty message writes nothing, and what the wire cannot take is declined" {
    var encoder: Encoder = .{ .carry = initial(null) };
    var pieces: codec_abi.Pieces = .{ .len = 0 };
    try encoder.encodeItem(&.{ .item = .{ .output_open = .{ .kind = .message, .phase = .final_answer, .omit_reasoning_text = false } }, .handles = 0 }, &pieces);
    try encoder.encodeItem(&.{ .item = .output_close, .handles = 0 }, &pieces);
    try std.testing.expectEqual(@as(u8, 0), pieces.len);

    // No output_limit: the wire requires max_tokens, so the request cannot be sent.
    try std.testing.expectError(error.Declined, encoder.encodeItem(&.{ .item = settingsItem(0), .handles = 0b1 }, &pieces));
    try std.testing.expectError(error.Declined, encoder.encodeItem(&.{ .item = .compaction_trigger, .handles = 0 }, &pieces));
    try std.testing.expectError(error.Declined, encoder.encodeItem(&.{ .item = .declare_open, .handles = 0 }, &pieces));
    try std.testing.expectError(error.Declined, encoder.encodeItem(&.{ .item = .web_search, .handles = 0 }, &pieces));
    try std.testing.expectError(error.Declined, encoder.encodeItem(&.{ .item = .{ .output_open = .{ .kind = .compaction, .phase = .unphased, .omit_reasoning_text = false } }, .handles = 0 }, &pieces));
    // A format with no effort operation before it has nothing to declare.
    try std.testing.expectError(error.Declined, encoder.encodeItem(&.{ .item = .text_format, .handles = 0b1 }, &pieces));
}

test "MSG-16 an HTTP error body classifies by the table the stream's error event uses" {
    var scratch: ClassifyScratch = undefined;
    var out: codec_abi.ErrorBody = undefined;

    const too_long = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 300000 tokens > 200000\"}}";
    classify(&scratch, too_long, &out);
    try std.testing.expect(out.context_overflow);
    try std.testing.expectEqual(@as(?codec_abi.Refusal, null), out.refusal);
    const code = out.report.code orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("invalid_request_error", too_long[@intCast(code.start)..][0..@intCast(code.length)]);

    const billing = "{\"type\":\"error\",\"error\":{\"type\":\"billing_error\",\"message\":\"Your credit balance is too low.\"}}";
    classify(&scratch, billing, &out);
    try std.testing.expect(!out.context_overflow);
    try std.testing.expectEqual(@as(?codec_abi.Refusal, .quota), out.refusal);

    const spend = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"limit\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}";
    classify(&scratch, spend, &out);
    try std.testing.expectEqual(@as(?codec_abi.Refusal, .quota), out.refusal);

    // A body that is not an error object classifies as no outcome and reports nothing.
    classify(&scratch, "{\"type\":\"other\"}", &out);
    try std.testing.expect(!out.context_overflow);
    try std.testing.expectEqual(@as(?codec_abi.Refusal, null), out.refusal);
    try std.testing.expectEqual(@as(?codec_abi.ReportRange, null), out.report.code);
}
