//! The codecs this Host serves, by the codec name a Session pins. A codec is
//! plain functions over values its caller stores, dispatched at comptime.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const protocol = @import("protocol.zig");
const json = @import("codecs/json.zig");
const responses = @import("codecs/responses.zig");

/// The module of each codec this Host serves, the one place a codec is
/// added: everything below is derived from it.
fn module(comptime codec: protocol.Codec) type {
    return switch (codec) {
        .@"openai-responses/1" => responses,
    };
}

pub fn manifest(codec: protocol.Codec) *const codec_abi.Manifest {
    return switch (codec) {
        inline else => |tag| &module(tag).manifest,
    };
}

comptime {
    for (@typeInfo(protocol.Codec).@"enum".field_names) |name| {
        const codec = module(@field(protocol.Codec, name));
        if (!codec.manifest.valid()) @compileError("codec " ++ name ++ " observes a header that is not a lowercase token");
        const headers = @typeInfo(codec.RequestHeader).@"enum".field_names;
        if (headers.len > codec_abi.max_request_headers) @compileError("codec " ++ name ++ " names more request headers than a request holds");
        for (headers) |header| if (!codec_abi.lowercaseToken(header)) @compileError("codec " ++ name ++ " names a request header that is not a lowercase token");
    }
    // The Responses classifier accepts exactly the bodies the Host's own
    // JSON reading did.
    std.debug.assert(json.max_depth == protocol.max_json_depth);
}

/// A pinned codec's request encoder state, which its caller stores. Each
/// codec's `Encoder` holds its `Carry` as `carry`, and its other fields'
/// defaults are its state at a history-element boundary.
pub const Encoder = PerCodec("Encoder");

/// A pinned codec's encoder state at a history-element boundary.
pub const Carry = PerCodec("Carry");

/// The union over every codec of the type each declares as `name`.
fn PerCodec(comptime name: []const u8) type {
    const codecs = @typeInfo(protocol.Codec).@"enum".field_names;
    var names: [codecs.len][]const u8 = undefined;
    var types: [codecs.len]type = undefined;
    for (codecs, &names, &types) |codec, *field, *T| {
        field.* = codec;
        T.* = @field(module(@field(protocol.Codec, codec)), name);
    }
    return @Union(.auto, protocol.Codec, &names, &types, &@splat(.{}));
}

/// Every codec's `name` type side by side, for scratch a caller lends: each
/// call writes its own codec's field before it reads it, so no tag says
/// which one was last used.
fn EachCodec(comptime name: []const u8) type {
    const codecs = @typeInfo(protocol.Codec).@"enum".field_names;
    var names: [codecs.len][]const u8 = undefined;
    var types: [codecs.len]type = undefined;
    for (codecs, &names, &types) |codec, *field, *T| {
        field.* = codec;
        T.* = @field(module(@field(protocol.Codec, codec)), name);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// The carry before a request's first history element.
pub fn initialCarry(codec: protocol.Codec) Carry {
    return switch (codec) {
        inline else => |tag| @unionInit(Carry, @tagName(tag), module(tag).initial),
    };
}

pub fn resumeFrom(carry: Carry) Encoder {
    return switch (carry) {
        inline else => |value, tag| @unionInit(Encoder, @tagName(tag), .{ .carry = value }),
    };
}

pub fn carryOf(encoder: *const Encoder) Carry {
    return switch (encoder.*) {
        inline else => |*state, tag| @unionInit(Carry, @tagName(tag), state.carry),
    };
}

/// Write the item's pieces into `out`. `error.Declined` is the codec
/// declining a request it cannot encode.
pub fn encodeItem(encoder: *Encoder, header: *const codec_abi.ItemHeader, out: *codec_abi.Pieces) error{Declined}!void {
    return switch (encoder.*) {
        inline else => |*state| state.encodeItem(header, out),
    };
}

/// The pinned codec's request headers for `settings`, written over `out`.
pub fn requestHeaders(codec: protocol.Codec, settings: *const codec_abi.Settings, out: *codec_abi.Headers) void {
    switch (codec) {
        inline else => |tag| module(tag).requestHeaders(settings, out),
    }
}

/// The name `codec` gives the request header `Headers.names` holds as
/// `name`.
pub fn headerName(codec: protocol.Codec, name: u8) []const u8 {
    return switch (codec) {
        inline else => |tag| @tagName(@as(module(tag).RequestHeader, @fromBackingInt(@intCast(name)))),
    };
}

/// A pinned codec's error classifier scratch, which its caller lends for
/// each `classify`.
pub const ClassifyScratch = EachCodec("ClassifyScratch");

/// Writes into `out` what the pinned codec reads in the HTTP error body
/// `body`, naming report text by range of `body`.
pub fn classify(codec: protocol.Codec, scratch: *ClassifyScratch, body: []const u8, out: *codec_abi.ErrorBody) void {
    switch (codec) {
        inline else => |tag| module(tag).classify(&@field(scratch, @tagName(tag)), body, out),
    }
}

/// A pinned codec's response stream state between events, which its
/// caller stores.
pub const Stream = PerCodec("Stream");

/// A pinned codec's interpreter scratch, which its caller lends for each
/// `interpretEvent`.
pub const InterpretScratch = EachCodec("InterpretScratch");

/// The state before a response's first event.
pub fn begin(codec: protocol.Codec, operation: codec_abi.Operation) Stream {
    return switch (codec) {
        inline else => |tag| @unionInit(Stream, @tagName(tag), module(tag).begin(operation)),
    };
}

/// The codec's verdict on one event's data, `data`, naming bytes by range
/// of it. Never inlined, like `nextMember`: the codec's frames stay apart
/// from the shell's, which hold the Host's rules across items.
pub noinline fn interpretEvent(stream: *Stream, scratch: *InterpretScratch, data: []const u8) codec_abi.Event {
    switch (stream.*) {
        inline else => |*state, tag| return module(tag).interpretEvent(state, &@field(scratch, @tagName(tag)), data),
    }
}

/// The next step of a walk over an event `interpretEvent` accepted, from
/// a cursor its answer gave.
pub noinline fn nextMember(codec: protocol.Codec, data: []const u8, cursor: *codec_abi.Cursor) ?codec_abi.Member {
    return switch (codec) {
        inline else => |tag| module(tag).nextMember(data, cursor),
    };
}

/// The stream ended between events: its verdict, if it fails.
pub fn finish(stream: *const Stream) ?codec_abi.Reason {
    return switch (stream.*) {
        inline else => |*state, tag| module(tag).finish(state),
    };
}

const TestItem = struct {
    item: codec_abi.Item,
    handles: []const ?[]const u8 = &.{},
};

/// Encode `items` into `out` as the Host does, resuming `encoder` from
/// `carry` before each item that resumes when `carry` is given, with
/// std.json's string escaping standing in for the Host's cursors.
fn encodeForTesting(encoder: *Encoder, carry: ?*Carry, items: []const TestItem, out: *std.Io.Writer) !void {
    var pieces: codec_abi.Pieces = .{ .len = 0 };
    for (items) |item| {
        var header: codec_abi.ItemHeader = .{ .item = item.item, .handles = 0 };
        for (item.handles, 0..) |handle, index| {
            if (handle != null) header.handles |= @as(u8, 1) << @intCast(index);
        }
        const kind: codec_abi.ItemKind = header.item;
        if (carry) |kept| if (kind.resumes()) {
            encoder.* = resumeFrom(kept.*);
        };
        try encodeItem(encoder, &header, &pieces);
        if (carry) |kept| if (kind.endsElement()) {
            kept.* = carryOf(encoder);
        };
        for (pieces.slice()) |piece| switch (piece) {
            .literal => |bytes| try out.writeAll(bytes),
            .content => |content| switch (content.escape) {
                .verbatim => try out.writeAll(item.handles[content.handle].?),
                .json_string_v1 => try std.json.Stringify.encodeJsonStringChars(item.handles[content.handle].?, .{}, out),
            },
        };
    }
}

const responses_initial = initialCarry(.@"openai-responses/1");

test "a tool entry escapes its name and description as JSON strings" {
    var encoder = resumeFrom(responses_initial);
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try encodeForTesting(&encoder, null, &.{.{ .item = .tool, .handles = &.{ "t", "say \"hi\"\\\n\x01é", "{}" } }}, &out);
    const written = out.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\\\n\x01é", parsed.value.object.get("description").?.string);
    try std.testing.expectEqualStrings("{\"type\":\"function\",\"name\":\"t\",\"description\":\"say \\\"hi\\\"\\\\\\n\\u0001é\",\"strict\":true,\"parameters\":{}}", written);
}

test "a resumed encoder writes what an uninterrupted one writes" {
    const history = [_]TestItem{
        .{ .item = .{ .message = .user }, .handles = &.{"one"} },
        .{ .item = .{ .output_open = .{ .kind = .reasoning, .phase = .unphased, .omit_reasoning_text = true } } },
        .{ .item = .{ .output_part = .{ .array = .summary, .kind = .summary_text } }, .handles = &.{ "plan", null } },
        .{ .item = .{ .output_part = .{ .array = .content, .kind = .reasoning_text } }, .handles = &.{"private"} },
        .{ .item = .output_close, .handles = &.{"\"encrypted_content\":\"x\""} },
        .{ .item = .{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, .handles = &.{ "bash", "c1", "{}" } },
        .{ .item = .output_close },
        .{ .item = .tool_result, .handles = &.{ "c1", "done" } },
        .{ .item = .{ .message = .instruction }, .handles = &.{ "two", "from peer" } },
    };
    const tail = [_]TestItem{ .{ .item = .history_end }, .{ .item = .compaction_trigger }, .{ .item = .tools_start }, .{ .item = .text_format }, .{ .item = .request_end } };
    // One encoder over the whole request, never resumed: the bytes a
    // carry that held less than the codec needs would change.
    var whole_buffer: [2048]u8 = undefined;
    var whole: std.Io.Writer = .fixed(&whole_buffer);
    var uninterrupted = resumeFrom(responses_initial);
    try encodeForTesting(&uninterrupted, null, &history, &whole);
    try encodeForTesting(&uninterrupted, null, &tail, &whole);
    // Cut before the first element and after every one: a fresh encoder
    // given only the carry writes the same remaining bytes.
    for (0..history.len + 1) |cut| {
        if (cut != 0) {
            const kind: codec_abi.ItemKind = history[cut - 1].item;
            if (!kind.endsElement()) continue;
        }
        var resumed_buffer: [2048]u8 = undefined;
        var resumed: std.Io.Writer = .fixed(&resumed_buffer);
        var carry = responses_initial;
        var first = resumeFrom(carry);
        try encodeForTesting(&first, &carry, history[0..cut], &resumed);
        var second = resumeFrom(responses_initial);
        try encodeForTesting(&second, &carry, history[cut..], &resumed);
        try encodeForTesting(&second, &carry, &tail, &resumed);
        try std.testing.expectEqualStrings(whole.buffered(), resumed.buffered());
    }
    try std.testing.expectStringStartsWith(whole.buffered(), "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"one\"}]},{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"plan\"}],\"encrypted_content\":\"x\"}");
    try std.testing.expectStringEndsWith(whole.buffered(), "{\"type\":\"compaction_trigger\"}],\"tools\":[],\"text\":{\"verbosity\":\"low\"}}");
}

test "the codec's JSON reader names each syntax error as validation did" {
    // The digest of each document's error name, or `ok`, one per line, as
    // validation's own parser named them before the codec's reader
    // replaced it.
    const expected = "76669bb7f8a5561499c529d7bf886895e7e4371f76d2820a7d06cf53e08b73f0";
    const Names = struct {
        hash: std.crypto.hash.sha2.Sha256 = protocol.contentHasher(),

        fn add(self: *@This(), document: []const u8) void {
            const Ignored = struct {
                pub fn key(_: *@This(), _: *const json.Reader, _: u8) void {}
                pub fn begin(_: *@This(), _: *const json.Reader, _: json.Kind, _: u8) void {}
                pub fn end(_: *@This(), _: *const json.Reader, _: json.Kind, _: u8) void {}
            };
            var ignored: Ignored = .{};
            var reader: json.Reader = undefined;
            self.hash.update(if (reader.read(document, &ignored)) |_| "ok" else |err| @errorName(err));
            self.hash.update("\n");
        }
    };
    var names: Names = .{};
    const sample = "{\"type\":\"x\", \"a\":[1,-2.5e+3,0,true,null,{\"b\":\"\\u00e9\\n\xc3\xa9\\ud83d\\ude00\"}],\"c\":{}}";
    // Every prefix, and every byte replaced by each byte the grammar
    // treats apart.
    for (0..sample.len + 1) |cut| names.add(sample[0..cut]);
    const alphabet = "{}[]:,\"\\ 0-.eE+tfnux\x01\x7f\xc3\xe2\xf0\xff";
    var document: [sample.len]u8 = undefined;
    for (0..sample.len) |index| for (alphabet) |byte| {
        document = sample.*;
        document[index] = byte;
        names.add(&document);
    };
    const open = "{\"a\":" ++ @as([json.max_depth]u8, @splat('['));
    const close: [json.max_depth]u8 = @splat(']');
    for ([_][]const u8{ open ++ "1" ++ close ++ "}", open ++ " ", open[0 .. open.len - 1] ++ " ", open ++ "]" }) |deep| names.add(deep);
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&names.hash.finalResult()});
    try std.testing.expectEqualStrings(expected, &hex);
}
