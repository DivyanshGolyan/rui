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
        .@"openai-responses/1" => Responses(.one),
        .@"openai-responses/2" => Responses(.two),
        .@"openai-responses/3" => Responses(.three),
    };
}

/// A version of the Responses codec: one grammar, read the same way, whose
/// versions differ only in the requests they write.
fn Responses(comptime version: responses.Version) type {
    return struct {
        pub const manifest = responses.manifest;
        pub const RequestHeader = responses.RequestHeader;
        pub const requestHeaders = responses.requestHeaders;
        pub const Encoder = responses.Encoder;
        pub const Carry = responses.Carry;
        pub const ClassifyScratch = responses.ClassifyScratch;
        pub const classify = responses.classify;
        pub const Stream = responses.Stream;
        pub const InterpretScratch = responses.InterpretScratch;
        pub const begin = responses.begin;
        pub const interpretEvent = responses.interpretEvent;
        pub const nextMember = responses.nextMember;
        pub const hostedCall = responses.hostedCall;
        pub const finish = responses.finish;

        pub fn initial(starting_effort: ?codec_abi.Effort) responses.Carry {
            return responses.initial(version, starting_effort);
        }

        pub fn declaresTools() bool {
            return version.declaresTools();
        }

        pub fn effortChangeRefused(scratch: *const responses.ClassifyScratch, status: u16, body: []const u8) bool {
            return version.carriesEffort() and responses.effortChangeRefused(scratch, status, body);
        }
    };
}

/// Whether the codec declares function tools inside the history, at each
/// Operation boundary, instead of in the tools stage.
pub fn declaresTools(codec: protocol.Codec) bool {
    return switch (codec) {
        inline else => |tag| module(tag).declaresTools(),
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

const codec_names = @typeInfo(protocol.Codec).@"enum".field_names;

const CodecFields = struct { names: [codec_names.len][]const u8, types: [codec_names.len]type };

/// Each codec's name and the type its module declares as `name`.
fn codecFields(comptime name: []const u8) CodecFields {
    var fields: CodecFields = undefined;
    for (codec_names, &fields.names, &fields.types) |codec, *field, *T| {
        field.* = codec;
        T.* = @field(module(@field(protocol.Codec, codec)), name);
    }
    return fields;
}

/// The union over every codec of the type each declares as `name`.
fn PerCodec(comptime name: []const u8) type {
    const fields = codecFields(name);
    return @Union(.auto, protocol.Codec, &fields.names, &fields.types, &@splat(.{}));
}

/// Every codec's `name` type side by side, for scratch a caller lends: each
/// call writes its own codec's field before it reads it, so no tag says
/// which one was last used.
fn EachCodec(comptime name: []const u8) type {
    const fields = codecFields(name);
    return @Struct(.auto, null, &fields.names, &fields.types, &@splat(.{}));
}

/// The carry before a request's first history element, for a Session
/// whose first Operation froze `starting_effort`.
pub fn initialCarry(codec: protocol.Codec, starting_effort: ?codec_abi.Effort) Carry {
    return switch (codec) {
        inline else => |tag| @unionInit(Carry, @tagName(tag), module(tag).initial(starting_effort)),
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

/// The pinned codec owns whether status and error body refused an effort update.
pub fn effortChangeRefused(codec: protocol.Codec, scratch: *const ClassifyScratch, status: u16, body: []const u8) bool {
    return switch (codec) {
        inline else => |tag| module(tag).effortChangeRefused(&@field(scratch, @tagName(tag)), status, body),
    };
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

/// What an accepted hosted tool call item did, read from its bytes.
pub fn hostedCall(codec: protocol.Codec, data: []const u8, item: *const codec_abi.OutputItem) codec_abi.HostedCall {
    return switch (codec) {
        inline else => |tag| module(tag).hostedCall(data, item),
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
            .base64 => |handle| {
                const encoding = @import("request_encoding.zig");
                const Sink = struct {
                    writer: *std.Io.Writer,
                    pub fn write(self: *@This(), bytes: []const u8) !void {
                        try self.writer.writeAll(bytes);
                    }
                };
                var sink: Sink = .{ .writer = out };
                var cursor: encoding.Base64Cursor = undefined;
                cursor.init();
                var allowance: usize = 17;
                while (!try cursor.advance(encoding.MemorySource{ .bytes = item.handles[handle].? }, &sink, &allowance)) allowance = 17;
            },
            .content => |content| switch (content.escape) {
                .verbatim => try out.writeAll(item.handles[content.handle].?),
                .json_string_v1 => try std.json.Stringify.encodeJsonStringChars(item.handles[content.handle].?, .{}, out),
            },
        };
    }
}

const responses_initial = initialCarry(.@"openai-responses/1", null);

test "a tool entry escapes its name and description as JSON strings" {
    var encoder = resumeFrom(responses_initial);
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try encodeForTesting(&encoder, null, &.{.{ .item = .tool, .handles = &.{ "t", "say \"hi\"\\\n\x01é", "{}" } }}, &out);
    const written = out.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\\\n\x01é", parsed.value.object.get("description").?.string);
    try std.testing.expectEqualStrings("{\"type\":\"function\",\"name\":\"t\",\"description\":\"say \\\"hi\\\"\\\\\\n\\u0001é\",\"strict\":false,\"parameters\":{}}", written);
}

test "hosted web search follows the function tools and asks for live pages" {
    var encoder = resumeFrom(responses_initial);
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try encodeForTesting(&encoder, null, &.{
        .{ .item = .tools_start },
        .{ .item = .tool, .handles = &.{ "bash", "d", "{}" } },
        .{ .item = .web_search },
        .{ .item = .text_format },
    }, &out);
    try std.testing.expectEqualStrings("],\"tools\":[{\"type\":\"function\",\"name\":\"bash\",\"description\":\"d\",\"strict\":false,\"parameters\":{}}," ++
        "{\"type\":\"web_search\",\"external_web_access\":true}],\"text\":{\"verbosity\":\"low\"}", out.buffered());
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

/// A whole `openai-responses/3` request for a Session whose first
/// Operation froze low effort, as the Host encodes it: resumed from the
/// carry before each element.
fn versionThreeForTesting(items: []const TestItem, out: *std.Io.Writer) !void {
    var carry = initialCarry(.@"openai-responses/3", .low);
    var encoder = resumeFrom(carry);
    try encodeForTesting(&encoder, &carry, items, out);
}

const version_three_top = "{\"model\":\"m\",\"parallel_tool_calls\":true,\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"reasoning\":{\"effort\":\"high\"},\"instructions\":\"i\",\"input\":[";
const version_three_first_operation = [_]TestItem{
    .{ .item = .{ .settings = .{ .effort = .high, .starting_effort = .low, .session_affinity = @splat(0), .model_length = 1 } }, .handles = &.{"m"} },
    .{ .item = .instructions, .handles = &.{"i"} },
    .{ .item = .{ .message = .user }, .handles = &.{"one"} },
    .{ .item = .{ .operation = .low } },
    .{ .item = .declare_open },
    .{ .item = .declared_tool, .handles = &.{ "bash", "d", "{}" } },
    .{ .item = .declare_close },
    .{ .item = .{ .output_open = .{ .kind = .message, .phase = .final_answer, .omit_reasoning_text = false } } },
    .{ .item = .{ .output_part = .{ .array = .content, .kind = .output_text } }, .handles = &.{"done"} },
    .{ .item = .output_close },
    .{ .item = .{ .message = .user }, .handles = &.{"two"} },
    .{ .item = .history_end },
};
const version_three_history = "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"one\"}]}," ++
    "{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[{\"type\":\"function\",\"name\":\"bash\",\"description\":\"d\",\"strict\":false,\"parameters\":{}}]}," ++
    "{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}," ++
    "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"two\"}]}";
const version_three_tools = [_]TestItem{ .{ .item = .tools_start }, .{ .item = .web_search }, .{ .item = .text_format }, .{ .item = .request_end } };
const version_three_end = "],\"tools\":[{\"type\":\"web_search\",\"external_web_access\":true}],\"text\":{\"verbosity\":\"low\"}";

test "version three sends a changed effort at the top of the request, never as an input item" {
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    // The first Operation froze low and this one high: both boundaries
    // write nothing.
    try versionThreeForTesting(&(version_three_first_operation ++ [_]TestItem{.{ .item = .{ .operation = .high } }} ++ version_three_tools), &out);
    try std.testing.expectEqualStrings(version_three_top ++ version_three_history ++ version_three_end ++ "}", out.buffered());
}

test "version three declares a tool an Operation adds inside the history" {
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try versionThreeForTesting(&(version_three_first_operation ++ [_]TestItem{
        .{ .item = .{ .operation = .high } },
        .{ .item = .declare_open },
        .{ .item = .declared_tool, .handles = &.{ "read", "r", "{\"type\":\"object\"}" } },
        .{ .item = .declare_close },
    } ++ version_three_tools), &out);
    try std.testing.expectEqualStrings(version_three_top ++ version_three_history ++
        ",{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[{\"type\":\"function\",\"name\":\"read\",\"description\":\"r\",\"strict\":false,\"parameters\":{\"type\":\"object\"}}]}" ++
        version_three_end ++ "}", out.buffered());
}

test "a version three compaction request asks for compaction at the top, never with a trigger item" {
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try versionThreeForTesting(&(version_three_first_operation ++ [_]TestItem{
        .{ .item = .{ .operation = .high } },
        .{ .item = .compaction_trigger },
    } ++ version_three_tools), &out);
    try std.testing.expectEqualStrings(version_three_top ++ version_three_history ++ version_three_end ++
        ",\"tool_choice\":\"none\",\"context_management\":[{\"type\":\"compaction\",\"compact_threshold\":1000}]}", out.buffered());
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

fn legacyImageDomain(codec: protocol.Codec, compact: bool, out: *std.Io.Writer) !void {
    var carry = initialCarry(codec, .low);
    var encoder = resumeFrom(carry);
    try encodeForTesting(&encoder, &carry, &.{
        .{ .item = .{ .settings = .{ .effort = .high, .starting_effort = .low, .session_affinity = @splat(0), .model_length = 1 } }, .handles = &.{"m"} },
        .{ .item = .instructions, .handles = &.{"i\"\\\n\x01é"} },
        .{ .item = .{ .message = .user }, .handles = &.{ "body\"\\\n\x01é", "peer sender, not instructions" } },
        .{ .item = .{ .message = .user }, .handles = &.{""} },
        .{ .item = .{ .message = .instruction }, .handles = &.{""} },
        .{ .item = .{ .operation = .low } },
    }, out);
    if (declaresTools(codec)) try encodeForTesting(&encoder, &carry, &.{
        .{ .item = .declare_open },
        .{ .item = .declared_tool, .handles = &.{ "browser", "observe\"\\\n", "{\"type\":\"object\"}" } },
        .{ .item = .declare_close },
    }, out);
    try encodeForTesting(&encoder, &carry, &.{
        .{ .item = .{ .output_open = .{ .kind = .reasoning, .phase = .unphased, .omit_reasoning_text = true } } },
        .{ .item = .{ .output_part = .{ .array = .summary, .kind = .summary_text } }, .handles = &.{"summary"} },
        .{ .item = .{ .output_part = .{ .array = .content, .kind = .reasoning_text } }, .handles = &.{"private, must not replay"} },
        .{ .item = .output_close, .handles = &.{"\"encrypted_content\":\"opaque\",\"status\":\"completed\""} },
        .{ .item = .{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, .handles = &.{ "browser", "call\"\\\n", "{\"url\":\"x\"}" } },
        .{ .item = .output_close, .handles = &.{"\"id\":\"old-call\""} },
        .{ .item = .tool_result, .handles = &.{ "call\"\\\n", "{\"content\":[{\"type\":\"text\",\"text\":\"MCP\\ntext\"}],\"isError\":false}" } },
        .{ .item = .tool_result, .handles = &.{ "empty", "" } },
        .{ .item = .tool_result, .handles = &.{ "legacy-image-json", "{\"content\":[{\"type\":\"image\",\"data\":\"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\",\"mimeType\":\"image/png\"}],\"isError\":false}" } },
        .{ .item = .{ .output_open = .{ .kind = .message, .phase = .final_answer, .omit_reasoning_text = false } } },
        .{ .item = .{ .output_part = .{ .array = .content, .kind = .output_text } }, .handles = &.{ "", "\"annotations\":[]" } },
        .{ .item = .{ .output_part = .{ .array = .content, .kind = .output_text } }, .handles = &.{"done"} },
        .{ .item = .output_close },
        .{ .item = .{ .message = .user }, .handles = &.{"next"} },
        .{ .item = .{ .operation = .high } },
        .{ .item = .history_end },
    }, out);
    if (compact) try encodeForTesting(&encoder, &carry, &.{.{ .item = .compaction_trigger }}, out);
    try encodeForTesting(&encoder, &carry, &.{.{ .item = .tools_start }}, out);
    if (!declaresTools(codec)) try encodeForTesting(&encoder, &carry, &.{.{ .item = .tool, .handles = &.{ "browser", "observe\"\\\n", "{\"type\":\"object\"}" } }}, out);
    try encodeForTesting(&encoder, &carry, &.{
        .{ .item = .web_search },
        .{ .item = .text_format, .handles = &.{"{\"type\":\"object\",\"properties\":{}}"} },
        .{ .item = .request_end },
    }, out);
}

test "additive image legacy requests retain their original bytes" {
    for ([_]protocol.Codec{ .@"openai-responses/1", .@"openai-responses/2", .@"openai-responses/3" }) |codec| {
        for ([_]bool{ false, true }) |compact| {
            var buffer: [8192]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            try legacyImageDomain(codec, compact, &out);
            try expectLegacyImageGolden(codec, compact, out.buffered());
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
            defer parsed.deinit();
            const history = parsed.value.object.get("input").?.array.items;
            var tool_outputs: usize = 0;
            for (history) |item| {
                const tag = item.object.get("type") orelse continue;
                if (!std.mem.eql(u8, tag.string, "function_call_output")) continue;
                try std.testing.expect(item.object.get("output").? == .string);
                tool_outputs += 1;
            }
            try std.testing.expectEqual(@as(usize, 3), tool_outputs);
        }
    }
}

fn expectLegacyImageGolden(codec: protocol.Codec, compact: bool, actual: []const u8) !void {
    const expected: []const u8 = switch (codec) {
        .@"openai-responses/1" => if (compact) @embedFile("codecs/fixtures/image-input/1-compaction.json") else @embedFile("codecs/fixtures/image-input/1-regular.json"),
        .@"openai-responses/2" => if (compact) @embedFile("codecs/fixtures/image-input/2-compaction.json") else @embedFile("codecs/fixtures/image-input/2-regular.json"),
        .@"openai-responses/3" => if (compact) @embedFile("codecs/fixtures/image-input/3-compaction.json") else @embedFile("codecs/fixtures/image-input/3-regular.json"),
    };
    try std.testing.expectEqualStrings(expected, actual);
}

const additive_png = @embedFile("codecs/fixtures/image-input/pixel.png");
const additive_base64 = @embedFile("codecs/fixtures/image-input/pixel.base64");
const additive_image_history = [_]TestItem{
    .{ .item = .{ .message = .user }, .handles = &.{"legacy-prefix"} },
    .{ .item = .{ .image_message_open = .user } },
    .{ .item = .input_text, .handles = &.{""} },
    .{ .item = .input_text, .handles = &.{"What is in this screenshot?"} },
    .{ .item = .input_text, .handles = &.{""} },
    .{ .item = .{ .input_image = .png }, .handles = &.{additive_png} },
    .{ .item = .image_message_close },
    .{ .item = .{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, .handles = &.{ "browser", "screenshot-call", "{}" } },
    .{ .item = .output_close },
    .{ .item = .image_tool_open, .handles = &.{"screenshot-call"} },
    .{ .item = .input_text, .handles = &.{"Observed browser screenshot"} },
    .{ .item = .{ .input_image = .png }, .handles = &.{additive_png} },
    .{ .item = .input_text, .handles = &.{""} },
    .{ .item = .image_tool_close },
    .{ .item = .{ .output_open = .{ .kind = .function_call, .phase = .unphased, .omit_reasoning_text = false } }, .handles = &.{ "browser", "text-call", "{}" } },
    .{ .item = .output_close },
    .{ .item = .tool_result, .handles = &.{ "text-call", "Fresh text-only observation remains a string" } },
};
const additive_image_tail = [_]TestItem{
    .{ .item = .history_end },
    .{ .item = .{ .operation = .high } },
    .{ .item = .tools_start },
    .{ .item = .text_format },
    .{ .item = .request_end },
};

fn additiveImageStart(codec: protocol.Codec, encoder: *Encoder, carry: *Carry, out: *std.Io.Writer) !void {
    carry.* = initialCarry(codec, .low);
    encoder.* = resumeFrom(carry.*);
    try encodeForTesting(encoder, carry, &.{
        .{ .item = .{ .settings = .{ .effort = .high, .starting_effort = .low, .session_affinity = @splat(0), .model_length = 1 } }, .handles = &.{"m"} },
        .{ .item = .instructions, .handles = &.{"i"} },
    }, out);
}

test "additive image inputs use typed parts and preserve whole-element carry" {
    try std.testing.expect(codec_abi.ItemKind.image_message_open.resumes());
    try std.testing.expect(codec_abi.ItemKind.image_tool_open.resumes());
    try std.testing.expect(codec_abi.ItemKind.image_message_close.endsElement());
    try std.testing.expect(codec_abi.ItemKind.image_tool_close.endsElement());
    for ([_]codec_abi.ItemKind{ .input_text, .input_image }) |kind| {
        try std.testing.expect(!kind.resumes());
        try std.testing.expect(!kind.endsElement());
    }
    for ([_]protocol.Codec{ .@"openai-responses/1", .@"openai-responses/2", .@"openai-responses/3" }) |codec| {
        var buffer: [8192]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var carry = initialCarry(codec, .low);
        var encoder = resumeFrom(carry);
        try additiveImageStart(codec, &encoder, &carry, &out);
        try encodeForTesting(&encoder, &carry, &additive_image_history, &out);
        try encodeForTesting(&encoder, &carry, &additive_image_tail, &out);
        const expected = switch (codec) {
            .@"openai-responses/1" => @embedFile("codecs/fixtures/image-input/1-image.json"),
            .@"openai-responses/2" => @embedFile("codecs/fixtures/image-input/2-image.json"),
            .@"openai-responses/3" => @embedFile("codecs/fixtures/image-input/3-image.json"),
        };
        try std.testing.expectEqualStrings(expected, out.buffered());
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
        defer parsed.deinit();
        const history = parsed.value.object.get("input").?.array.items;
        const user = history[1].object;
        try std.testing.expectEqualStrings("user", user.get("role").?.string);
        const parts = user.get("content").?.array.items;
        try std.testing.expectEqual(@as(usize, 4), parts.len);
        try std.testing.expectEqualStrings("", parts[0].object.get("text").?.string);
        try std.testing.expectEqualStrings("", parts[2].object.get("text").?.string);
        try std.testing.expectEqualStrings("input_image", parts[3].object.get("type").?.string);
        try std.testing.expectEqualStrings("data:image/png;base64," ++ additive_base64, parts[3].object.get("image_url").?.string);
        try std.testing.expectEqualStrings("auto", parts[3].object.get("detail").?.string);
        const tool = history[3].object;
        try std.testing.expectEqualStrings("function_call_output", tool.get("type").?.string);
        try std.testing.expectEqualStrings("screenshot-call", tool.get("call_id").?.string);
        const observed = tool.get("output").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), observed.len);
        try std.testing.expectEqualStrings("input_text", observed[0].object.get("type").?.string);
        try std.testing.expectEqualStrings("input_image", observed[1].object.get("type").?.string);
        try std.testing.expectEqualStrings("data:image/png;base64," ++ additive_base64, observed[1].object.get("image_url").?.string);
        try std.testing.expectEqualStrings("auto", observed[1].object.get("detail").?.string);
        try std.testing.expectEqualStrings("", observed[2].object.get("text").?.string);
        try std.testing.expectEqualStrings("text-call", history[5].object.get("call_id").?.string);
        try std.testing.expectEqualStrings("Fresh text-only observation remains a string", history[5].object.get("output").?.string);
        for (0..additive_image_history.len + 1) |cut| {
            if (cut != 0) {
                const kind: codec_abi.ItemKind = additive_image_history[cut - 1].item;
                if (!kind.endsElement()) continue;
            }
            var resumed_buffer: [8192]u8 = undefined;
            var resumed: std.Io.Writer = .fixed(&resumed_buffer);
            try additiveImageStart(codec, &encoder, &carry, &resumed);
            try encodeForTesting(&encoder, &carry, additive_image_history[0..cut], &resumed);
            encoder = resumeFrom(initialCarry(codec, .low));
            try encodeForTesting(&encoder, &carry, additive_image_history[cut..], &resumed);
            try encodeForTesting(&encoder, &carry, &additive_image_tail, &resumed);
            try std.testing.expectEqualStrings(out.buffered(), resumed.buffered());
        }
        var prefix_buffer: [1024]u8 = undefined;
        var prefix: std.Io.Writer = .fixed(&prefix_buffer);
        try additiveImageStart(codec, &encoder, &carry, &prefix);
        try encodeForTesting(&encoder, &carry, additive_image_history[0..1], &prefix);
        try std.testing.expectStringStartsWith(out.buffered(), prefix.buffered());
    }
}

test "additive typed image pieces stay bounded over the new value domain" {
    for (std.enums.values(responses.Version)) |version| {
        for ([_]bool{ false, true }) |comma| {
            for (std.enums.values(codec_abi.ImageMime)) |mime| {
                for ([_]codec_abi.Item{
                    .{ .image_message_open = .user },
                    .{ .image_message_open = .instruction },
                    .image_tool_open,
                    .input_text,
                    .{ .input_image = mime },
                    .image_message_close,
                    .image_tool_close,
                }) |item| {
                    var encoder: responses.Encoder = .{ .carry = .{ .version = version, .input_comma = comma }, .input_part_comma = comma };
                    var pieces: codec_abi.Pieces = .{ .len = 0 };
                    const header: codec_abi.ItemHeader = .{ .item = item, .handles = 0b1 };
                    try encoder.encodeItem(&header, &pieces);
                    try std.testing.expect(pieces.len <= codec_abi.max_pieces);
                    for (pieces.slice()) |piece| switch (piece) {
                        .literal => |bytes| try std.testing.expect(bytes.len != 0),
                        .content => |content| try std.testing.expect(header.has(content.handle)),
                        .base64 => |handle| try std.testing.expect(header.has(handle)),
                    };
                }
            }
        }
    }
}

test "additive image-only and repeated parts keep MIME framing and order" {
    const expected_png = "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64," ++ additive_base64 ++ "\",\"detail\":\"auto\"}";
    const expected_jpeg = "{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64,/9j/2Q==\",\"detail\":\"auto\"}";
    for ([_]protocol.Codec{ .@"openai-responses/1", .@"openai-responses/2", .@"openai-responses/3" }) |codec| {
        for (std.enums.values(codec_abi.Author)) |author| {
            var buffer: [2048]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            var carry = initialCarry(codec, null);
            var encoder = resumeFrom(carry);
            try encodeForTesting(&encoder, &carry, &.{
                .{ .item = .{ .image_message_open = author } },
                .{ .item = .{ .input_image = .png }, .handles = &.{additive_png} },
                .{ .item = .image_message_close },
            }, &out);
            try std.testing.expectEqualStrings(if (author == .user) "{\"role\":\"user\",\"content\":[" ++ expected_png ++ "]}" else "{\"role\":\"developer\",\"content\":[" ++ expected_png ++ "]}", out.buffered());
            out.end = 0;
            carry = initialCarry(codec, null);
            encoder = resumeFrom(carry);
            try encodeForTesting(&encoder, &carry, &.{
                .{ .item = .image_tool_open, .handles = &.{"call\"\n"} },
                .{ .item = .{ .input_image = .png }, .handles = &.{additive_png} },
                .{ .item = .input_text, .handles = &.{"between"} },
                .{ .item = .{ .input_image = .jpeg }, .handles = &.{"\xff\xd8\xff\xd9"} },
                .{ .item = .{ .input_image = .png }, .handles = &.{additive_png} },
                .{ .item = .image_tool_close },
            }, &out);
            try std.testing.expectEqualStrings("{\"type\":\"function_call_output\",\"call_id\":\"call\\\"\\n\",\"output\":[" ++ expected_png ++ ",{\"type\":\"input_text\",\"text\":\"between\"}," ++ expected_jpeg ++ "," ++ expected_png ++ "]}", out.buffered());
        }
    }
}
